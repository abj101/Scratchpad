**Before you start:** Read [README.md](README.md) first.

**Shared contracts:**
- [math-vocab.json](contracts.md#math-vocabjson-sourcescanvaskitresources-owned-by-a)
- [Soft resolver](contracts.md#soft-resolver-symbolresolvermemberweights-owned-by-a)
- [Linearization](contracts.md#linearization-latex--label-sequence-scriptsglyphslinearizepy-owned-by-c)
- [Pen-path features](contracts.md#pen-path-features-scriptsglyphssequencepy--glyphsequenceswift-owned-by-d)
- [Language model](contracts.md#language-model-mathlmjson--mathlanguagemodelswift-owned-by-c)

**Data:** See [data.md](data.md) for exact data sources.

---

[Previous wave](wave-0.md) · [Next wave](wave-2.md)

---

### Wave 1 (parallel, 4 Luna agents)

**Complete:** A–D integrated and independently verified. Hamilton allocation resolves
the original pen-path blocker. Wave 2 has not started.

**A. Math vocabulary + soft resolver.** Owns: `Resources/math-vocab.json`,
`MathVocabulary.swift` (new), `SymbolResolver.swift`, `scripts/glyphs/resolver.py`,
`Tests/.../SymbolResolverTests.swift`, `MathVocabularyTests.swift` (new).
- Build `math-vocab.json` exactly per Decision 3 and the contract, from `vocab.json` entries
  (keep each label's Hershey key).
- Add `memberWeights` per contract. Keep the existing hard `resolve` working (it's used until
  task G switches over); delete it in wave 4.
- Tests: 59 classes / 65 labels; logit order is lexical; every label has a Hershey glyph;
  memberWeights sum to 1; exact values for 20 fixtures.

Status: [x] integrated and independently verified.

**B. Data pipeline.** Owns: `scripts/glyphs/datasets.py`, `scripts/glyphs/DATA.md`.
- Subcommands: `mw-symbols`, `crohme`, `hwrt`, `stats`. Each writes `build/datasets/<src>-<split>.jsonl.gz`
  with records `{src, split, writer, label, class, strokes: [[[x, y, t], …], …], ink_id}`,
  using math labels only (others dropped, and counted in stats).
- MW: stream the tgz. `symbols.jsonl` → load the referenced `train/` inks → extract strokes
  by `strokeIndices`. Map `label` LaTeX through C's linearize table; for B's purposes, copy
  the single-token mapping table above into a module constant; C's module becomes the shared
  one in wave 2. Keep only those that map to exactly one math label.
- CR: unzip the inner zips in memory, parse traceGroups, map truth symbols with the same
  table (`\lt`/`\gt` → `<`/`>`, `\ldots` → drop). CROHME `Train.zip`: split by writer with
  SHA-256(`20261003:crohme:<writer>`) into 10% validation. `valid.zip` → `split = "test"`.
  `subTask_symbols/Train.zip` → train only, and drop any whose source expression id is in
  validation or test.
- HW: reuse `train.py`'s reader and writer split, re-mapped to math labels.
- `stats` writes `build/datasets/stats.json`: count per class × source × split.
- Checks: deterministic output bytes across two runs; no ink id appears in two splits; disk
  used ≤ 3 GB.

Status: [x] integrated; two full source passes byte-identical, schema/split/exclusion
audit passed for 209,023 records (64,930,469 compressed bytes).

**C. Linearizer + language model.** Owns: `scripts/glyphs/linearize.py`,
`scripts/glyphs/grammar.py`, `scripts/glyphs/lm.py`, `Resources/MathLM.json`,
`MathLanguageModel.swift` (new), `MathLanguageModelTests.swift` (new), and the LM fixtures.
- `linearize.py` per the contract, with 40 unit tests built from real `normalizedLabel`
  strings in the MW excerpt.
- Corpus: (a) MW `train/` and `synthetic/` normalized labels, plus CROHME `Train.zip` truth.
  Keep a sequence if `unk_count / len ≤ 0.10`. (b) `grammar.py` generates
  `0.5 × |a|` expressions with seed 20261003, drawn uniformly from these templates (random
  integers of 1–3 digits, variables from `x y z t n a b`, optional parentheses):
  linear equations `ax + b = c`; polynomials `f(x) = 3x2 − 5x + 7` (exponents inline);
  derivatives `d/dx(…)`, `dy/dx`, `f′(x) = …`; integrals `∫ x2 dx`, `∫ 0 1 (…) dx`; limits
  `lim x → 0 sin x / x`, `lim n → ∞ …`; trig/log `sin θ`, `cos(2x)`, `tan x`,
  `log 2 8 = 3`, `ln e = 1`; sums `∑ n = 1 ∞ 1/n2`, `n!`; inequalities `x ≤ 5`,
  `|x − 2| < 3`; the quadratic formula `x = (−b ± √(b2 − 4ac)) / (2a)`; decimals `3.14`,
  `0.5x`; `f(x, y)`; degrees `sin 45°`; `Δy / Δx`. Never use MW `valid/` or `test/`.
- Train the LM and write `MathLM.json` (≤ 3 MB). Report perplexity on MW `valid/`
  linearized labels.
- Swift loader and parity tests as in the contract. Check that `x` outscores `·` after `2`
  in `2_+4`.

Status: [x] integrated; 40 real-source goldens, 50 Swift/Python queries and 304
probability-mass contexts pass. Model: 2,922,626 bytes; all-nonempty MW valid
perplexity 13.00820699810784 (15,674 expressions / 178,512 labels). Whole-expression
`2x+4` outscores `2·+4`; isolated `x|2` slightly trails `·|2`.

**D. Pen-path features + v2 runtime.** Owns: `scripts/glyphs/sequence.py`,
`GlyphSequence.swift` (new), `GlyphSequenceTests.swift` (new), the sequence fixtures, and
(in wave 2) `MathGlyphClassifier.swift`.
- Wave 1: features and parity per contract.

Status: [x] wave 1 features integrated and independently verified; wave 2 runtime pending.

