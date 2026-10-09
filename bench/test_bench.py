"""Tests for the benchmark's scoring. Run: uv run --with pytest pytest bench"""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("bench", Path(__file__).with_name("bench.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def test_tokens_split_chinese_chars_and_english_words():
    assert bench.tokens("帮我 build 一个，然后 push！") == ["帮", "我", "build", "一", "个", "然", "后", "push"]


def test_tokens_ignore_case_spacing_and_fullwidth_punctuation():
    assert bench.tokens("帮我Build一个") == bench.tokens("帮我 build 一个。")
    assert bench.tokens("ＵＩ") == ["ui"]


def test_tokens_keep_contractions():
    assert bench.tokens("Let's go, it's fine") == ["let's", "go", "it's", "fine"]


def test_error_rate_perfect_and_total_miss():
    assert bench.error_rate("我觉得这个 feature 的 UI 太 ugly 了", "我觉得这个feature的UI太ugly了") == 0
    assert bench.error_rate("hello world", "") == 1


def test_error_rate_counts_substitutions():
    # 2 wrong tokens out of 4
    assert bench.error_rate("帮我 build 一", "帮我定一") == 0.25  # build → 定 (1 sub of 4 tokens)
    assert bench.error_rate("a b c d", "a x c y") == 0.5


def test_english_recall_on_mixed():
    ref = "帮我 build 一个然后 push 到 repository 里"
    assert bench.english_recall(ref, "帮我build一个然后push到repository里") == 1
    assert bench.english_recall(ref, "帮我定一个然后同时到repository里") == 1 / 3
    assert bench.english_recall("今天天气很好", "今天天气很好") is None


def test_english_recall_is_multiset():
    assert bench.english_recall("test 一下 test", "test 一下") == 0.5


def test_summary_aggregates_by_category():
    rows = [
        {"category": "mixed", "error_rate": 0.1, "en_recall": 1.0, "latency": 2.0, "cost": 0.001, "error": None, "audio_seconds": 5},
        {"category": "mixed", "error_rate": 0.3, "en_recall": 0.5, "latency": 4.0, "cost": 0.001, "error": None, "audio_seconds": 5},
        {"category": "chinese", "error_rate": 0.0, "en_recall": None, "latency": 1.0, "cost": 0.0, "error": None, "audio_seconds": 4},
    ]
    s = bench.summarize(rows)
    assert s["mixed"]["accuracy"] == 0.8
    assert s["mixed"]["en_recall"] == 0.75
    assert s["mixed"]["latency_p50"] == 3.0
    assert s["all"]["cases"] == 3
    assert s["all"]["cost_per_audio_hour"] == round(0.002 / 14 * 3600, 4)


def test_normalize_strips_speaker_tags():
    text, trad = bench.normalize("<|speaker:0|>帮我build一个")
    assert text == "帮我build一个" and not trad


def test_normalize_converts_traditional_and_flags_it():
    text, trad = bench.normalize("幫我build一個然後push到repository裡")
    assert text == "帮我build一个然后push到repository里" and trad
    assert bench.error_rate("帮我 build 一个然后 push 到 repository 里", text) == 0


def test_score_case_aggregates_repeats(monkeypatch):
    case = {"id": "x", "category": "mixed", "text": "帮我 build 一下"}
    runs = [{"text": "帮我build一下", "latency": 1.0, "cost": 0.001, "error": None},
            {"text": "帮我定一下", "latency": 3.0, "cost": 0.001, "error": None}]
    monkeypatch.setattr(bench, "wav_seconds", lambda p: 2.0)
    row = bench.score_case(case, runs)
    assert row["error_rate"] == 0.1  # 5 tokens; runs score 0 and 1/5
    assert row["en_recall"] == 0.5
    assert row["latency"] == 2.0 and row["latencies"] == [1.0, 3.0]
    assert row["cost"] == 0.002 and row["runs"] == 2


def _app_recording(directory, stem, transcript, seconds=2.0, model="openrouter:qwen/qwen3-asr-1.7b", error=None):
    """What RecordingArchive writes: a 16 kHz mono WAV and a JSON of what was heard."""
    import json
    bench._write_pcm(directory / f"{stem}.wav", [0] * int(16000 * seconds))
    meta = {"date": "2026-10-08T22:57:11Z", "model": model, "transcript": transcript, "seconds": seconds}
    if error:
        meta["error"] = error
    (directory / f"{stem}.json").write_text(json.dumps(meta, ensure_ascii=False))


def _isolated(monkeypatch, tmp_path):
    audio = tmp_path / "audio"
    audio.mkdir()
    monkeypatch.setattr(bench, "AUDIO", audio)
    monkeypatch.setattr(bench, "RECORDED", tmp_path / "recorded.json")
    app = tmp_path / "Recordings"
    app.mkdir()
    return app, audio


def test_import_recordings_adds_unverified_cases_once(monkeypatch, tmp_path):
    import argparse
    app, audio = _isolated(monkeypatch, tmp_path)
    _app_recording(app, "20261008-225711-123", "帮我 build 一下")
    _app_recording(app, "20261008-225800-000", "今天天气很好")
    _app_recording(app, "20261008-225900-000", "Ship it today", model="apple:en-US")
    _app_recording(app, "20261008-230000-000", "", error="Provider could not process the audio input")
    _app_recording(app, "20261008-230100-000", "嗯", seconds=0.4)  # a tap of the key
    args = argparse.Namespace(dir=str(app), category=None, min_seconds=1.0)
    assert bench.cmd_import_recordings(args) == 0
    cases = {c["id"]: c for c in bench.load_recorded()}
    assert set(cases) == {"rec-20261008-225711-123", "rec-20261008-225800-000", "rec-20261008-225900-000",
                          "rec-20261008-230000-000"}
    first = cases["rec-20261008-225711-123"]
    assert first["category"] == "mixed" and first["verified"] is False and first["source"] == "recorded"
    assert first["heard_by"] == "openrouter:qwen/qwen3-asr-1.7b"
    assert cases["rec-20261008-225800-000"]["category"] == "chinese"
    assert cases["rec-20261008-225900-000"]["category"] == "english"
    assert cases["rec-20261008-230000-000"]["error"].startswith("Provider")
    assert abs(bench.wav_seconds(audio / "rec-20261008-225711-123.wav") - 2.0) < 0.01
    assert not (audio / "rec-20261008-230100-000.wav").exists()
    assert bench.cmd_import_recordings(args) == 0
    assert len(bench.load_recorded()) == 4, "importing again adds nothing"


def test_verify_corrects_text_and_unverified_cases_are_not_scored(monkeypatch, tmp_path):
    import argparse
    app, _ = _isolated(monkeypatch, tmp_path)
    _app_recording(app, "a", "帮我定一下")
    bench.cmd_import_recordings(argparse.Namespace(dir=str(app), category=None, min_seconds=1.0))
    assert any(c["id"] == "rec-a" for c in bench.load_cases())
    bench.cmd_verify(argparse.Namespace(id="rec-a", text="帮我 build 一下", category="mixed"))
    case = bench.load_recorded()[0]
    assert case["verified"] is True and case["text"] == "帮我 build 一下"


def test_run_skips_unverified_recordings(monkeypatch, tmp_path, capsys):
    import argparse
    app, audio = _isolated(monkeypatch, tmp_path)
    for clip in (bench.ROOT / "audio").glob("*.wav"):
        (audio / clip.name).symlink_to(clip)
    _app_recording(app, "a", "hello there friend")
    bench.cmd_import_recordings(argparse.Namespace(dir=str(app), category=None, min_seconds=1.0))
    ran = []
    monkeypatch.setattr(bench, "run_model", lambda m, cases, args, commit: ran.extend(c["id"] for c in cases))
    monkeypatch.setattr(bench, "cmd_report", lambda a: 0)
    monkeypatch.setattr(bench, "RESULTS", tmp_path / "results")
    base = dict(model=["openrouter:x"], category=["english"], level=None, repeat=1, parallel=1,
                key_env="K", json=False)
    bench.cmd_run(argparse.Namespace(**base, include_unverified=False))
    assert "rec-a" not in ran and "english-01" in ran
    assert "skipping 1 unverified" in capsys.readouterr().out
    ran.clear()
    bench.cmd_run(argparse.Namespace(**base, include_unverified=True))
    assert "rec-a" in ran


def test_guess_category():
    assert bench.guess_category("帮我 build 一下") == "mixed"
    assert bench.guess_category("今天天气很好。") == "chinese"
    assert bench.guess_category("Ship it.") == "english"


def test_recordings_never_reach_git():
    import subprocess
    root = Path(__file__).resolve().parents[1]
    for path in ("bench/recorded.json", "bench/audio/rec-20261008-225711-123.wav"):
        assert subprocess.run(["git", "check-ignore", "-q", path], cwd=root).returncode == 0, path
