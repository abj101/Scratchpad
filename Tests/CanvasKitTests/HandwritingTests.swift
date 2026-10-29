import XCTest
@testable import CanvasKit

/// A stroke running diagonally across `rect` (bounds are the rect plus width padding).
func inkStroke(_ rect: CGRect, width: Double = 2, id: UUID = UUID()) -> Stroke {
    Stroke(id: id, points: [StrokePoint(x: rect.minX, y: rect.minY, t: 0),
                            StrokePoint(x: rect.maxX, y: rect.maxY, t: 0.1)], color: .black, width: width)
}

final class HandwritingLinesTests: XCTestCase {
    func ids(_ lines: [HandwritingLine]) -> [[UUID]] { lines.map(\.strokeIDs) }

    func testEmpty() {
        XCTAssertEqual(HandwritingLines.group([]), [])
    }

    func testTwoRowsInReadingOrder() {
        let a1 = inkStroke(CGRect(x: 0, y: 0, width: 20, height: 30))
        let a2 = inkStroke(CGRect(x: 40, y: 2, width: 20, height: 30))
        let b1 = inkStroke(CGRect(x: 0, y: 100, width: 20, height: 30))
        let b2 = inkStroke(CGRect(x: 40, y: 102, width: 20, height: 30))
        let lines = HandwritingLines.group([b2, a2, b1, a1])
        XCTAssertEqual(ids(lines), [[a1.id, a2.id], [b1.id, b2.id]])
    }

    func testStrokesLeftToRightWithinLine() {
        let s = (0..<4).map { inkStroke(CGRect(x: Double($0) * 30, y: 0, width: 20, height: 30)) }
        XCTAssertEqual(ids(HandwritingLines.group(s.reversed())), [s.map(\.id)])
    }

    func testSmallStrokesJoinTheirLine() {
        let letter = inkStroke(CGRect(x: 0, y: 20, width: 12, height: 40))
        let word = inkStroke(CGRect(x: 30, y: 20, width: 12, height: 40))
        let dot = inkStroke(CGRect(x: 4, y: 6, width: 1, height: 1))      // i-dot above the letter
        let bar = inkStroke(CGRect(x: 28, y: 30, width: 18, height: 1))   // crossbar between
        let lines = HandwritingLines.group([letter, word, dot, bar])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(Set(lines[0].strokeIDs), [letter.id, word.id, dot.id, bar.id])
    }

    func testWideGapSplitsLine() {
        let a = inkStroke(CGRect(x: 0, y: 0, width: 20, height: 30))
        let b = inkStroke(CGRect(x: 40, y: 0, width: 20, height: 30))
        let far = inkStroke(CGRect(x: 600, y: 0, width: 20, height: 30))
        let lines = HandwritingLines.group([a, b, far])
        XCTAssertEqual(ids(lines), [[a.id, b.id], [far.id]])
    }

    func testModerateGapKeepsWordsTogether() {
        let a = inkStroke(CGRect(x: 0, y: 0, width: 20, height: 30))
        let b = inkStroke(CGRect(x: 100, y: 0, width: 20, height: 30))
        XCTAssertEqual(HandwritingLines.group([a, b]).count, 1)
    }

    func testBoundsAreUnion() {
        let a = inkStroke(CGRect(x: 0, y: 0, width: 20, height: 30))
        let b = inkStroke(CGRect(x: 40, y: 0, width: 20, height: 30))
        XCTAssertEqual(HandwritingLines.group([a, b])[0].bounds, a.bounds.union(b.bounds))
    }

    func testSingleStroke() {
        let a = inkStroke(CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertEqual(ids(HandwritingLines.group([a])), [[a.id]])
    }
}

final class InkNormalizationTests: XCTestCase {
    func testShrinksMedianToTarget() {
        let strokes = (0..<3).map { inkStroke(CGRect(x: Double($0) * 100 + 500, y: 300, width: 40, height: 120)) }
        let n = InkNormalization(strokes: strokes)
        let h = strokes[0].bounds.height
        XCTAssertEqual(n.scale, 12 / h, accuracy: 1e-9)
        let origin = strokes.reduce(CGRect.null) { $0.union($1.bounds) }.origin
        let p = n.toPaper(origin)
        XCTAssertEqual(p.x, 72, accuracy: 1e-9)
        XCTAssertEqual(p.y, 72, accuracy: 1e-9)
    }

