import Foundation

/// Backoff n-gram probabilities for the bundled math vocabulary.
public struct MathLanguageModel {
    private struct Payload: Decodable {
        let order: Int
        let vocab: [String]
        let ngrams: [String: [Double]]
    }

    private let symbolIDs: [String: UInt8]
    private let unknownID: UInt8
    private let ngrams: [UInt32: [Double]]

    init(vocab: [String], ngrams: [String: [Double]]) {
        let sortedVocabulary = vocab.sorted()
        let ids = Dictionary(uniqueKeysWithValues: sortedVocabulary.enumerated().map {
            ($0.element, UInt8($0.offset + 1))
        })
        symbolIDs = ids
        unknownID = ids["<unk>"] ?? 1

        var packed: [UInt32: [Double]] = [:]
        for (key, value) in ngrams {
            guard let separator = key.firstIndex(of: "\u{001e}") else { continue }
            let contextText = String(key[..<separator])
            let word = String(key[key.index(after: separator)...])
            let context = contextText.isEmpty ? [] : contextText.components(separatedBy: "\u{001f}")
            let tokens = context + [word]
            guard (1...4).contains(tokens.count) else { continue }
            var code: UInt32 = 0
            for token in tokens {
                code = (code << 7) | UInt32(ids[token] ?? unknownID)
            }
            packed[code] = value
        }
        self.ngrams = packed
    }

    public static let bundled = load(from: .module)

    public static func load(from bundle: Bundle) -> MathLanguageModel? {
        guard let url = bundle.url(forResource: "MathLM", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.order == 4, payload.vocab.count == 67,
              Set(payload.vocab).count == payload.vocab.count,
              payload.vocab.contains("<s>"), payload.vocab.contains("<unk>"),
              !payload.vocab.contains("</s>"),
              payload.ngrams.values.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        return MathLanguageModel(vocab: payload.vocab, ngrams: payload.ngrams)
    }

    /// Returns the log10 probability after standard backoff; unknown tokens map to `<unk>`.
    public func logProb(_ word: String, context: [String]) -> Double {
        let history = context.suffix(3).map { symbolID(for: $0) }
        let code = history.reduce(UInt32(0)) { ($0 << 7) | UInt32($1) }
        return logProb(wordID: symbolID(for: word), historyCode: code, historyLength: history.count)
    }

    /// Stable numeric ID used by the decoder's hot path; zero is the history sentinel.
    func symbolID(for word: String) -> UInt8 { symbolIDs[word] ?? unknownID }

    /// Packs the last three context symbols into 7-bit slots, left padded with zeroes.
    func historyCode(for context: [String]) -> UInt32 {
        context.suffix(3).reduce(UInt32(0)) { ($0 << 7) | UInt32(symbolID(for: $1)) }
    }

    /// Numeric equivalent for the decoder's three-token context; IDs occupy 1...67.
    func logProb(wordID: UInt8, historyCode: UInt32) -> Double {
        var accumulatedBackoff = 0.0
        if let row = ngrams[(historyCode << 7) | UInt32(wordID)] { return row[0] }
        if let row = ngrams[historyCode] { accumulatedBackoff += row[1] }

        let twoTokenHistory = historyCode & 0x3fff
        if let row = ngrams[(twoTokenHistory << 7) | UInt32(wordID)] {
            return accumulatedBackoff + row[0]
        }
        if let row = ngrams[twoTokenHistory] { accumulatedBackoff += row[1] }

        let oneTokenHistory = historyCode & 0x7f
        if let row = ngrams[(oneTokenHistory << 7) | UInt32(wordID)] {
            return accumulatedBackoff + row[0]
        }
        if let row = ngrams[oneTokenHistory] { accumulatedBackoff += row[1] }
        return accumulatedBackoff + (ngrams[UInt32(wordID)]?.first ?? -.infinity)
    }

    private func logProb(wordID: UInt8, historyCode: UInt32, historyLength: Int) -> Double {
        var history = historyCode
        var length = historyLength
        var accumulatedBackoff = 0.0

        while length > 0 {
            if let row = ngrams[(history << 7) | UInt32(wordID)] {
                return accumulatedBackoff + row[0]
            }
            if let contextRow = ngrams[history] {
                accumulatedBackoff += contextRow[1]
            }
            history &= (UInt32(1) << (7 * (length - 1))) - 1
            length -= 1
        }

        return accumulatedBackoff + (ngrams[UInt32(wordID)]?.first ?? -.infinity)
    }
}
