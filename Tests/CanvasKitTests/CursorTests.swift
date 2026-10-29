import AppKit
import XCTest
@testable import CanvasKit

final class CursorTests: XCTestCase {
    func testOpeningToolMenuPreservesToolbarArrow() {
        let settings = CanvasSettings()
        let view = CanvasView(model: CanvasModel(), settings: settings)
        view.setToolbarHovered(true)
        settings.toggleToolMenu(.color)
        XCTAssertTrue(view.currentCursor() === NSCursor.arrow, "Hotspot: \(view.currentCursor().hotSpot)")
        settings.toggleToolMenu(.width)
        XCTAssertTrue(view.currentCursor() === NSCursor.arrow, "Hotspot: \(view.currentCursor().hotSpot)")
        settings.toggleToolMenu(.width)
    }

    func testWidthAdjustmentIncreasesDecreasesAndClamps() {
        let settings = CanvasSettings()
        settings.width = 2.5
        settings.adjustWidth(by: 0.5)
        XCTAssertEqual(settings.width, 3)
        settings.adjustWidth(by: -1)
        XCTAssertEqual(settings.width, 2)
        settings.adjustWidth(by: -100)
        XCTAssertEqual(settings.width, 0.5)
        settings.adjustWidth(by: 100)
        XCTAssertEqual(settings.width, 100)
        settings.adjustWidth(by: .nan)
        XCTAssertEqual(settings.width, 100)
    }

    func testKeyboardWidthClampMatchesScrollRange() {
        XCTAssertEqual(CanvasView.clampWidth(80 * 1.25), 100)
        XCTAssertEqual(CanvasView.clampWidth(125), 100)
        XCTAssertEqual(CanvasView.clampWidth(0.1), 0.5)
    }

    func testCircleTransitionKeepsItsHotspotAndEndsAtNativeArrow() {
        let frames = Cursors.canvasToArrow
        XCTAssertEqual(frames.count, 13)
        for cursor in frames.dropLast() {
            XCTAssertEqual(cursor.hotSpot, NSPoint(x: 12, y: 12))
            XCTAssertGreaterThanOrEqual(cursor.image.size.width, 32)
            XCTAssertGreaterThanOrEqual(cursor.image.size.height, 32)
        }
        XCTAssertTrue(frames.last === NSCursor.arrow)
    }
}
