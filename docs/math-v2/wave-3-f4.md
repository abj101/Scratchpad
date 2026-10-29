**Before you start:** Read [README.md](README.md), [contracts.md](contracts.md), [wave-3.md](wave-3.md) and [selective-validation-audit.md](selective-validation-audit.md).

[Back to Wave 3](wave-3.md)

---

# Wave 3 amendment: candidate F4 (junk class, case-fold scoring, τ_fill)

Approved by Ayush on 2026-10-05. This is a **third model candidate**, allowed by explicit decision, outside Wave 3's one-second-candidate rule. Every change below was chosen from **validation data only**. TEST-C and CAP-test are still unused.

## Why

On F3-second, validation only, from `build/orchestration-v2-wave3/fill-sweep.json`:

- Substitutions and fill-ins have the same precision at the same threshold. Right-hand context does not rescue precision.
- **70–80% of the remaining wrong swaps are on out-of-vocabulary (`<unk>`) truths.** The model has no class for those symbols, so they are forced into a lookalike class.
  - Global threshold, τ_fill = 0.97: 67 wrong, 48 of them on `<unk>` truths.
  - On known symbols alone, precision is 99.05% at 74.2% coverage.
- The most frequent `<unk>` truths in validation, out of 454 total:
  - Function words: `\sin` 56, `\log` 28, `\cos` 16, `\lim` 7.
  - Capitals and Greek: X 30, α 26, E 20, β 19, F 18, q 17, N 16, P 15, M 13, T 13, C 13, …
- Calibration disabled `x`, `c`, `p`, `k`, `y` and other labels, mostly because their capital lookalikes were being swapped into them.

## Decisions (Ayush, 2026-10-05)

1. **Case is not the glyph model's job.**
   - The Apple Intelligence correction pass fixes capitalization.
   - Capitals whose handwritten shape matches the lowercase letter count as **that lowercase label**, both in training and in scoring.
   - Capitals in math are often less important.
2. **No size or position features.** Trackpad writing scale is too random. Don't add context-geometry inputs to the model.
3. **Add a junk class.** The other out-of-vocab symbols get a reject class, so they stay as ink.
4. **New classes (α β μ φ q { }) are deferred.** They would need the shipped LM rebuilt (SHA pinned in contracts.md), and `{ }` collides with LaTeX grouping in the linearizer. They're about 1.6% of symbols. The junk class covers the precision side.
5. **Thresholds.** Use one global τ_sub plus a new **τ_fill** for ink → glyph revisions. τ_rev still gates glyph → glyph corrections.
   - Per-label thresholds are dropped; they overfit (99.15% on the selection half, 98.29% on the gate half).
   - Logit normalization is dropped; it traded too much coverage for too little precision.
6. **Function words are excluded from scoring.** CROHME labels `\sin` and similar as a single symbol. The app writes them as separate letters and has its own function-name path.
7. **The coverage gate changes.** It becomes **≥ 75% of known symbols** (it was ≥ 85% of all symbols). This lowers a gate after seeing validation results. Ayush approved it explicitly, and it is logged as that.

## Ground rules (unchanged unless stated)

- **No test access** until step 7, and then exactly once.
- Long runs (more than ~5 min) are handed off to Ayush, never run by the agent. Use the pattern in [wave-3.md](wave-3.md): one foreground command that tees to `build/orchestration-v2-wave3/<run>.log` and writes `<run>.done` with the exit code. The agent gives an estimated duration and stops. When Ayush says "done", it reads only the `.done` file, the summary JSON and the last ~20 log lines.
- The DEBUG recognition log is never data.
- **Do not touch shipped resources** (`Sources/CanvasKit/Resources/math-vocab.json`, `MathGlyphs.*`, the manifest, `MathLM.json`) until step 8. The app must keep loading the current model throughout.
- **Do not rewrite the existing dataset files** in `build/datasets/` (`*-train/valid/test.jsonl.gz`). F3-second's checkpoint lineage check hashes them. New data goes into new files.
- The working tree already contains uncommitted, reviewed changes from 2026-10-05. Build on them; don't revert them:
  - `scripts/glyphs/calibrate_v2.py`:
    - `simulate(..., tau_fill=None)`, plus the `finalByPath` breakdown (`substitution` / `fill` / `correction` / `fraction`).
    - The `selective-validation` and `fill-sweep` commands.
    - The `_selective_setup` and `_raw_thresholds` helpers.
    - `_sequence_evaluator` aggregates `finalByPath`.
  - `scripts/glyphs/test_calibrate_v2.py`: `test_fill_threshold_gates_only_ink_revisions`.
  - `scripts/glyphs/logit_normalization.py` and its test. Exploratory; leave them unused.

