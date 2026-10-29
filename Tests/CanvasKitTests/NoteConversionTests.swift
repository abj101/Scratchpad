import XCTest
@testable import CanvasKit

final class NoteConversionTests: XCTestCase {
    func testDocumentToCanvasKeepsBodyAndStrokeGeometry() {
        let body = block("Heading\nBody", at: CGPoint(x: 28, y: 72), width: 500)
        let stroke = line(id: UUID(), x: 120, y: 240)
        let zone = DrawingZone(strokeIDs: [stroke.id], rect: stroke.bounds)
        let model = CanvasModel(strokes: [stroke], textBlocks: [body], layout: .document, drawingZones: [zone])

        let snapshot = NoteConversion.canvasSnapshot(from: model, bodyID: body.id)

        XCTAssertEqual(snapshot.layout, .canvas)
        XCTAssertEqual(snapshot.textBlocks, [body])
        XCTAssertEqual(snapshot.strokes, [stroke])
        XCTAssertNil(snapshot.drawingZones)
    }

    func testCanvasToDocumentJoinsRowsInReadingOrderAndMapsInk() {
        let right = block("right", at: CGPoint(x: 180, y: 100), width: 100)
        let left = block("left", at: CGPoint(x: 30, y: 108), width: 100)
        let next = block("next", at: CGPoint(x: 30, y: 140), width: 100)
        let ink = line(id: UUID(), x: 190, y: 104)
        let model = CanvasModel(strokes: [ink], textBlocks: [right, next, left], layout: .canvas)

        let snapshot = NoteConversion.documentSnapshot(from: model, viewportWidth: 560)

        XCTAssertEqual(snapshot.layout, .document)
        XCTAssertEqual(snapshot.textBlocks.count, 1)
        let body = try! XCTUnwrap(snapshot.textBlocks.first)
        XCTAssertEqual(body.attributedString.string, "left\n\nright\n\nnext")
        XCTAssertEqual(body.origin, CGPoint(x: 28, y: DocumentLayout.topInset))
        XCTAssertEqual(body.width, 504)
        XCTAssertEqual(snapshot.strokes, [ink])
        XCTAssertNil(snapshot.drawingZones) // the document groups the ink into zones when it opens
    }

    func testEquationsSurviveCanvasDocumentCanvasConversion() throws {
        let first = EquationAttachment(latex: #"\frac{x_1}{y}"#, fontSize: 16)
        let second = EquationAttachment(latex: #"\beta^{3}"#, fontSize: 16)
        let upper = equationBlock("x = ", first, at: CGPoint(x: 30, y: 40))
        let lower = equationBlock("and ", second, at: CGPoint(x: 30, y: 100))
        let canvas = CanvasModel(textBlocks: [lower, upper], layout: .canvas)

        let documentSnapshot = NoteConversion.documentSnapshot(from: canvas, viewportWidth: 600)
        let documentBody = try XCTUnwrap(documentSnapshot.textBlocks.first).attributedString
        let documentModel = CanvasModel(textBlocks: documentSnapshot.textBlocks, layout: .document)
        let canvasSnapshot = NoteConversion.canvasSnapshot(from: documentModel, bodyID: documentSnapshot.textBlocks[0].id)
        let restored = try XCTUnwrap(canvasSnapshot.textBlocks.first).attributedString

        func equations(in text: NSAttributedString) -> [(UUID, String)] {
            var result: [(UUID, String)] = []
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let equation = value as? EquationAttachment { result.append((equation.id, equation.latex)) }
            }
            return result
        }
        XCTAssertEqual(equations(in: documentBody).map { $0.0 }, [first.id, second.id])
        XCTAssertEqual(equations(in: restored).map { $0.0 }, [first.id, second.id])
        XCTAssertEqual(equations(in: restored).map { $0.1 }, [first.latex, second.latex])
    }

    func testWholeModelReplacementNotifiesAfterApplyingSnapshotAndUndoRestoresIt() {
        let originalStroke = line(id: UUID(), x: 10, y: 20)
        let originalBlock = block("old", at: .zero, width: 120)
        let undo = UndoManager()
        let model = CanvasModel(strokes: [originalStroke], textBlocks: [originalBlock], layout: .canvas,
                                undoManager: undo)
        let convertedStroke = line(id: UUID(), x: 30, y: 40)
        let convertedBlock = block("new", at: CGPoint(x: 28, y: 72), width: 300)
        let convertedZone = DrawingZone(strokeIDs: [convertedStroke.id], rect: convertedStroke.bounds)
        let target = NoteModelSnapshot(strokes: [convertedStroke], textBlocks: [convertedBlock],
                                       layout: .document, drawingZones: [convertedZone])
        var notified = false
        model.onTextBlocksChange = { _ in
            notified = true
            if model.layout == .document {
                XCTAssertEqual(model.strokes, [convertedStroke])
                XCTAssertEqual(model.textBlocks, [convertedBlock])
                XCTAssertEqual(model.drawingZones, [convertedZone])
            } else {
                XCTAssertEqual(model.strokes, [originalStroke])
                XCTAssertEqual(model.textBlocks, [originalBlock])
                XCTAssertNil(model.drawingZones)
            }
        }

        model.replaceContents(with: target, actionName: "Convert to Document")
        XCTAssertTrue(notified)
        undo.undo()

        XCTAssertEqual(model.layout, .canvas)
        XCTAssertEqual(model.strokes, [originalStroke])
        XCTAssertEqual(model.textBlocks, [originalBlock])
        XCTAssertNil(model.drawingZones)
    }

    private func block(_ text: String, at origin: CGPoint, width: Double) -> TextBlock {
        TextBlock(origin: origin, width: width, content: TextBlock.content(from: NSAttributedString(string: text)))
    }

    private func equationBlock(_ prefix: String, _ equation: EquationAttachment, at origin: CGPoint) -> TextBlock {
        let content = NSMutableAttributedString(string: prefix)
        content.append(NSAttributedString(attachment: equation))
        return TextBlock(origin: origin, width: 180, content: TextBlock.content(from: content))
    }

    private func line(id: UUID, x: Double, y: Double) -> Stroke {
        Stroke(id: id, points: [StrokePoint(x: x, y: y, t: 0), StrokePoint(x: x + 12, y: y, t: 0.1)],
               color: .black, width: 2)
    }
}
