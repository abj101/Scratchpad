import AppKit
import XCTest
@testable import CanvasKit

final class DrawingZoneIntegrationTests: XCTestCase {
    private let sentence = "The quick brown fox jumps over the lazy dog while the rain keeps falling on the roof. "

    private func makeCanvas(width: CGFloat = 520) -> CanvasView {
        let canvas = CanvasView(model: CanvasModel(layout: .document), settings: CanvasSettings(), layout: .document)
        canvas.setFrameSize(NSSize(width: width, height: 900))
        canvas.documentViewportDidChange()
        return canvas
    }

    private func type(_ text: String, in canvas: CanvasView, at location: Int? = nil) throws {
        let body = try XCTUnwrap(canvas.documentBodyView)
        let at = location ?? body.textStorage.length
        body.textView.setSelectedRange(NSRange(location: at, length: 0))
        body.textView.insertText(text, replacementRange: body.textView.selectedRange())
    }

    private func stroke(_ x: Double, _ y: Double, _ x2: Double, _ y2: Double) -> Stroke {
        Stroke(points: [StrokePoint(x: x, y: y, t: 0), StrokePoint(x: x2, y: y2, t: 1)], color: .black, width: 2)
    }

    private func zone(of stroke: Stroke, in canvas: CanvasView) throws -> DrawingZone {
        try XCTUnwrap(canvas.model.drawingZones?.first { $0.strokeIDs.contains(stroke.id) })
    }

    private func current(_ stroke: Stroke, in canvas: CanvasView) throws -> Stroke {
        try XCTUnwrap(canvas.model.strokes.first { $0.id == stroke.id })
    }

    func testStrokeDrawnOverTextLeavesNoLineIntersectingItsZone() throws {
        let canvas = makeCanvas()
        try type(String(repeating: sentence, count: 6), in: canvas)
        let body = try XCTUnwrap(canvas.documentBodyView)
        let y = DocumentLayout.topInset + 24
        let ink = stroke(120, y, 260, y + 50)
        canvas.model.add(ink)

        let rect = try zone(of: ink, in: canvas).rect
        XCTAssertEqual(rect, ink.bounds.insetBy(dx: -8, dy: -8))
        let fragments = DocumentTextLayout(body: body).lineFragmentUsedRects()
        XCTAssertFalse(fragments.isEmpty)
        XCTAssertTrue(fragments.allSatisfy { !$0.intersects(rect) }, "text must not sit under the ink")
    }

    func testNarrowDrawingAtTheRightMarginShortensTheLinesBesideIt() throws {
        let canvas = makeCanvas()
        try type(String(repeating: sentence, count: 6), in: canvas)
        let body = try XCTUnwrap(canvas.documentBodyView)
        let y = DocumentLayout.topInset + 24
        let ink = stroke(420, y, 456, y + 50)
        canvas.model.add(ink)

        let rect = try zone(of: ink, in: canvas).rect
        let fragments = DocumentTextLayout(body: body).lineFragmentUsedRects()
        let beside = fragments.filter { $0.maxY > rect.minY && $0.minY < rect.maxY }
        let elsewhere = fragments.filter { $0.minY >= rect.maxY }
        XCTAssertFalse(beside.isEmpty)
        XCTAssertTrue(beside.allSatisfy { $0.maxX <= rect.minX + 0.5 }, "no sliver of text to the right of the drawing")
        let besideWidth = beside.map(\.width).max() ?? 0
        let elsewhereWidth = elsewhere.map(\.width).max() ?? 0
        XCTAssertLessThan(besideWidth, elsewhereWidth - 20)
        XCTAssertGreaterThan(besideWidth, 100, "text still flows on the open side")
    }

    func testDrawingInTheMiddleSendsTextBelowInsteadOfIntoSlivers() throws {
        let canvas = makeCanvas(width: 400) // column 344 wide
        try type(String(repeating: sentence, count: 6), in: canvas)
        let body = try XCTUnwrap(canvas.documentBodyView)
        let y = DocumentLayout.topInset + 24
        let ink = stroke(80, y, 330, y + 50) // leaves under 96 pt on both sides
        canvas.model.add(ink)

        let rect = try zone(of: ink, in: canvas).rect
        let fragments = DocumentTextLayout(body: body).lineFragmentUsedRects()
        XCTAssertTrue(fragments.allSatisfy { !$0.intersects(rect) })
        XCTAssertTrue(fragments.filter { $0.maxY > rect.minY && $0.minY < rect.maxY }.isEmpty,
                      "no text beside a zone with only slivers on both sides")
    }

