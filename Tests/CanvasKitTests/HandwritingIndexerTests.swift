import XCTest
@testable import CanvasKit

@MainActor
final class HandwritingIndexerTests: XCTestCase {
    override func setUp() { MockHandwritingRecognizer.version = 1 }

    /// A one-stroke line at row `row`.
    func line(_ row: Int, text: String, _ mock: MockHandwritingRecognizer) -> Stroke {
        let s = inkStroke(CGRect(x: 0, y: Double(row) * 200, width: 20, height: 30))
        mock.texts[s.id] = text
        return s
    }

    func makeIndexer(_ model: CanvasModel, _ mock: MockHandwritingRecognizer?, cache: HandwritingCache? = nil,
                     delay: TimeInterval = 0.05) -> HandwritingIndexer {
        HandwritingIndexer(model: model, recognizer: mock, cache: cache, delay: delay)
    }

    func testRecognizesLinesAndPublishes() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        model.add(line(1, text: "two", mock))
        model.add(line(0, text: "one", mock))
        let indexer = makeIndexer(model, mock)
        var updates = 0
        indexer.onUpdate = { _ in updates += 1 }
        await indexer.flushNow()
        XCTAssertEqual(indexer.cache?.text, "one\ntwo")
        XCTAssertEqual(indexer.cache?.recognitionVersion, 1)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(mock.calls.count, 2)
    }

    func testDebounceCoalesces() async throws {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let indexer = makeIndexer(model, mock, delay: 0.2)
        for i in 0..<3 {
            model.add(line(i, text: "l\(i)", mock))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(mock.calls.isEmpty)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(mock.calls.count, 3)
        XCTAssertEqual(indexer.cache?.lines.count, 3)
    }

    func testUnchangedLinesNotRerecognized() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        model.add(line(0, text: "a", mock))
        let indexer = makeIndexer(model, mock)
        await indexer.flushNow()
        model.add(line(1, text: "b", mock))
        await indexer.flushNow()
        XCTAssertEqual(mock.calls.count, 2)
        XCTAssertEqual(indexer.cache?.text, "a\nb")
        await indexer.flushNow()
        XCTAssertEqual(mock.calls.count, 2)
    }

    func testStoredCacheReused() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let s = line(0, text: "fresh", mock)
        model.add(s)
        let stored = HandwritingCache(recognitionVersion: 1, lines: [
            .init(digest: HandwritingCache.digest(of: [s]), strokeIDs: [s.id], bounds: s.bounds, text: "cached")])
        let indexer = makeIndexer(model, mock, cache: stored)
        await indexer.flushNow()
        XCTAssertTrue(mock.calls.isEmpty)
        XCTAssertEqual(indexer.cache?.text, "cached")
    }

    func testVersionMismatchDropsCache() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let s = line(0, text: "fresh", mock)
        model.add(s)
        let stored = HandwritingCache(recognitionVersion: 99, lines: [
            .init(digest: HandwritingCache.digest(of: [s]), strokeIDs: [s.id], bounds: s.bounds, text: "stale")])
        let indexer = makeIndexer(model, mock, cache: stored)
        await indexer.flushNow()
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(indexer.cache?.text, "fresh")
        XCTAssertEqual(indexer.cache?.recognitionVersion, 1)
    }

    func testEditMidRunRestarts() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        model.add(line(0, text: "a", mock))
        model.add(line(1, text: "b", mock))
        let late = line(2, text: "c", mock)
        mock.latency = 50_000_000
        var added = false
        // The recognizer runs off the main actor; edit the model from it as a user would.
        mock.onCall = { [unowned model] in
            Task { @MainActor in
                if !added { added = true; model.add(late) }
            }
        }
        let indexer = makeIndexer(model, mock)
        await indexer.flushNow()
        XCTAssertEqual(indexer.cache?.text, "a\nb\nc")
        // First line recognized once; the abandoned pass kept its finished work.
        XCTAssertEqual(mock.calls.count, 3)
    }

    func testRemovedLinesDropped() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let a = line(0, text: "a", mock), b = line(1, text: "b", mock)
        model.add(a); model.add(b)
        let indexer = makeIndexer(model, mock)
        await indexer.flushNow()
        model.remove(ids: [a.id])
        await indexer.flushNow()
        XCTAssertEqual(indexer.cache?.text, "b")
        XCTAssertEqual(mock.calls.count, 2)
        model.remove(ids: [b.id])
        await indexer.flushNow()
        XCTAssertEqual(indexer.cache?.lines, [])
    }

    func testNilTextCachedAsEmptyAndNotRetried() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let a = line(0, text: "a", mock)
        mock.nilFor = [a.id]
        model.add(a)
        let indexer = makeIndexer(model, mock)
        await indexer.flushNow()
        XCTAssertEqual(indexer.cache?.lines.map(\.text), [""])
        await indexer.flushNow()
        XCTAssertEqual(mock.calls.count, 1)
    }

    func testNilRecognizerDoesNothing() async {
        let model = CanvasModel()
        model.add(inkStroke(CGRect(x: 0, y: 0, width: 20, height: 30)))
        let indexer = makeIndexer(model, nil)
        await indexer.flushNow()
        XCTAssertNil(indexer.cache)
    }

    func testChainsExistingHooksEitherOrder() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        var before = 0, after = 0
        model.onChange = { _ in before += 1 }
        let indexer = makeIndexer(model, mock)
        let installed = model.onChange
        model.onChange = { r in installed?(r); after += 1 }   // a later hook that chains too
        model.add(line(0, text: "a", mock))
        await indexer.flushNow()
        XCTAssertEqual(before, 1)
        XCTAssertEqual(after, 1)
        XCTAssertEqual(indexer.cache?.text, "a")
    }

    func testInPlaceMoveReindexes() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let a = line(0, text: "a", mock)
        model.add(a)
        let indexer = makeIndexer(model, mock)
        await indexer.flushNow()
        model.onStrokesChange?([a.id])
        await indexer.flushNow()
        XCTAssertEqual(indexer.cache?.text, "a")
    }
}
