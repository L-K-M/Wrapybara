#!/usr/bin/env python3
"""Regenerates Wrapybara's AppIcon.appiconset from code.

The icon is drawn analytically rather than exported from a design tool, so it is
reproducible and reviewable in a diff: run this script and the ten PNG slots in
`Wrapybara/Resources/Assets.xcassets/AppIcon.appiconset/` are rewritten.

    python3 Tools/make-appicon.py

Depends only on the Python standard library (`zlib` + `struct` write the PNGs).
Every shape is rendered from its signed distance field, so edges are
antialiased at any size without supersampling, and each slot is drawn at its
native pixel size instead of downsampled from one master — small sizes drop
detail (traffic-light dots, eyes, nostrils) on purpose so 16pt stays legible.

The artwork: a warm sand squircle plate, a white browser window "wrapping" a
capybara whose muzzle breaks out through the window's bottom edge.
"""

from __future__ import annotations

import math
import os
import struct
import zlib

# ---------------------------------------------------------------------------
# Canvas
# ---------------------------------------------------------------------------


class Canvas:
    """A straight-alpha RGBA float canvas with SDF-coverage compositing."""

    def __init__(self, size: int):
        self.size = size
        # Row-major list of [r, g, b, a] in 0..1.
        self.px = [[0.0, 0.0, 0.0, 0.0] for _ in range(size * size)]

    # -- compositing ------------------------------------------------------

    def _blend(self, index: int, color: tuple[float, float, float], coverage: float) -> None:
        if coverage <= 0.0:
            return
        dst = self.px[index]
        sa = coverage
        da = dst[3]
        out_a = sa + da * (1.0 - sa)
        if out_a <= 0.0:
            dst[0] = dst[1] = dst[2] = dst[3] = 0.0
            return
        for c in range(3):
            dst[c] = (color[c] * sa + dst[c] * da * (1.0 - sa)) / out_a
        dst[3] = out_a

    def fill(self, sdf, color, bounds, alpha: float = 1.0, gradient=None) -> None:
        """Fills where `sdf(x, y) < 0`, antialiasing over the boundary pixel.

        `bounds` is an (x0, y0, x1, y1) pixel box to limit the scan. `gradient`,
        when given, is called with the normalised y (0 at top, 1 at bottom) and
        returns the colour for that row — used for the plate.
        """
        x0, y0, x1, y1 = bounds
        x0 = max(0, int(math.floor(x0)))
        y0 = max(0, int(math.floor(y0)))
        x1 = min(self.size, int(math.ceil(x1)))
        y1 = min(self.size, int(math.ceil(y1)))
        for y in range(y0, y1):
            row = y * self.size
            row_color = gradient(y / max(1, self.size - 1)) if gradient else color
            py = y + 0.5
            for x in range(x0, x1):
                d = sdf(x + 0.5, py)
                if d >= 0.5:
                    continue
                coverage = 1.0 if d <= -0.5 else 0.5 - d
                self._blend(row + x, row_color, coverage * alpha)

    # -- output -----------------------------------------------------------

    def png(self) -> bytes:
        # PNG stores straight (non-premultiplied) alpha, which is exactly how the
        # canvas keeps it, so the channels go out as they are.
        raw = bytearray()
        for y in range(self.size):
            raw.append(0)  # filter type 0 (None)
            row = y * self.size
            for x in range(self.size):
                r, g, b, a = self.px[row + x]
                raw += bytes((_byte(r), _byte(g), _byte(b), _byte(a)))
        return _png_bytes(self.size, self.size, bytes(raw))


def _byte(v: float) -> int:
    return max(0, min(255, int(round(v * 255.0))))


def _chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def _png_bytes(width: int, height: int, raw: bytes) -> bytes:
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", header)
        + _chunk(b"IDAT", zlib.compress(raw, 9))
        + _chunk(b"IEND", b"")
    )


# ---------------------------------------------------------------------------
# Signed distance fields
# ---------------------------------------------------------------------------


def rounded_rect(cx: float, cy: float, w: float, h: float, r: float):
    hw, hh = w / 2.0, h / 2.0
    r = min(r, hw, hh)

    def sdf(x: float, y: float) -> float:
        qx = abs(x - cx) - (hw - r)
        qy = abs(y - cy) - (hh - r)
        outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
        return outside + min(max(qx, qy), 0.0) - r

    return sdf, (cx - hw - 1, cy - hh - 1, cx + hw + 1, cy + hh + 1)


def ellipse(cx: float, cy: float, rx: float, ry: float):
    def sdf(x: float, y: float) -> float:
        dx = (x - cx) / rx
        dy = (y - cy) / ry
        return (math.hypot(dx, dy) - 1.0) * min(rx, ry)

    return sdf, (cx - rx - 1, cy - ry - 1, cx + rx + 1, cy + ry + 1)


def circle(cx: float, cy: float, r: float):
    return ellipse(cx, cy, r, r)


def intersect(a, b):
    """SDF of the intersection of two shapes (max of the two distances)."""
    sdf_a, bounds_a = a
    sdf_b, bounds_b = b
    bounds = (
        max(bounds_a[0], bounds_b[0]),
        max(bounds_a[1], bounds_b[1]),
        min(bounds_a[2], bounds_b[2]),
        min(bounds_a[3], bounds_b[3]),
    )
    return (lambda x, y: max(sdf_a(x, y), sdf_b(x, y))), bounds


