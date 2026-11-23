"""Tests for the history bench (suites/history.py), on the written fixture only: never real data, no network.
Run: uv run --with pytest --with opencc-python-reimplemented==0.1.7 pytest bench"""
import json
import os
import re
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from suites import history as h

FIXTURE = h.FIXTURE
HISTORY = json.loads((FIXTURE / "history.json").read_text())
VOCABULARY = json.loads((FIXTURE / "vocabulary.json").read_text())
D = lambda n: f"DDDDDDDD-0000-4000-8000-00000000000{n}"


def run_args(*extra: str, out: Path):
    # --data as typed: relative to where you are, as people run it
    return h.parser().parse_args(["run", "--data", os.path.relpath(FIXTURE), "--out", str(out), *extra])


# ---------------------------------------------------------------- words and scoring

def test_words_and_edges_are_the_apps():
    """The same fixture HistoryBenchTests checks against WordDiff.words and FixIntake.edges."""
    pinned = json.loads((FIXTURE / "words.json").read_text())
    for c in pinned["words"]:
        assert h.words(c["text"]) == c["words"], c["text"]
    for c in pinned["edges"]:
        assert h.trim(c["word"]) == c["trimmed"], c["word"]


def test_a_mishearing_is_fixed_by_whole_words_in_your_case():
    assert h.is_fixed("Ask Claude.", "Ask Claude.", "Claude"), "edge punctuation isn't part of the word"
    assert not h.is_fixed("Ask Claude's team.", "Ask Claude.", "Claude"), "a longer word isn't the word"
    assert not h.is_fixed("Ask Claudes.", "Ask Claude.", "Claude")
    assert not h.is_fixed("My remarkable synced.", "My reMarkable synced.", "reMarkable"), "case as you wrote it"
    assert h.is_fixed("My reMarkable synced.", "My reMarkable synced.", "reMarkable")
    assert h.is_fixed("I use (Claude Code) daily", "I use Claude Code daily", "Claude Code"), "several words"
    assert not h.is_fixed("I use Claude code daily", "I use Claude Code daily", "Claude Code")
    assert not h.is_fixed("Claude and cloud", "Claude and Claude", "Claude"), "at least as often as the fix"
    assert h.is_fixed("Claude, Claude", "Claude and Claude", "Claude")


def test_mishearings_wanting_the_same_word_count_one_by_one():
    two = [{"new": "Claude"}, {"new": "Claude"}]
    assert h.fixed_count("Claude and cloud", "Claude and Claude", two) == 1, "one of two fixed"
    assert h.fixed_count("Claude and Claude", "Claude and Claude", two) == 2
    assert h.fixed_count("Claude and cloud", "Claude and Claude, Claude", two) == 0, "the fix had one more already"
    assert h.fixed_count("Ask Claude", "Ask Claude", [{"new": "Claude"}]) == 1


def test_the_second_score_takes_any_case():
    """The strict score keeps your case; "fixed, any case" counts "Ticketmaster" for your "ticketmaster", whole words still."""
    assert not h.is_fixed("Buy on Ticketmaster.", "Buy on ticketmaster.", "ticketmaster")
    assert h.is_fixed("Buy on Ticketmaster.", "Buy on ticketmaster.", "ticketmaster", any_case=True)
    assert not h.is_fixed("Buy on Ticketmasters.", "Buy on ticketmaster.", "ticketmaster", any_case=True), "whole words"
    two = [{"new": "Claude"}, {"new": "claude"}]
    assert h.fixed_count("CLAUDE and cloud", "Claude and claude", two, any_case=True) == 1
    assert h.fixed_count("CLAUDE and cloud", "Claude and claude", two) == 0


def test_chinese_words_are_characters():
    """Chinese has no spaces: as FixIntake splits it, each character is a word, so a Chinese term counts
    wherever its characters stand in a row, and a Latin term next to Chinese is still whole."""
    assert h.is_fixed("我们跑代码审查。", "我们跑代码审查。", "查")
    assert not h.is_fixed("我们跑代码审茶。", "我们跑代码审查。", "查")
    assert h.is_fixed("用克劳德写代码", "用克劳德写", "克劳德")
    assert h.is_fixed("我们用Claude写代码", "我们用 Claude 写代码", "Claude"), "Latin beside Chinese is a word of its own"
    assert h.count_term("審查审查", "审查") == 1, "no Traditional-to-Simplified: written as you wrote it"


