"""Command mode's decision models: does what you said run the right command, how fast, how cheap.

  bench/suite.py commands run                                   # Jev and the default chat models
  bench/suite.py commands run -m jev -m openrouter:google/gemini-3.5-flash-lite -r 3
  bench/suite.py commands run --catalog                         # with 29 more commands to choose from
  bench/suite.py commands report [--file results/commands/….json] [--markdown] [--failures MODEL]
  bench/suite.py commands cases [--tag zh]

Each case (command_cases.json) is something you might say — English, Chinese, mixed, with fillers,
with speech-model errors, or not a command at all — and every answer that counts as right
("volume -10", "return", "none"). The commands are the app's: its example scripts' docstrings
(Sources/DictationKit/Commands/ExampleCommands) and the built-in return, repeat, create and open (its choices: this Mac's apps); --catalog adds the
commands in command_catalog.json, to see how a model copes with more to choose from.

Models:
  jev                   TypeSafe's Jev on OpenRouter's decisions API, asked exactly as the app asks it
                        (JevDecider): one multiple-choice question for the command, one per command
                        for its choice. Below 0.5 confidence counts as "none", as in the app.
  openrouter:<id>       a chat model, told the commands and their choices and asked for JSON
                        {"command", "choice"} (a schema with the names as an enum), at temperature 0,
                        reasoning off or lowest (ChatDecider in the app).

Scores: right (an expected answer), wrong run (ran a command that shouldn't run: the costly
mistake), missed (said "none" when a command should run). Wait: one request from this machine.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import time
from datetime import datetime
from pathlib import Path

import harness
import openrouter
from openrouter import CHAT, REASONING_FALLBACKS, post_json

NAME = "commands"
HELP = "command mode's decision models: right command, wrong runs, wait and cost"
CASES = harness.ROOT / "command_cases.json"
CATALOG = harness.ROOT / "command_catalog.json"
EXAMPLES = harness.ROOT.parent / "Sources/DictationKit/Commands/ExampleCommands"
DECISIONS = "https://openrouter.ai/api/alpha/decisions"
JEV = "~typesafe/jev-latest"
MIN_CONFIDENCE = 0.5  # CommandDecision.minConfidence
DEFAULT_MODELS = ["jev", "openrouter:google/gemini-3.5-flash-lite", "openrouter:anthropic/claude-haiku-5.5",
                  "openrouter:deepseek/deepseek-v4.1-flash", "openrouter:z-ai/glm-5.3-flash",
                  "openrouter:inception/mercury-3"]
BUILT_IN = [{"name": "return", "summary": "Press Return (send) in the front app", "choices": {}},
            {"name": "repeat", "summary": "Run the last command again", "choices": {}},
            {"name": "create", "summary": "Create a new command: the user asks for a new command (“create command”, "
                                          "“新建命令”, “写一个命令”) and describes what it should do", "choices": {}},
            {"name": "open", "summary": "Open an app installed on this Mac (not a website)", "choices": {}}]
APP_FOLDERS = [Path("/Applications"), Path.home() / "Applications"]  # Command.appFolders
MAX_APPS = 254  # Command.maxApps
NO_APP = "Not one of these apps"  # Command.noApp: "open none" runs nothing


def installed_apps(folders: list[Path] = APP_FOLDERS) -> list[str]:
    """The apps you installed, by name (Command.installedApps): open's choices."""
    return sorted({p.stem for folder in folders if folder.is_dir() for p in folder.glob("*.app")})


# ---------------------------------------------------------------- commands, as the app reads them

def parse_script(text: str, name: str) -> dict | None:
    """A script's command (Command.parse): the docstring's first line, and `value: meaning` lines
    under "Choices:" up to a blank line."""
    found = re.search(r'"""(.*?)"""', text, re.S) or re.search(r"'''(.*?)'''", text, re.S)
    if not found:
        return None
    lines = [line.strip() for line in found.group(1).splitlines()]
    summary = next((line for line in lines if line), None)
    if summary is None:
        return None
    choices: dict[str, str] = {}
    if "choices:" in [line.lower() for line in lines]:
        for line in lines[[line.lower() for line in lines].index("choices:") + 1:]:
            if not line:
                break
            value, colon, meaning = line.partition(":")
            if colon and value.strip() and " " not in value.strip():
                choices.setdefault(value.strip(), meaning.strip())
    return {"name": name, "summary": summary, "choices": choices}


def app_commands(examples: Path = EXAMPLES, apps: list[str] | None = None) -> list[dict]:
    """Built-ins (open's choices: this Mac's apps), then the example scripts by name (Command.all)."""
    apps = installed_apps() if apps is None else apps
    open_choices = {a: a for a in apps[:MAX_APPS]} | {"none": NO_APP}
    built_in = [{**c, "choices": open_choices} if c["name"] == "open" else c for c in BUILT_IN]
    scripts = [parse_script(p.read_text(), p.stem) for p in sorted(examples.glob("*.py"))]
    return built_in + [s for s in scripts if s]


