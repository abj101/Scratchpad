import XCTest
import AppKit
@testable import CanvasKit

final class SemanticTitleTests: XCTestCase {

    // MARK: - Helper for TextBlocks

    private func block(_ text: String, x: Double = 0, y: Double = 0) -> TextBlock {
        TextBlock(origin: CGPoint(x: x, y: y), content: TextBlock.content(from: NSAttributedString(string: text)))
    }

    private func cache(_ lines: [(String, Double, Double)]) -> HandwritingCache {
        HandwritingCache(recognitionVersion: 1, lines: lines.map {
            .init(digest: $0.0, strokeIDs: [], bounds: CGRect(x: $0.2, y: $0.1, width: 100, height: 20), text: $0.0)
        })
    }

    func testNamingTextIncludesHandwritingInReadingOrder() {
        let blocks = [block("Typed", y: 50)]
        let hw = cache([("Top", 0, 0), ("Bottom", 100, 0)])
        XCTAssertEqual(NoteTitle.namingText(from: blocks, handwriting: hw), "Top\nTyped\nBottom")
    }

    func testNamingTextInkOnlyWithHandwriting() {
        XCTAssertEqual(NoteTitle.namingText(from: [], handwriting: cache([("Hello", 0, 0)])), "Hello")
        XCTAssertEqual(NoteTitle.namingText(from: [], handwriting: nil), "")
    }

    // MARK: - namingText Tests

    func testNamingTextReadingOrderTopThenLeft() {
        let blocks = [
            block("Lower", y: 100),
            block("Right", x: 50, y: 0),
            block("Left", x: -50, y: 0)
        ]
        let result = NoteTitle.namingText(from: blocks)
        XCTAssertEqual(result, "Left\nRight\nLower")
    }

    func testNamingTextSkipsBlankBlocks() {
        let blocks = [
            block("   ", y: 0),
            block("", y: 10),
            block("First", y: 20)
        ]
        let result = NoteTitle.namingText(from: blocks)
        XCTAssertEqual(result, "First")
    }

    func testNamingTextTrimsEachBlock() {
        let blocks = [
            block("  trimmed  ", y: 0),
            block("\tindented\t", y: 10)
        ]
        let result = NoteTitle.namingText(from: blocks)
        XCTAssertEqual(result, "trimmed\nindented")
    }

    func testNamingTextJoinsWithNewline() {
        let blocks = [block("First", y: 0), block("Second", y: 10)]
        let result = NoteTitle.namingText(from: blocks)
        XCTAssertEqual(result, "First\nSecond")
    }

    func testNamingTextCutAtDefaultLimit() {
        let longText = String(repeating: "a", count: 2000)
        let blocks = [block(longText, y: 0)]
        let result = NoteTitle.namingText(from: blocks)
        XCTAssertEqual(result.count, NoteTitle.namingTextLimit)
        XCTAssertTrue(result.allSatisfy { $0 == "a" })
    }

    func testNamingTextCutAtCustomLimit() {
        let blocks = [block("Hello World", y: 0)]
        let result = NoteTitle.namingText(from: blocks, limit: 5)
        XCTAssertEqual(result, "Hello")
    }

    func testIsNameable() {
        let isWord: (String) -> Bool = { ["milk", "eggs", "bread"].contains($0) }
        XCTAssertFalse(NoteTitle.isNameable("hhhhshshhshshs", isWord: isWord))
        XCTAssertTrue(NoteTitle.isNameable("milk eggs bread", isWord: isWord))
        XCTAssertTrue(NoteTitle.isNameable("x^2 + 5x = 0", isWord: isWord))
    }

    func testNamingTextSmallLimit() {
        let blocks = [
            block("First", y: 0),
            block("Second", y: 10),
            block("Third", y: 20)
        ]
        let result = NoteTitle.namingText(from: blocks, limit: 10)
        XCTAssertEqual(result, "First\nSeco")
    }

