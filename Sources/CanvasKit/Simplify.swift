import CoreGraphics

// MARK: - Level of detail

/// Zoomed-out rendering support: simplified stroke geometry per detail level.
public enum StrokeLOD {
    /// Maximum on-screen deviation, in pixels, a simplified path may have.
    public static let screenTolerance: CGFloat = 0.5

    /// Detail level for a magnification: 0 at magnification >= 1 (full detail),
    /// otherwise `ceil(log2(1 / magnification))`, so each level halves the scale.
    public static func level(for magnification: CGFloat) -> Int {
        guard magnification < 1 else { return 0 }
        return max(0, Int(ceil(log2(1 / magnification))))
    }

    /// World-space tolerance for `level`: `screenTolerance * 2^level` (0 at level 0).
    public static func tolerance(for level: Int) -> CGFloat {
        level > 0 ? screenTolerance * CGFloat(1 << level) : 0
    }

    /// Ramer–Douglas–Peucker: the subset of `points` (always keeping first and
    /// last, preserving order) such that no dropped point is farther than
    /// `tolerance` from the kept polyline. Returns `points` unchanged when
    /// `tolerance <= 0` or `points.count <= 2`. Iterative (no recursion depth limit).
    public static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard tolerance > 0, points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi - lo > 1 else { continue }
            let a = points[lo], b = points[hi]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var maxDist: CGFloat = 0
            var index = lo
            for i in (lo + 1)..<hi {
                let p = points[i]
                let d: CGFloat
                if len2 == 0 {
                    d = hypot(p.x - a.x, p.y - a.y)
                } else {
                    let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
                    d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
                }
                if d > maxDist { maxDist = d; index = i }
            }
            if maxDist > tolerance {
                keep[index] = true
                stack.append((lo, index))
                stack.append((index, hi))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }
}

public extension Stroke {
    /// Path for detail `level`: `path` at level 0; otherwise a polyline through
    /// `StrokeLOD.simplify(points, tolerance: StrokeLOD.tolerance(for: level))`
    /// (same single-point/two-point handling as `path`).
    func path(level: Int) -> CGPath {
        guard level > 0 else { return path }
        let pts = StrokeLOD.simplify(points.map(\.cgPoint), tolerance: StrokeLOD.tolerance(for: level))
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        if pts.count == 1 {
            path.move(to: first)
            path.addLine(to: first) // round cap renders a dot
        } else {
            path.addLines(between: pts)
        }
        return path
    }
}
