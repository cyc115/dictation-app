#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Set the sound volume, or mute it.

Choices:
    +10: a bit louder
    -10: a bit quieter
    +30: a lot louder
    -30: a lot quieter
    0: silent
    25: a quarter
    50: half
    75: three quarters
    100: full, max
    mute: mute
    unmute: unmute

The current output device, through AppleScript's volume settings.
"""
import re
import subprocess
import sys


def osascript(script: str) -> str:
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=True).stdout.strip()


def target(current: int, choice: str) -> int:
    """The new level, 0-100, for a choice: +N / -N changes it, N sets it."""
    value = int(choice)
    level = current + value if choice[0] in "+-" else value
    return max(0, min(100, level))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: volume.py <choice>", file=sys.stderr)
        return 2
    choice = sys.argv[1]
    if choice in ("mute", "unmute"):
        osascript(f"set volume output muted {'true' if choice == 'mute' else 'false'}")
        print("Muted" if choice == "mute" else "Unmuted")
        return 0
    settings = osascript("get volume settings")
    found = re.search(r"output volume:(\d+)", settings)
    if not found:
        print("This output's volume can't be set", file=sys.stderr)
        return 1
    level = target(int(found.group(1)), choice)
    osascript(f"set volume output volume {level} without output muted")
    print(f"Volume {level}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
