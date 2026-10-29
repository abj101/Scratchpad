import XCTest
@testable import CanvasKit

final class TextScaleTests: XCTestCase {

    // MARK: - Scale for magnification

    func testScaleIsOneAtOrAboveActualSize() {
        XCTAssertEqual(TextBlock.scale(forMagnification: 1), 1)
        XCTAssertEqual(TextBlock.scale(forMagnification: 4), 1)
    }

    func testScaleIsInverseWhenZoomedOut() {
        XCTAssertEqual(TextBlock.scale(forMagnification: 0.25), 4)
        XCTAssertEqual(TextBlock.scale(forMagnification: 0.5), 2)
    }

    func testScaleIgnoresInvalidMagnification() {
        XCTAssertEqual(TextBlock.scale(forMagnification: 0), 1)
        XCTAssertEqual(TextBlock.scale(forMagnification: -1), 1)
    }

    // MARK: - Codable

    func testScaleRoundTrips() throws {
        let block = TextBlock(origin: .zero, width: 960, scale: 4)
        let decoded = try JSONDecoder().decode(TextBlock.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(decoded, block)
        XCTAssertEqual(decoded.scale, 4)
    }

    func testOlderBlockWithoutScaleDecodesAsOne() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TextBlock(origin: .zero))) as! [String: Any]
        json.removeValue(forKey: "scale")
        let decoded = try JSONDecoder().decode(TextBlock.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.scale, 1)
    }

    // MARK: - View

    func testScaledViewLaysOutTextAtNormalSizeAndDrawsLarger() {
        let text = NSAttributedString(string: "Hello world", attributes: TextFormatting.defaultAttributes)
        let plain = TextBlockView(blockID: UUID(), width: 240)
        plain.setContents(text)
        let scaled = TextBlockView(blockID: UUID(), width: 960, scale: 4)
        scaled.setContents(text)

        XCTAssertEqual(scaled.frame.width, 960, accuracy: 0.01)
        XCTAssertEqual(scaled.bounds.width, 240, accuracy: 0.01)
        XCTAssertEqual(scaled.layoutHeight(), plain.layoutHeight() * 4, accuracy: 0.01)
        XCTAssertEqual(scaled.frame.height, scaled.layoutHeight(), accuracy: 0.01)
        XCTAssertEqual(scaled.textView.font?.pointSize ?? TextFormatting.bodySize, TextFormatting.bodySize)
    }

    func testScaledViewWidthIsInWorldPoints() {
        let view = TextBlockView(blockID: UUID(), width: 960, scale: 4)
        view.setWidth(480)
        XCTAssertEqual(view.frame.width, 480, accuracy: 0.01)
        XCTAssertEqual(view.bounds.width, 120, accuracy: 0.01)
        view.setWidth(10) // clamps to minWidth text points
        XCTAssertEqual(view.bounds.width, CGFloat(TextBlock.minWidth), accuracy: 0.01)
    }
}
