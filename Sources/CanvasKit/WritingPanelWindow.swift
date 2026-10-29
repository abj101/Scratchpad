import AppKit

/// The writing panel's own window: a borderless, non-activating child of the note's window that
/// floats above it, so the note can stay small and the panel can sit anywhere. Its frame is
/// remembered across launches. Not resizable.
final class WritingPanelWindow: NSPanel {
    /// Transparent margin around the panel and pill, where the window is grabbed.
    static let padding: CGFloat = 12
    private static let positionKey = "WritingPanelTopLeft"
    /// The placement setting the saved position belongs to; choosing another one resets the position.
    private static let placementKey = "WritingPanelPlacement"
    private var placement = WritingPanelPlacement.middle
    private let defaults: UserDefaults

    /// Holds the panel and pill, and routes clicks.
    let content = WritingPanelContentView()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The panel and pill draw their own shadows; the window's would trace their alpha as a jagged outline.
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior.insert(.fullScreenAuxiliary)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sizes the window while keeping its top-left, and shows it as a child of `note`. Each note
    /// restores the shared position; with none saved for `placement`, the panel goes to that spot
    /// at the bottom of the note's screen.
    func show(beside note: NSWindow, size: NSSize, placement: WritingPanelPlacement = .middle) {
        self.placement = placement
        let saved = defaults.string(forKey: Self.placementKey) == placement.rawValue
            ? defaults.string(forKey: Self.positionKey).map { NSPointFromString($0) } : nil
        let screen = (note.screen ?? NSScreen.main)?.visibleFrame ?? note.frame
        let anchor: NSPoint
        if !isVisible, let saved {
            anchor = saved
        } else if saved != nil, !frame.isEmpty {
            anchor = NSPoint(x: frame.minX, y: frame.maxY)
        } else {
            anchor = Self.defaultTopLeft(size: size, placement: placement, in: screen)
        }
        var target = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        let offscreen = !NSScreen.screens.contains { $0.frame.intersects(target) }
        if offscreen {
            target.origin.x = min(max(target.minX, screen.minX), max(screen.minX, screen.maxX - target.width))
            target.origin.y = min(max(target.minY, screen.minY), max(screen.minY, screen.maxY - target.height))
        }
        if target != frame { setFrame(target, display: true) }
        if saved == nil || offscreen { savePosition() }
        if parent !== note {
            parent?.removeChildWindow(self)
            note.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFront(nil) }
    }

    /// Top-left of a `size` window at `placement` along the bottom of `screen` (a visible frame).
    static func defaultTopLeft(size: NSSize, placement: WritingPanelPlacement, in screen: NSRect) -> NSPoint {
        let inset = WritingLayout.panelMargin - padding
        let x: CGFloat = switch placement {
        case .left: screen.minX + inset
        case .middle: screen.midX - size.width / 2
        case .right: screen.maxX - inset - size.width
        }
        return NSPoint(x: x, y: screen.minY + WritingLayout.panelBottomInset - padding + size.height)
    }

    /// Save deliberate placement, so temporary note movement during summon cannot overwrite it.
    func savePosition() {
        defaults.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.positionKey)
        defaults.set(placement.rawValue, forKey: Self.placementKey)
    }

    func hide() {
        guard isVisible || parent != nil else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// The writing panel window's content: a clear margin around the panel and pill, with a grip at
/// the top. A press on the panel is the pen, forwarded to the note's canvas; anywhere else drags
/// the window. Bottom-anchored, so the panel keeps its place as the pill comes and goes.
final class WritingPanelContentView: NSView {
    /// The note's canvas, which receives the panel's pen input.
    weak var canvasView: CanvasView?
    weak var panel: WritingPanelView?
    private(set) var modeHintView: NSView?
    var modeHintSpace: CGFloat { modeHintView.map { $0.fittingSize.height + 6 } ?? 0 }
    /// A press that began on the panel: its drag and release go to the canvas too.
    private var isForwardingPress = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setModeHintView(_ view: NSView?) {
        guard modeHintView !== view else { panel?.layoutInSuperview(); return }
        modeHintView?.removeFromSuperview()
        modeHintView = view
        if let view { addSubview(view) }
        panel?.layoutInSuperview()
    }

    func layoutModeHint() {
        guard let modeHintView else { return }
        let size = modeHintView.fittingSize
        modeHintView.frame = CGRect(x: (bounds.width - size.width) / 2,
                                    y: WritingPanelWindow.padding + max(0, (modeHintSpace - size.height) / 2),
                                    width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let grip = CGRect(x: bounds.midX - 18, y: bounds.maxY - WritingPanelWindow.padding / 2 - 2, width: 36, height: 4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if let panel, let canvasView, panel.frame.contains(convert(event.locationInWindow, from: nil)),
           let note = noteEvent(event) {
            isForwardingPress = true
            canvasView.mouseDown(with: note)
        } else {
            window?.performDrag(with: event)
            (window as? WritingPanelWindow)?.savePosition()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isForwardingPress, let note = noteEvent(event) else { return }
        canvasView?.mouseDragged(with: note)
    }

    override func mouseUp(with event: NSEvent) {
        guard isForwardingPress else { return }
        isForwardingPress = false
        if let note = noteEvent(event) { canvasView?.mouseUp(with: note) }
    }

    /// `event` re-addressed to the note's window, where the canvas reads its location.
    private func noteEvent(_ event: NSEvent) -> NSEvent? {
        guard let own = window, let note = canvasView?.window else { return nil }
        let location = note.convertPoint(fromScreen: own.convertPoint(toScreen: event.locationInWindow))
        return NSEvent.mouseEvent(with: event.type, location: location, modifierFlags: event.modifierFlags,
                                  timestamp: event.timestamp, windowNumber: note.windowNumber, context: nil,
                                  eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
    }
}
