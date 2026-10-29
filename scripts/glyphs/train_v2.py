#!/usr/bin/env python3
"""Train and export the raster + pen-path math glyph model."""
from __future__ import annotations

import argparse
from collections import Counter
import gzip
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import subprocess
import time

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset

from raster import rasterize as canonical_rasterize
from sequence import encode as encode_sequence

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build'
VOCAB = ROOT / 'Sources/CanvasKit/Resources/math-vocab.json'
LANGUAGE_MODEL = ROOT / 'Sources/CanvasKit/Resources/MathLM.json'
DEFAULT_OUTPUT = BUILD / 'glyph-training-v2'
DUMMY_OUTPUT = BUILD / 'orchestration-v2-wave2/dummy'
SEED = 20261003
RASTER_SIZE = 32
MAX_EPOCH_CLASS = 20_000
SYNTHETIC_FLOOR = 2_000
PATH_SHAPE = (128, 4)


def label_maps(vocab_path: Path = VOCAB) -> tuple[list[str], dict[str, int], dict[str, str]]:
    ids = class_ids(vocab_path)
    vocab = json.loads(vocab_path.read_text())
    label_to_class = {label: entry['id'] for entry in vocab['classes'] for label in entry['labels']}
    return ids, {value: index for index, value in enumerate(ids)}, label_to_class


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def bundle_digest(directory: Path) -> str:
    h = hashlib.sha256()
    files = sorted(path for path in directory.rglob('*') if path.is_file())
    if not files:
        raise ValueError(f'compiled bundle is empty: {directory}')
    for path in files:
        h.update(str(path.relative_to(directory)).encode())
        h.update(bytes.fromhex(digest(path)))
    return h.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def stroke_points(strokes: list) -> list[np.ndarray]:
    paths = []
    for stroke in strokes:
        if isinstance(stroke, dict):
            stroke = stroke.get('points', [])
        path = []
        for point in stroke:
            if isinstance(point, dict):
                x, y = point['x'], point['y']
            else:
                x, y = point[0], point[1]
            x, y = float(x), float(y)
            if not (math.isfinite(x) and math.isfinite(y) and abs(x) <= 200_000 and abs(y) <= 200_000):
                raise ValueError('invalid stroke coordinate')
            path.append((x, y))
        if path:
            paths.append(np.asarray(path, dtype=np.float64))
    return paths


def stroke_globals(strokes: list[np.ndarray]) -> np.ndarray:
    """Count and aspect use the first 64 nonempty raw point strokes, without stroke width."""
    kept = strokes[:64]
    if not kept:
        raise ValueError('globals require at least one nonempty stroke')
    points = np.concatenate(kept, axis=0)
    width = float(points[:, 0].max() - points[:, 0].min())
    height = float(points[:, 1].max() - points[:, 1].min())
    ratio = max(-3.0, min(3.0, math.log(max(width, 1e-6) / max(height, 1e-6)))) / 3.0
    return np.asarray([min(len(kept), 6) / 6.0, ratio], dtype=np.float32)


def _round_away_array(values: np.ndarray) -> np.ndarray:
    return (np.sign(values) * np.floor(np.abs(values) + 0.5)).astype(np.int64)


