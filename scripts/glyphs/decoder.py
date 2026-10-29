"""Decode a short math line with exact order-4 forward-backward inference."""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
from pathlib import Path
from typing import Callable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[2]
START = "<s>"
UNK = "<unk>"
WINDOW = 12
LOG10_TO_LN = math.log(10.0)


@dataclass(frozen=True)
class Symbol:
    label_likelihoods: Mapping[str, float]
    displayed_label: str | None = None
    is_virtual: bool = False
    is_pinned: bool = False


@dataclass(frozen=True)
class Update:
    index: int
    label: str
    marginal: float


@dataclass(frozen=True)
class DecodeResult:
    symbols: tuple[Symbol, ...]
    marginals: tuple[dict[str, float], ...]
    substitution: Update | None
    revisions: tuple[Update, ...]

    def alternatives_at(self, index: int) -> list[tuple[str, float]]:
        if not 0 <= index < len(self.marginals):
            return []
        displayed = self.symbols[index].displayed_label or UNK
        return sorted(
            ((label, probability) for label, probability in self.marginals[index].items()
             if label not in (displayed, UNK) and probability >= 0.02),
            key=lambda item: (-item[1], item[0]),
        )[:3]


def _log_add(first: float, second: float) -> float:
    if first == -math.inf:
        return second
    if second == -math.inf:
        return first
    high, low = (first, second) if first >= second else (second, first)
    return high + math.log1p(math.exp(low - high))


def _log_sum(values: Sequence[float]) -> float:
    total = -math.inf
    for value in values:
        total = _log_add(total, value)
    return total


class MathLineDecoder:
    """Run a 12-token forward-backward pass over label likelihood lattices."""

    def __init__(self, log_prob: Callable[[str, Sequence[str]], float],
                 lambda_: float = 0.6, tau_sub: float = 0.80,
                 tau_rev: float = 0.90, disabled_labels: Sequence[str] = (),
                 tau_fill: float | None = None):
        self.log_prob = log_prob
        self.lambda_ = lambda_
        self.tau_sub = tau_sub
        self.tau_rev = tau_rev
        self.tau_fill = tau_rev if tau_fill is None else tau_fill
        self.disabled_labels = frozenset(disabled_labels)

    @staticmethod
    def _candidates(symbol: Symbol) -> list[tuple[str, float]]:
        if symbol.is_pinned:
            return [(symbol.displayed_label or UNK, 0.0)]

        entries = [(label, float(value)) for label, value in sorted(symbol.label_likelihoods.items())
                   if math.isfinite(value) and value > 0]
        if symbol.is_virtual:
            if not entries:
                return [(symbol.displayed_label or UNK, 0.0)]
            label = min(entries, key=lambda item: (-item[1], item[0]))[0]
            return [(label, 0.0)]

        total = 0.0
        for _, value in entries:
            total += value
        if total <= 0:
            return [(UNK, 0.0)]
        return [(label, math.log(value / total)) for label, value in entries]

    @classmethod
    def _fixed_label(cls, symbol: Symbol) -> str:
        if symbol.is_pinned:
            return symbol.displayed_label or UNK
        if symbol.is_virtual:
            return cls._candidates(symbol)[0][0]
        return symbol.displayed_label or UNK

    @staticmethod
    def _next_state(history: tuple[str, ...], label: str) -> tuple[str, ...]:
        return (*history, label)[-3:]

    # The shipped LM has no q or braces; score them as p, [ and ] only,
    # never for output.
    LM_STANDIN = {"q": "p", "{": "[", "}": "]"}

    def _transition(self, label: str, likelihood: float,
                    history: tuple[str, ...]) -> float:
        word = self.LM_STANDIN.get(label, label)
        context = tuple(self.LM_STANDIN.get(token, token) for token in history)
        return likelihood + self.lambda_ * LOG10_TO_LN * self.log_prob(word, context)

    def decode(self, symbols: Sequence[Symbol], newest_index: int | None = None,
               revision_indices: Sequence[int] | None = None) -> DecodeResult:
        symbols = tuple(symbols)
        count = len(symbols)
        newest = count - 1 if newest_index is None else newest_index
        empty = DecodeResult(symbols, tuple({} for _ in symbols), None, ())
        if not count or not 0 <= newest < count or symbols[newest].is_virtual:
            return empty

        end = newest + 1 if newest_index is not None else count
        start = max(0, end - WINDOW)
        prefix = [self._fixed_label(symbol) for symbol in symbols[:start]]
        initial = tuple(([START] * max(0, 3 - len(prefix)) + prefix)[-3:])
        rows = [self._candidates(symbol) for symbol in symbols[start:end]]
        length = len(rows)

        # State is the last three labels. Each layer contains the summed log mass
        # of every path that reaches that history.
        forward: list[dict[tuple[str, ...], float]] = [{initial: 0.0}]
        for row in rows:
            next_layer: dict[tuple[str, ...], float] = {}
            for history, prefix_score in sorted(forward[-1].items()):
                for label, likelihood in row:
                    score = prefix_score + self._transition(label, likelihood, history)
                    state = self._next_state(history, label)
                    next_layer[state] = _log_add(next_layer.get(state, -math.inf), score)
            forward.append(next_layer)

        backward: list[dict[tuple[str, ...], float]] = [{} for _ in range(length + 1)]
        backward[length] = {state: 0.0 for state in forward[length]}
        for position in range(length - 1, -1, -1):
            layer: dict[tuple[str, ...], float] = {}
            for history in sorted(forward[position]):
                score = -math.inf
                for label, likelihood in rows[position]:
                    next_state = self._next_state(history, label)
                    suffix_score = backward[position + 1].get(next_state, -math.inf)
                    score = _log_add(score, self._transition(label, likelihood, history) + suffix_score)
                layer[history] = score
            backward[position] = layer

        log_partition = _log_sum(list(forward[length].values()))
        marginal_rows: list[dict[str, float]] = [{self._fixed_label(s): 1.0} for s in symbols[:start]]
        for position, row in enumerate(rows):
            label_scores = {label: -math.inf for label, _ in row}
            for history, prefix_score in sorted(forward[position].items()):
                for label, likelihood in row:
                    state = self._next_state(history, label)
                    suffix_score = backward[position + 1].get(state, -math.inf)
                    value = prefix_score + self._transition(label, likelihood, history) + suffix_score
                    label_scores[label] = _log_add(label_scores[label], value)
            if log_partition == -math.inf:
                marginal_rows.append({label: 0.0 for label, _ in row})
            else:
                marginal_rows.append({
                    label: min(1.0, math.exp(score - log_partition)) if score != -math.inf else 0.0
                    for label, score in sorted(label_scores.items())
                })
        marginal_rows.extend({self._fixed_label(symbol): 1.0} for symbol in symbols[end:])

        def best(index: int) -> tuple[str, float]:
            distribution = marginal_rows[index]
            return min(distribution.items(), key=lambda item: (-item[1], item[0]))

        substitution = None
        if not symbols[newest].is_pinned:
            label, probability = best(newest)
            if (label != UNK and label not in self.disabled_labels and
                    probability >= self.tau_sub):
                substitution = Update(newest, label, probability)

        earlier = (list(revision_indices) if revision_indices is not None else
                   [index for index in range(newest) if not symbols[index].is_virtual][-2:])
        revisions = []
        for index in earlier:
            if not 0 <= index < count or index == newest or symbols[index].is_virtual:
                continue
            symbol = symbols[index]
            if symbol.is_pinned:
                continue
            label, probability = best(index)
            displayed_probability = marginal_rows[index].get(symbol.displayed_label or UNK, 0.0)
            if (label != (symbol.displayed_label or UNK) and label != UNK and
                    label not in self.disabled_labels and
                    probability >= (self.tau_fill if symbol.displayed_label is None else self.tau_rev) and
                    (symbol.displayed_label is None or displayed_probability <= 0.10)):
                revisions.append(Update(index, label, probability))

        return DecodeResult(symbols, tuple(marginal_rows), substitution, tuple(revisions))


