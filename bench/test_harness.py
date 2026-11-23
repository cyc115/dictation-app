"""Tests for the shared benchmark harness. Run: uv run --with pytest pytest bench"""
import json

import harness


def test_percentile_interpolates_like_numpy():
    xs = [4, 1, 3, 2]  # unsorted on purpose
    assert harness.percentile(xs, 50) == 2.5
    assert abs(harness.percentile(xs, 90) - 3.7) < 1e-9
    assert abs(harness.percentile(xs, 95) - 3.85) < 1e-9
    assert harness.percentile(xs, 0) == 1 and harness.percentile(xs, 100) == 4
    assert harness.percentile([7], 95) == 7
    assert harness.percentile([], 50) is None


def test_percentile_on_twenty_samples():
    xs = list(range(1, 21))  # 1..20
    assert harness.percentile(xs, 50) == 10.5
    assert abs(harness.percentile(xs, 95) - 19.05) < 1e-9


def test_describe():
    s = harness.describe([0.5, 1.0, 1.5, 2.0], errors=2)
    assert s["n"] == 4 and s["errors"] == 2
    assert (s["min"], s["p50"], s["max"], s["mean"]) == (0.5, 1.25, 2.0, 1.25)
    empty = harness.describe([], errors=3)
    assert empty["n"] == 0 and empty["p50"] is None and empty["stdev"] is None


def test_interleave_runs_every_item_once_per_round_in_a_reproducible_order():
    items = list("abcdef")
    order = harness.interleave(items, rounds=3, seed=7)
    assert len(order) == 18
    for rnd in (1, 2, 3):
        assert sorted(x for r, x in order if r == rnd) == items
    assert order == harness.interleave(items, rounds=3, seed=7)
    assert [x for r, x in order if r == 1] != [x for r, x in order if r == 2], "each round reshuffles"
    assert order != harness.interleave(items, rounds=3, seed=8)


def test_table_text_and_markdown():
    text = harness.table(["model", "p50"], [["a", "0.50"], ["long name", "1.25"]])
    assert text.splitlines()[0] == "model       p50"
    assert text.splitlines()[3] == "long name  1.25"
    md = harness.table(["model", "p50"], [["a", "0.50"]], markdown=True)
    assert md.splitlines() == ["| model | p50 |", "|:--|--:|", "| a | 0.50 |"]


def test_save_and_find_results(tmp_path):
    first = harness.save_result("latency", "Cloud Flash/qwen", {"x": 1}, tmp_path)
    assert first.name.endswith("_cloud_flash_qwen.json")
    assert json.loads(first.read_text()) == {"x": 1}
    assert harness.result_files("latency", tmp_path) == [first]


def test_environment_records_code_version_but_not_the_hostname():
    import platform
    env = harness.environment()
    assert env["commit"] and "os" in env
    assert platform.node() not in env.values()


def test_estimate_tokens_and_prices():
    assert harness.estimate_tokens("我们") == 2 and harness.estimate_tokens("abcdefgh") == 2
    table = {"a/b": (1.0, 2.0)}
    assert harness.read_prices(None, table) == table and harness.read_prices(None, table) is not table
    assert harness.read_prices(["openrouter:x/y=0.5,1.5"], table, lambda m: m.removeprefix("openrouter:"))["x/y"] == (0.5, 1.5)
    import pytest
    for bad in ("x/y=cheap", "x/y=1", "x/y=1,2,3", "x/y"):
        with pytest.raises(SystemExit, match="use MODEL=IN,OUT"):
            harness.read_prices([bad], table)
    assert harness.read_prices(["x/y=1,2,3"], table, two=False)["x/y"] == (1.0, 2.0, 3.0), "the history suite's lenient read"
