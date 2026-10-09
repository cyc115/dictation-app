"""Benchmark suites, one per question. Each module has NAME, HELP and main(argv) -> exit code;
add a suite by writing one and listing it here."""
from suites import accuracy, latency, polish

SUITES = {m.NAME: m for m in (latency, polish, accuracy)}
