import XCTest
@testable import CanvasKit

final class MockPolisher: TextPolisher {
    var isAvailable = true
    var reply: String?
    private(set) var calls: [(raw: String, context: String)] = []
    init(reply: String?) { self.reply = reply }
    func polish(_ raw: String, context: String) async -> String? {
        calls.append((raw, context))
        return reply
    }
}

final class ScribePolishTests: XCTestCase {
    /// Lowercase words known; `names` known only capitalized, like a dictionary with proper nouns.
    private func lexicon(_ words: Set<String>, names: Set<String> = []) -> (String) -> Bool {
        { words.contains($0) || names.contains($0) }
    }

    private let common: Set<String> = ["hello", "there", "world", "how", "are", "you", "my", "name", "is", "hi",
                                       "beautiful", "day", "what", "a", "i", "met", "came", "from", "form", "home"]

    func testAcceptsFormattingChanges() {
        let isWord = lexicon(common)
        XCTAssertTrue(ScribePolish.accepts(polished: "Hello, world!", raw: "hello world", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "It's 5 o'clock.", raw: "its 5 oclock", isWord: isWord))
    }

    func testAcceptsSmallSpellingFixesRejectsRewrites() {
        let isWord = lexicon(common, names: ["Ayush"])
        XCTAssertTrue(ScribePolish.accepts(polished: "Hello there", raw: "helo ther", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Ayuah arrived", raw: "Ayush arrived", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Hello there", raw: "hello therxx", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Hello there my friend", raw: "hello there", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Goodbye", raw: "hello", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "!!!", raw: "hello", isWord: isWord))
    }

    func testWordEditsAreLimitedIndividually() {
        XCTAssertTrue(ScribePolish.accepts(polished: "hello world", raw: "hillo wurld", isWord: lexicon(["hello", "world"])))
        XCTAssertFalse(ScribePolish.accepts(polished: "ayous", raw: "ayush", isWord: { _ in false }))
        XCTAssertFalse(ScribePolish.accepts(polished: "aaaaaaaaaaaaaaaa", raw: String(repeating: "a", count: 20), isWord: { _ in true }))
        XCTAssertEqual(ScribePolish.distance(Array("kitten"), Array("sitting")), 3)
    }

    func testAcceptsContextualTypoAndSpacingRepair() {
        let isWord = lexicon(common, names: ["Ayush"])
        XCTAssertTrue(ScribePolish.accepts(polished: "How are you", raw: "howar you", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "How are you?", raw: "howar you", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "How are you?", raw: "Howar you", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "Hello world", raw: "Helloworld", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "Beautiful day", raw: "Bea utiful day", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "Hi Ayush, how are you?", raw: "Hi Ayush howar you", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "Hello, world!", raw: "helloworld", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "What a beautiful day", raw: "what a beautif ul day", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "I came from home", raw: "I came form home", isWord: isWord))
        // Correct words are not re-spaced, and splits must be real words.
        XCTAssertFalse(ScribePolish.accepts(polished: "in to the room", raw: "into the room",
                                            isWord: lexicon(["into", "in", "to", "the", "room"])))
        XCTAssertFalse(ScribePolish.accepts(polished: "How are you doing", raw: "howar you", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "How were you", raw: "howar you", isWord: isWord))
    }

    /// The only test that depends on this Mac's spell checker.
    func testSystemCheckerSmoke() {
        XCTAssertTrue(ScribePolish.accepts(polished: "How are you", raw: "howar you"))
    }

