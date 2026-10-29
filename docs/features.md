# MVP Features

## Product

A lightweight native macOS visual notes app optimized for extremely fast scratch work.

Users can freely mix:
- handwriting / drawing
- typed rich text
- diagrams and sketches
- spatial notes on an infinite canvas

The key differentiator is **Trackpad Tablet Mode**, where the physical MacBook trackpad maps directly to the visible drawing region like a tiny graphics tablet.

---

# Product Principles

## 1. Trackpad-first
Drawing should feel natural without requiring click-and-drag.

## 2. Reuse first
Do **not** build generic editor infrastructure from scratch when a mature Swift package or Apple framework already exists.

Reuse existing components for:
- rich text editing
- infinite canvas pan / zoom
- drawing / stroke rendering where practical
- file persistence
- document handling
- undo / redo
- keyboard shortcuts

Custom code should be concentrated around the unique feature:

> Mapping raw Mac trackpad touch position into canvas coordinates and converting it into drawing input.

## 3. Lightweight
The app should open quickly, feel native, and avoid becoming a full productivity suite.

---

# Core Features

## 1. Documents and Infinite Canvas

New notes default to a flowing document with rich text from top to bottom. The text column follows the window width with 28 pt side margins. Documents scroll vertically, start beneath the floating toolbar, and keep zoom at 100%.

Draw over words, between lines, or in the margins. Annotations follow their words or lines when text is edited or rewrapped. Margin ink keeps its horizontal position and may be clipped in a narrow window.

Settings ▸ **Infinite canvas** chooses the layout of new notes. Each note saves its own layout; existing notes open as canvases. File ▸ **Convert to Document / Convert to Canvas** converts the open note in one undo step. Canvas-to-document conversion joins formatted text blocks in reading order with blank lines.

Canvas notes are an infinite 2D workspace.

Users can:
- pan with the trackpad
- pinch to zoom
- place content anywhere
- move between handwriting and typed notes freely
- zoom out for overview
- zoom into an area for detailed work

### Preferred implementation

Use an existing Swift package rather than implementing pan / zoom transforms manually.

Primary candidate:

- **swiftui-infinite-canvas**
  - SwiftUI
  - MIT licensed
  - provides an `InfiniteCanvas`
  - supports arbitrary SwiftUI content positioned in world coordinates

Alternative candidate:

- **SwiftUI-Infinite-Grid**
  - macOS 14+
  - already provides infinite 2D navigation using mouse / trackpad

Package choice should be validated with the trackpad input prototype before committing.

---

## 2. Handwriting and Freehand Drawing

Users can draw anywhere on a document page or infinite canvas. In documents, ink sits above text, and the Eraser and Pointer tools act on ink. Select text with the Text tool.

Features:
- pen
- eraser
- adjustable stroke width
- stroke color
- smooth handwriting
- undo / redo
- select / move strokes if supported by chosen drawing framework
- handwriting coexists with text objects

Do not build a full drawing engine from scratch.

Prefer Apple-native drawing primitives/frameworks where possible.

### Apple framework candidate

**PencilKit**
- native Apple ink representation
- stroke storage through `PKDrawing`
- built-in ink / eraser concepts
- mature rendering model

PencilKit should be evaluated for rendering/storage even if Mac trackpad input must be injected through the custom input layer.

If PencilKit's macOS capture path does not fit the trackpad architecture cleanly, keep the custom input layer small and use an existing stroke/path library rather than building a larger drawing framework.

---

## 3. Trackpad Drawing Mode

Standard mode.

- Finger movement controls the normal mouse cursor.
- A keyboard key puts the pen down.
- Mouse/trackpad movement while pen-down creates a stroke.
- No physical trackpad click is required.

### Pen activation

Support:

**Hold mode**
- Hold configured key → pen down
- Release → pen up

**Toggle mode**
- Press key → drawing enabled
- Press again → drawing disabled

Space is the default pen key. While a document text caret is active, Space types a space; use Fn or Option to draw. Space resumes its configured pen behavior when the caret is inactive.

---

# 4. Trackpad Tablet Mode — Core Differentiator

Optional mode that turns the MacBook trackpad into a miniature absolute-position drawing tablet.

```text
Physical Trackpad                 Active Canvas Region

┌─────────────────┐              ┌─────────────────┐
│        ●        │              │        ●        │
│                 │      →       │                 │
│                 │              │                 │
└─────────────────┘              └─────────────────┘
```

Instead of moving a mouse cursor relatively:

