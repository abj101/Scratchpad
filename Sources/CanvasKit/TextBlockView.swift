import AppKit

/// A key pressed with the note caret against an inline equation. An equation is one
/// attachment character, but it edits like a run of text: the key enters the live field
/// at the boundary it was pressed against.
enum InlineEquationKey { case backspace, forwardDelete, moveLeft, moveRight }

/// One text object on the canvas: a container hosting a borderless rich-text
/// `NSTextView`. Lives in the canvas document view (so it scales with zoom) and
/// is inert (transparent to hit testing) until `beginEditing()`.
final class TextBlockView: NSView, NSTextViewDelegate, NSTextStorageDelegate {
    static let inset = NSSize(width: 4, height: 4)
    static let handleWidth: CGFloat = 6

    let blockID: UUID
    let textView: NSTextView
    /// `TextBlock.scale`: frame (world) points per bounds (text) point.
    let scale: CGFloat
    private let handle = ResizeHandleView()
    /// Private undo stack used only while editing; keystrokes undo here, not in the model.
    private let editUndoManager = UndoManager()
    private var documentUndoManager: UndoManager?

    private(set) var isEditing = false
    private(set) var isDocumentBody = false

    /// Esc pressed inside the text view.
    var onCancel: (() -> Void)?
    /// A width drag ended with this width (superview points).
    var onResizeEnd: ((CGFloat) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onBeforeCopy: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var drawingCursor: (() -> NSCursor?)? {
        didSet { (textView as? BlockTextView)?.drawingCursor = drawingCursor }
    }
    var onPasteCanvasObjects: (() -> Bool)? {
        didSet { (textView as? BlockTextView)?.onPasteCanvasObjects = onPasteCanvasObjects }
    }
    /// Closure called when ⌘A is pressed to select all text and strokes together.
    var onSelectAll: (() -> Void)? {
        didSet { (textView as? BlockTextView)?.onSelectAll = onSelectAll }
    }
    /// Character edits use the range in the storage after the edit; report its
    /// old range to callers that maintain text-relative anchors.
    var onTextEdit: ((NSRange, Int) -> Void)?
    var onContentsChange: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    /// Called when text selection changes (excluding changes from selecting all).
    /// Used to clear ink selection when the user clicks or moves the caret.
    var onTextSelectionChanged: (() -> Void)? {
        didSet { (textView as? BlockTextView)?.onTextSelectionChanged = onTextSelectionChanged }
    }
    /// A user edit is about to replace `range` (typing, Backspace, cut, paste).
    var onWillChangeText: ((NSRange) -> Void)?
    /// Opens a persisted equation attachment for editing.
    var onEquationOpen: ((EquationAttachment, NSRange, CGPoint) -> Void)?
    /// Delete / arrow with the caret against an inline equation. The canvas reports whether
    /// it took the key over; a Delete it refuses is still swallowed by the text view, so one
    /// stray keystroke can never wipe a whole expression.
    var onEquationKey: ((EquationAttachment, NSRange, InlineEquationKey) -> Bool)? {
        didSet { (textView as? BlockTextView)?.onEquationKey = onEquationKey }
    }

    /// Hide only the active preview; its layout and persisted attachment stay intact.
    var editingEquationID: UUID? {
        didSet {
            (textView.layoutManager as? EquationLayoutManager)?.editingEquationID = editingEquationID
            textView.needsDisplay = true
        }
    }

    var defaultFontSize: CGFloat = TextFormatting.bodySize {
        didSet {
            if textStorage.length == 0 { textView.typingAttributes = TextFormatting.defaultAttributes(fontSize: defaultFontSize) }
        }
    }

    var textStorage: NSTextStorage { textView.textStorage ?? NSTextStorage() }

    func setWritingToolsEnabled(_ enabled: Bool) {
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = enabled ? .default : .none
        }
    }

