import Foundation

/// Deterministic 32×32 glyph raster shared with `scripts/glyphs/raster.py`.
public enum GlyphRaster {
    private static let size = 32
    private static let q8: Int64 = 1 << 8
    private static let q16 = 1 << 16
    private static let center: Int64 = 16 * q8
    private static let halfSpan: Int64 = 13 * q8
    private static let coordinateLimit = 200_000.0

    private struct Point {
        let x: Int64
        let y: Int64
    }

    private struct RawPoint {
        let x: Double
        let y: Double
    }

    /// Rasterize raw world-coordinate strokes into 1,024 row-major grayscale bytes.
    /// Empty or invalid input yields a white raster. Stroke color, width, and time are ignored.
    public static func rasterize(_ strokes: [Stroke]) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: size * size)
        guard let paths = normalized(strokes) else { return pixels }

        for path in paths {
            guard let first = path.first else { continue }
            if path.count == 1 {
                drawSegment(first, first, into: &pixels)
            } else {
                for index in 1..<path.count {
                    drawSegment(path[index - 1], path[index], into: &pixels)
                }
            }
        }
        return pixels
    }

    private static func normalized(_ strokes: [Stroke]) -> [[Point]]? {
        var rawPaths: [[RawPoint]] = []
        var minX = Double.infinity
        var minY = Double.infinity

        for stroke in strokes {
            let path = stroke.points.map { RawPoint(x: $0.x, y: $0.y) }
            guard !path.isEmpty else { continue }
            for point in path {
                guard point.x.isFinite, point.y.isFinite,
                      abs(point.x) <= coordinateLimit, abs(point.y) <= coordinateLimit else { return nil }
                minX = min(minX, point.x)
                minY = min(minY, point.y)
            }
            rawPaths.append(path)
        }
        guard !rawPaths.isEmpty else { return [] }

        let sourcePaths = rawPaths.map { path in
            path.map { point in
                Point(
                    x: Int64(((point.x - minX) * Double(q16)).rounded(.toNearestOrAwayFromZero)),
                    y: Int64(((point.y - minY) * Double(q16)).rounded(.toNearestOrAwayFromZero))
                )
            }
        }
        let allPoints = sourcePaths.flatMap { $0 }
        let spanX = allPoints.map(\.x).max() ?? 0
        let spanY = allPoints.map(\.y).max() ?? 0
        let span = max(spanX, spanY)
        guard span > 0 else {
            return sourcePaths.map { path in path.map { _ in Point(x: center, y: center) } }
        }

        return sourcePaths.map { path in
            path.map { point in
                Point(
                    x: center + roundedRatio((2 * point.x - spanX) * halfSpan, by: span),
                    y: center + roundedRatio((2 * point.y - spanY) * halfSpan, by: span)
                )
            }
        }
    }

    private static func roundedRatio(_ numerator: Int64, by denominator: Int64) -> Int64 {
        let magnitude = numerator >= 0 ? numerator : -numerator
        let rounded = (magnitude + denominator / 2) / denominator
        return numerator >= 0 ? rounded : -rounded
    }

    /// Pixel-center distance test for a round-capped line segment of radius one pixel.
    private static func drawSegment(_ start: Point, _ end: Point, into pixels: inout [UInt8]) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let radiusSquared = q8 * q8
        let minX = max(0, Int(min(start.x, end.x) / q8) - 1)
        let maxX = min(size - 1, Int(max(start.x, end.x) / q8) + 1)
        let minY = max(0, Int(min(start.y, end.y) / q8) - 1)
        let maxY = min(size - 1, Int(max(start.y, end.y) / q8) + 1)

        for y in minY...maxY {
            let py = Int64(y) * q8 + q8 / 2
            for x in minX...maxX {
                let px = Int64(x) * q8 + q8 / 2
                let vx = px - start.x
                let vy = py - start.y
                let projection = vx * dx + vy * dy
                let inside: Bool
                if projection <= 0 {
                    inside = vx * vx + vy * vy <= radiusSquared
                } else if projection >= lengthSquared {
                    let ex = px - end.x
                    let ey = py - end.y
                    inside = ex * ex + ey * ey <= radiusSquared
                } else {
                    let cross = vx * dy - vy * dx
                    inside = cross * cross <= radiusSquared * lengthSquared
                }
                if inside { pixels[y * size + x] = 0 }
            }
        }
    }
}
