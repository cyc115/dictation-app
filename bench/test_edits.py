"""Tests for the fix-judge suite (suites/edits.py). Run: uv run --with pytest pytest bench"""
import json
import math
import re
from types import SimpleNamespace

import pytest

from suites import edits

FIXTURE = json.loads((edits.CASES.parent / "judge_message_fixture.json").read_text())


def test_the_message_is_the_apps():
    """The app (FixJudge.message) and the bench send the judge the same message; both assert the fixture."""
    for m in FIXTURE["messages"]:
        items = [{"wrote": i["wrote"], "target": i["wanted"], "changes": i["changes"]} for i in m["items"]]
        assert edits.message(items, m["terms"]) == (m["prefix"], m["rest"])


def test_answers_are_read_as_the_app_reads_them():
    for a in FIXTURE["answers"]:
        assert edits.parse(a["text"], a["changes"]) == a["verdicts"], a["about"]
    assert edits.parse("{}", []) == []
    assert edits.parse('{"fixes": [{"fix": true, "verdicts": ["style"]}]}', [1]) == [None], "a bool isn't a number"


def test_the_instructions_are_the_apps_file():
    text = edits.instructions()
    assert text == edits.INSTRUCTIONS.read_text().strip()
    assert all(v in text for v in edits.VERDICTS)


def test_cases_are_well_formed():
    terms, cases = edits.load()
    assert terms and len(cases) >= 40
    assert len({c["id"] for c in cases}) == len(cases)
    assert {c["category"] for c in cases} == {"english", "chinese", "mixed"}
    labels = [ch["verdict"] for c in cases for ch in c["changes"]]
    assert set(labels) == set(edits.VERDICTS), "every verdict is tested"
    for c in cases:
        assert c["wrote"] and c["target"] and c["wrote"] != c["target"] and c["changes"], c["id"]
        for ch in c["changes"]:
            assert ch["old"] and ch["new"] and ch["old"] != ch["new"], c["id"]


def test_the_request_is_the_apps():
    items = [{"wrote": "I use cloud", "target": "I use Claude", "changes": [{"old": "cloud", "new": "Claude"}]}]
    body = edits.request_body("anthropic/claude-sonnet-5.5", items, ["Claude"], {"enabled": False}, "P")
    assert body["temperature"] == 0 and body["reasoning"] == {"enabled": False}
    assert body["messages"][0] == {"role": "system", "content": "P"}
    parts = body["messages"][1]["content"]
    assert parts[0] == {"type": "text", "text": "Vocabulary terms: Claude\n\n", "cache_control": {"type": "ephemeral"}}
    assert parts[1]["text"].startswith('<fix n="1">')
    plain = edits.request_body("google/gemini-3.8-flash", items, [], None, "P")
    assert plain["messages"][1]["content"].startswith("Vocabulary terms: (none)\n\n<fix")
    assert "reasoning" not in plain


def test_batches_come_from_one_seeded_shuffle():
    _, cases = edits.load()
    ones, tens = edits.batches(cases, 1, 7), edits.batches(cases, 10, 7)
    assert len(ones) == len(cases) and len(tens) == math.ceil(len(cases) / 10)
    assert [b[0]["id"] for b in ones] == [c["id"] for b in tens for c in b], "same order, cut differently"
    assert edits.batches(cases, 10, 7) == tens, "seeded"
    assert edits.batches(cases, 10, 8) != tens


def test_scoring_counts_what_the_answer_left_out_as_wrong():
    cases = [{"id": "a", "changes": [{"verdict": "misheard"}, {"verdict": "changedMind"}]},
             {"id": "b", "changes": [{"verdict": "style"}]},
             {"id": "c", "changes": [{"verdict": "unclear"}]}]
    s = edits.score(cases, {"a": ["misheard", "misheard"], "b": None, "c": ["unclear"]})
    assert s["changes"] == 4 and s["accuracy"] == 0.5 and s["coverage"] == 0.75
    assert s["recall"] == {"misheard": 1.0, "style": 0.0, "changedMind": 0.0, "unclear": 1.0}
    assert s["misheard_precision"] == 0.5, "a change of mind called misheard"


