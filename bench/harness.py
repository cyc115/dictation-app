"""Shared pieces for DictationApp benchmark suites (bench/suite.py): percentiles, trial
scheduling, run metadata, result files and text tables. Standard library only."""
from __future__ import annotations

import json
import math
import platform
import random
import re
import statistics
import subprocess
import unicodedata
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "results"


# ---------------------------------------------------------------- statistics

def percentile(values: list[float], p: float) -> float | None:
    """Linear interpolation between closest ranks (numpy's default, Excel PERCENTILE.INC)."""
    if not values:
        return None
    xs = sorted(values)
    rank = (len(xs) - 1) * p / 100
    lo, hi = math.floor(rank), math.ceil(rank)
    return xs[lo] + (xs[hi] - xs[lo]) * (rank - lo)


def describe(values: list[float], errors: int = 0) -> dict:
    """n, errors, best (min), p50, p90, p95, worst (max), mean, stdev — seconds, rounded to ms."""
    r = lambda x: None if x is None else round(x, 3)
    return {
        "n": len(values), "errors": errors,
        "min": r(min(values)) if values else None,
        "p50": r(percentile(values, 50)), "p90": r(percentile(values, 90)), "p95": r(percentile(values, 95)),
        "max": r(max(values)) if values else None,
        "mean": r(statistics.fmean(values)) if values else None,
        "stdev": r(statistics.stdev(values)) if len(values) > 1 else None,
    }


# ---------------------------------------------------------------- scheduling

def interleave(items: list, rounds: int, seed: int) -> list[tuple[int, object]]:
    """Every item once per round, in a fresh seeded shuffle each round. Interleaving spreads slow
    moments (network hiccups, thermal throttling) across all items instead of one model's block."""
    out = []
    for rnd in range(1, rounds + 1):
        order = list(items)
        random.Random(f"{seed}:{rnd}").shuffle(order)
        out += [(rnd, item) for item in order]
    return out


# ---------------------------------------------------------------- run metadata & files

def _run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def environment() -> dict:
    """What a result depends on besides the models: code version and machine (no hostnames)."""
    env = {
        "commit": _run(["git", "rev-parse", "--short", "HEAD"]),
        "dirty": bool(_run(["git", "status", "--porcelain", "--untracked-files=no"])),
        "os": platform.platform(terse=True),
        "python": platform.python_version(),
    }
    if platform.system() == "Darwin":
        env["macos"] = _run(["sw_vers", "-productVersion"])
        env["machine"] = _run(["sysctl", "-n", "hw.model"])
        env["cpu"] = _run(["sysctl", "-n", "machdep.cpu.brand_string"])
    return env


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9.-]+", "_", text.lower()).strip("_")[:80]


def save_result(suite: str, label: str, data: dict, directory: Path | None = None) -> Path:
    """Writes results/<suite>/<timestamp>_<label>.json and returns its path."""
    directory = directory or RESULTS / suite
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{datetime.now():%Y%m%d-%H%M%S}_{slug(label)}.json"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    return path


def result_files(suite: str, directory: Path | None = None) -> list[Path]:
    """Oldest first (file names start with the timestamp)."""
    return sorted((directory or RESULTS / suite).glob("*.json"))


# ---------------------------------------------------------------- tables

def seconds(x: float | None) -> str:
    return "—" if x is None else f"{x:.2f}"


GRADE_ANSI = {"good": "\033[32m", "ok": "\033[33m", "bad": "\033[31m"}
GRADE_DOT = {"good": "🟢 ", "ok": "🟡 ", "bad": "🔴 "}


def table(headers: list[str], rows: list[list], markdown: bool = False,
          grades: list[list[str | None]] | None = None, color: bool = False) -> str:
    """Plain-text (or Markdown) table; the first column is left-aligned, the rest right-aligned.
    `grades` (same shape as rows: "good", "ok", "bad" or None) colours cells: ANSI when `color`,
    a dot in Markdown."""
    cells = [[str(c) for c in headers]] + [[str(c) for c in row] for row in rows]
    grade = lambda r, i: grades[r - 1][i] if grades and r > 0 else None
    if markdown:
        body = [[GRADE_DOT.get(grade(r, i), "") + c for i, c in enumerate(row)] for r, row in enumerate(cells) if r > 0]
        lines = ["| " + " | ".join(cells[0]) + " |", "|" + "|".join([":--"] + ["--:"] * (len(headers) - 1)) + "|"]
        return "\n".join(lines + ["| " + " | ".join(r) + " |" for r in body])
    widths = [max(len(r[i]) for r in cells) for i in range(len(headers))]

    def fmt(r: int) -> str:
        out = []
        for i, c in enumerate(cells[r]):
            c = c.ljust(widths[0]) if i == 0 else c.rjust(widths[i])
            g = grade(r, i) if color else None
            out.append(f"{GRADE_ANSI[g]}{c}\033[0m" if g else c)
        return "  ".join(out)
    return "\n".join([fmt(0), "  ".join("-" * w for w in widths)] + [fmt(r) for r in range(1, len(cells))])


# ---------------------------------------------------------------- cases & audio (shared with bench.py)

CASES = ROOT / "cases.json"
AUDIO = ROOT / "audio"


RECORDED = ROOT / "recorded.json"  # your own recordings (bench.py import-recordings), git-ignored


def load_cases() -> list[dict]:
    recorded = json.loads(RECORDED.read_text())["cases"] if RECORDED.exists() else []
    return json.loads(CASES.read_text())["cases"] + recorded


def wav_seconds(path: Path) -> float:
    """Duration of a 16 kHz mono 16-bit WAV (bench/audio's format)."""
    return max(path.stat().st_size - 44, 0) / (16000 * 2)


# ---------------------------------------------------------------- scoring

CJK = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]")
_TOKEN = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]|[a-z0-9]+(?:'[a-z]+)?")


def tokens(text: str) -> list[str]:
    """Each CJK character is a token; each run of latin letters/digits is a token."""
    return _TOKEN.findall(unicodedata.normalize("NFKC", text or "").lower())


def edit_distance(a: list[str], b: list[str]) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def error_rate(reference: str, hypothesis: str) -> float:
    """Token edit distance over the reference's length (1 for anything heard against an empty one)."""
    ref = tokens(reference)
    if not ref:
        return 0.0 if not tokens(hypothesis) else 1.0
    return edit_distance(ref, tokens(hypothesis)) / len(ref)
