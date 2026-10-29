import XCTest
@testable import CanvasKit

final class ClipboardTests: XCTestCase {

    func step(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    // MARK: - ClipboardPayload init(model:ids:)

    func testInitPicksSelectedObjects() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        let t1 = TextBlock(origin: .zero)
        step(um) { model.add(s1); model.add(s2); model.addTextBlock(t1) }

        let payload = ClipboardPayload(model: model, ids: [s1.id, t1.id])

        XCTAssertEqual(payload.strokes.count, 1)
        XCTAssertEqual(payload.strokes[0].id, s1.id)
        XCTAssertEqual(payload.textBlocks.count, 1)
        XCTAssertEqual(payload.textBlocks[0].id, t1.id)
    }

    func testInitPreservesModelOrder() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        let s3 = Stroke(points: [StrokePoint(x: 20, y: 20, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1); model.add(s2); model.add(s3) }

        let payload = ClipboardPayload(model: model, ids: [s3.id, s1.id])

        XCTAssertEqual(payload.strokes[0].id, s1.id)
        XCTAssertEqual(payload.strokes[1].id, s3.id)
    }

    func testInitIgnoresUnknownIDs() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1) }

        let unknownID = UUID()
        let payload = ClipboardPayload(model: model, ids: [s1.id, unknownID])

        XCTAssertEqual(payload.strokes.count, 1)
        XCTAssertEqual(payload.strokes[0].id, s1.id)
    }

    // MARK: - ClipboardPayload bounds

    func testBoundsEmpty() {
        let payload = ClipboardPayload()
        XCTAssertTrue(payload.bounds.isNull)
    }

    func testBoundsUnion() {
        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 0.1)], color: .black, width: 1)
        let t = TextBlock(origin: CGPoint(x: 50, y: 50), width: 100, height: 100)
        let payload = ClipboardPayload(strokes: [s], textBlocks: [t])

        let bounds = payload.bounds
        XCTAssertFalse(bounds.isNull)
        XCTAssertTrue(bounds.contains(t.bounds))
    }

    // MARK: - ClipboardPayload reidentified

    func testReidentifiedNewIDs() {
        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let t = TextBlock(origin: CGPoint(x: 10, y: 20))
        let payload = ClipboardPayload(strokes: [s], textBlocks: [t])

        let reidentified = payload.reidentified(offsetBy: .zero)

        XCTAssertNotEqual(reidentified.strokes[0].id, s.id)
        XCTAssertNotEqual(reidentified.textBlocks[0].id, t.id)
    }

    func testMultipleEquationClipboardCopiesKeepLatexAndGetFreshIDs() throws {
        let equations = [EquationAttachment(latex: #"x^{2}"#, fontSize: 18),
                         EquationAttachment(latex: #"\frac{a}{b}"#, fontSize: 16)]
        let content = NSMutableAttributedString(string: "left ")
        content.append(NSAttributedString(attachment: equations[0]))
        content.append(NSAttributedString(string: " plus "))
        content.append(NSAttributedString(attachment: equations[1]))
        content.append(NSAttributedString(string: " right"))
        let block = TextBlock(origin: .zero, content: TextBlock.content(from: content))
        let copy = ClipboardPayload(textBlocks: [block]).reidentified(offsetBy: .zero).textBlocks[0]
        var copied: [EquationAttachment] = []
        copy.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.attributedString.length)) {
            value, _, _ in
            if let equation = value as? EquationAttachment { copied.append(equation) }
        }

        XCTAssertEqual(copied.map(\.latex), equations.map(\.latex))
        XCTAssertTrue(zip(copied, equations).allSatisfy { $0.0.id != $0.1.id })
        XCTAssertEqual(copy.plainText, "left x^{2} plus \\frac{a}{b} right")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("equation-copy-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        ClipboardPayload(textBlocks: [block]).write(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "left x^{2} plus \\frac{a}{b} right")
        let restored = try XCTUnwrap(ClipboardPayload.read(from: pasteboard)?.textBlocks.first)
        var restoredEquations: [EquationAttachment] = []
        restored.attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: restored.attributedString.length)) {
            value, _, _ in
            if let equation = value as? EquationAttachment { restoredEquations.append(equation) }
        }
        XCTAssertEqual(restoredEquations.map(\.id), equations.map(\.id))
        XCTAssertEqual(restoredEquations.map(\.latex), equations.map(\.latex))
    }

    func testNativeTextCopyAndPastePreserveEquationAttachmentsAndPlainText() {
        _ = NSApplication.shared
        let equation = EquationAttachment(latex: #"\frac{x}{y}"#, fontSize: 18)
        let source = NSMutableAttributedString(string: "value ")
        source.append(NSAttributedString(attachment: equation))
        let copyView = TextBlockView(blockID: UUID(), width: 320)
        copyView.setContents(source)
        copyView.beginEditing()
        copyView.textView.setSelectedRange(NSRange(location: 0, length: source.length))
        NSPasteboard.general.clearContents()
        copyView.textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), #"value \frac{x}{y}"#)

        let pasteView = TextBlockView(blockID: UUID(), width: 320)
        pasteView.setContents(NSAttributedString())
        pasteView.beginEditing()
        pasteView.textView.paste(nil)
        var pasted: EquationAttachment?
        pasteView.textStorage.enumerateAttribute(.attachment,
                                                  in: NSRange(location: 0, length: pasteView.textStorage.length)) {
            value, _, _ in pasted = value as? EquationAttachment
        }
        XCTAssertNotNil(pasted)
        XCTAssertEqual(pasted?.latex, equation.latex)
        XCTAssertNotEqual(pasted?.id, equation.id)
        NSPasteboard.general.clearContents()
    }

    func testReidentifiedDistinctIDs() {
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .black, width: 1)
        let payload = ClipboardPayload(strokes: [s1, s2])

        let reidentified = payload.reidentified(offsetBy: .zero)

        XCTAssertNotEqual(reidentified.strokes[0].id, reidentified.strokes[1].id)
    }

    func testReidentifiedStrokePointsOffset() {
        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 20, t: 0.1)], color: .black, width: 1)
        let payload = ClipboardPayload(strokes: [s])
        let delta = CGVector(dx: 5, dy: 10)

        let reidentified = payload.reidentified(offsetBy: delta)

        XCTAssertEqual(reidentified.strokes[0].points[0].x, 5)
        XCTAssertEqual(reidentified.strokes[0].points[0].y, 10)
        XCTAssertEqual(reidentified.strokes[0].points[1].x, 15)
        XCTAssertEqual(reidentified.strokes[0].points[1].y, 30)
    }

    func testReidentifiedTextBlockOriginOffset() {
        let t = TextBlock(origin: CGPoint(x: 50, y: 60))
        let payload = ClipboardPayload(textBlocks: [t])
        let delta = CGVector(dx: 10, dy: 20)

        let reidentified = payload.reidentified(offsetBy: delta)

        XCTAssertEqual(reidentified.textBlocks[0].origin.x, 60)
        XCTAssertEqual(reidentified.textBlocks[0].origin.y, 80)
    }

    func testReidentifiedPreservesColorAndWidth() {
        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .red, width: 5)
        let payload = ClipboardPayload(strokes: [s])

        let reidentified = payload.reidentified(offsetBy: CGVector(dx: 10, dy: 10))

        XCTAssertEqual(reidentified.strokes[0].color, .red)
        XCTAssertEqual(reidentified.strokes[0].width, 5)
    }

    func testReidentifiedPreservesTextContent() {
        let content = TextBlock.content(from: NSAttributedString(string: "Hello"))
        let t = TextBlock(origin: .zero, content: content)
        let payload = ClipboardPayload(textBlocks: [t])

        let reidentified = payload.reidentified(offsetBy: .zero)

        XCTAssertEqual(reidentified.textBlocks[0].content, content)
    }

    // MARK: - ClipboardPayload JSON round trip

    func testJSONRoundTrip() {
        let s = Stroke(points: [StrokePoint(x: 5, y: 10, t: 0.5)], color: .blue, width: 2.5)
        let t = TextBlock(origin: CGPoint(x: 100, y: 200), width: 150, height: 50)
        let payload = ClipboardPayload(strokes: [s], textBlocks: [t])

        let encoded = try! JSONEncoder().encode(payload)
        let decoded = try! JSONDecoder().decode(ClipboardPayload.self, from: encoded)

        XCTAssertEqual(decoded, payload)
    }

    // MARK: - ClipboardPayload pasteboard round trip

    func testWriteAndRead() {
        let s = Stroke(points: [StrokePoint(x: 5, y: 10, t: 0.5)], color: .blue, width: 2.5)
        let t = TextBlock(origin: CGPoint(x: 100, y: 200), width: 150, height: 50)
        let payload = ClipboardPayload(strokes: [s], textBlocks: [t])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        payload.write(to: pasteboard)
        let read = ClipboardPayload.read(from: pasteboard)

        XCTAssertEqual(read, payload)
    }

    func testReadNilWhenTypeAbsent() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.setString("plain text only", forType: .string)

        let read = ClipboardPayload.read(from: pasteboard)
        XCTAssertNil(read)
    }

    func testPlainTextWhenTextBlocks() {
        let content1 = TextBlock.content(from: NSAttributedString(string: "First"))
        let content2 = TextBlock.content(from: NSAttributedString(string: "Second"))
        let t1 = TextBlock(origin: .zero, content: content1)
        let t2 = TextBlock(origin: CGPoint(x: 100, y: 100), content: content2)
        let payload = ClipboardPayload(textBlocks: [t1, t2])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        payload.write(to: pasteboard)
        let plainText = pasteboard.string(forType: .string)

        XCTAssertEqual(plainText, "First\n\nSecond")
    }

    func testAttributedTextJoinsBlocksAndPreservesFormatting() {
        let red = NSAttributedString(string: "Red", attributes: [.foregroundColor: NSColor.red])
        let first = TextBlock(origin: .zero, content: TextBlock.content(from: red))
        let second = TextBlock(origin: .zero, content: TextBlock.content(from: NSAttributedString(string: "Plain")))

        let text = ClipboardPayload(textBlocks: [first, second]).attributedText

        XCTAssertEqual(text?.string, "Red\n\nPlain")
        XCTAssertTrue((text?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.red) == true)
    }

    func testNoPlainTextWhenOnlyStrokes() {
        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let payload = ClipboardPayload(strokes: [s])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        payload.write(to: pasteboard)
        let plainText = pasteboard.string(forType: .string)

        XCTAssertNil(plainText)
    }

    // MARK: - CanvasModel paste

    func testPasteAddsOnTop() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let s1 = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        step(um) { model.add(s1) }

        let s2 = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0)], color: .blue, width: 2)
        let payload = ClipboardPayload(strokes: [s2])
        step(um) { model.paste(payload, offsetBy: .zero) }

        XCTAssertEqual(model.strokes.count, 2)
        XCTAssertEqual(model.strokes[0].id, s1.id)
        XCTAssertNotEqual(model.strokes[1].id, s2.id) // new id
        XCTAssertEqual(model.strokes[1].color, .blue)
    }

    func testPasteReturnsNewIDs() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let t = TextBlock(origin: .zero)
        let payload = ClipboardPayload(strokes: [s], textBlocks: [t])

        var newIDs: Set<UUID> = []
        step(um) { newIDs = model.paste(payload, offsetBy: .zero) }

        XCTAssertEqual(newIDs.count, 2)
        XCTAssertTrue(newIDs.contains(model.strokes[0].id))
        XCTAssertTrue(newIDs.contains(model.textBlocks[0].id))
    }

    func testPasteAppliesDelta() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let payload = ClipboardPayload(strokes: [s])
        let delta = CGVector(dx: 20, dy: 30)

        step(um) { model.paste(payload, offsetBy: delta) }

        XCTAssertEqual(model.strokes[0].points[0].x, 20)
        XCTAssertEqual(model.strokes[0].points[0].y, 30)
    }

    func testPasteUndo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let payload = ClipboardPayload(strokes: [s])

        step(um) { model.paste(payload, offsetBy: .zero) }
        XCTAssertEqual(model.strokes.count, 1)

        um.undo()
        XCTAssertEqual(model.strokes.count, 0)
    }

    func testPasteRedo() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let payload = ClipboardPayload(strokes: [s])

        step(um) { model.paste(payload, offsetBy: .zero) }
        um.undo()
        um.redo()

        XCTAssertEqual(model.strokes.count, 1)
    }

    func testPasteUndoActionName() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0)], color: .black, width: 1)
        let payload = ClipboardPayload(strokes: [s])

        step(um) { model.paste(payload, offsetBy: .zero, actionName: "Custom Paste") }

        XCTAssertEqual(um.undoActionName, "Custom Paste")
    }

    func testPasteEmptyIsNoOp() {
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)

        let payload = ClipboardPayload()
        let newIDs = model.paste(payload, offsetBy: .zero)

        XCTAssertTrue(newIDs.isEmpty)
        XCTAssertEqual(model.strokes.count, 0)
    }

    // MARK: Canvas actions

    func testCanvasDuplicateSelectsOffsetCopyAsOneUndoStep() {
        let s = Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 10, y: 10, t: 1)], color: .black, width: 2)
        let model = CanvasModel(strokes: [s])
        let settings = CanvasSettings()
        settings.tool = .pointer
        let canvas = CanvasView(model: model, settings: settings)
        canvas.selection.select([s.id])
        canvas.duplicate(nil)
        XCTAssertEqual(model.strokes.count, 2)
        XCTAssertEqual(canvas.selection.selection, [model.strokes[1].id])
        XCTAssertEqual(model.strokes[1].bounds, s.bounds.offsetBy(dx: 20, dy: 20))
        XCTAssertEqual(model.undoManager.undoActionName, "Duplicate")
        model.undoManager.undo()
        XCTAssertEqual(model.strokes, [s])
    }
}
