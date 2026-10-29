import CoreGraphics
import XCTest
@testable import CanvasKit

final class MathScriptTests: XCTestCase {
    private let cell = LetterCell(margin: 0, top: 100, height: 40)

    private func role(_ fractions: [CGFloat], label: String = "2", kind: String = "digit") -> MathScript.Role {
        MathScript.zoneRole(ys: fractions.map { 100 + $0 * 40 }, cell: cell, label: label, kind: kind)
    }

    func testZoneWithMostInkSetsRole() {
        XCTAssertEqual(role([0.05, 0.1, 0.2]), .superscript)
        XCTAssertEqual(role([0.8, 0.9, 0.95]), .subscript)
        XCTAssertEqual(role([0.3, 0.5, 0.7]), .inherit)
        // Straddles upper and middle; most points are in the middle.
        XCTAssertEqual(role([0.1, 0.3, 0.4, 0.5]), .inherit)
        XCTAssertEqual(role([0.1, 0.15, 0.2, 0.4]), .superscript)
    }

    func testMiddleZoneInheritsScript() {
        XCTAssertEqual(role([0.4, 0.5]), .inherit)
        XCTAssertEqual(role([0.4, 0.5], label: ".", kind: "low"), .inherit)
        XCTAssertEqual(role([0.9, 0.95], label: ".", kind: "low"), .inherit)
        XCTAssertEqual(role([0.05, 0.1]), .superscript)
        XCTAssertEqual(role([0.9, 0.95]), .subscript)
    }
}
