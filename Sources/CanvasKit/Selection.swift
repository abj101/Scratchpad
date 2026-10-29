import Foundation

// MARK: - Selection (Phase 4 contract)
//
// Pointer-tool selection, independent of AppKit: the view converts mouse
// events to world points and forwards them here; the view renders `selection`,
// `marqueeRect` and the live `moveOffset`. Model edits happen only on commit,
// each as one undo step.

public final class SelectionController {
    public enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        /// Edge midpoints stretch along one axis only.
        case top, bottom, left, right
    }

    public enum Drag: Equatable {
        case idle
        /// Dragging the selection; `offset` is the live, uncommitted translation.
        case moving(start: CGPoint, offset: CGVector)
        /// Rubber-band selection. `base` is the selection to extend (Shift) or empty.
        case marquee(start: CGPoint, rect: CGRect, base: Set<UUID>)
        /// Resizing the selection from a corner; `original` is the selection bounds at drag start,
        /// `rect` is the live, uncommitted result.
        case resizing(corner: Corner, original: CGRect, rect: CGRect)
    }

    public let model: CanvasModel
    /// Document layout exposes only ink to pointer selection.
    private let includesTextBlocks: Bool
    public private(set) var selection: Set<UUID> = []
    public private(set) var drag: Drag = .idle

    /// Called with the dirty world rect whenever selection, marquee or the live
    /// move offset changes (old ∪ new extents, before padding for handles).
    public var onChange: ((CGRect) -> Void)?

    /// Optional hook to expand a single hit ID to a set (e.g., a stroke to its drawing zone).
    /// Used in pointerDown when a single object is hit and no extend modifier is held.
    public var expandHit: ((UUID) -> Set<UUID>)?

    public init(model: CanvasModel, includesTextBlocks: Bool = true) {
        self.model = model
        self.includesTextBlocks = includesTextBlocks
    }

    private var selectableIDs: Set<UUID> {
        includesTextBlocks ? model.allIDs : Set(model.strokes.map(\.id))
    }

    private func hitObject(at point: CGPoint, radius: Double) -> UUID? {
        if includesTextBlocks { return model.hitObject(at: point, radius: radius) }
        return model.strokes.last { $0.hitTest(point, radius: radius) }?.id
    }

    private func objects(in rect: CGRect) -> Set<UUID> {
        model.objects(in: rect).intersection(selectableIDs)
    }

    /// Live translation while moving, else `.zero`.
    public var moveOffset: CGVector {
        if case .moving(_, let offset) = drag { return offset }
        return .zero
    }

    /// Live marquee rect, else nil.
    public var marqueeRect: CGRect? {
        if case .marquee(_, let rect, _) = drag { return rect }
        return nil
    }

    /// Live resize rect (original and current) while resizing, else nil.
    public var liveResize: (original: CGRect, rect: CGRect)? {
        if case .resizing(_, let original, let rect) = drag { return (original, rect) }
        return nil
    }

    /// `model.bounds(of: selection)`; `.null` when empty.
    public var selectionBounds: CGRect { model.bounds(of: selection) }

    /// True when the selection is non-empty and contains only strokes (no text blocks).
    public var canResize: Bool {
        guard !selection.isEmpty else { return false }
        for id in selection {
            if model.textBlocks.contains(where: { $0.id == id }) { return false }
        }
        return true
    }

    // MARK: Extents

    /// Everything the view draws for the current state, in world space.
    private var extent: CGRect {
        var rect = selectionBounds
        if !rect.isNull { rect = rect.offsetBy(dx: moveOffset.dx, dy: moveOffset.dy) }
        if let marquee = marqueeRect { rect = rect.union(marquee) }
        if let (original, live) = liveResize { rect = rect.union(original).union(live) }
        return rect
    }

    /// Last extent reported to the view. Selected objects may already be gone from
    /// the model (deleted, undone), so the current extent alone can miss stale outlines.
    private var reportedExtent: CGRect = .null

    /// Run `body`, then report old ∪ new extents.
    private func mutate(_ body: () -> Void) {
        let before = reportedExtent.union(extent)
        body()
        reportedExtent = extent
        let dirty = before.union(reportedExtent)
        if !dirty.isNull { onChange?(dirty) }
    }

    // MARK: Pointer gestures (world coordinates)

    /// Hit-test a corner of `selectionBounds` when `canResize`. Returns the corner if
    /// within `radius`, else nil.
    public func corner(at p: CGPoint, radius: Double) -> Corner? {
        guard canResize else { return nil }
        let bounds = selectionBounds
        let corners: [(Corner, CGPoint)] = [
            (.topLeft, CGPoint(x: bounds.minX, y: bounds.minY)),
            (.topRight, CGPoint(x: bounds.maxX, y: bounds.minY)),
            (.bottomLeft, CGPoint(x: bounds.minX, y: bounds.maxY)),
            (.bottomRight, CGPoint(x: bounds.maxX, y: bounds.maxY)),
            (.top, CGPoint(x: bounds.midX, y: bounds.minY)),
            (.bottom, CGPoint(x: bounds.midX, y: bounds.maxY)),
            (.left, CGPoint(x: bounds.minX, y: bounds.midY)),
            (.right, CGPoint(x: bounds.maxX, y: bounds.midY))
        ]
        for (corner, pt) in corners {
            if hypot(p.x - pt.x, p.y - pt.y) <= radius {
                return corner
            }
        }
        return nil
    }

    /// Hit an object:
    /// - `extend` (Shift): toggle it in the selection; if it is now selected, start moving.
    /// - otherwise: if not already selected, select only it (expanding through expandHit hook if set); start moving the selection.
    /// Hit nothing inside the selection bounds (padded by `hitRadius`), without
    /// `extend`: start moving the selection.
    /// Hit nothing elsewhere: start a marquee; without `extend`, clear the selection first.
    /// A corner hit (when `canResize` and not `extend`) starts resizing.
    public func pointerDown(at p: CGPoint, extend: Bool, hitRadius: Double) {
        mutate {
            // Check for corner hit first (only if canResize and not extend)
            if !extend, let cornerHit = corner(at: p, radius: hitRadius) {
                let original = selectionBounds
                drag = .resizing(corner: cornerHit, original: original, rect: original)
                return
            }

            if let id = hitObject(at: p, radius: hitRadius) {
                if extend {
                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                } else if !selection.contains(id) {
                    // Expand hit through hook if set (e.g., to select entire zone)
                    let ids = expandHit?(id) ?? [id]
                    selection = ids
                }
                drag = selection.contains(id) ? .moving(start: p, offset: .zero) : .idle
            } else if !extend, selectionBounds.insetBy(dx: -hitRadius, dy: -hitRadius).contains(p) {
                // Inside the selection's box but between objects: still a move.
                drag = .moving(start: p, offset: .zero)
            } else {
                if !extend { selection = [] }
                drag = .marquee(start: p, rect: CGRect(origin: p, size: .zero), base: selection)
            }
        }
    }

    /// Moving: offset = p − start. Marquee: rect spans start…p and
    /// selection = base ∪ model.objects(in: rect), updated live.
    /// Resizing: compute live rect with opposite corner fixed and aspect ratio locked.
    public func pointerDragged(to p: CGPoint) {
        switch drag {
        case .idle:
            break
        case .moving(let start, _):
            mutate { drag = .moving(start: start, offset: CGVector(dx: p.x - start.x, dy: p.y - start.y)) }
        case .marquee(let start, _, let base):
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
            mutate {
                drag = .marquee(start: start, rect: rect, base: base)
                selection = base.union(objects(in: rect))
            }
        case .resizing(let corner, let original, _):
            mutate {
                let newRect = computeResizeRect(corner: corner, original: original, pointer: p)
                drag = .resizing(corner: corner, original: original, rect: newRect)
            }
        }
    }

    /// Compute the live rect during a corner drag, with the opposite corner fixed
    /// and aspect ratio locked. Enforce a minimum size of 8 pt on the shorter side.
    private func computeResizeRect(corner: Corner, original: CGRect, pointer: CGPoint) -> CGRect {
        let originalWidth = original.width
        let originalHeight = original.height

        // Edge handles stretch one axis; the opposite edge stays put.
        let minEdge: Double = 8
        var edge = original
        switch corner {
        case .top: edge.origin.y = min(pointer.y, original.maxY - minEdge); edge.size.height = original.maxY - edge.origin.y
        case .bottom: edge.size.height = max(pointer.y - original.minY, minEdge)
        case .left: edge.origin.x = min(pointer.x, original.maxX - minEdge); edge.size.width = original.maxX - edge.origin.x
        case .right: edge.size.width = max(pointer.x - original.minX, minEdge)
        default: break
        }
        if [.top, .bottom, .left, .right].contains(corner) { return edge }

        // Determine the fixed opposite corner
        let fixedPoint: CGPoint
        switch corner {
        case .topLeft:
            fixedPoint = CGPoint(x: original.maxX, y: original.maxY)
        case .topRight:
            fixedPoint = CGPoint(x: original.minX, y: original.maxY)
        case .bottomLeft:
            fixedPoint = CGPoint(x: original.maxX, y: original.minY)
        default:
            fixedPoint = CGPoint(x: original.minX, y: original.minY)
        }

        // Compute dx and dy from the fixed point
        let dx = pointer.x - fixedPoint.x
        let dy = pointer.y - fixedPoint.y

        // Determine scale factors
        let scaleX = dx / originalWidth
        let scaleY = dy / originalHeight

        // Take the larger scale factor to maintain aspect ratio
        let scale = max(scaleX, scaleY)

        // Compute new dimensions
        var newWidth = originalWidth * abs(scale)
        var newHeight = originalHeight * abs(scale)

        // Enforce minimum size of 8 pt on the shorter side
        let minDim: Double = 8
        if newWidth < minDim || newHeight < minDim {
            let targetScale = minDim / min(originalWidth, originalHeight)
            newWidth = originalWidth * targetScale
            newHeight = originalHeight * targetScale
        }

        // Compute new origin based on the corner being dragged
        var newOrigin = fixedPoint
        switch corner {
        case .topLeft:
            newOrigin.x -= newWidth
            newOrigin.y -= newHeight
        case .topRight:
            newOrigin.y -= newHeight
        case .bottomLeft:
            newOrigin.x -= newWidth
        default:
            break // Origin stays at fixed point
        }

        return CGRect(x: newOrigin.x, y: newOrigin.y, width: newWidth, height: newHeight)
    }

    /// Moving: commit `model.translate(selection, offset)` if offset is non-zero.
    /// Marquee: keep the live selection. Then idle.
    /// Resizing: commit `model.scale(ids:from:to:)` if the rect changed.
    public func pointerUp(at p: CGPoint) {
        let offset = moveOffset
        let liveResize = self.liveResize
        mutate {
            drag = .idle
            if offset.dx != 0 || offset.dy != 0 { model.translate(ids: selection, by: offset) }
            if let (original, rect) = liveResize, original != rect {
                model.scale(ids: selection, from: original, to: rect)
            }
        }
    }

    /// Abort a drag with no model change. A cancelled marquee restores `base`.
    /// A cancelled resize aborts without committing.
    public func cancelDrag() {
        mutate {
            if case .marquee(_, _, let base) = drag { selection = base }
            drag = .idle
        }
    }

    // MARK: Commands

    /// Replace the selection (ids not in the model are dropped).
    public func select(_ ids: Set<UUID>) {
        mutate { selection = ids.intersection(selectableIDs) }
    }

    public func selectAll() { select(model.allIDs) }
    public func clear() { select([]) }

    /// One "Delete" undo step; selection becomes empty.
    public func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        mutate {
            drag = .idle
            model.delete(ids: ids)
            selection = []
        }
    }

    /// One "Move" undo step; selection kept.
    public func nudge(by delta: CGVector) {
        mutate { model.translate(ids: selection, by: delta) }
    }

    public func bringToFront() { mutate { model.bringToFront(ids: selection) } }
    public func sendToBack() { mutate { model.sendToBack(ids: selection) } }

    /// Drop ids no longer in the model (call after undo/redo or erasing).
    /// Reports a change only if something was dropped.
    public func pruneMissing() {
        let kept = selection.intersection(selectableIDs)
        guard kept != selection else { return }
        mutate { selection = kept }
    }
}
