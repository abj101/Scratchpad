#!/usr/bin/env python3
"""Seeded algebra/calculus expressions for language-model top-up."""

from __future__ import annotations

import random
from typing import Callable, Iterator


VARIABLES = ("x", "y", "z", "t", "n", "a", "b")


def generate(count: int, seed: int = 20261003) -> Iterator[str]:
    """Generate ``count`` expressions, choosing each listed template uniformly."""
    rng = random.Random(seed)

    def integer() -> int:
        return rng.randint(1, 999)

    def variable() -> str:
        return rng.choice(VARIABLES)

    templates: tuple[Callable[[], str], ...] = (
        lambda: f"{integer()}{(x := variable())} + {integer()} = {integer()}",
        lambda: f"f(x) = {integer()}x2 - {integer()}x + {integer()}",
        lambda: f"d/dx({(x := variable())}2 + {integer()}{x})",
        lambda: "dy/dx",
        lambda: f"f′(x) = {integer()}x + {integer()}",
        lambda: f"∫ {(x := variable())}2 d{x}",
        lambda: f"∫_0^1 ({(x := variable())} + {integer()}) d{x}",
        lambda: f"lim x → 0 sin x / x",
        lambda: f"lim n → ∞ (1 + 1/n)^n",
        lambda: r"\sin\theta",
        lambda: f"cos({integer()}{variable()})",
        lambda: f"tan {variable()}",
        lambda: f"log {integer()} {integer()} = {integer()}",
        lambda: f"ln e = {integer()}",
        lambda: f"∑ n = 1 ∞ 1/n2",
        lambda: f"{variable()}!",
        lambda: f"{variable()} ≤ {integer()}",
        lambda: f"|{(x := variable())} - {integer()}| < {integer()}",
        lambda: f"x = (-b ± √(b2 - {integer()}ac)) / ({integer()}a)",
        lambda: f"{integer()}.{integer() % 100:02d}",
        lambda: f"{integer()}.{integer() % 10}{variable()}",
        lambda: f"f({variable()}, {variable()})",
        lambda: f"sin {integer()}°",
        lambda: "Δy / Δx",
    )

    for _ in range(count):
        yield rng.choice(templates)()


def _self_check() -> None:
    assert list(generate(24)) == list(generate(24))
    assert len(list(generate(101))) == 101


if __name__ == "__main__":
    _self_check()
    print("grammar self-check passed")
