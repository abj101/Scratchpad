import XCTest
@testable import CanvasKit

final class ScribeAlignmentTests: XCTestCase {
    private func dictionary(_ words: Set<String>) -> (String) -> Bool {
        { words.contains($0.lowercased()) }
    }

    /// Case-exact lexicon: `words` known in lowercase, `names` known only capitalized ("Ayush"),
    /// like a dictionary with proper nouns.
    private func lexicon(_ words: Set<String>, names: Set<String>) -> (String) -> Bool {
        { words.contains($0) || names.contains($0) }
    }

    func testSingleLetterRepairs() {
        let isWord = dictionary(["hello", "world", "friend", "there"])
        let cases = [
            ("helo", "hello"),       // missing letter
            ("helllo", "hello"),     // extra letter
            ("jello", "hello"),      // wrong letter
            ("wurld", "world"),      // wrong letter
        ]

        for (raw, polished) in cases {
            XCTAssertTrue(ScribePolish.accepts(polished: polished, raw: raw, isWord: isWord), "\(raw) → \(polished)")
        }
    }

    func testIndependentOneLetterRepairsDoNotPoolTheirBudgets() {
        let isWord = dictionary(["hello", "world", "friend", "there"])
        XCTAssertTrue(ScribePolish.accepts(polished: "hello world", raw: "helo wurld", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "there friend", raw: "ther frend", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "there friend", raw: "therxx frend", isWord: isWord))
    }

    func testSplitAndMergeRepairs() {
        let isWord = dictionary(["hello", "world", "how", "are", "you"])
        XCTAssertTrue(ScribePolish.accepts(polished: "hello world", raw: "helloworld", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "hello, world!", raw: "hellowrld", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "How are you?", raw: "howar you", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "How are you?", raw: "Howar you", isWord: isWord))
    }

    func testSpacingChangesRequireAnUnknownSourceWord() {
        let isWord = dictionary(["into", "in", "to", "the", "room", "hello", "world"])
        XCTAssertFalse(ScribePolish.accepts(polished: "in to the room", raw: "into the room", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "hello, world!", raw: "helloworld", isWord: isWord))
    }

    func testRejectsLargeEditsAndWordInsertionsDeletionsOrReordering() {
        let isWord = dictionary(["hello", "there", "friend", "red", "blue", "today"])
        let rejected = [
            ("hello", "goodbye"),
            ("there", "therxx"),
            ("hello there", "hello"),
            ("hello", "hello there"),
            ("blue red", "red blue"),
            ("hello today", "hello friend today"),
        ]

        for (polished, raw) in rejected {
            XCTAssertFalse(ScribePolish.accepts(polished: polished, raw: raw, isWord: isWord), "\(raw) → \(polished)")
        }
    }

    func testFixesRealWordMisreadsWithinOneEdit() {
        // The polisher is trusted with one-letter real-word fixes; larger edits and names are not.
        let isWord = dictionary(["i", "came", "from", "form", "home", "how", "hove", "cat", "bat", "met", "bill", "will"])
        XCTAssertTrue(ScribePolish.accepts(polished: "I came from home", raw: "I came form home", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "bat", raw: "cat", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "how", raw: "hove", isWord: isWord)) // two edits
        // A capital away from a sentence start is a name: its letters stay.
        XCTAssertFalse(ScribePolish.accepts(polished: "I met Bill", raw: "I met Will", isWord: isWord))
    }

    func testAcceptsAdjacentLetterTranspositionButKeepsNumbers() {
        let isWord = dictionary(["the", "science", "received", "fried", "cat", "i", "have", "cats"])
        XCTAssertTrue(ScribePolish.accepts(polished: "the", raw: "teh", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "science", raw: "sceince", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "received", raw: "recieved", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "fried", raw: "frend", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "I have 2 cats!", raw: "I have 2 cats", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "I have 3 cats", raw: "I have 2 cats", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "I have cats", raw: "I have 2 cats", isWord: isWord))
    }

    func testEditBudgetIsNotPooledAcrossAGroup() {
        let isWord = dictionary(["cat", "bat", "hello", "world"])
        XCTAssertTrue(ScribePolish.accepts(polished: "bat hello world", raw: "cat helloworld", isWord: isWord))
        // "wurld" is no word, so the split group is reverted and the real-word fix stays.
        XCTAssertEqual(ScribePolish.merge(polished: "bat hello wurld", raw: "cat helloworld", isWord: isWord),
                       "bat helloworld")
    }

