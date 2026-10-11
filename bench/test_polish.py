"""Tests for the AI polish suite. Run: uv run --with pytest pytest bench"""
import json

import pytest

from suites import polish


def test_prompt_versions_match_their_benchmark_files():
    """The app sends exactly the prompts that were benchmarked (PolishPrompt in Setups.swift)."""
    for version in ("v1", "v2", "v3", "v4"):
        benchmarked = (polish.CASES.parent / f"polish_prompts/{version}.txt").read_text().strip()
        assert polish.prompt_text(version) == benchmarked, version
    v1 = polish.prompt_text("v1")
    assert v1.startswith("Clean up dictated text: remove filler words (um, uh, like, you know), collapse")
    assert "\n" not in v1 and "\\" not in v1


def test_reads_the_apps_setups_and_their_prompts(tmp_path):
    built_in = polish.setups(tmp_path / "none.json")
    assert list(built_in) == ["on-device", "cloud-flash", "cloud-big"]
    assert all(s["prompt"] == "v3" and s["wrap"] for s in built_in.values())
    assert polish.resolve("setup:on-device", "ignored", False) == ("apple", polish.prompt_text("v3"), True)
    assert polish.resolve("setup:cloud-big")[0] == "openrouter:openai/gpt-oss-120b@Groq"
    assert polish.app_prompt("apple") == polish.app_prompt("openrouter:x") == polish.prompt_text("v3")
    assert polish.resolve("openrouter:m") == ("openrouter:m", polish.prompt_text("v3"), True)
    assert polish.resolve("openrouter:m", "P", False) == ("openrouter:m", "P", False)
    with pytest.raises(SystemExit, match="unknown setup"):
        polish.resolve("setup:nope")


def test_custom_setups_and_prompt_files(tmp_path, monkeypatch):
    prompt = tmp_path / "mine.txt"
    prompt.write_text("Only fix typos.\n")
    custom = tmp_path / "setups.json"
    custom.write_text(json.dumps({"setups": [{"id": "mine", "title": "Mine", "speech": "apple", "polish": "apple",
                                              "prompt": str(prompt), "wrap": False}]}))
    monkeypatch.setattr(polish, "CUSTOM_SETUPS", custom)
    monkeypatch.setattr(polish.setups, "__defaults__", (custom,))
    assert polish.resolve("setup:mine") == ("apple", "Only fix typos.", False)
    assert polish.resolve("setup:on-device")[0] == "apple", "built-ins are still there"


SETS = ["polish_cases.json", "polish_cases_holdout.json", "polish_cases_hard.json", "polish_cases_hard_holdout.json"]


def all_cases():
    return [c for name in SETS for c in polish.load_cases(polish.CASES.parent / name)]


def test_every_expected_output_passes_its_own_checks():
    for case in all_cases():
        assert polish.check(case, case["expected"])["passed"], case["id"]
        assert not polish.check(case, case["raw"])["passed"] or case["kind"] in ("trap", "clean"), case["id"]


def test_cases_are_well_formed():
    cases = all_cases()
    assert len({c["id"] for c in cases}) == len(cases)
    for c in cases:
        assert c["category"] in ("english", "chinese", "mixed") and c["kind"] in ("filler", "correction", "trap", "clean", "term")
        assert c["raw"] and c["expected"] and isinstance(c["must"], list) and isinstance(c["must_not"], list)


def test_latin_checks_match_whole_words_and_chinese_matches_substrings():
    assert polish.contains("Um, send it", "um") and not polish.contains("an umbrella", "um")
    assert polish.contains("I'll be there", "I'll") and not polish.contains("Bill", "I'll")
    assert polish.contains("把文件发给李娜。", "李娜") and polish.contains("cost $2 a month", "$2")
    assert polish.contains("它的latency哪个更高", "latency") and not polish.contains("它的latency哪个", "late")


