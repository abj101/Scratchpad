#if DEBUG
import Foundation
import CoreGraphics
import os

/// DEBUG-only per-symbol recognition log for manual testing (absent from Release).
/// Writes to os.Logger (category "MathRecognition") and appends one JSON object per
/// committed symbol to ~/Library/Logs/Scratchpad/math-recognition.jsonl.
enum MathRecognitionLog {
    struct Revision { let index: Int; let old: String?; let new: String }

    static var isEnabled = NSClassFromString("XCTestCase") == nil
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scratchpad",
                                       category: "MathRecognition")
    private static let queue = DispatchQueue(label: "MathRecognitionLog", qos: .utility)
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Scratchpad/math-recognition.jsonl")

    static func record(strokeCount: Int, extent: CGRect, likelihoods: [String: Double],
                       decodedBest: String?, displayed: String?, role: String,
                       revisions: [Revision]) {
        guard isEnabled else { return }
        let top5 = likelihoods.sorted { $0.value > $1.value }.prefix(5)
            .map { ["label": $0.key, "p": ($0.value * 1e4).rounded() / 1e4] as [String: Any] }
        let object: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Date()),
            "strokes": strokeCount,
            "extent": ["x": Double(extent.minX), "y": Double(extent.minY),
                       "w": Double(extent.width), "h": Double(extent.height)],
            "top5": top5,
            "decodedBest": decodedBest as Any? ?? NSNull(),
            "displayed": displayed as Any? ?? NSNull(),
            "ink": displayed == nil,
            "role": role,
            "event": "symbol",
            "revisions": revisions.map { ["index": $0.index, "old": $0.old as Any? ?? NSNull(), "new": $0.new] },
        ]
        write(object)
    }

    /// Structural events: `fraction_create` and `delete`.
    static func record(event: String, fields: [String: Any]) {
        guard isEnabled else { return }
        var object = fields
        object["t"] = ISO8601DateFormatter().string(from: Date())
        object["event"] = event
        write(object)
    }

    private static func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        logger.debug("\(line, privacy: .public)")
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
#endif
