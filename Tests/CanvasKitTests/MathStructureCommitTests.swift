#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

/// Answers every function-run recognition with one fixed name, so `lim` reaches the editor.
private actor StructureFunctionRecognizer: HandwritingRecognizer {
    nonisolated static let version = 1
    private let result: String
    private var calls = 0

    init(result: String) { self.result = result }

    func text(for strokes: [Stroke]) async -> String? { calls += 1; return result }
    func search(_ query: String, in strokes: [Stroke]) async -> [HandwritingMatch] { [] }
    func words(in strokes: [Stroke]) async -> [(word: String, match: HandwritingMatch)] { [] }

    func callCount() -> Int { calls }
}

@MainActor final class MathStructureCommitTests: XCTestCase {
    private struct Fixture {
        let view: CanvasView
        let model: CanvasModel
    }

    private func fixture(recognizer: HandwritingRecognizer? = nil) throws -> Fixture {
        _ = NSApplication.shared
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
        view.renderEquationPreview = { _, _, _ in }
        view.mathLineDecoderForTesting = MathLineDecoder(languageModel: try XCTUnwrap(MathLanguageModel.bundled),
                                                         lambda: 0, tauSub: 0.8, tauRev: 0.9)
        return Fixture(view: view, model: model)
    }

    private func classifier(for label: String) throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let glyphClass = try XCTUnwrap(vocabulary.classes.first { $0.labels.contains(label) },
                                       "Expected a math class for \(label)")
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

    private func editor(in fixture: Fixture) async throws -> MathLiveEditorView {
        let editor = try XCTUnwrap(fixture.view.mathEditorForTesting,
                                   "Handwritten math must mount the equation editor")
        for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should load offline")
        return editor
    }

    private func flush(_ editor: MathLiveEditorView) async {
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
    }

    private func latex(_ editor: MathLiveEditorView, matching predicate: (String) -> Bool,
                       timeout: Double = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = editor.latex
        while Date() < deadline {
            await flush(editor)
            latest = editor.latex
            if predicate(latest) { return latest }
            try await Task.sleep(for: .milliseconds(25))
        }
        return latest
    }

