import AppKit

// MARK: - Basic value types

/// Layout used for a note. Missing layout values keep older notes on canvas.
public enum NoteLayout: String, Codable, Equatable {
    case document, canvas
}

/// Legacy: the text location ink followed before drawing zones. Still decoded
/// from old files; document notes migrate to `DrawingZone`s when they open.
public struct InkAnchor: Codable, Hashable {
    public enum Kind: String, Codable { case glyph, line, sketch }

    public var id: UUID
    public var strokeIDs: Set<UUID>
    public var kind: Kind
    public var charIndex: Int
    public var offset: CGVector

    public init(id: UUID = UUID(), strokeIDs: Set<UUID>, kind: Kind, charIndex: Int, offset: CGVector) {
        self.id = id
        self.strokeIDs = strokeIDs
        self.kind = kind
        self.charIndex = charIndex
        self.offset = offset
    }
}

/// A committed ink mutation that may require document anchors to be rebuilt.
enum InkMutation {
    case added([Stroke])
    case removed(Set<UUID>)
    case moved(Set<UUID>)
}

/// All canvas geometry is in *world* coordinates: points, y-down, (0,0) at the
/// note's initial center. Independent of zoom and of the view hierarchy.
public struct StrokePoint: Codable, Hashable {
    public var x: Double
    public var y: Double
    /// Seconds since stroke start.
    public var t: Double

    public init(x: Double, y: Double, t: Double) {
        self.x = x; self.y = y; self.t = t
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct RGBA: Codable, Hashable {
    public var r, g, b, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = RGBA(r: 0.1, g: 0.1, b: 0.1)
    public static let blue  = RGBA(r: 0.15, g: 0.35, b: 0.85)
    public static let red   = RGBA(r: 0.85, g: 0.2, b: 0.2)
    public static let green = RGBA(r: 0.15, g: 0.6, b: 0.3)
    public static let orange = RGBA(r: 0.95, g: 0.55, b: 0.1)
    public static let palette: [RGBA] = [.black, .blue, .red, .green, .orange]

    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var cgColor: CGColor { nsColor.cgColor }

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
}

// MARK: - Stroke

public struct Stroke: Codable, Identifiable, Hashable {
    public var id: UUID
    public var points: [StrokePoint] { didSet { cachedBounds = Self.computeBounds(points, width) } }
    public var color: RGBA
    public var width: Double { didSet { cachedBounds = Self.computeBounds(points, width) } }

    /// Derived from `points` and `width`; excluded from coding, equality and hashing.
    private var cachedBounds: CGRect

    public init(id: UUID = UUID(), points: [StrokePoint], color: RGBA, width: Double) {
        self.id = id; self.points = points; self.color = color; self.width = width
        cachedBounds = Self.computeBounds(points, width)
    }

    private enum CodingKeys: String, CodingKey { case id, points, color, width }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), points: try c.decode([StrokePoint].self, forKey: .points),
                  color: try c.decode(RGBA.self, forKey: .color), width: try c.decode(Double.self, forKey: .width))
    }

    public static func == (a: Stroke, b: Stroke) -> Bool {
        a.id == b.id && a.points == b.points && a.color == b.color && a.width == b.width
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(points); hasher.combine(color); hasher.combine(width)
    }

    /// Bounding box of the rendered stroke (includes half the line width plus a
    /// little slack for curve overshoot). Use for invalidation and culling. O(1).
    public var bounds: CGRect { cachedBounds }

    /// Offset every point in one assignment (one bounds recompute).
    mutating func translate(by delta: CGVector) {
        points = points.map { StrokePoint(x: $0.x + delta.dx, y: $0.y + delta.dy, t: $0.t) }
    }

    private static func computeBounds(_ points: [StrokePoint], _ width: Double) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = width / 2 + 2
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    /// Smoothed path: quadratic curves through segment midpoints.
    public var path: CGPath {
        let path = CGMutablePath()
        let pts = points.map(\.cgPoint)
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first) // round cap renders a dot
            return path
        }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// True if `p` is within `radius` of the stroke's centerline (+ half width).
    public func hitTest(_ p: CGPoint, radius: Double) -> Bool {
        let r = radius + width / 2
        guard bounds.insetBy(dx: -radius, dy: -radius).contains(p) else { return false }
        if points.count == 1 {
            return hypot(points[0].x - p.x, points[0].y - p.y) <= r
        }
        for i in 1..<points.count where Self.distance(p, points[i - 1].cgPoint, points[i].cgPoint) <= r {
            return true
        }
        return false
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Text block

/// A rich text object on the canvas. Contents are a keyed-archived
/// `NSAttributedString`: unlike RTF, the archive round-trips everything
/// NSTextView produces exactly (RTF drops list marker text, for one).
public struct TextBlock: Codable, Identifiable, Hashable {
    public var id: UUID
    /// World position of the top-left corner.
    public var origin: CGPoint
    /// Layout width in world points (user-resizable).
    public var width: Double
    /// Laid-out height in world points, written back by the view after layout.
    public var height: Double
    /// Archived attributed contents (see `content(from:)`).
    public var content: Data
    /// World points per text point: the block is laid out at `width / scale`
    /// with ordinary font sizes, then drawn `scale` times larger. Set when a
    /// block is created while zoomed out so its text appears at a readable size.
    public var scale: Double

    public static let defaultWidth: Double = 240
    public static let minWidth: Double = 40

    public init(id: UUID = UUID(), origin: CGPoint, width: Double = TextBlock.defaultWidth,
                height: Double = 0, content: Data = Data(), scale: Double = 1) {
        self.id = id; self.origin = origin; self.width = width; self.height = height; self.content = content
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey { case id, origin, width, height, content, scale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        origin = try c.decode(CGPoint.self, forKey: .origin)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        content = try c.decode(Data.self, forKey: .content)
        let s = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        scale = s.isFinite && s > 0 ? s : 1 // older notes have none
    }

    /// Text scale for a block created at `magnification`: 1 at 100% and
    /// above, larger when zoomed out so new text reads at its usual size.
    public static func scale(forMagnification m: Double) -> Double {
        m > 0 && m < 1 ? 1 / m : 1
    }

    public var bounds: CGRect {
        CGRect(x: origin.x, y: origin.y, width: width, height: max(height, 1))
    }

    /// Decoded contents (empty if `content` is empty or invalid).
    public var attributedString: NSAttributedString {
        guard !content.isEmpty,
              let string = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: Self.allowedArchiveClasses, from: content)
                as? NSAttributedString
        else { return NSAttributedString() }
        return string
    }

    /// User-facing text with editable equations represented by their source.
    public var plainText: String { attributedString.equationPlainText }

    public static func content(from string: NSAttributedString) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: string, requiringSecureCoding: true)) ?? Data()
    }

    private static let allowedArchiveClasses: [AnyClass] = [
        NSAttributedString.self, NSMutableAttributedString.self,
        NSTextAttachment.self, EquationAttachment.self,
        NSDictionary.self, NSMutableDictionary.self, NSArray.self, NSMutableArray.self,
        NSString.self, NSNumber.self, NSData.self, NSValue.self,
        NSFont.self, NSColor.self, NSImage.self,
        NSParagraphStyle.self, NSMutableParagraphStyle.self, NSTextTab.self, NSShadow.self
    ]
}

