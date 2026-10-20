"""Command mode's "create command": does the model write a working command in one go?

  bench/suite.py create run                         # the app's model, every case, static checks
  bench/suite.py create run --try                   # also run the scripts of cases tagged "safe"
  bench/suite.py create run -m openrouter:<id> -m openrouter:<id>+think -r 2
  bench/suite.py create report [--file …] [--failures MODEL]
  bench/suite.py create show [--file …] CASE        # the script each model wrote for a case
  bench/suite.py create cases

Each case (create_cases.json) is a request as you'd say it ("create command, tile the window to the
left half", "新建命令 静音"), and either the existing command that already does it or "new". The model
is asked exactly as the app asks it (CommandWriter): the system prompt is
Sources/DictationKit/Commands/WriteCommand.txt with the app's commands filled in.

Checks, in order (the first failed one is the score):
  format     the reply is "EXISTING: <name>" or "NAME: <name>" and a ```python block
  existing   it found the command that already does it (or wrote one when none does)
  name       a new, lowercase-hyphenated name
  docstring  the app can read it (a summary line; choices under "Choices:")
  syntax     Python parses it
  runs       --try only, "safe" cases only: `uv run --script` with its first choice (if any) exits 0
             within 10 s and prints a line. Safe cases only read things (battery, time, Wi-Fi);
             --try-all runs every script, which changes this Mac (windows, settings, apps).

Models: openrouter:<id>, reasoning off or lowest as the app asks; "+think" asks with reasoning on.
"""
from __future__ import annotations

import argparse
import ast
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from datetime import datetime
from pathlib import Path

import harness
import openrouter
from openrouter import CHAT, REASONING_FALLBACKS, post_json
from suites import commands

NAME = "create"
HELP = "command mode's create command: does the model write a working script in one go"
CASES = harness.ROOT / "create_cases.json"
PROMPT = harness.ROOT.parent / "Sources/DictationKit/Commands/WriteCommand.txt"
MODEL = "openrouter:deepseek/deepseek-v4.1-flash"  # CommandWriter.model
PROVIDERS = ["Together", "DeepInfra"]  # CommandWriter.providers
TIMEOUT = 10  # CommandMode.timeout
NAME_PATTERN = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")  # CommandWriter.validName


def command_lines(cmds: list[dict]) -> str:
    """The commands as the prompt lists them (CommandWriter.list)."""
    lines = []
    for c in cmds:
        choices = ", ".join(f"{v} = {m}" for v, m in c["choices"].items())
        lines.append(f"- {c['name']}: {c['summary']}" + (f" (choices: {choices})" if choices else ""))
    return "\n".join(lines)


def system_prompt(cmds: list[dict]) -> str:
    """WriteCommand.txt with the commands filled in (CommandWriter.prompt): create isn't listed, and
    built-ins without their choices (open's apps)."""
    built_in = {c["name"] for c in commands.BUILT_IN}
    listed = [{**c, "choices": {}} if c["name"] in built_in else c for c in cmds if c["name"] != "create"]
    return PROMPT.read_text().replace("{commands}", command_lines(listed))


def parse_reply(text: str) -> dict:
    """{"existing": name} or {"name", "script"} (CommandWriter.parse); {} when it's neither."""
    text = text.strip()
    if found := re.match(r"^EXISTING:\s*([\w-]+)\s*$", text):
        return {"existing": found.group(1)}
    name = re.search(r"^NAME:\s*(\S+)\s*$", text, re.M)
    code = re.search(r"```(?:python)?\s*\n(.*?)```", text, re.S)
    if name and code:
        return {"name": name.group(1), "script": code.group(1).rstrip() + "\n"}
    return {}


