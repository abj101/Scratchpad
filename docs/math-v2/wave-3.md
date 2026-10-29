**Before you start:** Read [README.md](README.md) first.

This wave uses all contracts in [contracts.md](contracts.md).

**Data:** See [data.md](data.md) for exact data sources.

---

[Previous wave](wave-2.md) · [Next wave](wave-4.md)

---

### Wave 3 (sequential): trackpad tuning, conditional harvest, final model, calibration

**Long runs: hand off, don't poll.**
- The executing agent never launches or monitors runs longer than ~5 minutes (each sweep run, F2, F3, harvest if long).
- For each such run it prepares flags, output directory and log path, then gives Ayush one copy-paste shell command that runs in the foreground, tees output to `build/orchestration-v2-wave3/<run>.log`, and on exit writes `build/orchestration-v2-wave3/<run>.done` containing the exit code. The four sweep runs may be chained into one command.
- It states an estimated duration (~2 min/epoch on MPS for F-sized runs), then stops and waits. No polling, sleeping, tailing or status checks.
- When Ayush says "done", it reads only the `.done` file, the run's summary JSON/metrics, and the last ~20 log lines, then continues.

**3a-0. Re-baseline F.** Re-run `train_v2.py report` on the current F checkpoint (build/glyph-training-v2/best.pt) on validation and CAP-tune only, using the current math-mode member weights (digit priors: ring 0 .9/o .1 of non-degree mass, bar 1 .9/l .05/| .05). F's recorded CAP-tune 0.80 used the old neutral split and is not comparable. All 3a comparisons use this new baseline. No test-set access.

