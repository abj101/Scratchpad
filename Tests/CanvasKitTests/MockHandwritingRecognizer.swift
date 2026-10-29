import Foundation
@testable import CanvasKit

/// Reads each stroke as its text from `texts` ("?" if unset). Records every call.
final class MockHandwritingRecognizer: HandwritingRecognizer {
    nonisolated(unsafe) static var version = 1

    /// Text by stroke id (a line's text is its strokes' texts joined by spaces, left → right).
    var texts: [UUID: String] = [:]
    /// Strokes of each `text(for:)` call.
    private(set) var calls: [[UUID]] = []
    var latency: UInt64 = 0
    /// Runs inside each `text(for:)` call, before it returns.
    var onCall: (() -> Void)?
    /// Lines to read as nil.
    var nilFor: Set<UUID> = []

    func text(for strokes: [Stroke]) async -> String? {
        calls.append(strokes.map(\.id))
        onCall?()
        if latency > 0 { try? await Task.sleep(nanoseconds: latency) }
        if strokes.contains(where: { nilFor.contains($0.id) }) { return nil }
        return strokes.sorted { $0.bounds.minX < $1.bounds.minX }.map { texts[$0.id] ?? "?" }.joined(separator: " ")
    }

    func search(_ query: String, in strokes: [Stroke]) async -> [HandwritingMatch] {
        strokes.filter { texts[$0.id]?.localizedCaseInsensitiveContains(query) == true }
            .map { HandwritingMatch(strokeIDs: [$0.id], bounds: $0.bounds) }
    }

    func words(in strokes: [Stroke]) async -> [(word: String, match: HandwritingMatch)] {
        strokes.sorted { $0.bounds.minX < $1.bounds.minX }.map {
            (word: texts[$0.id] ?? "?", match: HandwritingMatch(strokeIDs: [$0.id], bounds: $0.bounds))
        }
    }
}
