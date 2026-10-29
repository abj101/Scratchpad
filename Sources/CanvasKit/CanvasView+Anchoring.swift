import AppKit

// MARK: - NSLayoutManager adapter

/// Queries the live body layout in the page's world coordinates.
struct DocumentTextLayout: ZoneLayoutQuerying {
    let body: TextBlockView
    private var layoutManager: NSLayoutManager { body.textView.layoutManager! }
    private var textContainer: NSTextContainer { body.textView.textContainer! }
    var scale: CGFloat { body.scale }
    /// World position of the text container's origin.
    var origin: CGPoint {
        CGPoint(x: body.frame.minX + TextBlockView.inset.width * scale,
                y: body.frame.minY + TextBlockView.inset.height * scale)
    }

    init(body: TextBlockView) { self.body = body }

    var characterCount: Int { body.textStorage.length }

    var textTop: CGFloat { origin.y }

    var columnRect: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: textContainer.containerSize.width * scale,
               height: max(0, body.frame.height - 2 * TextBlockView.inset.height * scale))
    }

    var lastLineBottom: CGFloat {
        layoutManager.ensureLayout(for: textContainer)
        let lineBottom = layoutManager.usedRect(for: textContainer).maxY
        let extraBottom = layoutManager.extraLineFragmentRect.maxY
        return origin.y + max(lineBottom, extraBottom) * scale
    }

    var paragraphStarts: [Int] {
        let text = body.textStorage.string as NSString
        var starts = [0]
        var searchFrom = 0
        while searchFrom < text.length {
            let found = text.range(of: "\n", options: [], range: NSRange(location: searchFrom, length: text.length - searchFrom))
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            searchFrom = found.location + 1
        }
        return starts
    }

    func lineBottom(ofCharacterAt index: Int) -> CGFloat? {
        guard index >= 0, index < characterCount else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return origin.y + rect.maxY * scale
    }

    func glyphRect(forCharacterAt index: Int) -> CGRect? {
        guard index >= 0, index <= characterCount else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        if index == characterCount {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty { return worldRect(extra) }
            guard layoutManager.numberOfGlyphs > 0 else { return nil }
            let glyph = layoutManager.numberOfGlyphs - 1
            var used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            used.origin.x = used.maxX
            used.size.width = 0
            return worldRect(used)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                              in: textContainer)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return worldRect(rect)
    }

    /// The occupied rect of every line fragment (one per segment beside a zone).
    func lineFragmentUsedRects() -> [CGRect] {
        layoutManager.ensureLayout(for: textContainer)
        var rects: [CGRect] = []
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return rects }
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphCount)) {
            _, used, _, _, _ in rects.append(self.worldRect(used))
        }
        return rects
    }

    /// Converts a world rect to text-container coordinates (for exclusion paths).
    func containerRect(fromWorld rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - origin.x) / scale, y: (rect.minY - origin.y) / scale,
               width: rect.width / scale, height: rect.height / scale)
    }

    private func worldRect(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
}

// MARK: - CanvasView drawing zones

extension CanvasView {
    func installDocumentAnchoring() {
        guard layout == .document, model.effectiveLayout == .document else { return }
        let previous = model.onInkMutation
        model.onInkMutation = { [weak self] mutation in
            previous?(mutation)
            self?.documentInkDidMutate(mutation)
        }
        onDocumentTextEdit = { [weak self] range, delta in self?.documentTextDidEdit(range, delta: delta) }
        onDocumentLayoutChange = { [weak self] in self?.reflowDocumentInk() }
        reflowDocumentInk()
    }

    private var liveDocumentBody: TextBlockView? {
        guard layout == .document, model.effectiveLayout == .document,
              let body = documentBodyView, body.isDocumentBody else { return nil }
        return body
    }

    private var strokesByID: [UUID: Stroke] {
        Dictionary(uniqueKeysWithValues: model.strokes.map { ($0.id, $0) })
    }

    // MARK: Ink edits

