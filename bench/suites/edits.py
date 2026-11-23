"""The fix judge: does a model tell a misheard word from style and a change of mind, one fix at a time and in batches?

  bench/suite.py edits run --dry-run                              # the plan and its estimated cost; sends nothing
  bench/suite.py edits run -m openrouter:google/gemini-3.8-flash -m openrouter:anthropic/claude-sonnet-5.5
  bench/suite.py edits run -m openrouter:deepseek/deepseek-v4.1-flash -b 10 --price deepseek/deepseek-v4.1-flash=0.2,0.8
  bench/suite.py edits report [--file results/edits/….json] [--markdown] [--failures MODEL@BATCH]
  bench/suite.py edits cases

Each case (edit_cases.json, written for the bench) is a fix: what the app wrote, what the person wanted,
and its word changes exactly as the app works them out (FixIntake; a Swift test keeps them equal), each
labelled misheard, style, changedMind or unclear. The model is asked as the app asks it (FixJudge,
OpenRouterJudge): the instructions in Sources/DictationKit/Vocabulary/JudgeFixes.txt, then the terms
(edit_cases.json's sample vocabulary), then the numbered fixes; temperature 0, reasoning off or lowest.

Every model runs every batch size given (default 1 and 10) on the same cases, in batches drawn from one
seeded shuffle, so sizes differ only in how many fixes share a request. A change scores when its verdict
matches the label; a change the answer didn't cover (malformed, left out) scores as wrong, and coverage
is reported apart. The app keeps batching only if batches of 10 score as well as one at a time.

Cost: each request's cost (OpenRouter's usage) is recorded and the run's total printed. --dry-run estimates
tokens (a Chinese character a token, else 4 characters a token) and prices them from PRICES (from saved
results) or --price; it reads no key and sends nothing.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import random
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

import harness
import openrouter
from harness import estimate_tokens
from openrouter import CHAT, key_problem

NAME = "edits"
HELP = "the fix judge: verdict accuracy per word change, by model and batch size, and cost"
CASES = harness.ROOT / "edit_cases.json"
INSTRUCTIONS = harness.ROOT.parent / "Sources/DictationKit/Vocabulary/JudgeFixes.txt"
DEFAULT_MODEL = "openrouter:anthropic/claude-sonnet-5.5"  # judgeModel's default (LearnController.teacherModel)
VERDICTS = ("misheard", "style", "changedMind", "unclear")
BATCH_SIZES = (1, 10)
# OpenRouter.mustThink: models that can't turn thinking off get the lowest effort from the start.
MUST_THINK = ("openai/gpt-oss", "openai/gpt-5", "openai/gpt-6")
LOWEST = {"effort": "minimal"}
# US $ per million tokens (prompt, completion), only where a saved result in this repo says so; others
# need --price. Claude Sonnet 5.5: bench/results/polish/README.md, teacher bake-off ("124k prompt
# tokens at $2, 8k out at $10").
PRICES = {"anthropic/claude-sonnet-5.5": (2.0, 10.0)}


# ---------------------------------------------------------------- the app's request

def instructions(path: Path = INSTRUCTIONS) -> str:
    """The judge's instructions, the file the app ships (FixJudge.instructions)."""
    return path.read_text().strip()


def load(path: Path = CASES) -> tuple[list[str], list[dict]]:
    """(terms, cases)."""
    data = json.loads(path.read_text())
    return data["terms"], data["cases"]


def message(items: list[dict], terms: list[str]) -> tuple[str, str]:
    """(prefix, rest) of the user message, as FixJudge.message writes it. Each item has wrote, target
    and changes ([old, new] pairs or {"old", "new"} dicts)."""
    prefix = "Vocabulary terms: " + (", ".join(terms) if terms else "(none)") + "\n\n"
    fixes = []
    for n, item in enumerate(items, 1):
        pairs = [(c["old"], c["new"]) if isinstance(c, dict) else tuple(c) for c in item["changes"]]
        lines = [f'<fix n="{n}">', "wrote: " + item["wrote"], "wanted: " + item["target"]]
        lines += [f"change {i}: {old} → {new}" for i, (old, new) in enumerate(pairs, 1)] + ["</fix>"]
        fixes.append("\n".join(lines))
    return prefix, "\n\n".join(fixes)


