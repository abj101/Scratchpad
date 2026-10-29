import XCTest
@testable import CanvasKit

final class ScribeSegmenterTests: XCTestCase {
    private let common: Set<String> = [
        "hi", "my", "name", "is", "met", "today", "how", "are", "you", "thank", "so", "much", "went", "to", "the",
        "store", "can", "help", "me", "no", "where", "nowhere", "together", "note", "book", "notebook", "said",
        "hello", "world", "got", "her", "ther", "here", "version", "cat", "tail", "a", "i", "go",
    ]
    private let names: Set<String> = ["ayush"]
    /// "ayu" and "sh" are accepted as words by the system spell checker; the mock does too, as a trap.
    private let junk: Set<String> = ["ayu", "sh", "bea", "ul"]

    private func lexicon(personal: Set<String> = []) -> ScribeLexicon {
        ScribeLexicon(isCommon: { self.common.contains($0) }, isKnownName: { self.names.contains($0.lowercased()) },
                      personalNames: personal)
    }

    private func seg(_ s: String, pauses: [Double]? = nil) -> String {
        ScribeSegmenter.segment(s, lexicon: lexicon(), pauses: pauses)
    }

    func testSplitsGluedSentences() {
        XCTAssertEqual(seg("HimynameisAyush"), "Hi my name is Ayush")
        XCTAssertEqual(seg("himynameisayush"), "hi my name is ayush")
        XCTAssertEqual(seg("Imetayushtoday"), "I met ayush today")
        XCTAssertEqual(seg("howareyou"), "how are you")
        XCTAssertEqual(seg("thankyousomuch"), "thank you so much")
        XCTAssertEqual(seg("iwenttothestore"), "i went to the store")
        XCTAssertEqual(seg("canyouhelpme"), "can you help me")
    }

    func testKnownWholeWordsAreNeverSplit() {
        for word in ["nowhere", "together", "notebook", "Ayush", "ayush"] { XCTAssertEqual(seg(word), word) }
    }

    func testUnknownChunksStayWhole() {
        XCTAssertEqual(seg("howar"), "howar")
        XCTAssertEqual(seg("Zorbith"), "Zorbith")
        XCTAssertEqual(seg("Zorbithsaidhi"), "Zorbith said hi")
        XCTAssertEqual(seg("Zorbithsaidhi".lowercased()), "zorbith said hi")
        XCTAssertEqual(seg("xyzq"), "xyzq")
    }

    func testJunkFragmentsNeverSplitAName() {
        // A mock where only a bare checker would accept the fragments: they are not in the lexicon.
        XCTAssertFalse(junk.contains { common.contains($0) })
        XCTAssertEqual(seg("Ayush"), "Ayush")
        let unknownName = ScribeLexicon(isCommon: { self.common.contains($0) })
        XCTAssertEqual(ScribeSegmenter.segment("Ayush", lexicon: unknownName), "Ayush")
        XCTAssertEqual(ScribeSegmenter.segment("himynameisAyush", lexicon: unknownName), "hi my name is Ayush")
        XCTAssertEqual(ScribeSegmenter.segment("hisayush", lexicon: unknownName), "his ayush")
        XCTAssertEqual(ScribeSegmenter.segment("Isabel", lexicon: unknownName), "Isabel")
    }

    func testPersonalNamesCountAsKnown() {
        let lex = lexicon(personal: ["zorbith"])
        XCTAssertEqual(ScribeSegmenter.segment("Zorbith", lexicon: lex), "Zorbith")
        XCTAssertEqual(ScribeSegmenter.segment("hizorbithtoday", lexicon: lex), "hi zorbith today")
    }

    func testInnerCapitalIsABoundary() {
        XCTAssertEqual(seg("MynameisZorbith"), "My name is Zorbith")
        XCTAssertEqual(seg("GotZorbithToday"), "Got Zorbith Today")
        // All caps has no inner boundaries.
        XCTAssertEqual(seg("NASA"), "NASA")
    }

