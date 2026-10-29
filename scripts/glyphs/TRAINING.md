# R5 stroke classifier

`train.py` accepts raw strokes only. It streams both original HWRT CSV members
from the bzip2 archive, ignores their original split, and assigns each `user_id`
to train or validation using SHA-256 of `20261003:hwrt:<writer>` (20% validation) with deterministic repair ensuring every source-backed group
has independent train and validation writers.
The two writer lists are asserted disjoint and retained in `prepare.json`.
HWRT ID aliases must belong to one canonical group; raw label counts use the
first vocabulary member for shared IDs. Every input record's group is recomputed
from the current vocabulary, including old synthetic JSONL files.

Synthetic Hershey/OFL records belong only to train. They have source families,
not writer IDs. Validation measures real writer transfer, and has no synthetic
augmentation copies. `validation_missing_labels` explicitly lists labels missing
from validation, including synthetic-only labels. Synthetic-only performance is
measured on the final held-out test. At least 300 train records per label are
required. Training never reads captures. No HASY PNGs, MathWriting or CROHME enter
the pipeline. Raw/synthetic/vocabulary/raster hashes, counts, source licenses and
writer membership are retained beside the raster cache.

## Run

After the canonical vocabulary and dot synthetic corpus are finalized:

```sh
python3 -m venv --system-site-packages build/glyph-venv
build/glyph-venv/bin/python -m pip install coremltools==9.0 numpy==1.26.4 scipy==1.17.0
build/glyph-venv/bin/python scripts/glyphs/train.py selfcheck
build/glyph-venv/bin/python scripts/glyphs/train.py prepare --hwrt build/hasy/2015-01-28-data.tar --synthetic build/glyph-synth/synthetic.jsonl
build/glyph-venv/bin/python scripts/glyphs/train.py train --hwrt build/hasy/2015-01-28-data.tar --synthetic build/glyph-synth/synthetic.jsonl
build/glyph-venv/bin/python scripts/glyphs/train.py export
build/glyph-venv/bin/python scripts/glyphs/train.py evaluate --capture build/glyph-capture
```

The default output is `build/glyph-training`; absolute data paths work from an
isolated worktree. Before training, the script checks the prepared vocabulary,
raster, HWRT archive and synthetic JSONL hashes against the live inputs, along
with the fixed seed, canonical groups and accepted split counts. `--workers` (default four), `--batch`, `--epochs`, `--device` and `--lr` control
preparation/training. Default training is 40 epochs, MPS, Adam at 0.001, batch 256,
class weights inverse to canonical group count, 0.25 dropout, Adam weight decay
of 0.0001, and a validation-accuracy plateau scheduler (factor 0.5, patience 4).
Only writer-held-out accuracy selects the checkpoint. Python, NumPy, Torch and
loader generators use seed 20261003; loader workers are zero. MPS operations may
have platform-dependent floating-point behavior; exact cross-machine training
equality is not claimed.

`evaluate` is deliberately final-only: it refuses to overwrite its report, and
prepare/train refuse to run once that output directory has a final test report.
Do not create a fresh directory to retrain on test errors. Capture remains Ayush's
immutable 790-record test set (five samples for each of 158 labels); no threshold
or checkpoint tuning uses its outcomes. Final test predictions come from the deployed FP16 `.mlmodelc` through
`coremltools.models.CompiledMLModel` with `ComputeUnit.ALL`; the report records
its backend and deterministic bundle hash. All reported accuracy is by canonical
group. Per-label accuracy means correctness of group prediction for records with
that source label; resolved-member accuracy is deferred to R6. Predictions retain
source filenames, runner-up probabilities and margins for the R6 audit. The report includes the full confusion matrix, per-group and per-label
accuracy, synthetic-only labels, and raw gate outcomes. Synthetic-only labels
below 85% are disabled; other labels whose group is below 95% are disabled.
Eligible-only accuracy is explicitly marked filtered and does not replace the
full 95% gate. Five-sample synthetic-only labels need five correct predictions.

## Core ML contract

One tiny convolution/pool CNN supplies a classifier over lexically sorted stable
canonical group IDs. Classifier input `glyphImage` is one 32×32 grayscale
`CVPixelBuffer` (`kCVPixelFormatType_OneComponent8`). Supply raster.py/GlyphRaster
bytes directly: black 0, white 255. Core ML ImageType scale is 1; the network
internally computes `1 - pixel / 255`. Swift must not invert or normalize again.
The classifier returns `group` and a probability dictionary keyed by every group
ID. The full vocabulary remains separate; group IDs are not resolved labels.

Export uses an FP16 ML Program (minimum macOS 13), compiles with
`xcrun coremlcompiler`, then loads the compiled bundle through
`CompiledMLModel` with `ComputeUnit.ALL`. It checks three fixed validation images
against PyTorch probabilities (maximum error <0.003). A compiled bundle of
1,000,000 bytes or more is rejected. `export.json` records actual output feature
names, compiled-model parity errors, source/checkpoint hashes and model size.
The final `MathGlyphs-manifest.json` holds stable groups, vocabulary hash,
`disabledLabels`, accuracy/coverage and fixed substitution thresholds 0.85/0.3.
No Swift integration is performed by this script.

Apple's [Core ML Tools 9 release](https://github.com/apple/coremltools/releases)
supports Python 3.12 and lists tested PyTorch 2.7. This run used PyTorch 2.9.1:
the selected model converted and compiled successfully, and its 288,988-byte FP16
bundle passed compiled `ComputeUnit.ALL` parity on validation indexes 0, 862 and
1724. Maximum probability error was 0.000522. This confirms this checkpoint's
conversion path; general PyTorch 2.9.1 support remains unlisted
([open support issue](https://github.com/apple/coremltools/issues/2615)). The
local venv pins NumPy 1.26.4 and SciPy 1.17.0 to avoid global NumPy 2.x and SciPy
import failures; global packages are unchanged.

The fixed-seed 40-epoch baseline selected epoch 13 at 86.5507% writer-validation
accuracy. One regularized run used dropout 0.25, Adam weight decay 0.0001 and a
validation-accuracy plateau scheduler; it was interrupted during epoch 33 after
32 complete epochs because no optimizer state was saved. Its best checkpoint was
epoch 23 at 88.05797%, selected over the baseline by validation accuracy. No
further training followed. The single final 790-record compiled-model evaluation
scored 75.5696% group top-1 (95% gate failed); the synthetic-only 85% gate also
failed, with 84 labels disabled and 46.8354% sample coverage. The full confusion
matrix, disabled-label list and filtered eligible-only score are in the final
`test-report.json` and `MathGlyphs-manifest.json` artifacts.
