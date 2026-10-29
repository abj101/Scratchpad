import SwiftUI
import AppKit
import Combine
import CanvasKit

/// Draws a tinted ring around the window when edge chrome is active.
/// Hosted in a window that sits `margin` outside the app window on the left, right and bottom and
/// has a `topBand` strip above it that acts as a title bar (see `WindowEdgeOverlay`).
struct WindowEdgeBorder: View {
    @ObservedObject var state: WindowChromeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("toolbarEdge") private var toolbarEdge = "left"
    /// Bumped on app/Space switches: the glass keeps its old backdrop sample until it is rebuilt.
    @State private var glassEpoch = 0

    /// How far the ring sits outside the app window.
    static let margin: CGFloat = 6
    /// Height of the strip above the window that holds the traffic lights and drags the window.
    static let topBand: CGFloat = 28
    /// Bottom of the band stays click-through so native top-edge resizing keeps working.
    static let resizeGrip: CGFloat = 4
    /// Width of the side strip that holds the vertical tool bar, on the side chosen in Settings.
    static let toolStrip: CGFloat = 44

    /// Where the tool bar lives, from Settings: "left", "right", "bottom" (a strip in the ring) or
    /// "overlay" (the floating capsule over the canvas, no strip).
    static var edge: String { UserDefaults.standard.string(forKey: "toolbarEdge") ?? "left" }
    /// Space the ring takes left, right and below the app window.
    static func insets(for edge: String) -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
        (edge == "left" ? toolStrip : margin, edge == "right" ? toolStrip : margin, edge == "bottom" ? toolStrip : margin)
    }
    static var leftInset: CGFloat { insets(for: edge).left }
    static var rightInset: CGFloat { insets(for: edge).right }
    static var bottomInset: CGFloat { insets(for: edge).bottom }

    // Tuning knobs for the native window corners on each macOS generation.
    private static let windowCornerRadius: CGFloat = {
        if #available(macOS 26, *) { 16 } else { 10 }
    }()

    // The outer edge of the ring follows the window corners, offset by the margin.
    private static let cornerRadius: CGFloat = windowCornerRadius + margin
    private static let tint = Color(white: 0.22).opacity(0.7)

    var body: some View {
        ZStack {
            ring
                .id(toolbarEdge) // the ring's geometry depends on the side; rebuild it when it flips
                .allowsHitTesting(false)
            // Outside the ring's no-hit-testing modifier, so the buttons take clicks.
            if let settings = state.settings {
                toolBarStrip(settings)
            }
        }
        // The panel is titled (for real traffic lights); without this SwiftUI keeps the ring
        // out of the titlebar, which is exactly where the top band is.
        .ignoresSafeArea()
        .opacity(state.showsBorder ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.showsBorder)
    }

    /// The tool bar in the strip beside or below the window; nothing in overlay mode.
    @ViewBuilder private func toolBarStrip(_ settings: CanvasSettings) -> some View {
        let inset = Self.insets(for: toolbarEdge)
        switch toolbarEdge {
        case "overlay":
            EmptyView()
        case "bottom":
            ToolBar(settings: settings, bare: true)
                .environment(\.colorScheme, .dark)
                .frame(height: Self.toolStrip)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Self.margin)
                .frame(maxHeight: .infinity, alignment: .bottom)
        default:
            ToolBar(settings: settings, axis: .vertical)
                .environment(\.colorScheme, .dark)
                .frame(width: Self.toolStrip)
                .frame(maxHeight: .infinity)
                .padding(.top, Self.topBand)
                .padding(.bottom, inset.bottom)
                .frame(maxWidth: .infinity, alignment: toolbarEdge == "right" ? .trailing : .leading)
        }
    }

    /// Glass (or material) ring: the outer rounded rect minus the app window's rect, so the ring
    /// meets the window edge exactly. A thin highlight stroke sits on the window edge; the glass draws its own outer rim.
    private var ring: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let m = Self.margin
            let (left, right, bottom) = Self.insets(for: toolbarEdge)
            let outer = CGRect(x: 0, y: 0, width: w, height: h)
            let inner = CGRect(x: left, y: Self.topBand, width: w - left - right, height: h - Self.topBand - bottom)
            let mask = Path { p in
                p.addRoundedRect(in: outer, cornerSize: CGSize(width: Self.cornerRadius, height: Self.cornerRadius),
                                 style: .continuous)
                p.addRoundedRect(in: inner, cornerSize: CGSize(width: Self.windowCornerRadius, height: Self.windowCornerRadius),
                                 style: .continuous)
            }

            ZStack(alignment: .topLeading) {
                if #available(macOS 26, *) {
                    shape.fill(.clear)
                        .glassEffect(.regular.tint(Self.tint), in: shape)
                        .mask(mask.fill(style: FillStyle(eoFill: true)))
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(Self.tint)
                        .mask(mask.fill(style: FillStyle(eoFill: true)))
                }
                // 1pt just outside the window's edge, catching the light along the glass.
                RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous)
                    .inset(by: -0.5)
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                    .frame(width: inner.width, height: inner.height)
                    .position(x: inner.midX, y: inner.midY)
            }
            .frame(width: w, height: h)
        }
        .id(glassEpoch)
        .onReceive(NotificationCenter.default.publisher(for: Summon.backdropChanged)) { _ in glassEpoch += 1 }
    }
}

