#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

/// Document Scribe's viewport follow, driven through the real path: settings → enterScribe →
/// appendScribe → the chase. The chase is stepped by hand so the assertions don't race a
/// display link.
final class ScribeFollowTests: XCTestCase {
    private func scribedDocument(lines: Int, reduceMotion: Bool = false) throws -> (scroll: CanvasScrollView, canvas: CanvasView, body: TextBlockView) {
        _ = NSApplication.shared
        let model = CanvasModel(layout: .document)
        let settings = CanvasSettings()
        let scroll = CanvasScrollView(model: model, settings: settings, layout: .document)
        scroll.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        scroll.tile()
        let canvas = scroll.canvasView
        let body = try XCTUnwrap(canvas.documentBodyView)
        body.textView.insertText(String(repeating: "a line of text\n", count: lines),
                                 replacementRange: NSRange(location: 0, length: 0))
        canvas.syncDocumentBody()
        scroll.updateDocumentSize()
        // Set before Scribe starts: opening the panel grows the page, which already follows.
        canvas.reduceMotionForTesting = reduceMotion
        settings.handwritingToText = true
        settings.inputMode = .scribe
        XCTAssertEqual(canvas.settings.inputMode, .scribe)
        return (scroll, canvas, body)
    }

    /// The caret in page coordinates, the way the follow measures it.
    private func caret(_ body: TextBlockView) -> CGRect {
        body.selectedCaretRect().offsetBy(dx: body.frame.minX, dy: body.frame.minY)
    }

    private func chaseToRest(_ canvas: CanvasView) {
        for _ in 0..<600 {
            guard canvas.followOriginForTesting != nil else { return }
            canvas.followStepForTesting(dt: 1.0 / 60)
        }
        XCTFail("the chase never settled")
    }

    func testRapidCaretUpdatesSettleOnOneTarget() throws {
        let (scroll, canvas, _) = try scribedDocument(lines: 60)
        var targets: [CGFloat] = []
        for _ in 0..<4 {
            canvas.appendScribeContentForTesting("word ")
            XCTAssertTrue(canvas.isFollowingForTesting)
            targets.append(try XCTUnwrap(canvas.followOriginForTesting).y)
        }
        // One target for the burst: the glide is retargeted in place, not restarted.
        XCTAssertEqual(Set(targets).count, 1)
        chaseToRest(canvas)
        XCTAssertFalse(canvas.isFollowingForTesting, "the glide stops when it arrives")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, targets[0], accuracy: 0.5)
    }

    func testManualScrollSuspendsTheFollowUntilThePenIsDown() throws {
        let (scroll, canvas, _) = try scribedDocument(lines: 60)
        canvas.appendScribeContentForTesting("word ")
        chaseToRest(canvas)
        let parked = scroll.contentView.bounds.origin

        // Scrolling by hand takes the viewport away from the follow.
        canvas.suspendFollowForTesting()
        canvas.appendScribeContentForTesting("word ")
        chaseToRest(canvas)
        XCTAssertEqual(scroll.contentView.bounds.origin, parked, "a manual scroll is never fought")

        // The pen going down hands it back: the next line glides the viewport again.
        canvas.resumeFollowForTesting()
        canvas.appendScribeContentForTesting("\n")
        XCTAssertNotNil(canvas.followOriginForTesting, "the follow is live again")
        chaseToRest(canvas)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, parked.y)
    }

    func testReduceMotionJumpsToTheTargetInsteadOfGliding() throws {
        let (scroll, canvas, body) = try scribedDocument(lines: 60, reduceMotion: true)
        canvas.appendScribeContentForTesting("word ")
        XCTAssertNil(canvas.followOriginForTesting, "arrived at once")
        XCTAssertFalse(canvas.isFollowingForTesting)
        let caret = caret(body)
        XCTAssertLessThanOrEqual(caret.maxY, canvas.scribeFreeRect().maxY, "the caret is clear of the panel")
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
    }
}
#endif
