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
                                       "HTTP-Referer": "http://dictation-app-bench.mac/",
                                       "X-OpenRouter-Title": "DictationApp bench",
                                       "X-Title": "DictationApp bench",
                                       "X-OpenRouter-App-Visibility": "hidden"}


def test_the_key_check_names_the_app_too(monkeypatch):
    # The key check is a run's first OpenRouter request, so it carries the attribution headers as well.
    sent = []

    def fake_urlopen(req, timeout=None):
        sent.append(req)
        raise OSError("offline")

    monkeypatch.setattr(openrouter.urllib.request, "urlopen", fake_urlopen)
    assert openrouter.key_problem("k") is None
    headers = {k.lower(): v for k, v in sent[0].header_items()}
    assert headers["authorization"] == "Bearer k"
    assert headers["http-referer"] == "http://dictation-app-bench.mac/"
    assert headers["x-openrouter-app-visibility"] == "hidden"


def test_error_message_is_openrouters_reason_or_nothing():
    """One reader for a failed request's reason (key_problem, polish, edits)."""
    import io
    import urllib.error

    def failed(body: bytes) -> urllib.error.HTTPError:
        return urllib.error.HTTPError("https://openrouter.ai", 402, "Payment Required", {}, io.BytesIO(body))

    assert openrouter.error_message(failed(b'{"error": {"message": "No credits."}}')) == "No credits."
    assert openrouter.error_message(failed(b'{"error": {}}')) == ""
    assert openrouter.error_message(failed(b"<html>bad gateway</html>")) == "", "not JSON"
    assert openrouter.error_message(failed(b'{"error": "flat"}')) == "", "an error that isn't an object"
