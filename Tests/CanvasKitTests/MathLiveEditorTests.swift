import AppKit
import PDFKit
import XCTest
@testable import CanvasKit

@MainActor final class MathLiveEditorTests: XCTestCase {
    func testBundledMathLiveLoadsOfflineEditsAndRendersPDF() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "\\frac{1}{2}", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        var loadFailure: Error?
        var handwritingChangeCount = 0
        var keyboardChangeCount = 0
        var undoCount = 0
        editor.onFailure = { loadFailure = $0 }
        editor.onUndo = { undoCount += 1 }
        editor.onChange = { _, origin in
            if origin == .handwriting { handwritingChangeCount += 1 }
            if origin == .keyboard { keyboardChangeCount += 1 }
        }
        for _ in 0..<200 where !editor.isReady && loadFailure == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(loadFailure)
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        editor.setLatex("x", fontSize: CGFloat(24))
        await flush(editor)
        let first = UUID()
        editor.applyHandwriting([MathLiveHandwritingEdit(id: first, latex: "+")])
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("x+"), editor.latex)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: first, latex: "-", replaces: [first])])
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("x-"), editor.latex)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "y")])
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("x-y"), "A revision must restore the user's later caret: \(editor.latex)")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(keyboardChangeCount, 0, "Deferred handwriting events must not invalidate recognition as keyboard edits")

        editor.setLatex("x", fontSize: CGFloat(24))
        await flush(editor)
        handwritingChangeCount = 0
        editor.applyHandwriting([
            MathLiveHandwritingEdit(id: UUID(), latex: "a", role: .superscript),
            MathLiveHandwritingEdit(id: UUID(), latex: "b", role: .superscript)
        ])
        await flush(editor)
        XCTAssertEqual(handwritingChangeCount, 1, "One recognized group emits one source update")
        XCTAssertTrue(editor.latex.contains("x^{ab}"), "Adjacent powers should share one script group: \(editor.latex)")
        editor.setLatex("x", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([
            MathLiveHandwritingEdit(id: UUID(), latex: "i", role: .subscript),
            MathLiveHandwritingEdit(id: UUID(), latex: "j", role: .subscript)
        ])
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("x_{ij}"), "Adjacent subscripts should share one script group: \(editor.latex)")

        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        let numeratorA = UUID(), numeratorB = UUID()
        editor.applyHandwriting([MathLiveHandwritingEdit(id: numeratorA, latex: "a"),
                                 MathLiveHandwritingEdit(id: numeratorB, latex: "b")])
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", isFraction: true,
                                                         operandIDs: [numeratorA, numeratorB])])
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("\\frac{ab}"), "Fraction trigger should wrap the exact recognized operand: \(editor.latex)")

        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "c"),
                                 MathLiveHandwritingEdit(id: UUID(), latex: "d")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\frac{ab}{cd}"#,
                       "The next handwriting must fill the denominator without navigating back")
        let denominatorE = UUID()
        editor.applyHandwriting([MathLiveHandwritingEdit(id: denominatorE, latex: "e")])
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", isFraction: true,
                                                         operandIDs: [denominatorE])])
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "f")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\frac{ab}{cd\frac{e}{f}}"#,
                       "Nested fractions must retain the denominator caret too")

        editor.setLatex("", fontSize: CGFloat(24))
        editor.insertFraction()
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "1")])
        await flush(editor)
        editor.navigate("down")
        await flush(editor)
        XCTAssertNil(loadFailure, "Navigation must use the current rendered atoms")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "2")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\frac12"#, "Empty fractions start in the numerator and navigate down")
        for direction in ["left", "up", "down", "right"] {
            editor.navigate(direction)
            await flush(editor)
            XCTAssertEqual(editor.latex, #"\frac12"#, "Caret navigation must not mutate source")
        }

        editor.setLatex("", fontSize: CGFloat(24))
        editor.insertFraction()
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "ab")])
        await flush(editor)
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "cd")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\frac{ab}{cd}"#, "Advance from the numerator must reach the empty denominator")
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "+x")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\frac{ab}{cd}+x"#, "Advance from the filled denominator must leave the fraction")

        editor.setLatex(#"\frac{ab}{cd}"#, fontSize: CGFloat(24))
        await flush(editor)
        editor.navigate("left")
        await flush(editor)
        _ = try await evaluate(editor, "(()=>{const tab=new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true});document.getElementById('mf').dispatchEvent(tab);})()")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "+y")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\frac{ab}{cd}+y"#, "Keyboard Tab must use the same filled-slot advance")

        editor.setLatex(#"\frac{ab}{cd}"#, fontSize: CGFloat(24))
        await flush(editor)
        let hitTestResult = try await evaluate(editor, "(()=>{const mf=document.getElementById('mf');const r=mf.getElementInfo(2).bounds;return {x:r.right,y:r.top+r.height/2};})()")
        let numeratorBounds = try XCTUnwrap(hitTestResult as? [String: Double])
        let cssPoint = CGPoint(x: try XCTUnwrap(numeratorBounds["x"]), y: try XCTUnwrap(numeratorBounds["y"]))
        let webPoint = CGPoint(x: cssPoint.x, y: editor.webView.isFlipped ? cssPoint.y : editor.webView.bounds.height - cssPoint.y)
        editor.focus(at: editor.convert(webPoint, from: editor.webView))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "z")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\frac{azb}{cd}"#, "Click coordinates must place the caret in the numerator, not at the end")
        XCTAssertNil(loadFailure)

        let highlightColor = try await evaluate(editor, "(()=>{const mf=document.getElementById('mf');mf.focus();const highlight=mf.shadowRoot.querySelector('.ML__contains-highlight');return highlight ? getComputedStyle(highlight).backgroundColor : getComputedStyle(mf).getPropertyValue('--contains-highlight-background-color').trim();})()")
        XCTAssertTrue(["transparent", "rgba(0, 0, 0, 0)"].contains(highlightColor as? String ?? ""),
                      "A collapsed caret must not gray-highlight the entire fraction")

        var finishes: [Bool] = []
        editor.onFinish = { finishes.append($0) }
        let prevented = try await evaluate(editor, "const escape=new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}); document.getElementById('mf').dispatchEvent(escape); escape.defaultPrevented")
        for _ in 0..<40 where finishes.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(prevented as? Bool, true)
        XCTAssertEqual(finishes, [false], "Escape must finish directly, even inside a nested math slot")
        editor.webView.cancelOperation(nil)
        for _ in 0..<40 where finishes.count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(finishes, [false, false], "AppKit's cancel action must also leave the math editor")

        // Exercise MathLive's actual internal caret inside a denominator and make
        // sure edit events are reported as keyboard edits to native note history.
        editor.setLatex("\\frac{ab}{c}", fontSize: CGFloat(24))
        await flush(editor)
        let keyboardResult = try await evaluate(editor, "const mf=document.getElementById('mf'); mf.executeCommand('moveToPreviousChar'); mf.insert('z',{format:'latex',selectionMode:'item',focus:true}); mf.value")
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("\\frac{ab}{cz}") || editor.latex.contains("\\frac{ab}{zc}"),
                      "Keyboard insertion should remain inside the fraction denominator: \(editor.latex); JS returned \(String(describing: keyboardResult))")
        XCTAssertGreaterThan(keyboardChangeCount, 0, "MathLive keyboard input should reach native source handling")
        editor.webView.undoManager?.undo()
        XCTAssertEqual(undoCount, 1, "The WebKit edit menu's undo manager should route to the note undo callback")

        let preview = try await render("\\frac{\\frac{a}{b}}{x^{2}_{i}}", size: 24)
        XCTAssertGreaterThan(preview.pdfData.count, 1000)
        XCTAssertGreaterThan(preview.size.width, 10)
        XCTAssertGreaterThan(preview.size.height, 10)
        XCTAssertGreaterThanOrEqual(preview.metrics.baseline, 0)
        XCTAssertLessThanOrEqual(preview.metrics.baseline, preview.size.height)
        XCTAssertNotNil(PDFDocument(data: preview.pdfData)?.page(at: 0))
        savePreview(preview, name: "nested-fraction")
        let wideSource = #"\frac{a+b+c+d+e+f+g+h}{x_i^{2}}+\alpha+\beta+\gamma"#
        let widePreview = try await render(wideSource, size: 24)
        XCTAssertGreaterThan(widePreview.size.width, 120)
        for width: CGFloat in [120, 400] {
            for zoom: CGFloat in [0.75, 2] {
                let text = NSMutableAttributedString(string: "Before ", attributes: TextFormatting.defaultAttributes)
                text.append(NSAttributedString(attachment: EquationAttachment(
                    latex: wideSource, fontSize: 24,
                    previewPDF: widePreview.pdfData, previewMetrics: widePreview.metrics)))
                text.append(NSAttributedString(string: " after", attributes: TextFormatting.defaultAttributes))
                let block = TextBlockView(blockID: UUID(), width: width * zoom, scale: zoom)
                block.setContents(text)
                let host = NSWindow(contentRect: block.frame, styleMask: .borderless, backing: .buffered, defer: false)
                host.isReleasedWhenClosed = false
                host.contentView = block
                block.layoutSubtreeIfNeeded()
                let equationRect = try XCTUnwrap(block.rectForAttachment(at: 7))
                XCTAssertLessThanOrEqual(equationRect.maxX, block.bounds.width + 1)
                let bitmap = try XCTUnwrap(block.bitmapImageRepForCachingDisplay(in: block.bounds))
                block.cacheDisplay(in: block.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/tmp/equation-width-\(Int(width))-zoom-\(zoom).png"))
                host.close()
            }
        }

        for size: Double in [13, 30] {
            let scaled = try await render("\\frac{a+b}{c_d}+\\theta", size: size)
            XCTAssertGreaterThan(scaled.size.width, 10)
            XCTAssertGreaterThan(scaled.size.height, 10)
            savePreview(scaled, name: "size-\(Int(size))")
        }
        window.close()
    }

    func testStructuresOpenTheirSlotsAndFillFromEitherSide() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        var loadFailure: Error?
        editor.onFailure = { loadFailure = $0 }
        for _ in 0..<200 where !editor.isReady && loadFailure == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(loadFailure)
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        // A drawn root spawns its bar with the caret in the radicand.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "sqrt")])
        await flush(editor)
        XCTAssertTrue(editor.latex.hasPrefix("\\sqrt"), "A root must spawn its radicand bar: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x", role: .body)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\sqrt{x}"#, "The radicand must fill from the caret: \(editor.latex)")

        // A raised symbol written in a root is its index; the radicand caret survives.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "sqrt")])
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "3", structure: "root")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\sqrt[3]{\placeholder{}}"#,
                       "The index must keep the empty radicand: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x", role: .body)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\sqrt[3]{x}"#, "The radicand must continue after the index: \(editor.latex)")

        // A filled radicand keeps its content when the index arrives.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "sqrt")])
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "2", role: .body)])
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "n", structure: "root")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\sqrt[n]{2}"#, "A filled radicand must survive the index: \(editor.latex)")

        // Rewriting the index keeps the root and its radicand.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "sqrt")])
        let indexID = UUID()
        editor.applyHandwriting([MathLiveHandwritingEdit(id: indexID, latex: "3", structure: "root")])
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x", role: .body)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\sqrt[3]{x}"#, "The index and radicand must both land: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: indexID, latex: "n", replaces: [indexID])])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\sqrt[n]{x}"#, "Revising the index must keep the radicand: \(editor.latex)")

        // Outside a root the same edit stays an ordinary superscript.
        editor.setLatex("x", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "3", structure: "root")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"x^3"#, "A raised symbol outside a root is a power: \(editor.latex)")

        // A summation opens with empty limits; lower then upper fill on the operator.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "sum")])
        await flush(editor)
        XCTAssertTrue(editor.latex.hasPrefix("\\sum\\limits"), "A summation must force its limits over and under: \(editor.latex)")
        for symbol in ["i", "=", "1"] {
            editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: symbol, role: .subscript)])
        }
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("\\sum\\limits_{i=1}"), "Adjacent limit symbols must share one slot: \(editor.latex)")
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "n", role: .superscript)])
        await flush(editor)
        XCTAssertTrue(editor.latex.contains("^{n}"), "Advancing from the lower slot must reach the upper one: \(editor.latex)")
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x", role: .body)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\sum\limits_{i=1}^{n}x"#,
                       "Advancing past the upper slot must reach the body: \(editor.latex)")

        // An integral is adjacent by default; our structure forces over/under too.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "int")])
        await flush(editor)
        XCTAssertTrue(editor.latex.hasPrefix("\\int\\limits"), "An integral must force its limits over and under: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "0", role: .subscript)])
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "1", role: .superscript)])
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "f", role: .body)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\int\limits_0^1f"#, "Integral bounds must sit above and below: \(editor.latex)")

        // A limit opens with its condition below the operator: a variable slot,
        // the arrow it approaches through, and the value slot.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "lim")])
        await flush(editor)
        XCTAssertTrue(editor.latex.hasPrefix("\\lim_{"), "A limit must render its condition below it: \(editor.latex)")
        XCTAssertTrue(editor.latex.contains("\\to"), "The limit must already name the approach arrow: \(editor.latex)")
        // Writing the variable and then the arrow fills the variable slot; the
        // hand-written arrow types over the template's arrow into the value slot.
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x", role: .subscript)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\lim_{x\to\placeholder{}}"#,
                       "The variable must fill the first slot after the arrow: \(editor.latex)")
        for symbol in ["\\to", "\\infty"] {
            editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: symbol, role: .subscript)])
        }
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\lim_{x\to\infty}"#, "The limit condition must fill below lim: \(editor.latex)")
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "f", role: .body)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\lim_{x\to\infty}f"#, "Advancing from the limit must reach the argument: \(editor.latex)")

        // Advancing from the variable reaches the approached-value slot without an arrow.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "lim")])
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "n", role: .subscript)])
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "0", role: .subscript)])
        editor.navigate("advance")
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "a", role: .body)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\lim_{n\to0}a"#, "Advancing must walk variable, value, then body: \(editor.latex)")

        // A subscript followed by a raised symbol reaches the other slot, never nests.
        editor.setLatex("x", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "a", role: .subscript)])
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "b", role: .superscript)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"x_{a}^{b}"#, "A raised symbol must leave the subscript first: \(editor.latex)")
        XCTAssertNil(loadFailure)
    }

    func testEmptySlotShowsACaretNotABlinkingSelectionBox() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "sqrt")])
        await flush(editor)
        let result = try await evaluate(editor, """
        (()=>{const mf=document.getElementById('mf');const sel=mf.shadowRoot.querySelector('.ML__selection');
        if(!sel)return null;const box=getComputedStyle(sel);const caret=getComputedStyle(sel,'::after');
        const container=getComputedStyle(mf.shadowRoot.querySelector('.ML__container'));
        return {cls:mf.className,background:box.backgroundColor,animation:box.animationName,
        caretAnimation:caret.animationName,caretColor:caret.backgroundColor,caretWidth:caret.width,
        placeholderColor:container.getPropertyValue('--_selection-color').trim()};})()
        """)
        let style = try XCTUnwrap(result as? [String: String])
        XCTAssertEqual(style["cls"], "ml-slot-caret", "An empty slot must be flagged for the caret style")
        XCTAssertEqual(style["background"], "rgba(0, 0, 0, 0)",
                       "A focused empty slot must not paint its selection box")
        XCTAssertEqual(style["animation"], "none",
                       "The whole slot box must never blink; only the caret should")
        XCTAssertEqual(style["placeholderColor"], "#bdbdbd",
                       "The fill-in box must stay light gray, not white")
        XCTAssertEqual(style["caretAnimation"], "ML__caret-blink",
                       "The slot must reuse MathLive's standard blinking caret")
        XCTAssertNotEqual(style["caretWidth"], "0px", "The slot caret must be visible")
        XCTAssertFalse(["transparent", "rgba(0, 0, 0, 0)"].contains(style["caretColor"] ?? ""),
                       "The slot caret must use the accent caret color")
    }

    /// MathLive can paint two carets for one selection: an operator with side scripts
    /// (`\int_0^1`) puts one caret in its group and one in the base, and a click could leave
    /// the native caret standing beside the slot caret. The re-rendered pair also blinks out
    /// of step, so at most one *visible* caret may ever stand on the field. While the slot bar
    /// is the caret, MathLive's own carets stay in the DOM but hidden: removing them from the
    /// render that just added them left the stale one standing.
    func testFieldNeverPaintsMoreThanOneCaret() async throws {
        _ = NSApplication.shared
        let (editor, window) = try await mountedEditor()
        defer { window.close() }

        func caretCount() async throws -> (Int, String) {
            let json = try await editor.webView.evaluateJavaScript("""
              (function(){
                const mf=document.getElementById('mf'); const root=mf.shadowRoot;
                // The bar is the caret's `::after`; the element itself always paints nothing.
                const carets=[...root.querySelectorAll('.ML__caret,.ML__text-caret,.ML__latex-caret')];
                const visible=carets.filter(caret=>getComputedStyle(caret,'::after').visibility!=='hidden').length;
                const bars=[...root.querySelectorAll('.ML__selection')].filter(selection=>
                  mf.classList.contains('ml-slot-caret') && getComputedStyle(selection,'::after').width!=='0px').length;
                return JSON.stringify({carets:visible, hidden:carets.length-visible, bars, pos:mf.position, last:mf.lastOffset, value:mf.value});
              })()
            """) as? String ?? "nil"
            guard let data = json.data(using: .utf8),
                  let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (-1, json) }
            return ((state["carets"] as? Int ?? 0) + (state["bars"] as? Int ?? 0), json)
        }

        let sources = [#"\int_0^1"#, #"\int_{}^{}"#, #"\oint_0^1"#, "x^{2}+y",
                       #"\sqrt{x}+x^{2}"#, #"\frac{a}{b}"#, #"\lim_{x\to0}"#, "x_{a}^{b}"]
        for source in sources {
            editor.setLatex(source, fontSize: CGFloat(24))
            try await Task.sleep(for: .milliseconds(60))
            let last = try await editor.webView.evaluateJavaScript("document.getElementById('mf').lastOffset") as? Int ?? 0
            for position in 0...last {
                _ = try await editor.webView.evaluateJavaScript("document.getElementById('mf').position = \(position)")
                try await Task.sleep(for: .milliseconds(60))
                let (total, json) = try await caretCount()
                XCTAssertLessThanOrEqual(total, 1, "\(source) at \(position) must paint one caret: \(json)")
            }
            for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
                _ = try await editor.webView.evaluateJavaScript("""
                  (function(){const box=document.getElementById('mf').getBoundingClientRect();
                    window.mathLive.focusAt(box.left+box.width*\(fraction), box.top+box.height*0.3);})()
                """)
                try await Task.sleep(for: .milliseconds(60))
                let (total, json) = try await caretCount()
                XCTAssertLessThanOrEqual(total, 1, "\(source) click at \(fraction) must paint one caret: \(json)")
            }
        }

        // The app's own path: a written integral, then its limits.
        editor.setLatex("", fontSize: CGFloat(24))
        try await Task.sleep(for: .milliseconds(60))
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "int")])
        try await Task.sleep(for: .milliseconds(80))
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "0", role: .subscript)])
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "1", role: .superscript)])
        try await Task.sleep(for: .milliseconds(120))
        let (total, json) = try await caretCount()
        XCTAssertLessThanOrEqual(total, 1, "The written integral must paint one caret: \(json)")
    }

    func testDeletingStructuresRemovesThemCleanlyWithoutLeftovers() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        func backspace(_ count: Int) async {
            for _ in 0..<count {
                _ = try? await editor.webView.evaluateJavaScript(
                    "document.getElementById('mf').dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true}))")
                await flush(editor)
            }
        }

        // A root: the radicand goes first, then the radical itself.
        editor.setLatex(#"\sqrt{x}"#, fontSize: CGFloat(24))
        await flush(editor)
        await backspace(1)
        XCTAssertEqual(editor.latex, #"\sqrt{}"#, "Backspace must delete the radicand in one press")
        await backspace(1)
        XCTAssertEqual(editor.latex, "", "The emptied radical must delete on the next press")

        // A big operator is one unit: the first press selects it whole, limits included, and
        // the next press takes it.
        var ranges: [[Int]] = []
        editor.onSelectionChange = { ranges = $0 }
        editor.setLatex(#"\int\limits_0^1"#, fontSize: CGFloat(24))
        await flush(editor)
        await backspace(1)
        XCTAssertEqual(editor.latex, #"\int\limits_0^1"#,
                       "A filled operator must be selected first, not emptied one slot at a time")
        XCTAssertEqual(ranges.first?.count, 2, "The first press must put a selection up: \(ranges)")
        XCTAssertGreaterThan((ranges.first?[1] ?? 0) - (ranges.first?[0] ?? 0), 1,
                             "The whole operator must be selected: \(ranges)")
        await backspace(1)
        XCTAssertEqual(editor.latex, "", "The next press must take the selected operator")

        // A summation and a limit likewise.
        for source in [#"\sum\limits_{i=1}^{n}"#, #"\lim_{x\to0}"#] {
            editor.setLatex(source, fontSize: CGFloat(24))
            await flush(editor)
            await backspace(2)
            XCTAssertEqual(editor.latex, "", "\(source) must delete without leftovers")
        }

        // A multi-symbol expression deletes one symbol at a time.
        editor.setLatex("x+y", fontSize: CGFloat(24))
        await flush(editor)
        await backspace(1)
        XCTAssertEqual(editor.latex, "x+", "A plain expression must delete its last symbol immediately")
        await backspace(2)
        XCTAssertEqual(editor.latex, "", "The remaining symbols must delete one at a time")

        // The routed navigation delete (Scribe mode) takes the same two presses.
        editor.setLatex(#"\int\limits_0^1"#, fontSize: CGFloat(24))
        await flush(editor)
        for _ in 0..<2 { editor.navigate("delete"); await flush(editor) }
        XCTAssertEqual(editor.latex, "", "The routed Delete must clear the integral too")
    }

    /// Deleting an integral used to walk into its limits one symbol at a time and then skip
    /// the atom itself: once the limits were empty the caret parked in front of the operator,
    /// where Backspace ate the symbol before it instead. An emptied operator has to go in one
    /// press, wherever it stands on the line.
    func testAnEmptiedOperatorDeletesInsteadOfTheSymbolBeforeIt() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        func backspace(_ count: Int) async {
            for _ in 0..<count {
                _ = try? await editor.webView.evaluateJavaScript(
                    "document.getElementById('mf').dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',bubbles:true,cancelable:true}))")
                await flush(editor)
            }
        }

        // The exact bug: a '+' before an emptied integral stayed put and the operator was skipped.
        editor.setLatex(#"x+\int\limits"#, fontSize: CGFloat(24))
        await flush(editor)
        await backspace(1)
        XCTAssertEqual(editor.latex, "x+", "Backspace must take the emptied integral, not the '+'")

        // A structure that never held anything goes the same way, from inside its own slot.
        editor.setLatex(#"x+\int\limits_{}^{}"#, fontSize: CGFloat(24))
        await flush(editor)
        await backspace(1)
        XCTAssertEqual(editor.latex, "x+", "An empty operator's slots must not shield the atom")

        // The routed navigation delete (Scribe mode) reaches it too.
        editor.setLatex(#"x+\sum\limits"#, fontSize: CGFloat(24))
        await flush(editor)
        editor.navigate("delete")
        await flush(editor)
        XCTAssertEqual(editor.latex, "x+", "The routed Delete must take the emptied summation")

        // Walking a whole expression back never skips a filled operator in the middle: select,
        // then delete, then the symbols in front of it.
        editor.setLatex(#"x+\int\limits_0^1"#, fontSize: CGFloat(24))
        await flush(editor)
        await backspace(4)
        XCTAssertEqual(editor.latex, "", "A finished integral must delete without being skipped: \(editor.latex)")

        // A caret inside a limit still edits the limit rather than taking the operator.
        editor.setLatex(#"x+\int\limits_0^1"#, fontSize: CGFloat(24))
        await flush(editor)
        _ = try await evaluate(editor, "document.getElementById('mf').position = 4")
        await backspace(1)
        XCTAssertEqual(editor.latex, #"x+\int\limits_{}^1"#, "A caret in a limit must edit the limit")

        // The space key types a real space in manually edited math; the trackpad arrow only
        // spaces at the end of the line and otherwise moves the caret.
        editor.setLatex("xy", fontSize: CGFloat(24))
        await flush(editor)
        _ = try await evaluate(editor, "document.getElementById('mf').position = 1")
        _ = try await evaluate(editor, "document.getElementById('mf').dispatchEvent(new KeyboardEvent('keydown',{key:' ',bubbles:true,cancelable:true}))")
        await flush(editor)
        XCTAssertEqual(editor.latex, #"x\ y"#, "Space must insert a space while editing: \(editor.latex)")
        editor.setLatex("xy", fontSize: CGFloat(24))
        await flush(editor)
        _ = try await evaluate(editor, "document.getElementById('mf').position = 1")
        editor.insertMathSpace(fallbackAdvance: true) { _ in }
        await flush(editor)
        XCTAssertEqual(editor.latex, "xy", "The arrow must navigate, not space, with content to its right")

        // A freshly spawned integral has its empty lower slot focused; Delete removes it whole.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "int")])
        await flush(editor)
        editor.navigate("delete")
        await flush(editor)
        XCTAssertEqual(editor.latex, "", "Delete right after spawning an integral must remove it: \(editor.latex)")
    }

    /// The host swaps its static preview for the live field only once the field reports the
    /// source it applied — otherwise the swap showed the previously edited equation for a
    /// frame — and needs to know where the math sits inside the field's box to put it exactly
    /// where that preview drew it.
    func testFieldReportsTheSourceItLaidOutAndWhereTheMathSits() async throws {
        _ = NSApplication.shared
        let (editor, window) = try await mountedEditor()
        defer { window.close() }

        var laidOut: String?
        editor.onLayoutApplied = { laidOut = $0 }
        editor.setLatex(#"\frac{a}{b}"#, fontSize: CGFloat(24))
        for _ in 0..<240 where laidOut != #"\frac{a}{b}"# { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(laidOut, #"\frac{a}{b}"#, "The field must report the source it holds")
        XCTAssertEqual(editor.contentInsets.x, 5, accuracy: 1.5,
                       "The math starts after the field's own left chrome: \(editor.contentInsets)")
        XCTAssertEqual(editor.contentInsets.y, 6, accuracy: 1.5,
                       "The math starts after the field's own top chrome: \(editor.contentInsets)")

        // A later layout keeps them, so every swap has numbers to line up with.
        editor.setLatex(#"\sqrt{x}+y"#, fontSize: CGFloat(24))
        await flush(editor)
        XCTAssertGreaterThan(editor.contentInsets.x, 0, "A later layout must keep the content inset")
    }

    /// The accent fill and its white text belong to a real selection. MathLive also boxes up a
    /// focused slot and can leave a selection box standing after a re-render, and painting those
    /// with the selection color drew the glyph inside white on white — the top half of a lone
    /// integral. Only `.ml-selecting` gets the accent.
    func testOnlyARealSelectionGetsTheAccentHighlight() async throws {
        _ = NSApplication.shared
        let (editor, window) = try await mountedEditor()
        defer { window.close() }

        editor.setLatex("x+y", fontSize: CGFloat(24))
        await flush(editor)
        _ = try await evaluate(editor, "document.getElementById('mf').position = 1")
        await flush(editor)
        let collapsed = try await evaluate(editor, "document.getElementById('mf').className") as? String ?? ""
        XCTAssertFalse(collapsed.contains("ml-selecting"), "A collapsed caret is not a selection: \(collapsed)")

        // A real range flags the host, the way a native ⌘A selection of the equation arrives.
        _ = try await evaluate(editor, "window.mathLive.setSelection([[0, 3]])")
        await flush(editor)
        let range = try await evaluate(editor, "document.getElementById('mf').className") as? String ?? ""
        XCTAssertTrue(range.contains("ml-selecting"), "A real selection must flag the host: \(range)")

        // A selection box MathLive paints for a focused slot is the stand-in here: it is the
        // state that drew white glyphs, and the field has to keep it unfilled when the flag is
        // not up. The same box shows what the flag buys.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "sqrt")])
        await flush(editor)
        let probe = try await evaluate(editor, """
        (function(){
          const mf=document.getElementById('mf');
          const selection=mf.shadowRoot.querySelector('.ML__selection');
          if(!selection) return JSON.stringify({none:mf.className});
          const styles=()=>({cls:mf.className, background:getComputedStyle(selection).backgroundColor,
                             color:getComputedStyle(selection).color});
          mf.classList.remove('ml-slot-caret');
          const stale=styles();
          mf.classList.add('ml-selecting');
          const real=styles();
          mf.classList.remove('ml-selecting');
          mf.classList.add('ml-slot-caret');
          return JSON.stringify({stale, real});
        })()
        """) as? String
        let data = try XCTUnwrap(probe?.data(using: .utf8), "The field must report its chrome")
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(probe ?? "nil")")
        XCTAssertNil(parsed["none"], "A focused slot must paint a selection box: \(probe ?? "nil")")
        let real = try XCTUnwrap(parsed["real"] as? [String: String]), stale = try XCTUnwrap(parsed["stale"] as? [String: String])
        XCTAssertTrue(real["cls"]?.contains("ml-selecting") == true, "The flag must be up while probed: \(real)")
        XCTAssertNotEqual(real["background"], "rgba(0, 0, 0, 0)", "A real selection must fill its box: \(real)")
        XCTAssertEqual(stale["background"], "rgba(0, 0, 0, 0)",
                       "A selection box left standing must not fill anything: \(stale)")
        XCTAssertNotEqual(stale["color"], "rgb(255, 255, 255)",
                          "An unfilled box must keep the text color, never draw it white: \(stale)")
    }

    private func flush(_ editor: MathLiveEditorView) async {
        await withCheckedContinuation { continuation in editor.flush { continuation.resume() } }
    }

    func testAbsoluteValueBarPairsWithItsCloser() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        // A recognized bar opens the pair with its closer already in place.
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "|")], autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "||", "An absolute bar must bring its closing bar: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x")], autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "|x|", "Ink between the bars must stay inside them: \(editor.latex)")

        // The hand-written closing bar types over the auto one instead of doubling it.
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "|")], autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "|x|", "A written closing bar must type over the auto one: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "+")], autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "|x|+", "The caret must leave the pair once it is closed: \(editor.latex)")

        // A closer first read as a digit, then corrected, absorbs the auto bar.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "|")], autoCloseBrackets: true)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x")], autoCloseBrackets: true)
        let closing = UUID()
        editor.applyHandwriting([MathLiveHandwritingEdit(id: closing, latex: "1")], autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "|x1|", "Uncorrected ink must stay between the bars: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: closing, latex: "|", replaces: [closing])],
                                autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "|x|", "The corrected closer must replace the auto bar: \(editor.latex)")

        // A correction that turns the last digit into the bar opens the pair too.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        let digit = UUID()
        editor.applyHandwriting([MathLiveHandwritingEdit(id: digit, latex: "1")], autoCloseBrackets: true)
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: digit, latex: "|", replaces: [digit])],
                                autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "||", "A corrected absolute bar must bring its closer: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "y")], autoCloseBrackets: true)
        await flush(editor)
        XCTAssertEqual(editor.latex, "|y|", "The corrected pair must hold the next symbol: \(editor.latex)")

        // With auto-close off the same bar stays a lone delimiter.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "|")], autoCloseBrackets: false)
        await flush(editor)
        XCTAssertEqual(editor.latex, "|", "Auto-close off must leave the lone bar: \(editor.latex)")
    }

    func testLimitConditionWrittenBeforeTheStructureFoldsIntoIt() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        // A fast writer's condition ink reaches the editor before the operator
        // replacement lands; it must fold into the limit instead of dangling after it.
        let run = [UUID(), UUID(), UUID()]
        editor.applyHandwriting([MathLiveHandwritingEdit(id: run[0], latex: "l"),
                                 MathLiveHandwritingEdit(id: run[1], latex: "i"),
                                 MathLiveHandwritingEdit(id: run[2], latex: "m")])
        await flush(editor)
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x", role: .subscript)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"lim_{x}"#, "The condition must sit below the run: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: run[0], latex: "", replaces: run, structure: "lim")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\lim_{x\to\placeholder{}}"#,
                       "The written condition must become the limit's variable: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "0", role: .inherit)])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\lim_{x\to0}"#, "The value must land past the template's arrow: \(editor.latex)")

        // A whole condition already written below the run fills both slots.
        editor.setLatex("", fontSize: CGFloat(24))
        await flush(editor)
        let run2 = [UUID(), UUID(), UUID()]
        editor.applyHandwriting([MathLiveHandwritingEdit(id: run2[0], latex: "l"),
                                 MathLiveHandwritingEdit(id: run2[1], latex: "i"),
                                 MathLiveHandwritingEdit(id: run2[2], latex: "m")])
        await flush(editor)
        for symbol in ["n", "\\to", "\\infty"] {
            editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: symbol, role: .subscript)])
        }
        await flush(editor)
        XCTAssertEqual(editor.latex, #"lim_{n\to\infty}"#, "The whole condition must sit below the run: \(editor.latex)")
        editor.applyHandwriting([MathLiveHandwritingEdit(id: run2[0], latex: "", replaces: run2, structure: "lim")])
        await flush(editor)
        XCTAssertEqual(editor.latex, #"\lim_{n\to\infty}"#,
                       "A complete written condition must fill both limit slots: \(editor.latex)")
    }

    func testLimitValueWithoutAnArrowFillsItsSlot() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        for role in [MathScript.Role.subscript, MathScript.Role.inherit] {
            editor.setLatex("", fontSize: CGFloat(24))
            await flush(editor)
            editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "", structure: "lim")])
            await flush(editor)
            editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "x", role: .subscript)])
            await flush(editor)
            editor.applyHandwriting([MathLiveHandwritingEdit(id: UUID(), latex: "0", role: role)])
            await flush(editor)
            XCTAssertEqual(editor.latex, #"\lim_{x\to0}"#,
                           "A value written without an arrow must fill the slot past it: \(editor.latex)")
        }
    }

    func testRightArrowActionCreatesASpaceAndNavigatesInsideStructures() async throws {
        _ = NSApplication.shared
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")

        func insertSpace(_ fallback: String) async throws -> Bool {
            let value = try await evaluate(editor, "window.mathLive.insertSpace('\(fallback)')")
            await flush(editor)
            return (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
        }
        func setLatex(_ source: String, caretAt position: Int? = nil) async throws {
            editor.setLatex(source, fontSize: CGFloat(24))
            await flush(editor)
            if let position {
                _ = try await evaluate(editor, "document.getElementById('mf').position = \(position)")
                await flush(editor)
            }
        }

        // At the top level the action inserts a real space into the source.
        try await setLatex("x")
        let spaced = try await insertSpace("advance")
        XCTAssertTrue(spaced, "A top-level action must be reported as a space")
        XCTAssertEqual(editor.latex, #"x\ "#, "A top-level action must insert a space: \(editor.latex)")

        // Once a structure is closed the caret is back at the top level.
        try await setLatex("(x)", caretAt: 3)
        let trailed = try await insertSpace("advance")
        XCTAssertTrue(trailed, "Past a closed group the action must still space")
        XCTAssertEqual(editor.latex, #"(x)\ "#, "A space must land after the group: \(editor.latex)")

        // Past a closed structure the caret is back at the top level and spaces again.
        for source in ["x^{2}", "\\frac{a}{b}"] {
            editor.setLatex(source, fontSize: CGFloat(24))
            await flush(editor)
            let measured = try await evaluate(editor, "document.getElementById('mf').lastOffset")
            let lastOffset = try XCTUnwrap(measured as? NSNumber).intValue
            _ = try await evaluate(editor, "document.getElementById('mf').position = \(lastOffset)")
            await flush(editor)
            let spaced = try await insertSpace("advance")
            XCTAssertTrue(spaced, "Past \(source) the caret is top level and must space")
            XCTAssertTrue(editor.latex.hasSuffix(#"\ "#), "A space must land after \(source): \(editor.latex)")
        }

        // Inside a structure the caret navigates instead and the source is untouched.
        for (source, position) in [("\\frac{a}{b}", 2), ("(x)", 1), ("x^{2}", 2)] {
            try await setLatex(source, caretAt: position)
            let navigated = try await insertSpace("advance")
            XCTAssertFalse(navigated, "Inside \(source) the action must navigate, not space")
            XCTAssertEqual(editor.latex, source, "Navigation must not mutate the source: \(editor.latex)")
        }

        // An empty field has nothing to separate.
        try await setLatex("")
        let empty = try await insertSpace("advance")
        XCTAssertFalse(empty, "An empty field must not leave a leading space")
    }

    private func evaluate(_ editor: MathLiveEditorView, _ javascript: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            editor.webView.evaluateJavaScript(javascript) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    /// Opening an equation must not squish it: the host measures the room left on the line
    /// and sets it before the first layout, and until then the field has no width to shrink
    /// into. Fitting to the provisional frame scaled the whole expression down and snapped
    /// it back the moment the real width arrived.
    func testFieldIsNeverScaledDownBeforeTheHostSetsTheAvailableWidth() async throws {
        _ = NSApplication.shared
        let (editor, window) = try await mountedEditor()
        defer { window.close() }
        let source = #"\frac{abcdef+ghijkl}{mnopqr+stuvwx}+\sqrt{yz}"#

        _ = try await evaluate(editor, "window.mathLive.setMaxWidth(null); window.mathLive.setLatex('\(source)', 24); 0")
        await flush(editor)
        try await Task.sleep(for: .milliseconds(150))
        let unscaled = try await evaluate(editor, "document.getElementById('mf').style.transform") as? String
        XCTAssertEqual(unscaled, "none", "An unknown available width must not shrink the field")

        // The fit still applies once the host says how much room there is.
        let narrow = try await evaluate(editor, """
            window.mathLive.setMaxWidth(40);
            document.getElementById('mf').style.transform;
            """) as? String
        XCTAssertNotEqual(narrow, "none", "A width that really is too small must still fit: \(narrow ?? "nil")")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThan(editor.contentScale, 1, "The reported scale must follow the fit: \(editor.contentScale)")
    }

    /// A click in the whitespace between two symbols used to leave the caret where it was,
    /// so placing the caret seemed to work only directly on a glyph.
    func testClickAnywhereInTheFieldPlacesTheCaret() async throws {
        _ = NSApplication.shared
        let (editor, window) = try await mountedEditor()
        defer { window.close() }
        editor.setLatex("x+1", fontSize: CGFloat(24))
        await flush(editor)
        let probe = try await evaluate(editor, """
            (function(){ const mf = document.getElementById('mf');
              const box = mf.getBoundingClientRect();
              const y = box.top + box.height / 2;
              let gap = null;
              for (let x = box.left + box.width * 0.35; x < box.right - 1; x += 0.5) {
                if (mf.getOffsetFromPoint(x, y) < 0) { gap = x; break; }
              }
              if (gap === null) return JSON.stringify({gap: null});
              mf.position = 0;
              window.mathLive.focusAt(gap, y);
              return JSON.stringify({gap, raw: mf.getOffsetFromPoint(gap, y), after: mf.position, last: mf.lastOffset});
            })()
            """) as? String
        let data = try XCTUnwrap(probe?.data(using: .utf8))
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(result["gap"], "The field must have whitespace between symbols: \(probe ?? "nil")")
        XCTAssertEqual(result["raw"] as? Int, -1, "MathLive alone must not resolve a gap: \(probe ?? "nil")")
        XCTAssertGreaterThan(result["after"] as? Int ?? 0, 0, "A click in the gap must still place the caret: \(probe ?? "nil")")
    }

    private func mountedEditor() async throws -> (MathLiveEditorView, NSWindow) {
        let editor = MathLiveEditorView(latex: "", fontSize: CGFloat(24))
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor)
        window.orderFront(nil)
        for _ in 0..<200 where !editor.isReady { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(editor.isReady, "Bundled MathLive should mount from local resources")
        return (editor, window)
    }

    func testSelectedEquationShowsSelectionHighlight() async throws {
        _ = NSApplication.shared
        let preview = try await render(#"\frac{a}{b}"#, size: 24)
        let text = NSMutableAttributedString(string: "Hi ", attributes: TextFormatting.defaultAttributes)
        text.append(NSAttributedString(attachment: EquationAttachment(
            latex: #"\frac{a}{b}"#, fontSize: 24, previewPDF: preview.pdfData, previewMetrics: preview.metrics)))
        let block = TextBlockView(blockID: UUID(), width: 300)
        block.setContents(text)
        let host = NSWindow(contentRect: block.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = block
        defer { host.close() }
        block.layoutSubtreeIfNeeded()
        let rect = try XCTUnwrap(block.rectForAttachment(at: 3))
        func averageColor() throws -> (r: Double, g: Double, b: Double) {
            let bitmap = try XCTUnwrap(block.bitmapImageRepForCachingDisplay(in: block.bounds))
            block.cacheDisplay(in: block.bounds, to: bitmap)
            var sum = (0.0, 0.0, 0.0), n = 0.0
            for x in stride(from: Int(rect.minX) + 1, to: Int(rect.maxX) - 1, by: 1) {
                for y in stride(from: Int(rect.minY) + 1, to: Int(rect.maxY) - 1, by: 1) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    sum.0 += c.redComponent * c.alphaComponent; sum.1 += c.greenComponent * c.alphaComponent
                    sum.2 += c.blueComponent * c.alphaComponent; n += 1
                }
            }
            return (sum.0 / n, sum.1 / n, sum.2 / n)
        }
        let before = try averageColor()
        block.textView.setSelectedRange(NSRange(location: 0, length: text.length))
        let after = try averageColor()
        let change = abs(before.r - after.r) + abs(before.g - after.g) + abs(before.b - after.b)
        XCTAssertGreaterThan(change, 0.05, "Selecting an equation must visibly highlight it: \(before) -> \(after)")
    }

    func testEquationPreviewKeepsATransparentBackground() async throws {
        let preview = try await render(#"\frac{a}{b}"#, size: 24)
        let provider = try XCTUnwrap(CGDataProvider(data: preview.pdfData as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let scale = min(1, 64 / max(box.width, box.height, 1))
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        // A transparent page leaves the clear context untouched at the padding corners;
        // an opaque page would have painted them white.
        let cornerAlpha = pixels[((height - 1) * width) * 4 + 3]
        XCTAssertEqual(cornerAlpha, 0,
                       "A selected equation must show the highlight, not a white box (corner alpha \(cornerAlpha))")
    }

    private func render(_ latex: String, size: Double) async throws -> MathLiveRenderedPreview {
        try await withCheckedThrowingContinuation { continuation in
            MathLivePreviewRenderer.shared.render(latex: latex, fontSize: size) { continuation.resume(with: $0) }
        }
    }

    private func savePreview(_ preview: MathLiveRenderedPreview, name: String) {
        let document = PDFDocument(data: preview.pdfData)
        guard let page = document?.page(at: 0),
              let tiff = page.thumbnail(of: NSSize(width: 900, height: 300), for: .mediaBox).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "/tmp/mathlive-\(name).png"))
        try? preview.pdfData.write(to: URL(fileURLWithPath: "/tmp/mathlive-\(name).pdf"))
    }
}