- trackpad X position maps directly to canvas X
- trackpad Y position maps directly to canvas Y
- touching another part of the trackpad jumps to that corresponding canvas position
- lifting the finger allows repositioning without drawing
- pen-down state is controlled separately by keyboard

### Mapping modes

Initial implementation should support:

**Visible Region**
- Entire physical trackpad maps to the currently visible canvas viewport.

Potential later modes:
- fixed-size drawing region
- selected region
- full page / frame

### Custom subsystem

This is intentionally one of the few features implemented directly.

Use AppKit APIs such as:
- `NSTouch`
- normalized trackpad touch position
- `NSEvent`
- keyboard state

The system converts:

```text
normalized trackpad position
        ↓
visible canvas coordinate
        ↓
drawing engine coordinate
        ↓
stroke
```

Do not tie this logic to one drawing package.

Create a small adapter so the input layer emits generic canvas points.

---

# 5. Typed Notes

In documents, ink never sits on top of text. Each drawing lives in a drawing zone (the union of its strokes plus 8 pt); strokes within 16 pt of a zone join it. Body text wraps around zones, beside them and below them, and goes fully below a zone that leaves under 96 pt of text on either side. A zone hangs from a paragraph (paragraph start plus a vertical offset), so it moves with the text above it and stays inside the column when the window narrows. Notes saved with sketch spacers or ink anchors migrate to zones when they open.

In document Text mode, the drawing modifier temporarily activates Pen while held and restores text input on release, even when drawing activation is Toggle. Pen and Eraser use the circular drawing cursor.

Documents have one live rich-text body. New documents open with the Text tool and a caret beneath the toolbar. Text and ink share one chronological undo stack, and edits autosave continuously.

Canvas notes let users place independent text blocks anywhere.

Canvas behavior:
- click / shortcut to create a text block
- type directly on the canvas
- move and resize the text block
- double-click to edit
- escape / click outside to finish editing

Typed notes should behave like objects on the same workspace as drawings.

---

# 6. Rich Text Editing

Text blocks support basic rich formatting:

- bold
- italic
- underline
- headings
- font size
- lists
- text color
- alignment
- links
- copy / paste

Do not implement the editor manually.

### Preferred package

**RichTextKit**

Provides:
- SwiftUI rich text editor
- macOS support
- `NSTextView` integration
- attributed text
- formatting commands
- fonts / sizes / colors
- alignment
- attachments
- keyboard shortcuts

Use its `RichTextEditor` inside canvas text objects.

### Native fallback

If the project targets macOS 26+ exclusively, evaluate SwiftUI's newer attributed-string editing support before taking a long-term dependency on RichTextKit.

---

# 7. Canvas Objects

Canvas notes contain independent objects. Document notes contain one flowing text body plus drawing zones that the text wraps around.

Initial object types:

### Drawing
Freehand strokes / handwriting.

### Text
Rich text blocks.

Later object types may include:
- images
- shapes
- PDFs
- sticky notes

All objects share:
- world position
- bounding box
- selectable state
- z-order
- move support

Avoid building a complex node framework during MVP.

---

# 8. Simple File System

The app should have a lightweight note browser rather than a complex workspace/database system.

Example:

```text
Notes
├── Calculus
│   ├── Limits
│   └── Homework Scratch
├── Game Ideas
│   └── Combat Notes
└── Quick Notes
```

Features:
- create note
- rename note
- delete note
- create folder
- move note into folder
- recent notes
- search by filename
- auto-save

No accounts or cloud backend required.

---

# 9. Documents and Persistence

Each note should serialize its canvas state.

Persist:
- per-note layout and viewport
- document drawing zones
- text objects
- attributed text
- handwriting / strokes
- object positions
- zoom level
- drawing settings

Prefer Apple's document APIs and file wrappers rather than designing a custom database layer.

Recommended native building blocks:
- SwiftUI document APIs / `Document`
- `FileWrapper`
- `UTType`
- Foundation file APIs
- `UndoManager`

A note can internally be represented as a document package:

```text
MyNote.note/
├── document.json
├── text/
├── drawings/
└── assets/
```

The exact internal structure is an implementation detail and should stay simple.

---

# 10. Auto Save

- Save continuously.
- No required Save button.
- Restore the last open note/window on launch.
- Protect against accidental data loss.

---

# 11. Undo / Redo

Unified:

- `⌘Z` → undo
- `⌘⇧Z` → redo

Should work across:
- drawing strokes
- deleting strokes
- moving objects
- text edits
- object creation/deletion

Use the native `UndoManager` where possible.

---

# 12. Minimal Toolbar

The canvas UI should remain extremely small.