def ask(model: str, said: str, cmds: list[dict], key: str) -> tuple[str, float | None]:
    think = model.endswith("+think")
    model_id = model.removesuffix("+think").removeprefix("openrouter:")
    tries = [{"enabled": True}] if think else REASONING_FALLBACKS
    for i, reasoning in enumerate(tries):
        body = {"model": model_id, "temperature": 0, "reasoning": reasoning, "max_tokens": 4000,
                "messages": [{"role": "system", "content": system_prompt(cmds)}, {"role": "user", "content": said}]}
        if model == MODEL:
            body["provider"] = {"order": PROVIDERS}
        try:
            answer = post_json(CHAT, body, key, timeout=120)
            break
        except RuntimeError as e:
            if i == len(tries) - 1 or "reasoning" not in str(e).lower():
                raise
    return answer["choices"][0]["message"].get("content") or "", answer.get("usage", {}).get("cost")


def try_script(script: str, name: str, choice: str | None, said: str = "") -> tuple[bool, str]:
    """Runs it as the app does (CommandMode.run); (exit 0 and printed something, what it printed)."""
    uv = shutil.which("uv")
    if not uv:
        return False, "uv isn't installed"
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / f"{name}.py"
        path.write_text(script)
        try:
            done = subprocess.run([uv, "run", "--quiet", "--script", str(path)] + ([choice] if choice else []),
                                  capture_output=True, text=True, timeout=TIMEOUT, stdin=subprocess.DEVNULL,
                                  env={**os.environ, "COMMAND_SAID": said})
        except subprocess.TimeoutExpired:
            return False, f"took longer than {TIMEOUT} s"
    out = done.stdout.strip().splitlines()
    if done.returncode != 0:
        errors = done.stderr.strip().splitlines()
        return False, (errors[-1] if errors else f"exited with {done.returncode}")[:200]
    return bool(out), (out[0] if out else "printed nothing")[:200]


def check(case: dict, reply: str, cmds: list[dict], run_it: bool) -> dict:
    """The first check that fails ("format", "existing", …) or "ok", with what it found."""
    parsed = parse_reply(reply)
    if not parsed:
        return {"score": "format"}
    wants = case["expect"] if isinstance(case["expect"], list) else [case["expect"]]
    if "existing" in parsed:
        return {"score": "ok" if parsed["existing"] in wants else "existing", "got": "existing:" + parsed["existing"]}
    found = {"got": "new:" + parsed["name"], "script": parsed["script"]}
    if "new" not in wants:
        return {**found, "score": "existing"}
    if not NAME_PATTERN.match(parsed["name"]) or parsed["name"] in {c["name"] for c in cmds}:
        return {**found, "score": "name"}
    command = commands.parse_script(parsed["script"], parsed["name"])
    if not command:
        return {**found, "score": "docstring"}
    try:
        ast.parse(parsed["script"])
    except SyntaxError as e:
        return {**found, "score": "syntax", "detail": str(e)}
    if run_it:
        choice = next(iter(command["choices"]), None)
        ok, printed = try_script(parsed["script"], parsed["name"], choice, case["said"])
        return {**found, "score": "ok" if ok else "runs", "ran": choice or "", "detail": printed}
    return {**found, "score": "ok"}


def run(models: list[str], cases: list[dict], rounds: int, workers: int, try_safe: bool, try_all: bool) -> dict:
    key = openrouter.key()
    cmds = commands.app_commands()
    results: dict[str, list[dict]] = {m: [] for m in models}

    def one(model: str, case: dict) -> dict:
        started = time.perf_counter()
        try:
            reply, cost = ask(model, case["said"], cmds, key)
            error = None
        except Exception as e:  # noqa: BLE001 (a failed request is a result too)
            reply, cost, error = "", None, str(e)[:200]
        seconds = time.perf_counter() - started
        run_it = try_all or (try_safe and "safe" in case.get("tags", []))
        found = {"score": "error"} if error else check(case, reply, cmds, run_it)
        return {"said": case["said"], "tags": case.get("tags", []), "expect": case["expect"], "reply": reply,
                "seconds": seconds, "cost": cost, "error": error, "tried": run_it, **found}

    jobs = [(m, c) for _ in range(rounds) for c in cases for m in models]
    # Requests in parallel; the scripts run one at a time inside `check`, which is fine for a handful.
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for model, done in zip([m for m, _ in jobs], pool.map(lambda job: one(*job), jobs)):
            results[model].append(done)
            print("." if done["score"] == "ok" else done["score"][0].upper(), end="", flush=True)
    print()
    return {"models": models, "rounds": rounds, "results": results}


