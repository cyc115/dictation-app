"""Turnaround latency: how long after you press stop until your text is ready.

  bench/suite.py latency run                         # Cloud Flash (+backup) × {no polish, Apple polish}, 5 rounds
  bench/suite.py latency run --local --big           # … plus On-device and Cloud Big (opt-in)
  bench/suite.py latency run --backup                # Cloud Flash with vs without the backup model
  bench/suite.py latency run -s flash -s big -r 10   # just the cloud models, 10 rounds
  bench/suite.py latency run -P none -P apple -P openrouter:anthropic/claude-haiku-5.5
  bench/suite.py latency run --recorded              # your own dictations (Settings → Keep recordings)
  bench/suite.py latency run --dry-run               # show the plan and how long it'll take
  bench/suite.py latency report [--by-length] [--markdown] [--file results/latency/….json]
  bench/suite.py latency polish-cost                 # does polish time follow words in, or words out?

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

Speech models: local (On-device: Qwen3-ASR on this Mac), flash, flash+backup, big, apple / apple-zh
(Apple Speech, en-US / zh-CN), or any local:<Hugging Face id> / apple:<locale> / openrouter:<model id>. "+backup" has the "Backup model when slow" setting
on (the app's default) for that model's dictations (AdaptiveBackup in Transcription.swift). Polish: none, apple (on-device), or openrouter:<model id> (any chat model).
Cloud models use the key saved in the app's Settings, or --key-env VAR to pass one.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import random
import re
import statistics
import subprocess
from collections import Counter
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

# The app's models by their short names (DictationSetup in Setups.swift; a test keeps them in sync).
STT_ALIASES = {
    "local": ("local:mlx-community/Qwen3-ASR-1.7B-8bit", "On-device"),
    "apple": ("apple:en-US", "Apple Speech"),
    "apple-zh": ("apple:zh-CN", "Apple Speech 中文"),
    "flash": ("openrouter:qwen/qwen3-asr-1.7b", "Cloud Flash"),
    "flash+backup": ("openrouter:qwen/qwen3-asr-1.7b+backup", "Cloud Flash+backup"),
    "big": ("openrouter:meta/muse-voice-transcribe-1.0", "Cloud Big"),
}
POLISH_TITLES = {"none": "no polish", "apple": "Apple on-device"}
# Cloud Flash as the app runs it by default (backup on); --local / --big (or -s) add the others.
# Cloud Big costs ~7× Flash.
DEFAULT_STT = ["flash+backup"]
DEFAULT_POLISH = ["none", "apple"]
BACKUP = "+backup"
LENGTH_BUCKETS = [(0, 5, "< 5 s"), (5, 10, "5–10 s"), (10, float("inf"), "≥ 10 s")]

_STT_SPEC = re.compile(r"^(apple:[A-Za-z]{2,3}(-[A-Za-z0-9]+)*|local:\S+|openrouter:\S+)$")
_POLISH_SPEC = re.compile(r"^(none|apple|openrouter:\S+|setup:\S+)$")


# ---------------------------------------------------------------- models & clips

def resolve_stt(name: str) -> str:
    spec = STT_ALIASES.get(name, (name,))[0]
    if not _STT_SPEC.match(spec):
        raise SystemExit(f"unknown speech model {name!r}: use {', '.join(STT_ALIASES)}, local:<id>, apple:<locale> or openrouter:<id>")
    return spec


def check_polish(spec: str) -> str:
    if not _POLISH_SPEC.match(spec):
        raise SystemExit(f"unknown polish model {spec!r}: use none, apple, openrouter:<id>[@Provider] or setup:<id>")
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
        pool = sorted((c for c in cases if c["category"] == category and c.get("level", 1) <= 2
                       and c.get("source") != "recorded"),  # a fixed set, so runs stay comparable
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
    if args.recorded:
        mine = [c for c in cases if c.get("source") == "recorded"]
        if not mine:
            raise SystemExit("no recordings imported yet — bench/bench.py import-recordings")
        return mine
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


def pids() -> list[int]:
    found = subprocess.run(["pgrep", "-x", "DictationApp"], capture_output=True, text=True).stdout.split()
    return [int(p) for p in found]


def run_in_app(trials: list[dict], pause: float, timeout: float, key_env: str | None, on_sample,
               plan_extra: dict | None = None, alongside: bool = False) -> list[dict]:
    """Launches the installed app in benchmark mode and collects one sample per trial. `plan_extra`
    and a trial's "text" are for polish-only runs (suite polish: prompt overrides, no audio).
    `alongside`: a second copy runs beside the one you're using, which is left alone (it shares the
    Mac, so timings are a little noisier); otherwise yours is quit for the run and reopened after."""
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
        plan.write_text(json.dumps({"pause": pause, "timeout": timeout, **(plan_extra or {}), "trials": [
            {k: t[k] for k in ("id", "file", "stt", "polish", "text") if k in t} for t in trials]}, ensure_ascii=False))
        running = lambda: subprocess.run(["pgrep", "-x", "DictationApp"], capture_output=True).returncode == 0
        was_running = running()
        before = set(pids())
        if not alongside:
            subprocess.run(["pkill", "-x", "DictationApp"], capture_output=True)
            time.sleep(0.5)
        subprocess.run(["open", "-n", "--env", f"DICTATIONAPP_LATENCY_PLAN={plan}",
                        "--env", f"DICTATIONAPP_LATENCY_OUT={out}", *env, str(APP)], check=True)
        if alongside:
            time.sleep(1)
            probe = [p for p in pids() if p not in before]
            running = lambda: bool(set(probe) & set(pids()))
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
            if alongside:
                for pid in probe:
                    subprocess.run(["kill", str(pid)], capture_output=True)
            else:
                subprocess.run(["pkill", "-x", "DictationApp"], capture_output=True)
            if was_running and not alongside:
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
                     "answered_by": s.get("answeredBy"),
                     "polish": {p["model"]: {k: p.get(k) for k in ("seconds", "text", "error", "answeredBy")}
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
    # With "+backup", a smaller model may answer instead (TranscriptionModel.backupOpenRouterID).
    summary["backups"] = {}
    for s, sel in by_stt.items():
        main = s.removesuffix(BACKUP)
        answered = [r for r in sel if not r["warmup"] and _transcribed(r)]
        by_backup = [r for r in answered if r.get("answered_by") and r["answered_by"] != main]
        if by_backup:
            summary["backups"][s] = {"count": len(by_backup), "of": len(answered),
                                     "models": sorted({r["answered_by"] for r in by_backup})}
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
    for stt, f in s.get("backups", s.get("fallbacks", {})).items():  # "fallbacks": results before the rename
        out.append(f"\n{title(stt).split('  ')[0]}: {f['count']} of {f['of']} dictations answered by the backup "
                   f"({', '.join(f['models'])}) because the main model was slow or failed.")
    for spec in result.get("config", {}).get("polish", []):
        if spec.startswith("setup:"):  # its backup, if it answered first
            by = Counter((r["polish"].get(spec) or {}).get("answeredBy") for r in result["trials"] if not r.get("warmup"))
            by.pop(None, None)
            if len(by) > 1:
                out.append(f"\n{spec} polish answered by: " + ", ".join(f"{m} {n}×" for m, n in by.most_common()))
    out += ["", "best/worst = fastest/slowest dictation; cold = the warm-up (first use), not in the percentiles.",
            "* fewer than 20 samples: treat p95 as rough (raise --rounds)."]
    return "\n".join(out)


# ---------------------------------------------------------------- polish cost vs length

_WORD = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]|[A-Za-z0-9]+(?:'[A-Za-z]+)?")
OUTPUT_BOUND = 3  # a word out costing ≥ this many words in: the time is in what the model writes


def words(text: str) -> int:
    """Chinese characters + English words: a rough, model-independent stand-in for tokens."""
    return len(_WORD.findall(text or ""))


def fit(columns: list[list[float]], y: list[float]) -> tuple[list[float], float] | None:
    """Least squares y ≈ b0 + b1·x1 + …; ([b0, b1, …], R²), or None if the columns can't be separated."""
    rows = [[1.0] + [c[i] for c in columns] for i in range(len(y))]
    k = len(rows[0])
    a = [[sum(r[i] * r[j] for r in rows) for j in range(k)] + [sum(r[i] * v for r, v in zip(rows, y))]
         for i in range(k)]
    for col in range(k):  # Gauss-Jordan on the normal equations
        pivot = max(range(col, k), key=lambda r: abs(a[r][col]))
        if abs(a[pivot][col]) < 1e-9:
            return None
        a[col], a[pivot] = a[pivot], a[col]
        for r in range(k):
            if r != col:
                f = a[r][col] / a[col][col]
                a[r] = [x - f * c for x, c in zip(a[r], a[col])]
    beta = [a[i][k] / a[i][i] for i in range(k)]
    mean = statistics.fmean(y)
    total = sum((v - mean) ** 2 for v in y)
    resid = sum((v - sum(b * x for b, x in zip(beta, r))) ** 2 for r, v in zip(rows, y))
    return beta, (1 - resid / total) if total else 1.0