    func testHandwrittenRootKeepsItsStructureThroughIndexAndRadicand() async throws {
        let fixture = try fixture()
        _ = try commit("√", in: fixture)
        let editor = try await editor(in: fixture)
        var source = try await latex(editor) { $0.hasPrefix("\\sqrt") }
        XCTAssertTrue(source.hasPrefix("\\sqrt"), "A written root must open its radicand bar: \(source)")

        // A raised symbol written while the caret is in the root is its index.
        _ = try commit("3", in: fixture, y: 98, height: 8)
        source = try await latex(editor) { $0.contains("\\sqrt[3]") }
        XCTAssertEqual(source, #"\sqrt[3]{\placeholder{}}"#,
                       "The raised symbol must become the index and keep the empty radicand: \(source)")

        // The radicand then continues from the caret the index left behind.
        _ = try commit("2", in: fixture)
        source = try await latex(editor) { $0.contains("\\sqrt[3]{2}") }
        XCTAssertEqual(source, #"\sqrt[3]{2}"#, "The radicand must follow the index: \(source)")
    }

    func testRightArrowInsertsAWordSpaceAndAdvancesTheWritingCell() async throws {
        let fixture = try fixture()
        _ = try commit("2", in: fixture)
        let editor = try await editor(in: fixture)
        _ = try await latex(editor) { $0.contains("2") }
        let before = try XCTUnwrap(fixture.view.writingCell)

        fixture.view.navigateMathEquation("spaceRight")

        var source = ""
        for _ in 0..<200 {
            await flush(editor)
            source = editor.latex
            if source != "2" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(source, #"2\ "#, "The right arrow at the top level must add a space: \(source)")

        var cell = try XCTUnwrap(fixture.view.writingCell)
        for _ in 0..<200 where cell.cursorX <= before.cursorX {
            try await Task.sleep(for: .milliseconds(25))
            cell = try XCTUnwrap(fixture.view.writingCell)
        }
        XCTAssertGreaterThan(cell.cursorX, before.cursorX, "The space must move the writing cell on")
    }

    func testRevisingTheIndexRewritesTheRootInPlace() async throws {
        let fixture = try fixture()
        _ = try commit("√", in: fixture)
        _ = try commit("3", in: fixture, y: 98, height: 8)
        _ = try commit("x", in: fixture)
        let editor = try await editor(in: fixture)
        _ = try await latex(editor) { $0.contains("\\sqrt[3]{x}") }

        guard fixture.view.writtenLetters.count == 3 else {
            return XCTFail("Expected root, index and radicand as three letters: \(fixture.view.writtenLetters.map(\.displayed))")
        }
        fixture.view.reviseMathLetterForTesting("n", id: fixture.view.writtenLetters[1].id)
        let source = try await latex(editor) { $0.contains("\\sqrt[n]") }
        XCTAssertEqual(source, #"\sqrt[n]{x}"#, "Correcting the index must keep the radicand: \(source)")
    }

    func testHandwrittenSummationLimitsAdvanceThroughTheEditor() async throws {
        let fixture = try fixture()
        _ = try commit("∑", in: fixture)
        let editor = try await editor(in: fixture)
        var source = try await latex(editor) { $0.hasPrefix("\\sum") }
        XCTAssertTrue(source.hasPrefix("\\sum\\limits"), "A written summation must force its limits over and under: \(source)")

        // Small symbols below the baseline land in the lower limit and share one slot.
        for symbol in ["i", "=", "1"] {
            _ = try commit(symbol, in: fixture, y: 124, height: 8)
        }
        source = try await latex(editor) { $0.contains("_{i=1}") }
        XCTAssertTrue(source.contains("_{i=1}"), "Adjacent limit symbols must share the lower slot: \(source)")

        fixture.view.navigateMathEquation("advance")
        _ = try commit("n", in: fixture, y: 98, height: 8)
        source = try await latex(editor) { $0.contains("^{n}") }
        XCTAssertTrue(source.contains("^{n}"), "Advancing from the lower slot must reach the upper one: \(source)")

        fixture.view.navigateMathEquation("advance")
        _ = try commit("x", in: fixture)
        source = try await latex(editor) { $0.hasSuffix("x") }
        XCTAssertEqual(source, #"\sum\limits_{i=1}^{n}x"#,
                       "Advancing past the upper slot must reach the body: \(source)")
    }

    func testHandwrittenLimOpensItsConditionSlot() async throws {
        let recognizer = StructureFunctionRecognizer(result: "lim")
        let fixture = try fixture(recognizer: recognizer)
        for (index, letter) in "lim".enumerated() {
            _ = try commit(String(letter), in: fixture, x: 110 + CGFloat(index) * 11)
        }
        let editor = try await editor(in: fixture)
        var source = try await latex(editor) { $0.contains("\\lim") }
        XCTAssertTrue(source.contains("\\lim_"), "A recognized lim must open its condition slot: \(source)")
        XCTAssertTrue(source.contains("\\to"), "The limit must already name the approach arrow: \(source)")

        // The variable fills the slot before the arrow; the arrow then steps the
        // caret into the approached-value slot, and the value fills it.
        _ = try commit("x", in: fixture, y: 124, height: 8)
        source = try await latex(editor) { $0.contains("\\lim_{x\\to") }
        XCTAssertTrue(source.contains("\\lim_{x\\to"), "The variable must fill below lim: \(source)")

        _ = try commit("→", in: fixture, y: 124, height: 8)
        _ = try commit("0", in: fixture, y: 124, height: 8)
        source = try await latex(editor) { $0.contains("\\lim_{x\\to0}") }
        XCTAssertEqual(source, #"\lim_{x\to0}"#, "The limit condition must read variable-to-value: \(source)")
    }

    /// A fast writer's condition ink can commit before the recognizer's `lim` answer
    /// reaches the editor; the condition must still fold into the limit's own slots.
    func testHandwrittenLimitConditionMayArriveBeforeTheStructure() async throws {
        let recognizer = StructureFunctionRecognizer(result: "lim")
        let fixture = try fixture(recognizer: recognizer)
        for (index, letter) in "lim".enumerated() {
            _ = try commit(String(letter), in: fixture, x: 110 + CGFloat(index) * 11)
        }
        _ = try commit("x", in: fixture, y: 124, height: 8)

        let editor = try await editor(in: fixture)
        var source = try await latex(editor) { $0.contains("\\lim") && $0.contains("x") }
        XCTAssertTrue(source.contains("\\lim_{x"), "The written condition must fold into lim: \(source)")
        XCTAssertFalse(source.contains("_{x}"), "A condition written early must not dangle after lim: \(source)")

        _ = try commit("→", in: fixture, y: 124, height: 8)
        _ = try commit("0", in: fixture, y: 124, height: 8)
        source = try await latex(editor) { $0.contains("\\lim_{x\\to0}") }
        XCTAssertEqual(source, #"\lim_{x\to0}"#, "The limit condition must read variable-to-value: \(source)")
    }

    func testWholeWordLimitOpensItsConditionSlots() async throws {
        let recognizer = StructureFunctionRecognizer(result: "lim")
        let fixture = try fixture(recognizer: recognizer)
        fixture.view.mathGlyphClassifier = try classifier(for: "l")
        let strokes = [
            Stroke(points: [StrokePoint(x: 110, y: 106, t: 0), StrokePoint(x: 110, y: 118, t: 0.1)],
                   color: .black, width: 2),
            Stroke(points: [StrokePoint(x: 110, y: 110, t: 0.2), StrokePoint(x: 145, y: 110, t: 0.3)],
                   color: .black, width: 2),
        ]
        fixture.view.pendingLetter = strokes
        fixture.view.commitPendingLetter(follow: false)
        let editor = try await editor(in: fixture)
        let source = try await latex(editor) { $0.contains("\\lim") }
        XCTAssertTrue(source.contains("\\lim_{"), "Whole-word lim must open its condition: \(source)")
        XCTAssertTrue(source.contains("\\to"), "Whole-word lim must include its approach arrow: \(source)")
    }

    func testWrittenAbsOpensBarsAndKeepsTheArgumentInside() async throws {
        for wholeWord in [false, true] {
            let recognizer = StructureFunctionRecognizer(result: "abs")
            let fixture = try fixture(recognizer: recognizer)
            fixture.view.settings.autoCloseBrackets = false
            if wholeWord {
                fixture.view.mathGlyphClassifier = try classifier(for: "a")
                fixture.view.pendingLetter = [
                    Stroke(points: [StrokePoint(x: 110, y: 106, t: 0), StrokePoint(x: 145, y: 118, t: 0.1)],
                           color: .black, width: 2),
                    Stroke(points: [StrokePoint(x: 110, y: 110, t: 0.2), StrokePoint(x: 145, y: 110, t: 0.3)],
                           color: .black, width: 2),
                ]
                fixture.view.commitPendingLetter(follow: false)
            } else {
                for (index, letter) in "abs".enumerated() {
                    _ = try commit(String(letter), in: fixture, x: 110 + CGFloat(index) * 11)
                }
            }
            let editor = try await editor(in: fixture)
            var source = try await latex(editor) { $0 == "||" }
            XCTAssertEqual(source, "||", "Written abs must open both bars (whole word: \(wholeWord))")
            _ = try commit("x", in: fixture)
            source = try await latex(editor) { $0 == "|x|" }
            XCTAssertEqual(source, "|x|", "The argument must land between the bars")
        }
    }

    func testSequentialStructureWordsUseRecognizedLettersAtTheNormalCellAdvance() async throws {
        for name in ["abs", "lim"] {
            // No second word recognizer: these letters have already been recognized.
            let fixture = try fixture()
            for letter in name {
                _ = try commit(String(letter), in: fixture)
            }
            let editor = try await editor(in: fixture)
            let source = try await latex(editor) {
                name == "abs" ? $0 == "||" : $0.contains("\\lim_{") && $0.contains("\\to")
            }
            if name == "abs" {
                XCTAssertEqual(source, "||")
            } else {
                XCTAssertTrue(source.contains("\\lim_{") && source.contains("\\to"), source)
            }
        }
    }

    /// Absolute value lives on the `|` label, which the bar class shares with the digit 1.
    /// The candidate pill is how a written bar is corrected into the delimiter.
    func testCorrectedAbsoluteBarBringsItsCloser() async throws {
        let fixture = try fixture()
        // The bar class reads as the digit; disabling it keeps the later commits from
        // re-revising the corrected delimiter back into a 1.
        fixture.view.mathLineDecoderForTesting = MathLineDecoder(
            languageModel: try XCTUnwrap(MathLanguageModel.bundled),
            lambda: 0, tauSub: 0.8, tauRev: 0.9, disabledLabels: ["1"])
        let bar = try commit("1", in: fixture)
        let editor = try await editor(in: fixture)
        var source = try await latex(editor) { $0 == "1" }
        XCTAssertEqual(source, "1", "The bar class decodes as the digit until corrected: \(source)")

        fixture.view.reviseMathLetterForTesting("|", id: bar.id)
        source = try await latex(editor) { $0.contains("|") }
        XCTAssertEqual(source, "||", "A corrected absolute bar must bring its closing bar: \(source)")

        _ = try commit("x", in: fixture)
        source = try await latex(editor) { $0.contains("|x|") }
        XCTAssertEqual(source, "|x|", "Ink between the bars must stay inside them: \(source)")

        // The closing bar arrives read as a digit; correcting it absorbs the auto bar.
        let closer = try commit("1", in: fixture)
        source = try await latex(editor) { $0.contains("|x1|") }
        XCTAssertEqual(source, "|x1|", "Uncorrected ink must stay between the bars: \(source)")
        fixture.view.reviseMathLetterForTesting("|", id: closer.id)
        source = try await latex(editor) { $0.contains("|x|") && !$0.contains("|x||") }
        XCTAssertEqual(source, "|x|", "The corrected closer must replace the auto bar: \(source)")
    }
}
#endif
