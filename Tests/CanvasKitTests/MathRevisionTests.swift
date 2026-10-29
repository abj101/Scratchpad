#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

final class MathRevisionTests: XCTestCase {
    private let decoderConfiguration = MathGlyphClassifier.DecoderConfiguration(
        lambda: 0.6, tauSub: 0.8, tauRev: 0.9, disabledLabels: [])

    private struct Fixture {
        let view: CanvasView
        let model: CanvasModel
    }

    private func fixture(decoder: MathLineDecoder? = nil) throws -> Fixture {
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
        if let decoder {
            view.mathLineDecoderForTesting = decoder
        } else {
            view.mathLineDecoderForTesting = MathLineDecoder(
                languageModel: try XCTUnwrap(MathLanguageModel.bundled), lambda: 0.6,
                tauSub: 0.8, tauRev: 0.9)
        }
        return Fixture(view: view, model: model)
    }

    private func classifier(_ probabilities: [String: Double]) throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let labels = probabilities.keys.sorted()
        let classes = try labels.map { label in
            if let singleton = vocabulary.classes.first(where: { $0.labels == [label] }) {
                return singleton
            }
            if label == "·" { return MathVocabulary.GlyphClass(id: "dot", labels: ["·"]) }
            throw XCTSkip("No deterministic test class is available for \(label).")
        }
        let logits = labels.map { log(probabilities[$0]!) }
        return MathGlyphClassifier(testClasses: classes, temperature: 1,
                                   decoderConfiguration: decoderConfiguration) { _, _, _ in logits }
    }

    @discardableResult
    private func commit(_ labelProbabilities: [String: Double], in fixture: Fixture) throws -> CanvasView.WrittenLetter {
        fixture.view.mathGlyphClassifier = try classifier(labelProbabilities)
        let x = fixture.view.writingCell?.cursorX ?? 110
        fixture.view.pendingLetter = [Stroke(
            points: [StrokePoint(x: x, y: 106, t: 0), StrokePoint(x: x + 6, y: 116, t: 0.1)],
            color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1), width: 2)]
        fixture.model.undoManager.beginUndoGrouping()
        fixture.view.commitPendingLetter(follow: false)
        fixture.model.undoManager.endUndoGrouping()
        return try XCTUnwrap(fixture.view.writtenLetters.last)
    }

    func testBundledContextResolvesAmbiguousXAfterPlus() throws {
        // Stub context: the bundled model no longer commits an ambiguous x/dot, so pin the context.
        let languageModel = model(conditions: [
            (["<s>", "<s>", "2"], ["x": 0.5, "·": 0.5]),
            (["<s>", "2", "x"], ["+": 0.9999]),
            (["<s>", "2", "·"], ["+": 0.0001]),
        ])
        let fixture = try fixture(decoder: MathLineDecoder(languageModel: languageModel, lambda: 0.6,
                                                           tauSub: 0.8, tauRev: 0.9))
        _ = try commit(["2": 1], in: fixture)
        _ = try commit(["x": 0.1, "·": 0.9], in: fixture)
        _ = try commit(["+": 1], in: fixture)

        XCTAssertEqual(fixture.view.writtenLetters.map(\.displayed), ["2", "x", "+"])
        XCTAssertEqual(fixture.model.strokes.count, fixture.view.writtenLetters.reduce(0) { $0 + $1.ids.count })
    }

    func testNinetyFivePercentRevisionAndOneStepUndoRestoreBothGlyphs() throws {
        let likelihoods = ["x": 0.1, "·": 0.9]
        let ratio = pow((0.95 / 0.05) / (likelihoods["x"]! / likelihoods["·"]!), 1 / 0.6)
        let plusAfterX = ratio / (1 + ratio)
        let plusAfterDot = 1 / (1 + ratio)
        let languageModel = model(conditions: [
            (["<s>", "<s>", "2"], ["x": 0.5, "·": 0.5]),
            (["<s>", "2", "x"], ["+": plusAfterX]),
            (["<s>", "2", "·"], ["+": plusAfterDot]),
        ])
        let decoder = MathLineDecoder(languageModel: languageModel, lambda: 0.6,
                                      tauSub: 0.8, tauRev: 0.9)
        let fixture = try fixture(decoder: decoder)

        _ = try commit(["2": 1], in: fixture)
        let ambiguous = try commit(likelihoods, in: fixture)
        XCTAssertEqual(ambiguous.displayed, "·")
        let beforeRevisionInk = fixture.model.strokes

        _ = try commit(["+": 1], in: fixture)
        XCTAssertEqual(fixture.view.writtenLetters.map(\.displayed), ["2", "x", "+"])
        let symbols = fixture.view.writtenLetters.map {
            MathLineDecoder.Symbol(labelLikelihoods: $0.likelihoods, displayedLabel: $0.displayed)
        }
        let result = decoder.decode(symbols, newestIndex: 2, revisionIndices: [1, 0])
        XCTAssertEqual(result.marginals[1]["x"] ?? 0, 0.95, accuracy: 1e-8)

        fixture.model.undoManager.undo()
        XCTAssertEqual(fixture.view.writtenLetters.map(\.displayed), ["2", "·"])
        XCTAssertEqual(fixture.model.strokes.count, beforeRevisionInk.count)
        for stroke in beforeRevisionInk { XCTAssertTrue(fixture.model.strokes.contains(stroke)) }
    }

    func testKMinusThreeRemainsUnchangedEvenWhenNewContextWouldReviseIt() throws {
        let xLikelihood = 0.1, dotLikelihood = 0.9
        let ratio = pow((0.95 / 0.05) / (xLikelihood / dotLikelihood), 1 / 0.6)
        let sAfterX = ratio / (1 + ratio)
        let sAfterDot = 1 / (1 + ratio)
        let languageModel = model(conditions: [
            (["<s>", "<s>", "2"], ["x": 0.5, "·": 0.5]),
            (["<s>", "2", "x"], ["=": 0.5]),
            (["<s>", "2", "·"], ["=": 0.5]),
            (["2", "x", "="], ["3": 0.5]),
            (["2", "·", "="], ["3": 0.5]),
            (["x", "=", "3"], ["s": sAfterX]),
            (["·", "=", "3"], ["s": sAfterDot]),
        ])
        let decoder = MathLineDecoder(languageModel: languageModel, lambda: 0.6,
                                      tauSub: 0.8, tauRev: 0.9)
        let fixture = try fixture(decoder: decoder)

        _ = try commit(["2": 1], in: fixture)
        _ = try commit(["x": xLikelihood, "·": dotLikelihood], in: fixture)
        XCTAssertEqual(fixture.view.writtenLetters[1].displayed, "·")
        _ = try commit(["=": 1], in: fixture)
        _ = try commit(["3": 1], in: fixture)
        XCTAssertEqual(fixture.view.writtenLetters[1].displayed, "·")
        _ = try commit(["s": 1], in: fixture)

        XCTAssertEqual(fixture.view.writtenLetters.map(\.displayed), ["2", "·", "=", "3", "s"])
        let symbols = fixture.view.writtenLetters.map {
            MathLineDecoder.Symbol(labelLikelihoods: $0.likelihoods, displayedLabel: $0.displayed)
        }
        let hypothetical = decoder.decode(symbols, newestIndex: 4, revisionIndices: [1])
        XCTAssertEqual(hypothetical.revisions.first?.index, 1)
        XCTAssertEqual(hypothetical.revisions.first?.label, "x")
        XCTAssertGreaterThan(hypothetical.marginals[1]["x"] ?? 0, 0.9)
        XCTAssertEqual(fixture.view.writtenLetters[1].displayed, "·",
                       "The app only revises k−1 and k−2; k−3 stays as rendered.")
    }

    private func model(conditions: [([String], [String: Double])]) -> MathLanguageModel {
        let vocabulary = ["<s>", "<unk>", "0", "2", "3", "=", "·", "+", "s", "x"]
        let base = 1 / Double(vocabulary.count)
        var ngrams = Dictionary(uniqueKeysWithValues: vocabulary.map { (key([], $0), [log10(base), 0]) })
        for (context, probabilities) in conditions {
            for (label, probability) in probabilities {
                ngrams[key(context, label)] = [log10(probability), 0]
            }
        }
        return MathLanguageModel(vocab: vocabulary, ngrams: ngrams)
    }

    private func key(_ context: [String], _ label: String) -> String {
        context.joined(separator: "\u{001f}") + "\u{001e}" + label
    }
}
#endif