def user_content(prefix: str, rest: str, model: str):
    """OpenRouter.content(caching:then:model:): Anthropic models get a cache breakpoint after the prefix."""
    if not model.startswith("anthropic/"):
        return prefix + rest
    return [{"type": "text", "text": prefix, "cache_control": {"type": "ephemeral"}}, {"type": "text", "text": rest}]


def request_body(model: str, items: list[dict], terms: list[str], reasoning: dict | None, prompt: str) -> dict:
    """The body OpenRouterJudge.request sends."""
    prefix, rest = message(items, terms)
    body = {"model": model, "temperature": 0,
            "messages": [{"role": "system", "content": prompt}, {"role": "user", "content": user_content(prefix, rest, model)}]}
    if reasoning is not None:
        body["reasoning"] = reasoning
    return body


def verdict(word) -> str | None:
    """FixJudge.verdict: any case, spaces and underscores ignored."""
    if not isinstance(word, str):
        return None
    key = "".join(ch for ch in word.lower() if ch.isalpha())
    return {"misheard": "misheard", "style": "style", "changedmind": "changedMind", "unclear": "unclear"}.get(key)


def parse(answer: str, change_counts: list[int]) -> list[list[str] | None]:
    """FixJudge.parse: per item, its verdicts, or None unless the answer has its number (an integer) with
    exactly one known verdict per change (the first such entry counts)."""
    found: list[list[str] | None] = [None] * len(change_counts)
    start, end = answer.find("{"), answer.rfind("}")
    if not change_counts or start < 0 or end <= start:
        return found
    try:
        data = json.loads(answer[start:end + 1])
    except ValueError:
        return found
    fixes = data.get("fixes") if isinstance(data, dict) else None
    for fix in fixes if isinstance(fixes, list) else []:
        if not isinstance(fix, dict):
            continue
        n, words = fix.get("fix"), fix.get("verdicts")
        if not isinstance(n, int) or isinstance(n, bool) or not 1 <= n <= len(change_counts) or found[n - 1] is not None:
            continue
        if not isinstance(words, list) or len(words) != change_counts[n - 1]:
            continue
        verdicts = [verdict(w) for w in words]
        if all(verdicts):
            found[n - 1] = verdicts
    return found


# ---------------------------------------------------------------- batches and scoring

def batches(cases: list[dict], size: int, seed: int) -> list[list[dict]]:
    """The cases in one seeded shuffle (the same for every model and size), cut into batches of `size`."""
    order = list(cases)
    random.Random(seed).shuffle(order)
    return [order[i:i + size] for i in range(0, len(order), size)]


def score(cases: list[dict], answers: dict[str, list[str] | None]) -> dict:
    """Per change: right when its verdict matches the label; not covered counts as wrong."""
    total = right = covered = 0
    by_label = {v: [0, 0] for v in VERDICTS}  # label: [right, of]
    said_misheard = said_misheard_right = 0
    for case in cases:
        got = answers.get(case["id"])
        for i, change in enumerate(case["changes"]):
            label = change["verdict"]
            total += 1
            by_label[label][1] += 1
            if got is None:
                continue
            covered += 1
            if got[i] == label:
                right += 1
                by_label[label][0] += 1
            if got[i] == "misheard":
                said_misheard += 1
                said_misheard_right += label == "misheard"
    rate = lambda a, b: round(a / b, 3) if b else None
    return {"changes": total, "accuracy": rate(right, total), "coverage": rate(covered, total),
            "recall": {v: rate(*by_label[v]) for v in VERDICTS},
            "misheard_precision": rate(said_misheard_right, said_misheard)}


# ---------------------------------------------------------------- calling a model

def parse_spec(spec: str) -> str:
    """'openrouter:<id>' (or a bare id) → the OpenRouter model id."""
    model = spec[len("openrouter:"):] if spec.startswith("openrouter:") else spec
    if not model or "/" not in model:
        raise SystemExit(f"unknown model {spec!r}: use openrouter:<id>")
    return model


def post(body: dict, key: str, timeout: float) -> dict:
    """One completion: the text, its cost and tokens, and the wall time; or {"error"}."""
    req = urllib.request.Request(CHAT, data=json.dumps(body).encode(), method="POST", headers=openrouter.headers(key))
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {openrouter.error_message(e)}"[:200]}
    except Exception as e:  # timeouts, resets
        return {"error": f"{type(e).__name__}: {e}"[:200]}
    usage = data.get("usage") or {}
    choices = data.get("choices") or [{}]
    return {"seconds": round(time.monotonic() - started, 3), "text": ((choices[0].get("message") or {}).get("content") or ""),
            "cost": usage.get("cost"), "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"), "provider": data.get("provider")}


