"""Tests for the turnaround latency suite. Run: uv run --with pytest pytest bench"""
import json
import re
from pathlib import Path

import pytest

import harness
from suites import SUITES, latency

REPO = Path(__file__).resolve().parents[1]


def case(cid, category, seconds):
    return {"id": cid, "category": category, "seconds": seconds}


@pytest.fixture
def fake_durations(monkeypatch):
    monkeypatch.setattr(latency, "clip_seconds", lambda c: c["seconds"])


def test_aliases_match_the_apps_models():
    """flash/big must name the models the app actually ships (TranscriptionModel raw values)."""
    swift = (REPO / "Sources/DictationKit/Transcription.swift").read_text()
    shipped = set(re.findall(r'case \w+ = "(openrouter:[^"]+)"', swift))
    assert {latency.STT_ALIASES["flash"][0], latency.STT_ALIASES["big"][0]} == shipped
    locales = set(re.findall(r'case \w+ = "([a-z]{2}-[A-Z]{2})"', swift))
    assert {latency.STT_ALIASES["local"][0], latency.STT_ALIASES["local-zh"][0]} == {f"apple:{l}" for l in locales}


def test_plan_matches_what_the_app_decodes():
    """The keys suite.py sends must be exactly LatencyTrial's / LatencyPlan's fields."""
    swift = (REPO / "Sources/DictationKit/LatencyProbe.swift").read_text()
    fields = lambda name: set(re.findall(r"let (\w+):", re.search(rf"struct {name}\b.*?\n}}", swift, re.S).group(0)))
    assert fields("LatencyTrial") == {"id", "file", "stt", "polish"}
    assert fields("LatencyPlan") == {"pause", "timeout", "trials"}
    src = (REPO / "bench/suites/latency.py").read_text()
    assert '("id", "file", "stt", "polish")' in src and '{"pause": pause, "timeout": timeout, "trials"' in src


def test_resolves_model_names():
    assert latency.resolve_stt("flash") == "openrouter:qwen/qwen3-asr-1.7b"
    assert latency.resolve_stt("apple:zh-CN") == "apple:zh-CN"
    assert latency.resolve_stt("openrouter:deepgram/nova-3") == "openrouter:deepgram/nova-3"
    with pytest.raises(SystemExit):
        latency.resolve_stt("whisper")
    assert latency.check_polish("openrouter:anthropic/claude-haiku-5.5")
    with pytest.raises(SystemExit):
        latency.check_polish("gpt")


def test_default_clips_span_short_to_long_in_every_category(fake_durations):
    cases = [case(f"{cat}-{i}", cat, i) for cat in ("mixed", "chinese", "english") for i in range(1, 8)]
    cases.append({**case("mixed-noisy", "mixed", 99), "level": 3})
    picked = latency.default_clips(cases)
    assert [c["id"] for c in picked] == ["mixed-1", "mixed-4", "mixed-7", "chinese-1", "chinese-4", "chinese-7",
                                         "english-1", "english-4", "english-7"]


def test_default_clips_on_the_real_cases_include_the_long_dictations():
    picked = {c["id"] for c in latency.default_clips(harness.load_cases())}
    assert {"long-mixed-01", "long-english-01"} <= picked
    assert len(picked) == 9


def test_on_device_models_get_clips_in_their_language(fake_durations):
    clips = [case("m", "mixed", 3), case("c", "chinese", 4), case("e1", "english", 2), case("e2", "english", 9)]
    assert [c["id"] for c in latency.clips_for("apple:en-US", clips)] == ["e1", "e2", "e1", "e2"]
    assert [c["id"] for c in latency.clips_for("apple:zh-CN", clips)] == ["m", "c", "m", "c"]
    assert latency.clips_for("openrouter:x", clips) == clips
    only_chinese = [case("c", "chinese", 4)]
    assert latency.clips_for("apple:en-US", only_chinese) == only_chinese


def test_plan_has_warmups_then_equal_interleaved_rounds(fake_durations):
    clips = [case("e1", "english", 2), case("m1", "mixed", 5), case("c1", "chinese", 1)]
    stt = ["apple:en-US", "openrouter:a"]
    trials = latency.plan_trials(stt, ["none", "apple", "openrouter:p"], clips, rounds=4, warmup=1, seed=3)
    warm = [t for t in trials if t["warmup"]]
    assert [(t["stt"], t["clip"]) for t in warm] == [("apple:en-US", "e1"), ("openrouter:a", "c1")]
    assert trials[:2] == warm, "warm-ups go first"
    measured = [t for t in trials if not t["warmup"]]
    for s in stt:
        assert sum(t["stt"] == s for t in measured) == 3 * 4, "same sample count per speech model"
    assert {t["clip"] for t in measured if t["stt"] == "apple:en-US"} == {"e1"}
    assert len({t["id"] for t in trials}) == len(trials)
    for t in trials:
        assert sorted(t["polish"]) == ["apple", "openrouter:p"], "'none' isn't sent to the app"
    assert len({tuple(t["polish"]) for t in trials}) == 2, "polish order is shuffled"
    assert trials == latency.plan_trials(stt, ["none", "apple", "openrouter:p"], clips, 4, 1, 3)