// MARK: - Canvas model

/// Owns the strokes of one note. Mutations register undo and report the
/// world-space rect that needs redrawing via `onChange`.
public final class CanvasModel {
    public private(set) var strokes: [Stroke] = []
    /// Nil on older notes; callers use `effectiveLayout` to treat those as canvas notes.
    @Published public var layout: NoteLayout?
    /// Legacy anchors from before drawing zones; read only to migrate old notes.
    public var inkAnchors: [InkAnchor]?
    /// Document-mode drawing zones. Nil on canvas notes and on document notes
    /// that predate zones (they are migrated when the document opens).
    public var drawingZones: [DrawingZone]?
    public var effectiveLayout: NoteLayout { layout ?? .canvas }
    public let undoManager: UndoManager

    /// Called with the dirty world rect after any mutation (including undo/redo).
    public var onChange: ((CGRect) -> Void)?
    /// Called with the ids of strokes whose geometry changed in place (moved),
    /// including on undo/redo, so the view can drop cached paths.
    public var onStrokesChange: ((Set<UUID>) -> Void)?
    /// Called after committed ink edits, including their undo and redo.
    var onInkMutation: ((InkMutation) -> Void)?

    public init(strokes: [Stroke] = [], textBlocks: [TextBlock] = [], layout: NoteLayout? = nil,
                inkAnchors: [InkAnchor]? = nil, drawingZones: [DrawingZone]? = nil,
                undoManager: UndoManager = UndoManager()) {
        self.strokes = strokes
        self.textBlocks = textBlocks
        self.layout = layout
        self.inkAnchors = inkAnchors
        self.drawingZones = drawingZones
        self.undoManager = undoManager
    }

    /// Replace a note's complete contents as one undoable edit.
    public func replaceContents(with snapshot: NoteModelSnapshot, actionName: String) {
        let old = NoteModelSnapshot(strokes: strokes, textBlocks: textBlocks, layout: layout, drawingZones: drawingZones)
        guard old != snapshot else { return }

        // Publish layout last: observers then see the matching content and anchors.
        strokes = snapshot.strokes
        textBlocks = snapshot.textBlocks
        inkAnchors = nil
        drawingZones = snapshot.drawingZones
        undoManager.registerUndo(withTarget: self) { $0.replaceContents(with: old, actionName: actionName) }
        undoManager.setActionName(actionName)
        layout = snapshot.layout

        let strokeIDs = Set(old.strokes.map(\.id)).union(strokes.map(\.id))
        let blockIDs = Set(old.textBlocks.map(\.id)).union(textBlocks.map(\.id))
        let dirty = Self.union(old.strokes).union(Self.union(strokes))
        if !strokeIDs.isEmpty {
            onStrokesChange?(strokeIDs)
            onChange?(dirty)
        }
        if !blockIDs.isEmpty { onTextBlocksChange?(blockIDs) }
    }