    func testDigitsPunctuationAndSpacesArePreserved() {
        XCTAssertEqual(seg("hello,worldhowareyou!"), "hello,world how are you!")
        XCTAssertEqual(seg("version2.0"), "version2.0")
        XCTAssertEqual(seg("thankyou   so\nmuch"), "thank you so much")
        XCTAssertEqual(seg("don'tgo"), "don't go")
        XCTAssertEqual(seg(""), "")
    }

    func testUnfinishedTailsStayWhole() {
        XCTAssertEqual(seg("hellowo"), "hellowo")
        XCTAssertEqual(seg("hellowor"), "hellowor")
        XCTAssertEqual(seg("helloworl"), "hello worl")
        XCTAssertEqual(seg("thankyou"), "thank you")
        XCTAssertEqual(seg("hello"), "hello")
    }

    func testCandidatesAreDistinctAndOrdered() {
        let c = ScribeSegmenter.candidates("hereto", lexicon: lexicon(), limit: 3)
        XCTAssertGreaterThanOrEqual(c.count, 2)
        XCTAssertEqual(Set(c.map(\.text)).count, c.count)
        XCTAssertEqual(c.map(\.cost), c.map(\.cost).sorted())
        XCTAssertEqual(c.first?.text, "here to")
        XCTAssertEqual(ScribeSegmenter.candidates("howareyou", lexicon: lexicon(), limit: 1).count, 1)
        XCTAssertEqual(ScribeSegmenter.candidates("ab cd", lexicon: lexicon(), limit: 3).first?.text, "ab cd")
    }

    func testPausePriorMovesBoundaryBetweenEquallyPlausibleSplits() {
        // Both "ab cd" and "abc d"-style splits are unknown-chunk costs; known pieces make a tie.
        let lex = ScribeLexicon(isCommon: { ["cat", "tail", "cattail", "ca", "ttail"].contains($0) && $0 != "cattail" })
        // "cattail" has two parses: "cat tail" (9.7+9.6) and "ca ttail" (9.8+9.4): "cat tail" is slightly cheaper.
        XCTAssertEqual(ScribeSegmenter.segment("cattail", lexicon: lex), "cat tail")
        // A long pause before the second "t" (index 3 is 't' of tail; index 2 is the 't' of cat's end)
        // pulls the boundary to index 2.
        var pauses = Array(repeating: 0.2, count: 7)
        pauses[2] = 1.2
        XCTAssertEqual(ScribeSegmenter.segment("cattail", lexicon: lex, pauses: pauses), "ca ttail")
        // Mismatched counts are ignored.
        XCTAssertEqual(ScribeSegmenter.segment("cattail", lexicon: lex, pauses: [0.2, 1.2]), "cat tail")
    }

    func testPersonalNamesFromText() {
        let names = ScribeSegmenter.personalNames(in: ["Hello. Ayush met Zorbith on Monday. We saw Bob", "Fine\nBeth is here"])
        XCTAssertTrue(names.contains("zorbith"))
        XCTAssertTrue(names.contains("monday"))
        XCTAssertFalse(names.contains("ayush"))   // sentence start
        XCTAssertFalse(names.contains("hello"))
        XCTAssertFalse(names.contains("al"))      // too short
        XCTAssertFalse(names.contains("beth"))    // line start
    }

    /// Uses this Mac's embedding and spell checker; the names are the whole point of the segmenter.
    func testSystemLexiconSmoke() {
        let s = ScribeLexicon.system
        XCTAssertEqual(ScribeSegmenter.segment("HimynameisAyush", lexicon: s), "Hi my name is Ayush")
        XCTAssertEqual(ScribeSegmenter.segment("howareyou", lexicon: s), "how are you")
        XCTAssertEqual(ScribeSegmenter.segment("nowhere", lexicon: s), "nowhere")
        XCTAssertNotEqual(ScribeSegmenter.segment("Ayush", lexicon: s), "Ayu sh")
        XCTAssertEqual(ScribeSegmenter.segment("Imetayushtoday", lexicon: s), "I met ayush today")
        XCTAssertEqual(ScribeSegmenter.segment("Zorbithsaidhi", lexicon: s), "Zorbith said hi")
        for name in ["Alice", "Isabel", "Antonio", "howar"] { XCTAssertEqual(ScribeSegmenter.segment(name, lexicon: s), name) }
    }
}
