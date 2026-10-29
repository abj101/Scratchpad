import Foundation

/// Pure placement, wrapping, panel and viewport-follow math for Write mode.
/// World coordinates are y-down; screen distances are divided by magnification.
public enum WritingLayout {
    /// Screen-point margin from the viewport's left edge to a new line, and from
    /// the right edge to the wrap limit.
    public static let screenMargin: CGFloat = 48
    /// A new line starts this fraction of the viewport height from the top.
    public static let topFraction: CGFloat = 0.25
    /// Seconds of idle after pen-up before the pending letter commits.
    public static let commitDelay: TimeInterval = 0.25
    /// Scribe: seconds of idle after pen-up before the pending letter commits.
    public static let scribeCommitDelay: TimeInterval = 0.4
    /// Scribe: trackpad buttons (normalized, origin bottom-left) where a tap acts instead of
    /// writing: the top-left corner slides the cell on, the top-right toggles math input.
    /// Narrow full-height trackpad edges: a tap on the right advances, on the left deletes.
    public static let scribeAdvanceZone = CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
    public static let scribeDeleteZone = CGRect(x: 0, y: 0, width: 0.25, height: 1)
    public static var scribeZones: [CGRect] { [scribeAdvanceZone, scribeDeleteZone] }

    /// `zone` (normalized trackpad, origin bottom-left) in the world rect the trackpad maps to.
    public static func worldRect(ofZone zone: CGRect, in r: CGRect) -> CGRect {
        CGRect(x: r.minX + zone.minX * r.width, y: r.minY + (1 - zone.maxY) * r.height,
               width: zone.width * r.width, height: zone.height * r.height)
    }
    /// Scribe: seconds of idle after the last letter before the phrase is sent to recognition.
    public static let scribePhraseDelay: TimeInterval = 1.0
    /// Scribe: a new block's left inset from the viewport edge, in screen points.
    public static let scribeLeftInset: CGFloat = 48
    /// Scribe: screen-point gap kept between the free area and the floating chrome / panel.
    public static let scribeFreePadding: CGFloat = 12
    /// Scribe: the cell's private world position, far from any content (the strokes never reach the canvas).
    public static let scribeOrigin: CGFloat = -50_000
    /// Screen-point padding kept around the cell when following it.
    public static let followPadding: CGFloat = 24
    /// The panel shows this many cell widths of committed letters left of the cell.
    public static let panelContext: CGFloat = 1
    /// Panel margin above and below the cell, as a fraction of its height (so ink at
    /// the cell's top and bottom isn't on the panel edge).
    public static let panelVerticalPad: CGFloat = 0.08
    public static let panelMargin: CGFloat = 16
    /// Gap from the screen's visible bottom to a new panel.
    public static let panelBottomInset: CGFloat = 24
    public static let panelWidth: CGFloat = 520

    // MARK: Placement

    /// A fresh cell near the top-left of the visible world rect.
    public static func initialCell(visible: CGRect, magnification m: CGFloat,
                                   height: CGFloat, deviceAspect: CGFloat) -> LetterCell {
        LetterCell(margin: visible.minX + screenMargin / m, top: visible.minY + topFraction * visible.height,
                   height: height, deviceAspect: deviceAspect)
    }

    /// Document Write starts on the visible caret line when available, or at
    /// the top-left of the visible text column after scrolling.
    public static func documentCellOrigin(visible: CGRect, column: CGRect, caret: CGRect?) -> CGPoint {
        if let caret, caret.minY < visible.maxY, caret.maxY > visible.minY {
            return CGPoint(x: caret.minX, y: caret.minY)
        }
        return CGPoint(x: column.minX, y: visible.minY)
    }

    /// Wrap limit: the visible right edge less the margin, but always room for two cells.
    public static func rightLimit(visible: CGRect, magnification m: CGFloat, cell: LetterCell) -> CGFloat {
        max(visible.maxX - screenMargin / m, cell.margin + 2 * cell.size.width)
    }

    // MARK: Letters

