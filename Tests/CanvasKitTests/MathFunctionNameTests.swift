#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

private actor ControlledFunctionRecognizer: HandwritingRecognizer {
    nonisolated static let version = 1
    private let result: String?
    private let controlled: Bool
    private(set) var calls: [[UUID]] = []
    private var resultContinuation: CheckedContinuation<String?, Never>?

    init(result: String?, controlled: Bool = false) {
        self.result = result
        self.controlled = controlled
    }

    func text(for strokes: [Stroke]) async -> String? {
        calls.append(strokes.map(\.id))
        guard controlled else { return result }
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func search(_ query: String, in strokes: [Stroke]) async -> [HandwritingMatch] { [] }
    func words(in strokes: [Stroke]) async -> [(word: String, match: HandwritingMatch)] { [] }

    func callCount() -> Int { calls.count }
    func complete(with text: String?) { resultContinuation?.resume(returning: text); resultContinuation = nil }
}

@MainActor
final class MathFunctionNameTests: XCTestCase {
    private struct Fixture {
        let view: CanvasView
        let model: CanvasModel
    }

    private func fixture(recognizer: ControlledFunctionRecognizer, lambda: Double = 0) throws -> Fixture {
        let settings = CanvasSettings()
        settings.handwritingToText = false
        settings.inputMode = .write
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let view = CanvasView(model: model, settings: settings)
        view.useScribeMathForTesting()
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = 700
        view.mathTidyEnabledForTesting = true
        view.mathFunctionRecognizer = recognizer
        view.mathLineDecoderForTesting = MathLineDecoder(
            languageModel: try XCTUnwrap(MathLanguageModel.bundled), lambda: lambda, tauSub: 0.8, tauRev: 0.9)
        return Fixture(view: view, model: model)
    }

    private func classifier(_ label: String) throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let glyphClass = label == "l" ? MathVocabulary.GlyphClass(id: "glyph_u006C", labels: ["l"])
            : try XCTUnwrap(vocabulary.classes.first { $0.labels.contains(label) })
        return MathGlyphClassifier(testClasses: [glyphClass], temperature: 1,
                                   decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9,
                                                               disabledLabels: [])) { _, _, _ in [40] }
    }

    private func batchClassifier(labels: [String], strokes: [Stroke]) throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let classes = try labels.map { label in
            try XCTUnwrap(vocabulary.classes.first { $0.labels.contains(label) })
        }
        let rasters = strokes.map { GlyphRaster.rasterize([$0]) }
        return MathGlyphClassifier(testClasses: classes, temperature: 1,
                                   decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9,
                                                               disabledLabels: [])) { pixels, _, _ in
            guard let index = rasters.firstIndex(of: pixels) else { return Array(repeating: 0, count: classes.count) }
            return classes.indices.map { $0 == index ? 40 : -40 }
        }
    }

    private func ambiguousOneClassifier() throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let classes = [try XCTUnwrap(vocabulary.classes.first { $0.labels.contains("1") })]
        return MathGlyphClassifier(testClasses: classes, temperature: 1,
                                   decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9,
                                                               disabledLabels: [])) { _, _, _ in [40] }
    }

    private func stroke(_ x: CGFloat, _ y: CGFloat = 106, _ dx: CGFloat = 8, _ dy: CGFloat = 10) -> Stroke {
        Stroke(points: [StrokePoint(x: x, y: y, t: 0), StrokePoint(x: x + dx, y: y + dy, t: 0.1)],
               color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1), width: 2)
    }

    private func letterStroke(_ label: Character, x: CGFloat) -> Stroke {
        let path: [(CGFloat, CGFloat)]
        switch label {
        case "l": path = [(0, 0), (1, 13)]
        case "o": path = [(1, 1), (5, 0), (8, 3), (7, 8), (3, 10), (0, 7), (1, 1)]
        case "g": path = [(1, 1), (5, 0), (8, 3), (7, 8), (3, 10), (0, 7), (1, 1), (7, 8), (6, 14)]
        case "s": path = [(8, 0), (2, 1), (0, 4), (7, 6), (8, 9), (1, 10)]
        case "i": path = [(2, 1), (3, 12)]
        case "n": path = [(0, 0), (0, 10), (2, 4), (5, 2), (7, 4), (7, 10)]
        case "m": path = [(0, 0), (0, 10), (2, 3), (4, 2), (5, 4), (5, 10), (7, 3), (9, 2), (10, 4), (10, 10)]
        default: path = [(0, 0), (8, 10)]
        }
        return Stroke(points: path.enumerated().map {
            StrokePoint(x: x + $0.element.0, y: 110 + $0.element.1, t: Double($0.offset) * 0.01)
        }, color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1), width: 2)
    }

    @discardableResult
    private func commit(_ label: String, at x: CGFloat, in fixture: Fixture) throws -> CanvasView.WrittenLetter {
        fixture.view.mathGlyphClassifier = try classifier(label)
        let ink = stroke(x, 106, label == "i" || label == "l" ? 2 : 8, 10)
        let point = ink.points[0]
        fixture.view.writingStrokeBegan(at: CGPoint(x: point.x, y: point.y))
        fixture.view.writingStrokeFinished(ink)
        fixture.view.commitPendingLetter(follow: false)
        return try XCTUnwrap(fixture.view.writtenLetters.last)
    }

    private func waitForRecognition(_ recognizer: ControlledFunctionRecognizer, in view: CanvasView? = nil) async -> Bool {
        for _ in 0..<400 {
            if await recognizer.callCount() > 0 || view?.writtenLetters.contains(where: \.isFunction) == true {
                try? await Task.sleep(nanoseconds: 25_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testSequentialLogSinAndLimBecomeFunctionTokensWithoutOutputInk() async throws {
        for name in ["log", "sin", "lim"] {
            let recognizer = ControlledFunctionRecognizer(result: name)
            let fixture = try fixture(recognizer: recognizer)
            for (index, letter) in name.enumerated() {
                _ = try commit(String(letter), at: 110 + CGFloat(index) * 11, in: fixture)
            }
            let recognized = await waitForRecognition(recognizer, in: fixture.view)
            XCTAssertTrue(recognized, name)
            let callCount = await recognizer.callCount()
            XCTAssertEqual(callCount, name == "lim" ? 0 : 1, name)
            XCTAssertEqual(fixture.view.writtenLetters.count, 1, name)
            XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, name, name)
            XCTAssertTrue(fixture.view.writtenLetters.first?.isFunction == true, name)
            XCTAssertTrue(fixture.model.strokes.isEmpty, name)
        }
    }

    func testOnePendingMultiStrokeBatchCanBecomeFunctionToken() async throws {
        let recognizer = ControlledFunctionRecognizer(result: "log")
        let fixture = try fixture(recognizer: recognizer)
        fixture.view.mathGlyphClassifier = try classifier("l")
        let strokes = [stroke(110, 108, 0, 12), stroke(110, 110, 30, 0), stroke(140, 110, 2, 10)]
        let first = strokes[0].points[0]
        fixture.view.writingStrokeBegan(at: CGPoint(x: first.x, y: first.y))
        strokes.forEach { fixture.view.writingStrokeFinished($0) }
        fixture.view.commitPendingLetter(follow: false)
        let recognized = await waitForRecognition(recognizer)
        XCTAssertTrue(recognized)
        let callCount = await recognizer.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(fixture.view.writtenLetters.count, 1)
        XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, "log")
        XCTAssertTrue(fixture.view.writtenLetters.first?.isFunction == true)
        XCTAssertEqual(fixture.view.writtenLetters.first?.originalStrokes.count, 3)
    }

    func testSinglePendingBatchRecognizesLogSinAndLim() async throws {
        for name in ["log", "sin", "lim"] {
            let recognizer = ControlledFunctionRecognizer(result: name)
            let fixture = try fixture(recognizer: recognizer)
            let strokes = Array(name).enumerated().map { letterStroke($0.element, x: 110 + CGFloat($0.offset) * 10) }
            fixture.view.mathGlyphClassifier = try batchClassifier(labels: Array(name).map(String.init), strokes: strokes)
            let first = strokes[0].points[0]
            fixture.view.writingStrokeBegan(at: CGPoint(x: first.x, y: first.y))
            strokes.forEach { fixture.view.writingStrokeFinished($0) }
            fixture.view.commitPendingLetter(follow: false)
            let recognized = await waitForRecognition(recognizer, in: fixture.view)
            XCTAssertTrue(recognized, name)
            XCTAssertEqual(fixture.view.writtenLetters.count, 1, name)
            XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, name, name)
            XCTAssertTrue(fixture.view.writtenLetters.first?.isFunction == true, name)
        }
    }

    func testNonmatchingRecognizerResultLeavesOneOgAlone() async throws {
        let recognizer = ControlledFunctionRecognizer(result: "cat")
        let fixture = try fixture(recognizer: recognizer)
        var originals: [CanvasView.WrittenLetter] = []
        for (index, label) in ["1", "o", "g"].enumerated() {
            fixture.view.mathGlyphClassifier = label == "1" ? try ambiguousOneClassifier() : try classifier(label)
            let ink = stroke(110 + CGFloat(index) * 11)
            let point = ink.points[0]
            fixture.view.writingStrokeBegan(at: CGPoint(x: point.x, y: point.y))
            fixture.view.writingStrokeFinished(ink)
            fixture.view.commitPendingLetter(follow: false)
            originals.append(try XCTUnwrap(fixture.view.writtenLetters.last))
        }
        let recognized = await waitForRecognition(recognizer)
        XCTAssertTrue(recognized)
        let callCount = await recognizer.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(fixture.view.writtenLetters.map(\.id), originals.map(\.id))
        XCTAssertEqual(fixture.view.writtenLetters.map(\.displayed), originals.map(\.displayed))
        XCTAssertFalse(fixture.view.writtenLetters.contains(where: \.isFunction))
    }

    func testOneEditMatchNeedsPerSymbolLetterSupportAndUsesUnaryContextToken() async throws {
        let matchingRecognizer = ControlledFunctionRecognizer(result: "sinn")
        let matchingFixture = try fixture(recognizer: matchingRecognizer)
        for (index, letter) in "sin".enumerated() {
            _ = try commit(String(letter), at: 110 + CGFloat(index) * 11, in: matchingFixture)
        }
        let didMatch = await waitForRecognition(matchingRecognizer)
        XCTAssertTrue(didMatch)
        let token = try XCTUnwrap(matchingFixture.view.writtenLetters.first)
        XCTAssertTrue(token.isFunction)
        XCTAssertEqual(token.displayed, "sin")
        XCTAssertEqual(token.likelihoods, ["sin": 1])
        let languageModel = try XCTUnwrap(MathLanguageModel.bundled)
        let decoder = MathLineDecoder(languageModel: languageModel)
        let next = MathLineDecoder.Symbol(labelLikelihoods: ["π": 0.5, "x": 0.5])
        let function = MathLineDecoder.Symbol(labelLikelihoods: ["sin": 1], displayedLabel: "sin", isPinned: true)
        let unary = MathLineDecoder.Symbol(labelLikelihoods: ["√": 1], displayedLabel: "√", isPinned: true)
        XCTAssertEqual(decoder.decode([function, next]).marginals[1], decoder.decode([unary, next]).marginals[1])

        let unsupportedRecognizer = ControlledFunctionRecognizer(result: "sit")
        let unsupportedFixture = try fixture(recognizer: unsupportedRecognizer)
        var originals: [CanvasView.WrittenLetter] = []
        for (index, letter) in "siz".enumerated() {
            originals.append(try commit(String(letter), at: 110 + CGFloat(index) * 11, in: unsupportedFixture))
        }
        let didCall = await waitForRecognition(unsupportedRecognizer)
        XCTAssertTrue(didCall)
        XCTAssertEqual(unsupportedFixture.view.writtenLetters.map(\.id), originals.map(\.id))
        XCTAssertFalse(unsupportedFixture.view.writtenLetters.contains(where: \.isFunction))
    }

    func testX1And2XDoNotCallFunctionRecognizer() async throws {
        for labels in [["x", "1"], ["2", "x"]] {
            let recognizer = ControlledFunctionRecognizer(result: "sin")
            let fixture = try fixture(recognizer: recognizer)
            for (index, label) in labels.enumerated() {
                _ = try commit(label, at: 110 + CGFloat(index) * 11, in: fixture)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let callCount = await recognizer.callCount()
            XCTAssertEqual(callCount, 0, labels.joined())
        }
    }

    func testDelayedRecognizerResultCannotRestoreDeletedRun() async throws {
        let recognizer = ControlledFunctionRecognizer(result: nil, controlled: true)
        let fixture = try fixture(recognizer: recognizer)
        var originals: [CanvasView.WrittenLetter] = []
        for (index, label) in "log".enumerated() {
            originals.append(try commit(String(label), at: 110 + CGFloat(index) * 11, in: fixture))
        }
        _ = try commit("+", at: 160, in: fixture)
        let recognized = await waitForRecognition(recognizer)
        XCTAssertTrue(recognized)
        fixture.view.invalidateMathRecognitionHistory()
        await recognizer.complete(with: "log")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(originals.allSatisfy { old in fixture.view.writtenLetters.contains { $0.id == old.id } })
        XCTAssertFalse(fixture.view.writtenLetters.contains(where: \.isFunction))
        XCTAssertTrue(fixture.model.strokes.isEmpty)
    }
    // MARK: function words via the decoder LM and bar-class letters

    /// Commit `labels` with the ambiguous bar class for "1" and singleton classes otherwise;
    /// the decoder runs with the production lambda, and no Apple recognizer result is available.
    private func writeWithLM(_ labels: [String]) throws -> [String?] {
        let fixture = try fixture(recognizer: ControlledFunctionRecognizer(result: nil), lambda: 0.6)
        for (index, label) in labels.enumerated() {
            fixture.view.mathGlyphClassifier = label == "1" ? try ambiguousOneClassifier() : try classifier(label)
            let ink = stroke(110 + CGFloat(index) * 12, 106, label == "1" ? 2 : 8, label == "1" ? 13 : 10)
            let point = ink.points[0]
            fixture.view.writingStrokeBegan(at: CGPoint(x: point.x, y: point.y))
            fixture.view.writingStrokeFinished(ink)
            fixture.view.commitPendingLetter(follow: false)
        }
        return fixture.view.writtenLetters.map(\.displayed)
    }

    func testF5BarStaysDigitAndSingletonLWorksBeforeIM() throws {
        XCTAssertEqual(try writeWithLM(["1", "i", "m"]).map { $0 ?? "ink" }, ["1", "i", "m"])
        XCTAssertEqual(try writeWithLM(["l", "i", "m"]).map { $0 ?? "ink" }, ["l", "i", "m"])
    }

    func testBarStaysDigitInNumbersAndAfterLetters() throws {
        XCTAssertEqual(try writeWithLM(["1", "2"]).map { $0 ?? "ink" }, ["1", "2"])
        XCTAssertEqual(try writeWithLM(["1", "+", "2"]).map { $0 ?? "ink" }, ["1", "+", "2"])
        XCTAssertEqual(try writeWithLM(["x", "1"]).map { $0 ?? "ink" }, ["x", "1"])
    }

    func testBarStemAndDotCountAsLettersForLim() async throws {
        let recognizer = ControlledFunctionRecognizer(result: "lim")
        let fixture = try fixture(recognizer: recognizer)
        func write(_ label: String, _ ink: Stroke) throws {
            fixture.view.mathGlyphClassifier = label == "1" ? try ambiguousOneClassifier() : try classifier(label)
            if label != "." {
                let point = ink.points[0]
                fixture.view.writingStrokeBegan(at: CGPoint(x: point.x, y: point.y))
            }
            fixture.view.writingStrokeFinished(ink)
            fixture.view.commitPendingLetter(follow: false)
        }
        try write("1", stroke(110, 106, 2, 13))        // the l, read as a digit
        try write("1", stroke(122, 106, 2, 13))        // the i stem
        try write(".", stroke(123, 100, 1, 1))         // its dot
        try write("m", letterStroke("m", x: 132))
        let recognized = await waitForRecognition(recognizer)
        XCTAssertTrue(recognized)
        XCTAssertEqual(fixture.view.writtenLetters.count, 1)
        XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, "lim")
        XCTAssertTrue(fixture.view.writtenLetters.first?.isFunction == true)
        XCTAssertTrue(fixture.model.strokes.isEmpty)
    }

    func testBarFirstLnAndLogBecomeFunctionTokensThroughRecognizer() async throws {
        for (name, labels) in [("ln", ["1", "n"]), ("log", ["1", "o", "g"])] {
            let recognizer = ControlledFunctionRecognizer(result: name)
            let fixture = try fixture(recognizer: recognizer)
            for (index, label) in labels.enumerated() {
                fixture.view.mathGlyphClassifier = label == "1" ? try ambiguousOneClassifier() : try classifier(label)
                let ink = stroke(110 + CGFloat(index) * 12, 106, label == "1" ? 2 : 8, label == "1" ? 13 : 10)
                fixture.view.writingStrokeBegan(at: CGPoint(x: ink.points[0].x, y: ink.points[0].y))
                fixture.view.writingStrokeFinished(ink)
                fixture.view.commitPendingLetter(follow: false)
            }
            let recognized = await waitForRecognition(recognizer)
            XCTAssertTrue(recognized, name)
            XCTAssertEqual(fixture.view.writtenLetters.count, 1, name)
            XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, name, name)
            XCTAssertTrue(fixture.view.writtenLetters.first?.isFunction == true, name)
        }
    }

    func testNumbersNeverReachTheFunctionRecognizer() async throws {
        for labels in [["1", "2"], ["1", "+", "2"], ["1", "1"]] {
            let recognizer = ControlledFunctionRecognizer(result: "lim")
            let fixture = try fixture(recognizer: recognizer)
            for (index, label) in labels.enumerated() {
                fixture.view.mathGlyphClassifier = label == "1" ? try ambiguousOneClassifier() : try classifier(label)
                let ink = stroke(110 + CGFloat(index) * 12, 106, 2, 13)
                fixture.view.writingStrokeBegan(at: CGPoint(x: ink.points[0].x, y: ink.points[0].y))
                fixture.view.writingStrokeFinished(ink)
                fixture.view.commitPendingLetter(follow: false)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let callCount = await recognizer.callCount()
            XCTAssertEqual(callCount, 0, labels.joined())
        }
    }
}
#endif
