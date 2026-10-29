import XCTest
@testable import CanvasKit

final class TextTests: XCTestCase {

    // MARK: - TextBlock Codable

    func testTextBlockCodableRoundTrip() throws {
        let original = TextBlock(
            id: UUID(),
            origin: CGPoint(x: 100, y: 200),
            width: 300,
            height: 50,
            content: TextBlock.content(from: NSAttributedString(string: "test"))
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TextBlock.self, from: encoded)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - TextBlock bounds

    func testTextBlockBoundsUsesMaxHeightOne() {
        let block = TextBlock(origin: CGPoint(x: 10, y: 20), width: 100, height: 0)
        let bounds = block.bounds

        XCTAssertEqual(bounds.minX, 10)
        XCTAssertEqual(bounds.minY, 20)
        XCTAssertEqual(bounds.width, 100)
        XCTAssertEqual(bounds.height, 1, "Height should be at least 1")
    }

    func testTextBlockBoundsWithNonZeroHeight() {
        let block = TextBlock(origin: CGPoint(x: 10, y: 20), width: 100, height: 60)
        let bounds = block.bounds

        XCTAssertEqual(bounds.height, 60)
    }

    // MARK: - TextBlock content round-trip

    private func roundTrip(_ string: NSAttributedString) -> NSAttributedString {
        TextBlock(origin: .zero, content: TextBlock.content(from: string)).attributedString
    }

    func testContentRoundTripSimpleString() {
        XCTAssertEqual(roundTrip(NSAttributedString(string: "Hello World")).string, "Hello World")
    }

    func testContentRoundTripWithBold() {
        let attr = NSAttributedString(string: "Hello", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        let font = roundTrip(attr).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    /// Regression: RTF kept the NSTextList but dropped the "\t1.\t" marker text,
    /// so lists turned into plain text after editing ended.
    func testContentRoundTripPreservesListsAlignmentAndLinks() {
        let list = NSTextList(markerFormat: NSTextList.MarkerFormat("{decimal}."), options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        style.alignment = .center
        let attr = NSMutableAttributedString(string: "\t1.\tFirst\n\t2.\tSecond", attributes: [
            .paragraphStyle: style, .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.red,
        ])
        attr.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 4, length: 5))

        let back = roundTrip(attr)
        XCTAssertEqual(back.string, attr.string)
        let backStyle = back.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(backStyle?.textLists.first?.markerFormat.rawValue, "{decimal}.")
        XCTAssertEqual(backStyle?.alignment, .center)
        XCTAssertEqual(back.attribute(.link, at: 5, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(back.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.red)
    }

    func testEmptyContentDecodesEmpty() {
        let block = TextBlock(origin: CGPoint(x: 0, y: 0), content: Data())
        let attr = block.attributedString

        XCTAssertEqual(attr.string, "")
        XCTAssertEqual(attr.length, 0)
    }

    // MARK: - CanvasModel text blocks

    func testAddTextBlock() {
        let model = CanvasModel()
        let block = TextBlock(origin: CGPoint(x: 50, y: 50))

        model.addTextBlock(block)

        XCTAssertEqual(model.textBlocks.count, 1)
        XCTAssertEqual(model.textBlocks[0].id, block.id)
    }

    func testRemoveTextBlock() {
        let model = CanvasModel()
        let block1 = TextBlock(origin: CGPoint(x: 50, y: 50))
        let block2 = TextBlock(origin: CGPoint(x: 100, y: 100))

        model.addTextBlock(block1)
        model.addTextBlock(block2)
        XCTAssertEqual(model.textBlocks.count, 2)

        model.removeTextBlock(id: block1.id)
        XCTAssertEqual(model.textBlocks.count, 1)
        XCTAssertEqual(model.textBlocks[0].id, block2.id)
    }

    func testTextBlockUndoRemove() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let block = TextBlock(origin: CGPoint(x: 50, y: 50))

        model.undoManager.beginUndoGrouping()
        model.addTextBlock(block)
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.textBlocks.count, 1)

        model.undoManager.beginUndoGrouping()
        model.removeTextBlock(id: block.id)
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.textBlocks.count, 0)

        model.undoManager.undo()
        XCTAssertEqual(model.textBlocks.count, 1)
        XCTAssertEqual(model.textBlocks[0].id, block.id)
    }

    func testTextBlockUndoAdd() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let block = TextBlock(origin: CGPoint(x: 50, y: 50))

        model.undoManager.beginUndoGrouping()
        model.addTextBlock(block)
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.textBlocks.count, 1)

