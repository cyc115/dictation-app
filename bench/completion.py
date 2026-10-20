"""Tab completion for bench/suite.py, read from the suites' own argparse parsers so it never drifts.

The shell calls `suite.py __complete <index> <word>...` (the words after suite.py; index is the one
being completed) and gets back a mode line, then one `value<TAB>description` line per candidate:

  values        complete from the lines that follow
  values+files  those, or any file
  files / dirs  any file / directory
  message:<m>   a free value (a number, a label); <m> says what it is

Install for zsh: `source bench/completion.zsh` from your .zshrc.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import harness

FILES = {"models_file", "setups_file", "corrections", "output", "dir", "audio"}


def _rel(path: Path) -> str:
    """The path as the user would type it from the current directory."""
    return os.path.relpath(path)


def _subparsers(p: argparse.ArgumentParser) -> dict[str, argparse.ArgumentParser]:
    for a in p._actions:
        if isinstance(a, argparse._SubParsersAction):
            return dict(a.choices)
    return {}


def _subcommand_help(p: argparse.ArgumentParser) -> dict[str, str]:
    for a in p._actions:
        if isinstance(a, argparse._SubParsersAction):
            return {c.dest: c.help or "" for c in a._choices_actions}
    return {}


def _takes_value(a: argparse.Action) -> bool:
    return a.nargs != 0 and not isinstance(a, argparse.BooleanOptionalAction)


def _option(p: argparse.ArgumentParser, word: str) -> argparse.Action | None:
    return p._option_string_actions.get(word)


def _models(suite: str, dest: str) -> list[tuple[str, str]]:
    from suites import commands, latency, polish
    if suite == "commands":
        return [(m, "decision model" + (" (the app's default)" if m == "jev" else "")) for m in commands.DEFAULT_MODELS]
    if suite == "latency" and dest == "stt":
        return [(k, f"{title} ({spec})") for k, (spec, title) in latency.STT_ALIASES.items()]
    known = polish.setups()
    if suite == "accuracy":
        return [(s["speech"], s["title"]) for s in known.values()]
    found = [("apple", "Apple on-device")] + ([("none", "no polish")] if suite == "latency" else [])
    found += [(f"setup:{k}", f"{s['title']}: {s['polish']}, prompt {s['prompt']}") for k, s in known.items()]
    for s in known.values():
        for key in ("polish", "polishBackup"):
            if s.get(key, "apple") != "apple" and s[key] not in dict(found):
                found.append((s[key], f"{s['title']} {'backup' if key == 'polishBackup' else 'polish'} model"))
    return found


def _values(suite: str, a: argparse.Action) -> tuple[str, list[tuple[str, str]]]:
    if a.choices:
        return "values", [(str(c), "") for c in a.choices]
    dest = a.dest
    if dest in ("model", "polish", "stt"):
        return "values", _models(suite, dest)
    if dest == "case":
        from suites import polish
        cases = [c for f in sorted(harness.ROOT.glob("polish_cases*.json")) for c in polish.load_cases(f)]
        return "values", [(c["id"], c["raw"][:60]) for c in cases]
    if dest == "clip":
        return "values", [(c["id"], c.get("text", "")[:60]) for c in harness.load_cases()
                          if (harness.AUDIO / f"{c['id']}.wav").exists()]
    if dest == "prompt_file":
        return "values+files", [(_rel(f), "") for f in sorted((harness.ROOT / "polish_prompts").glob("*.txt"))]
    if dest == "cases_file":
        return "values+files", [(_rel(f), f"{len(_cases(f))} cases") for f in sorted(harness.ROOT.glob("polish_cases*.json"))]
    if dest == "file":
        found = sorted((harness.RESULTS / suite).glob("*.json"), reverse=True)  # newest first
        return "values+files", [(_rel(f), "") for f in found]
    if dest == "out":
        return "dirs", []
    if dest in FILES:
        return "files", []
    return f"message:{a.help or a.metavar or dest}", []


def _cases(f: Path) -> list:
    data = json.loads(f.read_text())
    return data["cases"] if isinstance(data, dict) else data


def complete(words: list[str], index: int) -> tuple[str, list[tuple[str, str]]]:
    """(mode, [(value, description)]) for words[index], given the words before it."""
    from suites import SUITES
    if index == 0:
        return "values", [(name, s.HELP) for name, s in SUITES.items()] + [("list", "the suites")]
    suite = words[0]
    if suite not in SUITES or not hasattr(SUITES[suite], "parser"):
        return "values", []
    p = SUITES[suite].parser()
    used: set[str] = set()
    i = 1
    while i < index:
        word = words[i]
        subs = _subparsers(p)
        if word in subs:
            p = subs[word]
        elif (a := _option(p, word)) is not None:
            used.add(a.dest)
            if _takes_value(a) and i + 1 < index:
                i += 1  # its value
        i += 1
    prev = _option(p, words[index - 1]) if index > 1 else None
    if prev is not None and _takes_value(prev):
        return _values(suite, prev)
    current = words[index] if index < len(words) else ""
    subs = _subparsers(p)
    if subs and not current.startswith("-"):
        return "values", list(_subcommand_help(p).items())
    options = []
    for a in p._actions:
        if not a.option_strings or a.help == argparse.SUPPRESS:
            continue
        repeatable = isinstance(a, (argparse._AppendAction, argparse._CountAction))
        if a.dest in used and not repeatable:
            continue
        for s in a.option_strings:
            if s.startswith("--") or current.startswith("-") and not current.startswith("--"):
                options.append((s, a.help or ""))
    if not current.startswith("-") and any(not a.option_strings and a.dest != "help" for a in p._actions):
        return "values+files", options
    return "values", options


def main(argv: list[str]) -> int:
    index = int(argv[0])
    mode, found = complete(argv[1:], index)
    print(mode)
    for value, help in found:
        print(f"{value}\t{' '.join(help.split())}")
    return 0
