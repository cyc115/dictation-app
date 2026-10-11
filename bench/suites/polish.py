"""AI polish models: how fast, how good, how cheap — on the same dictations, with the app's prompt.

  bench/suite.py polish run -m openrouter:google/gemini-2.5-flash-lite -m openrouter:openai/gpt-oss-20b@Groq
  bench/suite.py polish run --models-file candidates.txt -r 3 --sort latency
  bench/suite.py polish report [--file results/polish/….json] [--markdown] [--failures MODEL]
  bench/suite.py polish cases [--quick]                    # the test set (--quick: the 20-case subset)
  bench/suite.py polish run -m apple -m openai/gpt-oss-120b@Groq --quick   # a fast comparison
  bench/suite.py polish run -m setup:on-device -m setup:cloud-flash --quick  # the app's setups, as shipped
  bench/suite.py polish run -m setup:cloud-flash --corrections             # on the dictations you corrected

Each case (polish_cases.json) is a raw transcript as the speech models write it, the cleanup the app's
instructions ask for, and checks: words that must survive (names, technical terms, the corrected
value) and words that must go (fillers, the corrected-away value, and signs the model *did* what the
dictation says — answered the question, wrote the email, translated — instead of cleaning it up).

A polish passes when every check holds and its words are within 25% of the expected text (Chinese
characters and English words; punctuation and case ignored). Models get the system prompt the app
gives them (their setup's, read from Setups.swift: On-device's for apple, Cloud Flash's for cloud
models; --prompt-file to try another) at temperature 0, like OpenRouterPolish. setup:<id> runs a
Settings → Model setup (built-in, or yours in ~/Library/Application Support/DictationApp/setups.json)
exactly as the app does: its polish model, prompt and tags.

Models: apple (Apple's on-device model, through the installed app: Mac only, needs ./build.sh), or
openrouter:<id>, optionally @<Provider> to pin one provider (e.g. @Groq, @Cerebras), else
OpenRouter routes (--sort latency|throughput|price to ask it to prefer one). Reasoning is turned off
where the model allows it, else set to its lowest effort. Timing is the wall time of one streamed
request from this machine (plus time to first token): run it on the Mac you dictate on, since your
network is part of the wait. apple runs one polish at a time inside the app, prewarmed 1.5 s ahead as
when you dictate.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import random
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

import harness

NAME = "polish"
HELP = "AI polish models: quality on tricky dictations, wait and cost, with the app's prompt"
CASES = harness.ROOT / "polish_cases.json"
SWIFT = harness.ROOT.parent / "Sources/DictationKit/Setups.swift"
CUSTOM_SETUPS = Path.home() / "Library/Application Support/DictationApp/setups.json"
HISTORY = Path.home() / "Library/Application Support/DictationApp/history.json"  # your Corrections
ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
MAX_ERROR = 0.25  # words off from the expected text, as a share of its words
# Lowest reasoning settings to try, in order, for models that can't turn it off.
REASONING_FALLBACKS = [{"enabled": False}, {"effort": "minimal"}, {"effort": "low"}]

_CJK = harness.CJK


# ---------------------------------------------------------------- the app's prompt and the cases

def swift_string(name: str, swift: Path = SWIFT) -> str:
    """A multi-line string constant in Setups.swift (a prompt, or the built-in setups), as the app sees it."""
    src = swift.read_text()
    body = re.search(rf'static let {name} = """\n(.*?)\n\s*"""', src, re.S).group(1)
    lines = [line.strip() for line in body.splitlines()]
    # Swift multi-line strings: a trailing backslash joins the next line without a newline.
    return "".join(line[:-1] if line.endswith("\\") else line + "\n" for line in lines).strip()


def prompt_text(ref: str) -> str:
    """A prompt version ("v3", PolishPrompt in Setups.swift) or a prompt file, as DictationSetup reads it."""
    if re.fullmatch(r"v\d+", ref):
        return swift_string(ref)
    return Path(ref).expanduser().read_text().strip()


def setups(custom: Path = CUSTOM_SETUPS) -> dict[str, dict]:
    """The app's setups by id: built-in (DictationSetup.builtInJSON), then yours in `custom`, if any."""
    found = {s["id"]: s for s in json.loads(swift_string("builtInJSON"))}
    if custom.exists():
        found.update({s["id"]: s for s in json.loads(custom.read_text()).get("setups", [])})
    return found


