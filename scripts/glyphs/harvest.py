#!/usr/bin/env python3
"""Align and harvest high-confidence MathWriting symbols with an F2 checkpoint."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import math
import random
import re
from pathlib import Path, PurePosixPath
import tarfile
import time
from xml.etree import ElementTree as ET

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont

import datasets
from linearize import linearize
from train_v2 import (MathGlyphNet, digest, label_maps, stroke_globals,
                      stroke_points, vectorized_raster, write_json, _cache_paths)
from sequence import encode as encode_sequence

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BUILD = ROOT / "build"
SEED = 20261003
DEFAULT_MIN_SYMBOL_P = 0.30
DEFAULT_MIN_MEAN_P = 0.70
DEFAULT_MIN_TARGET_P = 0.05
STRICT_MIN_SYMBOL_P = 0.50
STRICT_MIN_MEAN_P = 0.80
CONTACT_SHEET_SAMPLES = 400
QL_CONTACT_SHEET_SAMPLES = 200
# linearize() has no q label and \ell is a cursive l; both are handled by --only-labels.
_ELL = re.compile(r"\\ell(?![A-Za-z])")


def _ink_annotation(root: ET.Element, name: str) -> str | None:
    return next(((node.text or "").strip() for node in root
                 if node.tag.rsplit("}", 1)[-1] == "annotation"
                 and node.attrib.get("type", "").casefold() == name.casefold()
                 and (node.text or "").strip()), None)


def _strokes(root: ET.Element) -> list[list[list[int | float]]]:
    traces, order = datasets._inkml(root)
    filled = datasets._fill_times([traces[key] for key in order])
    return [stroke for stroke in filled if stroke]


def delayed_stroke_reorder(strokes: list[list]) -> list[list]:
    """Move short, late interior strokes just behind the earlier stroke they belong to."""
    if len(strokes) < 2:
        return strokes
    extents = []
    lengths = []
    centers = []
    all_y = [float(point[1]) for stroke in strokes for point in stroke]
    height = max(all_y) - min(all_y) if all_y else 0.0
    for stroke in strokes:
        xs = [float(point[0]) for point in stroke]
        length = sum(math.dist((float(a[0]), float(a[1])), (float(b[0]), float(b[1])))
                     for a, b in zip(stroke, stroke[1:]))
        extents.append((min(xs), max(xs)))
        centers.append((min(xs) + max(xs)) / 2)
        lengths.append(length)
    median = float(np.median(lengths))
    if median <= 0:
        return strokes

    # Work against original indices so moving one stroke cannot change later matches.
    moves: dict[int, int] = {}
    padding = 0.10 * height
    for late, length in enumerate(lengths):
        if length >= 0.25 * median or not any(center > centers[late] for center in centers[:late]):
            continue
        for earlier in range(late):
            low, high = extents[earlier]
            if low - padding <= centers[late] <= high + padding:
                moves[late] = earlier
                break
    if not moves:
        return strokes
    moved = set(moves)
    result = []
    for index, stroke in enumerate(strokes):
        if index not in moved:
            result.append(stroke)
        for delayed, anchor in moves.items():
            if anchor == index:
                result.append(strokes[delayed])
    return result


def stage1_group_caps(cache_dir: Path, ids: list[str]) -> dict[str, int]:
    """Empirical nearest-rank 99th percentile stroke count, capped at five."""
    values: dict[str, list[int]] = defaultdict(list)
    targets_path = cache_dir / "train-targets.npy"
    offsets_path = cache_dir / "train-raw-record-offsets.npy"
    if not targets_path.is_file() or not offsets_path.is_file():
        raise FileNotFoundError(f"stage-1 prepared training cache missing under {cache_dir}")
    targets = np.load(targets_path, mmap_mode="r")
    offsets = np.load(offsets_path, mmap_mode="r")
    if len(offsets) != len(targets) + 1:
        raise ValueError("stage-1 training cache target/record-offset sizes differ")
    for index, target in enumerate(targets):
        class_id = ids[int(target)]
        count = int(offsets[index + 1]) - int(offsets[index])
        if count:
            values[class_id].append(count)
    missing = sorted(set(ids) - set(values))
    if missing:
        raise ValueError(f"stage-1 has no stroke-count samples for classes: {missing}")
    result = {}
    for class_id, counts in values.items():
        counts.sort()
        rank = max(1, math.ceil(0.99 * len(counts)))
        result[class_id] = min(5, counts[rank - 1])
    return result


def _outlier_penalty(group: list[list]) -> int:
    if len(group) < 2:
        return 0
    bounds = [(min(float(p[0]) for p in stroke), max(float(p[0]) for p in stroke))
              for stroke in group]
    ys = [float(p[1]) for stroke in group for p in stroke]
    pad = 0.20 * (max(ys) - min(ys))
    penalty = 0
    for index, (low, high) in enumerate(bounds):
        rest_low = min(item[0] for other, item in enumerate(bounds) if other != index)
        rest_high = max(item[1] for other, item in enumerate(bounds) if other != index)
        if high < rest_low - pad or low > rest_high + pad:
            penalty += 1
    return penalty


def _group_probabilities(model: MathGlyphNet, strokes: list[list], max_group: int,
                         temperature: float) -> dict[tuple[int, int], np.ndarray]:
    groups, images, paths, globals_ = [], [], [], []
    for start in range(len(strokes)):
        for size in range(1, min(max_group, len(strokes) - start) + 1):
            group = strokes[start:start + size]
            paths_xy = stroke_points(group)
            encoded = encode_sequence(paths_xy)
            if encoded is None:
                continue
            groups.append((start, size))
            images.append(vectorized_raster(paths_xy).astype(np.float32))
            paths.append(np.asarray(encoded["strokePoints"], dtype=np.float32))
            globals_.append(stroke_globals(paths_xy))
    if not groups:
        return {}
    with torch.inference_mode():
        logits, _ = model(torch.from_numpy(np.stack(images)[:, None]),
                          torch.from_numpy(np.stack(paths)),
                          torch.from_numpy(np.stack(globals_)))
        probabilities = torch.softmax(logits / temperature, dim=1).cpu().numpy()
    return {group: probabilities[index] for index, group in enumerate(groups)}


def align(strokes: list[list], labels: list[str], label_to_class: dict[str, str],
          class_index: dict[str, int], caps: dict[str, int], model: MathGlyphNet,
          temperature: float) -> list[dict] | None:
    """Maximize summed log class probability minus the specified stroke outlier cost."""
    if not labels or not strokes:
        return None
    probs = _group_probabilities(model, strokes, max(caps.values()), temperature)
    n, m = len(strokes), len(labels)
    score = [[-math.inf] * (m + 1) for _ in range(n + 1)]
    back: list[list[tuple[int, int, float] | None]] = [[None] * (m + 1) for _ in range(n + 1)]
    score[0][0] = 0.0
    for consumed in range(n + 1):
        for matched in range(m):
            if score[consumed][matched] == -math.inf:
                continue
            class_id = label_to_class[labels[matched]]
            for size in range(1, min(caps[class_id], n - consumed) + 1):
                distribution = probs.get((consumed, size))
                if distribution is None:
                    continue
                p = float(distribution[class_index[class_id]])
                candidate = score[consumed][matched] + math.log(max(p, 1e-30)) - 3 * _outlier_penalty(strokes[consumed:consumed + size])
                if candidate > score[consumed + size][matched + 1]:
                    score[consumed + size][matched + 1] = candidate
                    back[consumed + size][matched + 1] = (consumed, matched, p)
    if score[n][m] == -math.inf:
        return None
    aligned = []
    i, j = n, m
    while j:
        previous = back[i][j]
        if previous is None:
            return None
        start, label_index_, probability = previous
        aligned.append({"label": labels[label_index_], "probability": probability,
                        "strokes": strokes[start:i]})
        i, j = start, label_index_
    if i != 0:
        return None
    return list(reversed(aligned))


def _candidate(root: ET.Element, member_name: str,
               only_labels: tuple[str, ...] | None = None) -> tuple[str, list[str], list[list]] | None:
    latex = _ink_annotation(root, "normalizedLabel") or _ink_annotation(root, "label")
    if not latex:
        return None
    # Glyph supervision maps multiplication signs to x; linearize() alone maps them to ·.
    latex = latex.replace(r"\times", "x").replace("×", "x")
    extra_direct = ""
    if only_labels:
        latex = _ELL.sub("l", latex)
        extra_direct = "".join(only_labels)
    labels, has_frac, unk_count = linearize(latex, extra_direct)
    if unk_count or has_frac or not 2 <= len(labels) <= 30:
        return None
    if only_labels and not any(label in only_labels for label in labels):
        return None
    strokes = _strokes(root)
    if not strokes or len(strokes) > 3 * len(labels):
        return None
    return PurePosixPath(member_name).stem, labels, delayed_stroke_reorder(strokes)


def _accept(aligned: list[dict], thresholds: tuple[float, float],
            targets: tuple[str, ...] | None = None,
            min_target_probability: float = DEFAULT_MIN_TARGET_P) -> bool:
    """Wave-3 acceptance; selected target labels are pinned by alignment position."""
    if targets:
        target = [symbol for symbol in aligned if symbol["label"] in targets]
        others = [symbol for symbol in aligned if symbol["label"] not in targets]
        if not target:
            return False
        if others:
            mean_log = sum(math.log(max(symbol["probability"], 1e-30)) for symbol in others) / len(others)
            if mean_log < math.log(thresholds[1]):
                return False
        return (all(symbol["probability"] >= min_target_probability for symbol in target)
                and all(symbol["probability"] >= thresholds[0] for symbol in others))
    mean_log = sum(math.log(max(symbol["probability"], 1e-30)) for symbol in aligned) / len(aligned)
    return (all(symbol["probability"] >= thresholds[0] for symbol in aligned)
            and mean_log >= math.log(thresholds[1]))


def _contact_sheet(samples: list[dict], destination: Path) -> None:
    cell, columns = 96, 20
    rows = max(1, math.ceil(len(samples) / columns))
    sheet = Image.new("RGB", (columns * cell, rows * cell), "white")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 14)
    for index, item in enumerate(samples):
        label, image = item["label"], item["image"]
        x, y = (index % columns) * cell, (index // columns) * cell
        glyph = Image.fromarray(image).convert("RGB").resize((64, 64), Image.Resampling.NEAREST)
        sheet.paste(glyph, (x + 4, y + 4))
        draw.text((x + 70, y + 8), f"{index + 1}\n{label}", font=font, fill="black", spacing=2)
    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination)


def _archive_hash(path: Path, build_dir: Path) -> str:
    manifests = (build_dir / "datasets/SOURCES.json", path.parent / "SOURCES.json")
    for manifest in manifests:
        if not manifest.is_file():
            continue
        for source in json.loads(manifest.read_text()).get("sources", []):
            if source.get("filename") == path.name and source.get("byte_size") == path.stat().st_size:
                return source["sha256"]
    return digest(path)


def harvest(args: argparse.Namespace) -> None:
    build_dir = Path(args.build_dir)
    archive_path = Path(args.mw_archive) if args.mw_archive else build_dir / "datasets/mathwriting-2024.tgz"
    checkpoint_path = Path(args.checkpoint) if args.checkpoint else build_dir / "glyph-training-v2/F2/best.pt"
    dataset_dir = build_dir / "datasets"
    targets = tuple(args.only_labels) if args.only_labels else ()
    # --tag keeps a second --only-labels harvest (braces) from colliding with the
    # q/l artifacts, whose names are frozen into the F6 lineage.
    tag = args.tag or ("mw-harvest" + ("-ql" if targets else ""))
    stem = tag.removeprefix("mw-")
    output_paths = {"train": dataset_dir / f"{tag}-train.jsonl.gz",
                    "valid": dataset_dir / f"{tag}-valid.jsonl.gz"}
    report_path = build_dir / "orchestration-v2-wave3" / f"{stem}-summary.json"
    contact_path = build_dir / "orchestration-v2-wave3" / f"{stem}-contact-sheet.png"
    index_path = build_dir / "orchestration-v2-wave3" / f"{stem}-contact-sheet-index.json"
    if any(path.exists() for path in (*output_paths.values(), report_path, contact_path, index_path)):
        raise FileExistsError("harvest outputs already exist; remove them explicitly before rerunning")

    ids, class_index, label_to_class = label_maps(args.vocab)
    unknown = sorted(set(targets) - set(label_to_class))
    if unknown:
        raise ValueError(f"unknown --only-labels vocab labels: {unknown}")
    sheet_size = args.contact_sheet_samples or (QL_CONTACT_SHEET_SAMPLES if targets else CONTACT_SHEET_SAMPLES)
    classes = json.loads(args.vocab.read_text())["classes"]
    torch.set_num_threads(4)
    model = MathGlyphNet(len(ids))
    saved = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    if saved.get("classes") != ids or saved.get("mathVocabSHA256") != digest(args.vocab):
        raise ValueError("F2 checkpoint class order or vocabulary hash changed")
    model.load_state_dict(saved["state"])
    model.eval()
    cache = _cache_paths(checkpoint_path.parent, "train")
    caps = stage1_group_caps(cache["targets"].parent, ids)
    thresholds = (STRICT_MIN_SYMBOL_P, STRICT_MIN_MEAN_P) if args.strict else (
        args.min_symbol_probability, args.min_mean_probability)
    rng = random.Random(args.seed)
    reservoir: list[dict] = []
    candidates = Counter()
    accepted = Counter()
    accepted_symbols = Counter()
    seen_symbols = 0
    started = time.monotonic()
    per_class = {entry["id"]: {"symbolsAligned": 0, "symbolsAccepted": 0} for entry in classes}
    record_counts = Counter()
    dataset_dir.mkdir(parents=True, exist_ok=True)
    with datasets._gzip_writers(dataset_dir, tag, ("train", "valid")) as writers:
        with tarfile.open(archive_path, mode="r|gz") as archive:
            for member in archive:
                parts = PurePosixPath(member.name).parts
                split = "train" if "train" in parts else "valid" if "valid" in parts else None
                if split is None or not member.isfile() or not member.name.lower().endswith(".inkml"):
                    continue
                if args.limit and candidates["train"] + candidates["valid"] >= args.limit:
                    break
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(f"unreadable MathWriting ink: {member.name}")
                try:
                    root = ET.parse(stream).getroot()
                    candidate = _candidate(root, member.name, targets or None)
                    if candidate is None:
                        continue
                    sample_id, labels, strokes = candidate
                    candidates[split] += 1
                    candidate_total = candidates["train"] + candidates["valid"]
                    if candidate_total % args.progress_every == 0:
                        elapsed = time.monotonic() - started
                        print(json.dumps({"progressEligibleInks": candidate_total,
                                          "elapsedSeconds": round(elapsed, 1),
                                          "eligibleInksPerSecond": round(candidate_total / max(elapsed, 1e-9), 2),
                                          "acceptedTrain": accepted["train"],
                                          "acceptedValid": accepted["valid"]}, sort_keys=True), flush=True)
                    aligned = align(strokes, labels, label_to_class, class_index, caps,
                                    model, args.temperature)
                    if aligned is None:
                        candidates[f"{split}_unalignable"] += 1
                        continue
                    for symbol in aligned:
                        per_class[label_to_class[symbol["label"]]]["symbolsAligned"] += 1
                    if not _accept(aligned, thresholds, targets or None, args.min_target_probability):
                        candidates[f"{split}_rejected_confidence"] += 1
                        continue
                    accepted[split] += 1
                    for symbol_index, symbol in enumerate(aligned):
                        label = symbol["label"]
                        if targets and label not in targets:
                            continue
                        class_id = label_to_class[label]
                        per_class[class_id]["symbolsAccepted"] += 1
                        accepted_symbols[(split, label)] += 1
                        group = symbol["strokes"]
                        row = datasets._record("mw-harvest", split, None, label, group,
                                               f"mw-harvest:{sample_id}:{symbol_index}", label_to_class)
                        datasets._write_record(writers[split], row, record_counts)
                        seen_symbols += 1
                        item = {"label": label, "split": split, "sampleId": sample_id,
                                "symbolIndex": symbol_index, "probability": symbol["probability"]}
                        if len(reservoir) < sheet_size:
                            item["image"] = vectorized_raster([np.asarray([[p[0], p[1]] for p in stroke], dtype=np.float64) for stroke in group])
                            reservoir.append(item)
                        else:
                            choice = rng.randrange(seen_symbols)
                            if choice < sheet_size:
                                item["image"] = vectorized_raster([np.asarray([[p[0], p[1]] for p in stroke], dtype=np.float64) for stroke in group])
                                reservoir[choice] = item
                finally:
                    stream.close()
    if len(reservoir) != min(sheet_size, sum(per_class[item["id"]]["symbolsAccepted"] for item in classes)):
        raise AssertionError("contact sheet reservoir size mismatch")
    _contact_sheet(reservoir, contact_path)
    write_json(index_path, {"seed": args.seed, "symbols": [
        {key: item[key] for key in ("label", "split", "sampleId", "symbolIndex", "probability")}
        | {"cell": index} for index, item in enumerate(reservoir)]})
    per_class_counts = {}
    for item in classes:
        class_id = item["id"]
        per_class_counts[class_id] = {**per_class[class_id], "labels": item["labels"]}
    write_json(report_path, {
        "source": str(archive_path), "checkpoint": str(checkpoint_path),
        "sourceHashes": {"mwArchiveSHA256": _archive_hash(archive_path, build_dir),
                         "checkpointSHA256": digest(checkpoint_path),
                         "harvestScriptSHA256": digest(Path(__file__)),
                         "mathVocabSHA256": digest(args.vocab)},
        "temperature": args.temperature,
        "seed": args.seed, "onlyLabels": list(targets) or None,
        "thresholds": {"minSymbolProbability": thresholds[0],
                       "minMeanProbability": thresholds[1],
                       "minTargetProbability": args.min_target_probability},
        "limitedRun": args.limit is not None, "limitEligibleInks": args.limit,
        "elapsedSeconds": round(time.monotonic() - started, 1),
        "candidateInks": {split: candidates[split] for split in ("train", "valid")},
        "acceptedInks": {split: accepted[split] for split in ("train", "valid")},
        "acceptanceRate": {split: accepted[split] / candidates[split] if candidates[split] else 0.0
                           for split in ("train", "valid")},
        "unassignableInks": {split: candidates[f"{split}_unalignable"] for split in ("train", "valid")},
        "confidenceRejectedInks": {split: candidates[f"{split}_rejected_confidence"] for split in ("train", "valid")},
        "perClass": per_class_counts,
        "labelCounts": {split: {label: accepted_symbols[(split, label)]
                                for _split, label in sorted(accepted_symbols) if _split == split}
                        for split in ("train", "valid")},
        "groupCapsByClass": caps,
        "contactSheet": str(contact_path), "contactSheetIndex": str(index_path),
        "contactSheetSymbols": len(reservoir),
    })
    print(json.dumps({"eligibleInks": sum(candidates[split] for split in ("train", "valid")),
                      "acceptedInks": dict(accepted), "acceptedSymbols": seen_symbols,
                      "symbolsByLabel": {split: {label: accepted_symbols[(split, label)]
                                                 for _split, label in sorted(accepted_symbols) if _split == split}
                                         for split in ("train", "valid")},
                      "acceptanceRate": {split: accepted[split] / candidates[split] if candidates[split] else 0.0
                                         for split in ("train", "valid")},
                      "contactSheetSymbols": len(reservoir),
                      "elapsedSeconds": round(time.monotonic() - started, 1),
                      "summary": str(report_path)}, sort_keys=True), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD)
    parser.add_argument("--mw-archive", type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--vocab", type=Path, default=ROOT / "Sources/CanvasKit/Resources/math-vocab.json")
    parser.add_argument("--temperature", type=float, required=True,
                        help="F2 temperature fit by NLL on validation")
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--limit", type=int,
                        help="smoke mode: stop after this many eligible train/valid inks")
    parser.add_argument("--progress-every", type=int, default=500,
                        help="emit a progress JSON row every N eligible inks")
    parser.add_argument("--min-symbol-probability", type=float, default=DEFAULT_MIN_SYMBOL_P)
    parser.add_argument("--min-mean-probability", type=float, default=DEFAULT_MIN_MEAN_P)
    parser.add_argument("--only-labels",
                        help="harvest only these comma-separated vocab labels, for example q,l; "
                             "q and l are treated as known while filtering candidates and \\ell maps to l")
    parser.add_argument("--tag",
                        help="override the output tag (default mw-harvest, or mw-harvest-ql with "
                             "--only-labels); use mw-harvest-brace for a brace harvest")
    parser.add_argument("--min-target-probability", type=float, default=DEFAULT_MIN_TARGET_P,
                        help="per-symbol floor for --only-labels targets, whose strokes are pinned by alignment")
    parser.add_argument("--contact-sheet-samples", type=int,
                        help="contact sheet sample count (default 200 with --only-labels, else 400)")
    parser.add_argument("--strict", action="store_true",
                        help="QA redo thresholds: per-symbol >=.5 and geometric mean >=.8")
    args = parser.parse_args()
    if args.only_labels is not None:
        args.only_labels = tuple(label.strip() for label in args.only_labels.split(",") if label.strip())
        if not args.only_labels:
            parser.error("--only-labels needs at least one label")
    if not 0 < args.min_target_probability <= 1:
        parser.error("--min-target-probability must be in (0, 1]")
    if args.contact_sheet_samples is not None and args.contact_sheet_samples < 1:
        parser.error("--contact-sheet-samples must be positive")
    if args.strict and args.only_labels:
        parser.error("--strict and --only-labels are alternative acceptance policies")
    if not math.isfinite(args.temperature) or args.temperature <= 0:
        parser.error("--temperature must be finite and positive")
    if not 0 < args.min_symbol_probability <= 1 or not 0 < args.min_mean_probability <= 1:
        parser.error("probability thresholds must be in (0, 1]")
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    if args.progress_every < 1:
        parser.error("--progress-every must be positive")
    harvest(args)


if __name__ == "__main__":
    main()
