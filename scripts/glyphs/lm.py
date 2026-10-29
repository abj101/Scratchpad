#!/usr/bin/env python3
"""Stream the approved math corpora into a pruned modified Kneser–Ney LM."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import random
import tarfile
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from grammar import generate
from linearize import linearize


LABELS = tuple(
    "0123456789abcdefghijklmnoprstuvwxyz"
    "+−·÷=≠<>≤≥±/!()[]|.,′√∫∑πθΔ∞→°"
)
VOCAB = LABELS + ("<s>", "<unk>")
START = "<s>"
ORDER = 4
SEED = 20261003
MAX_BYTES = 3_000_000

# Function names are written as plain letters in handwriting, but the corpora linearize
# them to <unk>. Spelled-out synthetic lines teach the LM the letter sequences, so the
# decoder can read a bar glyph as `l` in `lim` / `ln` / `log` while `12`, `1+`, `x1` stay.
FUNCTION_WORDS = ("sin", "cos", "tan", "sec", "csc", "cot", "log", "ln", "exp", "lim",
                  "max", "min", "det", "mod", "arcsin", "arccos", "arctan", "sinh",
                  "cosh", "tanh")
FUNCTION_PREFIXES = (("2",), ("+",), ("−",), ("=",), ("(",), ("[",), ("·",))
FUNCTION_SUFFIXES = ((), ("(",), ("x",), ("2",), ("θ",), ("π",))
FUNCTION_LINE_WEIGHT = 400


def function_word_sequences() -> list[tuple[list[str], int]]:
    """Deterministic (labels, weight) lines for the function-name lexicon."""
    lines = []
    for word in FUNCTION_WORDS:
        for prefix in FUNCTION_PREFIXES:
            for suffix in FUNCTION_SUFFIXES:
                lines.append(([*prefix, *word, *suffix], FUNCTION_LINE_WEIGHT))
    return lines


def strip_math_delimiters(source: str) -> str:
    """Remove only outer TeX math wrappers used by CROHME truth annotations."""
    value = source.strip()
    for marker in ("$$", "$", r"\(", r"\["):
        closing = {"$$": "$$", "$": "$", r"\(": r"\)", r"\[": r"\]"}[marker]
        if value.startswith(marker) and value.endswith(closing) and len(value) >= len(marker) + len(closing):
            return value[len(marker):-len(closing)].strip()
    return value


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _annotation(source, names: set[str]) -> str | None:
    found: dict[str, str] = {}
    depth = 0
    for event, element in ET.iterparse(source, events=("start", "end")):
        if event == "start":
            depth += 1
            continue
        if depth == 2 and _local_name(element.tag) == "annotation":
            kind = element.attrib.get("type", "")
            if kind in names and element.text:
                found[kind] = element.text.strip()
        element.clear()
        depth -= 1
    priority = ("normalizedLabel", "label", "truth")
    for name in sorted(names, key=lambda value: priority.index(value) if value in priority else len(priority)):
        if found.get(name):
            return found[name]
    return None


def _linearized(source: str) -> tuple[list[str], bool, int] | None:
    labels, has_frac, unk_count = linearize(strip_math_delimiters(source))
    if not labels or unk_count / len(labels) > 0.10:
        return None
    return labels, has_frac, unk_count


def _mw_split(name: str) -> str | None:
    parts = Path(name).parts
    if not parts or not parts[-1].lower().endswith(".inkml"):
        return None
    for split in ("train", "synthetic", "valid"):
        if split in parts[:-1]:
            return split
    return None


def _mw_corpus(path: Path, valid_spool, counters: list[Counter[int]],
               ids: dict[str, int]) -> dict[str, int]:
    stats = Counter()
    # Streaming mode never materializes or extracts the multi-gigabyte archive.
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            split = _mw_split(member.name)
            if split is None or not member.isfile():
                continue
            stream = archive.extractfile(member)
            if stream is None:
                continue
            with stream:
                annotation = _annotation(stream, {"normalizedLabel", "label"})
            if not annotation:
                stats[f"{split}_missing_label"] += 1
                continue
            stats[f"{split}_records"] += 1
            if split == "valid":
                labels, has_frac, unk_count = linearize(strip_math_delimiters(annotation))
                if not labels:
                    stats["valid_empty"] += 1
                    continue
                stats["valid_accepted"] += 1
                stats["valid_tokens"] += len(labels)
                if has_frac:
                    stats["valid_fractions"] += 1
                if unk_count / len(labels) > 0.10:
                    stats["valid_over_10pct_unk"] += 1
                else:
                    stats["valid_within_10pct_unk"] += 1
                valid_spool.write(" ".join(str(ids[label]) for label in labels) + "\n")
                continue
            result = _linearized(annotation)
            if result is None:
                stats[f"{split}_filtered"] += 1
                continue
            labels, has_frac, _ = result
            stats[f"{split}_accepted"] += 1
            if has_frac:
                stats[f"{split}_fractions"] += 1
            _count_sequence(counters, [ids[label] for label in labels], ids[START])
            record_count = stats[f"{split}_records"]
            if record_count % 50_000 == 0:
                print(f"MathWriting {split}: {record_count:,} records", flush=True)
    return dict(stats)


def _crohme_corpus(path: Path, counters: list[Counter[int]], ids: dict[str, int]) -> dict[str, int]:
    name = "Task1_and_Task2/Task1_and_Task2/Task1_onlineRec/MainTask_formula/Train.zip"
    stats = Counter()
    with zipfile.ZipFile(path) as outer:
        with tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024, mode="w+b") as nested_file:
            with outer.open(name) as source:
                while data := source.read(1024 * 1024):
                    nested_file.write(data)
            nested_file.seek(0)
            with zipfile.ZipFile(nested_file) as formulas:
                files = (member for member in formulas.infolist() if member.filename.lower().endswith(".inkml"))
                for member in files:
                    with formulas.open(member) as source:
                        truth = _annotation(source, {"truth"})
                    if not truth:
                        stats["missing_truth"] += 1
                        continue
                    stats["records"] += 1
                    result = _linearized(truth)
                    if result is None:
                        stats["filtered"] += 1
                        continue
                    labels, _, _ = result
                    _count_sequence(counters, [ids[label] for label in labels], ids[START])
                    stats["accepted"] += 1
                    record_count = stats["records"]
                    if record_count % 5_000 == 0:
                        print(f"CROHME formulas: {record_count:,} records", flush=True)
    return dict(stats)


def _count_sequence(counters: list[Counter[int]], sequence: list[int], start_id: int,
                    context_only: int = 0) -> None:
    """Count n-grams; the first `context_only` tokens serve only as context, never as predictions."""
    padded = [start_id, start_id, start_id, *sequence]
    size = len(VOCAB)
    for end in range(3 + context_only, len(padded)):
        for order in range(1, min(ORDER, end + 1) + 1):
            start = end - order + 1
            counters[order - 1][_encode(padded[start:end + 1], size)] += 1


def _decode(key: int, length: int, size: int) -> list[int]:
    result = [0] * length
    for index in range(length - 1, -1, -1):
        result[index] = key % size
        key //= size
    return result


def _encode(tokens: list[int], size: int) -> int:
    key = 0
    for token in tokens:
        key = key * size + token
    return key


def _continuations(raw: list[Counter[int]], size: int) -> list[Counter[int]]:
    counts = [Counter() for _ in range(ORDER)]
    for key in raw[1]:
        counts[0][key % size] += 1
    for key in raw[2]:
        counts[1][key % (size * size)] += 1
    for key in raw[3]:
        counts[2][key % (size ** 3)] += 1
    counts[3] = raw[3]
    return counts


def _discounts(values) -> tuple[float, float, float]:
    buckets = Counter(value for value in values if value <= 4)
    n1, n2, n3, n4 = (buckets[i] for i in range(1, 5))
    y = n1 / (n1 + 2 * n2) if n1 + 2 * n2 else 0.0
    estimates = (
        1 - 2 * y * n2 / n1 if n1 else 0.5,
        2 - 3 * y * n3 / n2 if n2 else 1.0,
        3 - 4 * y * n4 / n3 if n3 else 1.5,
    )
    return (min(1.0, max(0.0, estimates[0])),
            min(2.0, max(0.0, estimates[1])),
            min(3.0, max(0.0, estimates[2])))


def _discount(value: int, estimates: tuple[float, float, float]) -> float:
    return estimates[0] if value == 1 else estimates[1] if value == 2 else estimates[2]


def _key(tokens: list[str]) -> str:
    return "\x1f".join(tokens[:-1]) + "\x1e" + tokens[-1]


class LanguageModel:
    def __init__(self, vocab: list[str], ngrams: dict[str, list[float]]):
        self.vocab = tuple(vocab)
        self.vocab_set = set(vocab)
        self.ngrams = ngrams

    def log_prob(self, word: str, context: list[str] | tuple[str, ...] = ()) -> float:
        word = word if word in self.vocab_set else "<unk>"
        history = [token if token in self.vocab_set else "<unk>" for token in context][-ORDER + 1:]
        backoff = 0.0
        while history:
            probability = self.ngrams.get(_key([*history, word]))
            if probability is not None:
                return backoff + probability[0]
            context_row = self.ngrams.get(_key(history))
            if context_row is not None:
                backoff += context_row[1]
            history = history[1:]
        unigram = self.ngrams.get(_key([word]))
        return backoff + (unigram[0] if unigram is not None else -math.inf)


def _model(raw: list[Counter[int]], kn: list[Counter[int]], cutoff: int) -> dict[str, list[float]]:
    size = len(VOCAB)
    probs: list[dict[int, float]] = [{} for _ in range(ORDER + 1)]
    bows: list[dict[int, float]] = [{} for _ in range(ORDER + 1)]

    # Unigram continuation probabilities need a tiny closed-vocabulary floor for absent labels.
    total = sum(kn[0].values())
    floor = 1e-12
    denom = total + floor * sum(token not in kn[0] for token in range(size))
    probs[1] = {token: kn[0].get(token, floor) / denom for token in range(size)}
    discounts = {order: _discounts(kn[order - 1].values()) for order in range(2, ORDER + 1)}

    for order in range(2, ORDER + 1):
        totals: Counter[int] = Counter()
        kept: dict[int, list[tuple[int, int]]] = defaultdict(list)
        for key, count in kn[order - 1].items():
            context = key // size
            totals[context] += count
            if order < 3 or raw[order - 1].get(key, 0) >= cutoff:
                kept[context].append((key, count))
        for context, children in kept.items():
            denominator = totals[context]
            direct = [max(0.0, count - _discount(count, discounts[order])) / denominator
                      for _, count in children]
            alpha = max(1e-300, 1.0 - sum(direct))
            bows[order - 1][context] = alpha
            context_ids = _decode(context, order - 1, size)
            suffix = context_ids[1:]
            for (key, _), direct_probability in zip(children, direct):
                word_id = key % size
                backoff_probability = _probability(word_id, suffix, probs, bows, size)
                probs[order][key] = direct_probability + alpha * backoff_probability

    # A context can be needed for its bow even when it was never a predicted token
    # (the all-<s> line prefixes are the common case). Preserve its fallback score.
    for context_length in range(1, ORDER):
        for context in bows[context_length]:
            if context not in probs[context_length]:
                context_ids = _decode(context, context_length, size)
                probs[context_length][context] = _probability(
                    context_ids[-1], context_ids[:-1], probs, bows, size
                )

    ngrams: dict[str, list[float]] = {}
    for order in range(1, ORDER + 1):
        for key, probability in probs[order].items():
            tokens = [VOCAB[token] for token in _decode(key, order, size)]
            alpha = bows[order].get(key, 1.0) if order < ORDER else 1.0
            ngrams[_key(tokens)] = [math.log10(probability), math.log10(alpha)]
    return ngrams


def _probability(word: int, context: list[int], probs: list[dict[int, float]],
                 bows: list[dict[int, float]], size: int) -> float:
    backoff = 1.0
    history = context[-ORDER + 1:]
    while history:
        key = _encode([*history, word], size)
        probability = probs[len(history) + 1].get(key)
        if probability is not None:
            return backoff * probability
        context_key = _encode(history, size)
        backoff *= bows[len(history)].get(context_key, 1.0)
        history = history[1:]
    return backoff * probs[1][word]


def _payload(ngrams: dict[str, list[float]]) -> bytes:
    data = json.dumps({"order": ORDER, "vocab": VOCAB, "ngrams": ngrams},
                      ensure_ascii=False, separators=(",", ":"), sort_keys=True,
                      allow_nan=False).encode("utf-8") + b"\n"
    return data


def _fit(raw: list[Counter[int]]) -> tuple[int, dict[str, list[float]], bytes]:
    kn = _continuations(raw, len(VOCAB))
    cutoff = 2
    while True:
        ngrams = _model(raw, kn, cutoff)
        data = _payload(ngrams)
        if len(data) <= MAX_BYTES:
            return cutoff, ngrams, data
        cutoff += 1


def _queries(ngrams: dict[str, list[float]]) -> list[dict[str, object]]:
    model = LanguageModel(list(VOCAB), ngrams)
    queries: list[tuple[str, list[str]]] = [
        ("x", ["2"]), ("·", ["2"]), ("x", ["2", "+"]), ("·", ["2", "+"]),
        ("4", ["2", "x", "+"]), ("4", ["2", "·", "+"]),
        ("=", ["x", "+", "1"]), ("−", ["x", "="]), ("°", ["4", "5"]),
        ("→", ["x", "∞"]), ("√", ["±", "b"]), ("′", ["f"]),
        ("<unk>", ["<s>"]), ("x", ["∞", "∞", "∞"]),
        ("<s>", ["z", "z", "z"]), ("n", ["<s>", "<s>", "<s>"]),
        ("x", ["<s>"]), ("∫", ["<s>"]), ("π", ["sin"]),
    ]
    # Include one query that must back off from a pruned 4-gram context when available.
    labels = [label for label in VOCAB if label not in ("<s>", "<unk>")]
    for context in ([a, b, c] for a in labels for b in labels for c in labels):
        if len(queries) >= 20:
            break
        context_key = _key(list(context))
        context_row = ngrams.get(context_key)
        if context_row is None or context_row[1] == 0.0:
            continue
        for word in labels:
            if _key([*context, word]) not in ngrams:
                queries.append((word, list(context)))
                break
    rng = random.Random(SEED)
    while len(queries) < 50:
        size = rng.randrange(4)
        context = [rng.choice(VOCAB) for _ in range(size)]
        word = rng.choice(VOCAB)
        queries.append((word, context))
    unique: list[tuple[str, list[str]]] = []
    seen: set[tuple[str, tuple[str, ...]]] = set()
    for word, context in queries:
        identity = (word, tuple(context))
        if identity not in seen:
            seen.add(identity)
            unique.append((word, context))
    while len(unique) < 50:
        context = [rng.choice(VOCAB) for _ in range(rng.randrange(4))]
        query = (rng.choice(VOCAB), context)
        identity = (query[0], tuple(query[1]))
        if identity not in seen:
            seen.add(identity)
            unique.append(query)
    return [{"word": word, "context": context, "log10p": model.log_prob(word, context)}
            for word, context in unique[:50]]


def _validate_model(model: LanguageModel, queries: list[dict[str, object]]) -> dict[str, object]:
    contexts = {tuple(context) for context in ([], [START], [START, START],
                [START, START, START], ["2"], ["2", "x", "+"], ["z", "z", "z"])}
    contexts.update(tuple(query["context"]) for query in queries)
    errors = []
    for context in contexts:
        mass = sum(10 ** model.log_prob(word, context) for word in VOCAB)
        error = abs(mass - 1.0)
        errors.append(error)
        if error > 1e-9:
            raise ValueError(f"LM distribution does not normalize for {context}: {mass}")

    def sequence_score(words: list[str]) -> float:
        history = [START, START, START]
        score = 0.0
        for word in words:
            score += model.log_prob(word, history)
            history = [*history, word][-ORDER + 1:]
        return score

    x_after_2 = model.log_prob("x", ["2"])
    dot_after_2 = model.log_prob("·", ["2"])
    x_sequence = sequence_score(["2", "x", "+", "4"])
    dot_sequence = sequence_score(["2", "·", "+", "4"])
    return {
        "probability_mass_contexts": len(contexts),
        "max_probability_mass_error": max(errors, default=0.0),
        "log10p_x_given_2": x_after_2,
        "log10p_middle_dot_given_2": dot_after_2,
        "log10p_2_x_plus_4": x_sequence,
        "log10p_2_middle_dot_plus_4": dot_sequence,
        "x_sequence_outranks_middle_dot": x_sequence > dot_sequence,
    }


def _perplexity(model: LanguageModel, valid_spool) -> tuple[float, int, int]:
    valid_spool.seek(0)
    token_count = sequence_count = 0
    negative_log10 = 0.0
    ids_to_word = VOCAB
    for line in valid_spool:
        ids = [int(value) for value in line.split()]
        history = [START, START, START]
        for token_id in ids:
            word = ids_to_word[token_id]
            negative_log10 -= model.log_prob(word, history)
            history.append(word)
            history = history[-ORDER + 1:]
        token_count += len(ids)
        sequence_count += 1
    return (10 ** (negative_log10 / token_count) if token_count else math.inf,
            token_count, sequence_count)


def _score_labels(model: LanguageModel, labels: list[str]) -> float:
    history = [START, START, START]
    score = 0.0
    for word in labels:
        score += model.log_prob(word, history)
        history = [*history, word][-ORDER + 1:]
    return score


def _mw_valid_perplexity(path: Path, model: LanguageModel) -> dict[str, object]:
    stats = Counter()
    all_neg_log10 = low_unk_neg_log10 = 0.0
    all_tokens = low_unk_tokens = 0
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            if _mw_split(member.name) != "valid" or not member.isfile():
                continue
            stream = archive.extractfile(member)
            if stream is None:
                continue
            with stream:
                source = _annotation(stream, {"normalizedLabel", "label"})
            stats["records"] += 1
            if not source:
                stats["missing_label"] += 1
                continue
            labels, _, unk_count = linearize(strip_math_delimiters(source))
            if not labels:
                stats["empty"] += 1
                continue
            score = _score_labels(model, labels)
            all_neg_log10 -= score
            all_tokens += len(labels)
            stats["nonempty_sequences"] += 1
            stats["nonempty_tokens"] += len(labels)
            if unk_count / len(labels) > 0.10:
                stats["over_10pct_unk"] += 1
            else:
                stats["within_10pct_unk"] += 1
                low_unk_neg_log10 -= score
                low_unk_tokens += len(labels)
            if stats["records"] % 5_000 == 0:
                print(f"MathWriting valid: {stats['records']:,} records", flush=True)
    return {
        **dict(stats),
        "all_nonempty_perplexity": 10 ** (all_neg_log10 / all_tokens) if all_tokens else math.inf,
        "all_nonempty_tokens": all_tokens,
        "all_nonempty_sequences": stats["nonempty_sequences"],
        "within_10pct_unk_perplexity": 10 ** (low_unk_neg_log10 / low_unk_tokens) if low_unk_tokens else math.inf,
        "within_10pct_unk_tokens": low_unk_tokens,
        "within_10pct_unk_sequences": stats["within_10pct_unk"],
    }


def _self_check() -> None:
    ids = {label: index for index, label in enumerate(VOCAB)}
    size = len(VOCAB)
    raw = [Counter() for _ in range(ORDER)]
    for sequence in (["2", "x", "+", "4"], ["2", "x", "+", "4"], ["π", "Δ", "∞"]):
        _count_sequence(raw, [ids[label] for label in sequence], ids[START])
    assert raw[0][ids["2"]] == 2
    assert raw[1][_encode([ids[START], ids["2"]], size)] == 2
    assert raw[2][_encode([ids[START], ids[START], ids["2"]], size)] == 2
    assert raw[3][_encode([ids[START], ids[START], ids[START], ids["2"]], size)] == 2

    pruned_trigram = _encode([ids[START], ids["π"], ids["Δ"]], size)
    assert raw[2][pruned_trigram] == 1
    ngrams = _model(raw, _continuations(raw, size), cutoff=2)
    model = LanguageModel(list(VOCAB), ngrams)
    for context in ([], [START], ["2"], ["2", "x", "+"], ["z", "z", "z"]):
        mass = sum(10 ** model.log_prob(word, context) for word in VOCAB)
        assert math.isclose(mass, 1.0, rel_tol=0.0, abs_tol=1e-9), (context, mass)

    weighted = [Counter() for _ in range(ORDER)]
    for text, count in (("2x+4", 100), ("2y+3", 40), ("a+2", 7), ("x+1", 2)):
        sequence = [ids[label] for label in text]
        for _ in range(count):
            _count_sequence(weighted, sequence, ids[START])
    fitted = _model(weighted, _continuations(weighted, size), cutoff=2)
    weighted_model = LanguageModel(list(VOCAB), fitted)
    for context in ([START], [START, START], [START, START, START],
                    ["2"], ["2", "x", "+"], ["∞", "∞", "∞"]):
        mass = sum(10 ** weighted_model.log_prob(word, context) for word in VOCAB)
        assert math.isclose(mass, 1.0, rel_tol=0.0, abs_tol=1e-9), (context, mass)


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def train(args: argparse.Namespace) -> dict[str, object]:
    ids = {label: index for index, label in enumerate(VOCAB)}
    counters = [Counter() for _ in range(ORDER)]
    valid_tmp = tempfile.TemporaryFile(mode="w+t", encoding="ascii")
    mw_stats = _mw_corpus(args.mathwriting, valid_tmp, counters, ids)
    cr_stats = _crohme_corpus(args.crohme, counters, ids)
    real_count = mw_stats.get("train_accepted", 0) + mw_stats.get("synthetic_accepted", 0) + cr_stats.get("accepted", 0)
    grammar_count = real_count // 2
    for source in generate(grammar_count, SEED):
        result = _linearized(source)
        if result is None:
            raise ValueError(f"generated grammar expression did not linearize: {source}")
        _count_sequence(counters, [ids[label] for label in result[0]], ids[START])
    for labels, weight in function_word_sequences():
        sequence = [ids[label] for label in labels]
        # The prefix is context only, so these lines do not move the line-start distribution.
        for _ in range(weight):
            _count_sequence(counters, sequence, ids[START], context_only=1)
    cutoff, ngrams, data = _fit(counters)
    model = LanguageModel(list(VOCAB), ngrams)
    query_rows = _queries(ngrams)
    model_checks = _validate_model(model, query_rows)
    if not model_checks["x_sequence_outranks_middle_dot"]:
        raise ValueError("LM check failed: 2,x,+,4 does not outscore 2,·,+,4")
    perplexity, valid_tokens, valid_sequences = _perplexity(model, valid_tmp)
    valid_tmp.close()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)

    _write_json(args.fixtures / "lm-queries.json", query_rows)

    order_counts = Counter(
        1 if not key.split("\x1e", 1)[0]
        else len(key.split("\x1e", 1)[0].split("\x1f")) + 1
        for key in ngrams
    )
    stats = {
        "order": ORDER,
        "vocabulary": len(VOCAB),
        "vocab_items": list(VOCAB),
        "mathwriting": mw_stats,
        "crohme_formula_train": cr_stats,
        "grammar_sequences": grammar_count,
        "function_word_lines": len(function_word_sequences()),
        "function_word_line_weight": FUNCTION_LINE_WEIGHT,
        "pruning_count_order_3_plus": cutoff,
        "ngrams_by_order": {str(order): order_counts[order] for order in range(1, ORDER + 1)},
        "ngrams": len(ngrams),
        "file_bytes": len(data),
        "lm_checks": model_checks,
        "mw_valid_perplexity": perplexity,
        "mw_valid_tokens": valid_tokens,
        "mw_valid_sequences": valid_sequences,
    }
    return stats


def _main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mathwriting", type=Path,
                        default=root / "build/datasets/mathwriting-2024.tgz")
    parser.add_argument("--crohme", type=Path,
                        default=root / "build/datasets/Task1_and_Task2.zip")
    parser.add_argument("--output", type=Path, default=root / "Sources/CanvasKit/Resources/MathLM.json")
    parser.add_argument("--fixtures", type=Path, default=root / "Tests/CanvasKitTests/Fixtures/lm")
    parser.add_argument("--self-check", action="store_true", help="run fixed-corpus checks without archives")
    parser.add_argument("--perplexity-only", action="store_true",
                        help="score the existing model on every nonempty MathWriting valid line")
    args = parser.parse_args()
    if args.self_check:
        _self_check()
        print("LM fixed-corpus counts and probability-mass checks passed")
        return
    if args.perplexity_only:
        model_data = json.loads(args.output.read_text())
        model = LanguageModel(model_data["vocab"], model_data["ngrams"])
        print(json.dumps(_mw_valid_perplexity(args.mathwriting, model), ensure_ascii=False, indent=2))
        return
    print(json.dumps(train(args), ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    _main()
