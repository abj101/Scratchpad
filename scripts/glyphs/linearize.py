#!/usr/bin/env python3
"""Flatten supported MathWriting/CROHME LaTeX into the math label vocabulary."""

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


_TOKEN = re.compile(r"\\[A-Za-z]+|\\.|[^\s]", re.S)
_DIRECT = set("0123456789abcdefghijklmnoprstuvwxyz+=<>/!()[]|.,")
_UNICODE = set("−·÷≠≤≥±√∫∑πθΔ∞→°′")
_COMMANDS = {
    r"\cdot": "·", r"\times": "·", r"\div": "÷", r"\pm": "±",
    r"\neq": "≠", r"\ne": "≠", r"\leq": "≤", r"\le": "≤",
    r"\geq": "≥", r"\ge": "≥", r"\|": "|", r"\vert": "|",
    r"\mid": "|", r"\lvert": "|", r"\rvert": "|", r"'": "′",
    r"\prime": "′", r"\sqrt": "√", r"\int": "∫", r"\sum": "∑",
    r"\pi": "π", r"\theta": "θ", r"\Delta": "Δ", r"\infty": "∞",
    r"\to": "→", r"\rightarrow": "→",
}
_FUNCTIONS = (r"\lim", r"\sin", r"\cos", r"\tan", r"\log", r"\ln",
              r"\exp", r"\sec", r"\csc", r"\cot")
_DROP = {r"\left", r"\right", r"\,", r"\;", r"\quad", r"\!", r"\:"}


def _tokens(source: str) -> list[str]:
    return _TOKEN.findall(source)


