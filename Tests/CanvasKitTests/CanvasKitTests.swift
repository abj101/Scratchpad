import XCTest
@testable import CanvasKit

final class CanvasKitTests: XCTestCase {

    func testCanvasViewCoordinateOriginUsesLayout() {
        let settings = CanvasSettings()
        let canvas = CanvasView(model: CanvasModel(), settings: settings)
        let document = CanvasView(model: CanvasModel(), settings: settings, layout: .document)

        XCTAssertEqual(canvas.worldToView(.zero), CGPoint(x: CanvasView.documentSize / 2, y: CanvasView.documentSize / 2))
        XCTAssertEqual(document.worldToView(.zero), .zero)
        let rect = CGRect(x: -20, y: 35, width: 100, height: 80)
        XCTAssertEqual(document.worldRect(for: document.viewRect(for: rect)), rect)
    }

    // MARK: - Stroke Codable

    func testStrokeCodableRoundTrip() throws {
        let original = Stroke(
            id: UUID(),
            points: [
                StrokePoint(x: 10, y: 20, t: 0),
                StrokePoint(x: 30, y: 40, t: 0.1),
                StrokePoint(x: 50, y: 60, t: 0.2)
            ],
            color: .blue,
            width: 2.5
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Stroke.self, from: encoded)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - Stroke bounds

    func testStrokeBoundsIncludesHalfWidth() {
        let stroke = Stroke(
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 10, y: 10, t: 0.1)
            ],
            color: .black,
            width: 4
        )

