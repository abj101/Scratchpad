import AppKit
import NaturalLanguage

/// Cleans up a recognized phrase: spaces, punctuation, capitalization, obvious
/// misspellings. Implemented with Foundation Models on macOS 26+
/// (`TextPolishers.system()`); tests use a mock.
public protocol TextPolisher: AnyObject {
    /// Whether polishing can be done right now (Apple Intelligence on, model ready).
    var isAvailable: Bool { get }
    /// `raw` corrected; `context` is the text before it (only so sentence starts are
    /// right). The result is only the corrected piece, never the context. Nil on any failure.
    func polish(_ raw: String, context: String) async -> String?
    /// Loads the model ahead of the first request. Optional.
    func prewarm()
}

public extension TextPolisher { func prewarm() {} }

public enum TextPolishers {
    /// The Foundation Models polisher on macOS 26+ when the framework exists, else nil.
    /// Non-nil does not mean available; check `isAvailable` at call time.
    public static func system() -> TextPolisher? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return FoundationModelsPolisher() }
        #endif
        return nil
    }
}

/// What became of one phrase: for the debug log and tests.
public struct ScribePolishResult: Equatable {
    public var raw: String
    public var polished: String?
    /// Whether any of the polish was used (`final` is built from it, rejected parts reverted).
    public var accepted: Bool
    /// The text after the system autocorrect pass (before any empty-result guard).
    public var autocorrected: String
    public var final: String
}

/// Block text that polish must not change: words repaired with high confidence. Valid only
/// while the block still reads `text` at `range`.
struct ScribeLock: Equatable {
    var range: NSRange
    var text: String
}

/// Pure guard and fallback for polished phrases.
public enum ScribePolish {
    /// Characters of the target block's tail sent to the polisher as context.
    public static let contextLimit = 200

    /// The last `contextLimit` characters of `text`.
    public static func context(from text: String) -> String {
        String(text.suffix(contextLimit))
    }