    func testRepairNeverSplitsOrRewritesNames() {
        // A mock dictionary that does not know the name at all.
        let isWord = lexicon(["my", "name", "is", "ayu", "how", "are", "you", "hi", "she"])
        XCTAssertFalse(ScribePolish.accepts(polished: "My name is ayu sh", raw: "My name is ayush", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Hi Ayu, how are you", raw: "Hi Ayush howar you", isWord: isWord))
        XCTAssertFalse(ScribePolish.accepts(polished: "Hi a yush", raw: "Hi ayush", isWord: isWord))
        XCTAssertTrue(ScribePolish.accepts(polished: "Hi ayush, how are you", raw: "hi ayush howar you", isWord: isWord))
        // Without name evidence an unknown lowercase word may still be capitalized as a name.
        XCTAssertTrue(ScribePolish.accepts(polished: "Hi Ayush, how are you", raw: "hi ayush howar you", isWord: isWord))
    }

    func testProcessAppliesContextualRepairButKeepsNames() async {
        let none: (String, String) -> String = { $1 }
        let isWord = lexicon(common, names: ["Ayush"])
        var r = await ScribePolish.process(raw: "howar you", context: "", polisher: MockPolisher(reply: "How are you"),
                                           isWord: isWord, autocorrect: none)
        XCTAssertTrue(r.accepted)
        XCTAssertEqual(r.final, "How are you")
        r = await ScribePolish.process(raw: ScribeText.formattedPhrase(raw: "howar you", context: ""), context: "",
                                       polisher: MockPolisher(reply: "How are you?"), isWord: isWord, autocorrect: none)
        XCTAssertTrue(r.accepted)
        XCTAssertEqual(r.final, "How are you?")
        // The altered name reverts; nothing else was wrong.
        r = await ScribePolish.process(raw: "My name is ayush", context: "",
                                       polisher: MockPolisher(reply: "My name is Ayu sh"), isWord: isWord, autocorrect: none)
        XCTAssertEqual(r.final, "My name is ayush")
        r = await ScribePolish.process(raw: "My name is ayush", context: "",
                                       polisher: MockPolisher(reply: "My name is Ayush."), isWord: isWord, autocorrect: none)
        XCTAssertTrue(r.accepted)
        XCTAssertEqual(r.final, "My name is Ayush.")
    }

    func testProcessKeepsGoodGroupsWhenAnotherIsRejected() async {
        let isWord = lexicon(common.union(["friend"]), names: ["Ayush"])
        let r = await ScribePolish.process(raw: "hi ayush howar you friend", context: "",
                                           polisher: MockPolisher(reply: "Hi Ayu, how are you buddy?"),
                                           isWord: isWord, autocorrect: { $1 })
        XCTAssertTrue(r.accepted)
        XCTAssertEqual(r.polished, "Hi Ayu, how are you buddy?")
        XCTAssertEqual(r.final, "Hi Ayush, how are you friend?")
    }

    func testPolishPreservesNameWordBoundaries() {
        let isWord = lexicon(common, names: ["Ayush"])
        for name in ["Ayush", "ayush"] {
            XCTAssertFalse(ScribePolish.accepts(polished: "Ayu sh", raw: name, isWord: isWord))
            XCTAssertFalse(ScribePolish.accepts(polished: "My name is Ayu sh", raw: "My name is \(name)", isWord: isWord))
            XCTAssertTrue(ScribePolish.accepts(polished: "My name is \(name).", raw: "My name is \(name)", isWord: isWord))
        }
        XCTAssertFalse(ScribePolish.accepts(polished: "My name is Ayush", raw: "My name is Ayu sh", isWord: isWord))
    }

    func testStartsSentence() {
        XCTAssertTrue(ScribePolish.startsSentence(after: ""))
        XCTAssertTrue(ScribePolish.startsSentence(after: "Hi there. "))
        XCTAssertTrue(ScribePolish.startsSentence(after: "Done!"))
        XCTAssertTrue(ScribePolish.startsSentence(after: "Why?"))
        XCTAssertTrue(ScribePolish.startsSentence(after: "line\n"))
        XCTAssertFalse(ScribePolish.startsSentence(after: "Hi there"))
        XCTAssertFalse(ScribePolish.startsSentence(after: "Hi,"))
    }

    func testFallbackCapitalizesAtSentenceStart() {
        XCTAssertEqual(ScribePolish.fallback(raw: "hello world", context: ""), "Hello world")
        XCTAssertEqual(ScribePolish.fallback(raw: "next one", context: "Done. "), "Next one")
        XCTAssertEqual(ScribePolish.fallback(raw: "and more", context: "Hello"), "and more")
    }

    func testApplyingEditsInsidePieceBackwards() {
        // "Hi. helo wrld" with piece "helo wrld" at 4...
        let full = "Hi. helo wrld"
        let piece = NSRange(location: 4, length: 9)
        let edits: [(range: NSRange, replacement: String)] = [
            (NSRange(location: 4, length: 4), "hello"), (NSRange(location: 9, length: 4), "world!")]
        XCTAssertEqual(ScribePolish.applying(edits, to: full, within: piece), "hello world!")
    }

    func testApplyingSkipsOutsideAndOverlappingEdits() {
        let full = "Hi. helo wrld"
        let piece = NSRange(location: 4, length: 9)
        let edits: [(range: NSRange, replacement: String)] = [
            (NSRange(location: 0, length: 2), "Yo"),          // in the context
            (NSRange(location: 2, length: 4), "xx"),          // straddles the piece start
            (NSRange(location: 4, length: 4), "hello"),
            (NSRange(location: 4, length: 4), "other"),       // same range, later: skipped
            (NSRange(location: 6, length: 5), "zzzzz"),       // overlaps accepted
            (NSRange(location: 11, length: 5), "nope"),       // past the end
            (NSRange(location: NSNotFound, length: 0), "x")]
        XCTAssertEqual(ScribePolish.applying(edits, to: full, within: piece), "hello wrld")
        XCTAssertEqual(ScribePolish.applying([], to: full, within: piece), "helo wrld")
    }

    func testContextIsLastCharacters() {
        let long = String(repeating: "a", count: 500) + "end"
        XCTAssertEqual(ScribePolish.context(from: long).count, ScribePolish.contextLimit)
        XCTAssertTrue(ScribePolish.context(from: long).hasSuffix("end"))
    }

    func testSeparatorBeforePiece() {
        XCTAssertEqual(ScribeText.separator(before: "hi", piece: "there"), " ")
        XCTAssertEqual(ScribeText.separator(before: "hi", piece: ", there"), "")
        XCTAssertEqual(ScribeText.separator(before: "hi", piece: "."), "")
        XCTAssertEqual(ScribeText.separator(before: "", piece: "hi"), "")
        XCTAssertEqual(ScribeText.separator(before: "hi\n", piece: "there"), "")
    }

    func testProcessUsesAcceptedPolish() async {
        let polisher = MockPolisher(reply: "Hello, world.")
        let r = await ScribePolish.process(raw: "hello world", context: "", polisher: polisher,
                                           isWord: lexicon(common), autocorrect: { $1 })
        XCTAssertEqual(r.final, "Hello, world.")
        XCTAssertTrue(r.accepted)
        XCTAssertEqual(polisher.calls.first?.context, "")
    }

    func testProcessAutocorrectsChosenText() async {
        var seen: [(String, String)] = []
        let fix: (String, String) -> String = { seen.append(($0, $1)); return $1.replacingOccurrences(of: "Helo", with: "Hello") }
        let r = await ScribePolish.process(raw: "helo", context: "Hi. ", polisher: nil, autocorrect: fix)
        XCTAssertEqual(seen.first?.0, "Hi. ")
        XCTAssertEqual(seen.first?.1, "Helo")
        XCTAssertEqual(r.final, "Hello")
        XCTAssertEqual(r.autocorrected, "Hello")
    }

    func testSystemAutocorrectPreservesLowercaseName() {
        XCTAssertEqual(ScribePolish.systemAutocorrect("I met", "ayush"), "ayush")
    }

    func testProcessFallsBackOnRejectedNilOrUnavailable() async {
        let none: (String, String) -> String = { $1 }
        let rewrite = MockPolisher(reply: "Something else entirely")
        var r = await ScribePolish.process(raw: "hello world", context: "", polisher: rewrite, isWord: lexicon(common), autocorrect: none)
        XCTAssertEqual(r.final, "Hello world")
        XCTAssertFalse(r.accepted)
        XCTAssertEqual(r.polished, "Something else entirely")

        r = await ScribePolish.process(raw: "hello", context: "Hi ", polisher: MockPolisher(reply: nil), autocorrect: none)
        XCTAssertEqual(r.final, "hello")

        let off = MockPolisher(reply: "Hello")
        off.isAvailable = false
        r = await ScribePolish.process(raw: "hello", context: "", polisher: off, autocorrect: none)
        XCTAssertEqual(r.final, "Hello")
        XCTAssertTrue(off.calls.isEmpty)

        r = await ScribePolish.process(raw: "hello", context: "", polisher: nil, autocorrect: none)
        XCTAssertEqual(r.final, "Hello")
    }

    func testQueuePopReadyLimit() {
        var q = ScribeQueue()
        let a = q.enqueuePending(), b = q.enqueuePending()
        q.complete(b, text: "two")
        XCTAssertTrue(q.popReady(limit: 1).isEmpty) // a still pending: order kept
        q.complete(a, text: "one")
        XCTAssertEqual(q.popReady(limit: 1), ["one"])
        XCTAssertEqual(q.popReady(limit: 1), ["two"])
    }

    func testWritingLayoutFreeRect() {
        let free = WritingLayout.freeRect(visible: CGRect(x: 100, y: 200, width: 1000, height: 800), magnification: 2,
                                          top: 60, bottom: 200, left: 48)
        XCTAssertEqual(free, CGRect(x: 124, y: 230, width: 976, height: 670))
    }

    func testBlockOriginClearOfChromeAndBelowContent() {
        let free = CGRect(x: 48, y: 60, width: 900, height: 500)
        let size = CGSize(width: 300, height: 28)
        var r = ScribeText.blockOrigin(free: free, size: size, content: [], gap: 28)
        XCTAssertEqual(r.origin, CGPoint(x: 48, y: 60))
        XCTAssertFalse(r.needsScroll)
        // Content behind the toolbar (above `free`) doesn't count; content in `free` does.
        r = ScribeText.blockOrigin(free: free, size: size, content: [CGRect(x: 60, y: 0, width: 200, height: 50)], gap: 28)
        XCTAssertEqual(r.origin.y, 60)
        r = ScribeText.blockOrigin(free: free, size: size, content: [CGRect(x: 60, y: 100, width: 200, height: 100)], gap: 28)
        XCTAssertEqual(r.origin.y, 228)
        r = ScribeText.blockOrigin(free: free, size: size, content: [CGRect(x: 60, y: 400, width: 200, height: 150)], gap: 28)
        XCTAssertEqual(r.origin.y, 578)
        XCTAssertTrue(r.needsScroll)
    }
}

final class ScribeSentenceRangeTests: XCTestCase {
    func testRecentSentence() {
        let text = "Hello there. how are you"
        let r = ScribePolish.recentSentenceRange(in: text)!
        XCTAssertEqual((text as NSString).substring(with: r), "how are you")
        XCTAssertEqual((("One\ntwo three" as NSString)).substring(with: ScribePolish.recentSentenceRange(in: "One\ntwo three")!), "two three")
        XCTAssertNil(ScribePolish.recentSentenceRange(in: "  "))
    }

    func testFormattedSmartInsert() {
        let id: (String, String) -> String = { $1 }
        func f(_ raw: String, _ ctx: String) -> String { ScribeText.formatted(raw: raw, context: ctx, autocorrect: id) }
        XCTAssertEqual(f("hello", ""), "Hello")
        XCTAssertEqual(f("world", "Hello"), " world")
        XCTAssertEqual(f(".", "Hello"), ".")
        XCTAssertEqual(f(",", "Hello"), ",")
        XCTAssertEqual(f("next", "Hello."), " Next")
        XCTAssertEqual(f("next", "Hello.\n"), "Next")
        XCTAssertEqual(f("word", "(") , "Word")
        XCTAssertEqual(f(")", "(word"), ")")
        XCTAssertEqual(f("i", "so"), " I")
        XCTAssertEqual(f("i'm", "so,"), " I'm")
        XCTAssertEqual(f("hi", "Ok"), " hi")
        XCTAssertEqual(f("  ", "Ok"), "")
    }

    // MARK: Segmenter

    private let words: Set<String> = ["hello", "world", "how", "are", "you", "the", "cat", "into", "in", "to", "this", "is", "a", "test", "write", "writing", "i", "am"]
    private func seg(_ s: String) -> String { ScribeText.segmented(s, isWord: { self.words.contains($0) }) }

    func testSegmenterSplitsGluedWords() {
        XCTAssertEqual(seg("helloworld"), "hello world")
        XCTAssertEqual(seg("howareyou"), "how are you")
        XCTAssertEqual(seg("thecatintothe"), "the cat into the")
        XCTAssertEqual(seg("thisisatest"), "this is a test")
    }

    func testSegmenterKeepsSpacesPunctuationAndDigits() {
        XCTAssertEqual(seg("hello worldhow"), "hello world how")
        XCTAssertEqual(seg("helloworld,howareyou?"), "hello world,how are you?")
        XCTAssertEqual(seg("test123thecat"), "test123the cat")
    }

    func testSegmenterLeavesUnknownAndTails() {
        XCTAssertEqual(seg("xqzt"), "xqzt")
        XCTAssertEqual(seg("teh"), "teh")
        XCTAssertEqual(seg("helloworl"), "hello worl")
        let names: Set<String> = ["hi", "my", "name", "is"]
        XCTAssertEqual(ScribeText.segmented("himynameisayush", isWord: { names.contains($0) }), "hi my name is ayush")
        XCTAssertEqual(seg("hello"), "hello")
        XCTAssertEqual(seg(""), "")
    }

    func testFormattedPhrase() {
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "hello world i am", context: ""), "Hello world I am")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "how are you", context: "Hello."), " How are you")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "hello , world !", context: ""), "Hello, world!")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "  ", context: ""), "")
    }

    func testFormattedPhrasePreservesRecognizerTokens() {
        // The real spell checker accepts "ayu" but rejects "ayush" on this Mac.
        // These exercise the production formatter rather than a mock dictionary.
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "Ayush", context: ""), "Ayush")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "ayush", context: ""), "Ayush")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "My name is Ayush", context: ""), "My name is Ayush")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "ayush", context: "My name is"), " Ayush")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "Ayus", context: ""), "Ayus")
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "hi ayush", context: ""), "Hi Ayush")
    }

    func testFormattedPhraseRespacesOnlyCheckerSplits() {
        // Mock lexicon with known words for testing ScribeSegmenter behavior.
        let common: Set<String> = ["thank", "you", "so", "much", "how", "are"]
        let names: Set<String> = ["ayush"]
        let lexicon = ScribeLexicon(isCommon: { common.contains($0) },
                                    isKnownName: { names.contains($0.lowercased()) })

        // Complete known words are split immediately by the segmenter.
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "thankyou so much", context: "", lexicon: lexicon),
                       "Thank you so much")

        // With minimal lexicon, segmenter splits based on the system spell checker for unknown pieces.
        let minimal: Set<String> = ["so"]
        let lexiconMinimal = ScribeLexicon(isCommon: { minimal.contains($0) })
        let result = ScribeText.formattedPhrase(raw: "so thankyou", context: "", lexicon: lexiconMinimal)
        // The segmenter finds "than" and "kyou" or keeps "thankyou" whole depending on spell checker
        XCTAssertTrue(result == "So thankyou" || result == "So than kyou", "Got: \(result)")

        // howar and you are known; howar is not a real word and stays whole.
        let howarKnown: Set<String> = ["how", "are", "you", "howar"]
        let lexiconHowar = ScribeLexicon(isCommon: { howarKnown.contains($0) })
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "howar you", context: "", lexicon: lexiconHowar),
                       "Howar you")

        // Names are never split, and a known name is capitalized at once.
        let lexiconNames = ScribeLexicon(isCommon: { _ in false },
                                         isKnownName: { names.contains($0.lowercased()) })
        XCTAssertEqual(ScribeText.formattedPhrase(raw: "ayush", context: "Hi", lexicon: lexiconNames),
                       " Ayush")
    }
}

