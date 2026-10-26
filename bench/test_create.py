"""Tests for the create-command suite. Run: uv run --with pytest pytest bench"""
import json
from pathlib import Path

from suites import commands, create

REPO = Path(__file__).resolve().parents[1]


def test_the_prompt_is_the_apps_with_the_commands_but_not_create():
    prompt = create.system_prompt(commands.app_commands())
    assert "- volume: Set the sound volume, or mute it (choices: +10 = a bit louder, " in prompt
    assert "- switch-app: Switch to another app that's already open, by name\n" in prompt
    assert "- create:" not in prompt
    assert "- open: Open an app installed on this Mac (not a website)\n" in prompt
    assert "{commands}" not in prompt
    assert prompt.startswith(create.PROMPT.read_text().split("{commands}")[0])


def test_reads_existing_or_a_named_script():
    assert create.parse_reply("EXISTING: volume\n") == {"existing": "volume"}
    reply = 'NAME: battery\n```python\n"""Battery."""\nprint(1)\n```\n'
    assert create.parse_reply(reply) == {"name": "battery", "script": '"""Battery."""\nprint(1)\n'}
    assert create.parse_reply("print(1)") == {}


def test_checks_stop_at_the_first_problem():
    cmds = commands.app_commands()
    new = {"expect": "new"}
    script = '"""Say the battery level."""\nprint("Battery 80%")\n'
    assert create.check(new, f"NAME: battery\n```python\n{script}```", cmds, False)["score"] == "ok"
    assert create.check(new, "EXISTING: volume", cmds, False)["score"] == "existing"
    assert create.check({"expect": "volume"}, "EXISTING: volume", cmds, False)["score"] == "ok"
    assert create.check(new, f"NAME: Battery_Level\n```python\n{script}```", cmds, False)["score"] == "name"
    assert create.check(new, f"NAME: volume\n```python\n{script}```", cmds, False)["score"] == "name"
    assert create.check(new, "NAME: battery\n```python\nprint(1)\n```", cmds, False)["score"] == "docstring"
    assert create.check(new, 'NAME: battery\n```python\n"""B."""\nif True print(1)\n```', cmds, False)["score"] == "syntax"
    assert create.check(new, "Sure!", cmds, False)["score"] == "format"


def test_the_suite_asks_as_the_apps_writer_does():
    """The constants that mirror CommandWriter and CommandMode (model, providers, name rule, time limit)."""
    writer = (REPO / "Sources/DictationKit/Commands/CommandWriter.swift").read_text()
    mode = (REPO / "Sources/DictationKit/Commands/CommandMode.swift").read_text()
    assert f'static let model = "{create.MODEL.removeprefix("openrouter:")}"' in writer
    assert "static let providers = " + json.dumps(create.PROVIDERS) in writer
    assert f'#"{create.NAME_PATTERN.pattern}"#' in writer
    assert f"static let timeout: TimeInterval = {create.TIMEOUT}\n" in mode
