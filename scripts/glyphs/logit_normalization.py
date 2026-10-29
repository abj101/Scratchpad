"""Post-hoc per-example logit normalization for selective confidence scoring."""

import math

import numpy as np


def normalize_logits(logits, p: float = 2.0) -> np.ndarray:
    """Center each class-logit vector and divide by its p-norm (paper Eq. 28).

    Tune ``p`` on validation data only. A zero vector stays zero; the input is
    not modified. The transformation preserves each row's class ordering.
    """
    values = np.asarray(logits, dtype=np.float64)
    if values.ndim < 1 or values.shape[-1] == 0 or not np.isfinite(values).all():
        raise ValueError("logits must be finite and have a nonempty class axis")
    if not math.isfinite(p) or p < 1:
        raise ValueError("p must be finite and at least 1")
    centered = values - values.mean(axis=-1, keepdims=True)
    norm = np.linalg.norm(centered, ord=p, axis=-1, keepdims=True)
    return centered / np.where(norm > 0, norm, 1.0)
