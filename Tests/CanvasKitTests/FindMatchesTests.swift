import XCTest
@testable import CanvasKit

@MainActor
final class FindMatchesTests: XCTestCase {
    override func setUp() { MockHandwritingRecognizer.version = 1 }

    func block(_ text: String, at origin: CGPoint) -> TextBlock {
        TextBlock(origin: origin, height: 20, content: TextBlock.content(from: NSAttributedString(string: text)))
    }

    func testTextMatchesAreCaseAndDiacriticInsensitiveWithRanges() {
        let b = block("Café au lait, CAFE", at: .zero)
        let matches = FindMatches.text("cafe", in: [b])
        XCTAssertEqual(matches.map(\.kind), [.text(blockID: b.id, range: NSRange(location: 0, length: 4)),
                                             .text(blockID: b.id, range: NSRange(location: 14, length: 4))])
        XCTAssertTrue(FindMatches.text("zzz", in: [b]).isEmpty)
        XCTAssertTrue(FindMatches.text("", in: [b]).isEmpty)
    }

    func testEquationSourceSearchHighlightsContainingAttachment() {
        let content = NSMutableAttributedString(string: "f(x) = ")
        content.append(NSAttributedString(attachment: EquationAttachment(latex: #"\frac{x^2}{\alpha}"#,
                                                                           fontSize: 16)))
        content.append(NSAttributedString(string: " + 1"))
        let b = TextBlock(origin: .zero, content: TextBlock.content(from: content))

        let matches = FindMatches.text("alpha", in: [b])
        XCTAssertEqual(matches.map(\.kind), [.text(blockID: b.id, range: NSRange(location: 7, length: 1))])
    }

    func testReadingOrderMixesTextAndInk() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let low = inkStroke(CGRect(x: 0, y: 300, width: 20, height: 30))
        let high = inkStroke(CGRect(x: 100, y: 0, width: 20, height: 30))
        mock.texts[low.id] = "find me"
        mock.texts[high.id] = "also FIND"
        model.add(low); model.add(high)
        let text = block("find here", at: CGPoint(x: 0, y: 150))
        model.addTextBlock(text)
        let indexer = HandwritingIndexer(model: model, recognizer: mock, cache: nil, delay: 5)
        await indexer.flushNow()

        let ink = await FindMatches.ink("find", cache: indexer.cache, strokes: model.strokes, recognizer: mock)
        let all = FindMatches.ordered(FindMatches.text("find", in: model.textBlocks) + ink)
        XCTAssertEqual(all.map(\.kind), [.ink(strokeIDs: [high.id]),
                                         .text(blockID: text.id, range: NSRange(location: 0, length: 4)),
                                         .ink(strokeIDs: [low.id])])
        XCTAssertEqual(all[0].bounds, high.bounds)
    }

    func testInkSkipsLinesWithoutQueryOrWithoutRecognizer() async {
        let mock = MockHandwritingRecognizer()
        let model = CanvasModel()
        let s = inkStroke(CGRect(x: 0, y: 0, width: 20, height: 30))
        mock.texts[s.id] = "hello"
        model.add(s)
        let indexer = HandwritingIndexer(model: model, recognizer: mock, cache: nil, delay: 5)
        await indexer.flushNow()
        let none = await FindMatches.ink("world", cache: indexer.cache, strokes: model.strokes, recognizer: mock)
        XCTAssertTrue(none.isEmpty)
        let noRecognizer = await FindMatches.ink("hello", cache: indexer.cache, strokes: model.strokes, recognizer: nil)
        XCTAssertTrue(noRecognizer.isEmpty)
    }

    func testInkFallsBackToLineBoundsWhenSearchFindsNothing() async {
        let mock = MockHandwritingRecognizer()
        let s = inkStroke(CGRect(x: 0, y: 0, width: 20, height: 30))
        mock.texts[s.id] = "hello"
        // The cache says "hello" but the recognizer's own search (mock: per-stroke text) finds nothing for "ell".
        let line = HandwritingLines.group([s])[0]
        let cache = HandwritingCache(recognitionVersion: 1, lines: [
            .init(digest: "x", strokeIDs: line.strokeIDs, bounds: line.bounds, text: "Hélló")])
        mock.texts[s.id] = "other"
        let matches = await FindMatches.ink("hello", cache: cache, strokes: [s], recognizer: mock)
        XCTAssertEqual(matches.map(\.bounds), [line.bounds])
    }

    func testReplaceStrokesWithTextBlockIsOneUndoStep() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let a = inkStroke(CGRect(x: 0, y: 0, width: 10, height: 10)), b = inkStroke(CGRect(x: 20, y: 0, width: 10, height: 10))
        um.beginUndoGrouping(); model.add(a); model.add(b); um.endUndoGrouping()
        let tb = block("hi", at: .zero)
        um.beginUndoGrouping()
        model.replace(strokeIDs: [a.id, b.id], with: tb, actionName: "Convert to Text")
        um.endUndoGrouping()
        XCTAssertTrue(model.strokes.isEmpty)
        XCTAssertEqual(model.textBlocks.map(\.id), [tb.id])
        XCTAssertEqual(um.undoActionName, "Convert to Text")
        um.undo()
        XCTAssertEqual(model.strokes.map(\.id), [a.id, b.id])
        XCTAssertTrue(model.textBlocks.isEmpty)
        um.redo()
        XCTAssertTrue(model.strokes.isEmpty)
        XCTAssertEqual(model.textBlocks.map(\.id), [tb.id])
    }
}
