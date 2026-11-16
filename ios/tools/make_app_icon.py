"""Draw the OpenSpeak app icon: an open speech-bubble ring around five voice bars,
one gradient line weight on white.

    python ios/tools/make_app_icon.py   # writes AppIcon.appiconset/AppIcon.png
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parents[1] / "OpenSpeak/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
SIZE = 1024
SCALE = 4                      # draw large, then downsample for smooth edges
S = SIZE * SCALE
STROKE = 46 * SCALE
CENTER = (S / 2, S / 2 - 10 * SCALE)
RING = 300 * SCALE
GAP = (112, 152)               # degrees, clockwise from 3 o'clock; the tail leaves the ring here
TAIL_TIP = (130, 1.36)         # angle, distance as a multiple of RING
BARS = [0.30, 0.62, 0.92, 0.56, 0.34]   # heights as a share of the ring's inner diameter
BAR_GAP = 116 * SCALE
STOPS = [(0.0, (247, 211, 72)), (0.36, (112, 219, 114)), (0.66, (34, 195, 181)), (1.0, (28, 125, 240))]


def polar(angle, radius):
    a = math.radians(angle)
    return CENTER[0] + radius * math.cos(a), CENTER[1] + radius * math.sin(a)


def dot(draw, p):
    r = STROKE / 2
    draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=255)


def line(draw, a, b):
    draw.line([a, b], fill=255, width=STROKE)
    dot(draw, a)
    dot(draw, b)


def mask():
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    box = [CENTER[0] - RING - STROKE / 2, CENTER[1] - RING - STROKE / 2,
           CENTER[0] + RING + STROKE / 2, CENTER[1] + RING + STROKE / 2]
    d.arc(box, start=GAP[1], end=GAP[0] + 360, fill=255, width=STROKE)
    tip = polar(TAIL_TIP[0], RING * TAIL_TIP[1])
    line(d, polar(GAP[1], RING), tip)
    line(d, tip, polar(GAP[0], RING))
    inner = 2 * (RING - STROKE)
    for i, share in enumerate(BARS):
        x = CENTER[0] + (i - (len(BARS) - 1) / 2) * BAR_GAP
        half = max(inner * share / 2 - STROKE / 2, 0)
        line(d, (x, CENTER[1] - half), (x, CENTER[1] + half))
    return m


def gradient(top, bottom):
    g = Image.new("RGB", (1, S))
    for y in range(S):
        t = min(max((y - top) / (bottom - top), 0), 1)
        for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
            if t <= t1:
                k = (t - t0) / (t1 - t0)
                g.putpixel((0, y), tuple(round(a + (b - a) * k) for a, b in zip(c0, c1)))
                break
    return g.resize((S, S))


def main():
    m = mask()
    top, bottom = m.getbbox()[1], m.getbbox()[3]
    icon = Image.new("RGB", (S, S), (255, 255, 255))
    icon.paste(gradient(top, bottom), (0, 0), m)
    icon.resize((SIZE, SIZE), Image.LANCZOS).save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
