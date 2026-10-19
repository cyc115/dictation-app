#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["opencc-python-reimplemented==0.1.7"]
# ///
"""Speech-to-text benchmark for DictationApp: Chinese with English mixed in, Chinese only, English.

Compare any OpenRouter transcription model against Apple's on-device models on the same audio.

  bench/bench.py synth                      # (re)generate TTS audio for the cases
  bench/bench.py run -m openrouter:meta/muse-voice-transcribe-1.0
  bench/bench.py run -m apple:en-US -m apple:zh-CN   # needs ./build.sh (uses the installed app)
  bench/bench.py run -m openrouter:deepgram/nova-3?language=zh   # extra form fields after "?"
  bench/bench.py run -r 3 -m … -m …         # 3 repeats per clip → min/median/max wait
  bench/bench.py report                     # latest result per model, side by side
  bench/bench.py export > results.json      # everything the comparison page needs
  bench/bench.py add my-clip.m4a --id mixed-real-01 --category mixed --text "帮我 build 一下"
  bench/bench.py import-recordings          # your dictations, kept by Settings → Keep recordings
  bench/bench.py verify rec-… --text "what I actually said"   # then they count for accuracy
  bench/bench.py list

Models: "openrouter:<model-id>", "apple:<locale>", or a local one on this Mac's GPU (MLX):
"parakeet:<hf-id>" (parakeet-mlx, e.g. parakeet:mlx-community/parakeet-tdt-0.6b-v2) or "mlx:<hf-id>"
(any mlx-audio model, e.g. mlx:mlx-community/Qwen3-ASR-1.7B-8bit). Results: bench/results/*.json.
Score: token error rate, where each Chinese character and each English word is one token
(= CER for Chinese, WER for English). "EN recall" = share of the English words in a
mixed sentence that came out right. Before scoring, speaker tags like <|speaker:0|> are
removed and Traditional characters are converted to Simplified (models that answer in
Traditional are flagged separately). Levels: 1 easy, 2 hard (jargon, idioms), 3 hard +
fast + noisy — see "levels" in cases.json.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import math
import random
import struct
import wave
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

import harness
from harness import AUDIO, CASES, ROOT, error_rate, tokens, wav_seconds  # noqa: F401 (tests use bench.*)

# Your own recordings (import-recordings): git-ignored, like audio/rec-*.wav — your voice stays local.
RECORDED = ROOT / "recorded.json"
APP_RECORDINGS = Path.home() / "Library/Application Support/DictationApp/Recordings"
RESULTS = ROOT / "results"
APP = Path("/Applications/DictationApp.app")
OPENROUTER_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
CATEGORIES = ["mixed", "chinese", "english"]

# ---------------------------------------------------------------- scoring

_CJK = harness.CJK


_TAG = re.compile(r"<\|[^|>]*\|>")
_t2s = None


def to_simplified(text: str) -> str:
    global _t2s
    if _t2s is None:
        from opencc import OpenCC
        _t2s = OpenCC("t2s")
    return _t2s.convert(text)


def normalize(text: str) -> tuple[str, bool]:
    """Strips speaker tags and converts to Simplified. Returns (text, was_traditional)."""
    text = _TAG.sub("", text or "")
    simplified = to_simplified(text)
    return simplified, simplified != text


def english_recall(reference: str, hypothesis: str) -> float | None:
    """Fraction of the reference's English words present in the hypothesis (multiset)."""
    ref = [t for t in tokens(reference) if not _CJK.match(t)]
    if not ref:
        return None
    pool = [t for t in tokens(hypothesis) if not _CJK.match(t)]
    hits = 0
    for t in ref:
        if t in pool:
            pool.remove(t)
            hits += 1
    return hits / len(ref)


# ---------------------------------------------------------------- cases & audio

def load_cases(categories: list[str] | None = None) -> list[dict]:
    cases = json.loads(CASES.read_text())["cases"] + load_recorded()
    return [c for c in cases if not categories or c["category"] in categories]


def load_recorded() -> list[dict]:
    return json.loads(RECORDED.read_text())["cases"] if RECORDED.exists() else []


def save_recorded(cases: list[dict]) -> None:
    RECORDED.write_text(json.dumps({"about": "Your recordings (bench.py import-recordings). Git-ignored. "
                                    "'verified': false means text is what the app heard, not checked yet.",
                                    "cases": cases}, ensure_ascii=False, indent=2) + "\n")


