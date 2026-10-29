#if DEBUG
import AppKit
import CanvasKit

/// Debug-only: runs the CanvasKit recognition path on the canvas's strokes
/// (the selected ones, or all if nothing is selected), line by line.
@MainActor
enum DebugRecognition {
    static func run(on canvas: CanvasView) {
        let selected = canvas.selection.selection
        let strokes = canvas.model.strokes.filter { selected.isEmpty || selected.contains($0.id) }
        guard !strokes.isEmpty else { return show("No strokes to recognize.") }
        guard let recognizer = HandwritingRecognizers.system() else {
            return show("Handwriting recognition requires macOS 27.")
        }

        let byID = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
        let lines = HandwritingLines.group(strokes)
        Task {
            var report = ["Strokes: \(strokes.count), lines: \(lines.count), recognition version \(HandwritingRecognizers.systemVersion)"]
            for (i, line) in lines.enumerated() {
                let t0 = Date()
                let text = await recognizer.text(for: line.strokeIDs.compactMap { byID[$0] })
                report.append("Line \(i + 1) (\(Int(Date().timeIntervalSince(t0) * 1000)) ms): \(text ?? "nil")")
            }
            show(report.joined(separator: "\n\n"))
        }
    }

    private static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Handwriting Recognition"
        alert.informativeText = message
        alert.runModal()
    }
}
#endif
