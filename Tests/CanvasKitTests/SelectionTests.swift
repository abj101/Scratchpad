import XCTest
@testable import CanvasKit

final class SelectionTests: XCTestCase {

    func step(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    // MARK: - Model: allIDs and contains

    func testAllIDsEmpty() {
        let model = CanvasModel()
        XCTAssertEqual(model.allIDs, [])
    }

    func testAllIDsWithStrokes() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        XCTAssertEqual(model.allIDs, [s1.id, s2.id])
    }

    func testAllIDsWithTextBlocks() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let t1 = TextBlock(origin: .zero)
        let t2 = TextBlock(origin: CGPoint(x: 100, y: 100))
        step(um) { model.addTextBlock(t1); model.addTextBlock(t2) }

        XCTAssertEqual(model.allIDs, [t1.id, t2.id])
    }

    func testAllIDsWithMixed() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let t1 = TextBlock(origin: .zero)
        step(um) { model.add(s1); model.addTextBlock(t1) }

        XCTAssertEqual(model.allIDs, [s1.id, t1.id])
    }

    func testDocumentSelectionOnlyExposesInk() {
        let model = CanvasModel()
        let stroke = Stroke(points: [StrokePoint(x: 150, y: 150, t: 0)], color: .black, width: 2)
        let body = TextBlock(origin: .zero, width: 100, height: 100)
        model.add(stroke)
        model.addTextBlock(body)
        let selection = SelectionController(model: model, includesTextBlocks: false)

        selection.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 1)
        selection.pointerDragged(to: CGPoint(x: 100, y: 100))
        XCTAssertTrue(selection.selection.isEmpty)
        selection.cancelDrag()

        selection.selectAll()
        XCTAssertEqual(selection.selection, [stroke.id])
        selection.deleteSelection()
        XCTAssertTrue(model.strokes.isEmpty)
        XCTAssertEqual(model.textBlocks.map(\.id), [body.id])
    }

    func testContains() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let t1 = TextBlock(origin: .zero)
        let unknownID = UUID()

        step(um) { model.add(s1); model.addTextBlock(t1) }

        XCTAssertTrue(model.contains(id: s1.id))
        XCTAssertTrue(model.contains(id: t1.id))
        XCTAssertFalse(model.contains(id: unknownID))
    }

    // MARK: - Model: hitObject

    func testHitObjectMissReturnsNil() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        XCTAssertNil(model.hitObject(at: CGPoint(x: 100, y: 100), radius: 1))
    }

    func testHitObjectStroke() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let hitID = model.hitObject(at: CGPoint(x: 5, y: 5), radius: 2)
        XCTAssertEqual(hitID, stroke.id)
    }

    func testHitObjectTextBlockPriority() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 1
        )
        let textBlock = TextBlock(origin: CGPoint(x: 40, y: 40), width: 30, height: 30)
        step(um) { model.add(stroke); model.addTextBlock(textBlock) }

        let hitID = model.hitObject(at: CGPoint(x: 55, y: 55), radius: 1)
        XCTAssertEqual(hitID, textBlock.id)
    }

    func testHitObjectTopmostTextBlock() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let t1 = TextBlock(origin: CGPoint(x: 0, y: 0), width: 100, height: 100)
        let t2 = TextBlock(origin: CGPoint(x: 10, y: 10), width: 100, height: 100)
        step(um) { model.addTextBlock(t1); model.addTextBlock(t2) }

        let hitID = model.hitObject(at: CGPoint(x: 50, y: 50), radius: 1)
        XCTAssertEqual(hitID, t2.id)
    }

    // MARK: - Model: objects(in:)

    func testObjectsInRectEmpty() {
        let model = CanvasModel()
        let result = model.objects(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(result, [])
    }

    func testObjectsInRectStrokeWithPointInside() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let result = model.objects(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(result, [stroke.id])
    }

    func testObjectsInRectStrokeSegmentCrossing() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [
                StrokePoint(x: -50, y: -50, t: 0),
                StrokePoint(x: 50, y: 50, t: 0.1)
            ],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let result = model.objects(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(result, [stroke.id])
    }

    func testObjectsInRectTextBlockIntersecting() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let textBlock = TextBlock(origin: CGPoint(x: 50, y: 50), width: 100, height: 100)
        step(um) { model.addTextBlock(textBlock) }

        let result = model.objects(in: CGRect(x: 100, y: 100, width: 50, height: 50))
        XCTAssertEqual(result, [textBlock.id])
    }

    func testObjectsInRectMultiple() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 25, y: 25, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 75, y: 75, t: 0)], color: .black, width: 1)
        let t1 = TextBlock(origin: CGPoint(x: 0, y: 0), width: 50, height: 50)
        step(um) { model.add(s1); model.add(s2); model.addTextBlock(t1) }

        let result = model.objects(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(result, [s1.id, s2.id, t1.id])
    }

    // MARK: - Model: bounds(of:)

    func testBoundsOfEmpty() {
        let model = CanvasModel()
        let bounds = model.bounds(of: [])
        XCTAssertTrue(bounds.isNull)
    }

    func testBoundsOfUnknownIDs() {
        let model = CanvasModel()
        let bounds = model.bounds(of: [UUID(), UUID()])
        XCTAssertTrue(bounds.isNull)
    }

    func testBoundsOfStroke() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let bounds = model.bounds(of: [stroke.id])
        XCTAssertFalse(bounds.isNull)
        XCTAssertTrue(bounds.width > 10)
        XCTAssertTrue(bounds.height > 10)
    }

    func testBoundsOfTextBlock() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let textBlock = TextBlock(origin: CGPoint(x: 50, y: 60), width: 100, height: 40)
        step(um) { model.addTextBlock(textBlock) }

        let bounds = model.bounds(of: [textBlock.id])
        XCTAssertEqual(bounds, textBlock.bounds)
    }

    func testBoundsOfMixed() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 2
        )
        let textBlock = TextBlock(origin: CGPoint(x: 50, y: 60), width: 100, height: 40)
        step(um) { model.add(stroke); model.addTextBlock(textBlock) }

        let bounds = model.bounds(of: [stroke.id, textBlock.id])
        XCTAssertFalse(bounds.isNull)
        XCTAssertTrue(bounds.contains(textBlock.bounds))
    }

    // MARK: - Model: translate

    func testTranslateStroke() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }
        step(um) { model.translate(ids: [stroke.id], by: CGVector(dx: 5, dy: 10)) }

        XCTAssertEqual(model.strokes[0].points[0].x, 5)
        XCTAssertEqual(model.strokes[0].points[0].y, 10)
        XCTAssertEqual(model.strokes[0].points[1].x, 15)
        XCTAssertEqual(model.strokes[0].points[1].y, 20)
    }

    func testTranslateTextBlock() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let textBlock = TextBlock(origin: CGPoint(x: 50, y: 60))
        step(um) { model.addTextBlock(textBlock) }
        step(um) { model.translate(ids: [textBlock.id], by: CGVector(dx: 10, dy: 20)) }

        XCTAssertEqual(model.textBlocks[0].origin.x, 60)
        XCTAssertEqual(model.textBlocks[0].origin.y, 80)
    }

    func testTranslateUndo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }
        step(um) { model.translate(ids: [stroke.id], by: CGVector(dx: 5, dy: 5)) }

        um.undo()
        XCTAssertEqual(model.strokes[0].points[0].x, 0)
        XCTAssertEqual(model.strokes[0].points[0].y, 0)
    }

    func testTranslateRedo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }
        step(um) { model.translate(ids: [stroke.id], by: CGVector(dx: 5, dy: 5)) }

        um.undo()
        um.redo()

        XCTAssertEqual(model.strokes[0].points[0].x, 5)
        XCTAssertEqual(model.strokes[0].points[0].y, 5)
    }

    func testTranslateZeroDeltaNoUndo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }

        let couldUndoBefore = um.canUndo
        model.translate(ids: [stroke.id], by: .zero)
        XCTAssertEqual(um.canUndo, couldUndoBefore, "Zero delta should not add undo step")
    }

    // MARK: - Model: delete

    func testDeleteStroke() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .black,
            width: 1
        )
        step(um) { model.add(stroke) }
        step(um) { model.delete(ids: [stroke.id]) }

        XCTAssertEqual(model.strokes.count, 0)
    }

    func testDeleteTextBlock() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let textBlock = TextBlock(origin: .zero)
        step(um) { model.addTextBlock(textBlock) }
        step(um) { model.delete(ids: [textBlock.id]) }

        XCTAssertEqual(model.textBlocks.count, 0)
    }

    func testDeleteMixed() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 0, y: 0, t: 0)],
            color: .black,
            width: 1
        )
        let textBlock = TextBlock(origin: .zero)
        step(um) { model.add(stroke); model.addTextBlock(textBlock) }
        step(um) { model.delete(ids: [stroke.id, textBlock.id]) }

        XCTAssertEqual(model.strokes.count, 0)
        XCTAssertEqual(model.textBlocks.count, 0)
    }

    func testDeleteUndoRestoresOriginalIndices() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        let s3 = Stroke(points: [StrokePoint(x: 20, y: 20, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2); model.add(s3) }
        step(um) { model.delete(ids: [s2.id]) }

        XCTAssertEqual(model.strokes.count, 2)
        XCTAssertEqual(model.strokes[0].id, s1.id)
        XCTAssertEqual(model.strokes[1].id, s3.id)

        um.undo()
        XCTAssertEqual(model.strokes.count, 3)
        XCTAssertEqual(model.strokes[0].id, s1.id)
        XCTAssertEqual(model.strokes[1].id, s2.id)
        XCTAssertEqual(model.strokes[2].id, s3.id)
    }

    // MARK: - Model: bringToFront

    func testBringToFrontStroke() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }
        step(um) { model.bringToFront(ids: [s1.id]) }

        XCTAssertEqual(model.strokes[0].id, s2.id)
        XCTAssertEqual(model.strokes[1].id, s1.id)
    }

    func testBringToFrontAlreadyFrontNoUndo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        let couldUndoBefore = um.canUndo
        model.bringToFront(ids: [s2.id])
        XCTAssertEqual(um.canUndo, couldUndoBefore, "Already-front should not add undo step")
    }

    func testBringToFrontPreservesRelativeOrder() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        let s3 = Stroke(points: [StrokePoint(x: 20, y: 20, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2); model.add(s3) }
        step(um) { model.bringToFront(ids: [s1.id, s2.id]) }

        XCTAssertEqual(model.strokes[0].id, s3.id)
        XCTAssertEqual(model.strokes[1].id, s1.id)
        XCTAssertEqual(model.strokes[2].id, s2.id)
    }

    // MARK: - Model: sendToBack

    func testSendToBackStroke() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }
        step(um) { model.sendToBack(ids: [s2.id]) }

        XCTAssertEqual(model.strokes[0].id, s2.id)
        XCTAssertEqual(model.strokes[1].id, s1.id)
    }

    func testSendToBackAlreadyBackNoUndo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        let couldUndoBefore = um.canUndo
        model.sendToBack(ids: [s1.id])
        XCTAssertEqual(um.canUndo, couldUndoBefore, "Already-back should not add undo step")
    }

    func testSendToBackTextBlocks() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let t1 = TextBlock(origin: .zero)
        let t2 = TextBlock(origin: CGPoint(x: 100, y: 100))
        step(um) { model.addTextBlock(t1); model.addTextBlock(t2) }
        step(um) { model.sendToBack(ids: [t2.id]) }

        XCTAssertEqual(model.textBlocks[0].id, t2.id)
        XCTAssertEqual(model.textBlocks[1].id, t1.id)
    }

    // MARK: - SelectionController: pointer selection

    func testClickSelectsObject() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)

        XCTAssertEqual(controller.selection, [stroke.id])
    }

    func testClickEmptyClearsSelection() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)
        XCTAssertEqual(controller.selection, [stroke.id])

        controller.pointerDown(at: CGPoint(x: 200, y: 200), extend: false, hitRadius: 5)
        XCTAssertEqual(controller.selection, [])
    }

    func testShiftClickToggles() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 50, y: 50, t: 0)], color: .black, width: 2)
        let s2 = Stroke(points: [StrokePoint(x: 100, y: 100, t: 0)], color: .black, width: 2)
        step(um) { model.add(s1); model.add(s2) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)
        XCTAssertEqual(controller.selection, [s1.id])

        controller.pointerDown(at: CGPoint(x: 100, y: 100), extend: true, hitRadius: 5)
        XCTAssertEqual(controller.selection, [s1.id, s2.id])

        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: true, hitRadius: 5)
        XCTAssertEqual(controller.selection, [s2.id])
    }

    // MARK: - SelectionController: dragging and moving

    func testDragStartsMove() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)

        if case .moving = controller.drag {
            // Success
        } else {
            XCTFail("Expected moving drag state")
        }
    }

    func testMoveOffsetLive() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)
        controller.pointerDragged(to: CGPoint(x: 100, y: 150))

        XCTAssertEqual(controller.moveOffset.dx, 50)
        XCTAssertEqual(controller.moveOffset.dy, 100)
    }

    func testPointerUpCommitsTranslate() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)
        controller.pointerDragged(to: CGPoint(x: 100, y: 100))
        step(um) { controller.pointerUp(at: CGPoint(x: 100, y: 100)) }

        XCTAssertEqual(model.strokes[0].points[0].x, 100)
        XCTAssertEqual(model.strokes[0].points[0].y, 100)
        XCTAssertTrue(um.canUndo)
    }

    func testPointerUpZeroDeltaNoUndo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let stroke = Stroke(
            points: [StrokePoint(x: 50, y: 50, t: 0)],
            color: .black,
            width: 2
        )
        step(um) { model.add(stroke) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)

        let couldUndoBefore = um.canUndo
        controller.pointerUp(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(um.canUndo, couldUndoBefore, "Zero delta move should not add undo step")
    }

    // MARK: - SelectionController: marquee selection

    func testMarqueeSelectsObjects() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 25, y: 25, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 75, y: 75, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 0, y: 0), extend: false, hitRadius: 0)
        controller.pointerDragged(to: CGPoint(x: 50, y: 50))

        XCTAssertEqual(controller.selection, [s1.id])
    }

    func testMarqueeShiftExtends() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 25, y: 25, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 75, y: 75, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 0, y: 0), extend: false, hitRadius: 0)
        controller.pointerDragged(to: CGPoint(x: 50, y: 50))

        XCTAssertEqual(controller.selection, [s1.id])
        controller.pointerUp(at: CGPoint(x: 50, y: 50))

        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: true, hitRadius: 0)
        controller.pointerDragged(to: CGPoint(x: 100, y: 100))

        XCTAssertTrue(controller.selection.contains(s1.id))
        XCTAssertTrue(controller.selection.contains(s2.id))
    }

    func testMarqueeRectLive() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 0, y: 0), extend: false, hitRadius: 0)
        controller.pointerDragged(to: CGPoint(x: 100, y: 100))

        guard let marqueeRect = controller.marqueeRect else {
            XCTFail("Expected marquee rect")
            return
        }
        XCTAssertEqual(marqueeRect.minX, 0)
        XCTAssertEqual(marqueeRect.minY, 0)
        XCTAssertEqual(marqueeRect.maxX, 100)
        XCTAssertEqual(marqueeRect.maxY, 100)
    }

    func testCancelDragRestoresMarqueeBase() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 50, y: 50, t: 0)], color: .black, width: 2)
        step(um) { model.add(s1) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)
        XCTAssertEqual(controller.selection, [s1.id])

        controller.pointerDown(at: CGPoint(x: 0, y: 0), extend: true, hitRadius: 0)
        controller.pointerDragged(to: CGPoint(x: 100, y: 100))

        controller.cancelDrag()
        XCTAssertEqual(controller.selection, [s1.id])
        XCTAssertNil(controller.marqueeRect)
    }

    // MARK: - SelectionController: selection commands

    func testSelectAll() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let t1 = TextBlock(origin: .zero)
        step(um) { model.add(s1); model.addTextBlock(t1) }

        let controller = SelectionController(model: model)
        controller.selectAll()

        XCTAssertEqual(controller.selection, [s1.id, t1.id])
    }

    func testSelectFiltersUnknownIDs() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1) }

        let controller = SelectionController(model: model)
        let unknownID = UUID()
        controller.select([s1.id, unknownID])

        XCTAssertEqual(controller.selection, [s1.id])
    }

    func testClear() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 0, y: 0), extend: false, hitRadius: 5)
        XCTAssertEqual(controller.selection, [s1.id])

        controller.clear()
        XCTAssertEqual(controller.selection, [])
    }

    // MARK: - SelectionController: delete selection

    func testDeleteSelection() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 0, y: 0), extend: false, hitRadius: 5)
        step(um) { controller.deleteSelection() }

        XCTAssertEqual(model.strokes.count, 0)
        XCTAssertEqual(controller.selection, [])
        XCTAssertTrue(um.canUndo)
    }

    func testDeleteSelectionEmpty() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let controller = SelectionController(model: model)
        controller.deleteSelection()

        XCTAssertFalse(um.canUndo)
    }

    // MARK: - SelectionController: nudge

    func testNudgeKeepsSelection() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 50, y: 50, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1) }

        let controller = SelectionController(model: model)
        controller.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 5)
        step(um) { controller.nudge(by: CGVector(dx: 10, dy: 10)) }

        XCTAssertEqual(model.strokes[0].points[0].x, 60)
        XCTAssertEqual(model.strokes[0].points[0].y, 60)
        XCTAssertEqual(controller.selection, [s1.id])
    }

    // MARK: - SelectionController: arrange

    func testBringToFrontViaController() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        let controller = SelectionController(model: model)
        controller.select([s1.id])
        step(um) { controller.bringToFront() }

        XCTAssertEqual(model.strokes[0].id, s2.id)
        XCTAssertEqual(model.strokes[1].id, s1.id)
    }

    func testSendToBackViaController() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        let controller = SelectionController(model: model)
        controller.select([s2.id])
        step(um) { controller.sendToBack() }

        XCTAssertEqual(model.strokes[0].id, s2.id)
        XCTAssertEqual(model.strokes[1].id, s1.id)
    }

    // MARK: - SelectionController: pruneMissing

    func testPruneMissingAfterUndo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2) }

        let controller = SelectionController(model: model)
        controller.select([s1.id, s2.id])
        XCTAssertEqual(controller.selection.count, 2)

        step(um) { model.delete(ids: [s2.id]) }
        um.undo()

        step(um) { controller.pruneMissing() }
        XCTAssertEqual(controller.selection, [s1.id, s2.id])
    }

    func testPruneMissingFiresOnChange() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1) }

        let controller = SelectionController(model: model)
        var changedRects: [CGRect] = []
        controller.onChange = { changedRects.append($0) }

        controller.select([UUID()])
        XCTAssertEqual(controller.selection.count, 0)

        let changeCountBefore = changedRects.count
        step(um) { controller.pruneMissing() }
        XCTAssertEqual(changedRects.count, changeCountBefore)
    }

    // MARK: - SelectionController: onChange

    func testOnChangeFiresOnSelectionChange() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 2)
        step(um) { model.add(s1) }

        let controller = SelectionController(model: model)
        var callCount = 0
        controller.onChange = { _ in callCount += 1 }

        controller.pointerDown(at: CGPoint(x: 0, y: 0), extend: false, hitRadius: 5)
        XCTAssertGreaterThan(callCount, 0)
    }
    // MARK: - Drag inside selection bounds

    func testDragInsideSelectionBoundsMovesWithoutHittingInk() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let a = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 0, t: 0.1)], color: .black, width: 1)
        let b = Stroke(points: [StrokePoint(x: 100, y: 100, t: 0), StrokePoint(x: 110, y: 100, t: 0.1)], color: .black, width: 1)
        step(um) { model.add(a); model.add(b) }
        let sel = SelectionController(model: model)
        sel.select([a.id, b.id])

        // (50, 50) is between the strokes but inside the combined bounds.
        sel.pointerDown(at: CGPoint(x: 50, y: 50), extend: false, hitRadius: 2)
        XCTAssertEqual(sel.selection, [a.id, b.id])
        sel.pointerDragged(to: CGPoint(x: 70, y: 60))
        XCTAssertEqual(sel.moveOffset, CGVector(dx: 20, dy: 10))
        step(um) { sel.pointerUp(at: CGPoint(x: 70, y: 60)) }
        XCTAssertEqual(model.strokes[0].points[0].x, 20)
        XCTAssertEqual(model.strokes[1].points[0].y, 110)
    }

    func testPressOutsideSelectionBoundsStillClears() {
        let model = CanvasModel()
        let a = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 0, t: 0.1)], color: .black, width: 1)
        model.add(a)
        let sel = SelectionController(model: model)
        sel.select([a.id])
        sel.pointerDown(at: CGPoint(x: 500, y: 500), extend: false, hitRadius: 2)
        XCTAssertEqual(sel.selection, [])
        XCTAssertNotNil(sel.marqueeRect)
    }

    // MARK: - Invalidation

    /// Removing a selected object must still repaint where its outline was drawn.
    func testPruneMissingInvalidatesRemovedObjects() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let a = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 0, t: 0)], color: .black, width: 1)
        let b = Stroke(points: [StrokePoint(x: 200, y: 0, t: 0), StrokePoint(x: 210, y: 0, t: 0)], color: .black, width: 1)
        step(um) { model.add(a); model.add(b) }
        let selection = SelectionController(model: model)
        selection.select([a.id, b.id])
        var dirty = CGRect.null
        selection.onChange = { dirty = dirty.union($0) }
        step(um) { model.remove(ids: [b.id]) }
        selection.pruneMissing()
        XCTAssertTrue(dirty.contains(b.bounds), "stale outline around the removed stroke must be invalidated")
    }
}