def polish_samples(result: dict, spec: str) -> list[dict]:
    """Timed, non-warm-up polishes: words in (transcript), words out (polished text), seconds."""
    out = []
    for r in result["trials"]:
        p = (r.get("polish") or {}).get(spec) or {}
        if not r["warmup"] and _transcribed(r) and p.get("seconds") is not None:
            out.append({"clip": r["clip"], "stt": r["stt"], "in": words(r["raw"]), "out": words(p.get("text")),
                        "seconds": p["seconds"]})
    return out


def polish_cost_text(result: dict, spec: str, markdown: bool = False) -> str:
    samples = polish_samples(result, spec)
    if len(samples) < 5:
        return f"only {len(samples)} timed {title(spec)} polishes in this run — need at least 5"
    w_in, w_out, secs = ([s[k] for s in samples] for k in ("in", "out", "seconds"))
    together = statistics.correlation(w_in, w_out) if len(set(w_in)) > 1 and len(set(w_out)) > 1 else 1.0
    fits = {"out": fit([w_out], secs), "in": fit([w_in], secs), "both": fit([w_in, w_out], secs)}
    sec = lambda x: f"{x:+.3f} s" if x is not None else ""
    rows = []
    for label, key, cols in (("fixed + words out", "out", ("out",)), ("fixed + words in", "in", ("in",)),
                             ("fixed + words in + words out", "both", ("in", "out"))):
        f = fits[key]
        if f is None:
            rows.append([label, "—", "", "", "can't separate"])
            continue
        beta, r2 = f
        per = dict(zip(cols, beta[1:]))
        rows.append([label, f"{beta[0]:.2f} s", sec(per.get("in")), sec(per.get("out")), f"{r2:.2f}"])
    out = [f"{title(spec)}: what its time depends on — {len(samples)} polishes, warm-ups left out",
           f"words = Chinese characters + English words. In: {min(w_in)}–{max(w_in)} (transcript), "
           f"out: {min(w_out)}–{max(w_out)} (polished). Correlation of in and out: {together:.2f}", ""]
    out.append(harness.table(["time ≈", "fixed", "per word in", "per word out", "R²"], rows, markdown))

    # Same audio, different transcripts: does the polish time follow the words?
    by_clip: dict[tuple, list[dict]] = {}
    for s in samples:
        by_clip.setdefault((s["clip"], s["stt"]), []).append(s)
    clips_seen = {}
    for clip, stt in by_clip:
        clips_seen.setdefault(clip, set()).add(stt)
    shared = sorted(c for c, stts in clips_seen.items() if len(stts) > 1)
    if shared:
        out += ["", "Same clip, different speech models (mean words, p50 seconds):", ""]
        table_rows = []
        for clip in shared:
            for (c, stt), group in sorted(by_clip.items()):
                if c == clip:
                    table_rows.append([f"{clip}  {title(stt).split('  ')[0]}", len(group),
                                       f"{statistics.fmean(g['in'] for g in group):.0f}",
                                       f"{statistics.fmean(g['out'] for g in group):.0f}",
                                       harness.seconds(harness.percentile([g['seconds'] for g in group], 50))])
        out.append(harness.table(["clip  speech model", "n", "words in", "words out", "p50"], table_rows, markdown))

    out += ["", polish_cost_verdict(fits, together, max(w_out))]
    return "\n".join(out)


