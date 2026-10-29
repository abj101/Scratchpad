import SwiftUI
import AppKit
import Combine
import CanvasKit

private extension CanvasSettings {
    var chromeColorScheme: ColorScheme { backgroundColor.prefersLightForeground ? .dark : .light }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var canvasHandle: CanvasHandle
    @StateObject private var chromeState = WindowChromeState()
    @State private var layoutChangeToken = UUID()

    var body: some View {
        detail
            // A scrap of paper: opens small, and shrinks small.
            .frame(minWidth: NoteWindow.side, idealWidth: NoteWindow.side, maxWidth: .infinity,
                   minHeight: NoteWindow.contentHeight, idealHeight: NoteWindow.contentHeight, maxHeight: .infinity)
            .background(InitialWindowSize(width: NoteWindow.side, height: NoteWindow.contentHeight))
            .background(AutoHideTrafficLights(state: chromeState))
            .task { appState.start() }
            .onAppear {
                chromeState.toggleSettings = { [appState] in SettingsWindow.toggle(appState: appState) }
                chromeState.rename = { [appState] name in
                    if let url = appState.session?.url { appState.rename(url, to: name) }
                }
                chromeState.newNote = { [appState] in appState.createNote(in: appState.currentFolder) }
                chromeState.libraryView = { [appState] in AnyView(LibraryPopover(appState: appState, library: appState.library)) }
                chromeState.settings = canvasHandle.settings
            }
            .alert("Scratchpad", isPresented: errorBinding) {
                Button("OK") {}
            } message: {
                Text(appState.errorMessage ?? "")
            }
    }

    @ViewBuilder private var detail: some View {
        if let session = appState.session {
            CanvasRepresentable(model: session.model, settings: canvasHandle.settings,
                                viewport: session.initialViewport, layout: session.layout,
                                cachedScrollView: session.scrollViews[session.layout]) { scrollView in
                session.scrollView = scrollView
                canvasHandle.scrollView = scrollView
            }
            .id("\(session.id)-\(session.layout.rawValue)-\(layoutChangeToken)")
            .onReceive(session.model.$layout.dropFirst()) { _ in layoutChangeToken = UUID() }
            .canvasGlassBorder()
            .ignoresSafeArea(edges: [.top, .bottom])
            // Sits under the chrome so a click anywhere but the color / width menu
            // (including the toolbar it is anchored to) simply closes that menu.
            .overlay { ToolMenuClickCatcher(settings: canvasHandle.settings) }
            .overlay(alignment: .top) {
                FloatingChrome(settings: canvasHandle.settings, handle: canvasHandle)
            }
            .overlay(alignment: .bottom) {
                CanvasInputModeHint(settings: canvasHandle.settings)
            }
            .overlay {
                WritingPanelModeHint(settings: canvasHandle.settings, handle: canvasHandle)
                    .frame(width: 0, height: 0)
            }
            .navigationTitle(session.name)
        } else {
            Color.clear.navigationTitle("Scratchpad")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } })
    }
}

/// The note is a square of `side` points. The window's title band is part of the window
/// frame but not its content, so the content is `titleBand` shorter than the square.
enum NoteWindow {
    static let side: CGFloat = 240
    static let titleBand: CGFloat = 32
    static var contentHeight: CGFloat { side - titleBand }
}

/// Sizes the window once, the first time this version runs: the window had been
/// restored at its old full-screen-ish size, which isn't a scrap of paper. After
/// that, the size is whatever the user last left it at.
private struct InitialWindowSize: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { SizerView(size: NSSize(width: width, height: height)) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SizerView: NSView {
        private static let key = "initialWindowSize.v6"
        let size: NSSize

        init(size: NSSize) {
            self.size = size
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Remembers the size (and position) the window was last closed at.
            window.setFrameAutosaveName("MainWindow")
            // SwiftUI applies its own frame just after the window appears; go after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let window = self.window else { return }
                // The minimum is the square, so the note can't narrow past what its height can follow.
                window.contentMinSize = self.size
                guard !UserDefaults.standard.bool(forKey: Self.key) else { return }
                UserDefaults.standard.set(true, forKey: Self.key)
                window.setContentSize(self.size)
                window.center()
            }
        }
    }
}

/// Shared show/hide for the panel that drops under the tool bar. The color / width
/// menu and the text formatting bar swap places, so both use this and a single
/// animation curve to read as one cross-fade instead of two mismatched moves.
private extension AnyTransition {
    static var floatingPanel: AnyTransition { .opacity.combined(with: .offset(y: -8)) }
}

