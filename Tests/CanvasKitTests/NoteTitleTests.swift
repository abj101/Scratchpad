import XCTest
@testable import CanvasKit

final class NoteTitleTests: XCTestCase {
    private func block(_ text: String, x: Double = 0, y: Double = 0) -> TextBlock {
        TextBlock(origin: CGPoint(x: x, y: y), content: TextBlock.content(from: NSAttributedString(string: text)))
    }

    func testFirstNonEmptyLine() {
        XCTAssertEqual(NoteTitle.derive(from: [block("\n  \nGrocery list\nmilk")]), "Grocery list")
    }

    func testTopmostThenLeftmostBlockWins() {
        let blocks = [block("Lower", y: 100), block("Right", x: 50, y: 0), block("Left", x: -50, y: 0)]
        XCTAssertEqual(NoteTitle.derive(from: blocks), "Left")
    }

    func testSkipsEmptyBlocks() {
        XCTAssertEqual(NoteTitle.derive(from: [block("   ", y: 0), block("Second", y: 10)]), "Second")
        XCTAssertNil(NoteTitle.derive(from: [block("")]))
        XCTAssertNil(NoteTitle.derive(from: []))
    }

    private func cache(_ lines: [(String, Double, Double)]) -> HandwritingCache {
        HandwritingCache(recognitionVersion: 1, lines: lines.map {
            .init(digest: $0.0, strokeIDs: [], bounds: CGRect(x: $0.2, y: $0.1, width: 100, height: 20), text: $0.0)
        })
    }

    func testHandwritingBecomesTitleWhenNoText() {
        XCTAssertEqual(NoteTitle.derive(from: [], handwriting: cache([("Shopping", 0, 0)])), "Shopping")
    }

    func testHandwritingAndTextOrderedByPosition() {
        let blocks = [block("Typed", y: 50)]
        XCTAssertEqual(NoteTitle.derive(from: blocks, handwriting: cache([("Written", 10, 0)])), "Written")
        XCTAssertEqual(NoteTitle.derive(from: blocks, handwriting: cache([("Written", 80, 0)])), "Typed")
    }

    func testEmptyHandwritingLinesAreSkipped() {
        let hw = HandwritingCache(recognitionVersion: 1, lines: [
            .init(digest: "a", strokeIDs: [], bounds: .zero, text: ""),
            .init(digest: "b", strokeIDs: [], bounds: CGRect(x: 0, y: 30, width: 5, height: 5), text: "Second"),
        ])
        XCTAssertEqual(NoteTitle.derive(from: [], handwriting: hw), "Second")
        XCTAssertNil(NoteTitle.derive(from: [], handwriting: HandwritingCache(recognitionVersion: 1)))
    }

    func testSanitize() {
        XCTAssertEqual(NoteTitle.sanitize("\t•\tBuy milk"), "Buy milk")
        XCTAssertEqual(NoteTitle.sanitize("\t1.\tFirst step"), "First step")
        XCTAssertEqual(NoteTitle.sanitize("a/b: c"), "a b c")
        XCTAssertEqual(NoteTitle.sanitize("..hidden"), "hidden")
        XCTAssertNil(NoteTitle.sanitize(" \t "))
    }

    func testTruncatesAtWordBreak() {
        let title = NoteTitle.sanitize("The quick brown fox jumps over the lazy dog and keeps running")!
        XCTAssertLessThanOrEqual(title.count, NoteTitle.maxLength)
        XCTAssertEqual(title, "The quick brown fox jumps over the lazy")
        XCTAssertEqual(NoteTitle.sanitize(String(repeating: "x", count: 60))?.count, NoteTitle.maxLength)
    }

    func testDefaultAndNumberedNames() {
        XCTAssertTrue(NoteTitle.isDefault("Untitled"))
        XCTAssertTrue(NoteTitle.isDefault("Untitled 12"))
        XCTAssertFalse(NoteTitle.isDefault("Untitled draft"))
        XCTAssertFalse(NoteTitle.isDefault("Untitled "))
        XCTAssertTrue(NoteTitle.matches("groceries 2", base: "Groceries"))
        XCTAssertFalse(NoteTitle.matches("Groceries list", base: "Groceries"))
    }

    func testNamedByUserRoundTripsAndDefaultsToNil() throws {
        var document = NoteDocument()
        XCTAssertNil(try JSONDecoder().decode(NoteDocument.self, from: JSONEncoder().encode(document)).namedByUser)
        document.namedByUser = true
        XCTAssertEqual(try JSONDecoder().decode(NoteDocument.self, from: JSONEncoder().encode(document)).namedByUser, true)
    }

    func testAutosaverWritesNamedByUserAndReportsEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Note.\(NotePackage.fileExtension)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let um = UndoManager()
        um.groupsByEvent = false
        let model = CanvasModel(undoManager: um)
        let saver = NoteAutosaver(model: model, url: url, delay: 10)
        var edits = 0
        saver.onEdit = { edits += 1 }
        um.beginUndoGrouping()
        model.addTextBlock(block("Hi"))
        um.endUndoGrouping()
        XCTAssertEqual(edits, 1)
        saver.namedByUser = false
        XCTAssertTrue(saver.flush())
        XCTAssertEqual(try NotePackage.read(from: url).namedByUser, false)
    }
}

final class NamedByUserTests: XCTestCase {
    private func doc(_ named: Bool?, _ automatic: String?) -> NoteDocument {
        var d = NoteDocument()
        d.namedByUser = named
        d.automaticName = automatic
        return d
    }

    func testRenamedInAppIsNeverAutomatic() {
        XCTAssertTrue(NoteTitle.isNamedByUser(doc(true, "Groceries"), currentName: "Groceries"))
    }

    func testRenamedInFinderIsDetected() {
        XCTAssertTrue(NoteTitle.isNamedByUser(doc(false, "Groceries"), currentName: "Shopping"))
        XCTAssertFalse(NoteTitle.isNamedByUser(doc(false, "Groceries"), currentName: "Groceries"))
        XCTAssertFalse(NoteTitle.isNamedByUser(doc(false, "Groceries"), currentName: "Groceries 2"))
    }

    func testOlderFiles() {
        XCTAssertFalse(NoteTitle.isNamedByUser(doc(nil, nil), currentName: "Untitled 3"))
        XCTAssertTrue(NoteTitle.isNamedByUser(doc(nil, nil), currentName: "Physics"))
        XCTAssertFalse(NoteTitle.isNamedByUser(doc(false, nil), currentName: "hello"))
    }

    func testAutosaverWritesAutomaticName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Note.\(NotePackage.fileExtension)")
        let saver = NoteAutosaver(model: CanvasModel(), url: url, delay: 10)
        saver.automaticName = "Groceries"
        saver.markDirty()
        XCTAssertTrue(saver.flush())
        XCTAssertEqual(try NotePackage.read(from: url).automaticName, "Groceries")
    }
}
