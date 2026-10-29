#!/usr/bin/env python3
"""Build the fixed 128-step pen-path input used by the math glyph model."""

from __future__ import annotations

import json
import math
import struct
from pathlib import Path
from typing import Sequence


SAMPLE_COUNT = 128
MAX_STROKES = 64
MIN_SAMPLES_PER_STROKE = 2
COORDINATE_LIMIT = 200_000.0
Point = tuple[float, float]


def _float32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def _segment_lengths(path: Sequence[Point]) -> list[float]:
    lengths = []
    for first, second in zip(path, path[1:]):
        dx = second[0] - first[0]
        dy = second[1] - first[1]
        dx_squared = dx * dx
        dy_squared = dy * dy
        lengths.append(math.sqrt(dx_squared + dy_squared))
    return lengths


def _allocate_sample_counts(lengths: Sequence[float]) -> list[int]:
    count = len(lengths)
    if not 1 <= count <= MAX_STROKES:
        raise ValueError("sample allocation requires 1 to 64 nonempty strokes")

    remainder = SAMPLE_COUNT - MIN_SAMPLES_PER_STROKE * count
    total_length = 0.0
    for length in lengths:
        total_length = total_length + length

    if total_length == 0:
        each, extra = divmod(remainder, count)
        result = [MIN_SAMPLES_PER_STROKE + each + (index < extra) for index in range(count)]
        assert sum(result) == SAMPLE_COUNT and min(result) >= MIN_SAMPLES_PER_STROKE
        return result

    bases = []
    fractions = []
    allocated = 0
    for length in lengths:
        quota = (float(remainder) * length) / total_length
        base = math.floor(quota)
        bases.append(base)
        fractions.append(quota - base)
        allocated += base

    leftover = remainder - allocated
    order = sorted(range(count), key=lambda index: (-fractions[index], index))
    bonuses = [0] * count
    for index in order[:leftover]:
        bonuses[index] = 1

    result = [MIN_SAMPLES_PER_STROKE + base + bonus for base, bonus in zip(bases, bonuses)]
    assert sum(result) == SAMPLE_COUNT and min(result) >= MIN_SAMPLES_PER_STROKE
    return result


def _resample(path: Sequence[Point], count: int, length: float) -> list[Point]:
    if length == 0:
        return [path[0]] * count

    segment_lengths = _segment_lengths(path)
    cumulative_ends = []
    cumulative = 0.0
    for segment_length in segment_lengths:
        cumulative = cumulative + segment_length
        cumulative_ends.append(cumulative)

    samples = [path[0]]
    segment_index = 0
    for sample_index in range(1, count - 1):
        target = (float(sample_index) * length) / float(count - 1)
        while segment_index < len(segment_lengths) and (
            segment_lengths[segment_index] == 0
            or cumulative_ends[segment_index] < target
        ):
            segment_index += 1

        segment_length = segment_lengths[segment_index]
        segment_start = 0.0 if segment_index == 0 else cumulative_ends[segment_index - 1]
        fraction = (target - segment_start) / segment_length
        first, second = path[segment_index], path[segment_index + 1]
        dx = second[0] - first[0]
        dy = second[1] - first[1]
        x_offset = fraction * dx
        y_offset = fraction * dy
        samples.append((first[0] + x_offset, first[1] + y_offset))

    samples.append(path[-1])
    return samples


def encode(strokes: Sequence[Sequence[Sequence[float]]]) -> dict | None:
    """Return sample-major [128, 4] Float32 features and allocation counts, or None."""
    paths: list[list[Point]] = []
    for stroke in strokes:
        path = []
        for point in stroke:
            current = (float(point[0]), float(point[1]))
            if any(not math.isfinite(value) or abs(value) > COORDINATE_LIMIT for value in current):
                return None
            if not path or current != path[-1]:
                path.append(current)
        if path:
            paths.append(path)
            if len(paths) == MAX_STROKES:
                break

    if not paths:
        return None

    lengths = []
    for path in paths:
        length = 0.0
        for segment_length in _segment_lengths(path):
            length = length + segment_length
        lengths.append(length)
    sample_counts = _allocate_sample_counts(lengths)

    min_x = min(point[0] for path in paths for point in path)
    max_x = max(point[0] for path in paths for point in path)
    min_y = min(point[1] for path in paths for point in path)
    max_y = max(point[1] for path in paths for point in path)
    width = max_x - min_x
    height = max_y - min_y
    center_x = min_x + width / 2.0
    center_y = min_y + height / 2.0
    scale = max(width, height, 1e-6)

    features = []
    for path, count, length in zip(paths, sample_counts, lengths):
        samples = _resample(path, count, length)
        for index, (x, y) in enumerate(samples):
            features.append([
                _float32((x - center_x) / scale),
                _float32((y - center_y) / scale),
                float(index == 0),
                float(index == count - 1),
            ])

    assert len(features) == SAMPLE_COUNT and sum(sample_counts) == SAMPLE_COUNT
    return {
        "strokePoints": features,
        "sampleCounts": sample_counts,
    }


def _check_fixture_file() -> None:
    fixture_path = Path(__file__).parents[2] / "Tests/CanvasKitTests/Fixtures/sequence/fixtures.json"
    manifest = json.loads(fixture_path.read_text())
    assert len(manifest["fixtures"]) == 12
    for fixture in manifest["fixtures"]:
        actual = encode(fixture["strokes"])
        assert actual is not None, fixture["name"]
        assert actual["sampleCounts"] == fixture["sampleCounts"], fixture["name"]
        assert actual["strokePoints"] == fixture["strokePoints"], fixture["name"]

    seventy = next(fixture for fixture in manifest["fixtures"] if fixture["name"] == "seventy_strokes")
    assert encode(seventy["strokes"]) == encode(seventy["strokes"][:MAX_STROKES])

    assert _allocate_sample_counts([2.0, 1.0] + [0.0] * 62) == [2] * 64
    assert _allocate_sample_counts([0.0]) == [128]
    assert _allocate_sample_counts([0.0] * 3) == [43, 43, 42]
    assert _allocate_sample_counts([3.0, 1.0]) == [95, 33]
    assert _allocate_sample_counts([1.0] * 3) == [43, 43, 42]
    assert encode([]) is None
    assert encode([[[float("nan"), 0.0]]]) is None
    assert encode([[[float("inf"), 0.0]]]) is None
    assert encode([[[200_001.0, 0.0]]]) is None


if __name__ == "__main__":
    _check_fixture_file()
    print("sequence fixtures and allocation checks passed")
