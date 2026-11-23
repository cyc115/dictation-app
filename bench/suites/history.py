"""History bench: what vocabulary does on your own dictations (docs/superpowers/specs/2026-11-22-history-bench-design.md).

  bench/suite.py history run --dry-run           # what it would run and cost; reads no key, sends nothing
  bench/suite.py history run                     # all six parts on your History (cap: --max-cost, default $0.50)
  bench/suite.py history run --parts 3,5,6       # only the free, local parts
  bench/suite.py history run --parts 1 --prompts base --arms off,again   # a cheap part-1 rerun
  bench/suite.py history report [--file …] [--markdown]
  bench/suite.py history report --details        # hits and misses WITH your text: for your eyes only

Reads, read-only, ~/Library/Application Support/DictationApp (--data): history.json, vocabulary.json,
edit-watch.json (and learned-prompts.json, setups.json for the setup's prompt), copied to a temporary
folder first; Recordings/ is read in place. Nothing is written there.

The test set is every dictation with a fix of yours (a correction, or a captured edit you accepted; not
`auto` captures) whose word changes have the judge's verdicts; a mishearing is a change judged misheard.
The app's own code does the work, through HistoryBenchTests (an XCTest skipped unless HISTORY_BENCH_JOB
names a job file): this module snapshots the files, picks the test set, matches recordings, builds the
held-out vocabularies, writes the job, runs the test, scores and reports.

Parts: 1 mishearings fixed (stored raw → replace → cloud polish with terms → replace; 3 rounds, arms
interleaved per dictation), 2 speech with terms (each recording through the on-device model, arms
interleaved per clip; skipped when the model isn't downloaded; echoes the app caught and transcribed again,
and clips whose hinted transcript diverged from the unhinted one), 3 reach and wrong hits (replacement on
every raw and text), 4 wait, 5 what learns (rules vs judge against your Add and Dismiss), 6 edit replay
(each fix through the watcher's two trackers with synthesized keys).

Arms: off (no vocabulary), terms-only (part 1: your terms told to polish, no replacement before or after),
again (your vocabulary as it is: circular on purpose), held-out (without the variants and learned entries
whose only source is the dictation under test; entries you typed stay). Part 2 runs off, again, held-out.
Part 1 runs each arm under two prompts: learned (the setup's active learned prompt, which may know the terms
already) and base (its built-in one); --prompts and --arms pick a subset, and --prompts also takes a built-in
version by name (v4: the setup's model with that version's text). Scores: fixed (your case) and
fixed, any case.

Privacy: only fixed dictations go to the cloud (part 1), with the bench's key ($OPENROUTER_BENCH_API_KEY).
Result files hold your text and stay in bench/results/history/ (git-ignored; never `git add -f` one). The
report printed here has totals only; --details is the local list of hits and misses with text.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import statistics
import subprocess
import tempfile
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

import harness
import openrouter
from suites import polish

NAME = "history"
HELP = "vocabulary on your own History: mishearings fixed, speech, reach, wait, learning, edit replay (read-only)"
DATA = Path.home() / "Library/Application Support/DictationApp"
FIXTURE = harness.ROOT / "history_fixture"
FIXTURE_JOB = FIXTURE / "job.json"
RESULTS = harness.RESULTS / NAME
REPO = harness.ROOT.parent
SNAPSHOT_FILES = ("history.json", "vocabulary.json", "edit-watch.json", "learned-prompts.json", "setups.json")
# Part 1: terms-only is the terms block in polish with no replacement (does polish alone get the term right?).
ARMS = ("off", "terms-only", "again", "held-out")
SPEECH_ARMS = ("off", "again", "held-out")  # part 2 scores the transcript before and after replacement itself
# Part 1's prompts: the setup's active learned prompt (tuned on these same fixes, so it may name the terms
# already), and its built-in one (what it polishes with before any tune).
PROMPTS = ("learned", "base")
SETUPS_SWIFT = REPO / "Sources/DictationKit/Polish/Setups.swift"
POLISH_PROMPTS = harness.ROOT / "polish_prompts"  # each identical to its PolishPrompt version (test_polish checks)
PARTS = (1, 2, 3, 4, 5, 6)
PART_NAMES = {1: "mishearings fixed", 2: "speech with terms", 3: "reach and wrong hits", 4: "wait", 5: "what learns",
              6: "edit replay"}
ROUNDS = 3
# The result file's format, written by `run` and checked by `report`, which reads only this one. Raise it
# when a result's summary or rows change shape.
RESULT_FORMAT = 1
WINDOW = 90  # seconds: a kept recording ends at most this long before its History entry is saved
MAX_COST = 0.50
LEARN_AFTER = 3  # AppSettings.vocabularyLearnAfter's default (test_history checks Settings.swift)
APP_DEFAULTS = "com.mikechen.DictationApp"
SETUP_KEY = "transcriptionModel"  # AppSettings.setupKey: the current setup's id (test_history checks Settings.swift)
FALLBACK_SETUP = "cloud-flash"
# US $ per million tokens (prompt, completion), only from a saved result: DeepSeek V4.1 Flash on Together, the
# provider Cloud Flash pins first (bench/results/edits/20261122-045602_judge-first.json: 426 in, 23 out,
# $0.0001554 = exactly 0.30 and 1.20). Others need --price.
PRICES = {"deepseek/deepseek-v4.1-flash": (0.30, 1.20)}
TEST = "DictationKitTests.HistoryBenchTests/testRunsTheJobItIsGiven"
VOCABULARY_SWIFT = REPO / "Sources/DictationKit/Vocabulary/Vocabulary.swift"


# ---------------------------------------------------------------- words, as the app splits them

# \p{Han} as Swift's Regex reads it (Script_Extensions, so 。、「」 and · count; listed from Swift itself), and
# \s as Unicode's White_Space: Python's re has neither, and WordDiff.words splits on both.
HAN = ("\u00B7\u2E80-\u2E99\u2E9B-\u2EF3\u2F00-\u2FD5\u2FF0-\u2FFF\u3001-\u3003\u3005-\u3011\u3013-\u301F"
       "\u3021-\u302D\u3030\u3037-\u303F\u30FB\u3190-\u319F\u31C0-\u31E5\u31EF\u3220-\u3247\u3280-\u32B0"
       "\u32C0-\u32CB\u32FF\u3358-\u3370\u337B-\u337F\u33E0-\u33FE\u3400-\u4DBF\u4E00-\u9FFF\uA700-\uA707"
       "\uF900-\uFA6D\uFA70-\uFAD9\uFE45-\uFE46\uFF61-\uFF65\U00016FE2-\U00016FE3\U00016FF0-\U00016FF1"
       "\U0001D360-\U0001D371\U0001F250-\U0001F251\U00020000-\U0002A6DF\U0002A700-\U0002B739\U0002B740-\U0002B81D"
       "\U0002B820-\U0002CEA1\U0002CEB0-\U0002EBE0\U0002EBF0-\U0002EE5D\U0002F800-\U0002FA1D\U00030000-\U0003134A"
       "\U00031350-\U000323AF")
SPACE = "\t\n\x0b\x0c\r \x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000"
WORD = re.compile(f"[{HAN}]|[^{SPACE}{HAN}]+")
# FixIntake.edges: sentence punctuation, quotes and brackets (plus spaces and tabs).
EDGES = set(".,;:!?…。，、；：！？\"'“”‘’()[]{}（）「」《》—–")


def words(text: str) -> list[str]:
    """WordDiff.words: a Chinese character each, else a run of non-space characters."""
    return WORD.findall(text or "")


def _edge(c: str) -> bool:
    """FixIntake.edges: the marks above, plus CharacterSet.whitespaces (tab and the space separators)."""
    return c in EDGES or c == "\t" or unicodedata.category(c) == "Zs"


def trim(word: str, left: bool = True, right: bool = True) -> str:
    """`word.trimmingCharacters(in: FixIntake.edges)`, or one side of it."""
    i, j = 0, len(word)
    while left and i < j and _edge(word[i]):
        i += 1
    while right and j > i and _edge(word[j - 1]):
        j -= 1
    return word[i:j]


def count_term(text: str, term: str, any_case: bool = False) -> int:
    """Times `term` stands in `text` as whole words, case as written (or any case). Words are WordDiff's, so a Chinese
    character is a word of its own and a Chinese term matches wherever its characters stand in a row
    (Chinese has no spaces, as FixIntake splits it); a Latin term needs its words whole, with only
    FixIntake's edge punctuation around them ("Claude." counts for Claude, "Claude's" doesn't)."""
    if any_case:
        text, term = text.lower(), term.lower()
    want, have = words(term), words(text)
    k = len(want)
    if not k:
        return 0

    def same(got: list[str]) -> bool:
        if k == 1:
            return trim(got[0]) == trim(want[0])
        return (trim(got[0], right=False) == trim(want[0], right=False) and got[1:-1] == want[1:-1]
                and trim(got[-1], left=False) == trim(want[-1], left=False))

    n = i = 0
    while i + k <= len(have):
        if same(have[i:i + k]):
            n += 1
            i += k
        else:
            i += 1
    return n


