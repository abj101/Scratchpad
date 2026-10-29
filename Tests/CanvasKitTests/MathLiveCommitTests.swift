#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

final class MathLiveCommitTests: XCTestCase {
    private struct Fixture {
        let view: CanvasView
        let model: CanvasModel
    }

    private final class EventObserver: PenEventSink {
        weak var source: TabletInputSource?
        var next: PenEventSink?
        var drawingAtBegan: [Bool] = []

        func handle(_ event: PenEvent) {
            if event.phase == .began { drawingAtBegan.append(source?.isDrawing ?? false) }
            next?.handle(event)
        }
    }

    private func fixture(math: Bool = true) throws -> Fixture {
        let settings = CanvasSettings()
        settings.handwritingToText = false
        settings.inputMode = .write
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let view = CanvasView(model: model, settings: settings)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = 700
        view.mathTidyEnabledForTesting = math
        view.mathFunctionRecognizer = nil
        view.mathLineDecoderForTesting = MathLineDecoder(
            languageModel: try XCTUnwrap(MathLanguageModel.bundled), lambda: 0, tauSub: 0.8, tauRev: 0.9)
        return Fixture(view: view, model: model)
    }

    private func stroke(_ path: [(CGFloat, CGFloat)], t: TimeInterval = 0) -> Stroke {
        Stroke(points: path.enumerated().map {
            StrokePoint(x: $0.element.0, y: $0.element.1, t: t + Double($0.offset) * 0.01)
        }, color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 1), width: 2)
    }

    private func line(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> Stroke {
        stroke([(x, y), (x + dx, y + dy)])
    }

    private func classifier(labels: [String], rasters: [[UInt8]]? = nil) throws -> MathGlyphClassifier {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let classes = try labels.map { label in
            try XCTUnwrap(vocabulary.classes.first { $0.labels.contains(label) }, "No class for \(label)")
        }
        let expected = rasters ?? []
        return MathGlyphClassifier(testClasses: classes, temperature: 1,
                                   decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9,
                                                               disabledLabels: [])) { pixels, _, _ in
            guard let index = expected.firstIndex(of: pixels) else { return Array(repeating: 0, count: classes.count) }
            return classes.indices.map { $0 == index ? 40 : -40 }
        }
    }

    private func write(_ stroke: Stroke, in view: CanvasView) {
        let point = stroke.points[0]
        view.writingStrokeBegan(at: CGPoint(x: point.x, y: point.y))
        view.writingStrokeFinished(stroke)
    }

    private func commitIdle(_ view: CanvasView) { view.commitPendingLetter(follow: false) }

    func testFastSpatialPairsCommitAsTwoSymbols() throws {
        for (text, shapes) in [
            ("2x", [stroke([(110, 106), (120, 106), (112, 116)]), line(140, 106, 10, 10)]),
            ("15", [line(110, 106, 2, 12), line(140, 106, 8, 12)]),
            ("12", [line(110, 106, 2, 12), line(140, 106, 10, 12)]),
        ] {
            let fixture = try fixture()
            let labels = Array(text).map(String.init)
            fixture.view.mathGlyphClassifier = try classifier(labels: labels,
                                                                rasters: shapes.map { GlyphRaster.rasterize([$0]) })
            for shape in shapes { write(shape, in: fixture.view) }
            commitIdle(fixture.view)
            XCTAssertEqual(fixture.view.writtenLetters.map(\.displayed), labels, text)
            XCTAssertEqual(fixture.view.writtenLetters.map { $0.originalStrokes.count }, [1, 1], text)
        }
    }

    func testUnsureSymbolCommitsBestGuessAndDisabledLabelsStillCommit() throws {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let mark = line(110, 104, 8, 14)
        for (top, other, topProbability, disabled, expected) in [
            ("4", "+", 0.6, [String](), "4"),
            ("y", "+", 0.9, ["y"], "y"),
        ] as [(String, String, Double, [String], String?)] {
            let fixture = try fixture()
            fixture.view.mathLineDecoderForTesting = MathLineDecoder(
                languageModel: try XCTUnwrap(MathLanguageModel.bundled), lambda: 0, tauSub: 0.98, tauRev: 0.99,
                disabledLabels: Set(disabled))
            let classes = try [top, other].map { label in
                try XCTUnwrap(vocabulary.classes.first { $0.labels.contains(label) })
            }
            let raster = GlyphRaster.rasterize([mark])
            fixture.view.mathGlyphClassifier = MathGlyphClassifier(
                testClasses: classes, temperature: 1,
                decoderConfiguration: .init(lambda: 0, tauSub: 0.98, tauRev: 0.99, disabledLabels: Set(disabled))) { pixels, _, _ in
                pixels == raster ? [log(topProbability), log(1 - topProbability)] : nil
            }
            write(mark, in: fixture.view)
            commitIdle(fixture.view)
            XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, expected, top)
        }
    }

    func testF5TailedQAndCursiveLCommitTheirOwnLabelsBeforeResourceSwap() throws {
        let cases: [(String, String, Stroke)] = [
            ("q", "glyph_u0071", stroke([(116, 110), (111, 105), (107, 110), (111, 115),
                                        (116, 110), (115, 121), (120, 118)])),
            ("l", "glyph_u006C", stroke([(110, 116), (117, 104), (113, 102), (111, 110),
                                        (112, 116), (120, 116)])),
        ]
        for (label, classID, mark) in cases {
            let fixture = try fixture()
            fixture.view.mathLineDecoderForTesting = MathLineDecoder(
                languageModel: try XCTUnwrap(MathLanguageModel.bundled), lambda: 0.4,
                tauSub: 0.98, tauRev: 0.99, disabledLabels: [label])
            let glyphClass = MathVocabulary.GlyphClass(id: classID, labels: [label])
            fixture.view.mathGlyphClassifier = MathGlyphClassifier(
                testClasses: [glyphClass], temperature: 1,
                decoderConfiguration: .init(lambda: 0.4, tauSub: 0.98, tauRev: 0.99,
                                            disabledLabels: [label])) { _, _, _ in [4] }
            write(mark, in: fixture.view)
            commitIdle(fixture.view)
            XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, label)
            XCTAssertEqual(fixture.view.writtenLetters.first?.originalStrokes, [mark])
        }
    }

    func testOverlappingSymbolStrokesStayTogether() throws {
        let symbols: [(String, [[Stroke]])] = [
            ("+", [[line(110, 111, 14, 0), line(117, 104, 0, 14)]]),
            ("x", [[line(110, 104, 14, 14), line(110, 118, 14, -14)]]),
            ("=", [[line(110, 107, 14, 0), line(110, 113, 14, 0)]]),
            ("≥", [[line(110, 104, 12, 7), line(122, 111, -12, 7), line(110, 120, 14, 0)]]),
            ("4", [[line(110, 104, 0, 14), line(110, 111, 14, 0)]]),
            ("4", [[line(110, 104, 14, 14), line(110, 111, 14, 0), line(122, 118, 0, -14)]]),
            ("π", [[line(110, 104, 0, 14), line(110, 109, 14, 0), line(124, 109, -1, 9)]]),
            ("÷", [[line(110, 111, 14, 0), line(117, 104, 0, 0), line(117, 118, 0, 0)]])
        ]

        for (label, groups) in symbols {
            let fixture = try fixture()
            let strokes = groups[0]
            fixture.view.mathGlyphClassifier = try classifier(labels: [label],
                                                                rasters: [GlyphRaster.rasterize(strokes)])
            for stroke in strokes { write(stroke, in: fixture.view) }
            commitIdle(fixture.view)
            XCTAssertEqual(fixture.view.writtenLetters.count, 1, label)
            XCTAssertEqual(fixture.view.writtenLetters.first?.displayed, label, label)
            XCTAssertEqual(fixture.view.writtenLetters.first?.originalStrokes.count, strokes.count, label)
        }
    }

    func testDelayedDotReopensCommittedIWithinOneReplacementUndo() throws {
        let fixture = try fixture()
        let stem = line(115, 108, 0, 11)
        var dot = line(115, 103, 0, 0)
        fixture.view.mathGlyphClassifier = try classifier(labels: ["i"],
                                                            rasters: [GlyphRaster.rasterize([stem]),
                                                                      GlyphRaster.rasterize([stem, dot])])
        write(stem, in: fixture.view)
        commitIdle(fixture.view)
        let original = try XCTUnwrap(fixture.view.writtenLetters.first)
        let originalInk = fixture.model.strokes

        dot = line(original.extent.midX, original.extent.minY - 2, 0, 0)
        fixture.view.mathGlyphClassifier = try classifier(labels: ["i"],
                                                            rasters: [GlyphRaster.rasterize([stem, dot])])
        write(dot, in: fixture.view)
        commitIdle(fixture.view)
        XCTAssertEqual(fixture.view.writtenLetters.count, 1)
        XCTAssertEqual(fixture.view.writtenLetters.first?.id, original.id)
        XCTAssertEqual(fixture.view.writtenLetters.first?.originalStrokes.count, 2)
        XCTAssertTrue(fixture.model.strokes.isEmpty)

        fixture.model.undoManager.undo()
        XCTAssertEqual(fixture.view.writtenLetters.count, 1)
        XCTAssertEqual(fixture.view.writtenLetters.first?.id, original.id)
        XCTAssertEqual(fixture.view.writtenLetters.first?.originalStrokes, original.originalStrokes)
        XCTAssertEqual(fixture.model.strokes, originalInk)
    }

    func testWideMergedMultiStrokeBlobKeepsOriginalInk() throws {
        let fixture = try fixture()
        let blob = [line(110, 110, 16, 1), line(124, 111, 16, -1), line(138, 110, 16, 1)]
        fixture.view.mathGlyphClassifier = try classifier(labels: ["x"], rasters: [GlyphRaster.rasterize(blob)])
        for stroke in blob { write(stroke, in: fixture.view) }
        commitIdle(fixture.view)
        XCTAssertTrue(fixture.model.strokes.isEmpty)
        XCTAssertEqual(fixture.view.unresolvedMathStrokes.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       blob.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }

    func testFollowingContextCannotSwapAnUnsplittableWideBlob() throws {
        let fixture = try fixture()
        let blob = [line(110, 110, 16, 1), line(124, 111, 16, -1), line(138, 110, 16, 1)]
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let alternatives = try ["x", "·"].map { label in
            try XCTUnwrap(vocabulary.classes.first { $0.labels.contains(label) })
        }
        fixture.view.mathGlyphClassifier = MathGlyphClassifier(
            testClasses: alternatives, temperature: 1,
            decoderConfiguration: .init(lambda: 0.6, tauSub: 0.8, tauRev: 0.9, disabledLabels: [])) {
                _, _, _ in [0, 0]
            }
        let ratio = pow(0.95 / 0.05, 1 / 0.6)
        let plusAfterX = ratio / (1 + ratio)
        let plusAfterDot = 1 / (1 + ratio)
        let vocab = ["<s>", "<unk>", "x", "·", "+"]
        let base = 1 / Double(vocab.count)
        var ngrams = Dictionary(uniqueKeysWithValues: vocab.map { (mathLMKey([], $0), [log10(base), 0]) })
        for (context, probabilities) in [
            (["<s>", "<s>"], ["x": 0.5, "·": 0.5]),
            (["<s>", "x"], ["+": plusAfterX]),
            (["<s>", "·"], ["+": plusAfterDot]),
        ] {
            for (label, probability) in probabilities {
                ngrams[mathLMKey(context, label)] = [log10(probability), 0]
            }
        }
        fixture.view.mathLineDecoderForTesting = MathLineDecoder(
            languageModel: MathLanguageModel(vocab: vocab, ngrams: ngrams), lambda: 0.6,
            tauSub: 0.8, tauRev: 0.9)
        for stroke in blob { write(stroke, in: fixture.view) }
        commitIdle(fixture.view)
        let retained = fixture.view.unresolvedMathStrokes
        XCTAssertEqual(retained.count, blob.count)

        fixture.view.mathGlyphClassifier = try classifier(labels: ["+"], rasters: [GlyphRaster.rasterize([line(180, 110, 12, 0)])])
        write(line(180, 110, 12, 0), in: fixture.view)
        commitIdle(fixture.view)

        XCTAssertEqual(fixture.view.unresolvedMathStrokes, retained)
        XCTAssertTrue(fixture.model.strokes.isEmpty)
    }

    func testTabletStrokesCommitAtNextBeganAndKeepMappingStableMidStroke() throws {
        let fixture = try fixture()
        fixture.view.mathGlyphClassifier = try classifier(labels: ["2"], rasters: [GlyphRaster.rasterize([line(0, 0, 10, 10)])])
        let source = fixture.view.tabletSource
        source.mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 800, height: 600), inset: 0,
                                      deviceSize: CGSize(width: 1600, height: 1000))
        let fixedMapping = source.mapping
        let observer = EventObserver()
        observer.source = source
        observer.next = source.sink
        source.sink = observer

        func touch(_ x: CGFloat, _ y: CGFloat) -> TouchSample {
            TouchSample(id: "finger", normalized: CGPoint(x: x, y: y),
                        deviceSize: CGSize(width: 1600, height: 1000))
        }
        func draw(_ startX: CGFloat, _ startY: CGFloat, time: TimeInterval) {
            source.touchesChanged([touch(startX, startY)], timestamp: time)
            source.touchesChanged([touch(startX + 0.02, startY - 0.02)], timestamp: time + 0.05)
            source.touchesChanged([], timestamp: time + 0.1)
        }

        source.penChanged(.down, timestamp: 0)
        draw(0.2, 0.7, time: 0.01)
        XCTAssertEqual(fixture.view.writtenLetters.count, 0)
        XCTAssertEqual(fixture.view.pendingLetter.count, 1)
        XCTAssertEqual(source.mapping, fixedMapping)

        source.touchesChanged([touch(0.26, 0.7)], timestamp: 0.2)
        XCTAssertTrue(source.isDrawing)
        XCTAssertEqual(fixture.view.writtenLetters.count, 1, "The first pending symbol commits from the next .began callback")
        XCTAssertEqual(observer.drawingAtBegan, [true, true])
        XCTAssertEqual(source.mapping, fixedMapping, "The mapping remains fixed while the next stroke is live")
        source.touchesChanged([touch(0.28, 0.68)], timestamp: 0.25)
        XCTAssertEqual(source.mapping, fixedMapping)
        source.touchesChanged([], timestamp: 0.3)
        source.penChanged(.up, timestamp: 0.31)
        commitIdle(fixture.view)

        XCTAssertEqual(fixture.view.writtenLetters.count, 2)
        XCTAssertGreaterThan(fixture.view.writingCell?.cursorX ?? 0, 100)
    }

    func testTextModeOnlyCommitsAfterIdle() throws {
        let fixture = try fixture(math: false)
        fixture.view.useScribeMathForTesting()
        fixture.view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        fixture.view.writingRightLimit = 700
        let first = line(110, 106, 6, 10)
        let second = line(145, 106, 6, 10)
        write(first, in: fixture.view)
        write(second, in: fixture.view)
        XCTAssertEqual(fixture.view.pendingLetter.count, 2)
        XCTAssertTrue(fixture.view.writtenLetters.isEmpty)
        commitIdle(fixture.view)
        XCTAssertTrue(fixture.view.pendingLetter.isEmpty)
        XCTAssertTrue(fixture.model.strokes.isEmpty)
    }
}

private func mathLMKey(_ context: [String], _ label: String) -> String {
    context.joined(separator: "\u{001f}") + "\u{001e}" + label
}
#endif
