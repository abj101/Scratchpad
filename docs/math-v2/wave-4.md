**Before you start:** Read [README.md](README.md) first.

---

[Previous wave](wave-3.md) · [Next wave](wave-5.md)

---

### Wave 4 (Sol): integrate and clean up
- [ ] Bundle the v2 `MathGlyphs.mlmodelc`, manifest v2, `MathLM.json`, `math-vocab.json`
  and `MATH-MODEL-LICENSE.md`. Remove the legacy adapter, the hard `SymbolResolver.resolve`
  and the v1 model files.
- [ ] Keep `vocab.json` only if still referenced (`grep`); otherwise delete it with its
  tests.
- [ ] Run `swift test`, Debug and Release `xcodebuild`, and the latency tests. Update
  `TRAINING-v2.md`, `running.md` and this file's checkboxes. Commit locally.

**Checkpoint 2 `[?]` (Ayush, about 15 min, accuracy).**
1. Repeat checkpoint 1.
2. Write `f(x)=3x²−5x+7`, `f′(x)=6x−5`, `∫x²dx`, `lim x→∞ 1/x = 0`, `|x−2|<3`, `x=(−b±√(b²−4ac))/2a` (stacked),
   `sin 45° = √2/2`, `Δy/Δx`, `∑ n=1 ∞ 1/n²`, `3.14`, `f(x,y)`.
   Also write `x¹⁰`, `aₙ₊₁` and `e⁻ˣ`, and check that exponents and subscripts keep their
   size and height. Write `dy/dx`, `1/x`, `(sin x)/x` and `∫ 1/(1+x²) dx` with `/`; each
   should become a stacked fraction.
3. Report every wrong glyph (what you wrote → what appeared), every symbol left as ink that
   should have been redrawn, and any swap that felt wrong.