## Definitions

- **CASE_FOLD** = `{"C":"c", "K":"k", "O":"o", "P":"p", "S":"s", "U":"u", "V":"v", "W":"w", "X":"x", "Z":"z"}`.
  - These are shape-identical pairs. **Not** Y, M, N or any other capital; those go to junk.
  - `O` folds to `o`, which is in the `ring` class with `0` and `°`.
- **Function word**: a raw label whose only token is a key of `datasets.MULTI_COMMANDS` (`\sin`, `\cos`, `\tan`, `\log`, `\ln`, `\exp`, `\lim`, `\sec`, `\csc`, `\cot`). Also catch the bare spelled forms (`sin`, `log`, …) if CROHME uses them; check the data.
- **Junk-eligible raw label**: after the same tokenization as `datasets._single_label` (with `DROP_COMMANDS` removed), it is **exactly one token**, and that token is:
  - not a vocab label,
  - not in `TOKEN_MAP`,
  - not in `MULTI_COMMANDS`,
  - not in `CASE_FOLD`.

  Examples: `E F N T R L M B H Y A I G Q D J`, `\alpha \beta \phi \mu \lambda \sigma \gamma`, `q`, `\{ \}`, `\ldots`, `\exists`.

  Multi-token labels stay dropped, as today. Put this logic in one shared function in `datasets.py`, e.g. `extended_label(raw, labels) -> str | None`. It returns the vocab label, the CASE_FOLD target, `"<unk>"` for junk-eligible labels, or `None` (dropped). Scoring needs a sibling that also reports function words; one function with a small result enum is fine.
- **Known symbol**: a scored symbol whose truth is not `<unk>`, after CASE_FOLD and after function words are removed.

## Steps

### 1. Staging vocabulary and junk class (agent; short)

- Create **`scripts/glyphs/math-vocab-f4.json`** as a copy of the shipped vocab plus:
  - class `{"id": "junk", "labels": ["<unk>"]}`, inserted in sorted id order (after `glyph_u2265`, before `ring`), giving **60 classes**;
  - label entry `{"label": "<unk>", "class": "junk", "kind": "junk", "hershey": "", "latex": []}`. Check that Swift `MathVocabulary.Label` decodes it (step 5).
- `train_v2.class_ids()` currently requires exactly 59 classes ([train_v2.py:890](../../scripts/glyphs/train_v2.py)). Accept 59, or 60 when the extra id is `junk`.
- Replace the `→59` architecture string with the real class count.
- **Resolver weights.** `scripts/glyphs/resolver.py` builds `CLASS_LABELS` from the *shipped* vocab file, so `member_weights("junk", …)` would return `{}` and junk probability would silently vanish from likelihoods. Add an explicit special case in both places:
  - `if class_id == "junk": return {"<unk>": 1.0}` in `resolver.py`;
  - the same in Swift `SymbolResolver.memberWeights` (step 5).
- Python decoder (`decoder.py`): `"<unk>"` is already never substituted or revised. With a junk class, the `<unk>` likelihood competes in the LM marginal as a real hypothesis (the LM vocab already has `<unk>`, so no LM change). Add a unit test: a symbol whose junk probability dominates is never substituted or filled.
- Check every Python consumer of vocab `kind` (for example `calibrate_v2._role`, `kind_by_label`) for the new `"junk"` kind, and give it a neutral role.
- Synthetic top-up (`prepare`): exclude `junk` (no Hershey source). It will have far more than 2,000 real records anyway.

### 2. Extra training data (agent writes code; Ayush runs R1)