def guess_category(text: str) -> str:
    has_cjk = bool(_CJK.search(text))
    has_latin = bool(re.search(r"[A-Za-z]{2,}", text))
    return "mixed" if has_cjk and has_latin else "chinese" if has_cjk else "english"


def to_wav(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(src), str(dst)],
                   check=True, capture_output=True)


BABBLE_LINES = [
    ("Eddy (English (US))", "So anyway I told them the meeting was moved to the afternoon and nobody seemed to mind."),
    ("Tingting", "你昨天晚上看那个节目了吗，我觉得最后那一段特别好笑。"),
    ("Daniel", "Could you pass the menu over here, I think we should order another round of coffee."),
    ("Sandy (Chinese (China mainland))", "我们下次再约吧，最近工作实在是太忙了，周末都在加班。"),
]


def _read_pcm(path: Path) -> list[int]:
    with wave.open(str(path)) as w:
        raw = w.readframes(w.getnframes())
    return list(struct.unpack(f"<{len(raw) // 2}h", raw))


def _write_pcm(path: Path, samples: list[int]) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(struct.pack(f"<{len(samples)}h", *samples))


def _rms(x: list[float]) -> float:
    return math.sqrt(sum(v * v for v in x) / max(len(x), 1)) or 1.0


def babble_track(tmp: Path) -> list[int]:
    """Overlapping background conversation (2 streams), cached in audio/_babble.wav."""
    cache = AUDIO / "_babble.wav"
    if not cache.exists():
        streams = []
        for i, (voice, line) in enumerate(BABBLE_LINES):
            aiff = tmp / f"b{i}.aiff"
            subprocess.run(["say", "-v", voice, "-o", str(aiff), line], check=True)
            to_wav(aiff, tmp / f"b{i}.wav")
            streams.append(_read_pcm(tmp / f"b{i}.wav"))
        a = streams[0] + streams[2]
        b = [0] * 4000 + streams[1] + streams[3]
        n = max(len(a), len(b))
        mixed = [(a[i] if i < len(a) else 0) + (b[i] if i < len(b) else 0) for i in range(n)]
        _write_pcm(cache, [max(-32768, min(32767, v // 2)) for v in mixed])
    return _read_pcm(cache)


def add_noise(path: Path, snr_db: float, babble: list[int], seed: str) -> None:
    """Mixes looping background chatter plus a little hiss under the speech at `snr_db`."""
    speech = _read_pcm(path)
    rng = random.Random(seed)
    noise = [babble[i % len(babble)] + rng.gauss(0, 1200) for i in range(len(speech))]
    scale = _rms(speech) / (_rms(noise) * 10 ** (snr_db / 20))
    _write_pcm(path, [max(-32768, min(32767, int(s + n * scale))) for s, n in zip(speech, noise)])


def cmd_synth(args) -> int:
    made = 0
    for c in load_cases():
        if c.get("source") != "tts":
            continue
        out = AUDIO / f"{c['id']}.wav"
        if out.exists() and not args.force:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            aiff = Path(tmp) / "x.aiff"
            say = ["say", "-v", c["voice"], "-o", str(aiff)] + (["-r", str(c["rate"])] if c.get("rate") else [])
            subprocess.run(say + [c["text"]], check=True)
            to_wav(aiff, out)
            if c.get("noise_snr_db") is not None:
                add_noise(out, c["noise_snr_db"], babble_track(Path(tmp)), c["id"])
        made += 1
        print(f"  {c['id']}  {wav_seconds(out):4.1f}s  {c['text']}")
    for c in load_cases():
        if c.get("source") != "concat":
            continue
        out = AUDIO / f"{c['id']}.wav"
        if out.exists() and not args.force:
            continue
        concat_clips(c["parts"], c.get("gap", 0.4), out)
        made += 1
        print(f"  {c['id']}  {wav_seconds(out):4.1f}s  (= {' + '.join(c['parts'])})")
    print(f"synthesized {made} clip(s) into {AUDIO.relative_to(ROOT.parent)}/")
    return 0


def concat_clips(parts: list[str], gap_seconds: float, out: Path) -> None:
    """A long dictation made of existing clips with short pauses between them."""
    gap = [0] * int(16000 * gap_seconds)
    samples: list[int] = []
    for i, part in enumerate(parts):
        samples += (gap if i else []) + _read_pcm(AUDIO / f"{part}.wav")
    _write_pcm(out, samples)


def cmd_add(args) -> int:
    data = json.loads(CASES.read_text())
    if any(c["id"] == args.id for c in data["cases"]):
        sys.exit(f"case id {args.id!r} already exists")
    to_wav(Path(args.audio), AUDIO / f"{args.id}.wav")
    data["cases"].append({"id": args.id, "category": args.category, "source": "recorded", "text": args.text})
    CASES.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"added {args.id} ({args.category}, {wav_seconds(AUDIO / f'{args.id}.wav'):.1f}s)")
    return 0


def cmd_import_recordings(args) -> int:
    """Copies recordings kept by the app (WAV + JSON of what it heard) into the benchmark as cases."""
    source = Path(args.dir).expanduser()
    wavs = sorted(source.glob("*.wav")) if source.is_dir() else []
    if not wavs:
        print(f"no recordings in {source} — turn on Settings → Keep recordings and dictate a few")
        return 1
    recorded = load_recorded()
    known = {c["id"] for c in json.loads(CASES.read_text())["cases"] + recorded}
    added = 0
    for wav in wavs:
        cid = f"rec-{wav.stem}"
        if cid in known:
            continue
        meta_path = wav.with_suffix(".json")
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        out = AUDIO / f"{cid}.wav"
        try:
            with wave.open(str(wav)) as w:
                plain = (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 16000)
        except (wave.Error, EOFError):
            plain = False  # a WAV variant Python can't parse: afconvert can
        if plain:
            _write_pcm(out, _read_pcm(wav))  # rewrites the header: the app's WAVs can carry padding chunks
        else:
            to_wav(wav, out)
        if wav_seconds(out) < args.min_seconds:
            out.unlink()
            continue
        text = meta.get("transcript", "")
        recorded.append({"id": cid, "category": args.category or guess_category(text), "source": "recorded",
                         "text": text, "verified": False, "heard_by": meta.get("model"),
                         "recorded_at": meta.get("date"), **({"error": meta["error"]} if meta.get("error") else {})})
        known.add(cid)
        added += 1
        print(f"  {cid}  {wav_seconds(out):5.1f}s  {recorded[-1]['category']:<8} {text[:70] or '(' + meta.get('error', 'no transcript') + ')'}")
    save_recorded(recorded)
    print(f"imported {added} recording(s) into bench/{RECORDED.name} (git-ignored).")
    if added:
        print("Latency works with them now (suite.py latency run --recorded). For accuracy, correct each text\n"
              "to what you actually said: bench/bench.py verify <id> --text \"…\" (or edit recorded.json, verified: true).")
    return 0


def cmd_verify(args) -> int:
    recorded = load_recorded()
    case = next((c for c in recorded if c["id"] == args.id), None)
    if case is None:
        sys.exit(f"no recorded case {args.id!r} (bench/bench.py list)")
    if args.text is not None:
        case["text"] = args.text
    if args.category:
        case["category"] = args.category
    case["verified"] = True
    save_recorded(recorded)
    print(f"verified {case['id']}: {case['text']}")
    return 0


def cmd_list(args) -> int:
    for c in load_cases(args.category):
        wav = AUDIO / f"{c['id']}.wav"
        dur = f"{wav_seconds(wav):4.1f}s" if wav.exists() else "  —  "
        flag = " (unverified)" if c.get("verified") is False else ""
        print(f"{c['id']:<17} L{c.get('level', 1)} {c['category']:<8} {c.get('source', 'tts'):<9} {dur}  {c['text']}{flag}")
    return 0


# ---------------------------------------------------------------- runners

def openrouter_once(model_id: str, options: dict, audio: bytes, name: str, key: str) -> dict:
        boundary = f"bench-{uuid.uuid4().hex}"
        fields = {"model": model_id, **options}
        body = "".join(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n"
                       for k, v in fields.items()).encode()
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}.wav\"\r\n"
                 f"Content-Type: audio/wav\r\n\r\n").encode() + audio + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(OPENROUTER_URL, data=body, method="POST", headers={
            "Authorization": f"Bearer {key}", "Content-Type": f"multipart/form-data; boundary={boundary}",
            "X-Title": "DictationApp benchmark"})
        start = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                payload = json.loads(r.read())
            err = None
        except urllib.error.HTTPError as e:
            payload, err = {}, f"HTTP {e.code}: {e.read()[:300].decode(errors='replace')}"
        except Exception as e:  # network etc.
            payload, err = {}, str(e)
        latency = time.monotonic() - start
        usage = payload.get("usage") or {}
        return {"text": payload.get("text", ""), "latency": latency, "cost": usage.get("cost"), "error": err}


def run_openrouter(spec: str, cases: list[dict], key: str, repeat: int, tag: str) -> list[list[dict]]:
    model_id, _, query = spec.partition("?")
    options = dict(urllib.parse.parse_qsl(query))
    out = []
    for c in cases:
        audio = (AUDIO / f"{c['id']}.wav").read_bytes()
        runs = [openrouter_once(model_id, options, audio, c["id"], key) for _ in range(repeat)]
        out.append(runs)
        r = runs[0]
        lat = "/".join(f"{x['latency']:.2f}" for x in runs)
        print(f"  {'✗' if r['error'] else '·'} [{tag}] {c['id']:<17} {lat}s  {(r['text'] or r['error'] or '')[:70]}", flush=True)
    return out


def run_apple(locale: str, cases: list[dict], repeat: int) -> list[list[dict]]:
    runs = [run_apple_once(locale, cases) for _ in range(repeat)]
    return [list(per_case) for per_case in zip(*runs)]


def run_apple_once(locale: str, cases: list[dict]) -> list[dict]:
    """Runs clips through the installed app's real SpeechEngine (needs its Speech permission)."""
    if not APP.exists():
        sys.exit(f"{APP} not found — run ./build.sh first")
    with tempfile.TemporaryDirectory() as tmp:
        plan, out = Path(tmp) / "plan.json", Path(tmp) / "out.jsonl"
        # The app's latency probe (LatencyProbe.swift); clips play at real-time pace, like the mic.
        plan.write_text(json.dumps({"pause": 0, "timeout": 60, "trials": [
            {"id": c["id"], "file": str(AUDIO / f"{c['id']}.wav"), "stt": f"apple:{locale}", "polish": []}
            for c in cases]}))
        was_running = subprocess.run(["pgrep", "-x", "DictationApp"], capture_output=True).returncode == 0
        subprocess.run(["pkill", "-x", "DictationApp"], capture_output=True)
        time.sleep(0.5)
        subprocess.run(["open", "-n", "--env", f"DICTATIONAPP_LATENCY_PLAN={plan}",
                        "--env", f"DICTATIONAPP_LATENCY_OUT={out}", str(APP)], check=True)
        deadline = time.monotonic() + 30 + sum(wav_seconds(AUDIO / f"{c['id']}.wav") + 5 for c in cases)
        lines: list[str] = []
        while time.monotonic() < deadline:
            lines = out.read_text().splitlines() if out.exists() else []
            if len(lines) >= len(cases):
                break
            time.sleep(0.5)
        subprocess.run(["pkill", "-x", "DictationApp"], capture_output=True)
        if was_running:
            time.sleep(0.5)
            subprocess.run(["open", str(APP)])
    by_id = {r["id"]: r for r in map(json.loads, lines)}
    results = []
    for c in cases:
        r = by_id.get(c["id"])
        if r is None:
            results.append({"text": "", "latency": None, "cost": 0.0, "error": "no result (timed out)"})
        else:
            results.append({"text": r["raw"], "latency": r.get("transcribe"), "cost": 0.0, "error": r.get("error")})
        print(f"  · {c['id']:<12} {results[-1]['text'] or results[-1]['error']}", flush=True)
    return results


def run_local(engine: str, model_id: str, cases: list[dict], repeat: int) -> list[list[dict]]:
    """A model running on this Mac (MLX), via local_stt.py in its own uv environment. The model
    loads and warms up once; each run's latency is decoding from memory, from end of audio to text."""
    files = [str(AUDIO / f"{c['id']}.wav") for c in cases for _ in range(repeat)]
    proc = subprocess.run([str(ROOT / "local_stt.py"), engine, model_id, *files], capture_output=True, text=True)
    lines = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{")]
    if not lines or "warmup" not in lines[0]:
        sys.exit(f"local_stt.py failed:\n{proc.stderr[-2000:]}")
    print(f"  loaded in {lines[0]['load']}s, warm-up {lines[0]['warmup']}s", flush=True)
    results = [{"text": r.get("text", ""), "latency": r.get("latency"), "cost": 0.0, "error": r.get("error")}
               for r in lines[1:]]
    results += [{"text": "", "latency": None, "cost": 0.0, "error": "no result"}] * (len(files) - len(results))
    out = [results[i * repeat:(i + 1) * repeat] for i in range(len(cases))]
    for c, runs in zip(cases, out):
        lat = "/".join(f"{x['latency']:.3f}" for x in runs if x["latency"] is not None)
        print(f"  · {c['id']:<17} {lat}s  {(runs[0]['text'] or runs[0]['error'] or '')[:70]}", flush=True)
    return out


# ---------------------------------------------------------------- run & report

def summarize(rows: list[dict]) -> dict:
    """Keys: "<category>" (all levels), "<category>@L<level>", "L<level>", and "all"."""
    groups: dict[str, list[dict]] = {"all": rows}
    for r in rows:
        level = r.get("level", 1)
        for key in (r["category"], f"{r['category']}@L{level}", f"L{level}"):
            groups.setdefault(key, []).append(r)
    summary = {}
    for key, sel in groups.items():
        lat = [x for r in sel for x in (r.get("latencies") or [r["latency"]]) if x is not None]
        rec = [r["en_recall"] for r in sel if r["en_recall"] is not None]
        audio = sum(r["audio_seconds"] * r.get("runs", 1) for r in sel)
        cost = sum(r["cost"] or 0 for r in sel)
        summary[key] = {
            "cases": len(sel),
            "errors": sum(1 for r in sel if r["error"]),
            "accuracy": round(1 - statistics.mean(min(r["error_rate"], 1.0) for r in sel), 4),
            "en_recall": round(statistics.mean(rec), 4) if rec else None,
            "traditional": sum(1 for r in sel if r.get("traditional")),
            "latency_min": round(min(lat), 3) if lat else None,
            "latency_p50": round(statistics.median(lat), 3) if lat else None,
            "latency_max": round(max(lat), 3) if lat else None,
            "cost": round(cost, 6),
            "cost_per_audio_hour": round(cost / audio * 3600, 4) if audio else None,
        }
    return summary


def score_case(c: dict, runs: list[dict]) -> dict:
    texts = [normalize(r["text"]) for r in runs]
    rates = [error_rate(c["text"], t) for t, _ in texts]
    recalls = [english_recall(c["text"], t) for t, _ in texts] if c["category"] == "mixed" else []
    lat = [r["latency"] for r in runs if r["latency"] is not None and not r["error"]]
    costs = [r["cost"] for r in runs if r["cost"] is not None]
    return {"id": c["id"], "category": c["category"], "level": c.get("level", 1), "source": c.get("source", "tts"),
            "reference": c["text"], "hypothesis": runs[0]["text"], "hypotheses": [r["text"] for r in runs],
            "error_rate": round(statistics.mean(rates), 4),
            "en_recall": round(statistics.mean(recalls), 4) if recalls and None not in recalls else None,
            "traditional": any(trad for _, trad in texts),
            "latency": round(statistics.median(lat), 3) if lat else None, "latencies": [round(x, 3) for x in lat],
            "cost": round(sum(costs), 8) if costs else None, "runs": len(runs),
            "error": next((r["error"] for r in runs if r["error"]), None),
            "audio_seconds": round(wav_seconds(AUDIO / f"{c['id']}.wav"), 2)}


def run_model(model: str, cases: list[dict], args, commit: str) -> Path:
    kind, _, name = model.partition(":")
    if kind == "openrouter":
        key = os.environ.get(args.key_env)
        if not key:
            raise SystemExit(f"${args.key_env} is not set (choose another with --key-env)")
        raw = run_openrouter(name, cases, key, args.repeat, model.split("/")[-1][:18])
    elif kind == "apple":
        raw = run_apple(name or "en-US", cases, args.repeat)
    elif kind == "parakeet":
        raw = run_local("parakeet", name or "mlx-community/parakeet-tdt-0.6b-v2", cases, args.repeat)
    elif kind == "mlx":
        raw = run_local("mlx", name, cases, args.repeat)
    else:
        raise SystemExit(f"unknown model {model!r}: use openrouter:<id>[?k=v], apple:<locale>, parakeet:<hf-id> or mlx:<hf-id>")
    rows = [score_case(c, runs) for c, runs in zip(cases, raw)]
    result = {"model": model, "run_at": datetime.now().isoformat(timespec="seconds"), "commit": commit,
              "repeat": args.repeat, "summary": summarize(rows), "cases": rows}
    slug = re.sub(r"[^a-z0-9.-]+", "_", model.lower())
    path = RESULTS / f"{datetime.now():%Y%m%d-%H%M%S}_{slug}.json"
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"    saved {path.relative_to(ROOT.parent)}", flush=True)
    return path


def cmd_run(args) -> int:
    cases = load_cases(args.category)
    if args.level:
        cases = [c for c in cases if c.get("level", 1) in args.level]
    unverified = [c for c in cases if c.get("verified") is False]
    if unverified and not args.include_unverified:
        # Their text is what one model heard: scoring against it would favour that model.
        print(f"skipping {len(unverified)} unverified recording(s) — `bench.py verify` them, or --include-unverified")
        cases = [c for c in cases if c.get("verified") is not False]
    missing = [c["id"] for c in cases if not (AUDIO / f"{c['id']}.wav").exists()]
    if missing:
        sys.exit(f"missing audio for {', '.join(missing)} — run `bench/bench.py synth`")
    RESULTS.mkdir(exist_ok=True)
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                            cwd=ROOT).stdout.strip()
    print(f"==> {len(args.model)} model(s) × {len(cases)} cases × {args.repeat} run(s)")
    # Cloud models run in parallel (each one sequentially, so its latencies aren't skewed by
    # itself); Apple runs use the app and must go one at a time.
    cloud = [m for m in args.model if m.startswith("openrouter:")]
    local = [m for m in args.model if not m.startswith("openrouter:")]
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
        futures = [pool.submit(run_model, m, cases, args, commit) for m in cloud]
        for m in local:
            run_model(m, cases, args, commit)
        for f in futures:
            f.result()
    print()
    return cmd_report(argparse.Namespace(json=args.json, model=args.model, all=False))


