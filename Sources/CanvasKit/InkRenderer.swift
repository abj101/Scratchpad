import AppKit

/// Cached stroke paths shared by canvas and document rendering.
final class InkRenderer {
    private final class CachedStroke {
        let path: CGPath
        let color: CGColor
        let width: CGFloat
        private var levels: [Int: CGPath] = [:]

        init(path: CGPath, color: CGColor, width: CGFloat) {
            self.path = path
            self.color = color
            self.width = width
        }

        func path(level: Int, of stroke: Stroke) -> CGPath {
            guard level > 0 else { return path }
            if let hit = levels[level] { return hit }
            let simplified = stroke.path(level: level)
            levels[level] = simplified
            return simplified
        }
    }

    private let model: CanvasModel
    private let toolController: ToolController
    private var pathCache: [UUID: CachedStroke] = [:]

    init(model: CanvasModel, toolController: ToolController) {
        self.model = model
        self.toolController = toolController
    }

    func invalidate(_ ids: Set<UUID>) {
        for id in ids { pathCache[id] = nil }
    }

    func pruneRemovedStrokes() {
        guard pathCache.count > model.strokes.count else { return }
        let live = Set(model.strokes.map(\.id))
        pathCache = pathCache.filter { live.contains($0.key) }
    }

    func draw(_ strokes: [Stroke], level: Int, in ctx: CGContext) {
        drawStrokes(strokes, level: level, in: ctx)
    }

    func draw(in ctx: CGContext, world: CGRect, level: Int, hidden: Set<UUID>,
              skipSelected: Bool, selected: Set<UUID>, pending: [Stroke]) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let visible = model.strokes(intersecting: world).filter {
            !hidden.contains($0.id) && !(skipSelected && selected.contains($0.id))
        }
        drawStrokes(visible, level: level, in: ctx)

        for stroke in pending where stroke.bounds.intersects(world) {
            draw(CachedStroke(path: stroke.path, color: stroke.color.cgColor, width: stroke.width), in: ctx)
        }
        if var live = toolController.liveStroke {
            let last = live.points.last?.t ?? 0
            live.points += toolController.livePrediction.map { StrokePoint(x: $0.x, y: $0.y, t: last) }
            if live.bounds.intersects(world) {
                draw(CachedStroke(path: live.path, color: live.color.cgColor, width: live.width), in: ctx)
            }
        }
    }

    private func draw(_ stroke: CachedStroke, in ctx: CGContext) {
        ctx.setStrokeColor(stroke.color)
        ctx.setLineWidth(stroke.width)
        ctx.addPath(stroke.path)
        ctx.strokePath()
    }

    /// Draw in z-order. Same-style strokes are faster as separate paths in Core Graphics.
    private func drawStrokes(_ strokes: [Stroke], level: Int, in ctx: CGContext) {
        for stroke in strokes {
            let entry = cached(stroke)
            ctx.setStrokeColor(entry.color)
            ctx.setLineWidth(entry.width)
            ctx.addPath(entry.path(level: level, of: stroke))
            ctx.strokePath()
        }
    }

    private func cached(_ stroke: Stroke) -> CachedStroke {
        if let hit = pathCache[stroke.id] { return hit }
        let entry = CachedStroke(path: stroke.path, color: stroke.color.cgColor, width: stroke.width)
        pathCache[stroke.id] = entry
        return entry
    }
}
