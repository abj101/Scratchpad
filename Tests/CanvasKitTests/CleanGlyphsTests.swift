import CoreGraphics
import Foundation
import XCTest
@testable import CanvasKit

final class CleanGlyphsTests: XCTestCase {
    private struct Vocabulary: Decodable {
        struct GlyphClass: Decodable {
            let label: String
            let hwrtIDs: [Int]
            let hershey: String
            let group: String
            let kind: String
            let hersheySources: [Int]

            enum CodingKeys: String, CodingKey {
                case label, hershey, group, kind
                case hwrtIDs = "hwrt_ids"
                case hersheySources = "hershey_sources"
            }
        }

        let version: Int
        let classes: [GlyphClass]
    }

    private struct GlyphResource: Decodable {
        let sourceID: Int?
        let sourceIDs: [Int]
        let composition: String?
        let baseline: Double
        let advance: Double
        let strokes: [[[Double]]]
    }

    private var expectedLabels: [String] {
        let labels = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            + Array(".,;:!?\'\"()[]{}-_ /\\|@#$%&*^~".replacingOccurrences(of: " ", with: ""))
            + Array("+−×÷±=≠<>≤≥≈≡∼∝√∫∑∏∞∂∇∈∉⊂⊆∪∩∅∀∃¬→←↔⇒⇔°′·∠⊥∥")
            + Array("αβγδεθλμπρστφχψωΓΔΘΛΠΣΦΩ")
            + ["∘", "—"]
        return labels.map(String.init).sorted()
    }

    private func resourceData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(CleanGlyphs.resourceBundle.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func glyphResources() throws -> [String: GlyphResource] {
        try JSONDecoder().decode([String: GlyphResource].self, from: resourceData("HersheyGlyphs"))
    }

    private func vocabulary() throws -> Vocabulary {
        try JSONDecoder().decode(Vocabulary.self, from: resourceData("vocab"))
    }

    private func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    func testFullVocabularyHasMatchingGlyphsGroupsAndSourceMetadata() throws {
        let glyphs = try glyphResources()
        let vocab = try vocabulary()
        let expected = Set(expectedLabels)

        XCTAssertEqual(vocab.version, 1)
        XCTAssertEqual(expected.count, 158)
        XCTAssertEqual(Set(CleanGlyphs.labels), expected)
        XCTAssertEqual(CleanGlyphs.labels, expectedLabels)
        XCTAssertEqual(Set(glyphs.keys), expected)
        XCTAssertEqual(vocab.classes.count, 158)
        XCTAssertEqual(vocab.classes.map(\.label).sorted(), expectedLabels)
        XCTAssertEqual(Set(vocab.classes.map(\.group)).count, 131)

        for entry in vocab.classes {
            let glyph = try XCTUnwrap(glyphs[entry.hershey], "No Hershey row for \(entry.label)")
            XCTAssertEqual(entry.hershey, entry.label)
            XCTAssertFalse(glyph.strokes.isEmpty, "No strokes for \(entry.label)")
            XCTAssertEqual(glyph.baseline, 9, "Unexpected baseline for \(entry.label)")
            XCTAssertGreaterThan(glyph.advance, 0, "Invalid advance for \(entry.label)")
            XCTAssertEqual(CleanGlyphs.metrics(for: entry.label)?.baseline, 9)
            XCTAssertEqual(CleanGlyphs.metrics(for: entry.label)?.advance, glyph.advance)
            XCTAssertNotNil(CleanGlyphs.strokes(for: entry.label))

            let points = glyph.strokes.flatMap { $0 }
            XCTAssertTrue(points.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) }, "Invalid point for \(entry.label)")
            if glyph.composition != nil {
                XCTAssertNil(glyph.sourceID, "A composition must not claim a whole-glyph source: \(entry.label)")
                XCTAssertFalse(glyph.sourceIDs.isEmpty, "Missing composition source IDs for \(entry.label)")
                XCTAssertTrue(entry.hersheySources.isEmpty, "Components are not whole-glyph variants: \(entry.label)")
            } else {
                let sourceID = try XCTUnwrap(glyph.sourceID, "Missing whole-glyph source for \(entry.label)")
                XCTAssertEqual(entry.hersheySources, glyph.sourceIDs)
                XCTAssertTrue(entry.hersheySources.contains(sourceID))
            }
        }

