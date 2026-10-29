**Read this file first, then only the wave doc you are executing and the contracts it links.**

# Math Recognition v2 Plan

Goal: fast math scratch work with a finger on the Mac trackpad. In math input, every
committed handwritten symbol (algebra through single-variable calculus, including exponents
and subscripts) is redrawn as a clean glyph, and is right far more often than it is now. Line context
fixes look-alikes, and a symbol the app isn't sure about stays tidied ink instead of being
redrawn as the wrong glyph.

Baseline: branch `codex/document-mode` at `8dadc1a`. Current state: 694 tests pass, Release
full commit takes 0.54 ms at most, and the v1 CNN scores 75.57% by group, with 84 of 158 labels
disabled. Details are in `running.md`.

Status key: `[ ]` todo · `[~]` in progress · `[x]` done · `[?]` needs Ayush (decision or manual test)

---

## For the orchestrator (Sol)

- **Branch:** create `codex/math-recognition-v2` from `8dadc1a`. Commit locally after each
  wave is verified. **Never push.** End commit messages with the attribution line Ayush's
  tooling specifies.
- **Agents:** Luna (max effort, ponytail skill) implements each task. Sol (medium) orchestrates,
  reviews and integrates, and is the only one who edits `CanvasView.swift` outside task G.
  Each task lists the files it **owns**; two parallel agents never own the same file. Give
  each agent an isolated worktree and a self-contained prompt: paste the task section plus
  the "Shared contracts" section.
- **Review every hand-back:** read the diff, rerun its checks yourself, run `swift test`, and
  build the app with `xcodebuild` (Debug, plus Release at the end of waves 2 and 4).
- **Disk:** the volume had **18 GB free** on 2026-10-03. Before wave 0 downloads, confirm at
  least 12 GB is free. If it isn't, stop and ask Ayush to free space. Never extract the
  MathWriting archive to disk: stream it with `tarfile`. Total new disk use must stay under
  8 GB.
- **Data rules:** never train, tune thresholds or select checkpoints on a **test** set. Test
  sets are the CROHME `valid.zip` expressions (labeled "TEST-C" below) and **CAP-test** (see
  "Capture split"). Each model candidate touches the test sets once, and there are at most 2
  candidates. Log every test run in `running.md`.
- **Capture split (added 2026-10-04 after the audit).** Ayush's 325 math-label captures in
  `build/glyph-capture` (5 per label) are split once, deterministically: for each label, sort
  its files by SHA-256 of the file name. The first 2 are **CAP-tune** (130 records); the other
  3 are **CAP-test** (195 records). Write the lists to `build/datasets/cap-split.json` and
  never change them.
  - CAP-tune is the only trackpad ink we have. It may be evaluated any number of times to
    tune augmentation and to measure the trackpad gap early.
  - CAP-tune is **never** a training sample, and never selects a checkpoint by itself.
  - CAP-test follows the test-set rules.
- **No new captures.** Ayush won't collect more samples. All training data comes from the
  public datasets below plus existing synthetic data. Ayush only runs the manual tests at
  checkpoints 1, 2 and 3.
- **Testing style:** use pure-logic unit tests with fixed seeds and exact numeric assertions,
  and Swift↔Python parity fixtures for every algorithm that exists in both languages. No UI
  automation rigs. Visual or tactile behavior goes to Ayush's manual checklists.
- **House style:** match the surrounding code: short doc comments, `// MARK:` sections, value
  types with pure static helpers, and `CanvasModel` as the only mutator of note data (with
  undo).
- Update `running.md` (Log section) as each task lands, and mark status here.

---

## Decisions (final; agents must not revisit them)

1. **Licensing.** The app is personal and will likely be open-sourced. We train on
   **MathWriting** (CC BY-NC-SA 4.0) and **CROHME 2019** (CC BY-NC-SA 3.0). The code stays
   under the repo's license. The trained model and language-model files are derived works,
   so they ship under **CC BY-NC-SA 4.0**, documented in
   `Sources/CanvasKit/Resources/MATH-MODEL-LICENSE.md` with attribution to both datasets,
   HWRT (ODbL), Hershey and Relief (existing notices). Datasets are never committed (`build/`
   is ignored). Commercial use would require retraining on HWRT and synthetic data only; note
   that in the license file.
