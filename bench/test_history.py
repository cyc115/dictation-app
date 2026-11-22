"""Tests for the history bench (suites/history.py), on the written fixture only: never real data, no network.
Run: uv run --with pytest --with opencc-python-reimplemented==0.1.7 pytest bench"""
import json
import os
import re
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
    assert [e["id"] for e in h.test_set(HISTORY)] == [D(4), D(3), D(2), D(1)]
    assert [e["id"] for e in h.test_set(HISTORY, limit=2)] == [D(4), D(3)], "--limit: the newest N"
    assert sum(len(h.mishearings(e)) for e in h.test_set(HISTORY)) == 5


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
    terms = lambda d: {e["term"]: e["heardAs"] for e in h.held_out(VOCABULARY, d)}
    assert "notes" not in terms(D(1)), "a learned entry from this dictation alone"
    assert terms(D(2))["Claude"] == ["cloud"], "a variant from it alone goes; the entry you typed stays (any-case id)"
    assert terms(D(3))["reMarkable"] == ["remarkable"], "seen in two dictations: stays"
    assert terms(D(4))["Hammerspoon"] == ["hammers poon"], "its other variant and the entry stay"
    assert terms(D(1))["Kubernetes"] == ["cooper netties"]
    orphan = {"entries": [{"term": "X", "heardAs": ["ex"], "source": "learned"}], "candidates": []}
    assert h.held_out(orphan, D(1)) == orphan["entries"], "nothing says where it came from: it stays"


def test_arms_are_interleaved_per_dictation():
    plan = h.schedule_polish([D(1), D(2)], rounds=3, seed=1)
    assert len(plan) == 2 * 3 * len(h.ARMS)
    for i in range(0, len(plan), len(h.ARMS)):
        block = plan[i:i + len(h.ARMS)]
        assert len({t["id"] for t in block}) == 1 and {t["arm"] for t in block} == set(h.ARMS), "a dictation's arms back to back"
    assert plan == h.schedule_polish([D(1), D(2)], rounds=3, seed=1)
    assert {tuple(t["arm"] for t in plan[i:i + 4]) for i in range(0, len(plan), 4)} != {h.ARMS}, "shuffled"
    speech = h.schedule_speech([D(1)], seed=1)
    assert {t["arm"] for t in speech} == set(h.SPEECH_ARMS)


def test_the_swift_harness_runs_this_job():
    """bench/history_fixture/job.json is what `run` builds for the fixture (HistoryBenchTests runs it in ./test.sh).
    After changing the job's shape: bench/suite.py history fixture-job."""
    assert h.fixture_job() == json.loads(h.FIXTURE_JOB.read_text())


def test_parts():
    assert h.parse_parts(None) == [1, 2, 3, 4, 5, 6]
    assert h.parse_parts("4,1,3") == [1, 3, 4]
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
    assert "48 polish calls (4 × 4 arms × 3 rounds)" in out
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
    assert plan["polish_calls"] == 4 * 4 * 3
    off = h.estimate({**job, "polish": [t for t in job["polish"] if t["arm"] == "off"]}, HISTORY, VOCABULARY, setup, h.PRICES)
    told = h.estimate({**job, "polish": [t for t in job["polish"] if t["arm"] == "terms-only"]}, HISTORY, VOCABULARY, setup, h.PRICES)
    assert told["tokens_in"] > off["tokens_in"], "the terms block costs tokens"
    assert setup["model"] == "deepseek/deepseek-v4.1-flash" and setup["prompt"] == "v7"
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
    rows = [{"part": 0, "kind": "setup", "setup": job["setup"], "prompt": "v7", "polish": "openrouter:deepseek/deepseek-v4.1-flash@Together,DeepInfra",
             "fellBack": False}]
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
        rows.append({"part": 1, "round": t["round"], "id": t["id"], "arm": t["arm"], "output": replace(e.get("raw") or e["text"], vocab_for(t["arm"], t["id"])),
                     "seconds": 0.5 + 0.1 * (t["arm"] != "off"), "error": None, "cost": 0.001})
        cost += 0.001
    for t in job["speech"]:
        e = history[t["id"]]
        rows.append({"part": 2, "id": t["id"], "arm": t["arm"], "transcript": e["raw"], "replaced": replace(e["raw"], vocab_for(t["arm"], t["id"])),
                     "seconds": 1.0, "error": None, "contextWords": 0})
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
    assert s["1"]["of"] == 5 and s["1"]["arms"]["off"]["fixed"]["mean"] == 0
    assert s["1"]["arms"]["again"]["fixed"]["mean"] == 4, "every mishearing with a variant (茶 has none)"
    assert s["1"]["arms"]["held-out"]["fixed"]["mean"] == 1, "only reMarkable, seen in another dictation too"
    assert s["4"]["polish"]["terms-only"]["p50_change"] == pytest.approx(0.1)
    assert s["6"]["keystrokes"] == {"exact": 3, "of": 3, "captured": 3, "missesPastTheEdge": 0, "inputMethod": 1, "inputMethodExact": 1}
    assert s["6"]["app"] == {"apps": 2, "armed": 8, "probesFailed": 4, "gaveUp": 2}
    assert s["5"]["added"] == 4 and s["5"]["dismissed"] == 1
    assert s["5"]["methods"]["rules"]["dismissed"]["proposed"] == 1 and s["5"]["methods"]["judge"]["dismissed"]["proposed"] == 0
    assert "has your text" in printed


def test_a_stopped_run_says_so(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(h.openrouter, "key", lambda env: "sk-test")
    monkeypatch.setattr(h.openrouter, "key_problem", lambda key: None)
    assert h.cmd_run(run_args("--parts", "1", out=tmp_path), harness_run=lambda *a: fake_harness(*a, stop_after=5)) == 0
    result = json.loads(next(tmp_path.glob("*.json")).read_text())
    assert result["summary"]["stopped"]
    assert "stopped sending at the cost cap" in h.report_text(result)
    assert sum(1 for r in result["rows"] if r.get("part") == 1 and "arm" in r) == 5, "the rows so far are kept"
    assert result["summary"]["parts"]["1"]["wholeRounds"] == 0, "a round cut short isn't scored"
    assert result["summary"]["cost"] == pytest.approx(0.005)
