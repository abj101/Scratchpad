import XCTest
@testable import CanvasKit

/// Notes-style list typing, driven through a real TextBlockView: characters via
/// insertText and Return/Backspace via doCommand(by:), the paths keystrokes take.
final class ListTypingTests: XCTestCase {
    private var block: TextBlockView!
    private var textView: NSTextView { block.textView }

    override func setUp() {
        block = TextBlockView(blockID: UUID(), width: 300)
        block.beginEditing()
        // No event loop in tests: give each simulated keystroke its own undo group.
        textView.undoManager?.groupsByEvent = false
    }

    private func type(_ s: String) {
        for ch in s {
            textView.undoManager?.beginUndoGrouping()
            defer { textView.undoManager?.endUndoGrouping() }
            switch ch {
            case "\n": textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            case "\u{8}": textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            case "\t": textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            case "\u{19}": textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            default: textView.insertText(String(ch), replacementRange: textView.selectedRange())
            }
        }
    }

    private func toggleBullet() {
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        textView.toggleBulletList(nil)
    }

    private func toggleNumbered() {
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        textView.toggleNumberList(nil)
    }

    private func lists(at index: Int) -> [NSTextList] {
        (textView.textStorage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
    }

    func testBulletToggleMakesParagraphAListItem() {
        type("Milk")
        toggleBullet()
        XCTAssertEqual(textView.string, "\t•\tMilk")
        XCTAssertEqual(lists(at: 0).first?.markerFormat, .disc)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0), "caret stays after the text")
    }

    func testBulletToggleTwiceRestoresPlainParagraph() {
        type("Milk")
        toggleBullet()
        toggleBullet()
        XCTAssertEqual(textView.string, "Milk")
        XCTAssertTrue(lists(at: 0).isEmpty)
    }

    func testBulletToggleOnEmptyParagraphThenTyping() {
        toggleBullet()
        type("Eggs")
        XCTAssertEqual(textView.string, "\t•\tEggs")
    }

    func testNumberToggleMakesParagraphANumberedItem() {
        type("Milk")
        toggleNumbered()
        XCTAssertEqual(textView.string, "\t1.\tMilk")
        XCTAssertEqual(lists(at: 0).first?.markerFormat.rawValue, "{decimal}.",
                       "the button agrees with typing \"1. \"")
    }

    func testNumberToggleTwiceRestoresPlainParagraph() {
        type("Milk")
        toggleNumbered()
        toggleNumbered()
        XCTAssertEqual(textView.string, "Milk")
        XCTAssertTrue(lists(at: 0).isEmpty)
    }

    func testNumberToggleThenReturnCountsUp() {
        type("One")
        toggleNumbered()
        type("\nTwo")
        XCTAssertEqual(textView.string, "\t1.\tOne\n\t2.\tTwo")
    }

    func testAsteriskSpaceStartsBulletList() {
        type("* Milk")
        XCTAssertEqual(textView.string, "\t•\tMilk")
        XCTAssertEqual(lists(at: 0).first?.markerFormat, .disc)
    }

    func testDashSpaceStartsBulletList() {
        type("- a")
        XCTAssertEqual(textView.string, "\t•\ta")
    }

    func testNumberDotStartsNumberedListAndReturnContinues() {
        type("1. One\nTwo")
        XCTAssertEqual(textView.string, "\t1.\tOne\n\t2.\tTwo")
        XCTAssertEqual(lists(at: textView.string.utf16.count - 1).first?.markerFormat.rawValue, "{decimal}.")
    }

    func testParenNumberKeepsParenAndStartNumber() {
        type("3) x\ny")
        XCTAssertEqual(textView.string, "\t3)\tx\n\t4)\ty")
    }

    func testReturnOnEmptyItemLeavesList() {
        type("* a\n\nplain")
        XCTAssertEqual(textView.string, "\t•\ta\nplain")
        XCTAssertTrue(lists(at: textView.string.utf16.count - 1).isEmpty)
    }

    func testBackspaceAfterMarkerRemovesList() {
        type("* a")
        textView.setSelectedRange(NSRange(location: 3, length: 0)) // just after "\t•\t"
        type("\u{8}")
        XCTAssertEqual(textView.string, "a")
        XCTAssertTrue(lists(at: 0).isEmpty)
    }

    func testTriggerOnlyAtParagraphStart() {
        type("a * b 1. c")
        XCTAssertEqual(textView.string, "a * b 1. c")
    }

    func testUndoRevertsAutoList() {
        type("* ")
        XCTAssertEqual(textView.string, "\t•\t")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "*")
    }

    func testListSurvivesCommitRoundTrip() {
        type("1. One\nTwo")
        let back = TextBlock(origin: .zero, content: TextBlock.content(from: textView.attributedString())).attributedString
        XCTAssertEqual(back.string, "\t1.\tOne\n\t2.\tTwo")
    }

    // MARK: Renumbering and nesting

    private func depth(at index: Int) -> Int { lists(at: index).count }

    func testInsertingMidListRenumbersFollowingItems() {
        type("1. a\nb\nc")
        textView.setSelectedRange(NSRange(location: 5, length: 0)) // end of "a"
        type("\nx")
        XCTAssertEqual(textView.string, "\t1.\ta\n\t2.\tx\n\t3.\tb\n\t4.\tc")
    }

    func testDeletingItemRenumbers() {
        type("1. a\nb\nc")
        let ns = textView.string as NSString
        let second = ns.paragraphRange(for: NSRange(location: 7, length: 0)) // "\t2.\tb\n"
        textView.undoManager?.beginUndoGrouping()
        textView.insertText("", replacementRange: second)
        textView.undoManager?.endUndoGrouping()
        XCTAssertEqual(textView.string, "\t1.\ta\n\t2.\tc")
    }

    func testTabNestsAndNumbersRestartThenShiftTabResumes() {
        type("1. a\n\tsub\nnext\u{19}")
        XCTAssertEqual(textView.string, "\t1.\ta\n\t1.\tsub\n\t2.\tnext")
        XCTAssertEqual(depth(at: 7), 2, "'sub' is nested")
        XCTAssertEqual(depth(at: textView.string.utf16.count - 1), 1, "'next' is back at the top level")
    }

    func testNestedBulletsChangeMarker() {
        type("* a\nb\t")
        XCTAssertEqual(textView.string, "\t•\ta\n\t◦\tb")
        XCTAssertEqual(lists(at: textView.string.utf16.count - 1).last?.markerFormat, .circle)
    }

    func testReturnOnEmptyNestedItemOutdents() {
        type("* a\n\t\nb")
        XCTAssertEqual(textView.string, "\t•\ta\n\t•\tb")
        XCTAssertEqual(depth(at: textView.string.utf16.count - 1), 1)
    }

    func testTabOutsideListInsertsTab() {
        type("a\tb")
        XCTAssertEqual(textView.string, "a\tb")
    }

    func testUndoTabRestoresLevel() {
        type("* a\nb")
        type("\t")
        XCTAssertEqual(depth(at: textView.string.utf16.count - 1), 2)
        textView.undoManager?.undo()
        XCTAssertEqual(depth(at: textView.string.utf16.count - 1), 1)
    }
}
