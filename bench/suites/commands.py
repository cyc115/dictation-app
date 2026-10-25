"""Command mode's decision models: does what you said run the right command, how fast, how cheap.

  bench/suite.py commands run                                   # Jev and the default chat models
  bench/suite.py commands run -m jev -m openrouter:google/gemini-3.5-flash-lite -r 3
  bench/suite.py commands run --catalog                         # with 29 more commands to choose from
  bench/suite.py commands report [--file results/commands/….json] [--markdown] [--failures MODEL]
  bench/suite.py commands cases [--tag zh]
  bench/suite.py commands run -m jev -m local:kev --workers 1 -r 3   # an on-device decider (its server running)
  bench/suite.py commands resources -m local:kev                 # its memory, CPU/GPU time and energy per decision

Each case (command_cases.json) is something you might say — English, Chinese, mixed, with fillers,
with speech-model errors, or not a command at all — and every answer that counts as right
("volume -10", "return", "none"). The commands are the app's built-ins (built_in_commands.json, which
a Swift test keeps word for word the app's Command.builtIn): open's choices are this Mac's apps,
switch-app's a fixed set of open apps (RUNNING). --catalog adds the commands in command_catalog.json,
to see how a model copes with more to choose from.

Models:
  jev                   TypeSafe's Jev on OpenRouter's decisions API, asked exactly as the app asks it
                        (JevDecider): one multiple-choice question for the command, one per command
                        for its choice. Below 0.5 confidence counts as "none", as in the app.
  openrouter:<id>       a chat model, told the commands and their choices and asked for JSON
                        {"command", "choice"} (a schema with the names as an enum), at temperature 0,
                        reasoning off or lowest (ChatDecider in the app).
  local:<name>          an on-device decision model behind its own server on this Mac, speaking Jev's
                        format (LOCAL: laya, laya-ml, kev, decider). Asked the command first, then
                        that command's choice: two requests, one question each (Decider takes one).
                        Run with --workers 1, so they don't share the GPU. Modifiers trim the prompt
                        (its wait follows its length): local:decider+bare+short-choice+preamble-short
                        (MODIFIERS); variants in one run are interleaved, so they see the same noise.

Scores: right (an expected answer), wrong run (ran a command that shouldn't run: the costly
mistake), missed (said "none" when a command should run). Wait: one request from this machine (local:
both requests); the first answer per model warms it up (loads the model, opens the connection) and
isn't counted.

resources: for a local:<name> model, the server's memory (footprint, resident), its CPU% while idle,
and per decision its CPU and GPU time and an energy estimate (procstats.py: no sudo, so estimated).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import http.client
import json
import re
import threading
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

import harness
import openrouter
import procstats
from openrouter import CHAT, REASONING_FALLBACKS, post_json

NAME = "commands"
HELP = "command mode's decision models: right command, wrong runs, wait and cost"
CASES = harness.ROOT / "command_cases.json"
CATALOG = harness.ROOT / "command_catalog.json"
BUILT_IN_FILE = harness.ROOT / "built_in_commands.json"
DECISIONS = "https://openrouter.ai/api/alpha/decisions"
JEV = "~typesafe/jev-latest"
MIN_CONFIDENCE = 0.5  # CommandDecision.minConfidence
_min_confidence = MIN_CONFIDENCE  # --min-confidence: 0 keeps every pick, so a report can try other cut-offs
# On-device decision models, each behind its own local server (start it first; see results/commands/).
LOCAL = {
    "laya": {"url": "http://127.0.0.1:8010/v1/systemone", "model": "english", "about": "Laya 421M (laya-mlx-serve)"},
    "laya-ml": {"url": "http://127.0.0.1:8010/v1/systemone", "model": "multilingual",
                "about": "Laya multilingual 322M (laya-mlx-serve)"},
    "kev": {"url": "http://127.0.0.1:8009/v1/systemone", "model": "kev-latest", "about": "Kev 0.8B (kev.serve)"},
    "decider": {"url": "http://127.0.0.1:8080/v1/decisions", "model": "pplx-decider-flash-v1.2",
                "about": "Perplexity Decider for Mac, 4B"},
}
# CommandDecision.heard, word for word (a Swift test checks): every decider is told it's speech, maybe misheard.
HEARD = "The user spoke this and speech-to-text wrote it down, so words may be misheard: go by how they sound (“lower the bright knees” is “lower the brightness”, “press and her” is “press Enter”). A stray word or two that sounds like no command is none."
DEFAULT_MODELS = ["jev", "openrouter:google/gemini-3.5-flash-lite", "openrouter:anthropic/claude-haiku-5.5",
                  "openrouter:deepseek/deepseek-v4.1-flash", "openrouter:z-ai/glm-5.3-flash",
                  "openrouter:inception/mercury-3"]
BUILT_IN = [{"name": c["name"], "summary": c["summary"], "choices": dict(c["choices"])}
            for c in json.loads(BUILT_IN_FILE.read_text())]
APP_FOLDERS = [Path("/Applications"), Path.home() / "Applications", Path("/System/Applications")]  # Command.appFolders
FROM_THIS_MAC = {"open", "switch-app", "fix"}  # Command.choicesFromThisMac: apps, or (fix) the other commands
RUNNING = ["Finder", "Ghostty", "Google Chrome", "Mail", "Muse", "Music", "Safari", "Slack", "WeChat"]  # switch-app's choices here
MAX_APPS = 254  # Command.maxApps
NO_APP = "Not one of these apps"  # Command.noApp: "open none" runs nothing
NO_COMMAND = "None named: the last command that failed"  # Command.noCommand


def installed_apps(folders: list[Path] = APP_FOLDERS) -> list[str]:
    """The apps on this Mac, by name (Command.installedApps): open's choices."""
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


