# Document Mode Plan

Goal: by default, Scratchpad is a notes app where text flows top to bottom like Docs or Apple Notes. The infinite canvas is an opt-in setting. In a document, you can draw anywhere, including in the margins, between lines and on top of text, and the ink stays attached to the text it belongs to as the text is edited or rewrapped.

Execution baseline: Scribe work committed as `1583eea`; implementation branch `codex/document-mode`.

Status key: `[ ]` todo · `[~]` in progress · `[x]` done · `[?]` needs the user's decision or a manual test

---

## For the orchestrator (Sol)

- **Before wave 0:** the `phase-8-write-mode` branch has a large uncommitted diff (Scribe work). Ask the user whether to commit it as-is, then branch `document-mode` from it. Don't start on a dirty tree, because the wave 0 refactor touches the same files.
- **Agents:** Luna (high effort). Each task below says which files it **owns**. Two agents running in parallel never own the same file. `CanvasView.swift` (2,600 lines) is the hotspot, so waves 0 and 2 serialize work on it, and new document-mode behavior goes in **new files** as `CanvasView` extensions.
- **After each wave:** run `swift test`, then `scripts/run.sh` (xcodegen + Debug build + launch). Fix integration breaks before starting the next wave. Every wave leaves canvas notes behaving exactly as they do today.
- **Testing:** prefer pure-logic unit tests (like `WritingLayoutTests` and `ScribeSegmenterTests`) over UI harnesses. For anything visual or tactile, time-box it and give the user a concrete manual-test checklist (see "Manual test" at the end). Don't build screenshot or automation rigs.
- **Match house style:** short doc comments, `// MARK:` sections, value types plus pure static helpers for logic, and `CanvasModel` as the only mutator of note data with undo.

---

## Decisions (all five defaults confirmed by the user)

1. **What the toggle controls.** Default: *per-note layout, stamped at creation.* Settings gets the toggle **"Infinite canvas"** (off by default), which decides the layout of *new* notes. Each note stores its own `layout`. Existing notes have no `layout` field, so they load as `.canvas` and keep working. File ▸ "Convert to Document / Convert to Canvas" switches one note (wave 3). The reason: canvas notes with free-floating text boxes can't be shown as a single flowing document without a lossy conversion, so flipping a global switch shouldn't silently rearrange old notes.
   *Alternative:* a global switch that forces every note into one layout, converting on open. Simpler UI, but lossy.
2. **Column width.** Default: *the full window width minus a 28 pt side margin, with no maximum.* (The request says text uses the full width.) The text rewraps live as the window resizes.
3. **Zoom in documents.** Default: *off.* No pinch zoom or magnification. ⌘+ / ⌘− are disabled in documents and can later become "text zoom".
4. **Ink in empty space below the text.** Default: *it reserves its space in the text flow* (a "sketch spacer", wave 3, task J). Text above it pushes it down, and you can type below it, the way Apple Notes treats inline drawings. Ink drawn over or beside existing lines is an *annotation* attached to that text.
5. **Pen key Space in documents.** Default: while the text caret is active, Space types a space, and only Fn or Option work as the pen key. When the caret isn't active (Pen, Eraser or Pointer tool), Space works as usual. Settings shows a footnote about this.

---

## Architecture

### One model, two layouts
Don't fork the app. A document note is still a `CanvasModel` holding **strokes + exactly one `TextBlock` (the "body")**, plus an ink-anchor table. That way the following keep working with small changes: `ToolController`, eraser, selection, `model.undoManager`, autosave, find (`FindMatches`), clipboard, `HandwritingIndexer`, `NoteTitle`/semantic naming, and Scribe.

```swift
public enum NoteLayout: String, Codable { case document, canvas }

// NoteDocument (version stays 1; every new field is optional)
public var layout: NoteLayout?        // nil → .canvas (older files)
public var inkAnchors: [InkAnchor]?   // document notes only
```

`CanvasView` and `CanvasScrollView` get a `layout` at init (`CanvasRepresentable` passes it through from the session). Document-only behavior goes in new files: `CanvasView+Document.swift`, `DocumentLayout.swift`, `InkAnchoring.swift`, `InkOverlayView.swift`, `SketchSpacer.swift`.

