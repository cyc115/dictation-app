"""Speech-to-text accuracy, English recall and cost per model: bench/bench.py under the suite runner."""
from __future__ import annotations

NAME = "accuracy"
HELP = "speech-to-text accuracy, cost and single-shot wait per model (= bench/bench.py)"


def main(argv: list[str]) -> int:
    import bench  # bench/bench.py (bench/ is on sys.path, as for every suite)
    return bench.main(argv or ["--help"])


def parser():
    import bench
    return bench.parser()