def test_check_reports_what_went_wrong():
    case = {"expected": "Send the report to Priya by Friday.", "must": ["Priya", "Friday"], "must_not": ["Sarah"]}
    assert polish.check(case, "Send the report to Priya by Friday")["passed"]
    bad = polish.check(case, "Send the report to Sarah sorry I mean to Priya by Friday")
    assert bad["kept"] == ["Sarah"] and not bad["passed"]
    answered = polish.check(case, "Sure! Here's a draft email to Priya about the report, due Friday: Hi Priya, ...")
    assert not answered["passed"] and answered["error"] > polish.MAX_ERROR
    assert not polish.check(case, "")["passed"]


def test_error_rate_ignores_punctuation_and_case_and_counts_chinese_characters():
    assert polish.error_rate("Let's meet at 4 pm.", "let's meet at 4 PM") == 0
    assert polish.error_rate("把文件发给李娜。", "把文件发给李娜") == 0
    assert polish.error_rate("我们下周见", "我们下周再见") == pytest.approx(1 / 5)


def test_model_specs_and_request_body():
    assert polish.parse_spec("openrouter:openai/gpt-oss-20b@Groq") == ("openai/gpt-oss-20b", "Groq")
    assert polish.parse_spec("openrouter:google/gemini-2.5-flash-lite") == ("google/gemini-2.5-flash-lite", None)
    with pytest.raises(SystemExit):
        polish.parse_spec("apple")
    pinned = polish.request_body("m", "hi", "P", "Groq", "latency", {"enabled": False})
    assert pinned["provider"] == {"order": ["Groq"], "allow_fallbacks": False}, "a pin wins over --sort"
    assert pinned["temperature"] == 0 and pinned["messages"][0] == {"role": "system", "content": "P"}
    assert polish.request_body("m", "hi", "P", None, "latency", None)["provider"] == {"sort": "latency"}
    assert "reasoning" not in polish.request_body("m", "hi", "P", None, None, None)
    wrapped = polish.request_body("m", "hi", "P", None, None, None)
    assert wrapped["messages"][1]["content"] == "<transcript>\nhi\n</transcript>", "wrapped by default"
    plain = polish.request_body("m", "hi", "P", None, None, None, wrap=False)
    assert plain["messages"][1]["content"] == "hi"


def test_caller_steps_down_to_the_lowest_reasoning_the_model_accepts():
    sent = []

    def fake(body, key, timeout):
        sent.append(body.get("reasoning"))
        if body["reasoning"] in ({"enabled": False}, {"effort": "minimal"}):
            return {"error": "HTTP 400: Reasoning is mandatory for this endpoint and cannot be disabled."}
        return {"seconds": 0.3, "first": 0.2, "text": "ok", "provider": "Groq", "cost": 1e-6}

    call = polish.Caller("openrouter:m", "k", "P", None, 5, send=fake)
    assert call("hi")["reasoning"] == {"effort": "low"}
    assert sent == [{"enabled": False}, {"effort": "minimal"}, {"effort": "low"}]
    call("again")
    assert sent[-1] == {"effort": "low"}, "remembered: no retries on later requests"


def test_plan_warms_up_each_model_then_shuffles_rounds():
    cases = [{"id": i, "raw": "x" * n} for i, n in (("a", 5), ("b", 2), ("c", 9))]
    jobs = polish.plan(["m1", "m2"], cases, rounds=2, seed=1)
    assert [(r, c["id"]) for r, s, c in jobs if s == "m1" and r == 0] == [(0, "b")], "warm-up: the shortest case"
    assert sorted(c["id"] for r, s, c in jobs if s == "m1" and r == 1) == ["a", "b", "c"]
    assert len(jobs) == 2 * (1 + 2 * 3)