    private func documentInkDidMutate(_ mutation: InkMutation) {
        guard !isReflowingDocumentInk, let body = liveDocumentBody,
              let zones = model.drawingZones else { return } // nil: not migrated yet
        let strokes = strokesByID
        var update: DrawingZones.Update
        switch mutation {
        case .added(let added):
            update = DrawingZones.adding(added.compactMap { strokes[$0.id] }, to: zones, strokesByID: strokes)
        case .removed(let ids):
            update = DrawingZones.removing(ids, from: zones, strokesByID: strokes)
        case .moved(let ids):
            update = DrawingZones.refreshing(ids, in: zones, strokesByID: strokes)
            let known = Set(update.zones.flatMap(\.strokeIDs))
            let stray = ids.subtracting(known).compactMap { strokes[$0] }
            if !stray.isEmpty {
                let extra = DrawingZones.adding(stray, to: update.zones, strokesByID: strokes)
                update = DrawingZones.Update(zones: extra.zones, touched: update.touched.union(extra.touched))
            }
        }
        var result = update.zones
        reanchorZones(&result, ids: update.touched, body: body)
        model.drawingZones = result
        reflowDocumentInk()
        onDocumentEdit?()
    }

    /// Picks the anchor paragraph for each zone in `ids`, in a layout where
    /// those zones do not yet affect the text (so their old shape can't skew
    /// the lines above them).
    private func reanchorZones(_ zones: inout [DrawingZone], ids: Set<UUID>, body: TextBlockView) {
        var pending = ids
        let order = zones.indices.filter { ids.contains(zones[$0].id) }
            .sorted { zones[$0].rect.minY < zones[$1].rect.minY }
        for index in order {
            applyDocumentExclusions(zones.filter { !pending.contains($0.id) }, to: body)
            let anchor = DrawingZones.chooseAnchor(forMinY: zones[index].rect.minY,
                                                   in: DocumentTextLayout(body: body))
            zones[index].paragraphIndex = anchor.paragraphIndex
            zones[index].dy = anchor.dy
            pending.remove(zones[index].id)
        }
    }

    // MARK: Text wrap

    /// Sets the text container's exclusion paths to the zones. Returns whether they changed.
    @discardableResult
    private func applyDocumentExclusions(_ zones: [DrawingZone], to body: TextBlockView) -> Bool {
        guard let container = body.textView.textContainer else { return false }
        let layout = DocumentTextLayout(body: body)
        let rects = DrawingZones.exclusionRects(zones, column: layout.columnRect)
            .map { layout.containerRect(fromWorld: $0) }
        guard container.exclusionPaths.map(\.bounds) != rects else { return false }
        container.exclusionPaths = rects.map { NSBezierPath(rect: $0) }
        body.textView.needsDisplay = true
        return true
    }

    // MARK: Text edits

    private func documentTextDidEdit(_ range: NSRange, delta: Int) {
        guard layout == .document, model.effectiveLayout == .document,
              !model.undoManager.isUndoing, !model.undoManager.isRedoing,
              let zones = model.drawingZones, !zones.isEmpty, let body = documentBodyView,
              range.length > 0 || delta != 0 else { return }
        registerDrawingZoneUndoIfNeeded()
        let starts = DocumentTextLayout(body: body).paragraphStarts
        let count = body.textStorage.length
        model.drawingZones = zones.map { zone in
            var copy = zone
            copy.paragraphIndex = DrawingZones.shiftedIndex(zone.paragraphIndex, editedRange: range,
                                                            changeInLength: delta, paragraphStarts: starts,
                                                            characterCount: count)
            return copy
        }
        onDocumentEdit?()
    }

    /// A text edit also moves the zones' anchors; undoing it restores them.
    func registerDrawingZoneUndoIfNeeded() {
        guard !(model.drawingZones ?? []).isEmpty,
              !hasRegisteredDrawingZoneUndo, !isRestoringDrawingZones else { return }
        hasRegisteredDrawingZoneUndo = true
        let snapshot = model.drawingZones ?? []
        model.undoManager.registerUndo(withTarget: self) { view in
            view.restoreDrawingZones(snapshot)
        }
        DispatchQueue.main.async { [weak self] in self?.hasRegisteredDrawingZoneUndo = false }
    }