def polish_cost_verdict(fits: dict, together: float, longest: int) -> str:
    one = fits["out"]
    if one is None or one[1] < 0.5:
        return ("Length explains little of the polish time here (R² < 0.5): something else dominates, so "
                "polishing earlier phrases while you speak would save little.")
    (fixed, per_out), r2 = one
    example = (f"For the longest dictation here ({longest} words out) that's ≈ {fixed + per_out * longest:.1f} s now, "
               f"vs ≈ {fixed + per_out * min(15, longest):.1f} s if only a last 15-word phrase were left to write.")
    both = fits["both"]
    if both is not None and together < 0.95:
        _, per_in, per_word_out = both[0]
        if per_word_out >= OUTPUT_BOUND * max(per_in, 0):
            return ("Polish time follows what the model writes, not what it reads: a word out costs "
                    f"{per_word_out:.3f} s, a word in {per_in:.3f} s. Polishing earlier phrases while you speak "
                    f"should help. {example}")
        return ("Reading the transcript costs about as much as writing it "
                f"({per_in:.3f} s vs {per_word_out:.3f} s a word): polishing earlier phrases while you speak "
                "saves less, since the whole text still has to be read for context.")
    return (f"Polish time grows with length (R² {r2:.2f}, {per_out:.3f} s a word, {fixed:.2f} s fixed), but words in "
            f"and out move together here (correlation {together:.2f}), so this run can't say whether reading or "
            f"writing costs the time. {per_out:.3f} s a word is {1 / per_out:.0f} words/s; LLMs usually read many "
            f"times faster than they write, so a rate this slow points to writing — an inference, not a measurement. "
            f"{example}")