def app_commands(apps: list[str] | None = None, running: list[str] = RUNNING) -> list[dict]:
    """The built-ins, as Command.all lists them: open's choices this Mac's apps, switch-app's `running`,
    fix's the other commands."""
    apps = installed_apps() if apps is None else apps
    def named(names: list[str]) -> dict:
        return {a: a for a in names[:MAX_APPS]} | {"none": NO_APP}
    cmds = [{**c, "choices": named(apps if c["name"] == "open" else running)} if c["name"] in {"open", "switch-app"} else c
            for c in BUILT_IN]
    fixable = {c["name"]: c["summary"] for c in cmds if c["name"] != "fix"} | {"none": NO_COMMAND}
    return [{**c, "choices": fixable} if c["name"] == "fix" else c for c in cmds]


def commands_for(catalog: bool) -> list[dict]:
    extra = json.loads(CATALOG.read_text())["commands"] if catalog else []
    return app_commands() + extra


def label(command: str | None, choice: str | None) -> str:
    """As History shows it: "volume -10", "return", "none"."""
    return " ".join(x for x in (command, choice) if x) if command else "none"


# ---------------------------------------------------------------- deciders

# Variants of Jev's request, for tuning it: name the model with modifiers (jev+bare+heard-command).
# Each is its own model in a run, interleaved with the others, so they all see the same network.
# Jev's wait hardly depends on the request's size (4,200 tokens or 700: ~230 ms); its cost does.
JEV_HEARD = {  # other things to tell Jev before what was said (the app's: HEARD)
    "heard-command": "The user is speaking a command to their Mac and speech-to-text wrote it down, so words may be "
                     "misheard: go by how they sound (“lower the bright knees” is “lower the brightness”, “press and "
                     "her” is “press Enter”). Short commands come out the most garbled. Answer none only when it "
                     "can't be one of these.",
    "heard-aloud": HEARD.replace("A stray word or two that sounds like no command is none.",
                                 "Say it out loud: if it sounds like a command, it's that command, even when the words "
                                 "make sense as something else. A stray word or two that sounds like no command is none."),
}
JEV_NONE = {  # other meanings for the command question's "none" (the app's: NONE)
    "none-noise": "It doesn't sound like any of these: noise, chatter, or a request none of them does",
}
NONE = "None of these does what the user asked"
JEV_ASK = {  # other instructions for the command question (the app's: ASK)
    "ask-sound": "Which command did the user ask for? Go by how the words sound, not what they mean.",
}
ASK = "Which command does what the user asked for?"
JEV_MODIFIERS = {"bare": "options named by themselves (\"Safari\": \"Safari\") are sent without a meaning",
                 "warm": "one connection kept open between requests (as a warmed-up app would have)",
                 **{k: "the state starts: " + v[:60] + "…" for k, v in JEV_HEARD.items()},
                 **{k: "none means: " + v for k, v in JEV_NONE.items()},
                 **{k: "the command question: " + v for k, v in JEV_ASK.items()}}