    /// Translate strokes without adding an undo step (used when text reflows).
    public func translateStrokes(_ moves: [UUID: CGVector]) {
        var dirty = CGRect.null
        var moved = Set<UUID>()
        for index in strokes.indices {
            guard let delta = moves[strokes[index].id], delta.dx != 0 || delta.dy != 0 else { continue }
            dirty = dirty.union(strokes[index].bounds)
            strokes[index].translate(by: delta)
            dirty = dirty.union(strokes[index].bounds)
            moved.insert(strokes[index].id)
        }
        guard !moved.isEmpty else { return }
        onStrokesChange?(moved)
        onChange?(dirty)
    }

    public func add(_ stroke: Stroke) {
        insert([(strokes.count, stroke)], actionName: "Draw")
    }

    public func remove(ids: Set<UUID>, actionName: String = "Erase") {
        let removed = strokes.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset, $0.element) }
        guard !removed.isEmpty else { return }
        strokes.removeAll { ids.contains($0.id) }
        undoManager.registerUndo(withTarget: self) { $0.insert(removed, actionName: actionName) }
        undoManager.setActionName(actionName)
        onChange?(Self.union(removed.map(\.1)))
        onInkMutation?(.removed(ids))
    }

    /// Partial erase: replaces each touched stroke with `pieces[id]` - the parts
    /// that survive - keeping the original's place in z-order. One undoable step.
    public func erase(ids: Set<UUID>, keeping pieces: [UUID: [Stroke]], actionName: String = "Erase") {
        guard strokes.contains(where: { ids.contains($0.id) }) else { return }
        let before = strokes
        var after: [Stroke] = []
        after.reserveCapacity(strokes.count)
        for stroke in strokes {
            if ids.contains(stroke.id) { after.append(contentsOf: pieces[stroke.id] ?? []) }
            else { after.append(stroke) }
        }
        strokes = after
        registerStrokeSnapshotUndo(before, actionName: actionName)
        let removed = before.filter { ids.contains($0.id) }
        let addedIds = Set(after.map(\.id)).subtracting(before.map(\.id))
        if !removed.isEmpty { onChange?(Self.union(removed)) }
        onInkMutation?(.removed(ids))
        if !addedIds.isEmpty { onInkMutation?(.added(after.filter { addedIds.contains($0.id) })) }
    }

    /// Undo/redo for `erase(ids:keeping:)` by swapping the whole stroke list,
    /// which keeps the survivors and the removed originals in their exact positions.
    private func registerStrokeSnapshotUndo(_ snapshot: [Stroke], actionName: String) {
        let previous = strokes
        undoManager.registerUndo(withTarget: self) { model in
            model.strokes = snapshot
            model.registerStrokeSnapshotUndo(previous, actionName: actionName)
            let removedIds = Set(previous.map(\.id)).subtracting(snapshot.map(\.id))
            let added = snapshot.filter { s in !previous.contains { $0.id == s.id } }
            let rect = Self.union(previous).union(Self.union(snapshot))
            if !rect.isNull { model.onChange?(rect) }
            if !removedIds.isEmpty { model.onInkMutation?(.removed(removedIds)) }
            if !added.isEmpty { model.onInkMutation?(.added(added)) }
        }
        undoManager.setActionName(actionName)
    }

    /// Re-insert strokes at their original indices (ascending order).
    private func insert(_ items: [(Int, Stroke)], actionName: String) {
        for (index, stroke) in items.sorted(by: { $0.0 < $1.0 }) {
            strokes.insert(stroke, at: min(index, strokes.count))
        }
        let ids = Set(items.map(\.1.id))
        undoManager.registerUndo(withTarget: self) { $0.remove(ids: ids, actionName: actionName) }
        undoManager.setActionName(actionName)
        onChange?(Self.union(items.map(\.1)))
        onInkMutation?(.added(items.map(\.1)))
    }

    public func strokes(intersecting rect: CGRect) -> [Stroke] {
        strokes.filter { $0.bounds.intersects(rect) }
    }

    /// Topmost-first ids of strokes under `p`.
    public func hitStrokes(at p: CGPoint, radius: Double) -> [UUID] {
        strokes.reversed().filter { $0.hitTest(p, radius: radius) }.map(\.id)
    }

    /// Union of all stroke and text block bounds, or nil if empty.
    public var contentBounds: CGRect? {
        let rect = textBlocks.reduce(Self.union(strokes)) { $0.union($1.bounds) }
        return rect.isNull ? nil : rect
    }

    // MARK: Text blocks
    //
    // Each mutation below is one undo step. Typing inside a block is not tracked
    // here: the editing view keeps its own fine-grained undo while editing and
    // commits the result as a single "Edit Text" step via `updateTextBlock`.

    public private(set) var textBlocks: [TextBlock] = []

    /// Called after any text block mutation (including undo/redo) with the ids
    /// that changed; the view reconciles its text subviews.
    public var onTextBlocksChange: ((Set<UUID>) -> Void)?

    public func textBlock(id: UUID) -> TextBlock? {
        textBlocks.first { $0.id == id }
    }

    public func addTextBlock(_ block: TextBlock, actionName: String = "Add Text") {
        insertTextBlock(block, at: textBlocks.count, actionName: actionName)
    }

    public func removeTextBlock(id: UUID, actionName: String = "Delete Text") {
        guard let index = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        let block = textBlocks.remove(at: index)
        undoManager.registerUndo(withTarget: self) { $0.insertTextBlock(block, at: index, actionName: actionName) }
        undoManager.setActionName(actionName)
        onTextBlocksChange?([id])
    }

    /// Replace a block with the same id. `actionName == nil` records no undo
    /// (use for derived data such as the laid-out height).
    public func updateTextBlock(_ block: TextBlock, actionName: String? = "Edit Text") {
        guard let index = textBlocks.firstIndex(where: { $0.id == block.id }) else { return }
        let old = textBlocks[index]
        guard old != block else { return }
        textBlocks[index] = block
        if let actionName {
            undoManager.registerUndo(withTarget: self) { $0.updateTextBlock(old, actionName: actionName) }
            undoManager.setActionName(actionName)
        }
        onTextBlocksChange?([block.id])
    }

    /// Add a block without an undo step (Scribe's provisional block).
    func addTextBlockSilently(_ block: TextBlock) {
        textBlocks.append(block)
        onTextBlocksChange?([block.id])
    }

    /// Remove a block without an undo step.
    func removeTextBlockSilently(id: UUID) {
        guard let index = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        textBlocks.remove(at: index)
        onTextBlocksChange?([id])
    }

    /// Topmost text block containing `p`.
    public func textBlock(at p: CGPoint) -> TextBlock? {
        textBlocks.last { $0.bounds.contains(p) }
    }

    private func insertTextBlock(_ block: TextBlock, at index: Int, actionName: String) {
        textBlocks.insert(block, at: min(index, textBlocks.count))
        undoManager.registerUndo(withTarget: self) { $0.removeTextBlock(id: block.id, actionName: actionName) }
        undoManager.setActionName(actionName)
        onTextBlocksChange?([block.id])
    }

    static func union(_ strokes: [Stroke]) -> CGRect {
        strokes.reduce(CGRect.null) { $0.union($1.bounds) }
    }
}

