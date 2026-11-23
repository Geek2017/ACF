#!/usr/bin/env python3
"""build-logo.py: make the fleet's icon, Windows icon and splash animation from logo.png.

logo.png is an animated PNG (61 frames, 1440x960, transparent): the >A draws in, the three
planes fly up, then it fades out. Made from it, into share/ (committed, so a machine that runs
the fleet from this folder needs no Pillow):

  share/icons/hicolor/<N>x<N>/apps/acf.png   the icon, N = 16 ... 512: the finished logo on a
                                              white rounded tile (its dark >A would vanish on a
                                              dark panel without one)
  share/acf/acf.ico                           the same for Windows (the Windows Terminal profile)
  share/acf/splash.png + splash.json          every frame side by side, cut to the part that ever
                                              shows, 120 px high, and each frame's time: what
                                              afc-splash plays (it fits the whole to 5 seconds)

Needs Pillow (python3-pil). Run it again after logo.png changes:
    python3 _tools/build-logo.py [--check]      --check: say what is out of date, write nothing
"""
import json
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGO = os.path.join(HERE, "logo.png")
SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
SPLASH_H = 120                # the splash's logo is this many pixels high (a small card, beside the name)


def frames(path):
    """Each frame of the animation as RGBA, with its time in ms."""
    im = Image.open(path)
    out = []
    for i in range(getattr(im, "n_frames", 1)):
        im.seek(i)
        out.append((im.convert("RGBA"), int(im.info.get("duration") or 100)))
    return out


def finished(fr):
    """The last frame drawn at full strength (before the fade-out): the logo as it is meant to look."""
    full = [f for f, _ in fr if f.split()[3].getextrema()[1] == 255]
    return (full or [fr[-1][0]])[-1]


def tile(logo, n):
    """The icon at n x n: the logo, cut to its edges, centred on a white rounded square."""
    big = n * 4                                   # drawn 4x, then scaled down: smooth corners
    card = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(card).rounded_rectangle((0, 0, big - 1, big - 1), radius=int(big * 0.22),
                                           fill=(255, 255, 255, 255))
    art = logo.crop(logo.getbbox())
    room = big * (0.86 if n <= 24 else 0.80)     # small icons: less margin, more logo
    k = min(room / art.width, room / art.height)
    art = art.resize((max(1, round(art.width * k)), max(1, round(art.height * k))), Image.LANCZOS)
    card.alpha_composite(art, ((big - art.width) // 2, (big - art.height) // 2))
    return card.resize((n, n), Image.LANCZOS)


def build(check=False):
    if not os.path.exists(LOGO):
        sys.exit(f"build-logo: no {LOGO}")
    fr = frames(LOGO)
    logo = finished(fr)
    todo = []

    def write(rel, save):
        dst = os.path.join(HERE, rel)
        if check:
            if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(LOGO):
                todo.append(rel)
            return
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        save(dst)
        todo.append(rel)

    for n in SIZES:
        write(f"share/icons/hicolor/{n}x{n}/apps/acf.png", lambda d, n=n: tile(logo, n).save(d, optimize=True))
    write("share/acf/acf.ico", lambda d: tile(logo, 256).save(d, sizes=[(n, n) for n in ICO_SIZES]))

    # the splash: one strip of every frame, cut to the box that any frame ever draws in
    box = None
    for f, _ in fr:
        b = f.getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    pad = 12
    box = (max(0, box[0] - pad), max(0, box[1] - pad), min(fr[0][0].width, box[2] + pad),
           min(fr[0][0].height, box[3] + pad))
    k = SPLASH_H / (box[3] - box[1])
    w, h = round((box[2] - box[0]) * k), SPLASH_H

    def strip(d):
        s = Image.new("RGBA", (w * len(fr), h), (0, 0, 0, 0))
        for i, (f, _) in enumerate(fr):
            s.alpha_composite(f.crop(box).resize((w, h), Image.LANCZOS), (i * w, 0))
        s.save(d, optimize=True)

    write("share/acf/splash.png", strip)
    # strength: how strongly each frame draws (its most opaque pixel), so afc-splash fades its card
    # out with the logo's own fade at the end
    write("share/acf/splash.json", lambda d: open(d, "w").write(json.dumps(
        {"source": "logo.png", "width": w, "height": h, "frames": len(fr),
         "durations": [ms for _, ms in fr],
         "strength": [round(f.split()[3].getextrema()[1] / 255, 3) for f, _ in fr]}) + "\n"))
    if check:
        print("out of date: " + ", ".join(todo) if todo else "all up to date")
        return 1 if todo else 0
    total = sum(ms for _, ms in fr)
    print(f"built {len(todo)} files from logo.png ({len(fr)} frames, {total / 1000:.1f} s; splash {w}x{h})")
    return 0


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv[1:]))
