"""Turnaround latency: how long after you press stop until your text is ready.

  bench/suite.py latency run                         # app models × {no polish, Apple polish}, 5 rounds
  bench/suite.py latency run -s flash -s big -r 10   # just the cloud models, 10 rounds
  bench/suite.py latency run -P none -P apple -P openrouter:anthropic/claude-haiku-5.5
  bench/suite.py latency run --dry-run               # show the plan and how long it'll take
  bench/suite.py latency report [--by-length] [--markdown] [--file results/latency/….json]

Runs inside the installed app (LatencyProbe.swift, needs ./build.sh) through its real code paths:
  transcription  stop pressed → raw transcript. Cloud: CloudEngine.stop() closes the WAV and uploads
                 it. On-device: the clip plays in real time, like the mic, then SpeechEngine.stop()
                 waits for the final result.
  AI polish      raw transcript → polished text (PolishService). Each polish model runs on the same
                 transcript, one after another, in a shuffled order.
  turnaround     transcription + polish of the same dictation: what you wait for before the paste
                 (the paste itself, ~10 ms, isn't included). Percentiles are of these per-dictation
                 sums; adding up the separate p95s would overstate the tail.

Each round plays every clip × speech model once, in a fresh shuffled order, so a slow minute on the
network hits every model alike. The first dictation per model is a warm-up (connection setup, model
load): it's reported as "cold" and kept out of the percentiles. On-device models are one language
each, so they're timed on clips in their language (repeated to the same count).

Speech models: local (apple:en-US), local-zh (apple:zh-CN), flash, big, or any apple:<locale> /
openrouter:<model id>. Polish: none, apple (on-device), or openrouter:<model id> (any chat model;
the app itself only offers on-device polish today). Cloud models use the key saved in the app's
Settings, or --key-env VAR to pass one.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import random
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

import harness

NAME = "latency"
HELP = "turnaround after you press stop: transcription, AI polish, both (p50/p90/p95)"
APP = Path("/Applications/DictationApp.app")
# A current build creates its output file as soon as it launches; an older one never does.
STARTUP_SECONDS = 15

# The app's models by their short names (TranscriptionModel in Transcription.swift; a test keeps them in sync).
STT_ALIASES = {
    "local": ("apple:en-US", "On-device"),
    "local-zh": ("apple:zh-CN", "On-device 中文"),
    "flash": ("openrouter:qwen/qwen3-asr-1.7b", "Cloud Flash"),
    "big": ("openrouter:meta/muse-voice-transcribe-1.0", "Cloud Big"),
}
POLISH_TITLES = {"none": "no polish", "apple": "Apple on-device"}
DEFAULT_STT = ["local", "flash", "big"]
DEFAULT_POLISH = ["none", "apple"]
LENGTH_BUCKETS = [(0, 5, "< 5 s"), (5, 10, "5–10 s"), (10, float("inf"), "≥ 10 s")]

_STT_SPEC = re.compile(r"^(apple:[A-Za-z]{2,3}(-[A-Za-z0-9]+)*|openrouter:\S+)$")
_POLISH_SPEC = re.compile(r"^(none|apple|openrouter:\S+)$")


# ---------------------------------------------------------------- models & clips

def resolve_stt(name: str) -> str:
    spec = STT_ALIASES.get(name, (name,))[0]
    if not _STT_SPEC.match(spec):
        raise SystemExit(f"unknown speech model {name!r}: use {', '.join(STT_ALIASES)}, apple:<locale> or openrouter:<id>")
    return spec


def check_polish(spec: str) -> str:
    if not _POLISH_SPEC.match(spec):
        raise SystemExit(f"unknown polish model {spec!r}: use none, apple or openrouter:<id>")
    return spec


def title(spec: str) -> str:
    """'Cloud Flash  qwen/qwen3-asr-1.7b' for the app's models, the spec itself otherwise."""
    for full, name in STT_ALIASES.values():
        if spec == full:
            return f"{name}  {spec.split(':', 1)[1]}"
    return POLISH_TITLES.get(spec, spec)


def clip_seconds(case: dict) -> float:
    return harness.wav_seconds(harness.AUDIO / f"{case['id']}.wav")


