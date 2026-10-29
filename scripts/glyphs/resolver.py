"""Geometry-based weights for members of merged math glyph classes."""

import json
import math
from pathlib import Path
from typing import Mapping, Sequence


ROOT = Path(__file__).resolve().parents[2]
VOCABULARY = json.loads((ROOT / "Sources/CanvasKit/Resources/math-vocab.json").read_text())
CLASS_LABELS = {entry["id"]: tuple(entry["labels"]) for entry in VOCABULARY["classes"]}


def _sigmoid(value: float) -> float:
    scaled = value / 0.05
    if scaled >= 0:
        return 1 / (1 + math.exp(-scaled))
    exponential = math.exp(scaled)
    return exponential / (1 + exponential)


def _height(value: object) -> float | None:
    if isinstance(value, (int, float)) and math.isfinite(value) and value > 0:
        return float(value)
    return None


def member_weights(class_id: str, bounds: Sequence[float],
                   context: Mapping[str, object]) -> dict[str, float]:
    """Return normalized label weights for a v2 class and CGRect-style bounds."""
    if class_id == "junk":
        return {"<unk>": 1.0}
    # New singleton classes must resolve before the staging vocab is shipped.
    fixed_singletons = {"glyph_u006C": "l", "glyph_u0071": "q",
                        "glyph_u007B": "{", "glyph_u007D": "}"}
    if class_id in fixed_singletons:
        return {fixed_singletons[class_id]: 1.0}
    members = CLASS_LABELS.get(class_id)
    if members is None:
        return {}
    if len(members) == 1:
        return {members[0]: 1.0}

    math_mode = context.get("mode", "math") == "math"
    if class_id == "bar":
        if math_mode:
            return {"1": 0.95, "|": 0.05}
        return {"1": 0.5, "|": 0.5}

    neutral = {
        "dot": {".": 0.5, "·": 0.5},
        "tick": {",": 0.5, "′": 0.5},
        "ring": ({"0": 0.855, "o": 0.095, "°": 0.05} if math_mode
                 else {"0": 0.45, "o": 0.45, "°": 0.1}),
    }[class_id]
    height = _height(context.get("medianHeight"))
    baseline_value = context.get("baseline")
    if (height is None or not math.isfinite(height) or
            not isinstance(baseline_value, (int, float)) or not math.isfinite(baseline_value)):
        return neutral

    if len(bounds) != 4:
        return neutral
    try:
        x, y, width, box_height = map(float, bounds)
    except (TypeError, ValueError):
        return neutral
    if not all(map(math.isfinite, (x, y, width, box_height))):
        return neutral
    if width < 0:
        x, width = x + width, -width
    if box_height < 0:
        y, box_height = y + box_height, -box_height

    raised = (float(baseline_value) - (y + box_height / 2)) / height
    size = max(width, box_height) / height
    if class_id == "dot":
        dot = _sigmoid(raised - 0.30)
        return {".": 1 - dot, "·": dot}
    if class_id == "tick":
        prime = _sigmoid(raised - 0.45)
        return {",": 1 - prime, "′": prime}
    degree = _sigmoid(raised - 0.55) * _sigmoid(0.45 - size)
    if math_mode:
        return {"0": 0.9 * (1 - degree), "o": 0.1 * (1 - degree), "°": degree}
    return {"0": (1 - degree) / 2, "o": (1 - degree) / 2, "°": degree}


def _self_check() -> None:
    fixtures = json.loads((ROOT / "Tests/CanvasKitTests/Fixtures/resolver/resolver-fixtures.json").read_text())
    assert len(fixtures) == 24
    assert member_weights("glyph_u0071", (0, 0, 2, 2), {}) == {"q": 1.0}
    assert member_weights("glyph_u006C", (0, 0, 2, 2), {}) == {"l": 1.0}
    assert member_weights("glyph_u007B", (0, 0, 2, 2), {}) == {"{": 1.0}
    assert member_weights("glyph_u007D", (0, 0, 2, 2), {}) == {"}": 1.0}
    for fixture in fixtures:
        actual = member_weights(fixture["classID"], fixture["bounds"], fixture["context"])
        expected = fixture["expected"]
        assert actual.keys() == expected.keys(), fixture["name"]
        assert all(math.isclose(actual[label], value, rel_tol=0, abs_tol=1e-9)
                   for label, value in expected.items()), fixture["name"]
        assert math.isclose(sum(actual.values()), 1, rel_tol=0, abs_tol=1e-9), fixture["name"]
    print(f"resolver parity self-check passed ({len(fixtures)} fixtures)")


if __name__ == "__main__":
    _self_check()