def _group_end(tokens: list[str], start: int) -> int | None:
    if start >= len(tokens) or tokens[start] != "{":
        return None
    depth = 0
    for i in range(start, len(tokens)):
        if tokens[i] == "{":
            depth += 1
        elif tokens[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return None


def linearize(source: str, extra_direct: str = "") -> tuple[list[str], bool, int]:
    r"""Return ``(labels, has_frac, unk_count)`` for one normalized LaTeX string.

    ``extra_direct`` adds single-character tokens that count as known labels. The
    harvest uses it for ``q``, which has a glyph class but no LM label, and for the
    braces ``{``/``}``, whose escaped LaTeX forms ``\{``/``\}`` are the printed
    glyphs while their bare forms are grouping and are consumed above.
    """
    tokens = _tokens(source)
    has_frac = False
    direct = _DIRECT | set(extra_direct)

    def parse(start: int, end: int, superscript: bool = False) -> list[str]:
        nonlocal has_frac
        result: list[str] = []
        i = start
        while i < end:
            token = tokens[i]
            if token == "}":
                i += 1
            elif token == "{":
                close = _group_end(tokens, i)
                if close is None or close >= end:
                    result.append("<unk>")
                    i += 1
                else:
                    result.extend(parse(i + 1, close, superscript))
                    i = close + 1
            elif token in ("^", "_"):
                script_super = token == "^"
                i += 1
                if i < end and tokens[i] == "{":
                    close = _group_end(tokens, i)
                    if close is None or close >= end:
                        result.append("<unk>")
                        i += 1
                    else:
                        result.extend(parse(i + 1, close, script_super))
                        i = close + 1
                elif i < end:
                    result.extend(parse(i, i + 1, script_super))
                    i += 1
            elif token == r"\frac":
                has_frac = True
                i += 1
                args: list[list[str]] = []
                for _ in range(2):
                    if i >= end:
                        args.append(["<unk>"])
                    elif tokens[i] == "{":
                        close = _group_end(tokens, i)
                        if close is None or close >= end:
                            args.append(["<unk>"])
                            i += 1
                        else:
                            args.append(parse(i + 1, close, superscript))
                            i = close + 1
                    else:
                        args.append(parse(i, i + 1, superscript))
                        i += 1
                if all(len(argument) == 1 for argument in args):
                    result.extend((*args[0], "/", *args[1]))
                else:
                    result.extend(("(", *args[0], ")", "/", "(", *args[1], ")"))
            elif token in _DROP:
                i += 1
            elif token in _FUNCTIONS:
                result.extend(token[1:])
                i += 1
            elif token in (r"\mathrm", r"\operatorname"):
                i += 1
                if i < end and tokens[i] == "{":
                    close = _group_end(tokens, i)
                    if close is not None and close < end:
                        result.extend(parse(i + 1, close, superscript))
                        i = close + 1
                    else:
                        result.append("<unk>")
                else:
                    result.append("<unk>")
            elif token == r"\sqrt":
                result.append("<unk>" if i + 1 < end and tokens[i + 1] == "[" else "√")
                i += 1
            elif token == r"\circ":
                result.append("°" if superscript else "<unk>")
                i += 1
            elif token in _COMMANDS:
                result.append(_COMMANDS[token])
                i += 1
            elif token == "-":
                result.append("−")
                i += 1
            elif len(token) == 2 and token.startswith("\\") and token[1].isspace():
                i += 1
            elif len(token) == 2 and token.startswith("\\") and token[1] in set(extra_direct):
                # Escaped punctuation the caller declared direct, e.g. \{ and \}.
                # Gated on extra_direct so no existing caller changes behaviour.
                result.append(token[1])
                i += 1
            elif len(token) == 1 and token in direct | _UNICODE:
                result.append(token)
                i += 1
            else:
                result.append("<unk>")
                i += 1
        return result

    labels = parse(0, len(tokens))
    return labels, has_frac, labels.count("<unk>")


def _golden_case(case: dict[str, object]) -> None:
    assert linearize(str(case["source"])) == (
        list(case["labels"]), bool(case["has_frac"]), int(case["unk_count"])
    )


def _install_golden_tests() -> None:
    path = Path(__file__).resolve().parents[2] / "Tests/CanvasKitTests/Fixtures/lm/linearize-goldens.json"
    if not path.exists():
        return
    cases = json.loads(path.read_text())
    sources = [str(case["source"]) for case in cases]
    if len(cases) != 40 or len(set(sources)) != 40:
        raise AssertionError("linearize goldens must contain 40 distinct MathWriting train rows")
    for index, case in enumerate(cases):
        def test(self: unittest.TestCase, item: dict[str, object] = case) -> None:
            _golden_case(item)
        setattr(LinearizeGoldenTests, f"test_mw_train_label_{index + 1:02d}", test)


class LinearizeGoldenTests(unittest.TestCase):
    """One independent assertion per real MathWriting train annotation."""


class LinearizeContractTests(unittest.TestCase):
    def test_fraction_wraps_both_arguments_when_either_is_compound(self) -> None:
        self.assertEqual(linearize(r"\frac{a+b}{c}"), (["(", "a", "+", "b", ")", "/", "(", "c", ")"], True, 0))

    def test_fraction_with_two_single_labels_stays_flat(self) -> None:
        self.assertEqual(linearize(r"\frac{a}{b}"), (["a", "/", "b"], True, 0))

    def test_commands_functions_and_spacing(self) -> None:
        self.assertEqual(linearize(r"\left(\sin x\right)\,\cdot\,\cos\theta"),
                         (["(", "s", "i", "n", "x", ")", "·", "c", "o", "s", "θ"], False, 0))
        self.assertEqual(linearize(r"\lim_{x\to\infty}\log x"),
                         (["l", "i", "m", "x", "→", "∞", "l", "o", "g", "x"], False, 0))

    def test_raised_prime_and_circle(self) -> None:
        self.assertEqual(linearize(r"x^{\prime}+x^{\circ}"),
                         (["x", "′", "+", "x", "°"], False, 0))

    def test_optional_sqrt_index_is_unknown(self) -> None:
        self.assertEqual(linearize(r"\sqrt[3]{x}"), (["<unk>", "[", "3", "]", "x"], False, 1))

    def test_mathrm_flattens_and_unknown_letters_are_counted(self) -> None:
        self.assertEqual(linearize(r"\mathrm{sin}+Q+q+\Delta"),
                         (["s", "i", "n", "+", "<unk>", "+", "<unk>", "+", "Δ"], False, 2))


_install_golden_tests()


if __name__ == "__main__":
    unittest.main()