/// Everything floating over the canvas: the tool bar, and the text formatting
/// bar that eases in underneath while a text block is being edited.
struct FloatingChrome: View {
    @ObservedObject var settings: CanvasSettings
    let handle: CanvasHandle
    @AppStorage("toolbarEdge") private var toolbarEdge = "left"

    private var isOverlay: Bool { toolbarEdge == "overlay" }

    var body: some View {
        VStack(spacing: FloatingChromeLayout.spacing) {
            if isOverlay {
                ToolBar(settings: settings)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                        handle.scrollView?.canvasView.setToolbarBottom($0)
                    }
            }
            if let menu = settings.toolMenu {
                FloatingToolMenuView(settings: settings, menu: menu)
                    .id(menu)
                    .transition(.floatingPanel)
            }
            FindBar(find: settings.find, handle: handle, settings: settings)
            if formattingBarShown {
                FormattingBar(settings: settings, handle: handle)
                    .transition(.floatingPanel)
            }
        }
        .background(ArrowCursorRegion())
        .onHover { handle.scrollView?.canvasView.setToolbarHovered($0) }
        .padding(.top, FloatingChromeLayout.topPadding)
        .environment(\.colorScheme, settings.chromeColorScheme)
        .animation(.spring(duration: 0.32, bounce: 0.12), value: settings.isEditingText)
        .animation(.spring(duration: 0.32, bounce: 0.12), value: settings.isTextOptionsOpen)
        .animation(.easeInOut(duration: 0.2), value: settings.tool)
        .animation(.easeInOut(duration: 0.15), value: settings.find.isVisible)
        // Same spring as the formatting bar it swaps with, so the two panels move
        // together rather than one snapping while the other eases.
        .animation(.spring(duration: 0.32, bounce: 0.12), value: settings.toolMenu)
        // The document text moves with the bar, not with the style dropdown inside it.
        .onAppear {
            handle.scrollView?.canvasView.setFormattingBarShown(formattingBarShown)
            if !isOverlay { handle.scrollView?.canvasView.setToolbarBottom(nil) }
        }
        // Without the floating bar the body starts at its stored origin again; the bar reports
        // its own bottom when it comes back.
        .onChange(of: isOverlay) { _, on in
            if !on { handle.scrollView?.canvasView.setToolbarBottom(nil) }
        }
        .onChange(of: formattingBarShown) { _, shown in
            handle.scrollView?.canvasView.setFormattingBarShown(shown)
        }
    }

    private var formattingBarShown: Bool {
        settings.toolMenu == nil
            && (settings.isTextOptionsOpen || (settings.isEditingText && settings.showTextOptionsWhileEditing))
    }
}

/// Catches clicks outside the floating color / width menu and closes it. Placed
/// beneath the chrome, so clicking the toolbar (or the menu's own badge) still
/// works normally. The text formatting bar is intentionally not covered.
private struct ToolMenuClickCatcher: View {
    @ObservedObject var settings: CanvasSettings

    var body: some View {
        if settings.toolMenu != nil || settings.isStyleMenuOpen {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    settings.toolMenu = nil
                    settings.isStyleMenuOpen = false
                }
        }
    }
}

/// In-note Find (⌘F): query field, "n of m", previous / next, close.
/// Return = next, Shift-Return = previous, Esc closes.
private struct FindBar: View {
    @ObservedObject var find: FindModel
    let handle: CanvasHandle
    @ObservedObject var settings: CanvasSettings
    @FocusState private var focused: Bool

    private var canvas: CanvasView? { handle.scrollView?.canvasView }

    var body: some View {
        if find.isVisible {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in note", text: $find.query)
                    .textFieldStyle(.plain)
                    .scratchpadWritingToolsAffordance(enabled: settings.writingToolsEnabled)
                    .frame(width: 150)
                    .focused($focused)
                    .help("Find in note (⌘F)")
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) { canvas?.findPrevious() } else { canvas?.findNext() }
                        return .handled
                    }
                    .onExitCommand { canvas?.hideFind() }
                Text(find.status)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .trailing)
                ToolButton(symbol: "chevron.up", help: "Previous (⇧⌘G)", isOn: false) { canvas?.findPrevious() }
                    .disabled(find.count == 0)
                ToolButton(symbol: "chevron.down", help: "Next (⌘G)", isOn: false) { canvas?.findNext() }
                    .disabled(find.count == 0)
                ToolButton(symbol: "xmark", help: "Close (Esc)", isOn: false) { canvas?.hideFind() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: FloatingChromeLayout.findBarHeight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .transition(.opacity.combined(with: .offset(y: -6)))
            .onAppear { focused = true }
            .onChange(of: find.focusToken) { focused = true }
        }
    }
}

