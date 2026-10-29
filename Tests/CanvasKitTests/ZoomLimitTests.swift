import AppKit
import XCTest
@testable import CanvasKit

final class ZoomLimitTests: XCTestCase {
    func testZoomCommandsAndRestoredViewportRespectLimits() {
        let view = CanvasScrollView(model: CanvasModel(), settings: CanvasSettings())
        view.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        view.tile()
        // AppKit uses these same bounds for pinch magnification.
        XCTAssertEqual(view.minMagnification, 0.25)
        XCTAssertEqual(view.maxMagnification, 4)
        for _ in 0..<30 { view.zoomOut() }
        XCTAssertEqual(view.magnification, 0.25)
        for _ in 0..<30 { view.zoomIn() }
        XCTAssertEqual(view.magnification, 4)
        view.setViewport(Viewport(magnification: 0.01))
        XCTAssertEqual(view.magnification, 0.25)
        view.setViewport(Viewport(magnification: 20))
        XCTAssertEqual(view.magnification, 4)
        view.zoomToActualSize()
        XCTAssertEqual(view.magnification, 1)
    }

    func testZoomToFitStopsAtMinimumForLargeNotes() {
        let model = CanvasModel()
        model.add(Stroke(points: [StrokePoint(x: -5000, y: -5000, t: 0),
                                  StrokePoint(x: 5000, y: 5000, t: 1)],
                         color: .black, width: 2.5))
        let view = CanvasScrollView(model: model, settings: CanvasSettings())
        view.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        view.tile()
        view.zoomToFit()
        XCTAssertEqual(view.magnification, 0.25)
    }
}