def reasoning_for(model: str) -> dict:
    """OpenRouter.reasoning(for:): off, or the lowest effort for a model that can't turn it off."""
    return dict(LOWEST) if model.startswith(MUST_THINK) else {"enabled": False}


class Caller:
    """Asks one model as OpenRouterJudge does: reasoning off (or lowest), and once more at the lowest
    effort if the model says reasoning is mandatory, remembered for its later requests."""

    def __init__(self, model: str, key: str, terms: list[str], prompt: str, timeout: float, send=post):
        self.model, self.key, self.terms, self.prompt, self.timeout, self.send = model, key, terms, prompt, timeout, send
        self.reasoning: dict = reasoning_for(model)

    def __call__(self, items: list[dict]) -> dict:
        result = self.send(request_body(self.model, items, self.terms, self.reasoning, self.prompt), self.key, self.timeout)
        if self.reasoning != LOWEST and "reasoning is mandatory" in result.get("error", "").lower():
            self.reasoning = dict(LOWEST)
            result = self.send(request_body(self.model, items, self.terms, self.reasoning, self.prompt), self.key, self.timeout)
        result["reasoning"] = self.reasoning
        return result


def run(specs: list[str], sizes: list[int], cases: list[dict], terms: list[str], key: str, seed: int,
        parallel: int, timeout: float, show, send=post, prompt: str | None = None) -> list[dict]:
    """One row per request. Model × size configurations run side by side; each sends one request at a time."""
    prompt = prompt if prompt is not None else instructions()
    configs = [(spec, size) for spec in specs for size in sizes]

    def work(config: tuple[str, int]) -> list[dict]:
        spec, size = config
        call = Caller(parse_spec(spec), key, terms, prompt, timeout, send)
        rows = []
        for batch in batches(cases, size, seed):
            result = call(batch)
            row = {"model": spec, "batch": size, "cases": [c["id"] for c in batch], **result}
            if "error" not in result:
                got = parse(result["text"], [len(c["changes"]) for c in batch])
                row["verdicts"] = {c["id"]: v for c, v in zip(batch, got)}
            rows.append(row)
            show(row)
        return rows

    rows: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max(1, parallel)) as pool:
        for part in pool.map(work, configs):
            rows += part
    return rows


def summarize(rows: list[dict], cases: list[dict]) -> dict:
    out = {}
    for config in dict.fromkeys((r["model"], r["batch"]) for r in rows):
        sel = [r for r in rows if (r["model"], r["batch"]) == config]
        answers = {cid: v for r in sel for cid, v in (r.get("verdicts") or {}).items()}
        costs = [r["cost"] for r in sel if r.get("cost") is not None]
        secs = [r["seconds"] for r in sel if "error" not in r]
        out[f"{config[0]}@{config[1]}"] = {
            "model": config[0], "batch": config[1], **score(cases, answers),
            "requests": len(sel), "errors": sum("error" in r for r in sel),
            "cost": round(sum(costs), 6), "cost_per_1000_fixes": round(1000 * sum(costs) / len(cases), 4) if costs else None,
            "seconds_p50": round(statistics.median(secs), 3) if secs else None,
            "reasoning": next((r.get("reasoning") for r in sel if "error" not in r), None),
        }
    return out


# ---------------------------------------------------------------- the estimate

def estimate(specs: list[str], sizes: list[int], cases: list[dict], terms: list[str], seed: int,
             prices: dict[str, tuple[float, float]], prompt: str | None = None) -> list[dict]:
    """Per model × size: requests, estimated prompt and completion tokens, and cost (None: price unknown)."""
    prompt = prompt if prompt is not None else instructions()
    out = []
    for spec in specs:
        model = parse_spec(spec)
        for size in sizes:
            prompt_tokens = completion_tokens = 0
            groups = batches(cases, size, seed)
            for batch in groups:
                prefix, rest = message(batch, terms)
                prompt_tokens += estimate_tokens(prompt + prefix + rest) + 10  # + the messages' framing
                answer = {"fixes": [{"fix": n, "verdicts": [c["verdict"] for c in case["changes"]]} for n, case in enumerate(batch, 1)]}
                completion_tokens += estimate_tokens(json.dumps(answer))
            price = prices.get(model)
            cost = None if price is None else (prompt_tokens * price[0] + completion_tokens * price[1]) / 1e6
            out.append({"model": spec, "batch": size, "requests": len(groups), "prompt_tokens": prompt_tokens,
                        "completion_tokens": completion_tokens, "cost": cost})
    return out