    /// `width` in superview (world) points.
    init(blockID: UUID, width: CGFloat, scale: CGFloat = 1) {
        self.blockID = blockID
        self.scale = scale
        let width = width / scale
        let storage = NSTextStorage()
        let layoutManager = EquationLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(width - 2 * Self.inset.width, 1), height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = BlockTextView(frame: NSRect(x: 0, y: 0, width: width, height: 20), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: width * scale, height: 20 * scale))
        (textView as? BlockTextView)?.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
        (textView as? BlockTextView)?.onMouseDown = { [weak self] in self?.onMouseDown?() }
        (textView as? BlockTextView)?.onBeforeCopy = { [weak self] in self?.onBeforeCopy?() }
        (textView as? BlockTextView)?.onEquationClick = { [weak self] point in
            guard let self, let hit = self.equation(at: self.convert(point, from: self.textView)) else { return false }
            self.onEquationOpen?(hit.0, hit.1, self.convert(point, from: self.textView))
            return true
        }
        setBoundsSize(NSSize(width: width, height: 20))

        wantsLayer = true
        appearance = NSAppearance(named: .aqua) // the canvas is always light
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFontPanel = true
        textView.usesRuler = true // enables the paragraph controls in the inspector bar
        textView.isRulerVisible = false
        // Formatting controls live in the app's floating bar (FormattingBar).
        textView.usesInspectorBar = false
        setWritingToolsEnabled(false)
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = Self.inset
        textView.isEditable = false
        textView.isSelectable = false
        textView.typingAttributes = TextFormatting.defaultAttributes
        addSubview(textView)

