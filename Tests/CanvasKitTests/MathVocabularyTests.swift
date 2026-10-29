import Foundation
import XCTest
@testable import CanvasKit

final class MathVocabularyTests: XCTestCase {
    func testV2VocabularyHasExpectedClassesLabelsAndLogitOrder() throws {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let expected = Set(Array("0123456789") + Array("abcdefghijklmnopqrstuvwxyz")
                           + Array("+−·÷=≠<>≤≥±/!") + Array("()[]{}|") + Array(".,′")
                           + Array("√∫∑πθΔ∞→°")).map(String.init)

        XCTAssertEqual(vocabulary.version, 2)
        XCTAssertEqual(vocabulary.classes.count, 64)
        XCTAssertEqual(vocabulary.labels.count, 69)
        XCTAssertEqual(vocabulary.classes.map(\.id), vocabulary.classes.map(\.id).sorted())
        XCTAssertEqual(Set(vocabulary.labels.map(\.label)), Set(expected + ["<unk>"]))
        XCTAssertEqual(Set(vocabulary.labels.map(\.label)).count, vocabulary.labels.count)

        let classes = Dictionary(uniqueKeysWithValues: vocabulary.classes.map { ($0.id, $0.labels) })
        XCTAssertEqual(classes["ring"], ["0", "o", "°"])
        XCTAssertEqual(classes["bar"], ["1", "|"])
        XCTAssertEqual(classes["glyph_u006C"], ["l"])
        XCTAssertEqual(classes["glyph_u0071"], ["q"])
        XCTAssertEqual(classes["glyph_u007B"], ["{"])
        XCTAssertEqual(classes["glyph_u007D"], ["}"])
        XCTAssertEqual(classes["dot"], [".", "·"])
        XCTAssertEqual(classes["tick"], [",", "′"])
        XCTAssertEqual(classes["junk"], ["<unk>"])
        XCTAssertTrue(vocabulary.classes.filter { $0.id != "junk" }.allSatisfy { $0.labels.allSatisfy { $0.count == 1 } })

        let labelClasses = Dictionary(uniqueKeysWithValues: vocabulary.labels.map { ($0.label, $0.classID) })
        for label in expected where !["0", "o", "°", "1", "l", "|", ".", "·", ",", "′"].contains(label) {
            let scalar = try XCTUnwrap(label.unicodeScalars.first)
            XCTAssertEqual(labelClasses[label], String(format: "glyph_u%04X", scalar.value), label)
        }
        XCTAssertEqual(vocabulary.labels.first(where: { $0.label == "·" })?.kind, "raised")
        XCTAssertEqual(vocabulary.labels.first(where: { $0.label == "′" })?.kind, "raised")
        XCTAssertEqual(vocabulary.labels.first(where: { $0.label == "." })?.kind, "low")
        XCTAssertEqual(vocabulary.labels.first(where: { $0.label == "," })?.kind, "low")
    }

    func testEveryMathLabelUsesAnExistingHersheyGlyph() throws {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        for label in vocabulary.labels {
            if label.label == "<unk>" {
                XCTAssertEqual(label.kind, "junk")
                XCTAssertEqual(label.hershey, "")
                XCTAssertEqual(label.latex, [])
                XCTAssertNil(CleanGlyphs.strokes(for: label.label))
                continue
            }
            XCTAssertNotNil(CleanGlyphs.strokes(for: label.label), "No Hershey glyph for \(label.label)")
            XCTAssertEqual(label.hershey, label.label)
        }
    }
}
