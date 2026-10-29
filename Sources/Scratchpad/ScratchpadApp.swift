import AppKit
import SwiftUI
import CanvasKit

@main
struct ScratchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    private var canvasHandle: CanvasHandle { appState.canvasHandle }
    private var findCanvas: CanvasView? { canvasHandle.scrollView?.canvasView }

    var body: some Scene {
        Window("Scratchpad", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.canvasHandle)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: NoteWindow.side, height: NoteWindow.contentHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Scratchpad") {
                    let credits = """
                    Math glyph training data: HWRT by Martin Thoma, with approximately 90% of its data provided by Daniel Kirsch via detexify-data; HASYv2 by Martin Thoma. Both datasets are used under the Open Data Commons Open Database License (ODbL) 1.0.
                    HWRT: https://doi.org/10.5281/zenodo.50022
                    HASYv2: https://doi.org/10.5281/zenodo.259444
                    ODbL 1.0: https://opendatacommons.org/licenses/odbl/1-0/

                    Clean glyphs and synthetic stroke variants use Hershey fonts, originally created by Dr. A. V. Hershey at the U.S. National Bureau of Standards; the font-data format was created by James Hurt. See the bundled HERSHEY-NOTICE.txt for the complete acknowledgement.
                    Synthetic strokes also use Relief SingleLine by The Relief SingleLine Project Authors, under the SIL Open Font License 1.1; the license is bundled with the source notice.
                    """
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: credits)
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Note") { appState.createNote(in: nil) }
                    .keyboardShortcut("n", modifiers: .command)
                RecentNotesMenu(appState: appState, library: appState.library)
                Divider()
                if appState.namer != nil {
                    Button("Suggest Name") {
                        if let url = appState.session?.url { appState.suggestName(for: url) }
                    }
                    Toggle("Rename Notes Automatically", isOn: $appState.renameAutomatically)
                }
                Divider()
                Button("Show in Finder") {
                    if let url = appState.session?.url { appState.showInFinder(url) }
                }
                Button("Show All Notes in Finder") { appState.showLibraryInFinder() }
                Button("Move Note to Trash") {
                    if let url = appState.session?.url { appState.trash(url) }
                }
                Divider()
                if appState.session?.layout == .document {
                    Button("Convert to Canvas") { appState.convertCurrentNote(to: .canvas) }
                        .disabled(appState.session == nil)
                } else {
                    Button("Convert to Document") { appState.convertCurrentNote(to: .document) }
                        .disabled(appState.session == nil)
                }
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Button("Zoom In") {
                    canvasHandle.scrollView?.zoomIn()
                }
                .disabled(appState.session?.layout == .document)
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    canvasHandle.scrollView?.zoomOut()
                }
                .disabled(appState.session?.layout == .document)
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    canvasHandle.scrollView?.zoomToActualSize()
                }
                .disabled(appState.session?.layout == .document)
                .keyboardShortcut("0", modifiers: .command)

                Button("Zoom to Fit") {
                    canvasHandle.scrollView?.zoomToFit()
                }
                .disabled(appState.session?.layout == .document)
                .keyboardShortcut("9", modifiers: .command)
            }

            CommandMenu("Tool") {
                Button("Select (1)") {
                    canvasHandle.settings.selectTool(.pointer)
                }

                Button("Pen (2)") {
                    canvasHandle.settings.selectTool(.pen)
                }

                Button("Eraser (3)") {
                    canvasHandle.settings.selectTool(.eraser)
                }

                Button("Writing Mode (4)") {
                    canvasHandle.settings.toggleWritingMode()
                }

                Divider()

                MathInputToggle(settings: canvasHandle.settings)
                ExitTabletModeButton(settings: canvasHandle.settings)
            }

            CommandGroup(after: .pasteboard) {
                FormatButton("Duplicate", #selector(CanvasView.duplicate(_:)), key: "d")
                ConvertToTextButton(settings: canvasHandle.settings)
                Divider()
                Menu("Find") {
                    Button("Find…") { findCanvas?.showFind() }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { findCanvas?.findNext() }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { findCanvas?.findPrevious() }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }

            #if DEBUG
            CommandMenu("Debug") {
                Button("Capture Glyph Samples") { findCanvas?.startGlyphCapture() }
                Button("Save Glyph Sample") { findCanvas?.saveGlyphCaptureSample() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Redo Last Glyph Sample") { findCanvas?.redoLastGlyphCaptureSample() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                Button("Cancel Glyph Capture") { findCanvas?.stopGlyphCapture() }
                Divider()
                Button("Recognize Handwriting") {
                    if let canvas = canvasHandle.scrollView?.documentView as? CanvasView, !canvas.isCapturingGlyphs {
                        DebugRecognition.run(on: canvas)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                HapticPicker(title: "Stroke Start Haptic", settings: canvasHandle.settings, pattern: \.touchHaptic)
                HapticPicker(title: "Friction Haptic", settings: canvasHandle.settings, pattern: \.frictionHaptic)
                FrictionSpacingPicker(settings: canvasHandle.settings)
                Divider()
                LetterDelayPicker(settings: canvasHandle.settings)
            }
            #endif

            CommandMenu("Arrange") {
                FormatButton("Bring to Front", #selector(CanvasView.bringToFront(_:)), key: "]", modifiers: [.command, .shift])
                FormatButton("Send to Back", #selector(CanvasView.sendToBack(_:)), key: "[", modifiers: [.command, .shift])
            }

            // Every item sends a standard AppKit text action (or one of ours from
            // TextFormatting) to the first responder, i.e. the editing text view.
            CommandMenu("Format") {
                Menu("Font") {
                    Button("Show Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }
                        .keyboardShortcut("t", modifiers: .command)
                    Divider()
                    FormatButton("Bold", TextFormatting.boldSelector, key: "b")
                    FormatButton("Italic", TextFormatting.italicSelector, key: "i")
                    FormatButton("Underline", #selector(NSText.underline(_:)), key: "u")
                    Divider()
                    FormatButton("Bigger", TextFormatting.biggerSelector)
                    FormatButton("Smaller", TextFormatting.smallerSelector)
                    Divider()
                    Button("Show Colors") {
                        // Clear any target the stroke color button set, so the panel
                        // colors the selected text via the responder chain.
                        NSColorPanel.shared.setTarget(nil)
                        NSColorPanel.shared.setAction(nil)
                        NSApp.orderFrontColorPanel(nil)
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                Menu("Text") {
                    FormatButton("Align Left", #selector(NSText.alignLeft(_:)), key: "{")
                    FormatButton("Center", #selector(NSText.alignCenter(_:)), key: "|")
                    FormatButton("Justify", #selector(NSTextView.alignJustified(_:)))
                    FormatButton("Align Right", #selector(NSText.alignRight(_:)), key: "}")
                }
                FormatButton("Lists…", #selector(NSTextView.orderFrontListPanel(_:)))

                Divider()

                FormatButton("H1", TextFormatting.heading1Selector, key: "1", modifiers: [.command, .option])
                FormatButton("H2", TextFormatting.heading2Selector, key: "2", modifiers: [.command, .option])
                FormatButton("H3", TextFormatting.heading3Selector, key: "3", modifiers: [.command, .option])
                FormatButton("Body", TextFormatting.bodySelector, key: "0", modifiers: [.command, .option])

                Divider()

                FormatButton("Add Link…", TextFormatting.addLinkSelector, key: "k")
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.show(appState: appState) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// File > Open Recent. Observes the library itself so the list stays current.
private struct RecentNotesMenu: View {
    let appState: AppState
    @ObservedObject var library: NoteLibrary

    var body: some View {
        Menu("Open Recent") {
            ForEach(library.recents, id: \.self) { url in
                Button(AppState.noteName(url)) { appState.open(url) }
                    .disabled(appState.session.map { AppState.samePath($0.url, url) } ?? false)
            }
        }
        .disabled(library.recents.isEmpty)
    }
}

/// Menu item that sends `action` to the first responder.
private struct FormatButton: View {
    let title: String
    let action: Selector
    let key: KeyEquivalent?
    let modifiers: EventModifiers

    init(_ title: String, _ action: Selector, key: KeyEquivalent? = nil, modifiers: EventModifiers = .command) {
        self.title = title; self.action = action; self.key = key; self.modifiers = modifiers
    }

    var body: some View {
        if let key {
            button.keyboardShortcut(key, modifiers: modifiers)
        } else {
            button
        }
    }

    private var button: some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
    }
}

/// Observes settings itself: `CanvasHandle` doesn't republish settings changes,
/// so a plain button in `.commands` would keep a stale disabled state. Disabled
/// outside Tablet and Write modes so Esc reaches the canvas (which lifts the pen).
#if DEBUG
/// Debug: pick one of the three public trackpad haptic patterns, or Off; plays it on selection.
private struct HapticPicker: View {
    let title: String
    @ObservedObject var settings: CanvasSettings
    let pattern: ReferenceWritableKeyPath<CanvasSettings, NSHapticFeedbackManager.FeedbackPattern?>

    private static let off = -1
    private static let options: [(String, NSHapticFeedbackManager.FeedbackPattern)] =
        [("Alignment (light)", .alignment), ("Generic", .generic), ("Level Change", .levelChange)]

    var body: some View {
        Picker(title, selection: Binding(
            get: { settings[keyPath: pattern]?.rawValue ?? Self.off },
            set: { raw in
                let p = NSHapticFeedbackManager.FeedbackPattern(rawValue: raw)
                settings[keyPath: pattern] = raw == Self.off ? nil : p
                if raw != Self.off, let p { NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now) }
            })) {
            Text("Off").tag(Self.off)
            ForEach(Self.options, id: \.1.rawValue) { Text($0.0).tag($0.1.rawValue) }
        }
    }
}
#endif

#if DEBUG
/// Debug: distance between friction clicks, as a fraction of the trackpad width (~16 cm).
private struct FrictionSpacingPicker: View {
    @ObservedObject var settings: CanvasSettings

    private static let options: [(String, Double)] =
        [("Very Fine (~1 mm)", 0.006), ("Fine (~2 mm)", 0.012), ("Medium (~3 mm)", 0.02), ("Coarse (~6 mm)", 0.04)]

    var body: some View {
        Picker("Friction Spacing", selection: $settings.frictionSpacing) {
            ForEach(Self.options, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
}
#endif

#if DEBUG
/// Debug: Write and Scribe idle time after pen-up before the letter commits.
private struct LetterDelayPicker: View {
    @ObservedObject var settings: CanvasSettings

    private static let options: [TimeInterval] = [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75]

    var body: some View {
        Picker("Letter Commit Delay", selection: $settings.letterCommitDelay) {
            ForEach(Self.options, id: \.self) { Text("\(Int($0 * 1000)) ms").tag($0) }
        }
        Picker("Scribe Letter Commit Delay", selection: $settings.scribeLetterCommitDelay) {
            ForEach(Self.options, id: \.self) { Text("\(Int($0 * 1000)) ms").tag($0) }
        }
    }
}
#endif

/// Scribe's math input (ink, not text). Observes settings so the check and disabled state follow.
private struct MathInputToggle: View {
    @ObservedObject var settings: CanvasSettings

    var body: some View {
        Toggle("Math Input", isOn: $settings.scribeMath)
            .keyboardShortcut("m", modifiers: .control)
            .disabled(!settings.offersScribeZones)
    }
}

/// Observes settings itself so the disabled state follows the selection.
private struct ConvertToTextButton: View {
    @ObservedObject var settings: CanvasSettings

    var body: some View {
        Button("Convert to Text") { NSApp.sendAction(#selector(CanvasView.convertToText(_:)), to: nil, from: nil) }
            .keyboardShortcut("t", modifiers: [.command, .control])
            .disabled(!settings.canConvertToText)
    }
}

private struct ExitTabletModeButton: View {
    @ObservedObject var settings: CanvasSettings

    var body: some View {
        Button(settings.inputMode.usesLetterCell ? "Exit Write Mode" : "Exit Mode") {
            settings.inputMode = .pen
            settings.tool = .pointer
        }
        .keyboardShortcut(.escape, modifiers: [])
        .disabled(!settings.inputMode.usesTabletInput)
    }
}

final class CanvasHandle: ObservableObject {
    weak var scrollView: CanvasScrollView? {
        didSet {
            if oldValue !== scrollView { oldValue?.setWritingPanelModeHint(nil) }
            scrollView?.setWritingPanelModeHint(writingPanelModeHint)
        }
    }
    var writingPanelModeHint: NSView? {
        didSet { scrollView?.setWritingPanelModeHint(writingPanelModeHint) }
    }
    let settings = CanvasSettings()
}
