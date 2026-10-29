import AppKit

extension CanvasView {
    // MARK: Selection

    /// Select all text and strokes in the document, without changing the tool.
    /// Called by the document body's text view on ⌘A, or by CanvasView for other tools.
    func selectAllDocumentContent() {
        guard layout == .document, let body = documentBodyView else { return }

        // Select all text without making the text view first responder.
        let fullRange = NSRange(location: 0, length: body.textStorage.length)
        body.textView.setSelectedRange(fullRange)

        // Select all strokes.
        selection.selectAll()
        // Drop the caret: the canvas owns the selection now, so Delete removes text and ink together.
        window?.makeFirstResponder(self)
    }

    /// Typing, Backspace or cut over the whole text while ⌘A also selected ink
    /// removes that ink too, in the same undo group as the text edit.
    func documentTextWillReplace(_ range: NSRange) {
        guard layout == .document, let body = documentBodyView, !selection.selection.isEmpty,
              range.location == 0, range.length == body.textStorage.length, range.length > 0 else { return }
        let ids = selection.selection
        selection.clear()
        model.remove(ids: ids, actionName: "Delete")
    }

    /// Clear the ink selection; used when text selection changes.
    func clearInkSelection() {
        guard layout == .document else { return }
        selection.clear()
    }

    /// Reuse native editors across layout conversions so earlier typing undo
    /// still targets the editor that becomes visible again.
    public func prepareForPresentation() {
        guard layout == model.effectiveLayout else { return }
        if layout == .document {
            refreshDocumentBodyFromModel()
            documentViewportDidChange()
            reflowDocumentInk()
        } else {
            reconcileTextBlocks(Set(model.textBlocks.map(\.id)))
        }
    }

    func refreshDocumentBodyFromModel() {
        guard layout == .document, model.effectiveLayout == .document,
              let block = model.textBlocks.first else { return }
        let prior = documentBodySyncSuspended
        documentBodySyncSuspended = true
        defer { documentBodySyncSuspended = prior }
        if documentBodyID != block.id {
            documentBodyView?.removeFromSuperview()
            documentBodyID = block.id
            documentBodyView = textViews[block.id]
            documentModelContent = nil
        }
        if documentBodyView == nil {
            let view = configuredTextView(for: block)
            textViews[block.id] = view
            documentBodyView = view
        }
        guard let body = documentBodyView else { return }
        if body.superview !== self { addSubview(body) }
        // Height-only model updates must not replace unsaved native typing.
        if documentModelContent != block.content {
            let contents = block.attributedString
            if !body.textStorage.isEqual(to: contents) { body.setContents(contents) }
            documentModelContent = block.content
        }
        // Model updates land here too: keep the menu's slide, or the text snaps back under the bar.
        body.setFrameOrigin(worldToView(CGPoint(x: block.origin.x, y: block.origin.y + documentBodyShift)))
        body.setWidth(block.width)
        body.setPageHeight(frame.height)
        if let overlay = inkOverlayView, subviews.last !== overlay {
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }

    /// Place the initial caret in a new document body once the window is ready.
    public func focusDocumentBody() {
        guard layout == .document, settings.tool == .pointer,
              let textView = documentBodyView?.textView else { return }
        window?.makeFirstResponder(textView)
    }

    /// The document body is a normal model text block, but it never uses the
    /// canvas draft/commit edit session.
    public func syncDocumentBody() {
        guard layout == .document, model.effectiveLayout == .document,
              !documentBodySyncSuspended, let id = documentBodyID,
              let view = documentBodyView, var block = model.textBlock(id: id) else { return }
        documentSyncWork?.cancel()
        documentSyncWork = nil
        block.origin = viewToWorld(view.frame.origin)
        block.origin.y -= documentBodyShift
        block.width = Double(view.frame.width)
        let contents = NSMutableAttributedString(attributedString: view.textStorage)
        if let provisional = scribeProvisional {
            guard NSMaxRange(provisional.range) <= contents.length else { return }
            contents.deleteCharacters(in: provisional.range)
        } else {
            block.height = Double(view.layoutHeight())
        }
        block.content = TextBlock.content(from: contents)
        documentModelContent = block.content
        model.updateTextBlock(block, actionName: nil)
    }

    /// Insert rich text into the live document body as one native, undoable text edit.
    /// With no index, use the body selection when it is active, otherwise append.
    @discardableResult
    func insertDocumentText(_ text: NSAttributedString, at index: Int? = nil,
                            actionName: String = "Paste") -> Bool {
        guard layout == .document, model.effectiveLayout == .document,
              let view = documentBodyView else { return false }
        syncDocumentBody()
        let textView = view.textView
        let length = view.textStorage.length
        let range: NSRange
        if let index {
            range = NSRange(location: min(max(index, 0), length), length: 0)
        } else if window?.firstResponder === textView {
            range = textView.selectedRange()
        } else {
            range = NSRange(location: length, length: 0)
        }
        model.undoManager.beginUndoGrouping()
        defer { model.undoManager.endUndoGrouping() }
        textView.insertText(text, replacementRange: range)
        model.undoManager.setActionName(actionName)
        return true
    }

    func scheduleDocumentBodySync() {
        guard layout == .document, model.effectiveLayout == .document else { return }
        documentSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncDocumentBody() }
        documentSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        DispatchQueue.main.async { [weak self] in self?.revealDocumentCaret() }
    }

