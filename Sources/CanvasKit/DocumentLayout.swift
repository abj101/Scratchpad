import AppKit

/// Geometry shared by the flowing document body and its scroll view.
public enum DocumentLayout {
    public static let sideMargin: CGFloat = 28
    /// The text starts right below the window's top band while the formatting bar is closed.
    public static let topInset: CGFloat = FloatingChromeLayout.topZoneHeight
    /// How far the text slides down while the formatting bar is open: the bar and its gap.
    public static let formattingBarDrop: CGFloat = FloatingChromeLayout.formattingBarHeight + FloatingChromeLayout.spacing

    public static func columnWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - sideMargin * 2)
    }

    /// Keep the document at least viewport-sized; scrolling begins when content
    /// extends a line below the viewport, avoiding a scroll range for the
    /// document body's empty or single-line baseline height.
    public static func documentHeight(contentBottom: CGFloat, viewportHeight: CGFloat,
                                       bodySize: CGFloat = TextFormatting.bodySize) -> CGFloat {
        let minimumOverflow = bodySize * 1.5
        guard contentBottom > viewportHeight + minimumOverflow else { return max(0, viewportHeight) }
        return max(max(contentBottom, 0), max(viewportHeight, 0))
    }
}
