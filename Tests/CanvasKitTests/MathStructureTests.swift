import XCTest
@testable import CanvasKit

final class MathStructureTests: XCTestCase {
    func testRecognizedLabelsMapToTheirStructure() {
        XCTAssertEqual(MathStructure.kind(forLabel: "∑"), .summation)
        XCTAssertEqual(MathStructure.kind(forLabel: "∫"), .integral)
        XCTAssertEqual(MathStructure.kind(forLabel: "√"), .squareRoot)
        XCTAssertEqual(MathStructure.kind(forLabel: "lim"), .limit)
        XCTAssertEqual(MathStructure.kind(forLabel: "abs"), .absoluteValue)
    }

    func testPlainSymbolsDoNotOpenAStructure() {
        for label in ["x", "3", "+", "/", "π", "→", "∞", "sin", "<unk>", ""] {
            XCTAssertNil(MathStructure.kind(forLabel: label), "\(label) must stay a plain symbol")
        }
    }

    func testStructureNamesAreTheEditorsContract() {
        // editor.js keys its templates by these names; renaming one silently disables it.
        XCTAssertEqual(MathStructure.Kind.summation.rawValue, "sum")
        XCTAssertEqual(MathStructure.Kind.integral.rawValue, "int")
        XCTAssertEqual(MathStructure.Kind.limit.rawValue, "lim")
        XCTAssertEqual(MathStructure.Kind.absoluteValue.rawValue, "abs")
        XCTAssertEqual(MathStructure.Kind.squareRoot.rawValue, "sqrt")
        XCTAssertEqual(MathStructure.Kind.rootIndex.rawValue, "root")
    }
}