def jev_model(model: str) -> set[str] | None:
    """jev[+modifier…] → its modifiers; None if it isn't Jev."""
    name, *mods = model.split("+")
    return set(mods) if name == "jev" and set(mods) <= set(JEV_MODIFIERS) else None


def jev_body(said: str, commands: list[dict], mods: set[str] = frozenset()) -> dict:
    """JevDecider.request's body (with no modifiers)."""
    which = {c["name"]: c["summary"] for c in commands}
    which["none"] = next((JEV_NONE[m] for m in mods if m in JEV_NONE), NONE)
    questions = {"command": {"type": "choice", "instructions": next((JEV_ASK[m] for m in mods if m in JEV_ASK), ASK),
                             "criteria": which}}
    for c in commands:
        if c["choices"]:
            criteria = {k: None if v == k else v for k, v in c["choices"].items()} if "bare" in mods else c["choices"]
            questions["choice:" + c["name"]] = {
                "type": "choice", "instructions": f"If the user wants {c['name']} ({c['summary']}): which of these?",
                "criteria": criteria}
    heard = next((JEV_HEARD[m] for m in mods if m in JEV_HEARD), HEARD)
    return {"model": JEV, "state": heard + "\nThe user said: " + said, "questions": questions}


_connections = threading.local()  # +warm: each worker's open connection to OpenRouter


def post_warm(url: str, body: dict, key: str) -> dict:
    """post_json over a connection kept open between calls (opened again if the server closed it)."""
    parts = urllib.parse.urlsplit(url)
    for attempt in range(2):
        conn = getattr(_connections, parts.netloc, None) or http.client.HTTPSConnection(parts.netloc, timeout=30)
        setattr(_connections, parts.netloc, conn)
        try:
            conn.request("POST", parts.path, json.dumps(body).encode(), openrouter.headers(key))
            response = conn.getresponse()
            data = response.read()
        except (http.client.HTTPException, OSError):
            conn.close()
            setattr(_connections, parts.netloc, None)
            if attempt:
                raise
            continue
        if response.status != 200:
            raise RuntimeError(f"HTTP {response.status}: {data.decode(errors='replace')[:300]}")
        return json.loads(data)


def ask_jev(said: str, commands: list[dict], key: str, mods: set[str] = frozenset()) -> tuple[str, float | None, dict]:
    answer = (post_warm if "warm" in mods else post_json)(DECISIONS, jev_body(said, commands, mods), key)
    answers = answer["answers"]
    pick = answers["command"]
    name = pick["choice"]
    if name == "none" or pick.get("confidence", 0) < _min_confidence:
        return "none", answer.get("usage", {}).get("cost"), {"confidence": pick.get("confidence"), "picked": name}
    choice = answers.get("choice:" + name, {}).get("choice")
    return label(name, choice), answer.get("usage", {}).get("cost"), {"confidence": pick.get("confidence")}


# A local decider's wait grows with its prompt (Decider: ~1.4 ms a token, nothing cached between
# requests), so its requests can be trimmed, by naming the model with modifiers
# (local:decider+bare+short-choice+preamble-short): each is its own model in a run, interleaved with the rest.
SHORT_HEARD = "Speech-to-text wrote this down, so words may be misheard: go by how they sound."
PREAMBLES = {"full": HEARD + "\n", "short": SHORT_HEARD + "\n", "none": ""}
MODIFIERS = {"bare": "options named by themselves (\"Safari\": \"Safari\") are sent without a meaning",
             "short-choice": "the choice question doesn't repeat the command's summary",
             "preamble-short": "a one-line \"may be misheard\" instead of the app's HEARD",
             "preamble-none": "just what the user said",
             "lean-choice": "the choice question gets just what the user said (the command question keeps the preamble)"}


