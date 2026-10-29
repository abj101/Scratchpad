import AppKit
import XCTest
@testable import CanvasKit

final class DocumentScrollTests: XCTestCase {
    func testDocumentPinsHorizontalScrollAndIgnoresZoom() {
        let scroll = CanvasScrollView(model: CanvasModel(layout: .document), settings: CanvasSettings(), layout: .document)
        scroll.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        scroll.tile()
        let constrained = scroll.contentView.constrainBoundsRect(CGRect(x: 90, y: -40, width: 560, height: 680))
        XCTAssertEqual(constrained.minX, 0)
        XCTAssertEqual(constrained.minY, 0)
        XCTAssertFalse(scroll.allowsMagnification)
        for zoom in [scroll.zoomIn, scroll.zoomOut, scroll.zoomToFit, scroll.zoomToActualSize] { zoom() }
        XCTAssertEqual(scroll.magnification, 1)
        XCTAssertEqual(scroll.canvasView.frame.width, scroll.contentView.bounds.width)
    }

    func testDocumentClampsRestoredScrollToContent() {
        let saved = Viewport(center: CGPoint(x: 300, y: 5000), magnification: 3)
        let scroll = CanvasScrollView(model: CanvasModel(layout: .document), settings: CanvasSettings(),
                                      viewport: saved, layout: .document)
        scroll.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        scroll.tile()
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        XCTAssertNotEqual(scroll.viewport.center.y, saved.center.y)
        XCTAssertEqual(scroll.viewport.magnification, 1)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
    }
}
