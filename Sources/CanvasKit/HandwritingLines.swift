import Foundation

/// One line of handwriting: its strokes left → right and their union bounds.
public struct HandwritingLine: Equatable {
    public var strokeIDs: [UUID]
    public var bounds: CGRect

    public init(strokeIDs: [UUID], bounds: CGRect) {
        self.strokeIDs = strokeIDs; self.bounds = bounds
    }
}

/// Geometric line finding for recognition (one recognizer call per line).
///
/// Strokes sweep left → right and join the line whose vertical band (the mean
/// top/bottom of its strokes, so one tall stroke doesn't widen it) they
/// overlap by at least `minOverlap` of the smaller height, provided the
/// horizontal gap to that line is at most `maxGap` × its band height — wider
/// gaps start a new line (separate columns stay apart). Small strokes (dots,
/// crossbars, punctuation: under `smallFraction` of the median height) are
/// placed afterwards with the nearest line within one band height.
public enum HandwritingLines {
    static let minOverlap = 0.5
    static let maxGap = 3.0
    static let smallFraction = 0.5

    /// Lines in reading order (top, then left).
    public static func group(_ strokes: [Stroke]) -> [HandwritingLine] {
        let strokes = strokes.filter { !$0.points.isEmpty }
        guard !strokes.isEmpty else { return [] }
        let heights = strokes.map(\.bounds.height).sorted()
        let small = smallFraction * heights[heights.count / 2]
        var main = strokes.filter { $0.bounds.height >= small }
        var minor = strokes.filter { $0.bounds.height < small }
        if main.isEmpty { swap(&main, &minor) }

        var clusters = sweep(main)
        var orphans: [Stroke] = []
        for stroke in minor {
            let c = CGPoint(x: stroke.bounds.midX, y: stroke.bounds.midY)
            let best = clusters.indices
                .map { ($0, distance(c, clusters[$0].bounds)) }
                .filter { $0.1 <= clusters[$0.0].bandHeight }
                .min { $0.1 < $1.1 }
            if let (i, _) = best { clusters[i].add(stroke) } else { orphans.append(stroke) }
        }
        clusters += sweep(orphans)

        return clusters
            .map { c in
                HandwritingLine(strokeIDs: c.strokes.sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }.map(\.id),
                                bounds: c.bounds)
            }
            .sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
    }

    private struct Cluster {
        var strokes: [Stroke] = []
        var bounds = CGRect.null
        private var topSum = 0.0, bottomSum = 0.0

        var bandTop: Double { topSum / Double(strokes.count) }
        var bandBottom: Double { bottomSum / Double(strokes.count) }
        var bandHeight: Double { max(bandBottom - bandTop, 1) }

        init(_ stroke: Stroke) { add(stroke) }

        mutating func add(_ stroke: Stroke) {
            strokes.append(stroke)
            bounds = bounds.union(stroke.bounds)
            topSum += stroke.bounds.minY
            bottomSum += stroke.bounds.maxY
        }

        /// Vertical overlap with the band as a fraction of the smaller height.
        func overlap(_ r: CGRect) -> Double {
            let o = min(r.maxY, bandBottom) - max(r.minY, bandTop)
            return o / max(min(r.height, bandHeight), 1)
        }
    }

    private static func sweep(_ strokes: [Stroke]) -> [Cluster] {
        var clusters: [Cluster] = []
        for stroke in strokes.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            let r = stroke.bounds
            let best = clusters.indices
                .filter { r.minX - clusters[$0].bounds.maxX <= maxGap * clusters[$0].bandHeight }
                .map { ($0, clusters[$0].overlap(r)) }
                .filter { $0.1 >= minOverlap }
                .max { $0.1 < $1.1 }
            if let (i, _) = best { clusters[i].add(stroke) } else { clusters.append(Cluster(stroke)) }
        }
        return clusters
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> Double {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}