def default_clips(cases: list[dict]) -> list[dict]:
    """Per category, the shortest, the median and the longest clean clip (levels 1–2): a quick
    command up to a long dictation. Latency grows with length for cloud models (bigger upload)."""
    picked: list[dict] = []
    for category in ("mixed", "chinese", "english"):
        pool = sorted((c for c in cases if c["category"] == category and c.get("level", 1) <= 2),
                      key=lambda c: (clip_seconds(c), c["id"]))
        for c in (pool[0], pool[len(pool) // 2], pool[-1]) if pool else ():
            if c not in picked:
                picked.append(c)
    return picked


def select_clips(args) -> list[dict]:
    cases = [c for c in harness.load_cases() if (harness.AUDIO / f"{c['id']}.wav").exists()]
    if args.clip:
        by_id = {c["id"]: c for c in cases}
        missing = [i for i in args.clip if i not in by_id]
        if missing:
            raise SystemExit(f"no audio for {', '.join(missing)} (bench/bench.py list)")
        return [by_id[i] for i in args.clip]
    if args.all_clips:
        return cases
    return default_clips(cases)


# ---------------------------------------------------------------- plan

def clips_for(stt: str, clips: list[dict]) -> list[dict]:
    """Apple's models are one language each, so they get the clips in their language, repeated to
    the same count as everyone else's (equal sample sizes). Cloud models get every clip."""
    language = {"en": ("english",), "zh": ("chinese", "mixed")}.get(stt[len("apple:"):][:2]) if stt.startswith("apple:") else None
    pool = [c for c in clips if c["category"] in language] if language else clips
    pool = pool or clips  # nothing in its language was picked: time it on what there is
    return [pool[i % len(pool)] for i in range(len(clips))]


def plan_trials(stt: list[str], polish: list[str], clips: list[dict], rounds: int, warmup: int,
                seed: int) -> list[dict]:
    """Warm-ups first (shortest clip, per speech model), then `rounds` interleaved rounds."""
    app_polish = [p for p in polish if p != "none"]
    jobs = [(0, (min(clips_for(s, clips), key=clip_seconds), s), True) for s in stt for _ in range(warmup)]
    pairs = [(c, s) for s in stt for c in clips_for(s, clips)]
    jobs += [(rnd, job, False) for rnd, job in harness.interleave(pairs, rounds, seed)]
    trials = []
    for i, (rnd, (clip, s), warm) in enumerate(jobs):
        order = list(app_polish)
        random.Random(f"{seed}:polish:{i}").shuffle(order)
        trials.append({"id": f"{i:04d}", "round": rnd, "warmup": warm, "clip": clip["id"],
                       "file": str(harness.AUDIO / f"{clip['id']}.wav"),
                       "audio_seconds": round(clip_seconds(clip), 2), "stt": s, "polish": order})
    return trials


def estimate_seconds(trials: list[dict], pause: float) -> float:
    """Rough wall time: on-device plays each clip in real time; cloud is one round trip."""
    total = 0.0
    for t in trials:
        total += (t["audio_seconds"] + 0.5) if t["stt"].startswith("apple:") else 1.5
        total += 1.0 * len(t["polish"]) + pause
    return total + 5


# ---------------------------------------------------------------- runners

def progress(trials: list[dict]):
    by_id = {t["id"]: t for t in trials}

    def show(sample: dict, done: int) -> None:
        t = by_id.get(sample.get("id"), {})
        stage = "warm-up" if t.get("warmup") else f"r{t.get('round')}"
        head = f"  [{done:>4}/{len(trials)}] {stage:<7} {t.get('clip', '?'):<16} {title(t.get('stt', '?'))[:28]:<28}"
        if sample.get("error"):
            print(f"{head}  ✗ {sample['error'][:80]}", flush=True)
            return
        polish = "  ".join(f"{p['model'].split('/')[-1][:14]} "
                           + (harness.seconds(p.get('seconds')) + "s" if p.get("seconds") is not None else "✗")
                           for p in sample.get("polish", []))
        print(f"{head}  {harness.seconds(sample.get('transcribe'))}s  {polish}", flush=True)

    return show


def run_in_app(trials: list[dict], pause: float, timeout: float, key_env: str | None, on_sample) -> list[dict]:
    """Launches the installed app in benchmark mode and collects one sample per trial."""
    if platform.system() != "Darwin":
        raise SystemExit("the latency suite runs the installed macOS app — run it on your Mac (or try --simulate)")
    if not APP.exists():
        raise SystemExit(f"{APP} not found — run ./build.sh first")
    env = []
    if key_env:
        key = os.environ.get(key_env) or sys.exit(f"${key_env} is not set")
        env += ["--env", f"DICTATIONAPP_PROBE_KEY={key}"]
    with tempfile.TemporaryDirectory() as tmp:
        plan, out = Path(tmp) / "plan.json", Path(tmp) / "out.jsonl"
        plan.write_text(json.dumps({"pause": pause, "timeout": timeout, "trials": [
            {k: t[k] for k in ("id", "file", "stt", "polish")} for t in trials]}, ensure_ascii=False))
        running = lambda: subprocess.run(["pgrep", "-x", "DictationApp"], capture_output=True).returncode == 0
        was_running = running()
        subprocess.run(["pkill", "-x", "DictationApp"], capture_output=True)
        time.sleep(0.5)
        subprocess.run(["open", "-n", "--env", f"DICTATIONAPP_LATENCY_PLAN={plan}",
                        "--env", f"DICTATIONAPP_LATENCY_OUT={out}", *env, str(APP)], check=True)
        lines: list[str] = []
        stall = timeout + max(t["audio_seconds"] for t in trials) + 30
        last_change = time.monotonic()
        try:
            while len(lines) < len(trials):
                time.sleep(0.25)
                if not out.exists() and time.monotonic() - last_change > STARTUP_SECONDS:
                    raise SystemExit(f"{APP.name} didn't start the benchmark: the installed build is older than this "
                                     "checkout. Run ./build.sh (after ./test.sh passes), then try again.")
                fresh = out.read_text().splitlines() if out.exists() else []
                for i, line in enumerate(fresh[len(lines):], len(lines) + 1):
                    sample = json.loads(line)
                    if sample.get("id") == "plan":
                        raise SystemExit(f"the app couldn't run the benchmark: {sample.get('error')}")
                    on_sample(sample, i)
                if len(fresh) > len(lines):
                    lines, last_change = fresh, time.monotonic()
                elif time.monotonic() - last_change > stall or (time.monotonic() - last_change > 3 and not running()):
                    print(f"  ! the app stopped answering after {len(lines)} of {len(trials)} trials", flush=True)
                    break
        finally:
            subprocess.run(["pkill", "-x", "DictationApp"], capture_output=True)
            if was_running:
                time.sleep(0.5)
                subprocess.run(["open", str(APP)])
    return [json.loads(line) for line in lines]


def simulate(trials: list[dict], seed: int, on_sample) -> list[dict]:
    """Made-up but plausible timings, for trying the suite and its report without a Mac or API key."""
    rng = random.Random(seed)
    jitter = lambda: rng.lognormvariate(0, 0.25) + (rng.uniform(0.5, 2.0) if rng.random() < 0.04 else 0)
    samples = []
    for i, t in enumerate(trials, 1):
        cold = 2.0 if t["warmup"] else 1.0
        if t["stt"].startswith("apple:"):
            transcribe = (0.25 + 0.01 * t["audio_seconds"]) * jitter()
        else:
            transcribe = (0.35 + (0.9 if "muse" in t["stt"] else 0.0) + 0.03 * t["audio_seconds"]) * jitter() * cold
        polish = [{"model": p, "seconds": round((0.9 if p == "apple" else 0.6) * jitter() * cold, 4), "text": "…"}
                  for p in t["polish"]]
        sample = {"id": t["id"], "transcribe": round(transcribe, 4), "raw": "…", "polish": polish}
        samples.append(sample)
        on_sample(sample, i)
    return samples


# ---------------------------------------------------------------- results

def merge(trials: list[dict], samples: list[dict]) -> list[dict]:
    """One row per trial; trials the app never answered count as errors."""
    by_id = {s["id"]: s for s in samples}
    rows = []
    for t in trials:
        s = by_id.get(t["id"], {"error": "no result"})
        rows.append({**{k: t[k] for k in ("id", "round", "warmup", "clip", "audio_seconds", "stt")},
                     "transcribe": s.get("transcribe"), "raw": s.get("raw", ""), "error": s.get("error"),
                     "polish": {p["model"]: {k: p.get(k) for k in ("seconds", "text", "error")}
                                for p in s.get("polish", [])}})
    return rows


def _transcribed(r: dict) -> bool:
    return r["error"] is None and r["transcribe"] is not None


def _polish_seconds(r: dict, spec: str) -> float | None:
    """0 for "none"; None if that polish failed."""
    return 0.0 if spec == "none" else (r["polish"].get(spec) or {}).get("seconds")


def _group(rows: list[dict], value) -> dict:
    """Stats over non-warm-up rows (`value` → seconds, or None for an error), plus the cold value."""
    measured = [value(r) for r in rows if not r["warmup"]]
    stats = harness.describe([v for v in measured if v is not None], errors=sum(v is None for v in measured))
    cold = [value(r) for r in rows if r["warmup"]]
    stats["cold"] = round(cold[0], 3) if cold and cold[0] is not None else None
    return stats


def summarize(rows: list[dict], stt: list[str], polish: list[str]) -> dict:
    by_stt = {s: [r for r in rows if r["stt"] == s] for s in stt}
    transcribed = [r for r in rows if _transcribed(r)]  # polish only counts dictations that produced text
    summary = {
        "transcription": {s: _group(sel, lambda r: r["transcribe"] if _transcribed(r) else None)
                          for s, sel in by_stt.items()},
        "polish": {p: _group(transcribed, lambda r, p=p: _polish_seconds(r, p)) for p in polish if p != "none"},
        "turnaround": {},
        "transcription_by_length": {},
    }
    for s, sel in by_stt.items():
        for p in polish:
            def total(r, p=p):
                extra = _polish_seconds(r, p)
                return r["transcribe"] + extra if _transcribed(r) and extra is not None else None
            summary["turnaround"][f"{s} + {p}"] = _group(sel, total)
        summary["transcription_by_length"][s] = {
            label: _group([r for r in sel if lo <= r["audio_seconds"] < hi],
                          lambda r: r["transcribe"] if _transcribed(r) else None)
            for lo, hi, label in LENGTH_BUCKETS}
    return summary


# ---------------------------------------------------------------- report

COLUMNS = ["n", "errors", "best", "p50", "p90", "p95", "worst", "cold"]


def _row(label: str, s: dict) -> list:
    p95 = harness.seconds(s["p95"]) + ("*" if 0 < s["n"] < 20 else "")
    return [label, s["n"], s["errors"] or "", harness.seconds(s["min"]), harness.seconds(s["p50"]),
            harness.seconds(s["p90"]), p95, harness.seconds(s["max"]), harness.seconds(s["cold"])]


def _sorted(group: dict) -> list:
    return sorted(group.items(), key=lambda kv: (kv[1]["p50"] is None, kv[1]["p50"] or 0))


def report_text(result: dict, by_length: bool = False, markdown: bool = False) -> str:
    s, cfg = result["summary"], result["config"]
    heading = (lambda t: f"### {t}") if markdown else (lambda t: f"{t}\n")
    out = []
    if result.get("simulated"):
        out.append("SIMULATED — made-up timings from --simulate, not measurements.\n")
    env = result.get("env", {})
    out.append(f"{result['run_at']}  commit {env.get('commit', '?')}{' (dirty)' if env.get('dirty') else ''}  "
               f"{env.get('machine', env.get('os', ''))} {env.get('macos', '')}  "
               f"{len(cfg['clips'])} clips × {cfg['rounds']} rounds, seconds")
    out.append("")
    out.append(heading("Transcription — stop pressed → raw text"))
    out.append(harness.table(["speech model"] + COLUMNS, [_row(title(k), v) for k, v in _sorted(s["transcription"])],
                             markdown))
    if s["polish"]:
        out += ["", heading("AI polish — raw text → polished text")]
        out.append(harness.table(["polish model"] + COLUMNS, [_row(title(k), v) for k, v in _sorted(s["polish"])],
                                 markdown))
    out += ["", heading("Turnaround — stop pressed → text ready to paste (transcription + polish)")]
    rows = []
    for key, v in _sorted(s["turnaround"]):
        stt, _, polish = key.partition(" + ")
        rows.append(_row(f"{title(stt).split('  ')[0]} + {title(polish)}", v))
    out.append(harness.table(["speech model + polish"] + COLUMNS, rows, markdown))
    if by_length:
        out += ["", heading("Transcription by clip length (p50 / p95)")]
        labels = [label for _, _, label in LENGTH_BUCKETS]
        cell = lambda b: "—" if not b["n"] else f"{harness.seconds(b['p50'])} / {harness.seconds(b['p95'])} (n={b['n']})"
        out.append(harness.table(["speech model"] + labels,
                                 [[title(k)] + [cell(v[label]) for label in labels]
                                  for k, v in s["transcription_by_length"].items()], markdown))
    out += ["", "best/worst = fastest/slowest dictation; cold = the warm-up (first use), not in the percentiles.",
            "* fewer than 20 samples: treat p95 as rough (raise --rounds)."]
    return "\n".join(out)


# ---------------------------------------------------------------- commands

def cmd_run(args) -> int:
    stt = list(dict.fromkeys(resolve_stt(m) for m in (args.stt or DEFAULT_STT)))
    polish = list(dict.fromkeys(check_polish(p) for p in (args.polish or DEFAULT_POLISH)))
    clips = select_clips(args)
    trials = plan_trials(stt, polish, clips, args.rounds, args.warmup, args.seed)
    minutes = estimate_seconds(trials, args.pause) / 60
    print(f"==> {len(stt)} speech model(s) × {len(clips)} clips × {args.rounds} rounds (+{args.warmup} warm-up each)"
          f" = {len(trials)} dictations, each polished by {len([p for p in polish if p != 'none'])} model(s);"
          f" ≈ {minutes:.0f} min")
    if args.dry_run:
        for c in clips:
            print(f"    {c['id']:<16} {clip_seconds(c):5.1f}s  {c['category']}")
        return 0
    show = progress(trials)
    started = datetime.now()
    if args.simulate:
        samples = simulate(trials, args.seed, show)
    else:
        samples = run_in_app(trials, args.pause, args.timeout, args.key_env, show)
    if not samples:
        print("\nno dictations finished — nothing saved")
        return 1
    rows = merge(trials, samples)
    result = {
        "suite": NAME, "run_at": started.isoformat(timespec="seconds"), "simulated": args.simulate,
        "env": harness.environment(),
        "config": {"stt": stt, "polish": polish, "clips": [c["id"] for c in clips], "rounds": args.rounds,
                   "warmup": args.warmup, "seed": args.seed, "pause": args.pause, "timeout": args.timeout},
        "summary": summarize(rows, stt, polish), "trials": rows,
    }
    if args.out or not args.simulate:
        label = "simulated" if args.simulate else "_".join(m.split(":")[-1].split("/")[-1] for m in stt)
        path = harness.save_result(NAME, label, result, Path(args.out) if args.out else None)
        print(f"\n    saved {path}")
    print()
    print(report_text(result, by_length=args.by_length))
    return 0


def cmd_report(args) -> int:
    path = Path(args.file) if args.file else next(reversed(harness.result_files(NAME)), None)
    if path is None:
        print("no results yet — run `bench/suite.py latency run`")
        return 1
    print(report_text(json.loads(path.read_text()), by_length=args.by_length, markdown=args.markdown))
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="suite.py latency", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="time dictations in the installed app and report percentiles")
    r.add_argument("-s", "--stt", action="append", metavar="MODEL",
                   help=f"speech model (repeatable; default: {' '.join(DEFAULT_STT)})")
    r.add_argument("-P", "--polish", action="append", metavar="MODEL",
                   help=f"polish model (repeatable; default: {' '.join(DEFAULT_POLISH)})")
    r.add_argument("-r", "--rounds", type=int, default=5, help="times each clip × speech model is dictated (default 5)")
    r.add_argument("--clip", action="append", metavar="ID", help="use these clips instead of the default 9")
    r.add_argument("--all-clips", action="store_true", help="every clip with audio (slow)")
    r.add_argument("--warmup", type=int, default=1, help="warm-up dictations per speech model (default 1)")
    r.add_argument("--seed", type=int, default=1, help="shuffle seed, for a reproducible order")
    r.add_argument("--pause", type=float, default=0.3, help="seconds between dictations")
    r.add_argument("--timeout", type=float, default=90, help="seconds before a dictation counts as failed")
    r.add_argument("--key-env", metavar="VAR", help="env var with the cloud API key (default: the app's saved key)")
    r.add_argument("--by-length", action="store_true", help="also break transcription down by clip length")
    r.add_argument("--dry-run", action="store_true", help="show the plan and estimated time, run nothing")
    r.add_argument("--simulate", action="store_true", help="fake timings (try the suite without a Mac); not saved")
    r.add_argument("--out", metavar="DIR", help="save the result here instead of results/latency/")
    r.set_defaults(func=cmd_run)
    rep = sub.add_parser("report", help="show the latest (or a given) result")
    rep.add_argument("--file", help="result JSON (default: the latest in results/latency/)")
    rep.add_argument("--by-length", action="store_true")
    rep.add_argument("--markdown", action="store_true", help="Markdown tables, for pasting into notes or PRs")
    rep.set_defaults(func=cmd_report)
    args = p.parse_args(argv)
    if getattr(args, "rounds", 1) < 1:
        p.error("--rounds must be at least 1")
    return args.func(args)
