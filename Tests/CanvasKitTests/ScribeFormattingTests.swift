import XCTest
@testable import CanvasKit

final class ScribeFormattingTests: XCTestCase {
    /// Knows no words beyond the segmenter's function words, so tokens are only split at those.
    private let bare = ScribeLexicon(isCommon: { _ in false })

    func testPhraseFormattingPreservesNameAndTokenBoundaries() {
        let cases: [(raw: String, context: String, expected: String)] = [
            ("Ayush", "", "Ayush"),
            ("ayush", "", "Ayush"),
            ("My name is Ayush", "", "My name is Ayush"),
            ("Ayush", "Hi", " Ayush"),
            ("Alice and London", "", "Alice and London"),
        ]
        for test in cases {
            XCTAssertEqual(ScribeText.formattedPhrase(raw: test.raw, context: test.context, lexicon: bare),
                           test.expected, "raw=\(test.raw), context=\(test.context)")
        }
    }

    func testPolishCanRepairSmallTyposWithoutSplittingKnownNames() {
        let words: Set<String> = ["how", "are", "you", "hello", "there", "my", "name", "is", "ayu", "sh"]
        let isWord: (String) -> Bool = { words.contains($0.lowercased()) }
        let cases: [(polished: String, raw: String, expected: Bool)] = [
            ("How are you", "howar you", true),
            ("Hello there", "helo ther", true),
            ("Hello there", "hello therxx", false),
            ("My name is Ayu sh", "My name is Ayush", false),
            ("My name is Ayush", "My name is Ayush", true),
        ]
        for test in cases {
            XCTAssertEqual(ScribePolish.accepts(polished: test.polished, raw: test.raw, isWord: isWord),
                           test.expected, "raw=\(test.raw), polished=\(test.polished)")
        }
    }

    func testNameProtectionUsesLexicalAndMidSentenceCapitalEvidence() {
        let nameOnlyDictionary: (String) -> Bool = { $0 == "Ayush" || $0 == "Alice" }
        XCTAssertEqual(ScribePolish.protectedNames(in: "Ayush", isWord: nameOnlyDictionary), [true])
        XCTAssertFalse(ScribePolish.accepts(polished: "hi", raw: "Li",
                                           isWord: { $0 == "Li" || $0 == "hi" }))
        XCTAssertEqual(ScribePolish.protectedNames(in: "I met Alice", isWord: { _ in false }),
                       [false, false, true])

        // Context alone cannot distinguish common words that also appear as names.
        // Keep this characterization so a change to name protection gets an explicit review.
        for ambiguous in ["Will", "Rose", "May"] {
            XCTAssertEqual(ScribePolish.protectedNames(in: ambiguous, isWord: { _ in false }), [false], ambiguous)
        }
    }

    func testPhraseFormattingPunctuationDigitsAndUnicode() {
        let cases: [(raw: String, expected: String)] = [
            ("hello , world !", "Hello, world!"),
            ("( hello )", "(Hello)"),
            ("don't stop", "Don't stop"),
            ("i'm ready", "I'm ready"),
            ("version 2.0!", "Version 2.0!"),
            ("café déjà", "Café déjà"),
            ("  \n\t", ""),
            ("", ""),
        ]
        for test in cases {
            XCTAssertEqual(ScribeText.formattedPhrase(raw: test.raw, context: "", lexicon: bare),
                           test.expected, "raw=\(test.raw)")
        }
    }

    func testPhraseFormattingAddsBoundaryBeforeFollowingDocumentText() {
        let insertion = ScribeText.formattedPhrase(raw: "new", context: "Hello ", following: "world")
        XCTAssertEqual("Hello " + insertion + "world", "Hello new world")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "hello", context: "", following: ")"),
                       "Hello")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "hello", context: "", following: " world"),
                       "Hello")
    }

    func testRespacingAndIncompleteFinalToken() {
        let words: Set<String> = ["thank", "you", "so", "much", "hello", "world"]
        let lexicon = ScribeLexicon(isCommon: { words.contains($0) })
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "thankyou so much", context: "", lexicon: lexicon),
                       "Thank you so much")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "Thankyousomuch", context: "Hi.", lexicon: lexicon),
                       " Thank you so much")
        // Complete words in the last token are split at once; an unknown tail stays whole.
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "thankyou Ayush", context: "",
                                                  lexicon: lexicon), "Thank you Ayush")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "thankyouso", context: "",
                                                  lexicon: lexicon), "Thank you so")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "helloworl", context: "",
                                                  lexicon: lexicon), "Hello worl")
        // A short unfinished fragment is never split off.
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "helloworldwo", context: "",
                                                  lexicon: lexicon), "Hello worldwo")
    }

    func testPausesSplitNamesAndFallBackWhenCountsDiffer() {
        let words: Set<String> = ["cat", "tail", "ca", "ttail"]
        let lexicon = ScribeLexicon(isCommon: { words.contains($0) })
        var pauses = Array(repeating: 0.2, count: 7)
        pauses[2] = 1.2
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "cattail", context: "", lexicon: lexicon), "Cat tail")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "cattail", context: "", lexicon: lexicon, pauses: pauses),
                       "Ca ttail")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "cattail", context: "", lexicon: lexicon, pauses: [1, 1]),
                       "Cat tail")
    }
}

final class ScribeNameCapitalTests: XCTestCase {
    private let lexicon = ScribeLexicon(isCommon: { ["hi", "my", "name", "is", "will", "met", "today"].contains($0) },
                                        isKnownName: { $0.lowercased() == "ayush" }, personalNames: ["zorbith"])

    func testKnownNamesAreCapitalizedImmediately() {
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "hi ayush", context: "", lexicon: lexicon), "Hi Ayush")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "himynameisayush", context: "", lexicon: lexicon), "Hi my name is Ayush")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "met zorbith today", context: "I", lexicon: lexicon), " met Zorbith today")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "(ayush)", context: "Hi", lexicon: lexicon), " (Ayush)")
    }

    func testCommonWordsAndUnknownWordsKeepTheirCase() {
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "will", context: "I", lexicon: lexicon), " will")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "howar", context: "I", lexicon: lexicon), " howar")
    }
}
