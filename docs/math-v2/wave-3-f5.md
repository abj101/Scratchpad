[Back to Wave 3](wave-3.md) · builds on [wave-3-f4.md](wave-3-f4.md)

# F5: give `q` and `l` their own classes

Approved by Ayush, 2026-10-05. The app now commits the decoder's best guess when it is at least 0.5 (`CanvasView.mathCommitMinimumMarginal`). Disabled labels still commit, and junk (`<unk>`) is rejected.

Two letters can't be entered:
- **`q`** has no class, so it goes to junk.
- **Cursive `l`** is inside `bar = {1, l, |}` with a 0.05 math prior, so it can never win.

**Goal:** a tailed `q` and a cursive `l` always commit as `q` and `l`. Everything that works today keeps working.

## Rules (same as Wave 3)
- Ayush runs every long command. The agent writes `build/orchestration-v2-wave3/run-<name>.sh` (foreground, tee to `<name>.log`, write `<name>.done` with the exit code), gives one command with a time estimate, and stops. No polling.
- Use the venv python directly, never under `timeout`.
- Don't touch `Sources/CanvasKit/Resources/` until step 6.
- Don't rewrite existing `build/datasets/*.jsonl.gz`. The extras files may be regenerated.
- No test-set access. TEST-C is spent; Ayush's manual check is the gate.
- Minimal diffs. Don't revert uncommitted work.

## Steps

1. **Vocab** `scripts/glyphs/math-vocab-f5.json`, starting from the shipped F4 vocab:
   - `bar` becomes `{1, |}`;
   - add class `glyph_u006C` = `{l}` and class `glyph_u0071` = `{q}`, plus their label entries (`kind: lower`, `hershey`, `latex`);
   - keep class ids sorted, which gives 62 classes. Update every class-count check (`train_v2.class_ids`, the architecture string, and the CAP and confusion sizes, which are derived from the label list).
   - `bar` math weights in `resolver.py` and Swift `SymbolResolver.memberWeights` become `1: 0.95`, `|: 0.05`.
2. **Data.** In `datasets.py`, add `q` to `TOKEN_MAP` so it maps to the vocab label `q`. Re-run `extras` so `q` records are labeled `q` instead of `<unk>`. `l` records re-map through the vocab with no code change.
3. **LM.** `MathLM.json` has no `q`, so don't rebuild it. Score `q` in the LM as `p` in both decoders: in Python, map the word and its context before `lm.log_prob`; in Swift, add it to `MathLineDecoder.contextSymbolID`, the same way function names are mapped to `√`. Add a parity fixture.
4. **Calibration matches the app.** Add `simulate(..., commit_floor=0.5)`:
   - a symbol with no substitution commits its decoder best label when that label isn't `<unk>` and its marginal is ≥ the floor, ignoring disabled labels;
   - fills only happen for symbols that are still uncommitted.

   `calibrate` keeps λ = 0.4 and the τ_fill grid. Report precision, coverage, and the per-label accuracy for `q`, `l`, `9`, `1` and `t`. There is no pass/fail on 99%; the run only has to finish and write `calibration.json`.
5. **Runs (Ayush):**

   | Run | What it does | Estimate |
   |---|---|---|
   | R1 | `extras` | 15–30 min |
   | R2 | `prepare` into `F5` (`--include-harvest --include-extras`) | 10–20 min |
   | R3 | `train` F5, F4 recipe, 15 epochs | ~35 min |
   | R4 | `calibrate` | 20–40 min |

   **Stop and report if** validation `knownClassTop1` is below 96.0%, `q` or `l` accuracy is below 90%, or `9 → q` or `1 → l` confusion is above 3% of that class.
6. **Swap:**
   - `export` with the F5 vocab and calibration;
   - copy the vocab, `MathGlyphs.mlmodelc` and the manifest into Resources in one change;
   - run `swift test`, a Debug `xcodebuild`, the native latency check, and `scripts/run.sh`.
7. **Ayush checks by hand:** tailed `q`, cursive `l`, `1`, `|`, `9`, `t` with a curled tail, `0–9`, `3/4`, `√`.
8. **Log** an entry at the top of `## Log` in `running.md` after each step.