    func documentViewportDidChange(animated: Bool = false) {
        guard layout == .document, model.effectiveLayout == .document, let id = documentBodyID,
              let view = documentBodyView else { return }
        let origin = CGPoint(x: DocumentLayout.sideMargin, y: DocumentLayout.topInset)
        let shown = CGPoint(x: origin.x, y: origin.y + documentBodyShift)
        let width = DocumentLayout.columnWidth(viewportWidth: frame.width)
        let changed = view.frame.origin != worldToView(shown) || abs(view.frame.width - width) > 0.01
        // Only the menu's slide animates; scrolling and resizing stay instant.
        if animated {
            view.animator().setFrameOrigin(worldToView(shown))
        } else {
            view.setFrameOrigin(worldToView(shown))
        }
        view.setWidth(width)
        view.setPageHeight(frame.height)
        guard changed, var block = model.textBlock(id: id) else {
            if model.drawingZones == nil { reflowDocumentInk() } // first sizing: migrate old notes
            return
        }
        block.origin = origin
        block.width = Double(view.frame.width)
        block.height = Double(view.layoutHeight())
        model.updateTextBlock(block, actionName: nil)
        onDocumentEdit?()
        onDocumentLayoutChange?()
    }

    /// How far the body sits below its stored origin: where the tool bar really ends (reported by
    /// the chrome, whatever the window's safe area) plus the open formatting bar.
    var documentBodyShift: CGFloat {
        let measured = toolbarBottom.map { $0 + FloatingChromeLayout.spacing - DocumentLayout.topInset } ?? 0
        return measured + documentBarShift
    }

    /// Called by the chrome with the tool bar's bottom edge, in the canvas's coordinates;
    /// nil when no bar floats over the canvas, which puts the body back at its stored origin.
    public func setToolbarBottom(_ bottom: CGFloat?) {
        guard bottom != toolbarBottom else { return }
        toolbarBottom = bottom
        documentViewportDidChange()
        refreshScribeTarget()
    }