### Coordinates and scrolling
- **World (0,0) is the top-left of the page.** In documents, `CanvasView.worldOffset` (currently a static 100,000) becomes an instance property `origin`: `0` for documents and `documentSize/2` for canvases. All world↔view conversion already goes through `worldToView`/`viewToWorld`/`viewRect(for:)`, so only those six call sites change.
- **Document view size:** width = the clip view's width. Height = `max(content bottom, scroll bottom) + one viewport height`, recomputed on scroll, text layout and ink changes. Scrolling near the bottom keeps growing the page, which is what makes it feel infinite.
- **Vertical scrolling only:** a `DocumentClipView` (an `NSClipView` subclass) pins `constrainBoundsRect` to `x = 0` and `y ≥ 0`. Horizontal elasticity is off, `allowsMagnification = false`, and the vertical scroller is visible (overlay style).
- **Under the toolbar:** the content starts below `FloatingChrome`. The text container's top inset is `DocumentLayout.topInset` (toolbar height + 12 pt) and scrolls with the content. Text can scroll under the translucent toolbar, like Safari.
- **Viewport persistence:** the existing `Viewport` stores `center.y` for documents, with magnification fixed at 1. No format change.

### Layers (back to front)
A **Layer** column entry of **CanvasView** means the content is drawn in `CanvasView.draw`. Every other entry is a separate subview.

| # | Layer | View | Hit-testing |
|---|-------|------|-------------|
| 0 | Paper (background color; ruled lines later) | `CanvasView.draw` | — |
| 1 | Under-ink (reserved for a future highlighter; empty for now) | `CanvasView.draw` | — |
| 2 | **Body text**: `TextBlockView` with a transparent background, always live | subview | only when the Text tool is active |
| 3 | **Ink**: committed strokes, live stroke and prediction, pending Write letters | `InkOverlayView` subview | never (`hitTest → nil`) |
| 4 | Chrome: selection outlines, marquee, find highlights, Scribe caret, tablet/write overlays | `InkOverlayView` (second pass) | never |

- **Shared renderer.** Extract stroke drawing (the path cache, LOD, `drawStrokes`, live and pending ink) from `CanvasView.draw` into an `InkRenderer`. Canvas mode keeps calling it from `CanvasView.draw`, so text still sits above ink there and canvas behavior is unchanged. Document mode calls it from `InkOverlayView.draw`, which puts ink above the text.
- **Invalidation.** `setNeedsDisplay(world:)` goes to the overlay in document mode. `InkOverlayView` is layer-backed and as large as the document view, like `CanvasView` today, so AppKit tiles it and draws only the visible part. Verify this with the existing `PerformanceTests` and a 2,000-stroke document.
- **The move preview** (the `CALayer` used while dragging a selection) attaches to the overlay's layer in document mode.

### Input routing
`CanvasView.hitTest` in document mode:
- **Text tool:** fall through to the body's text view. Clicks place the caret and drags select text natively. A click below the last line puts the caret at the end.
- **Pen, Eraser or Pointer tool:** return `self` everywhere, including over text, so ink can go on top of words. The eraser removes **ink only, never text**. The pointer selects and moves **ink only**; text is selected with the Text tool.
- **Pen key while typing.** The body text view is first responder, so `CanvasView.keyDown`/`flagsChanged` never see the pen key. Add a local `NSEvent` monitor in document mode, active only while the window is key. It feeds `PenKeyMonitor` on Fn/Option `flagsChanged`, and on Space only when the caret is inactive (decision 5). Pointer motion while the pen is down comes from that monitor's `.mouseMoved`/`.leftMouseDragged`, because the text view otherwise receives those events.
- **Default tool:** Text in documents and Pen in canvases. This is the selected tool when a note opens. The persisted `settings.tool` still wins after the user changes tool within a note.

### Body text
- **One body `TextBlockView`**, created at load, always in editing state. It never goes through `EditSession`'s draft/commit cycle. Its width is `DocumentLayout.columnWidth(viewportWidth:)` and its origin is `(margin, topInset)`. It resizes on `tile()`/window resize, with the resize handle hidden.
- **Shared undo:** the body's text view uses `model.undoManager`, through the `NSTextViewDelegate` method `undoManager(for:)`, so typing and ink undo in one chronological stack. Model syncs from the text view use `updateTextBlock(_:actionName: nil)`, which records no undo, so steps don't double up.
- **Model sync:** archiving the body on every keystroke is too expensive. Debounce a sync to `model` 0.4 s after the last edit, and also sync before `flush()`, find, title naming, handwriting indexing, copy and conversion. Call `autosaver.markDirty()` on every edit.
- **Formatting bar:** `settings.isEditingText` is true whenever the body is first responder, so `FormattingBar` and the Format menu work unchanged.
- **Caret visibility:** after typing, scroll so the caret line stays visible and not hidden under the toolbar (`scrollRangeToVisible` with the top inset subtracted).