- Add a `datasets.py extras` command. It writes **only new files**:
  - `build/datasets/mw-symbols-extra-train.jsonl.gz`
  - `build/datasets/crohme-extra-train.jsonl.gz`, `crohme-extra-valid.jsonl.gz`
  - `build/datasets/hwrt-extra-train.jsonl.gz`, `hwrt-extra-valid.jsonl.gz`
- Contents: exactly the records the base pass currently drops as `unmapped_label` and that `extended_label` now maps to a CASE_FOLD lowercase label or to `"<unk>"`.
  - Records keep their raw label in a new `rawLabel` field.
  - The record `class` comes from the **staging vocab** (`--math-vocab scripts/glyphs/math-vocab-f4.json`).
- **Reuse the existing loaders** (`_mw_symbols`, `_crohme`, `_hwrt`) with a mode parameter rather than copying them, so the same splits apply: writer split, held-out source expressions, dedup and empty-stroke rules.
  - **Never read CROHME `valid.zip` (TEST-C)**, and write no `crohme-extra-test`.
  - The base-pass output must be byte-identical. Assert this in a self-check by re-running the base mode into a temp dir on a small limit, or by checking SHA-256 against `SOURCES.json` / `stats.json`.
- Write `build/orchestration-v2-wave3/extras-stats.json`: per-source and per-split counts, the top 60 raw labels by count for both junk and case-fold, and the dropped counts. Harvest files are unchanged.
- **R1 runtime:** it scans the 3 GB MathWriting tar. Estimate 15–30 min; hand off.

### 3. Training changes (agent; short)

- `train_v2.py prepare` and `train`: add `--include-extras`. `source_groups()` then appends the five extras files to their splits. Source hashes include them, so lineage checks stay strict.
- Labels resolve through the staging vocab (`--vocab scripts/glyphs/math-vocab-f4.json`): `"<unk>"` maps to `junk`, and folded capitals map to their lowercase class.
- Validation metrics (`metrics.json`):
  - keep `classTop1` over all 60 classes (this drives best-epoch selection, as before);
  - **also report `knownClassTop1`** over the 59 non-junk classes, comparable to F3-second's 96.47%;
  - report junk recall and junk precision.
- CAP-tune report: size the confusion matrix from the label list (not a hard-coded 65), and count a `"<unk>"` guess as wrong.
- Export (`export_calibration`, manifest):
  - carry **`tauFill`** with bounds [0.9, 1];
  - the manifest's `classes` must list all 60 ids;
  - `export --vocab scripts/glyphs/math-vocab-f4.json`.
- `train_v2.py selfcheck` must pass.

### 4. Calibration changes (agent; short)

In `scripts/glyphs/calibrate_v2.py`:

1. **Truth scoring in `_formulas`.** Use the shared function from step 1:
   - CASE_FOLD capitals become their lowercase label;
   - **function-word groups are removed** from the sequence entirely (they never reach the decoder or the metrics), and each line counts them in `excludedFunctionWordSymbols`;
   - other unmapped labels become `"<unk>"`, as today.
   - This applies identically to `split="valid"` and `split="test"`, and is decided before any test access.
   - With the staging vocab, `labels` contains `"<unk>"`. Make sure no real raw label maps to `"<unk>"` through `_single_label`.