    /// Inked extent of strokes: point bounds grown by half the line width (no
    /// invalidation slack, unlike `Stroke.bounds`). `.null` for no points.
    public static func letterExtent(_ strokes: [Stroke]) -> CGRect {
        strokes.reduce(CGRect.null) { rect, stroke in
            guard let first = stroke.points.first else { return rect }
            var r = CGRect(x: first.x, y: first.y, width: 0, height: 0)
            for p in stroke.points.dropFirst() { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            let half = stroke.width / 2
            return rect.union(r.insetBy(dx: -half, dy: -half))
        }
    }

    // MARK: Panel

    /// World rect the panel shows: the cell, context to its left, and a little vertical margin.
    public static func panelWorldRect(for cell: LetterCell) -> CGRect {
        let r = cell.rect
        let extra = panelContext * r.width
        let pad = panelVerticalPad * r.height
        return CGRect(x: r.minX - extra, y: r.minY - pad, width: r.width + extra, height: r.height + 2 * pad)
    }

    /// Keep Scribe's chrome stable when the first touch reports the device aspect.
    /// Fit the cell inside a fixed aspect without stretching or clipping its ink.
    public static func scribePanelWorldRect(for cell: LetterCell) -> CGRect {
        let rect = cell.rect
        let width = max(rect.width, rect.height * TabletMapping.defaultAspect)
        let height = width / TabletMapping.defaultAspect
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }

    /// Fixed screen-point width, with the aspect of `world`, independent of the note's viewport.
    public static func panelSize(world: CGSize) -> CGSize {
        guard world.width > 0, world.height > 0 else { return .zero }
        return CGSize(width: panelWidth, height: panelWidth * world.height / world.width)
    }

    // MARK: Scribe free area

    /// The visible world rect minus the floating chrome at the top and the panel at the
    /// bottom (both in screen points), and `left` screen points at the left edge.
    public static func freeRect(visible: CGRect, magnification m: CGFloat,
                                top: CGFloat, bottom: CGFloat, left: CGFloat = 0) -> CGRect {
        var r = visible
        r.origin.x += left / m
        r.size.width = max(0, r.width - left / m)
        r.origin.y += top / m
        r.size.height = max(0, r.height - (top + bottom) / m)
        return r
    }

    // MARK: Viewport follow

    /// Smallest pan (world units) that brings `target` inside `visible`. A target
    /// larger than `visible` on an axis aligns its leading edge.
    public static func followDelta(target: CGRect, visible: CGRect) -> CGVector {
        func axis(_ lo: CGFloat, _ hi: CGFloat, _ vlo: CGFloat, _ vhi: CGFloat) -> CGFloat {
            if hi - lo > vhi - vlo || lo < vlo { return lo - vlo }
            if hi > vhi { return hi - vhi }
            return 0
        }
        return CGVector(dx: axis(target.minX, target.maxX, visible.minX, visible.maxX),
                        dy: axis(target.minY, target.maxY, visible.minY, visible.maxY))
    }

    /// Scribe: the pan that keeps `caret` inside `free`, resting it a line above the free
    /// area's bottom edge — the panel's top edge, in the layouts that have one. The step is
    /// whole lines, so a new line is one steady glide instead of a jitter per character.
    /// `xInset` pads the caret sideways (screen points, like `followPadding`).
    public static func scribeFollowDelta(caret: CGRect, free: CGRect, lineHeight: CGFloat,
                                         xInset: CGFloat = followPadding) -> CGVector {
        var d = followDelta(target: caret.insetBy(dx: -xInset, dy: 0), visible: free)
        let line = max(lineHeight, 1)
        let past = caret.maxY - (free.maxY - line)
        if past > 0 { d.dy = (past / line).rounded(.up) * line }
        return d
    }

    // MARK: The chase

    /// One frame of the viewport chase: `current` moved the fraction of what is left to
    /// `target` that `dt` buys. First-order, so it never overshoots its target, and
    /// re-aiming between frames is free — the fraction is always of what is still left, so
    /// a new target re-aims the glide in flight instead of restarting it.
    /// Nil when there is nothing to move: within `epsilon` of `target`, or no time passed.
    public static func chaseStep(from current: CGPoint, to target: CGPoint, dt: TimeInterval,
                                 timeConstant: TimeInterval, epsilon: CGFloat = 0.5) -> CGPoint? {
        let dx = target.x - current.x, dy = target.y - current.y
        let distance = hypot(dx, dy)
        guard distance > epsilon, dt > 0, timeConstant > 0 else { return nil }
        let fraction = 1 - exp(-dt / timeConstant)
        return CGPoint(x: current.x + dx * fraction, y: current.y + dy * fraction)
    }
}

/// Sizes of the floating chrome over the canvas, shared by the SwiftUI views that draw it
/// (`ContentView`) and the canvas, which keeps Scribe text clear of it.
public enum FloatingChromeLayout {
    public static let topPadding: CGFloat = 8
    public static let toolBarHeight: CGFloat = 52
    /// The window's top band: everything above the tool bar's bottom edge. Hovering it
    /// shows the traffic lights and the window border; it drags the window.
    public static let topZoneHeight: CGFloat = topPadding + 20
    public static let findBarHeight: CGFloat = 32
    public static let formattingBarHeight: CGFloat = 34
    public static let spacing: CGFloat = 10
    /// The paragraph-style dropdown under the formatting bar. Its gap is the same gap
    /// the bar keeps from the tool bar, so the panels stack on one rhythm.
    public static let styleMenuGap: CGFloat = spacing
    public static let styleMenuRowHeight: CGFloat = 26
    public static let styleMenuRowSpacing: CGFloat = 2
    public static let styleMenuPadding: CGFloat = 4
    public static let styleMenuRowCount = 4
    public static let styleMenuHeight: CGFloat = CGFloat(styleMenuRowCount) * styleMenuRowHeight
        + CGFloat(styleMenuRowCount - 1) * styleMenuRowSpacing + 2 * styleMenuPadding

    /// Screen points from the top of the canvas to the bottom of the chrome.
    public static func height(findVisible: Bool, formattingVisible: Bool = false) -> CGFloat {
        topPadding + toolBarHeight + (findVisible ? spacing + findBarHeight : 0)
            + (formattingVisible ? spacing + formattingBarHeight : 0)
    }
}
