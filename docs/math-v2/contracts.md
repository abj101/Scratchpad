## Shared contracts
## Table of Contents

- [math-vocab.json](#math-vocabjson-sourcescanvaskitresources-owned-by-a)
- [Linearization](#linearization-latex--label-sequence-scriptsglyphslinearizepy-owned-by-c)
- [Pen-path features](#pen-path-features-scriptsglyphssequencepy--glyphsequenceswift-owned-by-d)
- [Soft resolver](#soft-resolver-symbolresolvermemberweights-owned-by-a)
- [Language model](#language-model-mathlmjson--mathlanguagemodelswift-owned-by-c)
- [Decoder](#decoder-mathlinedecoderswift--scriptsglyphsdecoderpy-owned-by-e)
- [Script placement](#script-placement-mathscriptswift-owned-by-g)
- [Fraction layout](#fraction-layout-mathfractionswift-owned-by-l)
- [Structures: limits and roots](#structures-limits-and-roots-mathstructureswift-mathliveeditorjs)
- [Delimiters: absolute-value bars](#delimiters-absolute-value-bars-mathliveeditorjs-settingsautoclosebrackets)
- [Manifest v2](#manifest-v2-mathglyphs-manifestjson)

---


These are the interfaces between tasks. Parallel agents code against them, not against each
other's code.

### `math-vocab.json` (Sources/CanvasKit/Resources, owned by A)
```json
{"version": 2,
 "classes": [{"id": "ring", "labels": ["0","o","°"]}, {"id": "glyph_u0032", "labels": ["2"]}, …],
 "labels":  [{"label": "0", "class": "ring", "kind": "digit", "hershey": "0", "latex": ["0"]}, …]}
```
- 59 classes, sorted lexically by `id`; this order **is** the logit order. Single-label class
  ids are `glyph_uXXXX` (uppercase hex, as in v1). Merged ids are `ring`, `bar`, `dot`, `tick`.
- `kind` is one of `digit`, `lower`, `operator`, `delim`, `low`, `raised`, `calc`. `·` and
  `′` are `raised`; `.` and `,` are `low`.

### Linearization: LaTeX → label sequence (`scripts/glyphs/linearize.py`, owned by C)
Input is an MW `normalizedLabel` (or `label` for symbols) or a CROHME truth string. Output is
a list of math labels and `<unk>`. Tokenize with MathWriting's tokenizer rules (a backslash
command, or a single character). Then:

| Token(s) | Output |
|---|---|
| `0–9`, `a–p`, `r–z` | itself |
| `q`, `A–Z` (except via `\Delta`), any other letter or command not listed | `<unk>` |
| `+` `=` `<` `>` `/` `!` `(` `)` `[` `]` `.` `,` | itself |
| `-` | `−` |
| `\cdot` `\times` | `·` |
| `\div` | `÷` |
| `\pm` | `±` |
| `\neq` `\ne` | `≠` |
| `\leq` `\le` | `≤` |
| `\geq` `\ge` | `≥` |
| `\|` `\vert` `\mid` `\lvert` `\rvert` | `\|` |
| `'` `\prime` | `′` (a `^{\prime}` group becomes one `′`) |
| `\circ` inside `^{…}` | `°` |
| `\sqrt` | `√` (`\sqrt[` → `<unk>`) |
| `\int` `\sum` `\pi` `\theta` `\Delta` `\infty` | `∫ ∑ π θ Δ ∞` |
| `\to` `\rightarrow` | `→` |
| `\lim` `\sin` `\cos` `\tan` `\log` `\ln` `\exp` `\sec` `\csc` `\cot` | their letters (`l i m`, …) |
| `\mathrm{X}` `\operatorname{X}` | the letters of X |
| `^` `_` `{` `}` `\left` `\right` `\,` `\;` `\quad` `\!` and spaces | dropped (contents stay inline) |
| `\frac{A}{B}` | `A / B` if A and B each linearize to exactly one label, else `( A ) / ( B )` |

Two flags are returned with the sequence: `has_frac` and `unk_count`.

### Pen-path features (`scripts/glyphs/sequence.py` + `GlyphSequence.swift`, owned by D)
1. Use strokes in written order and points in time order. Drop strokes with no points. If
   more than 64 strokes remain, keep the first 64. Within a stroke, drop a point exactly
   equal (x and y) to the point before it. `n` is the resulting stroke count, 1 ≤ n ≤ 64.
   (No strokes means no features: the caller returns nil and never classifies.)
2. **Lengths.** All arithmetic is IEEE double, in the order written here, with no fused
   multiply-add (Swift: write `dx * dx` and `dy * dy` as separate `let`s; never use
   `hypot`, `addingProduct` or `fma`). Segment length is `sqrt(dx*dx + dy*dy)`. `len_i` is the
   sum of segment lengths from first to last (a 1-point stroke has `len_i = 0`).
   `L = len_1 + len_2 + … + len_n`, summed left to right.
3. **Allocation (Hamilton largest remainder above a 2-sample floor).** It can never violate
   the floor, because 128 ≥ 2 × 64.
   - Every stroke first gets 2 samples. The spare count is `R = 128 − 2n` (0 ≤ R ≤ 126).
   - If `L > 0`: `q_i = (Double(R) * len_i) / L`, `base_i = floor(q_i)`,
     `frac_i = q_i − base_i`. Hand the `R − Σ base_i` leftover samples one each to strokes
     sorted by `frac_i` descending, ties to the earlier stroke index. `count_i = 2 + base_i + bonus_i`.
   - If `L == 0` (taps and dots only): `count_i = 2 + R / n` (integer division), and the first
     `R mod n` strokes in written order get 1 more.
   - Assert `Σ count_i == 128` and every `count_i ≥ 2`.
   - Worked examples, which must be unit tests in both languages:
     - lengths `[2, 1] + [0] × 62` → R = 0 → all 2.
     - one tap → `[128]`.
     - three taps → R = 122, 40 each, first two get 1 more → `[43, 43, 42]`.
     - lengths `[3, 1]` → R = 124, q = `[93, 31]` → `[95, 33]`.
     - lengths `[1, 1, 1]` → R = 122, q = 40.667 each, base 40, leftover 2 → `[43, 43, 42]`.
4. **Resampling.** A stroke with `count = k` and `len > 0` takes targets
   `s_j = (Double(j) * len) / Double(k − 1)` for j = 0…k−1. Walk the cumulative segment lengths
   (summed in point order) and linearly interpolate in the first segment whose cumulative end
   is ≥ `s_j`, with `t = (s_j − segStart) / segLen`. Sample 0 is exactly the first point and
   sample k−1 is exactly the last point (no interpolation). A stroke with `len == 0` repeats
   its single point k times.
5. Normalize: compute the bbox from the kept points of step 1 (not the resampled ones),
   subtract its center, divide by `max(w, h, 1e-6)`, and keep y increasing
   **downward** (same as `raster.py`). Features per sample are
   `(x, y, isStrokeStart, isStrokeEnd)`, with the flags as 0/1.
6. Parity: the Swift and Python outputs on the six existing raster fixtures plus six new
   ones (a dot tap, three taps, `=`, `i`, a 9-stroke scribble, and 70 strokes with lengths
   `[2, 1] + [0] × 68`) must agree within 1e-5, and the per-stroke counts must be identical. Fixtures go in
   `Tests/CanvasKitTests/Fixtures/sequence/`.

### Soft resolver (`SymbolResolver.memberWeights`, owned by A)
`memberWeights(class:bounds:context:) -> [String: Double]` returns weights that sum to 1 over
the class's labels. Let `h = medianHeight` (fall back to the cell height × 0.4 when there is
no median), `r = (baseline − bounds.midY) / h` (raised-ness), `s = max(w, h_b) / h` (size),
and `σ(z) = 1 / (1 + e^(−z / 0.05))`.
- `dot`: `w(·) = σ(r − 0.30)`, `w(.) = 1 − w(·)`.
- `tick`: `w(′) = σ(r − 0.45)`, `w(,) = 1 − w(′)`.
- `ring`: `w(°) = σ(r − 0.55) · σ(0.45 − s)`. The remaining `1 − w(°)` splits between `0`
  and `o`: **math mode 0.9 / 0.1** (digits preferred; the LM can still move it to `o`),
  text mode equally.
- `bar`: **math mode `1 = 0.9`, `l = 0.05`, `|` = 0.05**; text mode 1/3 each (the LM decides).
  (Neutral splits left `0` capped near 0.5 and `1` at 0.2–0.33, under τ_sub, so isolated
  digits stayed ink; found in checkpoint-1 manual testing.)
- Single-label class: `[label: 1]`.
- If baseline or median is missing: dot/tick give 0.5/0.5, ring gives `° = 0.05` with `0 = 0.855`, `o = 0.095` (math) or `° = 0.1`, `0 = o = 0.45` (text).

Python twin: `scripts/glyphs/resolver.py`, with 20 parity fixtures agreeing within 1e-9.

### Language model (`MathLM.json` + `MathLanguageModel.swift`, owned by C)
- Order 4, interpolated modified Kneser–Ney. Vocabulary is the 65 labels plus `<s>` and
  `<unk>` (no `</s>`, because lines are scored while they're still being written).
- Stored in ARPA-equivalent JSON:
  `{"order": 4, "vocab": [...], "ngrams": {"<ctx joined by U+001F>\u001E<word>": [log10p, log10backoff]}}`.
- Prune n-grams of order 3 and above with count < 2. **File ≤ 3 MB**; raise the pruning
  count until it fits.
- Swift `logProb(_ word: String, context: [String]) -> Double` uses standard backoff.
  Python/Swift parity: 50 fixed queries within 1e-9.
- **Function words:** the corpora linearize `\sin` etc. to `<unk>`, so `lm.py` adds spelled
  letter lines for the 20 function names (sin cos tan sec csc cot log ln exp lim max min det
  mod arcsin arccos arctan sinh cosh tanh) after a one-symbol context prefix (`2 + − = ( [ ·`),
  weight 400 per line. The prefix is context only (`context_only=1`), so the line-start
  distribution is unchanged. Retraining regenerates `lm-queries.json`; after any LM change
  update `mathLMSHA256`, `compiledBundleSHA256` (the compiled bundle's `metadata.json`
  embeds the LM hash) and the decoder fixtures' expected values from `decoder.py`.

### Decoder (`MathLineDecoder.swift` + `scripts/glyphs/decoder.py`, owned by E)
- Input: the line's symbols in commit order; each has label likelihoods `L_i` (the top 5
  labels, renormalized). The line starts after the last line reset (see G). Window: the last
  12 symbols; symbols before that are fixed at their displayed label (or `<unk>` if
  displayed as ink).
- Score: `Σ log L_i(y_i) + λ · ln P_LM(y_i | y_{i−3..i−1})`. Exact forward–backward over the
  top-5 lattice gives the marginals `P_i(y)`.
- **Substitute** new symbol k when `max_y P_k(y) ≥ τ_sub` and the label isn't disabled.
  Otherwise it stays tidied ink.
- **Revise** symbol j ∈ {k−1, k−2} when its argmax `y*` differs from its displayed label,
  `P_j(y*) ≥ τ_rev`, and (if a label is displayed) `P_j(displayed) ≤ 0.10`. A symbol shown as
  ink is upgraded to a glyph under the same rule. A glyph is never downgraded to ink.
- Defaults until tuning: `λ = 0.6`, `τ_sub = 0.80`, `τ_rev = 0.90`. Tuned values live in the
  manifest.
- Must take ≤ 0.5 ms for a 12-symbol window in Release.
- **Virtual tokens (fractions):** the decoder sees the line flattened in reading order, with
  pinned virtual tokens around fractions. A slot with more than one symbol is wrapped as
  `( … )`; a one-symbol slot is not wrapped. The numerator and denominator are joined by
  `/`. This matches the `\frac` linearization the LM was trained on. Virtual tokens have
  likelihood 1, are never displayed, and count toward the 12-symbol window.
- **Pinned symbols (wave 5):** a symbol the user corrected is pinned. Its lattice has only
  the chosen label with likelihood 1 (or `<unk>` for "keep ink"), and it is never revised.
- **Alternatives API (wave 5):** `alternatives(at: j) -> [(label, marginal)]` returns the top
  3 labels by marginal, excluding the displayed one, keeping only marginals ≥ 0.02. It is
  computed during the same forward–backward pass, at no extra cost.

### Script placement (`MathScript.swift`, owned by G)
`MathScript.role(extent:label:kind:stats:) -> Role` (`.body`, `.superscript`, `.subscript`)
is a pure function of the **original** ink extent, the resolved label and kind, and the
line's `mathResolverStats`. Let `h = medianHeight`, `r = (baseline − extent.midY) / h`, and
`s = max(extent.width, extent.height) / h`.
- Return `.body` if stats have fewer than 2 heights, if baseline or median is missing, or if
  the kind is `raised` or `low`, or the label is `°`, `·`, `′`, `.` or `,`.
- Digits, lowercase letters, `π θ Δ ∞` and `( )`: `.superscript` if `s ≤ 0.70` and
  `r ≥ 0.80`; `.subscript` if `s ≤ 0.70` and `r ≤ 0.15`.
- `+` and `−`: `.superscript` if `s ≤ 0.60` and `r ≥ 0.80` (so `x⁻¹` works); never
  `.subscript`.
- Everything else: `.body`.

Effects (in `CanvasView`, task G):
- **Clean glyph:** a script glyph keeps the scale from its observed height (as now) and
  is centered vertically on the original extent's `midY` instead of being placed from the
  baseline.
- **Ink fallback:** script ink skips `alignTransform`.
- **Line stats:** script symbols are **not** recorded in `mathLineStats` or
  `mathResolverStats`, so they don't distort the body height or baseline.
- **Revisions** reuse the stored role.

Unit tests: 12 fixtures covering a body `2`, a superscript `2`, a subscript `n`, a raised
`−`, a body `−`, `°` always body, too few stats → body, and boundary values.
Known limitation (accept it, don't fix it): a tiny raised `0` may resolve to `°`. The LM
gets a say, and checkpoint 2 tests `x¹⁰`.

### Fraction layout (`MathFraction.swift`, owned by L)
These are pure value types and functions; `CanvasView` only applies the transforms they
return.
- **Rows and slots.** A math line is a `Row` of items. An item is a letter (a
  `WrittenLetter` id) or a `Fraction { numerator: Row, denominator: Row, barID }`.
  - Each row has its own `LetterCell` and its own `mathLineStats` / `mathResolverStats`.
  - A slot row's cell has height `0.8 × parent cell height`, so Ayush writes at the same
    physical size on the trackpad and the glyphs land 80% size.
  - A slot's stats start as the parent's stats scaled by 0.8 about the slot's baseline, then
    update from its own symbols.
- **Metrics.** For the parent row let `h` = medianHeight, `b` = baseline, and the math axis
  `a = b − 0.5h`. Then:
  - bar y = `a`;
  - numerator baseline = `a − 0.30h`;
  - denominator baseline = `a + 0.30h + 0.8h`;
  - bar x-span = `[left, left + max(numWidth, denWidth) + 0.3h]`;
  - both rows are horizontally centered on the bar, and `left` is the operand's original
    `minX`.

  If the parent row has fewer than 2 recorded heights, use `h = 0.4 × cell height` and `b` =
  the cell's line baseline from `LetterCell`.
- **Trigger.** It runs after normal recognition. It fires when the committed symbol is
  **substituted as `/`** (decoder posterior ≥ `τ_sub`), when the decoder's best label for it
  is `/` with marginal ≥ 0.5 even though the glyph stayed ink (below `τ_sub`), or when the `/` key is pressed in
  math Write mode with no pending ink. It doesn't fire when the nesting depth would exceed
  2; then the symbol stays a plain `/` glyph. A `/` that formed a fraction is pinned and is
  never revised by the decoder. `operand(row:) -> Range` implements the Decision 11
  numerator rule, including outer-parenthesis removal.
- **On trigger** (one undo group):
  - remove the slash ink and add one clean straight bar stroke at the bar span;
  - if the operand is a `( … )` group (not preceded by attached letters), delete the strokes
    of its outer `(` and `)`;
  - scale the remaining operand strokes by 0.8 about their (minX, baseline) and translate
    them so the numerator row sits at its baseline, centered;
  - move those `WrittenLetter`s into the numerator row;
  - set the writing cell to the denominator row's cell at its left end. With an empty
    operand, the bar starts at the cursor with width `0.9h`, and the cell goes to the
    numerator row.
- **Relayout** after every commit, delete or revision inside a slot: recompute the bar span
  and re-center both rows. Return per-letter translations (and a new bar stroke) for
  `CanvasView` to apply in the same undo group as the commit.
- **Keys inside a fraction** (`handleWritingKey`):
  - `↓` (numerator → denominator end) and `↑` (denominator → numerator end).
  - `→`/Tab: leave the fraction. The parent cursor goes to `bar.maxX + letterGap × H`, and
    the parent row stats are restored.
  - **Delete order** (Desmos-like), one item and one undo step per press: denominator
    items, then the bar, then numerator items, then earlier symbols. Delete with items in
    the slot removes the slot's last item.
  - Delete in an **empty denominator** removes the bar: with a non-empty numerator it
    dissolves (`MathFraction.dissolve(_, restoringSlash: false)`): the numerator letters
    return to the parent row at their original placement, any removed outer parentheses
    return as ink, the handwritten slash is **not** resurrected, and the cursor goes after the
    returned numerator. With an empty numerator the whole fraction is deleted. Delete never
    jumps from the denominator into the numerator.
  - Delete in an empty numerator deletes the bar if the denominator is also empty;
    otherwise the cursor moves to the denominator.
  - Outside fractions these keys behave exactly as today; `↑`/`↓` are currently unused in
    Write mode.
- **Line spacing:** `newLine()` puts the next line's top at
  `max(current top + linePitch × H, lowest ink maxY on the line + 0.25H)`, so stacked lines
  never collide.
- **Tests:**
  - `/` after `3x` triggers;
  - `/` at line start gives an empty numerator, and `↓` reaches the denominator;
  - a minus never triggers;
  - a third nesting level stays a plain `/`;
  - the `/` key triggers;
  - operand rule fixtures: `2+3x`→`3x`; `sin(x)`→`sin(x)` (parentheses kept);
    `a·b`→`b`; `(x+1)`→`x+1` (outer parentheses removed); `x²`→`x²`;
    `2(x+1)`→`2(x+1)` (kept);
  - exact metric values;
  - relayout when the denominator becomes wider than the numerator;
  - dissolve restores the original transforms exactly, including removed parentheses and
    the slash;
  - ↑/↓/→ navigation;
  - `newLine()` spacing.

### Structures: limits and roots (`MathStructure.swift`, `MathLive/editor.js`)
Handwritten operators that own slots are mirrored into MathLive atoms instead of being
typed as plain symbols. `MathStructure.kind(forLabel:)` maps `∑ → sum`, `∫ → int`,
`lim → lim`, `√ → sqrt`; every other label stays a plain symbol. The edit's `structure`
field carries that name (`MathLiveHandwritingEdit.structure`); `root` is the only edit
that writes `latex` as a root's index rather than opening a structure.
- **Templates** (`editor.js` `structureSource`): `\sum\limits_{p}^{p}`,
  `\int\limits_{p}^{p}`, `\lim_{p\to p}`, `\sqrt{p}` with `p = \placeholder{}`.
  `\limits` forces an operator's limits above and below (an integral would otherwise sit
  beside) and round-trips through MathLive's serializer. A limit opens with both of its
  condition slots — the variable and the value it approaches — and the arrow between
  them is part of the template, so the condition reads `\lim_{x\to0}` once the two slots
  are filled.
- **Slots.** MathLive focuses the first placeholder on insert: the lower limit for the
  operators, the radicand for a root. A `superscript`/`subscript` edit written while a
  placeholder is focused fills that slot rather than opening a lane, and consecutive
  script symbols share the one slot (`i = 1`). `advance` (Tab or the panel's right zone)
  walks lower → upper → body via `moveToNextPlaceholder`; a script edit that leaves an
  open lane first closes it, so `x_{a}^{b}` never nests. A limit's condition walks
  variable → value the same way: `advance` from the variable reaches the value slot, a
  hand-written `\to` types over the template's arrow and steps into that slot (the arrow
  is never doubled), and any other symbol written directly after a filled variable is
  placed past the arrow instead of before it.
- **Late condition ink.** A `lim` run is recognized asynchronously, so a fast writer's
  condition can reach the editor first (`lim_{x}` in plain letters). When the structure
  replacement lands, `editor.js` folds a subscript branch already attached to the run
  into the structure's own slots — `x` becomes the variable, a complete `n\to\infty`
  fills both — instead of leaving a dangling `\lim_{\placeholder{}\to\placeholder{}}_{x}`
  after it. The absorbed symbol keeps its history id, so a later correction still
  rewrites it in place.
- **Root index** (`structure: "root"`). A raised symbol whose enclosing atom is a
  `\sqrt` becomes that root's index: the radical atom's full offset range (children
  precede their parent in the flat atom list, so the range starts at the first atom of
  greater depth) is replaced by `\sqrt[index]{radicand}`, preserving an existing
  radicand. MathLive omits braces for a single-token radicand (`\sqrt2`), so the
  radicand parser accepts both forms. Outside a root the same edit stays an ordinary
  superscript. Rewriting an index later (`replaces`) swaps only the index — the
  editor tracks `rootIndexes` (letter id → root offset) so the radicand survives.
- **Revisions.** `applyMathRevision` opens the structure in place of a bare symbol when
  a candidate pill or decoder revision maps to `∑`/`∫`/`√`; a recognized `lim` run
  replaces all its letters with one `\lim_{…}` structure.
- **Tests:** label→kind mapping and raw names (`MathStructureTests`); editor slot
  filling, root spawn/index/radicand (empty and filled), index revision keeping the
  radicand, outside-root superscript, summation/integral/limit placement, condition ink
  absorbed when the structure lands late, value written without an arrow
  (`MathLiveEditorTests`); native commits for a root and its raised index, an index
  revision, summation limits with `advance`, a `lim` run, and a `lim` run whose condition
  commits first (`MathStructureCommitTests`).

### Delimiters: absolute-value bars (`MathLive/editor.js`, `settings.autoCloseBrackets`)
Writing the word `abs` (separate letters or one wide stroke group) opens `||` with
the caret between the bars. This explicit structure command works even when
automatic bracket closing is disabled; it uses the same delimiter pairing path.
In Scribe math, consecutive letters share a word run until an explicit space or
nonletter; the separate cell advance is not an ink gap between words. Already
recognized `abs` and `lim` open their structures directly without a second OCR
pass. Ambiguous letters and whole-word ink retain the word recognizer fallback.
A written bar is one side of an absolute value, not the digit `1`:
`CanvasView.mathLatex(for:)` special-cases the `|` label to the single bar, because the
vocabulary lists the double bar (`\|`) first. With `settings.autoCloseBrackets` on, an
opener that has a closer — `(`→`)`, `[`→`]`, `\{`→`\}`, `|`→`|` — inserts that closer in
the same edit and records it under `id + ':close'`. A hand-written closer then types over
the auto one instead of doubling it (`|x|`, never `|x||`), and finishing the pair releases
the caret, so the next body symbol lands after both bars. A digit corrected into `|` brings
its closer the same way, and a correction that lands a bar directly before its auto closer
absorbs that closer rather than nesting the two.
- **Tests:** `MathLiveEditorTests.testAbsoluteValueBarPairsWithItsCloser` (opener, written
  closer, corrected closer, caret leaving the pair, auto-close off) and
  `MathStructureCommitTests.testCorrectedAbsoluteBarBringsItsCloser` (the native commit
  path, where the bar class reads as a digit until the pill corrects it).

### Live field: keys, click placement and fit (`MathLive/editor.js`, `MathLiveEditor.swift`, `CanvasView.swift`)
The live MathLive field is the one place math symbols are edited, so it has to behave like a
text field: a click anywhere in it moves the caret there, one key removes one symbol, and it
never rescales on open.
- **One page per canvas.** `CanvasView` keeps one `MathLiveEditorView`
  (`reusableMathEditor`, created on first use) and retargets it for every equation: opening an
  expression re-parents the view and swaps its source (`setLatex`), closing takes it out of the
  hierarchy but keeps the page loaded. Entering a second expression therefore pays no page
  load, and the field already has real geometry when the host positions and focuses it.
  `activeEquationEditor` stays nil while no equation is edited, so every "is an equation open"
  check reads exactly as before. A page whose web content died (`hasFailed`) is replaced
  instead of reused, so a single failure cannot strand every later equation.
- **The page is released when math editing goes idle.** Closing an equation schedules the
  shared page's release after `mathEditorIdleReleaseDelay` (60 s; a delayed
  `mathEditorIdleRelease` work item). Any math editing in that window — opening another
  equation, a recognized symbol, a revision — cancels it, so re-entering an expression during
  a session is still the loaded page. When it fires with no active equation and no pending
  handwriting, the view is removed and dropped (`releaseIdleMathEditor`), leaving the note
  with no live MathLive page; the next expression mounts a fresh one and pays one page load.
  `mathEditorIdleReleaseDelayForTesting` shortens the window for tests.
- **Available width.** The host measures the room left on the line and calls
  `setMaxWidth(width)` in CSS pixels before the first layout. `applyFit` shrinks **nothing**
  while that width is unknown: the field still sits in its provisional frame, and fitting to
  it scaled the whole expression down and snapped it back when the real width arrived (the
  squish seen when an equation opens). `size` reports `width:height:scale`, so the host sees
  the scale the field applied.
- **Click placement.** `focusAt(x, y)` takes top-left CSS pixels. MathLive resolves only
  points that land on an atom, so a click in the whitespace between two symbols missed every
  atom and left the caret where it was — placing the caret seemed to work only directly on a
  glyph. `offsetNearPoint` searches outward from the click (clamped into the field's box) for
  the nearest position the field can resolve, so any click inside the box places the caret.
  The host lays the web view out (`layoutSubtreeIfNeeded`) before converting the click: the
  view is sized by Auto Layout, so it has to match the frame the host just set — on the very
  first equation it is still empty at that moment, and converting through the empty view
  produced a negative y that parked the caret before the first symbol. Reusing the page makes
  the geometry stale rather than empty on later opens, which the same pass also settles.
- **Keys.** A collapsed Backspace/Delete goes through `deleteStep` — one symbol per press,
  `deleteForward` included. `→` / Tab / the panel's right zone insert a real space at the top
  level and navigate inside a structure (`insertSpace`, which reports whether a space landed
  so the writing cell advances only then).
- **One caret.** MathLive can paint two caret bars for one selection — an operator with side
  scripts (`\int_0^1`) gets a caret in its group and another in the base, and a click can leave
  the native caret beside the slot caret. `dedupeCarets` keeps exactly one: it drops every
  caret after the first, and drops them all when the slot bar (`.ml-slot-caret` on a
  `.ML__selection`) is the caret. It runs from `updateSlotCaret` and from a `MutationObserver`
  on the shadow root, because MathLive can add the caret in a render that lands after the host
  call.
- **Entering from the note.** An inline equation is one attachment character, but it edits
  like a run of text: with the collapsed note caret against an expression, Backspace / ← and
  Forward Delete / → enter the live field at that boundary (`focusBoundary`) and the delete
  keys additionally drop one symbol. `BlockTextView` swallows a Delete it cannot route, so a
  single stray keystroke can never remove a whole expression. The key is remembered in
  `CanvasView.pendingInlineEquationKey` and applied when the page becomes ready, because the
  host queues `evaluate` until then.
- **Tests:** `MathLiveEditorTests.testFieldIsNeverScaledDownBeforeTheHostSetsTheAvailableWidth`
  (no shrink while the width is unknown, fit still applies once it is known),
  `.testClickAnywhereInTheFieldPlacesTheCaret` (a gap MathLive alone cannot resolve),
  `EquationRecognitionIntegrationTests.testClickingAnEquationInTheNotePlacesTheCaretWhereItWasClicked`
  (a click on a freshly opened equation lands inside it),
  `.testNoteLevelDeleteAndArrowEditTheEquationInsteadOfRemovingIt` (Backspace drops one
  symbol, an arrow enters the field at the end it was pressed from),
  `.testSecondEquationReusesTheLoadedPageInsteadOfOpeningANewOne` (the second equation is the
  same view and the same web document, ready with no wait — measured 0.7 ms against 296 ms
  for the first open),
  `EquationRecognitionIntegrationTests.testIdleMathPageIsReleasedAndTheNextOpenMountsAFreshOne`
  (editing inside the idle window keeps the same page, the release drops it, and the next
  expression mounts a new one), and `MathLiveEditorTests.testFieldNeverPaintsMoreThanOneCaret`
  (every caret position and click inside integral, root, script and fraction sources, plus the
  written-integral path, paints at most one caret).

### Manifest v2 (`MathGlyphs-manifest.json`)
Fields: `version: 2`, `classes` (ids in logit order), `mathVocabSHA256`,
`compiledBundleSHA256`, `temperature`, `lambda`, `tauSub`, `tauRev`, `disabledLabels`,
`mathLMSHA256`, `metrics` (copied from the final report).
