#!/usr/bin/env python3
"""Generates the SmartTile app icon.

Writes Resources/AppIcon.png (1024x1024) and Resources/AppIcon.icns.
Requires Pillow and NumPy:  pip3 install pillow numpy

The design: a macOS-style rounded square with an indigo-to-cyan gradient and three
tiled windows (code on the left, reference top-right, music bottom-right), plus a
small sparkle for the "learns your habits" part.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4                      # supersampling factor for smooth edges
S = SIZE * SS


def px(v):
    """Design units (on a 1024 grid) to supersampled pixels."""
    return int(round(v * SS))


def gradient(w, h, top_left, bottom_right):
    """Diagonal linear gradient as an RGBA image."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    t = (x / w + y / h) / 2.0
    t = t[..., None]
    a = np.array(top_left, dtype=np.float32)
    b = np.array(bottom_right, dtype=np.float32)
    rgb = a * (1 - t) + b * t
    alpha = np.full((h, w, 1), 255, dtype=np.float32)
    return Image.fromarray(np.concatenate([rgb, alpha], axis=2).astype(np.uint8), "RGBA")


def rounded_mask(w, h, box, radius):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def draw_window(layer, box, fill, radius=px(34)):
    """A small window: body, title-bar dots."""
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle(box, radius=radius, fill=fill)
    x0, y0, _, _ = box
    for i, color in enumerate([(255, 95, 87, 255), (254, 188, 46, 255), (40, 200, 64, 255)]):
        cx = x0 + px(30) + i * px(26)
        cy = y0 + px(30)
        r = px(8)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color)


def sparkle(draw, cx, cy, r, fill):
    """Four-pointed star."""
    k = 0.28
    pts = [
        (cx, cy - r), (cx + r * k, cy - r * k), (cx + r, cy), (cx + r * k, cy + r * k),
        (cx, cy + r), (cx - r * k, cy + r * k), (cx - r, cy), (cx - r * k, cy - r * k),
    ]
    draw.polygon(pts, fill=fill)


def render():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Body: Big Sur grid (824x824 at offset 100) with a soft drop shadow
    body = (px(100), px(100), px(924), px(924))
    radius = px(185)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (body[0], body[1] + px(12), body[2], body[3] + px(12)), radius=radius, fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(18)))
    canvas.alpha_composite(shadow)

    bg = gradient(S, S, (79, 70, 229), (6, 182, 212))          # indigo → cyan
    canvas.paste(bg, (0, 0), rounded_mask(S, S, body, radius))

    # Subtle top highlight
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse((px(-200), px(-620), px(1224), px(430)), fill=(255, 255, 255, 30))
    hl = hl.filter(ImageFilter.GaussianBlur(px(70)))
    hl_masked = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hl_masked.paste(hl, (0, 0), rounded_mask(S, S, body, radius))
    canvas.alpha_composite(hl_masked)

    # Tiles
    gap = px(28)
    area = (px(212), px(232), px(812), px(792))
    ax0, ay0, ax1, ay1 = area
    split = ax0 + int((ax1 - ax0 - gap) * 0.58)
    mid = ay0 + int((ay1 - ay0 - gap) * 0.55)
    main_box = (ax0, ay0, split, ay1)
    ref_box = (split + gap, ay0, ax1, mid)
    aux_box = (split + gap, mid + gap, ax1, ay1)

    tiles = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tshadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(tshadow)
    for b in (main_box, ref_box, aux_box):
        sd.rounded_rectangle((b[0], b[1] + px(10), b[2], b[3] + px(10)), radius=px(34), fill=(20, 20, 80, 70))
    tshadow = tshadow.filter(ImageFilter.GaussianBlur(px(14)))
    canvas.alpha_composite(tshadow)

    draw_window(tiles, main_box, (255, 255, 255, 250))
    draw_window(tiles, ref_box, (236, 246, 255, 245))
    draw_window(tiles, aux_box, (255, 236, 196, 248))
    d = ImageDraw.Draw(tiles)

    # Main tile: code lines
    code_colors = [(99, 102, 241, 255), (14, 165, 233, 255), (167, 139, 250, 255), (99, 102, 241, 255),
                   (45, 212, 191, 255), (14, 165, 233, 255), (167, 139, 250, 255)]
    widths = [0.62, 0.78, 0.48, 0.70, 0.36, 0.58, 0.44]
    indents = [0, 0.08, 0.16, 0.16, 0.08, 0.16, 0]
    lx0 = main_box[0] + px(32)
    lw = main_box[2] - main_box[0] - px(64)
    ly = main_box[1] + px(84)
    for c, w, ind in zip(code_colors, widths, indents):
        x = lx0 + int(lw * ind)
        d.rounded_rectangle((x, ly, x + int(lw * w), ly + px(20)), radius=px(10), fill=c)
        ly += px(52)

    # Reference tile: text block
    rx0 = ref_box[0] + px(28)
    rw = ref_box[2] - ref_box[0] - px(56)
    ry = ref_box[1] + px(72)
    d.rounded_rectangle((rx0, ry, rx0 + int(rw * 0.7), ry + px(22)), radius=px(11), fill=(30, 64, 175, 255))
    ry += px(46)
    for w in (1.0, 0.86, 0.94):
        d.rounded_rectangle((rx0, ry, rx0 + int(rw * w), ry + px(14)), radius=px(7), fill=(148, 163, 184, 255))
        ry += px(32)

    # Aux tile: equalizer bars
    bx = aux_box[0] + px(40)
    base = aux_box[3] - px(36)
    heights = [70, 120, 92, 140, 60]
    bw = px(22)
    for h in heights:
        d.rounded_rectangle((bx, base - px(h), bx + bw, base), radius=px(11), fill=(245, 158, 11, 255))
        bx += bw + px(16)

    canvas.alpha_composite(tiles)

    # Sparkle ("learns")
    sp = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    spd = ImageDraw.Draw(sp)
    sparkle(spd, px(818), px(206), px(64), (255, 255, 255, 255))
    sparkle(spd, px(878), px(296), px(26), (255, 255, 255, 230))
    glow = sp.filter(ImageFilter.GaussianBlur(px(10)))
    canvas.alpha_composite(glow)
    canvas.alpha_composite(sp)

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(root, "Resources")
    icon = render()
    png = os.path.join(out_dir, "AppIcon.png")
    icns = os.path.join(out_dir, "AppIcon.icns")
    icon.save(png)
    sizes = [(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)]
    icon.save(icns, sizes=sizes)
    print(f"wrote {png}\nwrote {icns}")


if __name__ == "__main__":
    sys.exit(main())
