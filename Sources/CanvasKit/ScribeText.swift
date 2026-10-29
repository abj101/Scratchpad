import AppKit

/// Pure text edits and bookkeeping for Scribe mode: recognized words are appended
/// to a text block's attributed string and can be taken back out again, a word at a time.
public enum ScribeText {
    /// What a recognizer's output becomes: whitespace collapsed to single spaces,
    /// nil if nothing is left.
    public static func normalized(_ recognized: String?) -> String? {
        guard let recognized else { return nil }
        let words = recognized.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static let closingPunctuation = Set(",.;:!?)]}%'\u{2019}\u{201D}")
    static let openingPunctuation = Set("([{\u{201C}\u{2018}")

    /// What to insert after `context` for a recognized `raw` piece, in a few ms and without a model,
    /// like Scribble's smart insert: spacing (none before closing punctuation or after an opening
    /// one), a capital at a sentence start, a standalone "i" as "I", and the spell checker's fixes.
    public static func formatted(raw: String, context: String,
                                 autocorrect: (_ context: String, _ piece: String) -> String = ScribePolish.systemAutocorrect) -> String {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return "" }
        let isPunctuation = word.allSatisfy { !$0.isLetter && !$0.isNumber }
        func tidy(_ s: String) -> String {
            let fixed = s.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
            return ScribePolish.fallback(raw: fixed, context: context)
        }
        var piece = tidy(word)
        if !isPunctuation {
            let corrected = autocorrect(context, piece)
            if !corrected.isEmpty { piece = tidy(corrected) }
        }
        return separator(before: context, piece: piece) + piece
    }

    /// Common two-letter words; any other two-letter piece is not trusted as a word by the segmenter.
    static let commonShortWords: Set<String> = ["of", "to", "in", "is", "it", "on", "at", "as", "an", "be", "by", "do", "go",
                                                "he", "me", "my", "no", "so", "up", "us", "we", "or", "if", "am", "hi", "ok"]

    /// Whether lowercased `word` stands on its own as a word: single letters only "a" / "i",
    /// 2-letter words only if common, longer ones per `isWord`.
    static func isPlausibleWord(_ word: String, isWord: (String) -> Bool) -> Bool {
        switch word.count {
        case 0: return false
        case 1: return word == "a" || word == "i"
        case 2: return commonShortWords.contains(word)
        default: return isWord(word)
        }
    }

    /// Splits glued recognizer output ("helloworldhowareyou") into words. Existing spaces are kept,
    /// digits and punctuation stay attached where they were, and a run of letters is split by dynamic
    /// programming over `isWord` (lowercased): fewest pieces wins, then longer first pieces. Single
    /// letters count only as "a" / "i"; other 2-letter pieces only if common. A run that can't be fully
    /// split into words is left whole, except that it may end in one unknown tail (a word still being
    /// written) after at least 3 letters of known words.
    public static func segmented(_ glued: String, isWord: (String) -> Bool) -> String {
        glued.split(whereSeparator: \.isWhitespace).map { token in
            var out = "", run = ""
            func flush() { if !run.isEmpty { out += splitRun(run, isWord: isWord); run = "" } }
            for ch in token {
                if ch.isLetter || (ch == "'" || ch == "\u{2019}") && !run.isEmpty { run.append(ch) } else { flush(); out.append(ch) }
            }
            flush()
            return out
        }.joined(separator: " ")
    }

    private static func splitRun(_ run: String, isWord: (String) -> Bool) -> String {
        let chars = Array(run)
        let n = chars.count
        guard n >= 3, n <= 60 else { return run }
        func valid(_ s: ArraySlice<Character>) -> Bool { isPlausibleWord(String(s).lowercased(), isWord: isWord) }
        // best[i]: cheapest all-valid split of chars[0..<i] as (cost, previous index).
        var best = [(cost: Int, prev: Int)?](repeating: nil, count: n + 1)
        best[0] = (0, 0)
        for i in 1...n {
            for j in 0..<i {
                guard let b = best[j], valid(chars[j..<i]) else { continue }
                // 1000 per piece, a little extra for short pieces so "into" beats "in to".
                let cost = b.cost + 1000 + (i - j <= 2 ? 300 : 0) - (i - j)
                if best[i] == nil || cost < best[i]!.cost { best[i] = (cost, j) }
            }
        }
        func build(_ end: Int) -> [String] {
            var parts: [String] = [], i = end
            while i > 0, let b = best[i] { parts.append(String(chars[b.prev..<i])); i = b.prev }
            return parts.reversed()
        }
        if best[n] != nil { return build(n).joined(separator: " ") }
        // Keep the longest known prefix; the cost is useful for choosing its split,
        // but must not make us prefer a shorter prefix over a later one.
        var choice: (cost: Int, at: Int)?
        for j in 3..<n {
            guard let b = best[j], build(j).last?.count != 1,
                  choice == nil || j > choice!.at else { continue }
            choice = (b.cost, j)
        }
        guard let c = choice else { return run }
        return (build(c.at) + [String(chars[c.at...])]).joined(separator: " ")
    }

