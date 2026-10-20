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

The built-in display, through macOS's DisplayServices. External monitors need DDC, which macOS
doesn't do itself: this says so instead.
"""
import ctypes
import sys

cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
ds = ctypes.CDLL("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
ds.DisplayServicesCanChangeBrightness.argtypes = [ctypes.c_uint32]
ds.DisplayServicesCanChangeBrightness.restype = ctypes.c_bool
ds.DisplayServicesGetBrightness.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_float)]
ds.DisplayServicesSetBrightness.argtypes = [ctypes.c_uint32, ctypes.c_float]


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
