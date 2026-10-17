#!/usr/bin/env -S uv run -q --with pillow python
"""README screenshot (docs/images/screenshot.gif): History and Insights windows from the snapshot-test
PNGs, with the real recording pill animating in front of them. A Bluetooth mic starts (dots), goes
live (green flash), you talk, then it polishes.

The windows come from the snapshot tests and the pill frames from Tests/DictationKitTests/ReadmeFrames.swift,
all fixture data at a fixed scale, so the image shows nothing from this Mac.
Rerun after re-recording snapshots or changing the pill:  scripts/readme-screenshot.py
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
root = Path(__file__).resolve().parent.parent
snap = root / "Tests/DictationKitTests/__Snapshots__"
out = root / "docs/images/screenshot.gif"
W, H = 2400, 1640
OUT_W = 1200  # README width is ~900 px; half of the 2x composition keeps text crisp
PILL_CENTER = (568, 1120)  # where the pill sat in the static screenshot
PILL_ZOOM = 2  # frames are at 2x; the composition shows the pill larger than life

def background():
    """Soft diagonal gradient."""
    bg = Image.new("RGB", (W, H))
    top, bot = (88, 110, 200), (196, 120, 190)
    px = bg.load()
    for y in range(H):
        for x in range(W):
            t = x / W * 0.4 + y / H * 0.6
            px[x, y] = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    return bg.convert("RGBA")

def window(img, title_h=56, radius=24):
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

def place(canvas, layer, xy, shadow=40, opacity=1.0):
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
        canvas.alpha_composite(patch, (xy[0] - pad, xy[1] - pad))
    canvas.alpha_composite(layer, xy)

def pill_frames():
    """Renders the pill's frames with the test target; returns (frames dir, frame list)."""
    tmp = Path(tempfile.mkdtemp(prefix="readme-frames-"))
    run = subprocess.run(["swift", "test", "--filter", "ReadmeFrames"], cwd=root, env={**os.environ, "README_FRAMES": str(tmp)},
                         capture_output=True, text=True)
    index = tmp / "frames.json"
    if run.returncode != 0 or not index.exists():
        sys.exit("ReadmeFrames failed:\n" + run.stdout[-3000:] + run.stderr[-3000:])
    return tmp, json.loads(index.read_text())["frames"]

def main():
    base = background()
    hist = Image.open(snap / "history.png").crop((0, 0, 1520, 560))
    ins = Image.open(snap / "insights-breakdown.png")
    place(base, window(hist), (120, 90))
    place(base, window(ins), (1040, 760))

    tmp, frames = pill_frames()
    last, fade_from = None, None
    images, durations = [], []
    for i, f in enumerate(frames):
        canvas = base.copy()
        opacity = min(1.0, (i + 1) / 3)  # the pill fades in over ~0.12 s
        if f["file"]:
            last, shadow = Image.open(tmp / f["file"]).convert("RGBA"), f["shadow"]
        elif last is not None:  # hidden: fade out over ~0.15 s, then nothing
            fade_from = i if fade_from is None else fade_from
            opacity = max(0.0, 1 - (i - fade_from + 1) / 4)
        if last is not None and opacity > 0:
            pill = last.resize((last.width * PILL_ZOOM, last.height * PILL_ZOOM), Image.LANCZOS)
            place(canvas, pill, (PILL_CENTER[0] - pill.width // 2, PILL_CENTER[1] - pill.height // 2),
                  shadow=24 if shadow else 0, opacity=opacity)
        images.append(canvas.convert("RGB").resize((OUT_W, H * OUT_W // W), Image.LANCZOS))
        durations.append(f["ms"])
    # One palette for every frame, so the background is identical between frames and each frame
    # only stores the pill's pixels.
    # Median cut weighs colors by area, so the small saturated bits (window buttons, the chart, the
    # green glow) get extra copies or they come out teal.
    s = OUT_W / W
    box = lambda x0, y0, x1, y1: tuple(int(v * s) for v in (x0, y0, x1, y1))
    pill_box = box(PILL_CENTER[0] - 560, PILL_CENTER[1] - 200, PILL_CENTER[0] + 560, PILL_CENTER[1] + 200)
    details = [images[0].crop(box(120, 90, 360, 146)), images[0].crop(box(1040, 760, 1280, 816)),
               images[0].crop(box(1080, 1060, 2260, 1160))]
    pills = [images[min(i, len(images) - 1)].crop(pill_box) for i in (13, 24, 26, 28, 31, 70, 140)]
    tiles = [images[0]] + details * 6 + pills * 2
    key = Image.new("RGB", (OUT_W, sum(t.height for t in tiles)))
    y = 0
    for t in tiles:
        key.paste(t, (0, y))
        y += t.height
    exact = [(255, 95, 87), (254, 188, 46), (40, 200, 64)]  # window buttons
    exact += [base.getpixel(xy)[:3] for xy in [(2130, 1306), (2200, 1306), (1662, 1365), (1776, 1365)]]  # chart parts
    cut = key.quantize(colors=255 - len(exact), method=Image.Quantize.MEDIANCUT).getpalette()[:(255 - len(exact)) * 3]
    palette = Image.new("P", (1, 1))
    palette.putpalette(cut + [c for rgb in exact for c in rgb])
    gif = [im.quantize(palette=palette, dither=Image.Dither.NONE) for im in images]
    durations[-1] += 600  # rest before it loops
    gif[0].save(out, save_all=True, append_images=gif[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"{out.relative_to(root)}: {len(gif)} frames, {out.stat().st_size / 1e6:.1f} MB")

main()
