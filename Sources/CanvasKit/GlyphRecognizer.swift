import CoreGraphics

/// One handwritten symbol: its strokes' points (any units) and its height relative to the cell.
public struct GlyphSample: Codable, Equatable {
    public var strokes: [[CGPoint]]
    /// Ink height / cell height, so a "−" and a "1" of similar shape still differ in size.
    public var relativeHeight: Double

    public init(strokes: [[CGPoint]], relativeHeight: Double = 0.5) {
        self.strokes = strokes
        self.relativeHeight = relativeHeight
    }

    public init(strokes: [Stroke], relativeHeight: Double = 0.5) {
        self.init(strokes: strokes.map { $0.points.map(\.cgPoint) }, relativeHeight: relativeHeight)
    }
}

/// $P point-cloud recognizer (Vatavu, Anthony & Wobbrock 2012) over the user's own samples.
/// Clouds keep their aspect ratio and orientation, so "−", "1" and "/" stay distinct.
public struct GlyphRecognizer {
    /// Best match must be at most this far (weighted $P distance over `cloudSize` points).
    public static let maxDistance: Double = 2.0
    /// Runner-up label must be at least this fraction further than the best.
    public static let minMargin: Double = 0.25
    /// Distance added per unit of |ln(height ratio)| between sample and template.
    public static let sizeWeight: Double = 1.5
    static let cloudSize = 32

    public typealias Result = (label: String, distance: Double, runnerUp: Double)

    public let templates: [String: [GlyphSample]]
    private let clouds: [(label: String, cloud: [CGPoint], height: Double)]

    public init(templates: [String: [GlyphSample]] = [:]) {
        self.templates = templates
        clouds = templates.flatMap { label, samples in
            samples.compactMap { s in Self.cloud(s.strokes).map { (label, $0, s.relativeHeight) } }
        }
    }

    /// Best label with its distance and the nearest other label's distance; nil without templates
    /// or for an empty sample. `relativeHeight` defaults to the sample's own.
    public func classify(_ sample: GlyphSample, relativeHeight: Double? = nil) -> Result? {
        guard let cloud = Self.cloud(sample.strokes) else { return nil }
        let height = relativeHeight ?? sample.relativeHeight
        var best: [String: Double] = [:]
        for t in clouds {
            var d = Self.distance(cloud, t.cloud)
            if height > 0, t.height > 0 { d += abs(log(height / t.height)) * Self.sizeWeight }
            best[t.label] = min(best[t.label] ?? .infinity, d)
        }
        let ranked = best.sorted { $0.value < $1.value }
        guard let first = ranked.first else { return nil }
        return (first.key, first.value, ranked.dropFirst().first?.value ?? .infinity)
    }

    public static func isConfident(_ r: Result) -> Bool {
        r.distance <= maxDistance && r.runnerUp - r.distance >= minMargin * r.distance
    }

    // MARK: Normalization

    /// `cloudSize` points spread along the ink by length (never across pen-up gaps), centered
    /// on their centroid and scaled by the larger bounding-box side. Nil for no ink.
    static func cloud(_ strokes: [[CGPoint]]) -> [CGPoint]? {
        let strokes = strokes.filter { !$0.isEmpty }
        guard !strokes.isEmpty else { return nil }
        let lengths = strokes.map(length)
        let total = lengths.reduce(0, +)
        var points: [CGPoint] = []
        if total == 0 {
            points = Array(repeating: strokes[0][0], count: cloudSize)
        } else {
            // Allot points per stroke by length (at least one each), then trim/pad to size.
            for (stroke, len) in zip(strokes, lengths) {
                let n = max(1, Int((CGFloat(cloudSize) * len / total).rounded()))
                points += resample(stroke, to: n)
            }
            while points.count > cloudSize { points.remove(at: points.count / 2) }
            while points.count < cloudSize { points.append(points[points.count - 1]) }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let side = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let scale = side > 0 ? 1 / side : 1
        let c = CGPoint(x: xs.reduce(0, +) / CGFloat(points.count), y: ys.reduce(0, +) / CGFloat(points.count))
        return points.map { CGPoint(x: ($0.x - c.x) * scale, y: ($0.y - c.y) * scale) }
    }

    static func length(_ s: [CGPoint]) -> CGFloat {
        zip(s, s.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// `n` points evenly spaced along `s` by length, endpoints included (one point: the midpoint).
    static func resample(_ s: [CGPoint], to n: Int) -> [CGPoint] {
        let total = length(s)
        guard n > 1, total > 0 else { return Array(repeating: s[s.count / 2], count: max(n, 0)) }
        var out = [s[0]]
        let step = total / CGFloat(n - 1)
        var walked: CGFloat = 0, next = step, i = 1
        var prev = s[0]
        while out.count < n - 1, i < s.count {
            let seg = hypot(s[i].x - prev.x, s[i].y - prev.y)
            if walked + seg >= next, seg > 0 {
                let f = (next - walked) / seg
                let p = CGPoint(x: prev.x + f * (s[i].x - prev.x), y: prev.y + f * (s[i].y - prev.y))
                out.append(p)
                walked = next; prev = p; next += step
            } else {
                walked += seg; prev = s[i]; i += 1
            }
        }
        while out.count < n { out.append(s[s.count - 1]) }
        return out
    }

    // MARK: Matching

    /// $P greedy cloud match: min over start points and both match directions.
    static func distance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        let step = max(1, Int(Double(a.count).squareRoot()))
        var best = Double.infinity
        for start in stride(from: 0, to: a.count, by: step) {
            best = min(best, cloudDistance(a, b, start), cloudDistance(b, a, start))
        }
        return best
    }

    /// Each point of `a`, from `start` on, takes its nearest unused point of `b`; early matches weigh more.
    static func cloudDistance(_ a: [CGPoint], _ b: [CGPoint], _ start: Int) -> Double {
        let n = a.count
        var used = [Bool](repeating: false, count: b.count)
        var sum = 0.0
        for k in 0..<n {
            let p = a[(start + k) % n]
            var nearest = -1
            var d = CGFloat.infinity
            for (j, q) in b.enumerated() where !used[j] {
                let dj = hypot(p.x - q.x, p.y - q.y)
                if dj < d { d = dj; nearest = j }
            }
            guard nearest >= 0 else { break }
            used[nearest] = true
            sum += (1 - Double(k) / Double(n)) * Double(d)
        }
        return sum
    }
}