    /// Cached word test in the selected spelling language. Automatic language
    /// detection on isolated fragments can accept glued text as a foreign word.
    /// Main thread only.
    public static let systemIsWord: (String) -> Bool = { word in
        let checker = NSSpellChecker.shared
        let language = checker.language(), key = language + "\u{0}" + word
        if let known = wordCache[key] { return known }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        let ok = range.location == NSNotFound
        wordCache[key] = ok
        return ok
    }
    private static var wordCache: [String: Bool] = [:]

    /// Format recognizer tokens: capitals, spacing, and run-together tokens split into words at once
    /// by `ScribeSegmenter` ("HimynameisAyush" → "Hi my name is Ayush"). Unknown chunks stay whole, and
    /// letter fixes are left to the sentence polish. A final token still in progress needs no special
    /// case: its complete known words are split and an unfinished tail is an unknown chunk, so it stays
    /// whole. `pauses` (seconds before each non-whitespace character of `raw`, used only if the counts
    /// match) make boundaries at long pauses cheaper. Includes the separator before the first word.
    public static func formattedPhrase(raw: String, context: String,
                                       lexicon: ScribeLexicon = .system, pauses: [Double]? = nil) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let aligned = pauses.flatMap { $0.count == words.reduce(0) { $0 + $1.count } ? $0 : nil }
        let median = aligned.map(ScribeSegmenter.median)
        var ctx = context, out = "", offset = 0
        for word in words {
            let ctxTail = ScribePolish.context(from: ctx)
            let slice = aligned.map { Array($0[offset..<(offset + word.count)]) }
            offset += word.count
            let spaced = ScribeSegmenter.segment(word, lexicon: lexicon, pauses: slice, medianPause: median)
                .split(separator: " ").map { capitalizingName(String($0), lexicon: lexicon) }.joined(separator: " ")
            let piece = formatted(raw: spaced, context: ctxTail, autocorrect: { _, piece in piece })
            out += piece
            ctx += piece
        }
        return out
    }

    /// Formats a phrase inserted before existing text, adding a separator when
    /// the new phrase and the following text would otherwise join as one word.
    public static func formattedPhrase(raw: String, context: String, following: String,
                                       lexicon: ScribeLexicon = .system, pauses: [Double]? = nil) -> String {
        let phrase = formattedPhrase(raw: raw, context: context, lexicon: lexicon, pauses: pauses)
        return phrase + separator(after: phrase, before: following)
    }

    /// `word` capitalized when it is all lowercase and a known name ("ayush" → "Ayush"): the
    /// recognizer rarely keeps a trackpad capital, but the name is certain from the lexicon.
    static func capitalizingName(_ word: String, lexicon: ScribeLexicon) -> String {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 3, letters == letters.lowercased(), !lexicon.isCommon(letters),
              lexicon.personalNames.contains(letters) || lexicon.isKnownName(letters) else { return word }
        guard let i = word.firstIndex(where: \.isLetter) else { return word }
        return word.replacingCharacters(in: i...i, with: word[i].uppercased())
    }

    /// A single space unless `text` is empty or already ends in whitespace.
    public static func separator(before text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return "" }
        return " "
    }

    /// The separator before `piece` appended after `text`: none if `text` is empty or ends in
    /// whitespace, or `piece` starts with closing punctuation.
    public static func separator(before text: String, piece: String) -> String {
        guard let first = piece.first, !closingPunctuation.contains(first) else { return "" }
        guard let last = text.last, !openingPunctuation.contains(last) else { return "" }
        return separator(before: text)
    }

    /// The separator to add before existing text after inserting `text`.
    public static func separator(after text: String, before following: String) -> String {
        guard let first = following.first, !first.isWhitespace else { return "" }
        return separator(before: text, piece: String(first))
    }

    /// `piece` after `string`, in the attributes of its last character (or the
    /// defaults for empty text).
    public static func appending(_ piece: String, to string: NSAttributedString) -> NSAttributedString {
        let attributes = string.length > 0 ? string.attributes(at: string.length - 1, effectiveRange: nil)
                                           : TextFormatting.defaultAttributes
        let result = NSMutableAttributedString(attributedString: string)
        result.append(NSAttributedString(string: piece, attributes: attributes))
        return result
    }

    /// `string` without its last word: the trailing run of non-whitespace (punctuation attached
    /// to the word included) and the spaces before it. A trailing newline is removed alone, and
    /// newlines before the word are kept. Nil for empty text.
    public static func removingLastWord(from string: NSAttributedString) -> NSAttributedString? {
        let text = string.string as NSString
        guard text.length > 0 else { return nil }
        var end = text.length
        let isNewline = { (i: Int) in CharacterSet.newlines.contains(UnicodeScalar(text.character(at: i)) ?? " ") }
        let isSpace = { (i: Int) in CharacterSet.whitespaces.contains(UnicodeScalar(text.character(at: i)) ?? "a") }
        if isNewline(end - 1) {
            // "\r\n" is one line break.
            end -= end >= 2 && text.character(at: end - 2) == 13 && text.character(at: end - 1) == 10 ? 2 : 1
            return string.attributedSubstring(from: NSRange(location: 0, length: end))
        }
        while end > 0, isSpace(end - 1) { end -= 1 }
        while end > 0, !isSpace(end - 1), !isNewline(end - 1) { end -= 1 }
        while end > 0, isSpace(end - 1) { end -= 1 }
        return string.attributedSubstring(from: NSRange(location: 0, length: end))
    }

    /// The last `count` words of `text` (newlines kept as spaces), with a leading
    /// ellipsis if it was cut. Nil for blank text.
    public static func tail(of text: String, words count: Int) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, count > 0 else { return nil }
        let tail = words.suffix(count).joined(separator: " ")
        return words.count > count ? "…" + tail : tail
    }

    /// Where a new block goes: the top-left of `visible` inset by `inset`, pushed
    /// below every `obstacles` rect it would overlap.
    public static func newBlockOrigin(visible: CGRect, inset: CGFloat, size: CGSize,
                                      obstacles: [CGRect], gap: CGFloat) -> CGPoint {
        var origin = CGPoint(x: visible.minX + inset, y: visible.minY + inset)
        // Each pass moves below at least one obstacle, so this ends within `count` passes.
        for _ in 0...obstacles.count {
            let candidate = CGRect(origin: origin, size: size)
            guard let hit = obstacles.filter({ $0.intersects(candidate) }).max(by: { $0.maxY < $1.maxY }) else { break }
            origin.y = hit.maxY + gap
        }
        return origin
    }
}