def row(stt, transcribe, polish=None, warmup=False, error=None, audio=3.0):
    return {"id": "x", "round": 0 if warmup else 1, "warmup": warmup, "clip": "c", "audio_seconds": audio,
            "stt": stt, "transcribe": transcribe, "raw": "" if transcribe is None else "text", "error": error,
            "polish": {k: {"seconds": v, "text": "", "error": None if v is not None else "failed"}
                       for k, v in (polish or {}).items()}}


def test_summary_turnaround_is_per_dictation_sum_and_errors_are_counted_not_timed():
    rows = [
        row("s", 9.0, {"apple": 9.0}, warmup=True),
        row("s", 1.0, {"apple": 0.5}),
        row("s", 2.0, {"apple": 0.25}),
        row("s", 3.0, {"apple": None}),             # polish failed
        row("s", None, {"apple": None}, error="HTTP 500"),  # transcription failed
    ]
    s = latency.summarize(rows, ["s"], ["none", "apple"])
    t = s["transcription"]["s"]
    assert (t["n"], t["errors"], t["min"], t["max"], t["cold"]) == (3, 1, 1.0, 3.0, 9.0)
    p = s["polish"]["apple"]
    assert (p["n"], p["errors"], p["p50"]) == (2, 1, 0.375), "a failed transcription isn't a polish error"
    assert s["turnaround"]["s + none"]["p50"] == 2.0
    both = s["turnaround"]["s + apple"]
    assert (both["n"], both["errors"], both["min"], both["max"], both["cold"]) == (2, 2, 1.5, 2.25, 18.0)


def test_summary_by_length():
    rows = [row("s", 1.0, audio=3), row("s", 2.0, audio=7), row("s", 4.0, audio=25), row("s", 6.0, audio=30)]
    by = latency.summarize(rows, ["s"], ["none"])["transcription_by_length"]["s"]
    assert by["< 5 s"]["p50"] == 1.0 and by["5–10 s"]["p50"] == 2.0 and by["≥ 10 s"]["p50"] == 5.0


def test_merge_marks_missing_samples_as_errors():
    trials = [{"id": "0", "round": 1, "warmup": False, "clip": "c", "audio_seconds": 3, "stt": "s", "polish": ["apple"]},
              {"id": "1", "round": 1, "warmup": False, "clip": "c", "audio_seconds": 3, "stt": "s", "polish": ["apple"]}]
    # The app's JSON: nil optionals are left out.
    samples = [{"id": "0", "transcribe": 0.4, "raw": "hi", "polish": [{"model": "apple", "seconds": 0.8, "text": "Hi."}]}]
    rows = latency.merge(trials, samples)
    assert rows[0]["transcribe"] == 0.4 and rows[0]["error"] is None
    assert rows[0]["polish"]["apple"] == {"seconds": 0.8, "text": "Hi.", "error": None}
    assert rows[1]["error"] == "no result" and rows[1]["transcribe"] is None


def test_simulated_run_saves_and_reports(tmp_path, capsys):
    assert SUITES["latency"].main(["run", "--simulate", "-r", "2", "--clip", "english-01", "--clip", "mixed-01",
                                   "-s", "flash", "-s", "local", "-P", "none", "-P", "apple", "--out", str(tmp_path)]) == 0
    saved = list(tmp_path.glob("*.json"))
    assert len(saved) == 1
    result = json.loads(saved[0].read_text())
    assert result["simulated"] and result["config"]["rounds"] == 2
    assert result["summary"]["transcription"]["openrouter:qwen/qwen3-asr-1.7b"]["n"] == 4
    assert result["summary"]["turnaround"]["apple:en-US + apple"]["n"] == 4
    capsys.readouterr()
    assert latency.main(["report", "--file", str(saved[0]), "--markdown", "--by-length"]) == 0
    out = capsys.readouterr().out
    assert "SIMULATED" in out and "### Turnaround" in out and "| Cloud Flash + Apple on-device |" in out
    assert "*" in out, "4 samples: p95 is flagged as rough"


def test_app_runner_refuses_off_macos(monkeypatch):
    monkeypatch.setattr(latency.platform, "system", lambda: "Linux")
    with pytest.raises(SystemExit, match="Mac"):
        latency.run_in_app([], 0.3, 90, None, lambda s, i: None)


