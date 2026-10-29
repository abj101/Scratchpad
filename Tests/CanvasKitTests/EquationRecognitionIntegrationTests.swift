#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

@MainActor final class EquationRecognitionIntegrationTests: XCTestCase {
    func testMathLineKeepsItsHorizontalAnchorAsSymbolsAreAdded() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        let model = CanvasModel()
        let scroll = CanvasScrollView(model: model, settings: settings)
        scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let view = scroll.canvasView
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        view.renderEquationPreview = { _, _, _ in }
        var block = TextBlock(origin: CGPoint(x: 70, y: 70), width: 400)
        block.content = TextBlock.content(from: NSAttributedString(string: "Before ", attributes: TextFormatting.defaultAttributes))
        model.addTextBlock(block)
        view.selection.select([block.id])
        settings.handwritingToText = true
        settings.scribeMath = true
        settings.inputMode = .write
        view.scribeTarget = block.id
        view.insertMathSymbol(id: UUID(), latex: "x", role: .body)
        let editor = try XCTUnwrap(view.mathEditorForTesting)
        for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(250))
        let initial = editor.frame.minX
        let viewportX = scroll.contentView.bounds.minX
        for i in 0..<60 {
            view.insertMathSymbol(id: UUID(), latex: i.isMultiple(of: 2) ? "+" : "1", role: .body)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(editor.frame.minX, initial, accuracy: 0.5, "Source fallback sizing must not wrap/re-anchor a live equation")
            XCTAssertEqual(scroll.contentView.bounds.minX, viewportX, accuracy: 0.5,
                           "Viewport follow must not pan the whole line horizontally while math grows")
            let x = try await editor.webView.evaluateJavaScript("window.scrollX") as? Double
            XCTAssertEqual(x, 0, "The math web document must not scroll horizontally during input")
        }
    }

    func testGrowingEquationIsNeverScaledDownWhileRoomRemains() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        let model = CanvasModel()
        let scroll = CanvasScrollView(model: model, settings: settings)
        scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let view = scroll.canvasView
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        view.renderEquationPreview = { _, _, _ in }
        settings.handwritingToText = true
        settings.scribeMath = true
        settings.inputMode = .write
        view.insertMathSymbol(id: UUID(), latex: "x", role: .body)
        let editor = try XCTUnwrap(view.mathEditorForTesting)
        for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        _ = try await editor.webView.evaluateJavaScript("""
            window.__scaled = [];
            new MutationObserver(() => { const t = document.getElementById('mf').style.transform;
              if (t && t !== 'none') window.__scaled.push(t); })
              .observe(document.getElementById('mf'), {attributes: true, attributeFilter: ['style']}); 0
            """)
        for i in 0..<12 {
            view.insertMathSymbol(id: UUID(), latex: i.isMultiple(of: 2) ? "+" : "1", role: .body)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scaled = try await editor.webView.evaluateJavaScript("window.__scaled.join(' | ')") as? String
        XCTAssertEqual(scaled, "", "A short equation with room to grow must not shrink as characters are added")
    }

    func testCaretStaysVisibleAfterArrowingOutOfDenominator() async throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let settings = CanvasSettings()
            let model = CanvasModel()
            model.layout = layout
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            view.renderEquationPreview = { _, _, _ in }
            settings.handwritingToText = true
            settings.scribeMath = true
            settings.inputMode = .write
            let numerator = UUID()
            view.insertMathSymbol(id: numerator, latex: "a", role: .body)
            let editor = try XCTUnwrap(view.mathEditorForTesting)
            for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            view.insertMathFraction(operandIDs: [numerator])
            view.insertMathSymbol(id: UUID(), latex: "b", role: .body)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            // Trackpad input keeps keyboard focus on the canvas, so arrows arrive through navigate().
            window.makeFirstResponder(view)
            _ = try await editor.webView.evaluateJavaScript("document.getElementById('mf').blur(); 0")
            editor.navigate("right")
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            try await Task.sleep(for: .milliseconds(150))
            let probe = try await editor.webView.evaluateJavaScript("""
                (() => { const mf = document.getElementById('mf');
                  const caret = mf.shadowRoot.querySelector('.ML__caret');
                  if (!caret) return 'no caret element; pos=' + mf.position + '/' + mf.lastOffset + ' focus=' + mf.hasFocus();
                  const r = caret.getBoundingClientRect(); const s = getComputedStyle(caret);
                  const after = getComputedStyle(caret, '::after');
                  return JSON.stringify({x:r.x, y:r.y, w:r.width, h:r.height, vw:innerWidth, vh:innerHeight,
                    vis:s.visibility, disp:s.display, op:s.opacity, afterW:after.width, afterH:after.height,
                    afterBg:after.backgroundColor, afterBorder:after.borderRightWidth+' '+after.borderRightColor,
                    focus:mf.hasFocus(), pos:mf.position, last:mf.lastOffset, latex:mf.value}); })()
                """) as? String
            XCTAssertEqual(editor.latex, #"\frac{a}{b}"#)
            let focused = try await editor.webView.evaluateJavaScript("document.getElementById('mf').hasFocus()") as? Bool
            XCTAssertEqual(focused, true, "\(layout): arrow navigation must leave a visible caret: \(probe ?? "nil")")
        }
    }

    func testDefaultFontSizeAppliesToNewTextAndMathButNotExistingContent() async throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let settings = CanvasSettings()
            settings.defaultFontSize = 24
            let model = CanvasModel()
            model.layout = layout
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            view.renderEquationPreview = { _, _, _ in }
            if layout == .document {
                let body = try XCTUnwrap(view.documentBodyView)
                XCTAssertEqual((body.textView.typingAttributes[.font] as? NSFont)?.pointSize, 24)
                settings.defaultFontSize = 26
                XCTAssertEqual((body.textView.typingAttributes[.font] as? NSFont)?.pointSize, 26,
                               "An empty editor should pick up settings changes")
                settings.defaultFontSize = 24
            }
            view.appendScribeContentForTesting("Before ")
            let block = try XCTUnwrap(model.textBlocks.first)
            view.insertMathSymbol(id: UUID(), latex: "x", role: .body)
            let editor = try XCTUnwrap(view.mathEditorForTesting)
            for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            XCTAssertEqual(editor.fontSize, 24)
            settings.defaultFontSize = 30
            view.insertMathSymbol(id: UUID(), latex: "+1", role: .body)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            let stored = try XCTUnwrap(model.textBlock(id: block.id)).attributedString
            XCTAssertEqual((stored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
            let equation = try XCTUnwrap(stored.attribute(.attachment, at: 7, effectiveRange: nil) as? EquationAttachment)
            XCTAssertEqual(equation.fontSize, 24, "Changing the default must not resize an active equation")
            view.finishMathEquation(insertNewline: true)
            for _ in 0..<80 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
            view.insertMathSymbol(id: UUID(), latex: "y", role: .body)
            let next = try XCTUnwrap(view.mathEditorForTesting)
            for _ in 0..<240 where !next.isReady { try await Task.sleep(for: .milliseconds(25)) }
            await withCheckedContinuation { continuation in next.flush { continuation.resume() } }
            XCTAssertEqual(next.fontSize, 30, "New equations should use the new default")
        }
    }

    /// An inline equation is one attachment character, but it edits like a run of text:
    /// Delete against its edge edits the expression and an arrow steps into it, instead of
    /// wiping it whole or selecting it. Leaving writing mode puts the caret just after the
    /// expression, so those are the keys the user presses first.
    func testNoteLevelDeleteAndArrowEditTheEquationInsteadOfRemovingIt() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        settings.handwritingToText = true
        settings.scribeMath = true
        let model = CanvasModel()
        model.layout = .document
        model.undoManager.groupsByEvent = false
        let scroll = CanvasScrollView(model: model, settings: settings, layout: .document)
        scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let view = scroll.canvasView
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        view.renderEquationPreview = { _, _, _ in }
        settings.inputMode = .write
        view.appendScribeContentForTesting("Before ")
        view.insertMathSymbol(id: UUID(), latex: "x+1+y", role: .body)
        let editor = try XCTUnwrap(view.mathEditorForTesting)
        for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        window.makeFirstResponder(editor.webView)

        settings.toggleWritingMode()
        for _ in 0..<240 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
        let body = try XCTUnwrap(view.documentBodyView)
        XCTAssertEqual(body.textStorage.string, "Before \u{fffc}", "Leaving writing mode keeps the expression")

        // Focus sits in the note with the caret right after the expression. One Backspace
        // edits the expression: it neither wipes it nor selects it as one object.
        window.makeFirstResponder(body.textView)
        body.textView.setSelectedRange(NSRange(location: body.textStorage.length, length: 0))
        body.textView.deleteBackward(nil)
        for _ in 0..<240 where model.textBlocks.first?.plainText != "Before x+1+" { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(model.textBlocks.first?.plainText, "Before x+1+",
                       "Backspace against the expression drops one symbol")
        XCTAssertEqual(body.textStorage.string, "Before \u{fffc}", "The expression stays in the note")
        XCTAssertEqual(body.textView.selectedRange().length, 0, "The expression is not selected as a unit")

        // Escape closes the field, and the arrow enters the expression from the note again.
        view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        for _ in 0..<240 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
        window.makeFirstResponder(body.textView)
        body.textView.setSelectedRange(NSRange(location: body.textStorage.length, length: 0))
        body.textView.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 3, windowNumber: window.windowNumber, context: nil,
            characters: String(utf16CodeUnits: [0xF702], count: 1),
            charactersIgnoringModifiers: String(utf16CodeUnits: [0xF702], count: 1), isARepeat: false, keyCode: 123)))
        let arrowed = try XCTUnwrap(view.mathEditorForTesting, "A left arrow at the expression enters it")
        for _ in 0..<240 where !arrowed.isReady { try await Task.sleep(for: .milliseconds(25)) }
        await withCheckedContinuation { continuation in arrowed.flush { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(50))
        let caret = try await arrowed.webView.evaluateJavaScript("""
            (function(){ const mf = document.getElementById('mf');
              return JSON.stringify({pos: mf.position, last: mf.lastOffset}); })()
            """) as? String
        let data = try XCTUnwrap(caret?.data(using: .utf8))
        let range = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertGreaterThan(range["last"] as? Int ?? 0, 0, "The expression is open: \(caret ?? "nil")")
        XCTAssertEqual(range["pos"] as? Int, range["last"] as? Int,
                       "The caret enters at the end it was pressed from: \(caret ?? "nil")")
        XCTAssertEqual(model.textBlocks.first?.plainText, "Before x+1+", "An arrow must not edit the expression")
    }

    /// The canvas keeps one MathLive page and retargets it for every equation, so the
    /// second expression opens on a field that is already loaded and laid out instead of
    /// paying for a page load (and the open-time layout race that came with it).
    func testSecondEquationReusesTheLoadedPageInsteadOfOpeningANewOne() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        settings.handwritingToText = false
        settings.inputMode = .write
        let model = CanvasModel()
        let scroll = CanvasScrollView(model: model, settings: settings)
        scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let view = scroll.canvasView
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        view.useScribeMathForTesting()
        view.renderEquationPreview = { _, _, _ in }
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = .greatestFiniteMagnitude

        let coldStart = Date()
        view.insertMathSymbol(id: UUID(), latex: "x", role: .body)
        let first = try XCTUnwrap(view.mathEditorForTesting, "Handwriting must mount the equation editor")
        for _ in 0..<240 where !first.isReady { try await Task.sleep(for: .milliseconds(25)) }
        let coldOpen = Date().timeIntervalSince(coldStart)
        XCTAssertTrue(first.isReady, "Bundled MathLive should load offline")
        await withCheckedContinuation { continuation in first.flush { continuation.resume() } }
        // A marker in the live document proves later equations run in this same page.
        _ = try await first.webView.evaluateJavaScript("window.__livePage = 'first'; 0")

        XCTAssertTrue(view.handleWritingKey(try writingKey(36, in: window, characters: "\r")))
        for _ in 0..<240 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(view.mathEditorForTesting, "Return must close the equation")

        let warmStart = Date()
        view.insertMathSymbol(id: UUID(), latex: "y", role: .body)
        let second = try XCTUnwrap(view.mathEditorForTesting)
        // The field is live on the same turn the equation opens: a page that had to load
        // could not report ready until an await had passed.
        XCTAssertTrue(second.isReady, "A reused page is live the moment the equation opens")
        for _ in 0..<240 where !second.isReady { try await Task.sleep(for: .milliseconds(25)) }
        let warmOpen = Date().timeIntervalSince(warmStart)
        XCTAssertTrue(second === first, "Every equation must retarget the page the canvas already has")
        XCTAssertLessThan(warmOpen, 0.05,
                          "Entering the second equation must not wait on a page load (\(warmOpen)s vs \(coldOpen)s for the first)")
        await withCheckedContinuation { continuation in second.flush { continuation.resume() } }
        XCTAssertEqual(second.latex, "y")
        XCTAssertEqual(model.textBlocks.first?.plainText, "x\ny")
        let token = try await second.webView.evaluateJavaScript("window.__livePage") as? String
        XCTAssertEqual(token, "first", "The reused page must be the document that was already loaded, not a reload")
    }

    /// An idle note must not keep the shared MathLive page (and its web content process)
    /// alive forever, but editing that resumes inside the idle window still finds the warm
    /// page. The next expression after the release mounts a fresh page.
    func testIdleMathPageIsReleasedAndTheNextOpenMountsAFreshOne() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        settings.handwritingToText = false
        settings.inputMode = .write
        let model = CanvasModel()
        let scroll = CanvasScrollView(model: model, settings: settings)
        scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let view = scroll.canvasView
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        view.useScribeMathForTesting()
        view.renderEquationPreview = { _, _, _ in }
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = .greatestFiniteMagnitude
        // A generous window proves the warm re-entry; the release check shortens it below.
        view.mathEditorIdleReleaseDelayForTesting = 2.0

        func closeEquation(_ label: String) async throws {
            XCTAssertTrue(view.handleWritingKey(try writingKey(36, in: window, characters: "\r")),
                          "\(label): Return must close the equation")
            for _ in 0..<240 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNil(view.mathEditorForTesting, "\(label): Return must close the equation")
        }

        view.insertMathSymbol(id: UUID(), latex: "x", role: .body)
        let first = try XCTUnwrap(view.mathEditorForTesting, "Handwriting must mount the equation editor")
        for _ in 0..<240 where !first.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(first.isReady, "Bundled MathLive should load offline")
        try await closeEquation("first")

        // Re-entering inside the idle window is still the loaded page.
        view.insertMathSymbol(id: UUID(), latex: "y", role: .body)
        let warm = try XCTUnwrap(view.mathEditorForTesting, "The next symbol must mount the editor")
        XCTAssertTrue(warm === first, "Editing inside the idle window must keep the loaded page")
        for _ in 0..<240 where !warm.isReady { try await Task.sleep(for: .milliseconds(25)) }
        view.mathEditorIdleReleaseDelayForTesting = 0.15
        try await closeEquation("warm")

        // Left alone past the idle window the page is gone, web content process included.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(view.reusableMathEditorForTesting, "An idle note must release the shared MathLive page")
        XCTAssertNil(first.superview)

        // The next expression loads a fresh page instead of the released one.
        view.insertMathSymbol(id: UUID(), latex: "z", role: .body)
        let fresh = try XCTUnwrap(view.mathEditorForTesting, "A new expression must mount a new editor")
        XCTAssertFalse(fresh === first, "The released page must not be reused")
        for _ in 0..<240 where !fresh.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(fresh.isReady, "The fresh page must load offline too")
        await withCheckedContinuation { continuation in fresh.flush { continuation.resume() } }
        XCTAssertEqual(fresh.latex, "z")
    }

    /// Clicking an equation in the note places the caret where the click landed, so editing
    /// it feels like clicking into a run of text instead of always starting at the end.
    func testClickingAnEquationInTheNotePlacesTheCaretWhereItWasClicked() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        settings.handwritingToText = true
        settings.scribeMath = true
        let model = CanvasModel()
        model.layout = .document
        model.undoManager.groupsByEvent = false
        let scroll = CanvasScrollView(model: model, settings: settings, layout: .document)
        scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let view = scroll.canvasView
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        view.renderEquationPreview = { _, _, _ in }
        settings.inputMode = .write
        view.appendScribeContentForTesting("Before ")
        view.insertMathSymbol(id: UUID(), latex: "x+1+y", role: .body)
        let editor = try XCTUnwrap(view.mathEditorForTesting)
        for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        settings.toggleWritingMode()
        for _ in 0..<240 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
        let body = try XCTUnwrap(view.documentBodyView)
        let rect = try XCTUnwrap(body.rectForAttachment(at: 7))
        let middle = body.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: middle, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        body.textView.mouseDown(with: click)
        let opened = try XCTUnwrap(view.mathEditorForTesting, "A click on the expression opens it")
        for _ in 0..<240 where !opened.isReady { try await Task.sleep(for: .milliseconds(25)) }
        await withCheckedContinuation { continuation in opened.flush { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(80))
        let caret = try await opened.webView.evaluateJavaScript("""
            (function(){ const mf = document.getElementById('mf');
              return JSON.stringify({pos: mf.position, last: mf.lastOffset, value: mf.value}); })()
            """) as? String
        let data = try XCTUnwrap(caret?.data(using: .utf8))
        let range = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let last = range["last"] as? Int ?? 0
        // The field is laid out by Auto Layout, so its own geometry can still be empty when
        // the click is routed; flipping through that empty height parked the caret before
        // the first symbol.
        XCTAssertGreaterThan(last, 0, "The expression is open: \(caret ?? "nil")")
        XCTAssertGreaterThan(range["pos"] as? Int ?? 0, 0, "The caret must follow the click into the middle: \(caret ?? "nil")")
        XCTAssertLessThan(range["pos"] as? Int ?? 0, last, "The caret must not jump to the end: \(caret ?? "nil")")
        XCTAssertEqual(model.textBlocks.first?.plainText, "Before x+1+y", "A click must not edit the expression")
    }

    func testSelectAllInTheEquationDoesNotDeleteTheNoteAfterLeavingWritingMode() async throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.document, .canvas] {
            let settings = CanvasSettings()
            settings.handwritingToText = true
            settings.scribeMath = true
            let model = CanvasModel()
            model.layout = layout
            model.undoManager.groupsByEvent = false
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            view.renderEquationPreview = { _, _, _ in }
            settings.inputMode = .write
            view.insertMathSymbol(id: UUID(), latex: "x+1", role: .body)
            let editor = try XCTUnwrap(view.mathEditorForTesting)
            for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            window.makeFirstResponder(editor.webView)
            // ⌘A while the equation field has focus selects the whole note, text and ink.
            view.selectAllDocumentContent()
            editor.navigate("selectAll")
            if let body = view.documentBodyView {
                XCTAssertGreaterThan(body.textView.selectedRange().length, 0, "\(layout): ⌘A selects the note")
            }

            settings.toggleWritingMode()
            for _ in 0..<240 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
            if let body = view.documentBodyView {
                XCTAssertEqual(body.textView.selectedRange().length, 0,
                               "\(layout): leaving writing mode must drop the equation's note-wide selection")
            }

            view.keyDown(with: try writingKey(51, in: window))
            XCTAssertEqual(model.textBlocks.count, 1, "\(layout): Delete after leaving writing mode must keep the expression")
            XCTAssertEqual(model.textBlocks.first?.plainText, "x+1", "\(layout): the expression survives Delete")
            if let body = view.documentBodyView {
                XCTAssertEqual(body.textStorage.string, "\u{fffc}", "\(layout): the document text is unchanged")
            }
        }
    }

    private func writingKey(_ code: UInt16, in window: NSWindow, characters: String = "") throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testCornerAdvanceLeavesFilledDenominatorAndDeleteRemovesMathNewlines() async throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let settings = CanvasSettings()
            settings.handwritingToText = true
            settings.scribeMath = true
            let model = CanvasModel()
            model.layout = layout
            model.undoManager.groupsByEvent = false
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            settings.inputMode = .write
            XCTAssertEqual(settings.effectiveInputMode, .scribe)
            view.renderEquationPreview = { _, _, _ in }
            view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
            view.tabletSource.buttonZones = WritingLayout.scribeZones
            let numerator = UUID()
            view.insertMathSymbol(id: numerator, latex: "ab", role: .body)
            let editor = try XCTUnwrap(view.mathEditorForTesting)
            for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertTrue(editor.isReady)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            view.insertMathFraction(operandIDs: [numerator])
            view.insertMathSymbol(id: UUID(), latex: "cd", role: .body)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            view.handleTouches([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.97, y: 0.5))], timestamp: 1)
            view.handleTouches([], timestamp: 1.1)
            // Zone taps are dispatched after the touch state update.
            try await Task.sleep(for: .milliseconds(25))
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            view.insertMathSymbol(id: UUID(), latex: "+x", role: .body)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            XCTAssertEqual(editor.latex, #"\frac{ab}{cd}+x"#, "Corner advance must leave the denominator")
            XCTAssertTrue(view.isCursorLocked)

            XCTAssertTrue(view.handleWritingKey(try writingKey(36, in: window, characters: "\r")))
            for _ in 0..<80 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNil(view.mathEditorForTesting)
            XCTAssertEqual(model.textBlocks.first?.plainText, #"\frac{ab}{cd}+x"# + "\n")
            XCTAssertTrue(view.handleWritingKey(try writingKey(36, in: window, characters: "\r")))
            XCTAssertEqual(model.textBlocks.first?.plainText, #"\frac{ab}{cd}+x"# + "\n\n")
            for remaining in ["\n", ""] {
                XCTAssertTrue(view.handleWritingKey(try writingKey(51, in: window)))
                XCTAssertEqual(model.textBlocks.first?.plainText, #"\frac{ab}{cd}+x"# + remaining,
                               "Delete must remove exactly one newline without deleting the equation")
            }
            model.undoManager.undo()
            if layout == .document { view.syncDocumentBody() }
            XCTAssertEqual(model.textBlocks.first?.plainText, #"\frac{ab}{cd}+x"# + "\n")
        }
    }

    func testBackspaceInEmptyMathLineReturnsToPreviousEquation() async throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let settings = CanvasSettings()
            settings.handwritingToText = true
            settings.scribeMath = true
            let model = CanvasModel()
            model.layout = layout
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            settings.inputMode = .write
            view.renderEquationPreview = { _, _, _ in }
            view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
            func settle(_ editor: MathLiveEditorView) async throws {
                for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
                await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            }
            view.insertMathSymbol(id: UUID(), latex: "x", role: .body)
            try await settle(try XCTUnwrap(view.mathEditorForTesting))
            XCTAssertTrue(view.handleWritingKey(try writingKey(36, in: window, characters: "\r")))
            for _ in 0..<80 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
            view.insertMathSymbol(id: UUID(), latex: "y", role: .body)
            let second = try XCTUnwrap(view.mathEditorForTesting)
            try await settle(second)
            XCTAssertEqual(model.textBlocks.first?.plainText, "x\ny")
            second.navigate("delete")
            try await settle(second)
            // Focus sits in the web field, so Backspace arrives there, not at handleWritingKey.
            _ = try await second.webView.evaluateJavaScript(
                "window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Backspace', bubbles: true, cancelable: true})); 0")
            // The canvas reuses one MathLive page, so the reopened equation is the same
            // instance retargeted at `x`; wait for the field to carry that source again.
            for _ in 0..<80 where view.mathEditorForTesting?.latex != "x" { try await Task.sleep(for: .milliseconds(25)) }
            if layout == .document { view.syncDocumentBody() }
            XCTAssertEqual(model.textBlocks.first?.plainText, "x", "\(layout): Backspace on an empty line joins the previous line")
            let reopened = try XCTUnwrap(view.mathEditorForTesting, "\(layout): previous equation reopens for editing")
            XCTAssertTrue(reopened === second, "\(layout): the reopened equation reuses the page the canvas already had")
            try await settle(reopened)
            XCTAssertEqual(reopened.latex, "x")
            let focused = try await reopened.webView.evaluateJavaScript("document.getElementById('mf').hasFocus()") as? Bool
            XCTAssertEqual(focused, true, "\(layout): the reopened equation shows its caret without new input")
        }
    }

    func testMathDeleteReachesProseWrittenBeforeSwitching() async throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let settings = CanvasSettings()
            settings.handwritingToText = true
            let model = CanvasModel()
            model.layout = layout
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            settings.inputMode = .write
            view.renderEquationPreview = { _, _, _ in }
            view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
            // Math first, then prose after it, then back to math.
            settings.scribeMath = true
            view.insertMathSymbol(id: UUID(), latex: "x", role: .body)
            let editor = try XCTUnwrap(view.mathEditorForTesting)
            for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            settings.scribeMath = false
            for _ in 0..<80 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
            view.appendScribeContentForTesting(" hello world")
            settings.scribeMath = true
            try await Task.sleep(for: .milliseconds(100))
            if let reopened = view.mathEditorForTesting {
                for _ in 0..<240 where !reopened.isReady { try await Task.sleep(for: .milliseconds(25)) }
                // With focus in the web field, Backspace is handled there.
                _ = try await reopened.webView.evaluateJavaScript(
                    "window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Backspace', bubbles: true, cancelable: true})); 0")
                for _ in 0..<40 { try await Task.sleep(for: .milliseconds(25)) }
            } else {
                XCTAssertTrue(view.handleWritingKey(try writingKey(51, in: window)))
            }
            if layout == .document { view.syncDocumentBody() }
            XCTAssertEqual(model.textBlocks.first?.plainText, "x hello", "\(layout): Delete in math removes the last prose word")
        }
    }

    func testProseReturnDeleteKeepsPrivateWritingCellOnItsInputRow() throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let settings = CanvasSettings()
            settings.handwritingToText = true
            let model = CanvasModel()
            model.layout = layout
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            settings.inputMode = .write
            XCTAssertEqual(settings.effectiveInputMode, .scribe)
            view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
            view.appendScribeContentForTesting(NSAttributedString(string: "Hello"))
            let initialTop = try XCTUnwrap(view.writingCell).top
            for _ in 0..<3 { XCTAssertTrue(view.handleWritingKey(try writingKey(36, in: window, characters: "\r"))) }
            XCTAssertEqual(model.textBlocks.first?.plainText, "Hello\n\n\n")
            view.tabletSource.buttonZones = WritingLayout.scribeZones
            // A tap on the trackpad's left edge deletes like the Delete key.
            view.handleTouches([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.02, y: 0.5))], timestamp: 1)
            view.handleTouches([], timestamp: 1.1)
            for _ in 0..<20 where model.textBlocks.first?.plainText != "Hello\n\n" { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(model.textBlocks.first?.plainText, "Hello\n\n", "\(layout): left-edge tap deletes")
            for remaining in ["\n", ""] {
                XCTAssertTrue(view.handleWritingKey(try writingKey(51, in: window)))
                XCTAssertEqual(model.textBlocks.first?.plainText, "Hello" + remaining)
                XCTAssertEqual(view.writingCell?.top, initialTop,
                               "Newlines belong to the output document, not the private trackpad input row")
            }
        }
    }

    func testSingleClickOpensEquationAndOneEscapeClosesItInBothLayouts() async throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let settings = CanvasSettings()
            let model = CanvasModel()
            model.layout = layout
            let scroll = CanvasScrollView(model: model, settings: settings, layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            let canvas = scroll.canvasView
            canvas.renderEquationPreview = { _, _, _ in }
            let id = UUID()
            canvas.applyEquationSourceForTesting(#"\frac{ab}{cd}"#, id: id)
            let block = try XCTUnwrap(model.textBlocks.first)
            let textView = try XCTUnwrap(canvas.textViews[block.id])
            let rect = try XCTUnwrap(textView.rectForAttachment(at: 0))
            let point = textView.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            canvas.mouseDown(with: click)
            let editor = try XCTUnwrap(canvas.mathEditorForTesting, "A single click opens the equation")
            for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertTrue(editor.isReady)
            await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
            // The static preview keeps the equation's place until the field reports the source back.
            for _ in 0..<240 where textView.editingEquationID != id { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(textView.editingEquationID, id)
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
            canvas.keyDown(with: escape)
            for _ in 0..<80 where canvas.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNil(canvas.mathEditorForTesting, "Escape must close directly without leaving an editing layer")
            XCTAssertNil(textView.editingEquationID)
            XCTAssertTrue(window.firstResponder === canvas)
            XCTAssertEqual(model.textBlocks.first?.plainText, #"\frac{ab}{cd}"#)
        }
    }

    func testFractionCreationKeepsHandwritingCursorLockedAndRoutesTouchesToCanvas() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        settings.handwritingToText = false
        settings.scribeMath = true
        settings.inputMode = .write
        let scroll = CanvasScrollView(model: CanvasModel(), settings: settings)
        scroll.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let view = scroll.canvasView
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        view.useScribeMathForTesting()
        view.mathTidyEnabledForTesting = true
        view.renderEquationPreview = { _, _, _ in }
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = .greatestFiniteMagnitude
        XCTAssertTrue(view.isCursorLocked)

        let slash = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        XCTAssertTrue(view.handleWritingKey(slash))
        let editor = try XCTUnwrap(view.mathEditorForTesting)
        XCTAssertTrue(view.isCursorLocked, "Creating a fraction must not reveal the system pointer")
        for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady)
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        view.insertMathSymbol(id: UUID(), latex: "ab", role: .body)
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        view.navigateMathEquation("down")
        view.insertMathSymbol(id: UUID(), latex: "cd", role: .body)
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        XCTAssertEqual(editor.latex, #"\frac{ab}{cd}"#)
        XCTAssertTrue(view.isCursorLocked, "Mounting and navigating math must keep the handwriting lock")
        let overlayPoint = CGPoint(x: editor.frame.midX, y: editor.frame.midY)
        let hitTestPoint = view.convert(overlayPoint, to: view.superview)
        XCTAssertTrue(view.hitTest(hitTestPoint) === view,
                      "The locked pointer must not route trackpad contacts into WebKit")

        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(overlayPoint, to: nil), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        XCTAssertFalse(view.isCursorLocked, "An explicit equation click may release the pointer for editing")
        let mouseTarget = try XCTUnwrap(view.hitTest(hitTestPoint))
        XCTAssertTrue(mouseTarget === editor || mouseTarget.isDescendant(of: editor),
                      "Mouse editing must still hit-test the live equation after unlocking")
        view.penKeyMonitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertTrue(view.isCursorLocked, "Resuming handwriting must re-hide and re-lock the pointer")
        XCTAssertTrue(view.hitTest(hitTestPoint) === view)
        view.handleTouches([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 2)
        XCTAssertTrue(view.tabletSource.isDrawing, "Trackpad input must still begin a handwriting stroke")

        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 3, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        for _ in 0..<80 where view.mathEditorForTesting != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(view.mathEditorForTesting)
        XCTAssertFalse(view.isCursorLocked, "Escape must restore the normal system cursor")
    }

    func testRecognizedHandwritingSavesEditableEquationAndUsesOneNativeUndoStep() async throws {
        _ = NSApplication.shared
        let settings = CanvasSettings()
        settings.handwritingToText = false
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        let view = CanvasView(model: model, settings: settings)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.useScribeMathForTesting()
        view.mathTidyEnabledForTesting = true
        view.renderEquationPreview = { _, _, _ in }
        view.writingCell = LetterCell(margin: 100, top: 100, height: 32)
        view.writingRightLimit = .greatestFiniteMagnitude
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let xClass = try XCTUnwrap(vocabulary.classes.first { $0.labels == ["x"] })
        view.mathGlyphClassifier = MathGlyphClassifier(testClasses: [xClass], temperature: 1,
            decoderConfiguration: .init(lambda: 0, tauSub: 0.8, tauRev: 0.9, disabledLabels: [])) { _, _, _ in [40] }
        view.mathLineDecoderForTesting = MathLineDecoder(languageModel: try XCTUnwrap(MathLanguageModel.bundled),
                                                         lambda: 0, tauSub: 0.8, tauRev: 0.9)
        view.pendingLetter = [Stroke(points: [StrokePoint(x: 110, y: 106, t: 0),
                                             StrokePoint(x: 116, y: 116, t: 0.1)],
                                     color: RGBA(r: 0, g: 0, b: 0, a: 1), width: 2)]
        view.commitPendingLetter(follow: false)
        let editor = try XCTUnwrap(view.mathEditorForTesting)
        for _ in 0..<240 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady)
        guard editor.isReady else { return }
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
        let block = try XCTUnwrap(model.textBlocks.first)
        let equation = try XCTUnwrap(block.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? EquationAttachment)
        XCTAssertEqual(equation.latex, "x")
        XCTAssertTrue(model.strokes.isEmpty)
        model.undoManager.undo()
        // Scribe can retain its empty provisional text target after undo.
        XCTAssertTrue(model.textBlocks.allSatisfy { $0.attributedString.length == 0 })
        model.undoManager.redo()
        XCTAssertEqual(model.textBlocks.first?.plainText, "x")
        XCTAssertTrue(model.strokes.isEmpty)
        view.openEquationForTesting(equation.id)
        let reopened = try XCTUnwrap(view.mathEditorForTesting)
        for _ in 0..<240 where !reopened.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(reopened.isReady)
        guard reopened.isReady else { return }
        try await reopened.webView.evaluateJavaScript("const mf=document.getElementById('mf'); mf.position=mf.lastOffset; mf.insert('+1');")
        await withCheckedContinuation { continuation in reopened.flush { continuation.resume() } }
        XCTAssertEqual(model.textBlocks.first?.plainText, "x+1")
        model.undoManager.undo()
        XCTAssertEqual(model.textBlocks.first?.plainText, "x")
        model.undoManager.redo()
        XCTAssertEqual(model.textBlocks.first?.plainText, "x+1")
    }
}

#endif
