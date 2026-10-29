#!/usr/bin/env python3
"""Build the streamed, math-only v2 stroke datasets."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from contextlib import ExitStack, contextmanager
import gzip
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
from xml.etree import ElementTree as ET
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
MATH_VOCAB = ROOT / "Sources/CanvasKit/Resources/math-vocab.json"
V1_VOCAB = ROOT / "Sources/CanvasKit/Resources/vocab.json"
MAX_DATASET_BYTES = 3_000_000_000
XML_ID = "{http://www.w3.org/XML/1998/namespace}id"

# Glyph targets describe ink shape; the LM linearizer separately maps multiplication to dot.
TOKEN_MAP = {
    **{str(n): str(n) for n in range(10)},
    **{c: c for c in "abcdefghijklmnopqrstuvwxyz"},
    **{c: c for c in "+=<>/!()[]{}|.,"},
    "-": "−", "\\cdot": "·", "\\times": "x", "×": "x", "\\div": "÷",
    "\\pm": "±", "\\neq": "≠", "\\ne": "≠", "\\leq": "≤",
    "\\le": "≤", "\\geq": "≥", "\\ge": "≥", "\\|": "|",
    "\\vert": "|", "\\mid": "|", "\\lvert": "|", "\\rvert": "|",
    "'": "′", "\\prime": "′", "\\sqrt": "√", "\\int": "∫",
    "\\sum": "∑", "\\pi": "π", "\\theta": "θ", "\\Delta": "Δ",
    "\\infty": "∞", "\\to": "→", "\\rightarrow": "→",
    "\\lt": "<", "\\gt": ">",
}
# Labels added after the frozen base datasets were generated (q, braces). Extras
# keep them; under an older vocabulary they fall back to junk like q does.
EXTRA_LABELS = ("q", "{", "}")

MULTI_COMMANDS = {
    "\\lim": "lim", "\\sin": "sin", "\\cos": "cos", "\\tan": "tan",
    "\\log": "log", "\\ln": "ln", "\\exp": "exp", "\\sec": "sec",
    "\\csc": "csc", "\\cot": "cot",
}
CASE_FOLD = dict(zip("CKOPSUVWXZ", "ckopsuvwxz"))

DROP_COMMANDS = {"\\left", "\\right", "\\,", "\\;", "\\quad", "\\!"}


def _label_tokens(raw: str) -> list[str]:
    raw = str(raw).strip()
    if raw.startswith("$") and raw.endswith("$") and len(raw) >= 2:
        raw = raw[1:-1].strip()
    raw = re.sub(r"\\(?:mathrm|operatorname)\{([^{}]*)\}", r"\1", raw)
    raw = re.sub(r"\^\s*\{\s*\\prime\s*\}", r"\\prime", raw)
    raw = re.sub(r"\^\s*\{\s*\\circ\s*\}", "°", raw)
    if raw in ("{", "}"):
        return [raw]
    tokens: list[str] = []
    i = 0
    while i < len(raw):
        c = raw[i]
        if c.isspace() or c in "{}^_":
            i += 1
            continue
        if c == "\\":
            j = i + 1
            if j < len(raw) and raw[j].isalpha():
                while j < len(raw) and raw[j].isalpha():
                    j += 1
            else:
                j = min(j + 1, len(raw))
            token = raw[i:j]
            # Escaped braces are literal braces; emit the brace itself.
            tokens.append(raw[j - 1] if len(token) == 2 and raw[j - 1] in "{}" else token)
            i = j
        else:
            tokens.append(c)
            i += 1
    return [token for token in tokens if token not in DROP_COMMANDS]


def _single_label(raw: str, labels: set[str]) -> str | None:
    out: list[str] = []
    for token in _label_tokens(raw):
        if token in DROP_COMMANDS:
            continue
        if token in labels:
            out.append(token)
        elif token in TOKEN_MAP:
            out.append(TOKEN_MAP[token])
        elif token in MULTI_COMMANDS:
            out.extend(MULTI_COMMANDS[token])
        else:
            return None
    return out[0] if len(out) == 1 and out[0] in labels else None


def is_function_word(raw: str) -> bool:
    tokens = _label_tokens(raw)
    return ((len(tokens) == 1 and tokens[0] in MULTI_COMMANDS)
            or "".join(tokens) in MULTI_COMMANDS.values())


def extended_label(raw: str, labels: set[str]) -> str | None:
    if is_function_word(raw):
        return None
    tokens = _label_tokens(raw)
    if len(tokens) != 1:
        return None
    token = tokens[0]
    if token in CASE_FOLD:
        return CASE_FOLD[token] if CASE_FOLD[token] in labels else None
    label = _single_label(raw, labels - {"<unk>"})
    if label is not None:
        return label
    if token not in labels and (token not in TOKEN_MAP or token in EXTRA_LABELS) and token not in MULTI_COMMANDS:
        return "<unk>"
    return None


def _source_label(raw: str, labels: set[str], extras: bool, dropped: Counter) -> str | None:
    label = _single_label(raw, labels - {"<unk>"})
    if extras:
        # EXTRA_LABELS were absent from the immutable base datasets; keep them in the new extras.
        if label is not None and label not in EXTRA_LABELS:
            dropped["base_label"] += 1
            return None
        label = extended_label(raw, labels)
    if label is None:
        dropped["function_word" if extras and is_function_word(raw) else "unmapped_label"] += 1
    return label


def _source_record(src, split, writer, label, strokes, ink_id, classes, raw, extras, raw_counts):
    row = _record(src, split, writer, label, strokes, ink_id, classes)
    if extras:
        row["rawLabel"] = raw
        # The "q" stats kind covers every EXTRA_LABELS member (q and braces).
        kind = "junk" if label == "<unk>" else "q" if label in EXTRA_LABELS else "caseFold"
        raw_counts[kind][raw] += 1
        raw_counts[kind + "BySplit"][split] += 1
    return row


def _source_metadata(directory, source, dropped, records, extras, raw_counts):
    if not extras:
        _save_source_metadata(directory, source, dropped, records)
    return {"records": dict(sorted(records.items())), "dropped": dict(sorted(dropped.items())),
            "recordsByKind": {kind: dict(sorted(raw_counts[kind + "BySplit"].items()))
                              for kind in ("junk", "caseFold", "q")},
            "rawLabels": {kind: [{"rawLabel": raw, "count": count}
                          for raw, count in raw_counts[kind].most_common(60)]
                          for kind in ("junk", "caseFold", "q")}}


def _load_vocab(path: Path) -> tuple[dict[str, str], set[str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    label_classes = {
        label: cls["id"]
        for cls in data["classes"]
        for label in cls["labels"]
    }
    labels = set(label_classes)
    if len(labels) != sum(len(cls["labels"]) for cls in data["classes"]):
        raise ValueError("math-vocab contains duplicate labels")
    return label_classes, labels


def _record(src: str, split: str, writer: str | None, label: str,
            strokes: list[list[list[int | float]]], ink_id: str,
            classes: dict[str, str]) -> dict:
    return {"src": src, "split": split, "writer": writer, "label": label,
            "class": classes[label], "strokes": strokes, "ink_id": ink_id}


@contextmanager
def _gzip_writers(directory: Path, source: str, splits: tuple[str, ...], exclusive=False):
    paths = {s: directory / f"{source}-{s}.jsonl.gz" for s in splits}
    temps = {s: p.with_name(p.name + ".tmp") for s, p in paths.items()}
    if exclusive and any(path.exists() or temps[split].exists() for split, path in paths.items()):
        raise FileExistsError(f"extras outputs already exist for {source}")
    try:
        with ExitStack() as stack:
            writers = {}
            for split, path in temps.items():
                raw = stack.enter_context(path.open("xb" if exclusive else "wb"))
                writers[split] = stack.enter_context(
                    gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=6)
                )
            yield writers
        for split in splits:
            if exclusive:
                os.link(temps[split], paths[split])
            else:
                os.replace(temps[split], paths[split])
    finally:
        for path in temps.values():
            path.unlink(missing_ok=True)


def _write_record(stream, record: dict, counts: Counter) -> None:
    stream.write((json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
    counts[record["split"]] += 1


def _metadata_path(directory: Path) -> Path:
    return directory / ".pipeline-metadata.json"


def _save_source_metadata(directory: Path, source: str, dropped: Counter, records: Counter) -> None:
    path = _metadata_path(directory)
    data = json.loads(path.read_text()) if path.exists() else {"version": 1, "sources": {}}
    data["sources"][source] = {
        "dropped": dict(sorted(dropped.items())),
        "records": dict(sorted(records.items())),
    }
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    os.replace(temp, path)


def _number(value: str) -> int | float:
    value = value.strip()
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"non-finite InkML coordinate: {value}")
    return int(value) if re.fullmatch(r"[+-]?\d+", value) else number


def _fill_times(strokes: list[list[list[int | float | None]]]) -> list[list[list[int | float]]]:
    if all(point[2] is not None for stroke in strokes for point in stroke):
        return strokes  # type: ignore[return-value]
    clock = 0
    for stroke in strokes:
        for point in stroke:
            if point[2] is None:
                point[2] = clock
            clock = max(clock + 1, int(point[2]) + 1)
    return strokes  # type: ignore[return-value]


def _inkml(root: ET.Element) -> tuple[dict[str, list[list[int | float | None]]], list[str]]:
    format_element = next((node for node in root.iter() if node.tag.rsplit("}", 1)[-1] == "traceFormat"), None)
    channels = [node.attrib.get("name", "").upper() for node in format_element] if format_element is not None else []
    x_index = channels.index("X") if "X" in channels else 0
    y_index = channels.index("Y") if "Y" in channels else 1
    time_index = next((channels.index(name) for name in ("T", "TIME", "TIMESTAMP") if name in channels), None)
    traces: dict[str, list[list[int | float | None]]] = {}
    order: list[str] = []
    for index, trace in enumerate(node for node in root.iter() if node.tag.rsplit("}", 1)[-1] == "trace"):
        trace_id = trace.attrib.get("id", str(index))
        if trace_id in traces:
            raise ValueError(f"duplicate trace id {trace_id}")
        points = []
        for encoded in (trace.text or "").split(","):
            fields = encoded.split()
            if not fields:
                continue
            if x_index >= len(fields) or y_index >= len(fields):
                raise ValueError(f"malformed trace {trace_id}")
            ti = time_index
            if ti is None and not channels and len(fields) > 2:
                ti = 2
            points.append([_number(fields[x_index]), _number(fields[y_index]),
                           _number(fields[ti]) if ti is not None and ti < len(fields) else None])
        traces[trace_id] = points
        order.append(trace_id)
    return traces, order


def _views(group: ET.Element) -> list[str]:
    return [node.attrib.get("traceDataRef", "").lstrip("#") for node in group
            if node.tag.rsplit("}", 1)[-1] == "traceView"]


def _leaf_groups(root: ET.Element) -> list[ET.Element]:
    return [node for node in root.iter() if node.tag.rsplit("}", 1)[-1] == "traceGroup"
            and not any(child.tag.rsplit("}", 1)[-1] == "traceGroup" for child in node)]


def _group_id(group: ET.Element, fallback: int) -> str:
    return str(group.attrib.get(XML_ID, group.attrib.get("id", fallback)))


def _annotation(root: ET.Element, kind: str) -> str | None:
    for node in root:
        if node.tag.rsplit("}", 1)[-1] == "annotation" and node.attrib.get("type", "").casefold() == kind.casefold():
            value = (node.text or "").strip()
            if value:
                return value
    return None


def _truth(group: ET.Element) -> str:
    return next(((node.text or "").strip() for node in group
                 if node.tag.rsplit("}", 1)[-1] == "annotation"
                 and node.attrib.get("type", "").casefold() == "truth"), "")


def _ordered_group_strokes(group: ET.Element, traces: dict, order: list[str] | dict[str, int]) -> list:
    refs = _views(group)
    if isinstance(order, list):
        order_map = {trace_id: i for i, trace_id in enumerate(order)}
    else:
        order_map = order
    if refs and all(ref in order_map for ref in refs):
        refs.sort(key=order_map.__getitem__)
    if any(ref not in traces for ref in refs):
        raise ValueError(f"traceGroup references missing trace: {refs}")
    return _fill_times([traces[ref] for ref in refs if traces[ref]])


def _mw_symbols(args, directory: Path, classes: dict[str, str], labels: set[str], extras=False) -> dict:
    source = "mw-symbols"
    dropped, records = Counter(), Counter()
    raw_counts = {kind: Counter() for kind in ("junk", "caseFold", "q", "junkBySplit", "caseFoldBySplit", "qBySplit")}
    with _gzip_writers(directory, source + ("-extra" if extras else ""), ("train",), exclusive=extras) as writers:
        candidates: dict[str, list[tuple[int, list[int], str, str]]] = defaultdict(list)
        with tarfile.open(args.mw_archive, mode="r|gz") as archive:
            for member in archive:
                if member.name.endswith("symbols.jsonl"):
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise ValueError("MathWriting symbols.jsonl is unreadable")
                    for line_no, line in enumerate(stream, 1):
                        row = json.loads(line)
                        label = _source_label(row["label"], labels, extras, dropped)
                        if label is None:
                            continue
                        sample_id = str(row["sourceSampleId"])
                        indices = [int(i) for i in row["strokeIndices"]]
                        if not indices:
                            dropped["empty_strokes"] += 1
                            continue
                        candidates[sample_id].append((line_no, indices, label, row["label"]))
                    continue
                parts = PurePosixPath(member.name).parts
                if "train" not in parts or not member.isfile():
                    continue
                sample_id = PurePosixPath(member.name).stem
                rows = candidates.get(sample_id)
                if not rows:
                    continue
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(f"unreadable MathWriting ink: {member.name}")
                root = ET.parse(stream).getroot()
                traces, _ = _inkml(root)
                stroke_list = [traces[k] for k in traces]
                for line_no, indices, label, raw_label in rows:
                    if any(index < 0 or index >= len(stroke_list) for index in indices):
                        raise ValueError(f"invalid strokeIndices in symbols.jsonl row {line_no}")
                    strokes = _fill_times([stroke_list[index] for index in indices])
                    ink_id = f"mw:{sample_id}:{'-'.join(map(str, indices))}:{line_no}"
                    _write_record(writers["train"], _source_record(source, "train", None, label, strokes, ink_id, classes, raw_label, extras, raw_counts), records)
                del candidates[sample_id]
        if candidates:
            missing = sum(len(v) for v in candidates.values())
            raise ValueError(f"MathWriting sourceSampleId references missing train inks ({missing} symbols)")
    return _source_metadata(directory, source, dropped, records, extras, raw_counts)


def _writer(root: ET.Element, filename: str) -> str:
    value = _annotation(root, "writer")
    if value:
        return value
    stem = PurePosixPath(filename).stem
    return stem.rsplit("_", 1)[0] if "_" in stem else stem


def _writer_split(writer: str) -> str:
    digest = hashlib.sha256(f"20261003:crohme:{writer}".encode()).digest()
    return "valid" if int.from_bytes(digest[:8], "big") % 10 == 0 else "train"


def _zip_member(outer: ZipFile, suffix: str) -> ZipFile:
    matches = [name for name in outer.namelist() if name.endswith(suffix)]
    if len(matches) != 1:
        raise ValueError(f"expected one CROHME member ending {suffix!r}, found {matches}")
    return ZipFile(io.BytesIO(outer.read(matches[0])))


def _crohme(args, directory: Path, classes: dict[str, str], labels: set[str], extras=False) -> dict:
    source = "crohme"
    dropped, records = Counter(), Counter()
    raw_counts = {kind: Counter() for kind in ("junk", "caseFold", "q", "junkBySplit", "caseFoldBySplit", "qBySplit")}
    expression_meta: dict[str, dict] = {}
    with _gzip_writers(directory, source + ("-extra" if extras else ""),
                       ("train", "valid") if extras else ("train", "valid", "test"), exclusive=extras) as writers:
        with ZipFile(args.crohme_archive) as outer:
            formula_train = _zip_member(outer, "/Task1_onlineRec/MainTask_formula/Train.zip")
            formula_valid = None if extras else _zip_member(outer, "/Task1_onlineRec/MainTask_formula/valid.zip")
            archives = [(formula_train, None)] + ([] if extras else [(formula_valid, "test")])
            for archive, forced_split in archives:
                for name in sorted(archive.namelist()):
                    if not name.lower().endswith(".inkml"):
                        continue
                    with archive.open(name) as stream:
                        root = ET.parse(stream).getroot()
                    traces, trace_order = _inkml(root)
                    traces = dict(zip(trace_order, _fill_times([traces[key] for key in trace_order])))
                    ui = _annotation(root, "UI") or PurePosixPath(name).stem
                    writer = _writer(root, name)
                    split = forced_split or _writer_split(writer)
                    if ui in expression_meta:
                        raise ValueError(f"duplicate CROHME expression UI: {ui}")
                    expression_meta[ui] = {"split": split, "writer": writer,
                                           "trace_order": {key: i for i, key in enumerate(trace_order)}}
                    groups = _leaf_groups(root)
                    if not groups:
                        dropped["no_trace_groups"] += 1
                        continue
                    for index, group in enumerate(groups):
                        raw_label = _truth(group)
                        label = _source_label(raw_label, labels, extras, dropped)
                        if label is None:
                            continue
                        strokes = _ordered_group_strokes(group, traces, trace_order)
                        if not strokes:
                            dropped["empty_strokes"] += 1
                            continue
                        group_id = _group_id(group, index)
                        ink_id = f"crohme-formula:{ui}:{group_id}"
                        row = _source_record(source, split, writer, label, strokes, ink_id, classes, raw_label, extras, raw_counts)
                        _write_record(writers[split], row, records)

            symbols = _zip_member(outer, "/Task1_onlineRec/subTask_symbols/Train.zip")
            folder_specs = (
                ("Train/isolatedTest2012/", "Train/isolatedTest2012/both_GT.txt", True),
                ("Train/isolatedTest2013b/", "Train/isolatedTest2013b/iso_GT.txt", True),
                ("Train/isolatedTrain2014/trainingSymbols/", "Train/isolatedTrain2014/trainingSymbols/iso_GT.txt", False),
                ("Train/isolatedTrain2014/trainingJunk/", "Train/isolatedTrain2014/trainingJunk/junk_GT.txt", False),
            )
            seen_symbols: dict[str, str] = {}
            for folder, gt_path, must_link in folder_specs:
                if gt_path not in symbols.namelist():
                    raise ValueError(f"CROHME symbol ground truth missing: {gt_path}")
                ground_truth = {}
                for line in symbols.read(gt_path).decode("utf-8-sig").splitlines():
                    if not line.strip() or "," not in line:
                        continue
                    key, value = line.split(",", 1)
                    ground_truth[key.strip()] = value.strip()
                for name in sorted(n for n in symbols.namelist()
                                   if n.startswith(folder) and n.lower().endswith(".inkml")):
                    with symbols.open(name) as stream:
                        root = ET.parse(stream).getroot()
                    ui = _annotation(root, "UI")
                    if not ui:
                        raise ValueError(f"CROHME isolated symbol missing UI: {name}")
                    groups = _leaf_groups(root)
                    if not groups:
                        raise ValueError(f"CROHME isolated symbol has no traceGroup: {name}")
                    traces, xml_order = _inkml(root)
                    for index, group in enumerate(groups):
                        group_id = _group_id(group, index)
                        gt_keys = (f"{ui}_{group_id}", ui)
                        key = next((candidate for candidate in gt_keys if candidate in ground_truth), None)
                        if key is None:
                            raise ValueError(f"CROHME isolated symbol ground truth missing for {ui}")
                        raw_label = ground_truth[key]
                        label = _source_label(raw_label, labels, extras, dropped)
                        if label is None:
                            continue
                        parent_ui = ui if ui in expression_meta else (
                            ui.rsplit("_", 1)[0] if re.search(r"_\d+$", ui) else None
                        )
                        meta = expression_meta.get(parent_ui) if parent_ui else None
                        if meta and meta["split"] != "train":
                            dropped["heldout_source_expression"] += 1
                            continue
                        if must_link and meta is None and extras:
                            dropped["heldout_source_expression"] += 1
                            continue
                        if must_link and meta is None:
                            raise ValueError(f"CROHME isolated symbol has no exact source expression UI: {ui}")
                        if meta is None and not (folder.startswith("Train/isolatedTrain2014/")
                                                 and parent_ui and parent_ui.startswith("MfrDB")):
                            raise ValueError(f"unmatched CROHME isolated symbol UI: {ui}")
                        if meta and any(ref not in meta["trace_order"] for ref in _views(group)):
                            raise ValueError(f"CROHME isolated symbol trace IDs do not match source UI: {ui}")
                        strokes = _ordered_group_strokes(group, traces,
                            meta["trace_order"] if meta else xml_order)
                        if not strokes:
                            dropped["empty_strokes"] += 1
                            continue
                        ink_id = f"crohme-symbol:{ui}:{group_id}"
                        fingerprint = hashlib.sha256(json.dumps([label, strokes], separators=(",", ":")).encode()).hexdigest()
                        if ink_id in seen_symbols:
                            if seen_symbols[ink_id] != fingerprint:
                                raise ValueError(f"conflicting duplicate CROHME symbol: {ink_id}")
                            dropped["duplicate_symbol"] += 1
                            continue
                        seen_symbols[ink_id] = fingerprint
                        writer = meta["writer"] if meta else _annotation(root, "writer")
                        row = _source_record(source, "train", writer, label, strokes, ink_id, classes, raw_label, extras, raw_counts)
                        _write_record(writers["train"], row, records)
            symbols.close()
            formula_train.close()
            if formula_valid is not None:
                formula_valid.close()
    return _source_metadata(directory, source, dropped, records, extras, raw_counts)


class _AllRawIds(dict):
    def get(self, key, default=None):
        return super().get(key, "__unmapped_hwrt_symbol__")


def _hwrt_strokes(raw: list) -> list[list[list[int | float]]]:
    strokes = []
    for stroke in raw:
        if isinstance(stroke, dict):
            stroke = stroke["points"]
        points = []
        for point in stroke:
            if isinstance(point, dict):
                x, y = point["x"], point["y"]
                t = point.get("time", point.get("t"))
            else:
                x, y = point[0], point[1]
                t = point[2] if len(point) > 2 else None
            for value in (x, y):
                if not isinstance(value, (int, float)) or not math.isfinite(value) or abs(value) > 200000:
                    raise ValueError("invalid HWRT coordinate")
            if t is not None and (not isinstance(t, (int, float)) or not math.isfinite(t)):
                raise ValueError("invalid HWRT timestamp")
            points.append([x, y, t])
        if points:
            strokes.append(points)
    return _fill_times(strokes)


def _hwrt(args, directory: Path, classes: dict[str, str], labels: set[str], extras=False) -> dict:
    sys.path.insert(0, str(ROOT / "scripts/glyphs"))
    import train as legacy_train

    split_data = json.loads(args.prepare.read_text(encoding="utf-8"))["writers"]
    assignment = {str(writer): split for split, writers in split_data.items() for writer in writers}
    if set(split_data) != {"train", "valid"} or len(assignment) != sum(map(len, split_data.values())):
        raise ValueError("prepared HWRT writer assignments overlap or are malformed")
    v1_labels, _, ids = legacy_train.vocabulary(args.v1_vocab)
    dropped, records = Counter(), Counter()
    raw_counts = {kind: Counter() for kind in ("junk", "caseFold", "q", "junkBySplit", "caseFoldBySplit", "qBySplit")}
    with _gzip_writers(directory, "hwrt-extra" if extras else "hwrt", ("train", "valid"), exclusive=extras) as writers:
        args_legacy = argparse.Namespace(hwrt=str(args.hwrt), synthetic=str(args.synthetic))
        sample_no = 0
        for item in legacy_train.records(args_legacy, v1_labels, _AllRawIds(ids)):
            if item["source"] != "HWRT raw ODbL":
                continue
            label = _source_label(item["label"], labels, extras, dropped)
            if label is None:
                sample_no += 1
                continue
            writer = str(item["writer"])
            split = assignment.get(writer)
            if split is None:
                raise ValueError(f"HWRT writer is absent from accepted prepare.json split: {writer}")
            legacy_train.points(item["strokes"])
            strokes = _hwrt_strokes(item["strokes"])
            if not strokes:
                dropped["empty_strokes"] += 1
                sample_no += 1
                continue
            row = _source_record("hwrt", split, writer, label, strokes,
                          f"hwrt:{writer}:{sample_no}", classes, item["label"], extras, raw_counts)
            _write_record(writers[split], row, records)
            sample_no += 1
    return _source_metadata(directory, "hwrt", dropped, records, extras, raw_counts)


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _stats(args, directory: Path, classes: dict[str, str], labels: set[str]) -> None:
    required = [
        "mw-symbols-train.jsonl.gz", "crohme-train.jsonl.gz", "crohme-valid.jsonl.gz",
        "crohme-test.jsonl.gz", "hwrt-train.jsonl.gz", "hwrt-valid.jsonl.gz",
    ]
    missing = [name for name in required if not (directory / name).is_file()]
    if missing:
        raise ValueError(f"dataset outputs missing; run source commands first: {missing}")
    counts, file_counts, seen_ids, outputs = Counter(), Counter(), {}, []
    for path in sorted(directory.glob("*-*.jsonl.gz")):
        if "-extra-" in path.name:
            continue
        with gzip.open(path, "rt", encoding="utf-8") as stream:
            for line in stream:
                row = json.loads(line)
                if set(row) != {"src", "split", "writer", "label", "class", "strokes", "ink_id"}:
                    raise ValueError(f"unexpected dataset record fields in {path.name}")
                if row["label"] not in labels or row["class"] != classes[row["label"]]:
                    raise ValueError(f"bad math class in {path.name}: {row['label']}")
                prior = seen_ids.setdefault(row["ink_id"], row["split"])
                if prior != row["split"]:
                    raise ValueError(f"ink id crosses splits: {row['ink_id']} ({prior}, {row['split']})")
                counts[(row["src"], row["split"], row["class"])] += 1
                file_counts[path.name] += 1
        outputs.append({"file": path.name, "bytes": path.stat().st_size,
                        "records": file_counts[path.name], "sha256": _digest(path)})
    data_bytes = sum(item["bytes"] for item in outputs)
    if data_bytes > MAX_DATASET_BYTES:
        raise ValueError(f"generated datasets exceed 3,000,000,000 bytes: {data_bytes}")
    meta_path = _metadata_path(directory)
    metadata = json.loads(meta_path.read_text()) if meta_path.exists() else {"sources": {}}
    dropped = {src: data.get("dropped", {}) for src, data in sorted(metadata.get("sources", {}).items())}
    result = {
        "counts": [
            {"src": src, "split": split, "class": cls, "count": count}
            for (src, split, cls), count in sorted(counts.items())
        ],
        "dropped": dropped,
        "total_records": sum(counts.values()),
        "dataset_bytes": data_bytes,
        "limit_bytes": MAX_DATASET_BYTES,
        "outputs": outputs,
    }
    temp = directory / "stats.json.tmp"
    temp.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    os.replace(temp, directory / "stats.json")
    generated_bytes = data_bytes + meta_path.stat().st_size + (directory / "stats.json").stat().st_size
    if generated_bytes > MAX_DATASET_BYTES:
        raise ValueError(f"generated dataset files exceed 3,000,000,000 bytes: {generated_bytes}")
    print(json.dumps({"total_records": result["total_records"], "dataset_bytes": data_bytes,
                      "generated_bytes": generated_bytes, "outputs": outputs}, ensure_ascii=False))


def _extras(args, directory: Path, classes: dict[str, str], labels: set[str]) -> None:
    if classes.get("<unk>") != "junk":
        raise ValueError("extras requires the staging vocab with junk")
    names = ("mw-symbols-extra-train", "crohme-extra-train", "crohme-extra-valid",
             "hwrt-extra-train", "hwrt-extra-valid")
    paths = [directory / f"{name}.jsonl.gz" for name in names]
    stats_path = args.build_dir / "orchestration-v2-wave3/extras-stats.json"
    for path in paths:
        if path.with_name(path.name + ".tmp").exists():
            raise FileExistsError(path.with_name(path.name + ".tmp"))
    replace = getattr(args, "replace_extras", False)
    if not replace:
        for path in [*paths, stats_path]:
            if path.exists():
                raise FileExistsError(path)
    else:
        # Explicit regeneration is restricted to the five extras and their summary.
        for path in [*paths, stats_path]:
            path.unlink(missing_ok=True)
    sources = {name: loader(args, directory, classes, labels, extras=True)
               for name, loader in (("mw-symbols", _mw_symbols), ("crohme", _crohme), ("hwrt", _hwrt))}
    result = {"sources": sources, "outputs": [{"file": f"{name}.jsonl.gz",
              "sha256": _digest(directory / f"{name}.jsonl.gz")} for name in names]}
    stats_path.parent.mkdir(parents=True, exist_ok=True)
    with stats_path.open("x") as stream:
        stream.write(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("mw-symbols", "crohme", "hwrt", "stats", "extras"))
    parser.add_argument("--build-dir", type=Path, default=BUILD)
    parser.add_argument("--math-vocab", type=Path, default=MATH_VOCAB)
    parser.add_argument("--replace-extras", action="store_true",
                        help="regenerate only the five extras files and extras-stats.json")
    parser.add_argument("--v1-vocab", type=Path, default=V1_VOCAB)
    parser.add_argument("--mw-archive", type=Path)
    parser.add_argument("--crohme-archive", type=Path)
    parser.add_argument("--hwrt", type=Path)
    parser.add_argument("--prepare", type=Path)
    parser.add_argument("--synthetic", type=Path)
    args = parser.parse_args()
    if args.replace_extras and args.command != "extras":
        parser.error("--replace-extras is only valid for extras")
    datasets = args.build_dir / "datasets"
    datasets.mkdir(parents=True, exist_ok=True)
    args.mw_archive = args.mw_archive or datasets / "mathwriting-2024.tgz"
    args.crohme_archive = args.crohme_archive or datasets / "Task1_and_Task2.zip"
    classes, labels = _load_vocab(args.math_vocab)
    if args.command == "mw-symbols":
        _mw_symbols(args, datasets, classes, labels)
    elif args.command == "crohme":
        _crohme(args, datasets, classes, labels)
    elif args.command in ("hwrt", "extras"):
        args.hwrt = args.hwrt or args.build_dir / "hasy/2015-01-28-data.tar"
        args.prepare = args.prepare or args.build_dir / "glyph-training/prepare.json"
        args.synthetic = args.synthetic or args.build_dir / "glyph-synth/synthetic.jsonl"
        if args.command == "extras":
            _extras(args, datasets, classes, labels)
        else:
            _hwrt(args, datasets, classes, labels)
    else:
        _stats(args, datasets, classes, labels)


if __name__ == "__main__":
    main()
