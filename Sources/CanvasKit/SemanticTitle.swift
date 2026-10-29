import CryptoKit
import Foundation

// MARK: - Phase 7 contract
//
// Semantic note names: an automatically named note (`namedByUser != true`) is
// renamed by the on-device language model when the user leaves it, only if its
// typed text changed since the last semantic name. First-line naming
// (`NoteTitle.derive`) stays the fallback while no semantic name exists or the
// model is unavailable. Recognized handwriting counts as text; ink not yet recognized stays "Untitled".

/// Suggests a short title for a note's text. Implemented with Foundation
/// Models on macOS 26+ (`NoteNamers.system()`); tests use a mock.
public protocol NoteNamer: AnyObject {
    /// Whether a suggestion can be made right now (Apple Intelligence on, model ready).
    var isAvailable: Bool { get }
    /// A cleaned title (`NoteTitle.cleanSuggestion`) for `text`; nil when the
    /// model has nothing usable. Never called with empty text.
    func suggestTitle(for text: String) async throws -> String?
}

public enum NoteNamers {
    /// The Foundation Models namer on macOS 26+ when the framework exists, else nil.
    /// Non-nil does not mean available; check `isAvailable` at call time.
    public static func system() -> NoteNamer? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return FoundationModelsNamer() }
        #endif
        return nil
    }
}

extension NoteTitle {
    /// Characters of typed text sent to the model.
    public static let namingTextLimit = 1500
    /// Most words kept from a suggestion.
    public static let maxSuggestionWords = 5

    /// Typed text and recognized handwriting lines in reading order (sorted
    /// like `derive`: top, then left), each item's string trimmed, empty blocks skipped, joined by
    /// "\n", then cut to the first `limit` characters. "" for ink-only notes.
    public static func namingText(from blocks: [TextBlock], handwriting: HandwritingCache? = nil,
                                  limit: Int = namingTextLimit) -> String {
        let text = readingOrder(blocks: blocks, handwriting: handwriting)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(text.prefix(limit))
    }

    /// Stable lowercase hex SHA-256 of `text` (UTF-8), persisted to detect
    /// changes across launches.
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Model output to a file name: first non-empty line only; strips
    /// surrounding quotes and a "Title:" prefix; removes punctuation except
    /// apostrophes and hyphens inside words; keeps at most
    /// `maxSuggestionWords` words; then `sanitize`; first letter capitalized. nil when nothing is left.
    public static func cleanSuggestion(_ raw: String) -> String? {
        guard var line = raw.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let quotes = CharacterSet(charactersIn: "\"'`\u{2018}\u{2019}\u{201C}\u{201D}*#")
        line = line.trimmingCharacters(in: quotes.union(.whitespaces))
        if let prefix = line.range(of: "^title\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
            line.removeSubrange(prefix)
        }
        line = line.trimmingCharacters(in: quotes.union(.whitespaces))
        // Keep letters, digits, whitespace, and apostrophes/hyphens that sit between word characters.
        let wordChar: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
        let chars = Array(line)
        var kept = ""
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber || c.isWhitespace {
                kept.append(c)
            } else if "'-\u{2019}".contains(c), wordChar(i > 0 ? chars[i - 1] : nil),
                      wordChar(i + 1 < chars.count ? chars[i + 1] : nil) {
                kept.append(c)
            } else {
                kept.append(" ")
            }
        }
        let words = kept.split(whereSeparator: \.isWhitespace).prefix(maxSuggestionWords)
        guard let title = sanitize(words.joined(separator: " ")) else { return nil }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Whether `text` is readable enough for the model to name: at least half of its words of 3+ letters
    /// are real words. Gibberish makes the model invent a topic; the first line is the better title.
    /// True when there are no such words (math, short notes), where the model is trusted.
    public static func isNameable(_ text: String, isWord: (String) -> Bool = ScribeText.systemIsWord) -> Bool {
        let words = text.split { !$0.isLetter }.map { $0.lowercased() }.filter { $0.count >= 3 }
        return words.isEmpty || words.filter(isWord).count * 2 >= words.count
    }

    /// Whether leaving a note should ask the model for a name: automatic
    /// naming, non-empty text, and the text's digest differs from `lastDigest`.
    public static func needsSemanticTitle(namedByUser: Bool?, text: String, lastDigest: String?) -> Bool {
        guard namedByUser != true else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return digest(text) != lastDigest
    }
}