def rgb(hex_code: str) -> tuple[float, float, float]:
    hex_code = hex_code.lstrip("#")
    return tuple(int(hex_code[i : i + 2], 16) / 255.0 for i in (0, 2, 4))  # type: ignore[return-value]


# ---------------------------------------------------------------------------
# The artwork
# ---------------------------------------------------------------------------

PLATE_TOP = rgb("F7DCAC")
PLATE_BOTTOM = rgb("DFA167")
WINDOW = rgb("FFFFFF")
TITLEBAR = rgb("ECE7E1")
FUR = rgb("8B5A2B")
FUR_LIGHT = rgb("A87243")
FUR_DARK = rgb("6B4522")
INK = rgb("3A2413")
TRAFFIC = (rgb("FF5F57"), rgb("FEBC2E"), rgb("28C840"))


def draw(size: int) -> Canvas:
    """Draws the icon at `size` pixels. Geometry is expressed in 1024 units."""
    canvas = Canvas(size)
    s = size / 1024.0

    def u(v: float) -> float:
        return v * s

    # Detail thresholds: below these sizes the small marks turn to mush and
    # muddy the silhouette, so they're dropped instead of drawn.
    show_traffic_lights = size >= 128
    show_face = size >= 64
    show_titlebar = size >= 48

    # 1. The plate — a squircle-ish rounded rect with a warm vertical gradient.
    plate = rounded_rect(u(512), u(512), u(824), u(824), u(188))
    plate_top_y = u(100) / max(1.0, size - 1)
    plate_bottom_y = u(924) / max(1.0, size - 1)

    def plate_gradient(t: float) -> tuple[float, float, float]:
        span = max(1e-6, plate_bottom_y - plate_top_y)
        k = min(1.0, max(0.0, (t - plate_top_y) / span))
        return tuple(  # type: ignore[return-value]
            PLATE_TOP[c] + (PLATE_BOTTOM[c] - PLATE_TOP[c]) * k for c in range(3)
        )

    canvas.fill(plate[0], None, plate[1], gradient=plate_gradient)

    # 2. The window that does the wrapping.
    win_cx, win_cy = u(512), u(486)
    win_w, win_h = u(608), u(556)
    win_r = u(76)
    window = rounded_rect(win_cx, win_cy, win_w, win_h, win_r)
    canvas.fill(window[0], WINDOW, window[1])

    win_top = win_cy - win_h / 2.0
    bar_h = u(104)
    if show_titlebar:
        # Clip a plain bar to the window so the top corners stay rounded.
        bar = rounded_rect(win_cx, win_top + bar_h / 2.0, win_w, bar_h, 0.0)
        clipped = intersect(bar, window)
        canvas.fill(clipped[0], TITLEBAR, clipped[1])

    if show_traffic_lights:
        for i, color in enumerate(TRAFFIC):
            dot = circle(u(272 + i * 58), win_top + bar_h / 2.0, u(17))
            canvas.fill(dot[0], color, dot[1])

    # 3. The capybara, drawn over the window so the muzzle breaks the frame.
    head_cx, head_cy = u(512), u(596)
    for ear_x in (u(372), u(652)):
        ear = circle(ear_x, u(438), u(54))
        canvas.fill(ear[0], FUR_DARK, ear[1])

    head = rounded_rect(head_cx, head_cy, u(384), u(346), u(128))
    canvas.fill(head[0], FUR, head[1])

    muzzle = rounded_rect(head_cx, u(716), u(268), u(190), u(86))
    canvas.fill(muzzle[0], FUR_LIGHT, muzzle[1])

    if show_face:
        for eye_x in (u(430), u(594)):
            eye = circle(eye_x, u(542), u(27))
            canvas.fill(eye[0], INK, eye[1])
        for nose_x in (u(468), u(556)):
            nose = ellipse(nose_x, u(690), u(17), u(23))
            canvas.fill(nose[0], INK, nose[1])
        # A short mouth line under the nostrils.
        mouth = rounded_rect(head_cx, u(756), u(96), u(16), u(8))
        canvas.fill(mouth[0], FUR_DARK, mouth[1], alpha=0.75)

    return canvas


# ---------------------------------------------------------------------------
# Slots
# ---------------------------------------------------------------------------

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
    out = os.path.join(
        root, "Wrapybara", "Resources", "Assets.xcassets", "AppIcon.appiconset"
    )
    os.makedirs(out, exist_ok=True)

    rendered: dict[int, bytes] = {}
    entries = []
    for point, scale, pixels in SLOTS:
        if pixels not in rendered:
            print(f"rendering {pixels}×{pixels}…", flush=True)
            rendered[pixels] = draw(pixels).png()
        name = f"icon_{point}x{point}@{scale}.png"
        with open(os.path.join(out, name), "wb") as handle:
            handle.write(rendered[pixels])
        entries.append(
            "    {\n"
            '      "idiom": "mac",\n'
            f'      "size": "{point}x{point}",\n'
            f'      "scale": "{scale}",\n'
            f'      "filename": "{name}"\n'
            "    }"
        )

    with open(os.path.join(out, "Contents.json"), "w", encoding="utf-8") as handle:
        handle.write(CONTENTS_TEMPLATE.format(entries=",\n".join(entries)))
    print(f"wrote {len(SLOTS)} slots to {out}")


if __name__ == "__main__":
    main()