def test_summary_and_report(tmp_path, capsys):
    rows = []
    for i, (secs, passed) in enumerate([(0.3, True), (0.5, True), (0.4, False), (9.0, True)]):
        rows.append({"model": "openrouter:m", "round": 0 if i == 3 else 1, "warmup": i == 3, "case": f"c{i}",
                     "category": "mixed", "kind": "trap" if i == 2 else "filler", "seconds": secs, "first": secs / 2,
                     "text": "t", "provider": "Groq", "cost": 2e-5, "check": {"passed": passed, "error": 0.1}})
    rows.append({"model": "openrouter:m", "round": 1, "warmup": False, "case": "c9", "category": "english",
                 "kind": "filler", "error": "HTTP 500"})
    s = polish.summarize(rows)["openrouter:m"]
    assert (s["n"], s["errors"], s["passed"], s["by_kind"]["trap"]) == (4, 1, round(2 / 3, 3), 0.0)
    assert s["seconds"]["max"] == 0.5, "the warm-up isn't timed"
    assert s["cost_per_1000"] == 0.02 and s["providers"] == ["Groq"]
    result = {"run_at": "t", "env": {}, "config": {"cases": ["c0"], "rounds": 1}, "summary": {"openrouter:m": s},
              "trials": rows}
    assert "67%" in polish.report_text(result)
    path = tmp_path / "r.json"
    path.write_text(json.dumps(result))
    assert polish.main(["report", "--file", str(path)]) == 0
    assert "pass" in capsys.readouterr().out


def test_apple_runs_through_the_app_with_text_trials(monkeypatch):
    from suites import latency
    sent = {}

    def fake_app(trials, pause, timeout, key_env, on_sample, extra):
        sent.update(trials=trials, extra=extra)
        for i, t in enumerate(trials):
            polished = t["text"].replace("嗯", "") if i != 1 else None
            on_sample({"id": t["id"], "transcribe": 0, "raw": t["text"],
                       "polish": [{"model": "apple", "seconds": 0.8, "text": polished}
                                  if polished is not None else {"model": "apple", "error": "unavailable"}]}, i + 1)
        return []

    monkeypatch.setattr(latency, "run_in_app", fake_app)
    cases = [c for c in polish.load_cases() if c["id"] in ("zh-short-filler", "mixed-ok")]
    rows = polish.run(["apple"], cases, 1, 1, "", None, 1, 30, lambda row: None, prompt="P", wrap=True)
    assert sent["extra"] == {"instructions": "P", "wrap": True}
    assert all(t["stt"] == "text" and t["polish"] == ["apple"] and t["text"] for t in sent["trials"])
    assert [r["warmup"] for r in rows] == [True, False, False]
    assert rows[1]["error"] == "unavailable" and "check" in rows[2] and rows[2]["cost"] == 0.0
    default = polish.run(["apple"], cases[:1], 1, 1, "", None, 1, 30, lambda row: None)
    assert default[0]["model"] == "apple"
    assert sent["extra"] == {"wrap": True} and len(default) == 2, "the app's own prompt, in tags like the app"
    polish.run(["apple"], cases[:1], 1, 1, "", None, 1, 30, lambda row: None, wrap=False)
    assert sent["extra"] == {"wrap": False}, "--no-wrap reaches the app, whose default is to wrap"
    as_shipped = polish.run(["setup:on-device"], cases[:1], 1, 1, "", None, 1, 30, lambda row: None, prompt="P", wrap=False)
    assert sent["extra"] == {"wrap": True}, "a setup runs as the app does: its prompt and tags, not the overrides"
    assert {r["model"] for r in as_shipped} == {"setup:on-device"}


def test_apple_stops_the_run_when_the_installed_app_is_too_old(monkeypatch):
    from suites import latency
    calls = []

    def old_app(trials, pause, timeout, key_env, on_sample, extra):
        on_sample({"id": trials[0]["id"], "error": "unknown speech model text"}, 1)

    monkeypatch.setattr(latency, "run_in_app", old_app)
    monkeypatch.setattr(polish, "stream", lambda *a: calls.append(a) or {"error": "should not run"})
    cases = polish.load_cases()[:2]
    with pytest.raises(SystemExit, match="older than this checkout"):
        polish.run(["apple", "openrouter:m"], cases, 1, 1, "k", None, 2, 30, lambda row: None)
    assert calls == [], "no cloud requests once Apple shows the build is stale"


