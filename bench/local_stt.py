#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["parakeet-mlx==0.5.2", "mlx-audio==0.5.9", "numpy"]
# ///
"""Speech models running locally on this Mac's GPU (MLX), for bench.py's local models.

  bench/local_stt.py parakeet mlx-community/parakeet-tdt-0.6b-v2 a.wav b.wav …   # one JSON line per file
  bench/local_stt.py mlx mlx-community/Qwen3-ASR-1.7B-8bit a.wav …               # any mlx-audio STT model

"parakeet" runs NVIDIA Parakeet TDT through parakeet-mlx, the way zisshh/computer-use does
(STT_BACKEND=parakeet). "mlx" runs any mlx-audio speech model (Qwen3-ASR: the open weights of
Cloud Flash's model, which also hears Chinese). Either way the model loads once, one warm-up decode
compiles the Metal kernels, then each clip goes in straight from memory (no temp file, no ffmpeg).
The time per clip is what a dictation would wait for after you stop. Clips are 16 kHz mono 16-bit
WAV, as the app records them.
"""
from __future__ import annotations

import json
import sys
import time
import wave

import mlx.core as mx
import numpy as np


def read_wav(path: str) -> np.ndarray:
    with wave.open(path) as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (16000, 1, 2):
            raise ValueError(f"{path}: expected 16 kHz mono 16-bit")
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[0] not in ("parakeet", "mlx"):
        print(__doc__.strip())
        return 0 if argv[:1] in (["-h"], ["--help"]) else 2
    engine, model_id, files = argv[0], argv[1], argv[2:]
    started = time.monotonic()
    if engine == "parakeet":
        from parakeet_mlx import from_pretrained
        from parakeet_mlx.audio import get_logmel
        model = from_pretrained(model_id)

        def transcribe(pcm: np.ndarray) -> str:
            mel = get_logmel(mx.array(pcm), model.preprocessor_config)
            return (model.generate(mel)[0].text or "").strip()
    else:
        from mlx_audio.stt.utils import load_model
        model = load_model(model_id)

        def transcribe(pcm: np.ndarray) -> str:
            return (model.generate(pcm).text or "").strip()
    load = time.monotonic() - started

    started = time.monotonic()
    transcribe(np.zeros(8000, dtype=np.float32))  # warm-up: compiles the kernels
    print(json.dumps({"load": round(load, 3), "warmup": round(time.monotonic() - started, 3)}), flush=True)
    for path in files:
        try:
            pcm = read_wav(path)
            started = time.monotonic()
            text = transcribe(pcm)
            seconds = time.monotonic() - started
            print(json.dumps({"file": path, "text": text, "latency": round(seconds, 4),
                              "audio": round(len(pcm) / 16000, 2)}, ensure_ascii=False), flush=True)
        except Exception as e:  # noqa: BLE001 -- one bad clip shouldn't end the run
            print(json.dumps({"file": path, "text": "", "latency": None, "error": str(e)}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