    private func restoreDrawingZones(_ zones: [DrawingZone]) {
        let current = model.drawingZones ?? []
        model.undoManager.registerUndo(withTarget: self) { $0.restoreDrawingZones(current) }
        isRestoringDrawingZones = true
        // Strokes are wherever reflow last put them; the snapshot only
        // restores which paragraph each zone hangs from, and its offset.
        model.drawingZones = DrawingZones.resynchronized(zones, strokesByID: strokesByID)
        isRestoringDrawingZones = false
        onDocumentEdit?()
    }

    // MARK: Reflow

    /// Wraps the text around the zones, then moves each zone (and its strokes)
    /// to where its anchor paragraph now puts it.
    func reflowDocumentInk() {
        guard !isReflowingDocumentInk, let body = liveDocumentBody else { return }
        isReflowingDocumentInk = true
        defer { isReflowingDocumentInk = false }
        migrateLegacyDocumentInk(body)
        guard let stored = model.drawingZones else { return }

        var zones = DrawingZones.resynchronized(stored, strokesByID: strokesByID)
        var layoutChanged = false
        for _ in 0...zones.count {
            zones.sort { $0.rect.minY < $1.rect.minY }
            layoutChanged = applyDocumentExclusions(zones, to: body) || layoutChanged
            let moves = DrawingZones.reflowMoves(zones, in: DocumentTextLayout(body: body))
            if moves.isEmpty { break }
            var strokeMoves: [UUID: CGVector] = [:]
            for index in zones.indices {
                guard let delta = moves[zones[index].id] else { continue }
                zones[index].rect = zones[index].rect.offsetBy(dx: delta.dx, dy: delta.dy)
                for id in zones[index].strokeIDs { strokeMoves[id] = delta }
            }
            model.translateStrokes(strokeMoves)
        }
        layoutChanged = applyDocumentExclusions(zones, to: body) || layoutChanged
        if layoutChanged {
            body.relayout()
            body.setPageHeight(frame.height)
        }
        if zones != stored { model.drawingZones = zones; onDocumentEdit?() }
        if layoutChanged || zones != stored {
            (enclosingScrollView as? CanvasScrollView)?.updateDocumentSize()
        }
    }

    // MARK: Migration

    /// Notes saved before zones: drop the sketch-spacer paragraphs and group
    /// the ink into zones where it already is. Old ink that overlapped text
    /// ends up with the text wrapping around it.
    private func migrateLegacyDocumentInk(_ body: TextBlockView) {
        guard model.drawingZones == nil, frame.width > 0, body.frame.width > 1 else { return }
        let storage = body.textStorage
        if !SketchSpacer.ranges(in: storage).isEmpty {
            let priorSuspension = documentBodySyncSuspended
            documentBodySyncSuspended = true
            model.undoManager.disableUndoRegistration()
            storage.beginEditing()
            SketchSpacer.strip(from: storage)
            storage.endEditing()
            body.relayout()
            body.setPageHeight(frame.height)
            model.undoManager.enableUndoRegistration()
            documentBodySyncSuspended = priorSuspension
            syncDocumentBody()
        }
        var zones = DrawingZones.grouping(model.strokes)
        reanchorZones(&zones, ids: Set(zones.map(\.id)), body: body)
        model.inkAnchors = nil
        model.drawingZones = zones
        onDocumentEdit?()
    }

    // MARK: Convert to text

    /// Where recognized handwriting goes: the start of the paragraph its ink
    /// hangs from, as its own paragraph.
    func documentConvertedText(_ text: NSAttributedString, forInk ids: Set<UUID>) -> (NSAttributedString, Int) {
        guard let body = documentBodyView else { return (text, 0) }
        let string = body.textStorage.string as NSString
        let length = string.length
        let zone = model.drawingZones?.first { !$0.strokeIDs.isDisjoint(with: ids) }
        let index = min(zone?.paragraphIndex ?? length, length)
        let result = NSMutableAttributedString()
        if index == length, length > 0, string.character(at: length - 1) != 10 {
            result.append(NSAttributedString(string: "\n", attributes: TextFormatting.defaultAttributes))
        }
        result.append(text)
        if index < length, string.character(at: index) != 10 {
            result.append(NSAttributedString(string: "\n", attributes: TextFormatting.defaultAttributes))
        }
        return (result, index)
    }
}
