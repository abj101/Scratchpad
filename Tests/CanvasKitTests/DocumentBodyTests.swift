import AppKit
import XCTest
@testable import CanvasKit

final class DocumentBodyTests: XCTestCase {
    func testTypingUndoSurvivesConversionAndRestoresTheSameEditor() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let model = canvas.model
        let undo = model.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body.textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        canvas.syncDocumentBody()
        undo.beginUndoGrouping()
        model.replaceContents(with: NoteConversion.canvasSnapshot(from: model), actionName: "Convert")
        undo.endUndoGrouping()
        XCTAssertEqual(body.textView.string, "hello")
        undo.undo()
        canvas.prepareForPresentation()
        XCTAssertTrue(canvas.documentBodyView === body)
        undo.undo()
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "")
        XCTAssertEqual(model.textBlocks.first?.attributedString.string, "")
        undo.redo()
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "hello")
        undo.redo()
        XCTAssertEqual(model.effectiveLayout, .canvas)
        undo.undo()
        canvas.prepareForPresentation()
        XCTAssertTrue(canvas.documentBodyView === body)
        XCTAssertEqual(body.textView.string, "hello")
    }

    func testTemporaryDocumentPenDoesNotHitTheNativeEditor() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        canvas.settings.tool = .pointer
        canvas.penKeyMonitor.penKey = .option
        canvas.penKeyMonitor.flagsChanged(option: true, function: false)
        XCTAssertTrue(canvas.penKeyMonitor.isPenDown)
        XCTAssertTrue(canvas.hitTest(CGPoint(x: 40, y: 80)) === canvas)
        canvas.penKeyMonitor.flagsChanged(option: false, function: false)
        XCTAssertFalse(canvas.hitTest(CGPoint(x: 40, y: 80)) === canvas)
    }

    func testTextPenModifierUsesHoldEvenWhenDrawingUsesToggle() {
        let canvas = makeScroll().canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        canvas.settings.tool = .pointer
        canvas.settings.penKey = .option
        canvas.settings.activation = .toggle
        XCTAssertTrue(body.drawingCursor?() === canvas.currentCursor(), "The canvas owns the cursor, morphing to the I-beam only near text")
        canvas.documentPenModifiersChanged(option: true, function: false)
        XCTAssertTrue(canvas.penKeyMonitor.isPenDown)
        XCTAssertNil(canvas.toolController.toolOverride, "Text never draws")
        XCTAssertTrue(body.drawingCursor?() === canvas.currentCursor())
        canvas.documentPenModifiersChanged(option: false, function: false)
        XCTAssertFalse(canvas.penKeyMonitor.isPenDown)
        XCTAssertNil(canvas.toolController.toolOverride)
        XCTAssertTrue(body.drawingCursor?() === canvas.currentCursor(), "The canvas owns the cursor, morphing to the I-beam only near text")
        XCTAssertEqual(canvas.settings.tool, .pointer)
        XCTAssertEqual(canvas.settings.activation, .toggle)
    }

    func testFormattingBarTracksBoldItalicUnderlineAndAlignment() {
        let canvas = makeScroll().canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let textView = body.textView
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        // Plain body text: no trait toggles, natural (left) alignment.
        canvas.refreshEditingTextFormatting()
        XCTAssertFalse(canvas.settings.editingIsBold)
        XCTAssertFalse(canvas.settings.editingIsItalic)
        XCTAssertFalse(canvas.settings.editingIsUnderline)
        XCTAssertEqual(canvas.settings.editingAlignment, .natural)

        // A bold + italic + underlined run lights all three toggles.
        let storage = body.textStorage
        let range = NSRange(location: 0, length: 5)
        let font = NSFontManager.shared.convert(.systemFont(ofSize: 15), toHaveTrait: [.boldFontMask, .italicFontMask])
        storage.addAttribute(.font, value: font, range: range)
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        canvas.refreshEditingTextFormatting()
        XCTAssertTrue(canvas.settings.editingIsBold)
        XCTAssertTrue(canvas.settings.editingIsItalic)
        XCTAssertTrue(canvas.settings.editingIsUnderline)

        // Alignment actions flow through to the bar.
        canvas.performTextAction(#selector(NSText.alignCenter(_:)))
        XCTAssertEqual(canvas.settings.editingAlignment, .center)
        canvas.performTextAction(#selector(NSText.alignRight(_:)))
        XCTAssertEqual(canvas.settings.editingAlignment, .right)
    }

    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: 0)!
    }

    func testPenKeyChordsRunShortcutsWhileTyping() {
        let canvas = makeScroll().canvasView
        canvas.settings.tool = .pointer
        canvas.settings.penKey = .space // Option stands in while the caret is active
        XCTAssertTrue(canvas.isDocumentShortcutChord(key("2", .option)))
        XCTAssertFalse(canvas.isDocumentShortcutChord(key("x", .option)), "Option+letter still types")
        XCTAssertFalse(canvas.isDocumentShortcutChord(key("2", [])))
        XCTAssertFalse(canvas.isDocumentShortcutChord(key("2", [.option, .command])))
        XCTAssertFalse(canvas.isDocumentShortcutChord(key("2", .function)))
        canvas.settings.penKey = .fn
        XCTAssertTrue(canvas.isDocumentShortcutChord(key("3", .function)))
        XCTAssertFalse(canvas.isDocumentShortcutChord(key("3", .option)))

        canvas.settings.penKey = .option
        canvas.documentPenModifiersChanged(option: true, function: false)
        XCTAssertTrue(canvas.penKeyMonitor.isPenDown)
        canvas.penKeyMonitor.cancel()
        XCTAssertTrue(canvas.performShortcut(key("2", .option)))
        XCTAssertEqual(canvas.settings.tool, .pen)
        XCTAssertNil(canvas.toolController.toolOverride)
        XCTAssertTrue(canvas.performShortcut(key("4", .option)))
        XCTAssertEqual(canvas.settings.inputMode, .scribe)
    }

    func testPenAndEraserOverrideTheBodyNativeCursor() {
        let canvas = makeScroll().canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        for tool in [Tool.pen, .eraser] {
            canvas.settings.tool = tool
            XCTAssertTrue(body.drawingCursor?() === canvas.currentCursor())
            XCTAssertTrue(canvas.hitTest(CGPoint(x: 40, y: 180)) === canvas)
        }
        canvas.settings.tool = .pointer
        XCTAssertTrue(body.drawingCursor?() === canvas.currentCursor(), "The canvas owns the cursor, morphing to the I-beam only near text")
    }

    private func makeScroll(width: CGFloat = 560) -> CanvasScrollView {
        let scroll = CanvasScrollView(model: CanvasModel(layout: .document), settings: CanvasSettings(), layout: .document)
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: 680)
        scroll.tile()
        return scroll
    }

    func testDocumentCreatesOneLiveBodyAtTheColumnGeometry() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)

        XCTAssertEqual(canvas.model.textBlocks.count, 1)
        XCTAssertTrue(body.isDocumentBody)
        XCTAssertTrue(body.textView.isEditable)
        XCTAssertTrue(body.textView.isSelectable)
        XCTAssertEqual(body.frame.minX, DocumentLayout.sideMargin, accuracy: 0.01)
        XCTAssertEqual(body.frame.minY, DocumentLayout.topInset, accuracy: 0.01)
        XCTAssertEqual(body.frame.width, scroll.contentView.bounds.width - 2 * DocumentLayout.sideMargin, accuracy: 0.01)

        scroll.frame.size.width += 120
        scroll.tile()
        XCTAssertEqual(body.frame.width, scroll.contentView.bounds.width - 2 * DocumentLayout.sideMargin, accuracy: 0.01)
    }

    func testBodySyncAndTypingUndoUseModelUndoManager() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let undo = canvas.model.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body.textView.insertText("hello", replacementRange: body.textView.selectedRange())
        undo.endUndoGrouping()

        canvas.syncDocumentBody()
        XCTAssertEqual(canvas.model.textBlocks.first?.attributedString.string, "hello")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "")
        XCTAssertEqual(canvas.model.textBlocks.first?.attributedString.string, "")
    }

    func testDocumentTextInsertionAtAnchorUsesBodyUndo() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let undo = canvas.model.undoManager
        undo.groupsByEvent = false
        body.setContents(NSAttributedString(string: "abcd"))
        canvas.syncDocumentBody()
        undo.removeAllActions()
        XCTAssertTrue(canvas.insertDocumentText(NSAttributedString(string: "X"), at: 2,
                                                actionName: "Convert to Text"))
        XCTAssertEqual(body.textView.string, "abXcd")
        canvas.syncDocumentBody()
        undo.undo()
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "abcd")
    }

    func testDocumentScribePreviewStaysOutOfSyncAndCommittedTextUndoes() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let undo = canvas.model.undoManager
        body.setContents(NSAttributedString(string: "Hello world"))
        canvas.syncDocumentBody()
        undo.removeAllActions()
        var dirtyCount = 0
        canvas.onDocumentEdit = { dirtyCount += 1 }

        let insertion = ScribeText.formattedPhrase(raw: "new", context: "Hello ", following: "world",
                                                   lexicon: ScribeLexicon(isCommon: { _ in false }))
        let preview = NSAttributedString(string: insertion)
        let previewRange = NSRange(location: 6, length: preview.length)
        canvas.documentBodySyncSuspended = true
        body.textStorage.insert(preview, at: previewRange.location)
        canvas.documentBodySyncSuspended = false
        canvas.scribeProvisional = (preview.string, previewRange)
        canvas.syncDocumentBody()
        XCTAssertEqual(canvas.model.textBlocks.first?.attributedString.string, "Hello world")
        XCTAssertEqual(dirtyCount, 0)

        canvas.documentBodySyncSuspended = true
        body.textStorage.deleteCharacters(in: previewRange)
        canvas.documentBodySyncSuspended = false
        canvas.scribeProvisional = nil
        XCTAssertTrue(canvas.insertDocumentText(preview, at: 6, actionName: "Scribe"))
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "Hello new world")
        XCTAssertEqual(canvas.model.textBlocks.first?.attributedString.string, "Hello new world")
        XCTAssertGreaterThan(dirtyCount, 0)

        undo.undo()
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "Hello world")
        undo.redo()
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "Hello new world")
    }

    func testDocumentReportsPreEditCharacterRange() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        body.textView.insertText("abcdef", replacementRange: body.textView.selectedRange())
        var received: (NSRange, Int)?
        canvas.onDocumentTextEdit = { received = ($0, $1) }

        body.textView.setSelectedRange(NSRange(location: 2, length: 2))
        body.textView.insertText("x", replacementRange: body.textView.selectedRange())

        XCTAssertEqual(received?.0, NSRange(location: 2, length: 2))
        XCTAssertEqual(received?.1, -1)

        body.textStorage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        XCTAssertEqual(received?.0, NSRange(location: 0, length: 0))
        XCTAssertEqual(received?.1, 0)
    }

    func testHitTestingRoutesByDocumentTool() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let point = NSPoint(x: 100, y: DocumentLayout.topInset + 10)
        canvas.settings.tool = .pointer
        XCTAssertTrue(canvas.hitTest(point) === canvas.documentBodyView?.textView)
        canvas.settings.tool = .pen
        XCTAssertTrue(canvas.hitTest(point) === canvas)
    }

    func testSelectAllInTextToolSelectsTextAndStrokes() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let undo = canvas.model.undoManager
        undo.groupsByEvent = false

        // Add text
        undo.beginUndoGrouping()
        body.textView.insertText("hello world", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()

        // Add strokes
        let stroke = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0), StrokePoint(x: 20, y: 20, t: 1)], color: .black, width: 2)
        canvas.model.undoManager.groupsByEvent = false; canvas.model.undoManager.beginUndoGrouping(); canvas.model.add(stroke); canvas.model.undoManager.endUndoGrouping()

        // Set Text tool
        canvas.settings.tool = .pointer

        // Call selectAll
        canvas.selectAll(nil)

        // Text should be fully selected
        XCTAssertEqual(body.textView.selectedRange().length, body.textStorage.length)
        XCTAssertGreaterThan(body.textView.selectedRange().length, 0)

        // Strokes should be selected
        XCTAssertTrue(canvas.selection.selection.contains(stroke.id))

        // Tool should still be Text
        XCTAssertEqual(canvas.settings.tool, .pointer)
    }

    func testSelectAllInPenToolSelectsTextAndStrokes() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)

        // Add text
        body.textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))

        // Add strokes
        let stroke = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0), StrokePoint(x: 20, y: 20, t: 1)], color: .black, width: 2)
        canvas.model.undoManager.groupsByEvent = false; canvas.model.undoManager.beginUndoGrouping(); canvas.model.add(stroke); canvas.model.undoManager.endUndoGrouping()

        // Set Pen tool
        canvas.settings.tool = .pen

        // Call selectAll
        canvas.selectAll(nil)

        // Text should be fully selected
        XCTAssertEqual(body.textView.selectedRange().length, body.textStorage.length)

        // Strokes should be selected
        XCTAssertTrue(canvas.selection.selection.contains(stroke.id))

        // Tool should still be Pen
        XCTAssertEqual(canvas.settings.tool, .pen)
    }

    func testDeleteRemovesTextAndStrokesAsOneStep() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let undo = canvas.model.undoManager
        undo.groupsByEvent = false

        // Add text
        undo.beginUndoGrouping()
        body.textView.insertText("hello world", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()

        // Add strokes
        let stroke = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0), StrokePoint(x: 20, y: 20, t: 1)], color: .black, width: 2)
        canvas.model.undoManager.groupsByEvent = false; canvas.model.undoManager.beginUndoGrouping(); canvas.model.add(stroke); canvas.model.undoManager.endUndoGrouping()

        canvas.syncDocumentBody()
        undo.removeAllActions()

        // Select all
        canvas.selectAll(nil)
        XCTAssertGreaterThan(body.textView.selectedRange().length, 0)
        XCTAssertTrue(canvas.selection.selection.contains(stroke.id))

        // Delete
        canvas.delete(nil)

        // Text should be cleared
        XCTAssertEqual(body.textView.string, "")

        // Strokes should be deleted
        XCTAssertFalse(canvas.model.strokes.contains { $0.id == stroke.id })

        // One undo should restore both
        undo.undo()
        canvas.syncDocumentBody()
        XCTAssertEqual(body.textView.string, "hello world")
        XCTAssertTrue(canvas.model.strokes.contains { $0.id == stroke.id })
        XCTAssertFalse(undo.canUndo, "text and ink deletion must be one undo step")
    }

    func testTypingOverSelectAllInTextViewAlsoRemovesInk() {
        let canvas = makeScroll().canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)
        let undo = canvas.model.undoManager
        undo.groupsByEvent = false
        canvas.settings.tool = .pointer
        let stroke = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0), StrokePoint(x: 20, y: 20, t: 1)], color: .black, width: 2)
        undo.beginUndoGrouping()
        body.textView.insertText("hello world", replacementRange: NSRange(location: 0, length: 0))
        canvas.model.add(stroke)
        undo.endUndoGrouping()
        undo.removeAllActions()

        body.textView.selectAll(nil)
        XCTAssertTrue(canvas.selection.selection.contains(stroke.id))
        undo.beginUndoGrouping()
        body.textView.insertText("x", replacementRange: body.textView.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(body.textView.string, "x")
        XCTAssertFalse(canvas.model.strokes.contains { $0.id == stroke.id })

        undo.undo()
        XCTAssertEqual(body.textView.string, "hello world")
        XCTAssertTrue(canvas.model.strokes.contains { $0.id == stroke.id })
    }

    func testTextSelectionChangeClearsInkSelection() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)

        // Add text
        canvas.model.undoManager.beginUndoGrouping()
        body.textView.insertText("hello world", replacementRange: NSRange(location: 0, length: 0))
        canvas.model.undoManager.endUndoGrouping()

        // Add strokes
        let stroke = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0), StrokePoint(x: 20, y: 20, t: 1)], color: .black, width: 2)
        canvas.model.undoManager.groupsByEvent = false; canvas.model.undoManager.beginUndoGrouping(); canvas.model.add(stroke); canvas.model.undoManager.endUndoGrouping()

        // Select all
        canvas.selectAll(nil)
        XCTAssertTrue(canvas.selection.selection.contains(stroke.id))

        // Change text selection to just part of the text
        body.textView.setSelectedRange(NSRange(location: 0, length: 5))

        // Ink selection should be cleared
        XCTAssertFalse(canvas.selection.selection.contains(stroke.id))
    }

    func testCopyTextAndStrokes() {
        let scroll = makeScroll()
        let canvas = scroll.canvasView
        let body = try! XCTUnwrap(canvas.documentBodyView)

        // Add text
        body.textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))

        // Add strokes
        let stroke = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0), StrokePoint(x: 20, y: 20, t: 1)], color: .black, width: 2)
        canvas.model.undoManager.groupsByEvent = false; canvas.model.undoManager.beginUndoGrouping(); canvas.model.add(stroke); canvas.model.undoManager.endUndoGrouping()

        // Select all
        canvas.selectAll(nil)

        // Copy
        canvas.copy(nil)

        // Read from pasteboard
        let pb = NSPasteboard.general
        let payload = ClipboardPayload.read(from: pb)

        // Should have text and strokes
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.textBlocks.count, 1)
        XCTAssertGreaterThan(payload?.textBlocks[0].attributedString.string.count ?? 0, 0)
        XCTAssertEqual(payload?.strokes.count, 1)

        // Plain text should also be on pasteboard
        let plainText = pb.string(forType: .string)
        XCTAssertNotNil(plainText)
        XCTAssertTrue(plainText?.contains("hello") ?? false)
    }

    func testCanvasLayoutSelectAllStillChangesToPointer() {
        let scroll = CanvasScrollView(model: CanvasModel(layout: .canvas), settings: CanvasSettings(), layout: .canvas)
        scroll.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        scroll.tile()
        let canvas = scroll.canvasView

        // Add a stroke
        let stroke = Stroke(points: [StrokePoint(x: 10, y: 10, t: 0), StrokePoint(x: 20, y: 20, t: 1)], color: .black, width: 2)
        canvas.model.undoManager.groupsByEvent = false; canvas.model.undoManager.beginUndoGrouping(); canvas.model.add(stroke); canvas.model.undoManager.endUndoGrouping()

        // Set tool to something other than pointer
        canvas.settings.tool = .pen

        // Call selectAll
        canvas.selectAll(nil)

        // Should have switched to pointer
        XCTAssertEqual(canvas.settings.tool, .pointer)

        // Stroke should be selected
        XCTAssertTrue(canvas.selection.selection.contains(stroke.id))
    }
}