### Ink anchoring (the core problem)
Ink must move with the text it belongs to when you type above it, delete lines or resize the window. Strokes keep **absolute world coordinates in the model**, so the eraser, selection, find, the handwriting index, clipboard and every other consumer keep working without changes. A separate anchor table records what each group of strokes is attached to. After any text layout change, a **reflow** pass moves strokes by the change in their anchor's position.

```swift
public struct InkAnchor: Codable, Hashable {
    public var id: UUID
    public var strokeIDs: Set<UUID>   // a group moves as a unit
    public var kind: Kind             // .glyph | .line | .sketch
    public var charIndex: Int         // anchor character in the body
    public var offset: CGVector       // group bounds origin − anchor rect origin, at anchoring time
    public enum Kind: String, Codable { case glyph, line, sketch }
}
```

- **Grouping:** a new stroke joins the group of any existing stroke whose bounds lie within 8 pt and that was drawn in the last 3 s, or that it overlaps. Otherwise it starts a new group. If one stroke bridges two groups, they merge and keep the topmost anchor. This keeps a drawing that spans several lines from tearing apart when text is inserted in its middle.
- **Choosing the anchor** (re-anchoring), based on the group's bounds:
  - **`.glyph`:** the group overlaps laid-out glyphs, as when circling, underlining or striking a word. Anchor to the first character the group overlaps. The offset is measured from that character's glyph rect, so the annotation follows the word when it rewraps.
  - **`.line`:** the group sits beside text, in the margin or to the right of a short line. Anchor to the first character of the line fragment whose vertical span contains the group's top (or the nearest fragment above). The offset is measured from that fragment's rect, so the ink follows the line vertically and keeps its x.
  - **`.sketch`:** the group starts below the last line fragment. See the sketch spacer in task J.
- **When to re-anchor** (the anchor follows the ink): after a stroke is added, after a move or nudge, after a paste or duplicate, after a partial erase, and after undo or redo of any of these. In each case the user placed the ink deliberately, so the ink's position is the source of truth.
- **When to reflow** (the ink follows the anchor): after the text storage changes, after a width change, and after undo or redo of typing. In each case the text is the source of truth.
- **Keeping indices current:** the text storage delegate `didProcessEditing(editedRange:changeInLength:)` shifts every `charIndex` at or after the edit by `delta`. An anchor whose character was deleted moves to the start of the edit and keeps its *old on-screen position* until the next reflow. Its ink therefore doesn't jump; it rejoins the text at that point.
- **Moving strokes:** add `CanvasModel.translateStrokes(_ moves: [UUID: CGVector])`, which records **no undo**. Undo of the text edit triggers its own reflow, so the ink moves back. Coalesce the moves into one `onChange` dirty rect per reflow.
- **Horizontal overflow:** when the window narrows, `.line` ink keeps its x and can extend past the right edge. It is clipped, with no horizontal scrolling. This is a known limitation to revisit after the manual test.
- **Persistence:** `NoteDocument.inkAnchors` is saved with the note. On load, run one reflow, because the window width may differ from when the note was saved.

### Scribe, Write, and Absolute in documents
- **Scribe:** the target is always the body, and recognized text goes in **at the caret**. If the caret isn't active, it goes at the end. The provisional (live) text is inserted into the body at the caret, replacing today's provisional text blocks. `makeScribeBlock`, `scribeFreeRect` and `scribeTarget` get document-mode branches.
- **Write mode:** the ink letter cell starts on the caret's line if it's visible, otherwise at the top-left of the visible text column. The letters it writes are ordinary strokes, so they are anchored like any other ink.
- **Absolute (tablet) mode:** maps onto the visible rect as it does today. Two-finger navigation scrolls vertically only.

---

## Tasks

### Wave 0: groundwork with no behavior change (1 agent, serial)
**Owns:** `Model.swift`, `Persistence.swift`, `CanvasView.swift`, `CanvasScrollView.swift`, new `InkRenderer.swift`, and the matching tests.

