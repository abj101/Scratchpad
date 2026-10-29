import XCTest
@testable import CanvasKit

/// Lines are 20 pt tall from y = 100. Each paragraph is `10 * lines` characters
/// long and ends in "\n"; the column is x 28...428.
private struct FakeZoneLayout: ZoneLayoutQuerying {
    var paragraphLines: [Int]
    var trailingNewline = true
    let lineHeight: CGFloat = 20
    var textTop: CGFloat { 100 }
    var columnRect: CGRect { CGRect(x: 28, y: 100, width: 400, height: 1000) }

    var paragraphStarts: [Int] {
        var starts = [0]
        var offset = 0
        for lines in paragraphLines { offset += lines * 10; starts.append(offset) }
        return trailingNewline ? starts : Array(starts.dropLast())
    }
    var characterCount: Int { paragraphLines.reduce(0) { $0 + $1 * 10 } }

    func lineBottom(ofCharacterAt index: Int) -> CGFloat? {
        guard index >= 0, index < characterCount else { return nil }
        var offset = 0
        var lines = 0
        for count in paragraphLines {
            offset += count * 10
            lines += count
            if index < offset { return textTop + CGFloat(lines) * lineHeight }
        }
        return nil
    }
}

final class DrawingZoneTests: XCTestCase {
    private func stroke(_ x: Double, _ y: Double, _ x2: Double, _ y2: Double) -> Stroke {
        Stroke(points: [StrokePoint(x: x, y: y, t: 0), StrokePoint(x: x2, y: y2, t: 1)], color: .black, width: 2)
    }

    private func zone(minY: CGFloat, minX: CGFloat = 60, width: CGFloat = 100, height: CGFloat = 60,
                      paragraph: Int = 0, dy: Double = 0) -> DrawingZone {
        DrawingZone(strokeIDs: [UUID()], rect: CGRect(x: minX, y: minY, width: width, height: height),
                    paragraphIndex: paragraph, dy: dy)
    }

    // MARK: Anchor choice

    func testChooseAnchorPicksLastParagraphWhoseReferenceIsAtOrAboveTheZone() {
        // Paragraphs of 2, 1 and 3 lines: starts 0, 20, 30, 60; references 100, 140, 160, 220.
        let layout = FakeZoneLayout(paragraphLines: [2, 1, 3])
        let table: [(minY: CGFloat, paragraph: Int, dy: Double)] = [
            (50, 0, -50), (100, 0, 0), (139, 0, 39), (140, 20, 0), (155, 20, 15),
            (160, 30, 0), (219, 30, 59), (220, 60, 0), (900, 60, 680),
        ]
        for row in table {
            let anchor = DrawingZones.chooseAnchor(forMinY: row.minY, in: layout)
            XCTAssertEqual(anchor.paragraphIndex, row.paragraph, "minY \(row.minY)")
            XCTAssertEqual(anchor.dy, row.dy, accuracy: 0.001, "minY \(row.minY)")
        }
    }

    func testChooseAnchorWithoutTrailingNewlineNeverPicksTheLength() {
        let layout = FakeZoneLayout(paragraphLines: [2, 1], trailingNewline: false)
        XCTAssertEqual(layout.paragraphStarts, [0, 20])
        XCTAssertEqual(DrawingZones.chooseAnchor(forMinY: 900, in: layout).paragraphIndex, 20)
    }

    // MARK: Index shifting

    func testShiftedIndexTable() {
        // After the edit the text is "ab\ncd\nef\n": paragraphs start at 0, 3, 6, 9.
        let starts = [0, 3, 6, 9]
        let table: [(name: String, index: Int, range: NSRange, delta: Int, expected: Int)] = [
            ("insert above moves it", 6, NSRange(location: 0, length: 0), 3, 9),
            ("insert before a paragraph start keeps the paragraph", 3, NSRange(location: 0, length: 0), 3, 6),
            ("insert below leaves it", 3, NSRange(location: 8, length: 0), 1, 3),
            ("typing at its start snaps back to the start", 3, NSRange(location: 3, length: 0), 1, 3),
            ("typing inside the paragraph", 3, NSRange(location: 5, length: 0), 1, 3),
            ("deleting a paragraph above", 6, NSRange(location: 0, length: 3), -3, 3),
            ("deleting its own start collapses to the edit", 6, NSRange(location: 5, length: 2), -2, 3),
            ("merging paragraphs (deleted newline)", 6, NSRange(location: 2, length: 1), -1, 3),
            ("replacement shorter (7 snaps to its paragraph)", 9, NSRange(location: 0, length: 4), -2, 6),
        ]
        for row in table {
            let result = DrawingZones.shiftedIndex(row.index, editedRange: row.range, changeInLength: row.delta,
                                                   paragraphStarts: starts, characterCount: 9)
            XCTAssertEqual(result, row.expected, row.name)
        }
    }

