#!/usr/bin/env python3
"""Rasterize stroke coordinates with CanvasKit's deterministic 32px raster."""

from __future__ import annotations

import math
from typing import Sequence

from PIL import Image


SIZE = 32
SOURCE_SCALE = 1 << 16
PIXEL_SCALE = 1 << 8
CENTER = (SIZE // 2) * PIXEL_SCALE
HALF_SPAN = 13 * PIXEL_SCALE  # 26px centerline span leaves two painted px of padding.
COORDINATE_LIMIT = 200_000.0
def _round_away(value: float) -> int:
    """Round to nearest integer, with half values away from zero."""
    return math.floor(value + 0.5) if value >= 0 else -math.floor(-value + 0.5)


def _round_ratio(numerator: int, denominator: int) -> int:
    """Round an integer ratio to nearest, with half values away from zero."""
    sign = -1 if numerator < 0 else 1
    return sign * ((abs(numerator) + denominator // 2) // denominator)


def _normalize_strokes(
    strokes: Sequence[Sequence[Sequence[float]]]
) -> list[list[tuple[int, int]]] | None:
    paths: list[list[tuple[float, float]]] = []
    flat: list[tuple[float, float]] = []
    for stroke in strokes:
        path = [(float(point[0]), float(point[1])) for point in stroke]
        if not path:
            continue
        if any(
            not math.isfinite(coord) or abs(coord) > COORDINATE_LIMIT
            for point in path
            for coord in point
        ):
            return None
        paths.append(path)
        flat.extend(path)
    if not flat:
        return []

    min_x = min(point[0] for point in flat)
    min_y = min(point[1] for point in flat)
    source_paths = [
        [
            (
                _round_away((x - min_x) * SOURCE_SCALE),
                _round_away((y - min_y) * SOURCE_SCALE),
            )
            for x, y in path
        ]
        for path in paths
    ]
    span_x = max(point[0] for path in source_paths for point in path)
    span_y = max(point[1] for path in source_paths for point in path)
    span = max(span_x, span_y)
    if span == 0:
        return [[(CENTER, CENTER) for _ in path] for path in source_paths]

    return [
        [
            (
                CENTER + _round_ratio((2 * x - span_x) * HALF_SPAN, span),
                CENTER + _round_ratio((2 * y - span_y) * HALF_SPAN, span),
            )
            for x, y in path
        ]
        for path in source_paths
    ]


def _draw_segment(pixels: bytearray, start: tuple[int, int], end: tuple[int, int]) -> None:
    x0, y0 = start
    x1, y1 = end
    dx, dy = x1 - x0, y1 - y0
    length_squared = dx * dx + dy * dy
    radius_squared = PIXEL_SCALE * PIXEL_SCALE

    x_min = max(0, min(x0, x1) // PIXEL_SCALE - 1)
    x_max = min(SIZE - 1, max(x0, x1) // PIXEL_SCALE + 1)
    y_min = max(0, min(y0, y1) // PIXEL_SCALE - 1)
    y_max = min(SIZE - 1, max(y0, y1) // PIXEL_SCALE + 1)
    for y in range(y_min, y_max + 1):
        py = y * PIXEL_SCALE + PIXEL_SCALE // 2
        for x in range(x_min, x_max + 1):
            px = x * PIXEL_SCALE + PIXEL_SCALE // 2
            vx, vy = px - x0, py - y0
            projection = vx * dx + vy * dy
            if projection <= 0:
                inside = vx * vx + vy * vy <= radius_squared
            elif projection >= length_squared:
                ex, ey = px - x1, py - y1
                inside = ex * ex + ey * ey <= radius_squared
            else:
                cross = vx * dy - vy * dx
                inside = cross * cross <= radius_squared * length_squared
            if inside:
                pixels[y * SIZE + x] = 0


def rasterize(strokes: Sequence[Sequence[Sequence[float]]]) -> Image.Image:
    """Return a 32×32 grayscale image (0 black, 255 white) from raw strokes."""
    lines = _normalize_strokes(strokes)
    pixels = bytearray([255]) * (SIZE * SIZE)
    if lines is None:
        return Image.frombytes("L", (SIZE, SIZE), bytes(pixels))
    for line in lines:
        if len(line) == 1:
            _draw_segment(pixels, line[0], line[0])
        else:
            for start, end in zip(line, line[1:]):
                _draw_segment(pixels, start, end)
    return Image.frombytes("L", (SIZE, SIZE), bytes(pixels))


def _self_check() -> None:
    dot = rasterize([[(10, 20)]])
    assert dot.mode == "L" and dot.size == (32, 32)
    assert dot.getpixel((16, 16)) == 0
    assert sum(value == 0 for value in dot.getdata()) == 4
    flat = rasterize([[(0, 0), (1, 0)]])
    expected = {y * SIZE + x for y in (15, 16) for x in range(2, 30)}
    assert {index for index, value in enumerate(flat.getdata()) if value == 0} == expected
    negative = rasterize([[(-6, -4), (6, 4)]])
    translated = rasterize([[(4, 6), (16, 14)]])
    assert negative.tobytes() == translated.tobytes()

    blank = rasterize([])
    assert blank.getpixel((16, 16)) == 255


if __name__ == "__main__":
    _self_check()
    print("raster self-check passed")