**3a. Trackpad augmentation sweep (F's owner).** As the first step, add training CLI flags: `--trackpad-p` (default 0.5) and `--tremor` (default `0.01-0.03`, i.e. 1–3%) options to `scripts/glyphs/train_v2.py train` (they do not exist yet); defaults reproduce F exactly. `training.json` records the flag values and the training script SHA-256.

Run four short training runs (10 epochs each, otherwise identical to F) over the trackpad-simulation settings
`p ∈ {0.5, 0.8}` × tremor `∈ {1–3%, 2–5%}`. Pick the setting with the highest **CAP-tune**
isolated accuracy whose validation class accuracy is within 1.0 point of the best run's.
CAP-tune has 130 records (one record ≈ 0.77 points), so runs whose CAP-tune differs by ≤ 2 records are tied; ties go to the lower p and tremor. Then run the full 15-epoch training (cosine schedule over 15 epochs; best epoch selected on validation as in F) with it. If F2's best validation class top-1 is more than 0.3 points below F's 95.55% (re-baselined numbers aside, use F's recorded validation top-1), stop and report to Ayush; he decides whether to rerun at 30 epochs. Call the
result **F2**.

**3b. Harvest decision (Sol).** Run H and retrain (F3 = F2's recipe plus harvested data)
**only if** either:
- any class with ≥ 50 validation samples has F2 validation accuracy below 95%, or
- F2's CAP-tune accuracy is below 90%.

Otherwise skip H and use F2. Log the decision with the numbers.

**H. Harvest MathWriting human inks (conditional, stage 2).** Owns: `scripts/glyphs/harvest.py`.
- Candidates: MW `train/` (training) and MW `valid/` (validation) inks whose linearized label
  has `unk_count = 0`, `has_frac = false`, 2 ≤ length ≤ 30, and stroke count ≤ 3 × length.
- Delayed-stroke fix before alignment: a stroke shorter than 0.25 × the ink's median stroke
  length, whose x-center lies within an earlier stroke's x-extent (padded by 10% of the ink
  height), and which was written after a stroke whose x-center lies further right, is moved
  in order to immediately after that earlier stroke.
- Alignment: DP over (strokes consumed i, labels matched j). Each step takes a group of
  g ∈ 1…G(label) consecutive strokes, where G is the 99th percentile of stroke count for that
  class in stage-1 training data (cap 5). Score = `log P_F(class(label) | group)` using
  model F2 with its validation temperature, minus 3 × (the number of strokes in the
  group whose x-extent does not overlap the rest of the group's x-extent padded by 20% of
  the group height).
- Accept an ink only if every aligned symbol has P ≥ 0.30 and the mean log P ≥ ln 0.70.
- Output in B's record format, `src = "mw-harvest"`. Report the acceptance rate and
  per-class counts.
- QA gate (Sol): render a contact sheet of 400 random harvested symbols with a fixed seed.
  If more than 8 are mislabeled (2%), tighten to P ≥ 0.5 and mean ≥ ln 0.8 and redo.

**3c. Final model, calibration and test.** The final model is F3 if H ran (mw-harvest
train added to training, mw-harvest valid added to validation), else F2.
- Calibrate on validation: temperature by NLL; then, in the Python decoder simulation on
  **validation sequences** (CR validation expressions with `has_frac = false`, with symbols
  in first-stroke time order and resolver geometry from the original ink), grid-search
  `λ ∈ {0.2, 0.4, …, 1.2}`.
- Pick the smallest `τ_sub` giving substitution precision ≥ 99.0%; `τ_rev` stays 0.90 unless
  harmful swaps exceed 0.5 per 100 symbols (then raise it in steps of 0.02).
- Disable a label if its validation substitution precision is below 95% with ≥ 30
  substitutions.
- **Simulation must match the shipped app:**
  - resolver/member weights in math mode (`scripts/glyphs/resolver.py`, `mode="math"`), matching Swift `SymbolResolver.memberWeights`;
  - the current language model with function words (Sources/CanvasKit/Resources/MathLM.json, SHA-256 `71376749b22abc6305f43220a24e395f3d0f82e7e6e5037701176c784ca9c917`); the final export passes this LM via `--language-model` so manifest `mathLMSHA256` matches;
  - optional: calibrate the decoded-slash fraction trigger threshold (currently decoder marginal ≥ 0.5 for `/`) on validation sequences alongside τ_sub, reporting precision of fraction triggers.
- **Final test (once):** run TEST-C sequences (same simulation) and CAP-test (isolated, no
  context). Write `build/glyph-training-v2/test-report.json`; it refuses to overwrite.

- **Data rule:** The DEBUG recognition log (`~/Library/Logs/Scratchpad/math-recognition.jsonl`) is never training, validation, calibration or test data.

**Gates** (on TEST-C unless noted):

| Metric | Gate |
|---|---|
| Isolated label accuracy (no LM) | ≥ 93% |
| Substitution precision, with context and revisions, final line state | ≥ 98.5% |
| Coverage (share of symbols substituted) | ≥ 85% |
| Harmful swaps (correct → wrong) | ≤ 0.5 per 100 symbols |
| CAP-test isolated label accuracy (trackpad-domain check) | target ≥ 90%; **< 80% is a blocker**: stop and report to Ayush with the confusion pairs |
| Release: model ≤ 2 ms, decoder ≤ 0.5 ms, full commit ≤ 5 ms | required |

If a gate fails, Sol may make one second candidate (allowed changes: run H if it was
skipped, per-class caps, augmentation strengths, epochs, harvest thresholds; never anything
chosen by looking at test errors). If the second candidate also fails, stop and report both reports to Ayush.


---

### Status (2026-10-05): stopped, then amended with candidate F4

F3 and F3-second both failed calibration, and Wave 3 stopped under the one-second-candidate rule. Validation-only diagnostics ([selective-validation-audit.md](selective-validation-audit.md), `build/orchestration-v2-wave3/fill-sweep.json`) found that most remaining wrong swaps are out-of-vocabulary symbols, mostly capital letters.

Ayush approved a third candidate, **F4**, with these changes:
- a junk class;
- case-fold scoring for capitals shaped like their lowercase;
- function words excluded from scoring;
- a separate τ_fill threshold;
- the coverage gate changed to ≥ 75% of known symbols.

Full plan: [wave-3-f4.md](wave-3-f4.md). Its gates replace the gate table above for F4.

F4 implementation (2026-10-05): steps 1–5 and R1–R5 handoff scripts are prepared. Python discovery/selfcheck and Debug build pass; the full Swift suite has two failures that also reproduce before F4 (document page-height and bundled-context revision integration). No F4 data preparation, training, calibration, test, or resource swap has run. No test data used.

F4 R4 (2026-10-05): calibration passed at λ=.4 / τ_sub=.98 / τ_fill=.97 / τ_rev=.90, with 99.0082% final validation precision, 75.6316% known-symbol coverage and zero harmful swaps. R5 is ready for the one-time final test; no test data used or resource swap.

F4 R5 (2026-10-05): stopped after the one-time final test. Known-label isolated accuracy 93.3087%, final precision 98.5238%, harmful swaps 0/100, CAP-test 82.5641%; known-symbol coverage 73.6389% fails the approved ≥75% gate. No retuning on test, rerun, new candidate, export or resource swap. Final report: `build/glyph-training-v2/F4/test-report.json`; gate decision: `build/glyph-training-v2/F4/final-gate-report.json`.

F4 acceptance/export (2026-10-05): Ayush explicitly accepted the 1.3611 point known-coverage miss because it reflects abstention and precision passes. Mixed-precision export passed native parity; the matched 60-class vocab/model/manifest is shipped. Required latency gates measured and passed: native .all model median .182729 ms, worst-case decoder max .231958 ms, warmed full commit max 1.2314 ms. Debug build succeeds; full Swift suite retains two reproduced pre-F4 failures. Step 9 physical trackpad check remains pending for Ayush. No test rerun or retuning.