0. [x] **Orchestrator:** confirm the decisions above with the user, then commit or branch as described in the orchestrator notes.
1. [x] `NoteLayout`. Optional `NoteDocument.layout` and `inkAnchors` fields that round-trip; older files decode as `.canvas`. `CanvasSettings.defaultLayout` (default `.document`) is persisted in `SettingsPersistence` as `settings.defaultLayout`. Tests in `PersistenceTests`.
2. [x] `CanvasView`/`CanvasScrollView` take `layout:` at init (default `.canvas` for now). Static `worldOffset` becomes the instance `origin`. Nothing else changes.
3. [x] Extract `InkRenderer` (path cache, LOD, stroke, live-stroke and pending-letter drawing) from `CanvasView.draw`. Canvas mode calls it with identical output.
4. [x] Change to `internal` the `CanvasView` members that the new `CanvasView+Document.swift` and `CanvasView+Anchoring.swift` files will need (session, textViews, gesture, penKeyMonitor, the scribe helpers, `setNeedsDisplay(world:)`). List them in the PR description.
5. [x] `CanvasModel.translateStrokes(_:)`, which records no undo. Tests.

**Done when:** `swift test` passes, the app looks and behaves identically, and `PerformanceTests` shows no regression.

### Wave 1: independent pieces (3 agents in parallel)
**Agent A owns** `InkAnchoring.swift` and `InkAnchoringTests.swift`. It is pure logic with no AppKit views.
6. [x] A `TextLayoutQuerying` protocol: glyph rect for a character, line fragment containing a y value, last line bottom, column rect, and the characters overlapped by a rect. Tests use a fake grid layout that implements it.
7. [x] Grouping (merge, split, bridge), anchor choice (`.glyph`, `.line`, `.sketch` boundary), index shifting for inserts, deletes and replaces (including a deleted anchor character), and reflow, which returns `[strokeID: delta]`. Table-driven tests cover typing above, deleting the anchored word, a rewrap that moves a word to the next line, and merging two groups.

**Agent B owns** `DocumentLayout.swift`, `DocumentClipView.swift`, and a new `DocumentScrollBehavior` section in a **new file** `CanvasScrollView+Document.swift`.
8. [x] `DocumentLayout`: margins, `topInset`, `columnWidth(viewportWidth:)`, and the document height rule. Pure, with tests.
9. [x] Vertical-only scrolling: pin x, clamp y ≥ 0, no magnification, grow the page near the bottom, top inset under the toolbar, persist the viewport as `center.y`. Zoom commands are no-ops in documents.

**Agent C owns** `SettingsView.swift`, `AppState.swift`, `ContentView.swift` and `ScratchpadApp.swift`.
10. [x] Settings: an **"Infinite canvas"** toggle (off), on when `defaultLayout == .canvas`, in a "Notes" section shown always, not only when `namer != nil`. Footer: "Off: notes are documents where text flows top to bottom and you can draw anywhere. On: new notes are an infinite canvas." Add the pen-key footnote from decision 5.
11. [x] `AppState.createNote` stamps `layout` from the setting. `NoteSession` exposes `layout`. `CanvasRepresentable` passes it through.
12. [x] Chrome in documents: the toolbar defaults to the Text tool, and Bring to Front, Send to Back, Zoom to Fit, Actual Size and Zoom In/Out are hidden or disabled in documents (menu validation).

**Done when:** all tests pass. New notes open in a vertical-only scrolling page, with the text not working yet. Canvas notes are unchanged.

### Wave 2: document view (serial: D, then E, then F)
**D owns** `CanvasView+Document.swift`, `TextBlockView.swift`, and the document branches in `CanvasView.swift`.
13. [x] The live body `TextBlockView`: created at load (making an empty body if none exists), width tracks the column, transparent, always editable, resize handle hidden.
14. [x] Shared undo through `undoManager(for:)`. Debounced model sync plus forced syncs. `markDirty` on every edit.
15. [x] Routing in `hitTest` by tool. A click below the end puts the caret at the end. Caret scroll-into-view respects the top inset. `isEditingText` drives the formatting bar.
16. [x] Pen-key local monitor (decision 5) plus pointer motion while the pen is down.