def app_prompt(model: str) -> str:
    """The prompt the app gives this polish model: On-device's for apple, Cloud Flash's for cloud models."""
    return prompt_text(setups()["on-device" if model == "apple" else "cloud-flash"]["prompt"])


def resolve(spec: str, prompt: str | None = None, wrap: bool = True) -> tuple[str, str, bool]:
    """(polish model, prompt, wrap) for a spec. "setup:<id>" is that setup exactly as the app runs it;
    other models get `prompt` (else the app's prompt for them) and `wrap`."""
    if spec.startswith("setup:"):
        known = setups()
        if spec[len("setup:"):] not in known:
            raise SystemExit(f"unknown setup {spec!r}: use one of {', '.join('setup:' + k for k in known)}")
        setup = known[spec[len("setup:"):]]
        return setup["polish"], prompt_text(setup["prompt"]), setup.get("wrap", True)
    return spec, prompt or app_prompt(spec), wrap


def load_cases(path: Path = CASES) -> list[dict]:
    """A test set, or the app's history.json: each dictation you corrected (Corrections tab) is a case —
    what polish was given (the speech model's text; the polished text for entries saved before the app
    kept it) and what you wanted, with no word checks."""
    data = json.loads(path.read_text())
    if isinstance(data, dict):
        return data["cases"]
    return [{"id": f"correction-{e['id'][:8].lower()}", "category": "correction", "kind": e.get("setup") or "correction",
             "raw": e.get("raw") or e["text"], "expected": e["correction"], "must": [], "must_not": []}
            for e in data if e.get("correction")]


# ---------------------------------------------------------------- scoring

tokens, error_rate = harness.tokens, harness.error_rate


def contains(text: str, phrase: str) -> bool:
    """Chinese: substring. Latin: whole words, case-insensitive (so "um" doesn't match "umbrella"); a
    Chinese character next to it is a boundary ("的latency哪个" has "latency")."""
    if _CJK.search(phrase) or not re.search(r"\w", phrase):
        return phrase in text
    return re.search(rf"(?<![A-Za-z0-9_']){re.escape(phrase)}(?![A-Za-z0-9_'])", text, re.I) is not None


def check(case: dict, output: str) -> dict:
    out = (output or "").strip()
    missing = [m for m in case["must"] if not any(contains(out, alt) for alt in m.split("|"))]
    kept = [m for m in case["must_not"] if any(contains(out, alt) for alt in m.split("|"))]
    err = error_rate(case["expected"], out)
    return {"missing": missing, "kept": kept, "error": round(err, 3),
            "passed": bool(out) and not missing and not kept and err <= MAX_ERROR}


# ---------------------------------------------------------------- calling a model

def parse_spec(spec: str) -> tuple[str, str | None]:
    """'openrouter:<id>[@Provider]' → (id, provider)."""
    if not spec.startswith("openrouter:"):
        raise SystemExit(f"unknown polish model {spec!r}: use apple or openrouter:<id>[@Provider]")
    model, _, provider = spec[len("openrouter:"):].partition("@")
    return model, provider or None


def user_message(text: str, wrap: bool) -> str:
    """The transcript as sent; `wrap` marks it as data so the model doesn't take it as a request."""
    return f"<transcript>\n{text}\n</transcript>" if wrap else text


def request_body(model: str, text: str, prompt: str, provider: str | None, sort: str | None,
                 reasoning: dict | None, wrap: bool = True) -> dict:
    body = {"model": model, "temperature": 0, "stream": True, "usage": {"include": True},
            "messages": [{"role": "system", "content": prompt},
                         {"role": "user", "content": user_message(text, wrap)}]}
    if provider:
        body["provider"] = {"order": provider.split(","), "allow_fallbacks": False}
    elif sort:
        body["provider"] = {"sort": sort}
    if reasoning is not None:
        body["reasoning"] = reasoning
    return body


