# Handwriting Plan

Goal: make trackpad handwriting easy and neat. Use PencilKit for recognition only; no Vision or other image models.

Status key: `[ ]` todo · `[~]` in progress · `[x]` done · `[?]` needs the user's decision or a manual test

---

## Phase 8 — Writing box + stroke modeler

### Why
Trackpad writing gets messy because of size and placement: letters drift, grow, and wander off the line, and there's no cue for where the next word goes. Jitter is a smaller factor. The fix is to **write big, place small**. The whole trackpad maps to a word-sized box on a ruled line. You see that box magnified in a panel, and the ink lands on the canvas at normal note size. The box advances along the line as you write.

### Design (defaults; flag anything to change)
- **Write mode** is a fourth `InputMode` (`.write`) with its own icon, placed next to Tablet in the toolbar pill. It reuses Tablet mode's input source (pen key, finger tracking, two-finger navigation, cursor lock, Esc exits). Only the *mapping target* changes: `TabletMapping.visibleWorldRect = box.rect`, inset 0. The box already has the trackpad's aspect ratio, so `TabletMapping` needs no change.
- **Line metrics:** line height `L` = 32 pt in world space (setting). The box is `2L` tall (baseline at about 65%, which leaves room for descenders) and `2L × trackpad aspect` wide, about one word (~100 pt).
- **Zoom panel:** a strip docked at the bottom of the canvas, rendering the box plus some ink to its left for context. It is magnified to fill the panel and shows baseline/x-height guides, the hover dot and live ink. The main canvas shows the box outline and the ruled line at its real position.
- **Advance:**
  - Automatic: after pen-up, once ink reaches the right ~70% of the box, shift the box right by about half its width.
  - Manual: `→`/`Tab` (next word), `←` (back), `Return` (new line at the line's left margin).
  - Entering Write mode resumes the previous box if it's visible; otherwise it places a new line near the top-left of the visible region. Two-finger panning moves only the viewport.
  - The box never moves mid-stroke.
- **Viewport** auto-scrolls to keep the box visible, without zoom changes.
- **Haptic:** one `.alignment` tick (public `NSHapticFeedbackManager`) on each advance or new line. No continuous texture.
- **Smoothing runs in input space.** In the box, a big finger motion becomes a small world motion, so filters tuned in world units would behave differently. `ToolController.inputScale` (world units per on-screen point the user is watching; fixed per stroke) lets it filter in screen/panel units: `1/magnification` normally, `box width / panel box width` in Write mode.

### Tasks
Execution: wave 1 runs in parallel — agent A (task 1) and agent B (tasks 3–5). Wave 2 is agent C (tasks 6–9). The orchestrator reviews and builds after each wave.

1. [x] **`WritingBox` model** (pure, unit-tested in CanvasKit): line origin, `L`, box rect, guides, `advance()`, `back()`, `newLine()`, auto-advance rule given the stroke bounds.
2. [x] **Mapping:** not needed; `TabletMapping` with `visibleWorldRect = box.rect` and `inset = 0` maps exactly onto the box.
3. [x] **`ToolController.inputScale`;** smoothing runs in input units. Existing behavior stays identical at scale 1. Tests.
4. [x] **Stroke modeler port to Swift** (`StrokeModeler.swift`), after Google's ink-stroke-modeler: Wave 1 done: 423 tests pass.
   - wobble smoother (time-windowed moving average when slow)
   - spring–mass position model with fixed-step Euler
   - end-of-stroke catch-up
   Replaces One-Euro in `ToolController` (keep One-Euro until it's tuned). Tests: endpoints preserved, jitter reduced, monotonic time.
5. [x] **Prediction** for live rendering only: extrapolate a few ms ahead from modeler state, draw it as the live stroke tail, never commit it.
6. [x] **Canvas overlay:** box outline + ruled line + "next word" ghost in `CanvasView`, using the existing overlay-invalidation pattern.
7. [x] **Zoom panel view** (AppKit, in CanvasKit): renders strokes/live stroke in the box's world rect at panel scale, shares the stroke path cache or draws from `model.strokes(intersecting:)`, plus guides and the hover dot.
8. [x] **Advance logic wired:** auto-advance after pen-up, the keys above, placement on entering the mode, keeping the viewport scrolled to the box, and the haptic tick.
9. [x] **Settings + UI:** `.write` in the input-mode pill with an icon, line-height setting, hint text.
10. [~] **Manual test by the user:** write a sentence in writing mode vs plain Tablet mode, compare neatness and comfort, and tune `L`, box width and advance threshold.
11. [ ] *(Stretch)* Speed-based width variation (thinner when fast) for a more ink-like look. Needs variable-width rendering; do it only if cheap.

### Done when
You can write a multi-word line in writing mode without looking down, words land evenly sized on one baseline, and `swift test` + the app build pass.

### Phase 8b — Letter-at-a-time rework (after the user's first test)
User feedback: the 2-line-tall box made letters overlap vertically; the user wants to write without managing letter height. Decision: **one letter at a time**.
- The trackpad maps to one **letter cell**: height `H` (setting, default 32) spans the ascender top to the descender bottom; width `H × trackpad aspect`. Four-line practice-paper guides: ascender (0), x-height (~0.35), baseline (~0.7), descender (1.0). Line pitch is about 1.2·H, so lines never touch.
- A **letter commits** after pen-up + ~0.5 s idle. Its strokes are shifted horizontally so the left edge sits at the cursor; the cursor moves to the letter's right edge + a gap of ~0.12·H. Vertical position is kept as written (the cell already constrains it). The app controls letter spacing.
- Keys: `Tab`/`→` = word space (~0.45·H); `Return` = new line; `Delete` = remove the last letter. Auto-wrap at the right limit.
- Ideally one undo step per letter. Haptic tick on commit.
- [x] Implemented (`LetterCell`, `ToolController.strokeSink`, one undo step per letter). 393 tests pass; app builds. [?] The user retests.

---

## Phase 9 — Recognition (PencilKit only)

- `PKStrokeRecognizer`, gated by `#available(macOS 27, *)`. No recognition on older macOS. **No Vision fallback.**
- Must normalize scale before recognizing: shrink so the median stroke is ~12 pt tall; it silently returns `nil` on trackpad-sized ink. Never mutate stored strokes.
- Recognize per line after a pause (~1 s per call measured), in the background.
- Store `recognitionVersion` with any cached results.

### Design (orchestrator's defaults)
- **No library search exists** (the sidebar was removed), so "handwriting search" is an in-note **Find bar** (⌘F / ⌘G / ⇧⌘G, Esc closes) that matches handwriting (via `search()`) and typed text, highlights matches and scrolls to the current one.
- **Lines** are found geometrically (Write-mode output and free ink alike): strokes cluster into a line when their vertical extents overlap enough; a line also splits at a horizontal gap much wider than its height. One recognizer call per line.
- **Cache** lives in the note file (`NoteDocument.handwriting`), so titles work for closed notes and reopening doesn't re-recognize. A line's entry is keyed by a digest of its strokes' geometry; a cache whose `recognitionVersion` differs from the system's is dropped.
- **Titles:** recognized handwriting joins typed text in reading order (top, then left) for both first-line names and semantic names.
- **Convert to Text** (Edit menu + selection context menu, macOS 27 only): recognizes the selected strokes line by line, replaces them with one `TextBlock` at the ink's top-left (font size picked from the ink's x-height), one undo step "Convert to Text".
- **Word → strokes** (for Phase 10): `HandwritingRecognizer.words(in:)` returns each word's stroke IDs + bounds.

### Contract (CanvasKit)
```swift
// InkNormalization.swift — pure
public struct InkNormalization {            // world → "paper" points
    public static let targetMedianHeight = 12.0, paperOrigin = CGPoint(x: 72, y: 72)
    public let transform: CGAffineTransform  // world → paper
    public init(strokes: [Stroke])          // median stroke height → 12 pt, union top-left → (72,72); scale ≤ 1
    public func toWorld(_ rect: CGRect) -> CGRect
}
// HandwritingLines.swift — pure
public struct HandwritingLine: Equatable { public var strokeIDs: [UUID]; public var bounds: CGRect }
public enum HandwritingLines { public static func group(_ strokes: [Stroke]) -> [HandwritingLine] }  // reading order
// HandwritingRecognizer.swift
public struct HandwritingMatch: Equatable { public var strokeIDs: Set<UUID>; public var bounds: CGRect /* world */ }
public protocol HandwritingRecognizer: AnyObject {
    static var version: Int { get }  // PKStrokeRecognizer.recognitionVersion
    func text(for strokes: [Stroke]) async -> String?
    func search(_ query: String, in strokes: [Stroke]) async -> [HandwritingMatch]
    func words(in strokes: [Stroke]) async -> [(word: String, match: HandwritingMatch)]
}
public enum HandwritingRecognizers { public static func system() -> HandwritingRecognizer? }  // PencilKit on macOS 27+, else nil
// HandwritingCache.swift — Codable, in NoteDocument.handwriting (optional; old files decode)
public struct HandwritingCache: Codable, Equatable {
    public var recognitionVersion: Int
    public var lines: [Entry]
    public struct Entry: Codable, Equatable { public var digest: String; public var strokeIDs: [UUID]; public var bounds: CGRect; public var text: String }
    public var text: String  // non-empty line texts in reading order, joined by "\n"
}
// HandwritingIndexer.swift — @MainActor; watches a CanvasModel, debounced (~1 s after the last stroke change),
// re-recognizes only lines whose digest changed, one at a time; publishes `cache` and calls `onUpdate`.
```

### Tasks
Wave 1: agent A (Sonnet) — tasks 1–4. Wave 2 in parallel: agent B (Sonnet) — tasks 5–6; agent C (Sonnet) — tasks 7–9. Orchestrator reviews and builds after each wave.

1. [x] `InkNormalization` + `HandwritingLines` + tests.
2. [x] `HandwritingRecognizer` protocol, PencilKit implementation (macOS 27), mock for tests.
3. [x] `HandwritingCache` in `NoteDocument` + `Autosaver`; tests (round-trip, old files, version drop).
4. [x] `HandwritingIndexer` + tests with a mock recognizer (debounce, only dirty lines, version drop). Wave 1 done: 423 tests pass.
5. [x] Find bar (handwriting + typed text), highlights, next/previous.
6. [x] Convert to Text (Edit menu, ⌃⌘T, one undo step; the canvas has no context menu).
7. [x] Titles from handwriting (`NoteTitle.derive`/`namingText` take the handwriting text; `AppState` wiring incl. closed notes).
8. [x] `DebugRecognition`: remove Vision; show per-line results from the indexer path.
9. [x] `docs/features.md`: recognition moves out of "out of scope"; describe Find and Convert to Text.
10. [x] Manual test by the user.

### Phase 9b — Scribe mode (after the user's first test)
User feedback: nothing visible happened when writing in Write mode; Find / Convert to Text don't match how the user works. Wanted: a mode like Write mode where **handwriting is only ever visible in the writing panel** and recognized text is placed on the note automatically.

Design (user's answers: per word, one growing text block, Delete removes the last word):
- Fifth `InputMode` `.scribe` ("Scribe", icon `character.cursor.ibeam`), next to Write in the pill; same tablet input, letter cell, panel, letter-commit idle, haptics. Disabled (hidden from the pill) when `HandwritingRecognizers.system()` is nil.
- Letters of the current word **never enter the model**. They live in a scribe buffer laid out by the letter cell in a private coordinate space; the panel draws only that buffer (no model ink) plus the live stroke and hover dot. The canvas shows no cell/ruled line in this mode.
- **Word commit:** Tab / Space / → , or ~1 s idle after the last letter. The word's strokes go to `recognizer.text(for:)`; the panel clears at once so the next word can start while recognition runs; results are applied in order.
- **Target:** the text block being edited/selected when entering the mode, else a new block created at the top-left of the visible area (below existing content in view) on the first word. Words append with a single space; Return commits the pending word then starts a new paragraph. The block's insertion point is shown with a caret/highlight on the canvas, which follows the block.
- **Delete:** with letters in the buffer, removes the last letter; else removes the last word appended in this session (or a queued unrecognized word). One undo step per appended word.
- Nothing recognized → beep, word dropped, panel briefly shows "Couldn't read that". The panel shows the last few typed words as context.

Tasks
1. [x] `.scribe` mode + scribe buffer + panel rendering (no model ink).
2. [x] Word commit / recognition queue / append to the text block / Delete / Return / undo.
3. [x] Tests for the pure parts (word buffer, text appending & last-word removal); `swift test` + app build.
4. [x] Manual test by the user: enter Scribe, write "hello world", see the text appear.

### Phase 9c — Scribe: inferred spacing, punctuation, autocorrect; better placement
User feedback (2026-10-02): recognition works, but new text landed in the note's top-left corner under the floating toolbar. The user wants to focus on letters: no need to press space; spacing, punctuation, capitalization and spelling inferred.

Design:
- **Phrases, not words.** Letters accumulate into one run with no explicit spaces needed. A phrase commits on a ~2 s pause (constant near `scribeWordDelay`), Return, or Tab. Tab/→ still also work as an explicit space (the separator is then kept).
- **Polish pass** after recognition: protocol `TextPolisher` (CanvasKit, like `NoteNamer`) — Foundation Models implementation (macOS 26+) with strict instructions: insert spaces, punctuation and capitalization, fix obvious misspellings, never add/remove/reorder words, keep punctuation the user wrote. Context: the last ~200 characters of the target block, so sentence boundaries/capitalization are right.
- **Guard (pure, tested):** accept the polished text only if its letters (lowercased, no spaces/punctuation) are within a small edit distance of the raw letters (≈ max(2, 20%)); otherwise fall back.
- **Fallback** (model unavailable or rejected): raw text, per-word `NSSpellChecker` correction for misspelled words; capitalize after sentence ends / at block start.
- **Joining:** appended text gets a space separator unless it starts with punctuation; the polisher decides internal spacing.
- **Placement:** a new block avoids the floating toolbar and the writing panel: it's placed in the visible area minus the chrome (top inset clears the toolbar/find bar, bottom clears the panel), left inset ~48 pt; below the lowest content visible in that region if there is any, else near the top of the free region. The viewport keeps the caret within that free region.
- Delete removes the last appended phrase.

Tasks
1. [x] Phrase commit + `TextPolisher` (FM + spell-check fallback) + guard + tests.
2. [x] Placement clear of toolbar/panel; viewport follow respects it.
3. [x] Manual test by the user.

### Phase 9d — Scribe: word-level Delete, system autocorrect
User feedback (2026-10-02): Delete removes a whole recognized phrase; it should remove one word. Wants stronger autocorrect "like iOS". iOS's keyboard autocorrect isn't public API on macOS; the closest is the system text checker (`NSSpellChecker.checkString` with correction + spelling + grammar, the engine behind macOS's automatic correction; macOS 27 adds `NSTextCheckingWaitForAllGrammarCheckingResultsKey`).

- **Delete:** with an empty buffer and nothing queued, removes the last word of the target block (plus its attached punctuation and the whitespace before it; a trailing newline counts as one deletion). One undo step per Delete. A phrase still being recognized/polished is cancelled whole (it isn't visible yet).
- **Autocorrect pass** after the polish/guard (and in the fallback instead of per-word `correction(forWordRange:)`): run the system checker on context + new piece; apply `.correction` results and grammar results with exactly one suggested replacement, only inside the new piece's range; spelling results without a correction get the checker's `correction(forWordRange:)` if any. Pure range-application logic is unit-tested with fake results.

Tasks
1. [x] Word-level Delete + tests.
2. [x] System autocorrect pass + tests.
3. [x] Manual test by the user.

## Phase 10 — Geometric neatening (no ML)

Per word (from Phase 9 groups, or writing-box words): straighten onto the baseline, correct slant, normalize x-height to `L`, even out spacing. Strokes are geometrically transformed; style is preserved. Undoable, with a "Neaten" command plus an optional automatic mode.

## Later / maybe
- Generative style-preserving refine (DeepWriting/DiffInk-style); research-level.
- Pencil-scratch audio feedback modulated by speed.
- Private `MTActuator` haptics; blocked by the no-private-API rule unless you lift it.

## Decisions log
- 2026-10-02: Recognition is PencilKit only; no Vision (your call: compute cost).
- 2026-10-02: Order is writing box → recognition → geometric neatening (reconfirmed by the user after the first test: recognition next).
- 2026-10-02: Write mode becomes one-letter-at-a-time (the user's choice) instead of a word-sized box.
- 2026-10-02: Verified `PKStrokeRecognizer` reads trackpad handwriting once scaled to paper size ("hello MAC", ~1.2 s).
- 2026-10-02: Phase 8 implemented: Write mode (`pencil.line` icon) next to Tablet in the pill; `WritingLayout.swift` + `WritingPanelView.swift`. Deviations: →/Tab also wrap at the right limit; right limit leaves room for at least 2 boxes; the area under the panel counts as hidden when following the box. 413 tests pass; app builds. Awaiting the user's manual test (task 10).
- 2026-10-02: Write-mode polish after the user's testing: pen width is measured in panel points (ink shrinks with the letter); guide lines replaced by one dotted middle line; Delete with a selection deletes the selection (fixed stale selection outlines generally); haptics are now a tick on finger contact and on each crossing of the cell's middle line (4% dead band) — the letter-commit tick was dropped.
- 2026-10-02: Experimental friction haptics (Debug menu, default Off): a click every N of finger travel while drawing in Tablet/Write mode; spacing 1–6 mm; capped at 50 clicks/s.
- 2026-10-02: Phase 9 implemented: PencilKit-only recognition. Search is an in-note Find bar (no library search exists); lines are found geometrically; the cache lives in the note file (`NoteDocument.handwriting`), so closed notes get handwriting-based names and reopening doesn't re-recognize; recognized lines join typed text in reading order for first-line and semantic names. Awaiting the user's manual test (task 10).
- 2026-10-02: Phases 9b–9d (Scribe mode, inferred spacing/punctuation via Foundation Models + system autocorrect, word-level Delete) tested by the user: works.