def test_word_errors_are_the_benchs():
    assert h.word_errors("a b c d", "a b c d") == 0
    assert h.word_errors("a b c d", "a x c d") == 0.25


# ---------------------------------------------------------------- the test set, recordings, held out

def test_the_test_set_is_your_judged_fixes():
    """Corrections and accepted captures whose word changes have verdicts; not a waiting or auto capture,
    not an unjudged fix, not one whose word changes are from an older version of it."""
    assert [e["id"] for e in h.test_set(HISTORY)] == [D(9), D(4), D(3), D(2), D(1)]
    assert [e["id"] for e in h.test_set(HISTORY, limit=2)] == [D(9), D(4)], "--limit: the newest N"
    assert sum(len(h.mishearings(e)) for e in h.test_set(HISTORY)) == 6


def test_recordings_match_by_time_and_text():
    at = datetime(2026, 11, 1, 9, 0, 30, tzinfo=timezone.utc)
    entry = {"id": "a", "date": "2026-11-01T09:00:30Z", "text": "Hello there.", "raw": "hello there"}
    rec = lambda name, seconds_before, **kw: {"wav": Path(name), "when": at - timedelta(seconds=seconds_before), **kw}
    kept = [rec("early", 100, polished="Hello there."), rec("after", -5, polished="Hello there."),
            rec("other", 10, transcript="something else"), rec("far", 60, transcript="hello there"),
            rec("near", 20, polished="Hello there.")]
    assert h.match_recordings([entry], kept) == {"A": Path("near")}, "nearest within 90 s, text matching"
    two = [entry, {**entry, "id": "b"}]
    assert h.match_recordings(two, kept) == {"A": Path("near"), "B": Path("far")}, "each recording once"
    assert h.match_recordings([entry], [rec("raw", 5, transcript="Hello there.")]) == {"A": Path("raw")}, "transcript == text"


def test_the_fixtures_recordings():
    found = h.match_recordings(h.test_set(HISTORY), h.recordings(FIXTURE / "Recordings"))
    assert found == {D(1): FIXTURE / "Recordings/20261101-090010.wav"}, "D4's sidecar has no WAV"


def test_held_out_drops_only_what_this_dictation_taught():
    terms = lambda d: {e["term"]: e["heardAs"] for e in h.held_out(VOCABULARY, d, HISTORY)}
    assert "notes" not in terms(D(1)), "a learned entry from this dictation alone"
    assert terms(D(2))["Claude"] == ["cloud"], "a variant from it alone goes; the entry you typed stays (any-case id)"
    assert terms(D(3))["reMarkable"] == ["remarkable"], "seen in two dictations: stays"
    assert terms(D(4))["Hammerspoon"] == ["hammers poon"], "its other variant and the entry stay"
    assert terms(D(1))["Kubernetes"] == ["cooper netties"]
    orphan = {"entries": [{"term": "X", "heardAs": ["ex"], "source": "learned"}], "candidates": []}
    assert h.held_out(orphan, D(1), HISTORY) == orphan["entries"], "nothing says where it came from: it stays"


def test_held_out_finds_sources_in_history_too():
    """A candidate that stopped counting is kept with `heard: []`: History still says which dictation taught the entry."""
    neovim = next(c for c in VOCABULARY["candidates"] if c["term"] == "Neovim")
    assert neovim["heard"] == []
    assert "Neovim" not in {e["term"] for e in h.held_out(VOCABULARY, D(9), HISTORY)}, "its one source, found in History"
    assert "Neovim" in {e["term"] for e in h.held_out(VOCABULARY, D(4), HISTORY)}
    assert "Zettlr" in {e["term"] for e in h.held_out(VOCABULARY, D(9), HISTORY)}, "no known source: kept"
    assert h.unsourced(VOCABULARY, HISTORY) == 1
    cased = [{**e, "intake": {**e["intake"], "changes": [{"old": "Neo Vim.", "new": "neovim", "verdict": "misheard"}]}}
             if e["id"] == D(9) else e for e in HISTORY]
    assert "Neovim" not in {e["term"] for e in h.held_out(VOCABULARY, D(9), cased)}, "edges trimmed, any case"
    plain = {**VOCABULARY, "candidates": []}
    assert {e["term"]: e["heardAs"] for e in h.held_out(plain, D(2), HISTORY)}["Claude"] == ["cloud"], "History alone is enough"