def latest_results(models: list[str] | None = None) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for path in sorted(RESULTS.glob("*.json")):
        r = json.loads(path.read_text())
        if models and r["model"] not in models:
            continue
        latest[r["model"]] = r  # files sort by timestamp, so last wins
    return latest


def export_data(models: list[str] | None, reference: str) -> dict:
    """Latest result per model + cost relative to the reference model, for the comparison page."""
    latest = latest_results(models)
    ref = latest.get(reference, {}).get("summary", {}).get("all", {}).get("cost_per_audio_hour")
    cases = {c["id"]: c for c in load_cases()}
    out = {"reference": reference, "levels": json.loads(CASES.read_text()).get("levels", {}), "models": []}
    for model, r in latest.items():
        cph = r["summary"]["all"]["cost_per_audio_hour"]
        out["models"].append({
            "model": model, "run_at": r["run_at"], "repeat": r.get("repeat", 1), "summary": r["summary"],
            "cost_per_audio_hour": cph,
            "cost_vs_reference": round(cph / ref, 4) if (ref and cph is not None) else None,
            "cases": [{k: x[k] for k in ("id", "category", "level", "reference", "hypothesis", "error_rate",
                                          "en_recall", "traditional", "latencies", "error")} for x in r["cases"]],
        })
    out["case_count"] = len(cases)
    return out