def stream(body: dict, key: str, timeout: float) -> dict:
    """One streamed completion: wall time, time to first text, the text, who served it, cost."""
    req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json", "X-Title": "DictationApp bench"})
    started = time.monotonic()
    first, text, usage, provider = None, "", {}, None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:") or line == "data: [DONE]":
                    continue
                chunk = json.loads(line[5:])
                if "error" in chunk:
                    return {"error": str(chunk["error"].get("message", chunk["error"]))[:200]}
                provider = chunk.get("provider") or provider
                for choice in chunk.get("choices") or []:
                    piece = (choice.get("delta") or {}).get("content")
                    if piece:
                        first = first if first is not None else time.monotonic() - started
                        text += piece
                usage = chunk.get("usage") or usage
    except urllib.error.HTTPError as e:
        try:
            message = json.loads(e.read()).get("error", {}).get("message", "")
        except Exception:
            message = ""
        return {"error": f"HTTP {e.code}: {message}"[:200]}
    except Exception as e:  # timeouts, resets
        return {"error": f"{type(e).__name__}: {e}"[:200]}
    details = usage.get("completion_tokens_details") or {}
    return {"seconds": round(time.monotonic() - started, 3), "first": round(first, 3) if first is not None else None,
            "text": text.strip(), "provider": provider, "cost": usage.get("cost"),
            "tokens_out": usage.get("completion_tokens"), "reasoning_tokens": details.get("reasoning_tokens")}


class Caller:
    """Calls one model, remembering the lowest reasoning setting it accepts."""

    def __init__(self, spec: str, key: str, prompt: str, sort: str | None, timeout: float, wrap: bool = True,
                 send=stream):
        self.spec, self.key, self.prompt, self.sort, self.timeout = spec, key, prompt, sort, timeout
        self.wrap, self.send = wrap, send
        self.model, self.provider = parse_spec(spec)
        self.reasoning: dict | None = REASONING_FALLBACKS[0]

    def __call__(self, text: str) -> dict:
        while True:
            body = request_body(self.model, text, self.prompt, self.provider, self.sort, self.reasoning, self.wrap)
            result = self.send(body, self.key, self.timeout)
            error = result.get("error", "")
            if "reasoning" in error.lower() and ("mandatory" in error.lower() or "not supported" in error.lower()
                                                 or "invalid" in error.lower()):
                tried = REASONING_FALLBACKS.index(self.reasoning) if self.reasoning in REASONING_FALLBACKS else -1
                if tried + 1 < len(REASONING_FALLBACKS):
                    self.reasoning = REASONING_FALLBACKS[tried + 1]
                    continue
            result["reasoning"] = self.reasoning
            return result


# ---------------------------------------------------------------- running

def plan(specs: list[str], cases: list[dict], rounds: int, seed: int) -> list[tuple[int, str, dict]]:
    """Per model, its own shuffled order of cases each round (one warm-up first, round 0)."""
    jobs = []
    for spec in specs:
        rng = random.Random(f"{seed}:{spec}")
        jobs.append((0, spec, min(cases, key=lambda c: len(c["raw"]))))
        for rnd in range(1, rounds + 1):
            order = list(cases)
            rng.shuffle(order)
            jobs += [(rnd, spec, c) for c in order]
    return jobs


