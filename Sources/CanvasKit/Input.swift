import AppKit

// MARK: - Device-independent pen input
//
// Every input source (mouse drag now; relative-pen and trackpad-tablet modes in
// Phase 2) converts its own coordinates to world space and emits PenEvents.
// Nothing downstream knows where the input came from.

public enum PenPhase {
    case began, moved, ended, cancelled
}

public struct PenEvent {
    public var phase: PenPhase
    /// World coordinates.
    public var point: CGPoint
    /// Seconds (NSEvent.timestamp clock).
    public var timestamp: TimeInterval

    public init(phase: PenPhase, point: CGPoint, timestamp: TimeInterval) {
        self.phase = phase; self.point = point; self.timestamp = timestamp
    }
}

public protocol PenEventSink: AnyObject {
    func handle(_ event: PenEvent)
}

// MARK: - Tool controller

/// Turns PenEvents into model edits according to the current tool.
/// The view renders `liveStroke` on top of committed strokes and redraws the
/// world rects passed to `onLiveChange`.
public final class ToolController: PenEventSink {
    public let model: CanvasModel
    public let settings: CanvasSettings
    /// Temporary pen-key drawing while the document Text tool stays selected.
    public var toolOverride: Tool?

    public private(set) var liveStroke: Stroke?
    /// Dirty world rect for the in-progress stroke or eraser feedback.
    public var onLiveChange: ((CGRect) -> Void)?

    /// Always on in the app; tests turn it off to assert raw points.
    public var smoothingEnabled = true
    /// World units per on-screen point the user is watching while drawing.
    /// Read at `.began` and fixed for that stroke; smoothing runs in input space.
    public var inputScale: CGFloat = 1
    /// Multiplies `settings.width` for new strokes (read at `.began`). Write mode
    /// sets it to `inputScale`, so the pen width is what the user sees in the panel.
    public var widthScale: CGFloat = 1
    /// Short look-ahead past the live stroke's end (world coords). Render only.
    public private(set) var livePrediction: [CGPoint] = []

    private var modeler = StrokeModeler(params: Smoothing.modeler)
    private var origin = CGPoint.zero
    private var scale: CGFloat = 1
    private var lastInput = CGPoint.zero
    private var startTime: TimeInterval = 0
    /// When set, finished pen strokes go here instead of into the model (Write
    /// mode buffers a letter, then commits it in one undo step).
    public var strokeSink: ((Stroke) -> Void)?
    /// Ids hidden during the current erase gesture; render must skip these and
    /// draw their surviving pieces (`liveErasePieces`) in their place instead.
    public var pendingErase: Set<UUID> { Set(erasedBases.keys) }
    /// The parts of the touched strokes left after the current erase gesture.
    public var liveErasePieces: [Stroke] { erasedPieces.values.flatMap { $0 } }
    /// Original strokes touched this gesture, by id (so undo can restore them).
    private var erasedBases: [UUID: Stroke] = [:]
    /// Surviving pieces of each touched stroke, by original id (empty = gone).
    private var erasedPieces: [UUID: [Stroke]] = [:]
    /// Eraser disc radius in world units, taken from the pen width the user chose.
    private var eraserRadius: Double { max(settings.width / 2, 0.5) }

    public init(model: CanvasModel, settings: CanvasSettings) {
        self.model = model
        self.settings = settings
    }

    public func handle(_ event: PenEvent) {
        switch toolOverride ?? settings.tool {
        case .pen: handlePen(event)
        case .eraser: handleEraser(event)
        case .pointer: break
        }
    }

    // MARK: Pen

    private func handlePen(_ e: PenEvent) {
        switch e.phase {
        case .began:
            startTime = e.timestamp
            origin = e.point
            scale = inputScale > 0 ? inputScale : 1
            lastInput = .zero
            livePrediction = []
            var points: [StrokePoint] = []
            if smoothingEnabled {
                modeler = StrokeModeler(params: Smoothing.modeler)
                append(modeler.begin(.zero, t: e.timestamp), to: &points, force: true)
            } else {
                points = [StrokePoint(x: e.point.x, y: e.point.y, t: 0)]
            }
            liveStroke = Stroke(points: points, color: settings.color, width: settings.width * Double(widthScale > 0 ? widthScale : 1))
            invalidateLive(appended: points.count, previousPrediction: [])
        case .moved:
            guard liveStroke != nil else { return }
            let previous = livePrediction
            var added: [StrokePoint] = []
            if smoothingEnabled {
                append(modeler.update(input(e.point), t: e.timestamp), to: &added)
                livePrediction = modeler.predict().map { world($0.position) }
            } else {
                let pt = StrokePoint(x: e.point.x, y: e.point.y, t: e.timestamp - startTime)
                if isNovel(input(e.point)) { added = [pt]; lastInput = input(e.point) }
            }
            guard !added.isEmpty || !previous.isEmpty || !livePrediction.isEmpty else { return }
            liveStroke?.points.append(contentsOf: added)
            invalidateLive(appended: added.count, previousPrediction: previous)
        case .ended:
            guard var stroke = liveStroke else { return }
            if smoothingEnabled {
                var added: [StrokePoint] = []
                append(modeler.end(input(e.point), t: e.timestamp), to: &added)
                stroke.points.append(contentsOf: added)
            }
            finishLive(stroke)
            if let strokeSink { strokeSink(stroke) } else { model.add(stroke) }
        case .cancelled:
            guard let stroke = liveStroke else { return }
            finishLive(stroke)
        }
    }