def _round_ratio_array(numerators: np.ndarray, denominator: int) -> np.ndarray:
    magnitudes = (np.abs(numerators) + denominator // 2) // denominator
    return np.sign(numerators) * magnitudes


def vectorized_raster(strokes: list[np.ndarray]) -> np.ndarray:
    """NumPy equivalent of raster.py; returned bytes are OneComponent8 gray pixels."""
    pixels = np.full((32, 32), 255, dtype=np.uint8)
    if not strokes:
        return pixels
    flat = np.concatenate(strokes, axis=0)
    min_x, min_y = flat.min(axis=0)
    source = [_round_away_array((path - (min_x, min_y)) * 65536) for path in strokes]
    span_x = max(int(path[:, 0].max()) for path in source)
    span_y = max(int(path[:, 1].max()) for path in source)
    span = max(span_x, span_y)
    if span == 0:
        fixed = [[(4096, 4096)] * len(path) for path in source]
    else:
        fixed = []
        for path in source:
            x = 4096 + _round_ratio_array((2 * path[:, 0] - span_x) * 3328, span)
            y = 4096 + _round_ratio_array((2 * path[:, 1] - span_y) * 3328, span)
            fixed.append(list(zip(x.astype(int).tolist(), y.astype(int).tolist())))
    starts, ends = [], []
    for path in fixed:
        if len(path) == 1:
            starts.append(path[0])
            ends.append(path[0])
        else:
            starts.extend(path[:-1])
            ends.extend(path[1:])
    start, end = np.asarray(starts, dtype=np.int64), np.asarray(ends, dtype=np.int64)
    x_min = np.maximum(0, np.minimum(start[:, 0], end[:, 0]) // 256 - 1)
    x_max = np.minimum(31, np.maximum(start[:, 0], end[:, 0]) // 256 + 1)
    y_min = np.maximum(0, np.minimum(start[:, 1], end[:, 1]) // 256 - 1)
    y_max = np.minimum(31, np.maximum(start[:, 1], end[:, 1]) // 256 + 1)
    widths, heights = x_max - x_min + 1, y_max - y_min + 1
    candidate_count = widths * heights
    offsets = np.arange(int(candidate_count.max()), dtype=np.int64)[None, :]
    candidate = offsets < candidate_count[:, None]
    xx = x_min[:, None] + offsets % widths[:, None]
    yy = y_min[:, None] + offsets // widths[:, None]
    px, py = xx * 256 + 128, yy * 256 + 128
    vx, vy = px - start[:, 0, None], py - start[:, 1, None]
    dx, dy = end[:, 0] - start[:, 0], end[:, 1] - start[:, 1]
    length_squared = dx * dx + dy * dy
    projection = vx * dx[:, None] + vy * dy[:, None]
    first = vx * vx + vy * vy <= 256 * 256
    ex, ey = px - end[:, 0, None], py - end[:, 1, None]
    last = ex * ex + ey * ey <= 256 * 256
    cross = vx * dy[:, None] - vy * dx[:, None]
    middle = cross * cross <= (256 * 256) * length_squared[:, None]
    inside = candidate & np.where(projection <= 0, first,
                                  np.where(projection >= length_squared[:, None], last, middle))
    pixels.reshape(-1)[(yy * 32 + xx)[inside]] = 0
    return pixels


def record_class(row: dict, label_to_class: dict[str, str]) -> str | None:
    label = row.get('label')
    class_id = row.get('class') or label_to_class.get(label)
    if class_id is None:
        return None
    # Immutable F4/base/harvest records put l in bar; F5 splits it by label.
    if label == 'l' and class_id == 'bar' and label_to_class.get(label) == 'glyph_u006C':
        return 'glyph_u006C'
    if class_id != label_to_class.get(label):
        raise ValueError(f'label/class mismatch for {label!r}: {class_id!r}')
    return class_id


def source_groups(build_dir: Path, include_harvest: bool = False, include_extras: bool = False,
                  include_harvest_ql: bool = False,
                  include_harvest_brace: bool = False) -> dict[str, list[Path]]:
    datasets = build_dir / 'datasets'
    groups = {
        'train': [datasets / 'mw-symbols-train.jsonl.gz', datasets / 'crohme-train.jsonl.gz',
                  datasets / 'hwrt-train.jsonl.gz'],
        'valid': [datasets / 'crohme-valid.jsonl.gz', datasets / 'hwrt-valid.jsonl.gz'],
    }
    if include_harvest:
        for split in groups:
            groups[split].append(datasets / f'mw-harvest-{split}.jsonl.gz')
    if include_extras:
        groups['train'].extend(datasets / name for name in (
            'mw-symbols-extra-train.jsonl.gz', 'crohme-extra-train.jsonl.gz',
            'hwrt-extra-train.jsonl.gz'))
        groups['valid'].extend(datasets / name for name in (
            'crohme-extra-valid.jsonl.gz', 'hwrt-extra-valid.jsonl.gz'))
    if include_harvest_ql:
        for split in groups:
            groups[split].append(datasets / f'mw-harvest-ql-{split}.jsonl.gz')
    if include_harvest_brace:
        for split in groups:
            groups[split].append(datasets / f'mw-harvest-brace-{split}.jsonl.gz')
    return groups


def jsonl_rows(path: Path):
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'rt', encoding='utf-8') as stream:
        for line in stream:
            if line.strip():
                yield json.loads(line)


def _record_count(path: Path, split: str, label_to_class: dict[str, str]) -> tuple[Counter, int, int]:
    counts, point_count, stroke_count = Counter(), 0, 0
    for row in jsonl_rows(path):
        if path.name.startswith('crohme') and row.get('split') != split:
            continue
        if row.get('split') not in (None, split):
            continue
        class_id = record_class(row, label_to_class)
        if class_id is not None:
            paths = stroke_points(row.get('strokes', []))
            if not paths:
                continue
            counts[class_id] += 1
            point_count += sum(len(points) for points in paths)
            stroke_count += len(paths)
    return counts, point_count, stroke_count


def _cache_paths(output: Path, split: str) -> dict[str, Path]:
    base = output / 'cache'
    return {key: base / f'{split}-{key}.npy' for key in (
        'images', 'paths', 'globals', 'targets', 'raw-points', 'raw-stroke-offsets', 'raw-record-offsets')}


def _open_cache(paths: dict[str, Path], count: int, point_count: int,
                stroke_count: int, mode: str) -> dict[str, np.ndarray]:
    paths['images'].parent.mkdir(parents=True, exist_ok=True)
    return {
        'images': np.lib.format.open_memmap(paths['images'], mode=mode, dtype=np.uint8,
                                            shape=(count, 1024)),
        'paths': np.lib.format.open_memmap(paths['paths'], mode=mode, dtype=np.float32,
                                           shape=(count, *PATH_SHAPE)),
        'globals': np.lib.format.open_memmap(paths['globals'], mode=mode, dtype=np.float32,
                                             shape=(count, 2)),
        'targets': np.lib.format.open_memmap(paths['targets'], mode=mode, dtype=np.uint8,
                                             shape=(count,)),
        'raw-points': np.lib.format.open_memmap(paths['raw-points'], mode=mode, dtype=np.float64,
                                                shape=(point_count, 2)),
        'raw-stroke-offsets': np.lib.format.open_memmap(paths['raw-stroke-offsets'], mode=mode,
                                                        dtype=np.int64, shape=(stroke_count + 1,)),
        'raw-record-offsets': np.lib.format.open_memmap(paths['raw-record-offsets'], mode=mode,
                                                        dtype=np.int64, shape=(count + 1,)),
    }


def prepare(args: argparse.Namespace) -> None:
    build_dir, out = Path(args.build_dir), Path(args.output)
    ids, class_index, label_to_class = label_maps(args.vocab)
    groups = source_groups(build_dir, args.include_harvest, args.include_extras,
                           args.include_harvest_ql, args.include_harvest_brace)
    missing = [str(path) for paths in groups.values() for path in paths if not path.is_file()]
    synthetic_path = build_dir / 'glyph-synth/synthetic.jsonl'
    if missing or not synthetic_path.is_file():
        raise FileNotFoundError(f'missing training sources: {missing or [str(synthetic_path)]}')

    source_counts = {split: Counter() for split in groups}
    point_counts, stroke_counts = Counter(), Counter()
    for split, files in groups.items():
        for path in files:
            counts, points, strokes = _record_count(path, split, label_to_class)
            source_counts[split].update(counts)
            point_counts[split] += points
            stroke_counts[split] += strokes
    real_train = source_counts['train']
    shortage = {class_id: (0 if class_id == 'junk' else max(0, SYNTHETIC_FLOOR - real_train[class_id]))
                for class_id in ids}

    # Sample the existing synthetic pool with replacement to reach each 2000-record floor.
    reservoirs: dict[str, list[str]] = {class_id: [] for class_id in ids if shortage[class_id]}
    rng = np.random.default_rng(SEED)
    with synthetic_path.open(encoding='utf-8') as stream:
        for line in stream:
            row = json.loads(line)
            label = {'-': '−', "'": '′', '×': 'x'}.get(row.get('label'), row.get('label'))
            class_id = label_to_class.get(label)
            if class_id not in reservoirs:
                continue
            if row.get('source_license') not in ('Hershey permitted-use notice', 'SIL Open Font License 1.1'):
                raise ValueError(f'unapproved synthetic license: {row.get("source_license")}')
            if str(row.get('writer', '')).casefold() == 'ayush' or row.get('split') == 'test':
                raise ValueError('held-out capture cannot enter training')
            reservoirs[class_id].append(line)
    for class_id, pool in reservoirs.items():
        if shortage[class_id] and not pool:
            raise ValueError(f'no synthetic samples available for class {class_id}')
        pool[:] = [pool[int(index)] for index in rng.integers(len(pool), size=shortage[class_id])]
    for rows in reservoirs.values():
        for line in rows:
            row = json.loads(line)
            row['label'] = {'-': '−', "'": '′', '×': 'x'}.get(row.get('label'), row.get('label'))
            paths = stroke_points(row.get('strokes', []))
            point_counts['train'] += sum(len(points) for points in paths)
            stroke_counts['train'] += len(paths)

    train_count = sum(real_train.values()) + sum(shortage.values())
    valid_count = sum(source_counts['valid'].values())
    if min(train_count, valid_count) <= 0:
        raise ValueError('empty training or validation split')
    caches = {split: _open_cache(_cache_paths(out, split), count, point_counts[split],
                                 stroke_counts[split], 'w+')
              for split, count in (('train', train_count), ('valid', valid_count))}
    offsets = {'train': 0, 'valid': 0}
    point_offsets, stroke_offsets = {'train': 0, 'valid': 0}, {'train': 0, 'valid': 0}
    actual_counts = {split: Counter() for split in groups}

    def add(split: str, row: dict) -> None:
        class_id = record_class(row, label_to_class)
        if class_id is None:
            return
        strokes = stroke_points(row.get('strokes', []))
        if not strokes:
            return
        index = offsets[split]
        encoded = encode_sequence(strokes)
        if encoded is None:
            raise ValueError(f'empty or invalid pen path in {row.get("ink_id", "record")}')
        cache = caches[split]
        cache['images'][index] = vectorized_raster(strokes).reshape(-1)
        cache['paths'][index] = np.asarray(encoded['strokePoints'], dtype=np.float32)
        cache['globals'][index] = stroke_globals(strokes)
        cache['targets'][index] = class_index[class_id]
        point_cursor, stroke_cursor = point_offsets[split], stroke_offsets[split]
        for stroke in strokes:
            next_point = point_cursor + len(stroke)
            cache['raw-points'][point_cursor:next_point] = stroke
            cache['raw-stroke-offsets'][stroke_cursor + 1] = next_point
            point_cursor, stroke_cursor = next_point, stroke_cursor + 1
        cache['raw-record-offsets'][index + 1] = stroke_cursor
        point_offsets[split], stroke_offsets[split] = point_cursor, stroke_cursor
        offsets[split] += 1
        actual_counts[split][class_id] += 1

    for split, files in groups.items():
        for path in files:
            for row in jsonl_rows(path):
                if path.name.startswith('crohme') and row.get('split') != split:
                    continue
                if row.get('split') not in (None, split):
                    continue
                if record_class(row, label_to_class) is not None:
                    add(split, row)
    for class_id in ids:
        for line in reservoirs.get(class_id, ()):
            row = json.loads(line)
            row['label'] = {'-': '−', "'": '′', '×': 'x'}.get(row.get('label'), row.get('label'))
            row['class'] = label_to_class[row['label']]
            add('train', row)
    for split in caches:
        caches[split]['raw-stroke-offsets'][0] = 0
        caches[split]['raw-record-offsets'][0] = 0
        if point_offsets[split] != len(caches[split]['raw-points']) or stroke_offsets[split] != len(caches[split]['raw-stroke-offsets']) - 1:
            raise ValueError(f'{split} raw stroke cache size mismatch')
        for array in caches[split].values():
            array.flush()
        if offsets[split] != len(caches[split]['targets']):
            raise ValueError(f'{split} cache size mismatch: {offsets[split]}')

    cache_meta = {
        'seed': SEED, 'classes': ids, 'includeHarvest': args.include_harvest,
        'includeExtras': args.include_extras,
        'includeHarvestQL': args.include_harvest_ql,
        'includeHarvestBrace': args.include_harvest_brace,
        'cache_shapes': {split: offsets[split] for split in offsets},
        'counts': {split: dict(counts) for split, counts in actual_counts.items()},
        'sources': {str(path): digest(path) for paths in groups.values() for path in paths},
        'synthetic': digest(synthetic_path), 'mathVocabSHA256': digest(args.vocab),
        'raster_sha256': digest(Path(__file__).with_name('raster.py')),
        'sequence_sha256': digest(Path(__file__).with_name('sequence.py')),
        'train_script_sha256': digest(Path(__file__)),
        'top_up': {class_id: shortage[class_id] for class_id in ids if shortage[class_id]},
        'pool_policy': 'MW symbols train; CROHME Train.zip formulas split by writer plus isolated train symbols; HWRT legacy writer split; optional MW harvest and extras train/valid; synthetic top-up (except junk) only to 2000 real+SY per class',
    }
    write_json(out / 'prepare.json', cache_meta)
    print(json.dumps({'train_records': offsets['train'], 'valid_records': offsets['valid'],
                      'synthetic_top_up': sum(shortage.values()), 'cache': str(out / 'cache')},
                     sort_keys=True), flush=True)


def _raw_strokes_from_cache(arrays: dict[str, np.ndarray], index: int) -> list[np.ndarray]:
    first = int(arrays['raw-record-offsets'][index])
    end = int(arrays['raw-record-offsets'][index + 1])
    return [np.asarray(arrays['raw-points'][arrays['raw-stroke-offsets'][stroke]:
                            arrays['raw-stroke-offsets'][stroke + 1]], dtype=np.float64)
            for stroke in range(first, end)]


def _elastic(strokes: list[np.ndarray], rng: np.random.Generator) -> list[np.ndarray]:
    field = rng.normal(0, .08, size=(3, 3, 2))
    result = []
    for stroke in strokes:
        points = stroke.copy()
        grid = np.clip((points + .5) * 2, 0, 2 - 1e-7)
        base = np.floor(grid).astype(int)
        frac = grid - base
        dx, dy = base[:, 0], base[:, 1]
        fx, fy = frac[:, 0:1], frac[:, 1:2]
        top = field[dy, dx] * (1 - fx) + field[dy, dx + 1] * fx
        bottom = field[dy + 1, dx] * (1 - fx) + field[dy + 1, dx + 1] * fx
        points += top * (1 - fy) + bottom * fy
        result.append(points)
    return result


def _trackpad(stroke: np.ndarray, rng: np.random.Generator,
              tremor: tuple[float, float] = (.01, .03)) -> np.ndarray:
    if len(stroke) < 2:
        return stroke.copy()
    # Source timestamps mix milliseconds and ordinal fallbacks; use a fresh ms clock.
    clock = np.concatenate(([0.0], np.cumsum(rng.uniform(8.0, 16.0, len(stroke) - 1))))
    targets = [0.0]
    while targets[-1] < clock[-1]:
        next_target = targets[-1] + float(rng.uniform(8.0, 16.0))
        if next_target >= clock[-1]:
            targets.append(float(clock[-1]))
            break
        targets.append(next_target)
    targets = np.asarray(targets, dtype=np.float64)
    resampled = np.column_stack((np.interp(targets, clock, stroke[:, 0]),
                                 np.interp(targets, clock, stroke[:, 1])))
    padded = np.pad(resampled, ((1, 1), (0, 0)), mode='edge')
    smoothed = (padded[:-2] + padded[1:-1] + padded[2:]) / 3.0
    smoothed[0], smoothed[-1] = resampled[0], resampled[-1]
    amplitude = float(rng.uniform(*tremor))
    frequency = float(rng.uniform(2.0, 8.0))
    phase = float(rng.uniform(0, 2 * math.pi))
    angle = 2 * math.pi * frequency * targets / 1000.0 + phase
    smoothed[1:-1, 0] += amplitude * np.sin(angle[1:-1])
    smoothed[1:-1, 1] += amplitude * np.cos(angle[1:-1])
    smoothed[0], smoothed[-1] = stroke[0], stroke[-1]
    return smoothed


def augment_strokes(strokes: list[np.ndarray], rng: np.random.Generator,
                    trackpad_p: float = .5,
                    tremor: tuple[float, float] = (.01, .03)) -> list[np.ndarray]:
    points = np.concatenate(strokes, axis=0)
    center = (points.min(axis=0) + points.max(axis=0)) / 2
    scale = max(float((points.max(axis=0) - points.min(axis=0)).max()), 1e-6)
    angle = math.radians(float(rng.uniform(-10.0, 10.0)))
    shear = float(rng.uniform(-.3, .3))
    x_scale = float(rng.uniform(.8, 1.25))
    rotation = np.asarray([[math.cos(angle), -math.sin(angle)],
                           [math.sin(angle), math.cos(angle)]])
    affine = rotation @ np.asarray([[1.0, shear], [0.0, 1.0]]) @ np.diag([x_scale, 1.0])
    result = [((stroke - center) / scale) @ affine.T for stroke in strokes]
    result = _elastic(result, rng)
    result = [stroke + rng.normal(0, .01, stroke.shape) for stroke in result]
    if rng.random() < trackpad_p:
        result = [_trackpad(stroke, rng, tremor) for stroke in result]
    if rng.random() < .2:
        index = int(rng.integers(len(result)))
        result[index] = result[index][::-1].copy()
    if len(result) > 1 and rng.random() < .1:
        result = [result[i] for i in rng.permutation(len(result))]
    return result


class GlyphDataset(Dataset):
    """Mmap-backed dataset; workers reopen cache files instead of copying them."""

    def __init__(self, output: Path, split: str, indices: np.ndarray | None = None,
                 epoch: int = 0, augment: bool = False, trackpad_p: float = .5,
                 tremor: tuple[float, float] = (.01, .03)):
        self.files = {key: str(value) for key, value in _cache_paths(output, split).items()}
        self.indices = indices
        self.epoch = epoch
        self.augment = augment
        self.trackpad_p = trackpad_p
        self.tremor = tremor
        self._arrays = None

    def __getstate__(self):
        state = self.__dict__.copy()
        state['_arrays'] = None
        return state

    def _open(self):
        if self._arrays is None:
            self._arrays = {key: np.load(path, mmap_mode='r') for key, path in self.files.items()}
        return self._arrays

    def __len__(self) -> int:
        return len(self.indices) if self.indices is not None else len(np.load(self.files['targets'], mmap_mode='r'))

    def __getitem__(self, item: int):
        arrays = self._open()
        index = int(self.indices[item]) if self.indices is not None else item
        target = int(arrays['targets'][index])
        if not self.augment:
            return (torch.from_numpy(np.array(arrays['images'][index], dtype=np.float32, copy=True).reshape(1, 32, 32)),
                    torch.from_numpy(np.array(arrays['paths'][index], dtype=np.float32, copy=True)),
                    torch.from_numpy(np.array(arrays['globals'][index], dtype=np.float32, copy=True)), target)
        rng = np.random.default_rng(SEED + 1_000_003 * self.epoch + 97_409 * index)
        strokes = augment_strokes(_raw_strokes_from_cache(arrays, index), rng,
                                  self.trackpad_p, self.tremor)
        path = encode_sequence(strokes)
        if path is None:
            raise ValueError(f'augmentation erased training record {index}')
        image = vectorized_raster(strokes).astype(np.float32)[None, :, :]
        return (torch.from_numpy(image),
                torch.from_numpy(np.asarray(path['strokePoints'], dtype=np.float32)),
                torch.from_numpy(stroke_globals(strokes)), target)


def epoch_sample_indices(targets: np.ndarray, class_count: int, epoch: int,
                         max_per_class: int = MAX_EPOCH_CLASS) -> np.ndarray:
    rng = np.random.default_rng(SEED + epoch)
    selected = []
    for class_index in range(class_count):
        members = np.flatnonzero(targets == class_index)
        if not len(members):
            continue
        count = min(len(members), max_per_class)
        selected.append(rng.choice(members, count, replace=False))
    return rng.permutation(np.concatenate(selected))


def _source_hashes(build_dir: Path, vocab: Path, include_harvest: bool = False,
                   include_extras: bool = False, include_harvest_ql: bool = False,
                   include_harvest_brace: bool = False) -> dict[str, str]:
    groups = source_groups(build_dir, include_harvest, include_extras, include_harvest_ql,
                           include_harvest_brace)
    result = {str(path): digest(path) for paths in groups.values() for path in paths}
    synthetic = build_dir / 'glyph-synth/synthetic.jsonl'
    result[str(synthetic)] = digest(synthetic)
    result['mathVocabSHA256'] = digest(vocab)
    result['raster_sha256'] = digest(Path(__file__).with_name('raster.py'))
    result['sequence_sha256'] = digest(Path(__file__).with_name('sequence.py'))
    result['train_script_sha256'] = digest(Path(__file__))
    return result


def _verify_checkpoint_sources(saved: dict, build_dir: Path, vocab: Path) -> None:
    # Reporting/exporting can change independently of the frozen training script.
    # Keep that original hash in the report; still reject any changed model inputs.
    training = saved.get('sourceHashes', {})
    include_harvest = any(Path(key).name == 'mw-harvest-train.jsonl.gz' for key in training)
    include_extras = any(Path(key).name == 'mw-symbols-extra-train.jsonl.gz' for key in training)
    include_harvest_ql = any(Path(key).name == 'mw-harvest-ql-train.jsonl.gz' for key in training)
    include_harvest_brace = any(Path(key).name == 'mw-harvest-brace-train.jsonl.gz' for key in training)
    current = _source_hashes(build_dir, vocab, include_harvest, include_extras, include_harvest_ql,
                             include_harvest_brace)
    if ({key: value for key, value in training.items() if key != 'train_script_sha256'}
            != {key: value for key, value in current.items() if key != 'train_script_sha256'}):
        raise ValueError('checkpoint source lineage no longer matches training inputs')


def _verify_cache(args: argparse.Namespace) -> tuple[dict, list[str]]:
    out = Path(args.output)
    path = out / 'prepare.json'
    if not path.is_file():
        raise FileNotFoundError(f'run prepare first: {path}')
    info = json.loads(path.read_text())
    if info.get('seed') != SEED or info.get('mathVocabSHA256') != digest(args.vocab):
        raise ValueError('prepared cache seed or math vocabulary changed')
    current = _source_hashes(Path(args.build_dir), args.vocab, info.get('includeHarvest', False),
                             info.get('includeExtras', False), info.get('includeHarvestQL', False),
                             info.get('includeHarvestBrace', False))
    expected = {key: value for key, value in current.items()
                if key not in ('mathVocabSHA256', 'raster_sha256', 'sequence_sha256', 'train_script_sha256')}
    saved = {**info.get('sources', {}), str(Path(args.build_dir) / 'glyph-synth/synthetic.jsonl'): info.get('synthetic')}
    if expected != saved:
        raise ValueError('prepared cache source hashes changed; rerun prepare')
    if info.get('raster_sha256') != current['raster_sha256'] or info.get('sequence_sha256') != current['sequence_sha256']:
        raise ValueError('raster or sequence implementation changed; rerun prepare')
    ids = class_ids(args.vocab)
    if info.get('classes') != ids:
        raise ValueError('prepared cache class order changed')
    for split in ('train', 'valid'):
        for cache_path in _cache_paths(out, split).values():
            if not cache_path.is_file():
                raise FileNotFoundError(cache_path)
    return info, ids


def _worker_seed(worker_id: int) -> None:
    seed = (SEED + worker_id * 104729) % (2**32)
    np.random.seed(seed)
    random.seed(seed)
    torch.manual_seed(seed)


def evaluate_model(model: MathGlyphNet, output: Path, class_ids_: list[str],
                   device: torch.device, batch: int, workers: int) -> dict:
    loader = DataLoader(GlyphDataset(output, 'valid'), batch_size=batch, shuffle=False,
                        num_workers=workers, worker_init_fn=_worker_seed,
                        persistent_workers=workers > 0)
    confusion = np.zeros((len(class_ids_), len(class_ids_)), dtype=np.int64)
    model.eval()
    with torch.no_grad():
        for image, path, globals_, target in loader:
            prediction = model(image.to(device), path.to(device), globals_.to(device))[0].argmax(1).cpu().numpy()
            target = target.numpy()
            np.add.at(confusion, (target, prediction), 1)
    supports = confusion.sum(axis=1)
    accuracies = {class_ids_[i]: (float(confusion[i, i] / supports[i]) if supports[i] else None)
                  for i in range(len(class_ids_))}
    available = [value for value in accuracies.values() if value is not None]
    sample_accuracy = float(confusion.trace() / max(1, confusion.sum()))
    known_indices = [i for i, class_id in enumerate(class_ids_) if class_id != 'junk']
    known_support = int(supports[known_indices].sum())
    known_correct = sum(int(confusion[i, i]) for i in known_indices)
    junk_index = class_ids_.index('junk') if 'junk' in class_ids_ else None
    junk_correct = int(confusion[junk_index, junk_index]) if junk_index is not None else 0
    junk_support = int(supports[junk_index]) if junk_index is not None else 0
    junk_predictions = int(confusion[:, junk_index].sum()) if junk_index is not None else 0
    return {
        'classTop1': sample_accuracy,
        'knownClassTop1': known_correct / max(1, known_support),
        'junkRecall': junk_correct / junk_support if junk_support else None,
        'junkPrecision': junk_correct / junk_predictions if junk_predictions else None,
        'sampleAccuracy': sample_accuracy,
        'macroClassAccuracy': float(np.mean(available)) if available else 0.0,
        'perClassAccuracy': accuracies,
        'supportByClass': {class_ids_[i]: int(supports[i]) for i in range(len(class_ids_))},
        'confusionPairs': _confusion_pairs(confusion, class_ids_),
        'confusionMatrix': confusion.tolist(),
    }


def _checkpoint(args: argparse.Namespace) -> tuple[MathGlyphNet, dict, list[str]]:
    out = Path(args.output)
    checkpoint_path = Path(args.checkpoint) if args.checkpoint else out / 'best.pt'
    saved = torch.load(checkpoint_path, map_location='cpu', weights_only=True)
    ids = class_ids(args.vocab)
    if saved.get('classes') != ids or saved.get('mathVocabSHA256') != digest(args.vocab):
        raise ValueError('checkpoint class order or vocabulary hash changed')
    model = MathGlyphNet(len(ids))
    model.load_state_dict(saved['state'])
    return model.eval(), saved, ids


def _capture_bounds(strokes: list[np.ndarray], styles: list[dict]) -> tuple[float, float, float, float]:
    extents = []
    for index, stroke in enumerate(strokes):
        width = float(styles[index].get('width', 0.0)) if index < len(styles) else 0.0
        radius = max(0.0, width) / 2
        extents.append((stroke.min(axis=0) - radius, stroke.max(axis=0) + radius))
    minimum = np.min([extent[0] for extent in extents], axis=0)
    maximum = np.max([extent[1] for extent in extents], axis=0)
    return float(minimum[0]), float(minimum[1]), float(maximum[0] - minimum[0]), float(maximum[1] - minimum[1])


def cap_tune_report(model: MathGlyphNet, class_ids_: list[str], vocab_path: Path,
                    build_dir: Path) -> dict:
    from resolver import member_weights

    split = json.loads((build_dir / 'datasets/cap-split.json').read_text())
    names = split.get('CAP-tune')
    if not isinstance(names, list) or len(names) != 134 or len(set(names)) != len(names):
        raise ValueError('CAP-tune split must be the immutable 134-record array')
    capture_dir = build_dir / 'glyph-capture'
    vocab = json.loads(vocab_path.read_text())
    label_to_class = {label: item['id'] for item in vocab['classes'] for label in item['labels']}
    class_index = {class_id: i for i, class_id in enumerate(class_ids_)}
    labels = sorted(label_to_class)
    label_index = {label: i for i, label in enumerate(labels)}
    confusion = np.zeros((len(labels), len(labels)), dtype=np.int64)
    model.eval()
    with torch.no_grad():
        for name in names:
            if Path(name).name != name:
                raise ValueError(f'invalid CAP-tune filename: {name}')
            record = json.loads((capture_dir / name).read_text())
            strokes = stroke_points(record['strokes'])
            encoded = encode_sequence(strokes)
            if encoded is None:
                raise ValueError(f'empty CAP-tune capture: {name}')
            image = torch.from_numpy(vectorized_raster(strokes).astype(np.float32)[None, None])
            path = torch.from_numpy(np.asarray(encoded['strokePoints'], dtype=np.float32)[None])
            globals_ = torch.from_numpy(stroke_globals(strokes)[None])
            probabilities = torch.softmax(model(image, path, globals_)[0], dim=1)[0].numpy()
            bounds = _capture_bounds(strokes, record.get('styles', []))
            scores = np.zeros(len(labels), dtype=np.float64)
            for class_id, index in class_index.items():
                weights = member_weights(class_id, bounds, {})
                for label, weight in weights.items():
                    scores[label_index[label]] += probabilities[index] * weight
            truth = label_index[record['label']]
            prediction = int(scores.argmax())
            confusion[truth, prediction] += 1
    accuracy = float(confusion.trace() / confusion.sum())
    return {
        'records': int(confusion.sum()), 'labelAccuracy': accuracy,
        'below80Percent': accuracy < .80,
        'selectionPolicy': 'class probability multiplied by SymbolResolver.memberWeights using this capture raw-point bbox and empty line context',
        'confusionPairs': _confusion_pairs(confusion, labels),
        'confusionMatrix': confusion.tolist(),
    }


def train(args: argparse.Namespace) -> None:
    info, ids = _verify_cache(args)
    torch.manual_seed(SEED)
    np.random.seed(SEED)
    random.seed(SEED)
    torch.set_num_threads(4)
    torch.use_deterministic_algorithms(True, warn_only=True)
    if args.device == 'mps' and not torch.backends.mps.is_available():
        raise RuntimeError('MPS is required by default; pass --device cpu only for a smoke check')
    device = torch.device(args.device)
    if args.include_extras and not info.get('includeExtras', False):
        raise ValueError('--include-extras requires a cache prepared with --include-extras')
    out = Path(args.output)
    targets = np.load(_cache_paths(out, 'train')['targets'], mmap_mode='r')
    model = MathGlyphNet(len(ids)).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    loss_fn = nn.CrossEntropyLoss(label_smoothing=.05)
    history, best, best_epoch = [], -1.0, None
    lineage = _source_hashes(Path(args.build_dir), args.vocab, info.get('includeHarvest', False),
                             info.get('includeExtras', False), info.get('includeHarvestQL', False),
                             info.get('includeHarvestBrace', False))
    config = {
        'architecture': f'TinyCNN64 + Conv1d(4→64→96→128), avg/max pool→128, globals2→fused256→{len(ids)}',
        'optimizer': 'AdamW', 'learningRate': args.lr, 'weightDecay': 1e-4,
        'scheduler': 'CosineAnnealingLR over configured epochs', 'labelSmoothing': .05,
        'batchSize': args.batch, 'workers': args.workers, 'maxPerClassPerEpoch': args.max_per_class,
        'includeHarvest': info.get('includeHarvest', False),
        'includeExtras': info.get('includeExtras', False),
        'includeHarvestQL': info.get('includeHarvestQL', False),
        'includeHarvestBrace': info.get('includeHarvestBrace', False),
        'trackpadP': args.trackpad_p, 'tremor': list(args.tremor),
        'augmentation': f'rotate ±10°, shear ±0.3, x-scale 0.8–1.25, 3x3 smooth elastic σ=.08, point jitter σ=.01; p={args.trackpad_p:g} simulated 8–16ms trackpad clock + 3-tap average + {args.tremor[0] * 100:g}–{args.tremor[1] * 100:g}% tremor; p=.2 reverse one stroke; p=.1 permute multi-stroke order',
        'timestampPolicy': 'discard source times because MathWriting/HWRT use milliseconds while CROHME may use ordinal fallbacks; trackpad augmentation synthesizes monotonic millisecond intervals',
        'globalPolicy': 'first 64 nonempty raw point strokes, ignore stroke width; min(strokeCount,6)/6 and clamped log width/height',
    }
    for epoch in range(args.epochs):
        indices = epoch_sample_indices(targets, len(ids), epoch, args.max_per_class)
        dataset = GlyphDataset(out, 'train', indices=indices, epoch=epoch, augment=True,
                               trackpad_p=args.trackpad_p, tremor=args.tremor)
        loader = DataLoader(dataset, batch_size=args.batch, shuffle=True, num_workers=args.workers,
                            worker_init_fn=_worker_seed, generator=torch.Generator().manual_seed(SEED + epoch))
        model.train()
        total_loss = 0.0
        for image, path, globals_, target in loader:
            image, path, globals_, target = (image.to(device), path.to(device),
                                               globals_.to(device), target.to(device))
            optimizer.zero_grad(set_to_none=True)
            logits, _ = model(image, path, globals_)
            loss = loss_fn(logits, target)
            loss.backward()
            optimizer.step()
            total_loss += float(loss.detach()) * len(target)
        validation = evaluate_model(model, out, ids, device, args.batch, args.workers)
        row = {'epoch': epoch + 1, 'loss': total_loss / len(indices),
               'validationClassTop1': validation['classTop1'],
               'validationKnownClassTop1': validation['knownClassTop1'],
               'validationJunkRecall': validation['junkRecall'],
               'validationJunkPrecision': validation['junkPrecision'],
               'validationMacroClassAccuracy': validation['macroClassAccuracy'],
               'validationSampleAccuracy': validation['sampleAccuracy'],
               'learningRate': optimizer.param_groups[0]['lr'], 'samples': len(indices)}
        history.append(row)
        print(json.dumps(row, sort_keys=True), flush=True)
        if validation['classTop1'] > best:
            best = validation['classTop1']
            best_epoch = epoch + 1
            torch.save({
                'state': {key: value.detach().cpu() for key, value in model.state_dict().items()},
                'classes': ids, 'epoch': epoch + 1, 'validation': validation,
                'mathVocabSHA256': digest(args.vocab), 'sourceHashes': lineage,
                'seed': SEED, 'trainingConfig': config,
            }, out / 'best.pt')
        scheduler.step()
        write_json(out / 'training.json', {
            'history': history, 'arguments': {k: str(v) if isinstance(v, Path) else v
                                               for k, v in vars(args).items()
                                               if k != 'run' and not callable(v)},
            'device': str(device), 'trainingConfig': config,
            'sourceHashes': lineage,
            'cache': {'trainRecords': info['cache_shapes']['train'],
                      'validRecords': info['cache_shapes']['valid']},
            'selectedEpoch': best_epoch,
        })
    selected = torch.load(out / 'best.pt', map_location='cpu', weights_only=True)
    model.load_state_dict(selected['state'])
    model.to('cpu')
    validation = evaluate_model(model, out, ids, torch.device('cpu'), args.batch, args.workers)
    cap = cap_tune_report(model, ids, args.vocab, Path(args.build_dir))
    metrics = {
        'seed': SEED, 'selectedEpoch': selected['epoch'], 'selectionMetric': f'aggregate {len(ids)}-class top-1 on CROHME+HWRT validation',
        'validation': validation, 'capTune': cap,
        'training': config, 'sourceHashes': selected['sourceHashes'],
    }
    write_json(out / 'metrics.json', metrics)
    print(json.dumps({'selectedEpoch': selected['epoch'], 'validationClassTop1': validation['classTop1'],
                      'validationMacroClassAccuracy': validation['macroClassAccuracy'],
                      'capTuneLabelAccuracy': cap['labelAccuracy'], 'capTuneBelow80Percent': cap['below80Percent']},
                     sort_keys=True), flush=True)


def report(args: argparse.Namespace) -> None:
    model, saved, ids = _checkpoint(args)
    _verify_checkpoint_sources(saved, Path(args.build_dir), args.vocab)
    model.to('cpu')
    validation = evaluate_model(model, Path(args.output), ids, torch.device('cpu'), args.batch, args.workers)
    cap = cap_tune_report(model, ids, args.vocab, Path(args.build_dir))
    metrics = {
        'seed': SEED, 'selectedEpoch': saved['epoch'],
        'selectionMetric': f'aggregate {len(ids)}-class top-1 on CROHME+HWRT validation',
        'validation': validation, 'capTune': cap, 'training': saved['trainingConfig'],
        'sourceHashes': saved['sourceHashes'],
        'report_script_sha256': digest(Path(__file__)),
    }
    write_json(Path(args.output) / 'metrics.json', metrics)
    print(json.dumps({'selectedEpoch': saved['epoch'], 'validationClassTop1': validation['classTop1'],
                      'validationMacroClassAccuracy': validation['macroClassAccuracy'],
                      'capTuneLabelAccuracy': cap['labelAccuracy'], 'capTuneBelow80Percent': cap['below80Percent']},
                     sort_keys=True), flush=True)


def _confusion_pairs(matrix: np.ndarray, classes: list[str], limit: int = 20) -> list[dict]:
    pairs = []
    for truth in range(len(classes)):
        for predicted in range(len(classes)):
            if truth != predicted and matrix[truth, predicted]:
                pairs.append({'true': classes[truth], 'predicted': classes[predicted],
                              'count': int(matrix[truth, predicted])})
    return sorted(pairs, key=lambda item: (-item['count'], item['true'], item['predicted']))[:limit]


def selfcheck(args: argparse.Namespace) -> None:
    import tempfile
    from raster import _self_check as raster_check
    from sequence import _check_fixture_file as sequence_check

    raster_check()
    sequence_check()
    with tempfile.TemporaryDirectory() as directory:
        staging_path = Path(directory) / 'math-vocab-f4.json'
        staging = json.loads(VOCAB.read_text())
        if not any(entry['id'] == 'junk' for entry in staging['classes']):
            staging['classes'].append({'id': 'junk', 'labels': ['<unk>']})
        staging['classes'].sort(key=lambda entry: entry['id'])
        write_json(staging_path, staging)
        assert len(class_ids(staging_path)) == len(staging['classes'])
        assert label_maps(staging_path)[2]['<unk>'] == 'junk'
        f5_path = Path(__file__).with_name('math-vocab-f5.json')
        assert len(class_ids(f5_path)) == 62
        assert label_maps(f5_path)[2]['l'] == 'glyph_u006C'
        assert label_maps(f5_path)[2]['q'] == 'glyph_u0071'
        f7_path = Path(__file__).with_name('math-vocab-f7.json')
        assert len(class_ids(f7_path)) == 64
        assert label_maps(f7_path)[2]['{'] == 'glyph_u007B'
        assert label_maps(f7_path)[2]['}'] == 'glyph_u007D'
        calibration_path = Path(directory) / 'calibration.json'
        calibration = {'checkpointSHA256': 'selfcheck', 'selectedEpoch': 13,
                       'mathVocabSHA256': digest(VOCAB), 'mathLMSHA256': digest(LANGUAGE_MODEL),
                       'temperature': .75, 'lambda': .6, 'tauSub': .8, 'tauRev': .9, 'tauFill': .97,
                       'disabledLabels': [], 'validation': {'substitutionPrecision': .99,
                                                           'harmfulSwapsPer100': .5}}
        write_json(calibration_path, calibration)
        assert export_calibration(calibration_path, 'selfcheck', 13, VOCAB, LANGUAGE_MODEL)['temperature'] == .75
        for key, value in [('checkpointSHA256', 'other'), ('temperature', 0),
                           ('disabledLabels', ['invalid-label']), ('tauFill', .89), ('tauFill', 1.01),
                           ('validation', {'substitutionPrecision': .98,
                                           'harmfulSwapsPer100': .5})]:
            write_json(calibration_path, {**calibration, key: value})
            try:
                export_calibration(calibration_path, 'selfcheck', 13, VOCAB, LANGUAGE_MODEL)
            except ValueError:
                pass
            else:
                raise AssertionError(f'accepted invalid calibration {key}')
    horizontal = stroke_globals(stroke_points([[[0, 0], [10, 0]]]))
    vertical = stroke_globals(stroke_points([[[0, 0], [0, 10]]]))
    dot = stroke_globals(stroke_points([[[2, 3]]]))
    thick = stroke_globals(stroke_points([[{'x': 0, 'y': 0}, {'x': 10, 'y': 0, 'width': 80}]]))
    assert np.allclose(horizontal, [1 / 6, 1.0], atol=1e-6), horizontal
    assert np.allclose(vertical, [1 / 6, -1.0], atol=1e-6), vertical
    assert np.allclose(dot, [1 / 6, 0.0], atol=1e-6), dot
    assert np.array_equal(horizontal, thick), (horizontal, thick)
    first64 = stroke_points([[[i, 0]] for i in range(64)] + [[[1000, 1000]]])
    assert np.allclose(stroke_globals(first64), [1.0, 1.0], atol=1e-6)
    trackpad_input = np.column_stack((np.linspace(0, 1, 12), np.linspace(1, 0, 12)))
    trackpad_output = _trackpad(trackpad_input, np.random.default_rng(SEED))
    assert np.array_equal(trackpad_output[0], trackpad_input[0])
    assert np.array_equal(trackpad_output[-1], trackpad_input[-1])
    augmented = augment_strokes([trackpad_input, trackpad_input[::-1]], np.random.default_rng(SEED + 1))
    repeated = augment_strokes([trackpad_input, trackpad_input[::-1]], np.random.default_rng(SEED + 1))
    explicit = augment_strokes([trackpad_input, trackpad_input[::-1]],
                               np.random.default_rng(SEED + 1), .5, (.01, .03))
    assert len(augmented) == len(repeated)
    assert all(np.array_equal(first, second) for first, second in zip(augmented, repeated))
    assert all(np.array_equal(first, second) for first, second in zip(augmented, explicit))
    assert all(np.isfinite(stroke).all() for stroke in augmented)
    assert encode_sequence(augmented) is not None
    assert len(source_groups(BUILD)['train']) == 3
    assert source_groups(BUILD, True)['train'][-1].name == 'mw-harvest-train.jsonl.gz'
    assert source_groups(BUILD, True)['valid'][-1].name == 'mw-harvest-valid.jsonl.gz'
    assert len(source_groups(BUILD, True, True)['train']) == 7
    assert len(source_groups(BUILD, True, True)['valid']) == 5
    assert len(source_groups(BUILD, False, False, True)['train']) == 4
    assert source_groups(BUILD, False, False, True)['train'][-1].name == 'mw-harvest-ql-train.jsonl.gz'
    assert len(source_groups(BUILD, True, True, True)['train']) == 8
    assert len(source_groups(BUILD, True, True, True)['valid']) == 6
    assert len(source_groups(BUILD, False, False, False, True)['train']) == 4
    assert source_groups(BUILD, False, False, False, True)['train'][-1].name == \
        'mw-harvest-brace-train.jsonl.gz'
    assert len(source_groups(BUILD, True, True, True, True)['train']) == 9
    assert len(source_groups(BUILD, True, True, True, True)['valid']) == 7

    fixture_path = ROOT / 'Tests/CanvasKitTests/Fixtures/raster/fixtures.json'
    fixtures = json.loads(fixture_path.read_text())['fixtures']
    for fixture in fixtures:
        paths = stroke_points(fixture['strokes'])
        expected = canonical_rasterize(fixture['strokes']).tobytes()
        assert vectorized_raster(paths).tobytes() == expected, fixture['name']

    groups = source_groups(Path(args.build_dir))['train']
    rng = np.random.default_rng(SEED)
    sample: list[tuple[list[np.ndarray], str]] = []
    seen = 0
    for path in groups:
        for row in jsonl_rows(path):
            if row.get('split') != 'train':
                continue
            paths = stroke_points(row['strokes'])
            seen += 1
            if len(sample) < 1000:
                sample.append((paths, path.name))
            else:
                replace = int(rng.integers(seen))
                if replace < 1000:
                    sample[replace] = (paths, path.name)
    if len(sample) != 1000:
        raise ValueError(f'expected 1000 raw raster records, found {len(sample)}')
    start = time.perf_counter()
    reference = [canonical_rasterize(paths).tobytes() for paths, _ in sample]
    canonical_seconds = time.perf_counter() - start
    start = time.perf_counter()
    actual = [vectorized_raster(paths).tobytes() for paths, _ in sample]
    vector_seconds = time.perf_counter() - start
    for i, (expected, got) in enumerate(zip(reference, actual)):
        if expected != got:
            raise AssertionError(f'vector raster differs from raster.py on reservoir record {i}')
    throughput_path = Path(args.build_dir) / 'orchestration-v2-wave2/raster-throughput.json'
    previous = json.loads(throughput_path.read_text()) if throughput_path.exists() else {}
    previous.update({
        'seed': SEED, 'paritySamples': len(sample), 'paritySourceRecords': seen,
        'canonicalParitySeconds': canonical_seconds,
        'vectorizedSeconds': vector_seconds,
        'vectorizedSamplesPerSecond': len(sample) / max(vector_seconds, 1e-9),
        'vectorizedByteParity': True,
        'sourceFiles': sorted({name for _, name in sample}),
    })
    write_json(throughput_path, previous)
    print(json.dumps({'raster_fixtures': len(fixtures), 'sequence_fixtures': 12,
                      'seeded_raster_samples': len(sample),
                      'canonical_samples_per_second': len(sample) / canonical_seconds,
                      'vectorized_samples_per_second': len(sample) / vector_seconds,
                      'raw_bbox_globals': 'horizontal, vertical, dot, thick-stroke, first-64'},
                     sort_keys=True), flush=True)


def class_ids(path: Path = VOCAB) -> list[str]:
    vocab = json.loads(path.read_text())
    classes = vocab.get('classes')
    if vocab.get('version') != 2 or not isinstance(classes, list):
        raise ValueError('math-vocab.json must contain the v2 class order')
    ids = [entry['id'] for entry in classes]
    if not (len(ids) == 59 and 'junk' not in ids or len(ids) == 60 and 'junk' in ids
            or len(ids) == 62 and {'junk', 'glyph_u006C', 'glyph_u0071'} <= set(ids)
            or len(ids) == 64 and {'junk', 'glyph_u006C', 'glyph_u0071',
                                   'glyph_u007B', 'glyph_u007D'} <= set(ids)):
        raise ValueError('math-vocab.json must contain 59 classes, 60 with junk, '
                         '62 with junk/l/q, or 64 with junk/l/q plus braces')
    if len(ids) in (62, 64):
        members = {entry['id']: entry['labels'] for entry in classes}
        expected = {'bar': ['1', '|'], 'glyph_u006C': ['l'], 'glyph_u0071': ['q']}
        if len(ids) == 64:
            expected |= {'glyph_u007B': ['{'], 'glyph_u007D': ['}']}
        if any(members[key] != labels for key, labels in expected.items()):
            raise ValueError('newer vocabularies require bar={1,|} and singleton classes')
    if ids != sorted(ids) or len(ids) != len(set(ids)):
        raise ValueError('math-vocab class ids are not uniquely sorted')
    return ids


class MathGlyphNet(nn.Module):
    """Dual-branch classifier; forward returns logits and the 256-d fused embedding."""

    def __init__(self, classes: int = 59):
        super().__init__()
        self.image_features = nn.Sequential(
            nn.Conv2d(1, 16, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(16, 32, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(32, 48, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Flatten(), nn.Linear(48 * 4 * 4, 64), nn.ReLU(),
        )
        self.path_features = nn.Sequential(
            nn.Conv1d(4, 64, 5, padding=2), nn.BatchNorm1d(64), nn.ReLU(),
            nn.Conv1d(64, 96, 5, stride=2, padding=2), nn.BatchNorm1d(96), nn.ReLU(),
            nn.Conv1d(96, 128, 3, stride=2, padding=1), nn.BatchNorm1d(128), nn.ReLU(),
        )
        self.path_projection = nn.Linear(256, 128)
        self.fusion = nn.Linear(64 + 128 + 2, 256)
        self.dropout = nn.Dropout(.25)
        self.classifier = nn.Linear(256, classes)

    def forward(self, glyph_image: torch.Tensor, stroke_points: torch.Tensor,
                stroke_globals: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        image = self.image_features(1.0 - glyph_image / 255.0)
        path = self.path_features(stroke_points.transpose(1, 2))
        pooled = torch.cat((path.mean(dim=2), path.amax(dim=2)), dim=1)
        path = self.path_projection(pooled)
        embedding = torch.relu(self.fusion(torch.cat((image, path, stroke_globals), dim=1)))
        return self.classifier(self.dropout(embedding)), embedding


def _parity_inputs(model: MathGlyphNet, checkpoint_path: Path | None) -> list[tuple[np.ndarray, np.ndarray, np.ndarray]]:
    if checkpoint_path is None:
        rng = np.random.default_rng(SEED + 59)
        examples = []
        for _ in range(5):
            image = rng.integers(0, 256, size=(32, 32), dtype=np.uint8)
            path = np.zeros((128, 4), dtype=np.float32)
            path[:, :2] = rng.normal(0, .2, size=(128, 2))
            path[0, 2], path[-1, 3] = 1, 1
            globals_ = rng.uniform(0, 1, size=2).astype(np.float32)
            examples.append((image, path, globals_))
        return examples
    cache_dir = checkpoint_path.parent
    arrays = {key: np.load(_cache_paths(cache_dir, 'valid')[key], mmap_mode='r')
              for key in ('images', 'paths', 'globals')}
    length = len(arrays['images'])
    selected = sorted(set([0, length // 4, length // 2, (3 * length) // 4, length - 1]))
    if len(selected) != 5:
        raise ValueError('validation cache needs at least five records for export parity')
    return [(np.array(arrays['images'][i], dtype=np.uint8).reshape(32, 32),
             np.array(arrays['paths'][i], dtype=np.float32),
             np.array(arrays['globals'][i], dtype=np.float32)) for i in selected]


def _native_parity(model: MathGlyphNet, compiled: Path,
                   examples: list[tuple[np.ndarray, np.ndarray, np.ndarray]]) -> dict:
    import coremltools as ct
    from PIL import Image

    native = ct.models.CompiledMLModel(str(compiled), compute_units=ct.ComputeUnit.ALL)
    logits_errors, embedding_errors = [], []
    model = model.cpu().eval()
    with torch.no_grad():
        for image, path, globals_ in examples:
            expected_logits, expected_embedding = model(
                torch.from_numpy(image.astype(np.float32)[None, None]),
                torch.from_numpy(path.astype(np.float32)[None]),
                torch.from_numpy(globals_.astype(np.float32)[None]),
            )
            result = native.predict({
                'glyphImage': Image.fromarray(image, mode='L'),
                'strokePoints': path.astype(np.float32)[None],
                'strokeGlobals': globals_.astype(np.float32)[None],
            })
            actual_logits = np.asarray(result['logits'], dtype=np.float32).reshape(1, model.classifier.out_features)
            actual_embedding = np.asarray(result['embedding'], dtype=np.float32).reshape(1, 256)
            logits_errors.append(float(np.max(np.abs(actual_logits - expected_logits.numpy()))))
            embedding_errors.append(float(np.max(np.abs(actual_embedding - expected_embedding.numpy()))))
    parity = {
        'inputs': len(examples), 'logitsMaxAbsError': logits_errors,
        'embeddingMaxAbsError': embedding_errors,
        'worstLogitsError': max(logits_errors), 'worstEmbeddingError': max(embedding_errors),
        'computeUnits': 'ALL',
    }
    if max(parity['worstLogitsError'], parity['worstEmbeddingError']) >= .003:
        raise ValueError(f'Core ML parity exceeds 3e-3: {parity}')
    return parity


def export_calibration(path: Path, checkpoint_hash: str, epoch: int,
                       vocab: Path, language_model: Path) -> dict:
    calibration = json.loads(path.read_text())
    expected = {'checkpointSHA256': checkpoint_hash, 'selectedEpoch': epoch,
                'mathVocabSHA256': digest(vocab), 'mathLMSHA256': digest(language_model)}
    if any(calibration.get(key) != value for key, value in expected.items()):
        raise ValueError('calibration checkpoint, epoch, vocabulary or LM mismatch')
    bounds = {'temperature': (0, math.inf), 'lambda': (.2, 1.2),
              'tauSub': (0, 1), 'tauRev': (.9, 1), 'tauFill': (.9, 1)}
    for key, (low, high) in bounds.items():
        value = calibration.get(key)
        if not isinstance(value, (int, float)) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError(f'invalid calibration {key}: {value}')
    if calibration['temperature'] <= 0:
        raise ValueError('calibration temperature must be positive')
    labels = {label for cls in json.loads(vocab.read_text())['classes'] for label in cls['labels']}
    disabled = calibration['disabledLabels']
    if not isinstance(disabled, list) or any(label not in labels for label in disabled):
        raise ValueError('invalid disabled calibration labels')
    validation = calibration['validation']
    precision, harmful = validation['substitutionPrecision'], validation['harmfulSwapsPer100']
    if not ((.90 if calibration.get('commitMode') else .99) <= precision <= 1 and 0 <= harmful <= .5):
        raise ValueError('calibration did not meet validation gates')
    return {key: calibration[key] for key in (*bounds, 'disabledLabels')}


def export(args: argparse.Namespace) -> None:
    import coremltools as ct

    ids = class_ids(args.vocab)
    lm_path = Path(args.language_model)
    if not lm_path.is_file():
        raise FileNotFoundError(lm_path)
    default_output = DUMMY_OUTPUT if args.dummy else (Path(args.checkpoint).parent if args.checkpoint else DEFAULT_OUTPUT)
    out = Path(args.output or default_output)
    checkpoint_path = None
    if args.dummy:
        torch.manual_seed(SEED)
        model = MathGlyphNet(len(ids)).eval()
        checkpoint_hash = 'dummy-seed-20261003'
        metrics = {'kind': 'dummy runtime smoke model'}
    else:
        checkpoint_path = Path(args.checkpoint) if args.checkpoint else out / 'best.pt'
        model, saved, _ = _checkpoint(argparse.Namespace(
            output=checkpoint_path.parent, checkpoint=checkpoint_path, vocab=args.vocab))
        _verify_checkpoint_sources(saved, Path(args.build_dir), args.vocab)
        training_hashes = saved.get('sourceHashes', {})
        checkpoint_hash = digest(checkpoint_path)
        metrics_path = Path(args.metrics) if args.metrics else checkpoint_path.parent / 'metrics.json'
        if not metrics_path.is_file():
            raise FileNotFoundError(f'run report before export: {metrics_path}')
        metrics = json.loads(metrics_path.read_text())
        if metrics.get('sourceHashes') != training_hashes or metrics.get('selectedEpoch') != saved['epoch']:
            raise ValueError('metrics do not belong to the selected checkpoint')

    calibration = {'temperature': 1.0, 'lambda': .6, 'tauSub': .8,
                   'tauRev': .9, 'tauFill': .9, 'disabledLabels': []}
    if args.calibration:
        if args.dummy:
            raise ValueError('dummy export cannot use trained calibration')
        calibration = export_calibration(args.calibration, checkpoint_hash, saved['epoch'],
                                         args.vocab, lm_path)

    precision = ct.precision.FLOAT16
    if args.precision == 'mixed':
        from coremltools.converters.mil.mil.passes.defs.quantization import FP16ComputePrecision

        def use_half(op):
            # Keep learned feature operations and output heads in FP32. Intermediate
            # activation/pooling and input normalization can safely use FP16.
            consumers = {child.op_type for output in op.outputs for child in output.child_ops}
            return op.op_type in {'mul', 'sub', 'max_pool'} or (
                op.op_type == 'relu' and not consumers.intersection({'linear', 'concat'}))

        precision = FP16ComputePrecision(op_selector=use_half)

    example = (torch.full((1, 1, 32, 32), 255.0),
               torch.zeros((1, 128, 4), dtype=torch.float32),
               torch.zeros((1, 2), dtype=torch.float32))
    traced = torch.jit.trace(model, example, strict=True)
    converted = ct.convert(
        traced,
        inputs=[
            ct.ImageType(name='glyphImage', shape=example[0].shape,
                         color_layout=ct.colorlayout.GRAYSCALE, scale=1.0),
            ct.TensorType(name='strokePoints', shape=example[1].shape, dtype=np.float32),
            ct.TensorType(name='strokeGlobals', shape=example[2].shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name='logits', dtype=np.float32),
                 ct.TensorType(name='embedding', dtype=np.float32)],
        convert_to='mlprogram', minimum_deployment_target=ct.target.macOS13,
        compute_precision=precision,
    )
    converted.short_description = 'Math glyph classifier: raster, pen path, and raw geometry globals'
    converted.user_defined_metadata['mathVocabSHA256'] = digest(args.vocab)
    converted.user_defined_metadata['mathLMSHA256'] = digest(lm_path)
    out.mkdir(parents=True, exist_ok=True)
    package = out / 'MathGlyphs.mlpackage'
    compiled = out / 'MathGlyphs.mlmodelc'
    if package.exists():
        shutil.rmtree(package)
    if compiled.exists():
        shutil.rmtree(compiled)
    converted.save(str(package))
    subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), str(out)], check=True)
    compiled_bytes = sum(p.stat().st_size for p in compiled.rglob('*') if p.is_file())
    if compiled_bytes > 1_000_000:
        raise ValueError(f'compiled model exceeds 1,000,000 bytes: {compiled_bytes}')

    spec = converted.get_spec()
    inputs = {item.name: item.type for item in spec.description.input}
    outputs = {item.name: item.type for item in spec.description.output}
    if set(inputs) != {'glyphImage', 'strokePoints', 'strokeGlobals'}:
        raise ValueError(f'unexpected model inputs: {inputs.keys()}')
    if set(outputs) != {'logits', 'embedding'}:
        raise ValueError(f'unexpected model outputs: {outputs.keys()}')
    image = inputs['glyphImage'].imageType
    if (image.width, image.height, image.colorSpace) != (32, 32, 10):
        raise ValueError(f'wrong image contract: {image}')
    expected_shapes = {
        'strokePoints': [1, 128, 4], 'strokeGlobals': [1, 2],
        'logits': [1, len(ids)], 'embedding': [1, 256],
    }
    for name, shape in expected_shapes.items():
        feature = (inputs if name in inputs else outputs)[name].multiArrayType
        if list(feature.shape) != shape or feature.dataType != 65568:  # Core ML FLOAT32
            raise ValueError(f'wrong tensor contract for {name}: shape={list(feature.shape)}, type={feature.dataType}')
    parity = _native_parity(model, compiled, _parity_inputs(model, checkpoint_path))
    manifest = {
        'version': 2,
        'classes': ids,
        'mathVocabSHA256': digest(args.vocab),
        'compiledBundleSHA256': bundle_digest(compiled),
        **calibration,
        'mathLMSHA256': digest(lm_path),
        'metrics': metrics,
    }
    write_json(out / 'MathGlyphs-manifest.json', manifest)
    write_json(out / 'export.json', {
        'checkpoint': checkpoint_hash, 'compiled_bytes': compiled_bytes,
        'compiled_bundle_sha256': manifest['compiledBundleSHA256'],
        'input_names': sorted(inputs), 'output_names': sorted(outputs),
        'precision': args.precision, 'status': 'dummy' if args.dummy else 'trained',
        'training_script_sha256': None if args.dummy else training_hashes['train_script_sha256'],
        'export_script_sha256': digest(Path(__file__)),
        'calibration_sha256': digest(args.calibration) if args.calibration else None,
        'parity': parity,
    })
    print(json.dumps({'output': str(out), 'compiled_bytes': compiled_bytes,
                      'bundle_sha256': manifest['compiledBundleSHA256']}, sort_keys=True))


def _probability(value: str) -> float:
    probability = float(value)
    if not 0 <= probability <= 1:
        raise argparse.ArgumentTypeError('must be between 0 and 1')
    return probability


def _tremor_range(value: str) -> tuple[float, float]:
    try:
        low, high = map(float, value.split('-', 1))
    except ValueError as exc:
        raise argparse.ArgumentTypeError('expected MIN-MAX, for example 0.01-0.03') from exc
    if not 0 <= low <= high <= 1:
        raise argparse.ArgumentTypeError('expected 0 <= MIN <= MAX <= 1')
    return low, high


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check_parser = commands.add_parser('selfcheck')
    check_parser.add_argument('--build-dir', type=Path, default=BUILD)
    check_parser.set_defaults(run=selfcheck)
    prepare_parser = commands.add_parser('prepare')
    prepare_parser.add_argument('--build-dir', type=Path, default=BUILD)
    prepare_parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    prepare_parser.add_argument('--vocab', type=Path, default=VOCAB)
    prepare_parser.add_argument('--include-harvest', action='store_true')
    prepare_parser.add_argument('--include-extras', action='store_true')
    prepare_parser.add_argument('--include-harvest-ql', action='store_true')
    prepare_parser.add_argument('--include-harvest-brace', action='store_true')
    prepare_parser.set_defaults(run=prepare)
    train_parser = commands.add_parser('train')
    train_parser.add_argument('--build-dir', type=Path, default=BUILD)
    train_parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    train_parser.add_argument('--vocab', type=Path, default=VOCAB)
    train_parser.add_argument('--include-extras', action='store_true')
    train_parser.add_argument('--epochs', type=int, default=30)
    train_parser.add_argument('--batch', type=int, default=512)
    train_parser.add_argument('--workers', type=int, default=8)
    train_parser.add_argument('--max-per-class', type=int, default=MAX_EPOCH_CLASS)
    train_parser.add_argument('--device', default='mps')
    train_parser.add_argument('--lr', type=float, default=1e-3)
    train_parser.add_argument('--trackpad-p', type=_probability, default=.5)
    train_parser.add_argument('--tremor', type=_tremor_range, default=(.01, .03), metavar='MIN-MAX')
    train_parser.set_defaults(run=train)
    report_parser = commands.add_parser('report')
    report_parser.add_argument('--build-dir', type=Path, default=BUILD)
    report_parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    report_parser.add_argument('--checkpoint', type=Path)
    report_parser.add_argument('--vocab', type=Path, default=VOCAB)
    report_parser.add_argument('--batch', type=int, default=512)
    report_parser.add_argument('--workers', type=int, default=8)
    report_parser.set_defaults(run=report)
    export_parser = commands.add_parser('export')
    export_parser.add_argument('--dummy', action='store_true')
    export_parser.add_argument('--precision', choices=('float16', 'mixed'), default='float16')
    export_parser.add_argument('--checkpoint', type=Path)
    export_parser.add_argument('--output', type=Path)
    export_parser.add_argument('--metrics', type=Path)
    export_parser.add_argument('--calibration', type=Path)
    export_parser.add_argument('--build-dir', type=Path, default=BUILD)
    export_parser.add_argument('--vocab', type=Path, default=VOCAB)
    export_parser.add_argument('--language-model', type=Path, default=LANGUAGE_MODEL)
    export_parser.set_defaults(run=export)
    args = parser.parse_args()
    args.run(args)


if __name__ == '__main__':
    main()