extension ScribeText {
    /// Where a new block goes inside `free` (the visible area clear of the toolbar and panel):
    /// below the lowest of `content` visible in `free` (a `gap` below it), else at the top-left.
    /// `needsScroll` when the block's first line would end below `free`.
    public static func blockOrigin(free: CGRect, size: CGSize, content: [CGRect],
                                   gap: CGFloat) -> (origin: CGPoint, needsScroll: Bool) {
        let inFree = content.filter { $0.intersects(free) }
        var top = free
        if let lowest = inFree.map(\.maxY).max() { top.origin.y = max(free.minY, lowest + gap) }
        let origin = newBlockOrigin(visible: top, inset: 0, size: size, obstacles: content, gap: gap)
        return (origin, origin.y + size.height > free.maxY)
    }
}

/// Words waiting for recognition. Results can arrive in any order but are handed
/// out strictly in the order the words were queued; a Return is queued as an
/// already-finished entry.
public struct ScribeQueue {
    private enum State { case pending, done(String?) }
    private var entries: [(id: Int, state: State, afterPendingID: Int?, pauses: [Double]?)] = []
    private var nextID = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// A word being recognized; its id goes to `complete`. `pauses` are the seconds of pause before
    /// each of its letters, handed back with the result.
    public mutating func enqueuePending(pauses: [Double]? = nil) -> Int {
        defer { nextID += 1 }
        entries.append((nextID, .pending, nil, pauses))
        return nextID
    }

    /// Text that needs no recognition (a line break).
    public mutating func enqueueDone(_ text: String, afterPendingID: Int? = nil) {
        entries.append((nextID, .done(text), afterPendingID, nil))
        nextID += 1
    }

    /// Records a word's result (nil: nothing recognized). Ignored for dropped entries.
    public mutating func complete(_ id: Int, text: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .done(text)
    }

    /// Removes and returns the leading finished entries, in order (nil: failed word), at most `limit`.
    public mutating func popReady(limit: Int = .max) -> [String?] {
        popReadyWithPauses(limit: limit).map(\.text)
    }

    /// Like `popReady`, with each word's letter pauses.
    public mutating func popReadyWithPauses(limit: Int = .max) -> [(text: String?, pauses: [Double]?)] {
        var out: [(text: String?, pauses: [Double]?)] = []
        while out.count < limit, let first = entries.first, case .done(let text) = first.state {
            out.append((text, first.pauses))
            entries.removeFirst()
        }
        return out
    }

    /// Drops the newest entry, finished or not; false if the queue is empty.
    @discardableResult
    public mutating func dropLast() -> Bool { entries.popLast() != nil }

    /// Delete cancels the newest queued line and its Return together when both are pending.
    @discardableResult
    public mutating func dropLastForDelete() -> Bool {
        dropLastPendingLine() || dropLast()
    }

    /// Cancels the newest unconsumed line and its Return when that Return explicitly
    /// names the line's pending id, preserving every earlier queued entry. It also
    /// works if recognition finished but an earlier entry is keeping this pair queued.
    @discardableResult
    public mutating func dropLastPendingLine() -> Bool {
        guard entries.count >= 2,
              case .done("\n") = entries[entries.count - 1].state,
              entries[entries.count - 1].afterPendingID == entries[entries.count - 2].id else { return false }
        switch entries[entries.count - 2].state {
        case .pending:
            entries.removeLast(2)
            return true
        case .done(let text):
            guard text != "\n" else { return false }
            entries.removeLast(2)
            return true
        }
    }
}
