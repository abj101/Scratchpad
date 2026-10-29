import AppKit

/// Tablet mode: the whole trackpad maps to the visible canvas region.
///
/// Pure core (`touchesChanged`, `penChanged`) is unit-testable with
/// `TouchSample`s; `activate(in:)` wires touches and the cursor lock.
///
/// Rules:
/// - The first touching finger is tracked by identity.
/// - Finger down while the pen is down → `.began`; pen goes down while the finger
///   is down → `.began` at the hover point.
/// - Finger lift → `.ended`, even if the pen key is still down.
/// - A different finger landing never connects to the previous stroke.
/// - Two or more touches with the pen up → `.cancelled`; drawing is suspended
///   until all fingers lift (two-finger navigation).
/// - A finger landing in one of `buttonZones` never draws; a quick tap there (lifted
///   soon, barely moved) calls `onZoneTap` with the zone's index.
/// - With the pen down, extra contacts (a thumb or palm brushing the pad while
///   a key is pressed) are ignored: the tracked finger keeps drawing, or the
///   highest contact takes over (palms rest low on the pad).
public final class TabletInputSource: PenInputSource {
    public weak var sink: PenEventSink?
    public private(set) var isDrawing = false
    public private(set) var isPenDown = false

    /// Updated by `CanvasView` whenever the viewport scrolls, zooms or resizes.
    /// Device aspect is updated from incoming touch samples.
    public var mapping: TabletMapping
    /// Mapped world point of the tracked finger, nil when no single finger is down.
    public private(set) var hoverPoint: CGPoint?
    /// True while 2+ fingers are (or were, until all lift) on the trackpad.
    public private(set) var isSuspended = false
    /// Called when hoverPoint / isSuspended / isDrawing change (overlay redraw).
    public var onStateChange: (() -> Void)?
    /// Normalized trackpad rects (origin bottom-left) reserved as buttons.
    public var buttonZones: [CGRect] = []
    /// Called with the index of the zone tapped.
    public var onZoneTap: ((Int) -> Void)?
    static let toggleTapDuration: TimeInterval = 0.4
    static let toggleTapTravel: CGFloat = 0.04

    public init(mapping: TabletMapping) {
        self.mapping = mapping
    }

    private weak var view: CanvasView?
    private var trackedID: AnyHashable?
    /// Latest contacts, so pressing the pen key can re-evaluate a suspension.
    private var lastTouching: [TouchSample] = []
    /// Set when the pen goes down under a finger that is already resting on the
    /// pad: the stroke starts only once that finger actually moves, so toggling
    /// the pen never stamps a dot at the resting position.
    private var armedAt: CGPoint?
    private static let armDistance: CGFloat = 0.015
    /// The tracked finger landed in a button zone: which, where and when, until it lifts.
    private var zoneTouch: (zone: Int, start: CGPoint, time: TimeInterval)?
    private var lastFinger: CGPoint?

    // MARK: Lifecycle

    public func activate(in view: CanvasView) {
        self.view = view
        reset()
    }

    public func deactivate() {
        cancelStroke(timestamp: ProcessInfo.processInfo.systemUptime)
        view = nil
        notifying { reset(); isPenDown = false }
    }

    private func reset() {
        lastTouching = []
        trackedID = nil
        hoverPoint = nil
        isSuspended = false
        armedAt = nil
        zoneTouch = nil
        lastFinger = nil
    }

    // MARK: Pen

    public func penChanged(_ transition: PenTransition, timestamp: TimeInterval) {
        notifying {
            switch transition {
            case .down:
                isPenDown = true
                if isSuspended, !lastTouching.isEmpty {
                    // Pen intent beats a stale multi-touch suspension.
                    isSuspended = false
                    trackedID = nil
                    process(lastTouching, timestamp, arming: true)
                } else if hoverPoint != nil, !isSuspended, !isDrawing, zoneTouch == nil {
                    armedAt = lastTouching.first { $0.id == trackedID }?.normalized
                }
            case .up:
                isPenDown = false
                armedAt = nil
                if isDrawing { finish(.ended, timestamp) }
            case .cancelled:
                isPenDown = false
                armedAt = nil
                if isDrawing { finish(.cancelled, timestamp) }
            }
        }
    }