extension View {
    @ViewBuilder
    func canvasGlassBorder() -> some View {
        if #available(macOS 26, *) {
            // Expose the native glass around the opaque writing surface.
            self
                .clipShape(.rect(cornerRadius: 14))
                .padding(2)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            self
        }
    }

    @ViewBuilder
    func scratchpadWritingToolsAffordance(enabled: Bool) -> some View {
        if #available(macOS 15.0, *) {
            writingToolsAffordanceVisibility(enabled ? .automatic : .hidden)
        } else {
            self
        }
    }
}

/// Tools, the Writing mode and the stroke options, as icons with no backing bar.
/// One divider splits the tools from the options; everything else is spaced evenly.
/// Horizontal is the capsule (or bare, below the window); vertical is the bare strip on a side edge.
struct ToolBar: View {
    @ObservedObject var settings: CanvasSettings
    var axis: Axis = .horizontal
    /// Horizontal without the capsule, for the strip below the window.
    var bare = false

    private var isWriting: Bool { settings.inputMode.usesLetterCell }

    /// Writing mode runs the Pen tool underneath, but it is its own choice: while
    /// it is on, only the Writing button reads as selected.
    private func isSelected(_ tool: Tool) -> Bool { !isWriting && settings.tool == tool }

    var body: some View {
        let vertical = axis == .vertical
        let capsule = !vertical && !bare
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ToolButton(symbol: "cursorarrow", help: "Select (1)", shortcut: "1", isOn: isSelected(.pointer)) { settings.selectTool(.pointer) }
            ToolButton(symbol: "pencil.tip", help: "Pen (2)", shortcut: "2", isOn: isSelected(.pen)) { settings.toggleTool(.pen) }
            ToolButton(symbol: "eraser", help: "Eraser (3)", shortcut: "3", isOn: isSelected(.eraser)) { settings.toggleTool(.eraser) }
            ToolButton(symbol: "pencil.line", help: "Writing mode (4)", shortcut: "4", isOn: isWriting) { settings.toggleWritingMode() }

            Divider().frame(width: vertical ? 18 : nil, height: vertical ? nil : 18)

            ToolButton(symbol: "textformat", help: "Text options (Q)", shortcut: "Q", isOn: settings.isTextOptionsOpen) { settings.isTextOptionsOpen.toggle() }
            StrokeBadge(settings: settings, menu: .color)
            StrokeBadge(settings: settings, menu: .width)
        }
        .padding(.horizontal, capsule ? 12 : 0)
        .padding(.top, capsule ? 4 : (vertical ? 8 : 0))
        .padding(.bottom, capsule ? 6 : (vertical ? 8 : 0))
        .frame(height: capsule ? FloatingChromeLayout.toolBarHeight : nil)
        .background {
            if capsule { Capsule().fill(.regularMaterial) }
        }
        .overlay {
            if capsule { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
        }
        .shadow(color: capsule ? .black.opacity(0.12) : .clear, radius: 10, y: 3)
    }
}

private struct ToolButton: View {
    let symbol: String
    let help: String
    var shortcut: String? = nil
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false
    @AppStorage("showToolbarShortcutLabels") private var showsLabel = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isOn ? Color.accentColor : (hovering ? Color.primary.opacity(0.08) : .clear))
                    )
                if showsLabel, let shortcut {
                    Text(shortcut)
                        .font(.system(size: 7, weight: .regular))
                        .fixedSize()
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Keep one decimal in toolbar values, except 100 so it fits the width badge.
private extension Double {
    var compactLabel: String {
        self == 100 ? "100" : String(format: "%.1f", self)
    }
}

private struct AnimatedNumber: View {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(value.compactLabel)
            .monospacedDigit()
            .contentTransition(.numericText(value: value))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: value)
    }
}

/// Color and width stay available regardless of the selected tool.
private struct StrokeBadge: View {
    @ObservedObject var settings: CanvasSettings
    let menu: FloatingToolMenu
    @State private var hovering = false
    @AppStorage("showToolbarShortcutLabels") private var showsLabel = false

