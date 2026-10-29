import CoreGraphics

/// Math ink tidying: stroke smoothing, straightening, and baseline alignment.
enum MathInkTidy {
    /// Stroke statistics for baseline alignment: body glyph heights and bottoms on current line.
    struct LineStats {
        var heights: [CGFloat] = []
        var bottoms: [CGFloat] = []
        private static let maxEntries = 8

        var medianHeight: CGFloat? { median(heights) }
        var baseline: CGFloat? { median(bottoms) }

        /// Record a body glyph's height and bottom; maintains recent history.
        mutating func record(_ extent: CGRect, kind: String? = nil, minimumHeight: CGFloat? = nil) {
            if let kind, !["digit", "lower", "upper"].contains(kind) { return }
            guard !extent.isNull, extent.height.isFinite, extent.maxY.isFinite, extent.height > 0 else { return }
            if let minimumHeight, extent.height < minimumHeight { return }
            if heights.count >= Self.maxEntries {
                heights.removeFirst()
                bottoms.removeFirst()
            }
            heights.append(extent.height)
            bottoms.append(extent.maxY)
        }

        /// True if this extent is a body glyph (within [0.7·h̃, 1.4·h̃]).
        func isBody(_ extent: CGRect) -> Bool {
            guard heights.count >= 2 else { return true }
            let median = heights.sorted()[heights.count / 2]
            return extent.height >= 0.7 * median && extent.height <= 1.4 * median
        }