def test_arms_are_interleaved_per_dictation():
    plan = h.schedule_polish([D(1), D(2)], rounds=3, seed=1)
    size = len(h.ARMS) * len(h.PROMPTS)
    assert len(plan) == 2 * 3 * size
    for i in range(0, len(plan), size):
        block = plan[i:i + size]
        assert len({t["id"] for t in block}) == 1, "a dictation's trials back to back"
        assert {(t["prompt"], t["arm"]) for t in block} == {(p, a) for p in h.PROMPTS for a in h.ARMS}, "every prompt × arm"
    assert plan == h.schedule_polish([D(1), D(2)], rounds=3, seed=1)
    assert len({tuple((t["prompt"], t["arm"]) for t in plan[i:i + size]) for i in range(0, len(plan), size)}) > 1, "shuffled"
    some = h.schedule_polish([D(1)], rounds=1, seed=1, arms=("off", "again"), prompts=("base",))
    assert {(t["prompt"], t["arm"]) for t in some} == {("base", "off"), ("base", "again")}
    speech = h.schedule_speech([D(1)], seed=1)
    assert {t["arm"] for t in speech} == set(h.SPEECH_ARMS)


def test_the_swift_harness_runs_this_job():
    """bench/history_fixture/job.json is what `run` builds for the fixture (HistoryBenchTests runs it in ./test.sh).
    After changing the job's shape: bench/suite.py history fixture-job."""
    assert h.fixture_job() == json.loads(h.FIXTURE_JOB.read_text())


def test_parts():
    assert h.parse_parts(None) == [1, 2, 3, 4, 5, 6]
    assert h.parse_parts("4,1,3") == [1, 3, 4]
    assert h.parse_list("again,off", h.ARMS, "--arms") == ("off", "again"), "in the arms' own order"
    assert h.parse_list(None, h.PROMPTS, "--prompts") == h.PROMPTS
    with pytest.raises(SystemExit):
        h.parse_list("loud", h.ARMS, "--arms")
    for bad in ("7", "a", ""):
        if bad:
            with pytest.raises(SystemExit):
                h.parse_parts(bad)


# ---------------------------------------------------------------- dry run and the cost cap

def no_network(monkeypatch):
    def refuse(*a, **k):
        raise AssertionError("must not be called")
    monkeypatch.setattr(h.openrouter, "key", refuse)
    monkeypatch.setattr(h.openrouter, "key_problem", refuse)
    return refuse


def test_dry_run_sends_nothing(monkeypatch, capsys, tmp_path):
    refuse = no_network(monkeypatch)
    assert h.cmd_run(run_args("--dry-run", out=tmp_path), harness_run=refuse) == 0
    out = capsys.readouterr().out
    assert "120 polish calls (5 × 4 arms × 2 prompts × 3 rounds)" in out
    assert "prompts learned (v8) and base (v7)" in out
    assert "an upper estimate" in out
    assert "1 learned entries with no known source (kept in held out)" in out
    assert "3 on-device transcriptions (1 clips × 3 arms)" in out
    assert "dry run: nothing sent" in out
    assert not list(tmp_path.iterdir()), "no result file"


def test_a_run_above_the_cap_refuses_to_start(monkeypatch, capsys, tmp_path):
    refuse = no_network(monkeypatch)
    assert h.cmd_run(run_args("--max-cost", "0.0001", out=tmp_path), harness_run=refuse) == 1
    assert "refusing to start: the estimate" in capsys.readouterr().out


def test_an_unpriced_model_refuses_to_start(monkeypatch, capsys, tmp_path):
    refuse = no_network(monkeypatch)
    monkeypatch.setattr(h, "PRICES", {})
    assert h.cmd_run(run_args(out=tmp_path), harness_run=refuse) == 1
    assert "no price" in capsys.readouterr().out
    assert h.cmd_run(run_args("--parts", "3,5,6", out=tmp_path), harness_run=lambda *a: fake_harness(*a)) == 0, "free parts need no price"


def test_the_estimate_reads_the_apps_terms_header():
    assert h.prompt_header().startswith("Vocabulary: the speaker uses these terms.")