        handle.isHidden = true
        handle.onDrag = { [weak self] x in self?.dragWidth(toViewX: x) }
        handle.onEnd = { [weak self] in
            guard let self else { return }
            self.onResizeEnd?(self.frame.width)
        }
        addSubview(handle)

        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged), name: NSText.didChangeNotification, object: textView)
        // Losing first responder can be temporary (for example, a formatting
        // control). CanvasView owns the explicit boundaries of the edit session.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditing ? super.hitTest(point) : nil
    }

    // MARK: Contents and layout

    func setContents(_ string: NSAttributedString) {
        textStorage.setAttributedString(string)
        if string.length == 0 { textView.typingAttributes = TextFormatting.defaultAttributes(fontSize: defaultFontSize) }
        relayout()
    }

    /// Attachment bounds in this view's coordinates, suitable for editor overlays.
    func rectForAttachment(at characterIndex: Int) -> CGRect? {
        guard characterIndex >= 0, characterIndex < textStorage.length,
              textStorage.attribute(.attachment, at: characterIndex, effectiveRange: nil) is NSTextAttachment,
              let manager = textView.layoutManager, let container = textView.textContainer else { return nil }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: characterIndex, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textView.textContainerOrigin.x,
                                                                                        dy: textView.textContainerOrigin.y).insetBy(dx: -2, dy: -2)
        return textView.convert(rect, to: self)
    }

    func equation(at point: CGPoint) -> (EquationAttachment, NSRange)? {
        var hit: (EquationAttachment, NSRange)?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            guard let equation = value as? EquationAttachment,
                  let rect = rectForAttachment(at: range.location), rect.contains(point) else { return }
            hit = (equation, range)
            stop.pointee = true
        }
        return hit
    }

    /// `width` in superview (world) points.
    func setWidth(_ width: CGFloat) {
        let minimum = isDocumentBody ? 1 : CGFloat(TextBlock.minWidth) * scale
        let w = max(width, minimum)
        guard abs(frame.width - w) > 0.01 else { return }
        setSize(NSSize(width: w / scale, height: bounds.height))
        relayout()
    }

    /// Resizes to `size` text points; the frame is `scale` times larger.
    private func setSize(_ size: NSSize) {
        setFrameSize(NSSize(width: size.width * scale, height: size.height * scale))
        setBoundsSize(size)
    }

    /// Laid-out height including insets, in superview (world) points.
    func layoutHeight() -> CGFloat {
        textLayoutHeight() * scale
    }

    private func textLayoutHeight() -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        var h = lm.usedRect(for: tc).height
        let extra = lm.extraLineFragmentRect
        if extra.height > 0 { h = max(h, extra.maxY) }
        return ceil(h + 2 * Self.inset.height)
    }

    /// A zero-width caret rect at the end of the text, relative to the frame origin
    /// in superview (world) points.
    func endCaretRect() -> CGRect {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return .zero }
        lm.ensureLayout(for: tc)
        var rect: CGRect
        let extra = lm.extraLineFragmentRect
        if extra.height > 0 {
            rect = CGRect(x: extra.minX, y: extra.minY, width: 0, height: extra.height)
        } else if lm.numberOfGlyphs > 0 {
            let used = lm.lineFragmentUsedRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil)
            rect = CGRect(x: used.maxX, y: used.minY, width: 0, height: used.height)
        } else {
            rect = CGRect(x: 0, y: 0, width: 0, height: defaultFontSize * 1.2)
        }
        rect = rect.offsetBy(dx: Self.inset.width, dy: Self.inset.height)
        return CGRect(x: rect.minX * scale, y: rect.minY * scale, width: 0, height: rect.height * scale)
    }

    func selectedCaretRect() -> CGRect {
        let range = textView.selectedRange()
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return .zero }
        lm.ensureLayout(for: tc)
        if range.location >= textStorage.length { return endCaretRect() }
        let glyph = lm.glyphIndexForCharacter(at: range.location)
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return CGRect(x: (rect.minX + Self.inset.width) * scale,
                      y: (rect.minY + Self.inset.height) * scale,
                      width: 0, height: rect.height * scale)
    }

    /// Re-run layout for the current width and resize the frame to fit.
    func relayout() {
        textView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: textView.frame.height)
        let h = textLayoutHeight()
        if abs(bounds.height - h) > 0.01 { setSize(NSSize(width: bounds.width, height: h)) }
        textView.frame = bounds
        layoutHandle()
    }

    /// Keep the one document body live and give its text view the full page for
    /// hit testing below the last line.
    func configureAsDocumentBody(pageHeight: CGFloat, undoManager: UndoManager) {
        isDocumentBody = true
        isEditing = true
        documentUndoManager = undoManager
        textView.textStorage?.delegate = self
        (textView as? BlockTextView)?.clickBelowToEnd = true
        textView.isEditable = true
        textView.isSelectable = true
        handle.isHidden = true
        onResizeEnd = nil
        relayout()
        setPageHeight(pageHeight)
    }

    func setPageHeight(_ height: CGFloat) {
        guard isDocumentBody else { return }
        let h = max(layoutHeight(), height)
        if frame.height != h { setFrameSize(NSSize(width: frame.width, height: h)) }
        textView.frame = bounds
    }

    private func layoutHandle() {
        handle.frame = NSRect(x: bounds.width - Self.handleWidth, y: 0, width: Self.handleWidth, height: bounds.height)
    }

    @objc private func contentChanged(_ note: Notification) {
        renumberLists()
        relayout()
        if isDocumentBody { setPageHeight(superview?.bounds.height ?? frame.height) }
    }

    private var isRenumbering = false

    /// Keeps numbered lists counting correctly after any edit (insert, delete,
    /// paste, indent). Runs inside the same event, so it joins that undo group.
    private func renumberLists() {
        guard !isRenumbering, let storage = textView.textStorage else { return }
        let edits = TextFormatting.renumberEdits(in: storage)
        guard !edits.isEmpty else { return }
        isRenumbering = true
        defer { isRenumbering = false }
        var selection = textView.selectedRange()
        for edit in edits where textView.shouldChangeText(in: edit.range, replacementString: edit.marker) {
            storage.replaceCharacters(in: edit.range, with: edit.marker)
            textView.didChangeText()
            if edit.range.location < selection.location { selection.location += edit.marker.utf16.count - edit.range.length }
        }
        textView.setSelectedRange(selection)
    }

    // MARK: Editing

    /// Make the text view editable and first responder; `point` (in this view's
    /// superview coordinates) places the caret, otherwise it goes to the end.
    func beginEditing(caretAt point: NSPoint? = nil) {
        isEditing = true
        textView.isEditable = true
        textView.isSelectable = true
        handle.isHidden = false
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        window?.makeFirstResponder(textView)
        if let point, let superview {
            let p = textView.convert(point, from: superview)
            let index = textView.characterIndexForInsertion(at: p)
            textView.setSelectedRange(NSRange(location: min(index, textStorage.length), length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: textStorage.length, length: 0))
        }
        window?.invalidateCursorRects(for: self)
    }

    /// Leave editing and drop the private undo history.
    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.isEditable = false
        textView.isSelectable = false
        handle.isHidden = true
        layer?.borderWidth = 0
        editUndoManager.removeAllActions()
        relayout()
    }

    // MARK: Width resize

    private func dragWidth(toViewX x: CGFloat) {
        // `x` is in the superview's coordinates.
        setWidth(x - frame.minX)
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { documentUndoManager ?? editUndoManager }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard isDocumentBody else { return }
        if editedMask.contains(.editedCharacters) {
            onTextEdit?(NSRange(location: editedRange.location, length: max(0, editedRange.length - delta)), delta)
        } else if editedMask.contains(.editedAttributes) {
            onTextEdit?(NSRange(location: editedRange.location, length: 0), 0)
        } else { return }
        onContentsChange?()
        DispatchQueue.main.async { [weak self] in self?.onLayoutChange?() }
    }

    private var isApplyingListEdit = false

    /// Notes-style list typing (see `TextFormatting.listEdit`): a space after
    /// "*" / "1." arrives here as typed text.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        onWillChangeText?(range)
        guard !isApplyingListEdit, let replacementString, replacementString == " " else { return true }
        return !applyListEdit(in: textView, range: range, replacement: replacementString)
    }

    /// Applies the list rule for a keystroke as one undoable change. Returns
    /// false if no rule applies.
    private func applyListEdit(in textView: NSTextView, range: NSRange, replacement: String) -> Bool {
        guard let storage = textView.textStorage,
              let edit = TextFormatting.listEdit(in: storage, range: range, replacement: replacement,
                                                 typingAttributes: textView.typingAttributes)
        else { return false }
        return apply(edit, in: textView)
    }

    private func apply(_ edit: TextFormatting.ListEdit, in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage else { return false }
        isApplyingListEdit = true
        defer { isApplyingListEdit = false }
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement.string) else { return true }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.setSelectedRange(edit.selection) // before didChangeText, which renumbers relative to it
        if let style = edit.typingParagraphStyle { textView.typingAttributes[.paragraphStyle] = style }
        textView.didChangeText()
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        // A plain arrow at an equation's edge steps into the expression instead of over it.
        if commandSelector == #selector(NSResponder.moveLeft(_:)), handleEquationKey(.moveLeft) { return true }
        if commandSelector == #selector(NSResponder.moveRight(_:)), handleEquationKey(.moveRight) { return true }
        // Return / Backspace / Tab in lists: handled before NSTextView's own logic runs.
        let selection = textView.selectedRange()
        if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            guard let storage = textView.textStorage,
                  let edit = TextFormatting.listIndentEdit(in: storage, selection: selection,
                                                           outdent: commandSelector == #selector(NSResponder.insertBacktab(_:)))
            else { return commandSelector == #selector(NSResponder.insertBacktab(_:)) }
            return apply(edit, in: textView)
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), selection.length == 0 {
            return applyListEdit(in: textView, range: selection, replacement: "\n")
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)), selection.length == 0, selection.location > 0 {
            return applyListEdit(in: textView, range: NSRange(location: selection.location - 1, length: 1), replacement: "")
        }
        return false
    }

    /// Hands the key to the equation the caret sits against. Returns whether the text view
    /// must leave the key alone.
    private func handleEquationKey(_ key: InlineEquationKey) -> Bool {
        (textView as? BlockTextView)?.handleEquationKey(key) ?? false
    }
}