    func testTypingAParagraphAboveMovesTheZoneAndItsStrokesDown() throws {
        let canvas = makeCanvas()
        try type("first\nsecond line of text", in: canvas)
        let body = try XCTUnwrap(canvas.documentBodyView)
        let y = DocumentLayout.topInset + 60
        let ink = stroke(200, y, 260, y + 30)
        canvas.model.add(ink)
        let before = try zone(of: ink, in: canvas)
        let beforeY = try current(ink, in: canvas).bounds.minY

        let undo = canvas.model.undoManager
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        undo.removeAllActions()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try type("top\n", in: canvas, at: 0)
        undo.endUndoGrouping()
        canvas.reflowDocumentInk()

        let after = try zone(of: ink, in: canvas)
        let lineHeight = DocumentTextLayout(body: body).lineFragmentUsedRects().first?.height ?? 0
        XCTAssertEqual(after.paragraphIndex, before.paragraphIndex + 4)
        XCTAssertEqual(after.dy, before.dy, accuracy: 0.01)
        XCTAssertEqual(try current(ink, in: canvas).bounds.minY - beforeY, lineHeight, accuracy: 1.5)
        XCTAssertEqual(after.rect, try current(ink, in: canvas).bounds.insetBy(dx: -8, dy: -8))

        undo.undo()
        canvas.reflowDocumentInk()
        XCTAssertEqual(body.textView.string, "first\nsecond line of text")
        XCTAssertEqual(try zone(of: ink, in: canvas).paragraphIndex, before.paragraphIndex)
        XCTAssertEqual(try current(ink, in: canvas).bounds.minY, beforeY, accuracy: 0.6)
        undo.redo()
        canvas.reflowDocumentInk()
        XCTAssertEqual(try zone(of: ink, in: canvas).paragraphIndex, before.paragraphIndex + 4)
        XCTAssertGreaterThan(try current(ink, in: canvas).bounds.minY, beforeY)
    }

    func testTypingInsideTheAnchorParagraphKeepsTheZoneAnchored() throws {
        let canvas = makeCanvas()
        try type("first\nsecond", in: canvas)
        let y = DocumentLayout.topInset + 70
        let ink = stroke(300, y, 340, y + 30)
        canvas.model.add(ink)
        let before = try zone(of: ink, in: canvas)
        try type("more ", in: canvas, at: before.paragraphIndex)
        canvas.reflowDocumentInk()
        XCTAssertEqual(try zone(of: ink, in: canvas).paragraphIndex, before.paragraphIndex)
    }

