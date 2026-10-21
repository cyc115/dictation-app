"""Tests for the command-mode suite. Run: uv run --with pytest pytest bench"""
import json

from suites import commands


def test_the_commands_are_the_apps_built_ins():
    found = {c["name"]: c for c in commands.app_commands()}
    assert list(found) == ["return", "repeat", "create", "fix", "open", "brightness", "volume", "lock-screen", "media-control",
                           "open-website", "switch-app"]
    assert list(found["fix"]["choices"])[-2:] == ["switch-app", "none"]
    assert found["volume"]["choices"]["mute"] == "mute"
    assert list(found["brightness"]["choices"])[:2] == ["+10", "-10"]
    assert found["switch-app"]["choices"] == {a: a for a in commands.RUNNING} | {"none": commands.NO_APP}


def test_choices_stop_at_a_blank_line_and_skip_values_with_spaces():
    text = '"""Do it.\n\nChoices:\n    a: one\n    two words: no\n    b: two\n\n    c: after the gap\n"""'
    assert commands.parse_script(text, "x") == {"name": "x", "summary": "Do it.", "choices": {"a": "one", "b": "two"}}
    assert commands.parse_script("print(1)", "x") is None


def test_jev_is_asked_what_the_app_asks():
    body = commands.jev_body("mute", commands.app_commands())
    assert body["model"] == "~typesafe/jev-latest"
    assert body["state"] == "The user said: mute"
    assert set(body["questions"]) == {"command"} | {f"choice:{c['name']}" for c in commands.app_commands() if c["choices"]}
    assert "choice:media-control" in body["questions"]
    assert body["questions"]["command"]["criteria"]["none"] == "None of these does what the user asked"


def test_scores_right_wrong_runs_and_misses():
    case = {"expect": ["volume -10", "volume -30"]}
    assert commands.score(case, "volume -30") == "right"
    assert commands.score(case, "brightness -10") == "wrong-run"
    assert commands.score(case, "none") == "missed"
    assert commands.score({"expect": ["none"]}, "volume mute") == "wrong-run"


def test_every_case_expects_commands_that_exist():
    known = {c["name"]: c for c in commands.commands_for(catalog=False)}
    for case in json.loads(commands.CASES.read_text())["cases"]:
        for label in case["expect"]:
            if label == "none":
                continue
            name, _, choice = label.partition(" ")
            assert name in known, label
            assert (choice in known[name]["choices"]) if choice else not known[name]["choices"], label


def test_the_catalog_adds_distinct_commands():
    names = [c["name"] for c in commands.commands_for(catalog=True)]
    assert len(names) == len(set(names)) == len(commands.BUILT_IN) + len(json.loads(commands.CATALOG.read_text())["commands"])


def test_open_lists_the_installed_apps(tmp_path):
    (tmp_path / "Safari.app").mkdir()
    (tmp_path / "notes.txt").write_text("")
    assert commands.installed_apps([tmp_path, tmp_path / "missing"]) == ["Safari"]
    found = {c["name"]: c for c in commands.app_commands(apps=["Ghostty", "Safari"], running=["Safari"])}
    assert found["switch-app"]["choices"] == {"Safari": "Safari", "none": commands.NO_APP}
    assert found["open"]["choices"] == {"Ghostty": "Ghostty", "Safari": "Safari", "none": commands.NO_APP}
