#!/usr/bin/env -S uv run -q --with pillow python
"""The README's animations (docs/images/*.gif), one per feature, from the real app: the recording pill
and Settings as Tests/DictationKitTests/ReadmeFrames.swift renders them, and the snapshot-test PNGs for
windows. All fixture data at a fixed scale, so nothing from this Mac shows.

  scripts/readme-gifs.py list                     # the scenes
  scripts/readme-gifs.py render                   # all of them
  scripts/readme-gifs.py render commands pill     # some
  scripts/readme-gifs.py render --frames DIR      # reuse frames from an earlier render (faster)

Rerun after changing the pill, Settings, or re-recording snapshots.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SNAP = ROOT / "Tests/DictationKitTests/__Snapshots__"
OUT = ROOT / "docs/images"
SF = "/System/Library/Fonts/SFNS.ttf"
CJK = "/System/Library/Fonts/Hiragino Sans GB.ttc"  # Latin and Chinese
GRADIENT = ((86, 100, 196), (132, 104, 192))  # gentle: a wide gradient bands in a 256-color GIF
# Colors that must come out exact, not the nearest of a small palette: the window buttons, the
# system blue, the pill's green, yellow and red edges, command mode's blue, and the charts' speaking,
# transcribing and polishing colors.
EXACT = [(255, 95, 87), (254, 188, 46), (40, 200, 64), (0, 122, 255), (52, 199, 89), (255, 204, 0),
         (255, 59, 48), (127, 160, 255), (255, 255, 255), (29, 29, 31), (0, 136, 255), (203, 48, 224),
         (255, 141, 40)]


# ---------------------------------------------------------------- drawing

def background(w: int, h: int, colors=GRADIENT) -> Image.Image:
    """Soft diagonal gradient (a 2×2 image, scaled up smoothly)."""
    top, bottom = colors
    mid = tuple((a + b) // 2 for a, b in zip(top, bottom))
    seed = Image.new("RGB", (2, 2))
    seed.putdata([top, mid, mid, bottom])
    return seed.resize((w, h), Image.BILINEAR).convert("RGBA")


def font(text: str, size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    if any("　" <= c <= "鿿" or "＀" <= c <= "￯" for c in text):
        return ImageFont.truetype(CJK, size, index=1 if bold else 0)
    f = ImageFont.truetype(SF, size)
    try:
        f.set_variation_by_name("Semibold" if bold else "Regular")
    except (OSError, ValueError):
        pass
    return f


def window(img: Image.Image, title_h: int = 56, radius: int = 24) -> Image.Image:
    """`img` in a plain macOS window: grey title bar with the three buttons, rounded corners."""
    w, h = img.size
    win = Image.new("RGBA", (w, h + title_h), (255, 255, 255, 255))
    d = ImageDraw.Draw(win)
    d.rectangle([0, 0, w, title_h], fill=(236, 236, 236, 255))
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx = 30 + i * 36
        d.ellipse([cx - 11, title_h // 2 - 11, cx + 11, title_h // 2 + 11], fill=c + (255,))
    win.alpha_composite(img.convert("RGBA"), (0, title_h))
    mask = Image.new("L", win.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, win.width - 1, win.height - 1], radius, fill=255)
    win.putalpha(mask)
    return win


def place(canvas: Image.Image, layer: Image.Image, xy, shadow: int = 40, opacity: float = 1.0) -> None:
    """`layer` at `xy` over a soft drop shadow (blurred on a padded patch, not the whole canvas)."""
    if opacity < 1:
        layer = layer.copy()
        layer.putalpha(layer.getchannel("A").point(lambda v: int(v * opacity)))
    if shadow:
        pad = shadow * 3
        patch = Image.new("RGBA", (layer.width + 2 * pad, layer.height + 2 * pad), (0, 0, 0, 0))
        blob = Image.new("RGBA", layer.size, (0, 0, 0, 255))
        blob.putalpha(layer.getchannel("A").point(lambda v: int(v * 0.35)))
        patch.paste(blob, (pad, pad + shadow // 2), blob)
        patch = patch.filter(ImageFilter.GaussianBlur(shadow))
        canvas.alpha_composite(patch, (int(xy[0]) - pad, int(xy[1]) - pad))
    canvas.alpha_composite(layer, (int(xy[0]), int(xy[1])))


def caption(canvas: Image.Image, text: str, center_x: int, y: int, size: int = 44) -> None:
    """A dark rounded chip with white text, centered on `center_x`."""
    if not text:
        return
    f = font(text, size, bold=True)
    left, top, right, bottom = f.getbbox(text)
    w, h = right - left + 64, size + 40
    chip = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(chip)
    d.rounded_rectangle([0, 0, w - 1, h - 1], h // 2, fill=(20, 20, 28, 170))
    d.text((32 - left, (h - size) // 2 - top + 4), text, font=f, fill=(255, 255, 255, 255))
    canvas.alpha_composite(chip, (center_x - w // 2, y))


def title(canvas: Image.Image, text: str, xy, size: int = 64) -> None:
    ImageDraw.Draw(canvas).text(xy, text, font=font(text, size, bold=True), fill=(255, 255, 255, 255))


def save_gif(images: list[Image.Image], durations: list[int], name: str, width: int) -> None:
    """One palette for every frame, no dithering, so unchanged areas stay identical and each frame
    stores only what moved. The palette is cut from the first frame plus, twice over, what changes
    in the others (else the big background takes every color and the small moving parts come out
    wrong), with `EXACT` added."""
    frames = [im.convert("RGB").resize((width, im.height * width // im.width), Image.LANCZOS) for im in images]
    first = frames[0]
    changed = [f.crop(box) for f in frames[:: max(1, len(frames) // 32)]
               if (box := ImageChops.difference(f, first).getbbox())]
    tiles = [first] + changed * 2
    key = Image.new("RGB", (max(t.width for t in tiles), sum(t.height for t in tiles)))
    y = 0
    for t in tiles:
        key.paste(t, (0, y))
        y += t.height
    cut = key.quantize(colors=256 - len(EXACT), method=Image.Quantize.MEDIANCUT).getpalette()[:(256 - len(EXACT)) * 3]
    palette = Image.new("P", (1, 1))
    palette.putpalette(cut + [c for rgb in EXACT for c in rgb])
    gif = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
    durations = list(durations)
    durations[-1] += 900  # a rest before it loops
    out = OUT / f"{name}.gif"
    out.parent.mkdir(parents=True, exist_ok=True)
    gif[0].save(out, save_all=True, append_images=gif[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"{out.relative_to(ROOT)}: {len(gif)} frames, {sum(durations) / 1000:.1f} s, {out.stat().st_size / 1e6:.1f} MB")


# ---------------------------------------------------------------- frames from the app

def render_frames(directory: Path) -> None:
    """Runs ReadmeFrames, which writes each scene's frames under `directory`."""
    run = subprocess.run(["swift", "test", "--filter", "ReadmeFrames"], cwd=ROOT,
                         env={**os.environ, "README_FRAMES": str(directory)}, capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit("ReadmeFrames failed:\n" + run.stdout[-3000:] + run.stderr[-3000:])


def frames(directory: Path, scene: str) -> tuple[Path, list[dict]]:
    index = directory / scene / "frames.json"
    if not index.exists():
        sys.exit(f"no frames for {scene} in {directory}: render without --frames")
    return directory / scene, json.loads(index.read_text())["frames"]


def pill_layers(directory: Path, scene: str, zoom: float = 2):
    """Per frame: (pill image or None, shadow, opacity, caption, dx, ms), the pill fading in and out
    as the app's does."""
    folder, index = frames(directory, scene)
    last, shadow, hidden_for, shown_for = None, True, 0, 0
    for f in index:
        if f["file"]:
            img = Image.open(folder / f["file"]).convert("RGBA")
            last = img.resize((int(img.width * zoom), int(img.height * zoom)), Image.LANCZOS)
            shadow, hidden_for = f["shadow"], 0
            shown_for += 1
            opacity = min(1.0, shown_for / 3)  # fades in over ~0.12 s
        else:
            hidden_for += 1
            shown_for = 0
            opacity = max(0.0, 1 - hidden_for / 4)  # fades out over ~0.15 s
        yield (last if opacity > 0 else None), shadow, opacity, f.get("caption", ""), f.get("dx", 0) * zoom, f["ms"]


# ---------------------------------------------------------------- scenes

def scene_hero(directory: Path) -> None:
    """Dictating: a Bluetooth mic starts, goes live, you talk, it polishes; History and Insights behind."""
    W, H = 2400, 1640
    base = background(W, H)
    place(base, window(Image.open(SNAP / "history.png").crop((0, 0, 1520, 560))), (120, 90))
    place(base, window(Image.open(SNAP / "insights-breakdown.png")), (1040, 760))
    images, durations = [], []
    for pill, shadow, opacity, _, dx, ms in pill_layers(directory, "hero"):
        canvas = base.copy()
        if pill:
            place(canvas, pill, (568 - pill.width // 2 + dx, 1120 - pill.height // 2), shadow=24 if shadow else 0, opacity=opacity)
        images.append(canvas)
        durations.append(ms)
    save_gif(images, durations, "hero", 1200)


def pill_on_stage(directory: Path, scene: str, name: str, heading: str, behind: Image.Image | None = None,
                  W: int = 2000, H: int = 900, pill_y: int | None = None) -> None:
    """The pill scene `scene`, large, over a gradient (and `behind`, a window), its caption below."""
    base = background(W, H)
    title(base, heading, (80, 60))
    if behind is not None:
        place(base, behind, ((W - behind.width) // 2, 190))
    pill_y = pill_y or H // 2 + 20
    images, durations = [], []
    for pill, shadow, opacity, text, dx, ms in pill_layers(directory, scene, zoom=2.6):
        canvas = base.copy()
        if pill:
            place(canvas, pill, (W // 2 - pill.width // 2 + dx, pill_y - pill.height // 2), shadow=24 if shadow else 0, opacity=opacity)
        caption(canvas, text, W // 2, pill_y + 190)
        images.append(canvas)
        durations.append(ms)
    save_gif(images, durations, name, 1000)


def scene_pill(directory: Path) -> None:
    """The recording bar: starting, live, a better mic, no sound, then transcribing."""
    pill_on_stage(directory, "pill", "pill", "The recording bar tells you what's happening")


def scene_commands(directory: Path) -> None:
    """Command mode: one command runs, one doesn't fit; History › Commands behind."""
    history = window(Image.open(SNAP / "history-commands.png").crop((0, 0, 1520, 660)))
    history = history.resize((history.width * 3 // 4, history.height * 3 // 4), Image.LANCZOS)
    pill_on_stage(directory, "commands", "commands", "Command mode: say it, it runs", behind=history,
                  W=2000, H=1500, pill_y=1080)


def scene_on_device(directory: Path) -> None:
    """Settings › Speech model: picking On-device downloads the model, with progress, then it's ready."""
    folder, index = frames(directory, "on-device")
    W, H = 2000, 900
    base = background(W, H)
    title(base, "On-device: download once, nothing leaves your Mac", (80, 60))
    images, durations = [], []
    for f in index:
        panel = Image.open(folder / f["file"]).convert("RGBA").crop((0, 0, 1280, 390))
        canvas = base.copy()
        place(canvas, window(panel), ((W - panel.width) // 2, 190))
        caption(canvas, f["caption"], W // 2, 720)
        images.append(canvas)
        durations.append(f["ms"])
    save_gif(images, durations, "on-device", 1000)


def crossfade(stills: list[tuple[Image.Image, str, int]], name: str, heading: str, W: int, H: int, top: int = 190) -> None:
    """Each (image, caption, ms) held, then faded into the next over ~0.4 s."""
    base = background(W, H)
    title(base, heading, (80, 60))
    composed = []
    for img, text, _ in stills:
        canvas = base.copy()
        place(canvas, window(img), ((W - img.width) // 2, top))
        caption(canvas, text, W // 2, H - 150)
        composed.append(canvas)
    images, durations = [], []
    for i, (canvas, (_, _, hold)) in enumerate(zip(composed, stills)):
        images.append(canvas)
        durations.append(hold)
        following = composed[(i + 1) % len(composed)]
        for step in range(1, 6):
            images.append(Image.blend(canvas, following, step / 6))
            durations.append(70)
    save_gif(images, durations, name, 1000)


def scene_learn(directory: Path) -> None:
    """Corrections → Learn: your corrections tune the polish prompt, and it's scored before you keep it."""
    crop = lambda name: Image.open(SNAP / f"{name}.png").convert("RGBA").crop((0, 0, 1520, 1000))  # noqa: E731
    crossfade([(crop("learn-first-run"), "Correct a few dictations", 1800),
               (crop("learn-ready"), "Learn: a new polish prompt from them", 1800),
               (crop("learn-done"), "Scored before you keep it", 2600)],
              "learn", "Learns from your corrections", 2000, 1500)


def scene_analytics(directory: Path) -> None:
    """Detailed analytics: recent dictations' waits, model by model, panned top to bottom."""
    full = Image.open(SNAP / "recent-latency.png").convert("RGBA")
    view_h = 1000
    W, H = 2000, 1450
    base = background(W, H)
    title(base, "Detailed analytics: where the wait went", (80, 60))
    steps = 40
    images, durations = [], []
    stops = [0] * 12 + [int((full.height - view_h) * i / steps) for i in range(steps + 1)] + [full.height - view_h] * 14
    for y in stops:
        canvas = base.copy()
        place(canvas, window(full.crop((0, y, full.width, y + view_h))), ((W - full.width) // 2, 190))
        images.append(canvas)
        durations.append(70)
    save_gif(images, durations, "analytics", 900)


def scene_paste(directory: Path) -> None:
    """Pasting after text already in the field: a space first, except between Chinese characters."""
    folder, index = frames(directory, "hero")
    talk = [i for i, f in enumerate(index) if f["file"]][24:120:2]  # live and talking, at half the frames
    W, H = 2000, 860
    base = background(W, H)
    title(base, "A space before it, when the cursor follows text", (80, 60))
    rows = [("Running a bit late.", "Be there in 10.", " ", "English after text: a space first"),
            ("我们明天", "开会吧。", "", "Chinese after Chinese: no space")]
    images, durations = [], []

    def field(before: str, added: str, gap: str, highlight: bool) -> Image.Image:
        w, h = 1400, 150
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, w - 1, h - 1], 40, fill=(255, 255, 255, 255), outline=(205, 205, 212, 255), width=3)
        f = font(before + added, 54)
        x = 50
        d.text((x, 42), before, font=f, fill=(29, 29, 31, 255))
        x += d.textlength(before, font=f)
        if added:
            gap_w = d.textlength(gap, font=f) if gap else 0
            if highlight and gap:  # a ⎵ under the space
                d.line([(x + 3, 104), (x + 3, 116), (x + gap_w - 3, 116), (x + gap_w - 3, 104)], fill=(0, 122, 255, 255), width=5)
            d.text((x + gap_w, 42), added, font=f, fill=(29, 29, 31, 255))
            x += gap_w + d.textlength(added, font=f)
        d.rectangle([x + 4, 40, x + 8, 112], fill=(0, 122, 255, 255))  # caret
        return img

    for before, added, gap, note in rows:
        def frame(img_field: Image.Image, pill: Image.Image | None, text: str, ms: int, opacity: float = 1.0) -> None:
            canvas = base.copy()
            place(canvas, img_field, ((W - img_field.width) // 2, 260), shadow=30)
            if pill is not None:
                place(canvas, pill, (W // 2 - pill.width // 2, 560 - pill.height // 2), shadow=24, opacity=opacity)
            caption(canvas, text, W // 2, H - 150)
            images.append(canvas)
            durations.append(ms)
        frame(field(before, "", gap, False), None, "Click after the text, then dictate", 1200)
        for n, i in enumerate(talk):
            img = Image.open(folder / index[i]["file"]).convert("RGBA")
            pill = img.resize((img.width * 2, img.height * 2), Image.LANCZOS)
            frame(field(before, "", gap, False), pill, f"“{added.rstrip('。.')}”", 80, opacity=min(1.0, (n + 1) / 3))
        frame(field(before, added, gap, True), None, note, 2400)
    save_gif(images, durations, "paste", 1000)


SCENES = {
    "hero": scene_hero, "pill": scene_pill, "commands": scene_commands, "on-device": scene_on_device,
    "learn": scene_learn, "analytics": scene_analytics, "paste": scene_paste,
}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="readme-gifs.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("list", help="the scenes")
    r = sub.add_parser("render", help="render scenes (all by default) into docs/images")
    r.add_argument("scenes", nargs="*", metavar="scene", help=", ".join(SCENES))
    r.add_argument("--frames", type=Path, help="frames from an earlier render (skips the Swift step)")
    args = parser.parse_args(argv)
    if args.action == "list":
        for name, fn in SCENES.items():
            print(f"  {name:<10} {fn.__doc__.splitlines()[0]}")
        return 0
    unknown = [s for s in args.scenes if s not in SCENES]
    if unknown:
        parser.error(f"unknown scene {', '.join(unknown)}: choose from {', '.join(SCENES)}")
    directory = args.frames
    if directory is None:
        directory = Path(tempfile.mkdtemp(prefix="readme-frames-"))
        render_frames(directory)
    for name in args.scenes or SCENES:
        SCENES[name](directory)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