def run(specs: list[str], cases: list[dict], rounds: int, seed: int, key: str, sort: str | None,
        parallel: int, timeout: float, show, prompt: str | None = None, wrap: bool = True) -> list[dict]:
    """Models run side by side (one request at a time per model, so a model never competes with itself)."""
    configs = {s: resolve(s, prompt, wrap) for s in specs}
    callers = {s: Caller(m, key, p, sort, timeout, w) for s, (m, p, w) in configs.items() if m != "apple"}
    by_model: dict[str, list] = {}
    for job in plan(specs, cases, rounds, seed):
        by_model.setdefault(job[1], []).append(job)
    rows: list[dict] = []

    def work(spec: str) -> list[dict]:
        model, spec_prompt, spec_wrap = configs[spec]
        if model == "apple":
            return run_apple(by_model[spec], spec_prompt, spec_wrap, timeout, show, label=spec)
        out = []
        for rnd, _, case in by_model[spec]:
            result = callers[spec](case["raw"])
            row = {"model": spec, "round": rnd, "warmup": rnd == 0, "case": case["id"],
                   "category": case["category"], "kind": case["kind"], **result}
            if "error" not in result:
                row["check"] = check(case, result["text"])
            out.append(row)
            show(row)
        return out

    # Apple first, on its own: it stops the run straight away if the installed app is too old.
    # Apple runs one model at a time inside the app, so its specs go one after another, before the rest.
    for spec in [s for s in specs if configs[s][0] == "apple"]:
        rows += work(spec)
    cloud = [s for s in specs if configs[s][0] != "apple"]
    with concurrent.futures.ThreadPoolExecutor(max(1, parallel)) as pool:
        for part in pool.map(work, cloud):
            rows += part
    return rows


def run_apple(jobs: list, prompt: str, wrap: bool, timeout: float, show, label: str = "apple") -> list[dict]:
    """Apple's on-device model through the installed app (LatencyProbe's polish-only trials)."""
    from suites import latency
    trials = [{"id": f"{i:04d}", "file": "", "stt": "text", "polish": ["apple"], "text": case["raw"],
               "audio_seconds": 0} for i, (_, _, case) in enumerate(jobs)]
    extra = {} if prompt == app_prompt("apple") else {"instructions": prompt}
    extra["wrap"] = wrap
    rows = {}

    def on_sample(sample: dict, _done: int) -> None:
        if "unknown speech model text" in (sample.get("error") or ""):
            raise SystemExit("the installed app is older than this checkout (it can't run polish-only trials): "
                             "run ./build.sh (after ./test.sh passes), then try again")
        i = int(sample["id"])
        rnd, _, case = jobs[i]
        p = (sample.get("polish") or [{}])[0]
        row = {"model": label, "round": rnd, "warmup": rnd == 0, "case": case["id"], "category": case["category"],
               "kind": case["kind"], "provider": "Apple (on-device)", "cost": 0.0, "first": None}
        if sample.get("error") or p.get("error") or p.get("seconds") is None:
            row["error"] = sample.get("error") or p.get("error") or "no polish"
        else:
            row.update(seconds=round(p["seconds"], 3), text=(p.get("text") or "").strip())
            row["check"] = check(case, row["text"])
        rows[i] = row
        show(row)

    latency.run_in_app(trials, 0.3, timeout, None, on_sample, extra)
    return [rows.get(i) or {"model": label, "round": jobs[i][0], "warmup": jobs[i][0] == 0, "case": jobs[i][2]["id"],
                            "category": jobs[i][2]["category"], "kind": jobs[i][2]["kind"], "error": "no result"}
            for i in range(len(jobs))]


# ---------------------------------------------------------------- summary & report

def summarize(rows: list[dict]) -> dict:
    out = {}
    for spec in dict.fromkeys(r["model"] for r in rows):
        sel = [r for r in rows if r["model"] == spec and not r["warmup"]]
        ok = [r for r in sel if "error" not in r]
        secs = [r["seconds"] for r in ok]
        firsts = [r["first"] for r in ok if r.get("first") is not None]
        costs = [r["cost"] for r in ok if r.get("cost") is not None]
        by_kind = {}
        for kind in ("filler", "correction", "trap", "clean", "term"):
            k = [r for r in ok if r["kind"] == kind]
            by_kind[kind] = round(sum(r["check"]["passed"] for r in k) / len(k), 3) if k else None
        by_cat = {}
        for cat in ("english", "chinese", "mixed"):
            k = [r for r in ok if r["category"] == cat]
            by_cat[cat] = round(sum(r["check"]["passed"] for r in k) / len(k), 3) if k else None
        out[spec] = {
            "n": len(sel), "errors": len(sel) - len(ok),
            "passed": round(sum(r["check"]["passed"] for r in ok) / len(ok), 3) if ok else None,
            "word_error": round(statistics.fmean(r["check"]["error"] for r in ok), 3) if ok else None,
            "by_kind": by_kind, "by_category": by_cat,
            "seconds": harness.describe(secs, errors=len(sel) - len(ok)),
            "first_p50": round(harness.percentile(firsts, 50), 3) if firsts else None,
            "cost_per_1000": round(1000 * statistics.fmean(costs), 4) if costs else None,
            "providers": sorted({r["provider"] for r in ok if r.get("provider")}),
            "reasoning": next((r.get("reasoning") for r in ok), None),
        }
    return out


