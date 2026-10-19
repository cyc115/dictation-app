#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["opencc-python-reimplemented==0.1.7"]
# ///
"""Local speech models vs the cloud, on your own kept recordings (Settings → Keep recordings).

  bench/recordings_compare.py -m mlx:mlx-community/Qwen3-ASR-1.7B-8bit -m mlx:mlx-community/Qwen3-ASR-0.6B-8bit
  bench/recordings_compare.py -m parakeet:mlx-community/parakeet-tdt-0.6b-v2 --english-only
  bench/recordings_compare.py --reuse local=out.jsonl …   # re-report a saved run, no new decoding

Each local model (local_stt.py, one at a time so they don't share the GPU) transcribes every kept
recording of 1 s or more. The table compares its stop-to-text time, by clip length, with what the
cloud took for the same dictation when you made it (the recording's transcribeSeconds: your network
at that moment, backup model included). "Agrees" is 1 − token error rate against the cloud's
transcript, fillers (uh, um…) removed from both, split by which cloud model gave it: the cloud's
text is no ground truth, but a local copy of the same model should come close to it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import bench  # noqa: E402

RECORDINGS = Path.home() / "Library/Application Support/DictationApp/Recordings"
FILLERS = re.compile(r"\b(uh+|um+|ah+|mm+|hmm+|er+|erm)\b[,.]?", re.I)
CJK = re.compile(r"[一-鿿]")
BUCKETS = [(0, 10), (10, 20), (20, 30), (30, 60), (60, None)]


def clean(text: str) -> str:
    return re.sub(r"\s+", " ", FILLERS.sub(" ", text or "")).strip()


def percentile(values: list[float], p: float) -> float:
    values = sorted(values)
    return values[min(len(values) - 1, round(p / 100 * (len(values) - 1)))]


def recordings(english_only: bool) -> list[tuple[Path, dict]]:
    found = []
    for meta_path in sorted(RECORDINGS.glob("*.json")):
        meta, wav = json.loads(meta_path.read_text()), meta_path.with_suffix(".wav")
        if not meta.get("transcript") or meta.get("error") or not wav.exists() or meta.get("seconds", 0) < 1:
            continue
        if english_only and CJK.search(meta["transcript"]):
            continue
        found.append((wav, meta))
    return found


def run_local(model: str, wavs: list[Path], out: Path) -> Path:
    engine, _, model_id = model.partition(":")
    if engine not in ("parakeet", "mlx"):
        sys.exit(f"{model}: use parakeet:<hf-id> or mlx:<hf-id>")
    print(f"==> {model}: {len(wavs)} recordings…", flush=True)
    with out.open("w") as f:
        subprocess.run([str(ROOT / "local_stt.py"), engine, model_id, *map(str, wavs)], stdout=f, check=True)
    return out


def agreement(reference: str, hypothesis: str) -> float:
    reference, hypothesis = clean(reference), clean(hypothesis)
    if not reference:
        return 0.0 if hypothesis else 1.0
    return 1 - min(bench.error_rate(reference, bench.normalize(hypothesis)[0]), 1.0)


def report(found: list[tuple[Path, dict]], runs: dict[str, dict[str, dict]]) -> None:
    meta = {str(wav): m for wav, m in found}
    files = [f for f in meta if all(f in r for r in runs.values())]
    audio = {f: meta[f]["seconds"] for f in files}
    columns = {"cloud (as dictated)": {f: meta[f]["transcribeSeconds"] for f in files if meta[f].get("transcribeSeconds")}}
    columns |= {name: {f: r[f]["latency"] for f in files} for name, r in runs.items()}
    print(f"\n{len(files)} recordings. Stop to text, seconds: typical / p95 / worst\n")
    print(f"{'clip length':16}" + "".join(f"{name:>26}" for name in columns))
    for lo, hi in BUCKETS + [(0, None)]:
        chosen = [f for f in files if audio[f] >= lo and (hi is None or audio[f] < hi)]
        label = "all" if (lo, hi) == (0, None) else f"{lo}–{hi} s" if hi else f"{lo}+ s"
        cells = []
        for column in columns.values():
            times = [column[f] for f in chosen if f in column]
            cells.append(f"{statistics.median(times):5.2f} / {percentile(times, 95):5.2f} / {max(times):5.1f}" if times else "–")
        print(f"{label + f' (n={len(chosen)})':16}" + "".join(f"{c:>26}" for c in cells))
    print()
    for name, r in runs.items():
        for cloud in sorted({meta[f]["model"] for f in files}):
            chosen = [f for f in files if meta[f]["model"] == cloud]
            scores = [agreement(meta[f]["transcript"], r[f]["text"]) for f in chosen]
            print(f"{name} agrees with {cloud} (n={len(chosen)}): {statistics.mean(scores):.3f}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-m", "--model", action="append", default=[], help="parakeet:<hf-id> or mlx:<hf-id>")
    parser.add_argument("--english-only", action="store_true", help="only recordings the cloud heard as English")
    parser.add_argument("--reuse", action="append", default=[], metavar="NAME=FILE",
                        help="a saved local_stt.py output instead of a new run")
    parser.add_argument("--out", type=Path, default=Path(os.environ.get("TMPDIR", "/tmp")),
                        help="where each run's local_stt.py output goes (default: $TMPDIR)")
    args = parser.parse_args(argv)
    if not args.model and not args.reuse:
        parser.error("give at least one -m or --reuse")
    found = recordings(args.english_only)
    if not found:
        sys.exit(f"no kept recordings in {RECORDINGS}: turn on Settings → Keep recordings and dictate")
    outputs = {m: run_local(m, [w for w, _ in found], args.out / f"local-{re.sub(r'[^a-z0-9.-]+', '_', m.lower())}.jsonl")
               for m in args.model}
    outputs |= {name: Path(path) for name, path in (r.split("=", 1) for r in args.reuse)}
    runs = {name: {r["file"]: r for r in map(json.loads, path.read_text().splitlines())
                   if r.get("file") and r.get("latency") is not None}
            for name, path in outputs.items()}
    report(found, runs)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