final class ScribeLockTests: XCTestCase {
    private let words: Set<String> = ["hello", "world", "how", "are", "you", "there", "goodbye"]
    private func isWord(_ word: String) -> Bool { words.contains(word) }

    func testConfidentRepairIsLockedAndSurvivesLaterPass() {
        let merged = ScribePolish.merge(polished: "Hello world", raw: "helo world", isWord: isWord)!
        let locks = ScribePolish.confidentLocks(raw: "helo world", merged: merged, isWord: isWord)
        XCTAssertEqual(locks, [ScribeLock(range: NSRange(location: 0, length: 5), text: "Hello")])

        // Words are appended after the lock: it still matches, and the open part skips it.
        let later = "Hello world how ar"
        let valid = ScribePolish.validLocks(locks, in: later)
        XCTAssertEqual(valid, locks)
        let open = ScribePolish.openRange(in: later, locks: valid)!
        XCTAssertEqual((later as NSString).substring(with: open), "world how ar")
        XCTAssertNil(ScribePolish.openRange(in: "Hello", locks: ScribePolish.validLocks(locks, in: "Hello")))
    }

    func testStaleLocksAreDropped() {
        let lock = ScribeLock(range: NSRange(location: 0, length: 5), text: "Hello")
        XCTAssertEqual(ScribePolish.validLocks([lock], in: "Hello there").count, 1)
        XCTAssertTrue(ScribePolish.validLocks([lock], in: "Help there").isEmpty)
        XCTAssertTrue(ScribePolish.validLocks([lock], in: "Hi").isEmpty)
    }

    func testOpenRangeWithoutLocksIsRecentSentence() {
        let text = "Goodbye. Hello world how"
        let open = ScribePolish.openRange(in: text, locks: [])!
        XCTAssertEqual((text as NSString).substring(with: open), "Hello world how")
    }

    func testLowConfidenceEditIsNotLocked() {
        // A rewrite, an inserted word, and a protected name are never locked.
        XCTAssertTrue(ScribePolish.confidentLocks(raw: "xqz world", merged: "Goodbye world", isWord: isWord).isEmpty)
        XCTAssertTrue(ScribePolish.confidentLocks(raw: "hello", merged: "hello there", isWord: isWord).isEmpty)
        let names: (String) -> Bool = { $0 == "Ayush" || self.isWord($0) }
        XCTAssertTrue(ScribePolish.confidentLocks(raw: "Ayush arrived", merged: "Ayuah arrived", isWord: names).isEmpty)
    }
}