def estimate_text(rows: list[dict]) -> str:
    lines = []
    for r in rows:
        cost = "price unknown (pass --price MODEL=IN,OUT, $ per million tokens)" if r["cost"] is None else f"≈ ${r['cost']:.4f}"
        lines.append(f"  {r['model'].replace('openrouter:', '')} @ {r['batch']:<2}  {r['requests']:>3} requests, "
                     f"≈ {r['prompt_tokens']:,} tokens in, {r['completion_tokens']:,} out: {cost}")
    known = [r["cost"] for r in rows if r["cost"] is not None]
    total = f"≈ ${sum(known):.4f}" + (" + the unpriced models" if len(known) < len(rows) else "")
    return "\n".join(lines + [f"  estimated total {total}"])


def read_prices(values: list[str] | None) -> dict[str, tuple[float, float]]:
    """PRICES, with --price over it (the model as openrouter:<id> or <id>)."""
    return harness.read_prices(values, PRICES, parse_spec)


# ---------------------------------------------------------------- report

def _pct(x) -> str:
    return "—" if x is None else f"{100 * x:.0f}%"


COLUMNS = ["model", "batch", "accuracy", "covered", "misheard prec", "misheard", "style", "changed mind", "unclear",
           "requests", "errors", "p50 s", "cost", "per 1k fixes"]


def report_text(result: dict, markdown: bool = False) -> str:
    s = result["summary"]
    env = result.get("env", {})
    head = (f"{result['run_at']}  commit {env.get('commit', '?')}  {len(result['config']['cases'])} fixes, "
            f"{sum(len(c['changes']) for c in result.get('cases', [])) or '?'} changes, batch sizes {result['config']['batches']}")
    ranked = sorted(s.values(), key=lambda v: (-(v["accuracy"] or 0), v["batch"], v["cost"]))
    rows = [[v["model"].replace("openrouter:", ""), v["batch"], _pct(v["accuracy"]), _pct(v["coverage"]),
             _pct(v["misheard_precision"]), *(_pct(v["recall"][k]) for k in VERDICTS), v["requests"], v["errors"] or "",
             harness.seconds(v["seconds_p50"]), f"${v['cost']:.4f}",
             f"${v['cost_per_1000_fixes']:.3f}" if v["cost_per_1000_fixes"] is not None else "—"] for v in ranked]
    total = sum(v["cost"] for v in s.values())
    notes = ["accuracy: changes whose verdict matches the label (not covered = wrong); covered: changes the answer gave a "
             "verdict for; misheard prec: of the changes called misheard, the share that were (a wrong one teaches vocabulary "
             "a bad variant); misheard … unclear: recall per label", f"total cost ${total:.4f}"]
    return "\n".join([head, "", harness.table(COLUMNS, rows, markdown), "", *notes])


def failures_text(result: dict, config: str) -> str:
    cases = {c["id"]: c for c in result.get("cases", [])}
    lines = []
    for r in result["trials"]:
        if f"{r['model']}@{r['batch']}" != config and f"{r['model'].replace('openrouter:', '')}@{r['batch']}" != config:
            continue
        if "error" in r:
            lines.append(f"✗ request {r['cases']}: {r['error']}")
            continue
        for cid, got in r["verdicts"].items():
            want = [c["verdict"] for c in cases[cid]["changes"]]
            if got != want:
                pairs = ", ".join(f"{c['old']} → {c['new']}" for c in cases[cid]["changes"])
                lines.append(f"✗ {cid}: {pairs}  wanted {want}, got {got if got is not None else 'nothing'}")
    return "\n".join(lines) or f"{config}: no failures"


# ---------------------------------------------------------------- commands

def read_specs(args) -> list[str]:
    specs = [s if s.startswith("openrouter:") else f"openrouter:{s}" for s in (args.model or [DEFAULT_MODEL])]
    for s in specs:
        parse_spec(s)
    return list(dict.fromkeys(specs))