private final class EdgeHostingView: NSHostingView<WindowEdgeBorder> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

private final class ChromeActionButton: NSButton {
    var isActive = false { didSet { updateAppearance() } }
    private var isHovered = false { didSet { updateAppearance() } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func updateAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isActive ? 0.24 : isHovered ? 0.14 : 0).cgColor
        setAccessibilityValue(isActive ? "Open" : "Closed")
    }
}

/// System traffic lights only draw in color when their window has an active appearance, which
/// AppKit decides privately (overriding `isKeyWindow` is ignored). This panel is never key, so it
/// borrows the app window's state through the private hook; verified to give the native colors.
/// Harmless if a future macOS stops asking: the buttons just draw grey.
private final class EdgePanel: NSPanel {
    weak var appWindow: NSWindow?
    /// The band sits above the app window; at the top of the screen (tiling, maximized) AppKit would
    /// squash it under the menu bar and drag the app window along. Let it hang off-screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    @objc(_hasActiveAppearance) func hasActiveAppearance() -> Bool { (appWindow?.isKeyWindow ?? false) || isKeyWindow }
    @objc(_hasActiveAppearanceIgnoringKeyFocus) func hasActiveAppearanceIgnoringKeyFocus() -> Bool {
        hasActiveAppearance()
    }
}

