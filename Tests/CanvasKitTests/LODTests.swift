import XCTest
@testable import CanvasKit

final class LODTests: XCTestCase {
    private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func noisyStroke(count: Int = 200) -> Stroke {
        var rng = SystemRandomNumberGenerator()
        var x = 0.0, y = 0.0
        let pts = (0..<count).map { i -> StrokePoint in
            x += 1; y += Double.random(in: -0.8...0.8, using: &rng)
            return StrokePoint(x: x, y: y, t: Double(i))
        }
        return Stroke(points: pts, color: .black, width: 2)
    }

    // MARK: Levels

    func testLevelForMagnification() {
        XCTAssertEqual(StrokeLOD.level(for: 1), 0)
        XCTAssertEqual(StrokeLOD.level(for: 2), 0)
        XCTAssertEqual(StrokeLOD.level(for: 8), 0)
        XCTAssertEqual(StrokeLOD.level(for: 0.5), 1)
        XCTAssertEqual(StrokeLOD.level(for: 0.25), 2)
        XCTAssertEqual(StrokeLOD.level(for: 0.3), 2)
        XCTAssertEqual(StrokeLOD.level(for: 0.1), 4)
    }

    func testToleranceForLevel() {
        XCTAssertEqual(StrokeLOD.tolerance(for: 0), 0)
        XCTAssertEqual(StrokeLOD.tolerance(for: 1), 1)
        XCTAssertEqual(StrokeLOD.tolerance(for: 2), 2)
        XCTAssertEqual(StrokeLOD.tolerance(for: 4), 8)
    }

    // MARK: Simplify

    func testKeepsEndpointsAndDropsCollinear() {
        let pts = (0...10).map { pt(Double($0), Double($0) * 2) }
        XCTAssertEqual(StrokeLOD.simplify(pts, tolerance: 0.1), [pts.first!, pts.last!])
    }

    func testKeepsCorner() {
        let pts = [pt(0, 0), pt(5, 0), pt(10, 0), pt(10, 5), pt(10, 10)]
        XCTAssertEqual(StrokeLOD.simplify(pts, tolerance: 0.5), [pt(0, 0), pt(10, 0), pt(10, 10)])
    }

    func testRespectsTolerance() {
        let s = noisyStroke(count: 500)
        let pts = s.points.map(\.cgPoint)
        for tol in [0.25, 1, 4] as [CGFloat] {
            let out = StrokeLOD.simplify(pts, tolerance: tol)
            XCTAssertEqual(out.first, pts.first)
            XCTAssertEqual(out.last, pts.last)
            XCTAssertLessThan(out.count, pts.count)
            var seg = 0 // index into `out` of the current segment's start
            for p in pts {
                if seg + 1 < out.count - 1, p == out[seg + 1] { seg += 1 }
                XCTAssertLessThanOrEqual(distance(p, toSegment: out[seg], out[seg + 1]), tol + 1e-9)
            }
        }
    }

    func testZeroToleranceIsIdentity() {
        let pts = noisyStroke(count: 50).points.map(\.cgPoint)
        XCTAssertEqual(StrokeLOD.simplify(pts, tolerance: 0), pts)
        XCTAssertEqual(StrokeLOD.simplify(pts, tolerance: -1), pts)
    }

    func testSmallInputs() {
        XCTAssertEqual(StrokeLOD.simplify([], tolerance: 5), [])
        XCTAssertEqual(StrokeLOD.simplify([pt(1, 1)], tolerance: 5), [pt(1, 1)])
        XCTAssertEqual(StrokeLOD.simplify([pt(1, 1), pt(2, 2)], tolerance: 5), [pt(1, 1), pt(2, 2)])
    }

    func testClosedLoopKeepsFarPoint() {
        let pts = [pt(0, 0), pt(5, 5), pt(0, 0)]
        XCTAssertEqual(StrokeLOD.simplify(pts, tolerance: 1), pts)
    }

    func testLargeInputDoesNotRecurse() {
        let n = 100_000
        let circle = (0..<n).map { i -> CGPoint in
            let a = Double(i) / Double(n) * 2 * .pi
            return pt(cos(a) * 500, sin(a) * 500)
        }
        let out = StrokeLOD.simplify(circle, tolerance: 1)
        XCTAssertGreaterThan(out.count, 10)
        XCTAssertLessThan(out.count, 200)
        // Deep, lopsided splits must not overflow the stack.
        let parabola = (0..<20_000).map { i -> CGPoint in pt(Double(i), Double(i * i) / 20_000) }
        XCTAssertGreaterThan(StrokeLOD.simplify(parabola, tolerance: 0.01).count, 2)
        let line = (0..<n).map { pt(Double($0), 0) }
        XCTAssertEqual(StrokeLOD.simplify(line, tolerance: 1).count, 2)
    }

    // MARK: Stroke paths

    func testLevelZeroPathMatchesFullPath() {
        let s = noisyStroke()
        XCTAssertEqual(s.path(level: 0).boundingBox, s.path.boundingBox)
    }

    func testHigherLevelsHaveFewerElements() {
        let s = noisyStroke(count: 400)
        func count(_ path: CGPath) -> Int {
            var n = 0
            path.applyWithBlock { _ in n += 1 }
            return n
        }
        let counts = (0...4).map { count(s.path(level: $0)) }
        XCTAssertLessThan(counts[1], counts[0])
        XCTAssertLessThanOrEqual(counts[4], counts[2])
        XCTAssertLessThan(counts[4], counts[0] / 2)
    }

    func testSimplifiedPathStaysNearFullPath() {
        let s = noisyStroke()
        let full = s.path.boundingBox, lod = s.path(level: 3).boundingBox
        XCTAssertLessThan(abs(full.maxX - lod.maxX), 1e-9)
        XCTAssertLessThan(abs(full.maxY - lod.maxY), StrokeLOD.tolerance(for: 3) + 1)
    }

    func testSinglePointAndTwoPointLevelPaths() {
        let dot = Stroke(points: [StrokePoint(x: 3, y: 4, t: 0)], color: .black, width: 2)
        XCTAssertFalse(dot.path(level: 2).isEmpty)
        XCTAssertEqual(dot.path(level: 2).currentPoint, CGPoint(x: 3, y: 4))
        let seg = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 9, y: 9, t: 1)], color: .black, width: 2)
        XCTAssertEqual(seg.path(level: 2).currentPoint, CGPoint(x: 9, y: 9))
        let empty = Stroke(points: [], color: .black, width: 2)
        XCTAssertTrue(empty.path(level: 2).isEmpty)
    }

    // MARK: Redraw on zoom

    /// Zooming rescales existing tiles, so a magnification change that keeps the
    /// grid step and LOD level must still repaint the visible region once.
    func testZoomRepaintsVisibleRegion() {
        let model = CanvasModel(strokes: [Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 50, y: 20, t: 1)],
                                                 color: .black, width: 2)])
        let scroll = CanvasScrollView(model: model, settings: CanvasSettings())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroll.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        scroll.displayIfNeeded()
        let canvas = scroll.canvasView
        XCTAssertFalse(canvas.needsDisplay)

        scroll.magnification = 1.5
        XCTAssertEqual(StrokeLOD.level(for: 1.5), StrokeLOD.level(for: 1))
        XCTAssertTrue(canvas.needsDisplay)
        scroll.displayIfNeeded()
        XCTAssertFalse(canvas.needsDisplay)
    }
}
