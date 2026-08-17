#!/usr/bin/env python3
"""Builds Wrapybara's app icon from the committed source artwork.

    python3 Tools/make-appicon.py

Reads `media-sources/icon.png` and writes:

  * the ten slots in `Wrapybara/Resources/Assets.xcassets/AppIcon.appiconset/`
  * `docs/icon.png`, the small inline icon the README uses

Depends only on the Python standard library — it decodes, resamples and re-encodes
PNG itself (`zlib` does the compression), so regenerating the icon needs no image
tooling installed.

## What it does to the artwork, and why

The source is a full-bleed square. Dropped straight into a bundle it would sit in
the Dock as a hard square among rounded plates, at the wrong visual weight — the
exact tell this project exists to avoid. So the artwork is scaled to **824 of 1024**
(Apple's macOS app-icon grid) and its corners are rounded to the system radius,
which makes the source's own background field serve as the plate margin.

That inset is deliberate even though it makes the artwork smaller than filling the
canvas would: the grid is what makes an icon look the same *size* as its neighbours
in the Dock. An icon that ignores it reads as slightly too big, which is its own
kind of wrong.
"""

from __future__ import annotations

import math
import os
import struct
import sys
import zlib

# ---------------------------------------------------------------------------
# Geometry (in 1024-unit space)
# ---------------------------------------------------------------------------

CANVAS = 1024
PLATE = 824      # Apple's macOS app-icon grid
RADIUS = 185     # close enough to the system squircle that it doesn't read as "a
                 # rounded rectangle someone drew"

SOURCE = os.path.join("media-sources", "icon.png")
APPICONSET = os.path.join(
    "Wrapybara", "Resources", "Assets.xcassets", "AppIcon.appiconset")
README_ICON = os.path.join("docs", "icon.png")
README_ICON_PIXELS = 256   # the README displays it at 48pt; 256 covers Retina

SLOTS = [
    (16, "1x", 16),
    (16, "2x", 32),
    (32, "1x", 32),
    (32, "2x", 64),
    (128, "1x", 128),
    (128, "2x", 256),
    (256, "1x", 256),
    (256, "2x", 512),
    (512, "1x", 512),
    (512, "2x", 1024),
]

# ---------------------------------------------------------------------------
# PNG decoding
# ---------------------------------------------------------------------------


class Image:
    """An 8-bit RGBA raster, one `bytearray` of `w * h * 4`."""

    __slots__ = ("width", "height", "px")

    def __init__(self, width: int, height: int, px: bytearray | None = None):
        self.width = width
        self.height = height
        self.px = px if px is not None else bytearray(width * height * 4)


