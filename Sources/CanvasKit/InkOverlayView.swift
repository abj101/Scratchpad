import AppKit

/// Transparent document layer that draws ink and chrome over the live body text.
final class InkOverlayView: NSView {
    weak var canvasView: CanvasView?

    init(canvasView: CanvasView) {
        self.canvasView = canvasView
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The overlay is visually above text, but never takes its mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvasView, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: canvasView.origin, y: canvasView.origin)
        canvasView.drawDocumentOverlay(in: ctx, world: canvasView.worldRect(for: dirtyRect))
    }
}