def local_question(said: str, commands: list[dict], name: str | None = None,
                   bare_choices: bool = False, short_choice: bool = False) -> dict:
    """One of JevDecider's questions, as a local decider gets it: the command, or `name`'s choice.
    bare_choices: an option whose meaning is its own name ("Safari": "Safari") is sent without one;
    short_choice: the choice question doesn't repeat the command's summary."""
    key = "command" if name is None else "choice:" + name
    question = jev_body(said, commands)["questions"][key]
    if bare_choices:
        question = {**question, "criteria": {k: None if v == k else v for k, v in question["criteria"].items()}}
    if short_choice and name is not None:
        question = {**question, "instructions": f"The user wants {name}: which of these?"}
    return {key: question}


def local_model(model: str) -> tuple[str, set[str]] | None:
    """local:<name>[+modifier…] → (name, modifiers); None if it isn't one."""
    if not model.startswith("local:"):
        return None
    name, *mods = model[len("local:"):].split("+")
    return (name, set(mods)) if name in LOCAL and set(mods) <= set(MODIFIERS) else None


def ask_local(name: str, said: str, commands: list[dict], mods: set[str] = frozenset()) -> tuple[str, float | None, dict]:
    server = LOCAL[name]
    shape = {"bare_choices": "bare" in mods, "short_choice": "short-choice" in mods}
    preamble = PREAMBLES["short" if "preamble-short" in mods else "none" if "preamble-none" in mods else "full"]
    tokens = 0

    def answers(questions: dict) -> dict:
        nonlocal tokens
        lean = "lean-choice" in mods and "command" not in questions
        body = {"model": server["model"], "state": ("" if lean else preamble) + "The user said: " + said,
                "questions": questions}
        answer = post_json(server["url"], body, "local")
        tokens += answer.get("usage", {}).get("input_tokens", 0)
        return answer["answers"]

    pick = answers(local_question(said, commands, **shape))["command"]
    # Laya's own confidence is entropy; x_jev_confidence is Jev's formula, which MIN_CONFIDENCE is for.
    picked, confidence = pick["choice"], pick.get("x_jev_confidence", pick.get("confidence", 0))
    if picked == "none" or confidence < _min_confidence:
        return "none", None, {"confidence": confidence, "picked": picked, "tokens": tokens}
    if not any(c["name"] == picked and c["choices"] for c in commands):
        return label(picked, None), None, {"confidence": confidence, "tokens": tokens}
    choice = answers(local_question(said, commands, picked, **shape))["choice:" + picked]["choice"]
    return label(picked, choice), None, {"confidence": confidence, "tokens": tokens}


def chat_prompt(commands: list[dict]) -> str:
    lines = ["You pick the command for what the user said (often transcribed speech, English, Chinese or both).",
             HEARD, "Commands:"]
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
    if (mods := jev_model(model)) is not None:
        got, cost, extra = ask_jev(said, commands, key, mods)
    elif model.startswith("openrouter:"):
        got, cost, extra = ask_chat(model[len("openrouter:"):], said, commands, key)
    elif local := local_model(model):
        got, cost, extra = ask_local(local[0], said, commands, local[1])
    else:
        raise SystemExit(f"unknown model {model!r}: use jev[+{'|'.join(JEV_MODIFIERS)}…], openrouter:<id> "
                         f"or local:<{'|'.join(LOCAL)}>[+{'|'.join(MODIFIERS)}…]")
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

    for model in models:  # the first answer loads the model or opens the connection: not timed
        try:
            ask(model, cases[0]["said"], commands, key)
        except Exception:  # noqa: BLE001 (the timed run reports it)
            pass
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
    tokens = [a["tokens"] for a in answers if a.get("tokens")]
    return {"right": count("right") / n, "wrong_run": count("wrong-run"), "missed": count("missed"),
            "errors": count("error"), "n": n, "seconds": harness.describe([a["seconds"] for a in answers if not a["error"]]),
            "cost_per_1000": 1000 * sum(costs) / len(costs) if costs else None,
            "tokens": round(sum(tokens) / len(tokens)) if tokens else None}