    var body: some View {
        let isOn = settings.toolMenu == menu
        Button { settings.toggleToolMenu(menu) } label: {
            VStack(spacing: 2) {
                VStack(spacing: 3) {
                    if menu == .color {
                        Circle()
                            .fill(Color(nsColor: settings.color.nsColor))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(isOn ? Color.white : Color.primary.opacity(0.15), lineWidth: isOn ? 1.5 : 0.5))
                    } else {
                        AnimatedNumber(value: settings.width)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(isOn ? Color.white : Color.secondary)
                        Capsule()
                            .fill(isOn ? Color.white : Color(nsColor: settings.color.nsColor))
                            .frame(width: 20, height: 1 + settings.widthPreviewFraction * 5)
                            .overlay(Capsule().stroke(Color.white, lineWidth: 0))
                    }
                }
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn ? Color.accentColor : (hovering ? Color.primary.opacity(0.08) : .clear))
                )
                if showsLabel {
                    Text(menu == .color ? "W" : "E")
                        .font(.system(size: 7, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background {
            if menu == .width {
                ScrollStepRegion { delta, precise in settings.adjustWidthForScroll(delta: delta, precise: precise) }
            }
        }
        .help(menu == .color ? "Color (W)" : "Width (E) · Hold E and scroll to adjust")
    }
}

/// Native cursor rectangles keep controls independent of canvas redraws and hover animations.
private struct ArrowCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RegionView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    }
}

/// Reports the pointer entering and leaving its bounds without intercepting clicks.
/// SwiftUI's `onHover` never fires over a `Menu`'s label (the menu's own control
/// swallows it), so the style and size controls track the pointer with a real
/// `NSTrackingArea` instead.
private struct HoverRegion: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> RegionView { RegionView(onChange: onChange) }
    func updateNSView(_ view: RegionView, context: Context) { view.onChange = onChange }

    final class RegionView: NSView {
        var onChange: (Bool) -> Void
        private var area: NSTrackingArea?
        private var inside = false

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        /// Clicks belong to the control this sits behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }
        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        private func report(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            onChange(value)
        }
    }
}

/// Observe wheel input over a control without intercepting its clicks or forwarding
/// scroll to the canvas. `step` gets the vertical delta and whether it is precise.
private struct ScrollStepRegion: NSViewRepresentable {
    let step: (Double, Bool) -> Void
    func makeNSView(context: Context) -> ScrollView { ScrollView(step: step) }
    func updateNSView(_ view: ScrollView, context: Context) { view.step = step }

    final class ScrollView: NSView {
        var step: (Double, Bool) -> Void
        private var monitor: Any?
        init(step: @escaping (Double, Bool) -> Void) {
            self.step = step
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                self.step(Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas)
                return nil
            }
        }
    }
}