        let bounds = stroke.bounds
        // Should include half width (2) plus slack (2) = 4 padding on each side
        XCTAssertTrue(bounds.width > 10, "Bounds width should exceed stroke extent")
        XCTAssertTrue(bounds.height > 10, "Bounds height should exceed stroke extent")
    }

    func testSinglePointStrokeBoundsNonEmpty() {
        let stroke = Stroke(
            points: [StrokePoint(x: 5, y: 5, t: 0)],
            color: .black,
            width: 2
        )

        let bounds = stroke.bounds
        XCTAssertFalse(bounds.isNull, "Single point stroke bounds should not be null")
        XCTAssertTrue(bounds.width > 0, "Single point stroke bounds should have positive width")
        XCTAssertTrue(bounds.height > 0, "Single point stroke bounds should have positive height")
    }

    // MARK: - Stroke hitTest

    func testHitTestPointOnSegment() {
        let stroke = Stroke(
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 10, y: 0, t: 0.1)
            ],
            color: .black,
            width: 2
        )

        // Point on the segment should hit
        XCTAssertTrue(stroke.hitTest(CGPoint(x: 5, y: 0), radius: 1))
    }

    func testHitTestPointFarAway() {
        let stroke = Stroke(
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 10, y: 0, t: 0.1)
            ],
            color: .black,
            width: 2
        )

        // Point far away should miss
        XCTAssertFalse(stroke.hitTest(CGPoint(x: 100, y: 100), radius: 1))
    }

    func testHitTestPointWithinRadius() {
        let stroke = Stroke(
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 10, y: 0, t: 0.1)
            ],
            color: .black,
            width: 2
        )

        // Point within width/2 + radius should hit
        XCTAssertTrue(stroke.hitTest(CGPoint(x: 5, y: 1.5), radius: 1))
    }

    // MARK: - CanvasModel

    func testAddRemovePreservesOrder() {
        let model = CanvasModel()

        let stroke1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 2)
        let stroke2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .blue, width: 2)
        let stroke3 = Stroke(points: [StrokePoint(x: 20, y: 20, t: 0)], color: .red, width: 2)

        model.add(stroke1)
        model.add(stroke2)
        model.add(stroke3)

        XCTAssertEqual(model.strokes.count, 3)
        XCTAssertEqual(model.strokes[0].id, stroke1.id)
        XCTAssertEqual(model.strokes[1].id, stroke2.id)
        XCTAssertEqual(model.strokes[2].id, stroke3.id)

        // Remove middle stroke
        model.remove(ids: [stroke2.id])

        XCTAssertEqual(model.strokes.count, 2)
        XCTAssertEqual(model.strokes[0].id, stroke1.id)
        XCTAssertEqual(model.strokes[1].id, stroke3.id)
    }

    func testUndoRestoresAtOriginalIndex() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let stroke1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 2)
        let stroke2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .blue, width: 2)
        let stroke3 = Stroke(points: [StrokePoint(x: 20, y: 20, t: 0)], color: .red, width: 2)

        model.undoManager.beginUndoGrouping()
        model.add(stroke1)
        model.undoManager.endUndoGrouping()

        model.undoManager.beginUndoGrouping()
        model.add(stroke2)
        model.undoManager.endUndoGrouping()

        model.undoManager.beginUndoGrouping()
        model.add(stroke3)
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.strokes.count, 3)

        model.undoManager.beginUndoGrouping()
        model.remove(ids: [stroke2.id])
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.strokes.count, 2)

        model.undoManager.undo()

        XCTAssertEqual(model.strokes.count, 3)
        XCTAssertEqual(model.strokes[1].id, stroke2.id)
    }

    func testRedoRemovesAgain() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let stroke1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 2)
        let stroke2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .blue, width: 2)

        model.undoManager.beginUndoGrouping()
        model.add(stroke1)
        model.undoManager.endUndoGrouping()

        model.undoManager.beginUndoGrouping()
        model.add(stroke2)
        model.undoManager.endUndoGrouping()

        model.undoManager.beginUndoGrouping()
        model.remove(ids: [stroke2.id])
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.strokes.count, 1)

        model.undoManager.undo()
        XCTAssertEqual(model.strokes.count, 2)

        model.undoManager.redo()
        XCTAssertEqual(model.strokes.count, 1)
    }

    func testOnChangeFiresWithNonNullRect() {
        let model = CanvasModel()
        var firedRect: CGRect?
        model.onChange = { rect in
            firedRect = rect
        }

        let stroke = Stroke(
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 10, y: 10, t: 0.1)
            ],
            color: .black,
            width: 2
        )

        model.add(stroke)

        XCTAssertNotNil(firedRect)
        XCTAssertFalse(firedRect!.isNull)
    }

    func testUndoOfAddRemovesStroke() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .black,
            width: 2
        )

        model.undoManager.beginUndoGrouping()
        model.add(stroke)
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.strokes.count, 1)

        model.undoManager.undo()

        XCTAssertEqual(model.strokes.count, 0)
    }

    // MARK: - Smoothing

    func testSmoothingConstantsArePositive() {
        XCTAssertGreaterThan(Smoothing.minCutoff, 0)
        XCTAssertGreaterThan(Smoothing.beta, 0)
    }

    // MARK: - ToolController

    func testPenDrawsStroke() {
        let model = CanvasModel()
        let settings = CanvasSettings()
        settings.tool = .pen
        settings.color = .red
        settings.width = 3.5

        let controller = ToolController(model: model, settings: settings)
        controller.smoothingEnabled = false

        let pt1 = CGPoint(x: 0, y: 0)
        let pt2 = CGPoint(x: 10, y: 10)
        let pt3 = CGPoint(x: 20, y: 20)
        let pt4 = CGPoint(x: 30, y: 30)
        let pt5 = CGPoint(x: 40, y: 40)
        let pt6 = CGPoint(x: 50, y: 50)

        let t0 = ProcessInfo.processInfo.systemUptime

        controller.handle(PenEvent(phase: .began, point: pt1, timestamp: t0))
        controller.handle(PenEvent(phase: .moved, point: pt2, timestamp: t0 + 0.1))
        controller.handle(PenEvent(phase: .moved, point: pt3, timestamp: t0 + 0.2))
        controller.handle(PenEvent(phase: .moved, point: pt4, timestamp: t0 + 0.3))
        controller.handle(PenEvent(phase: .moved, point: pt5, timestamp: t0 + 0.4))
        controller.handle(PenEvent(phase: .moved, point: pt6, timestamp: t0 + 0.5))
        controller.handle(PenEvent(phase: .ended, point: pt6, timestamp: t0 + 0.5))

        XCTAssertEqual(model.strokes.count, 1)
        let stroke = model.strokes[0]
        XCTAssertEqual(stroke.color, .red)
        XCTAssertEqual(stroke.width, 3.5)
        XCTAssertGreaterThanOrEqual(stroke.points.count, 5)
    }

    func testEraserClearsStroke() {
        let model = CanvasModel()
        let settings = CanvasSettings()
        settings.tool = .eraser
        settings.width = 100 // disc covers the whole stroke, so nothing survives

        let stroke = Stroke(
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 10, y: 10, t: 0.1)
            ],
            color: .black,
            width: 2
        )
        model.add(stroke)

        XCTAssertEqual(model.strokes.count, 1)

        let controller = ToolController(model: model, settings: settings)
        let t0 = ProcessInfo.processInfo.systemUptime

        controller.handle(PenEvent(phase: .began, point: CGPoint(x: 0, y: 0), timestamp: t0))

        XCTAssertTrue(controller.pendingErase.contains(stroke.id))
        XCTAssertEqual(model.strokes.count, 1)

        controller.handle(PenEvent(phase: .ended, point: CGPoint(x: 0, y: 0), timestamp: t0))

        XCTAssertTrue(controller.pendingErase.isEmpty)
        XCTAssertEqual(model.strokes.count, 0)
    }

    func testEraserCancelClearsWithoutRemoving() {
        let model = CanvasModel()
        let settings = CanvasSettings()
        settings.tool = .eraser
        settings.width = 100 // disc covers the whole stroke

        let stroke = Stroke(
            points: [
                StrokePoint(x: 0, y: 0, t: 0),
                StrokePoint(x: 10, y: 10, t: 0.1)
            ],
            color: .black,
            width: 2
        )
        model.add(stroke)

        let controller = ToolController(model: model, settings: settings)
        let t0 = ProcessInfo.processInfo.systemUptime

        controller.handle(PenEvent(phase: .began, point: CGPoint(x: 0, y: 0), timestamp: t0))

        XCTAssertTrue(controller.pendingErase.contains(stroke.id))
        XCTAssertEqual(model.strokes.count, 1)

        controller.handle(PenEvent(phase: .cancelled, point: CGPoint(x: 0, y: 0), timestamp: t0))

        XCTAssertTrue(controller.pendingErase.isEmpty)
        XCTAssertEqual(model.strokes.count, 1)
    }

    func testEraserUndoRestoresStrokeInOneStep() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let settings = CanvasSettings()
        let stroke = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)], color: .black, width: 2)

        model.undoManager.beginUndoGrouping()
        model.add(stroke)
        model.undoManager.endUndoGrouping()

        settings.tool = .eraser
        settings.width = 100 // disc covers the whole stroke, so it is fully erased
        let controller = ToolController(model: model, settings: settings)
        model.undoManager.beginUndoGrouping()
        controller.handle(PenEvent(phase: .began, point: .zero, timestamp: 0))
        controller.handle(PenEvent(phase: .ended, point: .zero, timestamp: 0))
        model.undoManager.endUndoGrouping()
        XCTAssertEqual(model.strokes.count, 0)

        model.undoManager.undo()
        XCTAssertEqual(model.strokes.map(\.id), [stroke.id])
        model.undoManager.redo()
        XCTAssertTrue(model.strokes.isEmpty)
        model.undoManager.undo()
        model.undoManager.undo()
        XCTAssertTrue(model.strokes.isEmpty, "second undo removes the drawn stroke")
    }

    func testEraserRemovesOnlyThePartUnderTheDisc() {
        let model = CanvasModel()
        let settings = CanvasSettings()
        settings.tool = .eraser
        settings.width = 10 // disc radius 5: the middle goes, the two ends stay

        let stroke = Stroke(points: [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 20, y: 0, t: 0.1),
            StrokePoint(x: 40, y: 0, t: 0.2),
        ], color: .black, width: 2)
        model.add(stroke)

        let controller = ToolController(model: model, settings: settings)
        let t0 = ProcessInfo.processInfo.systemUptime
        controller.handle(PenEvent(phase: .began, point: CGPoint(x: 20, y: 0), timestamp: t0))
        controller.handle(PenEvent(phase: .ended, point: CGPoint(x: 20, y: 0), timestamp: t0))

        XCTAssertFalse(model.contains(id: stroke.id), "the original whole stroke is gone")
        XCTAssertEqual(model.strokes.count, 2, "the two ends survive as separate pieces")
        let runs = model.strokes.map { $0.points.map(\.x) }.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
        XCTAssertEqual(runs, [[0], [40]])
    }
}
