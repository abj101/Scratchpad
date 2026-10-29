import CoreGraphics

/// Maps normalized trackpad positions onto the visible canvas.
///
/// `activeRect` is `visibleWorldRect` inset by `inset`, then aspect-fitted
/// (centered) to the trackpad's aspect ratio. A normalized point (origin
/// bottom-left) maps to `minX + nx·w`, `minY + (1−ny)·h` (world is y-down).
public struct TabletMapping: Equatable {
    public static let defaultAspect: CGFloat = 1.6
    /// Default inset in *screen* points; divide by magnification for world units.
    public static let defaultScreenInset: CGFloat = 40

    /// Visible world rect of the canvas viewport.
    public var visibleWorldRect: CGRect
    /// Inset in world units. If insetting leaves an empty rect, no inset is applied.
    public var inset: CGFloat
    /// Trackpad width / height. Always > 0.
    public var deviceAspect: CGFloat

    /// `deviceSize` of `.zero` (or any non-positive dimension) uses `defaultAspect`.
    public init(visibleWorldRect: CGRect, inset: CGFloat, deviceSize: CGSize = .zero) {
        self.visibleWorldRect = visibleWorldRect
        self.inset = inset
        self.deviceAspect = Self.defaultAspect
        setDeviceSize(deviceSize)
    }

    /// Update the aspect from a reported device size; ignores non-positive sizes.
    public mutating func setDeviceSize(_ size: CGSize) {
        if size.width > 0 && size.height > 0 { deviceAspect = size.width / size.height }
    }

    /// The world rect the whole trackpad maps to.
    public var activeRect: CGRect {
        var base = visibleWorldRect.insetBy(dx: inset, dy: inset)
        if !(base.width > 0 && base.height > 0) { base = visibleWorldRect }
        guard base.width > 0, base.height > 0 else { return base }
        var size = base.size
        if size.width / size.height > deviceAspect {
            size.width = size.height * deviceAspect
        } else {
            size.height = size.width / deviceAspect
        }
        return CGRect(x: base.midX - size.width / 2, y: base.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// World point for a normalized trackpad position. Inputs are clamped to 0...1.
    public func worldPoint(normalized n: CGPoint) -> CGPoint {
        let r = activeRect
        let nx = min(max(n.x, 0), 1), ny = min(max(n.y, 0), 1)
        return CGPoint(x: r.minX + nx * r.width, y: r.minY + (1 - ny) * r.height)
    }
}
