#if DEBUG
import Foundation
import CoreGraphics

/// Developer-only held-out raw ink. Files are the session's source of truth.
final class GlyphCapture {
    struct Record: Codable {
        let label: String
        let codepoints: [String]
        let writer: String
        let split: String
        let strokes: [[[Double]]]
        let cell: [Double]
        let styles: [Style]
        struct Style: Codable { let width: Double; let color: RGBA }

        var isValid: Bool {
            writer == "ayush" && split == "test" && codepoints == GlyphCapture.codepoints(label)
            && cell.count == 4 && cell.allSatisfy(\.isFinite) && cell[2] > 0 && cell[3] > 0
            && !strokes.isEmpty && strokes.count == styles.count
            && strokes.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) } }
            && styles.allSatisfy { $0.width.isFinite && $0.width > 0
                && [$0.color.r, $0.color.g, $0.color.b, $0.color.a].allSatisfy { $0.isFinite && (0...1).contains($0) } }
        }
    }
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/glyph-capture", isDirectory: true)
    }
    static func codepoints(_ label: String) -> [String] {
        label.unicodeScalars.map { String(format: "U+%04X", $0.value) }
    }
    let directory: URL
    let labels: [String]
    private(set) var files: [String: [URL]] = [:]
    private var lastSaved: (label: String, url: URL)?
    var label: String? { labels.first { (files[$0]?.count ?? 0) < 5 } }
    var count: Int { labels.reduce(0) { $0 + min(5, files[$1]?.count ?? 0) } }
    var sampleNumber: Int { (label.flatMap { files[$0]?.count } ?? 0) + 1 }

    init(directory: URL = GlyphCapture.directory, labels: [String] = CleanGlyphs.labels) throws {
        self.directory = directory
        self.labels = labels
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url)),
                  record.isValid, labels.contains(record.label) else { continue }
            files[record.label, default: []].append(url)
        }
    }

    func save(_ strokes: [Stroke], cell: CGRect) throws {
        guard let label else { return }
        let record = Record(label: label, codepoints: Self.codepoints(label), writer: "ayush", split: "test",
                            strokes: strokes.map { $0.points.map { [$0.x, $0.y, $0.t] } },
                            cell: [cell.minX, cell.minY, cell.width, cell.height],
                            styles: strokes.map { Record.Style(width: $0.width, color: $0.color) })
        guard record.isValid else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(record).write(to: temporary, options: .withoutOverwriting)
        // A same-directory hard link publishes complete bytes atomically and fails if url exists.
        try FileManager.default.linkItem(at: temporary, to: url)
        files[label, default: []].append(url)
        lastSaved = (label, url)
    }

    func redoLast() throws {
        guard let last = lastSaved else { return }
        try FileManager.default.removeItem(at: last.url)
        files[last.label]?.removeAll { $0 == last.url }
        lastSaved = nil
    }
}
#endif
