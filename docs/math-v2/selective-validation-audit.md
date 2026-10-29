# F3-second selective-validation audit

## Completed human-run comparison

The human-run `selective-validation` command completed with exit code 0. The report is `build/orchestration-v2-wave3/selective-validation.json`. The full historical baseline replay reproduces the saved 3,665 covered / 3,556 correct outcomes: **38 of 109 wrong final substitutions (34.86%) had `<unk>` truth**. The other 71 errors had known truth. Excluding OOV substitutions would raise baseline precision from 97.03% to 98.04%, still below the 99% validation target.

Comparison on the same 350-expression / 2,871-symbol evaluation fold (180 OOV truths):

| Setting | Final precision | All-symbol coverage | Known-symbol coverage | Wrong OOV substitutions |
|---|---:|---:|---:|---:|
| Saved baseline | 97.04% | 63.60% | 67.26% | 16 |
| Selection-fit global threshold | 95.47% | 76.94% | 80.19% | 51 |
| Per-label thresholds | 98.29% | 57.09% | 60.57% | 9 |
| Per-label + normalized logits, p=2 | 98.61% | 52.49% | 55.89% | 3 |

All settings recorded zero harmful revisions. None meets both 99% validation precision and 85% all-symbol coverage. The normalized setting clears the numerical 98.5% test precision target on this validation fold, but this is not a test-set result and coverage remains far below target.

Raw per-label thresholds restore `x` (112/118 correct, 94.92% evaluation precision); normalized thresholds reject `x` because no selection threshold meets 99% precision with at least 30 accepted examples. Only 20 labels receive usable raw thresholds and 19 normalized thresholds, so the minimum-support rule also limits coverage. Thresholds are fitted from immediate candidate decisions, while the reported metric includes final revisions and fraction structure; those are different objectives. In particular, the existing slash-to-fraction trigger at marginal ≥0.5 can produce visible `/` outcomes even when its per-label substitution threshold rejects the label.

These are exploratory Python results: the checkpoint and historical calibration used full validation data, and normalization is a softmax-decoder adaptation of the paper. Do not export a candidate or infer that geometry is the sole remaining cause. No retraining or further calibration was launched.

## Original persisted-artifact audit

Audited the persisted F3-second outputs only: `build/glyph-training-v2/F3-second/metrics.json` and `calibration-search-summary.json`. No model inference or calibration was run.

## Findings

- The sequence calibration evaluates 5,840 symbols, of which 454 have truth `<unk>` (`calibration-search-summary.json`: `symbols`, `unknownSymbols`). Thus 5,386 / 5,840 = **92.23%** are in-vocabulary; 7.77% are out of vocabulary.
- **92.23% is the ceiling on correct coverage over all symbols** if the recognizer abstains on every `<unk>` truth and recognizes every in-vocabulary truth correctly. It is not a ceiling on raw coverage: an incorrect substitution on an `<unk>` truth still increments raw coverage.
- The saved calibration summary uses all 5,840 symbols for final-line `coverage`. Its six best-attempt rows each report `tauSub=0.995`, `unknownSymbols=454`, and `harmfulSwaps=0`; none met the 99% final-line precision target (`candidateCount=0`, `status=failed`). At λ=0.4, for example, final coverage is 3,665 / 5,840 = 62.76%; 3,556 of those labels are correct (97.03% final-line precision). The same row has 2,775 immediate update actions, 2,755 of which were correct (99.28% update precision). These are different measures; neither aggregate says how many errors were on `<unk>` truths.
- `metrics.json` has isolated 59-class confusion pairs but no `<unk>` row or per-symbol decoder outcomes. The calibration summary stores aggregate precision, coverage, update counts, and harmful-revision counts only. Its `harmfulSwaps` means a revision that damages a previously correct symbol; it cannot answer how many wrong final updates had `<unk>` truth. Therefore the exact requested count of wrong substitutions/revisions with `<unk>` truth is **not recoverable** from these artifacts.

## Required reporting in the item 2 comparison

For baseline and each candidate, retain the 5,840-symbol sequence validation denominator and report counts for `unknownSymbols`, `unknownCovered`, `unknownWrong`, `knownSymbols`, `knownCovered`, all-symbol raw coverage, and correct coverage over all symbols. Define `unknownWrong` as final substituted labels that differ from an `<unk>` truth; keep it separate from harmful revisions. This is enough to recompute eligible known-symbol coverage without letting wrong OOV substitutions inflate it. Persist the aggregates in the comparison JSON so the per-symbol records need not be retained.
