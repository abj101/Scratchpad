**Before you start:** Read [README.md](README.md) first.

**Shared contracts:**
- [Language model](contracts.md#language-model-mathlmjson--mathlanguagemodelswift-owned-by-c)
- [Decoder](contracts.md#decoder-mathlinedecoderswift--scriptsglyphsdecoderpy-owned-by-e)
- [Script placement](contracts.md#script-placement-mathscriptswift-owned-by-g)
- [Fraction layout](contracts.md#fraction-layout-mathfractionswift-owned-by-l)
- [Pen-path features](contracts.md#pen-path-features-scriptsglyphssequencepy--glyphsequenceswift-owned-by-d)
- [math-vocab.json](contracts.md#math-vocabjson-sourcescanvaskitresources-owned-by-a)
- [Soft resolver](contracts.md#soft-resolver-symbolresolvermemberweights-owned-by-a)
- [Manifest v2](contracts.md#manifest-v2-mathglyphs-manifestjson)

---

[Previous wave](wave-1.md) · [Next wave](wave-3.md)

---

### Wave 2 (parallel, after wave 1 is integrated)

Status: E `[x]` · D runtime `[x]` · L `[x]` · F `[x]` · G `[x]` · Checkpoint 1 `[?]`

**E. Decoder.** Owns: `MathLineDecoder.swift` (new), `scripts/glyphs/decoder.py`,
`MathLineDecoderTests.swift` (new), and the decoder fixtures.
- Implement per contract against A's resolver and C's LM, with Swift↔Python parity on 15
  fixed lattices (marginals within 1e-9; identical decisions).
- Scenario tests with a stub likelihood source:
  1. `2 [x 0.5 / · 0.5]` followed by `+` → `x`.
  2. `[bar] o g` → `l`.
  3. `c [ring] s` → `o`.
  4. `4 [ring] [ring]` → `0 0`.
  5. A revision fires: k−1 displayed `·`, the new evidence flips it to `x` at 0.95.
  6. A revision is blocked: the old label still has a marginal of 0.2.
  7. A k−3 symbol never changes.

**D (continued). v2 classifier runtime.** Owns: `MathGlyphClassifier.swift`,
`MathGlyphClassifierTests.swift`.
- Support the 3-input model and manifest v2: temperature softmax, then `labelLikelihoods(strokes, bounds, context) -> [String: Double]`
  (class probability × memberWeights, keep top 5, renormalize).
- **Legacy adapter (temporary):** when the bundled manifest is v1, map the v1 group
  probabilities onto math labels: `P(label) = P(v1 group) × memberWeights` over the math
  members of that group (old `ambig_*` groups use A's merged classes where they overlap;
  `ambig_x_times` → `x` only; groups without math labels are dropped). Renormalize, and
  **ignore the v1 `disabledLabels`**. This lets checkpoint 1 run before the new model exists.
- Build a dummy 3-input model (random weights, the exact contract shapes) with a
  `scripts/glyphs/train_v2.py export --dummy` path so the runtime is tested before training.

**L. Stacked fractions (pure logic).** Owns: `MathFraction.swift` (new) and
`MathFractionTests.swift` (new). Runs in parallel with E, D and F. No `CanvasView` edits;
implement the "Fraction layout" contract as value types and functions with all of its
tests.

**F. Bootstrap model (stage 1).** Owns: `scripts/glyphs/train_v2.py`,
`scripts/glyphs/TRAINING-v2.md`.
- Data: B's MW-symbols, CR train, CR symbols, HW train, plus SY top-up. Validation: CR
  validation plus HW validation. Cap at 20,000 samples per class per epoch, drawn uniformly
  from that class's pool each epoch.
- Augmentation, applied on the fly to strokes before both the raster and the pen path:
  rotation ±10°; shear ±0.3; x-scale 0.8–1.25; elastic warp (σ = 0.08 of size,
  smoothness 3); per-point jitter σ = 0.01; **trackpad simulation** with p = 0.5 (resample to
  uneven 8–16 ms spacing, 3-tap moving average, then 1–3% sinusoidal tremor); with p = 0.2,
  reverse one stroke's direction; with p = 0.1, permute the stroke order of multi-stroke
  symbols. Use 8 DataLoader workers. If raster.py throughput is below 5,000 samples/s, write
  a vectorized NumPy raster that matches `raster.py` byte-for-byte on 1,000 random records.
- Architecture:
  - Raster branch: the v1 TinyCNN trunk producing a 64-d embedding.
  - Path branch: Conv1d 4→64 (k5) → 64→96 (k5, stride 2) → 96→128 (k3, stride 2), ReLU and
    BatchNorm, then concatenated global average and max pooling (256-d) → Linear 128.
  - Concatenate both with the 2 globals → Linear 256 → ReLU → Dropout 0.25 → Linear 59.
- Training: AdamW (lr 1e-3, weight decay 1e-4), cosine schedule over 30 epochs, label
  smoothing 0.05, batch 512, MPS, seed 20261003. Select the checkpoint on validation class
  accuracy.
- Export: FP16 ML Program, compiled bundle ≤ 1,000,000 B, Core ML vs PyTorch parity within
  3e-3 on 5 fixed inputs.
  **Approved exception (Ayush, 2026-10-04):** mixed precision may retain sensitive
  operations in FP32. The bundle-size and parity gates are unchanged.
- Report validation class accuracy and the confusion pairs. **Don't touch the test sets.**
- **Early trackpad check:** also report isolated label accuracy on **CAP-tune** (class
  probability × memberWeights, using the capture's own bounds and no line context), with its
  confusion pairs. If it is below 80%, Sol reports to Ayush before wave 3, but G and
  checkpoint 1 continue.
- Export both outputs (`logits`, `embedding`) per Decision 4.

**G. App integration (with the legacy adapter).** Owns: `CanvasView.swift` (math commit
path only), `MathScript.swift` (new), `MathScriptTests.swift` (new),
`MathGlyphCommitTests.swift`, and a new `MathRevisionTests.swift`. One agent, because
`CanvasView` is the hotspot.
- After L is integrated, wire fractions into the commit path, `handleWritingKey` (including
  the `/` key) and `newLine()` per the "Fraction layout" contract. Use the decoder's
  virtual tokens. The fraction trigger runs after the symbol is resolved as `/`. Script placement inside a slot uses that
  slot's stats.
- Implement script placement per the "Script placement" contract. `WrittenLetter` also
  stores its `role`. Before G starts, Sol records in `running.md` the actual baseline
  placement code it changes (`renderCleanGlyph`, the `centerY` branch at
  `CanvasView.swift:1161`).
- `WrittenLetter` gains:
  - `likelihoods: [String: Double]`
  - `displayed: String?` (a label, or nil for ink)
  - `renderInputs`: the cell before commit, `mathLineStats` before, `originalExtent`, and
    the applied `(dx, dy)`.
- Line context = the `WrittenLetter`s committed since the last time `mathLineStats` was reset
  to nil (a new line). Sol confirms the reset sites before the agent starts.
- At commit: compute likelihoods → run the decoder over the line → substitute (or keep ink)
  → apply revisions to k−1 and k−2. To revise: re-render with that letter's stored
  `renderInputs`, apply the same `(dx, dy)`, and replace its strokes. The cell advance isn't
  reflowed.
- Undo: the commit and its revisions form **one** undo group (`⌘Z` restores both). In Scribe
  mode (buffered letters), revisions update `writtenLetters[j].strokes` and
  `writingPanel.bufferedStrokes`.
- `mathResolverStats` is recorded from the displayed label's kind (same rule as now).
  `previousSymbol` becomes the displayed label of k−1.
- Tests: end-to-end with the classifier test seam covering scenarios 1, 5 and 7 above, plus
  undo restoring both glyphs. Full commit latency ≤ 5 ms in `MathGlyphLatencyTests` (Release).

**Checkpoint 1 `[?]` (Ayush, about 10 min, current v1 model + new vocab + context).** Sol
writes the checklist into `running.md`:
1. Math input: write `2x+4−21+400`, `21−4=5x−21`, `7x+21`.
2. Write `sin x`, `log 2`, `lim x→0`.
3. Write `x·3` with a raised dot.
4. Write `x` then `+`, and watch whether an earlier glyph swaps.
5. Press ⌘Z once after a swap.
6. Write `x²+3x`, `eˣ`, `x⁻¹` and `aₙ`. Exponents should stay small and raised, and
   subscripts small and lowered.
7. **Fractions:**
   - Write `3x/4`: you should get 3x over 4. Then `→` and `+1`.
   - Write `2+x/y`: only `x` should move up.
   - Write `(x+1)/(x−1)`: the top should lose its parentheses; the bottom keeps them.
   - Write `sin(x)/x`.
   - Start a line with `/`, write the top, press `↓`, and write the bottom.
   - Try the `/` key.
   - Try a fraction inside a numerator.
   - Use `↑`/`↓` between parts, Delete in an empty denominator, and ⌘Z.
   - Write `5−3`: the minus must **not** become a fraction.

Report wrong glyphs, swaps that felt wrong or jarring, exponents that dropped to the line,
fractions that triggered when they shouldn't have (or didn't when they should), awkward
spacing, and whether undo restored things. This validates the UX only; accuracy improves in wave 3.
