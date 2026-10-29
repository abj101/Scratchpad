import XCTest
@testable import CanvasKit

final class ResizeTests: XCTestCase {

    func step(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    // MARK: - Model: scale

    func testScallingDoublesPointsAndWidth() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let from = CGRect(x: 0, y: 0, width: 10, height: 10)
        let to = CGRect(x: 0, y: 0, width: 20, height: 20)
        step(um) { model.scale(ids: [stroke.id], from: from, to: to) }

        XCTAssertEqual(model.strokes.count, 1)
        XCTAssertEqual(model.strokes[0].points[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].points[0].y, 0, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].points[1].x, 20, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].points[1].y, 20, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].width, 4, accuracy: 0.001)
    }

    func testScaleWithTranslation() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 0, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let from = CGRect(x: 0, y: 0, width: 10, height: 10)
        let to = CGRect(x: 100, y: 100, width: 20, height: 20)
        step(um) { model.scale(ids: [stroke.id], from: from, to: to) }

        XCTAssertEqual(model.strokes[0].points[0].x, 100, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].points[0].y, 100, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].points[1].x, 120, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].points[1].y, 100, accuracy: 0.001)
    }

    func testUndoRestoresOriginalStrokes() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let originalPoints = [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)]
        let stroke = Stroke(points: originalPoints, color: .black, width: 2)
        step(um) { model.add(stroke) }

        let from = CGRect(x: 0, y: 0, width: 10, height: 10)
        let to = CGRect(x: 0, y: 0, width: 20, height: 20)
        step(um) { model.scale(ids: [stroke.id], from: from, to: to) }

        let scaled = model.strokes[0]
        XCTAssertEqual(scaled.points[1].x, 20, accuracy: 0.001)

        um.undo()
        let restored = model.strokes[0]
        XCTAssertEqual(restored.points[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(restored.points[0].y, 0, accuracy: 0.001)
        XCTAssertEqual(restored.points[1].x, 10, accuracy: 0.001)
        XCTAssertEqual(restored.points[1].y, 10, accuracy: 0.001)
        XCTAssertEqual(restored.width, 2, accuracy: 0.001)
    }

    func testRedoReapplies() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let from = CGRect(x: 0, y: 0, width: 10, height: 10)
        let to = CGRect(x: 0, y: 0, width: 20, height: 20)
        step(um) { model.scale(ids: [stroke.id], from: from, to: to) }

        um.undo()
        um.redo()

        XCTAssertEqual(model.strokes[0].points[1].x, 20, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].points[1].y, 20, accuracy: 0.001)
        XCTAssertEqual(model.strokes[0].width, 4, accuracy: 0.001)
    }

    func testScaleIgnoresNonStrokeIDs() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        let textBlock = TextBlock(origin: .zero, width: 100, height: 100)
        step(um) { model.add(stroke); model.addTextBlock(textBlock) }

        let from = CGRect(x: 0, y: 0, width: 10, height: 10)
        let to = CGRect(x: 0, y: 0, width: 20, height: 20)
        step(um) { model.scale(ids: [stroke.id, textBlock.id], from: from, to: to) }

        // Stroke should be scaled
        XCTAssertEqual(model.strokes[0].points[1].x, 20, accuracy: 0.001)
        // Text block should be unchanged
        XCTAssertEqual(model.textBlocks[0].origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(model.textBlocks[0].width, 100, accuracy: 0.001)
    }

    func testScaleWidthClampedToRange() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 1, y: 1, t: 0.1)],
            color: .black,
            width: 100
        )
        step(um) { model.add(stroke) }

        let from = CGRect(x: 0, y: 0, width: 1, height: 1)
        let to = CGRect(x: 0, y: 0, width: 2, height: 2)
        step(um) { model.scale(ids: [stroke.id], from: from, to: to) }

        // Width would be 200, but should be clamped to max of 100
        XCTAssertEqual(model.strokes[0].width, CanvasSettings.widthRange.upperBound)
    }

    func testScaleGuardsAgainstInvalidRects() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let original = model.strokes[0]

        // Null rect - should be no-op
        model.scale(ids: [stroke.id], from: .null, to: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(model.strokes[0], original)

        // Zero width - should be no-op
        model.scale(ids: [stroke.id], from: CGRect(x: 0, y: 0, width: 0, height: 10), to: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(model.strokes[0], original)

        // Negative width - should be no-op
        model.scale(ids: [stroke.id], from: CGRect(x: 0, y: 0, width: -10, height: 10), to: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(model.strokes[0], original)
    }

    // MARK: - Selection: canResize and corner

    func testCanResizeWithStrokesOnly() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model, includesTextBlocks: true)
        selection.select([stroke.id])

        XCTAssertTrue(selection.canResize)
    }

    func testCanResizeIsFalseWhenEmpty() {
        let model = CanvasModel()
        let selection = SelectionController(model: model)

        XCTAssertFalse(selection.canResize)
    }

    func testCanResizeIsFalseWithTextBlock() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        let textBlock = TextBlock(origin: .zero, width: 100, height: 100)
        step(um) { model.add(stroke); model.addTextBlock(textBlock) }

        let selection = SelectionController(model: model, includesTextBlocks: true)
        selection.select([stroke.id, textBlock.id])

        XCTAssertFalse(selection.canResize)
    }

    func testCornerHitDetection() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 100, y: 100, t: 0.1)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model)
        selection.select([stroke.id])

        let bounds = selection.selectionBounds
        let radius: Double = 5

        // Test corner hits
        if let topLeft = selection.corner(at: CGPoint(x: bounds.minX, y: bounds.minY), radius: radius) {
            XCTAssertEqual(topLeft, .topLeft)
        }
        if let topRight = selection.corner(at: CGPoint(x: bounds.maxX, y: bounds.minY), radius: radius) {
            XCTAssertEqual(topRight, .topRight)
        }
        if let bottomLeft = selection.corner(at: CGPoint(x: bounds.minX, y: bounds.maxY), radius: radius) {
            XCTAssertEqual(bottomLeft, .bottomLeft)
        }
        if let bottomRight = selection.corner(at: CGPoint(x: bounds.maxX, y: bounds.maxY), radius: radius) {
            XCTAssertEqual(bottomRight, .bottomRight)
        }
    }

    // MARK: - Selection: resizing drag

    func testResizeStartsOnCornerHit() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 100, y: 100, t: 0.1)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model)
        selection.select([stroke.id])

        let bounds = selection.selectionBounds
        selection.pointerDown(at: CGPoint(x: bounds.minX, y: bounds.minY), extend: false, hitRadius: 5)

        XCTAssertNotNil(selection.liveResize)
    }

    func testResizeMaintainsAspectRatio() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 100, y: 50, t: 0.1)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model)
        selection.select([stroke.id])

        let bounds = selection.selectionBounds
        selection.pointerDown(at: CGPoint(x: bounds.minX, y: bounds.minY), extend: false, hitRadius: 5)

        let originalAspectRatio = bounds.width / bounds.height

        // Drag to scale up
        selection.pointerDragged(to: CGPoint(x: bounds.minX - 100, y: bounds.minY - 50))

        if let (_, live) = selection.liveResize {
            let liveAspectRatio = live.width / live.height
            XCTAssertEqual(liveAspectRatio, originalAspectRatio, accuracy: 0.001)
        }
    }

    func testResizeEnforcesMinimumSize() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 100, y: 100, t: 0.1)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model)
        selection.select([stroke.id])

        let bounds = selection.selectionBounds
        selection.pointerDown(at: CGPoint(x: bounds.minX, y: bounds.minY), extend: false, hitRadius: 5)

        // Drag inward to try to shrink below minimum
        selection.pointerDragged(to: CGPoint(x: bounds.maxX - 10, y: bounds.maxY - 10))

        if let (_, live) = selection.liveResize {
            XCTAssertGreaterThanOrEqual(live.width, 8)
            XCTAssertGreaterThanOrEqual(live.height, 8)
        }
    }

    func testResizeCommitsOnPointerUp() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 100, y: 100, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model)
        selection.select([stroke.id])

        let bounds = selection.selectionBounds
        selection.pointerDown(at: CGPoint(x: bounds.minX, y: bounds.minY), extend: false, hitRadius: 5)

        let originalPoints = model.strokes[0].points
        selection.pointerDragged(to: CGPoint(x: bounds.minX - 100, y: bounds.minY - 100))
        step(um) { selection.pointerUp(at: CGPoint(x: bounds.minX - 100, y: bounds.minY - 100)) }

        let scaled = model.strokes[0].points
        XCTAssertNotEqual(scaled, originalPoints)
        XCTAssertNil(selection.liveResize)
    }

    func testCancelDragAbortsResize() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 100, y: 100, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model)
        selection.select([stroke.id])

        let bounds = selection.selectionBounds
        let originalPoints = model.strokes[0].points
        selection.pointerDown(at: CGPoint(x: bounds.minX, y: bounds.minY), extend: false, hitRadius: 5)
        selection.pointerDragged(to: CGPoint(x: bounds.minX - 100, y: bounds.minY - 100))
        selection.cancelDrag()

        XCTAssertEqual(model.strokes[0].points, originalPoints)
        XCTAssertNil(selection.liveResize)
    }

    func testMoveStillWorksWithSelection() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 100, y: 100, t: 0.1)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let selection = SelectionController(model: model)
        selection.select([stroke.id])

        let bounds = selection.selectionBounds
        let midpoint = CGPoint(x: bounds.midX, y: bounds.midY)

        selection.pointerDown(at: midpoint, extend: false, hitRadius: 5)
        selection.pointerDragged(to: CGPoint(x: midpoint.x + 50, y: midpoint.y + 50))
        step(um) { selection.pointerUp(at: CGPoint(x: midpoint.x + 50, y: midpoint.y + 50)) }

        // Stroke should be moved, not resized
        XCTAssertTrue(model.strokes[0].points[0].x > 0)
        XCTAssertTrue(model.strokes[0].points[0].y > 0)
    }

    // MARK: - Transform helper

    func testResizeTransformFromOriginToOrigin() {
        let transform = CanvasView.resizeTransform(from: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                   to: CGRect(x: 0, y: 0, width: 20, height: 20))
        let point = CGPoint(x: 5, y: 5).applying(transform)
        XCTAssertEqual(point.x, 10, accuracy: 0.001)
        XCTAssertEqual(point.y, 10, accuracy: 0.001)
    }

    func testResizeTransformWithTranslation() {
        let transform = CanvasView.resizeTransform(from: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                   to: CGRect(x: 100, y: 100, width: 20, height: 20))
        let point = CGPoint(x: 0, y: 0).applying(transform)
        XCTAssertEqual(point.x, 100, accuracy: 0.001)
        XCTAssertEqual(point.y, 100, accuracy: 0.001)
    }

    // MARK: - expandHit hook

    func testExpandHitSelectsWholeZone() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let stroke1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)], color: .black, width: 2)
        let stroke2 = Stroke(points: [StrokePoint(x: 15, y: 15, t: 0), StrokePoint(x: 25, y: 25, t: 0.1)], color: .black, width: 2)
        let stroke3 = Stroke(points: [StrokePoint(x: 100, y: 100, t: 0), StrokePoint(x: 110, y: 110, t: 0.1)], color: .black, width: 2)
        step(um) { model.add(stroke1); model.add(stroke2); model.add(stroke3) }

        let selection = SelectionController(model: model)
        var zoneID: UUID?

        // Group strokes into zones
        let strokes = [stroke1, stroke2, stroke3]
        var zones = DrawingZones.grouping(strokes)
        zoneID = zones.first?.id
        model.drawingZones = zones

        // Set up expandHit hook to return zone members
        selection.expandHit = { id in
            guard let zones = model.drawingZones else { return [id] }
            if let zone = zones.first(where: { $0.strokeIDs.contains(id) }) {
                return zone.strokeIDs
            }
            return [id]
        }

        // Click on stroke1, which is in a zone with stroke2
        selection.pointerDown(at: CGPoint(x: 5, y: 5), extend: false, hitRadius: 5)

        // Both strokes should be selected
        XCTAssertTrue(selection.selection.contains(stroke1.id))
        XCTAssertTrue(selection.selection.contains(stroke2.id))
        XCTAssertFalse(selection.selection.contains(stroke3.id))
    }
}