def decode_png(data: bytes) -> Image:
    """Decodes a non-interlaced, 8-bit PNG in RGB, RGBA, grey or grey+alpha.

    Deliberately narrow: it has to read one committed file, and refusing anything
    else loudly is better than mis-decoding it quietly. Palette and 16-bit sources
    are rejected with a message that says what to do about it.
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{SOURCE} is not a PNG")

    width = height = 0
    bit_depth = color_type = interlace = 0
    idat = bytearray()
    pos = 8
    while pos + 8 <= len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", body)
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + length

    if bit_depth != 8:
        raise SystemExit(f"{SOURCE}: expected 8 bits per channel, found {bit_depth}. "
                         "Re-export it as 8-bit RGB or RGBA.")
    if interlace:
        raise SystemExit(f"{SOURCE}: interlaced PNGs aren't supported. "
                         "Re-export without interlacing.")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        raise SystemExit(f"{SOURCE}: colour type {color_type} isn't supported "
                         "(palette/indexed). Re-export as RGB or RGBA.")

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    expected = (stride + 1) * height
    if len(raw) < expected:
        raise SystemExit(f"{SOURCE}: truncated image data")

    # Reverse the per-scanline filters. This is the whole of PNG decoding for a
    # non-interlaced 8-bit image.
    out = Image(width, height)
    previous = bytearray(stride)
    offset = 0
    for y in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride

        if filter_type == 1:      # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:    # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:    # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                up_left = previous[i - channels] if i >= channels else 0
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                nearest = left if (pa <= pb and pa <= pc) else (up if pb <= pc else up_left)
                line[i] = (line[i] + nearest) & 0xFF
        elif filter_type != 0:
            raise SystemExit(f"{SOURCE}: unknown scanline filter {filter_type}")

        # Widen whatever came in to RGBA.
        row = y * width * 4
        if channels == 4:
            out.px[row:row + width * 4] = line
        elif channels == 3:
            for x in range(width):
                s, d = x * 3, row + x * 4
                out.px[d:d + 4] = bytes((line[s], line[s + 1], line[s + 2], 255))
        elif channels == 2:
            for x in range(width):
                s, d = x * 2, row + x * 4
                grey = line[s]
                out.px[d:d + 4] = bytes((grey, grey, grey, line[s + 1]))
        else:
            for x in range(width):
                grey, d = line[x], row + x * 4
                out.px[d:d + 4] = bytes((grey, grey, grey, 255))

        previous = line

    return out


# ---------------------------------------------------------------------------
# Resampling
# ---------------------------------------------------------------------------


def resize(source: Image, size: int) -> Image:
    """Area-averages `source` down to `size`×`size`.

    A box filter rather than nearest-neighbour: these are large downscales (1254 to
    as little as 13 pixels), and point-sampling a furry photographic subject at
    those ratios produces exactly the crunchy aliasing that makes a small icon look
    cheap. Alpha is averaged alongside the colour channels, weighted so transparent
    pixels don't drag the colour toward black.
    """
    out = Image(size, size)
    sw, sh = source.width, source.height
    for y in range(size):
        y0 = y * sh // size
        y1 = max(y0 + 1, (y + 1) * sh // size)
        for x in range(size):
            x0 = x * sw // size
            x1 = max(x0 + 1, (x + 1) * sw // size)

            r = g = b = a = 0
            weight = 0
            count = 0
            for sy in range(y0, y1):
                base = (sy * sw) * 4
                for sx in range(x0, x1):
                    i = base + sx * 4
                    alpha = source.px[i + 3]
                    r += source.px[i] * alpha
                    g += source.px[i + 1] * alpha
                    b += source.px[i + 2] * alpha
                    a += alpha
                    weight += alpha
                    count += 1

            d = (y * size + x) * 4
            if weight:
                out.px[d:d + 4] = bytes((r // weight, g // weight, b // weight, a // count))
            # else: leave fully transparent
    return out


# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------


def rounded_rect_coverage(x: float, y: float, cx: float, cy: float,
                          half: float, radius: float) -> float:
    """Antialiased coverage of a rounded square at a pixel centre.

    Uses the shape's signed distance field, so the corners are smooth at any size
    without supersampling.
    """
    qx = abs(x - cx) - (half - radius)
    qy = abs(y - cy) - (half - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    distance = outside + min(max(qx, qy), 0.0) - radius
    if distance <= -0.5:
        return 1.0
    if distance >= 0.5:
        return 0.0
    return 0.5 - distance


def compose(source: Image, size: int) -> Image:
    """The finished icon at `size` pixels: the artwork on the grid, corners rounded."""
    plate = max(1, round(size * PLATE / CANVAS))
    scaled = resize(source, plate)

    canvas = Image(size, size)
    origin = (size - plate) / 2.0
    centre = size / 2.0
    half = plate / 2.0
    radius = max(0.5, RADIUS * size / CANVAS)

    for y in range(size):
        py = y + 0.5
        for x in range(size):
            coverage = rounded_rect_coverage(x + 0.5, py, centre, centre, half, radius)
            if coverage <= 0.0:
                continue
            sx = int(x - origin)
            sy = int(y - origin)
            if not (0 <= sx < plate and 0 <= sy < plate):
                continue
            s = (sy * plate + sx) * 4
            d = (y * size + x) * 4
            canvas.px[d] = scaled.px[s]
            canvas.px[d + 1] = scaled.px[s + 1]
            canvas.px[d + 2] = scaled.px[s + 2]
            canvas.px[d + 3] = int(round(scaled.px[s + 3] * coverage))
    return canvas


# ---------------------------------------------------------------------------
# PNG encoding
# ---------------------------------------------------------------------------


def encode_png(image: Image) -> bytes:
    raw = bytearray()
    stride = image.width * 4
    for y in range(image.height):
        raw.append(0)   # filter type 0 (None)
        raw += image.px[y * stride:(y + 1) * stride]

    def chunk(tag: bytes, body: bytes) -> bytes:
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", image.width, image.height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


# ---------------------------------------------------------------------------
# Slots
# ---------------------------------------------------------------------------

CONTENTS_TEMPLATE = """{{
  "images": [
{entries}
  ],
  "info": {{
    "author": "xcode",
    "version": 1
  }}
}}
"""


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)

    if not os.path.exists(SOURCE):
        raise SystemExit(f"{SOURCE} is missing — the app icon is built from it.")

    with open(SOURCE, "rb") as handle:
        source = decode_png(handle.read())
    print(f"source {source.width}×{source.height}", flush=True)

    os.makedirs(APPICONSET, exist_ok=True)
    os.makedirs(os.path.dirname(README_ICON), exist_ok=True)

    rendered: dict[int, bytes] = {}

    def render(pixels: int) -> bytes:
        if pixels not in rendered:
            print(f"rendering {pixels}×{pixels}…", flush=True)
            rendered[pixels] = encode_png(compose(source, pixels))
        return rendered[pixels]

    entries = []
    for point, scale, pixels in SLOTS:
        name = f"icon_{point}x{point}@{scale}.png"
        with open(os.path.join(APPICONSET, name), "wb") as handle:
            handle.write(render(pixels))
        entries.append(
            "    {\n"
            '      "idiom": "mac",\n'
            f'      "size": "{point}x{point}",\n'
            f'      "scale": "{scale}",\n'
            f'      "filename": "{name}"\n'
            "    }"
        )

    with open(os.path.join(APPICONSET, "Contents.json"), "w", encoding="utf-8") as handle:
        handle.write(CONTENTS_TEMPLATE.format(entries=",\n".join(entries)))

    with open(README_ICON, "wb") as handle:
        handle.write(render(README_ICON_PIXELS))

    print(f"wrote {len(SLOTS)} slots to {APPICONSET} and {README_ICON}")


if __name__ == "__main__":
    sys.exit(main())
