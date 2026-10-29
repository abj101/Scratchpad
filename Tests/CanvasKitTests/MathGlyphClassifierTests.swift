import CoreML
import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import CanvasKit

final class MathGlyphClassifierTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Image: Decodable {
            let validation_index: Int
            let raster_base64: String
            let pytorch_probabilities: [Double]
        }
        let groups: [String]
        let images: [Image]
    }

    /// The bundled resource is the v2 export; PyTorch/native parity was gated at export time.
    func testBundledModelIsV2AndProducesNormalizedLabelLikelihoods() throws {
        let classifier = MathGlyphClassifier.shared
        XCTAssertTrue(classifier.isAvailable)
        XCTAssertEqual(classifier.runtimeVersion, 2)
        let ink = [stroke([(0, 0), (6, 30)])]
        let labels = classifier.labelLikelihoods(
            strokes: ink, bounds: CGRect(x: 0, y: 0, width: 6, height: 30),
            context: SymbolResolver.Context(mode: .math))
        XCTAssertFalse(labels.isEmpty)
        XCTAssertLessThanOrEqual(labels.count, 5)
        XCTAssertEqual(labels.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testBundledManifestWithoutTauFillUsesRevisionThreshold() throws {
        let bundle = CleanGlyphs.resourceBundle
        let manifestURL = try XCTUnwrap(bundle.url(forResource: "MathGlyphs-manifest", withExtension: "json"))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest.removeValue(forKey: "tauFill")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: try XCTUnwrap(bundle.url(forResource: "MathGlyphs", withExtension: "mlmodelc")),
                                         to: directory.appendingPathComponent("MathGlyphs.mlmodelc"))
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("MathGlyphs-manifest.json"))
        let classifier = MathGlyphClassifier(testRuntimeAt: directory)
        XCTAssertTrue(classifier.isAvailable)
        XCTAssertEqual(classifier.decoderConfiguration.tauFill, classifier.decoderConfiguration.tauRev)
    }

    func testJunkVocabularyAndDominantJunkRemainInk() throws {
        let data = Data(#"{"version":2,"classes":[{"id":"glyph_u0078","labels":["x"]},{"id":"junk","labels":["<unk>"]}],"labels":[{"label":"<unk>","class":"junk","kind":"junk","hershey":"","latex":[]}]}"#.utf8)
        let vocabulary = try JSONDecoder().decode(MathVocabulary.self, from: data)
        XCTAssertEqual(vocabulary.labels.first?.kind, "junk")
        XCTAssertEqual(vocabulary.labels.first?.latex, [])
        let classifier = MathGlyphClassifier(testClasses: vocabulary.classes, temperature: 1) { _, _, _ in
            [0, 10]
        }
        let likelihoods = classifier.labelLikelihoods(
            strokes: [stroke([(0, 0), (10, 5)])], bounds: CGRect(x: 0, y: 0, width: 10, height: 5),
            context: mathContext)
        XCTAssertEqual(likelihoods.max(by: { $0.value < $1.value })?.key, "<unk>")
        let decoder = MathLineDecoder(languageModel: try XCTUnwrap(MathLanguageModel.bundled), lambda: 0)
        let result = decoder.decode([
            MathLineDecoder.Symbol(labelLikelihoods: likelihoods),
            MathLineDecoder.Symbol(labelLikelihoods: ["+": 1]),
        ])
        XCTAssertEqual(result.substitution?.label, "+")
        XCTAssertTrue(result.revisions.isEmpty)
        XCTAssertNil(decoder.decode([MathLineDecoder.Symbol(labelLikelihoods: likelihoods)]).substitution)
        XCTAssertNil(MathFunctionNames.letters(in: likelihoods))
        XCTAssertFalse(MathFunctionNames.canRecognize([likelihoods], isBlob: true))
        XCTAssertFalse(MathFunctionNames.isLetter("<unk>"))
    }

    func testConfidenceMarginAndDisabledMemberFallback() {
        let bounds = CGRect(x: 0, y: 80, width: 18, height: 18)
        let context = SymbolResolver.Context(medianHeight: 20, baseline: 100, mode: .math)
        let groups = ["ambig_circle", "glyph_u0032"]
        let ink = [Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
                          color: .black, width: 2)]
        let confident = MathGlyphClassifier(testGroups: groups, disabledLabels: ["0"]) { _ in
            ["ambig_circle": 0.95, "glyph_u0032": 0.05]
        }
        XCTAssertNil(confident.resolve(ink, originalBounds: bounds, context: context))
        let uncertain = MathGlyphClassifier(testGroups: groups) { _ in
            ["ambig_circle": 0.8, "glyph_u0032": 0.2]
        }
        XCTAssertNil(uncertain.resolve(ink, originalBounds: bounds, context: context))
        let lowMargin = MathGlyphClassifier(testGroups: groups) { _ in
            ["ambig_circle": 0.6, "glyph_u0032": 0.4]
        }
        XCTAssertNil(lowMargin.resolve(ink, originalBounds: bounds, context: context))
    }

    func testV2TemperatureSoftmaxReturnsTopFiveRenormalizedLabels() throws {
        let classes = try XCTUnwrap(MathVocabulary.bundled?.classes)
        let byID = Dictionary(uniqueKeysWithValues: classes.enumerated().map { ($0.element.id, $0.offset) })
        var logits = [Double](repeating: 0, count: classes.count)
        logits[try XCTUnwrap(byID["glyph_u0021"])] = 4
        logits[try XCTUnwrap(byID["glyph_u0028"])] = 2
        logits[try XCTUnwrap(byID["bar"])] = 1
        let classifier = MathGlyphClassifier(testClasses: classes, temperature: 2) { _, _, _ in logits }

        let labels = classifier.labelLikelihoods(
            strokes: [stroke([(0, 0), (10, 5)])], bounds: CGRect(x: 0, y: 0, width: 10, height: 5),
            context: SymbolResolver.Context(mode: .text)  // neutral bar split keeps `+ ) /` in the top five
        )
        XCTAssertEqual(Set(labels.keys), ["!", "(", ")", "+", "/"])
        XCTAssertEqual(labels.values.reduce(0, +), 1, accuracy: 1e-12)

        let raw = classes.indices.map { exp(logits[$0] / 2) }
        let denominator = raw.reduce(0, +)
        let retained = (raw[try XCTUnwrap(byID["glyph_u0021"])]
            + raw[try XCTUnwrap(byID["glyph_u0028"])]
            + raw[try XCTUnwrap(byID["glyph_u0029"])]
            + raw[try XCTUnwrap(byID["glyph_u002B"])]
            + raw[try XCTUnwrap(byID["glyph_u002F"])]) / denominator
        XCTAssertEqual(try XCTUnwrap(labels["!"]),
                       raw[try XCTUnwrap(byID["glyph_u0021"])] / denominator / retained,
                       accuracy: 1e-12)
        XCTAssertEqual(labels["!"]! / labels[")"]!, exp(2), accuracy: 1e-12)
    }

    func testV2MergedClassUsesGeometryWeights() throws {
        let classes = try XCTUnwrap(MathVocabulary.bundled?.classes)
        let ringIndex = try XCTUnwrap(classes.firstIndex { $0.id == "ring" })
        let logits = classes.indices.map { $0 == ringIndex ? 10.0 : -1_000.0 }
        let classifier = MathGlyphClassifier(testClasses: classes, temperature: 1) { _, _, _ in logits }
        let bounds = CGRect(x: 0, y: 80, width: 8, height: 8)
        let context = SymbolResolver.Context(medianHeight: 20, baseline: 100, mode: .math)

        let likelihoods = classifier.labelLikelihoods(
            strokes: [stroke([(0, 0), (8, 8)])], bounds: bounds, context: context
        )
        let expected = SymbolResolver.memberWeights(class: "ring", bounds: bounds, context: context)
        XCTAssertEqual(Set(likelihoods.keys), Set(["0", "o", "°"]))
        for (label, weight) in expected {
            XCTAssertEqual(try XCTUnwrap(likelihoods[label]), weight, accuracy: 1e-12)
        }
    }

    func testLegacyV1AdapterMapsMathMembersAndIgnoresOldDisabledLabels() throws {
        let groups = ["ambig_x_times", "glyph_u0032"]
        let classifier = MathGlyphClassifier(testGroups: groups, disabledLabels: ["2", "x"]) { _ in
            ["ambig_x_times": 0.5, "glyph_u0032": 0.5]
        }
        let likelihoods = classifier.labelLikelihoods(
            strokes: [stroke([(0, 0), (10, 5)])], bounds: CGRect(x: 0, y: 0, width: 10, height: 5),
            context: mathContext
        )

        XCTAssertEqual(try XCTUnwrap(likelihoods["x"]), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(likelihoods["2"]), 0.5, accuracy: 1e-12)
        XCTAssertNil(likelihoods["×"])
        XCTAssertEqual(likelihoods.values.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertTrue(classifier.decoderConfiguration.disabledLabels.isEmpty)
    }

    func testLegacyAmbiguousGroupUsesNewMergedClassesAndDropsUnmappedGroups() throws {
        let circle = MathGlyphClassifier(testGroups: ["ambig_circle"]) { _ in
            ["ambig_circle": 1]
        }
        let bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        let context = SymbolResolver.Context(mode: .math)
        let likelihoods = circle.labelLikelihoods(
            strokes: [stroke([(0, 0), (10, 10)])], bounds: bounds, context: context
        )
        XCTAssertEqual(Set(likelihoods.keys), Set([".", "·", "0", "o", "°"]))
        let dot = SymbolResolver.memberWeights(class: "dot", bounds: bounds, context: context)
        let ring = SymbolResolver.memberWeights(class: "ring", bounds: bounds, context: context)
        for (label, weight) in dot.merging(ring, uniquingKeysWith: { first, _ in first }) {
            XCTAssertEqual(try XCTUnwrap(likelihoods[label]), weight / 2, accuracy: 1e-12)
        }

        let unmapped = MathGlyphClassifier(testGroups: ["ambig_pi_product"]) { _ in
            ["ambig_pi_product": 1]
        }
        XCTAssertTrue(unmapped.labelLikelihoods(
            strokes: [stroke([(0, 0), (10, 10)])], bounds: bounds, context: context
        ).isEmpty)
    }

    func testV2GlobalsUseRawKeptPointBoundsAndIgnoreStrokeWidth() throws {
        let horizontal = [stroke([(0, 0), (12, 0)])]
        let vertical = [stroke([(0, 0), (0, 12)])]
        let dots = [stroke([(0, 0)]), stroke([(2, 1)]), stroke([(1, 0)])]
        let thick = [stroke([(0, 0), (12, 0)], width: 40)]

        let horizontalGlobals = try globals(for: horizontal)
        let verticalGlobals = try globals(for: vertical)
        let dotsGlobals = try globals(for: dots)
        let thickGlobals = try globals(for: thick)
        XCTAssertEqual(horizontalGlobals[0], Float(1.0 / 6.0), accuracy: 1e-7)
        XCTAssertEqual(horizontalGlobals[1], 1, accuracy: 1e-7)
        XCTAssertEqual(verticalGlobals[0], Float(1.0 / 6.0), accuracy: 1e-7)
        XCTAssertEqual(verticalGlobals[1], -1, accuracy: 1e-7)
        XCTAssertEqual(dotsGlobals[0], 0.5, accuracy: 1e-7)
        XCTAssertEqual(dotsGlobals[1], Float(Darwin.log(2.0) / 3), accuracy: 1e-7)
        XCTAssertEqual(thickGlobals, horizontalGlobals)
    }

    func testDummyThreeInputModelWhenDirectoryIsSet() throws {
        guard let directory = ProcessInfo.processInfo.environment["MATH_GLYPH_DUMMY_DIR"] else {
            throw XCTSkip("Set MATH_GLYPH_DUMMY_DIR to the exported dummy model directory.")
        }
        let classifier = MathGlyphClassifier(testRuntimeAt: URL(fileURLWithPath: directory))
        XCTAssertTrue(classifier.isAvailable, "The dummy manifest or 3-input Core ML model failed validation.")
        XCTAssertEqual(classifier.decoderConfiguration.lambda, 0.6, accuracy: 1e-12)
        let likelihoods = classifier.labelLikelihoods(
            strokes: [stroke([(0, 0), (10, 5)])], bounds: CGRect(x: 0, y: 0, width: 10, height: 5),
            context: mathContext
        )
        XCTAssertEqual(likelihoods.count, 5)
        XCTAssertEqual(likelihoods.values.reduce(0, +), 1, accuracy: 1e-6)
    }

    private var mathContext: SymbolResolver.Context {
        SymbolResolver.Context(medianHeight: 20, baseline: 100, mode: .math)
    }

    private func stroke(_ coordinates: [(Double, Double)], width: Double = 2) -> Stroke {
        Stroke(points: coordinates.enumerated().map { index, point in
            StrokePoint(x: point.0, y: point.1, t: Double(index) * 0.01)
        }, color: .black, width: width)
    }

    private func globals(for strokes: [Stroke]) throws -> [Float] {
        let classes = try XCTUnwrap(MathVocabulary.bundled?.classes)
        var capturedGlobals: [Float]?
        let classifier = MathGlyphClassifier(testClasses: classes, temperature: 1) { _, _, globals in
            capturedGlobals = globals
            return [Double](repeating: 0, count: classes.count)
        }
        _ = classifier.labelLikelihoods(strokes: strokes, bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
                                        context: mathContext)
        return try XCTUnwrap(capturedGlobals)
    }
}
