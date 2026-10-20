"""Tab completion (bench/completion.py). Run: uv run --with pytest pytest bench"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

import completion

BENCH = Path(__file__).resolve().parent


def values(words, index=None):
    mode, found = completion.complete(words, len(words) - 1 if index is None else index)
    return mode, [v for v, _ in found]


def test_suites_then_subcommands():
    assert values([""]) == ("values", ["latency", "polish", "commands", "accuracy", "list"])
    assert values(["commands", ""])[1] == ["run", "report", "cases"]
    assert "jev" in values(["commands", "run", "-m", ""])[1]
    assert values(["polish", ""])[1] == ["run", "report", "cases"]
    assert values(["latency", ""])[1] == ["run", "report", "polish-cost"]
    assert "import-recordings" in values(["accuracy", ""])[1]


def test_options_with_their_help_and_used_ones_dropped():
    mode, found = completion.complete(["polish", "run", "--"], 2)
    helps = dict(found)
    assert "--prompt-file" in helps and "--no-wrap" in helps
    assert helps["--rounds"].startswith("times each case is polished")
    assert "-m" not in helps, "short options only once you type a single dash"
    assert "-m" in values(["polish", "run", "-"])[1]
    after = values(["polish", "run", "--quick", "-m", "apple", "--"])[1]
    assert "--quick" not in after, "a flag isn't offered twice"
    assert "--model" in after, "repeatable options stay"


def test_option_values():
    models = values(["polish", "run", "-m", ""])[1]
    assert {"apple", "setup:cloud-flash", "setup:cloud-big",
            "openrouter:deepseek/deepseek-v4.1-flash@Together,DeepInfra",
            "openrouter:deepseek/deepseek-v4.1-flash@DeepInfra,Together"} <= set(models)
    assert "none" in values(["latency", "run", "-P", ""])[1]
    assert "flash+backup" in values(["latency", "run", "--stt", ""])[1]
    assert values(["polish", "run", "--sort", ""]) == ("values", ["latency", "throughput", "price"])
    mode, prompts = values(["polish", "run", "--prompt-file", ""])
    assert mode == "values+files" and os.path.relpath(BENCH / "polish_prompts/v4.txt") in prompts
    mode, sets = values(["polish", "run", "--cases-file", ""])
    assert os.path.relpath(BENCH / "polish_cases.json") in sets
    assert values(["polish", "run", "--rounds", ""])[0].startswith("message:times each case")
    assert values(["polish", "run", "--out", ""])[0] == "dirs"
    assert values(["polish", "run", "--models-file", ""])[0] == "files"
    case = completion.complete(["polish", "run", "--case", ""], 3)[1][0]
    assert case[0] and case[1], "case ids come with the start of the dictation"


def test_a_value_is_skipped_not_mistaken_for_an_option():
    assert "--quick" in values(["polish", "run", "--label", "--quick", "--"])[1], "--quick here is the label"
    assert values(["polish", "run", "-r", "3", "--sort", ""])[1] == ["latency", "throughput", "price"]


def test_suite_py_complete_protocol():
    out = subprocess.run([str(BENCH / "suite.py"), "__complete", "3", "polish", "run", "--sort", ""],
                         capture_output=True, text=True, check=True).stdout
    assert out.splitlines() == ["values", "latency\t", "throughput\t", "price\t"]


@pytest.mark.skipif(not shutil.which("zsh"), reason="needs zsh")
def test_zsh_function_escapes_colons_and_picks_the_mode():
    script = f"""
compdef() {{ :; }}
source {BENCH / 'completion.zsh'}
_describe() {{ print -rl -- "${{(@P)4}}"; }}
_files() {{ print -r -- "FILES $*"; }}
_message() {{ print -r -- "MESSAGE $*"; }}
words=({BENCH / 'suite.py'} polish run -m ""); CURRENT=5; _dictation_bench_suite
words=({BENCH / 'suite.py'} polish run --out ""); CURRENT=5; _dictation_bench_suite
words=({BENCH / 'suite.py'} polish run -r ""); CURRENT=5; _dictation_bench_suite
"""
    out = subprocess.run(["zsh", "-f", "-c", script], capture_output=True, text=True, check=True).stdout
    assert r"setup\:cloud-flash:Cloud Flash: openrouter:deepseek/deepseek-v4.1-flash@Together,DeepInfra, prompt v7" in out.splitlines()
    assert "FILES -/" in out
    assert "MESSAGE -r times each case is polished per model (default 1)" in out
