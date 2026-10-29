import AppKit

/// A complete note state used by layout conversion and its single undo step.
public struct NoteModelSnapshot: Equatable {
    public var strokes: [Stroke]
    public var textBlocks: [TextBlock]
    public var layout: NoteLayout?
    public var drawingZones: [DrawingZone]?

    public init(strokes: [Stroke], textBlocks: [TextBlock], layout: NoteLayout?, drawingZones: [DrawingZone]?) {
        self.strokes = strokes
        self.textBlocks = textBlocks
        self.layout = layout
        self.drawingZones = drawingZones
    }
}

/// Builds the model snapshots used to switch one note between its two layouts.
public enum NoteConversion {
    private static let rowTolerance: CGFloat = 12

    /// A document already has one live body; preserve its archived formatting and geometry.
    public static func canvasSnapshot(from model: CanvasModel, bodyID: UUID? = nil) -> NoteModelSnapshot {
        let body = bodyID.flatMap { model.textBlock(id: $0) } ?? model.textBlocks.first
        return NoteModelSnapshot(strokes: model.strokes, textBlocks: body.map { [$0] } ?? [],
                                 layout: .canvas, drawingZones: nil)
    }

    /// Combines canvas blocks in reading order and leaves ink in place for zone migration.
    public static func documentSnapshot(from model: CanvasModel, viewportWidth: CGFloat) -> NoteModelSnapshot {
        var ordered = readingOrder(model.textBlocks)
        let width = Double(DocumentLayout.columnWidth(viewportWidth: viewportWidth))
        let origin = CGPoint(x: DocumentLayout.sideMargin, y: DocumentLayout.topInset)
        if ordered.isEmpty { ordered = [TextBlock(origin: origin, width: max(width, 1))] }
        let joined = NSMutableAttributedString(string: "")

        for (position, block) in ordered.enumerated() {
            if position > 0 {
                joined.append(NSAttributedString(string: "\n\n", attributes: TextFormatting.defaultAttributes))
            }
            joined.append(block.attributedString)
        }

        let content = NSAttributedString(attributedString: joined)
        let body = TextBlock(id: ordered.first?.id ?? UUID(), origin: origin, width: max(width, 1),
                             height: measuredHeight(content, width: max(width, 1)),
                             content: TextBlock.content(from: content))
        // Strokes keep their positions; the document groups them into drawing
        // zones (and wraps the text around them) when it opens.
        return NoteModelSnapshot(strokes: model.strokes, textBlocks: [body], layout: .document, drawingZones: nil)
    }

    private static func readingOrder(_ blocks: [TextBlock]) -> [TextBlock] {
        let vertical = blocks.sorted {
            $0.origin.y == $1.origin.y ? $0.origin.x < $1.origin.x : $0.origin.y < $1.origin.y
        }
        var rows: [[TextBlock]] = []
        for block in vertical {
            if let index = rows.indices.first(where: { abs(rows[$0][0].origin.y - block.origin.y) <= rowTolerance }) {
                rows[index].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows.flatMap { $0.sorted { $0.origin.x < $1.origin.x } }
    }

    private static func measuredHeight(_ string: NSAttributedString, width: Double) -> Double {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(CGFloat(width) - TextBlockView.inset.width * 2, 1),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let bottom = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        return Double(max(bottom + 2 * TextBlockView.inset.height, 1))
    }
}