**E owns** `InkOverlayView.swift` and the overlay wiring in `CanvasView.swift`.
17. [x] `InkOverlayView` above the body: ink and chrome passes through `InkRenderer`, with `setNeedsDisplay(world:)`, the move preview, and the tablet and write overlays redirected to it in document mode. `CanvasView.draw` paints only the paper in documents.

**F owns** `CanvasView+Anchoring.swift` and the `CanvasModel` hooks.
18. [x] Connect `InkAnchoring` to the real text: a `TextLayoutQuerying` adapter over the body's `NSLayoutManager`, re-anchor and reflow triggers as listed in the anchoring design, persist `inkAnchors` through the autosaver, and reflow once on load.

**Done when:** you can type formatted text (headings, lists, bold, links) top to bottom, draw over and around it, type above the drawings and watch them move down, resize the window and see annotations follow their words, undo typing and ink in order, and quit and reopen with everything in place.

### Wave 3: features in documents (3 agents in parallel)
**G owns** the Scribe and Write sections of `CanvasView.swift` (no other wave-3 agent edits those MARK regions), `ScribeText.swift`, and `WritingLayout.swift`.
19. [x] Scribe inserts at the caret, provisional text goes into the body, polish and undo still work, and the preview pill is unchanged.
20. [x] Write mode places the cell on the caret line or at the top of the visible column, and the follow-scroll is vertical only.

**H owns** `FindMatches.swift`, `Clipboard.swift`, `Selection.swift`, and the find, clipboard and convert sections of `CanvasView.swift`.
21. [x] The eraser and marquee act on ink only. Find (text and handwriting) scrolls vertically to the match. Pasting canvas text blocks into a document inserts their text at the caret. Pasting ink re-anchors it. Convert to Text on selected ink inserts the recognized text at the ink's anchor character and removes the ink.

**I owns** `NoteConversion.swift` and its tests, plus the menu items in `ScratchpadApp.swift`, added after C is merged.
22. [x] Document → Canvas is lossless: the body becomes one `TextBlock` at its current origin and width, and strokes stay where they are. Canvas → Document: sort the text blocks in reading order (rows by y with a tolerance, then by x), join them with blank lines into the body, and re-anchor each stroke to the nearest block's text in the new body. Both conversions are undoable through a whole-model snapshot.

**J owns** `SketchSpacer.swift`. Run it after G and H, since it touches the body text system.
23. [x] Sketch spacer (decision 4): ink drawn below the last line becomes a `.sketch` group. Insert into the body one paragraph holding an `NSTextAttachment` whose cell is a transparent spacer as tall as the drawing plus 12 pt. The anchor is that attachment character. Text typed above pushes the sketch down; the caret can go after it to type below. Ink added to an existing sketch grows its spacer. Backspacing over the spacer deletes the sketch's ink in one undo step. The spacer archives through `NSKeyedArchiver`, which `TextBlock.content` already uses; verify the attachment round-trips.

**Done when:** all tests pass and the manual test below passes.

### Wave 4: integration (orchestrator)
24. [x] Full `swift test`, `scripts/run.sh`, a self-review pass (`/code-review high`) on the branch, an update to `docs/features.md`, then a handoff to the user for the manual test.

---

Automated integration: 593 tests pass; Debug app built and launched; review findings fixed.

## Manual test (for the user, about 10 minutes)

Status: `[?]` visual and tactile checks await the user.
1. New note: the caret is under the toolbar. Type a heading, two paragraphs and a bulleted list. You should be able to scroll vertically only, never horizontally, and pinching should do nothing.
2. With the Pen tool, circle a word in paragraph 2, draw a star in the right margin next to paragraph 1, and scribble across the list.
3. With the Text tool, add three lines at the very top. Everything you drew should move down with its text.
4. Make the window narrow, then wide again. The circle should follow its word as the word rewraps.
5. Draw a box in the empty space below the text, put the caret after it, and type. The text should appear below the box. Then add a line above everything; the box should move down.
6. Press ⌘Z repeatedly. Typing and ink should undo in the order you did them.
7. Write a word in Scribe mode. It should appear at the caret. Use the eraser on top of the text: it should remove only ink.
8. Quit and reopen. Everything should be where you left it. Turn on Settings ▸ "Infinite canvas" and create a note: it should be the old canvas. Old notes should open unchanged.

Tuning knobs to report back on: the grouping distance and time (8 pt / 3 s), the side margin (28 pt), the spacer padding (12 pt), and whether `.line` ink should keep its x or scale with the width.
