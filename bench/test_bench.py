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
