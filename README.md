# Scratchpad

**A native macOS notes app that turns a Mac trackpad into a handwriting surface.**

Scratchpad combines typed notes, freehand ink, and equations in a small window you can summon while working in another app. It explores a simple question: can the trackpad already built into a Mac be useful for writing, without a separate drawing tablet?

This is an actively developed prototype. The core app is written in Swift with SwiftUI and AppKit; its editing engine lives in a separate, testable Swift package called `CanvasKit`.

## What it does

- **Draw with the trackpad:** use relative cursor movement or map the trackpad directly to the visible canvas. A configurable pen key controls when movement leaves ink.
- **Mix text and sketches:** write in a flowing document with text that wraps around drawing zones, or arrange independent objects on an infinite canvas.
- **Use a dedicated writing panel:** Write mode maps the trackpad to a letter-sized cell; Scribe mode converts handwriting into typed text when the system recognizer is available.
- **Work with equations:** experimental math recognition combines a bundled Core ML glyph model with segmentation and decoding; MathLive provides an embedded equation editor.
- **Keep notes as files:** notes autosave locally as `.scratch` packages, with layout, text, strokes, and recognition caches. The app includes a note library and search.
- **Call up a note quickly:** a menu bar icon and configurable global shortcut show or hide the note window, including over full-screen apps.

## Run locally

### Requirements

- A Mac and Xcode with the **macOS 27 SDK**. The project deploys to macOS 14+, but its source references newer PencilKit APIs, so an older SDK may not compile it.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- A compatible multitouch trackpad for the absolute-position drawing modes.

From the repository root:

```sh
# Generate the Xcode project and build the app.
xcodegen generate
xcodebuild -project Scratchpad.xcodeproj \
  -scheme Scratchpad -derivedDataPath build build

# Launch the local Debug build.
open build/Build/Products/Debug/Scratchpad.app
```

Alternatively, run `scripts/run.sh` to generate, build, and launch in one step. That script closes any running Scratchpad process before relaunching. To work in Xcode, open `Scratchpad.xcodeproj` after generation and select the Scratchpad scheme.

### First use

1. Create a note and type, or choose the Pen tool to draw.
2. Configure the pen key and input mode in Settings. Hold the pen key while moving a finger to draw; toggle activation is also available.
3. Try Write mode for a focused writing area. Press Escape to leave a tablet input mode.
4. Use the menu bar icon to put the note away and bring it back.

| Action | Shortcut |
| --- | --- |
| New note | `⌘N` |
| Find in the current note | `⌘F` |
| Next / previous match | `⌘G` / `⇧⌘G` |
| Undo / redo | `⌘Z` / `⇧⌘Z` |
| Canvas zoom in / out | `⌘+` / `⌘−` |
| Canvas actual size / fit contents | `⌘0` / `⌘9` |

## How it is built

```text
Trackpad / mouse / keyboard
           ↓
Input sources → coordinate mapping → stroke processing
                                         ↓
                            Canvas / document editor
                                         ↓
                              Model → .scratch package
```

| Area | Responsibility | Start here |
| --- | --- | --- |
| App shell | Windows, commands, note lifecycle, and global summon shortcut | [`Sources/Scratchpad/`](Sources/Scratchpad/) |
| Input | Relative and absolute trackpad input, pen state, and coordinate mapping | [`InputModes.swift`](Sources/CanvasKit/InputModes.swift), [`TabletInputSource.swift`](Sources/CanvasKit/TabletInputSource.swift) |
| Editing | Ink rendering, selection, rich text, drawing zones, and document layout | [`CanvasView.swift`](Sources/CanvasKit/CanvasView.swift), [`DocumentLayout.swift`](Sources/CanvasKit/DocumentLayout.swift) |
| Data | Note model, file packages, and autosave | [`Model.swift`](Sources/CanvasKit/Model.swift), [`Persistence.swift`](Sources/CanvasKit/Persistence.swift) |
| Recognition | Handwriting recognition, math glyph classification, and equation decoding | [`HandwritingRecognizer.swift`](Sources/CanvasKit/HandwritingRecognizer.swift), [`MathGlyphClassifier.swift`](Sources/CanvasKit/MathGlyphClassifier.swift), [`MathLineDecoder.swift`](Sources/CanvasKit/MathLineDecoder.swift) |
| Validation | Unit, integration, fixture, and performance tests | [`Tests/CanvasKitTests/`](Tests/CanvasKitTests/) |

For a technical review, the input layer shows how physical touch coordinates become ink; document layout shows how drawings interact with flowing text; persistence shows how edits become saved notes. The math pipeline and its fixtures provide a deeper example of recognition and decoding across Swift and Python tooling.

## Tests

Run the CanvasKit test suite independently of the app:

```sh
swift test
```

Tests cover input modes, coordinate mapping, strokes, selection, text and document layout, persistence, recognition, and equation editing. Some integration tests depend on system recognition APIs or a graphical macOS session.

Latest local validation: the app build succeeds. `swift test` runs 868 tests with 3 skipped and 1 failure: `DocumentLayoutTests.testTopInsetClearsTopBandWithFormattingBarClosed` expects a 38-point top inset but receives 28 points. This layout expectation remains unresolved.

Optional Python tooling for training and validating math models lives in [`scripts/glyphs/`](scripts/glyphs/). It is separate from the normal app build; see the [training guide](scripts/glyphs/TRAINING-v2.md) for setup and data requirements.

## Status and limitations

- Handwriting recognition and Scribe require the macOS 27 PencilKit recognizer. The implementation returns no system recognizer on older systems.
- Math recognition is experimental; ambiguous handwriting can produce incorrect results.
- This repository provides source and local build instructions. The build uses local ad hoc signing rather than a notarized distribution workflow.
- Notes are stored locally. There is no account or collaboration service.
- Files under [`docs/`](docs/) include design plans and development history; some describe proposals rather than shipped behavior.

## Third-party acknowledgments

Bundled resources include MathLive (MIT), KaTeX fonts and Relief SingleLine (SIL Open Font License), and Hershey glyph data with its accompanying notice. Their licenses and notices are retained under [`Sources/CanvasKit/Resources/`](Sources/CanvasKit/Resources/). Consult those notices before reusing bundled assets.
