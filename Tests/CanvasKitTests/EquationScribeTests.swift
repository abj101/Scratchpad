#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

final class EquationScribeTests: XCTestCase {
    private func canvas(layout: NoteLayout = .canvas) -> CanvasView {
        _ = NSApplication.shared
        let model = CanvasModel()
        model.layout = layout
        let view = CanvasScrollView(model: model, settings: CanvasSettings(), layout: layout)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.canvasView.renderEquationPreview = { _, _, _ in }
        return view.canvasView
    }

    func testAttributedScribePreservesProseAndEquationAtTarget() throws {
        let view = canvas()
        var block = TextBlock(origin: CGPoint(x: 20, y: 30), width: 400)
        block.content = TextBlock.content(from: NSAttributedString(string: "Before "))
        view.model.addTextBlock(block)
        view.scribeTarget = block.id
        let equation = EquationAttachment(latex: #"\frac{x^{2}}{\alpha_{i}}"#, fontSize: 16)
        view.appendScribeContentForTesting(NSAttributedString(attachment: equation))
        view.appendScribeContentForTesting(NSAttributedString(string: " after"))
        let result = try XCTUnwrap(view.model.textBlock(id: block.id)).attributedString
        XCTAssertEqual(result.equationPlainText, #"Before \frac{x^{2}}{\alpha_{i}} after"#)
        XCTAssertEqual((result.attribute(.attachment, at: 7, effectiveRange: nil) as? EquationAttachment)?.id, equation.id)
        XCTAssertTrue(view.model.strokes.isEmpty)
    }

    func testEquationSourceSavedBeforePreviewAndUndoIsOneStep() throws {
        let view = canvas()
        let undo = view.model.undoManager
        undo.groupsByEvent = false
        let id = UUID()
        view.applyEquationSourceForTesting(#"\frac{a}{b}"#, id: id)
        let block = try XCTUnwrap(view.model.textBlocks.first)
        let first = try XCTUnwrap(block.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? EquationAttachment)
        XCTAssertEqual(first.latex, #"\frac{a}{b}"#)
        XCTAssertNil(first.previewPDF)
        view.applyEquationSourceForTesting(#"\frac{a^{2}}{b}"#, id: id)
        XCTAssertEqual(view.model.textBlocks.first?.plainText, #"\frac{a^{2}}{b}"#)
        undo.undo()
        XCTAssertEqual(view.model.textBlocks.first?.plainText, #"\frac{a}{b}"#)
        undo.undo()
        XCTAssertTrue(view.model.textBlocks.isEmpty)
        undo.redo()
        undo.redo()
        XCTAssertEqual(view.model.textBlocks.first?.plainText, #"\frac{a^{2}}{b}"#)
        XCTAssertTrue(view.model.strokes.isEmpty)
    }

    /// Opening an equation must not show the live field until it holds that equation: the page
    /// still renders the previously edited source for a frame, and hiding the static preview
    /// first showed that stale equation where the click landed. The preview keeps the place
    /// until the field reports the source back, and the live math is put exactly where the
    /// preview drew it instead of on the field box's corner.
    @MainActor func testLiveEquationWaitsForItsSourceAndSitsOnThePreview() async throws {
        let view = canvas()
        let equation = EquationAttachment(latex: #"\frac{a}{b}"#, fontSize: 24,
                                          previewMetrics: EquationPreviewMetrics(width: 28, height: 48, baseline: 27))
        var block = TextBlock(origin: CGPoint(x: 40, y: 40), width: 400)
        block.content = TextBlock.content(from: NSAttributedString(attachment: equation))
        view.model.addTextBlock(block)
        let textView = try XCTUnwrap(view.textViews[block.id])
        let rect = try XCTUnwrap(textView.rectForAttachment(at: 0))

        view.openEquationForTesting(equation.id)
        let editor = try XCTUnwrap(view.mathEditorForTesting, "Opening an equation mounts the live field")
        XCTAssertNil(textView.editingEquationID, "The preview must hold the equation until the field holds it")
        XCTAssertEqual(editor.alphaValue, 0, accuracy: 0.01, "The stale field must not be visible yet")
        for _ in 0..<240 where editor.alphaValue == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(textView.editingEquationID, equation.id, "The field must take over once it holds the source")

        // The preview draws the math `fontSize * 0.2` inside the attachment's box (which
        // `rectForAttachment` inflates by 2pt for hit tolerance); the field wraps the same math
        // in its own chrome, so its content inset has to be taken off again.
        let box = rect.insetBy(dx: 2, dy: 2)
        let pad = CGFloat(equation.fontSize) * 0.2
        let expected = textView.convert(CGPoint(x: box.minX + pad, y: box.minY + pad), to: view)
        let math = CGPoint(x: editor.frame.minX + editor.contentInsets.x * textView.scale,
                           y: editor.frame.minY + editor.contentInsets.y * textView.scale)
        XCTAssertEqual(math.x, expected.x, accuracy: 0.75, "The live math must stay on the preview's left")
        XCTAssertEqual(math.y, expected.y, accuracy: 0.75, "The live math must stay on the preview's row")
    }

    func testDocumentInsertionBetweenProseKeepsNativeUndo() throws {
        let view = canvas(layout: .document)
        let body = try XCTUnwrap(view.documentBodyView)
        let undo = view.model.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body.textView.insertText("Before after", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        view.syncDocumentBody()
        view.scribeDocumentIndex = 7
        view.scribeTarget = view.documentBodyID
        let id = UUID()
        view.applyEquationSourceForTesting("x_{i}^{2}", id: id)
        XCTAssertEqual(body.textStorage.equationPlainText, "Before x_{i}^{2}after")
        XCTAssertEqual(view.model.textBlocks.first?.plainText, "Before x_{i}^{2}after")
        undo.undo()
        view.syncDocumentBody()
        XCTAssertEqual(body.textStorage.string, "Before after")
        undo.redo()
        view.syncDocumentBody()
        XCTAssertEqual(body.textStorage.equationPlainText, "Before x_{i}^{2}after")
        XCTAssertTrue(view.model.strokes.isEmpty)
    }
    func testDecoderRevisionAndRepeatedSourceKeepOneUndoStep() throws {
        for layout: NoteLayout in [.canvas, .document] {
            let view = canvas(layout: layout)
            let undo = view.model.undoManager
            undo.groupsByEvent = false
            let id = UUID()
            view.applyEquationSourceForTesting("log", id: id)
            view.applyEquationSourceForTesting(#"\log"#, id: id, undoable: false)
            view.applyEquationSourceForTesting(#"\log"#, id: id)
            undo.undo()
            if layout == .document { view.syncDocumentBody() }
            XCTAssertTrue(view.model.textBlocks.allSatisfy { $0.attributedString.length == 0 })
            undo.redo()
            if layout == .document { view.syncDocumentBody() }
            XCTAssertEqual(view.model.textBlocks.first?.plainText, #"\log"#)
        }
    }
    func testStalePreviewRejectedAndDerivedPreviewAddsNoUndo() throws {
        let view = canvas()
        var replies: [(Result<MathLiveRenderedPreview, Error>) -> Void] = []
        view.renderEquationPreview = { _, _, completion in replies.append(completion) }
        let undo = view.model.undoManager
        undo.groupsByEvent = false
        let id = UUID()
        view.applyEquationSourceForTesting("x", id: id)
        view.applyEquationSourceForTesting("x^{2}", id: id)
        XCTAssertEqual(replies.count, 2)
        guard replies.count == 2 else { return }
        let previewView = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        let pdf = previewView.dataWithPDF(inside: previewView.bounds)
        let preview = MathLiveRenderedPreview(pdfData: pdf, size: CGSize(width: 80, height: 40))
        replies[0](.success(preview))
        var equation = try XCTUnwrap(view.model.textBlocks.first?.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? EquationAttachment)
        XCTAssertEqual(equation.latex, "x^{2}")
        XCTAssertNil(equation.previewPDF)
        replies[1](.success(preview))
        equation = try XCTUnwrap(view.model.textBlocks.first?.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? EquationAttachment)
        XCTAssertEqual(equation.previewPDF, pdf)
        undo.undo()
        XCTAssertEqual(view.model.textBlocks.first?.plainText, "x")
    }

    func testActiveEquationPreviewIsHiddenWithoutChangingStorageOrLayout() throws {
        _ = NSApplication.shared
        let equation = EquationAttachment(latex: "XXXX", fontSize: 28)
        let block = TextBlockView(blockID: UUID(), width: 300)
        block.setContents(NSAttributedString(attachment: equation))
        let host = NSWindow(contentRect: block.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = block
        defer { host.close() }
        let originalRect = try XCTUnwrap(block.rectForAttachment(at: 0))
        let originalText = NSAttributedString(attributedString: block.textStorage)
        func snapshot() throws -> Data {
            let bitmap = try XCTUnwrap(block.bitmapImageRepForCachingDisplay(in: block.bounds))
            block.cacheDisplay(in: block.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let visible = try snapshot()
        block.editingEquationID = equation.id
        let hidden = try snapshot()
        XCTAssertNotEqual(visible, hidden, "The persisted preview must not draw underneath the web editor")
        XCTAssertTrue(block.textStorage.isEqual(to: originalText), "Hiding is presentation-only")
        XCTAssertEqual(block.rectForAttachment(at: 0), originalRect)
        block.editingEquationID = nil
        XCTAssertEqual(try snapshot(), visible, "Finishing must restore the single saved preview")
        let hit = try XCTUnwrap(block.equation(at: CGPoint(x: originalRect.midX, y: originalRect.midY)))
        XCTAssertEqual(hit.0.id, equation.id)
        XCTAssertNil(block.equation(at: CGPoint(x: 280, y: originalRect.midY)),
                     "Nearby prose/whitespace must not open the closest equation")
    }

    private func key(_ code: UInt16, chars: String = "",
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code))
    }

    /// The preview's left edge is the line's origin: growth goes right, and reaching the
    /// page edge shrinks the preview instead of wrapping it to the next line.
    func testGrowingEquationKeepsItsLineOriginWithoutWrapping() throws {
        _ = NSApplication.shared
        func pdf(width: CGFloat) -> Data {
            let view = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 20))
            return view.dataWithPDF(inside: view.bounds)
        }
        func attachment(width: CGFloat) -> EquationAttachment {
            EquationAttachment(latex: "x", fontSize: 16, previewPDF: pdf(width: width),
                               previewMetrics: EquationPreviewMetrics(width: width, height: 20, baseline: 16))
        }
        let block = TextBlockView(blockID: UUID(), width: 200, scale: 1)
        let host = NSWindow(contentRect: block.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = block
        defer { host.close() }

        var text = NSMutableAttributedString(string: "Before ")
        text.append(NSAttributedString(attachment: attachment(width: 60)))
        block.setContents(text as NSAttributedString)
        let origin = try XCTUnwrap(block.rectForAttachment(at: 7))

        text = NSMutableAttributedString(string: "Before ")
        text.append(NSAttributedString(attachment: attachment(width: 400)))
        block.setContents(text as NSAttributedString)
        let grown = try XCTUnwrap(block.rectForAttachment(at: 7))

        XCTAssertEqual(grown.minX, origin.minX, accuracy: 0.5,
                       "The line must grow only to the right, never jump to another line's origin")
        XCTAssertGreaterThan(grown.width, origin.width, "The wider preview still uses the space to its right")
        XCTAssertLessThanOrEqual(grown.maxX, block.bounds.width + 1,
                                 "At the page edge the preview shrinks instead of wrapping")
    }

    /// Re-entering Scribe finds the equation the caret sits in or next to, so the
    /// suspended-math restore path can reopen it as the active editor.
    func testEquationAtScribeCaretFindsTheEquationBesideTheCaret() throws {
        let view = canvas(layout: .document)
        let body = try XCTUnwrap(view.documentBodyView)
        let equation = EquationAttachment(latex: #"\frac{a}{b}"#, fontSize: 16)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(attachment: equation))
        text.append(NSAttributedString(string: " tail"))
        body.setContents(text as NSAttributedString)
        view.syncDocumentBody()
        view.scribeTarget = view.documentBodyID

        view.scribeDocumentIndex = 1 // the caret sits right after the equation
        let found = try XCTUnwrap(view.equationAtScribeCaret())
        XCTAssertEqual(found.equation.id, equation.id)

        view.scribeDocumentIndex = text.length // the caret is past the trailing prose
        XCTAssertNil(view.equationAtScribeCaret(),
                     "Prose between the caret and the equation keeps it out of reach")
    }

    /// ⌘A selects the body text (ink included via `documentTextWillReplace`); Delete must
    /// clear all of it even in Scribe math, where the key otherwise deletes written letters.
    func testSelectAllThenDeleteClearsEverythingInScribeMath() throws {
        let view = canvas(layout: .document)
        let body = try XCTUnwrap(view.documentBodyView)
        body.setContents(NSAttributedString(string: "Hello world"))
        view.syncDocumentBody()
        view.scribeTarget = view.documentBodyID
        view.useScribeMathForTesting()
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)

        view.selectAllDocumentContent()
        XCTAssertEqual(body.textView.selectedRange(), NSRange(location: 0, length: 11))

        view.keyDown(with: try key(51))
        XCTAssertEqual(body.textStorage.string, "",
                       "⌘A then Delete must clear everything, in any mode")
    }

    func testRendererFailurePreservesSavedSource() throws {
        let view = canvas()
        view.renderEquationPreview = { _, _, completion in
            completion(.failure(NSError(domain: "RendererTest", code: 1)))
        }
        view.applyEquationSourceForTesting(#"\frac{x}{y}"#, id: UUID())
        let equation = try XCTUnwrap(view.model.textBlocks.first?.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? EquationAttachment)
        XCTAssertEqual(equation.latex, #"\frac{x}{y}"#)
        XCTAssertNotNil(equation.image)
        XCTAssertNil(equation.previewPDF)
        XCTAssertTrue(view.model.strokes.isEmpty)
    }

}

#endif
