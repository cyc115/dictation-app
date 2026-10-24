"""What every benchmark that calls OpenRouter shares: the key, checking it, a JSON POST, and the
reasoning settings to fall back through (the app's OpenRouterPolish.reasoning rule, tried in order)."""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from pathlib import Path

# The bench's own key, kept apart from the app's so its spend shows separately; set in ~/.secrets
# (chezmoi), which shells source.
BENCH_ENV = "OPENROUTER_BENCH_API_KEY"
DOT_SECRETS = Path.home() / ".secrets"
CHAT = "https://openrouter.ai/api/v1/chat/completions"
# Lowest reasoning settings to try, in order, for models that can't turn it off.
REASONING_FALLBACKS = [{"enabled": False}, {"effort": "minimal"}, {"effort": "low"}]


def secrets_file_key(name: str, path: Path = DOT_SECRETS) -> str:
    """`export <name>=<value>` from ~/.secrets, for a shell that hasn't sourced it; "" if it's not there."""
    try:
        text = path.read_text()
    except OSError:
        return ""
    found = re.search(rf"^\s*(?:export\s+)?{re.escape(name)}=([\"']?)(.*?)\1\s*$", text, re.MULTILINE)
    return found.group(2) if found else ""


def key(env: str = BENCH_ENV) -> str:
    """$env, else its line in ~/.secrets; exits saying how to add it if neither. Never the app's own key."""
    found = os.environ.get(env) or secrets_file_key(env)
    if not found:
        raise SystemExit(f"no OpenRouter key for the bench: add `export {env}=…` to ~/.secrets (chezmoi)")
    return found


def key_problem(key: str) -> str | None:
    """Why OpenRouter won't take this key, checked once before a run; None if it's fine
    (or OpenRouter couldn't be reached, which the requests themselves will report)."""
    req = urllib.request.Request("https://openrouter.ai/api/v1/key", headers={"Authorization": f"Bearer {key}"})
    try:
        urllib.request.urlopen(req, timeout=15).close()
        return None
    except urllib.error.HTTPError as e:
        try:
            message = json.loads(e.read()).get("error", {}).get("message", "")
        except Exception:
            message = ""
        return f"HTTP {e.code}{': ' + message if message else ''}" if e.code in (401, 402, 403) else None
    except Exception:
        return None


def headers(key: str, content_type: str = "application/json") -> dict[str, str]:
    return {"Authorization": f"Bearer {key}", "Content-Type": content_type, "X-Title": "DictationApp bench"}


def post_json(url: str, body: dict, key: str, timeout: float = 30) -> dict:
    """POSTs `body`, returns the JSON answer; an HTTP error raises RuntimeError with OpenRouter's reason."""
    request = urllib.request.Request(url, json.dumps(body).encode(), headers(key))
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        raise RuntimeError(f"HTTP {e.code}: {detail}") from None
