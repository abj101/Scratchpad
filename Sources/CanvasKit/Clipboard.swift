import AppKit

// MARK: - Clipboard

/// Canvas objects on the pasteboard (copy / cut / paste / duplicate).
public struct ClipboardPayload: Codable, Equatable {
    public var strokes: [Stroke]
    public var textBlocks: [TextBlock]

    public init(strokes: [Stroke] = [], textBlocks: [TextBlock] = []) {
        self.strokes = strokes; self.textBlocks = textBlocks
    }

    /// Private pasteboard type for the JSON-encoded payload.
    public static let pasteboardType = NSPasteboard.PasteboardType("com.scratchpad.canvas-objects")
    /// Offset applied by Duplicate and by pasting where the copied objects still sit.
    public static let duplicateOffset = CGVector(dx: 20, dy: 20)

    public var isEmpty: Bool { strokes.isEmpty && textBlocks.isEmpty }

    /// Text blocks in the order they were copied, separated as paragraphs.
    public var attributedText: NSAttributedString? {
        guard !textBlocks.isEmpty else { return nil }
        let result = NSMutableAttributedString(string: "")
        for (index, block) in textBlocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: TextFormatting.defaultAttributes))
            }
            result.append(block.attributedString)
        }
        return result
    }

    /// Union bounds of all objects (`.null` if empty).
    public var bounds: CGRect {
        let strokeBounds = strokes.reduce(CGRect.null) { $0.union($1.bounds) }
        return textBlocks.reduce(strokeBounds) { $0.union($1.bounds) }
    }

    /// The selected objects of `model`, in model z-order.
    public init(model: CanvasModel, ids: Set<UUID>) {
        self.init(strokes: model.strokes.filter { ids.contains($0.id) },
                  textBlocks: model.textBlocks.filter { ids.contains($0.id) })
    }

    /// A copy with fresh ids, every object offset by `delta` (stroke points and text origins).
    public func reidentified(offsetBy delta: CGVector) -> ClipboardPayload {
        let newStrokes = strokes.map { stroke -> Stroke in
            var copy = stroke
            copy.id = UUID()
            copy.translate(by: delta)
            return copy
        }

        let newBlocks = textBlocks.map { block -> TextBlock in
            var copy = block
            copy.id = UUID()
            copy.origin.x += delta.dx
            copy.origin.y += delta.dy
            copy.content = TextBlock.content(from: block.attributedString.duplicatingEquations())
            return copy
        }

        return ClipboardPayload(strokes: newStrokes, textBlocks: newBlocks)
    }

    /// Write to `pasteboard` (clears it first). Also writes plain text: the
    /// text blocks' strings joined by blank lines, if any text blocks.
    public func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if let encoded = try? JSONEncoder().encode(self) {
            pasteboard.setData(encoded, forType: Self.pasteboardType)
        }

        if !textBlocks.isEmpty {
            let plainText = textBlocks.map(\.plainText).joined(separator: "\n\n")
            pasteboard.setString(plainText, forType: .string)
        }
    }

    /// Read our type from `pasteboard`; nil if absent or undecodable.
    public static func read(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        guard let data = pasteboard.data(forType: pasteboardType),
              let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) else {
            return nil
        }
        return payload
    }
}

public extension CanvasModel {
    /// Insert `payload` with fresh ids, offset by `delta`, on top of everything,
    /// as one undo step named `actionName`. Returns the new ids (for selecting).
    @discardableResult
    func paste(_ payload: ClipboardPayload, offsetBy delta: CGVector, actionName: String = "Paste") -> Set<UUID> {
        guard !payload.isEmpty else { return [] }
        let reidentified = payload.reidentified(offsetBy: delta)
        append(strokes: reidentified.strokes, textBlocks: reidentified.textBlocks, actionName: actionName)

        return Set(reidentified.strokes.map(\.id)).union(reidentified.textBlocks.map(\.id))
    }
}