    /// Slides the body down (or back up) with the formatting bar. Only the bar calls this:
    /// the style dropdown draws over the text and leaves the layout alone.
    public func setFormattingBarShown(_ shown: Bool) {
        let shift: CGFloat = shown ? DocumentLayout.formattingBarDrop : 0
        guard shift != documentBarShift else { return }
        documentBarShift = shift
        refreshScribeTarget()
        // Same 0.32s spring as the bar's own transition, so the text and bar move together.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            documentViewportDidChange(animated: true)
        }
        (enclosingScrollView as? CanvasScrollView)?.updateDocumentSize()
    }

    func documentBodyLayoutDidChange() {
        guard layout == .document, model.effectiveLayout == .document,
              let id = documentBodyID, let view = documentBodyView else { return }
        guard scribeProvisional == nil, !documentBodySyncSuspended,
              var block = model.textBlock(id: id) else {
            (enclosingScrollView as? CanvasScrollView)?.updateDocumentSize()
            return
        }
        let height = Double(view.layoutHeight())
        if abs(block.height - height) > 0.01 {
            block.height = height
            model.updateTextBlock(block, actionName: nil)
        } else {
            (enclosingScrollView as? CanvasScrollView)?.updateDocumentSize()
        }
        onDocumentLayoutChange?()
    }

    func documentPenModifiersChanged(option: Bool, function: Bool) {
        let caretActive = settings.tool == .pointer
        penKeyMonitor.activation = caretActive ? .hold : settings.activation
        penKeyMonitor.penKey = settings.penKey == .space && caretActive ? .option : settings.penKey
        penKeyMonitor.flagsChanged(option: option, function: function)
    }

    /// While typing, the pen key (Fn, or Option when the pen key is Space) is a
    /// leader: held with a shortcut key, it runs that shortcut.
    func isDocumentShortcutChord(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard !flags.contains(.command), !flags.contains(.control),
              let key = event.charactersIgnoringModifiers, Self.shortcutKeys.contains(key) else { return false }
        switch settings.penKey == .space ? .option : settings.penKey {
        case .option: return flags.contains(.option)
        case .fn: return flags.contains(.function)
        case .space: return false
        }
    }

    func installDocumentEventMonitor() {
        guard layout == .document, documentEventMonitor == nil else { return }
        documentEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp, .mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            guard let self, self.model.effectiveLayout == .document,
                  let window = self.window, event.window === window,
                  window.isKeyWindow, window.firstResponder === self.documentBodyView?.textView else { return event }

            let caretActive = self.settings.tool == .pointer
            if event.type == .keyDown, caretActive, self.isDocumentShortcutChord(event) {
                // Pen key + a shortcut key: switch instead of typing (or drawing).
                // Lift the pen first, while the Text tool still owns the override.
                self.penKeyMonitor.cancel()
                _ = self.performShortcut(event)
                return nil
            }
            if event.type == .flagsChanged {
                self.documentPenModifiersChanged(option: event.modifierFlags.contains(.option),
                                                  function: event.modifierFlags.contains(.function))
            } else if event.type == .keyDown, !(caretActive && event.keyCode == PenKeyMonitor.spaceKeyCode) {
                self.penKeyMonitor.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat)
            } else if event.type == .keyUp, !(caretActive && event.keyCode == PenKeyMonitor.spaceKeyCode) {
                self.penKeyMonitor.keyUp(keyCode: event.keyCode)
            } else if event.type == .mouseMoved, self.penKeyMonitor.isPenDown {
                self.pointerMoved(event)
            } else if event.type == .leftMouseDragged, self.penKeyMonitor.isPenDown {
                self.pointerMoved(event)
                return nil
            }
            return event
        }
    }

    func revealDocumentCaret() {
        guard layout == .document, let view = documentBodyView,
              window?.firstResponder === view.textView,
              let scrollView = enclosingScrollView else { return }
        let caret = view.selectedCaretRect().offsetBy(dx: view.frame.minX, dy: view.frame.minY)
        view.textView.scrollRangeToVisible(view.textView.selectedRange())
        let clip = scrollView.contentView
        // Clear the formatting bar too while it is open, or the caret scrolls under it.
        let inset = DocumentLayout.topInset + documentBodyShift
        guard caret.minY < clip.bounds.minY + inset else { return }
        clip.scroll(to: NSPoint(x: 0, y: max(0, caret.minY - inset)))
        scrollView.reflectScrolledClipView(clip)
    }
}