/// A transparent titled window around the app window, ordered just below it, so the ring is drawn
/// around the window rather than over its content. Being titled gives it real system traffic lights
/// (exact size, look and hover glyphs) in its top band; they are retargeted at the app window.
/// The middle of the band shows the note's title (the app window's title); double-click it to
/// rename, like Finder. The panel takes the mouse over the glass border and title band.
final class WindowEdgeOverlay: NSObject, NSTextFieldDelegate {
    private enum BorderResize {
        case left, right, bottom, topLeft, topRight, bottomLeft, bottomRight

        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                switch self {
                case .left: .frameResize(position: .left, directions: .all)
                case .right: .frameResize(position: .right, directions: .all)
                case .bottom: .frameResize(position: .bottom, directions: .all)
                case .topLeft: .frameResize(position: .topLeft, directions: .all)
                case .topRight: .frameResize(position: .topRight, directions: .all)
                case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
                case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
                }
            } else {
                switch self {
                case .left, .right: .resizeLeftRight
                case .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: .resizeUpDown
                }
            }
        }
    }

    private let panel: EdgePanel
    private weak var state: WindowChromeState?
    private weak var parent: NSWindow?
    private let titleField = NSTextField(labelWithString: "")
    /// New note, Notes library and Settings, at the band's trailing edge. Created after `super.init`
    /// since their targets are this object.
    private var actionButtons: [NSButton] = []
    private var libraryWindow: NSPanel?
    private var titleObservation: NSKeyValueObservation?
    private var resignObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private var windowObserver: NSObjectProtocol?
    /// The lights' own x positions, captured before any shift for the tool strip.
    private var lightBaseX: [CGFloat]?
    /// The title when editing began; non-nil while editing.
    private var titleBeforeEdit: String?
    private var fade: AnyCancellable?
    private var monitor: Any?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin = NSPoint.zero
    private var resizeStartFrame: NSRect?
    private var borderResize: BorderResize?
    /// The press we took over. Its mouse-up must be taken too: AppKit runs the title bar's
    /// double-click action (full screen) on mouse-up if it gets the event.
    private var pressConsumed = false
    /// True while the app window is entering, in or leaving full screen.
    private var isSuspended = false

    private var buttons: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { panel.standardWindowButton($0) }
    }

    init(state: WindowChromeState) {
        panel = EdgePanel(contentRect: .zero,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                          backing: .buffered, defer: true)
        self.state = state
        super.init()
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        // Not transient, and not hidden on deactivate (an NSPanel default): either makes the ring vanish
        // ahead of the window on Cmd-Tab and Mission Control. Auxiliary so it follows the note onto full-screen Spaces.
        panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = EdgeHostingView(rootView: WindowEdgeBorder(state: state))
        let actions = [#selector(closeApp), #selector(minimizeApp), #selector(zoomApp)]
        for (button, action) in zip(buttons, actions) {
            button.target = self
            button.action = action
            button.alphaValue = 0
        }
        titleField.font = .titleBarFont(ofSize: 0)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.delegate = self
        titleField.alphaValue = 0
        let icons: [(symbol: String, help: String, action: Selector)] = [
            ("square.and.pencil", "New Note", #selector(newNote)),
            ("folder", "Notes", #selector(toggleLibrary(_:))),
            ("gearshape", "Settings", #selector(showSettings)),
        ]
        actionButtons = icons.map { icon in
            let button = ChromeActionButton(image: NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.help)!,
                                            target: self, action: icon.action)
            button.isBordered = false
            button.contentTintColor = .white
            button.toolTip = icon.help
            button.alphaValue = 0
            button.updateAppearance()
            return button
        }
        actionButtons.forEach { buttons.first?.superview?.addSubview($0) }
        buttons.first?.superview?.addSubview(titleField)
        // Clicking back into the note (or another app) ends the edit, keeping what was typed.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                self?.panel.makeFirstResponder(nil)
            }
        fade = state.$showsBorder.sink { [weak self] shows in self?.fadeButtons(in: shows) }
        // Moving the tool strip to the other side changes the panel's width.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.syncFrame()
            }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                self?.syncActionButtonStates()
            })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.syncActionButtonStates() }
            })
        // Band drags move the app window. Handled ahead of the titlebar, which would otherwise
        // try to move (or double-click zoom) the panel itself.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleBandMouse(event) ? nil : event
        }
    }

    @objc private func closeApp() { parent?.performClose(nil) }
    @objc private func minimizeApp() { parent?.miniaturize(nil) }
    /// The window's frame before the expand button filled the screen; nil when it is not filled.
    private var frameBeforeFill: NSRect?

    /// Fills the screen with the edge ring still around it: the band above, the tool strip and margin
    /// beside and below. A second press restores the previous frame. The window never goes to a full-screen Space.
    @objc private func zoomApp() {
        guard let parent else { return }
        if let frame = frameBeforeFill {
            frameBeforeFill = nil
            parent.setFrame(frame, display: true, animate: true)
            return
        }
        guard let area = (parent.screen ?? NSScreen.main)?.visibleFrame else { return }
        let bottom = WindowEdgeBorder.bottomInset, left = WindowEdgeBorder.leftInset, right = WindowEdgeBorder.rightInset
        frameBeforeFill = parent.frame
        parent.setFrame(NSRect(x: area.minX + left, y: area.minY + bottom,
                               width: area.width - left - right,
                               height: area.height - bottom - WindowEdgeBorder.topBand), display: true, animate: true)
    }

    @objc private func newNote() {
        state?.newNote?()
        parent?.makeKey()
    }

    @objc private func toggleLibrary(_ sender: NSButton) {
        if let window = libraryWindow, window.isVisible { window.close(); return }
        guard let makeView = state?.libraryView else { return }
        let window = libraryWindow ?? NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                                              backing: .buffered, defer: true)
        window.title = "Notes"
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: makeView())
        // Fixed size up front: otherwise the panel opens empty and resizes as SwiftUI lays out.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 300, height: 380))
        libraryWindow = window
        placeBeside(window)
        window.makeKeyAndOrderFront(nil)
        syncActionButtonStates()
    }

    @objc private func showSettings() {
        state?.toggleSettings?()
        // The Settings scene's window appears on the next turn; park it beside the note too.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = NSApp.windows.first(where: { $0 !== self.parent && $0.isVisible && $0.title.contains("Settings") })
            else { return }
            self.placeBeside(window)
            self.syncActionButtonStates()
        }
    }

    private func syncActionButtonStates() {
        let libraryVisible = libraryWindow?.isVisible == true
        let settingsVisible = NSApp.windows.contains { $0 !== parent && $0.isVisible && $0.title.contains("Settings") }
        (actionButtons.count > 1 ? actionButtons[1] as? ChromeActionButton : nil)?.isActive = libraryVisible
        (actionButtons.count > 2 ? actionButtons[2] as? ChromeActionButton : nil)?.isActive = settingsVisible
    }

    /// Right of the note window, or left of it when the screen has no room.
    func placeBeside(_ window: NSWindow) {
        guard let parent else { return }
        let f = parent.frame, size = window.frame.size
        let room = (parent.screen?.visibleFrame.maxX ?? .infinity) - f.maxX
        let x = room >= size.width + 8 ? f.maxX + 8 : f.minX - size.width - 8
        window.setFrameOrigin(NSPoint(x: x, y: f.maxY - size.height))
    }

    private func fadeButtons(in shows: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The canvas draws its own native glass rim; suppress the window shadow's dark outline.
        parent?.hasShadow = isSuspended
        parent?.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.18
            (buttons + actionButtons + [titleField]).forEach { $0.animator().alphaValue = shows ? 1 : 0 }
        }
    }

    /// Hidden while the app window enters, sits in, or leaves full screen; a child panel can't keep
    /// up with the system's full-screen animation, and there are no edges to grab there.
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            panel.makeFirstResponder(nil)
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            parent?.hasShadow = true
            parent?.invalidateShadow()
        } else {
            syncFrame()
            panel.alphaValue = 1
        }
    }

    func attach(to window: NSWindow?) {
        guard window !== parent else { syncFrame(); return }
        detach()
        guard let window else { return }
        parent = window
        window.hasShadow = false
        window.invalidateShadow()
        panel.appWindow = window
        titleObservation = window.observe(\.title, options: [.initial, .new]) { [weak self] window, _ in
            guard let self, self.titleBeforeEdit == nil else { return }
            self.titleField.stringValue = window.title
        }
        syncFrame()
        window.addChildWindow(panel, ordered: .below)
    }

    func detach() {
        titleObservation = nil
        parent?.hasShadow = true
        parent?.invalidateShadow()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent = nil
    }

    /// Child windows move with their parent but do not resize with it. Also redraws the lights,
    /// since this runs whenever the app window gains or loses key.
    func syncFrame() {
        guard !isSuspended, let parent else { return }
        parent.hasShadow = false
        let m = WindowEdgeBorder.margin, f = parent.frame
        let left = WindowEdgeBorder.leftInset, right = WindowEdgeBorder.rightInset, bottom = WindowEdgeBorder.bottomInset
        panel.setFrame(NSRect(x: f.minX - left, y: f.minY - bottom, width: f.width + left + right,
                              height: f.height + bottom + WindowEdgeBorder.topBand), display: true)
        // The lights sit at the panel's left edge, `margin` from the window; with a wider strip
        // on the left they move along with the window.
        let lights = buttons
        let base = lightBaseX ?? lights.map { $0.frame.minX }
        lightBaseX = base
        for (light, x) in zip(lights, base) {
            light.setFrameOrigin(NSPoint(x: x + left - m, y: light.frame.minY))
        }
        lights.forEach { $0.needsDisplay = true }
        layoutTitle()
    }

    /// True when a click lands on the drawn title text, not the blank part of the field.
    private func isOnTitleText(_ event: NSEvent) -> Bool {
        let bounds = titleField.bounds
        let textWidth = min(titleField.attributedStringValue.size().width, bounds.width)
        let textRect = NSRect(x: bounds.midX - textWidth / 2 - 4, y: bounds.minY,
                              width: textWidth + 8, height: bounds.height)
        return textRect.contains(titleField.convert(event.locationInWindow, from: nil))
    }

    /// Centered in the band, as wide as it can be without reaching the traffic lights or the action buttons.
    /// The action buttons sit at the trailing edge, in order left to right, vertically centered on the lights.
    private func layoutTitle() {
        guard let bar = titleField.superview, let close = buttons.first, let zoom = buttons.last else { return }
        let actionsWidth: CGFloat = CGFloat(actionButtons.count) * 24 + CGFloat(actionButtons.count - 1) * 4
        let inset = WindowEdgeBorder.rightInset
        // The whole gap between the lights and the icons, so a narrow window still shows most of the title.
        let left = zoom.frame.maxX + 8, right = bar.bounds.width - inset - actionsWidth - 6
        let height = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(x: left, y: close.frame.midY - height / 2, width: max(0, right - left), height: height)
        // The app window's right edge sits `rightInset` in from the panel's edge.
        var x = bar.bounds.width - inset
        for button in actionButtons.reversed() {
            x -= 24
            button.frame = NSRect(x: x, y: close.frame.midY - 11, width: 24, height: 22)
            x -= 4
        }
    }

    // MARK: Title editing

    private var isTitleHit: (NSView?) -> Bool {
        { [titleField] view in view.map { $0 === titleField || $0.isDescendant(of: titleField) } ?? false }
    }

    private func beginEditingTitle() {
        titleBeforeEdit = titleField.stringValue
        titleField.isEditable = true
        state?.isEditingTitle = true
        panel.makeKey()
        panel.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    /// Escape puts the old title back; the end-editing handler then sees no change.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let old = titleBeforeEdit else { return false }
        titleField.stringValue = old
        panel.makeFirstResponder(nil)
        return true
    }

    /// Return, Escape, Tab or clicking away all land here.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let old = titleBeforeEdit else { return }
        titleBeforeEdit = nil
        titleField.isEditable = false
        let name = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != old { state?.rename?(name) }
        // Show what the note is really called now (unchanged if the rename failed).
        titleField.stringValue = parent?.title ?? old
        DispatchQueue.main.async { [weak self] in
            guard let self, self.titleBeforeEdit == nil else { return }
            self.titleField.stringValue = self.parent?.title ?? self.titleField.stringValue
        }
        state?.isEditingTitle = false
        if panel.isKeyWindow { parent?.makeKey() }
    }

    /// Capture the glass border for dragging, while leaving the window's native resize edges exposed.
    func updateMouseInteractivity(showsBorder: Bool) {
        guard !isSuspended else { return }
        var inDragArea = false
        if showsBorder, let parent {
            let p = NSEvent.mouseLocation
            let inParent = parent.frame.contains(p)
            let topResizeGrip = p.y >= parent.frame.maxY && p.y <= parent.frame.maxY + WindowEdgeBorder.resizeGrip &&
                p.x >= parent.frame.minX && p.x <= parent.frame.maxX
            inDragArea = panel.frame.contains(p) && !inParent && !topResizeGrip
        }
        if panel.ignoresMouseEvents == inDragArea { panel.ignoresMouseEvents = !inDragArea }

        // The panel isn't key after the app is re-activated, so its cursor rects don't apply and the
        // canvas's cursor would stick over the border; set the cursor here on each mouse move.
        if panel.isVisible, let parent {
            let p = NSEvent.mouseLocation
            if panel.frame.contains(p), !parent.frame.contains(p) {
                let localPoint = panel.convertPoint(fromScreen: p)
                if let resize = borderResize(at: p, parentFrame: parent.frame),
                   (!isInToolStrip(localPoint) || isInToolStripGutter(localPoint)) {
                    resize.cursor.set()
                    return
                }
                var overTitleText = false
                if titleBeforeEdit != nil, let window = titleField.window {
                    overTitleText = window.convertToScreen(titleField.convert(titleField.bounds, to: nil)).contains(p)
                }
                if overTitleText { NSCursor.iBeam.set() } else { NSCursor.arrow.set() }
            }
        }
    }

    private func borderResize(at point: NSPoint, parentFrame frame: NSRect) -> BorderResize? {
        guard panel.frame.contains(point), !frame.contains(point) else { return nil }
        let panelFrame = panel.frame
        let cornerSize = min(24, min(panelFrame.width, panelFrame.height) / 3)
        let inLeft = point.x < frame.minX
        let inRight = point.x > frame.maxX
        let inBottom = point.y < frame.minY

        // Use the visible outer corners of the ring as the corner resize targets.
        if point.x <= panelFrame.minX + cornerSize, point.y <= panelFrame.minY + cornerSize { return .bottomLeft }
        if point.x >= panelFrame.maxX - cornerSize, point.y <= panelFrame.minY + cornerSize { return .bottomRight }
        if point.x <= panelFrame.minX + cornerSize, point.y >= panelFrame.maxY - cornerSize { return .topLeft }
        if point.x >= panelFrame.maxX - cornerSize, point.y >= panelFrame.maxY - cornerSize { return .topRight }

        if inLeft { return .left }
        if inRight { return .right }
        if inBottom { return .bottom }
        return nil
    }

    private func resizeWindow(to point: NSPoint) {
        guard let parent, let start = resizeStartFrame, let borderResize else { return }
        let dx = point.x - (dragStartMouse?.x ?? point.x)
        let dy = point.y - (dragStartMouse?.y ?? point.y)
        let minSize = parent.minSize
        var frame = start
        switch borderResize {
        case .left, .topLeft, .bottomLeft:
            frame.size.width = max(minSize.width, start.width - dx)
            frame.origin.x = start.maxX - frame.width
        case .right, .topRight, .bottomRight:
            frame.size.width = max(minSize.width, start.width + dx)
        case .bottom:
            break
        }
        switch borderResize {
        case .bottom, .bottomLeft, .bottomRight:
            frame.size.height = max(minSize.height, start.height - dy)
            frame.origin.y = start.maxY - frame.height
        case .topLeft, .topRight:
            frame.size.height = max(minSize.height, start.height + dy)
        case .left, .right:
            break
        }
        parent.setFrame(frame, display: true)
        syncFrame()
    }

    /// True over the tool strip beside the window, below the band (panel-local coordinates).
    private func isInToolStrip(_ event: NSEvent) -> Bool {
        isInToolStrip(event.locationInWindow)
    }

    private func isInToolStrip(_ p: NSPoint) -> Bool {
        guard p.y <= panel.frame.height - WindowEdgeBorder.topBand else { return false }
        switch WindowEdgeBorder.edge {
        case "overlay": return false
        case "bottom": return p.y <= WindowEdgeBorder.toolStrip
        case "right": return p.x >= panel.frame.width - WindowEdgeBorder.toolStrip
        default: return p.x <= WindowEdgeBorder.toolStrip
        }
    }

    private func isInToolStripGutter(_ point: NSPoint) -> Bool {
        let gutter = (WindowEdgeBorder.toolStrip - 28) / 2
        switch WindowEdgeBorder.edge {
        case "bottom": return point.y <= gutter || point.y >= panel.frame.height - gutter
        case "right": return point.x <= panel.frame.width - WindowEdgeBorder.toolStrip + gutter ||
            point.x >= panel.frame.width - gutter
        case "left": return point.x <= gutter || point.x >= WindowEdgeBorder.toolStrip - gutter
        default: return false
        }
    }

    /// Moves the app window by the mouse delta since the press, in screen coordinates (the window
    /// moves under the pointer). Clicks on the traffic lights pass through untouched.
    private func handleBandMouse(_ event: NSEvent) -> Bool {
        guard let parent else { return false }
        switch event.type {
        case .leftMouseDown:
            pressConsumed = false
            let frame = panel.contentView?.superview
            let hit = frame?.hitTest(frame!.convert(event.locationInWindow, from: nil))
            if hit is NSButton { return false }
            let point = NSEvent.mouseLocation
            let localPoint = panel.convertPoint(fromScreen: point)
            if let resize = borderResize(at: point, parentFrame: parent.frame),
               (!isInToolStrip(event) || isInToolStripGutter(localPoint)) {
                borderResize = resize
                dragStartMouse = point
                resizeStartFrame = parent.frame
                pressConsumed = true
                return true
            }
            // The tool strip's buttons are SwiftUI, not NSButtons: let the click reach them.
            if isInToolStrip(event) {
                if titleBeforeEdit != nil { panel.makeFirstResponder(nil) }
                return false
            }
            if titleBeforeEdit != nil {
                if isTitleHit(hit) { return false }   // moving the caret
                panel.makeFirstResponder(nil)         // click elsewhere in the band commits
            } else if isTitleHit(hit), event.clickCount == 2, isOnTitleText(event) {
                beginEditingTitle()
                pressConsumed = true
                return true
            }
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = parent.frame.origin
            pressConsumed = true
        case .leftMouseDragged:
            if borderResize != nil {
                borderResize?.cursor.set()
                resizeWindow(to: NSEvent.mouseLocation)
                return true
            }
            guard let start = dragStartMouse else { return false }
            let mouse = NSEvent.mouseLocation
            parent.setFrameOrigin(NSPoint(x: dragStartOrigin.x + mouse.x - start.x,
                                          y: dragStartOrigin.y + mouse.y - start.y))
        default:
            // Only take the release of a press we took; otherwise a button's click-up never reaches it.
            let consumed = pressConsumed
            pressConsumed = false
            dragStartMouse = nil
            resizeStartFrame = nil
            borderResize = nil
            return consumed
        }
        return true
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        detach()
    }
}