def fake_send(answer_for=lambda body: None, cost=0.0005):
    """A sender that answers each request with the labels (or `answer_for`), and keeps what it was sent."""
    sent = []
    _, cases = edits.load()
    by_text = {c["wrote"]: c for c in cases}

    def send(body, key, timeout):
        sent.append(body)
        content = body["messages"][1]["content"]
        text = content if isinstance(content, str) else "".join(p["text"] for p in content)
        wrote = [line[len("wrote: "):] for line in text.splitlines() if line.startswith("wrote: ")]
        answer = answer_for(body) or json.dumps({"fixes": [{"fix": n, "verdicts": [ch["verdict"] for ch in by_text[w]["changes"]]}
                                                           for n, w in enumerate(wrote, 1)]})
        return {"seconds": 0.4, "text": answer, "cost": cost, "prompt_tokens": 900, "completion_tokens": 40}
    return send, sent


def args(**kw):
    base = dict(model=None, batch=None, dry_run=False, price=None, case=None, cases_file=None, parallel=2, timeout=5,
                seed=1, key_env="X", label="test", out=None)
    return SimpleNamespace(**{**base, **kw})


def test_a_run_scores_each_model_and_batch_size_and_adds_up_the_cost(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(edits.openrouter, "key", lambda env: "k")
    monkeypatch.setattr(edits, "key_problem", lambda key: None)
    send, sent = fake_send()
    _, cases = edits.load()
    assert edits.cmd_run(args(out=str(tmp_path)), send=send) == 0
    assert len(sent) == len(cases) + math.ceil(len(cases) / 10)
    result = json.loads(next(tmp_path.glob("*.json")).read_text())
    summary = result["summary"]
    assert set(summary) == {f"{edits.DEFAULT_MODEL}@1", f"{edits.DEFAULT_MODEL}@10"}
    assert all(v["accuracy"] == 1.0 and v["coverage"] == 1.0 for v in summary.values())
    assert summary[f"{edits.DEFAULT_MODEL}@10"]["cost"] == pytest.approx(0.0005 * math.ceil(len(cases) / 10))
    out = capsys.readouterr().out
    assert "estimated total ≈ $" in out
    assert f"total cost ${0.0005 * len(sent):.4f}" in out


def test_a_malformed_answer_covers_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(edits.openrouter, "key", lambda env: "k")
    monkeypatch.setattr(edits, "key_problem", lambda key: None)
    send, _ = fake_send(answer_for=lambda body: "Here you go: misheard, style")
    edits.cmd_run(args(out=str(tmp_path), batch=[10]), send=send)
    s = json.loads(next(tmp_path.glob("*.json")).read_text())["summary"][f"{edits.DEFAULT_MODEL}@10"]
    assert s["coverage"] == 0.0 and s["accuracy"] == 0.0


def test_dry_run_estimates_and_sends_nothing(monkeypatch, capsys):
    def no_key(env):
        raise AssertionError("a dry run reads no key")
    monkeypatch.setattr(edits.openrouter, "key", no_key)
    send, sent = fake_send()
    assert edits.cmd_run(args(dry_run=True, model=["anthropic/claude-sonnet-5.5", "google/gemini-3.8-flash"]), send=send) == 0
    assert sent == []
    out = capsys.readouterr().out
    assert "dry run: nothing sent" in out
    assert "gemini-3.8-flash @ 1" in out and "price unknown" in out
    assert "+ the unpriced models" in out


def test_the_estimate_prices_tokens(monkeypatch):
    _, cases = edits.load()
    terms = ["Claude"]
    rows = edits.estimate(["openrouter:a/b"], [1, 10], cases, terms, 1, {"a/b": (1.0, 2.0)})
    one, ten = rows
    assert one["requests"] == len(cases) and ten["requests"] == math.ceil(len(cases) / 10)
    assert one["prompt_tokens"] > ten["prompt_tokens"], "batching shares the instructions"
    assert one["cost"] == pytest.approx((one["prompt_tokens"] * 1 + one["completion_tokens"] * 2) / 1e6)
    assert edits.estimate_tokens("我们") == 2 and edits.estimate_tokens("abcdefgh") == 2
    assert edits.read_prices(["openrouter:x/y=0.5,1.5"])["x/y"] == (0.5, 1.5)
    with pytest.raises(SystemExit):
        edits.read_prices(["x/y=cheap"])


def test_reasoning_is_asked_as_the_app_asks_it():
    """OpenRouterJudge: off, or minimal for OpenRouter.mustThink's models; once more at minimal if the
    model says reasoning is mandatory."""
    swift = (edits.harness.ROOT.parent / "Sources/DictationKit/App/OpenRouter.swift").read_text()
    assert f'static let mustThink = [{", ".join(chr(34) + m + chr(34) for m in edits.MUST_THINK)}]' in swift
    sent = []

    def send(body, key, timeout):
        sent.append(body.get("reasoning"))
        if body["reasoning"] == {"enabled": False}:
            return {"error": "HTTP 400: Reasoning is mandatory for this endpoint and cannot be disabled."}
        return {"seconds": 0.3, "text": "{}", "cost": 1e-6}

    item = [{"wrote": "a", "target": "b", "changes": [["a", "b"]]}]
    call = edits.Caller("m/x", "k", [], "P", 5, send)
    assert call(item)["reasoning"] == {"effort": "minimal"}
    call(item)
    assert sent == [{"enabled": False}, {"effort": "minimal"}, {"effort": "minimal"}], "remembered"
    assert edits.Caller("openai/gpt-6-luna", "k", [], "P", 5, send).reasoning == {"effort": "minimal"}
    sent.clear()

    def refuses(body, key, timeout):
        sent.append(body.get("reasoning"))
        return {"error": "HTTP 400: reasoning not supported"}

    assert "error" in edits.Caller("m/y", "k", [], "P", 5, refuses)(item)
    assert sent == [{"enabled": False}], "only the app's one fallback"


def test_failures_show_what_was_judged_wrong():
    cases = [{"id": "a", "changes": [{"old": "Tuesday", "new": "Thursday", "verdict": "changedMind"}]}]
    result = {"cases": cases, "trials": [{"model": "openrouter:m/x", "batch": 10, "cases": ["a"], "verdicts": {"a": ["misheard"]}}]}
    text = edits.failures_text(result, "m/x@10")
    assert "Tuesday → Thursday" in text and "wanted ['changedMind'], got ['misheard']" in text


def swift_default(setting: str) -> str:
    """A setting's default in Settings.swift, following `Type.member` to that member's string literal anywhere in the app."""
    sources = edits.harness.ROOT.parent / "Sources/DictationKit"
    found = re.search(rf'@Setting\("{setting}", default: ([^)]+)\)', (sources / "Settings/Settings.swift").read_text())
    assert found, f"{setting} not found in Settings.swift"
    value = found.group(1).strip()
    if value.startswith('"'):
        return value.strip('"')
    owner, _, member = value.rpartition(".")
    for path in sources.rglob("*.swift"):
        text = path.read_text()
        if re.search(rf"\b(class|struct|enum|extension)\s+{owner}\b", text):
            literal = re.search(rf'static let {member}\s*=\s*"([^"]*)"', text)
            if literal:
                return literal.group(1)
    raise AssertionError(f"couldn't follow {value}")


def test_the_default_model_is_the_judges():
    """judgeModel's default, followed from Settings.swift to its string (today FixJudge.defaultModel)."""
    assert edits.DEFAULT_MODEL == "openrouter:" + swift_default("judgeModel")
