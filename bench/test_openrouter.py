"""Tests for the shared OpenRouter helpers. Run: uv run --with pytest pytest bench"""
import pytest

import openrouter


def test_key_is_the_env_var_else_the_apps_saved_one(tmp_path, monkeypatch):
    secrets = tmp_path / "secrets.json"
    secrets.write_text('{"openrouter-api-key": "sk-saved"}')
    monkeypatch.setattr(openrouter, "SECRETS", secrets)
    monkeypatch.setattr(openrouter.saved_key, "__defaults__", (secrets,))
    monkeypatch.setenv("K", "sk-env")
    assert openrouter.key("K") == "sk-env"
    monkeypatch.delenv("K")
    assert openrouter.key("K") == "sk-saved"
    secrets.unlink()
    with pytest.raises(SystemExit, match=r"set \$K or add one in the app's Settings"):
        openrouter.key("K")


def test_headers_name_the_app():
    assert openrouter.headers("k") == {"Authorization": "Bearer k", "Content-Type": "application/json",
                                       "X-Title": "DictationApp bench"}