    /// The range of the sentence being written at the end of `text` (after the last . ! ? or
    /// newline that precedes its final character, leading spaces skipped), cut at a word start
    /// to at most `limit` characters. Nil for blank text.
    public static func recentSentenceRange(in text: String, limit: Int = contextLimit) -> NSRange? {
        let ns = text as NSString
        var end = ns.length
        while end > 0, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: end - 1)) ?? "a") { end -= 1 }
        guard end > 0 else { return nil }
        var start = end - 1
        while start > 0, !".!?\n".contains(Character(UnicodeScalar(ns.character(at: start - 1)) ?? "a")) { start -= 1 }
        func isSpace(_ i: Int) -> Bool { CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i)) ?? "a") }
        while start < end, isSpace(start) { start += 1 }
        if end - start > limit {
            start = end - limit
            while start < end, !isSpace(start - 1) { start += 1 }
        }
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The locks that still match `text`. Any other lock is stale (edited, moved or undone).
    static func validLocks(_ locks: [ScribeLock], in text: String) -> [ScribeLock] {
        let ns = text as NSString
        return locks.filter { NSMaxRange($0.range) <= ns.length && ns.substring(with: $0.range) == $0.text }
    }

    /// The part of the sentence at the end of `text` that polish may change: the sentence from
    /// `recentSentenceRange`, starting after any lock in it, so locked text is only context.
    /// Nil when nothing is open. `locks` must be valid for `text`.
    static func openRange(in text: String, locks: [ScribeLock]) -> NSRange? {
        guard let sentence = recentSentenceRange(in: text) else { return nil }
        let ns = text as NSString
        let end = NSMaxRange(sentence)
        let lockEnd = locks.filter { $0.range.location < end }.map { NSMaxRange($0.range) }.max() ?? 0
        var start = max(sentence.location, lockEnd)
        while start < end, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: start)) ?? "a") {
            start += 1
        }
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Locks for the words a polish changed with high confidence, with ranges in `merged`. A
    /// changed group qualifies only when it is a pure space/case change or within one letter edit,
    /// its new words are plausible, and it touches no protected name. Pure insertions and
    /// deletions never lock.
    static func confidentLocks(raw: String, merged: String,
                               isWord: (String) -> Bool = ScribeText.systemIsWord) -> [ScribeLock] {
        let rawRanges = wordRanges(in: raw), mergedRanges = wordRanges(in: merged)
        let rawWords = rawRanges.map(\.word), mergedWords = mergedRanges.map(\.word)
        let rawNames = protectedNames(in: raw, isWord: isWord), mergedNames = protectedNames(in: merged, isWord: isWord)
        var locks: [ScribeLock] = []
        for group in changedGroups(rawWords, mergedWords) where !group.raw.isEmpty && !group.polished.isEmpty {
            let a = letters(rawWords[group.raw].joined()), b = letters(mergedWords[group.polished].joined())
            guard a == b || isSingleTypo(a, b),
                  !group.raw.contains(where: { rawNames[$0] }), !group.polished.contains(where: { mergedNames[$0] }),
                  group.polished.allSatisfy({ ScribeText.isPlausibleWord(mergedWords[$0].lowercased(), isWord: isWord) })
            else { continue }
            locks += group.polished.map { ScribeLock(range: mergedRanges[$0].range, text: mergedWords[$0]) }
        }
        return locks
    }

    /// Word groups where `polished` differs from `raw` (exact word match), as index ranges. The
    /// shortest skipped runs on each side are taken first.
    static func changedGroups(_ raw: [String], _ polished: [String])
        -> [(raw: Range<Int>, polished: Range<Int>)] {
        var groups: [(raw: Range<Int>, polished: Range<Int>)] = []
        var i = 0, j = 0
        while i < raw.count || j < polished.count {
            if i < raw.count, j < polished.count, raw[i] == polished[j] { i += 1; j += 1; continue }
            var found: (a: Int, b: Int)?
            for total in 1...(raw.count - i + polished.count - j) where found == nil {
                for a in 0...min(total, raw.count - i) {
                    let b = total - a
                    guard b <= polished.count - j else { continue }
                    let resumes = i + a < raw.count && j + b < polished.count && raw[i + a] == polished[j + b]
                    if resumes || (i + a == raw.count && j + b == polished.count) { found = (a, b); break }
                }
            }
            guard let f = found else { break }
            groups.append((i..<i + f.a, j..<j + f.b))
            i += f.a
            j += f.b
        }
        return groups
    }

    /// Lowercased letters and digits only.
    static func letters(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Levenshtein distance between two character sequences.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }

    /// Whether `polished` only repairs `raw` as a whole: `merge` keeps every word of it.
    public static func accepts(polished: String, raw: String,
                               isWord: (String) -> Bool = ScribeText.systemIsWord) -> Bool {
        if wordRanges(in: raw).isEmpty { return wordRanges(in: polished).isEmpty }
        return merge(polished: polished, raw: raw, isWord: isWord) == polished
    }

    /// `polished` with every part that is not a plain repair of `raw` reverted to the raw
    /// words ("howar you" → "How are you" stays even when another word was rewritten). Raw
    /// words are aligned to polished words in groups of up to 3 on each side, keeping as many
    /// fine groups as possible. A group is fine when its numbers and letters are unchanged
    /// (case and punctuation may change), or it is within one letter edit (including an
    /// adjacent swap, so "form" → "from" is fine), every resulting word is a real word, it
    /// touches no protected name, and, if its spacing changes, at least one raw word was not a
    /// real word. So "Ayush" is never split into "Ayu sh" and "into" is never re-spaced.
    /// Inserted, deleted and reordered words revert too. Nil when no group is fine.
    public static func merge(polished: String, raw: String,
                             isWord: (String) -> Bool = ScribeText.systemIsWord) -> String? {
        let rawRanges = wordRanges(in: raw), polishedRanges = wordRanges(in: polished)
        let rawWords = rawRanges.map(\.word), polishedWords = polishedRanges.map(\.word)
        guard !rawWords.isEmpty, !polishedWords.isEmpty else { return nil }
        func plausible(_ w: String) -> Bool { ScribeText.isPlausibleWord(w.lowercased(), isWord: isWord) }
        let rawPlausible = rawWords.map(plausible), polishedPlausible = polishedWords.map(plausible)
        let names = protectedNames(in: raw, isWord: isWord)
        // Preserve amounts, versions and identifiers; letter edit distance must not
        // authorize deleting or changing a number.
        func numericTokens(_ words: ArraySlice<String>) -> [String] {
            words.filter { $0.contains(where: \.isNumber) }.map { $0.lowercased() }
        }
        func groupOK(_ r: Range<Int>, _ p: Range<Int>) -> Bool {
            guard numericTokens(rawWords[r]) == numericTokens(polishedWords[p]) else { return false }
            let a = letters(rawWords[r].joined()), b = letters(polishedWords[p].joined())
            let single = r.count == 1 && p.count == 1
            if single && a == b { return true }
            guard isSingleTypo(a, b), !r.contains(where: { names[$0] }),
                  p.allSatisfy({ polishedPlausible[$0] }) else { return false }
            return single || r.contains(where: { !rawPlausible[$0] })
        }

        // Cheapest alignment, where a reverted group costs its words (finer groups preferred).
        let n = rawWords.count, m = polishedWords.count, unreachable = Int.max / 2
        var cost = Array(repeating: Array(repeating: unreachable, count: m + 1), count: n + 1)
        var back = Array(repeating: Array(repeating: (i: 0, j: 0, fine: false), count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 0...n {
            for j in 0...m where cost[i][j] < unreachable {
                for k in 0...min(3, n - i) {
                    for l in 0...min(3, m - j) where k + l > 0 {
                        let fine = k > 0 && l > 0 && groupOK(i..<i + k, j..<j + l)
                        let size = k + l
                        let total = cost[i][j] + (fine ? 0 : 10 * size + size * size + (k == 0 || l == 0 ? 3 : 0))
                        if total < cost[i + k][j + l] {
                            cost[i + k][j + l] = total
                            back[i + k][j + l] = (i, j, fine)
                        }
                    }
                }
            }
        }
        var groups: [(raw: Range<Int>, polished: Range<Int>, fine: Bool)] = []
        var (i, j) = (n, m)
        while i > 0 || j > 0 {
            let b = back[i][j]
            groups.append((b.i..<i, b.j..<j, b.fine))
            (i, j) = (b.i, b.j)
        }
        groups.reverse()
        guard groups.contains(where: \.fine) else { return nil }

        let rs = raw as NSString, ps = polished as NSString
        func span(_ ranges: [(word: String, range: NSRange)], _ r: Range<Int>, in text: NSString) -> String {
            text.substring(with: NSUnionRange(ranges[r.lowerBound].range, ranges[r.upperBound - 1].range))
        }
        /// Polished text between word `j - 1` and word `j` (leading for 0, trailing for `m`).
        func gap(before j: Int) -> String {
            let start = j == 0 ? 0 : NSMaxRange(polishedRanges[j - 1].range)
            let end = j == m ? ps.length : polishedRanges[j].range.location
            return ps.substring(with: NSRange(location: start, length: end - start))
        }
        var out = ""
        func append(gap: String, _ text: String) {
            out += (out.isEmpty ? String(gap.drop(while: \.isWhitespace)) : gap) + text
        }
        for g in groups {
            if g.polished.isEmpty { // a deleted raw word comes back
                if let last = out.last, !last.isWhitespace, !ScribeText.openingPunctuation.contains(last) { out += " " }
                out += span(rawRanges, g.raw, in: rs)
                continue
            }
            if g.fine {
                let text = keepingCapitals(of: Array(rawWords[g.raw].joined()),
                                           in: span(polishedRanges, g.polished, in: ps))
                append(gap: gap(before: g.polished.lowerBound), text)
            } else if !g.raw.isEmpty { // an inserted polished word is dropped
                var text = span(rawRanges, g.raw, in: rs)
                if polishedWords[g.polished.lowerBound].first?.isUppercase == true, text.first?.isLowercase == true,
                   startsSentence(after: out) || names[g.raw.lowerBound] {
                    text = text.prefix(1).uppercased() + text.dropFirst()
                }
                append(gap: gap(before: g.polished.lowerBound), text)
            }
        }
        return out + gap(before: m)
    }

    /// `text` with the capitals the writer chose in `raw` restored: letter by letter when the
    /// letters are unchanged ("Paris" never becomes "paris", "HELLO" never "Hello"), else just
    /// the first letter of a repaired word.
    static func keepingCapitals(of raw: [Character], in text: String) -> String {
        let rawLetters = raw.filter { $0.isLetter || $0.isNumber }
        let sameLetters = text.filter { $0.isLetter || $0.isNumber }.count == rawLetters.count
        var out = "", k = 0
        for ch in text {
            guard ch.isLetter || ch.isNumber else { out.append(ch); continue }
            let capital = sameLetters ? rawLetters[k].isUppercase : k == 0 && rawLetters.first?.isUppercase == true
            out += capital ? ch.uppercased() : String(ch)
            k += 1
        }
        return out
    }

    private static func isSingleTypo(_ a: [Character], _ b: [Character]) -> Bool {
        if distance(a, b) <= 1 { return true }
        guard a.count == b.count else { return false }
        let mismatches = a.indices.filter { a[$0] != b[$0] }
        guard mismatches.count == 2, mismatches[1] == mismatches[0] + 1 else { return false }
        let i = mismatches[0], j = mismatches[1]
        return a[i] == b[j] && a[j] == b[i]
    }

    /// Per word of `text`: whether it is a name the recognizer read and polish must keep
    /// letter for letter. That is a proper noun the dictionary knows only capitalized
    /// ("Ayush"), a capital away from a sentence start, or a word tagged as a personal name.
    /// Sentence-start capitalization alone is not name evidence: formatting adds it.
    static func protectedNames(in text: String, isWord: (String) -> Bool) -> [Bool] {
        let ns = text as NSString
        let tagger = NLTagger(tagSchemes: [.nameType])
        return wordRanges(in: text).map { word, range in
            let lower = word.lowercased(), capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
            // A capital-only short abbreviation ("ul" → "Ul") is not enough
            // name evidence for a lowercase fragment of a split word.
            if (word.count >= 3 || word.first?.isUppercase == true),
               lower != capitalized && isWord(capitalized) && !isWord(lower) { return true }
            let before = ns.substring(to: range.location)
            let sentenceStart = startsSentence(after: before)
            if word.first?.isUppercase == true && !sentenceStart { return true }
            // "Howar you" is tagged as a name solely because we capitalized it.
            // Keep lexical name evidence above; remove this formatting cue for tagging.
            let taggingText = sentenceStart ? ns.replacingCharacters(in: range, with: lower) : text
            let taggingRange = sentenceStart ? NSRange(location: range.location, length: (lower as NSString).length) : range
            tagger.string = taggingText
            guard let swiftRange = Range(taggingRange, in: taggingText) else { return false }
            return tagger.tags(in: swiftRange, unit: .word, scheme: .nameType, options: [.omitWhitespace, .joinNames])
                .contains { $0.0 == .personalName }
        }
    }

    private static func wordRanges(in text: String) -> [(word: String, range: NSRange)] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)*")
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { (ns.substring(with: $0.range), $0.range) }
    }

    /// Whether a piece placed after `context` starts a sentence: nothing before it, or the
    /// last non-blank character is . ! ? or a newline.
    public static func startsSentence(after context: String) -> Bool {
        guard let last = context.last(where: { $0 != " " && $0 != "\t" && !ScribeText.openingPunctuation.contains($0) }) else { return true }
        return ".!?\n".contains(last)
    }

    /// No-model path: `raw` with its first letter capitalized at a sentence start.
    public static func fallback(raw: String, context: String) -> String {
        guard startsSentence(after: context), let first = raw.first else { return raw }
        // Deliberate mixed case ("iPhone", "eBay") stays as written.
        if raw.dropFirst().first?.isUppercase == true { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    /// The edits (ranges in the checked string) that fall inside `range` and don't overlap an
    /// earlier accepted edit, applied last-to-first so ranges stay valid; returns the text of
    /// `range` after the edits. Earlier edits in `edits` win over later overlapping ones.
    public static func applying(_ edits: [(range: NSRange, replacement: String)], to text: String,
                                within range: NSRange) -> String {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return text }
        var accepted: [(range: NSRange, replacement: String)] = []
        for edit in edits {
            let r = edit.range
            guard r.location != NSNotFound, r.location >= range.location, NSMaxRange(r) <= NSMaxRange(range),
                  !accepted.contains(where: { NSIntersectionRange($0.range, r).length > 0 || $0.range.location == r.location })
            else { continue }
            accepted.append(edit)
        }
        var result = ns.substring(with: range) as NSString
        for edit in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            result = result.replacingCharacters(in: NSRange(location: edit.range.location - range.location,
                                                             length: edit.range.length),
                                                with: edit.replacement) as NSString
        }
        return result as String
    }

    /// The system text checker's corrections for `piece` as it reads after `context`: automatic
    /// corrections, grammar fixes with a single suggestion, and spelling corrections. Only
    /// `piece` is returned. The checker is used on the calling (main) thread.
    public static let systemAutocorrect: (_ context: String, _ piece: String) -> String = { context, piece in
        guard !piece.isEmpty else { return piece }
        // The recognizer's complete tokens are stronger evidence than a spell-check
        // guess. Preserve capitalized names and words tagged as personal names.
        if isProtectedName(in: piece, context: context) { return piece }
        let checker = NSSpellChecker.shared
        let prefix = context + ScribeText.separator(before: context, piece: piece)
        let full = prefix + piece
        let pieceRange = NSRange(location: (prefix as NSString).length, length: (piece as NSString).length)
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        var options: [NSSpellChecker.OptionKey: Any] = [:]
        if #available(macOS 27, *) { options[.waitForAllGrammarCheckingResultsKey] = true }
        let results = checker.check(full, range: NSRange(location: 0, length: (full as NSString).length),
                                    types: NSTextCheckingResult.CheckingType([.spelling, .correction, .grammar]).rawValue, options: options,
                                    inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil)
        var edits: [(range: NSRange, replacement: String)] = []
        var spelling: [NSRange] = []
        for result in results {
            switch result.resultType {
            case .spelling:
                spelling.append(result.range)
            default:
                break
            }
        }
        // Correct only explicit spelling errors. Contextual grammar/automatic fixes can
        // rewrite a correctly recognized word (including a name).
        for range in spelling where NSMaxRange(range) <= (full as NSString).length {
            if let fix = checker.correction(forWordRange: range, in: full, language: checker.language(),
                                            inSpellDocumentWithTag: tag), !fix.isEmpty {
                edits.append((range, fix))
            }
        }
        return applying(edits, to: full, within: pieceRange)
    }

    private static func isProtectedName(in piece: String, context: String) -> Bool {
        let firstIsSentenceStart = startsSentence(after: context)
        let ranges = wordRanges(in: piece)
        guard !ranges.isEmpty else { return false }
        let tagger = NLTagger(tagSchemes: [.nameType])
        let combined = context + " " + piece
        tagger.string = combined
        let offset = ((context + " ") as NSString).length
        for (index, token) in ranges.enumerated() {
            let word = (piece as NSString).substring(with: token.range)
            if word.first?.isUppercase == true && !(index == 0 && firstIsSentenceStart) { return true }
            let range = NSRange(location: offset + token.range.location, length: token.range.length)
            guard let swiftRange = Range(range, in: combined) else { continue }
            if tagger.tags(in: swiftRange, unit: .word, scheme: .nameType,
                           options: [.omitWhitespace, .joinNames]).contains(where: { $0.0 == .personalName }) {
                return true
            }
        }
        return false
    }

    /// Fast, synchronous cleanup for a word as it is inserted: sentence-start capital, then autocorrect.
    public static func quick(raw: String, context: String,
                             autocorrect: (_ context: String, _ piece: String) -> String = systemAutocorrect) -> String {
        let chosen = fallback(raw: raw, context: context)
        let corrected = autocorrect(context, chosen)
        return corrected.isEmpty ? chosen : corrected
    }

    /// recognize (done by the caller) → normalize → polish → guard → (merged polished, else raw
    /// capitalized) → system autocorrect. `raw` is already normalized.
    public static func process(raw: String, context: String, polisher: TextPolisher?,
                               isWord: (String) -> Bool = ScribeText.systemIsWord,
                               autocorrect: (_ context: String, _ piece: String) -> String = systemAutocorrect) async -> ScribePolishResult {
        var polished: String?
        if let polisher, polisher.isAvailable {
            polished = ScribeText.normalized(await polisher.polish(raw, context: context))
        }
        let merged = polished.flatMap { merge(polished: $0, raw: raw, isWord: isWord) }
        let accepted = merged != nil
        let chosen = merged ?? fallback(raw: raw, context: context)
        let corrected = autocorrect(context, chosen)
        return ScribePolishResult(raw: raw, polished: polished, accepted: accepted, autocorrected: corrected,
                                  final: corrected.isEmpty ? chosen : corrected)
    }
}