/// Excludes the equation being edited from glyph drawing, not from text storage.
/// Temporary drawing state must never leak into saving, clipboard, or undo.
private final class EquationLayoutManager: NSLayoutManager {
    var editingEquationID: UUID?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let id = editingEquationID, let textStorage else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        var hidden: NSRange?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            guard (value as? EquationAttachment)?.id == id else { return }
            hidden = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            stop.pointee = true
        }
        guard let hidden, NSIntersectionRange(hidden, glyphsToShow).length > 0 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        if glyphsToShow.location < hidden.location {
            super.drawGlyphs(forGlyphRange: NSRange(location: glyphsToShow.location,
                                                   length: hidden.location - glyphsToShow.location), at: origin)
        }
        if NSMaxRange(hidden) < NSMaxRange(glyphsToShow) {
            super.drawGlyphs(forGlyphRange: NSRange(location: NSMaxRange(hidden),
                                                   length: NSMaxRange(glyphsToShow) - NSMaxRange(hidden)), at: origin)
        }
    }
}

// MARK: - Text view

/// Copies the selection to the pasteboard as soon as it is made (mouse drag,
/// double/triple click, or keyboard selection), like a terminal's copy-on-select.
private final class BlockTextView: NSTextView {
    private static let attributedEquationType = NSPasteboard.PasteboardType("com.openai.scratchpad.attributed-equations")
    var onPasteCanvasObjects: (() -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onBeforeCopy: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var drawingCursor: (() -> NSCursor?)?
    var onSelectAll: (() -> Void)?
    var onTextSelectionChanged: (() -> Void)?
    var clickBelowToEnd = false
    var onEquationClick: ((CGPoint) -> Bool)?

    /// Track the last-selected range to detect changes (excluding automatic updates).
    private var lastNotifiedSelectionRange = NSRange(location: 0, length: 0)

    override func resetCursorRects() {
        if let cursor = drawingCursor?() {
            addCursorRect(visibleRect, cursor: cursor)
        } else {
            super.resetCursorRects()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = drawingCursor?() { cursor.set() }
        else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let cursor = drawingCursor?() {
            cursor.set()
        } else {
            super.mouseMoved(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        onSelectAll?()
    }

    var onEquationKey: ((EquationAttachment, NSRange, InlineEquationKey) -> Bool)?

    /// Delete against an equation edits the expression itself, the way it would edit a run
    /// of text. Leaving writing mode puts the caret just after the expression, so a stray
    /// key must never remove it whole: the expression is entered and loses one symbol.
    override func deleteBackward(_ sender: Any?) {
        if handleEquationKey(.backspace) { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if handleEquationKey(.forwardDelete) { return }
        super.deleteForward(sender)
    }

    fileprivate func handleEquationKey(_ key: InlineEquationKey) -> Bool {
        guard let onEquationKey, let hit = equationAdjacentToCaret(for: key) else { return false }
        if onEquationKey(hit.0, hit.1, key) { return true }
        // A refused Delete must not fall through to deleting the whole attachment; a refused
        // arrow is fine to fall back to ordinary caret movement.
        switch key {
        case .backspace, .forwardDelete: return true
        case .moveLeft, .moveRight: return false
        }
    }

    /// The equation the collapsed caret sits against in the direction `key` acts, with the
    /// range of its attachment character.
    func equationAdjacentToCaret(for key: InlineEquationKey) -> (EquationAttachment, NSRange)? {
        guard selectedRange().length == 0, let textStorage, textStorage.length > 0 else { return nil }
        let caret = selectedRange().location
        let location = switch key {
        case .backspace, .moveLeft: caret - 1
        case .forwardDelete, .moveRight: caret
        }
        guard location >= 0, location < textStorage.length,
              let equation = textStorage.attribute(.attachment, at: location, effectiveRange: nil) as? EquationAttachment
        else { return nil }
        return (equation, (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: location))
    }

    override func copy(_ sender: Any?) {
        onBeforeCopy?()
        if writeEquationSelection() { return }
        super.copy(sender)
    }

    override func paste(_ sender: Any?) {
        if NSPasteboard.general.data(forType: ClipboardPayload.pasteboardType) != nil,
           onPasteCanvasObjects?() == true { return }
        if let data = NSPasteboard.general.data(forType: Self.attributedEquationType),
           let attributed = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSAttributedString.self, NSMutableAttributedString.self,
                    EquationAttachment.self, NSTextAttachment.self, NSFont.self, NSColor.self, NSParagraphStyle.self], from: data),
           let attributed = attributed as? NSAttributedString, attributed.length > 0 {
            insertPastedEquationText(attributed.duplicatingEquations())
            return
        }
        if let data = NSPasteboard.general.data(forType: .rtfd),
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil),
           attributed.length > 0 {
            insertPastedEquationText(attributed.duplicatingEquations())
            return
        }
        super.paste(sender)
    }

    override func cut(_ sender: Any?) {
        onBeforeCopy?()
        if writeEquationSelection() {
            let range = selectedRange()
            guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
            insertText("", replacementRange: range)
            didChangeText()
            return
        }
        super.cut(sender)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        // Open before NSTextView's selection tracking loop, which otherwise leaves
        // an inactive gray attachment selection behind the live math field.
        if onEquationClick?(convert(event.locationInWindow, from: nil)) == true { return }
        if clickBelowToEnd, let manager = layoutManager, let container = textContainer {
            manager.ensureLayout(for: container)
            let extra = manager.extraLineFragmentRect
            let bottom = manager.usedRect(for: container).maxY
            let point = convert(event.locationInWindow, from: nil)
            let belowEnd = point.y >= (extra.height > 0 ? extra.minY : bottom) + textContainerInset.height
            if belowEnd, let length = textStorage?.length {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: length, length: 0))
                copySelection()
                return
            }
        }
        super.mouseDown(with: event) // runs the selection tracking loop
        copySelection()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Mouse selections copy once on mouse-up (above), not on every drag step.
        if !stillSelecting, NSEvent.pressedMouseButtons == 0 { copySelection() }

        // Notify when text selection changes (but not during mouse dragging).
        // This allows the canvas to clear ink selection when the text selection changes.
        if !stillSelecting {
            let newRange = selectedRange()
            if newRange != lastNotifiedSelectionRange {
                lastNotifiedSelectionRange = newRange
                onTextSelectionChanged?()
            }
        }
    }

