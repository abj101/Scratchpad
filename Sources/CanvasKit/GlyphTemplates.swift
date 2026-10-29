import CoreGraphics
import Foundation

/// Token mean (averaged glyph) computation and rendering.
public enum GlyphTemplates {
    /// Compute mean of samples with modal stroke count.
    /// Returns nil if no samples or they have no common stroke count.
    public static func mean(of samples: [GlyphSample]) -> GlyphSample? {
        guard samples.count > 0 else { return nil }

        // Find modal stroke count
        var counts: [Int: Int] = [:]
        for s in samples {
            let c = s.strokes.count
            counts[c, default: 0] += 1
        }
        guard let modalCount = counts.max(by: { $0.value < $1.value })?.key else { return nil }

        let filtered = samples.filter { $0.strokes.count == modalCount }
        guard !filtered.isEmpty else { return nil }

        // Normalize each sample to unit box
        let normalized = filtered.compactMap { sample -> [[CGPoint]]? in
            normalizeAndCenter(sample.strokes)
        }
        guard normalized.count == filtered.count else { return nil }

        // Compute average stroke lengths
        var strokeLengths: [[CGFloat]] = Array(repeating: [], count: modalCount)
        for strokes in normalized {
            for (i, stroke) in strokes.enumerated() {
                var len: CGFloat = 0
                for j in 1..<stroke.count {
                    let dx = stroke[j].x - stroke[j - 1].x
                    let dy = stroke[j].y - stroke[j - 1].y
                    len += hypot(dx, dy)
                }
                strokeLengths[i].append(len)
            }
        }

        // Target points per stroke: proportional to average length, min 8
        var targetPoints: [Int] = []
        for lengths in strokeLengths {
            let avgLen = lengths.isEmpty ? 0 : lengths.reduce(0, +) / CGFloat(lengths.count)
            let tgt = max(8, Int(round(avgLen * 20))) // ~20 pts per unit length
            targetPoints.append(tgt)
        }

        // Resample each normalized stroke to target points
        var resampled: [[[CGPoint]]] = []
        for sample in normalized {
            var strokes: [[CGPoint]] = []
            for (i, stroke) in sample.enumerated() {
                let tgt = targetPoints[i]
                let rs = resample(stroke, to: tgt)
                strokes.append(rs)
            }
            resampled.append(strokes)
        }

        // Handle stroke direction: if dot product of start→end is negative, reverse
        for i in 1..<resampled.count {
            for j in 0..<modalCount {
                guard j < resampled[i].count, j < resampled[0].count else { continue }
                let ref = resampled[0][j]
                let curr = resampled[i][j]
                if ref.count >= 2, curr.count >= 2 {
                    let refVec = CGVector(dx: ref.last!.x - ref.first!.x, dy: ref.last!.y - ref.first!.y)
                    let currVec = CGVector(dx: curr.last!.x - curr.first!.x, dy: curr.last!.y - curr.first!.y)
                    let dot = refVec.dx * currVec.dx + refVec.dy * currVec.dy
                    if dot < 0 {
                        resampled[i][j].reverse()
                    }
                }
            }
        }

        // Average point-wise
        var meanStrokes: [[CGPoint]] = []
        for j in 0..<modalCount {
            let strokes = resampled.compactMap { $0[j] }
            guard !strokes.isEmpty else { continue }
            let minLen = strokes.map(\.count).min() ?? 0
            guard minLen > 0 else { continue }

            var mean: [CGPoint] = []
            for k in 0..<minLen {
                var sumX: CGFloat = 0, sumY: CGFloat = 0
                for stroke in strokes {
                    if k < stroke.count {
                        sumX += stroke[k].x
                        sumY += stroke[k].y
                    }
                }
                mean.append(CGPoint(x: sumX / CGFloat(strokes.count), y: sumY / CGFloat(strokes.count)))
            }
            meanStrokes.append(mean)
        }

        // Average relative height
        let avgRelHeight = filtered.map(\.relativeHeight).reduce(0, +) / Double(filtered.count)

        return GlyphSample(strokes: meanStrokes, relativeHeight: avgRelHeight)
    }

    /// Render mean glyph into a bounding box with the style of original strokes.
    /// Height matches box.height; width follows mean aspect. For very flat glyphs,
    /// fit by width instead.
    public static func render(_ mean: GlyphSample, into box: CGRect, like original: [Stroke]) -> [Stroke] {
        guard !mean.strokes.isEmpty, !original.isEmpty else { return [] }

        // Compute mean bounds
        let flat = mean.strokes.flatMap { $0 }
        guard !flat.isEmpty,
              flat.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }

        let box = box.standardized
        guard box.origin.x.isFinite, box.origin.y.isFinite,
              box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else { return [] }

