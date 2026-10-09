#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["opencc-python-reimplemented==0.1.7"]
# ///
"""DictationApp benchmarks: one entry point, one suite per question.

  bench/suite.py list                     # the suites
  bench/suite.py latency run              # how long after you press stop until text is ready
  bench/suite.py latency report
  bench/suite.py accuracy run -m …        # speech-to-text accuracy and cost (= bench/bench.py)
  bench/suite.py <suite> --help

Results land in bench/results/<suite>/. To add a suite, write bench/suites/<name>.py with NAME,
HELP and main(argv) (bench/harness.py has percentiles, scheduling, result files and tables) and
list it in bench/suites/__init__.py.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from suites import SUITES  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] in ("-h", "--help", "list"):
        print(__doc__)
        for suite in SUITES.values():
            print(f"  {suite.NAME:<10} {suite.HELP}")
        return 0 if argv else 2
    suite = SUITES.get(argv[0])
    if suite is None:
        print(f"unknown suite {argv[0]!r}; choose from: {', '.join(SUITES)}", file=sys.stderr)
        return 2
    return suite.main(argv[1:])


if __name__ == "__main__":
    sys.exit(main())