    func testNamingTextIncludesEquationLaTeX() {
        let line = NSMutableAttributedString(string: "Solve ")
        line.append(NSAttributedString(attachment: EquationAttachment(latex: "x^2 = 4", fontSize: 16)))
        let blocks = [TextBlock(origin: .zero, content: TextBlock.content(from: line))]
        XCTAssertEqual(NoteTitle.namingText(from: blocks), "Solve x^2 = 4")
    }

    func testNamingTextInkOnlyReturnsEmpty() {
        let result = NoteTitle.namingText(from: [])
        XCTAssertEqual(result, "")
    }

    func testNamingTextMultipleBlanksThenContent() {
        let blocks = [
            block("   ", y: 0),
            block("  \t  ", y: 10),
            block("", y: 20),
            block("Content", y: 30)
        ]
        let result = NoteTitle.namingText(from: blocks)
        XCTAssertEqual(result, "Content")
    }

    // MARK: - digest Tests

    func testDigestIsDeterministic() {
        let text = "Hello World"
        let digest1 = NoteTitle.digest(text)
        let digest2 = NoteTitle.digest(text)
        XCTAssertEqual(digest1, digest2)
    }

    func testDigestIsLowercaseHex() {
        let digest = NoteTitle.digest("test")
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testDigestDiffersForDifferentText() {
        let digest1 = NoteTitle.digest("text1")
        let digest2 = NoteTitle.digest("text2")
        XCTAssertNotEqual(digest1, digest2)
    }

    func testDigestKnownValueForAbc() {
        let digest = NoteTitle.digest("abc")
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testDigestEmptyStringDiffers() {
        let digest1 = NoteTitle.digest("")
        let digest2 = NoteTitle.digest("a")
        XCTAssertNotEqual(digest1, digest2)
    }

    // MARK: - cleanSuggestion Tests

    func testCleanSuggestionRemovesSurroundingQuotes() {
        let result = NoteTitle.cleanSuggestion("\"Calculus Limits\"")
        XCTAssertEqual(result, "Calculus Limits")
    }

    func testCleanSuggestionRemovesTitlePrefix() {
        let result = NoteTitle.cleanSuggestion("Title: Foo Bar")
        XCTAssertEqual(result, "Foo Bar")
    }

    func testCleanSuggestionRemovesPunctuation() {
        let result = NoteTitle.cleanSuggestion("Limits, Homework!")
        XCTAssertEqual(result, "Limits Homework")
    }

    func testCleanSuggestionKeepsApostropheInside() {
        let result = NoteTitle.cleanSuggestion("Kid's Plan")
        XCTAssertEqual(result, "Kid's Plan")
    }

    func testCleanSuggestionKeepsHyphenInside() {
        let result = NoteTitle.cleanSuggestion("Long-term Plan")
        XCTAssertEqual(result, "Long-term Plan")
    }

    func testCleanSuggestionCutsAtFiveWords() {
        let result = NoteTitle.cleanSuggestion("One Two Three Four Five Six Seven")
        XCTAssertEqual(result, "One Two Three Four Five")
    }

    func testCleanSuggestionFirstNonEmptyLine() {
        let result = NoteTitle.cleanSuggestion("\n\nSecond Line\nThird Line")
        XCTAssertEqual(result, "Second Line")
    }

    func testCleanSuggestionReturnsNilForEmpty() {
        let result = NoteTitle.cleanSuggestion("")
        XCTAssertNil(result)
    }

    func testCleanSuggestionReturnsNilForWhitespace() {
        let result = NoteTitle.cleanSuggestion("   \t   ")
        XCTAssertNil(result)
    }

    func testCleanSuggestionReturnsNilForOnlyPunctuation() {
        let result = NoteTitle.cleanSuggestion("!!!")
        XCTAssertNil(result)
    }

    func testCleanSuggestionRemovesSlash() {
        let result = NoteTitle.cleanSuggestion("a/b/c")
        XCTAssertEqual(result, "A b c")
    }

    func testCleanSuggestionRemovesColon() {
        let result = NoteTitle.cleanSuggestion("a:b:c")
        XCTAssertEqual(result, "A b c")
    }

    func testCleanSuggestionComplexExample() {
        let result = NoteTitle.cleanSuggestion("\"Title: My Shopping/Groceries List!\"")
        XCTAssertEqual(result, "My Shopping Groceries List")
    }

    func testCleanSuggestionCapitalizesFirstLetter() {
        let result = NoteTitle.cleanSuggestion("grocery list")
        XCTAssertEqual(result, "Grocery list")
    }

    // MARK: - needsSemanticTitle Tests

    func testNeedsSemanticTitleTrueForNilNamedByUserNewText() {
        let lastDigest = NoteTitle.digest("old text")
        let newText = "new text"
        let result = NoteTitle.needsSemanticTitle(namedByUser: nil, text: newText, lastDigest: lastDigest)
        XCTAssertTrue(result)
    }

    func testNeedsSemanticTitleTrueForFalseNamedByUserNewText() {
        let lastDigest = NoteTitle.digest("old text")
        let newText = "new text"
        let result = NoteTitle.needsSemanticTitle(namedByUser: false, text: newText, lastDigest: lastDigest)
        XCTAssertTrue(result)
    }

    func testNeedsSemanticTitleFalseWhenNamedByUserTrue() {
        let result = NoteTitle.needsSemanticTitle(namedByUser: true, text: "any text", lastDigest: nil)
        XCTAssertFalse(result)
    }

    func testNeedsSemanticTitleFalseForEmptyText() {
        let result = NoteTitle.needsSemanticTitle(namedByUser: false, text: "", lastDigest: nil)
        XCTAssertFalse(result)
    }

    func testNeedsSemanticTitleFalseWhenDigestUnchanged() {
        let text = "same text"
        let digest = NoteTitle.digest(text)
        let result = NoteTitle.needsSemanticTitle(namedByUser: false, text: text, lastDigest: digest)
        XCTAssertFalse(result)
    }

    func testNeedsSemanticTitleTrueWhenDigestChanges() {
        let lastDigest = NoteTitle.digest("old text")
        let newText = "different text"
        let result = NoteTitle.needsSemanticTitle(namedByUser: false, text: newText, lastDigest: lastDigest)
        XCTAssertTrue(result)
    }

    // MARK: - Mock NoteNamer Tests

    final class MockNamer: NoteNamer {
        let suggestion: String?
        private(set) var callCount = 0
        var isAvailable: Bool { true }

        init(suggestion: String?) {
            self.suggestion = suggestion
        }

        func suggestTitle(for text: String) async throws -> String? {
            callCount += 1
            return suggestion
        }
    }

    func testMockNamerIsAvailable() {
        let namer = MockNamer(suggestion: "Test")
        XCTAssertTrue(namer.isAvailable)
    }

    func testMockNamerReturnsCanmedSuggestion() async throws {
        let namer = MockNamer(suggestion: "My Title")
        let result = try await namer.suggestTitle(for: "test text")
        XCTAssertEqual(result, "My Title")
    }

    func testMockNamerReturnsNilSuggestion() async throws {
        let namer = MockNamer(suggestion: nil)
        let result = try await namer.suggestTitle(for: "test text")
        XCTAssertNil(result)
    }

    func testMockNamerCountsCalls() async throws {
        let namer = MockNamer(suggestion: "Result")
        XCTAssertEqual(namer.callCount, 0)
        _ = try await namer.suggestTitle(for: "text1")
        XCTAssertEqual(namer.callCount, 1)
        _ = try await namer.suggestTitle(for: "text2")
        XCTAssertEqual(namer.callCount, 2)
    }

    // MARK: - Persistence Tests

    func testNoteDocumentSemanticDigestRoundTrip() throws {
        var doc = NoteDocument()
        doc.semanticDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: encoded)

        XCTAssertEqual(decoded.semanticDigest, doc.semanticDigest)
    }

    func testNoteDocumentSemanticDigestNilEncoding() throws {
        var doc = NoteDocument()
        doc.semanticDigest = nil

        let encoded = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: encoded)

        XCTAssertNil(decoded.semanticDigest)
    }

