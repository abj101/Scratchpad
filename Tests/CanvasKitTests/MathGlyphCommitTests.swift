#if DEBUG
import CoreGraphics
import XCTest
@testable import CanvasKit

final class MathGlyphCommitTests: XCTestCase {
    private func setup(group: String) -> (CanvasView, CanvasModel) {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let view = CanvasView(model: model, settings: CanvasSettings())
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = 700
        view.mathTidyEnabledForTesting = true
        view.mathGlyphClassifier = MathGlyphClassifier(testGroups: [group, "glyph_u0033"]) { _ in
            [group: 0.98, "glyph_u0033": 0.02]
        }
        return (view, model)
    }

    private func v2Classifier(labels: [String], logits: [Double],
                              disabledLabels: Set<String> = []) throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let classes = try labels.map { label in
            try XCTUnwrap(vocabulary.classes.first { $0.labels == [label] })
        }
        return MathGlyphClassifier(testClasses: classes, temperature: 1,
                                   decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9,
                                                               disabledLabels: disabledLabels)) { _, _, _ in logits }
    }

    private func ink(x: CGFloat = 110, y: CGFloat = 106, height: CGFloat = 10) -> Stroke {
        Stroke(points: [StrokePoint(x: x, y: y, t: 0),
                        StrokePoint(x: x + 6, y: y + height, t: 0.1)],
               color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1), width: 2)
    }

    private func commit(_ view: CanvasView, _ model: CanvasModel, _ stroke: Stroke) {
        view.pendingLetter = [stroke]
        model.undoManager.beginUndoGrouping()
        view.commitPendingLetter(follow: false)
        model.undoManager.endUndoGrouping()
    }

    func testActualCommitStoresRecognitionWithoutOutputInkAndSupportsUndo() throws {
        let (view, model) = setup(group: "glyph_u0032")
        let original = ink()
        commit(view, model, original)
        let letter = try XCTUnwrap(view.writtenLetters.last)
        XCTAssertEqual(letter.originalStrokes, [original])
        XCTAssertEqual(letter.label, "2")
        XCTAssertTrue(model.strokes.isEmpty)
        XCTAssertEqual(view.mathResolverStats?.heights.count, 1)

        model.undoManager.undo()
        XCTAssertTrue(model.strokes.isEmpty)
        XCTAssertTrue(view.writtenLetters.isEmpty)
        XCTAssertNil(view.mathResolverStats)
        model.undoManager.redo()
        XCTAssertEqual(view.writtenLetters.last?.originalStrokes, [original])
        XCTAssertEqual(view.mathResolverStats?.heights.count, 1)
    }

    func testCaseGroupUsesV2DecoderMarginalAndNoGenericResolverAnchor() {
        let (view, model) = setup(group: "ambig_case_c")
        commit(view, model, ink())
        commit(view, model, ink(x: 145))
        XCTAssertEqual(view.writtenLetters.map(\.label), ["c", "c"])
        XCTAssertTrue(view.mathResolverStats?.heights.isEmpty ?? true)
    }

    func testDisplayedLowercaseUpdatesLineStatsButNotResolverStats() throws {
        let (view, model) = setup(group: "glyph_u0065")
        view.mathGlyphClassifier = try v2Classifier(labels: ["e"], logits: [40])
        commit(view, model, ink())
        XCTAssertEqual(view.writtenLetters.last?.label, "e")
        XCTAssertEqual(view.mathLineStats?.heights.count, 1)
        XCTAssertTrue(view.mathResolverStats?.heights.isEmpty ?? true)

        view.mathGlyphClassifier = MathGlyphClassifier(testGroups: ["ambig_case_c", "glyph_u0033"]) { _ in
            ["ambig_case_c": 0.98, "glyph_u0033": 0.02]
        }
        commit(view, model, ink(x: 145))
        XCTAssertEqual(view.writtenLetters.last?.label, "c")
        XCTAssertTrue(view.mathResolverStats?.heights.isEmpty ?? true)
    }

    func testSecondCleanDigitUsesOriginalHandwritingGeometry() throws {
        let (view, model) = setup(group: "glyph_u0032")
        commit(view, model, ink())
        let baseline = try XCTUnwrap(view.mathLineStats?.baseline)
        commit(view, model, ink(x: 145, y: 110, height: 8))
        let second = try XCTUnwrap(view.writtenLetters.last)
        XCTAssertEqual(second.originalStrokes.first?.points.map(\.x), [145, 151])
        XCTAssertEqual(second.originalStrokes.first?.points.map(\.y), [110, 118])
        XCTAssertEqual(try XCTUnwrap(view.mathLineStats?.baseline), 119, accuracy: 1e-8)
        XCTAssertNotEqual(try XCTUnwrap(view.mathLineStats?.baseline), baseline)
        XCTAssertTrue(model.strokes.isEmpty)
    }

    func testMathModeBarAndRingResolveToDigits() {
        // Math input prefers digits for the merged bar and ring classes (neutral splits left
        // both unresolved before); the glyph still commits through the same path.
        // Legacy-v1 stub only: since F5, `l` is its own v2 class, so ambig_one_bar may resolve to `l`.
        let (view, model) = setup(group: "ambig_one_bar")
        commit(view, model, ink(height: 10))
        XCTAssertTrue(["1", "l"].contains(view.writtenLetters.last?.label ?? ""))
        let (ringView, ringModel) = setup(group: "ambig_circle")
        commit(ringView, ringModel, ink(height: 10))
        XCTAssertEqual(ringView.writtenLetters.last?.label, "0")
    }

    func testV2IsolatedRingAndBarSubstituteDigitsInMathMode() throws {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        for (classID, expected) in [("ring", "0"), ("bar", "1")] {
            let glyphClass = try XCTUnwrap(vocabulary.classes.first { $0.id == classID })
            let (view, model) = setup(group: "glyph_u0032")
            view.mathGlyphClassifier = MathGlyphClassifier(
                testClasses: [glyphClass], temperature: 1,
                decoderConfiguration: .init(lambda: 0.6, tauSub: 0.8, tauRev: 0.9, disabledLabels: [])) { _, _, _ in [4] }
            commit(view, model, ink())
            XCTAssertEqual(view.writtenLetters.last?.displayed, expected, classID)
        }
    }

    func testDeleteRestoresPriorResolverStateAndUndoRestoresOriginals() throws {
        let (view, model) = setup(group: "glyph_u0032")
        let first = ink(), second = ink(x: 145, height: 11)
        commit(view, model, first)
        let firstHeight = try XCTUnwrap(view.mathResolverStats?.medianHeight)
        commit(view, model, second)
        model.undoManager.beginUndoGrouping()
        view.deleteLastLetter()
        model.undoManager.endUndoGrouping()
        XCTAssertEqual(view.writtenLetters.count, 1)
        XCTAssertEqual(view.mathResolverStats?.medianHeight, firstHeight)
        model.undoManager.undo()
        XCTAssertEqual(view.writtenLetters.count, 2)
        XCTAssertEqual(view.writtenLetters.last?.originalStrokes, [second])
    }

    func testRecognizedEquationSymbolsHaveNoOutputInkIdentity() throws {
        let (view, model) = setup(group: "glyph_u0032")
        let original = ink()
        commit(view, model, original)
        XCTAssertTrue(view.writtenLetters.last?.ids.isEmpty ?? false)
        XCTAssertEqual(view.writtenLetters.last?.originalStrokes, [original])
        XCTAssertTrue(model.strokes.isEmpty)
    }

    func testLowMarginalBodySymbolsRemainPendingWithoutRecordingStats() throws {
        for (labels, logits, disabled) in [
            (["2", "3", "4"], [0.0, 0.0, 0.0], Set<String>()),
        ] {
            let (view, model) = setup(group: "glyph_u0032")
            view.mathGlyphClassifier = try v2Classifier(labels: labels, logits: logits,
                                                        disabledLabels: disabled)
            let original = ink()
            commit(view, model, original)
            XCTAssertEqual(view.unresolvedMathStrokes, [original])
            XCTAssertEqual(view.pendingLetter, [original])
            XCTAssertTrue(model.strokes.isEmpty)
            XCTAssertTrue(view.mathLineStats?.heights.isEmpty ?? true)
            XCTAssertTrue(view.mathResolverStats?.heights.isEmpty ?? true)
        }
    }

    func testActualCommitClassifiesPreTidyRaster() {
        let (view, model) = setup(group: "glyph_u0032")
        let original = Stroke(points: [StrokePoint(x: 110, y: 106, t: 0),
                                       StrokePoint(x: 112, y: 106.4, t: 0.1),
                                       StrokePoint(x: 114, y: 105.7, t: 0.2),
                                       StrokePoint(x: 117, y: 106, t: 0.3)],
                              color: .black, width: 2)
        let expected = GlyphRaster.rasterize([original])
        let tidied = GlyphRaster.rasterize(MathInkTidy.tidy([original], cellHeight: 32))
        XCTAssertNotEqual(expected, tidied)
        var classified = false
        view.mathGlyphClassifier = MathGlyphClassifier(testGroups: ["glyph_u0032", "glyph_u0033"]) { pixels in
            XCTAssertEqual(pixels, expected)
            classified = true
            return ["glyph_u0032": 0.8, "glyph_u0033": 0.2]
        }
        commit(view, model, original)
        XCTAssertTrue(classified)
        XCTAssertEqual(view.writtenLetters.last?.originalStrokes, [original])
    }
}
#endif