/// Closes the floating color / width menu on Escape. Attached to the menu itself,
/// so it only exists while the menu is shown; the text formatting bar is unaffected.
private struct EscapeDismissMonitor: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView(onDismiss: onDismiss) }
    func updateNSView(_ view: MonitorView, context: Context) { view.onDismiss = onDismiss }

    final class MonitorView: NSView {
        var onDismiss: () -> Void
        private var monitor: Any?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// Never intercept clicks; only watches keys.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      event.keyCode == PenKeyMonitor.escapeKeyCode else { return event }
                self.onDismiss()
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct FloatingToolMenuView: View {
    @ObservedObject var settings: CanvasSettings
    let menu: FloatingToolMenu

    @State private var selectedColorSlot: Int?

    private var editingColor: Binding<RGBA> {
        Binding(get: {
            selectedColorSlot.flatMap { settings.savedColors[$0] } ?? settings.color
        }, set: { value in
            if let slot = selectedColorSlot { settings.savedColors[slot] = value }
            settings.color = value
        })
    }

    private static let colors: [(name: String, color: RGBA)] = [
        ("Black", .black), ("Blue", .blue), ("Red", .red), ("Green", .green), ("Orange", .orange),
        ("Gray", RGBA(r: 0.5, g: 0.5, b: 0.5)), ("Purple", RGBA(r: 0.55, g: 0.3, b: 0.75)),
        ("Pink", RGBA(r: 0.9, g: 0.35, b: 0.6)), ("Yellow", RGBA(r: 0.95, g: 0.8, b: 0.2)),
        ("White", RGBA(r: 1, g: 1, b: 1)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if menu == .color {
                ColorCodeRow(title: "Color", color: editingColor,
                             submitHelp: selectedColorSlot == nil
                                ? "Hex or RGB (Return to apply)"
                                : "Hex or RGB (Return to save this slot)",
                             focusOnAppear: selectedColorSlot != nil)
                    .id(selectedColorSlot)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(Self.colors, id: \.name) { swatch in
                        Button {
                            selectedColorSlot = nil
                            settings.color = swatch.color
                        } label: {
                            Circle()
                                .fill(Color(nsColor: swatch.color.nsColor))
                                .frame(width: 23, height: 23)
                                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                                .padding(3)
                                .overlay(Circle().stroke(settings.color == swatch.color ? Color.primary.opacity(0.5) : .clear, lineWidth: 1))
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                        .accessibilityLabel(swatch.name)
                        .accessibilityAddTraits(settings.color == swatch.color ? [.isSelected] : [])
                    }
                }
                Divider()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: CanvasSettings.savedColorSlotCount)) {
                    ForEach(0..<CanvasSettings.savedColorSlotCount, id: \.self) { slot in
                        Button {
                            selectedColorSlot = slot
                            if let color = settings.savedColors[slot] { settings.color = color }
                        } label: {
                            Circle()
                                .fill(settings.savedColors[slot].map { Color(nsColor: $0.nsColor) } ?? Color.clear)
                                .frame(width: 23, height: 23)
                                .overlay(Circle().stroke(Color.primary.opacity(0.2),
                                    style: StrokeStyle(lineWidth: 0.5, dash: settings.savedColors[slot] == nil ? [3, 2] : [])))
                                .overlay {
                                    if settings.savedColors[slot] == nil {
                                        Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(3)
                                .overlay(Circle().stroke(selectedColorSlot == slot ? Color.primary.opacity(0.5) : .clear, lineWidth: 1))
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to use or edit · Enter a hex or RGB value above and press Return to save")
                        .accessibilityLabel("Saved color slot \(slot + 1): \(settings.savedColors[slot]?.hexCode ?? "Empty")")
                        .accessibilityAddTraits(selectedColorSlot == slot ? [.isSelected] : [])
                    }
                }
                ColorCodeRow(title: "BG color", color: $settings.backgroundColor, opaque: true)
            } else {
                HStack {
                    Text("Width").foregroundStyle(.secondary)
                    Spacer()
                    AnimatedNumber(value: settings.width)
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Slider(value: $settings.width, in: CanvasSettings.widthRange)
                    .help("Pen width ([ / ])")
                Capsule()
                    .fill(Color(nsColor: settings.color.nsColor))
                    .frame(height: 1 + settings.widthPreviewFraction * 21)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
            }
        }
        .padding(16)
        .frame(width: menu == .color ? 270 : 250)
        .font(.system(size: 12))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .onKeyPress(.escape) {
            settings.toolMenu = nil
            return .handled
        }
        .background(EscapeDismissMonitor { settings.toolMenu = nil })
        .environment(\.colorScheme, settings.chromeColorScheme)
    }
}

private struct ColorCodeRow: View {
    let title: String
    @Binding var color: RGBA
    var opaque = false
    var submitHelp = "Hex or RGB (Return to apply)"
    var focusOnAppear = false
    @State private var code = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                Circle()
                    .fill(Color(nsColor: color.nsColor))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .accessibilityHidden(true)
                ColorCodeField(text: $code, focusOnAppear: focusOnAppear) {
                    guard var value = RGBA(colorCode: code) else {
                        invalid = true
                        return
                    }
                    if opaque { value.a = 1 }
                    color = value
                    code = value.hexCode
                    invalid = false
                }
                .frame(width: 126, height: 16)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(invalid ? Color.red.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 0.5))
                .help(submitHelp)
                .accessibilityLabel(title + " code")
            }
            if invalid {
                Text("Enter a valid hex or RGB color").font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .onAppear { code = color.hexCode }
        .onChange(of: color) { code = color.hexCode; invalid = false }
        .onChange(of: code) { invalid = false }
    }
}

/// Use the same native single-line cell for display and editing to keep its baseline stable.
private struct ColorCodeField: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    var focusOnAppear = false
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit)
        field.placeholderString = "Hex or RGB"
        if focusOnAppear {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, window.isKeyWindow else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        field.textColor = .labelColor
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ColorCodeField
        init(_ parent: ColorCodeField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        @objc func commit() { parent.submit() }
    }
}

