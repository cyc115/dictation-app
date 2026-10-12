#!/usr/bin/env -S uv run -q --with pillow python
"""README screenshot (docs/images/screenshot.png), composed from the snapshot-test PNGs.

The snapshots render fixture data at a fixed scale, so the image shows nothing from this Mac.
Rerun after re-recording snapshots:  scripts/readme-screenshot.py
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
root = Path(__file__).resolve().parent.parent
snap = root / "Tests/DictationKitTests/__Snapshots__"
out = root / "docs/images/screenshot.png"
W, H = 2400, 1640
# soft diagonal gradient background
bg = Image.new("RGB", (W, H))
top, bot = (88, 110, 200), (196, 120, 190)
px = bg.load()
for y in range(H):
    for x in range(0, W):
        t = (x / W * 0.4 + y / H * 0.6)
        px[x, y] = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
bg = bg.convert("RGBA")

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

def place(canvas, layer, xy, shadow=40):
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    a = layer.getchannel("A").point(lambda v: int(v * 0.35))
    blob = Image.new("RGBA", layer.size, (0, 0, 0, 255)); blob.putalpha(a)
    sh.paste(blob, (xy[0], xy[1] + shadow // 2), blob)
    sh = sh.filter(ImageFilter.GaussianBlur(shadow))
    canvas.alpha_composite(sh)
    canvas.alpha_composite(layer, xy)

hist = Image.open(f"{snap}/history.png").crop((0, 0, 1520, 560))
ins = Image.open(f"{snap}/insights-breakdown.png")
place(bg, window(hist), (120, 90))
place(bg, window(ins), (1040, 760))
pill = Image.open(f"{snap}/overlay-listening.png").convert("RGBA")
pill = pill.resize((pill.width * 2, pill.height * 2), Image.LANCZOS)
place(bg, pill, (160, 1040), shadow=24)
bg.convert("RGB").save(out, optimize=True)
