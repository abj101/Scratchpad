import SwiftUI
import CanvasKit

/// Sidebar sections of the settings window.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case pen, write, text, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Trackpad Pen"
        case .write: "Write Mode"
        case .text: "Text"
        case .notes: "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .write: "hand.draw"
        case .text: "textformat"
        case .notes: "note.text"
        }
    }
}

/// App settings (Scratchpad > Settings, or ⌘,). A compact window: sections on the left, controls on the right.
struct SettingsView: View {
    @AppStorage("showToolbarShortcutLabels") private var showToolbarShortcutLabels = false
    @AppStorage("toolbarEdge") private var toolbarEdge = "left"
    @AppStorage("alwaysShowBorder") private var alwaysShowBorder = false
    @AppStorage(Summon.overFullScreenKey) private var showOverFullScreen = true
    @ObservedObject var appState: AppState
    @ObservedObject var settings: CanvasSettings
    @State private var pane: SettingsPane? = .pen

    private var scribeWidth: Binding<Double> {
        Binding(get: { settings.scribeDefaultWidth }, set: { value in
            guard value.isFinite else { return }
            settings.scribeDefaultWidth = min(max(value, CanvasSettings.widthRange.lowerBound), CanvasSettings.widthRange.upperBound)
        })
    }

    private var defaultFontSize: Binding<Double> {
        Binding(get: { settings.defaultFontSize }, set: { value in
            guard value.isFinite else { return }
            settings.defaultFontSize = CanvasSettings.canonicalFontSize(value)
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 168)

            Divider()

            Form {
                switch pane ?? .pen {
                case .pen: penSection
                case .write: writeSection
                case .text: textSection
                case .notes: notesSection
                }
            }
            .formStyle(.grouped)
            .controlSize(.small)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 640, height: 400)
    }

    private var penSection: some View {
        Section {
            Picker("Pen key", selection: $settings.penKey) {
                ForEach(PenKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("Key for drawing")
            Picker("Activation", selection: $settings.activation) {
                ForEach(PenActivation.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("Hold to draw or press to toggle")
        } footer: {
            Text("Used by Pen, Write and Scribe modes. Hold draws while the key is down; Toggle flips the pen on each press.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var writeSection: some View {
        Section {
            Picker("Writing area position", selection: $settings.writingPanelPlacement) {
                ForEach(WritingPanelPlacement.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("Where the writing area appears at the bottom of the screen. Drag it to move it.")
            if InputMode.scribe.isAvailable {
                Toggle("Convert handwriting to text", isOn: $settings.handwritingToText)
                    .help("Handwriting to text")
                Toggle("Use the general writing width", isOn: $settings.unifyScribeWidth)
                    .help("Scribe keeps the current pen width instead of applying a separate default")
                LabeledContent("Default line width") {
                    HStack(spacing: 6) {
                        TextField("Default line width", value: scribeWidth, format: .number.precision(.fractionLength(1)))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .scratchpadWritingToolsAffordance(enabled: settings.writingToolsEnabled)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .accessibilityLabel("Default line width")
                        Text("pt").foregroundStyle(.secondary)
                    }
                    .help("Pen width when entering Scribe mode (0.5–100 pt)")
                }
                .disabled(settings.unifyScribeWidth)
            }
            Toggle("Auto-close brackets in math", isOn: $settings.autoCloseBrackets)
                .help("Writing an opening bracket adds the closing one; keep writing inside and press an arrow key to step out")
        } footer: {
            Text("The whole trackpad maps to one letter, sized to the default font size. With conversion on, your writing is recognized and typed into a text block instead of staying as ink.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textSection: some View {
        Section {
            LabeledContent("Default font size") {
                HStack(spacing: 6) {
                    TextField("Default font size", value: defaultFontSize, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .scratchpadWritingToolsAffordance(enabled: settings.writingToolsEnabled)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .accessibilityLabel("Default font size")
                    Text("pt").foregroundStyle(.secondary)
                }
                .help("Font size for new text and equations (8–72 pt). Existing content keeps its formatting.")
            }
            Toggle("Show text options while editing", isOn: $settings.showTextOptionsWhileEditing)
                .help("Show the text options bar automatically when you edit text")
            Toggle("Enable Writing Tools", isOn: $settings.writingToolsEnabled)
                .help("Allow macOS Writing Tools in text editors")
        }
    }

    private var notesSection: some View {
        Section {
            SummonShortcutRecorder()
            Toggle("Show over full-screen apps", isOn: $showOverFullScreen)
                .help("A summoned note appears on top of apps in full screen instead of switching Spaces")
            Toggle("Show shortcut labels under tools", isOn: $showToolbarShortcutLabels)
                .help("Show the key (1, 2, Q, W…) under each tool bar button")
            Picker("Toolbar placement", selection: $toolbarEdge) {
                Text("Left").tag("left")
                Text("Right").tag("right")
                Text("Bottom").tag("bottom")
                Text("Overlay").tag("overlay")
            }
            .help("Where the tool bar sits: on a window edge (shown on hover), or floating over the note")
            Toggle("Always show window border", isOn: $alwaysShowBorder)
                .help("Keep the glass border, tool bar strip and window buttons visible instead of showing them on hover")
            Toggle("Infinite canvas", isOn: Binding(
                get: { settings.defaultLayout == .canvas },
                set: { settings.defaultLayout = $0 ? .canvas : .document }
            ))
            .help("Use an infinite canvas for new notes")
            if appState.namer != nil {
                Toggle("Rename notes automatically", isOn: $appState.renameAutomatically)
                    .help("Automatic note titles")
            }
        } footer: {
            Text("Off: notes are documents where text flows top to bottom and you can draw anywhere. On: new notes are an infinite canvas. While typing, hold Fn or Option to temporarily draw, then release to resume typing. This uses Hold even when drawing activation is Toggle. Space types a space. Hold the same key with a shortcut key (1–4, Q, W, E, [ or ]) to switch tools and modes without typing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The settings window: a plain titled window (traffic lights and title, nothing else). Not the
/// SwiftUI `Settings` scene, whose built-in toolbar draws hover highlights across the top on macOS 26.
@MainActor enum SettingsWindow {
    private static var window: NSWindow?

    static func show(appState: AppState) {
        let window = window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: true)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            let host = NSHostingController(rootView: SettingsView(appState: appState, settings: appState.canvasHandle.settings))
            // Fixed size up front: otherwise the window opens empty and resizes as SwiftUI lays out.
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: 640, height: 400))
            window.center()
            return window
        }()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static func toggle(appState: AppState) {
        if let window, window.isVisible { window.close() }
        else { show(appState: appState) }
    }
}
