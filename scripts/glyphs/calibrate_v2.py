#!/usr/bin/env python3
"""Calibrate the shipped math decoder on validation, then consume final test once."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
from functools import lru_cache
import io
import json
import math
from pathlib import Path
import time
import zipfile
import xml.etree.ElementTree as ET

import numpy as np
import torch

import datasets
from decoder import MathLineDecoder, Symbol
from linearize import linearize
from lm import LanguageModel, strip_math_delimiters
from resolver import member_weights
from sequence import encode
import train_v2
from logit_normalization import normalize_logits


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
OUT = BUILD / "glyph-training-v2"
ARCHIVE = BUILD / "datasets/Task1_and_Task2.zip"
VOCAB = ROOT / "Sources/CanvasKit/Resources/math-vocab.json"
LM = ROOT / "Sources/CanvasKit/Resources/MathLM.json"
LM_SHA256 = "71376749b22abc6305f43220a24e395f3d0f82e7e6e5037701176c784ca9c917"
LAMBDAS = tuple(round(value / 5, 1) for value in range(1, 7))
TAUS = tuple(round(value / 200, 3) for value in range(0, 201))


def _softmax(values: np.ndarray, temperature: float) -> np.ndarray:
    scaled = np.asarray(values, dtype=np.float64) / temperature
    scaled -= scaled.max()
    probs = np.exp(scaled)
    return probs / probs.sum()


def fit_temperature(logits: np.ndarray, targets: np.ndarray) -> float:
    """Minimize validation class NLL with a deterministic golden-section search."""
    logits, targets = np.asarray(logits, dtype=np.float64), np.asarray(targets, dtype=np.int64)
    if logits.ndim != 2 or len(logits) != len(targets) or not len(targets):
        raise ValueError("temperature fitting needs a nonempty [records, classes] validation set")
    if not np.isfinite(logits).all() or np.any(targets < 0) or np.any(targets >= logits.shape[1]):
        raise ValueError("invalid validation logits or targets")

    def nll(log_temperature: float) -> float:
        scaled = logits / math.exp(log_temperature)
        maximum = scaled.max(axis=1)
        return float(np.mean(maximum + np.log(np.exp(scaled - maximum[:, None]).sum(axis=1))
                             - scaled[np.arange(len(targets)), targets]))

    low, high = -3.0, 3.0
    ratio = (math.sqrt(5.0) - 1.0) / 2.0
    left, right = high - ratio * (high - low), low + ratio * (high - low)
    for _ in range(80):
        if nll(left) <= nll(right):
            high, right = right, left
            left = high - ratio * (high - low)
        else:
            low, left = left, right
            right = low + ratio * (high - low)
    return math.exp((low + high) / 2)


def _truth(root: ET.Element) -> str:
    return datasets._annotation(root, "truth") or ""


def _stroke_bounds(strokes: list) -> tuple[float, float, float, float]:
    points = np.concatenate([np.asarray(stroke, dtype=np.float64)[:, :2]
                             for stroke in strokes if stroke], axis=0)
    low, high = points.min(axis=0), points.max(axis=0)
    return float(low[0]), float(low[1]), float(high[0] - low[0]), float(high[1] - low[1])


def _formulas(archive_path: Path, split: str, vocab_path: Path = VOCAB,
              limit: int | None = None) -> list[dict]:
    """Read only formula Train.zip for validation, or valid.zip for final TEST-C."""
    suffix = ("/Task1_onlineRec/MainTask_formula/Train.zip" if split == "valid"
              else "/Task1_onlineRec/MainTask_formula/valid.zip")
    labels = set(train_v2.label_maps(vocab_path)[2])
    with zipfile.ZipFile(archive_path) as outer:
        names = [name for name in outer.namelist() if name.endswith(suffix)]
        if len(names) != 1:
            raise ValueError(f"expected one CROHME member ending {suffix!r}, found {names}")
        with zipfile.ZipFile(io.BytesIO(outer.read(names[0]))) as formulas:
            lines = []
            for name in sorted(formulas.namelist()):
                if not name.lower().endswith(".inkml"):
                    continue
                with formulas.open(name) as stream:
                    root = ET.parse(stream).getroot()
                if split == "valid":
                    writer = datasets._writer(root, name)
                    if datasets._writer_split(writer) != "valid":
                        continue
                source = strip_math_delimiters(_truth(root))
                _, has_frac, _ = linearize(source)
                if has_frac:
                    continue
                traces, order = datasets._inkml(root)
                traces = dict(zip(order, datasets._fill_times([traces[key] for key in order])))
                entries = []
                excluded = 0
                for index, group in enumerate(datasets._leaf_groups(root)):
                    raw_label = datasets._truth(group)
                    if datasets.is_function_word(raw_label):
                        excluded += 1
                        continue
                    label = datasets.extended_label(raw_label, labels) or "<unk>"
                    strokes = datasets._ordered_group_strokes(group, traces, order)
                    first_time = (min(float(stroke[0][2]) for stroke in strokes if stroke)
                                  if strokes else math.inf)
                    entries.append({"label": label, "strokes": strokes,
                                    "bounds": _stroke_bounds(strokes) if strokes else (0, 0, 0, 0),
                                    "firstTime": first_time,
                                    "order": index})
                if not entries and not excluded:
                    continue
                entries.sort(key=lambda item: (item["firstTime"], item["order"]))
                lines.append({"id": Path(name).stem, "symbols": entries,
                              "excludedFunctionWordSymbols": excluded})
                if limit is not None and len(lines) >= limit:
                    break
            return lines


def _inputs(strokes: list) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    paths = train_v2.stroke_points(strokes)
    encoded = encode(paths)
    if encoded is None:
        raise ValueError("empty or invalid validation/test symbol ink")
    image = train_v2.vectorized_raster(paths).astype(np.float32)[None, None]
    sequence = np.asarray(encoded["strokePoints"], dtype=np.float32)[None]
    globals_ = train_v2.stroke_globals(paths)[None]
    return (torch.from_numpy(image), torch.from_numpy(sequence), torch.from_numpy(globals_))


def _predict(model, lines: list[dict]) -> None:
    model.eval()
    with torch.no_grad():
        for line in lines:
            for item in line["symbols"]:
                if not item["strokes"]:
                    item["logits"] = None
                    continue
                image, path, globals_ = _inputs(item["strokes"])
                item["logits"] = model(image, path, globals_)[0][0].numpy()


def _cache_class_probs(lines: list[dict], temperature: float) -> None:
    for line in lines:
        for item in line["symbols"]:
            item["classProbabilities"] = (None if item["logits"] is None else
                                          _softmax(item["logits"], temperature))


def _cache_validation_logits(model, output: Path) -> tuple[np.ndarray, np.ndarray]:
    arrays = {key: np.load(train_v2._cache_paths(output, "valid")[key], mmap_mode="r")
              for key in ("images", "paths", "globals", "targets")}
    logits, targets = [], np.asarray(arrays["targets"], dtype=np.int64)
    model.eval()
    with torch.no_grad():
        for start in range(0, len(targets), 512):
            end = min(start + 512, len(targets))
            images = torch.from_numpy(np.array(arrays["images"][start:end], dtype=np.float32, copy=True).reshape(-1, 1, 32, 32))
            paths = torch.from_numpy(np.array(arrays["paths"][start:end], dtype=np.float32, copy=True))
            globals_ = torch.from_numpy(np.array(arrays["globals"][start:end], dtype=np.float32, copy=True))
            logits.append(model(images, paths, globals_)[0].numpy())
    return np.concatenate(logits), targets


def _row_entries(row: dict, symbols: list[dict], displayed: list[str | None], roles: list[str],
                 kinds: dict[str, str], resolver: bool) -> list[tuple[float, float]]:
    entries = list(row["resolverSeed"] if resolver else row["lineSeed"])
    for node in row["items"]:
        if (not isinstance(node, int) or node >= len(displayed) or
                node in row.get("seededItems", ())):
            continue
        label = displayed[node]
        kind = kinds.get(label or "", "")
        allowed = (kind in ("digit", "upper") if resolver else
                   kind in ("digit", "lower", "upper", "function"))
        height = symbols[node]["bounds"][3]
        if label and roles[node] == "body" and allowed and height > 0:
            _, y, _, _ = symbols[node]["bounds"]
            entries.append((height, y + height))
    return entries[-8:]


def _row_context(row: dict, symbols: list[dict], displayed: list[str | None], roles: list[str],
                 kinds: dict[str, str]) -> dict:
    entries = _row_entries(row, symbols, displayed, roles, kinds, True)
    if not entries:
        return {"mode": "math"}
    heights, bottoms = sorted(item[0] for item in entries), sorted(item[1] for item in entries)
    return {"mode": "math", "count": len(entries), "medianHeight": heights[len(heights) // 2],
            "baseline": bottoms[len(bottoms) // 2]}


def _row_metrics(row: dict, symbols: list[dict], displayed: list[str | None], roles: list[str],
                 kinds: dict[str, str]) -> tuple[float, float]:
    entries = _row_entries(row, symbols, displayed, roles, kinds, False)
    if len(entries) < 2:
        return .4 * row["cellHeight"], row["cellTop"] + .7 * row["cellHeight"]
    heights, bottoms = sorted(item[0] for item in entries), sorted(item[1] for item in entries)
    return heights[len(heights) // 2], bottoms[len(bottoms) // 2]


def _child_row(parent: dict, symbols: list[dict], displayed: list[str | None], roles: list[str],
               kinds: dict[str, str], items: list, numerator: bool) -> dict:
    height, baseline = _row_metrics(parent, symbols, displayed, roles, kinds)
    target = baseline - .8 * height if numerator else baseline + .6 * height
    resolver_seed = _row_entries(parent, symbols, displayed, roles, kinds, True)
    line_seed = _row_entries(parent, symbols, displayed, roles, kinds, False)
    seeded_items = {node for node in parent["items"] if isinstance(node, int)}
    return {"items": items, "cellHeight": .8 * parent["cellHeight"],
            "cellTop": target - .7 * (.8 * parent["cellHeight"]),
            "depth": parent["depth"] + 1,
            "seededItems": seeded_items,
            "resolverSeed": [(h * .8, target + (b - baseline) * .8) for h, b in resolver_seed],
            "lineSeed": [(h * .8, target + (b - baseline) * .8) for h, b in line_seed]}


def _operand_start(row: dict, structural: list[str | None], roles: list[str], before: int) -> int:
    separators = {"+", "−", "=", "≠", "<", ">", "≤", "≥", "±", "÷", "·"}
    start = before
    depth = 0
    while start > 0:
        node = row["items"][start - 1]
        label = structural[node] if isinstance(node, int) else None
        if depth == 0 and isinstance(node, int) and roles[node] == "body" and label in separators:
            break
        if label == ")":
            depth += 1
        elif label == "(":
            if depth == 0:
                break
            depth -= 1
        start -= 1
    return start


def _strip_outer_parentheses(nodes: list, structural: list[str | None]) -> tuple[list, list[int]]:
    if (len(nodes) < 2 or not isinstance(nodes[0], int) or not isinstance(nodes[-1], int) or
            structural[nodes[0]] != "(" or structural[nodes[-1]] != ")"):
        return nodes, []
    depth = 0
    for offset, node in enumerate(nodes):
        if not isinstance(node, int):
            continue
        if structural[node] == "(":
            depth += 1
        elif structural[node] == ")":
            depth -= 1
            if depth == 0:
                if offset == len(nodes) - 1:
                    return nodes[1:-1], [nodes[0], nodes[-1]]
                return nodes, []
    return nodes, []


def _role(item: dict, label: str, context: dict, kind_by_label: dict[str, str]) -> str:
    if context.get("count", 0) < 2:
        return "body"
    kind = kind_by_label.get(label, "")
    if kind in ("low", "raised", "junk") or label in ("°", "·", "′", ".", ","):
        return "body"
    _, y, width, height = item["bounds"]
    h = context["medianHeight"]
    raised = (context["baseline"] - (y + height / 2)) / h
    size = max(width, height) / h
    if (kind in ("digit", "lower") or label in "πθΔ∞()") and size <= .70:
        if raised >= .80:
            return "superscript"
        if raised <= .15:
            return "subscript"
    if label in ("+", "−") and size <= .60 and raised >= .80:
        return "superscript"
    return "body"


def _likelihoods(item: dict, temperature: float, context: dict,
                 class_ids: list[str], labels_by_class: dict[str, list[str]],
                 class_index: dict[str, int], label_order: dict[str, int]) -> dict[str, float]:
    if item["classProbabilities"] is None:
        return {"<unk>": 1.0}
    probs = item["classProbabilities"]
    scores: dict[str, float] = {}
    for class_id in class_ids:
        weights = member_weights(class_id, item["bounds"], context)
        probability = float(probs[class_index[class_id]])
        for label in labels_by_class[class_id]:
            scores[label] = probability * weights.get(label, 0.0)
    ranked = sorted(((label, value) for label, value in scores.items() if value > 0),
                    key=lambda pair: (-pair[1], label_order[pair[0]]))[:5]
    total = sum(value for _, value in ranked)
    return {label: value / total for label, value in ranked}


def _decoder_cache(lm: LanguageModel, lambda_: float):
    @lru_cache(maxsize=8192)
    def decode(signature: tuple, newest: int, revisions: tuple[int, ...]):
        symbols = [Symbol(dict(likelihoods), displayed, virtual, pinned)
                   for likelihoods, displayed, virtual, pinned in signature]
        raw = MathLineDecoder(lm.log_prob, lambda_, 0.0, 0.0).decode(
            symbols, newest_index=newest, revision_indices=revisions)
        indexes = sorted({newest, *revisions})
        return (raw.substitution, raw.revisions,
                tuple((index, raw.marginals[index]) for index in indexes))

    def cached(symbols: list[Symbol], newest: int, revisions: list[int]):
        signature = tuple((tuple(sorted((key, float(value)) for key, value in symbol.label_likelihoods.items())),
                           symbol.displayed_label, symbol.is_virtual, symbol.is_pinned)
                          for symbol in symbols)
        return decode(signature, newest, tuple(revisions))

    cached.cache_info = decode.cache_info
    return cached


def simulate(lines: list[dict], lm: LanguageModel, temperature: float, lambda_: float,
             tau_sub: float | dict[str, float], tau_rev: float, disabled: set[str], vocab: dict,
             class_ids: list[str], cell_height: float = 32.0, decode_cached=None,
             collect_candidates: bool = False, tau_fill: float | None = None,
             commit_floor: float | None = 0.5) -> dict:
    # tau_fill gates revisions of ink (ink -> glyph); tau_rev keeps gating glyph -> glyph.
    fill_threshold = tau_rev if tau_fill is None else tau_fill
    labels_by_class = {cls["id"]: cls["labels"] for cls in vocab["classes"]}
    class_index = {value: index for index, value in enumerate(class_ids)}
    label_order = {label: index for index, label in enumerate(label for cls in vocab["classes"] for label in cls["labels"])}
    kind_by_label = {row["label"]: row["kind"] for row in vocab["labels"]}
    decode_cached = decode_cached or _decoder_cache(lm, lambda_)
    substituted = update_correct = final_correct = covered = total = harmful = swaps = unknown = 0
    isolated_correct = isolated_total = isolated_unknown = 0
    tau_lower, tau_upper = -1.0, 1.0
    per_label: dict[str, list[int]] = {}
    candidate_rows = []
    unknown_wrong_updates = 0
    known_covered = unknown_covered = unknown_wrong_final = 0
    by_path: dict[str, list[int]] = {}
    by_truth: dict[str, list[int]] = {}
    for line in lines:
        entries = line["symbols"]
        root = {"items": [], "cellHeight": cell_height, "cellTop":
                (entries[0]["bounds"][1] - .3 * cell_height if entries else 0.0),
                "depth": 0, "resolverSeed": [], "lineSeed": []}
        active = root
        likelihoods: list[dict[str, float]] = []
        displayed: list[str | None] = []
        roles: list[str] = []
        structural: list[str | None] = []
        wide: list[bool] = []
        fraction_slash: list[bool] = []
        paths: list[str | None] = []
        archived: set[int] = set()
        hidden: set[int] = set()
        source_total = source_unknown = 0
        for index, item in enumerate(entries):
            active["items"].append(index)
            fraction_slash.append(False)
            context = _row_context(active, entries, displayed, roles, kind_by_label)
            line_heights = _row_entries(active, entries, displayed, roles, kind_by_label, False)
            normal_height = (context.get("medianHeight") or
                             (sorted(h for h, _ in line_heights)[len(line_heights) // 2]
                              if line_heights else max(item["bounds"][3], .4 * active["cellHeight"])))
            is_wide = len(item["strokes"]) > 1 and item["bounds"][2] > 1.6 * normal_height
            wide.append(is_wide)
            likelihoods.append(_likelihoods(item, temperature, context, class_ids,
                                            labels_by_class, class_index, label_order))
            flat, source_indices = [], {}

            def virtual(label: str) -> None:
                flat.append(Symbol({label: 1.0}, displayed_label=label,
                                  is_virtual=True, is_pinned=True))

            def flatten(row: dict) -> None:
                for node in row["items"]:
                    if isinstance(node, int):
                        if node in hidden or node in archived:
                            continue
                        source_indices[node] = len(flat)
                        shown = displayed[node] if node < len(displayed) else None
                        flat.append(Symbol(likelihoods[node], displayed_label=shown))
                        continue
                    numerator, denominator = node["numerator"], node["denominator"]
                    num_flat, den_flat = [], []
                    saved = flat[:]
                    flatten(numerator)
                    num_flat = flat[len(saved):]
                    del flat[len(saved):]
                    saved = flat[:]
                    flatten(denominator)
                    den_flat = flat[len(saved):]
                    del flat[len(saved):]
                    if not num_flat and not den_flat:
                        continue
                    if len(num_flat) > 1:
                        virtual("(")
                    flatten(numerator)
                    if len(num_flat) > 1:
                        virtual(")")
                    virtual("/")
                    if len(den_flat) > 1:
                        virtual("(")
                    flatten(denominator)
                    if len(den_flat) > 1:
                        virtual(")")

            flatten(root)
            newest_index = source_indices[index]
            eligible = [prior for prior in range(index - 1, -1, -1)
                        if prior in source_indices and not fraction_slash[prior]
                        and not wide[prior] and prior not in archived]
            revision_indices = [source_indices[prior] for prior in eligible[:2]]
            raw_substitution, raw_revisions, marginal_rows = decode_cached(
                flat, newest_index, revision_indices)
            threshold = (tau_sub.get(raw_substitution.label, 1.0000000000000002)
                         if isinstance(tau_sub, dict) and raw_substitution else
                         1.0000000000000002 if isinstance(tau_sub, dict) else tau_sub)
            if (collect_candidates and raw_substitution and not is_wide and
                    raw_substitution.label in label_order):
                candidate_rows.append({"label": raw_substitution.label,
                                       "score": raw_substitution.marginal,
                                       "truth": item["label"]})
            if raw_substitution and raw_substitution.label not in disabled and not is_wide:
                probability = raw_substitution.marginal
                if probability >= threshold:
                    tau_upper = min(tau_upper, probability)
                else:
                    tau_lower = max(tau_lower, probability)
            marginals = dict(marginal_rows)
            substitution = (raw_substitution if raw_substitution and
                            raw_substitution.label not in disabled and
                            raw_substitution.marginal >= threshold else None)
            revisions = tuple(update for update in raw_revisions
                              if update.label not in disabled and
                              update.marginal >= min(tau_rev, fill_threshold) and
                              (not isinstance(tau_sub, dict) or
                               update.marginal >= tau_sub.get(update.label, 1.0000000000000002)))
            for prior, token_index in source_indices.items():
                if prior == index:
                    continue
                for update in revisions:
                    if update.index == token_index:
                        old = displayed[prior]
                        if update.marginal < (fill_threshold if old is None else tau_rev):
                            continue
                        if update.label != old:
                            paths[prior] = "fill" if old is None else "correction"
                        swaps += 1
                        harmful += old == entries[prior]["label"] and update.label != old
                        unknown_wrong_updates += entries[prior]["label"] == "<unk>"
                        displayed[prior] = update.label
                        structural[prior] = update.label
            truth = item["label"]
            guess = min(marginals[newest_index].items(), key=lambda pair: (-pair[1], pair[0]))[0]
            pre_lm_guess = max(likelihoods[index], key=likelihoods[index].get)
            if truth == "<unk>":
                isolated_unknown += 1
            else:
                isolated_total += 1
                isolated_correct += pre_lm_guess == truth
            posterior = marginals[newest_index].get("/", 0.0)
            current_display = substitution.label if substitution and not is_wide else None
            path = "substitution" if current_display is not None else None
            # Match CanvasView.mathCommitLabel: disabled labels still commit at >= 0.5.
            if (current_display is None and not is_wide and guess != "<unk>" and
                    commit_floor is not None and marginals[newest_index][guess] >= commit_floor):
                current_display, path = guess, "commit"
            if current_display is not None:
                substituted += 1
                update_correct += current_display == truth
                unknown_wrong_updates += truth == "<unk>"
            displayed.append(current_display)
            paths.append(path)
            best_label = guess
            structural.append(current_display or best_label or pre_lm_guess)
            roles.append(_role(item, structural[-1], context, kind_by_label))
            source_total += 1
            source_unknown += truth == "<unk>"
            slash_posterior = (substitution.marginal if current_display == "/"
                               and substitution else posterior if guess == "/" else 0.0)
            slash_threshold = (tau_sub.get("/", 1.0000000000000002)
                               if isinstance(tau_sub, dict) else tau_sub)
            if ((guess == "/" or current_display == "/") and
                    slash_posterior >= (slash_threshold if current_display == "/" and substitution else .5)
                    and active["depth"] < 2):
                slash_pos = len(active["items"]) - 1
                start = _operand_start(active, structural, roles, slash_pos)
                selected_nodes = active["items"][start:slash_pos]
                numerator_nodes, removed = _strip_outer_parentheses(selected_nodes, structural)
                archived.update(removed)
                hidden.update(removed)
                fraction = {"numerator": _child_row(active, entries, displayed, roles, kind_by_label,
                                                     numerator_nodes, True),
                            "denominator": _child_row(active, entries, displayed, roles, kind_by_label,
                                                       [], False)}
                active["items"][start:] = [fraction]
                fraction_slash[index] = True
                active = fraction["numerator"] if not numerator_nodes else fraction["denominator"]
        total += source_total
        unknown += source_unknown
        # Keep every source symbol in the metrics, including archived parentheses/slashes.
        for index, (item, shown) in enumerate(zip(entries, displayed)):
            if fraction_slash[index]:
                shown = "/"
            truth_counts = by_truth.setdefault(item["label"], [0, 0])
            truth_counts[0] += int(shown == item["label"])
            truth_counts[1] += 1
            if shown is not None:
                covered += 1
                final_correct += shown == item["label"]
                path = by_path.setdefault("fraction" if fraction_slash[index] else paths[index], [0, 0])
                path[0] += int(shown == item["label"])
                path[1] += 1
                if item["label"] == "<unk>":
                    unknown_covered += 1
                    unknown_wrong_final += shown != item["label"]
                else:
                    known_covered += 1
                counts = per_label.setdefault(shown, [0, 0])
                counts[0] += int(shown == item["label"])
                counts[1] += 1
    known_total = total - unknown
    result = {"symbols": total, "unknownSymbols": int(unknown),
            "excludedFunctionWordSymbols": sum(line.get("excludedFunctionWordSymbols", 0)
                                                for line in lines),
            "knownSymbols": int(known_total), "substitutions": substituted,
            "coverage": covered / max(1, total),
            "coverageAllSymbols": covered / max(1, total),
            "coverageRecognizableSymbols": known_covered / max(1, known_total),
            "knownCovered": known_covered, "unknownCovered": unknown_covered,
            "correctCoverageAllSymbols": final_correct / max(1, total),
            "substitutionPrecision": final_correct / covered if covered else 1.0,
            "correctUpdates": int(update_correct),
            "updatePrecision": update_correct / substituted if substituted else 1.0,
            "harmfulSwaps": int(harmful), "revisions": swaps,
            "harmfulSwapsPer100": 100 * harmful / max(1, total),
            "isolatedLabelAccuracy": isolated_correct / max(1, isolated_total),
            "isolatedCorrect": int(isolated_correct),
            "tauSubInterval": {"lowerExclusive": tau_lower, "upperInclusive": tau_upper},
            "isolatedSymbols": isolated_total, "isolatedUnknownSymbols": isolated_unknown,
            "perLabelSubstitutions": {label: {"correct": row[0], "count": row[1],
                                              "precision": row[0] / row[1]}
                                      for label, row in sorted(per_label.items())},
            "perLabelAccuracy": {label: {"correct": row[0], "count": row[1],
                                          "accuracy": row[0] / row[1]}
                                 for label, row in sorted(by_truth.items())},
            "unknownTruthWrongUpdates": int(unknown_wrong_updates),
            "unknownWrongFinal": int(unknown_wrong_final),
            "finalByPath": {name: {"correct": row[0], "count": row[1], "precision": row[0] / row[1]}
                            for name, row in sorted(by_path.items())}}
    if collect_candidates:
        result["_candidateSubstitutions"] = candidate_rows
    return result


def _sequence_evaluator(lines, lm, temperature, lambda_, vocab, class_ids, decode_cached,
                        commit_floor=0.5):
    # ponytail: cache exact decision intervals per expression; clear at each lambda.
    @lru_cache(maxsize=65536)
    def ranges(index, context):
        return []
    counters = ("symbols", "unknownSymbols", "substitutions", "correctUpdates",
                "harmfulSwaps", "revisions", "isolatedCorrect", "isolatedSymbols",
                "isolatedUnknownSymbols", "knownCovered", "unknownCovered",
                "unknownTruthWrongUpdates", "unknownWrongFinal", "excludedFunctionWordSymbols")
    stats = {"hits": 0, "misses": 0}

    def evaluate(tau_sub, tau_rev, disabled, tau_fill=None):
        totals, per_label, by_path, by_truth = Counter({key: 0 for key in counters}), {}, {}, {}
        context = (tau_rev, tuple(sorted(disabled)), tau_rev if tau_fill is None else tau_fill)
        for index, line in enumerate(lines):
            intervals = ranges(index, context)
            result = next((row for row in intervals
                           if row["tauSubInterval"]["lowerExclusive"] < tau_sub
                           <= row["tauSubInterval"]["upperInclusive"]), None)
            if result is None:
                result = simulate([line], lm, temperature, lambda_, tau_sub, tau_rev,
                                  disabled, vocab, class_ids, decode_cached=decode_cached,
                                  tau_fill=tau_fill, commit_floor=commit_floor)
                intervals[:] = [result]
                stats["misses"] += 1
            else:
                stats["hits"] += 1
            totals.update({key: result[key] for key in counters})
            for label, counts in result["perLabelSubstitutions"].items():
                row = per_label.setdefault(label, Counter())
                row.update({key: counts[key] for key in ("correct", "count")})
            for label, counts in result["perLabelAccuracy"].items():
                by_truth.setdefault(label, Counter()).update(
                    {key: counts[key] for key in ("correct", "count")})
            for name, counts in result["finalByPath"].items():
                by_path.setdefault(name, Counter()).update(
                    {key: counts[key] for key in ("correct", "count")})
        covered = sum(row["count"] for row in per_label.values())
        correct = sum(row["correct"] for row in per_label.values())
        return {**totals, "coverage": covered / max(1, totals["symbols"]),
                "knownSymbols": totals["symbols"] - totals["unknownSymbols"],
                "coverageAllSymbols": covered / max(1, totals["symbols"]),
                "coverageRecognizableSymbols": totals["knownCovered"] /
                    max(1, totals["symbols"] - totals["unknownSymbols"]),
                "correctCoverageAllSymbols": correct / max(1, totals["symbols"]),
                "substitutionPrecision": correct / covered if covered else 1.0,
                "updatePrecision": totals["correctUpdates"] / totals["substitutions"]
                    if totals["substitutions"] else 1.0,
                "harmfulSwapsPer100": 100 * totals["harmfulSwaps"] / max(1, totals["symbols"]),
                "isolatedLabelAccuracy": totals["isolatedCorrect"] / max(1, totals["isolatedSymbols"]),
                "perLabelSubstitutions": {label: {**row, "precision": row["correct"] / row["count"]}
                                          for label, row in sorted(per_label.items())},
                "perLabelAccuracy": {label: {**row, "accuracy": row["correct"] / row["count"]}
                                     for label, row in sorted(by_truth.items())},
                "finalByPath": {name: {**row, "precision": row["correct"] / row["count"]}
                                for name, row in sorted(by_path.items())}}

    evaluate.cache_stats = stats
    return evaluate


def _calibration_setting(evaluate):
    tau_rev, disabled = .90, set()
    result = evaluate(tau_rev, disabled)
    while True:
        if result["harmfulSwapsPer100"] > .5 and tau_rev < 1.0:
            tau_rev = round(min(1.0, tau_rev + .02), 2)
        else:
            unreliable = {label for label, counts in result["perLabelSubstitutions"].items()
                          if counts["count"] >= 30 and counts["precision"] < .95} - disabled
            if not unreliable:
                return result, tau_rev, sorted(disabled)
            disabled.update(unreliable)
        result = evaluate(tau_rev, disabled)


def _validation_temperature_rows(lines: list[dict], selected_ids: set[str],
                                class_ids: list[str], vocab: dict,
                                normalized: bool = False) -> tuple[np.ndarray, np.ndarray]:
    class_by_label = {label: cls["id"] for cls in vocab["classes"] for label in cls["labels"]}
    indexes = {class_id: index for index, class_id in enumerate(class_ids)}
    rows, targets = [], []
    for line in lines:
        if line["id"] not in selected_ids:
            continue
        for item in line["symbols"]:
            class_id = class_by_label.get(item["label"])
            if class_id is None or item["logits"] is None:
                continue
            logits = np.asarray(item["logits"], dtype=np.float64)
            if normalized:
                logits = normalize_logits(logits)
            rows.append(logits)
            targets.append(indexes[class_id])
    return np.asarray(rows), np.asarray(targets, dtype=np.int64)


def _fit_thresholds(candidates: list[dict], target_precision: float,
                    minimum_support: int, per_label: bool,
                    labels: list[str] = ()) -> tuple[float | dict[str, float], dict]:
    grouped = {}
    for row in candidates:
        key = row["label"] if per_label else "*"
        grouped.setdefault(key, []).append(row)
    thresholds, details = {}, {}
    keys = set(grouped) | (set(labels) if per_label else set())
    for label in sorted(keys):
        rows = grouped.get(label, [])
        support = len(rows)
        chosen, accepted, correct = 1.0000000000000002, 0, 0
        # ponytail: one descending pass; tied confidence values enter together.
        count = hits = 0
        ordered = sorted(rows, key=lambda row: -row["score"])
        position = 0
        while position < len(ordered):
            threshold = ordered[position]["score"]
            end = position + 1
            while end < len(ordered) and ordered[end]["score"] == threshold:
                end += 1
            tied = ordered[position:end]
            count += len(tied)
            hits += sum(row["label"] == row["truth"] for row in tied)
            if count >= minimum_support and hits / count >= target_precision:
                chosen, accepted, correct = threshold, count, hits
            position = end
        thresholds[label] = chosen
        details[label] = {"threshold": chosen, "candidateSupport": support,
                          "acceptedSupport": accepted, "correct": correct,
                          "empiricalPrecision": correct / accepted if accepted else None,
                          "minimumSupport": minimum_support}
    if not per_label:
        return thresholds.get("*", 1.0000000000000002), details.get("*", {})
    return thresholds, details


def _selective_setup(args: argparse.Namespace):
    """Shared validation-only setup: checkpoint, expressions, selection/gate split, decoder."""
    if (not math.isfinite(args.target_precision) or not 0 < args.target_precision <= 1 or
            args.minimum_support < 1 or not math.isfinite(args.lambda_) or
            not .2 <= args.lambda_ <= 1.2):
        raise ValueError("invalid threshold target, minimum support, or lambda")
    torch.set_num_threads(4)
    lm_bytes = args.language_model.read_bytes()
    if hashlib.sha256(lm_bytes).hexdigest() != LM_SHA256:
        raise ValueError("language model SHA-256 does not match the shipped function-word LM")
    lines = _formulas(args.archive, "valid", args.vocab)
    if len(lines) < 2:
        raise ValueError("selective validation needs at least two validation expressions")
    checkpoint_path = args.checkpoint or args.output / "best.pt"
    checkpoint_hash = train_v2.digest(checkpoint_path)
    prior = json.loads((args.output / "calibration-search-summary.json").read_text())
    if prior.get("checkpointSHA256") != checkpoint_hash:
        raise ValueError("saved calibration-search summary belongs to a different checkpoint")
    model, saved, class_ids = train_v2._checkpoint(argparse.Namespace(
        output=args.output, checkpoint=args.checkpoint, vocab=args.vocab))
    train_v2._verify_checkpoint_sources(saved, args.build_dir, args.vocab)
    _predict(model, lines)
    vocab = json.loads(args.vocab.read_text())
    ordered = sorted(lines, key=lambda line: hashlib.sha256(line["id"].encode()).digest())
    selection_ids = {line["id"] for line in ordered[::2]}
    gate_ids = {line["id"] for line in ordered[1::2]}
    selection = [line for line in lines if line["id"] in selection_ids]
    gate = [line for line in lines if line["id"] in gate_ids]
    lm_data = json.loads(lm_bytes)
    lm = LanguageModel(lm_data["vocab"], lm_data["ngrams"])
    lm.log_prob = lru_cache(maxsize=131072)(lm.log_prob)
    decoder = _decoder_cache(lm, args.lambda_)
    prior_baseline = next((row for row in prior["lambdaResults"]
                           if math.isclose(row["lambda"], args.lambda_)), None)
    if prior_baseline is None:
        raise ValueError(f"no saved calibration-search baseline for lambda={args.lambda_}")
    return (lines, selection, gate, selection_ids, gate_ids, lm_bytes, lm, decoder, vocab,
            class_ids, checkpoint_hash, saved, prior_baseline, float(prior["temperature"]))


def _raw_thresholds(lines, selection, selection_ids, lm, decoder, vocab, class_ids, args):
    raw_logits, raw_targets = _validation_temperature_rows(lines, selection_ids, class_ids, vocab)
    raw_temperature = fit_temperature(raw_logits, raw_targets)
    _cache_class_probs(lines, raw_temperature)
    raw_candidates = simulate(selection, lm, raw_temperature, args.lambda_, 0.0, .90,
                              set(), vocab, class_ids, decode_cached=decoder,
                              collect_candidates=True)["_candidateSubstitutions"]
    global_tau, global_support = _fit_thresholds(raw_candidates, args.target_precision,
                                                  args.minimum_support, False)
    valid_labels = [row["label"] for row in vocab["labels"]]
    raw_thresholds, raw_support = _fit_thresholds(raw_candidates, args.target_precision,
                                                  args.minimum_support, True, valid_labels)
    return raw_temperature, global_tau, global_support, raw_thresholds, raw_support, valid_labels


def selective_validation(args: argparse.Namespace) -> None:
    """Compare global and per-label abstention on held-out validation expressions."""
    (lines, selection, gate, selection_ids, gate_ids, lm_bytes, lm, decoder, vocab, class_ids,
     checkpoint_hash, saved, prior_baseline, prior_temperature) = _selective_setup(args)
    _cache_class_probs(lines, prior_temperature)
    saved_baseline = simulate(gate, lm, prior_temperature, args.lambda_,
                              prior_baseline["tauSub"], prior_baseline["tauRev"],
                              set(prior_baseline["disabledLabels"]), vocab, class_ids,
                              decode_cached=decoder)
    saved_full_validation = simulate(lines, lm, prior_temperature, args.lambda_,
                                     prior_baseline["tauSub"], prior_baseline["tauRev"],
                                     set(prior_baseline["disabledLabels"]), vocab, class_ids,
                                     decode_cached=decoder)
    (raw_temperature, global_tau, global_support, raw_thresholds, raw_support,
     valid_labels) = _raw_thresholds(lines, selection, selection_ids, lm, decoder, vocab,
                                     class_ids, args)
    baseline = simulate(gate, lm, raw_temperature, args.lambda_, global_tau, .90,
                        set(), vocab, class_ids, decode_cached=decoder)
    per_class = simulate(gate, lm, raw_temperature, args.lambda_, raw_thresholds, .90,
                         set(), vocab, class_ids, decode_cached=decoder)

    normalized_logits, normalized_targets = _validation_temperature_rows(
        lines, selection_ids, class_ids, vocab, normalized=True)
    normalized_temperature = fit_temperature(normalized_logits, normalized_targets)
    for line in lines:
        for item in line["symbols"]:
            if item["logits"] is not None:
                item["logits"] = normalize_logits(item["logits"])
    _cache_class_probs(lines, normalized_temperature)
    normalized_candidates = simulate(
        selection, lm, normalized_temperature, args.lambda_, 0.0, .90, set(),
        vocab, class_ids, decode_cached=decoder,
        collect_candidates=True)["_candidateSubstitutions"]
    normalized_thresholds, normalized_support = _fit_thresholds(
        normalized_candidates, args.target_precision, args.minimum_support, True, valid_labels)
    normalized = simulate(gate, lm, normalized_temperature, args.lambda_,
                          normalized_thresholds, .90, set(), vocab, class_ids,
                          decode_cached=decoder)
    report = {"version": 1, "checkpointSHA256": checkpoint_hash,
              "checkpointEpoch": saved["epoch"],
              "mathVocabSHA256": train_v2.digest(args.vocab),
              "mathLMSHA256": hashlib.sha256(lm_bytes).hexdigest(),
              "calibrationScriptSHA256": train_v2.digest(Path(__file__)),
              "logitNormalizationScriptSHA256": train_v2.digest(Path(__file__).with_name("logit_normalization.py")),
              "checkpointAndPriorCalibrationSelectionUsedFullValidation": True,
              "selectionPolicy": {
                  "split": "expressions sorted by SHA-256 id; alternating selection/gate",
                  "selectionExpressions": len(selection), "gateExpressions": len(gate),
                  "selectionSymbols": sum(len(line["symbols"]) for line in selection),
                  "gateSymbols": sum(len(line["symbols"]) for line in gate),
                  "thresholdPrecisionTarget": args.target_precision,
                  "minimumThresholdSupport": args.minimum_support,
                  "selectionAndGateDisjoint": not (selection_ids & gate_ids)},
              "runtimeClaim": "Python decoder simulation only; no Swift/Core ML runtime parity claimed",
              "normalizationNote": "Exploratory normalized-logit softmax adaptation; the paper ranks with max normalized logit, not decoder marginals.",
              "lambda": args.lambda_, "tauRev": .90,
              "experiments": {
                  "savedFullValidationBaseline": {"provenance": "historical F3-second best attempt selected on the full validation set; gate rows are therefore not independent of its tuning",
                                                    "tauSub": prior_baseline["tauSub"],
                                                    "tauRev": prior_baseline["tauRev"],
                                                    "disabledLabels": prior_baseline["disabledLabels"],
                                                    "temperature": prior_temperature,
                                                    "gate": saved_baseline,
                                                    "fullValidation": saved_full_validation},
                  "globalRaw": {"threshold": global_tau, "selectionSupport": global_support,
                                "temperature": raw_temperature, "gate": baseline},
                  "perClassRaw": {"thresholds": raw_support,
                                  "temperature": raw_temperature, "gate": per_class},
                  "perClassNormalized": {"thresholds": normalized_support,
                                         "temperature": normalized_temperature,
                                         "normalizationP": 2.0, "gate": normalized}}
              }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: value["gate"] for key, value in report["experiments"].items()},
                     ensure_ascii=False, sort_keys=True))


FILL_GRID = (.90, .93, .95, .97, .98, .99, .995, .999)


def fill_sweep(args: argparse.Namespace) -> None:
    """Sweep the ink -> glyph revision threshold against final-line precision (validation only)."""
    (lines, selection, gate, selection_ids, gate_ids, lm_bytes, lm, decoder, vocab, class_ids,
     checkpoint_hash, saved, _, _) = _selective_setup(args)
    raw_temperature, global_tau, _, raw_thresholds, _, _ = _raw_thresholds(
        lines, selection, selection_ids, lm, decoder, vocab, class_ids, args)
    keys = ("substitutionPrecision", "coverageAllSymbols", "coverageRecognizableSymbols",
            "harmfulSwapsPer100", "unknownWrongFinal", "finalByPath")
    bases = {}
    for name, tau_sub in (("globalRaw", global_tau), ("perClassRaw", raw_thresholds)):
        rows = []
        for tau_fill in FILL_GRID:
            result = simulate(selection, lm, raw_temperature, args.lambda_, tau_sub, .90, set(),
                              vocab, class_ids, decode_cached=decoder, tau_fill=tau_fill)
            rows.append({"tauFill": tau_fill, "selection": {key: result[key] for key in keys}})
            print(json.dumps({"base": name, **rows[-1]}, sort_keys=True), flush=True)
        # Final-line objective: most coverage whose selection precision meets the target.
        passing = [row for row in rows
                   if row["selection"]["substitutionPrecision"] >= args.target_precision]
        chosen = max(passing, key=lambda row: row["selection"]["coverageAllSymbols"], default=None)
        gate_result = (simulate(gate, lm, raw_temperature, args.lambda_, tau_sub, .90, set(),
                                vocab, class_ids, decode_cached=decoder,
                                tau_fill=chosen["tauFill"]) if chosen else None)
        bases[name] = {"tauSub": tau_sub, "sweep": rows,
                       "chosenTauFill": chosen and chosen["tauFill"], "gate": gate_result}
    report = {"version": 1, "checkpointSHA256": checkpoint_hash, "checkpointEpoch": saved["epoch"],
              "mathLMSHA256": hashlib.sha256(lm_bytes).hexdigest(),
              "calibrationScriptSHA256": train_v2.digest(Path(__file__)),
              "lambda": args.lambda_, "tauRev": .90, "temperature": raw_temperature,
              "targetPrecision": args.target_precision, "fillGrid": FILL_GRID,
              "selectionExpressions": len(selection), "gateExpressions": len(gate),
              "note": "Exploratory validation only; checkpoint already saw full validation.",
              "bases": bases}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({name: {"chosenTauFill": base["chosenTauFill"],
                             "gate": base["gate"] and {key: base["gate"][key] for key in keys}}
                      for name, base in bases.items()}, sort_keys=True))


def calibrate(args: argparse.Namespace) -> None:
    if not math.isfinite(args.lambda_) or not .2 <= args.lambda_ <= 1.2:
        raise ValueError("lambda must be finite and in [0.2, 1.2]")
    torch.set_num_threads(4)
    print("Starting calibration: validation sequences and full validation NLL only", flush=True)
    lm_bytes = args.language_model.read_bytes()
    if hashlib.sha256(lm_bytes).hexdigest() != LM_SHA256:
        raise ValueError("language model SHA-256 does not match the shipped function-word LM")
    lines = _formulas(args.archive, "valid", args.vocab)
    print(f"Loaded {len(lines)} validation expressions / "
          f"{sum(len(line['symbols']) for line in lines)} symbols", flush=True)
    model, saved, class_ids = train_v2._checkpoint(argparse.Namespace(
        output=args.output, checkpoint=args.checkpoint, vocab=args.vocab))
    train_v2._verify_checkpoint_sources(saved, args.build_dir, args.vocab)
    _predict(model, lines)
    vocab = json.loads(args.vocab.read_text())
    logits, targets = _cache_validation_logits(model, args.output)
    temperature = fit_temperature(logits, targets)
    print(f"Validation temperature={temperature:.8f} from {len(targets)} records; "
          "starting decoder threshold search", flush=True)
    _cache_class_probs(lines, temperature)
    lm_data = json.loads(lm_bytes)
    lm = LanguageModel(lm_data["vocab"], lm_data["ngrams"])
    lm.log_prob = lru_cache(maxsize=131072)(lm.log_prob)

    candidates, fill_summaries = [], []

    def rank(row):
        # Keep F4's target as a preference, never as a pass/fail gate.
        meets_target = row["substitutionPrecision"] >= .99 and row["harmfulSwapsPer100"] <= .5
        return (meets_target,
                row["coverageRecognizableSymbols"] if meets_target else row["substitutionPrecision"],
                row["substitutionPrecision"] if meets_target else row["coverageRecognizableSymbols"],
                -row["harmfulSwapsPer100"], row["tauFill"], row["tauSub"])

    started = time.perf_counter()
    lambda_ = args.lambda_
    decode_cached = _decoder_cache(lm, lambda_)
    sequences = _sequence_evaluator(lines, lm, temperature, lambda_, vocab, class_ids, decode_cached)
    for tau_fill in FILL_GRID:
        selected = None
        for tau_sub in TAUS:

            def evaluate(tau_rev, disabled):
                return sequences(tau_sub, tau_rev, disabled, tau_fill)

            result, tau_rev, disabled = _calibration_setting(evaluate)
            attempt = {"lambda": lambda_, "tauSub": tau_sub, "tauRev": tau_rev,
                       "tauFill": tau_fill,
                       "disabledLabels": disabled, **result}
            if selected is None or rank(attempt) > rank(selected):
                selected = attempt
            elapsed = time.perf_counter() - started
            print(f"calibration lambda={lambda_:.1f} tauSub={tau_sub:.3f} "
                  f"tauRev={tau_rev:.2f} tauFill={tau_fill:.3f} elapsed={elapsed:.1f}s "
                  f"precision={result['substitutionPrecision']:.4f} "
                  f"harmful/100={result['harmfulSwapsPer100']:.3f} "
                  f"coverage={result['coverage']:.4f} disabled={disabled} "
                  f"sequenceCache={sequences.cache_stats}", flush=True)
            if result["substitutionPrecision"] >= .99 and result["harmfulSwapsPer100"] <= .5:
                break
        candidates.append(selected)
        fill_summaries.append(selected)
    train_v2.write_json(args.calibration.with_name("calibration-search-summary.json"), {
        "status": "completed", "temperature": temperature, "commitFloor": .5,
        "checkpointSHA256": train_v2.digest(args.checkpoint or args.output / "best.pt"),
        "calibrationScriptSHA256": train_v2.digest(Path(__file__)),
        "sequenceExpressions": len(lines), "temperatureRecords": len(targets),
        "elapsedSearchSeconds": time.perf_counter() - started,
        "candidateCount": len(candidates), "lambda": lambda_, "fillGrid": FILL_GRID,
        "fillResults": fill_summaries,
    })
    chosen = max(candidates, key=rank)
    disabled = chosen["disabledLabels"]
    final_validation = simulate(lines, lm, temperature, chosen["lambda"], chosen["tauSub"],
                                chosen["tauRev"], set(disabled), vocab, class_ids,
                                tau_fill=chosen["tauFill"])
    report = {"version": 1, "checkpointSHA256": train_v2.digest(args.checkpoint or args.output / "best.pt"),
              "selectedEpoch": saved["epoch"], "mathVocabSHA256": train_v2.digest(args.vocab),
              "calibrationScriptSHA256": train_v2.digest(Path(__file__)),
              "sourceHashes": saved["sourceHashes"], "temperature": temperature,
              "lambda": chosen["lambda"], "tauSub": chosen["tauSub"], "tauRev": chosen["tauRev"],
              "tauFill": chosen["tauFill"],
              "disabledLabels": disabled, "mathLMSHA256": LM_SHA256,
              "validation": final_validation, "candidates": candidates,
              "focusLabelAccuracy": {label: final_validation["perLabelAccuracy"].get(
                  label, {"correct": 0, "count": 0, "accuracy": None})
                  for label in ("q", "l", "9", "1", "t", "{", "}")},
              "simulation": {"pipelineRevision": "F5", "resolverMode": "math",
                             "commitFloor": .5, "commitIgnoresDisabledLabels": True,
                             "caseFold": datasets.CASE_FOLD, "functionWordsExcluded": True,
                             "junkClass": "junk maps to <unk>; never substituted or revised",
                             "sequenceOrder": "first stroke time, then XML group order",
                             "cellHeight": 32.0,
                             "initialCellTop": "first symbol ink top minus 0.3 * cellHeight",
                             "truthEligibility": "CROHME validation formulas with has_frac=false; case-folded truths; function-word groups excluded; unsupported leaves retained as <unk>",
                             "fractionMaxDepth": 2, "wideBlobWidthMultiple": 1.6,
                             "wideBlobNormalHeightFallback": "max(ink height, 0.4 * active cell height)",
                             "candidateTopK": 5, "tauRevStep": .02},
              "temperatureRecords": len(targets), "sequenceExpressions": len(lines),
              "lambdaSelection": "fixed lambda; prefer smallest tauSub reaching 99% precision and <=0.5 harmful swaps per fill setting, then maximum known coverage; if none reaches target choose best precision then known coverage; no pass/fail gate",
              "tauSearch": {"start": 0.0, "end": 1.0, "step": .005},
              "tauSearchStep": .005}
    args.calibration.parent.mkdir(parents=True, exist_ok=True)
    args.calibration.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: report[key] for key in
                      ("temperature", "lambda", "tauSub", "tauRev", "tauFill", "disabledLabels", "validation")},
                     ensure_ascii=False, sort_keys=True))


def _capture_bounds(strokes: list, styles: list[dict]) -> tuple[float, float, float, float]:
    extents = []
    for index, stroke in enumerate(strokes):
        points = np.asarray(stroke, dtype=np.float64)[:, :2]
        radius = max(0.0, float(styles[index].get("width", 0))) / 2 if index < len(styles) else 0
        extents.append((points.min(axis=0) - radius, points.max(axis=0) + radius))
    low = np.min([item[0] for item in extents], axis=0)
    high = np.max([item[1] for item in extents], axis=0)
    return float(low[0]), float(low[1]), float(high[0] - low[0]), float(high[1] - low[1])


def final_test(args: argparse.Namespace) -> None:
    torch.set_num_threads(4)
    report_path = args.report
    marker = report_path.with_name(f".{report_path.name}.consumed")
    if report_path.exists() or marker.exists():
        raise FileExistsError(f"final test already consumed or report exists: {report_path}")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    calibration = json.loads(args.calibration.read_text())
    required = ("checkpointSHA256", "selectedEpoch", "mathVocabSHA256", "mathLMSHA256",
                "calibrationScriptSHA256", "sourceHashes", "temperature", "lambda",
                "tauSub", "tauRev", "tauFill", "disabledLabels", "validation")
    missing = [key for key in required if key not in calibration]
    if missing:
        raise ValueError(f"calibration missing required fields: {missing}")
    if (not math.isfinite(float(calibration["temperature"])) or calibration["temperature"] <= 0 or
            not .2 <= float(calibration["lambda"]) <= 1.2 or
            not 0 <= float(calibration["tauSub"]) <= 1 or
            not .9 <= float(calibration["tauRev"]) <= 1 or
            not .9 <= float(calibration["tauFill"]) <= 1):
        raise ValueError("calibration parameters are outside supported ranges")
    validation = calibration["validation"]
    if not (.99 <= float(validation.get("substitutionPrecision", 0)) <= 1 and
            0 <= float(validation.get("harmfulSwapsPer100", math.inf)) <= .5):
        raise ValueError("calibration does not meet validation gates")
    if calibration["calibrationScriptSHA256"] != train_v2.digest(Path(__file__)):
        raise ValueError("calibration script hash differs")
    if calibration["mathVocabSHA256"] != train_v2.digest(args.vocab):
        raise ValueError("calibration math vocabulary hash differs")
    valid_labels = {label for cls in json.loads(args.vocab.read_text())["classes"] for label in cls["labels"]}
    if not isinstance(calibration["disabledLabels"], list) or not set(calibration["disabledLabels"]) <= valid_labels:
        raise ValueError("calibration contains invalid disabled labels")
    lm_bytes = args.language_model.read_bytes()
    if hashlib.sha256(lm_bytes).hexdigest() != LM_SHA256:
        raise ValueError("final test requires the shipped function-word math LM")
    if calibration.get("mathLMSHA256") != hashlib.sha256(lm_bytes).hexdigest():
        raise ValueError("calibration and shipped language model hashes differ")
    lm_data = json.loads(lm_bytes)
    lm = LanguageModel(lm_data["vocab"], lm_data["ngrams"])
    checkpoint_path = args.checkpoint or args.output / "best.pt"
    if train_v2.digest(checkpoint_path) != calibration.get("checkpointSHA256"):
        raise ValueError("calibration belongs to a different checkpoint")
    model, saved, class_ids = train_v2._checkpoint(argparse.Namespace(
        output=args.output, checkpoint=args.checkpoint, vocab=args.vocab))
    train_v2._verify_checkpoint_sources(saved, args.build_dir, args.vocab)
    if saved["epoch"] != calibration["selectedEpoch"] or saved["sourceHashes"] != calibration["sourceHashes"]:
        raise ValueError("calibration checkpoint lineage differs")
    split = json.loads((args.build_dir / "datasets/cap-split.json").read_text())
    names = split.get("CAP-test")
    if not isinstance(names, list) or len(names) != 201 or len(set(names)) != 201:
        raise ValueError("CAP-test split must be the immutable 201-record array")
    capture_dir = args.build_dir / "glyph-capture"
    if not args.archive.is_file() or any(Path(name).name != name or not (capture_dir / name).is_file()
                                         for name in names):
        raise FileNotFoundError("TEST-C archive or a CAP-test capture is missing")
    args.output.mkdir(parents=True, exist_ok=True)
    with marker.open("x") as stream:
        stream.write("final test access started\n")
    lines = _formulas(args.archive, "test", args.vocab)
    _predict(model, lines)
    vocab = json.loads(args.vocab.read_text())
    _cache_class_probs(lines, calibration["temperature"])
    result = simulate(lines, lm, calibration["temperature"], calibration["lambda"],
                      calibration["tauSub"], calibration["tauRev"],
                      set(calibration["disabledLabels"]), vocab, class_ids,
                      tau_fill=calibration["tauFill"])
    label_to_class = {label: cls["id"] for cls in vocab["classes"] for label in cls["labels"]}
    class_index = {value: index for index, value in enumerate(class_ids)}
    isolated_class_correct = isolated_total = isolated_unknown = 0
    all_labels = sorted(label for cls in vocab["classes"] for label in cls["labels"])
    label_order = {label: index for index, label in enumerate(all_labels)}
    for line in lines:
        for item in line["symbols"]:
            if item["label"] == "<unk>" or item["logits"] is None:
                isolated_unknown += 1
                continue
            probs = _softmax(item["logits"], calibration["temperature"])
            isolated_class_correct += class_ids[int(np.argmax(probs))] == label_to_class[item["label"]]
            isolated_total += 1
    cap_confusion = np.zeros((len(all_labels), len(all_labels)), dtype=np.int64)
    label_index = {label: index for index, label in enumerate(all_labels)}
    with torch.no_grad():
        for name in names:
            if Path(name).name != name:
                raise ValueError(f"invalid CAP-test filename: {name}")
            record = json.loads((args.build_dir / "glyph-capture" / name).read_text())
            paths = train_v2.stroke_points(record["strokes"])
            encoded = encode(paths)
            if encoded is None:
                raise ValueError(f"empty CAP-test capture: {name}")
            image = torch.from_numpy(train_v2.vectorized_raster(paths).astype(np.float32)[None, None])
            path = torch.from_numpy(np.asarray(encoded["strokePoints"], dtype=np.float32)[None])
            globals_ = torch.from_numpy(train_v2.stroke_globals(paths)[None])
            probs = _softmax(model(image, path, globals_)[0][0].numpy(), calibration["temperature"])
            bounds = _capture_bounds(paths, record.get("styles", []))
            scores = {label: 0.0 for label in all_labels}
            for class_id, index in class_index.items():
                for label, weight in member_weights(class_id, bounds, {"mode": "math"}).items():
                    scores[label] += float(probs[index]) * weight
            guess = max(all_labels, key=lambda label: (scores[label], -label_index[label]))
            cap_confusion[label_index[record["label"]], label_index[guess]] += 1
    cap_accuracy = float(cap_confusion.trace() / cap_confusion.sum())
    test_report = {"version": 1, "testAccess": "one-time", "checkpointSHA256": calibration["checkpointSHA256"],
                   "calibration": {key: calibration[key] for key in
                                   ("temperature", "lambda", "tauSub", "tauRev", "tauFill", "disabledLabels")},
                   "TEST-C": {**result,
                              "isolatedClassAccuracy": isolated_class_correct / max(1, isolated_total),
                              "isolatedSymbols": isolated_total, "isolatedUnknownSymbols": isolated_unknown},
                   "CAP-test": {"records": int(cap_confusion.sum()), "isolatedLabelAccuracy": cap_accuracy,
                                "confusionMatrix": cap_confusion.tolist(),
                                "labels": all_labels,
                                "confusionPairs": train_v2._confusion_pairs(cap_confusion, all_labels)}}
    with report_path.open("x") as stream:
        json.dump(test_report, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
    print(json.dumps({"report": str(report_path), "TEST-C": test_report["TEST-C"],
                      "CAP-test": test_report["CAP-test"]["isolatedLabelAccuracy"]},
                     ensure_ascii=False, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--archive", type=Path, default=ARCHIVE)
    common.add_argument("--build-dir", type=Path, default=BUILD)
    common.add_argument("--output", type=Path, default=OUT)
    common.add_argument("--checkpoint", type=Path)
    common.add_argument("--vocab", type=Path, default=VOCAB)
    common.add_argument("--language-model", type=Path, default=LM)
    calibrate_parser = commands.add_parser("calibrate", parents=[common])
    calibrate_parser.add_argument("--calibration", type=Path)
    calibrate_parser.add_argument("--lambda", dest="lambda_", type=float, default=.4)
    selective_parser = commands.add_parser("selective-validation", parents=[common])
    selective_parser.add_argument("--report", type=Path,
                                  default=BUILD / "orchestration-v2-wave3/selective-validation.json")
    selective_parser.add_argument("--lambda", dest="lambda_", type=float, default=.4)
    selective_parser.add_argument("--target-precision", type=float, default=.99)
    selective_parser.add_argument("--minimum-support", type=int, default=30)
    fill_parser = commands.add_parser("fill-sweep", parents=[common])
    fill_parser.add_argument("--report", type=Path,
                             default=BUILD / "orchestration-v2-wave3/fill-sweep.json")
    fill_parser.add_argument("--lambda", dest="lambda_", type=float, default=.4)
    fill_parser.add_argument("--target-precision", type=float, default=.99)
    fill_parser.add_argument("--minimum-support", type=int, default=30)
    test_parser = commands.add_parser("test-once", parents=[common])
    test_parser.add_argument("--calibration", type=Path)
    test_parser.add_argument("--report", type=Path, default=BUILD / "glyph-training-v2/test-report.json")
    args = parser.parse_args()
    if args.command == "calibrate":
        args.calibration = args.calibration or args.output / "calibration.json"
        calibrate(args)
    elif args.command == "selective-validation":
        selective_validation(args)
    elif args.command == "fill-sweep":
        fill_sweep(args)
    else:
        args.calibration = args.calibration or args.output / "calibration.json"
        final_test(args)


if __name__ == "__main__":
    main()