// MARK: - Canvas objects (Phase 4 contract)
//
// Strokes and text blocks share one id space (UUID). Z-order is per kind: ink
// renders below text, and within a kind later array entries draw on top.
// Every mutation below is exactly one undo step, reports dirty world rects via
// `onChange`, changed text ids via `onTextBlocksChange`, and stroke ids changed
// in place via `onStrokesChange`.

public extension CanvasModel {
    /// Ids of every stroke and text block.
    var allIDs: Set<UUID> { Set(strokes.map(\.id)).union(textBlocks.map(\.id)) }

    func contains(id: UUID) -> Bool {
        strokes.contains { $0.id == id } || textBlocks.contains { $0.id == id }
    }

    /// Topmost object under `p`: text blocks first (they render above ink,
    /// topmost = last), then strokes via `hitTest(_:radius:)`.
    func hitObject(at p: CGPoint, radius: Double) -> UUID? {
        if let block = textBlocks.last(where: { $0.bounds.contains(p) }) { return block.id }
        return strokes.last { $0.hitTest(p, radius: radius) }?.id
    }

    /// Marquee query: strokes with at least one point inside `rect` (a stroke
    /// whose segment crosses the rect also counts), text blocks whose bounds
    /// intersect `rect`.
    func objects(in rect: CGRect) -> Set<UUID> {
        let rect = rect.standardized
        var result = Set<UUID>()
        for stroke in strokes where Self.stroke(stroke, touches: rect) { result.insert(stroke.id) }
        for block in textBlocks where block.bounds.intersects(rect) { result.insert(block.id) }
        return result
    }

    /// Union of the bounds of the given objects; `.null` if none exist.
    func bounds(of ids: Set<UUID>) -> CGRect {
        var rect = CGRect.null
        for stroke in strokes where ids.contains(stroke.id) { rect = rect.union(stroke.bounds) }
        for block in textBlocks where ids.contains(block.id) { rect = rect.union(block.bounds) }
        return rect
    }

