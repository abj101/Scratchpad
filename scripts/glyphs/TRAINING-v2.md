# Math glyph v2 training

`train_v2.py` builds the 59-class raster-plus-pen-path model. It reads the prepared
MathWriting symbol, CROHME train/formula and isolated-symbol, and HWRT train pools, plus
the existing synthetic pool. CROHME's writer-held-out validation records and HWRT's
existing validation assignment form validation. It never opens `crohme-test` or any
capture file outside the immutable `CAP-tune` list.

When running from the training worktree, pass the main checkout's shared build directory
explicitly. Defaults otherwise stay under this repository's own `build/` directory.

```sh
PY=build/glyph-venv/bin/python
SCRIPT=scripts/glyphs/train_v2.py
BUILD="$(pwd)/build"
RUN=$BUILD/glyph-training-v2

$PY $SCRIPT selfcheck --build-dir "$BUILD"
$PY $SCRIPT prepare --build-dir "$BUILD" --output "$RUN"
$PY $SCRIPT train --build-dir "$BUILD" --output "$RUN"
# Optional repeatable report from the selected checkpoint:
$PY $SCRIPT report --build-dir "$BUILD" --output "$RUN"
$PY $SCRIPT export --precision mixed --build-dir "$BUILD" --checkpoint "$RUN/best.pt" --output "$RUN"
```

From a worktree, set `PY` and `BUILD` to the main checkout's existing environment
and shared build directory; set `SCRIPT` to that worktree's training script.

Supervised glyph labels map both `\times` and `×` to `x`, because they describe an
x-shaped stroke. The language-model linearizer separately maps multiplication to
`·`. Regenerate affected prepared sources after a mapping change before preparing
the feature cache.

`prepare.json` records source hashes, class counts, and the top-up policy. A class with
fewer than 2,000 real records is topped up from approved Hershey/Relief rows to 2,000;
if the source pool is smaller than its deficit, the fixed-seed sampler reuses rows with
replacement. The per-epoch sampler draws uniformly without replacement from each class
pool, up to 20,000 records per class.

For Wave 3 F3, run `prepare --include-harvest` in a fresh output directory after harvest
QA passes. It adds `datasets/mw-harvest-train.jsonl.gz` to training and the corresponding
`mw-harvest-valid.jsonl.gz` to validation; the cache and checkpoint record both hashes.

The cache keeps original XY points as Float64 in ragged point, stroke-offset, and
record-offset arrays. The loader augments these raw strokes, then derives both the 32×32
OneComponent8 raster and the 128×4 path features from that same ink. Its batched NumPy
raster matches `raster.py` byte-for-byte on the six raster fixtures and a fixed-seed
reservoir of 1,000 train records; `selfcheck` records both implementations' throughput in
`build/orchestration-v2-wave2/raster-throughput.json`.

Stroke globals use the first 64 nonempty raw point strokes, ignoring stroke width. They
are `[min(strokeCount, 6) / 6, clamp(ln(width / height), -3, 3) / 3]`, with each zero
dimension floored at `1e-6`. The self-check covers horizontal and vertical strokes, a tap,
a width-bearing `Stroke`, and the 64-stroke cutoff.

Every training sample receives rotation ±10°, shear ±0.3, x-scale 0.8–1.25, a smooth 3×3
elastic field with σ=0.08 of glyph size, and per-point jitter σ=0.01. With p=0.5, trackpad
simulation creates a fresh monotonic clock with uneven 8–16 ms intervals, resamples the
path, applies a three-tap average and 1–3% sinusoidal tremor, while preserving both stroke
endpoints. One stroke is reversed with p=0.2; multi-stroke order is permuted with p=0.1.
Source timestamps are discarded because MathWriting and HWRT use milliseconds while
CROHME may contain ordinal fallback times. The model path features themselves do not use
time.

Training defaults are seed 20261003, MPS, batch 512, eight loader workers, AdamW at 1e-3
with 1e-4 weight decay, label smoothing 0.05, and a 30-epoch cosine schedule. The selected
checkpoint maximizes aggregate top-1 accuracy on CROHME+HWRT validation. `metrics.json`
also reports per-class support/accuracy, macro class accuracy, and the most common
confusion pairs.

At the end of training, the script evaluates only the filenames in the `CAP-tune` array
from `datasets/cap-split.json`. Isolated label likelihood is class probability multiplied
by `resolver.member_weights`, using that capture's raw ink extent expanded by each stroke
style's width/2 and an empty line context. This accuracy is reported separately and never
selects a checkpoint. `CAP-test` remains unused.

The Core ML export is an ML Program with Float32 interfaces. Use `--precision mixed`
for trained weights: learned feature operations and output heads remain FP32,
while intermediate activations, pooling, and input normalization use FP16.
Ayush approved this Wave 2 exception on 2026-10-04 after pure FP16 missed the
0.003 parity gate. The 1,000,000-byte and 0.003 parity limits remain mandatory.
`--precision float16` remains the default for reproducing the dummy runtime check.
Export records the frozen training-script hash separately from the export-script
hash; data, vocabulary, raster, sequence, and selected-report lineage must still match.

The model interfaces are:

- `glyphImage`: grayscale 32×32 image, black 0 / white 255, scale 1
- `strokePoints`: `[1, 128, 4]`
- `strokeGlobals`: `[1, 2]`
- `logits`: `[1, 59]`
- `embedding`: `[1, 256]`, post-ReLU fused hidden layer before dropout and classification

Export compiles into the selected ignored build directory, rejects bundles over 1,000,000
bytes, and checks Core ML against PyTorch on five fixed inputs for both outputs (maximum
absolute error below 3e-3). The v2 manifest includes the sorted class IDs, vocabulary and
MathLM hashes, compiled bundle hash, decoder defaults, disabled-label field, and training
metrics. `disabledLabels` is empty for this bootstrap checkpoint; no capture score is used
to disable a model class.

For Wave 3, export with `--calibration <validation-calibration.json>` and the explicit
`--language-model Sources/CanvasKit/Resources/MathLM.json`. Export verifies the calibrated
checkpoint, selected epoch, vocabulary and LM hashes, and validation precision/harmful
swap gates before applying temperature, lambda, thresholds and disabled labels.
`calibrate_v2.py calibrate` fits NLL temperature on the selected checkpoint's full
validation cache and searches decoder settings on CROHME writer-validation expressions.
Its `test-once` command runs the final TEST-C/CAP-test report only after calibration and
export; an exclusive consumption marker and report prevent accidental repeat access.
Calibration caches each expression's result over the exact threshold interval where
all substitution decisions remain identical, separately for each lambda, revision
threshold and disabled-label set. Ratios are recomputed from summed integer counts;
the full search grid, label rules and gates remain unchanged.

To produce a runtime-only model before training, export a seeded instance of the same
architecture. It writes only to the ignored shared build directory:

```sh
$PY $SCRIPT export --dummy --output "$BUILD/orchestration-v2-wave2/dummy"
```

The dummy contains no trained weights and is only for native input/output loading and
inference checks. It does not alter bundled production resources.