def commands_for(catalog: bool) -> list[dict]:
    extra = json.loads(CATALOG.read_text())["commands"] if catalog else []
    return app_commands() + extra


def label(command: str | None, choice: str | None) -> str:
    """As History shows it: "volume -10", "return", "none"."""
    return " ".join(x for x in (command, choice) if x) if command else "none"


# ---------------------------------------------------------------- deciders

def jev_body(said: str, commands: list[dict]) -> dict:
    """JevDecider.request's body."""
    which = {c["name"]: c["summary"] for c in commands}
    which["none"] = "None of these does what the user asked"
    questions = {"command": {"type": "choice", "instructions": "Which command does what the user asked for?",
                             "criteria": which}}
    for c in commands:
        if c["choices"]:
            questions["choice:" + c["name"]] = {
                "type": "choice", "instructions": f"If the user wants {c['name']} ({c['summary']}): which of these?",
                "criteria": c["choices"]}
    return {"model": JEV, "state": "The user said: " + said, "questions": questions}


def ask_jev(said: str, commands: list[dict], key: str) -> tuple[str, float | None, dict]:
    answer = post_json(DECISIONS, jev_body(said, commands), key)
    answers = answer["answers"]
    pick = answers["command"]
    name = pick["choice"]
    if name == "none" or pick.get("confidence", 0) < MIN_CONFIDENCE:
        return "none", answer.get("usage", {}).get("cost"), {"confidence": pick.get("confidence"), "picked": name}
    choice = answers.get("choice:" + name, {}).get("choice")
    return label(name, choice), answer.get("usage", {}).get("cost"), {"confidence": pick.get("confidence")}


def chat_prompt(commands: list[dict]) -> str:
    lines = ["You pick the command for what the user said (often transcribed speech, English, Chinese or both).",
             "Commands:"]
    for c in commands:
        choices = "; ".join(f"{v} = {m}" for v, m in c["choices"].items())
        lines.append(f"- {c['name']}: {c['summary']}" + (f". Choices: {choices}" if choices else ""))
    lines.append('Answer JSON {"command": <name, or "none" if no command does it>, "choice": <one of that '
                 'command\'s choices, or "" if it has none>}. If it isn\'t a request to run one of these, answer none.')
    return "\n".join(lines)


def chat_body(model: str, said: str, commands: list[dict], reasoning: dict) -> dict:
    values = sorted({v for c in commands for v in c["choices"]} | {""})
    schema = {"type": "object", "additionalProperties": False, "required": ["command", "choice"], "properties": {
        "command": {"type": "string", "enum": [c["name"] for c in commands] + ["none"]},
        "choice": {"type": "string", "enum": values}}}
    return {"model": model, "temperature": 0, "max_tokens": 80, "reasoning": reasoning,
            "messages": [{"role": "system", "content": chat_prompt(commands)}, {"role": "user", "content": said}],
            "response_format": {"type": "json_schema", "json_schema": {"name": "command", "strict": True, "schema": schema}}}


_reasoning: dict[str, dict] = {}  # what each model accepted


def ask_chat(model: str, said: str, commands: list[dict], key: str) -> tuple[str, float | None, dict]:
    tries = [_reasoning[model]] if model in _reasoning else REASONING_FALLBACKS
    for i, reasoning in enumerate(tries):
        try:
            answer = post_json(CHAT, chat_body(model, said, commands, reasoning), key)
            _reasoning[model] = reasoning
            break
        except RuntimeError as e:
            if i == len(tries) - 1 or "reasoning" not in str(e).lower():
                raise
    content = answer["choices"][0]["message"].get("content") or ""
    picked = json.loads(content[content.find("{"):content.rfind("}") + 1])
    name, choice = picked.get("command"), picked.get("choice") or None
    known = {c["name"]: c for c in commands}
    if name not in known:
        return "none", answer.get("usage", {}).get("cost"), {}
    if choice not in known[name]["choices"]:
        choice = None  # a choice from another command: the app would run it without one
    return label(name, choice), answer.get("usage", {}).get("cost"), {}


def ask(model: str, said: str, commands: list[dict], key: str):
    if model == "jev":
        got, cost, extra = ask_jev(said, commands, key)
    elif model.startswith("openrouter:"):
        got, cost, extra = ask_chat(model[len("openrouter:"):], said, commands, key)
    else:
        raise SystemExit(f"unknown model {model!r}: use jev or openrouter:<id>")
    return ("none" if got == "open none" else got), cost, extra


# ---------------------------------------------------------------- run, score, report

def score(case: dict, got: str) -> str:
    """right, wrong-run (ran something it shouldn't), or missed (none when a command should run)."""
    if got in case["expect"]:
        return "right"
    return "missed" if got == "none" else "wrong-run"