    /// Offset strokes (every point) and text blocks (origin). No-op (no undo)
    /// for a zero delta or no matching ids. Undo translates back.
    func translate(ids: Set<UUID>, by delta: CGVector, actionName: String = "Move") {
        guard delta.dx != 0 || delta.dy != 0 else { return }
        var movedStrokes = Set<UUID>()
        var dirty = CGRect.null
        for i in strokes.indices where ids.contains(strokes[i].id) {
            dirty = dirty.union(strokes[i].bounds)
            strokes[i].translate(by: delta)
            dirty = dirty.union(strokes[i].bounds)
            movedStrokes.insert(strokes[i].id)
        }
        var movedBlocks = Set<UUID>()
        for i in textBlocks.indices where ids.contains(textBlocks[i].id) {
            textBlocks[i].origin.x += delta.dx
            textBlocks[i].origin.y += delta.dy
            movedBlocks.insert(textBlocks[i].id)
        }
        guard !movedStrokes.isEmpty || !movedBlocks.isEmpty else { return }
        let moved = movedStrokes.union(movedBlocks)
        let inverse = CGVector(dx: -delta.dx, dy: -delta.dy)
        undoManager.registerUndo(withTarget: self) { $0.translate(ids: moved, by: inverse, actionName: actionName) }
        undoManager.setActionName(actionName)
        if !movedStrokes.isEmpty {
            onStrokesChange?(movedStrokes)
            onChange?(dirty)
            onInkMutation?(.moved(movedStrokes))
        }
        if !movedBlocks.isEmpty { onTextBlocksChange?(movedBlocks) }
    }

    /// Scale strokes affinely from `from` rect to `to` rect. Every point is mapped
    /// affinely: x' = to.minX + (x - from.minX) * sx, and the same for y.
    /// Width is multiplied by min(sx, sy) and clamped to `CanvasSettings.widthRange`.
    /// Ignores IDs that aren't strokes. No-op (no undo) for invalid rects (null,
    /// zero, or infinite dimensions). Undo restores the original strokes exactly.
    func scale(ids: Set<UUID>, from: CGRect, to: CGRect, actionName: String = "Resize") {
        guard !from.isNull, !to.isNull else { return }
        guard from.width.isFinite, from.height.isFinite, to.width.isFinite, to.height.isFinite else { return }
        // `size`, not `width`/`height`: those standardize a negative rect.
        guard from.size.width > 0, from.size.height > 0, to.size.width > 0, to.size.height > 0 else { return }

        let sx = to.width / from.width
        let sy = to.height / from.height
        let widthScale = min(sx, sy)

        let scaled: [Stroke] = strokes.filter { ids.contains($0.id) }.map { original in
            var stroke = original
            stroke.points = original.points.map {
                StrokePoint(x: to.minX + ($0.x - from.minX) * sx, y: to.minY + ($0.y - from.minY) * sy, t: $0.t)
            }
            stroke.width = min(max(original.width * widthScale, CanvasSettings.widthRange.lowerBound),
                               CanvasSettings.widthRange.upperBound)
            return stroke
        }
        replaceStrokes(scaled, actionName: actionName)
    }

    /// Swap in new versions of existing strokes (same ids) as one undo step;
    /// undo restores the exact originals, so rounding and width clamping never drift.
    func replaceStrokes(_ replacements: [Stroke], actionName: String) {
        var originals: [Stroke] = []
        var changed = Set<UUID>()
        var dirty = CGRect.null
        for replacement in replacements {
            guard let i = strokes.firstIndex(where: { $0.id == replacement.id }) else { continue }
            originals.append(strokes[i])
            dirty = dirty.union(strokes[i].bounds).union(replacement.bounds)
            strokes[i] = replacement
            changed.insert(replacement.id)
        }
        guard !changed.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { $0.replaceStrokes(originals, actionName: actionName) }
        undoManager.setActionName(actionName)
        onStrokesChange?(changed)
        onChange?(dirty)
        onInkMutation?(.moved(changed))
    }