        let classesByGroup = Dictionary(grouping: vocab.classes, by: \.group)
        let expectedGroups: [String: Set<String>] = [
            "ambig_circle": ["0", "o", "O", "∘", "°", ".", "·"],
            "ambig_one_bar": ["1", "l", "I", "|"],
            "ambig_x_times": ["x", "X", "×"],
            "ambig_dash": ["-", "−", "_", "—"],
            "ambig_comma_quote": [",", "'"],
            "ambig_epsilon_in": ["ε", "∈"],
            "ambig_sigma_sum": ["Σ", "∑"],
            "ambig_pi_product": ["Π", "∏"],
            "ambig_case_c": ["c", "C"],
            "ambig_case_s": ["s", "S"],
            "ambig_case_v": ["v", "V"],
            "ambig_case_w": ["w", "W"],
            "ambig_case_z": ["z", "Z"],
            "ambig_case_p": ["p", "P"],
            "ambig_case_k": ["k", "K"],
            "ambig_case_u": ["u", "U"],
            "ambig_case_y": ["y", "Y"],
        ]
        for (group, expectedMembers) in expectedGroups {
            XCTAssertEqual(Set(try XCTUnwrap(classesByGroup[group]).map(\.label)), expectedMembers, group)
        }

        let classesByLabel = Dictionary(uniqueKeysWithValues: vocab.classes.map { ($0.label, $0) })
        XCTAssertEqual(classesByLabel["0"]?.hwrtIDs, [70])
        XCTAssertEqual(classesByLabel["A"]?.hwrtIDs, [31])
        XCTAssertEqual(classesByLabel["a"]?.hwrtIDs, [90])
        let syntheticOnly = Set("t.,;:!?\'\"()_@*=^~".map(String.init))
        XCTAssertEqual(Set(vocab.classes.filter { $0.hwrtIDs.isEmpty }.map(\.label)), syntheticOnly)
    }

    func testCleanGlyphGeometryAndUnsupportedLabel() throws {
        XCTAssertNil(CleanGlyphs.strokes(for: "🙂"))
        XCTAssertEqual(CleanGlyphs.strokes(for: "−"), [[CGPoint(x: -6, y: 0), CGPoint(x: 6, y: 0)]])
        XCTAssertEqual(CleanGlyphs.strokes(for: "|"), [[CGPoint(x: 0, y: -16), CGPoint(x: 0, y: 16)]])
        XCTAssertEqual(CleanGlyphs.strokes(for: "."), [[
            CGPoint(x: 0, y: 7), CGPoint(x: -1, y: 8), CGPoint(x: 0, y: 9),
            CGPoint(x: 1, y: 8), CGPoint(x: 0, y: 7),
        ]])

        XCTAssertEqual(CleanGlyphs.strokes(for: "+"), [
            [CGPoint(x: 0, y: -6), CGPoint(x: 0, y: 6)],
            [CGPoint(x: -6, y: 0), CGPoint(x: 6, y: 0)],
        ])
        XCTAssertEqual(CleanGlyphs.strokes(for: "="), [
            [CGPoint(x: -6, y: -2), CGPoint(x: 6, y: -2)],
            [CGPoint(x: -6, y: 2), CGPoint(x: 6, y: 2)],
        ])
        XCTAssertEqual(CleanGlyphs.strokes(for: "×"), [
            [CGPoint(x: -5, y: -5), CGPoint(x: 5, y: 5)],
            [CGPoint(x: 5, y: -5), CGPoint(x: -5, y: 5)],
        ])

        let yPoints = try XCTUnwrap(CleanGlyphs.strokes(for: "y")?.flatMap { $0 })
        XCTAssertEqual(yPoints.map(\.y).max(), 16, "The lowercase y descender must remain below baseline")
        let commaPoints = try XCTUnwrap(CleanGlyphs.strokes(for: ",")?.flatMap { $0 })
        XCTAssertGreaterThan(try XCTUnwrap(commaPoints.map(\.y).max()), 9)
    }

    func testComposedGlyphsUseDocumentedWholeShapesAndCorrectGeometry() throws {
        let glyphs = try glyphResources()
        let vocab = try vocabulary()
        let composed = Set(glyphs.filter { $0.value.composition != nil }.map(\.key))
        XCTAssertEqual(composed, Set(["—", "≈", "≤", "≥", "∉", "⊆", "∅", "∀", "¬", "↔", "⇒", "⇔", "⊥", "∘", "^"]))

        for label in ["≤", "≥", "⊆"] {
            let strokes = try XCTUnwrap(CleanGlyphs.strokes(for: label))
            XCTAssertEqual(strokes.count, 2, "\(label) should contain one base and one lower bar")
            let bar = try XCTUnwrap(strokes.first { $0.count == 2 && $0[0].y == $0[1].y })
            let base = try XCTUnwrap(strokes.first { $0.count > 2 })
            XCTAssertGreaterThan(bar[0].y, base.map(\.y).max()!)
            XCTAssertTrue(try XCTUnwrap(glyphs[label]?.sourceIDs).contains(1238))
        }

        let perpendicular = try XCTUnwrap(CleanGlyphs.strokes(for: "⊥"))
        let perpBounds = bounds(perpendicular.flatMap { $0 })
        XCTAssertEqual(perpBounds.midY, 0, accuracy: 0.001)
        let cap = try XCTUnwrap(perpendicular.first { $0.count == 2 && $0[0].y == $0[1].y })
        XCTAssertEqual(cap[0].y, perpBounds.maxY, accuracy: 0.001)

        for label in ["∘", "∅", "∀", "≈", "≤", "≥", "⊆", "⊥", "¬", "↔", "⇒", "⇔"] {
            XCTAssertEqual(bounds(try XCTUnwrap(CleanGlyphs.strokes(for: label)?.flatMap { $0 })).midY, 0, accuracy: 0.001, label)
        }

        let emptySet = try XCTUnwrap(CleanGlyphs.strokes(for: "∅"))
        XCTAssertEqual(emptySet.count, 2)
        let loopBounds = bounds(emptySet[0])
        let slashBounds = bounds(emptySet[1])
        XCTAssertEqual(loopBounds.midX, 0, accuracy: 0.001)
        XCTAssertEqual(loopBounds.midY, 0, accuracy: 0.001)
        XCTAssertEqual(slashBounds.midY, 0, accuracy: 0.001)
        XCTAssertGreaterThan(slashBounds.height, loopBounds.height)

        let caret = try XCTUnwrap(glyphs["^"])
        XCTAssertNil(caret.sourceID)
        XCTAssertEqual(caret.sourceIDs, [537])
        XCTAssertTrue(try XCTUnwrap(vocab.classes.first { $0.label == "^" }).hersheySources.isEmpty)
        let caretBounds = bounds(try XCTUnwrap(CleanGlyphs.strokes(for: "^")?.flatMap { $0 }))
        XCTAssertLessThan(caretBounds.maxY, 0, "Caret should be raised, not an up-arrow with a long shaft")
    }

    func testRenderFitsHorizontalVerticalAndSinglePointShapes() {
        let box = CGRect(x: 20, y: 30, width: 100, height: 80)
        let color = RGBA(r: 0.2, g: 0.3, b: 0.4)
        let original = [Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: color, width: 3)]
        func render(_ points: [CGPoint]) -> [Stroke] {
            GlyphTemplates.render(GlyphSample(strokes: [points]), into: box, like: original)
        }
        func assertStyleAndFinite(_ rendered: [Stroke], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(rendered.count, 1, file: file, line: line)
            XCTAssertEqual(rendered[0].color, color, file: file, line: line)
            XCTAssertEqual(rendered[0].width, 3, file: file, line: line)
            XCTAssertTrue(rendered.flatMap(\.points).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.t.isFinite }, file: file, line: line)
        }

        let horizontal = render([CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0)])
        assertStyleAndFinite(horizontal)
        let horizontalPoints = horizontal.flatMap(\.points).map(\.cgPoint)
        XCTAssertEqual(bounds(horizontalPoints).width, box.width, accuracy: 0.001)
        XCTAssertEqual(bounds(horizontalPoints).midY, box.midY, accuracy: 0.001)

        let vertical = render([CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)])
        assertStyleAndFinite(vertical)
        let verticalPoints = vertical.flatMap(\.points).map(\.cgPoint)
        XCTAssertEqual(bounds(verticalPoints).height, box.height, accuracy: 0.001)
        XCTAssertEqual(bounds(verticalPoints).midX, box.midX, accuracy: 0.001)

        let dot = render([CGPoint(x: 3, y: -2)])
        assertStyleAndFinite(dot)
        XCTAssertEqual(dot[0].points.map(\.cgPoint), [CGPoint(x: box.midX, y: box.midY)])
        XCTAssertTrue(GlyphTemplates.render(GlyphSample(strokes: [[CGPoint]]()), into: box, like: original).isEmpty)
        XCTAssertTrue(GlyphTemplates.render(GlyphSample(strokes: [[.zero]]), into: .zero, like: original).isEmpty)
    }
}
