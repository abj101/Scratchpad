import Foundation

/// Converts ordered pen strokes into the fixed 128-step math-model input.
public enum GlyphSequence {
    public static let sampleCount = 128
    public static let maximumStrokeCount = 64
    private static let coordinateLimit = 200_000.0

    public struct Features {
        /// Sample-major `[128, 4]`: x, y, stroke-start, stroke-end.
        public let strokePoints: [[Float]]
        /// Number of samples allocated to each retained stroke.
        public let sampleCounts: [Int]
    }

    private struct Point {
        let x: Double
        let y: Double
    }

    /// Return nil when there are no nonempty strokes.
    public static func encode(_ strokes: [Stroke]) -> Features? {
        var paths: [[Point]] = []
        for stroke in strokes {
            var path: [Point] = []
            for rawPoint in stroke.points {
                guard rawPoint.x.isFinite, rawPoint.y.isFinite,
                      abs(rawPoint.x) <= coordinateLimit, abs(rawPoint.y) <= coordinateLimit else {
                    return nil
                }
                let point = Point(x: rawPoint.x, y: rawPoint.y)
                if let previous = path.last, point.x == previous.x, point.y == previous.y {
                    continue
                }
                path.append(point)
            }
            if !path.isEmpty {
                paths.append(path)
                if paths.count == maximumStrokeCount { break }
            }
        }
        guard !paths.isEmpty else { return nil }

        let lengths = paths.map(arcLength)
        let counts = allocateSampleCounts(lengths)

        var minX = paths[0][0].x
        var maxX = minX
        var minY = paths[0][0].y
        var maxY = minY
        for path in paths {
            for point in path {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
        }
        let width = maxX - minX
        let height = maxY - minY
        let centerX = minX + width / 2.0
        let centerY = minY + height / 2.0
        let scale = max(max(width, height), 1e-6)

        var features: [[Float]] = []
        features.reserveCapacity(sampleCount)
        for index in paths.indices {
            let samples = resample(paths[index], count: counts[index], length: lengths[index])
            for sampleIndex in samples.indices {
                let point = samples[sampleIndex]
                features.append([
                    Float((point.x - centerX) / scale),
                    Float((point.y - centerY) / scale),
                    sampleIndex == 0 ? 1 : 0,
                    sampleIndex == samples.count - 1 ? 1 : 0,
                ])
            }
        }

        assert(features.count == sampleCount)
        assert(counts.reduce(0, +) == sampleCount)
        return Features(strokePoints: features, sampleCounts: counts)
    }

    private static func segmentLengths(_ path: [Point]) -> [Double] {
        guard path.count > 1 else { return [] }
        var lengths: [Double] = []
        lengths.reserveCapacity(path.count - 1)
        for index in 1..<path.count {
            let dx = path[index].x - path[index - 1].x
            let dy = path[index].y - path[index - 1].y
            let dxSquared = dx * dx
            let dySquared = dy * dy
            lengths.append(sqrt(dxSquared + dySquared))
        }
        return lengths
    }

    private static func arcLength(_ path: [Point]) -> Double {
        var length = 0.0
        for segmentLength in segmentLengths(path) {
            length = length + segmentLength
        }
        return length
    }

    private static func allocateSampleCounts(_ lengths: [Double]) -> [Int] {
        let strokeCount = lengths.count
        let remainder = sampleCount - 2 * strokeCount
        var totalLength = 0.0
        for length in lengths { totalLength = totalLength + length }

        if totalLength == 0 {
            let each = remainder / strokeCount
            let extra = remainder % strokeCount
            return lengths.indices.map { 2 + each + ($0 < extra ? 1 : 0) }
        }

        var bases: [Int] = []
        var fractions: [Double] = []
        var allocated = 0
        for length in lengths {
            let quota = (Double(remainder) * length) / totalLength
            let base = Int(floor(quota))
            bases.append(base)
            fractions.append(quota - Double(base))
            allocated += base
        }

        let leftover = remainder - allocated
        let order = lengths.indices.sorted { lhs, rhs in
            if fractions[lhs] == fractions[rhs] { return lhs < rhs }
            return fractions[lhs] > fractions[rhs]
        }
        var bonuses = [Int](repeating: 0, count: strokeCount)
        for index in order.prefix(leftover) { bonuses[index] = 1 }
        let counts = lengths.indices.map { 2 + bases[$0] + bonuses[$0] }
        assert(counts.reduce(0, +) == sampleCount)
        assert(counts.allSatisfy { $0 >= 2 })
        return counts
    }

    private static func resample(_ path: [Point], count: Int, length: Double) -> [Point] {
        if length == 0 { return [Point](repeating: path[0], count: count) }

        let lengths = segmentLengths(path)
        var cumulativeEnds: [Double] = []
        cumulativeEnds.reserveCapacity(lengths.count)
        var cumulative = 0.0
        for segmentLength in lengths {
            cumulative = cumulative + segmentLength
            cumulativeEnds.append(cumulative)
        }

        var samples = [path[0]]
        samples.reserveCapacity(count)
        var segmentIndex = 0
        for sampleIndex in 1..<(count - 1) {
            let target = (Double(sampleIndex) * length) / Double(count - 1)
            while segmentIndex < lengths.count,
                  lengths[segmentIndex] == 0 || cumulativeEnds[segmentIndex] < target {
                segmentIndex += 1
            }

            let segmentLength = lengths[segmentIndex]
            let segmentStart = segmentIndex == 0 ? 0.0 : cumulativeEnds[segmentIndex - 1]
            let fraction = (target - segmentStart) / segmentLength
            let first = path[segmentIndex]
            let second = path[segmentIndex + 1]
            let dx = second.x - first.x
            let dy = second.y - first.y
            let xOffset = fraction * dx
            let yOffset = fraction * dy
            samples.append(Point(x: first.x + xOffset, y: first.y + yOffset))
        }
        samples.append(path[path.count - 1])
        return samples
    }
}