def _load_fixture_model() -> tuple[MathLineDecoder, list[dict[str, object]]]:
    from lm import LanguageModel

    model_data = json.loads((ROOT / "Sources/CanvasKit/Resources/MathLM.json").read_text())
    fixture_path = ROOT / "Tests/CanvasKitTests/Fixtures/decoder/decoder-fixtures.json"
    fixtures = json.loads(fixture_path.read_text())
    model = LanguageModel(model_data["vocab"], model_data["ngrams"])
    return MathLineDecoder(model.log_prob), fixtures


def _assert_close(actual: float, expected: float, name: str) -> None:
    assert math.isclose(actual, expected, rel_tol=0.0, abs_tol=1e-9), (name, actual, expected)


def _self_check() -> None:
    decoder, fixtures = _load_fixture_model()
    assert len(fixtures) == 18
    for fixture in fixtures:
        symbols = [Symbol(
            token["labelLikelihoods"], token.get("displayedLabel"),
            token.get("isVirtual", False), token.get("isPinned", False),
        ) for token in fixture["symbols"]]
        result = MathLineDecoder(
            decoder.log_prob, float(fixture.get("lambda", 0.6)),
            float(fixture.get("tauSub", 0.8)), float(fixture.get("tauRev", 0.9)),
            fixture.get("disabledLabels", ()), fixture.get("tauFill"),
        ).decode(symbols, fixture.get("newestIndex"), fixture.get("revisionIndices"))
        expected = fixture["expected"]
        assert len(result.marginals) == len(expected["marginals"]), fixture["name"]
        for index, row in enumerate(expected["marginals"]):
            assert result.marginals[index].keys() == row.keys(), (fixture["name"], index)
            for label, value in row.items():
                _assert_close(result.marginals[index][label], value, f'{fixture["name"]}:{index}:{label}')
        actual_substitution = None if result.substitution is None else result.substitution.__dict__
        assert actual_substitution == expected["substitution"], fixture["name"]
        assert [update.__dict__ for update in result.revisions] == expected["revisions"], fixture["name"]
        actual_alternatives = [result.alternatives_at(i) for i in range(len(symbols))]
        for index, (actual, target) in enumerate(zip(actual_alternatives, expected["alternatives"])):
            assert len(actual) == len(target), (fixture["name"], index)
            for (label, probability), expected_item in zip(actual, target):
                assert label == expected_item["label"], (fixture["name"], index)
                _assert_close(probability, expected_item["marginal"], f'{fixture["name"]}:alt:{index}:{label}')
    print(f"decoder parity self-check passed ({len(fixtures)} fixtures)")


if __name__ == "__main__":
    _self_check()