    private func finishLive(_ stroke: Stroke) {
        let dirty = extent(of: livePrediction, width: stroke.width).union(stroke.bounds)
        liveStroke = nil
        livePrediction = []
        onLiveChange?(dirty)
    }

    /// Stroke-local input space: on-screen points relative to the stroke origin.
    private func input(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
    }

    private func world(_ q: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + q.x * scale, y: origin.y + q.y * scale)
    }

    /// Min-distance dedupe, measured in input units.
    private func isNovel(_ q: CGPoint) -> Bool {
        hypot(q.x - lastInput.x, q.y - lastInput.y) >= 0.25
    }

    /// Converts modeled points to stroke points, dropping near-duplicates.
    private func append(_ modeled: [ModeledPoint], to points: inout [StrokePoint], force: Bool = false) {
        for (i, m) in modeled.enumerated() where (force && i == 0) || isNovel(m.position) {
            let w = world(m.position)
            points.append(StrokePoint(x: w.x, y: w.y, t: m.time - startTime))
            lastInput = m.position
        }
    }

    private func extent(of points: [CGPoint], width: Double) -> CGRect {
        guard !points.isEmpty else { return .null }
        return Stroke(points: points.map { StrokePoint(x: $0.x, y: $0.y, t: 0) }, color: settings.color, width: width)
            .bounds.insetBy(dx: -width, dy: -width)
    }

    /// Invalidate the newly appended segments (a quad curve also touches the two
    /// points before them) plus the old and new prediction.
    private func invalidateLive(appended: Int, previousPrediction: [CGPoint]) {
        guard let s = liveStroke else { return }
        let tail = Stroke(points: Array(s.points.suffix(appended + 2)), color: s.color, width: s.width)
        let rect = tail.bounds.insetBy(dx: -s.width, dy: -s.width)
            .union(extent(of: previousPrediction, width: s.width))
            .union(extent(of: livePrediction, width: s.width))
        onLiveChange?(rect)
    }

    // MARK: Eraser (partial-stroke)
    //
    // The eraser is a disc the size of the chosen pen width. It removes only the
    // parts of strokes under it, splitting a stroke into the pieces that survive.
    // Touched originals are hidden immediately (`pendingErase`) and drawn as their
    // remaining pieces (`liveErasePieces`); the model is updated in a single
    // undoable step when the gesture ends.

    private func handleEraser(_ e: PenEvent) {
        switch e.phase {
        case .began, .moved:
            erase(at: e.point)
        case .ended:
            let rect = erasedRect()
            guard !erasedBases.isEmpty else { return }
            let ids = Set(erasedBases.keys)
            let pieces = erasedPieces
            clearErase()
            model.erase(ids: ids, keeping: pieces)
            if !rect.isNull { onLiveChange?(rect) }
        case .cancelled:
            let rect = erasedRect()
            clearErase()
            if !rect.isNull { onLiveChange?(rect) }
        }
    }

    private func clearErase() {
        erasedBases = [:]
        erasedPieces = [:]
    }

    /// World rect covering every stroke touched by the current gesture.
    private func erasedRect() -> CGRect {
        erasedBases.values.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    private func erase(at p: CGPoint) {
        let radius = eraserRadius
        var dirty = CGRect.null
        for stroke in model.strokes {
            let base = erasedBases[stroke.id] ?? stroke
            let current = erasedBases[stroke.id] != nil ? (erasedPieces[stroke.id] ?? []) : [stroke]
            guard !current.isEmpty else { continue }
            var next: [Stroke] = []
            var didErase = false
            for piece in current {
                guard piece.hitTest(p, radius: radius) else { next.append(piece); continue }
                let split = splitPiece(piece, erasingAt: p, radius: radius)
                if split.erased { didErase = true }
                next.append(contentsOf: split.pieces)
            }
            guard didErase else { continue }
            erasedBases[stroke.id] = base
            erasedPieces[stroke.id] = next
            dirty = dirty.union(base.bounds)
        }
        guard !dirty.isNull else { return }
        dirty = dirty.union(CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        onLiveChange?(dirty.insetBy(dx: -radius - 2, dy: -radius - 2))
    }

    /// Removes the points under the eraser disc and returns the surviving runs.
    /// `erased` is false (and the stroke comes back unchanged) when nothing fell
    /// inside, so a near-miss never splits a stroke.
    private func splitPiece(_ stroke: Stroke, erasingAt p: CGPoint, radius: Double) -> (pieces: [Stroke], erased: Bool) {
        let reach = radius + stroke.width / 2
        var runs: [[StrokePoint]] = []
        var run: [StrokePoint] = []
        var erased = false
        for point in stroke.points {
            if hypot(point.x - p.x, point.y - p.y) <= reach {
                erased = true
                if !run.isEmpty { runs.append(run); run = [] }
            } else {
                run.append(point)
            }
        }
        if !run.isEmpty { runs.append(run) }
        guard erased else { return ([stroke], false) }
        let pieces = runs.map { Stroke(points: $0, color: stroke.color, width: stroke.width) }
        return (pieces, true)
    }
}
