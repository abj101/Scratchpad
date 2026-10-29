#!/usr/bin/env python3
"""Generate deterministic augmented single-line training strokes."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import random
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SOURCES = Path(__file__).resolve().parent / "sources"
RELIEF_SVG = SOURCES / "ReliefSingleLineSVG-Regular.svg"
RELIEF_NOTICE = "scripts/glyphs/sources/ReliefSingleLine-OFL.txt"
HERSHEY_NOTICE = "Sources/CanvasKit/Resources/HERSHEY-NOTICE.txt"
RELIEF_URL = "https://github.com/isdat-type/Relief-SingleLine"
RELIEF_COMMIT = "01dfc5779ec1e9e4b288d96c6c96c23bfccbaf9d"
RELIEF_LICENSE = "SIL Open Font License 1.1"
HERSHEY_LICENSE = "Hershey permitted-use notice"
HERSHEY_URL = "https://github.com/scruss/python-hershey"
HERSHEY_RAW_URL = "https://raw.githubusercontent.com/scruss/python-hershey/master/hershey-occidental.json"
HERSHEY_FONTS_URL = "https://github.com/kamalmostafa/hershey-fonts/tree/1356bf2f83d380fcef68c887e88675eb9d445d86/hershey-fonts"
FAMILIES = ("Simplex", "Complex", "Script", "Italic", "Greek")
HERSHEY_FONT_FILES = (
    ("Hershey Simplex Roman", "rowmans.jhf"),
    ("Hershey Complex Roman", "timesr.jhf"),
    ("Hershey Complex Italic", "timesi.jhf"),
    ("Hershey Complex Italic Bold", "timesib.jhf"),
    ("Hershey Script Simplex", "scripts.jhf"),
    ("Hershey Script Complex", "scriptc.jhf"),
    ("Hershey Greek Simplex", "greeks.jhf"),
    ("Hershey Greek Complex", "greekc.jhf"),
)
DOT_LABELS = {".", "·"}
DOT_VARIANTS = ("point", "loop", "scribble")

Point = tuple[float, float]
Stroke = list[Point]


def _family_categories(name: str) -> set[str]:
    value = name.casefold()
    return {family for family in FAMILIES if family.casefold() in value}


def _stroke_key(left: int, right: int, lines: Any) -> tuple[Any, ...]:
    return left, right, tuple(tuple(tuple(int(value) for value in point) for point in line) for line in lines)


def _font_index(path: Path) -> tuple[set[int], set[tuple[Any, ...]]]:
    """Decode JHF polylines and index source IDs; a few carry placeholder IDs."""
    source_ids: set[int] = set()
    shapes: set[tuple[Any, ...]] = set()
    for line in path.read_text(encoding="latin-1").splitlines():
        if len(line) < 10 or not line[:5].strip().isdigit() or not line[5:8].strip().isdigit():
            continue
        source_ids.add(int(line[:5]))
        left, right = ord(line[8]) - ord("R"), ord(line[9]) - ord("R")
        body = line[10:].rstrip("\x1a ")
        strokes = []
        for part in body.split(" R"):
            part = part.rstrip("\x1a ")
            if not part:
                continue
            if len(part) % 2:
                raise ValueError(f"odd JHF coordinate byte count in {path.name}")
            strokes.append(tuple(
                (ord(part[index]) - ord("R"), ord(part[index + 1]) - ord("R"))
                for index in range(0, len(part), 2)
            ))
        shapes.add((left, right, tuple(strokes)))
    return source_ids, shapes


def _source_ids(raw: Any) -> list[int]:
    return sorted({int(source_id) for source_id in (raw or []) if source_id is not None})


def _distance(a: Point, b: Point) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def _extent(strokes: list[Stroke]) -> float:
    points = [point for stroke in strokes for point in stroke]
    if not points:
        return 1.0
    return max(
        max(point[0] for point in points) - min(point[0] for point in points),
        max(point[1] for point in points) - min(point[1] for point in points),
        1.0,
    )


def _center(strokes: list[Stroke]) -> Point:
    points = [point for stroke in strokes for point in stroke]
    if not points:
        return 0.0, 0.0
    return (
        (min(point[0] for point in points) + max(point[0] for point in points)) / 2,
        (min(point[1] for point in points) + max(point[1] for point in points)) / 2,
    )


def _path_length(stroke: Stroke) -> float:
    return sum(_distance(a, b) for a, b in zip(stroke, stroke[1:]))


def _dot_variant(template: list[Stroke], variant: str, rng: random.Random) -> list[Stroke]:
    """Derive point, loop, and overdraw variants from a sourced round glyph."""
    points = template[0]
    center = _center(template)
    if variant == "point":
        return [[center]]

    if not points:
        raise ValueError("round glyph template has no points")
    loop = list(points)
    if loop[0] != loop[-1]:
        loop.append(loop[0])

    def transformed(scale: float, angle: float, dx: float, dy: float) -> Stroke:
        cosine, sine = math.cos(angle), math.sin(angle)
        return [
            (
                center[0] + (x - center[0]) * scale * cosine - (y - center[1]) * scale * sine + dx,
                center[1] + (x - center[0]) * scale * sine + (y - center[1]) * scale * cosine + dy,
            )
            for x, y in loop
        ]

    if variant == "loop":
        return [transformed(rng.uniform(0.9, 1.1), rng.uniform(-0.16, 0.16), 0, 0)]
    if variant == "scribble":
        extent = _extent(template)
        passes = []
        for index in range(11):
            scale = 1.0 - index * 0.095
            passes.append(transformed(
                scale,
                rng.uniform(-0.12, 0.12),
                rng.uniform(-0.025, 0.025) * extent * scale,
                rng.uniform(-0.025, 0.025) * extent * scale,
            ))
        return passes
    raise ValueError(f"unknown dot variant: {variant}")


def _cubic_flatness(p0: Point, p1: Point, p2: Point, p3: Point) -> float:
    chord = _distance(p0, p3)
    if chord == 0:
        return max(_distance(p0, p1), _distance(p0, p2))
    return max(
        abs((p3[0] - p0[0]) * (p0[1] - p1[1]) - (p0[0] - p1[0]) * (p3[1] - p0[1])) / chord,
        abs((p3[0] - p0[0]) * (p0[1] - p2[1]) - (p0[0] - p2[0]) * (p3[1] - p0[1])) / chord,
    )


def _flatten_cubic(p0: Point, p1: Point, p2: Point, p3: Point, output: Stroke, depth: int = 0) -> None:
    if depth >= 12 or _cubic_flatness(p0, p1, p2, p3) <= 2.5:
        output.append(p3)
        return
    p01 = ((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2)
    p12 = ((p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2)
    p23 = ((p2[0] + p3[0]) / 2, (p2[1] + p3[1]) / 2)
    p012 = ((p01[0] + p12[0]) / 2, (p01[1] + p12[1]) / 2)
    p123 = ((p12[0] + p23[0]) / 2, (p12[1] + p23[1]) / 2)
    middle = ((p012[0] + p123[0]) / 2, (p012[1] + p123[1]) / 2)
    _flatten_cubic(p0, p01, p012, middle, output, depth + 1)
    _flatten_cubic(middle, p123, p23, p3, output, depth + 1)


def _relief_path_strokes(path_data: str) -> list[tuple[Stroke, bool]]:
    try:
        from fontTools.pens.recordingPen import RecordingPen
        from fontTools.svgLib.path import parse_path
    except ImportError as error:
        raise RuntimeError("Relief SVG parsing requires the already-installed fontTools package") from error

    pen = RecordingPen()
    parse_path(path_data, pen)
    paths: list[tuple[Stroke, bool]] = []
    current: Stroke = []
    start: Point | None = None

    def flush(closed: bool = False) -> None:
        nonlocal current, start
        if current:
            paths.append(([(x, -y) for x, y in current], closed))
        current, start = [], None

    for operation, args in pen.value:
        if operation == "moveTo":
            flush()
            start = tuple(args[0])
            current = [start]
        elif operation == "lineTo" and current:
            current.append(tuple(args[0]))
        elif operation == "curveTo" and current:
            points = [tuple(point) for point in args]
            while len(points) >= 3:
                _flatten_cubic(current[-1], points[0], points[1], points[2], current)
                points = points[3:]
        elif operation == "qCurveTo" and current:
            points = [tuple(point) if point is not None else None for point in args]
            if len(points) == 2 and all(point is not None for point in points):
                control, end = points
                p0 = current[-1]
                c1 = (p0[0] + (control[0] - p0[0]) * (2 / 3), p0[1] + (control[1] - p0[1]) * (2 / 3))
                c2 = (end[0] + (control[0] - end[0]) * (2 / 3), end[1] + (control[1] - end[1]) * (2 / 3))
                _flatten_cubic(p0, c1, c2, end, current)
            else:
                raise ValueError("unsupported quadratic Relief path")
        elif operation == "closePath" and current:
            if start is not None and current[-1] != start:
                current.append(start)
            flush(closed=True)
        elif operation == "endPath":
            flush()
        else:
            raise ValueError(f"unsupported Relief SVG path operation: {operation}")
    flush()
    return paths


def _load_relief(path: Path) -> dict[str, dict[str, Any]]:
    glyphs: dict[str, dict[str, Any]] = {}
    root = ET.parse(path).getroot()
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] != "glyph":
            continue
        label = element.get("unicode", "")
        path_data = element.get("d")
        if len(label) != 1 or not path_data:
            continue
        if label in glyphs:
            continue
        paths = _relief_path_strokes(path_data)
        strokes = [stroke for stroke, _ in paths if stroke]
        if not strokes:
            continue
        glyphs[label] = {
            "strokes": strokes,
            "advance": float(element.get("horiz-adv-x", "600")),
            "source_id": f"U+{ord(label):04X}",
        }
    return glyphs


def _load_sources(vocab_path: Path, glyphs_path: Path, raw_hershey_path: Path, relief_path: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    vocab = json.loads(vocab_path.read_text(encoding="utf-8"))
    glyphs = json.loads(glyphs_path.read_text(encoding="utf-8"))
    raw_records = json.loads(raw_hershey_path.read_text(encoding="utf-8"))
    raw_by_id = {int(record["charcode"]): record for record in raw_records}
    round_glyph = glyphs.get("°")
    if round_glyph is None:
        raise ValueError("missing bundled Hershey degree loop used for dot augmentation")
    dot_template = {
        "strokes": [[(float(x), float(y)) for x, y in line] for line in round_glyph["strokes"]],
        "source": "Hershey",
        "family": "Hershey canonical",
        "source_id": round_glyph.get("sourceID") or "composition:°",
        "source_ids": round_glyph.get("sourceIDs", []),
        "source_label": "°",
        "license": HERSHEY_LICENSE,
        "notice": HERSHEY_NOTICE,
        "url": HERSHEY_RAW_URL,
        "advance": float(round_glyph.get("advance", 0)),
    }
    font_indexes = {
        family: _font_index(SOURCES / "hershey" / filename)
        for family, filename in HERSHEY_FONT_FILES
    }
    font_hashes = {
        filename: hashlib.sha256((SOURCES / "hershey" / filename).read_bytes()).hexdigest()
        for _, filename in HERSHEY_FONT_FILES
    }
    relief = _load_relief(relief_path)
    classes: list[dict[str, Any]] = []
    misses: list[str] = []

    for item in vocab["classes"]:
        label = item["label"]
        variants: list[dict[str, Any]] = []
        candidate_ids = _source_ids(item.get("hershey_sources"))
        for family, (font_ids, shapes) in font_indexes.items():
            direct_ids = [source_id for source_id in candidate_ids if source_id in font_ids]
            placeholder_file = font_ids == {12345}
            if not direct_ids and placeholder_file:
                seen_shapes: set[tuple[Any, ...]] = set()
                for source_id in candidate_ids:
                    record = raw_by_id.get(source_id)
                    if record is None:
                        raise ValueError(f"{label!r}: missing Hershey source id {source_id}")
                    key = _stroke_key(record["left"], record["right"], record["lines"])
                    if key in shapes and key not in seen_shapes:
                        direct_ids.append(source_id)
                        seen_shapes.add(key)
            for source_id in direct_ids:
                record = raw_by_id.get(source_id)
                if record is None:
                    raise ValueError(f"{label!r}: missing Hershey source id {source_id}")
                key = _stroke_key(record["left"], record["right"], record["lines"])
                if not placeholder_file and key not in shapes:
                    raise ValueError(f"{label!r}: source {source_id} ID/geometry mismatch in {family}")
                if placeholder_file and key not in shapes:
                    raise ValueError(f"{label!r}: source {source_id} geometry mismatch in {family}")
                variants.append({
                    "strokes": [[(float(x), float(y)) for x, y in line] for line in record["lines"]],
                    "source": "Hershey",
                    "family": family,
                    "source_id": source_id,
                    "license": HERSHEY_LICENSE,
                    "notice": HERSHEY_NOTICE,
                    "url": HERSHEY_RAW_URL,
                    "map_url": f"{HERSHEY_FONTS_URL}/{dict(HERSHEY_FONT_FILES)[family]}",
                    "advance": float(record["right"] - record["left"]),
                })
        if label in glyphs:
            glyph = glyphs[label]
            variants.append({
                "strokes": [[(float(x), float(y)) for x, y in line] for line in glyph["strokes"]],
                "source": "Hershey",
                "family": "Hershey canonical",
                "source_id": glyph.get("sourceID") or f"composition:{label}",
                "source_ids": glyph.get("sourceIDs", []),
                "license": HERSHEY_LICENSE,
                "notice": HERSHEY_NOTICE,
                "url": HERSHEY_RAW_URL,
                "advance": float(glyph.get("advance", 0)),
            })
        if label in relief:
            glyph = relief[label]
            variants.append({
                "strokes": glyph["strokes"],
                "source": "Relief SingleLine SVG",
                "family": "Relief SingleLine",
                "source_id": glyph["source_id"],
                "license": RELIEF_LICENSE,
                "notice": RELIEF_NOTICE,
                "url": f"{RELIEF_URL}/tree/{RELIEF_COMMIT}",
                "advance": glyph["advance"],
            })
        unique: dict[tuple[str, str], dict[str, Any]] = {}
        for variant in variants:
            unique[(variant["family"], str(variant["source_id"]))] = variant
        variants = sorted(unique.values(), key=lambda variant: (variant["family"].casefold(), str(variant["source_id"])))
        if not variants:
            misses.append(label)
        classes.append({
            **item,
            "variants": variants,
            **({"dot_template": dot_template} if label in DOT_LABELS else {}),
        })

    if misses:
        raise ValueError("no verified stroke source for labels: " + " ".join(misses))
    return classes, {
        "vocab_sha256": hashlib.sha256(vocab_path.read_bytes()).hexdigest(),
        "glyphs_sha256": hashlib.sha256(glyphs_path.read_bytes()).hexdigest(),
        "relief_svg_sha256": hashlib.sha256(relief_path.read_bytes()).hexdigest(),
        "raw_hershey_records": len(raw_records),
        "raw_hershey_file": raw_hershey_path.name,
        "raw_hershey_sha256": hashlib.sha256(raw_hershey_path.read_bytes()).hexdigest(),
        "relief_glyphs": len(relief),
        "hershey_font_files": font_hashes,
        "dot_template": {
            "label": dot_template["source_label"],
            "source_id": dot_template["source_id"],
            "source_ids": dot_template["source_ids"],
            "license": dot_template["license"],
            "notice": dot_template["notice"],
        },
    }


def _stable_seed(seed: int, label: str, sample: int, source: dict[str, Any]) -> int:
    value = f"{seed}\0{label}\0{sample}\0{source['family']}\0{source['source_id']}".encode("utf-8")
    return int.from_bytes(hashlib.sha256(value).digest()[:8], "big")


def _rotate_and_shift(stroke: Stroke, center: Point, angle: float, dx: float, dy: float) -> Stroke:
    cosine, sine = math.cos(angle), math.sin(angle)
    return [
        (
            center[0] + (x - center[0]) * cosine - (y - center[1]) * sine + dx,
            center[1] + (x - center[0]) * sine + (y - center[1]) * cosine + dy,
        )
        for x, y in stroke
    ]


def _resample(stroke: Stroke, step: float) -> Stroke:
    output: Stroke = []
    for start, end in zip(stroke, stroke[1:]):
        if not output:
            output.append(start)
        length = _distance(start, end)
        pieces = max(1, min(32, math.ceil(length / max(step, 1e-6))))
        output.extend((
            start[0] + (end[0] - start[0]) * index / pieces,
            start[1] + (end[1] - start[1]) * index / pieces,
        ) for index in range(1, pieces + 1))
    return output or list(stroke)


def _wobble(stroke: Stroke, extent: float, rng: random.Random) -> Stroke:
    if len(stroke) < 2:
        return stroke
    path = _resample(stroke, extent * 0.18)
    total = _path_length(path)
    if total <= extent * 0.12:
        return path
    amplitude = extent * rng.uniform(0.006, 0.018)
    wavelength = total * rng.uniform(0.45, 0.9)
    phase = rng.uniform(-math.pi, math.pi)
    distance = 0.0
    result: Stroke = []
    for index, point in enumerate(path):
        if index:
            distance += _distance(path[index - 1], point)
        if index == 0 or index == len(path) - 1:
            result.append(point)
            continue
        before, after = path[index - 1], path[index + 1]
        tx, ty = after[0] - before[0], after[1] - before[1]
        norm = math.hypot(tx, ty)
        if norm == 0:
            result.append(point)
            continue
        envelope = math.sin(math.pi * distance / total)
        offset = amplitude * envelope * math.sin(2 * math.pi * distance / wavelength + phase)
        result.append((point[0] - ty / norm * offset, point[1] + tx / norm * offset))
    return result


def _endpoint_variant(stroke: Stroke, extent: float, rng: random.Random, hook: bool) -> Stroke:
    if len(stroke) < 2 or _path_length(stroke) < extent * 0.18:
        return stroke
    at_start = rng.random() < 0.5
    points = list(reversed(stroke)) if at_start else list(stroke)
    first, second = points[-2], points[-1]
    dx, dy = second[0] - first[0], second[1] - first[1]
    length = math.hypot(dx, dy)
    if length == 0:
        return stroke
    scale = extent * rng.uniform(0.018, 0.045) / length
    tip = (second[0] + dx * scale, second[1] + dy * scale)
    points.append(tip)
    if hook:
        side = rng.choice((-1, 1)) * extent * rng.uniform(0.012, 0.026)
        points.append((tip[0] - dy / length * side, tip[1] + dx / length * side))
    return list(reversed(points)) if at_start else points


def augment(strokes: list[Stroke], label: str, kind: str, rng: random.Random) -> tuple[list[Stroke], dict[str, Any]]:
    if not strokes:
        return [], {}
    extent = _extent(strokes)
    center = _center(strokes)
    metadata: dict[str, Any] = {}

    shear = rng.uniform(-0.14, 0.14) if rng.random() < 0.72 else 0.0
    warp = rng.uniform(0.006, 0.032) * extent if rng.random() < 0.55 else 0.0
    phase_x, phase_y = rng.uniform(-math.pi, math.pi), rng.uniform(-math.pi, math.pi)
    min_x = min(point[0] for stroke in strokes for point in stroke)
    min_y = min(point[1] for stroke in strokes for point in stroke)
    original: list[Stroke] = []
    for stroke in strokes:
        transformed: Stroke = []
        for x, y in stroke:
            sx, sy = x - center[0], y - center[1]
            wx = warp * math.sin(2 * math.pi * (y - min_y) / extent + phase_x)
            wy = warp * math.sin(2 * math.pi * (x - min_x) / extent + phase_y)
            transformed.append((x + shear * sy + wx, y + wy))
        original.append(transformed)
    if shear:
        metadata["shear"] = round(shear, 4)
    if warp:
        metadata["smooth_warp"] = round(warp / extent, 4)

    result: list[Stroke] = []
    protect_short_shape = label in DOT_LABELS or kind in {"punct", "raised", "low"}
    for stroke in original:
        angle = math.radians(rng.uniform(-3.5, 3.5)) if rng.random() < 0.7 else 0.0
        shift_limit = extent * (0.012 if len(original) > 1 else 0.0)
        dx = rng.uniform(-shift_limit, shift_limit) if shift_limit else 0.0
        dy = rng.uniform(-shift_limit, shift_limit) if shift_limit else 0.0
        transformed = _rotate_and_shift(stroke, _center([stroke]), angle, dx, dy)
        if angle or dx or dy:
            metadata["stroke_shift_rotation"] = True
        if not protect_short_shape and len(transformed) >= 2 and rng.random() < 0.45:
            transformed = _wobble(transformed, extent, rng)
            metadata["wobble"] = True
        if not protect_short_shape and rng.random() < 0.08:
            transformed = _endpoint_variant(transformed, extent, rng, hook=False)
            metadata["overshoot"] = True
        if not protect_short_shape and rng.random() < 0.045:
            transformed = _endpoint_variant(transformed, extent, rng, hook=True)
            metadata["hook"] = True
        if rng.random() < 0.5:
            transformed.reverse()
        result.append(transformed)
    if len(result) > 1:
        rng.shuffle(result)
        metadata["stroke_order"] = "shuffled"
    metadata["stroke_direction"] = "randomized"
    return result, metadata


def _round_strokes(strokes: list[Stroke]) -> list[list[list[float]]]:
    return [[[round(x, 3), round(y, 3)] for x, y in stroke] for stroke in strokes]


def _default_hershey_path() -> Path:
    return ROOT / "build/hershey/official.json"


def _select_contact_labels(classes: list[dict[str, Any]]) -> set[str]:
    labels = {item["label"] for item in classes}
    preferred = set("0123Aaagxy+-=×÷()[]/<>.,:;!?απΣ√∫∘—·")
    chosen = labels & preferred
    for item in classes:
        if not item.get("hwrt_ids") and item.get("kind") in {"punct", "raised", "low"}:
            chosen.add(item["label"])
    return chosen


def _contact_sheet(samples: list[dict[str, Any]], classes: list[dict[str, Any]], raster_path: Path, destination: Path) -> None:
    spec = importlib.util.spec_from_file_location("glyph_raster", raster_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load rasterizer: {raster_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    rasterize = module.rasterize
    from PIL import Image, ImageDraw, ImageFont

    chosen = _select_contact_labels(classes)
    by_family: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for sample in samples:
        if sample["label"] in chosen:
            by_family[sample["source_family"]].setdefault(sample["label"], sample)
    missing_punctuation = {
        item["label"] for item in classes
        if not item.get("hwrt_ids") and item.get("kind") in {"punct", "raised", "low"}
    }
    preferred = ("0", "A", "a", "x", "α", "π", "Σ", "+", "−", "×", "÷", "=", "∫", "<", ">", "(", ")", ".", "·", ",", ":", ";", "!", "?")
    selected: list[dict[str, Any]] = []
    for family, labels in sorted(by_family.items()):
        protected = family in {"Hershey canonical", "Relief SingleLine"}
        used = missing_punctuation & labels.keys() if protected else set()
        selected.extend(labels[label] for label in sorted(used))
        quota = 28 if protected else 7
        for label in preferred:
            if label in labels and label not in used and len(used) < quota:
                selected.append(labels[label])
                used.add(label)
        for label in sorted(labels):
            if len(used) >= quota or label in used:
                continue
            selected.append(labels[label])
            used.add(label)
    selected = selected[:112]
    selected.sort(key=lambda row: (row["source_family"].casefold(), row["label"], str(row["source_id"])))

    tile_w, tile_h, scale = 148, 128, 3
    columns = 8
    rows_count = max(1, math.ceil(len(selected) / columns))
    image = Image.new("RGB", (columns * tile_w, rows_count * tile_h), "white")
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 14)
    except OSError:
        font = ImageFont.load_default()
    for index, sample in enumerate(selected):
        x, y = (index % columns) * tile_w, (index // columns) * tile_h
        glyph = rasterize(sample["strokes"])
        if glyph.mode != "L" or glyph.size != (32, 32):
            raise ValueError("contact sheet requires R1's 32×32 grayscale rasterizer")
        glyph = glyph.resize((32 * scale, 32 * scale), Image.Resampling.NEAREST)
        image.paste(glyph.convert("RGB"), (x + 4, y + 2))
        family = sample["source_family"].replace("Hershey ", "H-")
        draw.text((x + 104, y + 4), sample["label"], fill="black", font=font)
        draw.text((x + 4, y + 104), family[:22], fill="#333333", font=font)
        draw.text((x + 4, y + 116), str(sample["source_id"])[:22], fill="#666666", font=font)
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination)


def generate(args: argparse.Namespace) -> dict[str, Any]:
    vocab_path = Path(args.vocab)
    glyphs_path = Path(args.glyphs)
    raw_path = Path(args.hershey_source)
    relief_path = Path(args.relief_svg)
    classes, source_info = _load_sources(vocab_path, glyphs_path, raw_path, relief_path)
    if args.expected_classes and len(classes) != args.expected_classes:
        raise ValueError(f"expected {args.expected_classes} vocab labels, got {len(classes)}")
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = output_dir / "synthetic.jsonl"
    preview_samples: list[dict[str, Any]] = []
    source_counts: Counter[str] = Counter()
    family_labels: dict[str, set[str]] = defaultdict(set)
    augmentation_counts: Counter[str] = Counter()
    class_counts: Counter[str] = Counter()
    record_count = 0

    with jsonl_path.open("w", encoding="utf-8", newline="\n") as output:
        for item in classes:
            variants = item["variants"]
            for sample_index in range(args.samples_per_class):
                dot_variant = None
                if item["label"] in DOT_LABELS and sample_index % 4:
                    dot_variant = DOT_VARIANTS[sample_index % 4 - 1]
                    source = {
                        **item["dot_template"],
                        "family": f"Hershey canonical dot {dot_variant}",
                    }
                    variant_index = -1
                else:
                    variant_index = (
                        (sample_index // 4) % len(variants)
                        if item["label"] in DOT_LABELS else sample_index % len(variants)
                    )
                    source = variants[variant_index]
                seed = _stable_seed(args.seed, item["label"], sample_index, source)
                rng = random.Random(seed)
                if dot_variant is None:
                    strokes, augmentation = augment(source["strokes"], item["label"], item["kind"], rng)
                else:
                    strokes = _dot_variant(source["strokes"], dot_variant, rng)
                    strokes, augmentation = augment(strokes, item["label"], item["kind"], rng)
                    augmentation["dot_variant"] = dot_variant
                record = {
                    "label": item["label"],
                    "group": item["group"],
                    "kind": item["kind"],
                    "source_family": source["family"],
                    "source_id": source["source_id"],
                    "source_label": source.get("source_label", item["label"]),
                    "source_ids": source.get("source_ids", []),
                    "source_license": source["license"],
                    "source_notice": source["notice"],
                    "source_url": source["url"],
                    "source_map_url": source.get("map_url"),
                    "sample_index": sample_index,
                    "seed": seed,
                    "augmentations": augmentation,
                    "strokes": _round_strokes(strokes),
                }
                output.write(json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n")
                record_count += 1
                class_counts[item["label"]] += 1
                source_counts[source["family"]] += 1
                family_labels[source["family"]].add(item["label"])
                augmentation_counts.update(augmentation.keys())
                if sample_index == variant_index or dot_variant is not None and sample_index in (1, 2, 3):
                    preview_samples.append(record)

    by_category: dict[str, set[str]] = {family: set() for family in FAMILIES}
    for family, labels in family_labels.items():
        for category in _family_categories(family):
            by_category[category].update(labels)
    all_labels = {item["label"] for item in classes}
    manifest = {
        "version": 1,
        "seed": args.seed,
        "seed_policy": "SHA-256(global seed, label, sample index, source family, source ID), first 64 bits",
        "samples_per_class": args.samples_per_class,
        "class_count": len(classes),
        "group_count": len({item["group"] for item in classes}),
        "record_count": record_count,
        "records_per_class": dict(sorted(class_counts.items())),
        "source_counts": dict(sorted(source_counts.items())),
        "augmentation_counts": dict(sorted(augmentation_counts.items())),
        "source_info": source_info,
        "input_sha256": {
            "vocab": source_info["vocab_sha256"],
            "glyphs": source_info["glyphs_sha256"],
            "raw_hershey_records": source_info["raw_hershey_sha256"],
            "relief_svg": source_info["relief_svg_sha256"],
        },
        "hershey_family_match_policy": "For valid-ID JHF files, both candidate charcode and exact decoded bearings/strokes must match. For placeholder-ID Times files, the candidate's exact decoded bearings/strokes must match a family record.",
        "source_families": {
            family: {
                "available_labels": sorted(by_category[family]),
                "unsupported_labels": sorted(all_labels - by_category[family]),
            }
            for family in FAMILIES
        },
        "exact_source_family_labels": {family: sorted(labels) for family, labels in sorted(family_labels.items())},
        "sources": {
            "hershey": {
                "license": HERSHEY_LICENSE,
                "notice": HERSHEY_NOTICE,
                "url": HERSHEY_RAW_URL,
                "decoded_coordinates_url": HERSHEY_RAW_URL,
                "raw_coordinates_notice": HERSHEY_NOTICE,
                "font_map_url": HERSHEY_FONTS_URL,
                "font_map_commit": "1356bf2f83d380fcef68c887e88675eb9d445d86",
                "font_map_notice": "scripts/glyphs/sources/hershey/hershey.txt",
            },
            "relief_singleline": {
                "license": RELIEF_LICENSE,
                "notice": RELIEF_NOTICE,
                "url": RELIEF_URL,
                "commit": RELIEF_COMMIT,
                "source_sha256": "75f05a5b64ed6039c9816628ee051d98e16c19148a8268c63f5eccf8382479e2",
            },
        },
        "records_file": jsonl_path.name,
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.contact_sheet:
        raster_path = Path(args.raster)
        _contact_sheet(preview_samples, classes, raster_path, output_dir / "contact-sheet.png")
    return manifest


def _self_check() -> None:
    sample = [[(0.0, 0.0), (20.0, 8.0)], [(3.0, 8.0), (3.0, 0.0)]]
    first, first_meta = augment(sample, "A", "upper", random.Random(813))
    second, second_meta = augment(sample, "A", "upper", random.Random(813))
    assert first == second and first_meta == second_meta
    assert _round_strokes(first) == [
        [[3.18, -0.008], [2.892, 7.992]],
        [[0.066, 0.485], [20.215, 7.309]],
    ]
    assert len(first) == 2 and sum(map(len, first)) == 4
    assert first_meta == {
        "smooth_warp": 0.0215,
        "stroke_shift_rotation": True,
        "stroke_order": "shuffled",
        "stroke_direction": "randomized",
    }
    assert _relief_path_strokes("M0 0 L3 4") == [([(0.0, -0.0), (3.0, -4.0)], False)]
    dot, dot_meta = augment([[(0.0, 0.0)]], ".", "punct", random.Random(2))
    assert dot == [[(0.0, 0.0)]] and "hook" not in dot_meta and "overshoot" not in dot_meta
    variants = [augment(sample, "A", "upper", random.Random(seed))[1] for seed in range(128)]
    for name in ("shear", "smooth_warp", "stroke_shift_rotation", "wobble", "overshoot", "hook", "stroke_order", "stroke_direction"):
        assert any(name in metadata for metadata in variants), name
    assert _family_categories("Complex Italic") == {"Complex", "Italic"}
    _, simplex = _font_index(SOURCES / "hershey" / "rowmans.jhf")
    assert _stroke_key(-9, 9, [[[0, -12], [-8, 9]], [[0, -12], [8, 9]], [[-5, 2], [5, 2]]]) in simplex
    relief = _load_relief(RELIEF_SVG)
    assert len(relief[":"]["strokes"]) == 2
    assert len(relief["!"]["strokes"]) == 2
    assert len(relief["i"]["strokes"]) == 4

    glyphs = json.loads((ROOT / "Sources/CanvasKit/Resources/HersheyGlyphs.json").read_text(encoding="utf-8"))
    degree = glyphs["°"]
    assert degree["sourceID"] == 718
    assert degree["sourceIDs"] == [218, 718, 1218, 2218, 2729, 2779, 3229, 3279, 3729]
    template = [[(float(x), float(y)) for x, y in line] for line in degree["strokes"]]
    dots = {
        name: _dot_variant(template, name, random.Random(813))
        for name in DOT_VARIANTS
    }
    assert dots["point"] == [[(0.0, -8.0)]]
    loop = dots["loop"][0]
    assert len(loop) == 13 and loop[0] == loop[-1]
    assert _round_strokes([loop[:3]]) == [[[-1.725, -12.101], [-3.693, -10.705], [-4.43, -8.408]]]
    scribble = dots["scribble"]
    assert len(scribble) == 11 and [len(stroke) for stroke in scribble] == [13] * 11
    assert _round_strokes([scribble[0][:3]]) == [[[-0.809, -12.039], [-2.894, -11.232], [-4.079, -9.336]]]
    assert _round_strokes([[scribble[-1][0]]]) == [[[-0.031, -8.212]]]

    raster_spec = importlib.util.spec_from_file_location("glyph_raster", ROOT / "scripts/glyphs/raster.py")
    if raster_spec is None or raster_spec.loader is None:
        raise RuntimeError("cannot load raster.py for dot checks")
    raster_module = importlib.util.module_from_spec(raster_spec)
    raster_spec.loader.exec_module(raster_module)
    images = {name: raster_module.rasterize(strokes) for name, strokes in dots.items()}
    coverage = {name: sum(value == 0 for value in image.getdata()) for name, image in images.items()}
    assert coverage == {"point": 4, "loop": 164, "scribble": 616}
    assert images["loop"].getpixel((16, 16)) == 255
    assert images["scribble"].getpixel((16, 16)) == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vocab", default=str(ROOT / "Sources/CanvasKit/Resources/vocab.json"))
    parser.add_argument("--glyphs", default=str(ROOT / "Sources/CanvasKit/Resources/HersheyGlyphs.json"))
    parser.add_argument("--hershey-source", default=str(_default_hershey_path()))
    parser.add_argument("--relief-svg", default=str(RELIEF_SVG))
    parser.add_argument("--output-dir", default=str(ROOT / "build/glyph-synth"))
    parser.add_argument("--samples-per-class", type=int, default=300)
    parser.add_argument("--expected-classes", type=int, default=158)
    parser.add_argument("--seed", type=int, default=20261003)
    parser.add_argument("--contact-sheet", action="store_true")
    parser.add_argument("--raster", default=str(ROOT / "scripts/glyphs/raster.py"))
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    if args.self_check:
        _self_check()
        print("synthetic augmentation self-check passed")
        return
    if args.samples_per_class < 1:
        parser.error("--samples-per-class must be positive")
    manifest = generate(args)
    print(f"wrote {manifest['record_count']} stroke records across {manifest['class_count']} labels")
    print(f"manifest: {Path(args.output_dir) / 'manifest.json'}")
    if args.contact_sheet:
        print(f"contact sheet: {Path(args.output_dir) / 'contact-sheet.png'}")


if __name__ == "__main__":
    main()