    private func copySelection() {
        guard isEditable || isSelectable, selectedRange().length > 0 else { return }
        copy(nil)
    }

    private func writeEquationSelection() -> Bool {
        let range = selectedRange()
        guard range.length > 0, let textStorage,
              textStorage.attribute(.attachment, at: range.location, effectiveRange: nil) is EquationAttachment ||
              (range.location..<NSMaxRange(range)).contains(where: { textStorage.attribute(.attachment, at: $0, effectiveRange: nil) is EquationAttachment }) else { return false }
        let selected = textStorage.attributedSubstring(from: range).duplicatingEquations()
        guard let data = try? selected.data(from: NSRange(location: 0, length: selected.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let archive = try? NSKeyedArchiver.archivedData(withRootObject: selected, requiringSecureCoding: true) {
            pasteboard.setData(archive, forType: Self.attributedEquationType)
        }
        pasteboard.setData(data, forType: .rtfd)
        pasteboard.setString(selected.equationPlainText, forType: .string)
        return true
    }

    private func insertPastedEquationText(_ attributed: NSAttributedString) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return }
        insertText(attributed, replacementRange: range)
        didChangeText()
    }
}

// MARK: - Resize handle

/// Thin strip on a block's right edge that drags the block's width.
private final class ResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: bounds.midX - 1, y: bounds.midY - 8, width: 2, height: 16)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview = superview?.superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}
