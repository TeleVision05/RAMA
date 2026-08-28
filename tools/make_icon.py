#!/usr/bin/env python3
"""Draw the RAMA app icon and build RAMA.icns.

Why drawn rather than a screenshot: a cropped render of the shrine turns to brown mush
at 32 px, which is where a Dock or Finder icon actually lives. A silhouette reads at
every size. The subject is the shrine's shikhara with the pillared mandapa beside it,
against a dusk sky — the same building the player climbs the knoll to reach.

Iconography note: an early version drew the finial as a neck bar plus a vertical rod,
which together read as a CROSS. Wrong for a Hindu temple. The crown is now a flattened
amalaka disc with a kalasha above it, which is what the building actually has.

    python3 tools/make_icon.py          # writes build/RAMA_icon_1024.png and build/RAMA.icns
"""
import math
import os
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build")
INK = (34, 22, 20)


def draw_art() -> Image.Image:
    art = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(art)

    # Dusk sky: deep indigo overhead falling to saffron at the horizon.
    top, mid, bottom = (26, 30, 62), (150, 74, 58), (243, 168, 74)
    for y in range(S):
        t = y / (S - 1)
        if t < 0.62:
            u = t / 0.62
            c = tuple(int(top[i] + (mid[i] - top[i]) * (u ** 1.35)) for i in range(3))
        else:
            u = (t - 0.62) / 0.38
            c = tuple(int(mid[i] + (bottom[i] - mid[i]) * (u ** 0.72)) for i in range(3))
        d.line([(0, y), (S, y)], fill=c)

    horizon = int(S * 0.795)
    glow = Image.new("RGB", (S, S), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        (S * 0.28, horizon - S * 0.30, S * 0.72, horizon + S * 0.14), fill=(255, 196, 96))
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    art = Image.composite(Image.new("RGB", (S, S), (255, 214, 130)), art,
                          glow.convert("L").point(lambda v: min(255, int(v * 0.85))))
    d = ImageDraw.Draw(art)
    d.ellipse((S * 0.415, horizon - S * 0.145, S * 0.585, horizon + S * 0.025),
              fill=(255, 232, 176))

    base_y = horizon + int(S * 0.055)
    top_y = int(S * 0.205)
    h = base_y - top_y
    half_base = S * 0.152
    cx = S * 0.50

    def half_width(t: float) -> float:
        # A shikhara's profile is convex and tightens near the top. A straight taper
        # reads as a pyramid, not a temple.
        return half_base * (1.0 - t) ** 0.70 * (1.0 - 0.14 * math.sin(t * math.pi))

    n = 160
    left, right = [], []
    for i in range(n + 1):
        t = i / n
        y = base_y - t * h
        w = half_width(t)
        left.append((cx - w, y))
        right.append((cx + w, y))
    d.polygon(left + right[::-1], fill=INK)

    for i in range(9):                                   # bhumi courses
        t = 0.06 + i * 0.098
        y = base_y - t * h
        w = half_width(t)
        d.rectangle([cx - w - 4, y - 5, cx + w + 4, y + 5], fill=INK)

    aw, ah, ay = S * 0.082, S * 0.030, top_y             # amalaka, then kalasha
    d.ellipse([cx - aw, ay - ah, cx + aw, ay + ah], fill=INK)
    d.ellipse([cx - aw * 0.62, ay - ah * 1.55, cx + aw * 0.62, ay - ah * 0.15], fill=INK)
    ky = ay - ah * 1.5
    d.ellipse([cx - S * 0.026, ky - S * 0.042, cx + S * 0.026, ky + S * 0.006], fill=INK)
    d.polygon([(cx - S * 0.009, ky - S * 0.036), (cx + S * 0.009, ky - S * 0.036),
               (cx, ky - S * 0.072)], fill=INK)

    mx0, mx1 = cx + S * 0.100, cx + S * 0.318            # mandapa
    mroof = base_y - S * 0.200
    d.polygon([(mx0, mroof + S * 0.045), (cx + S * 0.209, mroof - S * 0.030),
               (mx1, mroof + S * 0.045)], fill=INK)
    d.rectangle([mx0, mroof + S * 0.030, mx1, mroof + S * 0.060], fill=INK)
    for i in range(4):
        px = mx0 + S * 0.020 + i * S * 0.059
        d.rectangle([px, mroof + S * 0.058, px + S * 0.023, base_y], fill=INK)
    d.rectangle([mx0 - S * 0.014, base_y - S * 0.020, mx1 + S * 0.014, base_y], fill=INK)

    d.rectangle([S * 0.135, base_y, S * 0.865, base_y + S * 0.028], fill=INK)
    d.rectangle([S * 0.092, base_y + S * 0.026, S * 0.908, base_y + S * 0.052], fill=INK)
    d.rectangle([0, base_y + S * 0.050, S, S], fill=(24, 17, 17))

    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))        # sunlit edge
    rd = ImageDraw.Draw(rim)
    for i in range(n):
        t0, t1 = i / n, (i + 1) / n
        rd.line([(cx - half_width(t0), base_y - t0 * h),
                 (cx - half_width(t1), base_y - t1 * h)],
                fill=(255, 206, 132, 210), width=7)
    rim = rim.filter(ImageFilter.GaussianBlur(2))
    return Image.alpha_composite(art.convert("RGBA"), rim).convert("RGB")


def squircle(size: int, n: float = 5.0) -> Image.Image:
    """Superellipse — the shape macOS actually uses, not a plain rounded rect."""
    m = Image.new("L", (size * 4, size * 4), 0)
    d = ImageDraw.Draw(m)
    s4 = size * 4
    c = a = s4 / 2.0
    pts = []
    for i in range(720):
        th = 2 * math.pi * i / 720
        ct, st = math.cos(th), math.sin(th)
        pts.append((c + a * math.copysign(abs(ct) ** (2 / n), ct),
                    c + a * math.copysign(abs(st) ** (2 / n), st)))
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    art = draw_art()

    body, margin = 824, (1024 - 824) // 2               # Big Sur proportions
    mask = squircle(body)
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    sh = Image.new("L", (1024, 1024), 0)
    sh.paste(mask, (margin, margin + 14))
    sh = sh.filter(ImageFilter.GaussianBlur(20))
    shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    shadow.putalpha(sh.point(lambda v: int(v * 0.40)))
    canvas = Image.alpha_composite(canvas, shadow)
    lay = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    lay.paste(art.resize((body, body), Image.LANCZOS), (margin, margin), mask)
    canvas = Image.alpha_composite(canvas, lay)

    png = os.path.join(OUT, "RAMA_icon_1024.png")
    canvas.save(png)

    iconset = "/tmp/RAMA.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for px, name in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                     (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                     (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]:
        canvas.resize((px, px), Image.LANCZOS).save(f"{iconset}/icon_{name}.png")
    icns = os.path.join(OUT, "RAMA.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print(f"wrote {png}\nwrote {icns}")


if __name__ == "__main__":
    main()
