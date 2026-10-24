"""Tests for the shared OpenRouter helpers. Run: uv run --with pytest pytest bench"""
import pytest

import openrouter


def test_key_is_the_env_var_else_its_line_in_dot_secrets_never_the_apps(tmp_path, monkeypatch):
    secrets = tmp_path / ".secrets"
    secrets.write_text('export OPENROUTER_API_KEY=sk-app\nexport K="sk-file"\n')
    monkeypatch.setattr(openrouter.secrets_file_key, "__defaults__", (secrets,))
    monkeypatch.setenv("K", "sk-env")
    assert openrouter.key("K") == "sk-env"
    monkeypatch.delenv("K")
    assert openrouter.key("K") == "sk-file", "a shell that hasn't sourced ~/.secrets"
    secrets.write_text("export OPENROUTER_API_KEY=sk-app\n")
    with pytest.raises(SystemExit, match=r"add `export K=…` to ~/.secrets"):
        openrouter.key("K")


def test_the_bench_has_its_own_key():
    assert openrouter.BENCH_ENV == "OPENROUTER_BENCH_API_KEY"


def test_headers_name_the_app():
    assert openrouter.headers("k") == {"Authorization": "Bearer k", "Content-Type": "application/json",
                                       "X-Title": "DictationApp bench"}