def test_the_estimate_counts_every_arm():
    folder = FIXTURE
    chosen = h.test_set(HISTORY)
    job = h.build_job(folder, chosen, {}, [1], 3, 1, "cloud-flash", 0.5, 3)
    setup = h.resolve_setup("cloud-flash", folder)
    plan = h.estimate(job, HISTORY, VOCABULARY, setup, h.PRICES)
    assert plan["polish_calls"] == 5 * 4 * 2 * 3
    off = h.estimate({**job, "polish": [t for t in job["polish"] if t["arm"] == "off"]}, HISTORY, VOCABULARY, setup, h.PRICES)
    told = h.estimate({**job, "polish": [t for t in job["polish"] if t["arm"] == "terms-only"]}, HISTORY, VOCABULARY, setup, h.PRICES)
    assert told["tokens_in"] > off["tokens_in"], "the terms block costs tokens"
    assert setup["model"] == "deepseek/deepseek-v4.1-flash" and setup["base"]["version"] == "v7" and setup["learned"]["version"] == "v8"
    base = h.estimate({**job, "polish": [t for t in job["polish"] if t["prompt"] == "base"]}, HISTORY, VOCABULARY, setup, h.PRICES)
    learned = h.estimate({**job, "polish": [t for t in job["polish"] if t["prompt"] == "learned"]}, HISTORY, VOCABULARY, setup, h.PRICES)
    assert base["tokens_in"] > learned["tokens_in"], "each prompt's own length (the fixture's learned one is short)"
    assert h.resolve_setup("on-device", folder)["fellBack"], "a setup that polishes on this Mac: Cloud Flash's"


# ---------------------------------------------------------------- a run with a stand-in harness

def replace(text: str, entries: list[dict]) -> str:
    """A stand-in for Vocabulary.apply (the real one runs in the Swift harness)."""
    for e in entries:
        if e.get("enabled", True):
            for v in e.get("heardAs") or []:
                text = re.sub(rf"(?<![A-Za-z]){re.escape(v)}(?![A-Za-z])", e["term"], text, flags=re.I)
    return text


def fake_harness(job_path: Path, out_path: Path, key, log: Path, stop_after: int | None = None) -> int:
    """Writes the rows HistoryBenchTests would, from the job, without Swift or a network."""
    job = json.loads(job_path.read_text())
    folder = job_path.parent
    history = {e["id"].upper(): e for e in json.loads(Path(job["history"]).read_text())}
    vocab = json.loads(Path(job["vocabulary"]).read_text())
    held = {d["id"]: d["heldOut"] for d in job["dictations"]}
    for d in job["dictations"]:  # the harness runs elsewhere: every path it's given must stand on its own
        assert d["recording"] is None or (Path(d["recording"]).is_absolute() and Path(d["recording"]).exists())
    assert Path(job["history"]).is_absolute() and Path(job["history"]).parent == folder / "data"
    rows = [{"part": 0, "kind": "setup", "setup": job["setup"], "prompt": "v8", "basePrompt": "v7", "learnedPrompt": "v8",
             "polish": "openrouter:deepseek/deepseek-v4.1-flash@Together,DeepInfra", "fellBack": False}]
    for d in job["dictations"]:
        e = history[d["id"]]
        rows.append({"part": 0, "kind": "dictation", "id": d["id"], "input": e.get("raw") or e["text"], "hadRaw": "raw" in e,
                     "text": e["text"], "target": e["correction"], "changes": e["intake"]["changes"]})
    vocab_for = lambda arm, d: {"off": [], "terms-only": [], "again": vocab["entries"], "held-out": held[d]}[arm]
    cost, stopped = 0.0, False
    for n, t in enumerate(job["polish"]):
        if stop_after is not None and n >= stop_after:
            stopped = True
            rows.append({"part": 1, "kind": "stopped", "cost": cost})
            break
        e = history[t["id"]]
        output = replace(e.get("raw") or e["text"], vocab_for(t["arm"], t["id"]))
        if t["prompt"] == "learned":  # a stand-in for a learned prompt that knows a term already, in its own case
            output = output.replace("hammer spoon", "HAMMERSPOON")
        rows.append({"part": 1, "round": t["round"], "id": t["id"], "prompt": t["prompt"], "arm": t["arm"], "output": output,
                     "seconds": 0.5 + 0.1 * (t["arm"] != "off"), "error": None, "cost": 0.001})
        cost += 0.001
    for t in job["speech"]:
        e = history[t["id"]]
        echoed = t["arm"] == "again"  # a stand-in: the app caught again's echo and delivered its second pass
        rows.append({"part": 2, "id": t["id"], "arm": t["arm"], "transcript": e["raw"], "replaced": replace(e["raw"], vocab_for(t["arm"], t["id"])),
                     "seconds": 2.0 if echoed else 1.0, "error": None, "contextWords": 0, "echoed": echoed})
    for e in history.values():
        new = replace(e["text"], vocab["entries"])
        if new != e["text"]:
            rows.append({"part": 3, "kind": "hit", "id": e["id"], "rawChanged": False, "textChanged": True, "text": e["text"], "replacedText": new,
                         "target": e.get("correction"), "uses": {vocab["entries"][0]["id"]: 1}})
    rows.append({"part": 3, "kind": "summary", "entries": len(history), "withRaw": sum("raw" in e for e in history.values())})
    for e in vocab["entries"]:
        if e.get("enabled", True):
            rows.append({"part": 3, "kind": "entry", "entry": e["id"], "term": e["term"],
                         "variants": [{"text": v, "caseOnly": v.lower() == e["term"].lower() and v != e["term"], "ordinary": v == "nodes"} for v in e["heardAs"]]})
    rows.append({"part": 4, "kind": "replacement", "seconds": [0.00001, 0.00002], "build": "debug"})
    for method in ("rules", "judge"):
        rows.append({"part": 5, "method": method, "candidates": [{"term": c["term"], "seen": len(c["heard"][0]["dictations"]) if c["heard"] else 0}
                                                                 for c in vocab["candidates"] if method == "rules" or not c.get("dismissed")]})
    for d in job["dictations"]:
        target = history[d["id"]]["correction"]
        for mode in ("readback", "keystrokes"):
            rows.append({"part": 6, "id": d["id"], "mode": mode, "captured": True, "exact": True, "edited": target, "target": target,
                         "needsInputMethod": any(ord(c) > 127 for c in target)})
    rows.append({"part": -1, "kind": "done", "cost": cost, "stopped": stopped})
    out_path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    return 0