def cmd_run(args, send=post) -> int:
    specs = read_specs(args)
    sizes = sorted(set(args.batch or BATCH_SIZES))
    terms, cases = load(Path(args.cases_file) if args.cases_file else CASES)
    if args.case:
        cases = [c for c in cases if c["id"] in args.case]
    if not cases:
        raise SystemExit("no cases")
    plan = estimate(specs, sizes, cases, terms, args.seed, read_prices(args.price))
    print(f"==> {len(specs)} model(s) × batch sizes {sizes} on {len(cases)} fixes = {sum(r['requests'] for r in plan)} requests")
    print(estimate_text(plan))
    if args.dry_run:
        print("    dry run: nothing sent")
        return 0
    key = openrouter.key(args.key_env)
    if problem := key_problem(key):
        sys.exit(f"OpenRouter rejected ${args.key_env} ({problem}) — update it in ~/.secrets (chezmoi)")
    total = sum(r["requests"] for r in plan)
    done = [0]

    def show(row: dict) -> None:
        done[0] += 1
        status = f"✗ {row['error'][:70]}" if "error" in row else \
            f"{row['seconds']:5.2f}s  {sum(v is not None for v in row['verdicts'].values())}/{len(row['cases'])} covered  ${row.get('cost') or 0:.5f}"
        print(f"  [{done[0]:>3}/{total}] {row['model'].replace('openrouter:', '')[:40]:<40} @{row['batch']:<2} {status}", flush=True)

    started = datetime.now()
    rows = run(specs, sizes, cases, terms, key, args.seed, args.parallel, args.timeout, show, send)
    result = {"suite": NAME, "run_at": started.isoformat(timespec="seconds"), "env": harness.environment(),
              "config": {"models": specs, "batches": sizes, "cases": [c["id"] for c in cases], "seed": args.seed,
                         "terms": terms, "instructions": instructions()},
              "cases": cases, "summary": summarize(rows, cases), "trials": rows}
    path = harness.save_result(NAME, args.label or f"{len(specs)}-models", result, Path(args.out) if args.out else None)
    print(f"\n    saved {path}\n")
    print(report_text(result))
    return 0


def cmd_report(args) -> int:
    path = Path(args.file) if args.file else next(reversed(harness.result_files(NAME)), None)
    if path is None:
        print("no results yet — run `bench/suite.py edits run`")
        return 1
    result = json.loads(path.read_text())
    print(failures_text(result, args.failures) if args.failures else report_text(result, markdown=args.markdown))
    return 0


def cmd_cases(args) -> int:
    terms, cases = load()
    print(f"terms: {', '.join(terms)}")
    for c in cases:
        verdicts = ",".join(ch["verdict"] for ch in c["changes"])
        print(f"{c['id']:<28} {c['category']:<8} {verdicts:<34} {c['wrote'][:50]}")
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="suite.py edits", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="judge every fix with each model and batch size; accuracy and cost")
    r.add_argument("-m", "--model", action="append", metavar="SPEC",
                   help=f"openrouter:<id> (repeatable; default {DEFAULT_MODEL}, the app's)")
    r.add_argument("-b", "--batch", action="append", type=int, metavar="N",
                   help="fixes per request (repeatable; default 1 and 10: the app sends 10)")
    r.add_argument("--dry-run", action="store_true", help="print the plan and its estimated cost; send nothing")
    r.add_argument("--price", action="append", metavar="MODEL=IN,OUT",
                   help="$ per million prompt and completion tokens, for the estimate (repeatable)")
    r.add_argument("--case", action="append", metavar="ID", help="only these cases")
    r.add_argument("--cases-file", help="test set (default edit_cases.json)")
    r.add_argument("--parallel", type=int, default=4, help="model × batch size runs side by side (default 4)")
    r.add_argument("--timeout", type=float, default=60, help="seconds before a request counts as failed")
    r.add_argument("--seed", type=int, default=1, help="the shuffle the batches are cut from")
    r.add_argument("--key-env", default=openrouter.BENCH_ENV, help="env var with the OpenRouter key (default: %(default)s, from ~/.secrets)")
    r.add_argument("--label", help="name for the result file")
    r.add_argument("--out", metavar="DIR", help="save here instead of results/edits/")
    r.set_defaults(func=cmd_run)
    rep = sub.add_parser("report", help="the latest (or a given) result")
    rep.add_argument("--file")
    rep.add_argument("--markdown", action="store_true")
    rep.add_argument("--failures", metavar="MODEL@BATCH", help="the fixes one model and batch size got wrong")
    rep.set_defaults(func=cmd_report)
    c = sub.add_parser("cases", help="list the test set")
    c.set_defaults(func=cmd_cases)
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    return args.func(args)