2. **Scope is math mode only.** Text mode keeps PencilKit (`PKStrokeRecognizer`) and is not
   touched. The math classifier is only called from `CanvasView.commitPendingLetter` when
   `tidyMath` is true; that stays the only call site.
3. **Math vocabulary: 65 labels, 59 model classes.** This replaces the 158-label vocabulary
   for math. `vocab.json` and `HersheyGlyphs.json` stay as they are; Hershey glyphs exist for
   all 65 labels.

   | Kind | Labels |
   |---|---|
   | Digits (10) | `0 1 2 3 4 5 6 7 8 9` |
   | Lowercase (25) | `a b c d e f g h i j k l m n o p r s t u v w x y z` (no `q`, which reads as `9`) |
   | Operators (13) | `+ − · ÷ = ≠ < > ≤ ≥ ± / !` (`/` makes a stacked fraction, Decision 11) |
   | Delimiters (5) | `( ) [ ] \|` |
   | Low/raised marks (3) | `. , ′` |
   | Calculus/other (9) | `√ ∫ ∑ π θ Δ ∞ → °` |

   **Merged classes** (identical shapes; resolved by geometry and context, not the CNN):
   `ring = {0, o, °}` · `bar = {1, l, |}` · `dot = {., ·}` · `tick = {, ′}`. Every other label
   is its own class.
   **Removed from math:** `×` (multiplication is `·` or juxtaposition), `q`, all uppercase
   except `Δ`, other Greek letters, `∂ ∈ ∪ ∩ ⊂ ∀ ∃ ≈ ∝ ∅ ∇ ∏ ∘ ⇒ ⇔ ← ↔ ⊥ ∥ ∠ ¬`, and the
   punctuation `: ; ? " @ # $ % & * ^ ~ _ { } \`. Ink for these stays tidied, never
   substituted.
4. **Model: dual-input (raster + pen path).** It is trained on real handwriting at scale and
   takes:
   - `glyphImage`: the existing 32×32 OneComponent8 raster (`GlyphRaster` / `raster.py`,
     unchanged).
   - `strokePoints`: Float32 `[1, 128, 4]`, the pen path (spec in Shared contracts).
   - `strokeGlobals`: Float32 `[1, 2]`, `[min(strokeCount, 6) / 6, clamp(ln(w / h), −3, 3) / 3]`.
   - Output `logits`: Float32 `[1, 59]` in the class order of `math-vocab.json`. Swift applies
     the manifest's temperature and the softmax.
   - Output `embedding`: Float32 `[1, 256]`, the post-ReLU hidden layer before the final
     Linear. Wave 5 personalization uses it. It is exported from the first trained model on,
     so the model never has to be re-exported for wave 5.
   - Core ML compute units: the latency test measures `.cpuOnly` and `.all` (median of 1,000
     runs each) and the runtime uses the faster one. Record the choice in `running.md`.
5. **Context via a line decoder.** Each symbol yields label likelihoods: class probability
   times soft geometric member weight. A 4-gram math language model rescores the whole
   current line with forward–backward. The new symbol is substituted only when its posterior
   is at least `τ_sub`.
6. **Revisions (Ayush's choice).** When later context strongly disagrees, the **previous two**
   symbols can be swapped, with thresholds below. A swap belongs to the undo step of the
   commit that caused it. Older symbols are frozen.
7. **Multiplication (Ayush's choice).** `×` is dropped. Every x-shape is the variable `x`;
   multiply with a raised `·`.
8. **No off-the-shelf model is used as the main recognizer** (see "Existing models
   considered"). Apple has no math-ink API; open models are image-to-LaTeX and give no
   per-stroke symbols. A whole-expression transformer is also unnecessary, because the
   writing cell already separates symbols at commit.
9. **Exponents and subscripts (added after the audit).** A small symbol written raised is an
   exponent (`x²`); a small symbol written lowered is a subscript (`aₙ`). It is redrawn at its
   written size and height instead of being snapped to the baseline. Spec: "Script
   placement" in Shared contracts. The language model needs no change, because training
   already linearizes `^{…}` and `_{…}` inline.
10. **Correcting and learning (added after the audit; wave 5).**
    - Correcting: the most recent symbols offer their top 3 alternatives, selectable by click
      or keyboard.
    - Learning: confirmed and corrected glyphs are stored on-device as examples of Ayush's
      handwriting, and nearest-neighbor matching against them adapts recognition to Ayush's
      trackpad style.
    - No Core ML updatable model is used: a nearest-neighbor search in Swift over the model's
      `embedding` output is simpler and fully local.
11. **Stacked fractions (Ayush, 2026-10-04: important).**
    - **Gesture (Desmos-style, Ayush's choice):** write a term, then write `/`. The term
      shifts up into a numerator over a clean fraction bar, and the writing cell moves
      **below the bar** for the denominator. Pressing the `/` key does the same.
    - **Slash at the start:** a `/` with no term before it (line start, or right after an
      operator or `(`) makes an empty fraction with the cursor in the numerator; `↓` then
      moves to the denominator.
    - Every recognized `/` in math becomes a fraction (as in Desmos). There is no inline
      slash. A horizontal dash is always a minus and never triggers a fraction.
    - **Numerator ("pull up last term"):** the symbols back to the nearest body-level
      `+ − = ≠ < > ≤ ≥ ± ÷ ·`, word space, unmatched `(`, or line start.
    - **Parentheses:** if the term ends in a balanced `( … )` group, the whole group is the
      numerator, and its **outer parentheses are removed**, because stacking makes them
      redundant. So `(x+1)/` gives x+1 over the bar. Letters directly before a group stay
      attached and keep the parentheses, so `sin(x)/` gives sin(x) on top. Parentheses
      written inside a denominator stay as written.
    - **Leaving and moving:** `→`/Tab leave the fraction (inside a fraction they don't insert
      a word space); `↑`/`↓` move between numerator and denominator.
    - **Nesting:** fractions nest up to 2 deep.
    - **Spec:** "Fraction layout" in Shared contracts.
    - Structure lives only for the writing session; afterwards the strokes are ordinary
      ink, as with all Write-mode letters today.

---

## Existing models considered (researched 2026-10-03)

| Option | Why not (as the main recognizer) |
|---|---|
| `PKStrokeRecognizer` (macOS 27) | Text only, about 1 s per call, no math. Stays as the text-mode recognizer. |
| Vision `VNRecognizeTextRequest` | Image text recognition, not math, and no stroke alignment. |
| CoMER / PosFormer / TAMER (CROHME checkpoints on GitHub) | Offline image → LaTeX for a whole expression with beam search. No per-symbol stroke mapping (we redraw each symbol), trained on about 9k expressions, and heavy to port to Core ML. Could be a later whole-line second opinion; out of scope here. |
| Uni-MuMER / PaLI-style VLMs | Billions of parameters, not on-device. |
| MyScript iink SDK | Proprietary, needs a license key, incompatible with open-sourcing. |
| MathWriting baselines (CTC Transformer, 35M params) | No weights released. |

What we take from the field: online (stroke) features, large real datasets, a grammar or
language model for context, and abstaining when unsure. The 2026-10-04 audit added three
more:
- An alternatives list for quick correction (macOS trackpad Chinese input, GoodNotes,
  MyScript).
- On-device adaptation to the writer (nearest-neighbor over embeddings).
- Measuring the trackpad gap early, not at the end.

Considered and rejected: Bezier-curve stroke encoding (Carbune et al. 2020). Our arc-length
resampling plus trackpad augmentation already handles sampling jitter.


---

## Wave Index

| Wave | Doc | Status | Needs |
|---|---|---|---|
| 0 | [wave-0.md](wave-0.md) | Done | — |
| 1 | [wave-1.md](wave-1.md) | Done | contracts: math-vocab.json, Soft resolver, Linearization, Pen-path features, Language model; data.md |
| 2 | [wave-2.md](wave-2.md) | In progress | contracts: all |
| 3 | [wave-3.md](wave-3.md) | Todo | contracts: all; data.md |
| 4 | [wave-4.md](wave-4.md) | Todo | — |
| 5 | [wave-5.md](wave-5.md) | Todo | contracts: Decoder |

---

## Rough effort
Wave 0: about 1 h (downloads). Wave 1: 1 day in parallel. Wave 2: 2.5–3 days (now includes
script placement and stacked fractions). Wave 3: 1–1.5 days (augmentation sweep; the harvest only if needed;
training is about 2–4 h per full run on the M2). Wave 4: half a day. Wave 5: 1.5 days.