    func testNarrowingTheWindowClampsTheZoneIntoTheColumn() throws {
        let canvas = makeCanvas(width: 600)
        try type(String(repeating: sentence, count: 4), in: canvas)
        let y = DocumentLayout.topInset + 24
        let ink = stroke(440, y, 520, y + 50)
        canvas.model.add(ink)
        XCTAssertEqual(try current(ink, in: canvas).bounds.maxX, ink.bounds.maxX, accuracy: 0.01)

        canvas.setFrameSize(NSSize(width: 400, height: 900))
        canvas.documentViewportDidChange()
        let body = try XCTUnwrap(canvas.documentBodyView)
        let column = DocumentTextLayout(body: body).columnRect
        let rect = try zone(of: ink, in: canvas).rect
        XCTAssertLessThanOrEqual(rect.maxX, column.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(rect.minX, column.minX)
        XCTAssertEqual(rect, try current(ink, in: canvas).bounds.insetBy(dx: -8, dy: -8))
    }

    func testErasingShrinksThenRemovesTheZone() throws {
        let canvas = makeCanvas()
        try type(String(repeating: sentence, count: 4), in: canvas)
        let body = try XCTUnwrap(canvas.documentBodyView)
        let y = DocumentLayout.topInset + 24
        let a = stroke(100, y, 130, y + 30)
        let b = stroke(140, y, 170, y + 120)
        canvas.model.add(a)
        canvas.model.add(b)
        XCTAssertEqual(canvas.model.drawingZones?.count, 1)
        let tall = try zone(of: a, in: canvas).rect

        canvas.model.remove(ids: [b.id])
        let small = try zone(of: a, in: canvas).rect
        XCTAssertEqual(small, try current(a, in: canvas).bounds.insetBy(dx: -8, dy: -8))
        XCTAssertLessThan(small.height, tall.height)
        XCTAssertEqual(body.textView.textContainer?.exclusionPaths.count, 1)

        canvas.model.remove(ids: [a.id])
        XCTAssertEqual(canvas.model.drawingZones, [])
        XCTAssertEqual(body.textView.textContainer?.exclusionPaths.count, 0)
    }

    func testDraggingAZoneReanchorsItAndTheTextRewraps() throws {
        let canvas = makeCanvas()
        try type("one\ntwo\nthree\nfour\n" + String(repeating: sentence, count: 4), in: canvas)
        let body = try XCTUnwrap(canvas.documentBodyView)
        let y = DocumentLayout.topInset + 12
        let ink = stroke(200, y, 240, y + 30)
        canvas.model.add(ink)
        let first = try zone(of: ink, in: canvas)

        canvas.model.translate(ids: [ink.id], by: CGVector(dx: 0, dy: 90))
        let moved = try zone(of: ink, in: canvas)
        XCTAssertGreaterThan(moved.paragraphIndex, first.paragraphIndex)
        let fragments = DocumentTextLayout(body: body).lineFragmentUsedRects()
        XCTAssertTrue(fragments.allSatisfy { !$0.intersects(moved.rect) })
        XCTAssertEqual(moved.rect, try current(ink, in: canvas).bounds.insetBy(dx: -8, dy: -8))
    }

    func testPageHeightIncludesZoneBottoms() throws {
        let model = CanvasModel(layout: .document)
        let scroll = CanvasScrollView(model: model, settings: CanvasSettings(), layout: .document)
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        scroll.layoutSubtreeIfNeeded()
        let canvas = scroll.canvasView
        canvas.documentViewportDidChange()
        let ink = stroke(100, 1500, 140, 1560)
        canvas.model.add(ink)
        scroll.updateDocumentSize()
        XCTAssertGreaterThanOrEqual(canvas.frame.height, try zone(of: ink, in: canvas).rect.maxY)
    }

    // MARK: Migration and persistence

    func testOldNoteWithSketchSpacerMigratesToAZone() throws {
        let content = NSMutableAttributedString(string: "hello\n", attributes: TextFormatting.defaultAttributes)
        let spacer = NSMutableAttributedString(attachment: NSTextAttachment(data: nil, ofType: nil))
        spacer.addAttribute(SketchSpacer.marker, value: NSNumber(value: 80), range: NSRange(location: 0, length: 1))
        spacer.append(NSAttributedString(string: "\n", attributes: TextFormatting.defaultAttributes))
        content.append(spacer)
        content.append(NSAttributedString(string: "after", attributes: TextFormatting.defaultAttributes))
        let archived = TextBlock.content(from: content)
        let decoded = TextBlock(origin: .zero, content: archived).attributedString
        XCTAssertEqual(SketchSpacer.ranges(in: decoded).count, 1)

        let ink = stroke(84, 160, 108, 188)
        let block = TextBlock(origin: CGPoint(x: DocumentLayout.sideMargin, y: DocumentLayout.topInset),
                              width: 460, content: archived)
        let legacy = InkAnchor(strokeIDs: [ink.id], kind: .sketch, charIndex: 6, offset: .zero)
        let model = CanvasModel(strokes: [ink], textBlocks: [block], layout: .document, inkAnchors: [legacy])
        let canvas = CanvasView(model: model, settings: CanvasSettings(), layout: .document)
        canvas.setFrameSize(NSSize(width: 520, height: 900))
        canvas.documentViewportDidChange()

        let body = try XCTUnwrap(canvas.documentBodyView)
        XCTAssertTrue(SketchSpacer.ranges(in: body.textStorage).isEmpty)
        XCTAssertFalse(body.textStorage.string.contains("\u{FFFC}"))
        XCTAssertEqual(body.textStorage.string, "hello\nafter")
        XCTAssertNil(model.inkAnchors)
        XCTAssertEqual(model.drawingZones?.count, 1)
        XCTAssertEqual(model.drawingZones?.first?.strokeIDs, [ink.id])
        let rect = try XCTUnwrap(model.drawingZones?.first?.rect)
        XCTAssertTrue(DocumentTextLayout(body: body).lineFragmentUsedRects().allSatisfy { !$0.intersects(rect) })
        // The saved text no longer carries the spacer.
        let saved = try XCTUnwrap(model.textBlocks.first)
        XCTAssertTrue(SketchSpacer.ranges(in: saved.attributedString).isEmpty)
    }

    func testDrawingZonesRoundTripThroughSaveAndLoad() throws {
        let canvas = makeCanvas()
        try type(String(repeating: sentence, count: 3), in: canvas)
        let y = DocumentLayout.topInset + 24
        let ink = stroke(100, y, 160, y + 40)
        canvas.model.add(ink)
        canvas.syncDocumentBody()
        let zones = try XCTUnwrap(canvas.model.drawingZones)
        XCTAssertEqual(zones.count, 1)

        let data = try JSONEncoder().encode(NoteDocument(model: canvas.model, viewport: nil))
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: data)
        XCTAssertEqual(decoded.drawingZones, zones)

        let reopened = CanvasView(model: decoded.makeModel(), settings: CanvasSettings(), layout: .document)
        reopened.setFrameSize(NSSize(width: 520, height: 900))
        reopened.documentViewportDidChange()
        XCTAssertEqual(reopened.model.drawingZones, zones)
        let body = try XCTUnwrap(reopened.documentBodyView)
        XCTAssertEqual(body.textView.textContainer?.exclusionPaths.count, 1)
        XCTAssertTrue(DocumentTextLayout(body: body).lineFragmentUsedRects().allSatisfy { !$0.intersects(zones[0].rect) })
    }

    func testCanvasNotesAreUntouched() {
        let canvas = CanvasView(model: CanvasModel(layout: .canvas), settings: CanvasSettings(), layout: .canvas)
        canvas.model.add(stroke(0, 0, 40, 40))
        XCTAssertNil(canvas.model.drawingZones)
    }
}
