import XCTest
@testable import CanvasKit

final class MathInkTidyTests: XCTestCase {
    private let acc: CGFloat = 1e-6

    // MARK: Smoothing

    /// A jittery near-horizontal line becomes smoother.
    func testSmoothRemovesJitterFromNearHorizontal() {
        let H: CGFloat = 20
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 5, y: 0.3, t: 0.1),
            StrokePoint(x: 10, y: -0.2, t: 0.2),
            StrokePoint(x: 15, y: 0.2, t: 0.3),
            StrokePoint(x: 20, y: 0, t: 0.4),
        ]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let smoothed = MathInkTidy.smooth(stroke, cellHeight: H)

        // Smoothed stroke should have more points and reduced jitter
        XCTAssertGreaterThan(smoothed.points.count, 2)
        XCTAssertEqual(smoothed.points[0], points[0])
        XCTAssertEqual(smoothed.points[smoothed.points.count - 1], points[points.count - 1])

        // Check max y-deviation is reasonable (Catmull-Rom may overshoot slightly)
        var maxDev: CGFloat = 0
        for p in smoothed.points {
            let expectedY: CGFloat = 0
            maxDev = max(maxDev, abs(p.y - expectedY))
        }
        XCTAssertLessThan(maxDev, 2)
    }

    /// Clearly curved strokes are not straightened.
    func testCurvedStrokeNotStraightened() {
        let H: CGFloat = 20
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 5, y: 5, t: 0.2),
            StrokePoint(x: 10, y: 10, t: 0.4),
            StrokePoint(x: 15, y: 5, t: 0.6),
            StrokePoint(x: 20, y: 0, t: 0.8),
        ]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let tidied = MathInkTidy.tidy([stroke], cellHeight: H)

        // The stroke should not be straightened (curve is too pronounced)
        XCTAssertGreaterThan(tidied[0].points.count, 2)
        // Endpoints preserved
        XCTAssertEqual(tidied[0].points[0].x, 0, accuracy: acc)
        XCTAssertEqual(tidied[0].points[tidied[0].points.count - 1].x, 20, accuracy: acc)
    }

    /// Smoothing reduces deviation while preserving endpoints.
    func testSmoothPreservesEndpoints() {
        let H: CGFloat = 20
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 2, y: 3, t: 0.1),
            StrokePoint(x: 4, y: -2, t: 0.2),
            StrokePoint(x: 6, y: 4, t: 0.3),
            StrokePoint(x: 8, y: 0, t: 0.4),
        ]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let smoothed = MathInkTidy.smooth(stroke, cellHeight: H)

        XCTAssertEqual(smoothed.points[0].x, 0, accuracy: acc)
        XCTAssertEqual(smoothed.points[0].y, 0, accuracy: acc)
        XCTAssertEqual(smoothed.points[0].t, 0, accuracy: acc)
        XCTAssertEqual(smoothed.points[smoothed.points.count - 1].x, 8, accuracy: acc)
        XCTAssertEqual(smoothed.points[smoothed.points.count - 1].y, 0, accuracy: acc)
        XCTAssertEqual(smoothed.points[smoothed.points.count - 1].t, 0.4, accuracy: acc)
    }

    // MARK: Straightening

    /// A nearly horizontal jittery stroke becomes exactly horizontal.
    func testStraightenHorizontalLine() {
        let H: CGFloat = 20
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 5, y: 0.3, t: 0.1),
            StrokePoint(x: 10, y: -0.2, t: 0.2),
            StrokePoint(x: 15, y: 0.4, t: 0.3),
            StrokePoint(x: 20, y: 0, t: 0.4),
        ]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let straightened = MathInkTidy.straighten(stroke, cellHeight: H)

        // Should be straightened
        XCTAssertGreaterThanOrEqual(straightened.points.count, 2)
        XCTAssertNotEqual(straightened.points, stroke.points)
        // All y-values should be very close (within 0.04 * H = 0.8 of chord)
        let yValues = straightened.points.map(\.y)
        let minY = yValues.min() ?? 0
        let maxY = yValues.max() ?? 0
        XCTAssertLessThan(maxY - minY, 0.8)
        XCTAssertTrue(yValues.allSatisfy { abs($0) < acc })
    }

    /// Vertical lines are snapped to vertical.
    func testStraightenVerticalLine() {
        let H: CGFloat = 20
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 0.3, y: 5, t: 0.1),
            StrokePoint(x: -0.2, y: 10, t: 0.2),
            StrokePoint(x: 0.4, y: 15, t: 0.3),
            StrokePoint(x: 0, y: 20, t: 0.4),
        ]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let straightened = MathInkTidy.straighten(stroke, cellHeight: H)

        // Should be straightened
        XCTAssertGreaterThanOrEqual(straightened.points.count, 2)
        // All x-values should be very close (snapped to center)
        let xValues = straightened.points.map(\.x)
        let minX = xValues.min() ?? 0
        let maxX = xValues.max() ?? 0
        XCTAssertLessThan(maxX - minX, 0.8)
    }

    /// A narrow, nearly closed ellipse is not collapsed to its endpoint chord.
    func testStraightenKeepsNarrowNearlyClosedEllipse() {
        let H: CGFloat = 20
        let gap: CGFloat = 0.5
        let points = (0...64).map { i -> StrokePoint in
            let angle = gap / 2 + CGFloat(i) / 64 * (2 * .pi - gap)
            return StrokePoint(x: 0.3 * cos(angle), y: 8 * sin(angle), t: CGFloat(i) / 64)
        }
        let stroke = Stroke(points: points, color: .black, width: 1)
        let first = points[0].cgPoint
        let last = points[points.count - 1].cgPoint
        let chord = CGPoint(x: last.x - first.x, y: last.y - first.y)
        let chordLength = hypot(chord.x, chord.y)
        let maxDeviation = points.map { point in
            abs((point.x - first.x) * chord.y - (point.y - first.y) * chord.x) / chordLength
        }.max() ?? 0
        let pathLength = zip(points, points.dropFirst()).reduce(CGFloat.zero) { length, pair in
            length + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }

        XCTAssertGreaterThanOrEqual(chordLength, 0.15 * H)
        XCTAssertLessThanOrEqual(maxDeviation, 0.04 * H)
        XCTAssertGreaterThan(pathLength, 1.15 * chordLength)
        XCTAssertEqual(MathInkTidy.straighten(stroke, cellHeight: H).points, stroke.points)
    }

    // MARK: Tidy

    /// Tidy applies straighten first, then smooth if needed.
    func testTidyAppliesPasses() {
        let H: CGFloat = 20
        // A nearly-straight line
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 5, y: 0.5, t: 0.1),
            StrokePoint(x: 10, y: -0.3, t: 0.2),
            StrokePoint(x: 15, y: 0.4, t: 0.3),
            StrokePoint(x: 20, y: 0, t: 0.4),
        ]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let tidied = MathInkTidy.tidy([stroke], cellHeight: H)

        XCTAssertEqual(tidied.count, 1)
        XCTAssertGreaterThanOrEqual(tidied[0].points.count, 2)
    }

    // MARK: LineStats

    /// LineStats with <2 entries returns identity transform.
    func testLineStatsIdentityWithFewEntries() {
        let stats = MathInkTidy.LineStats()
        let extent = CGRect(x: 0, y: 0, width: 10, height: 10)
        let transform = stats.alignTransform(extent: extent)

        XCTAssertEqual(transform.a, 1)
        XCTAssertEqual(transform.b, 0)
        XCTAssertEqual(transform.c, 0)
        XCTAssertEqual(transform.d, 1)
        XCTAssertEqual(transform.tx, 0)
        XCTAssertEqual(transform.ty, 0)
    }

    /// LineStats records heights and bottoms.
    func testLineStatsRecords() {
        var stats = MathInkTidy.LineStats()
        let e1 = CGRect(x: 0, y: 0, width: 10, height: 10)
        let e2 = CGRect(x: 10, y: 5, width: 10, height: 9)

        stats.record(e1)
        XCTAssertEqual(stats.heights, [10])
        XCTAssertEqual(stats.bottoms, [10])

        stats.record(e2)
        XCTAssertEqual(stats.heights, [10, 9])
        XCTAssertEqual(stats.bottoms, [10, 14])
    }

    /// Tall glyph (2× median) is untouched (identity).
    func testLineStatsSkipsTallGlyph() {
        var stats = MathInkTidy.LineStats()
        stats.heights = [10, 10]
        stats.bottoms = [0, 0]

        let tallGlyph = CGRect(x: 0, y: 0, width: 10, height: 25)
        let transform = stats.alignTransform(extent: tallGlyph)

        // Should be identity for tall glyphs
        XCTAssertEqual(transform.a, 1, accuracy: acc)
        XCTAssertEqual(transform.d, 1, accuracy: acc)
        XCTAssertEqual(transform.tx, 0, accuracy: acc)
        XCTAssertEqual(transform.ty, 0, accuracy: acc)
    }

    /// Body glyph (within [0.7·h̃, 1.4·h̃]) is scaled and moved.
    func testLineStatsAlignBodyGlyph() {
        var stats = MathInkTidy.LineStats()
        let medianHeight: CGFloat = 10
        stats.heights = [medianHeight, medianHeight]
        stats.bottoms = [10, 10]

        // A glyph slightly smaller and higher
        let bodyGlyph = CGRect(x: 0, y: 2, width: 8, height: 8)
        let transform = stats.alignTransform(extent: bodyGlyph)

        // Moves ~70% of the way toward median height (log space) and bottom.
        let out = bodyGlyph.applying(transform)
        XCTAssertEqual(out.height, 8 * pow(10.0 / 8, 0.7), accuracy: 0.01)
        XCTAssertEqual(out.width / out.height, 1, accuracy: 0.001)
        XCTAssertEqual(out.maxY, 10 - 0.3 * (10 - (bodyGlyph.midY + out.height / 2)), accuracy: 0.05)
    }

    /// Verify isBody classification.
    func testLineStatsBodyClassification() {
        var stats = MathInkTidy.LineStats()
        stats.heights = [10, 10]

        let small = CGRect(x: 0, y: 0, width: 5, height: 7)
        let body = CGRect(x: 0, y: 0, width: 8, height: 10)
        let tall = CGRect(x: 0, y: 0, width: 10, height: 20)

        XCTAssertTrue(stats.isBody(body))
        XCTAssertTrue(stats.isBody(small))
        XCTAssertFalse(stats.isBody(tall))
    }

    // MARK: Transform application

    /// Applying identity transform leaves stroke unchanged.
    func testApplyIdentityTransform() {
        let stroke = Stroke(points: [
            StrokePoint(x: 1, y: 2, t: 0),
            StrokePoint(x: 3, y: 4, t: 0.1),
        ], color: .black, width: 1)
        let transformed = MathInkTidy.apply(.identity, to: stroke)

        for (original, result) in zip(stroke.points, transformed.points) {
            XCTAssertEqual(original.x, result.x, accuracy: acc)
            XCTAssertEqual(original.y, result.y, accuracy: acc)
            XCTAssertEqual(original.t, result.t, accuracy: acc)
        }
    }

    /// Applying a translation preserves time.
    func testApplyTranslationPreservesTime() {
        let stroke = Stroke(points: [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 10, y: 10, t: 0.5),
        ], color: .black, width: 1)
        let transform = CGAffineTransform(translationX: 5, y: 3)
        let transformed = MathInkTidy.apply(transform, to: stroke)

        XCTAssertEqual(transformed.points[0].x, 5, accuracy: acc)
        XCTAssertEqual(transformed.points[0].y, 3, accuracy: acc)
        XCTAssertEqual(transformed.points[0].t, 0, accuracy: acc)

        XCTAssertEqual(transformed.points[1].x, 15, accuracy: acc)
        XCTAssertEqual(transformed.points[1].y, 13, accuracy: acc)
        XCTAssertEqual(transformed.points[1].t, 0.5, accuracy: acc)
    }

    // MARK: Edge cases

    /// Stroke with <3 points is returned unchanged by smooth.
    func testSmoothHandlesSmallPointCount() {
        let H: CGFloat = 20
        let points = [StrokePoint(x: 0, y: 0, t: 0)]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let smoothed = MathInkTidy.smooth(stroke, cellHeight: H)

        XCTAssertEqual(smoothed.points.count, 1)
        XCTAssertEqual(smoothed.points[0], points[0])
    }

    /// Tiny extent (<0.05·H) is returned unchanged by smooth.
    func testSmoothHandlesTinyExtent() {
        let H: CGFloat = 20
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 0.2, y: 0.1, t: 0.1),
            StrokePoint(x: 0.3, y: 0, t: 0.2),
        ]
        let stroke = Stroke(points: points, color: .black, width: 0.1)
        let smoothed = MathInkTidy.smooth(stroke, cellHeight: H)

        // Tiny strokes should be returned unchanged
        XCTAssertEqual(smoothed.points, stroke.points)
    }

    /// Stroke too short to straighten (<0.15·H) is unchanged.
    func testStraightenTooShortLine() {
        let H: CGFloat = 20
        let points = [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 1, y: 0.2, t: 0.1),
        ]
        let stroke = Stroke(points: points, color: .black, width: 1)
        let straightened = MathInkTidy.straighten(stroke, cellHeight: H)

        XCTAssertEqual(straightened.points, stroke.points)
    }

    /// LineStats respects max 8 entries.
    func testLineStatsMaxEntries() {
        var stats = MathInkTidy.LineStats()
        for i in 0..<12 {
            let e = CGRect(x: 0, y: CGFloat(i), width: 10, height: 10)
            stats.record(e)
        }

        XCTAssertEqual(stats.heights.count, 8)
        XCTAssertEqual(stats.bottoms.count, 8)
    }
}
