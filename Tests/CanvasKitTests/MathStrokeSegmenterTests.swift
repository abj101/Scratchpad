#if DEBUG
import CoreGraphics
import XCTest
@testable import CanvasKit

final class MathStrokeSegmenterTests: XCTestCase {
    private let color = RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1)

    private func stroke(_ points: [(CGFloat, CGFloat)]) -> Stroke {
        Stroke(points: points.enumerated().map { StrokePoint(x: $1.0, y: $1.1, t: Double($0) * 0.02) },
               color: color, width: 2)
    }

    // 14-high glyph strokes at origin x.
    private func two(at x: CGFloat) -> [Stroke] { [stroke([(x, 106), (x + 8, 106), (x + 8, 113), (x, 120), (x + 8, 120)])] }
    private func one(at x: CGFloat) -> [Stroke] { [stroke([(x + 3, 106), (x + 3, 120)])] }
    private func five(at x: CGFloat) -> [Stroke] {
        [stroke([(x, 112), (x + 7, 112), (x + 8, 120), (x, 120)]), stroke([(x, 106), (x + 8, 106)])]
    }
    private func ex(at x: CGFloat) -> [Stroke] {
        [stroke([(x, 110), (x + 9, 120)]), stroke([(x + 9, 110), (x, 120)])]
    }
    private func plus(at x: CGFloat) -> [Stroke] {
        [stroke([(x, 113), (x + 12, 113)]), stroke([(x + 6, 107), (x + 6, 119)])]
    }
    private func equals(at x: CGFloat) -> [Stroke] {
        [stroke([(x, 110), (x + 12, 110)]), stroke([(x, 116), (x + 12, 116)])]
    }
    private func greaterEqual(at x: CGFloat) -> [Stroke] {
        [stroke([(x, 106), (x + 10, 112), (x, 118)]), stroke([(x, 122), (x + 10, 122)])]
    }
    private func four(at x: CGFloat) -> [Stroke] {
        [stroke([(x + 6, 106), (x, 116), (x + 10, 116)]), stroke([(x + 7, 110), (x + 7, 122)])]
    }

    /// Scores a group as confident when it matches an expected stroke count, mimicking a
    /// classifier that reads `2`, `1`, `5`, `x` fine but gives a weak answer for a merged pair.
    private func segment(_ strokes: [Stroke], whole: Double, parts: Double) -> [[Stroke]] {
        MathStrokeSegmenter.segment(strokes) { group in group.count == strokes.count ? whole : parts }
    }

    private func counts(_ groups: [[Stroke]]) -> [Int] { groups.map(\.count) }

    func testSideBySideSymbolsSplit() {
        XCTAssertEqual(counts(segment(two(at: 100) + ex(at: 112), whole: 0.5, parts: 0.9)), [1, 2])
        XCTAssertEqual(counts(segment(one(at: 100) + five(at: 110), whole: 0.4, parts: 0.9)), [1, 2])
    }

    func testOverlappingStrokesStayWholeEvenWhenWholeScoresPoorly() {
        for strokes in [plus(at: 100), ex(at: 100), equals(at: 100), greaterEqual(at: 100), four(at: 100),
                        five(at: 100)] {
            XCTAssertEqual(counts(segment(strokes, whole: 0.05, parts: 0.99)), [strokes.count])
        }
    }

    func testClearGapSplitsEvenWhenWholeIsConfident() {
        XCTAssertEqual(counts(segment(one(at: 100) + one(at: 108), whole: 0.95, parts: 0.9)), [1, 1])
    }

    func testLatePiCrossbarBridgesSeparatedLegs() {
        let legsAndBar = [stroke([(100, 106), (100, 120)]),
                          stroke([(112, 106), (112, 120)]),
                          stroke([(99, 106), (114, 106)])]
        XCTAssertEqual(counts(segment(legsAndBar, whole: 0.05, parts: 0.99)), [3])
    }

    func testConfidentWholeWinsWithoutClearGap() {
        XCTAssertEqual(counts(segment(one(at: 100) + one(at: 104), whole: 0.95, parts: 0.9)), [2])
    }

    func testSinglePendingStrokeIsNeverScored() {
        var scored = 0
        let result = MathStrokeSegmenter.segment(two(at: 100)) { _ in scored += 1; return 1 }
        XCTAssertEqual(counts(result), [1])
        XCTAssertEqual(scored, 0)
    }
}

final class MathStrokeSegmentationCommitTests: XCTestCase {
    private let color = RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1)

    private func fixture(labelsByStrokeCount: [Int: String]) throws -> (CanvasView, CanvasModel) {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let view = CanvasView(model: model, settings: CanvasSettings())
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = 700
        view.mathTidyEnabledForTesting = true
        view.mathLineDecoderForTesting = MathLineDecoder(languageModel: try XCTUnwrap(MathLanguageModel.bundled),
                                                         lambda: 0, tauSub: 0.8, tauRev: 0.9)
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let labels = ["2", "x", "π", "5", "7"]
        let classes = try labels.map { label in try XCTUnwrap(vocabulary.classes.first { $0.labels == [label] }) }
            .sorted { $0.id < $1.id }
        // Wide inks (more than ~14 wide) read as the wrong merged glyph; narrow ones as expected.
        view.mathGlyphClassifier = MathGlyphClassifier(testClasses: classes, temperature: 1,
            decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9, disabledLabels: [])) { _, _, globals in
            let wide = globals[0] >= 0.5
            return classes.map { c -> Double in
                switch c.labels[0] {
                case "π": return wide ? 3 : -3
                case "7": return wide ? 2 : -3
                case "2": return globals[0] < 0.2 ? 3 : 0
                case "x": return !wide && globals[0] >= 0.2 ? 3 : 0
                default: return -3
                }
            }
        }
        return (view, model)
    }

    private func line(_ points: [(CGFloat, CGFloat)]) -> Stroke {
        Stroke(points: points.enumerated().map { StrokePoint(x: $1.0, y: $1.1, t: Double($0) * 0.02) },
               color: color, width: 2)
    }

    func testTwoSymbolsCommitInOrderWithOneUndoStep() throws {
        let (view, model) = try fixture(labelsByStrokeCount: [:])
        let a = line([(100, 106), (108, 106), (108, 113), (100, 120), (108, 120)])
        let b = line([(112, 108), (121, 120)])
        let c = line([(121, 108), (112, 120)])
        view.pendingLetter = [a, b, c]
        model.undoManager.beginUndoGrouping()
        view.commitPendingLetter(follow: false)
        model.undoManager.endUndoGrouping()
        XCTAssertEqual(view.writtenLetters.count, 2)
        XCTAssertEqual(view.writtenLetters.map { $0.originalStrokes.count }, [1, 2])
        XCTAssertLessThan(view.writtenLetters[0].extent.maxX, view.writtenLetters[1].extent.minX)
        model.undoManager.undo()
        XCTAssertTrue(view.writtenLetters.isEmpty)
        XCTAssertTrue(model.strokes.isEmpty)
    }
}
#endif
