#!/usr/bin/env python3
"""Rebuilds the keyboard's word lists (app/src/main/assets/dict/) from AOSP, both Apache-2.0.

  en.txt  word<TAB>frequency (0-255, AOSP LatinIME's log scale), most frequent first
  zh.txt  words<TAB>frequency<TAB>pinyin syllables (space-separated), from AOSP PinyinIME

Run: python3 android/scripts/build-dicts.py  (fetches the pinned commits below; no other deps)
"""
import base64
import gzip
import re
import urllib.request
from pathlib import Path

LATIN = ("https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/"
         "127336e9f29d69607eab55982324b210279ae8c5/dictionaries/en_US_wordlist.combined.gz?format=TEXT")
PINYIN = ("https://android.googlesource.com/platform/packages/inputmethods/PinyinIME/+/"
          "49aebad1c1cfbbcaa9288ffed5161e79e57c3679/jni/data/rawdict_utf16_65105_freq.txt?format=TEXT")
OUT = Path(__file__).resolve().parent.parent / "app/src/main/assets/dict"
EN_WORDS = 60_000  # enough for swipe and completions; each 10k more is ~100 KB and slower decoding
SKIP_FLAGS = {"offensive", "nonword"}


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as r:  # googlesource serves file bytes base64-encoded
        return base64.b64decode(r.read())


def english() -> list[str]:
    words = []
    for line in gzip.decompress(fetch(LATIN)).decode().splitlines():
        m = re.match(r" word=([^,]+),f=(\d+),flags=([^,]*)", line)
        if m and m.group(3) not in SKIP_FLAGS and re.fullmatch(r"[A-Za-z][A-Za-z']*", m.group(1)):
            words.append((m.group(1), int(m.group(2))))
    words.sort(key=lambda w: -w[1])  # stable: AOSP's order breaks ties
    return [f"{w}\t{f}" for w, f in words[:EN_WORDS]]


def chinese() -> list[str]:
    rows = []
    for line in fetch(PINYIN).decode("utf-16").splitlines():
        parts = line.split()
        if len(parts) >= 4:
            word, freq, syllables = parts[0], float(parts[1]), parts[3:]
            rows.append((word, freq, " ".join(syllables)))
    rows.sort(key=lambda r: -r[1])
    return [f"{w}\t{f:.0f}\t{p}" for w, f, p in rows if f >= 1]


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, lines in (("en.txt", english()), ("zh.txt", chinese())):
        (OUT / name).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"{name}: {len(lines)} entries")
