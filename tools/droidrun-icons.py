"""Draws DroidRun's app icons: a phone outline with a play triangle inside, on a rounded square.

    python tools/droidrun-icons.py

Writes every icon the app ships (src/app/Husk/Assets.xcassets/*.appiconset at 1024 px, src/app/Husk/Resources/icon-*.png
at 256 px), in the same variants as before: default, dark, tinted dark, tinted light, clear dark, clear light.
Needs Pillow.
"""
import os

from PIL import Image, ImageChops, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "app", "Husk")
S = 4096  # drawn at 4x, then scaled down for smooth edges

TEAL, BLUE = (0, 201, 167), (30, 111, 255)


def gradient(c1, c2):
    """Diagonal gradient from the top-left (c1) to the bottom-right (c2)."""
    v = Image.linear_gradient("L").resize((S, S))       # 0 at the top, 255 at the bottom
    g = ImageChops.add(v, v.transpose(Image.Transpose.ROTATE_90).transpose(Image.Transpose.FLIP_LEFT_RIGHT), scale=2)
    return Image.composite(Image.new("RGB", (S, S), c2), Image.new("RGB", (S, S), c1), g)


def rounded(radius_frac):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, S - 1, S - 1), radius=int(S * radius_frac), fill=255)
    return m


def glyph():
    """White mask: phone outline, play triangle, speaker slot."""
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    w, h = int(S * 0.40), int(S * 0.62)
    x0, y0 = (S - w) // 2, (S - h) // 2
    d.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=int(S * 0.075), outline=255, width=int(S * 0.045))
    d.rounded_rectangle((S // 2 - S * 0.05, y0 + S * 0.055, S // 2 + S * 0.05, y0 + S * 0.075), radius=S * 0.01, fill=255)
    cx, cy, r = S // 2 + int(S * 0.02), S // 2 + int(S * 0.02), int(S * 0.12)
    tri = [(cx - r * 0.8, cy - r), (cx - r * 0.8, cy + r), (cx + r * 1.0, cy)]
    tm = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tm).polygon(tri, fill=255)
    tm = tm.resize((S // 8, S // 8), Image.LANCZOS).resize((S, S), Image.LANCZOS)  # soften the triangle's corners
    tm = tm.point(lambda v: 255 if v > 110 else 0)
    return ImageChops.lighter(m, tm)


def icon(bg, fg):
    """bg, fg: RGB images. Corners transparent like the old icons."""
    out = Image.composite(fg, bg, glyph()).convert("RGBA")
    out.putalpha(rounded(0.225))
    return out


def solid(c):
    return Image.new("RGB", (S, S), c)


def gray(img):
    return img.convert("L").convert("RGB")


def main():
    color = gradient(TEAL, BLUE)
    variants = {
        "default": icon(color, solid((255, 255, 255))),
        "dark": icon(gradient((22, 22, 24), (14, 26, 46)), color),
        "tinteddark": icon(solid((31, 29, 40)), gray(color).point(lambda v: min(255, v + 90))),
        "tintedlight": icon(gray(color), solid((255, 255, 255))),
        "cleardark": icon(solid((46, 46, 46)), solid((235, 235, 235))),
        "clearlight": icon(solid((130, 130, 130)), solid((255, 255, 255))),
    }
    sets = {
        "AppIcon.appiconset/Icon-Default.png": "default",
        "AppIcon.appiconset/Icon-Dark.png": "dark",
        "AppIcon.appiconset/Icon-Tinted.png": "tinteddark",
        "AppIconTintedDark.appiconset/Icon-1024.png": "tinteddark",
        "AppIconTintedLight.appiconset/Icon-1024.png": "tintedlight",
        "AppIconClearDark.appiconset/Icon-1024.png": "cleardark",
        "AppIconClearLight.appiconset/Icon-1024.png": "clearlight",
    }
    for path, v in sets.items():
        f = os.path.join(ROOT, "Assets.xcassets", path)
        variants[v].resize((1024, 1024), Image.LANCZOS).save(f, optimize=True)
        print(f)
    for v, img in variants.items():
        f = os.path.join(ROOT, "Resources", f"icon-{v}.png")
        img.resize((256, 256), Image.LANCZOS).save(f, optimize=True)
        print(f)


if __name__ == "__main__":
    main()
