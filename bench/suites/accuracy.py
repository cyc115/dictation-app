"""Speech-to-text accuracy, English recall and cost per model: bench/bench.py under the suite runner."""
from __future__ import annotations

import importlib.util
from pathlib import Path

NAME = "accuracy"
HELP = "speech-to-text accuracy, cost and single-shot wait per model (= bench/bench.py)"


def main(argv: list[str]) -> int:
    spec = importlib.util.spec_from_file_location("bench_accuracy", Path(__file__).resolve().parents[1] / "bench.py")
    bench = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bench)
    return bench.main(argv or ["--help"])