    /// Remove strokes and text blocks together; undo restores both at their
    /// original indices (so z-order is preserved).
    func delete(ids: Set<UUID>, actionName: String = "Delete") {
        let removedStrokes = strokes.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset, $0.element) }
        let removedBlocks = textBlocks.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset, $0.element) }
        guard !removedStrokes.isEmpty || !removedBlocks.isEmpty else { return }
        strokes.removeAll { ids.contains($0.id) }
        textBlocks.removeAll { ids.contains($0.id) }
        undoManager.registerUndo(withTarget: self) {
            $0.restore(strokes: removedStrokes, textBlocks: removedBlocks, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        if !removedStrokes.isEmpty { onChange?(Self.union(removedStrokes.map(\.1))) }
        if !removedStrokes.isEmpty { onInkMutation?(.removed(Set(removedStrokes.map(\.1.id)))) }
        if !removedBlocks.isEmpty { onTextBlocksChange?(Set(removedBlocks.map(\.1.id))) }
    }

    /// Delete strokes and add a text block as one undo step (e.g. "Convert to Text").
    func replace(strokeIDs: Set<UUID>, with block: TextBlock, actionName: String) {
        undoManager.beginUndoGrouping()
        delete(ids: strokeIDs, actionName: actionName)
        addTextBlock(block, actionName: actionName)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Move the objects to the top of their kind's order, keeping their
    /// relative order. No-op (no undo) if already there.
    func bringToFront(ids: Set<UUID>) {
        reorder(ids: ids, toFront: true, actionName: "Bring to Front")
    }

    /// Move the objects to the bottom of their kind's order, keeping their
    /// relative order. No-op (no undo) if already there.
    func sendToBack(ids: Set<UUID>) {
        reorder(ids: ids, toFront: false, actionName: "Send to Back")
    }

    /// Append strokes and text blocks on top of everything (paste / duplicate),
    /// as one undo step. Ids must not already be in the model.
    func append(strokes newStrokes: [Stroke], textBlocks newBlocks: [TextBlock], actionName: String) {
        guard !newStrokes.isEmpty || !newBlocks.isEmpty else { return }
        let s = newStrokes.enumerated().map { (strokes.count + $0.offset, $0.element) }
        let b = newBlocks.enumerated().map { (textBlocks.count + $0.offset, $0.element) }
        restore(strokes: s, textBlocks: b, actionName: actionName)
    }

    // MARK: Helpers

    private func restore(strokes items: [(Int, Stroke)], textBlocks blocks: [(Int, TextBlock)], actionName: String) {
        for (index, stroke) in items.sorted(by: { $0.0 < $1.0 }) {
            strokes.insert(stroke, at: min(index, strokes.count))
        }
        for (index, block) in blocks.sorted(by: { $0.0 < $1.0 }) {
            textBlocks.insert(block, at: min(index, textBlocks.count))
        }
        let ids = Set(items.map(\.1.id)).union(blocks.map(\.1.id))
        undoManager.registerUndo(withTarget: self) { $0.delete(ids: ids, actionName: actionName) }
        undoManager.setActionName(actionName)
        if !items.isEmpty { onChange?(Self.union(items.map(\.1))) }
        if !items.isEmpty { onInkMutation?(.added(items.map(\.1))) }
        if !blocks.isEmpty { onTextBlocksChange?(Set(blocks.map(\.1.id))) }
    }

    private func reorder(ids: Set<UUID>, toFront: Bool, actionName: String) {
        func arranged<T: Identifiable>(_ items: [T]) -> [T] where T.ID == UUID {
            let picked = items.filter { ids.contains($0.id) }
            let rest = items.filter { !ids.contains($0.id) }
            return toFront ? rest + picked : picked + rest
        }
        let newStrokes = arranged(strokes), newBlocks = arranged(textBlocks)
        let strokesChanged = newStrokes.map(\.id) != strokes.map(\.id)
        let blocksChanged = newBlocks.map(\.id) != textBlocks.map(\.id)
        guard strokesChanged || blocksChanged else { return }
        applyOrder(strokes: strokesChanged ? newStrokes.map(\.id) : nil,
                   textBlocks: blocksChanged ? newBlocks.map(\.id) : nil, actionName: actionName)
    }

    /// Set the array order (by id) for either kind, registering the inverse.
    private func applyOrder(strokes strokeOrder: [UUID]?, textBlocks blockOrder: [UUID]?, actionName: String) {
        let oldStrokeOrder = strokeOrder == nil ? nil : strokes.map(\.id)
        let oldBlockOrder = blockOrder == nil ? nil : textBlocks.map(\.id)
        if let strokeOrder {
            let byID = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
            strokes = strokeOrder.compactMap { byID[$0] }
        }
        if let blockOrder {
            let byID = Dictionary(uniqueKeysWithValues: textBlocks.map { ($0.id, $0) })
            textBlocks = blockOrder.compactMap { byID[$0] }
        }
        undoManager.registerUndo(withTarget: self) {
            $0.applyOrder(strokes: oldStrokeOrder, textBlocks: oldBlockOrder, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        if strokeOrder != nil { onChange?(Self.union(strokes)) }
        if blockOrder != nil { onTextBlocksChange?(Set(textBlocks.map(\.id))) }
    }

    private static func stroke(_ stroke: Stroke, touches rect: CGRect) -> Bool {
        let b = stroke.bounds // cheap reject; also true for zero-size rects on the edge
        guard b.minX <= rect.maxX, b.maxX >= rect.minX, b.minY <= rect.maxY, b.maxY >= rect.minY else { return false }
        let pts = stroke.points.map(\.cgPoint)
        if pts.contains(where: { rect.contains($0) }) { return true }
        guard pts.count > 1 else { return false }
        for i in 1..<pts.count where segment(pts[i - 1], pts[i], intersects: rect) { return true }
        return false
    }

    /// Liang–Barsky clip of segment `a`–`b` against `rect`.
    private static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        var t0 = 0.0, t1 = 1.0
        let dx = b.x - a.x, dy = b.y - a.y
        let checks = [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)]
        for (p, q) in checks {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let r = q / p
                if p < 0 { if r > t1 { return false }; t0 = max(t0, r) }
                else { if r < t0 { return false }; t1 = min(t1, r) }
            }
        }
        return true
    }
}

