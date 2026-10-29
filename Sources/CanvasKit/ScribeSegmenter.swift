import AppKit
import NaturalLanguage

/// What the segmenter knows about words. `isCommon` is a closed-ish vocabulary of everyday words that
/// excludes junk fragments; `isKnownName` recognizes proper names; `personalNames` (lowercased) are
/// names the user has written before.
public struct ScribeLexicon {
    public var isCommon: (String) -> Bool
    public var isKnownName: (String) -> Bool
    public var personalNames: Set<String>

    public init(isCommon: @escaping (String) -> Bool, isKnownName: @escaping (String) -> Bool = { _ in false },
                personalNames: Set<String> = []) {
        self.isCommon = isCommon
        self.isKnownName = isKnownName
        self.personalNames = personalNames
    }

    /// Whether `word` (any case) is a common word or a known name.
    func knows(_ word: String) -> Bool {
        let lower = word.lowercased()
        return isCommon(lower) || personalNames.contains(lower) || isKnownName(word)
    }

    /// The English word embedding's vocabulary (about 57k everyday words, no junk fragments such as
    /// "ayu" or "teh") and the spell checker's capitalized-only words (names such as "Ayush").
    /// Cached; main thread only.
    public static let system = ScribeLexicon(
        isCommon: { word in
            if let known = commonCache[word] { return known }
            let known: Bool
            switch word.count {
            case 0: known = false
            case 1: known = word == "a" || word == "i"
            default: known = embedding?.contains(word) ?? false
            }
            commonCache[word] = known
            return known
        },
        isKnownName: { word in
            let lower = word.lowercased()
            guard lower.count >= 3 else { return false }
            if let known = nameCache[lower] { return known }
            let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
            let known = ScribeText.systemIsWord(capitalized) && !ScribeText.systemIsWord(lower)
            nameCache[lower] = known
            return known
        })

    private static let embedding = NLEmbedding.wordEmbedding(for: .english)
    private static var commonCache: [String: Bool] = [:]
    private static var nameCache: [String: Bool] = [:]
}

/// Splits run-together recognizer output ("HimynameisAyush") into words with a cost-based dynamic
/// program. Known words are cheap, function words cheapest, and an unknown chunk is expensive and
/// never worth splitting into fragments, so names and typos stay whole for the sentence polish.
public enum ScribeSegmenter {
    /// Small closed-class English words, including common contractions without their apostrophe.
    static let functionWords: Set<String> = [
        "a", "i", "am", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could", "did", "do", "does",
        "for", "from", "had", "has", "have", "he", "her", "him", "his", "how", "if", "in", "is", "it", "its",
        "me", "my", "no", "not", "of", "on", "or", "our", "she", "so", "than", "that", "the", "their", "them",
        "then", "there", "they", "this", "to", "up", "us", "was", "we", "were", "what", "when", "where",
        "which", "who", "why", "will", "with", "would", "you", "your", "hi", "hello", "just", "very", "all",
        "some", "any", "here", "now", "cant", "dont", "im", "whats", "thats", "lets"]

    static let maxPieceLength = 24
    /// Extra cost when a short (at most this many letters) word touches an unknown chunk without a capital
    /// marking the boundary: it is far more likely a fragment of that chunk ("A|yush", "he|llowo") than a word.
    static let shortWordLength = 2
    static let shortNeighborPenalty = 20.0
    /// Largest cost reduction for a boundary at a long pause.
    static let maxPauseBonus = 8.0

    private enum Kind { case function, known, unknown }

    private static func normalized(_ piece: ArraySlice<Character>) -> String {
        String(piece.filter { $0 != "'" && $0 != "\u{2019}" }).lowercased()
    }

    private static func kind(of piece: ArraySlice<Character>, lexicon: ScribeLexicon) -> Kind {
        let key = normalized(piece)
        if functionWords.contains(key) { return .function }
        return lexicon.knows(String(piece)) ? .known : .unknown
    }

