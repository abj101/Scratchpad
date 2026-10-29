#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

final class MathFractionCommitTests: XCTestCase {
    private struct Fixture {
        let view: CanvasView
        let model: CanvasModel
    }

    private func fixture() throws -> Fixture {
        let settings = CanvasSettings()
        settings.handwritingToText = false
        settings.inputMode = .write
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let view = CanvasView(model: model, settings: settings)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = 700
        view.mathTidyEnabledForTesting = true
        view.mathLineDecoderForTesting = MathLineDecoder(languageModel: try XCTUnwrap(MathLanguageModel.bundled),
                                                         lambda: 0, tauSub: 0.8, tauRev: 0.9)
        return Fixture(view: view, model: model)
    }

    private func classifier(for label: String) throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let glyphClass = try XCTUnwrap(vocabulary.classes.first { $0.labels == [label] },
                                       "Expected a singleton math class for \(label)")
        return MathGlyphClassifier(testClasses: [glyphClass], temperature: 1,
                                   decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9,
                                                               disabledLabels: [])) { _, _, _ in [40] }
    }

    @discardableResult
    private func commit(_ label: String, in fixture: Fixture, x: CGFloat? = nil,
                        y: CGFloat = 106, height: CGFloat = 10) throws -> CanvasView.WrittenLetter {
        fixture.view.mathGlyphClassifier = try classifier(for: label)
        let originX = x ?? (fixture.view.writingCell?.cursorX ?? 110)
        let stroke = Stroke(points: [StrokePoint(x: originX, y: y, t: 0),
                                     StrokePoint(x: originX + 6, y: y + height, t: 0.1)],
                            color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1), width: 2)
        fixture.view.pendingLetter = [stroke]
        fixture.view.commitPendingLetter(follow: false)
        return try XCTUnwrap(fixture.view.writtenLetters.last)
    }

    private func key(_ code: UInt16, chars: String = "",
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code))
    }

    private func fractions(in row: MathFraction.Row?) -> [MathFraction.Fraction] {
        guard let row else { return [] }
        return row.items.flatMap { item -> [MathFraction.Fraction] in
            guard case .fraction(let fraction) = item else { return [] }
            return [fraction] + fractions(in: fraction.numerator) + fractions(in: fraction.denominator)
        }
    }

    private func row(_ id: UUID, in root: MathFraction.Row?) -> MathFraction.Row? {
        guard let root else { return nil }
        if root.id == id { return root }
        for item in root.items {
            guard case .fraction(let fraction) = item else { continue }
            if let found = row(id, in: fraction.numerator) { return found }
            if let found = row(id, in: fraction.denominator) { return found }
        }
        return nil
    }

    func testRecognizedFractionKeepsStructuredRowsAndAddsNoInk() throws {
        let fixture = try fixture()
        let numerator = try commit("3", in: fixture)
        _ = try commit("/", in: fixture)

        let fraction = try XCTUnwrap(fractions(in: fixture.view.mathFractionRoot).first)
        XCTAssertEqual(fraction.numerator.items.flatMap(\.letterIDs), [numerator.id])
        XCTAssertTrue(fraction.denominator.items.isEmpty)
        XCTAssertTrue(fixture.model.strokes.isEmpty)
        XCTAssertTrue(fixture.view.writtenLetters.allSatisfy { $0.ids.isEmpty })
    }

    func testUncertainRecognitionStaysAsOriginalInputWithoutAdvancing() throws {
        let fixture = try fixture()
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let classes = try ["2", "3", "4"].map { label in
            try XCTUnwrap(vocabulary.classes.first { $0.labels == [label] })
        }
        fixture.view.mathGlyphClassifier = MathGlyphClassifier(
            testClasses: classes, temperature: 1,
            decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9, disabledLabels: [])) { _, _, _ in [0, 0, 0] }
        let stroke = Stroke(points: [StrokePoint(x: 110, y: 106, t: 0), StrokePoint(x: 116, y: 116, t: 0.1)],
                            color: .black, width: 2)
        fixture.view.pendingLetter = [stroke]
        fixture.view.commitPendingLetter(follow: false)

        XCTAssertEqual(fixture.view.unresolvedMathStrokes, [stroke])
        XCTAssertEqual(fixture.view.pendingLetter, [stroke])
        XCTAssertTrue(fixture.view.writtenLetters.isEmpty)
        XCTAssertTrue(fixture.model.strokes.isEmpty)
    }

    func testHandwrittenSlashTriggersOnTopRankedLabelNotPosterior() {
        // Top-ranked `/` triggers at any posterior; a non-top-ranked `/` does not.
        XCTAssertTrue(MathFraction.shouldTrigger(.recognized(label: "/", posterior: 0.12),
                                                 nestingDepth: 0))
        XCTAssertFalse(MathFraction.shouldTrigger(.recognized(label: "−", posterior: 0.9),
                                                  nestingDepth: 0))
        XCTAssertFalse(MathFraction.shouldTrigger(.recognized(label: "/", posterior: 0.9),
                                                  nestingDepth: MathFraction.fractionDepthLimit))
        XCTAssertFalse(MathFraction.shouldTrigger(.slashKey, nestingDepth: MathFraction.fractionDepthLimit))
    }

    func testDigitThenSlashPutsThePendingDigitInTheNumerator() throws {
        let fixture = try fixture()
        let view = fixture.view
        view.useScribeMathForTesting()
        view.mathGlyphClassifier = try classifier(for: "3")
        let stroke = Stroke(points: [StrokePoint(x: 110, y: 106, t: 0),
                                     StrokePoint(x: 116, y: 116, t: 0.1)],
                            color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1), width: 2)
        view.pendingLetter = [stroke]
        XCTAssertTrue(view.handleWritingKey(try key(44, chars: "/")),
                      "The slash key must be handled by Scribe math")

        let digit = try XCTUnwrap(view.writtenLetters.last, "The pending digit commits before the fraction")
        let fraction = try XCTUnwrap(fractions(in: fixture.view.mathFractionRoot).first)
        XCTAssertEqual(fraction.numerator.items.flatMap(\.letterIDs), [digit.id],
                       "The digit just written becomes the numerator, not an empty fraction")
        XCTAssertTrue(fraction.denominator.items.isEmpty)
    }

    func testDeletedTrailingLetterIsNotPulledIntoNextFraction() throws {
        let fixture = try fixture()
        let kept = try commit("a", in: fixture)
        _ = try commit("b", in: fixture)
        fixture.model.undoManager.beginUndoGrouping()
        fixture.view.deleteLastLetter()
        fixture.model.undoManager.endUndoGrouping()
        XCTAssertTrue(fixture.view.handleWritingKey(try key(44, chars: "/")))

        let fraction = try XCTUnwrap(fractions(in: fixture.view.mathFractionRoot).first)
        XCTAssertEqual(fraction.numerator.items.flatMap(\.letterIDs), [kept.id],
                       "The surviving letter fills the numerator; the deleted one must not reappear")
    }
}
#endif
