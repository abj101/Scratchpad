import XCTest
@testable import CanvasKit

final class DocumentLayoutTests: XCTestCase {
    func testColumnUsesFullWidthWithSideMargins() {
        XCTAssertEqual(DocumentLayout.columnWidth(viewportWidth: 800), 744)
        XCTAssertEqual(DocumentLayout.columnWidth(viewportWidth: 20), 0)
    }

    func testTopInsetClearsTopBandWithFormattingBarClosed() {
        XCTAssertEqual(DocumentLayout.topInset, FloatingChromeLayout.topZoneHeight + FloatingChromeLayout.spacing)
    }

    func testOpenFormattingBarMovesTextBelowItself() {
        XCTAssertEqual(DocumentLayout.formattingBarDrop,
                       FloatingChromeLayout.formattingBarHeight + FloatingChromeLayout.spacing)
    }

    func testHeightOnlyAllowsScrollingPastViewportWhenContentReachesBottom() {
        XCTAssertEqual(DocumentLayout.documentHeight(contentBottom: 215, viewportHeight: 200), 200)
        XCTAssertEqual(DocumentLayout.documentHeight(contentBottom: 250, viewportHeight: 200), 250)
    }
}