    public func cancelStroke(timestamp: TimeInterval) {
        notifying { if isDrawing { finish(.cancelled, timestamp) } }
    }

    // MARK: Touches

    /// All currently touching fingers (empty when all lifted).
    public func touchesChanged(_ touching: [TouchSample], timestamp: TimeInterval) {
        notifying { process(touching, timestamp) }
    }

    private func process(_ allTouching: [TouchSample], _ timestamp: TimeInterval, arming: Bool = false) {
        lastTouching = allTouching
        for t in allTouching { mapping.setDeviceSize(t.deviceSize) }
        var touching = allTouching
        if touching.count > 1, isPenDown {
            let keep = touching.first { $0.id == trackedID } ?? touching.max { $0.normalized.y < $1.normalized.y }!
            touching = [keep]
            isSuspended = false
        }
        switch touching.count {
        case 0:
            if isDrawing { finish(.ended, timestamp) }
            let tapped = zoneTouch.flatMap { touch -> Int? in
                guard let last = lastFinger, timestamp - touch.time <= Self.toggleTapDuration,
                      hypot(last.x - touch.start.x, last.y - touch.start.y) <= Self.toggleTapTravel else { return nil }
                return touch.zone
            }
            reset()
            if let tapped { onZoneTap?(tapped) }
        case 1:
            guard !isSuspended else { return }
            let finger = touching[0]
            let p = mapping.worldPoint(normalized: finger.normalized)
            if trackedID == finger.id {
                hoverPoint = p
                lastFinger = finger.normalized
                if zoneTouch != nil { return }
                if isDrawing {
                    emit(.moved, p, timestamp)
                } else if let a = armedAt, isPenDown {
                    let dx = finger.normalized.x - a.x, dy = finger.normalized.y - a.y
                    if (dx * dx + dy * dy).squareRoot() > Self.armDistance {
                        armedAt = nil
                        begin(at: p, timestamp)
                    }
                }
            } else {
                if isDrawing { finish(.ended, timestamp) }
                trackedID = finger.id
                hoverPoint = p
                lastFinger = finger.normalized
                armedAt = nil
                zoneTouch = nil
                if let zone = buttonZones.firstIndex(where: { $0.insetBy(dx: -0.001, dy: -0.001).contains(finger.normalized) }) {
                    zoneTouch = (zone, finger.normalized, timestamp)
                } else if isPenDown {
                    if arming { armedAt = finger.normalized } else { begin(at: p, timestamp) }
                }
            }
        default:
            if isDrawing { finish(.cancelled, timestamp) }
            isSuspended = true
            trackedID = nil
            hoverPoint = nil
            zoneTouch = nil
        }
    }

    // MARK: Emission

    private func begin(at p: CGPoint, _ t: TimeInterval) {
        isDrawing = true
        emit(.began, p, t)
    }

    private func finish(_ phase: PenPhase, _ t: TimeInterval) {
        isDrawing = false
        emit(phase, hoverPoint ?? .zero, t)
    }

    private func emit(_ phase: PenPhase, _ p: CGPoint, _ t: TimeInterval) {
        sink?.handle(PenEvent(phase: phase, point: p, timestamp: t))
    }

    /// Runs `body`, then fires `onStateChange` if anything the overlay shows changed.
    private func notifying(_ body: () -> Void) {
        let before = (hoverPoint, isSuspended, isDrawing, mapping)
        body()
        if before.0 != hoverPoint || before.1 != isSuspended || before.2 != isDrawing || before.3 != mapping {
            onStateChange?()
        }
    }
}
