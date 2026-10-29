import XCTest
@testable import CanvasKit

final class StrokeModelerTests: XCTestCase {
    /// Deterministic pseudo-noise in -1...1.
    private func noise(_ i: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + 78.233) * 43758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }

    /// A 100 Hz horizontal drag at 100 pt/s with perpendicular noise.
    private func noisyLine(count: Int = 60, amplitude: Double = 1.5) -> [(p: CGPoint, t: Double)] {
        (0..<count).map { i in
            (CGPoint(x: 10 + Double(i), y: 50 + noise(i) * amplitude), Double(i) * 0.01)
        }
    }

    private func run(_ input: [(p: CGPoint, t: Double)], params: StrokeModelerParams = .default) -> [ModeledPoint] {
        var m = StrokeModeler(params: params)
        var out = m.begin(input[0].p, t: input[0].t)
        for s in input.dropFirst().dropLast() { out += m.update(s.p, t: s.t) }
        out += m.end(input.last!.p, t: input.last!.t)
        return out
    }

    func testNoiseIsReduced() {
        let input = noisyLine()
        let out = run(input)
        func rms(_ ys: [Double]) -> Double { sqrt(ys.map { ($0 - 50) * ($0 - 50) }.reduce(0, +) / Double(ys.count)) }
        let before = rms(input.map { Double($0.p.y) })
        let after = rms(out.dropFirst(10).map { Double($0.position.y) })
        XCTAssertLessThan(after, before * 0.6)
    }

    func testEndReachesLastInput() {
        let input = noisyLine()
        let out = run(input)
        let last = out.last!.position, target = input.last!.p
        XCTAssertLessThan(hypot(last.x - target.x, last.y - target.y), 1)
    }

    func testTimesAreNonDecreasing() {
        let out = run(noisyLine())
        XCTAssertTrue(zip(out, out.dropFirst()).allSatisfy { $0.time <= $1.time })
        XCTAssertEqual(out.first?.time, 0)
    }

    func testTapYieldsPointAtLocation() {
        var m = StrokeModeler()
        let p = CGPoint(x: 5, y: 7)
        var out = m.begin(p, t: 1)
        out += m.end(p, t: 1.05)
        XCTAssertGreaterThanOrEqual(out.count, 1)
        XCTAssertEqual(out.last!.position.x, 5, accuracy: 0.01)
        XCTAssertEqual(out.last!.position.y, 7, accuracy: 0.01)
    }

    func testPredictionAheadOfPenAndEmptyAfterEnd() {
        var m = StrokeModeler()
        var out = m.begin(.zero, t: 0)
        for i in 1...40 { out += m.update(CGPoint(x: Double(i), y: 0), t: Double(i) * 0.01) }
        let head = out.last!.position
        let prediction = m.predict()
        XCTAssertFalse(prediction.isEmpty)
        XCTAssertGreaterThan(prediction.last!.position.x, head.x)
        XCTAssertLessThanOrEqual(prediction.last!.position.x, 40.5)
        XCTAssertLessThanOrEqual(prediction.last!.time - out.last!.time, 0.025)
        _ = m.end(CGPoint(x: 40, y: 0), t: 0.41)
        XCTAssertTrue(m.predict().isEmpty)
    }

    func testToolControllerIsScaleInvariant() {
        func stroke(scale: CGFloat) -> [CGPoint] {
            let model = CanvasModel()
            let tc = ToolController(model: model, settings: CanvasSettings())
            tc.inputScale = scale
            let input = noisyLine(count: 40)
            let origin = CGPoint(x: 500, y: 300)
            func w(_ p: CGPoint) -> CGPoint {
                CGPoint(x: origin.x + (p.x - 10) * scale, y: origin.y + (p.y - 50) * scale)
            }
            tc.handle(PenEvent(phase: .began, point: w(input[0].p), timestamp: input[0].t))
            for s in input.dropFirst().dropLast() { tc.handle(PenEvent(phase: .moved, point: w(s.p), timestamp: s.t)) }
            tc.handle(PenEvent(phase: .ended, point: w(input.last!.p), timestamp: input.last!.t))
            return model.strokes[0].points.map { CGPoint(x: ($0.x - origin.x) / scale, y: ($0.y - origin.y) / scale) }
        }
        let a = stroke(scale: 1), b = stroke(scale: 0.1)
        XCTAssertEqual(a.count, b.count)
        for (p, q) in zip(a, b) {
            XCTAssertEqual(p.x, q.x, accuracy: 0.01)
            XCTAssertEqual(p.y, q.y, accuracy: 0.01)
        }
    }

    func testToolControllerPredictionLifecycle() {
        let tc = ToolController(model: CanvasModel(), settings: CanvasSettings())
        var dirty = CGRect.null
        tc.onLiveChange = { dirty = dirty.union($0) }
        tc.handle(PenEvent(phase: .began, point: .zero, timestamp: 0))
        for i in 1...10 { tc.handle(PenEvent(phase: .moved, point: CGPoint(x: Double(i) * 3, y: 0), timestamp: Double(i) * 0.01)) }
        XCTAssertFalse(tc.livePrediction.isEmpty)
        XCTAssertGreaterThanOrEqual(dirty.maxX, tc.livePrediction.last!.x)
        tc.handle(PenEvent(phase: .ended, point: CGPoint(x: 30, y: 0), timestamp: 0.11))
        XCTAssertTrue(tc.livePrediction.isEmpty)
    }
}