def by_tag(answers: list[dict]) -> dict[str, float]:
    tags = sorted({t for a in answers for t in a["tags"]})
    return {t: sum(a["score"] == "right" for a in answers if t in a["tags"]) / sum(t in a["tags"] for a in answers)
            for t in tags}


def at_cutoff(answers: list[dict], cutoff: float) -> list[dict]:
    """Re-scored as if a pick under `cutoff` confidence had been none (from a run at --min-confidence 0)."""
    def got(a: dict) -> str:
        return "none" if a.get("confidence") is not None and a["confidence"] < cutoff else a["got"]
    return [a if a["error"] else {**a, "got": got(a), "score": score(a, got(a))} for a in answers]


def cutoffs(data: dict, markdown: bool = False) -> str:
    """Right and wrong runs with the app's cut-off, none, and each model's best one."""
    rows = []
    for model, answers in data["results"].items():
        tried = {round(0.05 * i, 2): summary(at_cutoff(answers, 0.05 * i)) for i in range(20)}
        best = max(tried, key=lambda c: (tried[c]["right"], -tried[c]["wrong_run"]))
        app = summary(at_cutoff(answers, MIN_CONFIDENCE))
        rows.append([model, f"{100 * tried[0.0]['right']:.0f}%", f"{100 * app['right']:.0f}%", app["wrong_run"],
                     f"{best:.2f}", f"{100 * tried[best]['right']:.0f}%", tried[best]["wrong_run"]])
    return harness.table(["model", "right, no cut-off", f"right ≥{MIN_CONFIDENCE}", "wrong runs",
                          "best cut-off", "right", "wrong runs"], rows, markdown=markdown)


def report(data: dict, markdown: bool = False, failures: str | None = None) -> str:
    rows = []
    tags = sorted({t for answers in data["results"].values() for a in answers for t in a["tags"]})
    for model, answers in data["results"].items():
        s, t = summary(answers), by_tag(answers)
        rows.append([model, f"{100 * s['right']:.0f}%", s["wrong_run"], s["missed"], s["errors"],
                     harness.seconds(s["seconds"].get("p50")), harness.seconds(s["seconds"].get("p90")),
                     harness.seconds(s["seconds"].get("p95")),
                     f"${s['cost_per_1000']:.3f}" if s["cost_per_1000"] is not None else "–", s["tokens"] or "–"]
                    + [f"{100 * t[tag]:.0f}%" for tag in tags])
    rows.sort(key=lambda r: (-float(r[1][:-1]), r[2]))
    out = [f"{len(data['commands'])} commands, {data['rounds']} round(s)",
           harness.table(["model", "right", "wrong runs", "missed", "errors", "wait p50", "p90", "p95", "per 1000",
                          "tokens"] + tags,
                         rows, markdown=markdown)]
    if data.get("min_confidence", MIN_CONFIDENCE) < MIN_CONFIDENCE:
        out += [f"\nconfidence cut-off (run at {data['min_confidence']}; the app's is {MIN_CONFIDENCE}):",
                cutoffs(data, markdown)]
    if failures:
        out.append(f"\n{failures} — not right:")
        for a in data["results"].get(failures, []):
            if a["score"] != "right":
                out.append(f"  {a['score']:<9} {a['said']!r} → {a['got']}  (want {' | '.join(a['expect'])})"
                           + (f"  {a['error']}" if a["error"] else ""))
    return "\n".join(out)


