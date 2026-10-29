import Foundation

/// Maps world ink to "paper" points for `PKStrokeRecognizer`, which silently
/// returns nil on trackpad-sized ink: the median stroke height becomes
/// `targetMedianHeight` (never enlarged) and the ink's top-left lands on
/// `paperOrigin`. Stored strokes are never changed.
public struct InkNormalization {
    public static let targetMedianHeight = 12.0, paperOrigin = CGPoint(x: 72, y: 72)

    /// World → paper.
    public let transform: CGAffineTransform
    /// Uniform world → paper scale (≤ 1).
    public let scale: Double

    /// Identity for no strokes.
    public init(strokes: [Stroke]) {
        let heights = strokes.map(\.bounds.height).sorted()
        guard !heights.isEmpty else {
            transform = .identity; scale = 1
            return
        }
        let s = min(1, Self.targetMedianHeight / max(heights[heights.count / 2], 1))
        let origin = strokes.reduce(CGRect.null) { $0.union($1.bounds) }.origin
        scale = s
        transform = CGAffineTransform(translationX: -origin.x, y: -origin.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: Self.paperOrigin.x, y: Self.paperOrigin.y))
    }

    public func toPaper(_ p: CGPoint) -> CGPoint { p.applying(transform) }

    public func toWorld(_ rect: CGRect) -> CGRect { rect.applying(transform.inverted()) }
}
