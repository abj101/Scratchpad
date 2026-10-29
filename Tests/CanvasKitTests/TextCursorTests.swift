#if DEBUG
import AppKit
import XCTest
@testable import CanvasKit

final class TextCursorTests: XCTestCase {
    func testIBeamOnlyNearLaidOutText() throws {
        _ = NSApplication.shared
        for layout: NoteLayout in [.canvas, .document] {
            let model = CanvasModel()
            model.layout = layout
            let scroll = CanvasScrollView(model: model, settings: CanvasSettings(), layout: layout)
            scroll.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            let view = scroll.canvasView
            view.appendScribeContentForTesting("Hello world")
            let textView = try XCTUnwrap(view.textViews.values.first { $0.textStorage.length > 0 })
            textView.layoutSubtreeIfNeeded()
            let tv = textView.textView
            let manager = try XCTUnwrap(tv.layoutManager)
            manager.ensureLayout(for: try XCTUnwrap(tv.textContainer))
            let used = manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
                .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            let line = view.convert(used, from: tv)
            let onText = NSPoint(x: line.midX, y: line.midY)
            XCTAssertTrue(view.pointNearText(onText), "\(layout): on the line")
            XCTAssertTrue(view.pointNearText(NSPoint(x: line.maxX + 8, y: onText.y)), "\(layout): just beside the line")
            XCTAssertFalse(view.pointNearText(NSPoint(x: onText.x, y: onText.y + 200)), "\(layout): empty space below")
        }
    }
}
#endif
