#!/usr/bin/env python3
"""
Render a screenshot as text, so a text-only reader can see the layout.

The Read tool in this environment does not accept images, so a screenshot is otherwise a file I
cannot look at. This turns one into two things I *can* read:

  luminance   how dark each cell is -> layout, density, and where the eye lands
  colour      which palette token each cell is nearest -> what is a surface, a border, a muted
              label, or the accent colour

Both are coarse on purpose. The point is not to replace looking at the picture; it is to see
composition — what is big, what is dense, where the whitespace is, how the width is spent — and to
catch the cases where a measurement says "fine" but the page reads as a wall.

    python3 harness/ux-render.py shot.png                 # luminance, 128 cols
    python3 harness/ux-render.py shot.png --cols 100
    python3 harness/ux-render.py shot.png --colour        # palette map
    python3 harness/ux-render.py shot.png --crop 0,0,900,400
"""
import sys

try:
    from PIL import Image
    import numpy as np
except ImportError:
    sys.exit("needs pillow and numpy")

# Dark to light. A dark glyph is a dense character, so text on a light page reads as texture.
RAMP = "@%#*+=-:. "
# The palette in html/theme.mbt, as the renderer resolves it. Values are light-scheme.
PALETTE = {
    "b": (255, 255, 255),  # --bg
    "s": (246, 246, 247),  # --surface
    "S": (236, 236, 238),  # --surface-strong
    "k": (27, 28, 30),     # --fg (text)
    "m": (107, 111, 118),  # --muted
    "l": (224, 224, 226),  # --line (a faint border over white)
    "L": (184, 184, 187),  # --line-strong
    "a": (47, 111, 235),   # --accent
    "d": (200, 52, 47),    # --danger
    "o": (31, 138, 76),    # --ok
}


def load(path, crop=None):
    img = Image.open(path).convert("RGB")
    if crop:
        img = img.crop(crop)
    return img


def cells(img, cols):
    """Average the image into `cols` columns of square-ish cells."""
    w, h = img.size
    cw = max(1, w // cols)
    # Characters are about twice as tall as wide, so a cell is twice as tall as it is wide.
    ch = cw * 2
    rows = max(1, h // ch)
    a = np.asarray(img, dtype=np.float32)
    a = a[: rows * ch, : cols * cw]
    a = a.reshape(rows, ch, cols, cw, 3).mean(axis=(1, 3))
    return a


def luminance_map(a):
    # Rec. 709 luma, then the ramp: dark cell -> dense character.
    lum = 0.2126 * a[:, :, 0] + 0.7152 * a[:, :, 1] + 0.0722 * a[:, :, 2]
    idx = np.clip((lum / 255.0 * (len(RAMP) - 1)).round().astype(int), 0, len(RAMP) - 1)
    return "\n".join("".join(RAMP[i] for i in row) for row in idx)


def colour_map(a):
    names = list(PALETTE)
    values = np.array([PALETTE[n] for n in names], dtype=np.float32)
    flat = a.reshape(-1, 3)
    d = ((flat[:, None, :] - values[None, :, :]) ** 2).sum(axis=2)
    nearest = d.argmin(axis=1).reshape(a.shape[:2])
    return "\n".join("".join(names[i] for i in row) for row in nearest)


def band_summary(a, bands=6):
    """Per horizontal band: what the non-background pixels are, and how much of the band they fill.

    A band that is nearly all background is whitespace; a band that is all one muted colour is a
    wall of secondary text; a band with a little accent is where the eye goes.
    """
    rows = a.shape[0]
    out = []
    for b in range(bands):
        lo, hi = b * rows // bands, (b + 1) * rows // bands
        block = a[lo:hi].reshape(-1, 3)
        lum = 0.2126 * block[:, 0] + 0.7152 * block[:, 1] + 0.0722 * block[:, 2]
        ink = block[lum < 210]
        share = len(ink) / max(1, len(block))
        if len(ink) == 0:
            out.append(f"  band {b}: {' ' * 0} {share * 100:5.1f}% ink   (whitespace)")
            continue
        mean = ink.mean(axis=0).round().astype(int)
        # Nearest palette name for the average ink colour.
        names = list(PALETTE)
        vals = np.array([PALETTE[n] for n in names], dtype=np.float32)
        near = names[int(((mean[None, :] - vals) ** 2).sum(axis=1).argmin())]
        out.append(
            f"  band {b}: {share * 100:5.1f}% ink   mean ink rgb{tuple(mean)} ({near})"
        )
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    path = args[0]
    cols = 128
    colour = "--colour" in args
    crop = None
    for i, a in enumerate(args):
        if a == "--cols":
            cols = int(args[i + 1])
        if a == "--crop":
            crop = tuple(int(x) for x in args[i + 1].split(","))
    img = load(path, crop)
    a = cells(img, cols)
    w, h = img.size
    print(f"{path}  {w}x{h}  ->  {cols} cols x {a.shape[0]} rows")
    print()
    print(colour_map(a) if colour else luminance_map(a))
    print()
    print("bands (top to bottom):")
    print(band_summary(a))


if __name__ == "__main__":
    main()