    func testNeverEnlarges() {
        let n = InkNormalization(strokes: [inkStroke(CGRect(x: 0, y: 0, width: 4, height: 4))])
        XCTAssertEqual(n.scale, 1)
    }

    func testToWorldInvertsTransform() {
        let strokes = [inkStroke(CGRect(x: 200, y: 400, width: 80, height: 90)),
                       inkStroke(CGRect(x: 300, y: 410, width: 80, height: 90))]
        let n = InkNormalization(strokes: strokes)
        let rect = strokes[1].bounds
        let paper = CGRect(origin: n.toPaper(rect.origin), size: CGSize(width: rect.width * n.scale, height: rect.height * n.scale))
        let back = n.toWorld(paper)
        XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-6)
        XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-6)
        XCTAssertEqual(back.width, rect.width, accuracy: 1e-6)
        XCTAssertEqual(back.height, rect.height, accuracy: 1e-6)
    }

    func testEmptyIsIdentity() {
        let n = InkNormalization(strokes: [])
        XCTAssertEqual(n.transform, .identity)
    }
}

final class HandwritingCacheTests: XCTestCase {
    func entry(_ text: String) -> HandwritingCache.Entry {
        .init(digest: "d\(text)", strokeIDs: [UUID()], bounds: CGRect(x: 1, y: 2, width: 3, height: 4), text: text)
    }

    func testRoundTripThroughDocument() throws {
        var doc = NoteDocument()
        doc.handwriting = HandwritingCache(recognitionVersion: 3, lines: [entry("hello"), entry("")])
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(decoded.handwriting, doc.handwriting)
        XCTAssertEqual(decoded.version, NoteDocument.currentVersion)
    }

    func testOldJSONWithoutKeyDecodes() throws {
        let data = try JSONEncoder().encode(NoteDocument())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "handwriting")
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.handwriting)
    }

    func testTextJoinsNonEmptyLines() {
        let c = HandwritingCache(recognitionVersion: 1, lines: [entry("one"), entry(""), entry("two")])
        XCTAssertEqual(c.text, "one\ntwo")
    }

    func testDigestStableAndOrderIndependent() {
        let a = inkStroke(CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = inkStroke(CGRect(x: 20, y: 0, width: 10, height: 10))
        XCTAssertEqual(HandwritingCache.digest(of: [a, b]), HandwritingCache.digest(of: [b, a]))
        XCTAssertEqual(HandwritingCache.digest(of: [a, b]), HandwritingCache.digest(of: [a, b]))
    }

    func testDigestChangesWithGeometry() {
        let a = inkStroke(CGRect(x: 0, y: 0, width: 10, height: 10))
        var moved = a
        moved.points[1].x += 1
        var wider = a
        wider.width = 3
        let base = HandwritingCache.digest(of: [a])
        XCTAssertNotEqual(base, HandwritingCache.digest(of: [moved]))
        XCTAssertNotEqual(base, HandwritingCache.digest(of: [wider]))
        var recolored = a
        recolored.color = .red
        XCTAssertEqual(base, HandwritingCache.digest(of: [recolored]))
    }

    func testAutosaverWritesHandwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = CanvasModel()
        let saver = NoteAutosaver(model: model, url: dir.appendingPathComponent("n.scratchpad"))
        saver.handwriting = HandwritingCache(recognitionVersion: 2, lines: [entry("hi")])
        saver.markDirty()
        XCTAssertTrue(saver.flush())
        let loaded = try NotePackage.read(from: dir.appendingPathComponent("n.scratchpad"))
        XCTAssertEqual(loaded.handwriting?.text, "hi")
    }
}
