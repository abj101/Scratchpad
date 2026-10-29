import AppKit

/// Magnified view of the Write mode letter cell. It lives in its own floating window
/// (`WritingPanelWindow`), so it neither scrolls nor zooms with the note, and it never
/// takes mouse or trackpad events.
public final class WritingPanelView: NSView {
    private let model: CanvasModel
    private let toolController: ToolController

    /// The cell being written into; nil hides the panel's content.
    var cell: LetterCell? {
        didSet {
            guard cell != oldValue else { return }
            if cell.map(panelRect)?.size != oldValue.map(panelRect)?.size { layoutInSuperview() }
            needsDisplay = true
        }
    }
    /// Scribe: the panel fits the cell inside stable proportions, the word's letters (in
    /// the cell's private space) are drawn instead of model ink, and `previewPill` floats above.
    var isScribe = false {
        didSet {
            guard isScribe != oldValue else { return }
            layoutInSuperview()
            syncPillVisibility()
            needsDisplay = true
        }
    }
    /// Scribe: the word's committed letters.
    var bufferedStrokes: [Stroke] = [] { didSet { needsDisplay = true } }
    /// Scribe's floating text preview, laid out and shown with the panel.
    weak var previewPill: ScribePreviewPill?
    /// The note whose window hosts the panel.
    weak var host: CanvasScrollView?

    #if DEBUG
    var isGlyphCapture = false { didSet { syncPillVisibility(); layoutInSuperview(); needsDisplay = true } }
    #endif
    /// The preview pill above the panel is hidden for now; return `isScribe` to bring it back.
    private var showsPill: Bool { false }

    public override var isHidden: Bool { didSet { syncPillVisibility(); layoutInSuperview(); host?.updateDocumentSize() } }

    private func syncPillVisibility() {
        previewPill?.isHidden = isHidden || !showsPill
    }

    /// The in-progress letter's finished strokes, not yet in the model.
    var pendingStrokes: [Stroke] = [] { didSet { needsDisplay = true } }
    /// Mapped finger position (world); stays visible above ink while drawing.
    var hoverPoint: CGPoint? { didSet { if hoverPoint != oldValue { needsDisplay = true } } }
    /// Scribe's trackpad buttons (space, math) are shown, and whether math input is on.
    var showsZones = false { didSet { if showsZones != oldValue { needsDisplay = true } } }
    var mathOn = false { didSet { if mathOn != oldValue { needsDisplay = true } } }
    /// Panel-space frames of the edge zones from the last draw, for the tap glow.
    private var zoneFrames: [CGRect] = []