def _pct(x) -> str:
    return "—" if x is None else f"{100 * x:.0f}%"


def report_text(result: dict, markdown: bool = False) -> str:
    s = result["summary"]
    env = result.get("env", {})
    head = (f"{result['run_at']}  commit {env.get('commit', '?')}  {len(result['config']['cases'])} cases × "
            f"{result['config']['rounds']} rounds, from {result['config'].get('where', 'this machine')}"
            + (f", sort={result['config']['sort']}" if result["config"].get("sort") else "")
            + f", prompt: {result['config'].get('prompt', 'app')}" + (" + <transcript> tags" if result["config"].get("wrap") else ""))
    ranked = sorted(s.items(), key=lambda kv: (-(kv[1]["passed"] or 0), kv[1]["seconds"]["p50"] or 99))
    rows = []
    for spec, v in ranked:
        sec = v["seconds"]
        rows.append([spec.replace("openrouter:", ""), _pct(v["passed"]), _pct(v["by_kind"]["trap"]),
                     _pct(v["by_kind"]["correction"]), _pct(v["by_kind"].get("term")), _pct(v["by_category"]["mixed"]),
                     f"{v['word_error']:.2f}" if v["word_error"] is not None else "—",
                     harness.seconds(sec["p50"]), harness.seconds(sec["p90"]), harness.seconds(sec["max"]),
                     harness.seconds(v["first_p50"]), v["errors"] or "",
                     f"${v['cost_per_1000']:.3f}" if v["cost_per_1000"] is not None else "—",
                     ",".join(v["providers"])[:24]])
    table = harness.table(["model", "pass", "traps", "fixes", "terms", "mixed", "word err", "p50 s", "p90 s", "worst s",
                           "1st tok", "errors", "per 1k", "served by"], rows, markdown)
    notes = ["pass = every check holds and the words are within 25% of the expected text. traps = didn't answer,",
             "write or translate what was dictated. fixes = self-corrections resolved. terms = misheard terms fixed",
             "from context (hard sets). mixed = Chinese with English terms. word err = mean share of words off. per 1k = cost of 1,000 polishes. Seconds: one request,",
             "stop of streaming = what the app waits for; 1st tok = first text."]
    return "\n".join([head, "", table, "", *notes])


def failures_text(result: dict, spec: str) -> str:
    files = result["config"].get("cases_files") or [result["config"].get("cases_file", CASES.name)]
    cases = {c["id"]: c for f in files for c in load_cases(harness.ROOT / f)}
    lines = []
    for r in result["trials"]:
        if r["model"] != spec or r["warmup"]:
            continue
        if "error" in r:
            lines.append(f"✗ {r['case']}: {r['error']}")
        elif not r["check"]["passed"]:
            c = r["check"]
            why = ", ".join(filter(None, [c["missing"] and f"missing {c['missing']}", c["kept"] and f"kept {c['kept']}",
                                          c["error"] > MAX_ERROR and f"{c['error']:.0%} words off"]))
            lines += [f"✗ {r['case']} ({why})", f"    raw:      {cases[r['case']]['raw']}",
                      f"    expected: {cases[r['case']]['expected']}", f"    got:      {r['text']}"]
    return "\n".join(lines) or f"{spec}: no failures"


# ---------------------------------------------------------------- commands

SECRETS = Path.home() / "Library/Application Support/DictationApp/secrets.json"