def report(data: dict, markdown: bool = False, failures: str | None = None) -> str:
    checks = ["format", "existing", "name", "docstring", "syntax", "runs", "error"]
    rows = []
    for model, answers in data["results"].items():
        n = len(answers)
        tried = [a for a in answers if a.get("tried")]
        costs = [a["cost"] for a in answers if a["cost"] is not None]
        wait = harness.describe([a["seconds"] for a in answers if not a["error"]])
        rows.append([model, f"{100 * sum(a['score'] == 'ok' for a in answers) / n:.0f}%",
                     f"{sum(a['score'] == 'ok' for a in tried)}/{len(tried)}" if tried else "–"]
                    + [sum(a["score"] == c for a in answers) for c in checks]
                    + [harness.seconds(wait.get("p50")), harness.seconds(wait.get("max")),
                       f"${1000 * sum(costs) / len(costs):.2f}" if costs else "–"])
    out = [f"{data['rounds']} round(s)",
           harness.table(["model", "ok", "ran ok"] + checks + ["wait p50", "max", "per 1000"], rows, markdown=markdown)]
    if failures:
        out.append(f"\n{failures} — not ok:")
        for a in data["results"].get(failures, []):
            if a["score"] != "ok":
                out.append(f"  {a['score']:<9} {a['said']!r} → {a.get('got', '')}  (want {a['expect']})"
                           + (f"  {a.get('detail') or a.get('error') or ''}"))
    return "\n".join(out)


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="suite.py create", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    r = sub.add_parser("run", help="ask each model to write every case's command")
    r.add_argument("-m", "--model", action="append", help=f"openrouter:<id>[+think] (repeatable; default {MODEL})")
    r.add_argument("-r", "--rounds", type=int, default=1)
    r.add_argument("--tag", help="only cases with this tag")
    r.add_argument("--try", dest="try_safe", action="store_true", help='run the scripts of cases tagged "safe"')
    r.add_argument("--try-all", action="store_true", help="run every script (changes this Mac)")
    r.add_argument("--workers", type=int, default=8)
    p = sub.add_parser("report", help="the latest (or --file) run")
    p.add_argument("--file", type=Path)
    p.add_argument("--markdown", action="store_true")
    p.add_argument("--failures", metavar="MODEL", help="list the cases MODEL didn't get ok")
    s = sub.add_parser("show", help="what each model replied for the cases whose request contains CASE")
    s.add_argument("case")
    s.add_argument("--file", type=Path)
    c = sub.add_parser("cases", help="the test set")
    c.add_argument("--tag")
    return parser


def latest(path: Path | None) -> dict:
    files = harness.result_files(NAME)
    path = path or (files[-1] if files else None)
    if not path:
        raise SystemExit("no results yet: run first")
    return json.loads(path.read_text())


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    cases = json.loads(CASES.read_text())["cases"]
    if getattr(args, "tag", None):
        cases = [c for c in cases if args.tag in c.get("tags", [])]
    if args.action == "cases":
        for case in cases:
            print(f"{case['said']!r:70} → {case['expect']}   [{', '.join(case.get('tags', []))}]")
        print(f"{len(cases)} cases")
        return 0
    if args.action == "report":
        print(report(latest(args.file), args.markdown, args.failures))
        return 0
    if args.action == "show":
        for model, answers in latest(args.file)["results"].items():
            for a in answers:
                if args.case in a["said"]:
                    print(f"── {model}: {a['said']!r} → {a['score']} {a.get('detail') or ''}\n{a['reply']}\n")
        return 0
    data = run(args.model or [MODEL], cases, args.rounds, args.workers, args.try_safe, args.try_all)
    data.update(tag=args.tag, date=datetime.now().isoformat(timespec="seconds"), environment=harness.environment())
    path = harness.save_result(NAME, f"{len(data['models'])}-models", data)
    print(report(data))
    print(f"\nsaved {path.relative_to(harness.ROOT.parent)}")
    return 0
