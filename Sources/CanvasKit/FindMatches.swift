import Foundation

/// One hit of the Find bar: typed text (a range in a block) or handwriting (strokes).
public struct FindMatch: Equatable {
    public enum Kind: Equatable {
        case text(blockID: UUID, range: NSRange)
        case ink(strokeIDs: Set<UUID>)
    }

    public var kind: Kind
    /// World. Text starts as the block's bounds; the view refines it to the matched range.
    public var bounds: CGRect
    /// Top-left of the containing block or handwriting line, for reading order.
    var anchor: CGPoint
    /// Position within the container (range start, or left edge for ink).
    var position: Double
}

/// Pure matching and ordering for the Find bar.
public enum FindMatches {
    static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Case- and diacritic-insensitive substring test.
    public static func contains(_ text: String, _ query: String) -> Bool {
        !query.isEmpty && text.range(of: query, options: options) != nil
    }

    /// Every occurrence of `query` in the blocks' text.
    public static func text(_ query: String, in blocks: [TextBlock]) -> [FindMatch] {
        guard !query.isEmpty else { return [] }
        var result: [FindMatch] = []
        for block in blocks {
            let content = block.attributedString
            let original = content.string as NSString
            var equations: [(NSRange, String)] = []
            content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                if let equation = value as? EquationAttachment { equations.append((range, equation.latex)) }
            }
            let searchable = NSMutableString()
            var sourceOffsets: [Int] = []
            var cursor = 0
            for (range, latex) in equations {
                if range.location > cursor {
                    let plainRange = NSRange(location: cursor, length: range.location - cursor)
                    searchable.append(original.substring(with: plainRange))
                    sourceOffsets.append(contentsOf: cursor..<NSMaxRange(plainRange))
                }
                searchable.append(latex)
                sourceOffsets.append(contentsOf: repeatElement(range.location, count: (latex as NSString).length))
                cursor = NSMaxRange(range)
            }
            if cursor < original.length {
                let plainRange = NSRange(location: cursor, length: original.length - cursor)
                searchable.append(original.substring(with: plainRange))
                sourceOffsets.append(contentsOf: cursor..<original.length)
            }
            let string = searchable
            var search = NSRange(location: 0, length: string.length)
            while search.length > 0 {
                let found = string.range(of: query, options: options, range: search)
                guard found.location != NSNotFound, found.length > 0 else { break }
                let matchedOffsets = sourceOffsets[found.location..<NSMaxRange(found)]
                let start = matchedOffsets.min() ?? 0
                let end = (matchedOffsets.max() ?? start) + 1
                let sourceRange = NSRange(location: start, length: end - start)
                result.append(FindMatch(kind: .text(blockID: block.id, range: sourceRange), bounds: block.bounds,
                                        anchor: block.origin, position: Double(start)))
                let next = found.location + found.length
                search = NSRange(location: next, length: string.length - next)
            }
        }
        return result
    }

    /// Handwriting hits: cached lines whose text contains `query` are searched by the
    /// recognizer for precise bounds (falling back to the line's bounds). Lines whose
    /// strokes left the model are skipped. Stops early when cancelled.
    @MainActor
    public static func ink(_ query: String, cache: HandwritingCache?, strokes: [Stroke],
                           recognizer: HandwritingRecognizer?) async -> [FindMatch] {
        guard let cache, let recognizer, !query.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
        var result: [FindMatch] = []
        for line in cache.lines where contains(line.text, query) {
            if Task.isCancelled { return [] }
            let lineStrokes = line.strokeIDs.compactMap { byID[$0] }
            guard lineStrokes.count == line.strokeIDs.count, !lineStrokes.isEmpty else { continue }
            let found = await recognizer.search(query, in: lineStrokes)
            let anchor = line.bounds.origin
            if found.isEmpty {
                result.append(FindMatch(kind: .ink(strokeIDs: Set(line.strokeIDs)), bounds: line.bounds,
                                        anchor: anchor, position: line.bounds.minX))
            }
            for match in found {
                result.append(FindMatch(kind: .ink(strokeIDs: match.strokeIDs), bounds: match.bounds,
                                        anchor: anchor, position: match.bounds.minX))
            }
        }
        return result
    }

    /// Reading order: container top, then left, then position inside it.
    public static func ordered(_ matches: [FindMatch]) -> [FindMatch] {
        matches.sorted {
            ($0.anchor.y, $0.anchor.x, $0.position) < ($1.anchor.y, $1.anchor.x, $1.position)
        }
    }
}

/// Find bar state, shared with the SwiftUI bar through `CanvasSettings.find`.
public final class FindModel: ObservableObject {
    @Published public var isVisible = false
    @Published public var query = ""
    /// Bumped to focus the field again (⌘F while the bar is open).
    @Published public var focusToken = 0
    @Published public internal(set) var count = 0
    /// Zero-based index of the current match.
    @Published public internal(set) var index = 0
    @Published public internal(set) var isSearching = false

    public init() {}

    /// "n of m", "No results", or "" for an empty query.
    public var status: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if count > 0 { return "\(index + 1) of \(count)" }
        return isSearching ? "Searching…" : "No results"
    }
}
