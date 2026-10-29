import Foundation

/// Apple Notes-style automatic names: the first line of the note's text.
public enum NoteTitle {
    public static let defaultName = "Untitled"
    public static let maxLength = 40

    /// "Untitled", "Untitled 2", ...
    public static func isDefault(_ name: String) -> Bool {
        name == defaultName || isNumbered(name, base: defaultName)
    }

    /// True if `name` is `base` or a uniqued variant ("base 2", "base 3", ...).
    public static func matches(_ name: String, base: String) -> Bool {
        name.compare(base, options: .caseInsensitive) == .orderedSame || isNumbered(name, base: base)
    }

    /// Whether the note was named by hand, so automatic naming must leave it
    /// alone: renamed in the app, renamed outside it (the name no longer
    /// matches the last automatic one), or an older file with a custom name.
    public static func isNamedByUser(_ document: NoteDocument, currentName: String) -> Bool {
        if document.namedByUser == true { return true }
        if let automatic = document.automaticName { return !matches(currentName, base: automatic) }
        if document.namedByUser == false { return false }
        return !isDefault(currentName)
    }

    /// Typed blocks and recognized handwriting lines as text in reading
    /// order: top, then left. Equations contribute their LaTeX source.
    static func readingOrder(blocks: [TextBlock], handwriting: HandwritingCache?) -> [String] {
        var items = blocks.map { (origin: $0.origin, text: $0.plainText) }
        for line in handwriting?.lines ?? [] where !line.text.isEmpty {
            items.append((line.bounds.origin, line.text))
        }
        return items.sorted { ($0.origin.y, $0.origin.x) < ($1.origin.y, $1.origin.x) }.map(\.text)
    }

    /// First non-empty line of the topmost (then leftmost) text block or
    /// recognized handwriting line, made file-name safe. nil when the note has no text.
    public static func derive(from blocks: [TextBlock], handwriting: HandwritingCache? = nil) -> String? {
        for text in readingOrder(blocks: blocks, handwriting: handwriting) {
            for line in text.components(separatedBy: .newlines) {
                if let title = sanitize(line) { return title }
            }
        }
        return nil
    }

    /// Strips list markers and characters a file name can't hold, collapses
    /// whitespace and shortens to `maxLength` (at a word break when possible).
    public static func sanitize(_ line: String) -> String? {
        var s = line.replacingOccurrences(of: "[/:\\p{Cc}]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "^([•◦▪‣⁃–\\-*]|\\d+[.)]|[a-zA-Z][.)])\\s+", with: "",
                                   options: .regularExpression)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxLength {
            let cut = String(s.prefix(maxLength))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maxLength / 2 {
                s = String(cut[..<space])
            } else {
                s = cut
            }
            s = s.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        return s.isEmpty ? nil : s
    }

    private static func isNumbered(_ name: String, base: String) -> Bool {
        guard name.count > base.count + 1,
              name.prefix(base.count).compare(base, options: .caseInsensitive) == .orderedSame else { return false }
        let rest = name.dropFirst(base.count)
        return rest.first == " " && rest.dropFirst().allSatisfy(\.isNumber)
    }
}
