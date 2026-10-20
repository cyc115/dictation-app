#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Set the screen brightness.

Choices:
    +10: a bit brighter
    -10: a bit dimmer
    +30: a lot brighter
    -30: a lot dimmer
    0: lowest
    25: a quarter
    50: half
    75: three quarters
    100: full, max

With BetterDisplay (https://betterdisplay.pro) installed and running: the display the mouse pointer
is on, external monitors too (BetterDisplay does their DDC). Without it: the built-in display,
through macOS's DisplayServices; external monitors need DDC, which macOS doesn't do itself, so this
says so instead.
"""
import ctypes
import subprocess
import sys
from pathlib import Path

BETTERDISPLAY = [Path(p) / "BetterDisplay.app/Contents/MacOS/BetterDisplay"
                 for p in ("/Applications", Path.home() / "Applications")]

cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
ds = ctypes.CDLL("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
ds.DisplayServicesCanChangeBrightness.argtypes = [ctypes.c_uint32]
ds.DisplayServicesCanChangeBrightness.restype = ctypes.c_bool
ds.DisplayServicesGetBrightness.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_float)]
ds.DisplayServicesSetBrightness.argtypes = [ctypes.c_uint32, ctypes.c_float]


class Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


cg.CGEventCreate.restype = ctypes.c_void_p
cg.CGEventCreate.argtypes = [ctypes.c_void_p]
cg.CGEventGetLocation.restype = Point
cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
cg.CGGetDisplaysWithPoint.argtypes = [Point, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
cg.CFRelease.argtypes = [ctypes.c_void_p]


def pointer_display() -> int | None:
    """The display the mouse pointer is on."""
    event = cg.CGEventCreate(None)
    where = cg.CGEventGetLocation(event)
    cg.CFRelease(event)
    ids = (ctypes.c_uint32 * 1)()
    count = ctypes.c_uint32()
    cg.CGGetDisplaysWithPoint(where, 1, ids, ctypes.byref(count))
    return ids[0] if count.value else None


def betterdisplay(*args: str) -> str | None:
    """BetterDisplay's answer to a command, or None if it isn't installed, isn't running or says no."""
    app = next((p for p in BETTERDISPLAY if p.exists()), None)
    if not app:
        return None
    try:
        done = subprocess.run([str(app), *args], capture_output=True, text=True, timeout=4)
    except subprocess.TimeoutExpired:
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def with_betterdisplay(choice: str) -> int | None:
    """Sets the pointer's display through BetterDisplay; the new level, or None to fall back."""
    display = pointer_display()
    if display is None:
        return None
    which = f"-displayID={display}"
    try:
        current = float(betterdisplay("get", which, "-brightness") or "")
    except ValueError:
        return None
    level = target(current * 100, choice)
    if betterdisplay("set", which, f"-brightness={level / 100:.3f}") is None:
        return None
    return round(level)


def displays():
    ids = (ctypes.c_uint32 * 16)()
    count = ctypes.c_uint32()
    cg.CGGetOnlineDisplayList(16, ids, ctypes.byref(count))
    return [ids[i] for i in range(count.value) if ds.DisplayServicesCanChangeBrightness(ids[i])]


def target(current: float, choice: str) -> float:
    """The new level, 0-100, for a choice: +N / -N changes it, N sets it."""
    value = float(choice)
    level = current + value if choice[0] in "+-" else value
    return max(0.0, min(100.0, level))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: brightness.py <choice>", file=sys.stderr)
        return 2
    level = with_betterdisplay(sys.argv[1])
    if level is not None:
        print(f"Brightness {level}%")
        return 0
    shown = displays()
    if not shown:
        print("No display whose brightness macOS can set (external monitors need DDC)", file=sys.stderr)
        return 1
    level = 0.0
    for display in shown:
        now = ctypes.c_float()
        ds.DisplayServicesGetBrightness(display, ctypes.byref(now))
        level = target(now.value * 100, sys.argv[1])
        ds.DisplayServicesSetBrightness(display, level / 100)
    print(f"Brightness {round(level)}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