        model.undoManager.undo()
        XCTAssertEqual(model.textBlocks.count, 0)
    }

    func testTextBlockRedo() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let block = TextBlock(origin: CGPoint(x: 50, y: 50))

        model.undoManager.beginUndoGrouping()
        model.addTextBlock(block)
        model.undoManager.endUndoGrouping()

        model.undoManager.undo()
        XCTAssertEqual(model.textBlocks.count, 0)

        model.undoManager.redo()
        XCTAssertEqual(model.textBlocks.count, 1)
        XCTAssertEqual(model.textBlocks[0].id, block.id)
    }

    func testUpdateTextBlockWithActionName() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let block = TextBlock(origin: CGPoint(x: 50, y: 50), width: 100)

        model.undoManager.beginUndoGrouping()
        model.addTextBlock(block)
        model.undoManager.endUndoGrouping()

        var updated = block
        updated.width = 200

        model.undoManager.beginUndoGrouping()
        model.updateTextBlock(updated, actionName: "Edit Text")
        model.undoManager.endUndoGrouping()

        XCTAssertEqual(model.textBlocks[0].width, 200)
        XCTAssertTrue(model.undoManager.canUndo)

        model.undoManager.undo()
        XCTAssertEqual(model.textBlocks[0].width, 100)
    }

    func testUpdateTextBlockWithoutActionName() {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false

        let block = TextBlock(origin: CGPoint(x: 50, y: 50), width: 100)

        model.undoManager.beginUndoGrouping()
        model.addTextBlock(block)
        model.undoManager.endUndoGrouping()

        var updated = block
        updated.height = 60

        // Update without actionName (e.g., syncing laid-out height)
        model.updateTextBlock(updated, actionName: nil)

        XCTAssertEqual(model.textBlocks[0].height, 60)

        // Should not be undoable (only the original add is undoable)
        model.undoManager.undo()
        XCTAssertEqual(model.textBlocks.count, 0)
        // No redo available for the height update since it wasn't registered
    }

    func testUpdateTextBlockIdenticalNoOp() {
        let block = TextBlock(origin: CGPoint(x: 50, y: 50))
        let model = CanvasModel(textBlocks: [block])
        model.undoManager.groupsByEvent = false
        var changedIds: [Set<UUID>] = []
        model.onTextBlocksChange = { changedIds.append($0) }

        model.undoManager.beginUndoGrouping()
        model.updateTextBlock(block, actionName: "Edit")
        model.undoManager.endUndoGrouping()
        XCTAssertTrue(changedIds.isEmpty, "Identical update must not notify")

        var updated = block
        updated.width = 200
        model.undoManager.beginUndoGrouping()
        model.updateTextBlock(updated, actionName: "Edit")
        model.undoManager.endUndoGrouping()
        XCTAssertEqual(changedIds, [[block.id]])
        XCTAssertTrue(model.undoManager.canUndo)
    }
    func testTextBlockAtPoint() {
        let model = CanvasModel()
        let block1 = TextBlock(origin: CGPoint(x: 0, y: 0), width: 100, height: 50)
        let block2 = TextBlock(origin: CGPoint(x: 50, y: 50), width: 100, height: 50)

        model.addTextBlock(block1)
        model.addTextBlock(block2)

        // Point in block2 bounds should return block2 (topmost)
        let found = model.textBlock(at: CGPoint(x: 60, y: 60))
        XCTAssertEqual(found?.id, block2.id)
    }

    func testTextBlockAtPointOutside() {
        let model = CanvasModel()
        let block = TextBlock(origin: CGPoint(x: 0, y: 0), width: 100, height: 50)

        model.addTextBlock(block)

        let found = model.textBlock(at: CGPoint(x: 200, y: 200))
        XCTAssertNil(found)
    }

    func testTextBlockById() {
        let model = CanvasModel()
        let block = TextBlock(origin: CGPoint(x: 0, y: 0))

        model.addTextBlock(block)

        let found = model.textBlock(id: block.id)
        XCTAssertEqual(found?.id, block.id)
    }

    func testOnTextBlocksChangeFiresForAdd() {
        let model = CanvasModel()
        var changedIds: Set<UUID> = []
        model.onTextBlocksChange = { ids in
            changedIds = ids
        }

        let block = TextBlock(origin: CGPoint(x: 0, y: 0))
        model.addTextBlock(block)

        XCTAssertEqual(changedIds, [block.id])
    }

    func testOnTextBlocksChangeFiresForRemove() {
        let model = CanvasModel()
        let block = TextBlock(origin: CGPoint(x: 0, y: 0))
        model.addTextBlock(block)

        var changedIds: Set<UUID> = []
        model.onTextBlocksChange = { ids in
            changedIds = ids
        }

        model.removeTextBlock(id: block.id)

        XCTAssertEqual(changedIds, [block.id])
    }

    func testOnTextBlocksChangeFiresForUpdate() {
        let model = CanvasModel()
        let block = TextBlock(origin: CGPoint(x: 0, y: 0))
        model.addTextBlock(block)

        var changedIds: Set<UUID> = []
        model.onTextBlocksChange = { ids in
            changedIds = ids
        }

        var updated = block
        updated.width = 200
        model.updateTextBlock(updated, actionName: "Edit")

        XCTAssertEqual(changedIds, [block.id])
    }

    func testContentBoundsIncludesTextBlocks() {
        let model = CanvasModel()
        let block = TextBlock(origin: CGPoint(x: 100, y: 100), width: 50, height: 40)

        model.addTextBlock(block)

        let bounds = model.contentBounds
        XCTAssertNotNil(bounds)
        XCTAssertTrue(bounds!.contains(CGPoint(x: 100, y: 100)))
    }

    func testContentBoundsIncludesTextAndStrokes() {
        let model = CanvasModel()
        let block = TextBlock(origin: CGPoint(x: 100, y: 100), width: 50, height: 40)
        let stroke = Stroke(
            points: [StrokePoint(x: 200, y: 200, t: 0)],
            color: .black,
            width: 2
        )

        model.addTextBlock(block)
        model.add(stroke)

        let bounds = model.contentBounds
        XCTAssertNotNil(bounds)
    }

    func testContentBoundsNilWhenEmpty() {
        let model = CanvasModel()
        XCTAssertNil(model.contentBounds)
    }

    // MARK: - TextFormatting

    func testFontForBodySize() {
        let font = TextFormatting.font(for: .body)
        XCTAssertEqual(font.pointSize, TextFormatting.bodySize)
    }

    func testFontForHeading1() {
        let font = TextFormatting.font(for: .heading(1))
        // Heading 1 should be bold and 26pt
        XCTAssertEqual(font.pointSize, 26)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testFontForHeading2() {
        let font = TextFormatting.font(for: .heading(2))
        // Heading 2 should be bold and 20pt
        XCTAssertEqual(font.pointSize, 20)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testFontForHeading3() {
        let font = TextFormatting.font(for: .heading(3))
        // Heading 3 should be bold and 17pt
        XCTAssertEqual(font.pointSize, 17)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testApplyHeadingToMiddleParagraph() {
        let storage = NSMutableAttributedString(string: "Line 1\nLine 2\nLine 3")
        let range = NSRange(location: 7, length: 6) // "Line 2"

        TextFormatting.apply(.heading(1), to: storage, range: range)

        let font = storage.attribute(.font, at: 8, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertEqual(font?.pointSize, 26)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testApplyBodyReverts() {
        let storage = NSMutableAttributedString(string: "Text")
        let range = NSRange(location: 0, length: 4)

        // Apply heading first
        TextFormatting.apply(.heading(1), to: storage, range: range)
        // Then apply body
        TextFormatting.apply(.body, to: storage, range: range)

        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, TextFormatting.bodySize)
    }

    func testAddLinkToRange() {
        let storage = NSMutableAttributedString(string: "Link")
        let range = NSRange(location: 0, length: 4)
        let url = URL(string: "https://example.com")!

        TextFormatting.addLink(url, to: storage, range: range)

        let link = storage.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(link, url)
    }

    func testAddLinkToEmptyRange() {
        let storage = NSMutableAttributedString(string: "Text")
        let range = NSRange(location: 2, length: 0)
        let url = URL(string: "https://example.com")!

        TextFormatting.addLink(url, to: storage, range: range)

        // Should insert the URL text and link it
        XCTAssertTrue(storage.string.contains("example.com"))
    }

    func testURLParsingHttps() {
        let url = TextFormatting.url(from: "https://example.com")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "example.com")
    }

    func testURLParsingDomainWithoutScheme() {
        let url = TextFormatting.url(from: "example.com")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "example.com")
    }

    func testURLParsingMailto() {
        let url = TextFormatting.url(from: "mailto:user@example.com")
        XCTAssertEqual(url?.scheme, "mailto")
    }

    func testURLParsingInvalidNoDot() {
        let url = TextFormatting.url(from: "nodot")
        XCTAssertNil(url)
    }

    func testURLParsingInvalidPlainText() {
        let url = TextFormatting.url(from: "hello world")
        XCTAssertNil(url)
    }

    func testParagraphStyleKindDetection() {
        let storage = NSMutableAttributedString(string: "Heading")
        let headingFont = NSFont.boldSystemFont(ofSize: 26)
        storage.addAttribute(.font, value: headingFont, range: NSRange(location: 0, length: 7))

        let kind = TextFormatting.paragraphStyleKind(in: storage, at: 0)
        XCTAssertEqual(kind, .heading(1))
    }

    func testParagraphStyleKindBody() {
        let storage = NSAttributedString(string: "Body text")
        let kind = TextFormatting.paragraphStyleKind(in: storage, at: 0)
        XCTAssertEqual(kind, .body)
    }
}

/// The style label and size field the formatting bar reads back from the caret.
final class TextStyleCaretTests: XCTestCase {
    private var block: TextBlockView!
    private var textView: NSTextView { block.textView }

    override func setUp() {
        block = TextBlockView(blockID: UUID(), width: 300)
        block.beginEditing()
        // No event loop in tests: give each simulated edit its own undo group.
        textView.undoManager?.groupsByEvent = false
    }

    private func edit(_ body: () -> Void) {
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping() }
        body()
    }

    func testParagraphStyleKindFollowsTheFont() {
        XCTAssertEqual(TextFormatting.paragraphStyleKind(for: nil), .body)
        XCTAssertEqual(TextFormatting.paragraphStyleKind(for: .systemFont(ofSize: 15)), .body)
        XCTAssertEqual(TextFormatting.paragraphStyleKind(for: .boldSystemFont(ofSize: 8)), .body)
        XCTAssertEqual(TextFormatting.paragraphStyleKind(for: .boldSystemFont(ofSize: 17)), .heading(3))
        XCTAssertEqual(TextFormatting.paragraphStyleKind(for: .boldSystemFont(ofSize: 20)), .heading(2))
        XCTAssertEqual(TextFormatting.paragraphStyleKind(for: .boldSystemFont(ofSize: 26)), .heading(1))
    }

    func testParagraphStyleDisplayNames() {
        XCTAssertEqual(ParagraphStyleKind.body.displayName, "Body")
        XCTAssertEqual(ParagraphStyleKind.heading(2).displayName, "H2")
        XCTAssertEqual(ParagraphStyleKind.heading(9).displayName, "H3")
    }

    func testSettingFontSizeScalesTheSelectionAndKeepsTraits() {
        edit { textView.insertText("Head", replacementRange: textView.selectedRange()) }
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        textView.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 26),
                                           range: NSRange(location: 0, length: 4))
        edit { textView.setEditingFontSize(20) }
        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 20)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertEqual(TextFormatting.paragraphStyleKind(for: font), .heading(2))
    }

    func testSettingFontSizeAtABareCaretAppliesToTyping() {
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        edit { textView.setEditingFontSize(28) }
        XCTAssertEqual((textView.typingAttributes[.font] as? NSFont)?.pointSize, 28)
        edit { textView.insertText("x", replacementRange: textView.selectedRange()) }
        XCTAssertEqual((textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 28)
    }
}
