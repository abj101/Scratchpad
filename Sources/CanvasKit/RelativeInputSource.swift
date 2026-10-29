import AppKit

/// Pen mode: the cursor moves normally; while the pen is down, pointer motion draws.
///
/// `CanvasView` converts mouseMoved/mouseDragged to world points and calls
/// `pointerMoved`. `.down` only arms the pen at `pointerLocation()`: the stroke
/// begins there once the pointer moves, so a key press alone never leaves a dot.
public final class RelativeInputSource: PenInputSource {
    public weak var sink: PenEventSink?
    public private(set) var isDrawing = false
    public private(set) var isPenDown = false

    /// Current cursor position in world coordinates, or nil if unknown/outside
    /// the canvas. `activate(in:)` installs a provider reading the view's mouse
    /// location; tests may set it directly.
    public var pointerLocation: () -> CGPoint? = { nil }

    public init() {}

    private var lastPoint: CGPoint = .zero
    /// Where the pen went down, until the pointer moves away from it.
    private var armedAt: CGPoint?
    /// World distance the pointer must move before an armed pen starts a stroke.
    static let armDistance: CGFloat = 0.25

    // MARK: Lifecycle

    public func activate(in view: CanvasView) {
        pointerLocation = { [weak view] in
            guard let view, let window = view.window else { return nil }
            let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard view.visibleRect.contains(p) else { return nil }
            return view.viewToWorld(p)
        }
    }

    public func deactivate() {
        cancelStroke(timestamp: ProcessInfo.processInfo.systemUptime)
        isPenDown = false
        pointerLocation = { nil }
    }

    // MARK: Pen

    public func penChanged(_ transition: PenTransition, timestamp: TimeInterval) {
        switch transition {
        case .down:
            isPenDown = true
            if !isDrawing { armedAt = pointerLocation() }
        case .up:
            if isDrawing { finish(.ended, timestamp: timestamp) }
            isPenDown = false
            armedAt = nil
        case .cancelled:
            if isDrawing { finish(.cancelled, timestamp: timestamp) }
            isPenDown = false
            armedAt = nil
        }
    }

    /// Emits `.cancelled` if drawing. The pen stays down, so further motion
    /// starts a fresh stroke.
    public func cancelStroke(timestamp: TimeInterval) {
        if isDrawing { finish(.cancelled, timestamp: timestamp) }
    }

    /// Pointer moved to `world`. Emits `.moved` while drawing. An armed pen
    /// begins at its arming point once the pointer leaves it; with no arming
    /// point (location unknown at `.down`), the stroke begins here.
    public func pointerMoved(to world: CGPoint, timestamp: TimeInterval) {
        guard isPenDown else { return }
        if isDrawing {
            lastPoint = world
            sink?.handle(PenEvent(phase: .moved, point: world, timestamp: timestamp))
        } else if let start = armedAt {
            guard hypot(world.x - start.x, world.y - start.y) > Self.armDistance else { return }
            armedAt = nil
            begin(at: start, timestamp: timestamp)
            lastPoint = world
            sink?.handle(PenEvent(phase: .moved, point: world, timestamp: timestamp))
        } else {
            begin(at: world, timestamp: timestamp)
        }
    }

    // MARK: Emit

    private func begin(at p: CGPoint, timestamp: TimeInterval) {
        lastPoint = p
        isDrawing = true
        sink?.handle(PenEvent(phase: .began, point: p, timestamp: timestamp))
    }

    private func finish(_ phase: PenPhase, timestamp: TimeInterval) {
        isDrawing = false
        sink?.handle(PenEvent(phase: phase, point: lastPoint, timestamp: timestamp))
    }
}