def saved_key(secrets: Path = SECRETS) -> str:
    """The cloud key saved in the app's Settings (FileSecretStore), if any."""
    try:
        return json.loads(secrets.read_text()).get("openrouter-api-key", "")
    except (OSError, ValueError):
        return ""


def key_problem(key: str) -> str | None:
    """Why OpenRouter won't take this key, checked once before any polish request; None if it's fine
    (or OpenRouter couldn't be reached, which the requests themselves will report)."""
    req = urllib.request.Request("https://openrouter.ai/api/v1/key", headers={"Authorization": f"Bearer {key}"})
    try:
        urllib.request.urlopen(req, timeout=15).close()
        return None
    except urllib.error.HTTPError as e:
        try:
            message = json.loads(e.read()).get("error", {}).get("message", "")
        except Exception:
            message = ""
        return f"HTTP {e.code}{': ' + message if message else ''}" if e.code in (401, 402, 403) else None
    except Exception:
        return None


def read_specs(args) -> list[str]:
    specs = list(args.model or [])
    if args.models_file:
        specs += [line.split("#")[0].strip() for line in Path(args.models_file).read_text().splitlines()]
    specs = [s if s == "apple" or s.startswith(("openrouter:", "setup:")) else f"openrouter:{s}" for s in specs if s]
    if not specs:
        raise SystemExit("name models with -m apple / -m openrouter:<id>[@Provider] / -m setup:<id> or --models-file")
    for s in specs:
        model = resolve(s)[0]
        if model != "apple":
            parse_spec(model)
    return list(dict.fromkeys(specs))


def cmd_run(args) -> int:
    specs = read_specs(args)
    files = [Path(f).expanduser() for f in args.cases_file or []] + ([Path(args.corrections).expanduser()] if args.corrections else [])
    files = files or [CASES]
    cases = [c for f in files for c in load_cases(f)]
    if not cases:
        raise SystemExit("no cases: correct a dictation in the app's Corrections tab first" if args.corrections else "no cases")
    if args.quick:
        cases = [c for c in cases if c.get("quick")]
    if args.case:
        cases = [c for c in cases if c["id"] in args.case]
    cloud = [s for s in specs if resolve(s)[0] != "apple"]
    source = f"${args.key_env}" if os.environ.get(args.key_env) else "the key saved in the app's Settings"
    key = os.environ.get(args.key_env, "") or (saved_key() if cloud else "")
    if cloud and not key:
        sys.exit(f"no cloud key: save one in the app's Settings, or set ${args.key_env}")
    if cloud and (problem := key_problem(key)):
        hint = (f" — `unset {args.key_env}` to use the key saved in the app's Settings instead"
                if source.startswith("$") else " — update it in the app's Settings")
        sys.exit(f"OpenRouter rejected {source} ({problem}){hint}")
    total = len(specs) * (len(cases) * args.rounds + 1)
    print(f"==> {len(specs)} model(s) × {len(cases)} cases × {args.rounds} rounds (+1 warm-up) = {total} requests")
    done = [0]

    def show(row: dict) -> None:
        done[0] += 1
        if row.get("error"):
            status = f"✗ {row['error'][:70]}"
        else:
            status = (f"{row['seconds']:5.2f}s  {'ok ' if row['check']['passed'] else 'BAD'}  "
                      f"{row['text'][:60]!r}")
        print(f"  [{done[0]:>4}/{total}] {row['model'].replace('openrouter:', '')[:40]:<40} {row['case']:<24} {status}",
              flush=True)

    prompt = Path(args.prompt_file).read_text().strip() if args.prompt_file else None
    started = datetime.now()
    rows = run(specs, cases, args.rounds, args.seed, key, args.sort, args.parallel, args.timeout, show,
               prompt, args.wrap)
    result = {"suite": NAME, "run_at": started.isoformat(timespec="seconds"), "env": harness.environment(),
              "config": {"models": specs, "cases": [c["id"] for c in cases], "rounds": args.rounds, "seed": args.seed,
                         "sort": args.sort, "parallel": args.parallel, "where": args.where,
                         "cases_files": [f.name if f.resolve().parent == harness.ROOT.resolve() else str(f.resolve())
                                         for f in files],
                         "prompt": "app" if not args.prompt_file else Path(args.prompt_file).name,
                         "instructions": prompt, "wrap": args.wrap,
                         "setups": {s: setups()[s[len("setup:"):]] for s in specs if s.startswith("setup:")}},
              "summary": summarize(rows), "trials": rows}
    path = harness.save_result(NAME, args.label or f"{len(specs)}-models", result,
                               Path(args.out) if args.out else None)
    print(f"\n    saved {path}\n")
    print(report_text(result))
    return 0