    /// Accent glow across the full height of the tapped edge, clipped to the panel's rounded
    /// shape and faded out by Core Animation (no redraws).
    func flashEdge(_ zone: Int) {
        guard let host = layer, zoneFrames.indices.contains(zone) else { return }
        let zoneFrame = zoneFrames[zone]
        let right = zoneFrame.midX > bounds.midX
        let reach = right ? bounds.maxX - zoneFrame.minX : zoneFrame.maxX
        guard reach > 0, bounds.width > 0 else { return }
        let glow = CAGradientLayer()
        glow.frame = bounds
        glow.startPoint = CGPoint(x: right ? 1 : 0, y: 0.5)
        glow.endPoint = CGPoint(x: right ? 1 - reach / bounds.width : reach / bounds.width, y: 0.5)
        let accent = NSColor.controlAccentColor
        glow.colors = [accent.withAlphaComponent(0.6).cgColor, accent.withAlphaComponent(0).cgColor]
        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        glow.mask = mask
        glow.opacity = 0
        host.addSublayer(glow)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { glow.removeFromSuperlayer() }
        glow.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    static let cornerRadius: CGFloat = 10
    static let hoverRadius: CGFloat = 9

    init(model: CanvasModel, toolController: ToolController) {
        self.model = model
        self.toolController = toolController
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func panelRect(for cell: LetterCell) -> CGRect {
        isScribe ? WritingLayout.scribePanelWorldRect(for: cell) : WritingLayout.panelWorldRect(for: cell)
    }

    /// World rect currently shown, or nil without a cell.
    var worldRect: CGRect? { cell.map(panelRect) }

    /// World units per panel point; nil until laid out with a cell.
    var worldPerPoint: CGFloat? {
        guard let w = worldRect, bounds.width > 0 else { return nil }
        return w.width / bounds.width
    }

    // MARK: Layout

    /// Sized by `WritingLayout.panelSize`, with the preview pill above and mode hint below.
    /// The window hugs them and is shown only while the panel is.
    func layoutInSuperview() {
        guard let host, let container = superview else { return }
        let size = worldRect.map { WritingLayout.panelSize(world: $0.size) } ?? .zero
        let pad = WritingPanelWindow.padding
        let pillSpace = showsPill ? ScribePreviewPill.gap + ScribePreviewPill.height : 0
        let hintSpace = host.writingWindow.content.modeHintSpace
        // The window's content is bottom-anchored, so the panel stays put as the pill comes and goes.
        let frame = CGRect(x: pad, y: pad + hintSpace, width: size.width, height: size.height).integral
        if frame != self.frame { self.frame = frame }
        layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size),
                                   cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        previewPill?.layout(above: frame, in: container)
        if isHidden || size.width == 0 {
            host.writingWindow.hide()
        } else if let note = host.window {
            host.writingWindow.show(beside: note, size: NSSize(width: size.width + 2 * pad,
                                                               height: size.height + 2 * pad + pillSpace + hintSpace),
                                         placement: toolController.settings.writingPanelPlacement)
            host.writingWindow.content.layoutModeHint()
        }
        needsDisplay = true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let cell, let w = worldRect, bounds.width > 0 else { return }
        let shape = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.setFillColor(toolController.settings.backgroundColor.cgColor)
        ctx.fill(bounds)

        let s = bounds.width / w.width
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -w.minX, y: -w.minY)
        let r = cell.rect

        // Context strip left of the cell, and a faint lift on the cell itself.
        ctx.setFillColor(NSColor(white: 0, alpha: 0.045).cgColor)
        ctx.fill(CGRect(x: w.minX, y: w.minY, width: r.minX - w.minX, height: w.height))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.12).cgColor)
        ctx.setLineWidth(1 / s)
        ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: w.minY), CGPoint(x: r.minX, y: w.maxY)])
        if mathOn {
            // Script zones: exponent above, subscript below, regular line between.
            ctx.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.4).cgColor)
            ctx.setLineDash(phase: 0, lengths: [2 / s, 3 / s])
            for f in [MathScript.upperEdge, MathScript.lowerEdge] {
                let y = r.minY + (f) * r.height
                ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y)])
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let hidden = toolController.pendingErase
        if showsPill {
            for stroke in bufferedStrokes { draw(stroke.path, color: stroke.color.cgColor, width: stroke.width, in: ctx) }
        } else {
            for stroke in model.strokes(intersecting: w) where !hidden.contains(stroke.id) {
                draw(stroke.path, color: stroke.color.cgColor, width: stroke.width, in: ctx)
            }
        }
        for stroke in pendingStrokes {
            draw(stroke.path, color: stroke.color.cgColor, width: stroke.width, in: ctx)
        }
        if var live = toolController.liveStroke {
            let last = live.points.last?.t ?? 0
            live.points += toolController.livePrediction.map { StrokePoint(x: $0.x, y: $0.y, t: last) }
            draw(live.path, color: live.color.cgColor, width: live.width, in: ctx)
        }

        if let h = hoverPoint {
            let rad = Self.hoverRadius / s
            let dot = CGRect(x: h.x - rad, y: h.y - rad, width: 2 * rad, height: 2 * rad)
            ctx.setFillColor(NSColor.systemGray.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1 / s)
            ctx.strokeEllipse(in: dot.insetBy(dx: 0.5 / s, dy: 0.5 / s))
        }
        ctx.restoreGState()

        if showsZones { drawZoneButtons(cell: cell, world: w, scale: s, in: ctx) }

        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.15).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// Scribe's trackpad edges (`WritingLayout.scribeZones`): a small arrow at the right edge
    /// (advance) and a delete glyph at the left edge, with no button chrome.
    private func drawZoneButtons(cell: LetterCell, world w: CGRect, scale s: CGFloat, in ctx: CGContext) {
        let edges = [(WritingLayout.scribeAdvanceZone, "arrow.right", "Next"),
                     (WritingLayout.scribeDeleteZone, "delete.left", "Delete")]
        zoneFrames = []
        for (zone, symbol, name) in edges {
            let world = WritingLayout.worldRect(ofZone: zone, in: cell.rect)
            let frame = CGRect(x: (world.minX - w.minX) * s, y: (world.minY - w.minY) * s,
                               width: world.width * s, height: world.height * s)
            zoneFrames.append(frame)
            let size = min(18, frame.width * 0.5)
            guard size > 4 else { continue }
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(white: 0, alpha: 0.6)]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
                .withSymbolConfiguration(config), image.size.width > 0, image.size.height > 0 else { continue }
            image.draw(in: CGRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func draw(_ path: CGPath, color: CGColor, width: Double, in ctx: CGContext) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()
    }

    // MARK: Scribe ⇄ math morph

    /// The panel as it looked before a Scribe ⇄ math switch rebuilt it.
    struct Morph {
        fileprivate let frame: CGRect
        fileprivate let image: CGImage?
        fileprivate let pillFrame: CGRect?
    }

    static let morphDuration: CFTimeInterval = 0.32
    private var morphHost: NSView?
    private var morphToken = 0

    /// Call before the switch, while the old panel is still up.
    func beginMorph() -> Morph? {
        finishRunningMorph()
        guard !isHidden, frame.width > 0, superview != nil else { return nil }
        let pill = previewPill.flatMap { $0.isHidden ? nil : $0.frame }
        return Morph(frame: frame, image: snapshot(), pillFrame: pill)
    }

    /// Call after the switch: the old panel springs into the new frame while crossfading to the
    /// new look, and the pill drops behind the panel (into math) or rises out of it (into Scribe).
    func finishMorph(_ old: Morph) {
        guard !isHidden, frame.width > 0, let container = superview, !ScribePreviewPill.reduceMotion else { return }
        morphToken += 1
        let token = morphToken
        let target = frame
        let host = FlightHostView(frame: container.bounds)
        container.addSubview(host, positioned: .above, relativeTo: self)
        morphHost = host
        let from = host.convert(old.frame, from: container), to = host.convert(target, from: container)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let images = [(old.image, 1.0, 0.0), (snapshot(), 0.0, 1.0)]
        for (image, a, b) in images {
            guard let image else { continue }
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            layer.frame = to
            layer.opacity = Float(b)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 8
            layer.shadowOffset = CGSize(width: 0, height: -2)
            host.layer?.addSublayer(layer)
            let group = CAAnimationGroup()
            group.animations = [Self.animation("position", CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY)),
                                Self.animation("bounds.size", from.size, to.size),
                                Self.animation("opacity", a, b)]
            group.duration = Self.morphDuration
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(group, forKey: "morph")
        }
        CATransaction.commit()
        alphaValue = 0

        if let pill = previewPill { morphPill(pill, from: old.pillFrame, in: container, below: host) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.morphDuration) { [weak self] in
            guard let self, token == self.morphToken else { return }
            self.finishRunningMorph()
        }
    }

    /// Drops the pill from `old` behind the panel and fades it out, or raises the new one
    /// from behind it. Its own frame is restored when the motion ends.
    private func morphPill(_ pill: ScribePreviewPill, from old: CGRect?, in container: NSView, below host: NSView) {
        let showing = !pill.isHidden
        guard showing != (old != nil) else { return }
        let rest = showing ? pill.frame : old!
        // Sunk: centered on the panel's top edge, behind it.
        var sunk = rest
        sunk.origin.y += (container.isFlipped ? 1 : -1) * (ScribePreviewPill.gap + ScribePreviewPill.height)
        container.addSubview(pill, positioned: .below, relativeTo: self)
        pill.isHidden = false
        pill.frame = showing ? sunk : rest
        pill.alphaValue = showing ? 0 : 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.morphDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pill.animator().frame = showing ? rest : sunk
            pill.animator().alphaValue = showing ? 1 : 0
        }
    }

    /// Ends any morph at once: removes its layers and restores the panel and pill.
    private func finishRunningMorph() {
        guard let host = morphHost else { return }
        morphHost = nil
        host.removeFromSuperview()
        alphaValue = 1
        guard let pill = previewPill, let container = superview else { return }
        container.addSubview(pill, positioned: .above, relativeTo: self)
        pill.alphaValue = 1
        syncPillVisibility()
        layoutInSuperview()
    }

    private static func animation(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        return a
    }

    /// The panel as drawn now.
    private func snapshot() -> CGImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    // MARK: Scribe word flight

    /// A finished word's ink lifts out of the writing area and springs up into the pill's
    /// preview word, shrinking and fading as it lands. Call before the ink is cleared.
    func flyInk(_ strokes: [Stroke]) {
        guard isScribe, !isHidden, let pill = previewPill, !pill.isHidden, let container = superview,
              let w = worldRect, bounds.width > 0 else { return }
        let extent = WritingLayout.letterExtent(strokes)
        guard !extent.isNull, extent.width > 0, extent.height > 0 else { return }
        // The word as written, at the panel's scale but shrunk to fit, centered in the writing area.
        let area = bounds.insetBy(dx: 16, dy: 16)
        let fit = min(bounds.width / w.width, area.width / extent.width, area.height / extent.height)
        let size = CGSize(width: extent.width * fit, height: extent.height * fit)
        guard let image = inkImage(strokes, extent: extent, scale: fit, size: size) else { return }
        let landing = pill.previewTextRect

        let host = FlightHostView(frame: container.bounds)
        container.addSubview(host, positioned: .above, relativeTo: pill)
        let start = convert(CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                   width: size.width, height: size.height), to: host)
        let end = pill.convert(landing, to: host)
        let ink = CALayer()
        ink.contents = image
        ink.contentsGravity = .resize
        ink.frame = start
        host.layer?.addSublayer(ink)

        let from = CGPoint(x: start.midX, y: start.midY), to = CGPoint(x: end.midX, y: end.midY)
        var scale = end.height / start.height
        if end.width > 0 { scale = min(scale, end.width / start.width) }
        scale = min(1, max(scale, 0.05))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let duration: CFTimeInterval
        if ScribePreviewPill.reduceMotion {
            duration = 0.2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            ink.add(fade, forKey: "flight")
        } else {
            func spring(_ key: String, _ a: Any, _ b: Any) -> CASpringAnimation {
                let s = CASpringAnimation(keyPath: key)
                s.fromValue = a
                s.toValue = b
                s.mass = 1
                s.stiffness = 220
                s.damping = 24
                return s
            }
            let move = spring("position", from, to)
            let shrink = spring("transform.scale", 1, scale)
            duration = move.settlingDuration
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.3, 0.55]
            let group = CAAnimationGroup()
            group.animations = [move, shrink, fade]
            group.duration = duration
            ink.add(group, forKey: "flight")
            // The word lands about a third of the way through the settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.3) {
                pill.popPreview()
                pill.flash(landing)
            }
        }
        ink.position = to
        ink.opacity = 0
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { host.removeFromSuperview() }
    }

    /// `strokes` rendered at `scale` (panel points per world unit), cropped to `extent`.
    private func inkImage(_ strokes: [Stroke], extent: CGRect, scale: CGFloat, size: CGSize) -> CGImage? {
        let px = window?.backingScaleFactor ?? 2
        let w = Int(ceil(size.width * px)), h = Int(ceil(size.height * px))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // World is y-down; the bitmap is y-up.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: px * scale, y: -px * scale)
        ctx.translateBy(x: -extent.minX, y: -extent.minY)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes { draw(stroke.path, color: stroke.color.cgColor, width: stroke.width, in: ctx) }
        return ctx.makeImage()
    }
}

/// Transient, event-transparent layer host for the word flight.
private final class FlightHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