def cmd_export(args) -> int:
    print(json.dumps(export_data(args.model, args.reference), ensure_ascii=False, indent=2))
    return 0


def cmd_html(args) -> int:
    """Writes the visual comparison page (template + latest results)."""
    data = json.dumps(export_data(args.model, args.reference), ensure_ascii=False).replace("</", "<\\/")
    page = (ROOT / "report_template.html").read_text().replace("/*DATA*/null", data)
    out = Path(args.output)
    out.write_text(page)
    print(f"wrote {out}")
    return 0


def _pct(x):
    return "   —" if x is None else f"{x * 100:4.0f}%"


def _sec(x):
    return "    —" if x is None else f"{x:5.2f}s"


def cmd_report(args) -> int:
    latest = latest_results(args.model)
    if not latest:
        print("no results yet — run `bench/bench.py run -m <model>`")
        return 1
    if args.json:
        print(json.dumps({m: {"run_at": r["run_at"], "summary": r["summary"]} for m, r in latest.items()},
                         ensure_ascii=False, indent=2))
        return 0
    print(f"{'model':<44} {'mixed':>6} {'EN recall':>9} {'chinese':>8} {'english':>8} {'p50 wait':>9} {'$/audio hr':>10}")
    for model, r in sorted(latest.items(), key=lambda kv: -(kv[1]["summary"].get("mixed", {}).get("accuracy") or 0)):
        s = r["summary"]
        get = lambda cat, k: s.get(cat, {}).get(k)
        cost = get("all", "cost_per_audio_hour")
        print(f"{model:<44} {_pct(get('mixed', 'accuracy')):>6} {_pct(get('mixed', 'en_recall')):>9} "
              f"{_pct(get('chinese', 'accuracy')):>8} {_pct(get('english', 'accuracy')):>8} "
              f"{_sec(get('all', 'latency_p50')):>9} {('$%.2f' % cost) if cost else 'free':>10}")
    print("\naccuracy = 1 − token error rate (Chinese char / English word); p50 wait = time from end of audio to text.")
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("synth", help="generate TTS audio for cases (skips existing)")
    s.add_argument("--force", action="store_true", help="regenerate existing clips")
    s.set_defaults(func=cmd_synth)
    r = sub.add_parser("run", help="transcribe every case with one or more models and score them")
    r.add_argument("-m", "--model", action="append", required=True,
                   help="openrouter:<id>, apple:<locale>, parakeet:<hf-id> or mlx:<hf-id>")
    r.add_argument("-c", "--category", action="append", choices=CATEGORIES, help="limit to category (repeatable)")
    r.add_argument("-l", "--level", action="append", type=int, choices=[1, 2, 3], help="limit to level (repeatable)")
    r.add_argument("-r", "--repeat", type=int, default=1, help="runs per clip (latency min/median/max)")
    r.add_argument("-p", "--parallel", type=int, default=12, help="cloud models to run at once")
    r.add_argument("--key-env", default="OPENROUTER_API_KEY", help="env var holding the OpenRouter key")
    r.add_argument("--json", action="store_true", help="print the summary as JSON")
    r.add_argument("--include-unverified", action="store_true",
                   help="also score recordings whose text hasn't been checked (biased toward the model that heard them)")
    r.set_defaults(func=cmd_run)
    rep = sub.add_parser("report", help="compare the latest result of each model")
    rep.add_argument("-m", "--model", action="append", help="only these models")
    rep.add_argument("--json", action="store_true")
    rep.set_defaults(func=cmd_report)
    e = sub.add_parser("export", help="latest result per model as JSON (for the comparison page)")
    e.add_argument("-m", "--model", action="append")
    e.add_argument("--reference", default="openrouter:meta/muse-voice-transcribe-1.0",
                   help="model that costs are expressed relative to")
    e.set_defaults(func=cmd_export)
    h = sub.add_parser("html", help="write the visual comparison page")
    h.add_argument("-o", "--output", default=str(RESULTS / "report.html"))
    h.add_argument("-m", "--model", action="append")
    h.add_argument("--reference", default="openrouter:meta/muse-voice-transcribe-1.0")
    h.set_defaults(func=cmd_html)
    a = sub.add_parser("add", help="add a real recording as a case")
    a.add_argument("audio", help="any audio file afconvert can read (m4a, wav, aiff, …)")
    a.add_argument("--id", required=True)
    a.add_argument("--category", required=True, choices=CATEGORIES)
    a.add_argument("--text", required=True, help="exact reference transcript")
    a.set_defaults(func=cmd_add)
    im = sub.add_parser("import-recordings", help="add recordings the app kept (Settings → Keep recordings)")
    im.add_argument("dir", nargs="?", default=str(APP_RECORDINGS), help=f"default: {APP_RECORDINGS}")
    im.add_argument("--category", choices=CATEGORIES, help="instead of guessing from the transcript")
    im.add_argument("--min-seconds", type=float, default=1.0, help="skip shorter recordings")
    im.set_defaults(func=cmd_import_recordings)
    v = sub.add_parser("verify", help="mark a recording's text as checked (optionally correcting it)")
    v.add_argument("id")
    v.add_argument("--text", help="what was actually said")
    v.add_argument("--category", choices=CATEGORIES)
    v.set_defaults(func=cmd_verify)
    ls = sub.add_parser("list", help="list cases")
    ls.add_argument("-c", "--category", action="append", choices=CATEGORIES)
    ls.set_defaults(func=cmd_list)
    return p


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
