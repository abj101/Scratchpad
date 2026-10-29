# Math Recognition v2: allocation decision needed

**Resolved:** the plan now specifies Hamilton allocation above a two-sample
floor, all-zero-length allocation and deterministic arithmetic/resampling.
Ayush authorized resuming wave 1 only. The original evidence below is retained
as history; it is not a current blocker.

Stopped on 2026-10-03 at Ayush's instruction to defer actual blockers to Claude.

## Blocker

The pen-path contract allocates `max(2, round(128 * length / totalLength))`
samples per stroke, then fixes the total by removing samples from the longest
stroke. That correction cannot always preserve the two-sample minimum.

Reproduction (no datasets needed):

```python
lengths = [2, 1] + [0] * 62
counts = [max(2, round(128 * n / sum(lengths))) for n in lengths]
assert counts == [85, 43] + [2] * 62
assert sum(counts) == 252
assert counts[0] - (sum(counts) - 128) == -39
```

This input is within the explicit 64-stroke limit. The longest stroke can shed
only 83 samples while retaining two, but the excess is 124. Swift and Python
need the same agreed correction rule before implementation and parity fixtures.

Luna's proposed resolution, **not implemented**: repeatedly remove a sample
from the longest arc-length stroke whose allocation remains above two, breaking
ties in written order. Once that stroke reaches two, continue with the next
eligible stroke. Claude should also specify allocation when total arc length is
zero (including the required dot-tap fixture), and rounding ties across languages.

## Completed and preserved

- Local branch `codex/math-recognition-v2` from `8dadc1a`; no push.
- Downloaded both datasets under ignored `build/datasets/`; provenance in
  `SOURCES.json`, exact sizes and SHA-256 verified independently by root.
- CROHME `valid.zip`: Luna found all 986 InkML files have traceGroups; archives
  were inspected in memory. MathWriting was never extracted.
- Existing venv versions pinned in `scripts/glyphs/requirements-v2.txt`.
- `running.md` records supersession of R5–R7 math gates.
- Removed 1,910,789,758 logical bytes of obsolete reproducible build caches and
  duplicate synthetic check output. Preserved captures, source data, models,
  training reports, venv and active SwiftPM cache.
- Baseline `swift test`: 694 tests, zero failures, one opt-in benchmark skip.
  Debug `xcodebuild`: succeeded. Logs in `build/math-v2-baseline-*.log`.
- Vocabulary and sequence agents stopped before editing. No recognition code,
  training, calibration or test-set evaluation was performed.

Resume after Claude updates the pen-path contract; then execute wave 1.
