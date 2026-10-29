import CryptoKit
import Foundation

/// Recognized handwriting of one note, per line, stored in `NoteDocument.handwriting`.
/// Entries are keyed by `digest(of:)` of the line's strokes; the whole cache is
/// stale when `recognitionVersion` differs from the recognizer's.
public struct HandwritingCache: Codable, Equatable {
    public var recognitionVersion: Int
    /// Reading order (top, then left).
    public var lines: [Entry]

    public struct Entry: Codable, Equatable {
        public var digest: String
        /// Left → right.
        public var strokeIDs: [UUID]
        /// World.
        public var bounds: CGRect
        /// "" when the recognizer read nothing.
        public var text: String

        public init(digest: String, strokeIDs: [UUID], bounds: CGRect, text: String) {
            self.digest = digest; self.strokeIDs = strokeIDs; self.bounds = bounds; self.text = text
        }
    }

    public init(recognitionVersion: Int, lines: [Entry] = []) {
        self.recognitionVersion = recognitionVersion; self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case recognitionVersion, lines }

    /// Non-empty line texts in reading order, joined by "\n".
    public var text: String {
        lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// SHA-256 (hex) of the strokes' ids, widths and point coordinates;
    /// independent of the strokes' order. Color and timing don't count.
    public static func digest(of strokes: [Stroke]) -> String {
        var hash = SHA256()
        func add(_ value: Double) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { hash.update(bufferPointer: $0) }
        }
        for stroke in strokes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            withUnsafeBytes(of: stroke.id.uuid) { hash.update(bufferPointer: $0) }
            add(stroke.width)
            add(Double(stroke.points.count))
            for p in stroke.points { add(p.x); add(p.y) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