def run(models: list[str], cases: list[dict], commands: list[dict], rounds: int, workers: int) -> dict:
    key = openrouter.key()
    results: dict[str, list[dict]] = {m: [] for m in models}

    def one(model: str, case: dict) -> dict:
        started = time.perf_counter()
        try:
            got, cost, extra = ask(model, case["said"], commands, key)
            error = None
        except Exception as e:  # noqa: BLE001 (a failed request is a result too)
            got, cost, extra, error = "none", None, {}, str(e)[:200]
        return {"said": case["said"], "tags": case.get("tags", []), "expect": case["expect"], "got": got,
                "score": "error" if error else score(case, got), "seconds": time.perf_counter() - started,
                "cost": cost, "error": error, **extra}

    jobs = [(m, c) for _ in range(rounds) for c in cases for m in models]
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for model, done in zip([m for m, _ in jobs], pool.map(lambda job: one(*job), jobs)):
            results[model].append(done)
            mark = {"right": ".", "missed": "m", "wrong-run": "X", "error": "E"}[done["score"]]
            print(mark, end="", flush=True)
    print()
    return {"models": models, "rounds": rounds, "commands": [c["name"] for c in commands], "results": results}


def summary(answers: list[dict]) -> dict:
    n = len(answers)
    count = lambda s: sum(a["score"] == s for a in answers)  # noqa: E731
    costs = [a["cost"] for a in answers if a["cost"] is not None]
    return {"right": count("right") / n, "wrong_run": count("wrong-run"), "missed": count("missed"),
            "errors": count("error"), "n": n, "seconds": harness.describe([a["seconds"] for a in answers if not a["error"]]),
            "cost_per_1000": 1000 * sum(costs) / len(costs) if costs else None}


def by_tag(answers: list[dict]) -> dict[str, float]:
    tags = sorted({t for a in answers for t in a["tags"]})
    return {t: sum(a["score"] == "right" for a in answers if t in a["tags"]) / sum(t in a["tags"] for a in answers)
            for t in tags}


def report(data: dict, markdown: bool = False, failures: str | None = None) -> str:
    rows = []
    tags = sorted({t for answers in data["results"].values() for a in answers for t in a["tags"]})
    for model, answers in data["results"].items():
        s, t = summary(answers), by_tag(answers)
        rows.append([model, f"{100 * s['right']:.0f}%", s["wrong_run"], s["missed"], s["errors"],
                     harness.seconds(s["seconds"].get("p50")), harness.seconds(s["seconds"].get("p95")),
                     f"${s['cost_per_1000']:.3f}" if s["cost_per_1000"] is not None else "–"]
                    + [f"{100 * t[tag]:.0f}%" for tag in tags])
    rows.sort(key=lambda r: (-float(r[1][:-1]), r[2]))
    out = [f"{len(data['commands'])} commands, {data['rounds']} round(s)",
           harness.table(["model", "right", "wrong runs", "missed", "errors", "wait p50", "p95", "per 1000"] + tags,
                         rows, markdown=markdown)]
    if failures:
        out.append(f"\n{failures} — not right:")
        for a in data["results"].get(failures, []):
            if a["score"] != "right":
                out.append(f"  {a['score']:<9} {a['said']!r} → {a['got']}  (want {' | '.join(a['expect'])})"
                           + (f"  {a['error']}" if a["error"] else ""))
    return "\n".join(out)


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="suite.py commands", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    r = sub.add_parser("run", help="ask each model every case")
    r.add_argument("-m", "--model", action="append", help="jev or openrouter:<id> (repeatable; default: a set)")
    r.add_argument("-r", "--rounds", type=int, default=1)
    r.add_argument("--catalog", action="store_true", help="add command_catalog.json's commands to choose from")
    r.add_argument("--tag", help="only cases with this tag")
    r.add_argument("--workers", type=int, default=8)
    p = sub.add_parser("report", help="the latest (or --file) run")
    p.add_argument("--file", type=Path)
    p.add_argument("--markdown", action="store_true")
    p.add_argument("--failures", metavar="MODEL", help="list the cases MODEL didn't get right")
    c = sub.add_parser("cases", help="the test set")
    c.add_argument("--tag")
    return parser


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)

    cases = json.loads(CASES.read_text())["cases"]
    if getattr(args, "tag", None):
        cases = [c for c in cases if args.tag in c.get("tags", [])]
    if args.action == "cases":
        for case in cases:
            print(f"{case['said']!r:60} → {' | '.join(case['expect'])}   [{', '.join(case.get('tags', []))}]")
        print(f"{len(cases)} cases")
        return 0
    if args.action == "report":
        files = harness.result_files(NAME)
        path = args.file or (files[-1] if files else None)
        if not path:
            raise SystemExit("no results yet: run first")
        print(report(json.loads(path.read_text()), args.markdown, args.failures))
        return 0
    data = run(args.model or DEFAULT_MODELS, cases, commands_for(args.catalog), args.rounds, args.workers)
    data.update(catalog=args.catalog, tag=args.tag, date=datetime.now().isoformat(timespec="seconds"),
                environment=harness.environment())
    path = harness.save_result(NAME, ("catalog-" if args.catalog else "") + f"{len(data['models'])}-models", data)
    print(report(data))
    print(f"\nsaved {path.relative_to(harness.ROOT.parent)}")
    return 0