def is_fixed(output: str, target: str, new: str, any_case: bool = False) -> bool:
    """A mishearing is fixed when the output has the wanted words at least as often as your fix does: in
    your case, or (`any_case`, the second score) in any case ("Ticketmaster" for your "ticketmaster")."""
    return count_term(output, new, any_case) >= max(1, count_term(target, new, any_case))


def fixed_count(output: str, target: str, changes: list[dict], any_case: bool = False) -> int:
    """How many of a dictation's mishearings come out right. For one wanted word, `is_fixed`; for k
    mishearings wanting the same words, each occurrence beyond those your fix already had elsewhere
    fixes one, so fixing one of two counts one."""
    by_new: dict[str, int] = {}
    for c in changes:
        key = c["new"].lower() if any_case else c["new"]
        by_new[key] = by_new.get(key, 0) + 1
    n = 0
    for new, k in by_new.items():
        already = max(0, count_term(target, new, any_case) - k)  # occurrences in your fix that weren't these changes
        n += min(k, max(0, count_term(output, new, any_case) - already))
    return n


def word_errors(target: str, output: str) -> float:
    """Word errors against your fix (the bench's token error rate: lower case, punctuation dropped)."""
    return harness.error_rate(target, output)


DIVERGED = 0.5  # a hinted transcript this far from the off arm's (word errors, off as the reference) is "diverged"


def diverges(off: str, hinted: str) -> bool:
    """The hinted transcript differs from the same clip's unhinted one by more than half its words: an echo
    the guard didn't recognise, or other damage. Two empty transcripts are alike; text against an empty
    off transcript diverges."""
    return harness.error_rate(off, hinted) > DIVERGED


def case_words(text: str) -> list[str]:
    """Words as written, edges trimmed: what part 3 compares (a case fix counts there)."""
    return [w for w in (trim(w) for w in words(text)) if w]


# ---------------------------------------------------------------- reading the data

def load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def snapshot(data: Path, into: Path) -> Path:
    """Copies the JSON files the run reads into `into`, so the app can keep writing its own. history.json must be there."""
    if not (data / "history.json").exists():
        raise SystemExit(f"no history.json in {data}")
    into.mkdir(parents=True, exist_ok=True)
    for name in SNAPSHOT_FILES:
        if (data / name).exists():
            shutil.copy2(data / name, into / name)
    return into


def uid(value: str) -> str:
    return str(value).upper()


def parse_date(text: str) -> datetime | None:
    try:
        found = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    return found if found.tzinfo else found.replace(tzinfo=timezone.utc)


def fix_of(entry: dict) -> str | None:
    """The fix the test set takes: a correction (yours, or a captured edit you accepted); none for an `auto` capture."""
    correction = entry.get("correction")
    if not isinstance(correction, str) or not correction.strip():
        return None
    if (entry.get("capture") or {}).get("state") == "auto":
        return None
    return correction


def test_set(history: list[dict], limit: int | None = None) -> list[dict]:
    """Fixed dictations whose word changes (worked out from that fix) have the judge's verdicts, newest first."""
    found = []
    for entry in history:
        target = fix_of(entry)
        intake = entry.get("intake") or {}
        if target is None or intake.get("of") != target:
            continue
        if any(c.get("verdict") for c in intake.get("changes") or []):
            found.append(entry)
    return found[:limit] if limit else found


def mishearings(entry: dict) -> list[dict]:
    return [c for c in (entry.get("intake") or {}).get("changes") or [] if c.get("verdict") == "misheard"]


def recordings(folder: Path) -> list[dict]:
    """Kept recordings with their WAV: the sidecar's fields plus `wav` and a parsed `when`."""
    found = []
    for meta_path in sorted(folder.glob("*.json")) if folder.is_dir() else []:
        meta, wav = load(meta_path, None), meta_path.with_suffix(".wav")
        if not isinstance(meta, dict) or not wav.exists() or meta.get("error"):
            continue
        when = parse_date(meta.get("date", ""))
        if when is not None:
            found.append({**meta, "wav": wav, "when": when})
    return found


def match_recordings(entries: list[dict], kept: list[dict], window: float = WINDOW) -> dict[str, Path]:
    """Entry id → its recording. The sidecar has no dictation id: it's one that ended at most `window`
    seconds before the entry was saved, with the same polished text, or the same transcript as the
    entry's raw (or text). The nearest one wins; each recording goes to one entry."""
    used: set[Path] = set()
    out: dict[str, Path] = {}
    for entry in entries:
        when = parse_date(entry.get("date", ""))
        if when is None:
            continue
        texts = {entry.get("raw"), entry.get("text")} - {None}
        near = [r for r in kept if r["wav"] not in used and 0 <= (when - r["when"]).total_seconds() <= window
                and (r.get("polished") == entry.get("text") or r.get("transcript") in texts)]
        if near:
            best = min(near, key=lambda r: (when - r["when"]).total_seconds())
            used.add(best["wav"])
            out[uid(entry["id"])] = best["wav"]
    return out


# ---------------------------------------------------------------- vocabularies per arm

def fix_target(entry: dict) -> str | None:
    """HistoryEntry.fixTarget: your correction, else a captured edit you haven't dismissed."""
    if isinstance(entry.get("correction"), str):
        return entry["correction"]
    capture = entry.get("capture") or {}
    return capture.get("edited") if capture.get("edited") and capture.get("state") != "dismissed" else None


class Sources:
    """Where each vocabulary term and variant came from: the fixed dictations whose word changes (worked out
    from their current fix) have that heard and that term, compared as the app does (edges trimmed, any
    case), together with the candidates' `dictations`. History is needed too: a candidate that stops
    counting (say, under the shape rule) is kept in vocabulary.json with `heard: []`, and says nothing."""

    def __init__(self, vocabulary: dict, history: list[dict]):
        self.pairs: dict[tuple[str, str], set[str]] = {}  # (heard, term), lowered → dictations
        self.terms: dict[str, set[str]] = {}  # term, lowered → dictations
        for entry in history:
            target, intake = fix_target(entry), entry.get("intake") or {}
            if target is None or intake.get("of") != target:
                continue
            for c in intake.get("changes") or []:
                self._add(trim(str(c.get("old", ""))), trim(str(c.get("new", ""))), [entry["id"]])
        for c in vocabulary.get("candidates") or []:
            for heard in c.get("heard") or []:
                self._add(str(heard.get("text", "")), str(c.get("term", "")), heard.get("dictations") or [])

    def _add(self, heard: str, term: str, dictations: list[str]) -> None:
        ids = {uid(d) for d in dictations}
        self.pairs.setdefault((heard.lower(), term.lower()), set()).update(ids)
        self.terms.setdefault(term.lower(), set()).update(ids)

    def of_variant(self, heard: str, term: str) -> set[str]:
        return self.pairs.get((heard.lower(), term.lower()), set())

    def of_entry(self, entry: dict) -> set[str]:
        """Every dictation that fixed something to this term, by any heard."""
        return self.terms.get(str(entry.get("term", "")).lower(), set())


def unsourced(vocabulary: dict, history: list[dict]) -> int:
    """Learned entries with no known source anywhere: held out keeps them (nothing says which dictation taught them)."""
    sources = Sources(vocabulary, history)
    return sum(1 for e in vocabulary.get("entries") or [] if e.get("source") == "learned" and not sources.of_entry(e))