        /// Compute transform to align extent towards median height/bottom; identity if <2 stats.
        func alignTransform(extent: CGRect) -> CGAffineTransform {
            guard heights.count >= 2 else { return .identity }
            guard let medianHeight, let medianBottom = baseline else { return .identity }

            guard isBody(extent) else { return .identity }

            let s = exp(0.7 * log(medianHeight / extent.height))
            let scaledBottom = extent.midY + (extent.maxY - extent.midY) * s
            let dy = (medianBottom - scaledBottom) * 0.7

            // Scale about the center, then shift: p' = s·(p − c) + c + (0, dy).
            let center = extent.mid
            return CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y + dy))
        }

        private func median(_ values: [CGFloat]) -> CGFloat? {
            guard !values.isEmpty else { return nil }
            return values.sorted()[values.count / 2]
        }
    }

    /// Smooth a stroke: remove wobble via Douglas–Peucker + Catmull-Rom resampling.
    /// Tolerance and spacing are relative to cell height H.
    static func smooth(_ stroke: Stroke, cellHeight H: CGFloat) -> Stroke {
        guard stroke.points.count >= 3 else { return stroke }
        let extent = WritingLayout.letterExtent([stroke])
        guard extent.width >= 0.05 * H || extent.height >= 0.05 * H else { return stroke }

        let cgPoints = stroke.points.map(\.cgPoint)
        let simplified = StrokeLOD.simplify(cgPoints, tolerance: 0.02 * H)
        guard simplified.count >= 3 else { return stroke }

        let resampled = catmullRomResample(simplified, spacing: 0.03 * H, endpointFixed: true)
        guard resampled.count >= 2 else { return stroke }

        // Interpolate t linearly over the new points
        let newPoints = zip(resampled, linspace(from: stroke.points[0].t, to: stroke.points[stroke.points.count - 1].t, count: resampled.count))
            .map { StrokePoint(x: $0.x, y: $0.y, t: $1) }
        var result = stroke
        result.points = newPoints
        return result
    }

    /// Straighten a stroke if it's nearly straight; otherwise return unchanged.
    /// Straightness is determined by max deviation from start→end chord.
    static func straighten(_ stroke: Stroke, cellHeight H: CGFloat) -> Stroke {
        guard stroke.points.count >= 2 else { return stroke }
        let points = stroke.points.map(\.cgPoint)
        let a = points[0]
        let b = points[points.count - 1]
        let chord = b - a
        let chordLen = hypot(chord.x, chord.y)

        guard chordLen >= 0.15 * H else { return stroke }

        var pathLength: CGFloat = 0
        for (start, end) in zip(points, points.dropFirst()) {
            pathLength += hypot(end.x - start.x, end.y - start.y)
        }
        guard pathLength <= 1.15 * chordLen else { return stroke }

        // Compute max perpendicular deviation
        let dx = chord.x, dy = chord.y
        let len2 = dx * dx + dy * dy
        var maxDev: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let p = points[i]
            let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
            let closest = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let dev = hypot(p.x - closest.x, p.y - closest.y)
            maxDev = max(maxDev, dev)
        }

        guard maxDev <= 0.04 * H else { return stroke }

        // It's straight: snap to horiz/vert if close, then resample evenly
        let angle = atan2(chord.y, chord.x)
        let horizontal = atan2(0.0, 1.0)
        let vertical = atan2(1.0, 0.0)
        let thresh: CGFloat = 8 * .pi / 180

        if abs(angle - horizontal) < thresh {
            // Snap to horizontal about midpoint
            let mid = (a.y + b.y) / 2
            var result = stroke
            result.points = linspace(from: a, to: CGPoint(x: b.x, y: mid), count: min(stroke.points.count, 50))
                .enumerated()
                .map { (i, p) in
                    let t = stroke.points[0].t + (stroke.points[stroke.points.count - 1].t - stroke.points[0].t) * CGFloat(i) / CGFloat(max(1, result.points.count - 1))
                    return StrokePoint(x: p.x, y: p.y, t: t)
                }
            return result
        } else if abs(angle - vertical) < thresh {
            // Snap to vertical about midpoint
            let mid = (a.x + b.x) / 2
            var result = stroke
            result.points = linspace(from: a, to: CGPoint(x: mid, y: b.y), count: min(stroke.points.count, 50))
                .enumerated()
                .map { (i, p) in
                    let t = stroke.points[0].t + (stroke.points[stroke.points.count - 1].t - stroke.points[0].t) * CGFloat(i) / CGFloat(max(1, result.points.count - 1))
                    return StrokePoint(x: p.x, y: p.y, t: t)
                }
            return result
        }

        // Resample evenly
        var result = stroke
        result.points = linspace(from: a, to: b, count: min(stroke.points.count, 50))
            .enumerated()
            .map { (i, p) in
                let t = stroke.points[0].t + (stroke.points[stroke.points.count - 1].t - stroke.points[0].t) * CGFloat(i) / CGFloat(max(1, result.points.count - 1))
                return StrokePoint(x: p.x, y: p.y, t: t)
            }
        return result
    }

    /// Apply straighten first, then smooth (if not straightened).
    static func tidy(_ strokes: [Stroke], cellHeight H: CGFloat) -> [Stroke] {
        return strokes.map { stroke in
            let straightened = straighten(stroke, cellHeight: H)
            if straightened.points != stroke.points {
                return straightened
            }
            return smooth(stroke, cellHeight: H)
        }
    }

    /// Apply a CGAffineTransform to all points in a stroke.
    static func apply(_ transform: CGAffineTransform, to stroke: Stroke) -> Stroke {
        var result = stroke
        result.points = stroke.points.map { p in
            let pt = CGPoint(x: p.x, y: p.y)
            let transformed = pt.applying(transform)
            return StrokePoint(x: transformed.x, y: transformed.y, t: p.t)
        }
        return result
    }

    // MARK: - Helpers

    /// Catmull-Rom spline resampling at a given spacing.
    /// Endpoints are preserved exactly.
    private static func catmullRomResample(_ points: [CGPoint], spacing: CGFloat, endpointFixed: Bool = true) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        if points.count == 2 {
            return resampleLine(points[0], points[1], spacing: spacing)
        }

        var result: [CGPoint] = [points[0]]

        for i in 0..<(points.count - 1) {
            let p0 = i > 0 ? points[i - 1] : points[0]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : points[points.count - 1]

            let segmentLength = hypot(p2.x - p1.x, p2.y - p1.y)
            var t: CGFloat = 0
            while t < 1 {
                let q = catmullRomPoint(p0, p1, p2, p3, t: t)
                if i < points.count - 2 || t < 1 - 1e-6 {
                    result.append(q)
                }
                let dt = spacing / max(segmentLength, spacing / 2)
                t += dt
            }
        }

        result.append(points[points.count - 1])
        return result
    }

    /// Catmull-Rom point at parameter t ∈ [0, 1].
    private static func catmullRomPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let mt = 1 - t
        let mt2 = mt * mt
        _ = mt2 * mt // mt3 unused in Catmull-Rom formula

        let x = 0.5 * (
            2 * p1.x +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            2 * p1.y +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )
        return CGPoint(x: x, y: y)
    }

    /// Resample a line segment at a given spacing.
    private static func resampleLine(_ a: CGPoint, _ b: CGPoint, spacing: CGFloat) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return [a, b] }
        let count = max(2, Int(ceil(len / spacing)) + 1)
        return linspace(from: a, to: b, count: count)
    }

    /// Linear interpolation over n points from a to b.
    private static func linspace(from a: CGPoint, to b: CGPoint, count: Int) -> [CGPoint] {
        guard count > 1 else { return [a] }
        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
        }
    }

    /// Linear interpolation over n points from a to b.
    private static func linspace(from a: CGFloat, to b: CGFloat, count: Int) -> [CGFloat] {
        guard count > 1 else { return [a] }
        return (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            return a + t * (b - a)
        }
    }
}

// MARK: - CGPoint arithmetic helpers

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    var mid: CGPoint { self }
}

private extension CGRect {
    var mid: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