        var minX = flat[0].x, maxX = minX, minY = flat[0].y, maxY = minY
        for p in flat.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let meanWidth = maxX - minX
        let meanHeight = maxY - minY
        guard meanWidth.isFinite, meanHeight.isFinite else { return [] }

        // Fit: if very flat, fit by width; else by height
        let scale: CGFloat
        if meanWidth == 0, meanHeight == 0 {
            scale = 1 // A one-point dot has no intrinsic size.
        } else if meanHeight == 0 {
            scale = box.width / meanWidth
        } else if meanWidth == 0 {
            scale = box.height / meanHeight
        } else if meanHeight < 0.2 * meanWidth {
            scale = box.width / meanWidth
        } else {
            scale = box.height / meanHeight
        }
        guard scale.isFinite, scale > 0 else { return [] }

        // Center in box
        let tx = box.midX - (minX + maxX) / 2 * scale
        let ty = box.midY - (minY + maxY) / 2 * scale

        // Render strokes
        let color = original.first?.color ?? .black
        let width = original.first?.width ?? 1
        var cumDist: CGFloat = 0
        var result: [Stroke] = []

        for strokePoints in mean.strokes {
            guard !strokePoints.isEmpty else { continue }

            var points: [StrokePoint] = []
            for (i, p) in strokePoints.enumerated() {
                let pt = CGPoint(x: p.x * scale + tx, y: p.y * scale + ty)
                guard pt.x.isFinite, pt.y.isFinite else { return [] }
                if i > 0 {
                    let dx = pt.x - points.last!.cgPoint.x
                    let dy = pt.y - points.last!.cgPoint.y
                    cumDist += hypot(dx, dy)
                }
                let t = cumDist / 300 // ~300 pt/s
                guard cumDist.isFinite, t.isFinite else { return [] }
                points.append(StrokePoint(x: pt.x, y: pt.y, t: Double(t)))
            }

            let stroke = Stroke(id: UUID(), points: points, color: color, width: width)
            result.append(stroke)
        }

        return result
    }

    // MARK: - Helpers

    /// Normalize and center strokes to unit box.
    private static func normalizeAndCenter(_ strokes: [[CGPoint]]) -> [[CGPoint]]? {
        let flat = strokes.flatMap { $0 }
        guard flat.count > 0 else { return nil }

        // Centroid
        let sum = flat.reduce((x: CGFloat(0), y: CGFloat(0))) { ($0.x + $1.x, $0.y + $1.y) }
        let center = CGPoint(x: sum.x / CGFloat(flat.count), y: sum.y / CGFloat(flat.count))

        let translated = flat.map { CGPoint(x: $0.x - center.x, y: $0.y - center.y) }
        guard !translated.isEmpty else { return nil }

        // Find max dimension
        var minX = translated[0].x, maxX = minX, minY = translated[0].y, maxY = minY
        for p in translated.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let scale = max(maxX - minX, maxY - minY)
        guard scale > 0 else { return nil }

        // Re-index back to strokes and scale
        var result: [[CGPoint]] = []
        var idx = 0
        for stroke in strokes {
            let ratio = CGFloat(stroke.count) / CGFloat(flat.count)
            let count = Int(ceil(ratio * CGFloat(translated.count)))
            let slice = Array(translated[idx..<min(idx + count, translated.count)])
            let scaled = slice.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
            if !scaled.isEmpty {
                result.append(scaled)
                idx += count
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Resample a stroke to exactly n points.
    private static func resample(_ stroke: [CGPoint], to n: Int) -> [CGPoint] {
        guard stroke.count >= 2 else { return stroke }
        guard n >= 2 else { return [stroke[0]] }

        // Compute arc lengths
        var lengths: [CGFloat] = [0]
        var total: CGFloat = 0
        for i in 1..<stroke.count {
            let dx = stroke[i].x - stroke[i - 1].x
            let dy = stroke[i].y - stroke[i - 1].y
            let len = hypot(dx, dy)
            total += len
            lengths.append(total)
        }

        guard total > 0 else { return stroke }

        var result: [CGPoint] = [stroke[0]]
        for i in 1..<n - 1 {
            let target = total * CGFloat(i) / CGFloat(n - 1)
            // Binary search or linear search for simplicity
            if let idx = lengths.firstIndex(where: { $0 >= target }) {
                if idx == 0 {
                    result.append(stroke[0])
                } else {
                    let prev = lengths[idx - 1]
                    let curr = lengths[idx]
                    let frac = curr > prev ? (target - prev) / (curr - prev) : 0
                    let p0 = stroke[idx - 1]
                    let p1 = stroke[idx]
                    let interp = CGPoint(x: p0.x + frac * (p1.x - p0.x), y: p0.y + frac * (p1.y - p0.y))
                    result.append(interp)
                }
            }
        }
        result.append(stroke[stroke.count - 1])

        return Array(result.prefix(n))
    }
}