def test_stale_app_build_fails_fast_instead_of_timing_out(monkeypatch, tmp_path):
    """An app built before LatencyProbe ignores the plan: say so within seconds, don't wait out the stall timer."""
    import subprocess
    app = tmp_path / "DictationApp.app"
    app.mkdir()
    monkeypatch.setattr(latency, "APP", app)
    monkeypatch.setattr(latency, "STARTUP_SECONDS", 0.3)
    monkeypatch.setattr(latency.platform, "system", lambda: "Darwin")
    launched = []
    def fake_run(cmd, **kw):
        launched.append(cmd[0])
        return subprocess.CompletedProcess(cmd, 1, b"", b"")  # pgrep: not running; open: ignored
    monkeypatch.setattr(latency.subprocess, "run", fake_run)
    trial = {"id": "0", "file": "a.wav", "stt": "openrouter:m", "polish": [], "audio_seconds": 3}
    with pytest.raises(SystemExit, match="older than this checkout"):
        latency.run_in_app([trial], 0, 90, None, lambda s, i: None)
    assert "open" in launched and launched[-1] == "pkill", "the probe instance is cleaned up"


def test_run_with_no_finished_dictations_saves_nothing(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(latency, "simulate", lambda trials, seed, show: [])
    assert latency.main(["run", "--simulate", "-r", "1", "--clip", "english-01", "-s", "flash",
                         "--out", str(tmp_path)]) == 1
    assert not list(tmp_path.glob("*.json"))
    assert "nothing saved" in capsys.readouterr().out


def test_recorded_clips_only_with_the_flag(monkeypatch, tmp_path):
    import argparse
    mine = {"id": "rec-1", "category": "mixed", "source": "recorded", "text": "", "verified": False}
    monkeypatch.setattr(harness, "load_cases", lambda: harness.json.loads(harness.CASES.read_text())["cases"] + [mine])
    monkeypatch.setattr(latency, "clip_seconds", lambda c: 99.0 if c["id"] == "rec-1" else harness.wav_seconds(harness.AUDIO / f"{c['id']}.wav"))
    real_exists = Path.exists
    monkeypatch.setattr(Path, "exists", lambda p: p.name == "rec-1.wav" or real_exists(p))
    args = argparse.Namespace(clip=None, all_clips=False, recorded=False)
    assert "rec-1" not in {c["id"] for c in latency.select_clips(args)}, "default set stays fixed"
    args.recorded = True
    assert [c["id"] for c in latency.select_clips(args)] == ["rec-1"]


def test_only_cloud_flash_by_default(monkeypatch, capsys):
    monkeypatch.setattr(latency, "estimate_seconds", lambda trials, pause: 0)
    latency.main(["run", "--dry-run", "--clip", "english-01"])
    assert "1 speech model(s)" in capsys.readouterr().out
    planned = []
    monkeypatch.setattr(latency, "plan_trials", lambda stt, *a: planned.append(stt) or [])
    flash, big, local = ("openrouter:qwen/qwen3-asr-1.7b", "openrouter:meta/muse-voice-transcribe-1.0", "apple:en-US")
    for argv in ([], ["--big"], ["--local"], ["--local", "--big"], ["-s", "big"], ["-s", "big", "--big"]):
        latency.main(["run", "--dry-run", "--clip", "english-01", *argv])
    assert planned == [[flash], [flash, big], [flash, local], [flash, local, big], [big], [big]]


def test_report_counts_fallback_answers():
    flash = "openrouter:qwen/qwen3-asr-1.7b"
    rows = [row(flash, 1.0), row(flash, 3.2), row(flash, 3.5), row(flash, 9.0, warmup=True)]
    rows[1]["answered_by"] = rows[2]["answered_by"] = "openrouter:qwen/qwen3-asr-0.6b"
    rows[0]["answered_by"] = flash
    rows[3]["answered_by"] = "openrouter:qwen/qwen3-asr-0.6b"  # warm-ups don't count
    s = latency.summarize(rows, [flash], ["none"])
    assert s["fallbacks"][flash] == {"count": 2, "of": 3, "models": ["openrouter:qwen/qwen3-asr-0.6b"]}
    result = {"summary": s, "config": {"clips": ["a"], "rounds": 1}, "run_at": "t", "env": {}}
    assert "Cloud Flash: 2 of 3 dictations answered by the fallback" in latency.report_text(result)


def test_merge_keeps_which_model_answered():
    trials = [{"id": "0", "round": 1, "warmup": False, "clip": "c", "audio_seconds": 3, "stt": "s", "polish": []}]
    rows = latency.merge(trials, [{"id": "0", "transcribe": 3.1, "raw": "hi", "answeredBy": "openrouter:b"}])
    assert rows[0]["answered_by"] == "openrouter:b"
