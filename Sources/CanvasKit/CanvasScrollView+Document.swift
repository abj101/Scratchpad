import AppKit

extension CanvasScrollView {
    func configureDocumentScrolling() {
        contentView = DocumentClipView()
        documentView = canvasView
        allowsMagnification = false
        hasHorizontalScroller = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView?.setFrameOrigin(.zero)
        updateDocumentSize()
    }

    /// Size the page to its content while keeping at least one viewport visible.
    func updateDocumentSize() {
        guard canvasView.layout == .document, contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        let viewport = contentView.bounds
        let zoneBottom = canvasView.model.drawingZones?.map(\.rect.maxY).max() ?? 0
        let contentBottom = max(DocumentLayout.topInset, canvasView.model.contentBounds?.maxY ?? 0, zoneBottom)
        // While writing, the page extends a couple of lines past the text so the caret can rest
        // a line above the bottom edge; the page never scrolls past its own bottom.
        let runway = writingPanel.isHidden ? 0 : 2 * CGFloat(canvasView.settings.defaultFontSize) * 1.5
        let height = DocumentLayout.documentHeight(contentBottom: contentBottom + runway,
                                                   viewportHeight: viewport.height,
                                                   bodySize: CGFloat(canvasView.settings.defaultFontSize))
        let size = NSSize(width: viewport.width, height: height)
        if canvasView.frame.size != size { canvasView.setFrameSize(size) }
        let clampedOrigin = contentView.constrainBoundsRect(contentView.bounds).origin
        if clampedOrigin != contentView.bounds.origin {
            contentView.scroll(to: clampedOrigin)
            reflectScrolledClipView(contentView)
        }
    }

    func setDocumentViewport(_ viewport: Viewport) {
        centerOn(world: CGPoint(x: 0, y: viewport.center.y))
    }

    func centerOnDocument(worldY: CGFloat) {
        updateDocumentSize()
        let height = contentView.bounds.height
        let target = NSRect(x: 0, y: max(0, worldY - height / 2), width: contentView.bounds.width, height: height)
        contentView.scroll(to: contentView.constrainBoundsRect(target).origin)
        reflectScrolledClipView(contentView)
    }
}