    private static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "\u{2019}" }

    /// The best segmentation of `text`, spaces inserted into letter runs only. See `candidates`.
    public static func segment(_ text: String, lexicon: ScribeLexicon, pauses: [Double]? = nil,
                               medianPause: Double? = nil) -> String {
        candidates(text, lexicon: lexicon, pauses: pauses, limit: 1, medianPause: medianPause).first?.text ?? text
    }

    /// The `limit` cheapest distinct segmentations of `text`, best first. Whitespace is collapsed;
    /// digits and punctuation stay attached to the neighboring letter run. `pauses` are seconds of pause
    /// before each non-whitespace character (used only when the counts match): a pause above the
    /// median (`medianPause`, by default the median of `pauses`) makes a boundary there cheaper.
    /// An unfinished last word stays whole like any unknown chunk.
    public static func candidates(_ text: String, lexicon: ScribeLexicon, pauses: [Double]? = nil, limit: Int = 3,
                                  medianPause: Double? = nil) -> [(text: String, cost: Double)] {
        let limit = max(1, limit)
        let nonSpace = text.filter { !$0.isWhitespace }.count
        let aligned = pauses.flatMap { $0.count == nonSpace ? $0 : nil }
        let median = medianPause ?? aligned.map(Self.median)

        var parts: [(text: String, cost: Double)] = [("", 0)]
        func append(_ piece: [(text: String, cost: Double)]) {
            var next: [(text: String, cost: Double)] = []
            for p in parts { for q in piece { next.append((p.text + q.text, p.cost + q.cost)) } }
            parts = Array(next.sorted { $0.cost < $1.cost }.prefix(limit))
        }

        var run: [Character] = [], runStart = 0, offset = 0
        func flush() {
            guard !run.isEmpty else { return }
            let slice = aligned.map { Array($0[runStart..<(runStart + run.count)]) }
            append(runCandidates(run, lexicon: lexicon, pauses: slice, median: median, limit: limit))
            run = []
        }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        for (index, token) in tokens.enumerated() {
            if index > 0 { append([(" ", 0)]) }
            for ch in token {
                if ch.isLetter || isApostrophe(ch) && !run.isEmpty {
                    if run.isEmpty { runStart = offset }
                    run.append(ch)
                } else {
                    flush()
                    append([(String(ch), 0)])
                }
                offset += 1
            }
            flush()
        }
        return parts
    }

    /// Median of `pauses` ignoring the first (the pause before the first letter says nothing).
    static func median(_ pauses: [Double]) -> Double {
        let values = pauses.dropFirst().sorted()
        guard !values.isEmpty else { return 0 }
        return values.count % 2 == 1 ? values[values.count / 2]
                                      : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
    }

    private static func runCandidates(_ chars: [Character], lexicon: ScribeLexicon, pauses: [Double]?, median: Double?,
                                      limit: Int) -> [(text: String, cost: Double)] {
        let n = chars.count
        let whole = String(chars)
        if n == 1 || n > 80 { return [(whole, 0)] }
        let key = normalized(chars[...])
        if functionWords.contains(key) || lexicon.knows(whole) { return [(whole, 0)] }

        let hasLower = chars.contains { $0.isLowercase }
        func boundaryBonus(_ j: Int) -> Double {
            guard let pauses, let median, j > 0 else { return 0 }
            let excess = pauses[j] - median
            guard excess > 0 else { return 0 }
            return min(maxPauseBonus, 4 * excess / max(median, 0.1))
        }

        // Adjacent-piece penalties make costs path dependent, so keep a few more than `limit` per position.
        let beam = max(limit, 5)
        struct Step { var cost: Double; var prev: Int; var rank: Int }
        var best = [[Step]](repeating: [], count: n + 1)
        best[0] = [Step(cost: 0, prev: -1, rank: -1)]
        for i in 1...n {
            var steps: [Step] = []
            for j in max(0, i - maxPieceLength)..<i {
                guard !best[j].isEmpty, !isApostrophe(chars[j]) else { continue }
                let piece = chars[j..<i]
                let len = Double(i - j)
                let pieceKind = kind(of: piece, lexicon: lexicon)
                var cost: Double
                switch pieceKind {
                case .function: cost = 4
                case .known: cost = 10 - 0.1 * len
                case .unknown: cost = 20 + 6 * len + (len <= 3 ? 30 : 0)
                }
                if hasLower {
                    for k in (j + 1)..<i where chars[k].isUppercase && !(k == 1 && chars[0].isLowercase) { cost += 50 }
                    if j > 0, chars[j].isUppercase { cost -= 5 }
                    // A lowercase letter then a capital ("iPhone", "eBay") is deliberate casing, not a break.
                    if j == 1, chars[0].isLowercase, chars[1].isUppercase { cost += 60 }
                }
                cost -= boundaryBonus(j)
                for (rank, b) in best[j].enumerated() {
                    var total = b.cost + cost
                    if j > 0 {
                        let previous = chars[b.prev..<j]
                        let previousKind = kind(of: previous, lexicon: lexicon)
                        let shortKnown = pieceKind != .unknown && i - j <= shortWordLength
                        let shortPreviousKnown = previousKind != .unknown && j - b.prev <= shortWordLength
                        if !chars[j].isUppercase,
                           shortKnown && previousKind == .unknown || shortPreviousKnown && pieceKind == .unknown {
                            total += shortNeighborPenalty
                        }
                    }
                    steps.append(Step(cost: total, prev: j, rank: rank))
                }
            }
            best[i] = Array(steps.sorted { $0.cost < $1.cost }.prefix(beam))
        }
        return best[n].indices.prefix(limit).map { rank in
            var pieces: [String] = []
            var i = n, r = rank
            while i > 0 {
                let step = best[i][r]
                pieces.append(String(chars[step.prev..<i]))
                i = step.prev
                r = step.rank
            }
            return (pieces.reversed().joined(separator: " "), best[n][rank].cost)
        }
    }

    /// Words the user wrote capitalized somewhere other than a sentence start, lowercased (length ≥ 3):
    /// names worth never splitting.
    public static func personalNames(in texts: [String]) -> Set<String> {
        var names = Set<String>()
        for text in texts {
            var atStart = true, word = "", wordAtStart = true
            func end() {
                if word.count >= 3, !wordAtStart, word.first!.isUppercase, word.dropFirst().allSatisfy(\.isLowercase) {
                    names.insert(word.lowercased())
                }
                word = ""
            }
            for ch in text {
                if ch.isLetter {
                    if word.isEmpty { wordAtStart = atStart; atStart = false }
                    word.append(ch)
                } else {
                    end()
                    if ".!?\n".contains(ch) { atStart = true } else if !ch.isWhitespace, !"\"'\u{201C}\u{2018}([".contains(ch) { atStart = false }
                }
            }
            end()
        }
        return names
    }
}