2. **τ_fill in the decoders.** In `decoder.py` (and Swift, step 5), a revision passes when `probability >= (tau_fill if displayed_label is None else tau_rev)`. `tau_fill` defaults to `tau_rev`. `simulate` already applies τ_fill after a raw decode; keep both consistent, and keep the parity fixtures in sync.
3. **`_sequence_evaluator.evaluate(tau_sub, tau_rev, disabled, tau_fill)`.** `tau_fill` **must be part of the interval-cache context key** (today it's `(tau_rev, disabled)`). Extend `test_sequence_interval_cache_matches_replay_at_slash_boundary` to cover two τ_fill values.
4. **`calibrate` search.**
   - **λ is fixed at 0.4** (`--lambda`, default .4). F3-second's per-λ results put 0.4 at the best coverage, and fixing it keeps runtime at about 40 min instead of about 4 h.
   - For each `tau_fill` in `FILL_GRID = (.90, .93, .95, .97, .98, .99, .995, .999)`: scan `TAUS` in ascending order with the existing `_calibration_setting`. That keeps the τ_rev harmful-swap step and the rule disabling labels below 95% precision with ≥ 30 swaps. Take the smallest τ_sub that reaches **final-line precision ≥ 99%** and harmful swaps ≤ 0.5/100.
   - Across τ_fill values, choose the highest **`coverageRecognizableSymbols`**. Break ties with the higher τ_fill, then the higher τ_sub.
   - Print one progress line per (τ_fill, τ_sub) as today.
   - Write `tauFill` into `calibration.json` and the search summary. Add `"caseFold"`, `"functionWordsExcluded": true` and the junk-class note to the `simulation` block.
   - Pass/fail uses ≥ 99% validation precision, ≤ 0.5 harmful swaps and the known-symbol coverage reported (no coverage requirement at calibration time).
5. **`final_test`.**
   - Require `tauFill` in [0.9, 1] and pass it to `simulate`.
   - Report `coverageRecognizableSymbols`, `excludedFunctionWordSymbols` and `finalByPath`.
   - Size the CAP confusion from `all_labels` (not 65); a `"<unk>"` guess counts as wrong.
   - The isolated accuracy denominator is known symbols; a junk argmax on a known symbol counts as wrong.
6. Don't extend `selective-validation` or `fill-sweep`. They stay as exploratory tools.

### 5. Swift (agent; no resource swap)

- **`MathLineDecoder.swift`:**
  - add `tauFill` (init default = `tauRev`);
  - in the revision guard, replace `probability >= tauRev` with `probability >= (symbol.displayedLabel == nil ? tauFill : tauRev)`;
  - mirror `decoder.py` exactly;
  - add a decoder fixture in `Tests/CanvasKitTests/Fixtures/decoder/`: a fill that passes τ_rev but fails τ_fill, checked for parity in both languages.
- **`MathGlyphClassifier.swift`:**
  - `DecoderConfiguration` gains `tauFill`;
  - `Manifest` decodes an optional `tauFill`. If it's missing, use `tauRev`, so the **current shipped manifest still loads**; validate finite and in [0, 1];
  - `CanvasView.mathDecoder` passes `tauFill`.
- **Junk class in the app:**
  - `SymbolResolver.memberWeights(class: "junk")` returns `["<unk>": 1]`;
  - `MathVocabulary` must decode the `<unk>` label entry;
  - audit **every consumer of label likelihoods** so that `"<unk>"` is never displayed, inserted as LaTeX, treated as a letter, or counted as a function-word letter. Known places: `topFive`, `MathFunctionNames.letters(in:)`, `isMathWordLetter`, `mathKind`, `mathLatex`, and any argmax over likelihoods in `CanvasView`;
  - when `"<unk>"` is the top label, the ink stays ink.
- **Tests:**
  - decoder τ_fill parity;
  - an old manifest without `tauFill` still loads;
  - a junk-vocab classifier test with a stub predictor, where junk dominance means no swap;
  - existing suites pass.
- Run `swift test` and a Debug `xcodebuild`.

### 6. Runs (Ayush runs; agent prepares scripts under `build/orchestration-v2-wave3/`)

Each run gets one `run-<name>.sh` with the same `.log`/`.done` pattern as `run-fill-sweep.sh`. Use the venv python directly. Don't wrap it in `timeout`: that launches it under the wrong architecture (x86 vs arm64) on this Mac.

| Run | Command (confirm flags against the parsers) | Estimate |
|---|---|---|
| R1 `extras` | `datasets.py extras --math-vocab scripts/glyphs/math-vocab-f4.json --mw-archive build/datasets/mathwriting-2024.tgz --crohme-archive build/datasets/Task1_and_Task2.zip --hwrt build/hasy/2015-01-28-data.tar` | 15–30 min |
| R2 `F4-prepare` | `train_v2.py prepare --vocab scripts/glyphs/math-vocab-f4.json --include-harvest --include-extras --output build/glyph-training-v2/F4` | 10–20 min |
| R3 `F4` | `train_v2.py train --vocab scripts/glyphs/math-vocab-f4.json --output build/glyph-training-v2/F4 --epochs 15 --trackpad-p 0.5 --tremor 0.01-0.03` (F3-second recipe otherwise: batch 512, lr 1e-3, max-per-class 20,000, seed 20261003) | ~35 min |
| R4 `F4-calibration` | `calibrate_v2.py calibrate --vocab scripts/glyphs/math-vocab-f4.json --output build/glyph-training-v2/F4 --lambda .4` | ~40 min |
| R5 `F4-test` | `calibrate_v2.py test-once --vocab scripts/glyphs/math-vocab-f4.json --output build/glyph-training-v2/F4` | ~5 min |

Stop rules:
- **After R1:** the agent reports `extras-stats.json`. Stop if junk has under 5,000 train records, or if any case-fold capital shows up in the junk list (a mapping bug).
- **After R3:** stop and report if `knownClassTop1` < **96.0%** (F3-second's 96.47% minus 0.5) or CAP-tune < 80%.
- **After R4:** if no setting reaches 99% validation precision, stop and report with `finalByPath` and the top wrong (truth → shown) pairs. **No further candidate without Ayush.**
- R5 runs only after R4 passes. It is the single test access.

### 7. Gates (TEST-C with case-fold scoring and function words excluded, unless noted)

| Metric | Gate |
|---|---|
| Isolated label accuracy, known symbols, no LM | ≥ 93% |
| Final-line substitution precision, with context and revisions | ≥ 98.5% |
| **Coverage: share of known symbols substituted** (`coverageRecognizableSymbols`) | **≥ 75%** (changed from ≥ 85% of all symbols; Ayush, 2026-10-05) |
| Harmful swaps (correct → wrong) | ≤ 0.5 per 100 symbols |
| CAP-test isolated label accuracy | target ≥ 90%; < 80% blocks |
| Release: model ≤ 2 ms, decoder ≤ 0.5 ms, full commit ≤ 5 ms | required |

Also report, without a gate: all-symbol coverage, `unknownWrongFinal`, `finalByPath` and `excludedFunctionWordSymbols`.

If any gate fails: stop and report to Ayush. Don't retune on test results.

### 8. Export and swap (only if every gate passes)

1. `train_v2.py export --vocab scripts/glyphs/math-vocab-f4.json --checkpoint build/glyph-training-v2/F4/best.pt --calibration build/glyph-training-v2/F4/calibration.json --language-model Sources/CanvasKit/Resources/MathLM.json`, producing a model package and manifest with 60 classes and `tauFill`.
2. In **one change**, copy:
   - `math-vocab-f4.json` → `Sources/CanvasKit/Resources/math-vocab.json`;
   - the new `MathGlyphs.mlmodelc`;
   - `MathGlyphs-manifest.json`.

   The manifest's `mathVocabSHA256` must match the copied vocab. The LM is unchanged (`71376749…`).
3. Run `swift test`, a Debug `xcodebuild`, and the native latency measurement (`native-measure.json`) against the release gates.
4. Hand Ayush the manual trackpad checkpoint below.

### 9. Manual checkpoint (Ayush)

Write these in math input:
- `2x+3`, `x^2-4`, `(a+b)c`, `3/4`, `5−3`.
  - `x`, `c`, `p` and `k` should swap now; they were disabled before.
- Capitals `X`, `C`, `P`: they may show as lowercase, and the Apple Intelligence pass is expected to fix case.
- `E`, `F`, `N`, `α`, `β`: these should **stay ink** (junk) rather than swapping to a wrong glyph.
- `sin x` and `log 2`: the function-name path should behave as before.

Report wrong glyphs and any symbols that stayed ink but shouldn't have.

### 10. Docs

- After each step or run, add a dated entry at the top of the `## Log` in [running.md](../../running.md). Include the numbers, and say explicitly that no test data was used until R5.
- When finished, update the Wave 3 status in [wave-3.md](wave-3.md).

## Expected outcome (an estimate, not a measurement)

At τ_fill 0.97 on F3-second, 48 of the 67 wrong swaps were on `<unk>` truths.
- If the junk class and CASE_FOLD remove most of those, 99% validation precision should be reachable at a looser τ_fill.
- Known-symbol coverage should land around **77–78%**.
- Folded capitals add training data to `x`, `c`, `p`, `k` and others, which should let calibration stop disabling them.

The main risk is that junk eats coverage on known symbols. Calibration will show this as lower `coverageRecognizableSymbols`.