def cmd_polish_cost(args) -> int:
    spec = check_polish(args.polish)
    if args.file:
        path = Path(args.file)
    else:
        with_polish = [f for f in harness.result_files(NAME)
                       if spec in json.loads(f.read_text()).get("config", {}).get("polish", [])]
        path = with_polish[-1] if with_polish else None
    if path is None:
        print(f"no results with {spec} polish yet — run `bench/suite.py latency run`")
        return 1
    print(f"{path}\n")
    print(polish_cost_text(json.loads(path.read_text()), spec, markdown=args.markdown))
    return 0


# ---------------------------------------------------------------- commands

def cmd_run(args) -> int:
    names = ((args.stt or DEFAULT_STT) + (["local"] if args.local else []) + (["big"] if args.big else [])
             + (["flash", "flash+backup"] if args.backup else []))
    stt = list(dict.fromkeys(resolve_stt(m) for m in names))
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
        extra = {"setupsFile": str(Path(args.setups_file).resolve())} if args.setups_file else None
        samples = run_in_app(trials, args.pause, args.timeout, args.key_env, show, extra, alongside=args.alongside)
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


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="suite.py latency", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="time dictations in the installed app and report percentiles")
    r.add_argument("-s", "--stt", action="append", metavar="MODEL",
                   help=f"speech model (repeatable; default: {' '.join(DEFAULT_STT)})")
    r.add_argument("--local", action="store_true", help="also time On-device (Qwen on this Mac; free)")
    r.add_argument("--alongside", action="store_true",
                   help="run a second copy beside the app you're using instead of quitting it (noisier timings)")
    r.add_argument("--big", action="store_true", help="also time Cloud Big (adds ≈ $0.02 per default-size run)")
    r.add_argument("--backup", action="store_true",
                   help="time Cloud Flash with and without the backup model, interleaved")
    r.add_argument("-P", "--polish", action="append", metavar="MODEL",
                   help=f"polish model (repeatable; default: {' '.join(DEFAULT_POLISH)})")
    r.add_argument("-r", "--rounds", type=int, default=5, help="times each clip × speech model is dictated (default 5)")
    r.add_argument("--clip", action="append", metavar="ID", help="use these clips instead of the default 9")
    r.add_argument("--all-clips", action="store_true", help="every clip with audio (slow)")
    r.add_argument("--recorded", action="store_true",
                   help="your own dictations (bench.py import-recordings) instead of the TTS clips")
    r.add_argument("--warmup", type=int, default=1, help="warm-up dictations per speech model (default 1)")
    r.add_argument("--seed", type=int, default=1, help="shuffle seed, for a reproducible order")
    r.add_argument("--setups-file", metavar="JSON",
                   help="setups for -P setup:<id> beyond the built-in ones, instead of the app's setups.json")
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
    pc = sub.add_parser("polish-cost", help="does polish time follow the words read, or the words written?")
    pc.add_argument("--file", help="result JSON (default: the latest with that polish model)")
    pc.add_argument("-P", "--polish", default="apple", metavar="MODEL", help="polish model (default: apple)")
    pc.add_argument("--markdown", action="store_true")
    pc.set_defaults(func=cmd_polish_cost)
    return p


def main(argv: list[str]) -> int:
    p = parser()
    args = p.parse_args(argv)
    if getattr(args, "rounds", 1) < 1:
        p.error("--rounds must be at least 1")
    return args.func(args)