def job_speech_clips(result: dict) -> int:
    return result["summary"]["parts"]["2"]["clips"]


def fixture_texts() -> set[str]:
    """Every piece of text in the fixture: none may reach the totals."""
    found = set()
    for e in HISTORY:
        found |= {e["text"], e.get("raw") or "", e.get("correction") or ""}
        for c in (e.get("intake") or {}).get("changes", []):
            found |= {c["old"], c["new"]}
    for e in VOCABULARY["entries"]:
        found |= {e["term"], *e["heardAs"]}
    for c in VOCABULARY["candidates"]:
        found |= {c["term"], *(x["text"] for x in c["heard"])}
    return {t for t in found if t}


def test_the_report_has_totals_only(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(h.openrouter, "key", lambda env: "sk-test")
    monkeypatch.setattr(h.openrouter, "key_problem", lambda key: None)
    assert h.cmd_run(run_args(out=tmp_path), harness_run=fake_harness) == 0
    printed = capsys.readouterr().out
    result = json.loads(next(tmp_path.glob("*.json")).read_text())
    report = h.report_text(result)
    summary = json.dumps(result["summary"], ensure_ascii=False)
    for text in fixture_texts():
        # Whole words: "cloud" is a fixture variant, and "cloud-flash" a setup's name, not your text.
        found = re.compile(rf"(?<![\w-]){re.escape(text)}(?![\w-])")
        assert not found.search(report), f"{text!r} in the report"
        assert not found.search(printed), f"{text!r} printed"
        assert not found.search(summary), f"{text!r} in the summary"
    assert "Claude" in h.details_text(result), "the local details do have text"
    s = result["summary"]["parts"]
    base, learned = s["1"]["prompts"]["base"]["arms"], s["1"]["prompts"]["learned"]["arms"]
    assert s["1"]["of"] == 6 and base["off"]["fixed"]["mean"] == 0
    assert base["again"]["fixed"]["mean"] == 5, "every mishearing with a variant (茶 has none)"
    assert base["held-out"]["fixed"]["mean"] == 1, "only reMarkable, seen in another dictation too"
    assert learned["off"]["fixed"]["mean"] == 0
    assert learned["off"]["fixedAnyCase"]["mean"] == 2, "HAMMERSPOON, and the case-only remarkable: right in any case only"
    assert "prompt: learned (v8)" in report and "prompt: base (v7)" in report and "fixed, any case" in report
    assert "1 learned entries with no known source: kept in held out" in report
    assert s["4"]["polish"]["base"]["terms-only"]["p50_change"] == pytest.approx(0.1)
    assert s["4"]["polish"]["learned"]["again"]["p50_change"] == pytest.approx(0.1)
    assert "polish, prompt learned, seconds" in report
    assert s["6"]["keystrokes"] == {"exact": 4, "of": 4, "captured": 4, "missesPastTheEdge": 0, "inputMethod": 1, "inputMethodExact": 1}
    assert s["6"]["app"] == {"apps": 2, "armed": 8, "probesFailed": 4, "gaveUp": 2}
    assert s["5"]["added"] == 5 and s["5"]["dismissed"] == 1
    assert s["5"]["methods"]["rules"]["dismissed"]["proposed"] == 1 and s["5"]["methods"]["judge"]["dismissed"]["proposed"] == 0
    assert "has your text" in printed
    assert s["2"]["arms"]["again"]["echoes"] == job_speech_clips(result) and s["2"]["arms"]["held-out"]["echoes"] == 0
    assert s["2"]["arms"]["again"]["diverged"] == [], "the stand-in delivers the same text as off"
    assert "echoes caught" in report and "diverged from off" in report


def test_part_2_counts_echoes_and_clips_that_diverged_from_off():
    d = {"part": 0, "kind": "dictation", "target": "send the notes to Claude", "changes": [{"old": "cloud", "new": "Claude", "verdict": "misheard"}]}
    rows = [{**d, "id": "A"}, {**d, "id": "B"}, {**d, "id": "C"}, {**d, "id": "E"},
            {"part": 2, "id": "A", "arm": "off", "transcript": "send the notes to cloud", "replaced": "", "seconds": 1.0},
            {"part": 2, "id": "A", "arm": "again", "transcript": "send the notes to Claude", "replaced": "", "seconds": 2.0, "echoed": True},
            # The guard missed this one: a list in place of the dictation.
            {"part": 2, "id": "B", "arm": "off", "transcript": "send the notes to cloud", "replaced": "", "seconds": 1.0},
            {"part": 2, "id": "B", "arm": "again", "transcript": "Hammerspoon, reMarkable", "replaced": "", "seconds": 1.0, "echoed": False},
            # An empty off transcript: anything heard against it diverges.
            {"part": 2, "id": "C", "arm": "off", "transcript": "", "replaced": "", "seconds": 1.0},
            {"part": 2, "id": "C", "arm": "again", "transcript": "send it", "replaced": "", "seconds": 1.0},  # from before the guard: no "echoed"
            # An off run that failed can't be compared.
            {"part": 2, "id": "E", "arm": "off", "transcript": "", "replaced": "", "seconds": 0, "error": "boom"},
            {"part": 2, "id": "E", "arm": "again", "transcript": "anything at all", "replaced": "", "seconds": 1.0}]
    arms = h.score(rows, {}, {}, 3)["parts"][2]["arms"]
    assert arms["again"]["echoes"] == 1 and arms["off"]["echoes"] == 0
    assert arms["again"]["diverged"] == ["B", "C"] and arms["again"]["comparedWithOff"] == 3
    assert "diverged" not in arms["off"]
    assert arms["again"]["transcript"] == 1, "scored on the delivered text: A's second pass has Claude"
    assert h.diverges("a b c d", "a b x y") is False and h.diverges("a b c d", "a x y z") is True, "over half, not half"
    assert h.diverges("", "") is False


def test_a_stopped_run_says_so(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(h.openrouter, "key", lambda env: "sk-test")
    monkeypatch.setattr(h.openrouter, "key_problem", lambda key: None)
    assert h.cmd_run(run_args("--parts", "1", out=tmp_path), harness_run=lambda *a: fake_harness(*a, stop_after=5)) == 0
    result = json.loads(next(tmp_path.glob("*.json")).read_text())
    assert result["summary"]["stopped"]
    assert "stopped sending at the cost cap" in h.report_text(result)
    assert sum(1 for r in result["rows"] if r.get("part") == 1 and "arm" in r) == 5, "the rows so far are kept"
    assert all(v["wholeRounds"] == 0 for v in result["summary"]["parts"]["1"]["prompts"].values()), "a round cut short isn't scored"
    assert result["summary"]["cost"] == pytest.approx(0.005)


def test_a_skipped_part_1_prints_no_empty_table():
    result = {"run_at": "x", "config": {"parts": [1], "maxCost": 0.5}, "summary": {
        "dictations": 1, "changes": 1, "mishearings": 1, "cost": 0, "finished": True, "setup": {},
        "parts": {"1": {"of": 0, "dictations": 0, "prompts": {}, "calls": 0, "skipped": "no key"}}}}
    report = h.report_text(result)
    assert "skipped: no key" in report and "prompt:" not in report


def test_a_subset_of_arms_and_prompts(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(h.openrouter, "key", lambda env: "sk-test")
    monkeypatch.setattr(h.openrouter, "key_problem", lambda key: None)
    args = run_args("--parts", "1,4", "--arms", "off,again", "--prompts", "base", "--rounds", "1", out=tmp_path)
    assert h.cmd_run(args, harness_run=fake_harness) == 0
    result = json.loads(next(tmp_path.glob("*.json")).read_text())
    calls = [r for r in result["rows"] if r.get("part") == 1 and "arm" in r]
    assert len(calls) == 5 * 2 and {(r["prompt"], r["arm"]) for r in calls} == {("base", "off"), ("base", "again")}
    assert list(result["summary"]["parts"]["1"]["prompts"]) == ["base"]
    assert set(result["summary"]["parts"]["4"]["polish"]["base"]) == {"off", "again"}


def test_no_learned_prompt_runs_base_only(monkeypatch, capsys, tmp_path):
    data = tmp_path / "data"
    shutil.copytree(FIXTURE, data)
    (data / "learned-prompts.json").unlink()
    refuse = no_network(monkeypatch)
    args = h.parser().parse_args(["run", "--data", str(data), "--out", str(tmp_path / "out"), "--dry-run"])
    assert h.cmd_run(args, harness_run=refuse) == 0
    out = capsys.readouterr().out
    assert "60 polish calls (5 × 4 arms × 1 prompts × 3 rounds)" in out
    assert "no learned prompt active: part 1 runs the base prompt in its place" in out
    args = h.parser().parse_args(["run", "--data", str(data), "--out", str(tmp_path / "out"), "--dry-run", "--parts", "1", "--prompts", "learned,v4"])
    assert h.cmd_run(args, harness_run=refuse) == 0
    assert "prompts base (v7) and v4 (built-in)" in capsys.readouterr().out, "base stands in for the missing learned prompt"


def test_prompts_take_a_built_in_version(monkeypatch, capsys, tmp_path):
    """--prompts also takes any PolishPrompt version: the setup's model with that version's text."""
    assert h.builtin_versions() == ("v1", "v2", "v3", "v4", "v7")
    assert all((h.POLISH_PROMPTS / f"{v}.txt").exists() for v in h.builtin_versions()), "the estimate reads their text"
    refuse = no_network(monkeypatch)
    assert h.cmd_run(run_args("--parts", "1", "--prompts", "v4", "--dry-run", out=tmp_path), harness_run=refuse) == 0
    out = capsys.readouterr().out
    assert "60 polish calls (5 × 4 arms × 1 prompts × 3 rounds)" in out and "prompts v4 (built-in)" in out
    with pytest.raises(SystemExit, match="choose from learned,base,v1,v2,v3,v4,v7"):
        h.cmd_run(run_args("--prompts", "v9", "--dry-run", out=tmp_path), harness_run=refuse)


def test_a_version_that_is_base_runs_once(monkeypatch, capsys, tmp_path):
    refuse = no_network(monkeypatch)
    assert h.cmd_run(run_args("--parts", "1", "--prompts", "learned,base,v7", "--dry-run", out=tmp_path), harness_run=refuse) == 0
    out = capsys.readouterr().out
    assert "(5 × 4 arms × 2 prompts × 3 rounds)" in out and "v7 is the base prompt: run once, as base" in out
    assert h.cmd_run(run_args("--parts", "1", "--prompts", "v7", "--dry-run", out=tmp_path), harness_run=refuse) == 0
    assert "prompts base (v7)" in capsys.readouterr().out, "asked for v7 alone: it runs, as base"


def test_a_built_in_version_gets_its_own_table(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(h.openrouter, "key", lambda env: "sk-test")
    monkeypatch.setattr(h.openrouter, "key_problem", lambda key: None)
    args = run_args("--parts", "1,4", "--prompts", "base,v4", "--arms", "off,again", "--rounds", "1", out=tmp_path)
    assert h.cmd_run(args, harness_run=fake_harness) == 0
    result = json.loads(next(tmp_path.glob("*.json")).read_text())
    assert list(result["summary"]["parts"]["1"]["prompts"]) == ["base", "v4"]
    report = h.report_text(result)
    assert "prompt: v4 (built-in)" in report and "prompt: base (v7)" in report and "polish, prompt v4, seconds" in report


SETTINGS_SWIFT = h.REPO / "Sources/DictationKit/Settings/Settings.swift"


def test_the_apps_constants_are_the_benchs():
    """Copies of the app's settings the bench reads, checked against Settings.swift."""
    swift = SETTINGS_SWIFT.read_text()
    assert re.search(rf'@Setting\("vocabularyLearnAfter", default: {h.LEARN_AFTER}\)', swift), "AppSettings.vocabularyLearnAfter's default"
    assert f'private static let setupKey = "{h.SETUP_KEY}"' in swift, "the defaults key that holds the current setup's id"
    assert h.replaced_setups() == {"cloud-flash-deepseek": "cloud-flash", "cloud-big": "cloud-flash"}, "DictationSetup.replaced, as read"


# ---------------------------------------------------------------- results from before a change: still read

def fixture_result(monkeypatch, tmp_path, *extra: str) -> dict:
    monkeypatch.setattr(h.openrouter, "key", lambda env: "sk-test")
    monkeypatch.setattr(h.openrouter, "key_problem", lambda key: None)
    assert h.cmd_run(run_args(*extra, out=tmp_path), harness_run=fake_harness) == 0
    return json.loads(next(tmp_path.glob("*.json")).read_text())


def test_rows_from_before_prompts_were_split_score_as_learned(monkeypatch, tmp_path):
    rows = fixture_result(monkeypatch, tmp_path, "--parts", "1", "--prompts", "learned", "--rounds", "1")["rows"]
    old = [{k: v for k, v in r.items() if k != "prompt"} if r.get("part") == 1 else r for r in rows]
    s = h.score(old, {}, VOCABULARY, 3)
    assert list(s["parts"][1]["prompts"]) == ["learned"], "a row with no prompt was the learned prompt's"
    assert s["parts"][1]["prompts"] == h.score(rows, {}, VOCABULARY, 3)["parts"][1]["prompts"]
    details = h.details_text({"rows": old})
    assert " learned " in details and details == h.details_text({"rows": rows})


def test_a_summary_from_before_prompts_were_split_still_reports(monkeypatch, tmp_path):
    result = fixture_result(monkeypatch, tmp_path, "--parts", "1,2,4", "--prompts", "learned", "--rounds", "1")
    p = result["summary"]["parts"]
    arms = {arm: {k: v for k, v in a.items() if k != "fixedAnyCase"} for arm, a in p["1"]["prompts"]["learned"]["arms"].items()}
    p["1"] = {k: v for k, v in p["1"].items() if k != "prompts"} | {"arms": arms}
    p["4"]["polish"] = p["4"]["polish"]["learned"]
    p["2"]["arms"] = {arm: {k: v for k, v in a.items() if k not in ("replacedAnyCase", "echoes", "diverged", "comparedWithOff")}
                      for arm, a in p["2"]["arms"].items()}
    report = h.report_text(result)
    assert "prompt: as run (v8)" in report, "part 1's one table, named by the setup row's prompt"
    assert "polish, prompt as run, seconds" in report, "part 4's flat polish table"
    table = report[report.index("Part 2"):report.index("Part 4")]
    assert table.count("—") == 3 * 3, "after any case, echoes and diverged: a dash in each arm"


def test_part_2_rows_from_before_the_echo_guard(monkeypatch, tmp_path):
    rows = fixture_result(monkeypatch, tmp_path, "--parts", "2")["rows"]
    old = [{k: v for k, v in r.items() if k != "echoed"} for r in rows]
    assert all(a["echoes"] == 0 for a in h.score(old, {}, VOCABULARY, 3)["parts"][2]["arms"].values())


def test_an_estimate_from_a_job_without_prompts_prices_the_learned_prompt():
    job = h.build_job(FIXTURE, h.test_set(HISTORY), {}, [1], 1, 1, "cloud-flash", 0.5, 3, prompts=("learned",))
    setup = h.resolve_setup("cloud-flash", FIXTURE)
    bare = {**job, "polish": [{k: v for k, v in t.items() if k != "prompt"} for t in job["polish"]]}
    assert h.estimate(bare, HISTORY, VOCABULARY, setup, h.PRICES) == h.estimate(job, HISTORY, VOCABULARY, setup, h.PRICES)