def test_a_rejected_key_stops_the_run_before_any_polish(monkeypatch, capsys):
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-v1-revoked")
    monkeypatch.setattr(polish, "key_problem", lambda key: "HTTP 401: User not found.")
    monkeypatch.setattr(polish, "run", lambda *a, **k: pytest.fail("ran with a rejected key"))
    with pytest.raises(SystemExit, match=r"rejected \$OPENROUTER_API_KEY .*unset OPENROUTER_API_KEY"):
        polish.main(["run", "-m", "openai/gpt-oss-120b@Groq", "--case", "en-clean"])


def test_quick_set_is_twenty_main_cases_covering_every_language_and_kind():
    quick = [c for c in polish.load_cases() if c.get("quick")]
    assert len(quick) == 20
    for field, values in (("category", ("english", "chinese", "mixed")), ("kind", ("filler", "correction", "trap", "clean"))):
        assert {c[field] for c in quick} == set(values), field
    assert sum(c["category"] == "mixed" for c in quick) >= 6, "mixed speech is the main use"
    assert sum(len(c["raw"]) > 80 for c in quick) >= 2, "long dictations, for latency"
    holdout = polish.load_cases(polish.CASES.parent / "polish_cases_holdout.json")
    assert not any(c.get("quick") for c in holdout), "the held-out set stays unseen"


def test_saved_key_is_read_from_the_apps_secrets_file(tmp_path):
    secrets = tmp_path / "secrets.json"
    assert polish.saved_key(secrets) == "", "no file: no key"
    secrets.write_text(json.dumps({"openrouter-api-key": "sk-or-v1-test"}))
    assert polish.saved_key(secrets) == "sk-or-v1-test"


def test_corrections_in_history_json_are_cases(tmp_path):
    history = tmp_path / "history.json"
    history.write_text(json.dumps([
        {"id": "AB12CD34-0000-4000-8000-000000000001", "date": "2026-10-08T03:18:00Z", "duration": 2,
         "text": "Can you install Cloud Code?", "raw": "can you install cloud code", "setup": "cloud-flash",
         "prompt": "v3", "correction": "Can you install Claude Code?"},
        {"id": "AB12CD34-0000-4000-8000-000000000002", "date": "2026-10-07T03:18:00Z", "duration": 1,
         "text": "Not corrected."},
        {"id": "EF56AB78-0000-4000-8000-000000000003", "date": "2026-10-06T03:18:00Z", "duration": 1,
         "text": "Saved before raw was kept.", "correction": "Saved before raw was kept!"},
    ]))
    cases = polish.load_cases(history)
    assert [c["id"] for c in cases] == ["correction-ab12cd34", "correction-ef56ab78"]
    assert cases[0]["raw"] == "can you install cloud code" and cases[0]["expected"] == "Can you install Claude Code?"
    assert cases[1]["raw"] == "Saved before raw was kept.", "no raw: what the app wrote stands in"
    assert polish.check(cases[0], "Can you install Claude Code?")["passed"]
    assert not polish.check(cases[0], "Sure, here's how to install Claude Code: …")["passed"]


def test_hard_sets_are_thirty_and_twenty_and_expect_simplified_chinese():
    hard = polish.load_cases(polish.CASES.parent / "polish_cases_hard.json")
    holdout = polish.load_cases(polish.CASES.parent / "polish_cases_hard_holdout.json")
    assert (len(hard), len(holdout)) == (30, 20)
    traditional = set("們這個說們覺測試實對還麼")
    for c in hard + holdout:
        assert not traditional & set(c["expected"]), f"{c['id']}: the speaker never writes Traditional characters"