// MARK: - Tool settings

public enum Tool: String, CaseIterable, Codable {
    case pointer, pen, eraser
}

/// Fixed pen smoothing, tuned once instead of exposed as a slider. Digital ink
/// apps filter input speed-adaptively: steady when moving slowly (hand jitter),
/// no lag when moving fast. `StrokeModeler` does this; the One-Euro constants
/// remain for the standalone `OneEuroFilter`.
public enum Smoothing {
    /// Parameters for the live stroke modeler (input units are on-screen points).
    public static let modeler = StrokeModelerParams.default
    /// Steadiness at low speed in Hz (lower = steadier, more lag).
    public static let minCutoff = 1.4
    /// How quickly the line catches up as speed rises (higher = less lag).
    public static let beta = 0.017
}

public enum FloatingToolMenu { case color, width }

public final class CanvasSettings: ObservableObject {
    public static let widthRange: ClosedRange<Double> = 0.5...100
    public static let fontSizeRange: ClosedRange<Double> = 8...72
    /// Font size for new text and equations; existing content keeps its formatting.
    @Published public var defaultFontSize: Double = Double(TextFormatting.bodySize) {
        didSet {
            let size = Self.canonicalFontSize(defaultFontSize)
            if defaultFontSize != size { defaultFontSize = size }
        }
    }
    public static func canonicalFontSize(_ size: Double) -> Double {
        size.isFinite ? min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound) : Double(TextFormatting.bodySize)
    }
    var defaultTextAttributes: [NSAttributedString.Key: Any] {
        TextFormatting.defaultAttributes(fontSize: CGFloat(Self.canonicalFontSize(defaultFontSize)))
    }
    /// Layout stamped onto new notes. Existing notes retain their own layout.
    @Published public var defaultLayout: NoteLayout = .document
    @Published public var tool: Tool = .pen
    @Published public var color: RGBA = .black
    public static let savedColorSlotCount = 5
    @Published public var savedColors: [RGBA?] = Array(repeating: nil, count: savedColorSlotCount)
    @Published public var backgroundColor = RGBA(r: 0.995, g: 0.995, b: 0.99)
    @Published public var width: Double = 2.5
    /// Pen width applied each time Scribe starts. Persisted.
    @Published public var scribeDefaultWidth: Double = 10.0
    /// Scribe keeps the current general pen width instead of applying
    /// `scribeDefaultWidth`. Persisted.
    @Published public var unifyScribeWidth: Bool = false
    /// Whether macOS Writing Tools are available in text editors. Off by default.
    @Published public var writingToolsEnabled: Bool = UserDefaults.standard.bool(forKey: "writingToolsEnabled") {
        didSet { UserDefaults.standard.set(writingToolsEnabled, forKey: "writingToolsEnabled") }
    }
    @Published public var eraserRadius: Double = 8
    @Published public var inputMode: InputMode = .pen
    /// Write mode: recognize handwriting into text (Scribe) instead of leaving raw ink. Persisted.
    @Published public var handwritingToText: Bool = InputMode.scribe.isAvailable
    /// Correct the last sentence with Foundation Models after Scribe phrases are added (on by default).
    @Published public var scribeSentencePolish: Bool = true
    /// Text options bar: shown on demand from the tool bar, or automatically while editing text.
    @Published public var isTextOptionsOpen = false { didSet { if isTextOptionsOpen { toolMenu = nil } } }
    @Published public var showTextOptionsWhileEditing = false
    /// Scribe's math input: handwriting stays ink, written like Write mode, instead of
    /// becoming text. Persisted.
    @Published public var scribeMath: Bool = false
    /// Math: an opening bracket also inserts its closer; writing continues inside until an arrow key. Persisted.
    @Published public var autoCloseBrackets: Bool = true
    /// Math: the writing zone (upper / middle / lower) sets exponent / subscript level. When off, a
    /// middle-zone glyph stays in the current script until the user exits with the arrows. Persisted.
    /// Scribe / math: a letter commits and the cell slides on after a pause. When off (paused),
    /// only the trackpad's top-left zone slides. Not persisted.
    @Published public var writingAutoAdvance: Bool = true
    /// True while the pen is down (pen key held or toggled on). Set by the canvas. Not persisted.
    @Published public var penIsDown = false
    @Published public var penKey: PenKey = .space
    @Published public var activation: PenActivation = .hold
    /// Where a new writing panel appears; choosing one moves the panel there. Persisted.
    @Published public var writingPanelPlacement: WritingPanelPlacement = .middle
    /// Write mode letter cell height in world points. Derived from the font size so
    /// handwritten letters render at the same size as text and equations; not a setting.
    public var writingLineHeight: Double { Self.canonicalFontSize(defaultFontSize) }
    /// Write mode haptic at each stroke start; nil is off. Not persisted.
    @Published public var touchHaptic: NSHapticFeedbackManager.FeedbackPattern? = .alignment
    /// Experimental "friction": a click every `frictionSpacing` of finger travel while
    /// drawing in Tablet/Write mode. Spacing is a fraction of the trackpad width. Not persisted.
    @Published public var frictionHaptic: NSHapticFeedbackManager.FeedbackPattern?
    /// Write mode: idle seconds after pen-up before the letter commits and the cell moves on. Not persisted.
    @Published public var letterCommitDelay: TimeInterval = WritingLayout.commitDelay
    /// Scribe: idle seconds after pen-up before the letter commits. Not persisted.
    @Published public var scribeLetterCommitDelay: TimeInterval = WritingLayout.scribeCommitDelay
    @Published public var frictionSpacing: Double = 0.02
    /// True while a text block is being edited (drives the formatting bar). Not persisted.
    @Published public var isEditingText = false
    /// Paragraph style at the caret of the text being edited, for the formatting bar's
    /// style label. Not persisted.
    @Published public var editingTextStyle: ParagraphStyleKind?
    /// Point size at the caret of the text being edited, for the formatting bar's size
    /// field. Not persisted.
    @Published public var editingFontSize: Double?
    /// Bold / italic / underline at the caret of the text being edited, for the
    /// formatting bar's toggles. Not persisted.
    @Published public var editingIsBold = false
    @Published public var editingIsItalic = false
    @Published public var editingIsUnderline = false
    /// Paragraph alignment at the caret of the text being edited, for the formatting
    /// bar's alignment toggles. Not persisted.
    @Published public var editingAlignment: NSTextAlignment = .natural
    /// Floating tool menu state. Not persisted.
    @Published public var toolMenu: FloatingToolMenu? { didSet { if toolMenu != nil { isTextOptionsOpen = false } } }
    /// Paragraph-style dropdown under the formatting bar. Not persisted.
    @Published public var isStyleMenuOpen = false
    public var isToolMenuPresented: Bool { toolMenu != nil }
    public func toggleToolMenu(_ menu: FloatingToolMenu) {
        toolMenu = toolMenu == menu ? nil : menu
    }
    /// True when Convert to Text applies (selected ink and a recognizer). Set by the canvas. Not persisted.
    @Published public var canConvertToText = false
    /// In-note Find bar state. Not persisted.
    public let find = FindModel()

    /// Full width range mapped into the fixed-size toolbar and menu previews.
    public var widthPreviewFraction: Double {
        let range = Self.widthRange
        return min(max((width - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    public func adjustWidthForScroll(delta: Double, precise: Bool) {
        adjustWidth(by: -delta * (precise ? 0.1 : 2.5))
    }

    public func adjustWidth(by delta: Double) {
        guard delta.isFinite else { return }
        width = min(max(width + delta, Self.widthRange.lowerBound), Self.widthRange.upperBound)
    }

    public init() {}

    /// The mode the canvas actually runs: the toolbar's single Write choice (`.write` or a
    /// persisted `.scribe`) becomes Scribe when handwriting-to-text is on and available.
    /// Math input turns Scribe back into Write.
    public var effectiveInputMode: InputMode {
        Self.effectiveMode(inputMode, handwritingToText: handwritingToText, math: scribeMath)
    }

    public static func effectiveMode(_ mode: InputMode, handwritingToText: Bool, math: Bool = false) -> InputMode {
        guard offersScribeZones(mode, handwritingToText: handwritingToText) else {
            return mode == .scribe ? .write : mode
        }
        return .scribe
    }

    /// Whether Scribe's trackpad zones (space, math) and math toggle apply.
    public var offersScribeZones: Bool { Self.offersScribeZones(inputMode, handwritingToText: handwritingToText) }

    public static func offersScribeZones(_ mode: InputMode, handwritingToText: Bool) -> Bool {
        (mode == .write || mode == .scribe) && handwritingToText && InputMode.scribe.isAvailable
    }

    /// Picking a tool leaves Writing mode, so the tool bar's four buttons read as
    /// one choice: the first three return to the pen and eraser, Writing enters Scribe.
    public func selectTool(_ newTool: Tool) {
        if inputMode.usesLetterCell { inputMode = .pen }
        tool = newTool
    }

    /// Pen and Eraser in the tool bar: choosing the active tool again returns to Select.
    public func toggleTool(_ newTool: Tool) {
        if inputMode.usesLetterCell {
            inputMode = .pen
            tool = newTool
        } else {
            tool = tool == newTool ? .pointer : newTool
        }
    }

    /// Writing mode's button and the 4 key. Leaving Writing mode just returns the
    /// tool to the selector.
    public func toggleWritingMode() {
        if inputMode.usesLetterCell {
            inputMode = .pen
            tool = .pointer
        } else {
            inputMode = .scribe
        }
    }
}