    func testNotePackageWriteReadSemanticDigest() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let packageURL = tempDir.appendingPathComponent("Note.\(NotePackage.fileExtension)")
        var doc = NoteDocument()
        doc.semanticDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        try NotePackage.write(doc, to: packageURL)
        let read = try NotePackage.read(from: packageURL)

        XCTAssertEqual(read.semanticDigest, doc.semanticDigest)
    }

    func testOldJsonWithoutSemanticDigestDecodesToNil() throws {
        let oldJsonString = """
        {"version":1,"strokes":[],"textBlocks":[],"namedByUser":false}
        """
        let data = oldJsonString.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: data)

        XCTAssertNil(decoded.semanticDigest)
    }

    func testNoteAutosaverWritesSemanticDigest() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let model = CanvasModel()
        let autosaver = NoteAutosaver(model: model, url: url, delay: 10)

        autosaver.semanticDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        autosaver.markDirty()
        XCTAssertTrue(autosaver.flush())

        let doc = try NotePackage.read(from: url)
        XCTAssertEqual(doc.semanticDigest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testNoteAutosaverSemanticDigestNilFlush() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let model = CanvasModel()
        let autosaver = NoteAutosaver(model: model, url: url, delay: 10)

        autosaver.semanticDigest = nil
        autosaver.markDirty()
        XCTAssertTrue(autosaver.flush())

        let doc = try NotePackage.read(from: url)
        XCTAssertNil(doc.semanticDigest)
    }

    func testNoteAutosaverChangingSemanticDigest() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.\(NotePackage.fileExtension)")
        let model = CanvasModel()
        let autosaver = NoteAutosaver(model: model, url: url, delay: 10)

        let digest1 = NoteTitle.digest("first")
        autosaver.semanticDigest = digest1
        autosaver.markDirty()
        XCTAssertTrue(autosaver.flush())

        var doc = try NotePackage.read(from: url)
        XCTAssertEqual(doc.semanticDigest, digest1)

        let digest2 = NoteTitle.digest("second")
        autosaver.semanticDigest = digest2
        autosaver.markDirty()
        XCTAssertTrue(autosaver.flush())

        doc = try NotePackage.read(from: url)
        XCTAssertEqual(doc.semanticDigest, digest2)
    }

    // MARK: - Edge Cases

    func testCleanSuggestionWithCombinedPunctuation() {
        let result = NoteTitle.cleanSuggestion("Title: \"Multiple,\" / Punctuation!")
        XCTAssertEqual(result, "Multiple Punctuation")
    }

    func testNamingTextWithVeryLongLines() {
        let longLine = String(repeating: "x", count: 500)
        let blocks = [block(longLine, y: 0), block("Short", y: 10)]
        let result = NoteTitle.namingText(from: blocks, limit: 100)
        XCTAssertEqual(result.count, 100)
    }

    func testNamingTextMixedWhitespaceAndContent() {
        let blocks = [
            block("  \n  Content  \n  ", y: 0),
            block("\t\tTab\t\t", y: 10)
        ]
        let result = NoteTitle.namingText(from: blocks)
        XCTAssertEqual(result, "Content\nTab")
    }

    func testDigestWithUnicodeCharacters() {
        let digest1 = NoteTitle.digest("café")
        let digest2 = NoteTitle.digest("cafe")
        XCTAssertNotEqual(digest1, digest2)
    }

    func testNeedsSemanticTitleWithWhitespaceOnlyText() {
        let result = NoteTitle.needsSemanticTitle(namedByUser: false, text: "   \n  ", lastDigest: nil)
        XCTAssertFalse(result)
    }
}

// MARK: - Async Protocol Conformance Test

final class NoteNamerProtocolTests: XCTestCase {

    final class TestNamer: NoteNamer {
        var isAvailable: Bool = true

        func suggestTitle(for text: String) async throws -> String? {
            return "Test: \(text)"
        }
    }

    func testNoteNamerProtocolConformance() async throws {
        let namer = TestNamer()
        let result = try await namer.suggestTitle(for: "input")
        XCTAssertEqual(result, "Test: input")
    }

    func testNoteNamerProtocolUnavailable() {
        let namer = TestNamer()
        namer.isAvailable = false
        XCTAssertFalse(namer.isAvailable)
    }
}