/// Text formatting controls. Every action goes to the editing text view through
/// `CanvasView.performTextAction`; the style menu and size field read the caret back
/// from `settings` so they show what is actually in effect. All gaps are the same.
struct FormattingBar: View {
    @ObservedObject var settings: CanvasSettings
    let handle: CanvasHandle
    @State private var hoveringStyle = false

    private var style: ParagraphStyleKind { settings.editingTextStyle ?? .body }

    /// The left button also reads as on for `.natural` (the default), which lays
    /// out like left, so one alignment always looks selected.
    private var isLeftAligned: Bool {
        settings.editingAlignment == .left || settings.editingAlignment == .natural
    }

    private func send(_ action: Selector) {
        handle.scrollView?.canvasView.performTextAction(action)
    }

    var body: some View {
        // One row of controls, one gap: no dividers, whose line is invisible against
        // the material but whose width read as an extra empty gap between groups.
        HStack(spacing: 2) {
            // A plain button, not a native Menu: the native menu draws over the bar with
            // its own chrome. This one drops under the bar (see the overlay below).
            Button { settings.isStyleMenuOpen.toggle() } label: {
                Text(style.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 52, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hoveringStyle || settings.isStyleMenuOpen ? Color.primary.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringStyle = $0 }
            .help("Paragraph style · \(style.displayName)")

            FontSizeControl(settings: settings, handle: handle)

            FormatButton(symbol: "bold", help: "Bold (⌘B)", isOn: settings.editingIsBold) { send(TextFormatting.boldSelector) }
            FormatButton(symbol: "italic", help: "Italic (⌘I)", isOn: settings.editingIsItalic) { send(TextFormatting.italicSelector) }
            FormatButton(symbol: "underline", help: "Underline (⌘U)", isOn: settings.editingIsUnderline) { send(#selector(NSText.underline(_:))) }

            FormatButton(symbol: "text.alignleft", help: "Align left", isOn: isLeftAligned) { send(#selector(NSText.alignLeft(_:))) }
            FormatButton(symbol: "text.aligncenter", help: "Center", isOn: settings.editingAlignment == .center) { send(#selector(NSText.alignCenter(_:))) }
            FormatButton(symbol: "text.alignright", help: "Align right", isOn: settings.editingAlignment == .right) { send(#selector(NSText.alignRight(_:))) }

            FormatButton(symbol: "list.bullet", help: "Bullet list") { send(TextFormatting.bulletListSelector) }
            FormatButton(symbol: "list.number", help: "Numbered list") { send(TextFormatting.numberListSelector) }

            FormatButton(symbol: "link", help: "Add link (⌘K)") { send(TextFormatting.addLinkSelector) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: FloatingChromeLayout.formattingBarHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        // Drops under the bar, starting at the style button. An overlay, so the layout
        // (and the canvas inset) does not move while it is open.
        .overlay(alignment: .topLeading) {
            if settings.isStyleMenuOpen {
                StyleMenuPanel(current: style) { action in
                    settings.isStyleMenuOpen = false
                    send(action)
                }
                .offset(x: 8, y: FloatingChromeLayout.formattingBarHeight + FloatingChromeLayout.styleMenuGap)
                .transition(.floatingPanel)
            }
        }
        .onDisappear { settings.isStyleMenuOpen = false }
    }
}

/// The paragraph-style choices under the formatting bar. Same material as the bar it
/// hangs from, so the two read as one piece.
private struct StyleMenuPanel: View {
    let current: ParagraphStyleKind
    let choose: (Selector) -> Void

    private static let items: [(kind: ParagraphStyleKind, action: Selector)] = [
        (.heading(1), TextFormatting.heading1Selector),
        (.heading(2), TextFormatting.heading2Selector),
        (.heading(3), TextFormatting.heading3Selector),
        (.body, TextFormatting.bodySelector),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: FloatingChromeLayout.styleMenuRowSpacing) {
            ForEach(Self.items, id: \.kind.displayName) { item in
                StyleMenuRow(title: item.kind.displayName, isOn: item.kind == current) { choose(item.action) }
            }
        }
        .padding(FloatingChromeLayout.styleMenuPadding)
        .frame(width: 120, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

private struct StyleMenuRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: FloatingChromeLayout.styleMenuRowHeight)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Font size for the text being edited: an A-with-arrows icon and a borderless point
/// size field. Type a number, or scroll over the field to step it.
private struct FontSizeControl: View {
    @ObservedObject var settings: CanvasSettings
    let handle: CanvasHandle
    /// The pointer over the icon or the gap (SwiftUI hover) and over the native field
    /// (its own region). Either one lights the pill, so moving between them never blinks.
    @State private var overControl = false
    @State private var overField = false
    /// The field is being typed in, so the pill stays lit until editing ends.
    @State private var editingField = false

    /// Fixed, so the row never reflows: stepping 9 → 9.5 → 10 must not change the
    /// bar's width. Wide enough for the longest value the field can show, "72.5".
    private static let numberWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return ceil(("72.5" as NSString).size(withAttributes: [.font: font]).width) + 2
    }()

    private var size: Double { settings.editingFontSize ?? settings.defaultFontSize }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "textformat.size")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(height: 26)
                .accessibilityHidden(true)
            FontSizeField(size: size, onEditing: { editingField = $0 }) { handle.scrollView?.canvasView.setEditingTextFontSize($0) }
                .frame(width: Self.numberWidth, height: 26)
                .overlay(alignment: .leading) {
                    if !editingField {
                        AnimatedNumber(value: size)
                            .font(.system(size: 11))
                            .padding(.leading, 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(ScrollStepRegion { delta, precise in step(by: delta, precise: precise) })
                .background(HoverRegion { overField = $0 })
        }
        // A button-sized pill like the icon buttons, so the control reads and reacts
        // the same way; its padding is the same on both sides, so no side gains a gap.
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(overControl || overField || editingField ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { overControl = $0 }
        .help("Font size · type or scroll to change")
    }

    /// Half-point steps for a trackpad, whole points for a mouse wheel.
    private func step(by delta: Double, precise: Bool) {
        let next = size - delta * (precise ? 0.5 : 1)
        handle.scrollView?.canvasView.setEditingTextFontSize((next * 2).rounded() / 2)
    }
}

/// Borderless, background-less point-size cell. Return or leaving the field applies
/// the typed size; the size shown tracks the caret while the field is not being edited.
private struct FontSizeField: NSViewRepresentable {
    let size: Double
    let onEditing: (Bool) -> Void
    let submit: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        // SwiftUI draws the animated value until the native editor takes over.
        field.textColor = .clear
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.alignment = .left
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.stringValue = size.compactLabel
        field.placeholderString = size.compactLabel
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Leave the text alone mid-edit; otherwise track the caret's size.
        let text = size.compactLabel
        guard field.currentEditor() == nil, field.stringValue != text else { return }
        field.stringValue = text
        field.placeholderString = text
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FontSizeField
        init(_ parent: FontSizeField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            let field = notification.object as? NSTextField
            field?.textColor = .labelColor
            (field?.currentEditor() as? NSTextView)?.textColor = .labelColor
            parent.onEditing(true)
            // Deferred: the click that starts editing still places the caret after this runs.
            DispatchQueue.main.async {
                (notification.object as? NSTextField)?.currentEditor()?.selectAll(nil)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEditing(false)
            guard let field = notification.object as? NSTextField else { return }
            field.textColor = .clear
            apply(field.stringValue)
        }

        @objc func commit(_ sender: Any?) {
            guard let field = sender as? NSTextField else { return }
            apply(field.stringValue)
        }

        private func apply(_ text: String) {
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { return }
            parent.submit(value)
        }
    }
}

/// A formatting toggle. The on state uses the toolbar tool buttons' accent fill
/// with a white glyph, so a toggle reads exactly like a selected tool.
private struct FormatButton: View {
    let symbol: String
    let help: String
    /// On when the caret's text already carries this format (bold, alignment, …).
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.8))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Color.accentColor : (hovering ? Color.primary.opacity(0.1) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Pen-key and Scribe hints. Slides off screen for the Select, Eraser and Text tools.
private struct InputModeHint: View {
    @ObservedObject var settings: CanvasSettings
    var inWritingPanel = false

    private var shown: Bool { settings.tool == .pen }
    private var writing: Bool { settings.effectiveInputMode.usesLetterCell }

    private var penKey: String {
        switch settings.penKey {
        case .space: "␣"
        case .option: "⌥"
        case .fn: "fn"
        }
    }

    private func keyBadge(_ key: String, label: String) -> some View {
        Text(key)
            .fixedSize()
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4), lineWidth: 1))
            .accessibilityLabel(label)
    }

    /// Scribe: text or math (ink). Tap the trackpad's top-right corner, tap Control,
    /// press ⌃M, or click here.
    private var mathToggle: some View {
        let math = settings.scribeMath
        return Button { settings.scribeMath.toggle() } label: {
            HStack(spacing: 4) {
                keyBadge("⌃", label: "Control")
                Image(systemName: "function")
                    .foregroundStyle(math ? Color.white : Color.secondary)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 20)
                    .background(math ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                Text(math ? "Math" : "Text").fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(math ? "Math input: handwriting stays ink" : "Text input: handwriting becomes text")
        .help("\(math ? "Math: handwriting stays ink" : "Text: handwriting becomes text") · tap Control, ⌃M, or the trackpad's top-right corner")
    }

    // ponytail: Command-tap auto-advance pause (⌘ Auto/Paused pill button) disabled; restore with
    // trackModifierTap's .command branch in CanvasView if needed.
    // private var advanceToggle: some View {
    //     let on = settings.writingAutoAdvance
    //     return Button { settings.writingAutoAdvance.toggle() } label: {
    //         HStack(spacing: 4) {
    //             keyBadge("⌘", label: "Command")
    //             Image(systemName: on ? "play.fill" : "pause.fill")
    //             Text(on ? "Auto" : "Paused").fixedSize()
    //         }
    //     }.buttonStyle(.plain)
    // }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: writing ? "pencil.line" : "pencil.tip")
            Circle()
                .fill(settings.penIsDown ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)
                .accessibilityLabel(settings.penIsDown ? "Pen on" : "Pen off")
            keyBadge(penKey, label: settings.penKey.displayName)
            Text(settings.activation == .hold ? "Hold" : "Toggle").fixedSize()
            if settings.offersScribeZones { mathToggle }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, inWritingPanel ? 0 : 16)
        .environment(\.colorScheme, settings.chromeColorScheme)
        .offset(y: shown || inWritingPanel ? 0 : 80)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(.easeInOut(duration: 0.2), value: shown)
        .help("\(settings.activation.displayName) \(settings.penKey.displayName) to \(writing ? "write" : "draw")")
    }
}

private struct CanvasInputModeHint: View {
    @ObservedObject var settings: CanvasSettings

    var body: some View {
        if !settings.effectiveInputMode.usesLetterCell {
            InputModeHint(settings: settings)
        }
    }
}

/// Hosts the same hint in the floating writing panel while Write or Scribe is active.
private struct WritingPanelModeHint: NSViewRepresentable {
    @ObservedObject var settings: CanvasSettings
    let handle: CanvasHandle

    final class Coordinator {
        let handle: CanvasHandle
        let hostingView: NSHostingView<InputModeHint>

        init(settings: CanvasSettings, handle: CanvasHandle) {
            self.handle = handle
            hostingView = NSHostingView(rootView: InputModeHint(settings: settings, inWritingPanel: true))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(settings: settings, handle: handle) }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostingView.rootView = InputModeHint(settings: settings, inWritingPanel: true)
        handle.writingPanelModeHint = settings.effectiveInputMode.usesLetterCell
            ? context.coordinator.hostingView : nil
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if coordinator.handle.writingPanelModeHint === coordinator.hostingView {
            coordinator.handle.writingPanelModeHint = nil
        }
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let model: CanvasModel
    let settings: CanvasSettings
    let viewport: Viewport?
    let layout: NoteLayout
    let cachedScrollView: CanvasScrollView?
    let onScrollView: (CanvasScrollView) -> Void

    func makeNSView(context: Context) -> CanvasScrollView {
        let scrollView = cachedScrollView ?? CanvasScrollView(model: model, settings: settings, viewport: viewport, layout: layout)
        scrollView.canvasView.prepareForPresentation()
        onScrollView(scrollView)
        DispatchQueue.main.async {
            guard !settings.isEditingText else { return }
            if layout == .document, settings.tool == .pointer {
                scrollView.canvasView.focusDocumentBody()
            } else {
                scrollView.window?.makeFirstResponder(scrollView.canvasView)
            }
        }
        return scrollView
    }

    func updateNSView(_ nsView: CanvasScrollView, context: Context) {}
}
