**Before you start:** Read [README.md](README.md) first.

**Shared contracts:**
- [Decoder](contracts.md#decoder-mathlinedecoderswift--scriptsglyphsdecoderpy-owned-by-e)

---

[Previous wave](wave-4.md) · End of plan

---

### Wave 5: quick correction and personalization (after checkpoint 2)

**J. Alternatives (keyboard-first).** Owns: `ScribePreviewPill.swift`, `MathCorrection.swift`
(new), `MathCorrectionTests.swift` (new). CanvasView hooks are integrated by Sol.
- **Why keyboard:** in math Write mode the trackpad is absolutely mapped to the writing
  panel, `rightMouseDown` is swallowed (`CanvasView.swift:2566`), and the pill never takes
  events. Clicking a glyph mid-writing isn't possible.
- **Display:** after each commit, the pill shows the **target** symbol's alternatives from
  `MathLineDecoder.alternatives(at:)` as `1 x · 2 × · 3 ∗ · 0 ink`, with nothing shown when
  there are no alternatives. The target is the newest symbol; it resets on each commit.
- **Keys** (only while math Write mode is active and a target exists; otherwise keys pass
  through):
  - `⌃1`, `⌃2`, `⌃3` apply that alternative.
  - `⌃0` keeps the symbol as tidied ink.
  - `⌃[` and `⌃]` move the target back or forward among the last 3 symbols (the same window
    as revisions).
  - Avoid `⌃←`/`⌃→` (macOS Spaces).
- **Shortcut conflicts:** a keyDown already cancels the lone-Control toggle
  (`trackModifierTap`, `CanvasView.swift:1471`); add a test proving `⌃1` doesn't toggle math.
  If `⌃1–3` are captured by Mission Control's "Switch to Desktop" on Ayush's Mac, use
  `⌃⇧1–3` instead and note it in `running.md`.
- **Fraction bars:** when the target is a fraction bar, the alternatives are the slash's
  other decoder candidates (for example `1`, `l`, `|`). Choosing one dissolves the fraction
  as the empty-denominator Delete does, then shows that symbol in place of the slash.
- **Applying a choice:** re-render the symbol the same way a revision does. The choice is
  **one undo step**, and the symbol becomes pinned (decoder contract) and is recorded as a
  correction for K.
- **Pointer tool:** when the active tool is not tablet-based, a right-click on a glyph in the
  current math line opens an `NSMenu` with the same alternatives and "Keep as ink".
- **Tests:** pure logic for target movement, pinning, undo (one step), and pass-through when
  inactive.

**K. On-device personalization (nearest neighbor).** Owns: `MathPersonalization.swift` (new),
`MathPersonalizationTests.swift` (new), `scripts/glyphs/personal_eval.py` (new), and the
Settings toggle (`SettingsView.swift`, one row).
- **Store:**
  `~/Library/Application Support/Scratchpad/math-personal.json`, with entries
  `{label, embedding: [256 Float16 as base64], source: "confirmed" | "corrected", date}`.
  Keep at most 50 entries per label; when full, evict the oldest "confirmed" entry before
  any "corrected" one. Write atomically, debounced by 2 s, off the main thread.
- **What gets stored:**
  - A **corrected** entry each time J applies an alternative (not for "keep ink").
  - A **confirmed** entry when a substituted symbol had a marginal ≥ 0.95, then falls out of
    the 3-symbol revision window without being revised, corrected or undone.
  - Nothing from ink-only symbols.
- **Scoring:** cosine similarity between the symbol's `embedding` and stored entries;
  `k = 5`. `p_knn(label) ∝ Σ w · exp(sim / 0.1)` over the top-k, with `w = 2` for corrected
  and 1 for confirmed. Blend into the label likelihoods before decoding:
  `L = (1 − α) · L_model + α · p_knn` with `α = min(0.5, N / 400)`, where N is the total
  number of stored entries. With N = 0 nothing changes. Must cost ≤ 0.3 ms at 3,250 entries
  (vectorized with Accelerate `vDSP`).
- **Settings:** "Learn from my handwriting" (default on) and "Reset learned handwriting".
  Data never leaves the device; nothing is uploaded or synced.
- **Offline check (report only):** `personal_eval.py` seeds the store with **CAP-tune**
  embeddings (as "corrected") and reports CAP-test isolated accuracy with and without
  personalization. This is CAP-test's second use, allowed because the model is frozen and
  nothing is tuned on it; log it in `running.md`. Expect gains; if accuracy drops, set
  α's cap to 0.3 and report.

**Checkpoint 3 `[?]` (Ayush, about 10 min).**
1. Write `5s`, `2z`, `9g`, and anything that tends to misread for you; fix misreads with
   `⌃1–3`, `⌃0` and `⌃[`/`⌃]`.
2. Confirm the shortcuts feel fast and don't trigger anything else.
3. After a few days of normal use, note whether misreads become rarer.

