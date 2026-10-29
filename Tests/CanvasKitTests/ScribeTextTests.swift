import XCTest
@testable import CanvasKit

final class ScribeTextTests: XCTestCase {
    func testNormalizedCollapsesWhitespace() {
        XCTAssertEqual(ScribeText.normalized("  hello \n world "), "hello world")
        XCTAssertNil(ScribeText.normalized("  \n"))
        XCTAssertNil(ScribeText.normalized(nil))
    }

    func testSeparator() {
        XCTAssertEqual(ScribeText.separator(before: ""), "")
        XCTAssertEqual(ScribeText.separator(before: "hi"), " ")
        XCTAssertEqual(ScribeText.separator(before: "hi\n"), "")
        XCTAssertEqual(ScribeText.separator(before: "hi "), "")
    }

    func testAppendingKeepsEndAttributes() {
        let bold = [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: 20)]
        let base = NSMutableAttributedString(string: "a", attributes: TextFormatting.defaultAttributes)
        base.append(NSAttributedString(string: "b", attributes: bold))
        let result = ScribeText.appending(" c", to: base)
        XCTAssertEqual(result.string, "ab c")
        let font = result.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font, bold[.font])
    }

    func testAppendingToEmptyUsesDefaults() {
        let result = ScribeText.appending("hi", to: NSAttributedString())
        XCTAssertEqual(result.string, "hi")
        XCTAssertEqual(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, TextFormatting.font(for: .body))
    }

    func testRemovingLastWord() throws {
        func removed(_ text: String) -> String? {
            ScribeText.removingLastWord(from: NSAttributedString(string: text))?.string
        }
        XCTAssertEqual(removed("hello world"), "hello")
        XCTAssertEqual(removed("hello"), "")
        XCTAssertEqual(removed("hello, world."), "hello,")
        XCTAssertEqual(removed("hello   world"), "hello")
        XCTAssertEqual(removed("hello world  "), "hello")
        XCTAssertEqual(removed("hello world\n"), "hello world")
        XCTAssertEqual(removed("hello\nworld"), "hello\n")
        XCTAssertEqual(removed("hello\r\n"), "hello")
        XCTAssertEqual(removed("  "), "")
        XCTAssertNil(removed(""))
        let styled = NSAttributedString(string: "a bc", attributes: [.underlineStyle: 1])
        let rest = try XCTUnwrap(ScribeText.removingLastWord(from: styled))
        XCTAssertEqual(rest.string, "a")
        XCTAssertNotNil(rest.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }

    func testTail() {
        XCTAssertEqual(ScribeText.tail(of: "a b c", words: 5), "a b c")
        XCTAssertEqual(ScribeText.tail(of: "a b\nc d e", words: 3), "…c d e")
        XCTAssertNil(ScribeText.tail(of: " \n", words: 3))
    }

    func testNewBlockOriginAvoidsObstacles() {
        let visible = CGRect(x: 100, y: 200, width: 800, height: 600)
        let size = CGSize(width: 240, height: 28)
        XCTAssertEqual(ScribeText.newBlockOrigin(visible: visible, inset: 24, size: size, obstacles: [], gap: 12),
                       CGPoint(x: 124, y: 224))
        let blocks = [CGRect(x: 100, y: 210, width: 300, height: 50), CGRect(x: 120, y: 270, width: 300, height: 40)]
        let origin = ScribeText.newBlockOrigin(visible: visible, inset: 24, size: size, obstacles: blocks, gap: 12)
        XCTAssertEqual(origin, CGPoint(x: 124, y: 322))
        let far = [CGRect(x: 2000, y: 0, width: 10, height: 10)]
        XCTAssertEqual(ScribeText.newBlockOrigin(visible: visible, inset: 24, size: size, obstacles: far, gap: 12).y, 224)
    }

    func testQueueAppliesInOrder() {
        var q = ScribeQueue()
        let a = q.enqueuePending()
        let b = q.enqueuePending()
        q.enqueueDone("\n")
        q.complete(b, text: "world")
        XCTAssertTrue(q.popReady().isEmpty, "b waits for a")
        q.complete(a, text: nil)
        XCTAssertEqual(q.popReady(), [nil, "world", "\n"])
        XCTAssertTrue(q.isEmpty)
    }

    func testQueueDropLast() {
        var q = ScribeQueue()
        XCTAssertFalse(q.dropLast())
        let a = q.enqueuePending()
        let b = q.enqueuePending()
        XCTAssertTrue(q.dropLast())
        q.complete(b, text: "late") // ignored
        q.complete(a, text: "first")
        XCTAssertEqual(q.popReady(), ["first"])
        XCTAssertTrue(q.isEmpty)
    }

    func testQueueDropsLatestLineAndReturnTogether() {
        var q = ScribeQueue()
        let earlier = q.enqueuePending()
        let cancelled = q.enqueuePending()
        q.enqueueDone("\n", afterPendingID: cancelled)
        XCTAssertTrue(q.dropLastPendingLine())
        XCTAssertEqual(q.count, 1)
        q.complete(cancelled, text: "late result")
        q.complete(earlier, text: "keep")
        XCTAssertEqual(q.popReady(), ["keep"])

        _ = q.enqueuePending()
        let finished = q.enqueuePending()
        q.enqueueDone("\n", afterPendingID: finished)
        q.complete(finished, text: "recognized but blocked")
        XCTAssertTrue(q.dropLastPendingLine())
        XCTAssertEqual(q.count, 1)

        var returnsOnly = ScribeQueue()
        returnsOnly.enqueueDone("\n")
        XCTAssertFalse(returnsOnly.dropLastPendingLine())
        XCTAssertEqual(returnsOnly.popReady(), ["\n"])

        var idleLineThenReturn = ScribeQueue()
        let idle = idleLineThenReturn.enqueuePending()
        idleLineThenReturn.complete(idle, text: "keep this line")
        idleLineThenReturn.enqueueDone("\n") // Return had no line buffered to commit.
        XCTAssertFalse(idleLineThenReturn.dropLastPendingLine())
        XCTAssertEqual(idleLineThenReturn.count, 2)
    }

    func testDeleteDropsPendingLineAndReturnTogether() {
        var q = ScribeQueue()
        let earlier = q.enqueuePending()
        let id = q.enqueuePending()
        q.enqueueDone("\n", afterPendingID: id)

        XCTAssertTrue(q.dropLastForDelete())
        q.complete(id, text: "deleted line")
        q.complete(earlier, text: "keep this line")
        XCTAssertEqual(q.popReady(), ["keep this line"])
    }

    func testModes() {
        XCTAssertTrue(InputMode.scribe.usesTabletInput)
        XCTAssertTrue(InputMode.scribe.usesLetterCell)
        XCTAssertFalse(InputMode.tablet.usesLetterCell)
        XCTAssertNotNil(InputMode.scribe.hint(penKey: .space, activation: .hold))
    }
}
