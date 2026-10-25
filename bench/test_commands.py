"""Tests for the command-mode suite. Run: uv run --with pytest pytest bench"""
import json

from suites import commands


def test_the_commands_are_the_apps_built_ins():
    found = {c["name"]: c for c in commands.app_commands()}
    assert list(found) == ["return", "repeat", "create", "fix", "open", "brightness", "volume", "lock-screen", "media-control",
                           "open-website", "switch-app", "ask-muse"]
    assert list(found["fix"]["choices"])[-2:] == ["ask-muse", "none"]
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
    assert body["state"] == commands.HEARD + "\nThe user said: mute"
    assert commands.HEARD in commands.chat_prompt(commands.app_commands())
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


def test_a_local_decider_is_asked_the_command_then_its_choice(monkeypatch):
    asked = []

    def fake_post(url, body, key):
        asked.append((url, list(body["questions"])))
        (name,) = body["questions"]
        return {"answers": {name: {"choice": "volume", "confidence": 0.9} if name == "command" else {"choice": "mute"}}}

    monkeypatch.setattr(commands, "post_json", fake_post)
    cmds = commands.app_commands(apps=[])
    assert commands.ask("local:kev", "mute", cmds, "") == ("volume mute", None, {"confidence": 0.9})
    assert asked == [(commands.LOCAL["kev"]["url"], ["command"]), (commands.LOCAL["kev"]["url"], ["choice:volume"])]
    assert commands.local_question("mute", cmds, "volume") == {
        "choice:volume": commands.jev_body("mute", cmds)["questions"]["choice:volume"]}


def test_a_local_pick_under_the_cut_off_is_none_and_laya_uses_jevs_confidence(monkeypatch):
    monkeypatch.setattr(commands, "post_json", lambda url, body, key: {"answers": {"command": {
        "choice": "volume", "confidence": 0.9, "x_jev_confidence": 0.3}}})
    assert commands.ask("local:laya", "mute", commands.app_commands(apps=[]), "")[0] == "none"


def test_a_run_without_a_cut_off_can_be_scored_with_one():
    answers = [{"expect": ["volume mute"], "got": "volume mute", "confidence": 0.4, "error": None, "score": "right"},
               {"expect": ["none"], "got": "return", "confidence": 0.3, "error": None, "score": "wrong-run"},
               {"expect": ["none"], "got": "none", "error": "timeout", "score": "error"}]
    assert [a["score"] for a in commands.at_cutoff(answers, 0.5)] == ["missed", "right", "error"]
    assert [a["score"] for a in commands.at_cutoff(answers, 0.35)] == ["right", "right", "error"]


def test_jev_variants_change_only_what_they_name():
    cmds = commands.app_commands(apps=["Safari"])
    assert commands.jev_model("jev") == set() and commands.jev_model("jev+bare+warm") == {"bare", "warm"}
    assert commands.jev_model("jev+fast") is None and commands.jev_model("local:kev") is None
    assert commands.jev_body("mute", cmds, set()) == commands.jev_body("mute", cmds)
    bare = commands.jev_body("open safari", cmds, {"bare"})["questions"]
    assert bare["choice:open"]["criteria"] == {"Safari": None, "none": commands.NO_APP}
    assert bare["choice:brightness"]["criteria"] == commands.jev_body("x", cmds)["questions"]["choice:brightness"]["criteria"]
    worded = commands.jev_body("mute", cmds, {"heard-command", "none-noise"})
    assert worded["state"] == commands.JEV_HEARD["heard-command"] + "\nThe user said: mute"
    assert worded["questions"]["command"]["criteria"]["none"] == commands.JEV_NONE["none-noise"]