def held_out(vocabulary: dict, dictation: str, history: list[dict], sources: Sources | None = None) -> list[dict]:
    """Your vocabulary without what only `dictation` taught it: every variant whose only source is that
    dictation (on any entry: a variant handed to an entry you typed was learned too), and every learned
    entry whose only source is that dictation. Entries you typed stay, and so does a learned entry or
    variant with no known source (`unsourced` counts those)."""
    me = uid(dictation)
    sources = sources or Sources(vocabulary, history)
    out = []
    for entry in vocabulary.get("entries") or []:
        if entry.get("source") == "learned" and sources.of_entry(entry) == {me}:
            continue
        kept = dict(entry)
        kept["heardAs"] = [v for v in entry.get("heardAs") or [] if sources.of_variant(v, entry.get("term", "")) != {me}]
        out.append(kept)
    return out


# ---------------------------------------------------------------- the job

def schedule_polish(ids: list[str], rounds: int, seed: int, arms: tuple[str, ...] = ARMS,
                    prompts: tuple[str, ...] = PROMPTS) -> list[dict]:
    """Every dictation × prompt × arm once a round; each dictation's trials back to back in a seeded order, so a
    slow minute on the network hits all prompts and arms alike."""
    out = []
    for rnd in range(1, rounds + 1):
        for d in ids:
            trials = [(prompt, arm) for prompt in prompts for arm in arms]
            random.Random(f"{seed}:{rnd}:{d}").shuffle(trials)
            out += [{"round": rnd, "id": d, "prompt": prompt, "arm": arm} for prompt, arm in trials]
    return out


def schedule_speech(ids: list[str], seed: int) -> list[dict]:
    out = []
    for d in ids:
        arms = list(SPEECH_ARMS)
        random.Random(f"{seed}:speech:{d}").shuffle(arms)
        out += [{"id": d, "arm": arm} for arm in arms]
    return out


def build_job(folder: Path, chosen: list[dict], kept: dict[str, Path], parts: list[int], rounds: int, seed: int,
              setup: str, max_cost: float, learn_after: int, relative_to: Path | None = None,
              arms: tuple[str, ...] = ARMS, prompts: tuple[str, ...] = PROMPTS) -> dict:
    """The job HistoryBenchTests runs. Paths are absolute, or relative to the job file (`relative_to`)."""
    def path(p: Path | None) -> str | None:
        if p is None:
            return None
        return os.path.relpath(p, relative_to) if relative_to else str(p)

    vocabulary = load(folder / "vocabulary.json", {})
    history = load(folder / "history.json", [])
    sources = Sources(vocabulary, history)
    ids = [uid(e["id"]) for e in chosen]
    speech_ids = [d for d in ids if d in kept]
    return {
        "version": 1,
        "history": path(folder / "history.json"),
        "vocabulary": path(folder / "vocabulary.json"),
        "learnedPrompts": path(folder / "learned-prompts.json") if (folder / "learned-prompts.json").exists() else None,
        "setups": path(folder / "setups.json") if (folder / "setups.json").exists() else None,
        "setup": setup,
        "maxCost": max_cost,
        "learnAfter": learn_after,
        "learnedWithoutSource": unsourced(vocabulary, history),
        "parts": sorted(parts),
        "arms": list(arms),
        "prompts": list(prompts),
        "dictations": [{"id": d, "heldOut": held_out(vocabulary, d, history, sources), "recording": path(kept.get(d))} for d in ids],
        "polish": schedule_polish(ids, rounds, seed, arms, prompts) if 1 in parts else [],
        "speech": schedule_speech(speech_ids, seed) if 2 in parts else [],
    }


# ---------------------------------------------------------------- setup and estimate

