import XCTest
@testable import CanvasKit

final class ScribeMathToggleTests: XCTestCase {
    func testMathKeepsScribeLifecycleActive() throws {
        try XCTSkipUnless(InputMode.scribe.isAvailable)
        XCTAssertEqual(CanvasSettings.effectiveMode(.write, handwritingToText: true), .scribe)
        XCTAssertEqual(CanvasSettings.effectiveMode(.write, handwritingToText: true, math: true), .scribe)
        XCTAssertEqual(CanvasSettings.effectiveMode(.scribe, handwritingToText: true, math: true), .scribe)
        XCTAssertEqual(CanvasSettings.effectiveMode(.pen, handwritingToText: true, math: true), .pen)
        XCTAssertTrue(CanvasSettings.offersScribeZones(.write, handwritingToText: true))
        XCTAssertFalse(CanvasSettings.offersScribeZones(.write, handwritingToText: false))
        XCTAssertFalse(CanvasSettings.offersScribeZones(.tablet, handwritingToText: true))
    }

    func testZonesAreTheTrackpadEdges() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 50)
        func rounded(_ zone: CGRect) -> [CGFloat] {
            let w = WritingLayout.worldRect(ofZone: zone, in: r)
            return [w.minX, w.minY, w.width, w.height].map { $0.rounded() }
        }
        XCTAssertEqual(rounded(WritingLayout.scribeAdvanceZone), [75, 0, 25, 50])
        XCTAssertEqual(rounded(WritingLayout.scribeDeleteZone), [0, 0, 25, 50])
    }

    // MARK: Zone taps

    private func source() -> (TabletInputSource, RecordingSink, () -> [Int]) {
        let source = TabletInputSource(mapping: TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 160, height: 100), inset: 0))
        let sink = RecordingSink()
        source.sink = sink
        source.buttonZones = WritingLayout.scribeZones
        var taps: [Int] = []
        source.onZoneTap = { taps.append($0) }
        return (source, sink, { taps })
    }

    private func touch(_ x: CGFloat, _ y: CGFloat, id: Int = 1) -> [TouchSample] {
        [TouchSample(id: AnyHashable(id), normalized: CGPoint(x: x, y: y))]
    }

    func testQuickTapsHitTheirZoneWithoutDrawing() {
        let (s, sink, taps) = source()
        s.penChanged(.down, timestamp: 0)
        s.touchesChanged(touch(0.97, 0.5), timestamp: 1)
        s.touchesChanged(touch(0.98, 0.5), timestamp: 1.1)
        s.touchesChanged([], timestamp: 1.2)
        s.touchesChanged(touch(0.02, 0.2, id: 2), timestamp: 2)
        s.touchesChanged([], timestamp: 2.1)
        XCTAssertEqual(taps(), [0, 1])
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testTapWorksWithPenUp() {
        let (s, _, taps) = source()
        s.touchesChanged(touch(0.02, 0.8), timestamp: 1)
        s.touchesChanged([], timestamp: 1.1)
        XCTAssertEqual(taps(), [1])
    }

    func testLongPressOrDragInZoneDoesNotTap() {
        let (s, sink, taps) = source()
        s.penChanged(.down, timestamp: 0)
        s.touchesChanged(touch(0.97, 0.5), timestamp: 1)
        s.touchesChanged([], timestamp: 2)
        s.touchesChanged(touch(0.97, 0.5, id: 2), timestamp: 3)
        s.touchesChanged(touch(0.3, 0.5, id: 2), timestamp: 3.1)
        s.touchesChanged([], timestamp: 3.2)
        XCTAssertEqual(taps(), [])
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testOutsideZonesStillDraws() {
        let (s, sink, taps) = source()
        s.penChanged(.down, timestamp: 0)
        s.touchesChanged(touch(0.5, 0.05), timestamp: 1)
        s.touchesChanged([], timestamp: 1.1)
        XCTAssertEqual(taps(), [])
        XCTAssertEqual(sink.phases, [.began, .ended])
    }
}