Possible controls:

```text
[Pointer] [Pen] [Eraser] [Text]     [Color] [Width]

                   Trackpad: Tablet Mode ▼
```

The majority of actions should also have keyboard shortcuts.

---

# 13. Handwriting Recognition

Handwriting is recognized on-device with PencilKit's `PKStrokeRecognizer` (macOS 27+). There is no Vision fallback; older systems simply have no recognition.

Recognition runs in the background, line by line, a moment after the user stops writing. Results are cached in the note file, so reopening a note doesn't recognize it again.

Features:
- Find bar (⌘F) searches the open note: handwriting and typed text, with highlighted matches, next / previous (⌘G / ⇧⌘G) and Esc to close
- Convert to Text turns selected handwriting into text in one undo step: a block on canvas, or text at the start of the zone's anchor paragraph in a document
- Scribe inserts recognized text at the document caret, with a live preview that is excluded from saved contents
- Scribe letters commit after 400 ms idle (Write mode keeps 250 ms)
- Scribe math input keeps handwriting as ink (Scribe becomes Write mode until toggled back); toggle it with the trackpad's top-right corner, a lone Control tap, ⌃M (Tool ▸ Math Input) or the hint pill. The panel morphs between the two layouts and the preview pill sinks into / rises out of it
- In Scribe and math input, a tap on the trackpad's top-left corner (→) slides the cell past the letter being written, or ends the word when none is pending; both corners (20% × 30% of the pad) are drawn as buttons on the panel and never take ink
- A lone Command tap (or the hint pill's ⌘ play/pause) pauses auto-advance: letters stay in the cell until the top-left corner is tapped
- Write mode starts on the visible caret line or at the top of the visible document column
- recognized handwriting feeds automatic note names, together with typed text in reading order, so ink-only notes get names too

Ink is never modified by recognition.

---

# MVP Input Modes

## Pointer Mode
Normal mouse interaction.

Used for:
- selecting
- moving objects
- editing text
- panning

## Pen Mode
Normal relative trackpad movement draws without clicking.

## Trackpad Tablet Mode
Absolute physical trackpad position maps onto the visible canvas.

---

# Recommended Technical Stack

## App
- Swift
- SwiftUI
- AppKit where low-level macOS APIs are required

## Infinite Canvas
Preferred:
- `swiftui-infinite-canvas`

Alternative:
- `SwiftUI-Infinite-Grid`

## Rich Text
Preferred:
- `RichTextKit`

Possible macOS 26+ replacement:
- native SwiftUI attributed text editing

## Drawing / Handwriting
Preferred starting point:
- Apple PencilKit drawing/stroke model where compatible

Custom code should only bridge trackpad coordinates into the selected drawing representation.

## Trackpad Input
- AppKit
- `NSTouch`
- `NSEvent`

This is the main custom system.

## Documents
- native SwiftUI/Foundation document APIs
- `FileWrapper`
- `UTType`
- `UndoManager`

Avoid adding a database unless the document model later requires one.

---

# Architecture Boundary

```text
                 ┌───────────────────────┐
                 │   Trackpad Input      │
                 │ NSTouch / NSEvent     │
                 └──────────┬────────────┘
                            │
                      normalized point
                            │
                            ▼
                 ┌───────────────────────┐
                 │ Input Mapping Layer   │
                 │ CUSTOM / USP          │
                 └──────────┬────────────┘
                            │
                      canvas point
                            │
             ┌──────────────┴──────────────┐
             ▼                             ▼
    ┌─────────────────┐          ┌─────────────────┐
    │ Drawing Engine  │          │ Infinite Canvas │
    │ existing API    │          │ existing package│
    └─────────────────┘          └─────────────────┘

    ┌─────────────────┐          ┌─────────────────┐
    │ Rich Text       │          │ Documents       │
    │ existing package│          │ Apple APIs      │
    └─────────────────┘          └─────────────────┘
```

The project should not spend time recreating solved editor infrastructure.

---

# Explicitly Out of Scope for MVP

- cloud sync
- collaboration
- accounts
- AI features
- OCR
- real-time multiplayer
- complex databases
- mobile versions
- Notion-style databases
- complex shape/diagram editor
- plugin ecosystem

---

# MVP Success Criterion

The MVP should answer:

> **Can one lightweight native Mac app make the built-in trackpad feel like a genuinely useful handwriting surface while still providing the basic conveniences of a modern notes app?**

The unique engineering work should be the **trackpad-to-canvas experience**.

Everything else should be assembled from existing Swift packages and Apple frameworks wherever practical.