    func testPreservesVersionsAndIdentifierNumbers() {
        let isWord = dictionary(["build", "ticket", "release"])
        XCTAssertTrue(ScribePolish.accepts(polished: "Build v1.2.3!", raw: "Build v1.2.3", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Build v1.2.4", raw: "Build v1.2.3", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "Ticket AB-123.", raw: "Ticket AB-123", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Ticket AB-12", raw: "Ticket AB-123", isWord: isWord))
    }

    func testKeepsAyushWholeWhileRepairingNearbyWords() {
        let isWord = lexicon(["hi", "how", "are", "you", "my", "name", "is"], names: ["Ayush"])

        XCTAssertFalse(ScribePolish.accepts(polished: "Ayu sh", raw: "Ayush", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Hi Ayu, how are you", raw: "Hi Ayush howar you", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "Hi Ayush, how are you", raw: "Hi Ayush howar you", isWord: isWord))
        // The altered name reverts; the good "howar" → "how are" stays.
        XCTAssertEqual(ScribePolish.merge(polished: "Hi Ayu, how are you", raw: "Hi Ayush howar you", isWord: isWord),
                       "Hi Ayush, how are you")
        XCTAssertEqual(ScribePolish.merge(polished: "Hi Ayu sh, how are you", raw: "Hi Ayush howar you", isWord: isWord),
                       "Hi Ayush, how are you")
    }

    func testAyushNeverAlteredWhateverTheDictionaryKnows() {
        let known: Set<String> = ["my", "name", "is", "ayu", "how", "are", "you", "hi", "she", "a"]
        for isWord in [lexicon(known, names: []), lexicon(known, names: ["Ayush"])] {
            for raw in ["Ayush", "ayush"] {
                for polished in ["Ayu sh", "Ayuah", "Ayus", "Ayu", "A yush"] {
                    XCTAssertNil(ScribePolish.merge(polished: polished, raw: raw, isWord: isWord), "\(raw) → \(polished)")
                    let sentence = ScribePolish.merge(polished: "My name is \(polished)", raw: "My name is \(raw)", isWord: isWord)
                    // Letters are kept; a reverted name may take the polished capital.
                    XCTAssertEqual(sentence?.lowercased(), "my name is \(raw.lowercased())", "\(raw) → \(polished)")
                }
            }
        }
    }

    func testProtectsLowercaseNameWhenDictionaryHasCapitalizedEvidence() {
        // Lowercase unknown names are indistinguishable from typos without this evidence.
        let isWord: (String) -> Bool = { word in
            word == "Vian" || ["my", "name", "is", "van"].contains(word.lowercased())
        }
        XCTAssertFalse(ScribePolish.accepts(polished: "my name is van", raw: "my name is vian", isWord: isWord))
    }

    func testOrdinaryCapitalizationAndPunctuationRemainAllowed() {
        let isWord = dictionary(["hello", "there"])
        XCTAssertTrue(ScribePolish.accepts(polished: "Hello, there!", raw: "hello there", isWord: isWord))
        // Capitals the writer chose are kept: lowering one is not accepted as-is.
        XCTAssertFalse(ScribePolish.accepts(polished: "hello there", raw: "Hello there", isWord: isWord))
    }

    func testUnknownLowercaseWordMayBeCapitalizedAsAName() {
        let isWord = dictionary(["i", "met", "my", "name", "is", "and", "how", "are", "you"])
        XCTAssertTrue(ScribePolish.accepts(polished: "I met Zara", raw: "i met zara", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "My name is Ayush, and how are you?",
                                           raw: "My name is ayush and howar you", isWord: isWord))
        // Capitalizing is fine; changing the letters of an unknown word is not.
        XCTAssertFalse(ScribePolish.accepts(polished: "I met Zora", raw: "i met zara", isWord: isWord))
    }

    func testHowarYouBecomesHowAreYou() {
        let isWord = dictionary(["how", "are", "you"])
        XCTAssertTrue(ScribePolish.accepts(polished: "How are you", raw: "howar you", isWord: isWord))
        XCTAssertEqual(ScribePolish.merge(polished: "How are you", raw: "howar you", isWord: isWord), "How are you")
    }

    func testRejectedGroupsRevertWhileGoodGroupsStay() {
        let isWord = dictionary(["how", "are", "you", "today", "my", "friend", "from", "form", "came", "i"])
        // "howar" → "how are" stays; the rewrite "friend" → "buddy" reverts.
        XCTAssertEqual(ScribePolish.merge(polished: "Hey how are you buddy", raw: "hey howar you friend", isWord: isWord),
                       "Hey how are you friend")
        XCTAssertEqual(ScribePolish.merge(polished: "How are you, buddy?", raw: "howar you friend", isWord: isWord),
                       "How are you, friend?")
        XCTAssertFalse(ScribePolish.accepts(polished: "How are you, buddy?", raw: "howar you friend", isWord: isWord))
        // A reverted first word keeps the polished sentence-start capital.
        XCTAssertEqual(ScribePolish.merge(polished: "Buddy how are you", raw: "friend howar you", isWord: isWord),
                       "Friend how are you")
        // Inserted words drop out, deleted words come back, a reordering reverts.
        XCTAssertEqual(ScribePolish.merge(polished: "How are you today", raw: "howar you", isWord: isWord), "How are you")
        XCTAssertEqual(ScribePolish.merge(polished: "How are.", raw: "howar you", isWord: isWord), "How are you.")
        XCTAssertEqual(ScribePolish.merge(polished: "you how", raw: "how you", isWord: isWord), "how you")
    }

    func testMergeIsNilWhenNothingIsAccepted() {
        let isWord = dictionary(["hello", "goodbye"])
        XCTAssertNil(ScribePolish.merge(polished: "Goodbye", raw: "hello", isWord: isWord))
        XCTAssertNil(ScribePolish.merge(polished: "!!!", raw: "hello", isWord: isWord))
        XCTAssertNil(ScribePolish.merge(polished: "", raw: "hello", isWord: isWord))
        XCTAssertNil(ScribePolish.merge(polished: "hello", raw: "", isWord: isWord))
    }

    func testNumbersAreRestoredPerGroup() {
        let isWord = dictionary(["i", "have", "cats", "dogs"])
        XCTAssertEqual(ScribePolish.merge(polished: "I have 3 cats", raw: "i have 2 cats", isWord: isWord), "I have 2 cats")
        XCTAssertEqual(ScribePolish.merge(polished: "I have cats", raw: "i have 2 cats", isWord: isWord), "I have 2 cats")
        XCTAssertEqual(ScribePolish.merge(polished: "I have 2 dogs", raw: "i have 2 dogs", isWord: isWord), "I have 2 dogs")
    }

    func testSpacingChangesNeedAnUnknownRawWord() {
        let isWord = dictionary(["into", "in", "to", "the", "room", "how", "are", "you"])
        XCTAssertEqual(ScribePolish.merge(polished: "in to the room", raw: "into the room", isWord: isWord),
                       "into the room")
        XCTAssertEqual(ScribePolish.merge(polished: "How are you", raw: "howar you", isWord: isWord), "How are you")
    }
}

final class ScribeCapitalTests: XCTestCase {
    private let isWord: (String) -> Bool = { ["i", "love", "apple", "pie", "meet", "me", "in", "paris", "the", "big",
                                              "hello", "there", "met", "came", "from", "home"].contains($0.lowercased()) }

    func testPolishNeverLowercasesWrittenCapitals() {
        let cases = [("I love Apple pie", "I love apple pie", "I love Apple pie"),
                     ("Meet me in Paris", "Meet me in paris", "Meet me in Paris"),
                     ("I met Zorbith", "I met zorbith", "I met Zorbith"),
                     ("HELLO there", "Hello there", "HELLO there"),
                     ("The Big Apple", "The big apple", "The Big Apple"),
                     ("Hellp there", "hello there", "Hello there")]
        for (raw, polished, expected) in cases {
            XCTAssertEqual(ScribePolish.merge(polished: polished, raw: raw, isWord: isWord), expected, raw)
        }
    }

    func testPolishMayStillAddCapitals() {
        XCTAssertEqual(ScribePolish.merge(polished: "I met Zara.", raw: "i met zara", isWord: isWord), "I met Zara.")
    }

    func testMixedCaseWordsStayWhole() {
        let lexicon = ScribeLexicon(isCommon: { ["is", "great", "phone", "bay"].contains($0) })
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "iPhone is great", context: "", lexicon: lexicon), "iPhone is great")
        XCTAssertEqual(ScribeSegmenter.segment("eBay", lexicon: lexicon), "eBay")
    }
}
