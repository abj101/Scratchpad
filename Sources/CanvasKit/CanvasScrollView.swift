import AppKit
import Combine

/// Infinite-canvas scroll view: two-finger scroll pans, pinch zooms around the
/// cursor. Hosts a `CanvasView` as its document view and starts centered on
/// world (0,0).
public final class CanvasScrollView: NSScrollView {
    public let canvasView: CanvasView
    /// Write mode zoom panel, in `writingWindow` beside the note.
    let writingPanel: WritingPanelView
    /// Scribe's floating text preview, above the panel.
    let previewPill = ScribePreviewPill(frame: .zero)
    /// The panel's own floating window: a child of the note's window while the panel is shown.
    let writingWindow = WritingPanelWindow()

    static let zoomStep: CGFloat = 1.25
    /// World-point margin around content for `zoomToFit`.
    static let fitMargin: CGFloat = 48
    /// `zoomToFit` never zooms in past this, so a lone dot isn't blown up to 4×.
    static let maxFitMagnification: CGFloat = 2

    private var didInitialCenter = false
    private var observers: [NSObjectProtocol] = []
    private var placementObserver: AnyCancellable?

    /// Viewport applied on first layout instead of centering on world (0,0).
    private var initialViewport: Viewport?

    public init(model: CanvasModel, settings: CanvasSettings, viewport: Viewport? = nil, layout: NoteLayout = .canvas) {
        initialViewport = viewport
        canvasView = CanvasView(model: model, settings: settings, layout: layout)
        writingPanel = WritingPanelView(model: model, toolController: canvasView.toolController)
        super.init(frame: .zero)
        documentView = canvasView
        writingPanel.host = self
        writingPanel.isHidden = true
        writingWindow.content.canvasView = canvasView
        writingWindow.content.panel = writingPanel
        writingWindow.content.addSubview(writingPanel)
        previewPill.isHidden = true
        writingWindow.content.addSubview(previewPill)
        writingPanel.previewPill = previewPill
        canvasView.writingPanel = writingPanel
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 4
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .allowed
        drawsBackground = true
        backgroundColor = settings.backgroundColor.nsColor
        if layout == .document { configureDocumentScrolling() }
        contentView.postsBoundsChangedNotifications = true
        // A new placement resets the saved position, so a showing panel moves there now.
        placementObserver = settings.$writingPanelPlacement.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.writingPanel.layoutInSuperview() }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
                self?.canvasView.magnificationDidChange()
                self?.updateDocumentSize()
            },
            center.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: self, queue: .main) { [weak self] _ in
                self?.canvasView.liveMagnifyWillStart()
            },
            center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main) { [weak self] _ in
                self?.canvasView.liveMagnifyDidEnd()
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        writingWindow.hide()
    }

    /// Show an app-owned hint in the bottom strip of the floating writing panel.
    public func setWritingPanelModeHint(_ view: NSView?) {
        writingWindow.content.setModeHintView(view)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { writingWindow.hide() } else { writingPanel.layoutInSuperview() }
    }

    public override func tile() {
        super.tile()
        updateDocumentSize()
        if !didInitialCenter, contentView.bounds.width > 0, contentView.bounds.height > 0 {
            didInitialCenter = true
            if let initialViewport {
                setViewport(initialViewport)
                self.initialViewport = nil
            } else {
                centerOn(world: .zero)
            }
        }
    }

    // MARK: Navigation

    /// World point currently at the center of the viewport.
    public var visibleWorldCenter: CGPoint {
        let b = contentView.bounds
        return canvasView.viewToWorld(CGPoint(x: b.midX, y: b.midY))
    }

    /// Current center (world) and magnification. Phase 5 contract.
    public var viewport: Viewport {
        Viewport(center: visibleWorldCenter, magnification: canvasView.layout == .document ? 1 : Double(magnification))
    }

    /// Clamp the magnification to the allowed range and center on `viewport.center`.
    public func setViewport(_ viewport: Viewport) {
        if canvasView.layout == .document {
            setDocumentViewport(viewport)
            return
        }
        let m = min(max(CGFloat(viewport.magnification), minMagnification), maxMagnification)
        setMagnification(m, centeredAt: canvasView.worldToView(viewport.center))
        centerOn(world: viewport.center)
    }

    /// Scroll so `p` (world coordinates) is centered in the viewport.
    public func centerOn(world p: CGPoint) {
        if canvasView.layout == .document {
            centerOnDocument(worldY: p.y)
            return
        }
        let c = canvasView.worldToView(p)
        let size = contentView.bounds.size
        let target = NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        contentView.scroll(to: contentView.constrainBoundsRect(target).origin)
        reflectScrolledClipView(contentView)
    }

    public func zoomIn() { guard canvasView.layout == .canvas else { return }; zoom(to: magnification * Self.zoomStep) }
    public func zoomOut() { guard canvasView.layout == .canvas else { return }; zoom(to: magnification / Self.zoomStep) }

    /// Magnification 1, keeping the viewport center fixed.
    public func zoomToActualSize() { guard canvasView.layout == .canvas else { return }; zoom(to: 1) }

    /// Fit all strokes (plus a margin) in the viewport, or reset to the origin at 1× if empty.
    public func zoomToFit() {
        guard canvasView.layout == .canvas else { return }
        guard let content = model.contentBounds else {
            setMagnification(1, centeredAt: canvasView.worldToView(.zero))
            centerOn(world: .zero)
            return
        }
        let rect = content.insetBy(dx: -Self.fitMargin, dy: -Self.fitMargin)
        let viewport = frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let fit = min(viewport.width / rect.width, viewport.height / rect.height)
        let m = min(max(fit, minMagnification), min(maxMagnification, Self.maxFitMagnification))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        setMagnification(m, centeredAt: canvasView.worldToView(center))
        centerOn(world: center)
    }

    private var model: CanvasModel { canvasView.model }

    private func zoom(to m: CGFloat) {
        let center = visibleWorldCenter
        let clamped = min(max(m, minMagnification), maxMagnification)
        setMagnification(clamped, centeredAt: canvasView.worldToView(center))
        centerOn(world: center)
    }
}
