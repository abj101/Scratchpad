import AppKit

/// A document page starts at the top-left and only scrolls down.
final class DocumentClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        let maxY = max(0, (documentView?.frame.height ?? bounds.height) - bounds.height)
        bounds.origin.y = min(max(0, bounds.origin.y), maxY)
        // Whole device pixels only: a fractional origin leaves gray seams in the cached page.
        bounds.origin.y = backingAlignedRect(bounds, options: .alignAllEdgesNearest).origin.y
        return bounds
    }
}