def current_setup(data: Path) -> str:
    """The app's current setup, from its settings, when reading the app's own folder; else Cloud Flash."""
    if data.resolve() != DATA.resolve():
        return FALLBACK_SETUP
    try:
        found = subprocess.run(["defaults", "read", APP_DEFAULTS, SETUP_KEY], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        found = ""
    return found or FALLBACK_SETUP


def builtin_versions(swift: Path = SETUPS_SWIFT) -> tuple[str, ...]:
    """The keys of PolishPrompt.versions, read from the app's source: what --prompts takes besides learned and base."""
    found = re.search(r"static let versions = \[(.*?)\]", swift.read_text())
    if not found:
        raise SystemExit(f"PolishPrompt.versions not found in {swift}: update history.builtin_versions")
    return tuple(sorted(re.findall(r'"([^"]+)"\s*:', found.group(1)), key=_prompt_order))


def replaced_setups(swift: Path = SETUPS_SWIFT) -> dict[str, str]:
    """DictationSetup.replaced, read from the app's source: built-in setup ids that are gone, and the one in their place."""
    found = re.search(r"static let replaced = \[(.*?)\]", swift.read_text())
    if not found:
        raise SystemExit(f"DictationSetup.replaced not found in {swift}: update history.replaced_setups")
    return dict(re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"', found.group(1)))


def prompt_of(setup: dict, name: str) -> dict | None:
    """{version, text} of one of part 1's prompts: learned, base, or a built-in version by name (its text from
    bench/polish_prompts, for the estimate only: the harness sends the app's own)."""
    if name in ("learned", "base"):
        return setup[name]
    path = POLISH_PROMPTS / f"{name}.txt"
    return {"version": name, "text": path.read_text().strip() if path.exists() else ""}


def prompt_label(name: str, version: str | None) -> str:
    return f"{name} (built-in)" if name not in ("learned", "base") else f"{name} ({version})"


def resolve_setup(setup_id: str, folder: Path) -> dict:
    """What part 1 polishes with, as the harness picks it: the setup (built-in or in setups.json) with its
    active learned prompt; Cloud Flash's when that setup polishes on this Mac."""
    known = polish.setups(folder / "setups.json")
    replaced = replaced_setups()
    setup = known.get(replaced.get(setup_id, setup_id)) or known[FALLBACK_SETUP]
    fell_back = setup["polish"] == "apple"
    if fell_back:
        setup = known[FALLBACK_SETUP]
    # Learned: LearnedPromptStore.active(for:), a version that's also among the prompts. Base: the setup as read.
    learned_file = load(folder / "learned-prompts.json", {})
    version = (learned_file.get("active") or {}).get(setup["id"])
    text = next((p["text"] for p in learned_file.get("prompts") or [] if p.get("version") == version), None) if version else None
    try:
        base_text = polish.prompt_text(setup["prompt"], folder / "learned-prompts.json")
    except (SystemExit, OSError):
        base_text = ""
    spec = setup["polish"].removeprefix("openrouter:")
    return {"id": setup["id"], "asked": setup_id, "fellBack": fell_back,
            "learned": {"version": version, "text": text} if text is not None else None,
            "base": {"version": setup["prompt"], "text": base_text},
            "model": spec.split("@")[0], "polish": setup["polish"], "wrap": setup.get("wrap", True)}


def prompt_header(swift: Path = VOCABULARY_SWIFT) -> str:
    """Vocabulary.promptHeader, read from the app's source (the estimate's only use; the harness sends the app's own)."""
    found = re.search(r'static let promptHeader = "((?:[^"\\]|\\.)*)"', swift.read_text())
    if not found:
        raise SystemExit(f"Vocabulary.promptHeader not found in {swift}: update history.prompt_header")
    return found.group(1)


def terms_tokens(entries: list[dict]) -> int:
    """Vocabulary.promptBlock's size, roughly: the header and the enabled terms (at most 100)."""
    terms = [e["term"] for e in entries if e.get("enabled", True) and str(e.get("term", "")).strip()][:100]
    return harness.estimate_tokens(prompt_header()) + sum(harness.estimate_tokens(t) + 1 for t in terms) if terms else 0


def estimate(job: dict, history: list[dict], vocabulary: dict, setup: dict, prices: dict) -> dict:
    """Calls per part, and part 1's tokens and cost (None: the polish model's price isn't known)."""
    by_id = {uid(e["id"]): e for e in history}
    held = {d["id"]: d["heldOut"] for d in job["dictations"]}
    prompt = {p: harness.estimate_tokens((prompt_of(setup, p) or {}).get("text") or "") for p in job["prompts"]}
    again = terms_tokens(vocabulary.get("entries") or [])
    tokens_in = tokens_out = 0
    for trial in job["polish"]:
        entry = by_id[trial["id"]]
        block = {"off": 0, "terms-only": again, "again": again, "held-out": terms_tokens(held[trial["id"]])}[trial["arm"]]
        tokens_in += prompt[trial["prompt"]] + block + harness.estimate_tokens(entry.get("raw") or entry["text"]) + 20  # tags + framing
        tokens_out += harness.estimate_tokens(entry.get("correction") or entry["text"])
    price = prices.get(setup["model"])
    cost = None if price is None else (tokens_in * price[0] + tokens_out * price[1]) / 1e6
    clips = len({t["id"] for t in job["speech"]})
    return {"polish_calls": len(job["polish"]), "tokens_in": tokens_in, "tokens_out": tokens_out, "cost": cost,
            "speech_runs": len(job["speech"]), "clips": clips, "model": setup["model"]}


def plan_text(job: dict, plan: dict, setup: dict, counts: dict, rounds: int) -> str:
    """The dry run: counts only, no text."""
    n = len(job["dictations"])
    lines = [f"==> {counts['entries']:,} dictations, {counts['fixed']} fixed (the test set), {counts['mishearings']} mishearings; "
             f"{counts['recorded']} with a kept recording; {job.get('learnedWithoutSource', 0)} learned entries with no known source "
             "(kept in held out)"]
    parts = job["parts"]
    if 1 in parts:
        cost = ("price unknown: pass --price MODEL=IN,OUT ($ per million tokens)" if plan["cost"] is None
                else f"≈ ${plan['cost']:.4f} (an upper estimate: the pinned host's list price, no cache; the Nov 22 run cost about a third of its estimate)")
        prompts = " and ".join(prompt_label(p, prompt_of(setup, p)["version"]) for p in job["prompts"])
        lines.append(f"  part 1  {PART_NAMES[1]:<22} {plan['polish_calls']} polish calls ({n} × {len(job['arms'])} arms × "
                     f"{len(job['prompts'])} prompts × {rounds} rounds), setup {setup['id']}"
                     f"{' (yours polishes on this Mac)' if setup['fellBack'] else ''}, prompts {prompts}, arms {', '.join(job['arms'])}, "
                     f"{setup['model']}; ≈ {plan['tokens_in']:,} tokens in, {plan['tokens_out']:,} out: {cost}")
        if counts.get("noLearned"):
            lines.append(f"          {setup['id']} has no learned prompt active: part 1 runs the base prompt in its place")
        for name, same in (counts.get("promptsSameAs") or {}).items():
            lines.append(f"          {name} is the {same} prompt: run once, as {same}")
    if 2 in parts:
        lines.append(f"  part 2  {PART_NAMES[2]:<22} {plan['speech_runs']} on-device transcriptions ({plan['clips']} clips × {len(SPEECH_ARMS)} arms), "
                     "$0 (skipped at run time if the model isn't downloaded)")
    for p in (3, 4, 5, 6):
        if p in parts:
            what = {3: f"replacement on all {counts['entries']:,} dictations", 4: "replacement timed; polish and speech wait from parts 1 and 2",
                    5: "candidates by the rules vs the judge", 6: f"{n} fixes × 2 trackers"}[p]
            lines.append(f"  part {p}  {PART_NAMES[p]:<22} {what}, $0")
    total = plan["cost"] or 0.0
    lines.append(f"  estimated total ≈ ${total:.4f} (cap ${job['maxCost']:.2f})" + ("" if plan["cost"] is not None or 1 not in parts else " + part 1 unpriced"))
    return "\n".join(lines)


# ---------------------------------------------------------------- running the harness

def run_harness(job_path: Path, out_path: Path, key: str | None, log: Path) -> int:
    """Builds the tests and runs HistoryBenchTests on the job; rows land in `out_path` as they come. The key
    goes only in the test's environment (HISTORY_BENCH_KEY), never in the job file."""
    print("    building the tests (swift build --build-tests)…", flush=True)
    with log.open("w") as f:
        built = subprocess.run(["swift", "build", "--build-tests"], cwd=REPO, stdout=f, stderr=subprocess.STDOUT)
    if built.returncode:
        print(log.read_text()[-3000:])
        raise SystemExit("the tests didn't build")
    bundles = sorted((REPO / ".build/debug").glob("*.xctest"))
    if not bundles:
        raise SystemExit("no .xctest bundle in .build/debug")
    env = {k: v for k, v in os.environ.items() if k not in ("OPENROUTER_API_KEY", "HISTORY_BENCH_KEY")}
    env |= {"HISTORY_BENCH_JOB": str(job_path), "HISTORY_BENCH_OUT": str(out_path)}
    if key:
        env["HISTORY_BENCH_KEY"] = key
    proc = subprocess.Popen(["xcrun", "xctest", "-XCTest", TEST, str(bundles[0])], cwd=REPO, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    with log.open("a") as f:
        for line in proc.stdout:
            f.write(line)
            if line.startswith("[history]"):  # progress lines carry counts only
                print("   ", line.rstrip(), flush=True)
    return proc.wait()


def read_rows(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text().splitlines() if path.exists() else []:
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
    return rows


# ---------------------------------------------------------------- scoring

def _prompt_order(name: str) -> tuple:
    """learned, base, then the built-in versions by number."""
    return (PROMPTS.index(name), 0, "") if name in PROMPTS else (len(PROMPTS), int(name[1:]) if name[1:].isdigit() else 10**6, name)


def _spread(values: list[float]) -> dict:
    return {"mean": round(statistics.fmean(values), 4), "min": round(min(values), 4), "max": round(max(values), 4)} if values else None


def _wait(values: list[float]) -> dict:
    return {"n": len(values), "p50": harness.percentile(values, 50), "p95": harness.percentile(values, 95)}


def score(rows: list[dict], edit_watch: dict, vocabulary: dict, learn_after: int) -> dict:
    """Totals from the harness's rows. Every count, no text."""
    dictations = {r["id"]: r for r in rows if r.get("part") == 0 and r.get("kind") == "dictation" and "error" not in r}
    misheard = {d: [c for c in r["changes"] if c.get("verdict") == "misheard"] for d, r in dictations.items()}
    done = next((r for r in rows if r.get("kind") == "done"), {})
    # A harness that died before its last row still spent what its part 1 rows say.
    spent = done.get("cost", sum(r.get("cost") or 0.0 for r in rows if r.get("part") == 1 and "arm" in r))
    out: dict = {"cost": spent, "stopped": done.get("stopped", False), "finished": bool(done),
                 "setup": next(({k: r.get(k) for k in ("setup", "prompt", "learnedPrompt", "basePrompt", "polish", "fellBack")}
                                for r in rows if r.get("kind") == "setup"), None),
                 "dictations": len(dictations), "mishearings": sum(len(v) for v in misheard.values()),
                 "changes": sum(len(r["changes"]) for r in dictations.values()), "parts": {}}

    parts = out["parts"]  # in part order, only the parts that ran
    for n, part in ((1, _score_part1(rows, dictations, misheard)), (2, _score_part2(rows, dictations, misheard)), (3, _score_part3(rows))):
        if part is not None:
            parts[n] = part
    for n, part in ((4, _score_part4(rows, parts)), (5, _score_part5(rows, vocabulary, learn_after)), (6, _score_part6(rows, edit_watch))):
        if part is not None:
            parts[n] = part
    return out


def _score_part1(rows: list[dict], dictations: dict, misheard: dict) -> dict | None:
    """Part 1: per prompt, arm and round, mishearings fixed (your case, and any case) and word errors against the fix."""
    p1 = [r for r in rows if r.get("part") == 1 and "arm" in r]
    if not p1 and not any(r.get("part") == 1 for r in rows):
        return None
    by_prompt = {}
    for prompt in dict.fromkeys(r["prompt"] for r in sorted(p1, key=lambda r: _prompt_order(r["prompt"]))):
        sel = [r for r in p1 if r["prompt"] == prompt]
        arms_run = [a for a in ARMS if any(r["arm"] == a for r in sel)]
        # Only whole rounds count toward fixed and word errors: one cut short by the cost cap would drag the mean down.
        trials = {(r["round"], r["id"], r["arm"]) for r in sel}
        # Whole: every dictation in the job got every arm that round (not only the ones that ran before a stop).
        whole = {rnd for rnd in {t[0] for t in trials} if all((rnd, d, a) in trials for d in dictations for a in arms_run)}
        arms = {}
        for arm in arms_run:
            fixed_by_round, any_case_by_round, wer_by_round, secs, errors = {}, {}, {}, [], 0
            for r in (r for r in sel if r["arm"] == arm):
                d = dictations.get(r["id"])
                errors += d is not None and bool(r.get("error"))
                if d is not None and not r.get("error"):
                    secs.append(r["seconds"])
                if d is None or r["round"] not in whole:
                    continue
                # Any case never scores below your case (an "already" in another case could otherwise lower it).
                strict_here = fixed_count(r["output"], d["target"], misheard[r["id"]])
                any_here = max(strict_here, fixed_count(r["output"], d["target"], misheard[r["id"]], any_case=True))
                any_case_by_round[r["round"]] = any_case_by_round.get(r["round"], 0) + any_here
                fixed_by_round[r["round"]] = fixed_by_round.get(r["round"], 0) + strict_here
                wer_by_round.setdefault(r["round"], []).append(word_errors(d["target"], r["output"]))
            arms[arm] = {"fixed": _spread(list(fixed_by_round.values())), "fixedAnyCase": _spread(list(any_case_by_round.values())),
                         "word_errors": _spread([statistics.fmean(v) for v in wer_by_round.values()]),
                         "rounds": len(fixed_by_round), "errors": errors, "seconds": _wait(secs)}
        by_prompt[prompt] = {"arms": arms, "wholeRounds": len(whole), "calls": len(sel)}
    ran = {r["id"] for r in p1}
    skipped = next((r.get("reason") for r in rows if r.get("part") == 1 and r.get("kind") == "skipped"), None)
    return {"of": sum(len(misheard[d]) for d in ran if d in misheard), "dictations": len(ran), "prompts": by_prompt,
            "calls": len(p1), "skipped": skipped}


def _score_part2(rows: list[dict], dictations: dict, misheard: dict) -> dict | None:
    """Part 2: per arm, mishearings right in the delivered transcript (the second pass, when the app caught
    the model writing its context back), and after the arm's replacement; seconds (both passes); echoes
    caught; and, whatever the guard knows, clips whose hinted transcript diverged from the off arm's."""
    p2 = [r for r in rows if r.get("part") == 2]
    if not p2:
        return None
    skipped = next((r.get("reason") for r in p2 if r.get("kind") == "skipped"), None)
    runs = [r for r in p2 if "arm" in r]
    off = {r["id"]: r["transcript"] for r in runs if r["arm"] == "off" and not r.get("error")}
    arms = {}
    for arm in SPEECH_ARMS:
        sel = [r for r in runs if r["arm"] == arm and r["id"] in dictations]
        ok = [r for r in sel if not r.get("error")]
        arms[arm] = {"transcript": sum(fixed_count(r["transcript"], dictations[r["id"]]["target"], misheard[r["id"]]) for r in ok),
                     "replaced": sum(fixed_count(r["replaced"], dictations[r["id"]]["target"], misheard[r["id"]]) for r in ok),
                     "replacedAnyCase": sum(fixed_count(r["replaced"], dictations[r["id"]]["target"], misheard[r["id"]], any_case=True) for r in ok),
                     "errors": len(sel) - len(ok), "seconds": _wait([r["seconds"] for r in ok]),
                     "echoes": sum(bool(r["echoed"]) for r in ok)}
        if arm != "off":
            compared = [r for r in ok if r["id"] in off]
            arms[arm]["diverged"] = sorted(r["id"] for r in compared if diverges(off[r["id"]], r["transcript"]))
            arms[arm]["comparedWithOff"] = len(compared)
    clips = {r["id"] for r in runs}
    return {"skipped": skipped, "clips": len(clips), "of": sum(len(misheard.get(d, [])) for d in clips), "arms": arms}


def _score_part3(rows: list[dict]) -> dict | None:
    """Part 3: what replacement alone touches."""
    p3 = [r for r in rows if r.get("part") == 3]
    if not p3:
        return None
    summary = next((r for r in p3 if r.get("kind") == "summary"), {})
    hits = [r for r in p3 if r.get("kind") == "hit"]
    entries = [r for r in p3 if r.get("kind") == "entry"]
    per_entry: dict[str, int] = {}
    for r in hits:
        for e, n in (r.get("uses") or {}).items():
            per_entry[e] = per_entry.get(e, 0) + n
    away = toward = same = 0
    for r in hits:
        if r.get("target") and r.get("textChanged"):
            before = harness.edit_distance(case_words(r["target"]), case_words(r["text"]))
            after = harness.edit_distance(case_words(r["target"]), case_words(r["replacedText"]))
            away += after > before
            toward += after < before
            same += after == before
    flagged = {"caseOnly": [e["entry"] for e in entries if any(v["caseOnly"] for v in e["variants"])],
               "ordinary": [e["entry"] for e in entries if any(v["ordinary"] for v in e["variants"])]}
    counts = sorted(per_entry.values())
    return {"entries": summary.get("entries", 0), "withRaw": summary.get("withRaw", 0),
            "changedRaw": sum(bool(r.get("rawChanged")) for r in hits), "changedText": sum(bool(r.get("textChanged")) for r in hits),
            "changed": len(hits), "hits": sum(counts), "vocabularyEntries": len(entries),
            "entriesWithHits": len(counts), "hitsPerEntry": {"median": statistics.median(counts) if counts else 0, "max": max(counts, default=0)},
            "fixedTouched": sum(1 for r in hits if r.get("target") and r.get("textChanged")),
            "awayFromFix": away, "towardFix": toward, "sameDistance": same,
            "flagged": {k: len(v) for k, v in flagged.items()},
            "flaggedHits": {k: sum(per_entry.get(e, 0) for e in v) for k, v in flagged.items()}}


def _score_part4(rows: list[dict], scored: dict) -> dict | None:
    """Part 4: wait. Replacement timed in the harness; polish and speech from parts 1 and 2 (`scored`, by part)."""
    p4 = next((r for r in rows if r.get("part") == 4 and r.get("kind") == "replacement"), None)
    if p4 is None:
        return None
    wait = {"replacement": {**_wait(p4["seconds"]), "build": p4.get("build")}}

    def changes(arms: dict) -> dict:
        off = (arms.get("off") or {}).get("seconds") or {}
        def change(arm: str, q: str):
            mine, base = arms[arm]["seconds"][q], off.get(q)
            return None if mine is None or base is None else mine - base
        return {arm: {**arms[arm]["seconds"], "p50_change": change(arm, "p50"), "p95_change": change(arm, "p95")} for arm in arms}

    polish_prompts = (scored.get(1) or {}).get("prompts") or {}
    if polish_prompts:
        wait["polish"] = {prompt: changes(v["arms"]) for prompt, v in polish_prompts.items()}
    speech_arms = (scored.get(2) or {}).get("arms")
    if speech_arms:
        wait["speech"] = changes(speech_arms)
    return wait


def _score_part5(rows: list[dict], vocabulary: dict, learn_after: int) -> dict | None:
    """Part 5: candidates by the rules alone and by the judge, against your Add and Dismiss."""
    p5 = {r["method"]: r["candidates"] for r in rows if r.get("part") == 5}
    if not p5:
        return None
    cands = vocabulary.get("candidates") or []
    added = {str(c["term"]).lower() for c in cands if c.get("added") and not c.get("dismissed")}
    dismissed = {str(c["term"]).lower() for c in cands if c.get("dismissed")}
    methods = {}
    for method, found in p5.items():
        proposed = {str(c["term"]).lower(): c for c in found}
        learn = {t for t, c in proposed.items() if c.get("seen", 0) >= learn_after}
        methods[method] = {"candidates": len(proposed), "wouldLearn": len(learn),
                           "added": {"proposed": len(added & proposed.keys()), "wouldLearn": len(added & learn)},
                           "dismissed": {"proposed": len(dismissed & proposed.keys()), "wouldLearn": len(dismissed & learn)}}
    return {"added": len(added), "dismissed": len(dismissed), "learnAfter": learn_after, "methods": methods}


def _score_part6(rows: list[dict], edit_watch: dict) -> dict | None:
    """Part 6: fixes rebuilt exactly, per tracker; text that needs an input method apart for keystrokes."""
    p6 = [r for r in rows if r.get("part") == 6]
    if not p6:
        return None
    rb = [r for r in p6 if r["mode"] == "readback"]
    ks = [r for r in p6 if r["mode"] == "keystrokes"]
    typed, ime = [r for r in ks if not r["needsInputMethod"]], [r for r in ks if r["needsInputMethod"]]
    apps = edit_watch if isinstance(edit_watch, dict) else {}
    edge = lambda sel: sum(1 for r in sel if not r["exact"] and r.get("pastTheEdge"))  # noqa: E731
    return {"readback": {"exact": sum(r["exact"] for r in rb), "of": len(rb), "captured": sum(r["captured"] for r in rb),
                         "missesPastTheEdge": edge(rb)},
            "keystrokes": {"exact": sum(r["exact"] for r in typed), "of": len(typed), "captured": sum(r["captured"] for r in typed),
                           "missesPastTheEdge": edge(typed), "inputMethod": len(ime), "inputMethodExact": sum(r["exact"] for r in ime)},
            "app": {"apps": len(apps), **{k: sum(int((a or {}).get(k, 0)) for a in apps.values()) for k in ("armed", "probesFailed", "gaveUp")}}}


# ---------------------------------------------------------------- reports

def _range(s: dict | None, pct: bool = False) -> str:
    if not s:
        return "—"
    f = (lambda x: f"{100 * x:.1f}%") if pct else (lambda x: f"{x:g}")
    return f"{f(s['mean'])} ({f(s['min'])}–{f(s['max'])})" if s["min"] != s["max"] else f(s["mean"])


def _s(x) -> str:
    return "—" if x is None else f"{x:.2f}"


def _delta(x) -> str:
    return "—" if x is None else f"{x:+.2f}"


def _unsourced_note(cfg: dict) -> list[str]:
    n = cfg.get("learnedWithoutSource") or 0
    return [f"  {n} learned entries with no known source: kept in held out"] if n else []


def _edge_note(tracker: dict) -> str:
    n = tracker.get("missesPastTheEdge", 0)
    return f" ({n} of the misses add text before or after the paste: never the span's, by design)" if n else ""


def report_text(result: dict, markdown: bool = False) -> str:
    """Totals only: no dictation text, no term, no snippet. Safe to paste into a write-up."""
    s = result["summary"]
    cfg = result["config"]
    env = result.get("env", {})
    setup = s.get("setup") or {}
    lines = [f"{result['run_at']}  commit {env.get('commit', '?')}  {s['dictations']} fixed dictations, {s['changes']} changes, "
             f"{s['mishearings']} mishearings; parts {','.join(map(str, cfg['parts']))}; cost ${s['cost']:.4f} (cap ${cfg['maxCost']:.2f})"]
    if s.get("stopped"):
        lines.append("!! stopped sending at the cost cap: part 1 has the rows up to that point")
    if not s.get("finished"):
        lines.append("!! the harness didn't finish: the parts below have what it wrote before it stopped")
    # A result read back from its file has the part numbers as strings: one lookup by number either way.
    parts = {int(n): v for n, v in s["parts"].items()}
    for n, report in ((1, _report_part1), (2, _report_part2), (3, _report_part3), (4, _report_part4), (5, _report_part5), (6, _report_part6)):
        if n in parts:
            lines += report(parts[n], setup, cfg, markdown)
    return "\n".join(lines)


def _report_part1(v: dict, setup: dict, cfg: dict, markdown: bool) -> list[str]:
    """Part 1, mishearings fixed: its lines in the report."""
    lines = ["", f"Part 1, mishearings fixed (setup {setup.get('setup')}, {setup.get('polish')}"
             f"{'; yours polishes on this Mac' if setup.get('fellBack') or cfg.get('setupFellBack') else ''}): of {v['of']} in {v['dictations']} dictations"]
    if v.get("skipped"):
        lines.append(f"  skipped: {v['skipped']}")
    lines += _unsourced_note(cfg)
    if "learned" in (cfg.get("promptsAsked") or []) and "learned" not in (cfg.get("prompts") or []):
        lines.append(f"  {setup.get('setup')} has no learned prompt active: the base prompt in its place")
    for name, same in (cfg.get("promptsSameAs") or {}).items():
        lines.append(f"  {name} is the {same} prompt: run once, as {same}")
    prompts = v["prompts"]
    if len({pv.get("wholeRounds") for pv in prompts.values()}) > 1:
        lines.append("  !! the prompts have different numbers of whole rounds (a stop at the cap): compare with care")
    for prompt, pv in prompts.items():
        version = {"learned": setup.get("learnedPrompt"), "base": setup.get("basePrompt")}.get(prompt)
        rows = [[arm, _range(a["fixed"]), _range(a["fixedAnyCase"]), _range(a["word_errors"], pct=True), a["rounds"], a["errors"] or "",
                 _s(a["seconds"]["p50"]), _s(a["seconds"]["p95"])] for arm, a in pv["arms"].items()]
        lines += [f"  prompt: {prompt_label(prompt, version)}",
                  harness.table(["arm", "fixed (mean, range)", "fixed, any case", "word errors vs fix", "rounds", "errors", "polish p50 s", "p95 s"],
                                rows, markdown)]
    return lines


def _report_part2(v: dict, setup: dict, cfg: dict, markdown: bool) -> list[str]:
    """Part 2, speech with terms: its lines in the report."""
    lines = ["", f"Part 2, speech with terms (on-device): of {v['of']} mishearings in {v['clips']} recordings"]
    if v.get("skipped"):
        lines.append(f"  skipped: {v['skipped']}")
    else:
        lines += _unsourced_note(cfg)
        rows = [[arm, a["transcript"], a["replaced"], a["replacedAnyCase"], a["echoes"],
                 f"{len(a['diverged'])} of {a['comparedWithOff']}" if "diverged" in a else "—",
                 a["errors"] or "", _s(a["seconds"]["p50"]), _s(a["seconds"]["p95"])]
                for arm, a in v["arms"].items()]
        lines.append(harness.table(["arm", "right in transcript", "after replacement", "after, any case", "echoes caught",
                                    "diverged from off", "errors", "p50 s", "p95 s"], rows, markdown))
        lines.append("  right in transcript: the text delivered (after the second pass when the model echoed its context); "
                     f"diverged: hinted transcript over {DIVERGED:.0%} word errors from the same clip's off transcript "
                     "(ids in the result file)")
    return lines


def _report_part3(v: dict, setup: dict, cfg: dict, markdown: bool) -> list[str]:
    """Part 3, reach and wrong hits: its lines in the report."""
    return ["", f"Part 3, reach and wrong hits (replacement alone, your vocabulary): {v['changed']} of {v['entries']:,} dictations changed "
            f"({v['changedRaw']} raw of {v['withRaw']:,}, {v['changedText']} pasted text); {v['hits']} hits from {v['entriesWithHits']} "
            f"of {v['vocabularyEntries']} entries (median {v['hitsPerEntry']['median']}, most {v['hitsPerEntry']['max']})",
            f"  fixed dictations whose pasted text it changes: {v['fixedTouched']}; moved away from the fix {v['awayFromFix']}, "
            f"toward it {v['towardFix']}, neither {v['sameDistance']}",
            f"  flagged entries: {v['flagged']['caseOnly']} with a case-only variant ({v['flaggedHits']['caseOnly']} hits), "
            f"{v['flagged']['ordinary']} with an ordinary-word variant ({v['flaggedHits']['ordinary']} hits)"]


def _report_part4(v: dict, setup: dict, cfg: dict, markdown: bool) -> list[str]:
    """Part 4, wait: its lines in the report."""
    r = v["replacement"]
    lines = ["", f"Part 4, wait: replacement before + after polish, per dictation: p50 {1e6 * (r['p50'] or 0):.0f} µs, "
             f"p95 {1e6 * (r['p95'] or 0):.0f} µs (n={r['n']}, {r.get('build')} build)"]

    def wait_table(label: str, arms: dict) -> list[str]:
        rows = [[arm, _s(a["p50"]), _s(a["p95"]), _delta(a["p50_change"]), _delta(a["p95_change"])] for arm, a in arms.items()]
        return [f"  {label}, seconds (change vs off):", harness.table(["arm", "p50", "p95", "p50 change", "p95 change"], rows, markdown)]

    for prompt, arms in (v.get("polish") or {}).items():
        lines += wait_table(f"polish, prompt {prompt}", arms)
    if "speech" in v:
        lines += wait_table("on-device speech", v["speech"])
    return lines


def _report_part5(v: dict, setup: dict, cfg: dict, markdown: bool) -> list[str]:
    """Part 5, what learns: its lines in the report."""
    lines = ["", f"Part 5, what learns: of the {v['added']} terms added (by you, or learned after {v['learnAfter']} dictations: "
             f"the file doesn't tell them apart) and {v['dismissed']} you dismissed, the share each "
             f"method proposes (would learn: seen in {v['learnAfter']}+ dictations)"]

    def frac(a: int, b: int) -> str:
        return f"{a}/{b}" + (f" ({100 * a / b:.0f}%)" if b else "")

    rows = [[m, x["candidates"], frac(x["added"]["proposed"], v["added"]), frac(x["added"]["wouldLearn"], v["added"]),
             frac(x["dismissed"]["proposed"], v["dismissed"]), frac(x["dismissed"]["wouldLearn"], v["dismissed"])] for m, x in v["methods"].items()]
    lines.append(harness.table(["method", "candidates", "added: proposed", "added: learns", "dismissed: proposed", "dismissed: learns"], rows, markdown))
    return lines


def _report_part6(v: dict, setup: dict, cfg: dict, markdown: bool) -> list[str]:
    """Part 6, edit replay: its lines in the report."""
    k, a = v["keystrokes"], v["app"]
    return ["", "Part 6, edit replay (tracker fidelity with synthesized keys: per change, last first, arrows, backspaces, the new "
            "text; not how you really edit)",
            f"  readback (SpanTracker): {v['readback']['exact']} of {v['readback']['of']} rebuilt exactly"
            f"{_edge_note(v['readback'])}",
            f"  keystrokes (TypedEdit): {k['exact']} of {k['of']} rebuilt exactly{_edge_note(k)}; {k['inputMethod']} need an input method "
            f"(not ASCII), counted apart ({k['inputMethodExact']} rebuilt if typed as is)",
            f"  the app's own counts (edit-watch.json, {a['apps']} apps): {a['armed']} armed, {a['probesFailed']} probes failed "
            f"(keystroke mode), {a['gaveUp']} keystroke give-ups"]


def details_text(result: dict) -> str:
    """For your eyes only: the hits and misses with your text. Never paste this anywhere that gets committed."""
    rows = result.get("rows", [])
    dictations = {r["id"]: r for r in rows if r.get("part") == 0 and r.get("kind") == "dictation" and "error" not in r}
    out = ["# LOCAL ONLY: this has your dictations' text. Don't commit or paste it anywhere shared.", ""]
    for r in (r for r in rows if r.get("part") == 1 and "arm" in r):
        d = dictations.get(r["id"])
        if not d:
            continue
        for c in d["changes"]:
            if c.get("verdict") == "misheard":
                mark = "✓" if is_fixed(r["output"], d["target"], c["new"]) else "✗"
                out.append(f"part 1 {mark} r{r['round']} {r['prompt']:<7} {r['arm']:<10} {c['old']} → {c['new']}  [{r['id'][:8]}]{'  error: ' + r['error'] if r.get('error') else ''}")
    for r in (r for r in rows if r.get("part") == 2 and "arm" in r):
        d = dictations.get(r["id"])
        for c in (d or {}).get("changes", []):
            if c.get("verdict") == "misheard":
                mark = "✓" if is_fixed(r["transcript"], d["target"], c["new"]) else "✗"
                out.append(f"part 2 {mark} {r['arm']:<8} {c['old']} → {c['new']}  [{r['id'][:8]}] {r['transcript'][:120]}")
    off = {r["id"]: r["transcript"] for r in rows if r.get("part") == 2 and r.get("arm") == "off" and not r.get("error")}
    for r in (r for r in rows if r.get("part") == 2 and r.get("arm") not in (None, "off") and not r.get("error")):
        if r["id"] in off and diverges(off[r["id"]], r["transcript"]):
            out.append(f"part 2 diverged {r['arm']:<8} [{r['id'][:8]}]{' (echo caught)' if r.get('echoed') else ''} hinted: "
                       f"{r['transcript'][:120]}  |  off: {off[r['id']][:120]}")
    for r in (r for r in rows if r.get("part") == 3 and r.get("kind") == "hit"):
        out.append(f"part 3 hit [{r['id'][:8]}]{' (fixed)' if r.get('target') else ''}: {r['text'][:100]}  →  {r['replacedText'][:100]}")
    for r in (r for r in rows if r.get("part") == 3 and r.get("kind") == "entry"):
        flags = [f"{v['text']}{' (case only)' if v['caseOnly'] else ''}{' (ordinary)' if v['ordinary'] else ''}" for v in r["variants"]
                 if v["caseOnly"] or v["ordinary"]]
        if flags:
            out.append(f"part 3 flagged {r['term']}: {', '.join(flags)}")
    for r in (r for r in rows if r.get("part") == 6 and not r.get("exact")):
        out.append(f"part 6 ✗ {r['mode']}{' (input method)' if r['needsInputMethod'] else ''} [{r['id'][:8]}]: got {r.get('edited')!r}, wanted {r['target']!r}")
    return "\n".join(out)


# ---------------------------------------------------------------- commands

def parse_parts(text: str | None) -> list[int]:
    if not text:
        return list(PARTS)
    try:
        parts = sorted({int(x) for x in text.split(",") if x.strip()})
    except ValueError:
        raise SystemExit(f"--parts {text!r}: use numbers 1–6, e.g. 1,3,4") from None
    if not parts or any(p not in PARTS for p in parts):
        raise SystemExit(f"--parts {text!r}: use numbers 1–6, e.g. 1,3,4")
    return parts


def parse_list(text: str | None, choices: tuple[str, ...], flag: str, default: tuple[str, ...] | None = None) -> tuple[str, ...]:
    """A comma-separated subset of `choices`, in their order; `default` (all of them) when not given."""
    if not text:
        return choices if default is None else default
    asked = [x.strip() for x in text.split(",") if x.strip()]
    if not asked or any(x not in choices for x in asked):
        raise SystemExit(f"{flag} {text!r}: choose from {','.join(choices)}")
    return tuple(c for c in choices if c in asked)


def prepare(args, folder: Path) -> tuple[dict, dict, dict, dict]:
    """(job, plan, setup, counts) for the data snapshotted into `folder`."""
    history = load(folder / "history.json", [])
    chosen = test_set(history, args.limit)
    parts = parse_parts(args.parts)
    data = Path(args.data).expanduser().resolve()  # the job's paths are absolute: the harness reads them from elsewhere
    kept = match_recordings(chosen, recordings(data / "Recordings")) if 2 in parts else {}
    setup = resolve_setup(args.setup or current_setup(data), folder)
    arms = parse_list(args.arms, ARMS, "--arms")
    asked = parse_list(args.prompts, PROMPTS + builtin_versions(), "--prompts", default=PROMPTS)
    # No learned prompt active: base runs in its place.
    prompts = tuple("base" if p == "learned" and setup["learned"] is None else p for p in asked)
    # A built-in version that is the base or the learned prompt runs once, under that name.
    same_as = {}
    for name in [p for p in prompts if p not in PROMPTS]:
        mine = prompt_of(setup, name)
        for other in ("base", "learned"):
            theirs = setup[other]
            if theirs and (theirs["version"] == name or (mine["text"] and theirs["text"].strip() == mine["text"])):
                same_as[name] = other
                break
    prompts = tuple(p for p in prompts if p not in same_as)
    for name, other in same_as.items():
        if other not in prompts:
            prompts += (other,)
    prompts = tuple(sorted(dict.fromkeys(prompts), key=_prompt_order))
    job = build_job(folder, chosen, kept, parts, args.rounds, args.seed, setup["id"], args.max_cost, args.learn_after,
                    arms=arms, prompts=prompts)
    plan = estimate(job, history, load(folder / "vocabulary.json", {}), setup, read_prices(args.price))
    counts = {"entries": len(history), "fixed": len(chosen), "mishearings": sum(len(mishearings(e)) for e in chosen),
              "recorded": len(kept), "noLearned": "learned" in asked and setup["learned"] is None, "promptsAsked": list(asked),
              "promptsSameAs": same_as}
    return job, plan, setup, counts


def read_prices(values: list[str] | None) -> dict:
    """PRICES, with --price MODEL=IN,OUT over it (any count of numbers is taken as given, as before)."""
    return harness.read_prices(values, PRICES, lambda name: name.removeprefix("openrouter:"), two=False)


def cmd_run(args, harness_run=run_harness) -> int:
    data = Path(args.data).expanduser().resolve()
    tmp = Path(tempfile.mkdtemp(prefix="history-bench-"))
    try:
        folder = snapshot(data, tmp / "data")
        job, plan, setup, counts = prepare(args, folder)
        rounds = args.rounds
        print(plan_text(job, plan, setup, counts, rounds))
        if args.dry_run:
            print("    dry run: nothing sent")
            return 0
        if not job["dictations"]:
            print("no fixed dictation with the judge's verdicts: nothing to run")
            return 1
        if 1 in job["parts"]:
            if plan["cost"] is None:
                print(f"refusing to start: no price for {plan['model']}, so the cost cap can't be checked (pass --price)")
                return 1
            if plan["cost"] > args.max_cost:
                print(f"refusing to start: the estimate ${plan['cost']:.4f} is above --max-cost ${args.max_cost:.2f}")
                return 1
        key = None
        if 1 in job["parts"]:
            key = openrouter.key(args.key_env)
            if problem := openrouter.key_problem(key):
                print(f"OpenRouter rejected ${args.key_env} ({problem}): update it in ~/.secrets (chezmoi)")
                return 1
        job_path, out_path = tmp / "job.json", tmp / "rows.jsonl"
        job_path.write_text(json.dumps(job, ensure_ascii=False, indent=1))
        started = datetime.now()
        code = harness_run(job_path, out_path, key, tmp / "harness.log")
        rows = read_rows(out_path)
        summary = score(rows, load(folder / "edit-watch.json", {}), load(folder / "vocabulary.json", {}), args.learn_after)
        config = {k: v for k, v in job.items() if k not in ("dictations", "polish", "speech", "history", "vocabulary", "learnedPrompts", "setups")}
        config |= {"rounds": rounds, "seed": args.seed, "limit": args.limit, "estimate": plan, "harnessExit": code,
                   "setupAsked": setup["asked"], "setupFellBack": setup["fellBack"], "promptsAsked": counts["promptsAsked"],
                   "promptsSameAs": counts["promptsSameAs"]}
        result = {"suite": NAME, "format": RESULT_FORMAT, "run_at": started.isoformat(timespec="seconds"), "env": harness.environment(), "config": config,
                  "summary": summary, "rows": rows}
        saved = Path(args.out) if args.out else RESULTS
        saved.mkdir(parents=True, exist_ok=True)
        path = saved / f"{started:%Y%m%d-%H%M%S}.json"
        path.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n")
        print(f"\n    saved {path} (has your text: stays on this Mac, git-ignored)\n")
        print(report_text(result))
        if code:
            print(f"\n    the harness exited {code}: its log is {tmp / 'harness.log'}")
            args.keep_temp = True
        return 0 if code == 0 else 1
    finally:
        if not args.keep_temp:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"    kept {tmp} (job, rows and log hold your text: delete it when done)")


def cmd_report(args) -> int:
    folder = Path(args.out) if getattr(args, "out", None) else RESULTS
    path = Path(args.file) if args.file else next(reversed(sorted(folder.glob("*.json"))), None)
    if path is None:
        print("no results yet: run `bench/suite.py history run`")
        return 1
    result = json.loads(path.read_text())
    if problem := format_problem(result):
        print(f"{path.name}: {problem}")
        return 1
    print(details_text(result) if args.details else report_text(result, markdown=args.markdown))
    return 0


def format_problem(result: dict) -> str | None:
    """Why `report` won't read this result (written before the current format, or in another one); None if it can."""
    found = result.get("format") if isinstance(result, dict) else None
    if found is None:
        return f"predates the current result format ({RESULT_FORMAT}): run `bench/suite.py history run` again"
    if found != RESULT_FORMAT:
        return f"is in result format {found}, and this bench reads format {RESULT_FORMAT}: run `bench/suite.py history run` again"
    return None


def fixture_job() -> dict:
    """The job for bench/history_fixture, as `run` would build it, with paths relative to it: what the Swift
    harness runs in every ./test.sh (HistoryBenchTests), so both sides read one contract."""
    history = load(FIXTURE / "history.json", [])
    chosen = test_set(history)
    kept = match_recordings(chosen, recordings(FIXTURE / "Recordings"))
    # Every kind of prompt: learned (the fixture's v8), base (Cloud Flash's own), and a built-in version by name.
    return build_job(FIXTURE, chosen, kept, list(PARTS), 2, 1, FALLBACK_SETUP, MAX_COST, LEARN_AFTER, relative_to=FIXTURE,
                     prompts=("learned", "base", "v4"))


def cmd_fixture_job(args) -> int:
    FIXTURE_JOB.write_text(json.dumps(fixture_job(), ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {FIXTURE_JOB}")
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="suite.py history", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run the parts on your History (read-only) and report totals")
    r.add_argument("--parts", metavar="LIST", help="comma-separated, e.g. 1,3,4 (default all six)")
    r.add_argument("--dry-run", action="store_true", help="print the calls per part and the estimated cost; read no key, send nothing")
    r.add_argument("--max-cost", type=float, default=MAX_COST, help="US $ cap: refuse above it, and stop sending once spent (default %(default).2f)")
    r.add_argument("--rounds", type=int, default=ROUNDS, help="part 1 rounds (default %(default)s)")
    r.add_argument("--arms", metavar="LIST", help=f"part 1's arms, comma-separated (default all: {','.join(ARMS)})")
    r.add_argument("--prompts", metavar="LIST", help="part 1's prompts: learned (the setup's active learned prompt), base (its "
                   "own prompt) and any built-in version by name (v1, v4…: the setup's model with that version's text); "
                   "default learned,base")
    r.add_argument("--limit", type=int, metavar="N", help="only the newest N fixed dictations")
    r.add_argument("--setup", metavar="ID", help="part 1's setup (default: the app's current one when it polishes in the cloud, else cloud-flash)")
    r.add_argument("--price", action="append", metavar="MODEL=IN,OUT", help="$ per million prompt and completion tokens, for the estimate")
    r.add_argument("--data", default=str(DATA), help="the app's folder to read (default %(default)s)")
    r.add_argument("--learn-after", type=int, default=LEARN_AFTER, help="part 5: dictations before a term is learned (default %(default)s)")
    r.add_argument("--seed", type=int, default=1, help="the arms' order")
    r.add_argument("--key-env", default=openrouter.BENCH_ENV, help="env var with the bench's OpenRouter key (default %(default)s)")
    r.add_argument("--keep-temp", action="store_true", help="keep the snapshot, job and rows (they hold your text)")
    r.add_argument("--out", metavar="DIR", help="save here instead of results/history/")
    r.set_defaults(func=cmd_run)
    rep = sub.add_parser("report", help="the latest (or a given) result: totals only")
    rep.add_argument("--file")
    rep.add_argument("--out", metavar="DIR", help="read results from here instead of results/history/")
    rep.add_argument("--markdown", action="store_true")
    rep.add_argument("--details", action="store_true", help="hits and misses with your text (local only)")
    rep.set_defaults(func=cmd_report)
    f = sub.add_parser("fixture-job", help="rewrite bench/history_fixture/job.json (the Swift harness's test job)")
    f.set_defaults(func=cmd_fixture_job)
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    return args.func(args)
