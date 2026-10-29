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

## How the math model was trained

Scratchpad includes a custom **64-class math glyph classifier**, trained in PyTorch and exported to Core ML for inference on the Mac. Its job is to score possible symbols from a small group of handwritten strokes. General handwriting-to-text in Scribe uses Apple's PencilKit recognizer separately.

### Data and training

The bundled model's training metadata records data from **MathWriting, CROHME, and HWRT**, including symbols extracted from handwritten expressions, plus synthetic strokes generated from Hershey and Relief SingleLine glyphs. Synthetic examples supplement classes with limited real handwriting; sampling balances the classes during training.

Each example gives the network three views of the same ink:

| Input | What it contributes |
| --- | --- |
| A normalized **32 × 32 grayscale image** | The overall shape, processed by a small 2D convolutional network |
| A **128 × 4 pen-path sequence** | How the strokes were drawn, processed by a 1D convolutional network |
| **Stroke count and aspect ratio** | Geometry that helps distinguish similar shapes |

The image and path features are combined with the geometry inputs in a 256-unit hidden layer, then scored across 64 classes, including a `junk` class for unsupported or malformed ink. Using both shape and pen movement gives the classifier information that a static image alone loses.

Training augments the strokes with rotation, shear, stretching, elastic distortion, and point jitter. It also simulates trackpad sampling, smoothing, and tremor, and sometimes changes stroke direction or order. These variations help bridge the gap between dataset handwriting and input from a Mac trackpad.

The recorded training configuration uses **AdamW**, a learning rate of `0.001`, batches of `512`, label smoothing, and a cosine learning-rate schedule. The bundled checkpoint was selected at **epoch 13** by aggregate top-1 accuracy on CROHME and HWRT validation data. The pipeline keeps training, validation, and held-out test data separate; a small local capture tuning set is reported separately and does not select the checkpoint.

The [bundled manifest](Sources/CanvasKit/Resources/MathGlyphs-manifest.json) records **94.34% glyph-class accuracy** on that validation split and **82.09% resolved-label accuracy on 134 local tuning captures**. These measure isolated-symbol recognition, not complete equation accuracy or performance across all users. The manifest also retains the training configuration and source hashes for traceability.

### How predictions become equations

```text
Handwritten strokes
        ↓
Segment into candidate symbol groups
        ↓
Build image, pen-path, and geometry inputs
        ↓
Core ML classifier → candidate symbol probabilities
        ↓
Geometry resolver + mathematical language context
        ↓
Equation structure and editable math
```

The classifier is one part of the recognition pipeline. `MathStrokeSegmenter` groups strokes into candidate symbols. `MathGlyphClassifier` runs the bundled model and converts its scores into label likelihoods; `SymbolResolver` uses the original ink size and position to help interpret ambiguous shapes. `MathLineDecoder` combines those likelihoods with a bundled n-gram math language model and confidence thresholds, allowing nearby symbols to inform a decision. Separate layout logic handles structures such as fractions and superscripts, and MathLive provides the equation editing interface.

The exported model runs locally through Core ML, so math glyph inference requires no server request. Export checks compare Core ML outputs with PyTorch outputs to catch conversion differences. See [`train_v2.py`](scripts/glyphs/train_v2.py) for the training implementation and the [training guide](scripts/glyphs/TRAINING-v2.md) for the workflow. The guide includes earlier 59-class experiments; the bundled manifest describes the current 64-class model.

## Tests

Run the CanvasKit test suite independently of the app:

```sh
swift test
```

Tests cover input modes, coordinate mapping, strokes, selection, text and document layout, persistence, recognition, and equation editing. Some integration tests depend on system recognition APIs or a graphical macOS session.

Optional Python tooling for training and validating math models lives in [`scripts/glyphs/`](scripts/glyphs/). It is separate from the normal app build; see the [training guide](scripts/glyphs/TRAINING-v2.md) for setup and data requirements.

## Status and limitations

- Handwriting recognition and Scribe require the macOS 27 PencilKit recognizer. The implementation returns no system recognizer on older systems.
- Math recognition is experimental; ambiguous handwriting can produce incorrect results.
- This repository provides source and local build instructions. The build uses local ad hoc signing rather than a notarized distribution workflow.
- Notes are stored locally. There is no account or collaboration service.
- Files under [`docs/`](docs/) include design plans and development history; some describe proposals rather than shipped behavior.

## Third-party acknowledgments

Bundled resources include MathLive (MIT), KaTeX fonts and Relief SingleLine (SIL Open Font License), and Hershey glyph data with its accompanying notice. Their licenses and notices are retained under [`Sources/CanvasKit/Resources/`](Sources/CanvasKit/Resources/). Consult those notices before reusing bundled assets.