    func testShiftedIndexSnapsToTheParagraphContainingIt() {
        // Inserting "x\ny" at the very start of a paragraph that began at 3.
        // The index moves to 6, which is mid-paragraph in "ab\nx\ny cd" and snaps to 5.
        let starts = [0, 3, 5]
        XCTAssertEqual(DrawingZones.shiftedIndex(3, editedRange: NSRange(location: 3, length: 0), changeInLength: 3,
                                                 paragraphStarts: starts, characterCount: 9), 5)
        // The text can end with "\n": the length itself is a paragraph start.
        XCTAssertEqual(DrawingZones.shiftedIndex(5, editedRange: NSRange(location: 5, length: 0), changeInLength: 1,
                                                 paragraphStarts: [0, 6], characterCount: 6), 6)
    }

    // MARK: Reflow

    func testReflowMovesZoneToReferencePlusDy() {
        var layout = FakeZoneLayout(paragraphLines: [2, 1, 3])
        let anchored = zone(minY: 150, paragraph: 20, dy: 10) // reference 140
        XCTAssertTrue(DrawingZones.reflowMoves([anchored], in: layout).isEmpty)

        layout.paragraphLines = [4, 1, 3] // two more lines above: reference 180
        let moves = DrawingZones.reflowMoves([anchored], in: layout)
        XCTAssertEqual(moves[anchored.id]?.dy ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(moves[anchored.id]?.dx ?? 1, 0, accuracy: 0.001)
    }

    func testReflowIgnoresSubHalfPointDrift() {
        let layout = FakeZoneLayout(paragraphLines: [2, 1, 3])
        XCTAssertTrue(DrawingZones.reflowMoves([zone(minY: 150.4, paragraph: 20, dy: 10)], in: layout).isEmpty)
        XCTAssertFalse(DrawingZones.reflowMoves([zone(minY: 150.6, paragraph: 20, dy: 10)], in: layout).isEmpty)
    }

    func testReflowClampsHorizontallyIntoTheColumn() {
        let layout = FakeZoneLayout(paragraphLines: [2])
        let overflowing = zone(minY: 100, minX: 380, width: 100) // maxX 480, column maxX 428
        XCTAssertEqual(DrawingZones.reflowMoves([overflowing], in: layout)[overflowing.id]?.dx ?? 0, -52, accuracy: 0.001)

        // Wider than the column: stops at the left edge.
        let wide = zone(minY: 100, minX: 40, width: 500)
        XCTAssertEqual(DrawingZones.reflowMoves([wide], in: layout)[wide.id]?.dx ?? 0, -12, accuracy: 0.001)

        // Already left of the column: left alone.
        let margin = zone(minY: 100, minX: 0, width: 500)
        XCTAssertNil(DrawingZones.reflowMoves([margin], in: layout)[margin.id])
    }

    // MARK: Exclusion rects

    func testNarrowSidesAreClosedOffAndBothNarrowMeansFullWidth() {
        let column = CGRect(x: 28, y: 100, width: 400, height: 1000)
        // Column spans x 28...428; a side is closed when under 96 pt wide.
        let table: [(name: String, x: CGFloat, width: CGFloat, minX: CGFloat, maxX: CGFloat)] = [
            ("right margin", 328, 100, 328, 428),
            ("left margin", 28, 100, 28, 128),
            ("centered with room on both", 150, 130, 150, 280),
            ("sliver on the right closes it", 150, 200, 150, 428),
            ("sliver on the left closes it", 100, 150, 28, 250),
            ("96 pt on the left is enough", 124, 150, 124, 274),
            ("95 pt on the left is not", 123, 150, 28, 273),
            ("slivers on both sides", 100, 300, 28, 428),
        ]
        for row in table {
            let zone = DrawingZone(strokeIDs: [], rect: CGRect(x: row.x, y: 120, width: row.width, height: 60))
            let result = DrawingZones.exclusionRects([zone], column: column)[0]
            XCTAssertEqual(result, CGRect(x: row.minX, y: 120, width: row.maxX - row.minX, height: 60), row.name)
        }
    }

    func testFullWidthExclusionCoversZonesPastTheColumnEdges() {
        let column = CGRect(x: 28, y: 100, width: 400, height: 1000)
        let zone = DrawingZone(strokeIDs: [], rect: CGRect(x: 10, y: 0, width: 440, height: 50))
        XCTAssertEqual(DrawingZones.exclusionRects([zone], column: column)[0], CGRect(x: 10, y: 0, width: 440, height: 50))
    }

    // MARK: Joining, merging, removing

    func testStrokeNearAZoneJoinsItAndFarStrokeStartsANewOne() {
        let a = stroke(100, 100, 140, 140)
        let near = stroke(150, 150, 170, 170)   // within 16 pt of a's zone rect
        let far = stroke(400, 400, 420, 420)
        var strokes = [a.id: a]
        var update = DrawingZones.adding([a], to: [], strokesByID: strokes)
        XCTAssertEqual(update.zones.count, 1)
        XCTAssertEqual(update.zones[0].rect, a.bounds.insetBy(dx: -8, dy: -8))

        strokes[near.id] = near
        update = DrawingZones.adding([near], to: update.zones, strokesByID: strokes)
        XCTAssertEqual(update.zones.count, 1)
        XCTAssertEqual(update.zones[0].strokeIDs, [a.id, near.id])
        XCTAssertEqual(update.zones[0].rect, a.bounds.union(near.bounds).insetBy(dx: -8, dy: -8))
        XCTAssertEqual(update.touched, [update.zones[0].id])

        strokes[far.id] = far
        update = DrawingZones.adding([far], to: update.zones, strokesByID: strokes)
        XCTAssertEqual(update.zones.count, 2)
    }

    func testBridgingStrokeMergesZones() {
        let left = stroke(100, 100, 120, 120)
        let right = stroke(200, 100, 220, 120)
        let bridge = stroke(110, 100, 210, 120)
        let strokes = Dictionary(uniqueKeysWithValues: [left, right, bridge].map { ($0.id, $0) })
        var zones = DrawingZones.adding([left], to: [], strokesByID: strokes).zones
        zones = DrawingZones.adding([right], to: zones, strokesByID: strokes).zones
        XCTAssertEqual(zones.count, 2)
        let merged = DrawingZones.adding([bridge], to: zones, strokesByID: strokes)
        XCTAssertEqual(merged.zones.count, 1)
        XCTAssertEqual(merged.zones[0].strokeIDs, [left.id, right.id, bridge.id])
        XCTAssertEqual(merged.touched.count, 1)
    }

    func testRemovingShrinksOrDeletesZones() {
        let a = stroke(100, 100, 120, 120)
        let b = stroke(130, 100, 150, 180)
        var strokes = Dictionary(uniqueKeysWithValues: [a, b].map { ($0.id, $0) })
        let zones = DrawingZones.adding([a, b], to: [], strokesByID: strokes).zones
        XCTAssertEqual(zones.count, 1)

        strokes[b.id] = nil
        let shrunk = DrawingZones.removing([b.id], from: zones, strokesByID: strokes)
        XCTAssertEqual(shrunk.zones[0].strokeIDs, [a.id])
        XCTAssertEqual(shrunk.zones[0].rect, a.bounds.insetBy(dx: -8, dy: -8))
        XCTAssertEqual(shrunk.touched, [zones[0].id])

        strokes[a.id] = nil
        XCTAssertTrue(DrawingZones.removing([a.id], from: shrunk.zones, strokesByID: strokes).zones.isEmpty)
    }

    func testGroupingUsesTheJoinDistance() {
        let strokes = [stroke(0, 0, 20, 20), stroke(30, 0, 50, 20), stroke(300, 300, 320, 320)]
        let zones = DrawingZones.grouping(strokes)
        XCTAssertEqual(zones.count, 2)
        XCTAssertEqual(zones[0].strokeIDs, [strokes[0].id, strokes[1].id])
        XCTAssertEqual(zones[1].strokeIDs, [strokes[2].id])
    }
}