def cmd_report(args) -> int:
    path = Path(args.file) if args.file else next(reversed(harness.result_files(NAME)), None)
    if path is None:
        print("no results yet — run `bench/suite.py polish run`")
        return 1
    result = json.loads(path.read_text())
    if args.failures:
        spec = args.failures if args.failures.startswith("openrouter:") else f"openrouter:{args.failures}"
        print(failures_text(result, spec))
    else:
        print(report_text(result, markdown=args.markdown))
    return 0


def cmd_cases(args) -> int:
    for c in load_cases():
        if c.get("quick") or not args.quick:
            print(f"{c['id']:<24} {c['category']:<8} {c['kind']:<11} {'quick ' if c.get('quick') else '      '}{c['raw'][:64]}")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="suite.py polish", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="polish every case with each model; quality, wait and cost")
    r.add_argument("-m", "--model", action="append", metavar="SPEC",
                   help="apple, openrouter:<id>[@Provider], or setup:<id> (a Settings → Model setup's polish model, "
                        "prompt and tags, exactly as the app runs it; ignores --prompt-file/--no-wrap) (repeatable)")
    r.add_argument("--models-file", help="one model spec per line (# comments)")
    r.add_argument("-r", "--rounds", type=int, default=1, help="times each case is polished per model (default 1)")
    r.add_argument("--case", action="append", metavar="ID", help="only these cases")
    r.add_argument("--quick", action="store_true",
                   help="only the 20 quick cases: the ones models disagreed on, over every language and kind")
    r.add_argument("--cases-file", action="append", help="test set (default polish_cases.json; polish_cases_holdout.json checks a "
                                        "prompt on dictations it wasn't tuned on)")
    r.add_argument("--corrections", nargs="?", const=str(HISTORY), metavar="HISTORY_JSON",
                   help="your Corrections from the app (its history.json) as the test set")
    r.add_argument("--sort", choices=["latency", "throughput", "price"],
                   help="ask OpenRouter to route to the provider best at this (unpinned models)")
    r.add_argument("--parallel", type=int, default=4, help="models run side by side (default 4)")
    r.add_argument("--timeout", type=float, default=30, help="seconds before a request counts as failed")
    r.add_argument("--prompt-file", help="system prompt to try instead of the app's (the setup prompt each model "
                                         "gets in the app: On-device's for apple, Cloud Flash's for cloud models)")
    r.add_argument("--wrap", action=argparse.BooleanOptionalAction, default=True,
                   help="send the transcript inside <transcript> tags, as the app does (default; --no-wrap to compare)")
    r.add_argument("--seed", type=int, default=1)
    r.add_argument("--key-env", default="OPENROUTER_API_KEY",
                   help="env var with your OpenRouter key (default: the key saved in the app's Settings)")
    r.add_argument("--where", default="this machine", help="where the run happened, for the report")
    r.add_argument("--label", help="name for the result file")
    r.add_argument("--out", metavar="DIR", help="save here instead of results/polish/")
    r.set_defaults(func=cmd_run)
    rep = sub.add_parser("report", help="the latest (or a given) result")
    rep.add_argument("--file")
    rep.add_argument("--markdown", action="store_true")
    rep.add_argument("--failures", metavar="MODEL", help="show what one model got wrong")
    rep.set_defaults(func=cmd_report)
    c = sub.add_parser("cases", help="list the test set")
    c.add_argument("--quick", action="store_true", help="only the 20 quick cases")
    c.set_defaults(func=cmd_cases)
    args = p.parse_args(argv)
    return args.func(args)
