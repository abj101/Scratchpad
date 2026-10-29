import Foundation
#if canImport(PencilKit)
import PencilKit
#endif

/// Strokes found for a query or word, with their world bounds.
public struct HandwritingMatch: Equatable {
    public var strokeIDs: Set<UUID>
    /// World.
    public var bounds: CGRect

    public init(strokeIDs: Set<UUID>, bounds: CGRect) {
        self.strokeIDs = strokeIDs; self.bounds = bounds
    }
}

/// Reads handwriting. Each call recognizes exactly the given strokes (typically
/// one `HandwritingLine`); implementations serialize calls, so callers may
/// overlap them but they run one at a time.
public protocol HandwritingRecognizer: AnyObject {
    /// Changes when results may change; cached results from another version are stale.
    static var version: Int { get }
    func text(for strokes: [Stroke]) async -> String?
    func search(_ query: String, in strokes: [Stroke]) async -> [HandwritingMatch]
    /// Each recognized word in order, with its strokes.
    func words(in strokes: [Stroke]) async -> [(word: String, match: HandwritingMatch)]
}

public enum HandwritingRecognizers {
    /// The shared PencilKit recognizer on macOS 27+ (all callers share one
    /// queue of calls), else nil.
    public static func system() -> HandwritingRecognizer? {
        #if canImport(PencilKit)
        if #available(macOS 27, *) { return PencilKitHandwritingRecognizer.shared }
        #endif
        return nil
    }

    /// `PKStrokeRecognizer.recognitionVersion`, or 0 without a system recognizer.
    public static var systemVersion: Int {
        #if canImport(PencilKit)
        if #available(macOS 27, *) { return PencilKitHandwritingRecognizer.version }
        #endif
        return 0
    }
}

#if canImport(PencilKit)
/// `PKStrokeRecognizer` over strokes scaled to paper size by `InkNormalization`.
/// One recognizer instance; each call replaces its drawing, so calls are
/// chained (about 1 s each).
@available(macOS 27, *)
actor PencilKitHandwritingRecognizer: HandwritingRecognizer {
    static let shared = PencilKitHandwritingRecognizer()

    nonisolated static var version: Int { PKStrokeRecognizer.recognitionVersion }

    private let recognizer = PKStrokeRecognizer()
    private var tail: Task<Void, Never>?

    func text(for strokes: [Stroke]) async -> String? {
        guard !strokes.isEmpty else { return nil }
        return await withDrawing(of: strokes) { recognizer, _ in await recognizer.recognizedText() }
    }

    func search(_ query: String, in strokes: [Stroke]) async -> [HandwritingMatch] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !strokes.isEmpty, !query.isEmpty else { return [] }
        let ids = Set(strokes.map(\.id))
        return await withDrawing(of: strokes) { recognizer, normalization in
            await recognizer.search(query).compactMap { Self.match($0, ids, normalization) }
        }
    }

    func words(in strokes: [Stroke]) async -> [(word: String, match: HandwritingMatch)] {
        guard !strokes.isEmpty else { return [] }
        let ids = Set(strokes.map(\.id))
        // Reading order of a match: its line, then left edge.
        var lineOf: [UUID: Int] = [:]
        for (i, line) in HandwritingLines.group(strokes).enumerated() {
            for id in line.strokeIDs { lineOf[id] = i }
        }
        func order(_ m: HandwritingMatch) -> (Int, Double) {
            (m.strokeIDs.compactMap { lineOf[$0] }.min() ?? 0, m.bounds.minX)
        }
        return await withDrawing(of: strokes) { recognizer, normalization in
            guard let text = await recognizer.recognizedText() else { return [] }
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            var found: [String: [HandwritingMatch]] = [:]
            var used = Set<Set<UUID>>()
            var result: [(word: String, match: HandwritingMatch)] = []
            // Repeated words: each occurrence takes the earliest unused match.
            for word in words {
                let key = word.lowercased()
                if found[key] == nil {
                    found[key] = await recognizer.search(word, fullWordsOnly: true)
                        .compactMap { Self.match($0, ids, normalization) }
                        .sorted { order($0) < order($1) }
                }
                guard let match = found[key]?.first(where: { !used.contains($0.strokeIDs) }) else { continue }
                used.insert(match.strokeIDs)
                result.append((word, match))
            }
            return result
        }
    }

    // MARK: Helpers

    private static func match(_ r: PKStrokeRecognizer.SearchResult, _ ids: Set<UUID>,
                              _ normalization: InkNormalization) -> HandwritingMatch? {
        guard !r.strokes.isEmpty, r.strokes.isSubset(of: ids) else { return nil }
        return HandwritingMatch(strokeIDs: r.strokes, bounds: normalization.toWorld(r.bounds))
    }

    /// Runs `body` with the recognizer holding just `strokes`, after any earlier call finishes.
    private func withDrawing<T>(of strokes: [Stroke],
                                _ body: @escaping (PKStrokeRecognizer, InkNormalization) async -> T) async -> T {
        let previous = tail
        let recognizer = recognizer
        let task = Task {
            await previous?.value
            let normalization = InkNormalization(strokes: strokes)
            await recognizer.updateDrawing(Self.drawing(strokes, normalization))
            return await body(recognizer, normalization)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// As verified in the debug recognition command: our stroke ids, black pen ink.
    private static func drawing(_ strokes: [Stroke], _ normalization: InkNormalization) -> PKDrawing {
        let start = Date()
        return PKDrawing(strokes: strokes.map { s in
            let size = max(1, s.width * normalization.scale)
            let points = s.points.map {
                PKStrokePoint(location: normalization.toPaper($0.cgPoint), timeOffset: $0.t,
                              size: CGSize(width: size, height: size),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black),
                            path: PKStrokePath(controlPoints: points, creationDate: start), id: s.id)
        })
    }
}
#endif