def resources(model: str, cases: list[dict], commands: list[dict], n: int, idle: float) -> dict:
    """A local:<name> model's server, measured from outside: memory, CPU while idle, and per decision
    (both requests) its CPU and GPU time and the energy they'd take (procstats)."""
    if not local_model(model):
        raise SystemExit(f"resources measures a local model's server: local:<{'|'.join(LOCAL)}>[+modifier…]")
    name = local_model(model)[0]
    port = int(LOCAL[name]["url"].split(":")[2].split("/")[0])
    pid = procstats.pid_on_port(port)
    if pid is None:
        raise SystemExit(f"nothing listening on port {port}: start {LOCAL[name]['about']} first")
    ask(model, cases[0]["said"], commands, "")  # loaded and warm
    cpu = procstats.cpu_seconds(pid)
    time.sleep(idle)
    idle_cpu = (procstats.cpu_seconds(pid) - cpu) / idle
    cpu, gpu, started = procstats.cpu_seconds(pid), procstats.gpu_seconds(pid), time.perf_counter()
    for i in range(n):
        ask(model, cases[i % len(cases)]["said"], commands, "")
    wall = (time.perf_counter() - started) / n
    cpu, gpu = (procstats.cpu_seconds(pid) - cpu) / n, (procstats.gpu_seconds(pid) - gpu) / n
    joules = procstats.energy_joules(cpu, gpu)
    return {"model": model, "about": LOCAL[name]["about"], "pid": pid, "decisions": n, "memory_mb": procstats.memory_mb(pid),
            "idle_cpu_percent": round(100 * idle_cpu, 2), "idle_watts": round(idle_cpu * procstats.CPU_WATTS, 3),
            "per_decision": {"wall_ms": round(1000 * wall, 1), "cpu_ms": round(1000 * cpu, 1), "gpu_ms": round(1000 * gpu, 1),
                             "energy_mj": round(1000 * joules, 1)},
            "watts": {"cpu": procstats.CPU_WATTS, "gpu": procstats.GPU_WATTS}, "battery_wh": procstats.battery_wh()}


def resources_report(data: dict) -> str:
    m, d = data["memory_mb"], data["per_decision"]
    battery = data["battery_wh"]
    per_1000 = d["energy_mj"]  # mJ per decision = J per 1000 decisions
    share = f" = {100 * per_1000 / (battery * 3600):.3f}% of this {battery:.0f} Wh battery" if battery else ""
    return "\n".join([
        f"{data['about']} (pid {data['pid']}), {data['decisions']} decisions",
        f"  memory     footprint {m['footprint']} MB (peak {m['footprint_peak']} MB), resident {m['resident']} MB",
        f"  idle       {data['idle_cpu_percent']}% CPU ≈ {data['idle_watts']} W",
        f"  decision   {d['wall_ms']} ms wall, {d['cpu_ms']} ms CPU, {d['gpu_ms']} ms GPU ≈ {d['energy_mj']} mJ (estimate)",
        f"  per 1000   ≈ {per_1000:.0f} J{share}"])


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
    r.add_argument("--min-confidence", type=float, default=MIN_CONFIDENCE,
                   help=f"jev/local picks under this are none (the app's: {MIN_CONFIDENCE}); 0 keeps them, and the "
                        "report then compares cut-offs")
    p = sub.add_parser("report", help="the latest (or --file) run")
    p.add_argument("--file", type=Path)
    p.add_argument("--markdown", action="store_true")
    p.add_argument("--failures", metavar="MODEL", help="list the cases MODEL didn't get right")
    s = sub.add_parser("resources", help="a local model's memory, idle CPU, and CPU/GPU time and energy per decision")
    s.add_argument("-m", "--model", required=True, help=f"local:<{'|'.join(LOCAL)}> (its server running)")
    s.add_argument("-n", "--decisions", type=int, default=100)
    s.add_argument("--idle", type=float, default=30, help="seconds to watch it idle")
    s.add_argument("--catalog", action="store_true", help="add command_catalog.json's commands to choose from")
    s.add_argument("--tag", help="only cases with this tag")
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
    if args.action == "resources":
        data = resources(args.model, cases, commands_for(args.catalog), args.decisions, args.idle)
        data.update(date=datetime.now().isoformat(timespec="seconds"), environment=harness.environment())
        path = harness.save_result(NAME, "resources-" + args.model[len("local:"):], data)
        print(resources_report(data))
        print(f"\nsaved {path.relative_to(harness.ROOT.parent)}")
        return 0
    global _min_confidence
    _min_confidence = args.min_confidence
    data = run(args.model or DEFAULT_MODELS, cases, commands_for(args.catalog), args.rounds, args.workers)
    data.update(catalog=args.catalog, tag=args.tag, min_confidence=args.min_confidence, date=datetime.now().isoformat(timespec="seconds"),
                environment=harness.environment())
    path = harness.save_result(NAME, ("catalog-" if args.catalog else "") + f"{len(data['models'])}-models", data)
    print(report(data))
    print(f"\nsaved {path.relative_to(harness.ROOT.parent)}")
    return 0
