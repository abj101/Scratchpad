import AppKit
import Combine

/// The scroll view's document view: a huge flipped view whose center is world
/// (0,0). View coordinates are world coordinates offset by `origin`
/// (no scaling — zoom lives in the enclosing scroll view's magnification).
///
/// The view is layer-backed; AppKit tiles large layer-backed document views,
/// so only the visible region (plus responsive-scrolling overdraw) is rendered.
public final class CanvasView: NSView, NSMenuItemValidation {
    public let model: CanvasModel
    public let settings: CanvasSettings
    public let layout: NoteLayout
    public let toolController: ToolController
    public let selection: SelectionController

    /// Side length of the document view in points.
    public static let documentSize: CGFloat = 200_000
    /// View coordinate of world (0,0), selected by this note's layout.
    let origin: CGFloat

    static let canvasColor = NSColor(srgbRed: 0.995, green: 0.995, blue: 0.99, alpha: 1)
    static let gridDotColor = NSColor(white: 0.78, alpha: 1).cgColor
    static let gridSpacing: CGFloat = 24
    /// Never draw grid dots closer than this on screen.
    static let minGridScreenSpacing: CGFloat = 16

    let inkRenderer: InkRenderer

    enum Gesture {
        /// `pan` is a middle-mouse drag (window coordinates); `select` is a
        /// Pointer-tool drag forwarded to `selection`.
        case none, draw, pan(last: NSPoint), select
    }

    /// The text block currently being edited. A draft is not in the model until committed.
    struct EditSession {
        let view: TextBlockView
        var block: TextBlock
        let isDraft: Bool
        let baseline: NSAttributedString
    }
    var session: EditSession? {
        didSet { settings.isEditingText = session != nil }
    }
    var textViews: [UUID: TextBlockView] = [:]
    var documentBodyID: UUID?
    var documentBodyView: TextBlockView?
    /// View-only offset of the document body from its stored origin: `formattingBarDrop`
    /// while the formatting bar is open, 0 when closed. The style dropdown never changes it.
    var documentBarShift: CGFloat = 0
    /// Measured bottom edge of the floating tool bar; nil until the chrome reports it.
    var toolbarBottom: CGFloat?
    var inkOverlayView: InkOverlayView?
    public var onDocumentEdit: (() -> Void)?
    var onDocumentTextEdit: ((NSRange, Int) -> Void)?
    var onDocumentLayoutChange: (() -> Void)?
    var documentSyncWork: DispatchWorkItem?
    var documentEventMonitor: Any?
    var documentBodySyncSuspended = false
    var documentModelContent: Data?
    var isReflowingDocumentInk = false
    var isRestoringDrawingZones = false
    var hasRegisteredDrawingZoneUndo = false
    var gesture: Gesture = .none
    private var pendingTextTap: NSPoint?

    private var cursorFrame = 0
    private var toolbarHovered = false
    private var cursorAnimation: Timer?
    /// Eraser ring cursor: on-screen radius, its eased target, and a frame cache.
    private var eraserCursorRadius: CGFloat = 0
    private var eraserCursorTarget: CGFloat = 0
    private var eraserCursorAnimation: Timer?
    private var eraserCursorCache: [Int: NSCursor] = [:]
    /// Frame of the dot → I-beam morph shown near text, and its animation toward `textCursorTarget`.
    private var textCursorFrame = 0
    private var textCursorTarget = 0
    private var textCursorAnimation: Timer?
    private var lastMagnification: CGFloat = 0
    /// Magnification the visible region was last fully redrawn at. Zooming
    /// rescales existing tiles, so grid dots, outlines and LOD paths go stale
    /// until redrawn.
    private var renderedMagnification: CGFloat = 0
    private var isLiveMagnifying = false
    /// Selected text views are currently drawn at the live move offset.
    private var textViewsOffset = false
    /// Snapshot of the selected ink and outlines while moving; see `beginMovePreview`.
    private var movePreview: (layer: CALayer, origin: CGRect)?
    private var cancellables: Set<AnyCancellable> = []
    private var resignKeySubscription: AnyCancellable?
    private var resignKeyObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []

    /// Recognizes this note's handwriting for Find; owned by the note session.
    public weak var handwritingIndexer: HandwritingIndexer?
    /// Find hits in reading order, the current one, and the query they were found for.
    private var findMatches: [FindMatch] = []
    private var findIndex = 0
    private var searchedQuery = ""
    private var findTask: Task<Void, Never>?
    private var refindWork: DispatchWorkItem?
    private var convertTask: Task<Void, Never>?

    let penKeyMonitor = PenKeyMonitor()
    let relativeSource = RelativeInputSource()
    let tabletSource = TabletInputSource(mapping: TabletMapping(visibleWorldRect: .zero, inset: 0))
    private let cursorLock = CursorLock()
    private var widthKeyHeld = false
    private var widthScrolled = false
    private var widthMenuOpenedByHold = false
    private var toolMenuMonitor: Any?
    var isCursorLocked: Bool { cursorLock.isLocked }
    private var activeMode: InputMode = .pen
    private var trackpadPressed = false
    /// World rects (outline strips, hover ring, letter cell) the overlay last drew into.
    private var overlayRects: [CGRect] = []
    /// Sits between the pen sources and `toolController` to observe stroke starts.
    private let penTap = PenEventTap()

    /// Row tree and line context saved when a wrap starts a fresh decoder line.
    struct MathWrapSnapshot {
        var root: MathFraction.Row?
        var activeRowID: UUID?
        var lineStats: MathInkTidy.LineStats?
        var resolverStats: MathInkTidy.LineStats?
        var previousSymbol: String?
        var startsAfterWordSpace: Bool
        var cursorOwnsPlacement: Bool
    }

    private func mathWrapSnapshot() -> MathWrapSnapshot {
        MathWrapSnapshot(root: mathFractionRoot, activeRowID: mathActiveRowID, lineStats: mathLineStats,
                         resolverStats: mathResolverStats, previousSymbol: mathPreviousSymbol,
                         startsAfterWordSpace: mathStartsAfterWordSpace,
                         cursorOwnsPlacement: mathCursorOwnsPlacement)
    }

    private func restoreMathWrapSnapshot(_ snapshot: MathWrapSnapshot) {
        mathFractionRoot = snapshot.root
        mathActiveRowID = snapshot.activeRowID
        mathLineStats = snapshot.lineStats
        mathResolverStats = snapshot.resolverStats
        mathPreviousSymbol = snapshot.previousSymbol
        mathStartsAfterWordSpace = snapshot.startsAfterWordSpace
        mathCursorOwnsPlacement = snapshot.cursorOwnsPlacement
    }

    /// A committed Write mode letter: its strokes and the cell before and after it.
    struct WrittenLetter {
        let id: UUID
        var ids: Set<UUID>
        var before: LetterCell
        var after: LetterCell
        /// Original math ink retained with the undoable placement record.
        var originalStrokes: [Stroke] = []
        var likelihoods: [String: Double] = [:]
        var displayed: String? = nil
        /// Label used for math structure (parenthesis stripping, separators): displayed, else the
        /// decoder's best marginal, else the raw classifier label. Ink can still have one.
        var structuralLabel: String? = nil
        var role: MathScript.Role = .body
        var isFunction = false
        var isWideMathBlob = false
        var extent: CGRect = .null
        var rowID: UUID?
        var startsAfterWordSpace = false
        var isFractionSlash = false
        var isFractionArchive = false
        /// Excluded from decoder context after an external erase resets math history.
        var isMathHistoryFrozen = false
        var label: String? {
            get { displayed }
            set { displayed = newValue }
        }
        var beforeLineStats: MathInkTidy.LineStats? = nil
        var beforeResolverStats: MathInkTidy.LineStats? = nil
        var beforePreviousSymbol: String? = nil
        /// Math tree and context as they were when this letter's commit wrapped the line;
        /// Delete restores it so the pre-wrap line comes back.
        var wrapSnapshot: MathWrapSnapshot? = nil
        /// Math tree and context as they were when a word space after this letter wrapped.
        var spaceWrapSnapshot: MathWrapSnapshot? = nil
        /// Scribe only: the letter's strokes, kept until the whole line is recognized.
        var strokes: [Stroke] = []
        /// Scribe only: when the letter's first stroke began and its last ended (media time).
        var start: TimeInterval = 0
        var end: TimeInterval = 0
    }
    /// Write mode cell; kept after leaving the mode so it can be resumed.
    var writingCell: LetterCell?
    /// World x at which the cell wraps to a new line.
    var writingRightLimit: CGFloat = 0
    /// Letters committed on the current placement, for Delete. Restored by undo.
    var writtenLetters: [WrittenLetter] = [] {
        didSet {
            // A deletion or reset leaves nothing to correct, even though an earlier letter is now last.
            if writtenLetters.count < oldValue.count { dismissedCandidateID = writtenLetters.last?.id }
            refreshMathCandidates()
        }
    }
    /// The letter whose candidates were dismissed (deleted after, newline, navigation) until a new one lands.
    private var dismissedCandidateID: UUID?
    #if DEBUG
    private var glyphCapture: GlyphCapture?
    private var captureRestore: (() -> Void)?
    public var isCapturingGlyphs: Bool { glyphCapture != nil }

    public func startGlyphCapture() { startGlyphCapture(directory: GlyphCapture.directory) }

    /// Refuse uncommitted ink: capture must never flush a user's writing into the note.
    func startGlyphCapture(directory: URL) {
        guard glyphCapture == nil else { return }
        guard !tabletSource.isDrawing, !relativeSource.isDrawing, toolController.liveStroke == nil,
              pendingLetter.isEmpty, activeMode != .scribe || writtenLetters.isEmpty,
              !scribeLiveRunning, scribeQueue.isEmpty, session == nil, selection.selection.isEmpty else {
            NSSound.beep()
            return
        }
        let capture: GlyphCapture
        do { capture = try GlyphCapture(directory: directory) }
        catch { NSSound.beep(); return }
        guard capture.label != nil else { NSSound.beep(); return }
        let mode = settings.inputMode, conversion = settings.handwritingToText, math = settings.scribeMath
        let tool = settings.tool, width = settings.width
        let color = settings.color, autoAdvance = settings.writingAutoAdvance
        let cell = writingCell, letters = writtenLetters, limit = writingRightLimit, stats = mathLineStats
        let resolverStats = mathResolverStats, previousSymbol = mathPreviousSymbol
        let stash = stashedWriting
        let target = scribeTarget, index = scribeDocumentIndex, queue = scribeQueue, caret = scribeCaretRect
        let oldMode = activeMode
        let override = toolController.toolOverride
        captureRestore = { [weak self] in
            guard let self else { return }
            // Keep the Combine mode sink suppressed until all @Published setters finish.
            self.settings.handwritingToText = conversion
            self.settings.scribeMath = math
            self.settings.inputMode = mode
            self.settings.tool = tool
            self.settings.width = width
            self.settings.color = color
            self.settings.writingAutoAdvance = autoAdvance
            self.toolController.toolOverride = override
            self.applyInputMode(oldMode)
            self.writingCell = cell
            self.writtenLetters = letters
            self.writingRightLimit = limit
            self.mathLineStats = stats
            self.mathResolverStats = resolverStats
            self.mathPreviousSymbol = previousSymbol
            self.stashedWriting = stash
            self.scribeTarget = target
            self.scribeDocumentIndex = index
            self.scribeQueue = queue
            self.scribeCaretRect = caret
            self.scribeZonesOn = CanvasSettings.offersScribeZones(mode, handwritingToText: conversion)
            self.updateScribeZones()
            self.writingPanel?.cell = cell
            self.writingPanel?.bufferedStrokes = oldMode == .scribe ? letters.flatMap(\.strokes) : []
            self.writingPanel?.isHidden = !oldMode.usesLetterCell
            if oldMode == .scribe { self.refreshScribeTarget() }
            self.updateTabletMapping()
            self.refreshTabletOverlay()
        }
        glyphCapture = capture
        commitWork?.cancel(); commitWork = nil
        wordWork?.cancel(); wordWork = nil
        settings.handwritingToText = false
        settings.inputMode = .write
        settings.tool = .pen
        toolController.toolOverride = .pen
        applyInputMode(.write)
        scribeZonesOn = false
        updateScribeZones()
        writingCell = LetterCell(margin: WritingLayout.scribeOrigin, top: WritingLayout.scribeOrigin,
                                 height: CGFloat(settings.writingLineHeight), deviceAspect: tabletSource.mapping.deviceAspect)
        writtenLetters = []
        writingRightLimit = .greatestFiniteMagnitude
        writingPanel?.isGlyphCapture = true
        writingPanel?.bufferedStrokes = []
        writingPanel?.cell = writingCell
        writingPanel?.isHidden = false
        toolController.strokeSink = { [weak self] in self?.writingStrokeFinished($0) }
        updateTabletMapping()
        updateGlyphCapturePrompt()
    }

    public func saveGlyphCaptureSample() {
        guard let capture = glyphCapture, !tabletSource.isDrawing, toolController.liveStroke == nil,
              !pendingLetter.isEmpty, let cell = writingCell else { NSSound.beep(); return }
        do { try capture.save(pendingLetter, cell: cell.rect) }
        catch { writingPanel?.previewPill?.message = "Save failed; ink kept: \(error.localizedDescription)"; return }
        discardPendingLetter()
        if capture.label == nil { stopGlyphCapture() }
        else { updateGlyphCapturePrompt() }
    }

    public func redoLastGlyphCaptureSample() {
        guard let capture = glyphCapture, !tabletSource.isDrawing, toolController.liveStroke == nil,
              pendingLetter.isEmpty else { NSSound.beep(); return }
        do { try capture.redoLast(); updateGlyphCapturePrompt() }
        catch { writingPanel?.previewPill?.message = "Redo failed: \(error.localizedDescription)" }
    }

    /// Cancel drops only the capture draft. Starting again resumes from valid files.
    public func stopGlyphCapture() {
        guard glyphCapture != nil else { return }
        cancelGesture()
        discardPendingLetter()
        writingPanel?.isGlyphCapture = false
        writingPanel?.previewPill?.message = nil
        writingPanel?.previewPill?.preview = nil
        writingPanel?.previewPill?.context = nil
        toolController.toolOverride = nil
        captureRestore?()
        captureRestore = nil
        glyphCapture = nil
    }

    private func updateGlyphCapturePrompt() {
        guard let capture = glyphCapture, let label = capture.label else { return }
        writingPanel?.previewPill?.message = nil
        writingPanel?.previewPill?.context = "\(capture.count)/\(capture.labels.count * 5) · sample \(capture.sampleNumber)/5"
        writingPanel?.previewPill?.preview = "\(label)  \(GlyphCapture.codepoints(label).joined(separator: " "))"
    }
    #endif
    /// Finished strokes of the letter being written; not in the model until committed.
    var pendingLetter: [Stroke] = []
    /// Original strokes held for an uncertain math symbol until retry, correction, or deletion.
    var unresolvedMathStrokes: [Stroke] = []
    /// Script lanes open at the equation caret, innermost last; mirrors the editor's own stack.
    var mathLanes: [MathScript.Role] = []
    /// Scribe: media time the pending letter's first stroke began and its latest ended.
    private var pendingLetterTimes: (start: TimeInterval, end: TimeInterval)?
    /// Math mode: line statistics for baseline alignment.
    var mathLineStats: MathInkTidy.LineStats?
    /// Resolver geometry stays in the original trackpad coordinates.
    var mathResolverStats: MathInkTidy.LineStats?
    var mathPreviousSymbol: String?
    var mathGlyphClassifier = MathGlyphClassifier.shared
    var mathFractionRoot: MathFraction.Row?
    var mathActiveRowID: UUID?
    /// The root a raised symbol would index: set when √ opens, consumed by its index.
    var mathPendingRootID: UUID?
    var mathStartsAfterWordSpace = false
    /// Arrow navigation owns placement until the next symbol is committed.
    private var mathCursorOwnsPlacement = false
    private var pendingMathReopenedID: UUID?
    var mathFunctionRecognizer: HandwritingRecognizer? = HandwritingRecognizers.system()
    private var mathFunctionRun: [UUID] = []
    private var mathFunctionWork: DispatchWorkItem?
    private var mathFunctionRequest: [UUID] = []
    private var mathFunctionRecognitionTask: Task<Void, Never>?
    private var pendingMathEquationFinish: Bool?
    private var deleteAfterMathClose = false
    private var wideFunctionRequest: UUID?
    var mathLineDecoderForTesting: MathLineDecoder?
    #if DEBUG
    var mathTidyEnabledForTesting: Bool?
    #endif
    /// Friction: last drawing point (world), travel since the last click (trackpad widths), last click time.
    private var frictionLast: CGPoint?
    private var frictionTravel: CGFloat = 0
    private var frictionLastClick: TimeInterval = 0
    /// Which side of the cell's middle line the finger was last on (−1 above, 1 below).
    private var commitWork: DispatchWorkItem?

    // Scribe state: the word being written lives in `writtenLetters` (with strokes) and
    // `pendingLetter`, in a private cell far from the content, never in the model.
    /// Idle timer that sends the buffered word to recognition.
    private var wordWork: DispatchWorkItem?
    /// The text block recognized words are appended to; nil until the first word makes one.
    var scribeTarget: UUID?
    /// In document mode, the insertion point stays with Scribe across recognizer latency.
    var scribeDocumentIndex: Int?
    var scribeApplyingDocumentEdit = false
    /// What each word/line break appended to the target this session, for Delete.
    private var scribeQueue = ScribeQueue()
    /// Write mode's cell state and drawing width, set aside while Scribe uses its own.
    /// `width` is nil when the unified-width setting lets Scribe keep (and change) the
    /// current width, so there is nothing to restore.
    private var stashedWriting: (cell: LetterCell?, letters: [WrittenLetter], rightLimit: CGFloat, width: Double?)?
    /// World rect of the caret drawn at the end of the target's text.
    private var scribeCaretRect: CGRect?
    private var scribeCaretVisible = true
    private var scribeCaretBlink: Timer?
    private var scribeMessageToken = 0
    /// Cleans recognized phrases (spaces, punctuation, spelling); nil or unavailable falls back to the spell checker.
    var scribePolisher: TextPolisher? = TextPolishers.system()
    /// Live recognition of the line being written: one request in flight at a time, and at most
    /// one more remembered (`scribeLiveDirty`) that re-reads whatever the line is by then.
    private var scribeLiveRunning = false
    private var scribeLiveDirty = false
    private var scribeLiveGeneration = 0
    /// The latest finished live result and the line stroke ids it covers.
    private var scribeLiveResult: (ids: [UUID], text: String?)?
    /// Word knowledge for splitting run-together text; its personal names are refreshed on entering Scribe.
    private var scribeLexicon = ScribeLexicon.system
    /// Bumped on every append/delete/leave; a background polish only applies if it still matches.
    private var scribePolishToken = 0
    /// Words the polish pass repaired with high confidence; later passes only change text after them.
    private var scribeLocks: [ScribeLock] = []
    /// A lone Control or Command press and when it began; released quickly with no key, click
    /// or scroll in between, it toggles math input (Control) or auto-advance (Command).
    private var modifierTap: (flags: NSEvent.ModifierFlags, time: TimeInterval)?
    private var modifierTapMonitor: Any?
    /// On entering Write mode, the pen goes down once every finger is lifted.
    private var zonePenPending = false
    /// Scribe's trackpad zones are live (Write family with handwriting-to-text on).
    private var scribeZonesOn = false
    private var scribePolishWork: DispatchWorkItem?
    /// The live, unconfirmed text shown at the end of the target's text view (view only, never in
    /// the model): what it is (separator included) and where it sits.
    var scribeProvisional: (text: String, range: NSRange)?
    /// The target block was made (silently, no undo) just to show provisional text.
    var scribeProvisionalMadeBlock = false
    /// Set by `CanvasScrollView`.
    weak var writingPanel: WritingPanelView?

    private var activeSource: PenInputSource? {
        switch activeMode {
        case .pen: relativeSource
        case .tablet, .write, .scribe: tabletSource
        }
    }

    public init(model: CanvasModel, settings: CanvasSettings, layout: NoteLayout = .canvas) {
        self.model = model
        self.settings = settings
        self.layout = layout
        self.origin = layout == .document ? 0 : Self.documentSize / 2
        self.toolController = ToolController(model: model, settings: settings)
        self.selection = SelectionController(model: model, includesTextBlocks: layout == .canvas)
        self.inkRenderer = InkRenderer(model: model, toolController: toolController)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.documentSize, height: Self.documentSize))
        if layout == .document {
            let overlay = InkOverlayView(canvasView: self)
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            inkOverlayView = overlay
            addSubview(overlay)
            if let body = model.textBlocks.first {
                documentBodyID = body.id
            } else {
                let body = TextBlock(origin: CGPoint(x: DocumentLayout.sideMargin, y: DocumentLayout.topInset), width: 1)
                documentBodyID = body.id
                model.addTextBlockSilently(body)
            }
            // A note with no ink has nothing to migrate. Left nil, the first stroke skips zone
            // anchoring and the late migration re-places it, which reads as a shift.
            if model.drawingZones == nil, model.strokes.isEmpty { model.drawingZones = [] }
        }
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        bindModel()
        bindSelection()
        bindSettings()
        bindInput()
        bindTextBlocks()
        if layout == .document {
            installDocumentAnchoring()
            installDocumentEventMonitor()
            // In document layout, expand hit to select entire zone
            selection.expandHit = { [weak self] id in
                guard let self, let zones = self.model.drawingZones else { return [id] }
                if let zone = zones.first(where: { $0.strokeIDs.contains(id) }) {
                    return zone.strokeIDs
                }
                return [id]
            }
        }
        bindFind()
        // Accept trackpad touches from the start; enabling them only on entering
        // Tablet mode doesn't reliably register the window for touch delivery.
        // `forwardTouches` ignores them outside Tablet mode.
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let toolMenuMonitor { NSEvent.removeMonitor(toolMenuMonitor) }
        cursorAnimation?.invalidate()
        eraserCursorAnimation?.invalidate()
        cursorLock.unlock()
        findTask?.cancel()
        convertTask?.cancel()
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        if let documentEventMonitor { NSEvent.removeMonitor(documentEventMonitor) }
        if let modifierTapMonitor { NSEvent.removeMonitor(modifierTapMonitor) }
        documentSyncWork?.cancel()
        followLink?.invalidate()
        cancelMathEditorIdleRelease()
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var undoManager: UndoManager? { model.undoManager }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        let heightChanged = frame.height != newSize.height
        super.setFrameSize(newSize)
        if layout == .document { inkOverlayView?.frame = bounds }
        if widthChanged, layout == .document, documentBodyView != nil {
            documentViewportDidChange()
        } else if heightChanged, layout == .document {
            documentBodyView?.setPageHeight(newSize.height)
        }
    }

    // MARK: Coordinates

    public func worldToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + origin, y: p.y + origin)
    }

    public func viewToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - origin, y: p.y - origin)
    }

    public func viewRect(for worldRect: CGRect) -> CGRect {
        worldRect.offsetBy(dx: origin, dy: origin)
    }

    public func worldRect(for viewRect: CGRect) -> CGRect {
        viewRect.offsetBy(dx: -origin, dy: -origin)
    }

    var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// Invalidate a world rect, padded by a couple of screen pixels for antialiasing.
    func setNeedsDisplay(world rect: CGRect) {
        guard !rect.isNull else { return }
        let pad = 2 / magnification
        let viewRect = viewRect(for: rect).insetBy(dx: -pad, dy: -pad)
        if layout == .document {
            inkOverlayView?.setNeedsDisplay(viewRect)
        } else {
            setNeedsDisplay(viewRect)
        }
    }

    // MARK: Bindings

    private func bindModel() {
        let previous = model.onChange
        model.onChange = { [weak self] rect in
            previous?(rect)
            self?.modelDidChange(rect)
        }
        toolController.onLiveChange = { [weak self] rect in
            self?.setNeedsDisplay(world: rect)
            self?.setWritingPanelNeedsDisplay(world: rect)
        }
        let previousStrokes = model.onStrokesChange
        model.onStrokesChange = { [weak self] ids in
            previousStrokes?(ids)
            self?.inkRenderer.invalidate(ids)
        }
    }

    private func bindTextBlocks() {
        let previous = model.onTextBlocksChange
        model.onTextBlocksChange = { [weak self] ids in
            previous?(ids)
            self?.reconcileTextBlocks(ids)
            (self?.enclosingScrollView as? CanvasScrollView)?.updateDocumentSize()
            self?.pruneSelection()
            self?.scheduleRefind()
        }
        reconcileTextBlocks(Set(model.textBlocks.map(\.id)))
    }

    private func modelDidChange(_ rect: CGRect) {
        // Stroke contents never change for a given id, so only drop removed ids.
        inkRenderer.pruneRemovedStrokes()
        (enclosingScrollView as? CanvasScrollView)?.updateDocumentSize()
        setNeedsDisplay(world: rect)
        setWritingPanelNeedsDisplay(world: rect)
        pruneSelection()
        scheduleRefind()
    }

    private func bindSettings() {
        settings.$backgroundColor.removeDuplicates().sink { [weak self] color in
            guard let self else { return }
            self.enclosingScrollView?.backgroundColor = color.nsColor
            self.needsDisplay = true
            self.writingPanel?.needsDisplay = true
        }.store(in: &cancellables)
        // @Published emits on willSet: `settings.tool` still holds the old tool
        // here, so a cancel is routed to the tool that started the gesture.
        settings.$tool
            .removeDuplicates()
            .sink { [weak self] tool in
                guard let self else { return }
                #if DEBUG
                NSLog("DBG tool -> %@\n%@", tool.rawValue, Thread.callStackSymbols.prefix(10).joined(separator: "\n"))
                #endif
                #if DEBUG
                if self.isCapturingGlyphs { return }
                #endif
                self.cancelGesture()
                if tool == .eraser { self.penKeyMonitor.cancel() }
                self.finishEditing()
                if tool != .pointer { self.clearSelection() }
                DispatchQueue.main.async {
                    if self.layout == .document, tool == .pointer { self.focusDocumentBody() }
                    // Away from the selector, plain keys are shortcuts again, not typing.
                    if self.layout == .document, tool != .pointer,
                       let textView = self.documentBodyView?.textView,
                       self.window?.firstResponder === textView {
                        self.window?.makeFirstResponder(self)
                    }
                    self.updateCursor()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Input modes

    private func bindInput() {
        relativeSource.activate(in: self)
        updateTrackingAreas()
        penTap.target = toolController
        penTap.willHandle = { [weak self] in self?.penWillHandle($0) }
        relativeSource.sink = penTap
        tabletSource.sink = penTap
        tabletSource.onStateChange = { [weak self] in self?.tabletStateDidChange() }
        // After the touch is processed: a math toggle swaps the input mode.
        tabletSource.onZoneTap = { [weak self] zone in DispatchQueue.main.async { self?.scribeZoneTapped(zone) } }
        // Ahead of menu key equivalents, so a ⌘ or ⌃ shortcut never counts as a lone tap.
        modifierTapMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            if let self, event.window != nil, event.window === self.window { self.trackModifierTap(event) }
            return event
        }
        settings.$writingAutoAdvance
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in
                guard let self, on, !self.pendingLetter.isEmpty else { return }
                // Resume: let the waiting letter commit as if just written.
                DispatchQueue.main.async { self.scheduleLetterCommit() }
            }
            .store(in: &cancellables)
        penKeyMonitor.penKey = settings.penKey
        penKeyMonitor.activation = settings.activation
        penKeyMonitor.onTransition = { [weak self] transition in
            guard let self else { return }
            self.zonePenPending = false
            if transition == .down, self.followSuspended {
                // The pen owns the viewport again after a manual scroll.
                self.followSuspended = false
                if self.activeMode == .scribe { self.followWritingCell() }
            }
            // The eraser only erases on click and Text never draws; the pen key never puts either down.
            if transition == .down, self.inputTool == .eraser || self.textTool {
                self.settings.penIsDown = self.trackpadPressed
                return
            }
            if self.activeMode.usesTabletInput {
                if transition == .down, self.activeEquationEditor != nil,
                   !self.settings.isToolMenuPresented, !self.cursorLock.isLocked {
                    self.cursorLock.lock(centeredIn: self)
                }
                if transition == .cancelled { self.trackpadPressed = false }
                let effective: PenTransition = transition == .cancelled ? .cancelled
                    : (self.trackpadPressed || self.penKeyDraws ? .down : .up)
                self.tabletSource.penChanged(effective, timestamp: ProcessInfo.processInfo.systemUptime)
                if self.settings.activation == .toggle, !self.settings.isToolMenuPresented {
                    if transition == .down { if !self.cursorLock.isLocked { self.cursorLock.lock(centeredIn: self) } } else { self.cursorLock.unlock() }
                    self.window?.invalidateCursorRects(for: self)
                    self.tabletStateDidChange()
                }
            } else {
                if transition == .down { self.cancelGesture() }
                self.activeSource?.penChanged(transition, timestamp: ProcessInfo.processInfo.systemUptime)
            }
            self.settings.penIsDown = self.trackpadPressed || self.penKeyDraws
            self.updateCursor()
        }
        settings.$penKey
            .removeDuplicates()
            .sink { [weak self] in self?.penKeyMonitor.penKey = $0 }
            .store(in: &cancellables)
        settings.$activation
            .removeDuplicates()
            .sink { [weak self] in self?.penKeyMonitor.activation = $0 }
            .store(in: &cancellables)
        // @Published emits on willSet: use the value passed, not `settings.inputMode`.
        settings.$inputMode.combineLatest(settings.$handwritingToText, settings.$scribeMath)
            .map { (CanvasSettings.effectiveMode($0, handwritingToText: $1, math: $2),
                    CanvasSettings.offersScribeZones($0, handwritingToText: $1), $2) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] mode, zones, math in
                guard let self else { return }
                #if DEBUG
                if self.isCapturingGlyphs { return }
                #endif
                self.scribeZonesOn = zones
                if self.activeMode == .scribe { self.prepareScribeMathVariant(math) }
                self.applyInputMode(mode)
                if mode == .scribe { self.prepareScribeMathVariant(math) }
                self.updateScribeZones()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeMode == .scribe else { return }
                    self.prepareScribeMathVariant(self.settings.scribeMath)
                    self.updateScribeZones()
                }
            }
            .store(in: &cancellables)
        settings.$defaultFontSize
            .removeDuplicates()
            .sink { [weak self] size in
                guard let self else { return }
                let canonical = CanvasSettings.canonicalFontSize(size)
                self.textViews.values.forEach { $0.defaultFontSize = CGFloat(canonical) }
                // Handwriting follows the font size, so the letter cell tracks it too.
                self.writingCellHeightDidChange(CGFloat(canonical))
            }
            .store(in: &cancellables)

        settings.$writingToolsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.textViews.values.forEach { $0.setWritingToolsEnabled(enabled) }
                self.documentBodyView?.setWritingToolsEnabled(enabled)
            }
            .store(in: &cancellables)

        settings.$toolMenu
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] open in
                guard let self else { return }
                if open {
                    self.cancelGesture()
                    self.releaseInput(dropTablet: false)
                    self.tabletSource.touchesChanged([], timestamp: ProcessInfo.processInfo.systemUptime)
                    self.window?.invalidateCursorRects(for: self)
                    NSCursor.arrow.set()
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.updateCursor()
                        guard self.activeMode.usesTabletInput,
                              !self.settings.isToolMenuPresented, self.window?.isKeyWindow == true else { return }
                        self.window?.makeFirstResponder(self)
                        self.lockCursorForPen()
                    }
                }
            }
            .store(in: &cancellables)

        // Menus can move focus or the pointer away from the canvas. Keep the
        // hold shortcut and its release scoped to this canvas's window.
        toolMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyUp, .keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .keyDown, self.activeEquationEditor != nil,
               event.keyCode == PenKeyMonitor.escapeKeyCode {
                self.exitMathEditing()
                return nil
            }
            // ⌘A and Delete must reach the note while focus sits in the equation field.
            if event.type == .keyDown, self.activeEquationEditor != nil {
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a",
                   self.layout == .document, self.model.effectiveLayout == .document {
                    self.selectAllDocumentContent()
                    // The open equation is drawn by its editor, not the text view: highlight it there too.
                    self.activeEquationEditor?.navigate("selectAll")
                    return nil
                }
                if [Self.deleteKeyCode, Self.forwardDeleteKeyCode].contains(event.keyCode),
                   !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                   !self.selection.selection.isEmpty || self.documentTextIsFullySelected {
                    self.deleteSelection()
                    return nil
                }
            }
            if self.activeEquationEditor != nil, self.activeMode == .scribe {
                if event.type == .keyDown, !self.unresolvedMathStrokes.isEmpty,
                   event.keyCode == Self.deleteKeyCode {
                    self.clearUnresolvedMathInput()
                    return nil
                }
                if event.type == .flagsChanged {
                    self.penKeyMonitor.flagsChanged(option: event.modifierFlags.contains(.option),
                                                    function: event.modifierFlags.contains(.function))
                }
                if event.type == .keyDown, !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control),
                   self.penKeyMonitor.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat) { return nil }
                if event.type == .keyUp, self.penKeyMonitor.keyUp(keyCode: event.keyCode) { return nil }
            }
            if event.type == .scrollWheel, self.handleWidthScroll(event) { return nil }
            if event.type == .keyUp, self.releaseWidthKey(event) { return nil }
            if event.type == .keyDown, self.settings.isToolMenuPresented,
               !(window.firstResponder is NSTextView),
               event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
               let key = event.charactersIgnoringModifiers, ["q", "w", "e"].contains(key) {
                self.keyDown(with: event)
                return nil
            }
            return event
        }

        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.releaseInput(dropTablet: true)
            },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.cursorLock.unlock()
            },
        ]
    }

    private func applyInputMode(_ mode: InputMode) {
        guard mode != activeMode else { return }
        #if DEBUG
        NSLog("DBG inputMode %@ -> %@", activeMode.rawValue, mode.rawValue)
        #endif
        // In toggle mode, changing input modes ends the current drawing gesture;
        // commit it through the same path as lifting the pen.
        if activeMode == .pen, settings.activation == .toggle, relativeSource.isDrawing {
            relativeSource.penChanged(.up, timestamp: ProcessInfo.processInfo.systemUptime)
        }
        cancelGesture()
        penKeyMonitor.cancel()
        settings.penIsDown = false
        activeSource?.deactivate()
        if activeMode.usesTabletInput { cursorLock.unlock() }
        // Scribe ⇄ math keeps the panel up: morph it rather than swap.
        let morph = activeMode.usesLetterCell && mode.usesLetterCell ? writingPanel?.beginMorph() : nil
        if activeMode.usesLetterCell { leaveWriting() }
        activeMode = mode
        activeSource?.activate(in: self)
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
        if mode.usesLetterCell { enterWriting() }
        if let morph {
            updateScribeZones()
            writingPanel?.finishMorph(morph)
        }
        if mode.usesTabletInput {
            updateTabletMapping()
            window?.makeFirstResponder(self)
            if !settings.isToolMenuPresented {
                // Start already absolute: locked, with the pen going down once no finger is on the pad.
                cursorLock.lock(centeredIn: self)
                if settings.activation == .toggle {
                    zonePenPending = true
                    tabletStateDidChange()
                }
            }
        }
        refreshTabletOverlay()
    }

    /// Absolute modes lock the cursor, except in Toggle activation while the pen is toggled off.
    private func lockCursorForPen() {
        guard settings.activation == .hold || penKeyMonitor.isPenDown else { return }
        cursorLock.lock(centeredIn: self)
    }

    /// Cancel any stroke and pen state, free the cursor, and optionally leave Tablet mode.
    private func releaseInput(dropTablet: Bool) {
        widthKeyHeld = false
        widthScrolled = false
        widthMenuOpenedByHold = false
        cursorAnimation?.invalidate()
        cursorAnimation = nil
        cursorFrame = toolbarHovered ? Cursors.canvasToArrow.count - 1 : 0
        trackpadPressed = false
        penKeyMonitor.cancel()
        activeSource?.penChanged(.cancelled, timestamp: ProcessInfo.processInfo.systemUptime)
        settings.penIsDown = false
        cursorLock.unlock()
        if dropTablet, activeMode.usesTabletInput { settings.inputMode = .pen }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, activeMode.usesTabletInput, !settings.isToolMenuPresented, !cursorLock.isLocked { lockCursorForPen() }
        // Hover exits stop arriving once another window (Settings) is key, so drop the custom cursor here.
        resignKeySubscription = window.map {
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: $0)
                .sink { [weak self] _ in
                    guard let self, !self.cursorLock.isLocked else { return }
                    self.setToolbarHovered(true)
                    self.snapCursorToArrow()
                }
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Every mode tracks moves for the near-text cursor; pen mode also feeds relative input.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        guard pointerIsOverCanvas else { return }
        if toolbarHovered { setToolbarHovered(false) } else { cursorFrame = 0 }
        updateCursor()
    }

    public override func mouseExited(with event: NSEvent) {
        // Onto chrome or out of the window: morph to the arrow rather than snapping (or leaving the dot behind).
        setToolbarHovered(true)
        // The morph timer stops once the pointer is outside the window frame, so land on the arrow now.
        if let window, !window.frame.contains(NSEvent.mouseLocation), !cursorLock.isLocked { snapCursorToArrow() }
    }

    /// Lands on the arrow frame at once, for exits the morph timer can't finish.
    private func snapCursorToArrow() {
        cursorFrame = Cursors.canvasToArrow.count - 1
        currentCursor().set()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            finishEditing(restoreFocus: false)
            releaseInput(dropTablet: true)
        }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        guard let newWindow else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main
        ) { [weak self] _ in
            self?.cancelGesture()
            if let self { self.releaseInput(dropTablet: !self.settings.isToolMenuPresented) }
            self?.finishEditingIfWindowInactive()
        }
    }

    /// Called by the scroll view whenever its clip view bounds change.
    func magnificationDidChange() {
        positionMathEditor()
        if magnification != renderedMagnification {
            // Mid-pinch, only redraw when the grid step or LOD level changes; the
            // rest is caught up once the gesture ends.
            if !isLiveMagnifying || renderKey(for: magnification) != renderKey(for: renderedMagnification) {
                redrawForMagnification()
            } else if magnification != lastMagnification, movePreview == nil, !selection.selection.isEmpty {
                // Outline widths are in screen pixels.
                setNeedsDisplay(world: selectionDirtyRect(liveSelectionBounds))
            }
        }
        lastMagnification = magnification
        updateTabletMapping()
        // The eraser ring is in screen points, so zooming changes its size.
        if inputTool == .eraser, window != nil {
            updateEraserCursor()
            window?.invalidateCursorRects(for: self)
        }
    }

    func liveMagnifyWillStart() { isLiveMagnifying = true }

    func liveMagnifyDidEnd() {
        isLiveMagnifying = false
        if magnification != renderedMagnification { redrawForMagnification() }
    }

    private func renderKey(for m: CGFloat) -> (CGFloat, Int) { (gridStep(for: m), StrokeLOD.level(for: m)) }

    /// Repaint the visible region plus a margin for responsive-scrolling overdraw.
    private func redrawForMagnification() {
        renderedMagnification = magnification
        let r = visibleRect
        setNeedsDisplay(r.insetBy(dx: -r.width, dy: -r.height))
    }

    // MARK: Tablet mapping and overlay

    /// Tablet mode maps onto the viewport; Write mode onto the writing box, so
    /// panning and zooming never move where ink lands.
    private func updateTabletMapping() {
        guard activeMode.usesTabletInput else { return }
        // A spatial commit can happen at pen-down. Keep the input coordinates stable
        // through the next symbol's strokes, then advance on its idle commit.
        if isMathWriteEnabled, tabletSource.isDrawing || !pendingLetter.isEmpty { return }
        var mapping = tabletSource.mapping
        if activeMode.usesLetterCell {
            guard let cell = writingCell else { return }
            mapping.visibleWorldRect = cell.rect
            mapping.inset = 0
        } else {
            mapping.visibleWorldRect = worldRect(for: visibleRect)
            mapping.inset = TabletMapping.defaultScreenInset / magnification
        }
        guard mapping != tabletSource.mapping else { return }
        tabletSource.mapping = mapping
        refreshTabletOverlay()
    }

    private func currentOverlayRects() -> [CGRect] {
        if activeMode == .scribe { return [] }
        if activeMode == .write { return writingOverlayRects() }
        guard activeMode == .tablet else { return [] }
        let m = magnification
        let a = tabletSource.mapping.activeRect
        var rects: [CGRect] = []
        if !a.isEmpty {
            let p = 4 / m
            rects += [
                CGRect(x: a.minX - p, y: a.minY - p, width: a.width + 2 * p, height: 2 * p),
                CGRect(x: a.minX - p, y: a.maxY - p, width: a.width + 2 * p, height: 2 * p),
                CGRect(x: a.minX - p, y: a.minY - p, width: 2 * p, height: a.height + 2 * p),
                CGRect(x: a.maxX - p, y: a.minY - p, width: 2 * p, height: a.height + 2 * p),
            ]
        }
        if let h = tabletSource.hoverPoint {
            let r = Self.hoverExtent / m
            rects.append(CGRect(x: h.x - r, y: h.y - r, width: 2 * r, height: 2 * r))
        }
        return rects
    }

    private func refreshTabletOverlay() {
        let new = currentOverlayRects()
        for r in overlayRects + new { setNeedsDisplay(world: r) }
        overlayRects = new
    }

    /// Screen-point radius of the hover dot.
    private static let hoverExtent: CGFloat = 9

    private func drawTabletOverlay(in ctx: CGContext) {
        let m = magnification
        let gray = NSColor.systemGray
        ctx.setStrokeColor(gray.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1.5 / m)
        ctx.setLineDash(phase: 0, lengths: [6 / m, 4 / m])
        ctx.setLineCap(.butt)
        let a = tabletSource.mapping.activeRect
        if !a.isEmpty {
            let radius = min(12 / m, min(a.width, a.height) / 2)
            ctx.addPath(CGPath(roundedRect: a, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])

        guard let h = tabletSource.hoverPoint else { return }
        let r = Self.hoverExtent / m
        let dot = CGRect(x: h.x - r, y: h.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(gray.withAlphaComponent(0.5).cgColor)
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(gray.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1 / m)
        ctx.strokeEllipse(in: dot.insetBy(dx: 0.5 / m, dy: 0.5 / m))
    }

    // MARK: Write mode
    //
    // The trackpad maps onto `writingCell`, one letter-sized cell at a text cursor.
    // Finished strokes collect in `pendingLetter`; after a short idle they commit as
    // one undoable letter, shifted left to the cursor, and the cell moves past it.
    // The cell only moves between strokes. The panel shows it magnified.

    private func enterWriting() {
        if activeMode == .scribe { return enterScribe() }
        let visible = worldRect(for: visibleRect)
        let m = magnification
        let height = CGFloat(settings.writingLineHeight)
        let aspect = tabletSource.mapping.deviceAspect
        if var cell = writingCell, cell.rect.intersects(visible) {
            cell.height = height
            cell.setDeviceAspect(aspect)
            writingCell = cell
        } else {
            let cell: LetterCell
            if layout == .document, model.effectiveLayout == .document, let body = documentBodyView {
                let caret = body.selectedCaretRect().offsetBy(dx: body.frame.minX, dy: body.frame.minY)
                let column = CGRect(x: body.frame.minX, y: 0, width: body.frame.width, height: frame.height)
                let point = WritingLayout.documentCellOrigin(visible: visible, column: column, caret: caret)
                cell = LetterCell(margin: point.x, top: point.y, height: height, deviceAspect: aspect)
            } else {
                cell = WritingLayout.initialCell(visible: visible, magnification: m, height: height,
                                                 deviceAspect: aspect)
            }
            writingRightLimit = WritingLayout.rightLimit(visible: visible, magnification: m, cell: cell)
            writingCell = cell
            writtenLetters = []
            mathFractionRoot = nil
            mathActiveRowID = nil
            mathStartsAfterWordSpace = false
            mathCursorOwnsPlacement = false
            mathFunctionRun = []
        }
        toolController.strokeSink = { [weak self] in self?.writingStrokeFinished($0) }
        writingPanel?.hoverPoint = nil
        writingPanel?.pendingStrokes = []
        writingPanel?.isHidden = false
        writingPanel?.cell = writingCell
        followSuspended = false
        followWritingCell()
    }

    private func leaveWriting() {
        stopFollowingScroll()
        if activeMode == .scribe { return leaveScribe() }
        commitPendingLetter(follow: false)
        mathLineStats = nil
        mathResolverStats = nil
        mathPreviousSymbol = nil
        mathFractionRoot = nil
        mathActiveRowID = nil
        mathStartsAfterWordSpace = false
        mathCursorOwnsPlacement = false
        mathFunctionWork?.cancel()
        mathFunctionRun = []
        toolController.strokeSink = nil
        writingPanel?.isHidden = true
        writingPanel?.hoverPoint = nil
    }

    private func tabletStateDidChange() {
        updateFriction()
        if zonePenPending, tabletSource.hoverPoint == nil, !tabletSource.isDrawing {
            zonePenPending = false
            penKeyMonitor.engage()
        }
        guard activeMode.usesLetterCell else { return refreshTabletOverlay() }
        // The trackpad aspect arrives with the first touch; resize the cell between strokes.
        let aspect = tabletSource.mapping.deviceAspect
        if var cell = writingCell, cell.deviceAspect != aspect, !tabletSource.isDrawing {
            cell.setDeviceAspect(aspect)
            setWritingCell(cell)
        }
        // The system cursor is visible while unlocked; a second dot would duplicate it.
        writingPanel?.hoverPoint = cursorLock.isLocked ? tabletSource.hoverPoint : nil
        if !tabletSource.isDrawing, isMathWriteEnabled { updateTabletMapping() }
    }

    private func writingCellHeightDidChange(_ height: CGFloat) {
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        guard activeMode.usesLetterCell, var cell = writingCell, height > 0, cell.height != height,
              !tabletSource.isDrawing else { return }
        cell.height = height
        setWritingCell(cell)
    }

    /// Store the cell and refresh everything that depends on it.
    private func setWritingCell(_ cell: LetterCell) {
        // Reset math line stats if moving to a new line
        if let prev = writingCell, prev.top != cell.top {
            recognizeMathFunctionRun(mathFunctionRun)
            mathLineStats = nil
            mathResolverStats = nil
            mathPreviousSymbol = nil
            mathFractionRoot = nil
            mathActiveRowID = nil
            mathStartsAfterWordSpace = false
            mathCursorOwnsPlacement = false
            mathFunctionRun = []
        }
        writingCell = cell
        writingPanel?.cell = cell
        updateTabletMapping()
        refreshTabletOverlay()
    }

    /// A deliberate move: store the cell and follow it.
    private func moveWritingCell(to cell: LetterCell) {
        guard cell != writingCell else { return }
        setWritingCell(cell)
        followWritingCell()
    }

    // MARK: Friction haptics
    //
    // Clicks spaced by finger travel while the pen is down, measured on the trackpad
    // (fractions of its width), so faster strokes click faster.

    /// Minimum time between friction clicks; the actuator can't render clicks closer than this.
    private static let frictionMinInterval: TimeInterval = 0.02

    private func updateFriction() {
        guard let pattern = settings.frictionHaptic, activeMode.usesTabletInput, tabletSource.isDrawing,
              let p = tabletSource.hoverPoint else {
            frictionLast = nil
            frictionTravel = 0
            return
        }
        defer { frictionLast = p }
        let r = tabletSource.mapping.activeRect
        guard let last = frictionLast, r.width > 0, r.height > 0 else { return }
        // Normalize to trackpad widths: x spans 1, y spans 1/aspect.
        let dx = (p.x - last.x) / r.width
        let dy = (p.y - last.y) / r.height / tabletSource.mapping.deviceAspect
        frictionTravel += hypot(dx, dy)
        let spacing = max(CGFloat(settings.frictionSpacing), 0.001)
        let now = ProcessInfo.processInfo.systemUptime
        guard frictionTravel >= spacing, now - frictionLastClick >= Self.frictionMinInterval else { return }
        frictionTravel = min(frictionTravel - spacing, spacing)
        frictionLastClick = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// `cell` with its position (margin, line, cursor) taken from `position`; size is kept.
    private static func cell(_ cell: LetterCell, at position: LetterCell) -> LetterCell {
        var c = cell
        c.margin = position.margin
        c.top = position.top
        c.cursorX = position.cursorX
        return c
    }

    // MARK: Letters

    func writingStrokeBegan(at point: CGPoint) {
        guard isMathWriteEnabled else { return }
        // A stroke on old math reopens it as the active editor (see `leaveScribe()`),
        // so Delete and the arrows reach the equation through `navigateMathEquation`.
        if activeEquationEditor == nil, pendingLetter.isEmpty,
           let target = equationUnder(point) {
            openMathEquation(target.equation, in: target.block.id, at: target.range)
            return
        }
        mathFunctionWork?.cancel()
        let height = mathResolverStats?.medianHeight ?? mathLineStats?.medianHeight
            ?? max(WritingLayout.letterExtent(pendingLetter).height, 0.4 * (writingCell?.height ?? 32))
        let pendingExtent = pendingMathReopenedID.flatMap { id in
            writtenLetters.first { $0.id == id }?.extent
        } ?? WritingLayout.letterExtent(pendingLetter)
        let target = mathCursorOwnsPlacement ? nil : mathReopenedLetter(at: point, height: height)
        if !pendingLetter.isEmpty,
           point.x > pendingExtent.maxX + 0.15 * height || (target != nil && target != pendingMathReopenedID) {
            commitPendingLetter(follow: false, atStrokeStart: true)
        }
        guard pendingLetter.isEmpty, !mathCursorOwnsPlacement else { return }
        pendingMathReopenedID = mathReopenedLetter(at: point, height: height)
    }

    private func mathReopenedLetter(at point: CGPoint, height: CGFloat) -> UUID? {
        writtenLetters.reversed().first { letter in
            guard !letter.isFractionArchive, !letter.isMathHistoryFrozen,
                  !letter.isFunction, !letter.originalStrokes.isEmpty,
                  letter.rowID == mathActiveRowID else { return false }
            return point.x >= letter.extent.minX - 0.1 * height
                && point.x <= letter.extent.maxX + 0.1 * height
                && point.y >= letter.extent.minY - height
                && point.y <= letter.extent.maxY + 0.3 * height
        }?.id
    }

    func writingStrokeFinished(_ stroke: Stroke) {
        // A stroke away from the rejected ink is a fresh attempt: drop the stale strokes so
        // they can't keep failing (and blocking) everything written after them. Writing
        // continues to the right though, so a symbol drawn within a cell height of the
        // rejected ink is following context: it must not drop (or swap) the stale symbol.
        if isMathWriteEnabled, !unresolvedMathStrokes.isEmpty {
            let height = writingCell?.height ?? 32
            if !WritingLayout.letterExtent(unresolvedMathStrokes).insetBy(dx: -height, dy: -0.5 * height)
                .intersects(stroke.bounds) { clearUnresolvedMathInput() }
        }
        pendingLetter.append(stroke)
        let now = CACurrentMediaTime()
        pendingLetterTimes = (pendingLetterTimes?.start ?? now - (stroke.points.last?.t ?? 0), now)
        setNeedsDisplay(world: stroke.bounds)
        writingPanel?.pendingStrokes = pendingLetter
        scheduleLetterCommit()
    }

    /// Commit the pending letter after the idle delay, unless auto-advance is paused: then it
    /// waits (as does Scribe's line) for the top-left zone.
    private func scheduleLetterCommit() {
        commitWork?.cancel()
        commitWork = nil
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        if scribeZonesOn, !settings.writingAutoAdvance {
            wordWork?.cancel()
            wordWork = nil
            return
        }
        // Strokes added next to rejected ink retry together (e.g. the missing half of a symbol).
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.commitPendingLetter(follow: true, retryUnresolvedMath: !self.unresolvedMathStrokes.isEmpty)
        }
        commitWork = work
        let delay = scribeZonesOn ? settings.scribeLetterCommitDelay : settings.letterCommitDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }

    /// Shift the pending strokes so the letter starts at the cursor, add them in one
    /// undo step, and move the cell past the letter (wrapping at the right limit).
    func commitPendingLetter(follow: Bool, atStrokeStart: Bool = false, retryUnresolvedMath: Bool = false) {
        commitWork?.cancel()
        commitWork = nil
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        guard !pendingLetter.isEmpty, !tabletSource.isDrawing || atStrokeStart,
              let before = writingCell else { return }
        guard !isMathWriteEnabled || unresolvedMathStrokes.isEmpty || retryUnresolvedMath else { return }
        if retryUnresolvedMath { unresolvedMathStrokes = [] }
        let originalStrokes = pendingLetter
        let times = pendingLetterTimes
        let reopenedID = pendingMathReopenedID
        clearPendingLetter()
        #if DEBUG
        let tidyMath = mathTidyEnabledForTesting
            ?? (activeMode.usesLetterCell && settings.offersScribeZones && settings.scribeMath)
        #else
        let tidyMath = activeMode.usesLetterCell && settings.offersScribeZones && settings.scribeMath
        #endif

        if activeMode != .scribe { model.undoManager.beginUndoGrouping() }
        defer { if activeMode != .scribe { model.undoManager.endUndoGrouping() } }
        if activeMode != .scribe { registerWritingUndo() }

        if tidyMath {
            if activeMode == .scribe { beginMathRecognitionGroup() }
            defer { if activeMode == .scribe { endMathRecognitionGroup() } }
            if let reopenedID, writtenLetters.contains(where: { $0.id == reopenedID && !$0.isFunction }) {
                recommitMathLetter(reopenedID, adding: originalStrokes)
                mathCursorOwnsPlacement = false
                syncMathRowState()
                return
            }
            // Quickly written neighbours arrive as one pending group; split them first.
            let groups = segmentMathStrokes(originalStrokes)
            for (index, group) in groups.enumerated() {
                guard commitMathLetter(group, originalExtent: WritingLayout.letterExtent(group),
                                 before: index == 0 ? before : (writingCell ?? before),
                                 beforeLineStats: mathLineStats, beforeResolverStats: mathResolverStats,
                                 beforePreviousSymbol: mathPreviousSymbol, times: times, follow: follow) else {
                    let pending = groups[index...].flatMap { $0 }
                    unresolvedMathStrokes = pending
                    pendingLetter = pending
                    writingPanel?.pendingStrokes = pending
                    return
                }
            }
            mathCursorOwnsPlacement = false
            return
        }

        var cell = before
        let extent = WritingLayout.letterExtent(originalStrokes)
        let dy = cell.verticalOffset(for: extent)
        let dx = cell.commit(letter: extent)
        cell.wrap(at: writingRightLimit)
        let strokes = originalStrokes.map { stroke -> Stroke in
            var value = stroke
            value.translate(by: CGVector(dx: dx, dy: dy))
            return value
        }
        if activeMode == .scribe {
            writtenLetters.append(WrittenLetter(id: UUID(), ids: [], before: before, after: cell,
                                                strokes: strokes, start: times?.start ?? 0,
                                                end: times?.end ?? 0))
            writingPanel?.bufferedStrokes = writtenLetters.flatMap(\.strokes)
            scheduleWordCommit()
            return setWritingCell(cell)
        }
        model.append(strokes: strokes, textBlocks: [], actionName: "Write")
        writtenLetters.append(WrittenLetter(id: UUID(), ids: Set(strokes.map(\.id)),
                                            before: before, after: cell))
        if follow { moveWritingCell(to: cell) } else { setWritingCell(cell) }
    }

    /// Group pending math strokes into symbols (see `MathStrokeSegmenter`).
    private func segmentMathStrokes(_ strokes: [Stroke]) -> [[Stroke]] {
        let height = mathResolverStats?.medianHeight ?? mathLineStats?.medianHeight
            ?? max(WritingLayout.letterExtent(strokes).height, 0.4 * (writingCell?.height ?? 32))
        return MathStrokeSegmenter.segment(strokes, normalHeight: height) { group in
            let context = SymbolResolver.Context(medianHeight: mathResolverStats?.medianHeight,
                                                 baseline: mathResolverStats?.baseline, mode: .math,
                                                 previousSymbol: mathPreviousSymbol)
            return mathGlyphClassifier.labelLikelihoods(strokes: group, bounds: WritingLayout.letterExtent(group),
                                                        context: context).values.max() ?? 0
        }
    }

    @discardableResult
    private func commitMathLetter(_ originalStrokes: [Stroke], originalExtent: CGRect,
                                  before: LetterCell, beforeLineStats: MathInkTidy.LineStats?,
                                  beforeResolverStats: MathInkTidy.LineStats?,
                                  beforePreviousSymbol: String?,
                                  times: (start: TimeInterval, end: TimeInterval)?, follow: Bool) -> Bool {
        let context = SymbolResolver.Context(medianHeight: mathResolverStats?.medianHeight,
                                             baseline: mathResolverStats?.baseline, mode: .math,
                                             previousSymbol: mathPreviousSymbol)
        let likelihoods = mathGlyphClassifier.labelLikelihoods(strokes: originalStrokes,
                                                                bounds: originalExtent, context: context)
        let bestLabel = mathBestLabel(in: likelihoods)
        var row = activeMathRow(createAt: before)
        let letterID = UUID()
        let insertionIndex = mathCursorOwnsPlacement
            ? (row.items.firstIndex { $0.bounds.minX >= before.cursorX - 0.1 * before.height } ?? row.items.count)
            : row.items.count
        row.items.insert(.letter(MathFraction.Letter(id: letterID, label: bestLabel,
                                                     extent: originalExtent,
                                                     startsAfterWordSpace: mathStartsAfterWordSpace)), at: insertionIndex)
        replaceMathRow(row)

        let flattened = decoderTokens(in: mathFractionRoot ?? row,
                                      candidateID: letterID, candidateLikelihoods: likelihoods)
        let index = flattened.letterIndices[letterID]
        let revisionIndices = Array(writtenLetters.reversed().lazy
            .filter { !$0.isFractionSlash && !$0.isFunction && !$0.isWideMathBlob
                && flattened.letterIndices[$0.id] != nil }
            .prefix(2)
            .compactMap { flattened.letterIndices[$0.id] })
        let decoded = index.flatMap {
            mathDecoder?.decode(flattened.symbols, newestIndex: $0, revisionIndices: revisionIndices)
        }
        let substitution: MathLineDecoder.Update? = {
            guard let index, let update = decoded?.substitution, update.index == index else { return nil }
            return update
        }()
        // The language model demotes `/` after a digit or variable; a confident glyph stays a slash.
        let isClearSlash = bestLabel == "/" && likelihoods["/", default: 0] >= Self.mathClearSlashLikelihood
        let decodedBest: String? = isClearSlash ? "/" : {
            guard let index, let marginals = decoded?.marginals, marginals.indices.contains(index) else { return nil }
            return mathBestLabel(in: marginals[index])
        }()
        let normalHeight = mathResolverStats?.medianHeight ?? mathLineStats?.medianHeight
            ?? max(originalExtent.height, 0.4 * before.height)
        let isWideBlob = originalStrokes.count > 1 && originalExtent.width > 1.6 * normalHeight
        let displayed = isWideBlob ? nil : isClearSlash ? "/" : substitution?.label
            ?? mathCommitLabel(index.flatMap { i in decoded?.marginals.indices.contains(i) == true ? decoded?.marginals[i] : nil })
        let slashMarginal: Double? = {
            if displayed == "/", let marginal = substitution?.marginal { return marginal }
            // A raw `/` best guess is kept as a slash even when the decoder ranks something else first.
            guard displayed == "/" || decodedBest == "/" || bestLabel == "/", let index, let marginals = decoded?.marginals,
                  marginals.indices.contains(index) else { return nil }
            return marginals[index]["/", default: 0]
        }()
        let geometryLabel = displayed ?? decodedBest ?? bestLabel ?? ""
        let role = mathCursorOwnsPlacement ? .body
            : MathScript.zoneRole(ys: originalStrokes.flatMap { $0.points.map { CGFloat($0.y) } }, cell: before,
                                  label: geometryLabel, kind: mathKind(for: geometryLabel) ?? "")
        // Ink that stays in an open lane is script ink too, for row and line statistics.
        let recordRole = role == .inherit ? (mathLanes.last ?? .inherit) : role

        // A `/` the decoder ranks first commits (and forms a fraction) at any posterior.
        let accepted = displayed != nil || slashMarginal != nil
        guard accepted else {
            mathFractionRoot = replacingMathRow(row.id, with: MathFraction.Row(
                items: row.items.filter { $0.letterIDs != [letterID] }, cell: row.cell,
                lineStats: row.lineStats, resolverStats: row.resolverStats, id: row.id,
                transform: row.transform), in: mathFractionRoot ?? row)
            unresolvedMathStrokes = originalStrokes
            pendingLetter = originalStrokes
            writingPanel?.pendingStrokes = originalStrokes
            writingPanel?.previewPill?.message = "Unreadable symbol"
            if isWideBlob, MathFunctionNames.canRecognize([likelihoods], isBlob: true) {
                recognizeWideMathFunction(originalStrokes, extent: originalExtent,
                                          likelihoods: likelihoods, before: before,
                                          lineStats: beforeLineStats,
                                          resolverStats: beforeResolverStats,
                                          previousSymbol: beforePreviousSymbol, times: times)
            } else {
                ensureMathEditor()
            }
            return false
        }

        let advance = max(LetterCell.letterGap * before.height, 0.65 * before.height)
        var cell = before
        cell.cursorX += advance
        if activeMathFractionLocation() == nil { cell.wrap(at: writingRightLimit) }
        let record = WrittenLetter(id: letterID, ids: [], before: before, after: cell,
                                   originalStrokes: originalStrokes, likelihoods: likelihoods,
                                   displayed: displayed, structuralLabel: displayed ?? decodedBest ?? bestLabel,
                                   role: recordRole, isWideMathBlob: isWideBlob, extent: originalExtent,
                                   rowID: row.id, startsAfterWordSpace: mathStartsAfterWordSpace,
                                   beforeLineStats: beforeLineStats, beforeResolverStats: beforeResolverStats,
                                   beforePreviousSymbol: beforePreviousSymbol,
                                   start: times?.start ?? 0, end: times?.end ?? 0)
        writtenLetters.append(record)
        updateMathRowFor(record)
        updateMathStatsFor(record)

        for update in decoded?.revisions ?? [] {
            guard flattened.symbols.indices.contains(update.index),
                  let revisedID = flattened.letterIDs[update.index], revisedID != letterID else { continue }
            applyMathRevision(update.label, to: revisedID)
        }
        let insertedFraction = slashMarginal.map {
            insertRecognizedFraction(id: letterID, label: decodedBest ?? "/", posterior: $0)
        } ?? false
        var insertedStructure = false
        if !insertedFraction, let label = displayed {
            if let kind = MathStructure.kind(forLabel: label) {
                // ∑ ∫ √ open with their slots and the caret in the first one.
                insertedStructure = insertMathStructure(kind, id: letterID)
                mathPendingRootID = kind == .squareRoot ? letterID : nil
            } else if mathPendingRootID != nil, role == .superscript, let index = mathLatex(for: label) {
                // A small raised symbol written while the caret is in a root is its index.
                insertedStructure = insertMathStructure(.rootIndex, id: letterID, indexLatex: index)
                mathPendingRootID = nil
            } else if mathPendingRootID != nil {
                // The first radicand symbol has been written; later superscripts belong
                // to that symbol instead of turning the radical into an indexed root.
                mathPendingRootID = nil
            }
        }
        if !insertedFraction, !insertedStructure,
           let latex = (displayed ?? (slashMarginal == nil ? nil : "/")).flatMap(mathLatex(for:)) {
            insertHandwriting(id: letterID, latex: latex, role: role)
            switch role {
            case .superscript, .subscript: mathLanes.append(role)
            case .body: mathLanes = []
            case .inherit: break
            }
        }
        mathPreviousSymbol = displayed
        mathStartsAfterWordSpace = false
        updateMathFunctionRun(after: record)
        mathActiveRowID = mathActiveRowID ?? row.id
        syncMathRowState()
        if follow { followWritingCell() } else { setWritingCell(cell) }
        return true
    }

    private var mathDecoder: MathLineDecoder? {
        if let mathLineDecoderForTesting { return mathLineDecoderForTesting }
        guard let languageModel = MathLanguageModel.bundled else { return nil }
        let config = mathGlyphClassifier.decoderConfiguration
        return MathLineDecoder(languageModel: languageModel, lambda: config.lambda,
                               tauSub: config.tauSub, tauRev: config.tauRev,
                               disabledLabels: config.disabledLabels, tauFill: config.tauFill)
    }

    private func mathBestLabel(in likelihoods: [String: Double]) -> String? {
        guard let label = likelihoods.max(by: { $0.value < $1.value })?.key, label != "<unk>" else { return nil }
        return label
    }

    /// MathLive can't hold ink, so an unsubstituted symbol still commits its best guess (disabled labels included).
    private func mathCommitLabel(_ marginals: [String: Double]?) -> String? {
        guard let marginals, let label = mathBestLabel(in: marginals),
              marginals[label, default: 0] >= Self.mathCommitMinimumMarginal else { return nil }
        return label
    }

    private func mathKind(for label: String) -> String? {
        guard label != "<unk>" else { return nil }
        if MathFunctionNames.names.contains(label) { return "function" }
        return MathVocabulary.bundled?.labels.first(where: { $0.label == label })?.kind
    }

    private func mathLatex(for label: String) -> String? {
        guard label != "<unk>" else { return nil }
        if MathFunctionNames.names.contains(label) { return "\\\(label) " }
        let entry = MathVocabulary.bundled?.labels.first(where: { $0.label == label })
        // A written bar is one side of an absolute value; the vocabulary lists the
        // double bar (`\|`) first, so ask the editor for the single bar it closes.
        if label == "|" { return "|" }
        return entry?.latex.first
    }

    /// Math: the model's top guesses for the last symbol, shown in the pill; picking one swaps it in.
    private func refreshMathCandidates() {
        guard let pill = writingPanel?.previewPill else { return }
        pill.onSelect = { [weak self] label in
            guard let self, let id = self.writtenLetters.last?.id else { return }
            self.applyMathRevision(label, to: id)
        }
        guard isMathWriteEnabled, let last = writtenLetters.last, last.id != dismissedCandidateID,
              pendingLetter.isEmpty, !last.isWideMathBlob, !last.isFunction, !last.isFractionSlash else {
            pill.candidates = []
            return
        }
        let ranked = last.likelihoods.sorted { $0.value > $1.value }
        let floor = (ranked.first?.value ?? 0) * 0.02
        let options = ranked.lazy.filter { $0.value >= floor && self.mathLatex(for: $0.key) != nil }
            .prefix(4).map(\.key)
        // A lone guess has nothing to choose between: stay blank.
        pill.candidates = options.count > 1 ? Array(options) : []
        pill.current = last.displayed
    }

    func clearUnresolvedMathInput() {
        guard !unresolvedMathStrokes.isEmpty else { return }
        unresolvedMathStrokes = []
        wideFunctionRequest = nil
        pendingLetter = []
        pendingLetterTimes = nil
        pendingMathReopenedID = nil
        writingPanel?.pendingStrokes = []
        writingPanel?.previewPill?.message = nil
    }

    func invalidateMathRecognitionHistory() {
        let finishAfterInvalidation = pendingMathEquationFinish
        pendingMathEquationFinish = nil
        mathFunctionWork?.cancel()
        mathFunctionWork = nil
        mathFunctionRecognitionTask?.cancel()
        mathFunctionRecognitionTask = nil
        mathFunctionRun = []
        mathFunctionRequest = []
        wideFunctionRequest = nil
        mathLanes = []
        mathPendingRootID = nil
        for index in writtenLetters.indices { writtenLetters[index].isMathHistoryFrozen = true }
        if let insertNewline = finishAfterInvalidation {
            DispatchQueue.main.async { [weak self] in
                self?.finishMathEquation(insertNewline: insertNewline)
            }
        }
    }

    private func isMathWordLetter(_ record: WrittenLetter) -> Bool {
        !record.isFunction && !record.isFractionArchive && !record.isMathHistoryFrozen
            && record.role != .superscript && record.role != .subscript && MathFunctionNames.letters(in: record.likelihoods) != nil
    }

    /// A small mark just above a bar-class stem that is still in the function run: the dot of `i`.
    private func isMathIDot(_ record: WrittenLetter, after stem: WrittenLetter) -> Bool {
        guard !record.isFunction, !record.isFractionArchive, record.rowID == stem.rowID,
              !record.startsAfterWordSpace,
              let top = record.likelihoods.max(by: { $0.value < $1.value })?.key,
              MathFunctionNames.dotLabels.contains(top),
              MathFunctionNames.isBarClass(stem.likelihoods) else { return false }
        // Compare the written ink: tidied dots are re-placed beside the stem.
        let stemInk = WritingLayout.letterExtent(stem.originalStrokes)
        let dotInk = WritingLayout.letterExtent(record.originalStrokes)
        guard !stemInk.isNull, !dotInk.isNull else { return false }
        let stemHeight = stemInk.height
        return stemHeight > 0 && dotInk.height <= 0.5 * stemHeight
            && dotInk.maxY <= stemInk.minY + 0.3 * stemHeight
            && abs(dotInk.midX - stemInk.midX) <= 0.6 * stemHeight
    }

    /// Group a function run into letter slots; a stem plus its dot is one `i` slot.
    private func mathFunctionSlots(_ records: [WrittenLetter]) -> [(members: [WrittenLetter], guess: [String: Double])]? {
        var slots: [(members: [WrittenLetter], guess: [String: Double])] = []
        for record in records {
            if let last = slots.last, last.members.count == 1, isMathWordLetter(last.members[0]),
               isMathIDot(record, after: last.members[0]) {
                slots[slots.count - 1] = (last.members + [record], ["i": 1])
            } else if isMathWordLetter(record) {
                slots.append(([record], record.likelihoods))
            } else {
                return nil
            }
        }
        return slots
    }

    private func updateMathFunctionRun(after record: WrittenLetter) {
        mathFunctionWork?.cancel()
        let previous = mathFunctionRun.reversed().lazy
            .compactMap { id in self.writtenLetters.first { $0.id == id } }
            .first { isMathWordLetter($0) }
        let isDotOfLast = previous.map { stem in
            mathFunctionRun.last == stem.id && isMathIDot(record, after: stem)
        } ?? false
        if isDotOfLast {
            mathFunctionRun.append(record.id)
            let ids = mathFunctionRun
            let work = DispatchWorkItem { [weak self] in self?.recognizeMathFunctionRun(ids) }
            mathFunctionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        let height = record.beforeLineStats?.medianHeight ?? 0.4 * record.before.height
        // An i-dot placed after its stem extends the run's right edge.
        let runRight = mathFunctionRun.compactMap { id in writtenLetters.first { $0.id == id }?.extent.maxX }.max()
        let continues = previous.map {
            isMathWordLetter($0) && $0.rowID == record.rowID && !record.startsAfterWordSpace
                // Scribe advances a separate cell for every letter; ink gaps do
                // not mark word boundaries there. Explicit spaces still do.
                && (activeMode == .scribe
                    || (record.extent.minX - max($0.extent.maxX, runRight ?? $0.extent.maxX) <= 0.65 * height
                        && record.extent.minX >= $0.extent.minX))
        } ?? false
        if !isMathWordLetter(record) || !continues {
            recognizeMathFunctionRun(mathFunctionRun)
            mathFunctionRun = []
        }
        guard isMathWordLetter(record) else { return }
        mathFunctionRun.append(record.id)
        let ids = mathFunctionRun
        let work = DispatchWorkItem { [weak self] in self?.recognizeMathFunctionRun(ids) }
        mathFunctionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func originalMathInk(_ record: WrittenLetter) -> [Stroke] {
        record.originalStrokes
    }

    private func recognizeMathFunctionRun(_ ids: [UUID]) {
        guard isMathWriteEnabled, !ids.isEmpty, ids != mathFunctionRequest else { return }
        let records = ids.compactMap { id in writtenLetters.first { $0.id == id } }
        guard records.count == ids.count, let slots = mathFunctionSlots(records) else { return }
        let extent = records.reduce(CGRect.null) { $0.union($1.extent) }
        let isBlob = records.count == 1 && records[0].originalStrokes.count > 1
            && extent.width > 1.6 * extent.height
        let guesses = slots.map(\.guess)
        // Already-recognized structure words do not need a second OCR pass over
        // their separate writing cells. A stem and its dot form one i slot.
        let letters = slots.compactMap { slot in
            slot.members.count == 2 ? "i" : slot.members.first?.displayed?.lowercased()
        }
        let name = letters.joined()
        if !isBlob, letters.count == slots.count,
           letters.allSatisfy({ $0.count == 1 }), MathStructure.kind(forLabel: name) != nil {
            replaceMathFunctionRun(records, with: name)
            return
        }
        guard let recognizer = mathFunctionRecognizer else { return }
        guard MathFunctionNames.canRecognize(guesses, isBlob: isBlob) else { return }
        mathFunctionRequest = ids
        let strokes = records.flatMap(originalMathInk)
        mathFunctionRecognitionTask = Task { [weak self] in
            let text = await recognizer.text(for: strokes)
            guard let self, self.mathFunctionRequest == ids else { return }
            if let name = MathFunctionNames.match(text, guesses: guesses, isBlob: isBlob) {
                self.replaceMathFunctionRun(records, with: name, inSuspendedStateIfNeeded: true)
            }
            self.mathFunctionRequest = []
            self.mathFunctionRecognitionTask = nil
            if let insertNewline = self.pendingMathEquationFinish {
                self.pendingMathEquationFinish = nil
                self.finishMathEquation(insertNewline: insertNewline)
            }
        }
    }

    private func recognizeWideMathFunction(_ strokes: [Stroke], extent: CGRect,
                                           likelihoods: [String: Double], before: LetterCell,
                                           lineStats: MathInkTidy.LineStats?,
                                           resolverStats: MathInkTidy.LineStats?,
                                           previousSymbol: String?,
                                           times: (start: TimeInterval, end: TimeInterval)?) {
        guard let recognizer = mathFunctionRecognizer else { ensureMathEditor(); return }
        let request = UUID()
        wideFunctionRequest = request
        ensureMathEditor()
        Task { [weak self] in
            let text = await recognizer.text(for: strokes)
            guard let self, self.wideFunctionRequest == request,
                  self.unresolvedMathStrokes.map(\.id) == strokes.map(\.id),
                  self.isMathWriteEnabled,
                  let name = MathFunctionNames.match(text, guesses: [likelihoods], isBlob: true),
                  let latex = self.mathLatex(for: name) else { return }
            self.wideFunctionRequest = nil
            self.clearUnresolvedMathInput()
            let row = self.activeMathRow(createAt: before)
            let cell = self.writingCell ?? before
            let after = Self.cell(cell, at: cell)
            let id = UUID()
            let record = WrittenLetter(id: id, ids: [], before: before, after: after,
                                       originalStrokes: strokes, likelihoods: [name: 1],
                                       displayed: name, structuralLabel: name, role: .body,
                                       isFunction: true, extent: extent, rowID: row.id,
                                       beforeLineStats: lineStats, beforeResolverStats: resolverStats,
                                       beforePreviousSymbol: previousSymbol,
                                       start: times?.start ?? 0, end: times?.end ?? 0)
            self.writtenLetters.append(record)
            var updated = row
            updated.items.append(.letter(MathFraction.Letter(id: id, label: name, extent: extent)))
            updated.cell = after
            self.replaceMathRow(updated)
            self.beginMathRecognitionGroup()
            if let kind = MathStructure.kind(forLabel: name) {
                self.insertMathStructure(kind, id: id)
            } else {
                self.insertHandwriting(id: id, latex: latex, role: .body)
            }
            self.endMathRecognitionGroup()
            self.mathPreviousSymbol = name
            self.updateMathStatsFor(record)
            self.syncMathRowState()
        }
    }

    private func replaceMathFunctionRun(_ snapshots: [WrittenLetter], with name: String,
                                        inSuspendedStateIfNeeded: Bool = false) {
        if inSuspendedStateIfNeeded, suspendedMathInput != nil, pendingMathEquationFinish != nil {
            let liveCell = writingCell
            let liveLetters = writtenLetters
            let liveSnapshot = mathWrapSnapshot()
            let liveRun = mathFunctionRun
            let liveLineStats = mathLineStats
            let liveResolverStats = mathResolverStats
            let livePreviousSymbol = mathPreviousSymbol
            let liveStartsAfterWordSpace = mathStartsAfterWordSpace
            let liveCursorOwnsPlacement = mathCursorOwnsPlacement
            var saved = suspendedMathInput!
            writingCell = saved.cell
            writtenLetters = saved.letters
            restoreMathWrapSnapshot(saved.snapshot)
            mathFunctionRun = snapshots.map(\.id)
            replaceMathFunctionRun(snapshots, with: name)
            saved.cell = writingCell
            saved.letters = writtenLetters
            saved.snapshot = mathWrapSnapshot()
            suspendedMathInput = saved
            writingCell = liveCell
            writtenLetters = liveLetters
            restoreMathWrapSnapshot(liveSnapshot)
            mathFunctionRun = liveRun
            mathLineStats = liveLineStats
            mathResolverStats = liveResolverStats
            mathPreviousSymbol = livePreviousSymbol
            mathStartsAfterWordSpace = liveStartsAfterWordSpace
            mathCursorOwnsPlacement = liveCursorOwnsPlacement
            return
        }
        guard (isMathWriteEnabled || pendingMathEquationFinish != nil),
              let first = snapshots.first, let last = snapshots.last,
              let rowID = first.rowID else { return }
        let row = mathRow(id: rowID, in: mathFractionRoot)
        let ids = snapshots.map(\.id)
        let records = ids.compactMap { id in writtenLetters.first { $0.id == id } }
        guard records.count == snapshots.count,
                  zip(records, snapshots).allSatisfy({ current, snapshot in
                  current.originalStrokes == snapshot.originalStrokes && current.rowID == rowID
              }), mathFunctionSlots(records) != nil else { return }
        let start = row?.items.firstIndex(where: { $0.letterIDs == [first.id] })
        if let row {
            guard let start, start + ids.count <= row.items.count,
                  row.items[start..<start + ids.count].flatMap(\.letterIDs) == ids else { return }
            let end = start + ids.count
            if end < row.items.count, case .letter(let next) = row.items[end],
               !next.startsAfterWordSpace,
               let nextRecord = writtenLetters.first(where: { $0.id == next.id }),
               isMathWordLetter(nextRecord) { return }
        }
        if mathFunctionRun == ids, !pendingLetter.isEmpty || tabletSource.isDrawing { return }
        beginMathRecognitionGroup()
        if let kind = MathStructure.kind(forLabel: name) {
            // `lim` opens with its condition slot; its argument is written after it.
            insertMathStructure(kind, id: first.id, replaces: ids, coalescesUndo: true)
        } else {
            replaceMathSymbols(ids: ids, latex: "\\\(name) ", coalescesUndo: true)
        }
        endMathRecognitionGroup()
        var token = first
        token.ids = []
        token.originalStrokes = records.flatMap(originalMathInk)
        token.after = last.after
        token.displayed = name
        token.structuralLabel = name
        token.likelihoods = [name: 1]
        token.isFunction = true
        token.isWideMathBlob = false
        token.extent = records.reduce(.null) { $0.union($1.extent) }
        writtenLetters.removeAll { ids.contains($0.id) && $0.id != first.id }
        if let index = writtenLetters.firstIndex(where: { $0.id == first.id }) { writtenLetters[index] = token }
        if var row, let start {
            row.items.replaceSubrange(start..<start + ids.count, with: [.letter(MathFraction.Letter(id: token.id, label: name,
                                                                                                  extent: token.extent,
                                                                                                  startsAfterWordSpace: token.startsAfterWordSpace))])
            replaceMathRow(row)
            rebuildMathStats(for: rowID)
        }
        if mathFunctionRun == ids {
            mathFunctionRun = []
            mathPreviousSymbol = name
        }
        syncMathRowState()
    }

    private func activeMathRow(createAt cell: LetterCell) -> MathFraction.Row {
        if mathFractionRoot == nil {
            let row = MathFraction.Row(cell: cell,
                                       lineStats: MathFraction.LineStats(heights: mathLineStats?.heights ?? [],
                                                                        bottoms: mathLineStats?.bottoms ?? []),
                                       resolverStats: MathFraction.LineStats(heights: mathResolverStats?.heights ?? [],
                                                                            bottoms: mathResolverStats?.bottoms ?? []))
            mathFractionRoot = row
            mathActiveRowID = row.id
        }
        if mathActiveRowID == nil { mathActiveRowID = mathFractionRoot?.id }
        return mathActiveRowID.flatMap { mathRow(id: $0, in: mathFractionRoot) } ?? mathFractionRoot!
    }

    private func setActiveMathRow(_ row: MathFraction.Row) {
        replaceMathRow(row)
        mathActiveRowID = row.id
    }

    private func replaceMathRow(_ row: MathFraction.Row) {
        guard let root = mathFractionRoot else {
            mathFractionRoot = row
            return
        }
        mathFractionRoot = replacingMathRow(row.id, with: row, in: root)
    }

    private func mathRow(id: UUID, in row: MathFraction.Row?) -> MathFraction.Row? {
        guard let row else { return nil }
        if row.id == id { return row }
        for item in row.items {
            guard case .fraction(let fraction) = item else { continue }
            if let found = mathRow(id: id, in: fraction.numerator) { return found }
            if let found = mathRow(id: id, in: fraction.denominator) { return found }
        }
        return nil
    }

    private func replacingMathRow(_ id: UUID, with replacement: MathFraction.Row,
                                  in row: MathFraction.Row) -> MathFraction.Row {
        if row.id == id { return replacement }
        var copy = row
        copy.items = row.items.map { item in
            guard case .fraction(var fraction) = item else { return item }
            fraction.numerator = replacingMathRow(id, with: replacement, in: fraction.numerator)
            fraction.denominator = replacingMathRow(id, with: replacement, in: fraction.denominator)
            return .fraction(fraction)
        }
        return copy
    }

    private struct FlattenedMathLine {
        var symbols: [MathLineDecoder.Symbol] = []
        var letterIDs: [UUID?] = []
        var letterIndices: [UUID: Int] = [:]
    }

    private func decoderTokens(in root: MathFraction.Row, candidateID: UUID?,
                               candidateLikelihoods: [String: Double]) -> FlattenedMathLine {
        let records = Dictionary(uniqueKeysWithValues: writtenLetters.map { ($0.id, $0) })
        func virtual(_ label: String, into result: inout FlattenedMathLine) {
            result.symbols.append(MathLineDecoder.Symbol(labelLikelihoods: [label: 1],
                                                         displayedLabel: label,
                                                         isVirtual: true, isPinned: true))
            result.letterIDs.append(nil)
        }
        func appendRow(_ row: MathFraction.Row, into result: inout FlattenedMathLine) {
            for item in row.items {
                switch item {
                case .letter(let letter):
                    let record = records[letter.id]
                    if record?.isMathHistoryFrozen == true { continue }
                    let likelihoods = letter.id == candidateID ? candidateLikelihoods : (record?.likelihoods ?? [:])
                    let index = result.symbols.count
                    result.symbols.append(MathLineDecoder.Symbol(labelLikelihoods: likelihoods,
                                                                  displayedLabel: record?.displayed,
                                                                  isVirtual: false,
                                                                  isPinned: record?.isFractionSlash == true || record?.isFunction == true))
                    result.letterIDs.append(letter.id)
                    result.letterIndices[letter.id] = index
                case .fraction(let fraction):
                    var numerator = FlattenedMathLine()
                    appendRow(fraction.numerator, into: &numerator)
                    var denominator = FlattenedMathLine()
                    appendRow(fraction.denominator, into: &denominator)
                    guard !numerator.symbols.isEmpty || !denominator.symbols.isEmpty else { continue }
                    if numerator.symbols.count > 1 { virtual("(", into: &result) }
                    result.symbols.append(contentsOf: numerator.symbols)
                    result.letterIDs.append(contentsOf: numerator.letterIDs)
                    for (id, index) in numerator.letterIndices {
                        result.letterIndices[id] = result.symbols.count - numerator.symbols.count + index
                    }
                    if numerator.symbols.count > 1 { virtual(")", into: &result) }
                    virtual("/", into: &result)
                    if denominator.symbols.count > 1 { virtual("(", into: &result) }
                    result.symbols.append(contentsOf: denominator.symbols)
                    result.letterIDs.append(contentsOf: denominator.letterIDs)
                    for (id, index) in denominator.letterIndices {
                        result.letterIndices[id] = result.symbols.count - denominator.symbols.count + index
                    }
                    if denominator.symbols.count > 1 { virtual(")", into: &result) }
                }
            }
        }
        var result = FlattenedMathLine()
        appendRow(root, into: &result)
        return result
    }

    private func updateMathRowFor(_ letter: WrittenLetter, advanceCell: Bool = true) {
        guard let rowID = letter.rowID, let root = mathFractionRoot,
              var row = mathRow(id: rowID, in: root) else { return }
        row.items = row.items.map { item in
            guard case .letter(var value) = item, value.id == letter.id else { return item }
            value.label = letter.structuralLabel ?? letter.displayed
            value.extent = letter.extent
            value.isBody = letter.role != .superscript && letter.role != .subscript
            return .letter(value)
        }
        if advanceCell { row.cell = letter.after }
        replaceMathRow(row)
    }

    private func updateMathStatsFor(_ letter: WrittenLetter) {
        guard !letter.isMathHistoryFrozen, letter.role != .superscript && letter.role != .subscript,
              let kind = letter.displayed.flatMap(mathKind(for:)),
              ["digit", "lower", "upper", "function"].contains(kind),
              let rowID = letter.rowID, let root = mathFractionRoot,
              var row = mathRow(id: rowID, in: root) else { return }
        let minimumHeight = letter.before.height * 0.25
        if letter.extent.height >= minimumHeight {
            row.lineStats.record(letter.extent)
        }
        if ["digit", "upper"].contains(kind) {
            row.resolverStats.record(letter.extent)
        }
        replaceMathRow(row)
    }

    private func rebuildMathStats(for rowID: UUID) {
        guard let root = mathFractionRoot, var row = mathRow(id: rowID, in: root) else { return }
        let records = row.items.compactMap { item -> WrittenLetter? in
            guard case .letter(let letter) = item else { return nil }
            return writtenLetters.first(where: { $0.id == letter.id })
        }.filter { !$0.isMathHistoryFrozen }
        var line = records.first?.beforeLineStats
            ?? MathInkTidy.LineStats(heights: row.lineStats.heights, bottoms: row.lineStats.bottoms)
        var resolver = records.first?.beforeResolverStats
            ?? MathInkTidy.LineStats(heights: row.resolverStats.heights, bottoms: row.resolverStats.bottoms)
        for record in records {
            guard record.role != .superscript && record.role != .subscript, let kind = record.displayed.flatMap(mathKind(for:)) else { continue }
            if ["digit", "lower", "upper", "function"].contains(kind),
               record.extent.height >= record.before.height * 0.25 {
                line.record(record.extent)
            }
            if ["digit", "upper"].contains(kind) {
                resolver.record(record.extent)
            }
        }
        row.lineStats = MathFraction.LineStats(heights: line.heights, bottoms: line.bottoms)
        row.resolverStats = MathFraction.LineStats(heights: resolver.heights, bottoms: resolver.bottoms)
        replaceMathRow(row)
    }

    private func syncMathRowState() {
        guard let rowID = mathActiveRowID, let row = mathRow(id: rowID, in: mathFractionRoot) else { return }
        writingCell = row.cell
        writingPanel?.cell = row.cell
        mathLineStats = MathInkTidy.LineStats(heights: row.lineStats.heights, bottoms: row.lineStats.bottoms)
        mathResolverStats = MathInkTidy.LineStats(heights: row.resolverStats.heights, bottoms: row.resolverStats.bottoms)
        updateTabletMapping()
        refreshTabletOverlay()
    }

    private func applyMathRevision(_ label: String, to id: UUID) {
        guard let index = writtenLetters.firstIndex(where: { $0.id == id }) else { return }
        var record = writtenLetters[index]
        let structure = MathStructure.kind(forLabel: label)
        guard !record.isWideMathBlob, !record.isFunction,
              structure != nil || mathLatex(for: label) != nil else { return }
        record.displayed = label
        record.structuralLabel = label
        if let structure {
            // Correcting a glyph into ∑ ∫ or √ opens the structure, not a bare symbol.
            insertMathStructure(structure, id: id, replaces: [id])
            mathPendingRootID = structure == .squareRoot ? id : nil
        } else if let latex = mathLatex(for: label) {
            replaceHandwriting(id: id, latex: latex)
        }
        writtenLetters[index] = record
        updateMathRowFor(record, advanceCell: false)
        if let rowID = record.rowID {
            rebuildMathStats(for: rowID)
        }
    }

    /// The old ink and the new mark are replaced atomically by the enclosing commit's undo group.
    private func recommitMathLetter(_ id: UUID, adding strokes: [Stroke]) {
        guard let index = writtenLetters.firstIndex(where: { $0.id == id }) else { return }
        var record = writtenLetters[index]
        record.originalStrokes += strokes
        let extent = WritingLayout.letterExtent(record.originalStrokes)
        let normalHeight = record.beforeResolverStats?.medianHeight
            ?? record.beforeLineStats?.medianHeight ?? max(extent.height, 0.4 * record.before.height)
        record.isWideMathBlob = record.originalStrokes.count > 1 && extent.width > 1.6 * normalHeight
        if record.isWideMathBlob {
            let groups = segmentMathStrokes(record.originalStrokes)
            if groups.count > 1 {
                splitReopenedMathLetter(record, groups: groups)
                return
            }
        }
        let context = SymbolResolver.Context(medianHeight: record.beforeResolverStats?.medianHeight,
                                             baseline: record.beforeResolverStats?.baseline,
                                             mode: .math, previousSymbol: record.beforePreviousSymbol)
        record.likelihoods = mathGlyphClassifier.labelLikelihoods(strokes: record.originalStrokes,
                                                                 bounds: extent, context: context)
        if let root = mathFractionRoot {
            let flattened = decoderTokens(in: root, candidateID: id, candidateLikelihoods: record.likelihoods)
            if let token = flattened.letterIndices[id] {
                let result = mathDecoder?.decode(flattened.symbols, newestIndex: token, revisionIndices: [])
                record.displayed = record.isWideMathBlob ? nil
                    : result?.substitution?.label ?? mathCommitLabel(result?.marginals[token])
                record.structuralLabel = record.displayed
                    ?? result.flatMap { mathBestLabel(in: $0.marginals[token]) }
                    ?? mathBestLabel(in: record.likelihoods)
            }
        }
        #if DEBUG
        MathRecognitionLog.record(strokeCount: record.originalStrokes.count, extent: extent,
                                  likelihoods: record.likelihoods, decodedBest: record.structuralLabel,
                                  displayed: record.displayed, role: String(describing: record.role), revisions: [])
        #endif
        if let label = record.displayed, let latex = mathLatex(for: label) {
            replaceHandwriting(id: id, latex: latex)
        }
        if let rowID = record.rowID {
            let row = mathRow(id: rowID, in: mathFractionRoot)
            let position = row?.items.firstIndex { $0.letterIDs == [id] }
            let advancesCursor = row?.cell == record.after && position == (row?.items.count ?? 0) - 1
            let movesCursorWithSuffix = (row?.cell.cursorX ?? 0) > record.after.cursorX + 0.01
            if advancesCursor { record.after.cursorX += 0.65 * record.after.height }
            writtenLetters[index] = record
            updateMathRowFor(record, advanceCell: advancesCursor)
            _ = position
            _ = movesCursorWithSuffix
            rebuildMathStats(for: rowID)
        } else {
            writtenLetters[index] = record
        }
        if mathFunctionRun.contains(id) {
            mathFunctionRequest = []
            let ids = mathFunctionRun
            let work = DispatchWorkItem { [weak self] in self?.recognizeMathFunctionRun(ids) }
            mathFunctionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    private func splitReopenedMathLetter(_ record: WrittenLetter, groups: [[Stroke]]) {
        guard let rowID = record.rowID, let root = mathFractionRoot,
              var row = mathRow(id: rowID, in: root) else { return }
        let savedRowID = mathActiveRowID
        let savedCell = row.cell
        let wasAtCursor = savedRowID == rowID && savedCell == record.after
        replaceMathSymbols(ids: [record.id], latex: "")
        writtenLetters.removeAll { $0.id == record.id }
        row.items.removeAll { $0.letterIDs == [record.id] }
        row.cell = record.before
        setActiveMathRow(row)
        rebuildMathStats(for: rowID)
        syncMathRowState()
        mathCursorOwnsPlacement = true
        mathPreviousSymbol = record.beforePreviousSymbol
        for group in groups {
            guard let cell = writingCell else { break }
            commitMathLetter(group, originalExtent: WritingLayout.letterExtent(group), before: cell,
                             beforeLineStats: mathLineStats, beforeResolverStats: mathResolverStats,
                             beforePreviousSymbol: mathPreviousSymbol, times: nil, follow: false)
        }
        if !wasAtCursor, var updated = mathRow(id: rowID, in: mathFractionRoot) {
            updated.cell = savedCell
            replaceMathRow(updated)
        }
        mathActiveRowID = savedRowID
        syncMathRowState()
    }

    #if DEBUG
    func reviseMathLetterForTesting(_ label: String, id: UUID) {
        model.undoManager.beginUndoGrouping()
        registerWritingUndo()
        applyMathRevision(label, to: id)
        model.undoManager.endUndoGrouping()
    }

    func useScribeMathForTesting() {
        settings.scribeMath = true
        activeMode = .scribe
        scribeMathWasActive = true
    }
    #endif

    static let mathCommitMinimumMarginal = 0.5
    static let mathClearSlashLikelihood = 0.6

    private func insertRecognizedFraction(id: UUID, label: String, posterior: Double) -> Bool {
        guard let index = writtenLetters.firstIndex(where: { $0.id == id }) else { return false }
        var slashRecord = writtenLetters[index]
        guard let rowID = slashRecord.rowID,
              let root = mathFractionRoot, var row = mathRow(id: rowID, in: root),
              let slashIndex = row.items.firstIndex(where: {
                  if case .letter(let letter) = $0 { return letter.id == id }
                  return false
              }) else { return false }
        let depth = mathRowDepth(id: rowID, in: root) ?? 0
        guard MathFraction.shouldTrigger(.recognized(label: label, posterior: posterior),
                                         nestingDepth: depth) else { return false }
        guard case .letter(let slash) = row.items[slashIndex] else { return false }
        slashRecord.isFractionSlash = true
        writtenLetters[index] = slashRecord
        let operand = MathFraction.operand(in: row, before: slashIndex)
        var committedCell = slashRecord.after
        row.cell = committedCell
        guard applyFractionInsertion(parent: row, operand: operand, slash: slash,
                                     slashIndex: slashIndex, slashRecord: slashRecord,
                                     trigger: operand.range.isEmpty ? "leading slash" : "handwritten slash") else { return false }
        committedCell = writingCell ?? committedCell
        _ = committedCell
        return true
    }

    private func applyFractionInsertion(parent: MathFraction.Row, operand: MathFraction.Operand,
                                        slash: MathFraction.Letter?, slashIndex: Int?,
                                        slashRecord: WrittenLetter?, trigger: String) -> Bool {
        let removed = Set(operand.removedParenthesisIDs)
        let numeratorItems = parent.items[operand.range].filter { item in
            guard case .letter(let letter) = item else { return true }
            return !removed.contains(letter.id)
        }
        let operandIDs = numeratorItems.flatMap(\.letterIDs)
        guard insertMathFraction(operandIDs: operandIDs,
                                 removedParenthesisIDs: operand.removedParenthesisIDs) else { return false }
        for index in writtenLetters.indices where removed.contains(writtenLetters[index].id) {
            writtenLetters[index].isFractionArchive = true
        }
        if let slashRecord, let index = writtenLetters.firstIndex(where: { $0.id == slashRecord.id }) {
            writtenLetters[index].isFractionArchive = true
            writtenLetters[index].isFractionSlash = true
        }
        let stats = MathFraction.LineStats(heights: parent.lineStats.heights,
                                           bottoms: parent.lineStats.bottoms)
        let resolver = MathFraction.LineStats(heights: parent.resolverStats.heights,
                                              bottoms: parent.resolverStats.bottoms)
        let numerator = MathFraction.Row(items: numeratorItems, cell: parent.cell,
                                         lineStats: stats, resolverStats: resolver)
        let denominator = MathFraction.Row(cell: parent.cell)
        let bar = MathFraction.Bar(id: UUID(), start: .zero, end: .zero)
        let fraction = MathFraction.Fraction(numerator: numerator, denominator: denominator, bar: bar,
                                             startsAfterWordSpace: numeratorItems.first?.startsAfterWordSpace ?? false)
        var parentRow = parent
        var remaining = Array(parent.items[..<operand.range.lowerBound])
        remaining.append(.fraction(fraction))
        let suffixStart = slashIndex.map { min($0 + 1, parent.items.count) } ?? operand.range.upperBound
        if suffixStart < parent.items.count { remaining.append(contentsOf: parent.items[suffixStart...]) }
        parentRow.items = remaining
        if let slashRecord { parentRow.cell = slashRecord.after }
        replaceMathRow(parentRow)
        for index in writtenLetters.indices where numeratorItems.flatMap(\.letterIDs).contains(writtenLetters[index].id) {
            writtenLetters[index].rowID = numerator.id
        }
        mathActiveRowID = operand.isEmpty ? numerator.id : denominator.id
        mathStartsAfterWordSpace = false
        syncMathRowState()
        #if DEBUG
        MathRecognitionLog.record(event: "fraction_create", fields: [
            "barID": bar.id.uuidString,
            "sequence": writtenLetters.suffix(8).map { $0.id.uuidString },
            "operandLetterIDs": numeratorItems.flatMap(\.letterIDs).map(\.uuidString),
            "trigger": trigger,
            "slashLetterID": slashRecord?.id.uuidString ?? NSNull(),
            "activeSlot": operand.isEmpty ? "numerator" : "denominator",
        ])
        #endif
        return true
    }

    private func mathRowDepth(id: UUID, in row: MathFraction.Row, depth: Int = 0) -> Int? {
        if row.id == id { return depth }
        for item in row.items {
            guard case .fraction(let fraction) = item else { continue }
            if let value = mathRowDepth(id: id, in: fraction.numerator, depth: depth + 1) { return value }
            if let value = mathRowDepth(id: id, in: fraction.denominator, depth: depth + 1) { return value }
        }
        return nil
    }

    private struct ActiveMathFraction {
        let parent: MathFraction.Row
        let fraction: MathFraction.Fraction
        let slot: MathFraction.Slot
    }

    private var isMathWriteEnabled: Bool {
        #if DEBUG
        if let mathTidyEnabledForTesting { return mathTidyEnabledForTesting }
        #endif
        return activeMode == .scribe && settings.offersScribeZones && settings.scribeMath
    }

    private func activeMathFractionLocation() -> ActiveMathFraction? {
        guard let target = mathActiveRowID, let root = mathFractionRoot else { return nil }
        return activeMathFractionLocation(target: target, in: root)
    }

    private func activeMathFractionLocation(target: UUID,
                                            in row: MathFraction.Row) -> ActiveMathFraction? {
        for item in row.items {
            guard case .fraction(let fraction) = item else { continue }
            if fraction.numerator.id == target {
                return ActiveMathFraction(parent: row, fraction: fraction, slot: .numerator)
            }
            if fraction.denominator.id == target {
                return ActiveMathFraction(parent: row, fraction: fraction, slot: .denominator)
            }
            if let nested = activeMathFractionLocation(target: target, in: fraction.numerator) { return nested }
            if let nested = activeMathFractionLocation(target: target, in: fraction.denominator) { return nested }
        }
        return nil
    }

    private func createEmptyMathFraction() -> Bool {
        guard isMathWriteEnabled, writingCell != nil else { return false }
        guard unresolvedMathStrokes.isEmpty else { return false }
        // The last letter may still be pending ink; the operand must include it.
        commitPendingLetter(follow: false)
        guard pendingLetter.isEmpty, let cell = writingCell else { return false }
        var row = activeMathRow(createAt: cell)
        let depth = mathRowDepth(id: row.id, in: mathFractionRoot ?? row) ?? 0
        guard MathFraction.shouldTrigger(.slashKey, nestingDepth: depth) else { return false }
        let operand = MathFraction.operand(in: row)
        // An empty numerator is only wanted after an operator or special symbol, or on an empty line.
        guard !operand.range.isEmpty || startsEmptyFraction(row) else { return false }
        row.cell = cell
        return applyFractionInsertion(parent: row, operand: operand, slash: nil,
                                      slashIndex: nil, slashRecord: nil,
                                      trigger: operand.range.isEmpty ? "/ key (leading)" : "/ key")
    }

    /// Labels after which a `/` starts a fraction with an empty numerator.
    private func startsEmptyFraction(_ row: MathFraction.Row) -> Bool {
        guard let last = row.items.last else { return true }
        guard case .letter(let letter) = last, let label = letter.label else { return false }
        return ["+", "−", "=", "≠", "<", ">", "≤", "≥", "±", "÷", "·", "(", ","].contains(label)
    }

    private func discardPendingLetter() {
        commitWork?.cancel()
        commitWork = nil
        clearPendingLetter()
    }

    private func clearPendingLetter() {
        for stroke in pendingLetter { setNeedsDisplay(world: stroke.bounds) }
        pendingLetter = []
        pendingLetterTimes = nil
        pendingMathReopenedID = nil
        writingPanel?.pendingStrokes = []
    }

    /// Undo restores the cursor and letter list alongside the model change it's grouped with.
    private func registerWritingUndo() {
        guard activeMode != .scribe else { return }
        let cell = writingCell, letters = writtenLetters
        let lineStats = mathLineStats, resolverStats = mathResolverStats, previousSymbol = mathPreviousSymbol
        let fractionRoot = mathFractionRoot, activeRowID = mathActiveRowID
        let startsAfterWordSpace = mathStartsAfterWordSpace
        let cursorOwnsPlacement = mathCursorOwnsPlacement
        model.undoManager.registerUndo(withTarget: self) {
            $0.restoreWriting(cell: cell, letters: letters, lineStats: lineStats,
                              resolverStats: resolverStats, previousSymbol: previousSymbol,
                              fractionRoot: fractionRoot, activeRowID: activeRowID,
                              startsAfterWordSpace: startsAfterWordSpace,
                              cursorOwnsPlacement: cursorOwnsPlacement)
        }
    }

    private func restoreWriting(cell: LetterCell?, letters: [WrittenLetter],
                                lineStats: MathInkTidy.LineStats?, resolverStats: MathInkTidy.LineStats?,
                                previousSymbol: String?, fractionRoot: MathFraction.Row?,
                                activeRowID: UUID?, startsAfterWordSpace: Bool,
                                cursorOwnsPlacement: Bool) {
        guard activeMode != .scribe else { return }
        registerWritingUndo()
        writtenLetters = letters
        if let cell {
            let current = writingCell.map { Self.cell($0, at: cell) } ?? cell
            if activeMode.usesLetterCell {
                discardPendingLetter()
                setWritingCell(current)
                followWritingCell()
            } else {
                writingCell = current
            }
        }
        mathLineStats = lineStats
        mathResolverStats = resolverStats
        mathPreviousSymbol = previousSymbol
        mathFractionRoot = fractionRoot
        mathActiveRowID = activeRowID
        mathStartsAfterWordSpace = startsAfterWordSpace
        mathCursorOwnsPlacement = cursorOwnsPlacement
    }

    /// Delete: drop the pending letter; else step back over a trailing space or line
    /// break; else remove the last letter (undoable) and put the cursor where it began.
    func deleteLastLetter() {
        if activeMode == .scribe { return scribeDelete() }
        guard let cell = writingCell else { return }
        if !pendingLetter.isEmpty { return discardPendingLetter() }
        guard let last = writtenLetters.last else { return }
        if cell.top != last.after.top || cell.cursorX != last.after.cursorX {
            let wrapped = cell.top != last.after.top
            moveWritingCell(to: Self.cell(cell, at: last.after))
            // Stepping back over a wrapping word space returns to the pre-wrap line.
            if wrapped, let snapshot = last.spaceWrapSnapshot {
                restoreMathWrapSnapshot(snapshot)
                writtenLetters[writtenLetters.count - 1].spaceWrapSnapshot = nil
                syncMathRowState()
            }
            return
        }
        registerWritingUndo()
        writtenLetters.removeLast()
        model.remove(ids: last.ids, actionName: "Delete Letter")
        // Drop the letter from the math row too, or a later `/` would pull it into the numerator.
        if let root = mathFractionRoot { mathFractionRoot = pruningMathRow(root, removing: [last.id]).row }
        moveWritingCell(to: Self.cell(cell, at: last.before))
        if let snapshot = last.wrapSnapshot { restoreMathWrapSnapshot(snapshot) }
        mathLineStats = last.beforeLineStats
        mathResolverStats = last.beforeResolverStats
        mathPreviousSymbol = last.beforePreviousSymbol
        mathStartsAfterWordSpace = last.startsAfterWordSpace
    }

    /// Drop letters whose strokes are all gone. If the trailing letters went, the
    /// cursor returns to where the earliest of them began.
    private func reconcileWrittenLetters() {
        guard activeMode != .scribe, !writtenLetters.isEmpty,
              let cell = writingCell else { return }
        let live = model.allIDs
        let gone = writtenLetters.map { !$0.isFractionArchive && $0.ids.isDisjoint(with: live) }
        guard gone.contains(true) else { return }
        var trailing = writtenLetters.count
        while trailing > 0, gone[trailing - 1] { trailing -= 1 }
        let restart = trailing < writtenLetters.count ? writtenLetters[trailing].before : nil
        let goneIDs = Set(writtenLetters.enumerated().compactMap { index, letter in
            gone[index] ? letter.id : nil
        })
        writtenLetters = zip(writtenLetters, gone).filter { !$0.1 }.map(\.0)
        for index in writtenLetters.indices {
            writtenLetters[index].beforeLineStats = nil
            writtenLetters[index].beforeResolverStats = nil
            writtenLetters[index].beforePreviousSymbol = nil
            writtenLetters[index].isMathHistoryFrozen = true
        }
        if let root = mathFractionRoot {
            let pruned = pruningMathRow(root, removing: goneIDs)
            mathFractionRoot = pruned.row
            if let activeID = mathActiveRowID, mathRow(id: activeID, in: pruned.row) == nil {
                mathActiveRowID = pruned.row.id
            }
        }
        mathLineStats = nil
        mathResolverStats = nil
        mathPreviousSymbol = nil
        mathStartsAfterWordSpace = false
        guard let restart else {
            if let rowID = mathActiveRowID, let row = mathRow(id: rowID, in: mathFractionRoot) {
                writingCell = row.cell
                writingPanel?.cell = row.cell
            }
            return
        }
        if activeMode.usesLetterCell {
            moveWritingCell(to: Self.cell(cell, at: restart))
        } else {
            writingCell = Self.cell(cell, at: restart)
        }
    }

    private func pruningMathRow(_ source: MathFraction.Row,
                                removing ids: Set<UUID>) -> (row: MathFraction.Row, removed: Set<UUID>) {
        var row = source
        var removed = Set<UUID>()
        row.items = source.items.compactMap { item in
            switch item {
            case .letter(let letter):
                guard ids.contains(letter.id) else { return item }
                removed.insert(letter.id)
                return nil
            case .fraction(var fraction):
                let numerator = pruningMathRow(fraction.numerator, removing: ids)
                let denominator = pruningMathRow(fraction.denominator, removing: ids)
                fraction.numerator = numerator.row
                fraction.denominator = denominator.row
                removed.formUnion(numerator.removed)
                removed.formUnion(denominator.removed)
                return .fraction(fraction)
            }
        }
        row.lineStats = MathFraction.LineStats()
        row.resolverStats = MathFraction.LineStats()
        let trailingItemWasPruned = source.items.last.map {
            !Set($0.letterIDs).isDisjoint(with: removed)
        } ?? false
        if trailingItemWasPruned {
            if let last = row.items.last {
                row.cell.cursorX = last.bounds.maxX + LetterCell.letterGap * row.cell.height
            } else {
                row.cell.cursorX = row.cell.margin
            }
        }
        return (row, removed)
    }

    // MARK: Write mode keys

    /// Tab / → word space, Return new line, Delete / ← remove the last letter.
    /// Swallowed (no move) mid-stroke.
    func handleWritingKey(_ event: NSEvent) -> Bool {
        guard activeMode.usesLetterCell, session == nil, writingCell != nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let code = event.keyCode
        if activeMode.usesLetterCell, [Self.deleteKeyCode, Self.leftArrowKeyCode, Self.rightArrowKeyCode, Self.upArrowKeyCode,
                                       Self.downArrowKeyCode, Self.returnKeyCode, Self.enterKeyCode, Self.tabKeyCode,
                                       PenKeyMonitor.spaceKeyCode].contains(code) {
            dismissedCandidateID = writtenLetters.last?.id
            refreshMathCandidates()
        }
        if activeMode == .scribe, settings.scribeMath {
            guard !tabletSource.isDrawing else { return true }
            if code == Self.slashKeyCode, event.characters == "/" {
                return createEmptyMathFraction()
            }
            if [Self.returnKeyCode, Self.enterKeyCode].contains(code) {
                scribeNewLine()
                return true
            }
            if (!pendingLetter.isEmpty || activeEquationEditor == nil),
               [Self.deleteKeyCode, Self.leftArrowKeyCode].contains(code) {
                // After ⌘A the selection owns Delete: fall through to selection handling.
                if !selection.selection.isEmpty || documentTextIsFullySelected { return false }
                scribeDelete()
                return true
            }
            switch code {
            case Self.leftArrowKeyCode: navigateMathEquation("left")
            case Self.rightArrowKeyCode: navigateMathEquation("right")
            case Self.upArrowKeyCode: navigateMathEquation("up")
            case Self.downArrowKeyCode: navigateMathEquation("down")
            case Self.deleteKeyCode: navigateMathEquation("delete")
            case Self.tabKeyCode: navigateMathEquation("spaceAdvance")
            case PenKeyMonitor.spaceKeyCode: navigateMathEquation("spaceAdvance")
            default: return false
            }
            return true
        }
        var keys = [Self.rightArrowKeyCode, Self.tabKeyCode, Self.leftArrowKeyCode, Self.deleteKeyCode,
                    Self.returnKeyCode, Self.enterKeyCode]
        if isMathWriteEnabled { keys.append(Self.slashKeyCode) }
        // Space ends a word in Scribe unless it is the pen key (the monitor takes it first).
        if activeMode == .scribe { keys.append(PenKeyMonitor.spaceKeyCode) }
        guard keys.contains(code) else { return false }
        if code == Self.slashKeyCode, event.characters != "/" { return false }
        // With a selection (e.g. after ⌘A), Delete and arrows act on the selection.
        if !selection.selection.isEmpty, code != Self.tabKeyCode, code != Self.returnKeyCode, code != Self.enterKeyCode {
            return false
        }
        guard !tabletSource.isDrawing else { return true }
        if code == Self.slashKeyCode {
            return createEmptyMathFraction()
        }
        if activeMode == .scribe {
            switch code {
            case Self.leftArrowKeyCode, Self.deleteKeyCode: scribeDelete()
            case Self.returnKeyCode, Self.enterKeyCode: scribeNewLine()
            default: scribeWordBoundary()
            }
            return true
        }
        switch code {
        case Self.leftArrowKeyCode, Self.deleteKeyCode:
            deleteLastLetter()
        case Self.rightArrowKeyCode, Self.tabKeyCode:
            writeWordSpace()
        default:
            commitPendingLetter(follow: false)
            guard var cell = writingCell else { return true }
            if isMathWriteEnabled, let root = mathFractionRoot {
                let nextTop = MathFraction.nextLineTop(currentTop: root.cell.top,
                                                       lowestInkMaxY: root.bounds.isNull ? nil : root.bounds.maxY,
                                                       cellHeight: root.cell.height)
                cell.margin = root.cell.margin
                cell.top = nextTop
                cell.cursorX = cell.margin
            } else {
                cell.newLine()
            }
            moveWritingCell(to: cell)
            writingRightLimit = WritingLayout.rightLimit(visible: followTarget ?? worldRect(for: visibleRect),
                                                         magnification: magnification, cell: cell)
            refreshTabletOverlay()
        }
        return true
    }

    /// Write mode's word space: commit the letter and move the cell on.
    private func writeWordSpace() {
        commitPendingLetter(follow: false)
        guard var cell = writingCell else { return }
        let snapshot = mathWrapSnapshot()
        let isFractionSlot = isMathWriteEnabled && activeMathFractionLocation() != nil
        cell.space()
        let topBeforeWrap = cell.top
        if !isFractionSlot { cell.wrap(at: writingRightLimit) }
        mathPreviousSymbol = nil
        if isMathWriteEnabled, cell.top != topBeforeWrap {
            // A wrapping space starts a fresh decoder line, below any tall fraction above.
            if let lowestInk = mathFractionRoot?.bounds.maxY, !(mathFractionRoot?.bounds.isNull ?? true) {
                cell.top = max(cell.top, lowestInk + 0.25 * cell.height)
            }
            cell.cursorX = cell.margin
            if !writtenLetters.isEmpty { writtenLetters[writtenLetters.count - 1].spaceWrapSnapshot = snapshot }
            moveWritingCell(to: cell)
        } else if isMathWriteEnabled, mathFractionRoot != nil {
            var row = activeMathRow(createAt: cell)
            row.cell = cell
            setActiveMathRow(row)
            mathStartsAfterWordSpace = true
            syncMathRowState()
        } else {
            moveWritingCell(to: cell)
        }
    }

    // MARK: Scribe mode
    //
    // Same cell, panel and keys as Write mode, but a line's letters stay in
    // `writtenLetters` (never the model) until Return or three idle seconds;
    // recognition always sees the complete line so far.

    func documentBodyTextDidEdit(_ range: NSRange, _ delta: Int) {
        guard layout == .document, model.effectiveLayout == .document, !scribeApplyingDocumentEdit,
              scribeTarget == documentBodyID else { return }
        if let index = scribeDocumentIndex {
            if NSMaxRange(range) <= index {
                scribeDocumentIndex = max(0, index + delta)
            } else if range.location < index {
                scribeDocumentIndex = range.location + max(0, delta)
            }
        }
        scribePolishToken += 1
        if activeMode == .scribe {
            scribeQueue = ScribeQueue()
            scribeLiveGeneration += 1
            scribeLiveRunning = false
            scribeLiveResult = nil
            scribeLiveDirty = false
            setScribeProvisional(nil)
        }
    }

    private func enterScribe() {
        scribeEntryOrigin = enclosingScrollView?.contentView.bounds.origin
        scribeLocks = []
        let isDocumentBody = layout == .document && model.effectiveLayout == .document
        let documentIndex: Int? = isDocumentBody ? {
            guard let view = documentBodyView else { return nil }
            let textView = view.textView
            if window?.firstResponder === textView {
                return textView.selectedRange().location
            }
            if activeEquationID != nil { return scribeDocumentIndex ?? view.textStorage.length }
            return view.textStorage.length
        }() : nil
        // Target: the block being edited or the single selected one.
        if scribeQueue.isEmpty {
            if isDocumentBody {
                finishEditing()
                scribeTarget = documentBodyID
                scribeDocumentIndex = documentIndex
                if let documentIndex, let textView = documentBodyView?.textView {
                    textView.setSelectedRange(NSRange(location: min(documentIndex, textView.textStorage?.length ?? 0), length: 0))
                }
            } else {
                let chosen = activeEquationBlockID ?? session?.block.id ?? (selection.selection.count == 1 ? selection.selection.first : nil)
                finishEditing()
                scribeTarget = chosen.flatMap { model.textBlock(id: $0) }?.id
            }
        } else {
            finishEditing()
        }
        clearSelection()
        // Only the Pen tool writes.
        if settings.tool != .pen { settings.tool = .pen }
        stashedWriting = (writingCell, writtenLetters, writingRightLimit, settings.unifyScribeWidth ? nil : settings.width)
        if !settings.unifyScribeWidth {
            settings.width = Self.clampWidth(settings.scribeDefaultWidth)
        }
        if Self.sentencePolishEnabled, settings.scribeSentencePolish { scribePolisher?.prewarm() }
        scribeLexicon.personalNames = ScribeSegmenter.personalNames(in: model.textBlocks.map { $0.attributedString.string })
        let origin = WritingLayout.scribeOrigin
        writingCell = LetterCell(margin: origin, top: origin, height: CGFloat(settings.writingLineHeight),
                                 deviceAspect: tabletSource.mapping.deviceAspect)
        writingRightLimit = .greatestFiniteMagnitude
        writtenLetters = []
        mathLanes = []
        toolController.strokeSink = { [weak self] in self?.writingStrokeFinished($0) }
        if let panel = writingPanel {
            panel.hoverPoint = nil
            panel.pendingStrokes = []
            panel.bufferedStrokes = []
            panel.previewPill?.message = nil
            panel.isScribe = true
            panel.isHidden = false
            panel.cell = writingCell
        }
        if settings.scribeMath {
            if let saved = suspendedMathInput {
                writingCell = saved.cell
                writtenLetters = saved.letters
                pendingLetter = saved.pending
                restoreMathWrapSnapshot(saved.snapshot)
                suspendedMathInput = nil
                panelRestoreMathInput()
                // Only resume the equation if nothing was written after it; otherwise Delete would edit
                // that old equation instead of the text at the caret.
                if let id = saved.equationID, let target = equationAtScribeCaret(), target.equation.id == id {
                    openMathEquation(target.equation, in: target.block.id, at: target.range)
                }
            }
            // Old math at the caret resumes as the active editor, so Delete and the
            // arrows route to MathLive instead of the new line's letters.
            if activeEquationEditor == nil, let target = equationAtScribeCaret() {
                openMathEquation(target.equation, in: target.block.id, at: target.range)
            }
        }
        refreshScribeTarget()
        followWritingCell()
    }

    private func panelRestoreMathInput() {
        writingPanel?.cell = writingCell
        writingPanel?.pendingStrokes = pendingLetter
        if !unresolvedMathStrokes.isEmpty { writingPanel?.previewPill?.message = "Unreadable symbol" }
    }

    /// The equation the Scribe caret sits in or next to: the one at the caret, else the one
    /// immediately before it. The caret is the document index or the target block's end.
    func equationAtScribeCaret() -> (block: TextBlock, equation: EquationAttachment, range: NSRange)? {
        let contents: NSAttributedString
        let index: Int
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView {
            contents = view.textStorage
            index = min(max(scribeDocumentIndex ?? contents.length, 0), contents.length)
        } else if let block = scribeTarget.flatMap({ model.textBlock(id: $0) }) {
            contents = block.attributedString
            index = contents.length
        } else { return nil }
        guard contents.length > 0 else { return nil }
        func equation(at location: Int) -> EquationAttachment? {
            guard location >= 0, location < contents.length else { return nil }
            return contents.attribute(.attachment, at: location, effectiveRange: nil) as? EquationAttachment
        }
        guard let attachment = equation(at: index) ?? equation(at: index - 1),
              let (block, current, range) = equationLocation(attachment.id) else { return nil }
        return (block, current, range)
    }

    /// A stroke over old math resumes that equation instead of starting new ink.
    private func equationUnder(_ point: CGPoint) -> (block: TextBlock, equation: EquationAttachment, range: NSRange)? {
        for block in model.textBlocks.reversed() {
            guard let view = textViews[block.id],
                  let (equation, range) = view.equation(at: view.convert(point, from: self)) else { continue }
            return (block, equation, range)
        }
        return nil
    }

    private func leaveScribe() {
        let caret = scribeCaretRect
        defer { restoreScrollAfterScribe(caret: caret) }
        if settings.scribeMath {
            commitPendingLetter(follow: false)
            finishMathEquation(insertNewline: false)
            suspendedMathInput = (writingCell, writtenLetters, pendingLetter, mathWrapSnapshot(), activeEquationID)
        } else { commitScribeWord() }
        discardEquationTextSelection()
        wordWork?.cancel()
        wordWork = nil
        toolController.strokeSink = nil
        if let panel = writingPanel {
            panel.isHidden = true
            panel.hoverPoint = nil
            panel.isScribe = false
            panel.bufferedStrokes = []
            panel.previewPill?.context = nil
            panel.previewPill?.preview = nil
            panel.previewPill?.message = nil
        }
        if let stash = stashedWriting {
            writingCell = stash.cell
            writtenLetters = stash.letters
            writingRightLimit = stash.rightLimit
            if let width = stash.width { settings.width = width }
            stashedWriting = nil
        }
        if let old = scribeCaretRect { setNeedsDisplay(world: old) }
        scribeCaretRect = nil
        scribeCaretBlink?.invalidate()
        scribeCaretBlink = nil
    }

    /// Math is a recognition variant at the current Scribe target.
    func toggleScribeMath() {
        guard scribeZonesOn, activeMode.usesLetterCell else { return }
        let math = !settings.scribeMath
        prepareScribeMathVariant(math)
        settings.scribeMath = math
        updateScribeZones()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private var scribeMathWasActive = false
    private var suspendedMathInput: (cell: LetterCell?, letters: [WrittenLetter], pending: [Stroke], snapshot: MathWrapSnapshot, equationID: UUID?)?

    private func prepareScribeMathVariant(_ math: Bool) {
        guard math != scribeMathWasActive else { return }
        if math {
            if activeMode == .scribe { commitScribeWord() }
            scribeLiveGeneration += 1
            scribeLiveRunning = false
            scribeLiveResult = nil
            scribeLiveDirty = false
            scribePolishToken += 1
            scribePolishWork?.cancel()
            setScribeProvisional(nil)
            writtenLetters = []
            if let saved = suspendedMathInput {
                writingCell = saved.cell
                writtenLetters = saved.letters
                pendingLetter = saved.pending
                restoreMathWrapSnapshot(saved.snapshot)
                suspendedMathInput = nil
                writingPanel?.pendingStrokes = pendingLetter
                // Only resume the equation if nothing was written after it; otherwise Delete would edit
                // that old equation instead of the text at the caret.
                if let id = saved.equationID, let target = equationAtScribeCaret(), target.equation.id == id {
                    openMathEquation(target.equation, in: target.block.id, at: target.range)
                }
            }
        } else {
            commitPendingLetter(follow: false)
            finishMathEquation(insertNewline: false)
            suspendedMathInput = (writingCell, writtenLetters, pendingLetter, mathWrapSnapshot(), activeEquationID)
            pendingLetter = []
            writtenLetters = []
            writingPanel?.pendingStrokes = []
            writingPanel?.bufferedStrokes = []
            writingPanel?.previewPill?.message = nil
        }
        scribeMathWasActive = math
    }

    /// Arms the trackpad zones and the panel's buttons for the current mode.
    private func updateScribeZones() {
        let on = scribeZonesOn && activeMode.usesLetterCell
        tabletSource.buttonZones = on ? WritingLayout.scribeZones : []
        writingPanel?.showsZones = on
        writingPanel?.mathOn = settings.scribeMath
    }

    private func scribeZoneTapped(_ zone: Int) {
        guard scribeZonesOn, activeMode.usesLetterCell, !tabletSource.isDrawing else { return }
        writingPanel?.flashEdge(zone)
        switch zone {
        case 0:
            // Slide past the letter being written; with none, end the word.
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            if !pendingLetter.isEmpty {
                commitPendingLetter(follow: true, retryUnresolvedMath: !unresolvedMathStrokes.isEmpty)
            } else if activeMode == .scribe, settings.scribeMath {
                navigateMathEquation("spaceAdvance")
            } else if activeMode == .scribe {
                scribeWordBoundary()
            } else {
                writeWordSpace()
            }
        default:
            // Left edge: the same as the Delete key.
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            if activeMode == .scribe, settings.scribeMath, pendingLetter.isEmpty, activeEquationEditor != nil {
                navigateMathEquation("delete")
            } else if activeMode == .scribe {
                scribeDelete()
            } else {
                deleteLastLetter()
            }
        }
    }

    /// Scribe / math: pause or resume the letter auto-commit. A lone Command tap lands here.
    func toggleWritingAutoAdvance() {
        guard scribeZonesOn, activeMode.usesLetterCell else { return }
        settings.writingAutoAdvance.toggle()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// Tracks a lone Control or Command press and release (see `modifierTap`).
    private func trackModifierTap(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
        guard event.type == .flagsChanged else { modifierTap = nil; return }
        // ponytail: Command tap (auto-advance pause) disabled; add `|| flags == .command` and the else branch back to restore.
        if modifierTap == nil, flags == .control {
            modifierTap = (flags, event.timestamp)
            return
        }
        defer { modifierTap = nil }
        guard flags.isEmpty, let tap = modifierTap, event.timestamp - tap.time <= 0.4 else { return }
        if tap.flags == .control { toggleScribeMath() } // else { toggleWritingAutoAdvance() }
    }

    private func scribeDocumentContext() -> String? {
        guard layout == .document, model.effectiveLayout == .document, let view = documentBodyView else { return nil }
        let string = view.textStorage.string as NSString
        let index = min(max(scribeDocumentIndex ?? string.length, 0), string.length)
        return string.substring(to: index)
    }

    private func formattedScribePhrase(_ raw: String, pauses: [Double]?) -> String {
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView {
            let string = view.textStorage.string as NSString
            let index = min(max(scribeDocumentIndex ?? string.length, 0), string.length)
            let context = ScribePolish.context(from: string.substring(to: index))
            return ScribeText.formattedPhrase(raw: raw, context: context,
                                              following: string.substring(from: index),
                                              lexicon: scribeLexicon, pauses: pauses)
        }
        let context = scribeTarget.flatMap { model.textBlock(id: $0) }?.attributedString.string ?? ""
        return ScribeText.formattedPhrase(raw: raw, context: ScribePolish.context(from: context),
                                          lexicon: scribeLexicon, pauses: pauses)
    }

    /// Show the buffered line, recognize it live, and restart (or stop) its idle timer.
    private func scheduleWordCommit() {
        wordWork?.cancel()
        wordWork = nil
        writingPanel?.bufferedStrokes = writtenLetters.flatMap(\.strokes)
        guard !settings.scribeMath, !writtenLetters.isEmpty else {
            scribeLiveResult = nil
            scribeLiveDirty = false
            setScribeProvisional(nil)
            return
        }
        requestScribeLive()
        let work = DispatchWorkItem { [weak self] in self?.commitScribeWord() }
        wordWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WritingLayout.scribePhraseDelay, execute: work)
    }

    /// Recognize the line's strokes so far. Never more than one request in flight: asking
    /// while one runs just marks it dirty, and the next run reads the then-current strokes.
    private func requestScribeLive() {
        guard !settings.scribeMath, HandwritingRecognizers.system() != nil else { return }
        guard !scribeLiveRunning else { scribeLiveDirty = true; return }
        runScribeLive()
    }

    private func runScribeLive() {
        guard let recognizer = HandwritingRecognizers.system(), !writtenLetters.isEmpty else {
            scribeLiveRunning = false
            return
        }
        scribeLiveRunning = true
        scribeLiveDirty = false
        let strokes = writtenLetters.flatMap(\.strokes)
        let ids = strokes.map(\.id)
        let generation = scribeLiveGeneration
        #if DEBUG
        let began = CFAbsoluteTimeGetCurrent()
        #endif
        Task { [weak self] in
            let text = ScribeText.normalized(await recognizer.text(for: strokes))
            #if DEBUG
            NSLog("Scribe live recognition: %d strokes, %.0f ms", strokes.count, (CFAbsoluteTimeGetCurrent() - began) * 1000)
            #endif
            guard let self else { return }
            guard self.scribeLiveGeneration == generation else { return }
            self.scribeLiveRunning = false
            guard self.activeMode == .scribe, !self.settings.scribeMath else { return }
            // Only current if the line still has exactly these strokes.
            if self.writtenLetters.flatMap(\.strokes).map(\.id) == ids {
                self.scribeLiveResult = (ids, text)
                if let text { self.setScribeProvisional(text) }
            }
            if self.scribeLiveDirty, !self.writtenLetters.isEmpty, self.activeMode == .scribe { self.runScribeLive() }
        }
    }

    /// Clear the panel at once and queue the buffered line; its text is the live result when that
    /// covers every stroke, else one fresh recognition.
    @discardableResult
    private func commitScribeWord() -> Int? {
        wordWork?.cancel()
        wordWork = nil
        commitPendingLetter(follow: false)
        guard let first = writtenLetters.first, let cell = writingCell else { return nil }
        let strokes = writtenLetters.flatMap(\.strokes)
        let ids = strokes.map(\.id)
        let pauses = Self.pauses(of: writtenLetters)
        let live = scribeLiveResult
        writingPanel?.flyInk(strokes)
        writtenLetters = []
        scribeLiveResult = nil
        scribeLiveDirty = false
        writingPanel?.bufferedStrokes = []
        setWritingCell(Self.cell(cell, at: first.before))
        guard let recognizer = HandwritingRecognizers.system() else { return nil }
        let id = scribeQueue.enqueuePending(pauses: pauses)
        if let live, live.ids == ids, live.text != nil {
            scribeQueue.complete(id, text: live.text)
            drainScribe()
            return id
        }
        Task { [weak self] in
            let text = await recognizer.text(for: strokes)
            self?.scribeQueue.complete(id, text: ScribeText.normalized(text))
            self?.drainScribe()
        }
        return id
    }

    /// Return: the pending line, then a line break once it has been applied.
    private func scribeNewLine() {
        dismissedCandidateID = writtenLetters.last?.id
        refreshMathCandidates()
        if settings.scribeMath {
            guard unresolvedMathStrokes.isEmpty else { return }
            commitPendingLetter(follow: false)
            return finishMathEquation(insertNewline: true)
        }
        let lineID = commitScribeWord()
        // The input panel uses a private row, not the output document's line.
        // Moving it down here leaves it stranded when a Return is deleted.
        scribeQueue.enqueueDone("\n", afterPendingID: lineID)
        drainScribe()
    }

    /// Seconds of pause before each letter (the first has none): from the end of the previous letter's
    /// last stroke to the start of this one's first.
    private static func pauses(of letters: [WrittenLetter]) -> [Double] {
        letters.indices.map { $0 == 0 ? 0 : max(0, letters[$0].start - letters[$0 - 1].end) }
    }

    /// Separate words spatially while keeping their ink together for line recognition.
    private func scribeWordBoundary() {
        commitPendingLetter(follow: false)
        if settings.scribeMath { return }
        guard var cell = writingCell else { return }
        cell.space()
        setWritingCell(cell)
        scheduleWordCommit()
    }

    /// Delete: the pending letter, else the last letter of the line, else the newest
    /// queued line (cancelled whole), else the last word of the target block.
    private func scribeDelete() {
        if !pendingLetter.isEmpty {
            discardPendingLetter()
            unresolvedMathStrokes = []
            writingPanel?.previewPill?.message = nil
            return scheduleWordCommit()
        }
        if let last = writtenLetters.popLast(), let cell = writingCell {
            setWritingCell(Self.cell(cell, at: last.before))
            return scheduleWordCommit()
        }
        if scribeQueue.dropLastForDelete() { return }
        scribeLocks = []
        model.undoManager.beginUndoGrouping()
        defer { model.undoManager.endUndoGrouping() }
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView {
            let index = min(max(scribeDocumentIndex ?? view.textStorage.length, 0), view.textStorage.length)
            guard index > 0,
                  let rest = ScribeText.removingLastWord(
                    from: view.textStorage.attributedSubstring(from: NSRange(location: 0, length: index))) else { return }
            let range = NSRange(location: rest.length, length: index - rest.length)
            scribeApplyingDocumentEdit = true
            view.textView.insertText(NSAttributedString(), replacementRange: range)
            model.undoManager.setActionName("Scribe")
            scribeApplyingDocumentEdit = false
            scribeDocumentIndex = range.location
            scribePolishToken += 1
            syncDocumentBody()
            scribeTargetDidChange()
            return reopenMathAtScribeCaret()
        }
        scribePolishToken += 1
        guard var block = scribeTarget.flatMap({ model.textBlock(id: $0) }),
              let rest = ScribeText.removingLastWord(from: block.attributedString) else { return }
        if rest.length == 0 {
            model.removeTextBlock(id: block.id, actionName: "Scribe")
            scribeTarget = nil
        } else {
            block.content = TextBlock.content(from: rest)
            model.updateTextBlock(block, actionName: "Scribe")
        }
        scribeTargetDidChange()
        reopenMathAtScribeCaret()
    }

    /// After Delete steps back over a line break, the equation now before the caret is editable again.
    private func reopenMathAtScribeCaret() {
        guard settings.scribeMath, activeEquationEditor == nil, let target = equationAtScribeCaret() else { return }
        openMathEquation(target.equation, in: target.block.id, at: target.range)
    }

    /// Apply finished results in queue order. Each word gets the fast local fixes at once;
    /// the model polish of its sentence follows in the background.
    private func drainScribe() {
        for next in scribeQueue.popReadyWithPauses() { applyScribe(next.text, pauses: next.pauses) }
    }

    private func applyScribe(_ result: String?, pauses: [Double]?) {
        let made = takeScribeProvisional()
        defer {
            // The next word's live text, if it has any, is shown again after this one lands.
            if !writtenLetters.isEmpty, let text = scribeLiveResult?.text { setScribeProvisional(text) }
        }
        guard let raw = result else { return scribeFailed() }
        guard raw != "\n" else { return appendScribe(raw, reusing: made) }
        appendScribe(formattedScribePhrase(raw, pauses: pauses), reusing: made)
        scheduleScribePolish()
    }

    // MARK: Provisional text

    /// The target block's committed text (the model's, which never holds provisional text).
    private func scribeCommittedText() -> String {
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView {
            let contents = NSMutableString(string: view.textStorage.string)
            if let provisional = scribeProvisional, NSMaxRange(provisional.range) <= contents.length {
                contents.deleteCharacters(in: provisional.range)
            }
            return contents as String
        }
        return scribeTarget.flatMap { model.textBlock(id: $0) }?.attributedString.string ?? ""
    }

    /// Show `text` (formatted here) as dim provisional text at the end of the target, replacing the
    /// previous provisional text; nil removes it. No undo step and nothing reaches the model but a
    /// block created for it (silently) and its laid-out height.
    private func setScribeProvisional(_ raw: String?) {
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif
        removeProvisionalText()
        guard let raw, !raw.isEmpty else {
            if scribeProvisionalMadeBlock, let id = scribeTarget {
                model.removeTextBlockSilently(id: id)
                scribeTarget = nil
                scribeProvisionalMadeBlock = false
            }
            return scribeTargetDidChange()
        }
        if scribeTarget.flatMap({ model.textBlock(id: $0) }) == nil, let block = makeScribeBlock() {
            scribeLocks = []
            model.addTextBlockSilently(block.block)
            scribeTarget = block.block.id
            scribeProvisionalMadeBlock = true
            if block.needsScroll, activeMode == .scribe {
                insertProvisional(raw)
                refreshScribeTarget()
                return followWritingCell(target: block.block.bounds)
            }
        }
        insertProvisional(raw)
        scribeTargetDidChange()
        #if DEBUG
        NSLog("Scribe provisional: %.1f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        #endif
    }

    private func insertProvisional(_ raw: String) {
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView {
            let storage = view.textStorage
            let at = min(max(scribeDocumentIndex ?? storage.length, 0), storage.length)
            let letters = writtenLetters
            let current = scribeLiveResult.map { $0.ids == letters.flatMap(\.strokes).map(\.id) } ?? false
            let text = formattedScribePhrase(raw, pauses: current ? Self.pauses(of: letters) : nil)
            guard !text.isEmpty else { return }
            var attributes = at > 0 ? storage.attributes(at: at - 1, effectiveRange: nil) : settings.defaultTextAttributes
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
            let priorSuspension = documentBodySyncSuspended
            documentBodySyncSuspended = true
            storage.insert(NSAttributedString(string: text, attributes: attributes), at: at)
            documentBodySyncSuspended = priorSuspension
            let length = (text as NSString).length
            view.textView.setSelectedRange(NSRange(location: at + length, length: 0))
            view.relayout()
            scribeProvisional = (text, NSRange(location: at, length: length))
            return
        }
        guard let id = scribeTarget, let view = textViews[id], let block = model.textBlock(id: id) else { return }
        let letters = writtenLetters
        let current = scribeLiveResult.map { $0.ids == letters.flatMap(\.strokes).map(\.id) } ?? false
        let text = ScribeText.formattedPhrase(raw: raw, context: ScribePolish.context(from: block.attributedString.string),
                                              lexicon: scribeLexicon,
                                              pauses: current ? Self.pauses(of: letters) : nil)
        guard !text.isEmpty else { return }
        applyProvisional(text, to: view, committed: block.attributedString)
        var b = block
        b.height = Double(view.layoutHeight())
        model.updateTextBlock(b, actionName: nil)
    }

    private func applyProvisional(_ text: String, to view: TextBlockView, committed: NSAttributedString) {
        var attributes = committed.length > 0 ? committed.attributes(at: committed.length - 1, effectiveRange: nil)
                                              : settings.defaultTextAttributes
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
        let at = view.textStorage.length
        view.textStorage.append(NSAttributedString(string: text, attributes: attributes))
        view.relayout()
        scribeProvisional = (text, NSRange(location: at, length: (text as NSString).length))
    }

    /// Take the provisional text out of the target's view.
    private func removeProvisionalText() {
        guard let p = scribeProvisional else { return }
        scribeProvisional = nil
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView,
           NSMaxRange(p.range) <= view.textStorage.length {
            let priorSuspension = documentBodySyncSuspended
            documentBodySyncSuspended = true
            view.textStorage.deleteCharacters(in: p.range)
            documentBodySyncSuspended = priorSuspension
            view.textView.setSelectedRange(NSRange(location: min(p.range.location, view.textStorage.length), length: 0))
            view.relayout()
            return
        }
        guard let view = scribeTarget.flatMap({ textViews[$0] }), NSMaxRange(p.range) <= view.textStorage.length else { return }
        view.textStorage.deleteCharacters(in: p.range)
        view.relayout()
    }

    /// Re-show provisional text a model update wiped from the view.
    private func restoreProvisionalIfNeeded() {
        guard let p = scribeProvisional, let id = scribeTarget, let view = textViews[id],
              let block = model.textBlock(id: id) else { return }
        let storage = view.textStorage
        if NSMaxRange(p.range) <= storage.length,
           (storage.string as NSString).substring(with: p.range) == p.text { return }
        scribeProvisional = nil
        applyProvisional(p.text, to: view, committed: block.attributedString)
    }

    /// Drop provisional text before a word is finalized. Returns the block that was made only for
    /// it (removed from the model without undo) so the final text can add it back as one step.
    private func takeScribeProvisional() -> TextBlock? {
        removeProvisionalText()
        guard scribeProvisionalMadeBlock, let id = scribeTarget, let block = model.textBlock(id: id) else {
            scribeProvisionalMadeBlock = false
            return nil
        }
        scribeProvisionalMadeBlock = false
        model.removeTextBlockSilently(id: id)
        scribeTarget = nil
        return block
    }

    /// After a quiet moment, polish the sentence at the end of the target with the model and swap
    /// it in place, but only if the block is unchanged since (a newer word or edit drops it).
    /// Sentence autocorrect is switched off for now; flip to bring it (and its setting) back.
    private static let sentencePolishEnabled = false

    private func scheduleScribePolish() {
        if layout == .document, model.effectiveLayout == .document { syncDocumentBody() }
        scribePolishToken += 1
        let token = scribePolishToken
        scribePolishWork?.cancel()
        guard Self.sentencePolishEnabled, settings.scribeSentencePolish, let polisher = scribePolisher, polisher.isAvailable else { return }
        let work = DispatchWorkItem { [weak self] in self?.runScribePolish(token: token) }
        scribePolishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func runScribePolish(token: Int) {
        guard token == scribePolishToken, let polisher = scribePolisher, let id = scribeTarget,
              model.textBlock(id: id) != nil else { return }
        let documentSnapshot: String?
        let documentPrefix: String?
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView {
            let snapshot = view.textStorage.string
            let ns = snapshot as NSString
            let end = min(max(scribeDocumentIndex ?? ns.length, 0), ns.length)
            documentSnapshot = snapshot
            documentPrefix = ns.substring(to: end)
        } else {
            documentSnapshot = nil
            documentPrefix = nil
        }
        Task { [weak self] in
            guard let self, token == self.scribePolishToken, let block = self.model.textBlock(id: id) else { return }
            let snapshot = documentSnapshot ?? block.attributedString.string
            let locks = ScribePolish.validLocks(self.scribeLocks, in: snapshot)
            guard let range = ScribePolish.openRange(in: documentPrefix ?? snapshot, locks: locks) else { return }
            let ns = snapshot as NSString
            let piece = ns.substring(with: range)
            let context = ScribePolish.context(from: ns.substring(to: range.location))
            guard let polished = ScribeText.normalized(await polisher.polish(piece, context: context)) else { return }
            guard token == self.scribePolishToken,
                  let merged = ScribePolish.merge(polished: polished, raw: piece), merged != piece,
                  var block = self.model.textBlock(id: id) else { return }
            #if DEBUG
            NSLog("Scribe polish: \"%@\" -> \"%@\" (model: \"%@\")", piece, merged, polished)
            #endif
            // The piece never contains a lock (it starts after them), so locks stay as they are;
            // the confident words of this edit are added, at their place in the block.
            let newLocks = locks + ScribePolish.confidentLocks(raw: piece, merged: merged).map {
                ScribeLock(range: NSRange(location: range.location + $0.range.location, length: $0.range.length), text: $0.text)
            }
            if let documentSnapshot, let view = self.documentBodyView,
               view.textStorage.string == documentSnapshot,
               NSMaxRange(range) <= view.textStorage.length {
                let attrs = range.length > 0
                    ? view.textStorage.attributes(at: range.location, effectiveRange: nil)
                    : settings.defaultTextAttributes
                self.scribeApplyingDocumentEdit = true
                view.textView.insertText(NSAttributedString(string: merged, attributes: attrs), replacementRange: range)
                self.model.undoManager.setActionName("Scribe Polish")
                self.scribeApplyingDocumentEdit = false
                self.scribeLocks = newLocks
                let delta = (merged as NSString).length - range.length
                if let index = self.scribeDocumentIndex, NSMaxRange(range) <= index {
                    self.scribeDocumentIndex = max(0, index + delta)
                }
                self.scribeTargetDidChange()
                return
            }
            guard block.attributedString.string == snapshot else { return }
            let edited = NSMutableAttributedString(attributedString: block.attributedString)
            edited.replaceCharacters(in: range, with: merged)
            block.content = TextBlock.content(from: edited)
            self.model.updateTextBlock(block, actionName: "Scribe Polish")
            self.scribeLocks = newLocks
            self.scribeTargetDidChange()
        }
    }

    private func scribeFailed() {
        NSSound.beep()
        scribeMessageToken += 1
        let token = scribeMessageToken
        writingPanel?.previewPill?.message = "Couldn't read that"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.scribeMessageToken == token { self?.writingPanel?.previewPill?.message = nil }
        }
    }

    /// Add a recognized word ("\n": a line break) to the target block, creating it for the
    /// first word. One undo step each.
    private func appendScribe(_ piece: String, reusing made: TextBlock? = nil) {
        let current: NSAttributedString
        let index: Int
        if layout == .document, let view = documentBodyView {
            current = view.textStorage
            index = min(max(scribeDocumentIndex ?? current.length, 0), current.length)
        } else {
            current = scribeTarget.flatMap { model.textBlock(id: $0) }?.attributedString ?? NSAttributedString()
            index = current.length
        }
        var attributes = index > 0 ? current.attributes(at: index - 1, effectiveRange: nil)
                                   : settings.defaultTextAttributes
        attributes.removeValue(forKey: .attachment)
        appendScribe(NSAttributedString(string: piece, attributes: attributes), reusing: made)
    }

    /// Attributed insertion shares Scribe's placement and document caret. Equations arrive
    /// already formatted and never enter prose segmentation, correction, or polish.
    private func appendScribe(_ piece: NSAttributedString, reusing made: TextBlock? = nil) {
        guard piece.length > 0 else { return }
        model.undoManager.beginUndoGrouping()
        defer { model.undoManager.endUndoGrouping() }
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView {
            var index = min(max(scribeDocumentIndex ?? view.textStorage.length, 0), view.textStorage.length)
            var replacementRange = NSRange(location: index, length: 0)
            if piece.string == "\n", index > 0, index < view.textStorage.length {
                let string = view.textStorage.string as NSString
                let previous = string.substring(with: NSRange(location: index - 1, length: 1)).first
                let next = string.substring(with: NSRange(location: index, length: 1)).first
                if previous?.isWhitespace == true, next?.isWhitespace == false {
                    index -= 1
                    replacementRange = NSRange(location: index, length: 1)
                }
            }
            scribeApplyingDocumentEdit = true
            let inserted: Bool
            if replacementRange.length > 0 {
                view.textView.insertText(piece, replacementRange: replacementRange)
                model.undoManager.setActionName("Scribe")
                inserted = true
            } else {
                inserted = insertDocumentText(piece, at: index, actionName: "Scribe")
            }
            scribeApplyingDocumentEdit = false
            guard inserted else { return }
            scribeDocumentIndex = index + piece.length
            scribeTarget = documentBodyID
            syncDocumentBody()
            scribeTargetDidChange()
            return
        }
        let isBreak = piece.string == "\n"
        if var block = scribeTarget.flatMap({ model.textBlock(id: $0) }) {
            let current = NSMutableAttributedString(attributedString: block.attributedString)
            if isBreak && current.length == 0 { return }
            current.append(piece)
            block.content = TextBlock.content(from: current)
            model.updateTextBlock(block, actionName: "Scribe")
        } else {
            guard !isBreak else { return }
            let string = piece.string as NSString
            var start = 0
            while start < string.length && string.character(at: start) == 32 { start += 1 }
            let trimmed = piece.attributedSubstring(from: NSRange(location: start, length: piece.length - start))
            if var block = made {
                block.content = TextBlock.content(from: trimmed)
                model.addTextBlock(block, actionName: "Scribe")
                scribeTarget = block.id
            } else if var made = makeScribeBlock() {
                made.block.content = TextBlock.content(from: trimmed)
                model.addTextBlock(made.block, actionName: "Scribe")
                scribeTarget = made.block.id
                if made.needsScroll, activeMode == .scribe {
                    refreshScribeTarget()
                    return followWritingCell(target: made.block.bounds)
                }
            }
        }
        scribeTargetDidChange()
    }

    // MARK: Editable equations

    private var activeEquationEditor: MathLiveEditorView?
    private var activeEquationID: UUID?
    private var activeEquationBlockID: UUID?
    /// Text-view-local x stays fixed while the attachment's asynchronous preview reflows.
    private var equationAnchor: (blockID: UUID, x: CGFloat)?
    /// The equation whose static preview still stands in the text view while the live field
    /// applies its source. Hiding that preview first swapped a correct drawing for the field's
    /// stale contents — the previous equation, at the previous size — which read as the math
    /// jumping the moment the caret appeared.
    private var pendingEquationReveal: (id: UUID, latex: String)?
    private var equationEdits: [MathLiveHandwritingEdit] = []
    private var equationPendingInputIDs = Set<UUID>()
    private var equationGroupDepth = 0
    private var equationPreviewRequests: [UUID: UUID] = [:]
    var renderEquationPreview: (String, Double, @escaping (Result<MathLiveRenderedPreview, Error>) -> Void) -> Void = {
        MathLivePreviewRenderer.shared.render(latex: $0, fontSize: $1, completion: $2)
    }

    private func equationLocation(_ id: UUID) -> (TextBlock, EquationAttachment, NSRange)? {
        for block in model.textBlocks {
            let text = block.attributedString
            var result: (TextBlock, EquationAttachment, NSRange)?
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
                if let equation = value as? EquationAttachment, equation.id == id {
                    result = (block, equation, range)
                    stop.pointee = true
                }
            }
            if let result { return result }
        }
        return nil
    }

    /// The canvas's single MathLive page. It is created on first use and kept alive between
    /// equations, so re-entering an expression only re-parents it and swaps its source: the
    /// field is already loaded and laid out when it becomes active. A page whose web content
    /// died is replaced rather than reused, so one failure cannot strand every later equation.
    /// It is torn down after `mathEditorIdleReleaseDelay` with no math editing, so a note the
    /// user has left alone stops holding a web content process; re-entering an expression
    /// during that window still finds the page warm.
    private var reusableMathEditor: MathLiveEditorView?
    private var mathEditorIdleRelease: DispatchWorkItem?
    private static let mathEditorIdleReleaseDelay: TimeInterval = 60
    #if DEBUG
    /// Lets tests exercise the release without waiting out the real delay.
    var mathEditorIdleReleaseDelayForTesting: TimeInterval?
    #endif
    private var mathEditorIdleDelay: TimeInterval {
        #if DEBUG
        if let mathEditorIdleReleaseDelayForTesting { return mathEditorIdleReleaseDelayForTesting }
        #endif
        return Self.mathEditorIdleReleaseDelay
    }

    /// Math editing is live again: keep the loaded page for the work ahead.
    private func cancelMathEditorIdleRelease() {
        mathEditorIdleRelease?.cancel()
        mathEditorIdleRelease = nil
    }

    /// No equation is open: release the page after the idle delay unless math editing
    /// resumes first. Uncommitted ink needs no page — it is applied when it is recognized,
    /// and `liveMathEditor` mounts a fresh one then.
    private func scheduleMathEditorIdleRelease() {
        cancelMathEditorIdleRelease()
        guard reusableMathEditor != nil, activeEquationEditor == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.releaseIdleMathEditor() }
        mathEditorIdleRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + mathEditorIdleDelay, execute: work)
    }

    private func releaseIdleMathEditor() {
        mathEditorIdleRelease = nil
        guard activeEquationEditor == nil, let editor = reusableMathEditor else { return }
        reusableMathEditor = nil
        editor.removeFromSuperview()
    }

    private func liveMathEditor() -> MathLiveEditorView {
        cancelMathEditorIdleRelease()
        if let editor = reusableMathEditor, !editor.hasFailed { return editor }
        let editor = MathLiveEditorView()
        reusableMathEditor = editor
        editor.noteUndoManager = model.undoManager
        editor.onChange = { [weak self, weak editor] source, origin in
            guard let self, let editor, self.activeEquationEditor === editor else { return }
            if origin == .keyboard {
                self.clearUnresolvedMathInput()
                self.invalidateMathRecognitionHistory()
            }
            self.saveMathSource(source, undoable: origin != .handwritingRevision)
            self.equationPendingInputIDs.removeAll()
        }
        editor.onFailure = { [weak self, weak editor] _ in
            guard let self else { return }
            // A field that never laid the source out must not hold the preview hostage.
            if self.pendingEquationReveal != nil {
                self.pendingEquationReveal = nil
                editor?.alphaValue = 1
                self.positionMathEditor()
            }
            let input = self.writtenLetters.filter { self.equationPendingInputIDs.contains($0.id) }.flatMap(\.originalStrokes)
            if !input.isEmpty {
                self.unresolvedMathStrokes = input + self.pendingLetter
                self.pendingLetter = self.unresolvedMathStrokes
                self.writingPanel?.pendingStrokes = self.pendingLetter
            }
            self.writingPanel?.previewPill?.message = "Equation editor unavailable; input retained"
        }
        editor.onExternalSelectionChange = { [weak self] in self?.invalidateMathRecognitionHistory() }
        editor.onUndo = { [weak self] in self?.model.undoManager.undo() }
        editor.onRedo = { [weak self] in self?.model.undoManager.redo() }
        editor.onFinish = { [weak self] newline in
            guard let self else { return }
            if newline { self.finishMathEquation(insertNewline: true) }
            else { self.exitMathEditing() }
        }
        editor.onDeleteAtStart = { [weak self] in
            self?.deleteAfterMathClose = true
            self?.finishMathEquation(insertNewline: false)
        }
        editor.onSizeChange = { [weak self] _ in self?.positionMathEditor() }
        editor.onLayoutApplied = { [weak self, weak editor] source in
            guard let self, let editor, self.activeEquationEditor === editor,
                  let pending = self.pendingEquationReveal, pending.id == self.activeEquationID,
                  source == pending.latex || source == self.equationLocation(pending.id)?.1.latex else { return }
            self.pendingEquationReveal = nil
            editor.alphaValue = 1
            self.positionMathEditor()
        }
        return editor
    }

    @discardableResult
    private func ensureMathEditor() -> MathLiveEditorView {
        if let editor = activeEquationEditor { return editor }
        activeEquationID = UUID()
        activeEquationBlockID = scribeTarget
        let editor = liveMathEditor()
        editor.setLatex("", fontSize: settings.defaultFontSize)
        activateMathEditor(editor)
        return editor
    }

    /// Shows the shared field for the equation that just became active and gives it focus.
    private func activateMathEditor(_ editor: MathLiveEditorView) {
        activeEquationEditor = editor
        // A key can only ever act on the equation it was pressed against.
        if pendingInlineEquationKey?.id != activeEquationID { pendingInlineEquationKey = nil }
        equationAnchor = nil
        if editor.superview !== self { addSubview(editor, positioned: .above, relativeTo: nil) }
        positionMathEditor()
        // A Delete/arrow that entered the equation from the note acts as soon as the field
        // is live: `evaluate` queues the commands in order until the page is ready.
        if let pending = pendingInlineEquationKey, pending.id == activeEquationID {
            pendingInlineEquationKey = nil
            applyInlineEquationKey(pending.key, to: editor)
        }
        // Automatic handwriting edits must preserve the tablet cursor lock.
        // Only an explicit equation click below switches to mouse editing.
        window?.makeFirstResponder(editor.webView)
    }

    /// A Delete/arrow that pressed against an inline equation before its field was live.
    private var pendingInlineEquationKey: (id: UUID, key: InlineEquationKey)?

    /// An inline equation is one attachment character, but it edits like a run of text:
    /// Delete and the arrows against its edge enter the live field and act on its symbols.
    /// Returns false only when the equation is gone.
    func editInlineEquation(_ equation: EquationAttachment, key: InlineEquationKey) -> Bool {
        guard let (block, current, range) = equationLocation(equation.id) else { return false }
        if let editor = activeEquationEditor, activeEquationID == equation.id {
            applyInlineEquationKey(key, to: editor)
            return true
        }
        // `openMathEquation` closes any other live equation first and re-enters this one.
        pendingInlineEquationKey = (equation.id, key)
        openMathEquation(current, in: block.id, at: range)
        return true
    }

    /// Enters the field at the boundary the key was pressed against, then performs the
    /// edit: Backspace drops the last symbol, Forward Delete the first, an arrow only places
    /// the caret.
    private func applyInlineEquationKey(_ key: InlineEquationKey, to editor: MathLiveEditorView) {
        editor.focusBoundary(key == .forwardDelete || key == .moveRight ? .start : .end)
        switch key {
        case .backspace: editor.navigate("delete")
        case .forwardDelete: editor.navigate("deleteForward")
        case .moveLeft, .moveRight: break
        }
    }

    private func openMathEquation(_ equation: EquationAttachment, in blockID: UUID, at range: NSRange,
                                  at point: CGPoint? = nil) {
        if activeEquationID == equation.id, let editor = activeEquationEditor {
            if let point {
                cursorLock.unlock()
                editor.focus(at: editor.convert(point, from: self))
            }
            return
        }
        if let editor = activeEquationEditor {
            editor.flush { [weak self, weak editor] in
                guard let self else { return }
                if self.activeEquationEditor === editor { self.closeMathEditor(insertNewline: false) }
                guard self.activeEquationEditor == nil else { return }
                if let (block, current, currentRange) = self.equationLocation(equation.id) {
                    self.openMathEquation(current, in: block.id, at: currentRange, at: point)
                }
            }
            return
        }
        finishEditing(restoreFocus: false)
        textViews[blockID]?.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        activeEquationID = equation.id
        activeEquationBlockID = blockID
        scribeTarget = blockID
        if layout == .document { scribeDocumentIndex = NSMaxRange(range) }
        let editor = liveMathEditor()
        // The preview stays up until the field reports this source back laid out; the page
        // still holds the previously edited equation until the swap lands.
        pendingEquationReveal = (equation.id, equation.latex)
        editor.alphaValue = 0
        editor.setLatex(equation.latex, fontSize: equation.fontSize)
        activateMathEditor(editor)
        if let point, let editor = activeEquationEditor {
            cursorLock.unlock()
            editor.focus(at: editor.convert(point, from: self))
        }
        window?.makeFirstResponder(activeEquationEditor?.webView)
    }

    private func saveMathSource(_ latex: String, undoable: Bool = true) {
        guard let id = activeEquationID else { return }
        let location = equationLocation(id)
        if let (_, old, _) = location {
            guard old.latex != latex else { return }
        } else {
            guard !latex.isEmpty else { return }
        }
        let recordsUndo = undoable || location == nil
        if recordsUndo { model.undoManager.beginUndoGrouping() }
        defer { if recordsUndo { model.undoManager.endUndoGrouping() } }
        if let (block, old, range) = location {
            // Keep the old preview until the new one renders: without it the attachment falls back to
            // raw-source bounds and the line relayouts twice per character (visible flashing).
            // ponytail: a failed render leaves the previous preview stored; re-render on open if that shows up.
            let replacement = EquationAttachment(id: id, latex: latex, fontSize: old.fontSize,
                                                 previewPDF: old.previewPDF, previewMetrics: old.previewMetrics)
            replaceEquation(replacement, in: block, range: range, undoable: undoable)
        } else {
            let equation = EquationAttachment(id: id, latex: latex, fontSize: settings.defaultFontSize)
            // A bare attachment has no font, so text typed after it fell back to the system size.
            let piece = NSMutableAttributedString(attachment: equation)
            piece.addAttributes(settings.defaultTextAttributes.filter { $0.key != .attachment },
                                range: NSRange(location: 0, length: piece.length))
            appendScribe(piece)
            model.undoManager.setActionName("Equation")
            activeEquationBlockID = scribeTarget
        }
        requestEquationPreview(id)
        positionMathEditor()
    }

    private func replaceEquation(_ equation: EquationAttachment, in block: TextBlock, range: NSRange, undoable: Bool) {
        // Keep the character's own formatting; a bare attachment drops the font for what follows.
        let existing = layout == .document && block.id == documentBodyID
            ? documentBodyView?.textStorage : block.attributedString
        let text = NSMutableAttributedString(attachment: equation)
        if let existing, range.location < existing.length {
            text.addAttributes(existing.attributes(at: range.location, effectiveRange: nil)
                .filter { $0.key != .attachment }, range: NSRange(location: 0, length: text.length))
        }
        if layout == .document, let view = documentBodyView, block.id == documentBodyID {
            scribeApplyingDocumentEdit = true
            if undoable {
                model.undoManager.beginUndoGrouping()
                view.textView.insertText(text, replacementRange: range)
                model.undoManager.setActionName("Equation")
                model.undoManager.endUndoGrouping()
            } else {
                let selection = view.textView.selectedRange()
                view.textStorage.replaceCharacters(in: range, with: text)
                view.textView.setSelectedRange(selection)
                view.relayout()
            }
            scribeApplyingDocumentEdit = false
            syncDocumentBody()
        } else {
            let contents = NSMutableAttributedString(attributedString: block.attributedString)
            contents.replaceCharacters(in: range, with: text)
            var changed = block
            changed.content = TextBlock.content(from: contents)
            model.updateTextBlock(changed, actionName: undoable ? "Equation" : nil)
        }
    }

    private func requestEquationPreview(_ id: UUID) {
        guard let (_, equation, _) = equationLocation(id) else { return }
        let source = equation.latex
        let fontSize = equation.fontSize
        let request = UUID()
        equationPreviewRequests[id] = request
        renderEquationPreview(source, fontSize) { [weak self] result in
            guard let self, self.equationPreviewRequests[id] == request,
                  let (block, current, range) = self.equationLocation(id),
                  current.latex == source, current.fontSize == fontSize else { return }
            self.equationPreviewRequests.removeValue(forKey: id)
            guard case .success(let preview) = result else { return }
            let updated = EquationAttachment(id: id, latex: source, fontSize: fontSize,
                                             previewPDF: preview.pdfData,
                                             previewMetrics: preview.metrics)
            self.replaceEquation(updated, in: block, range: range, undoable: false)
            self.positionMathEditor()
        }
    }

    private func refreshActiveEquation() {
        guard let id = activeEquationID, let editor = activeEquationEditor else { return }
        if let (_, equation, _) = equationLocation(id) {
            if editor.latex != equation.latex {
                invalidateMathRecognitionHistory()
                editor.setLatex(equation.latex, fontSize: equation.fontSize)
            }
            positionMathEditor()
        } else if !editor.latex.isEmpty {
            invalidateMathRecognitionHistory()
            pendingEquationReveal = nil
            textViews.values.forEach { $0.editingEquationID = nil }
            editor.removeFromSuperview()
            activeEquationEditor = nil
            activeEquationID = nil
            activeEquationBlockID = nil
            equationAnchor = nil
            equationIsFinishing = false
            scheduleMathEditorIdleRelease()
        }
    }

    private func positionMathEditor() {
        guard let editor = activeEquationEditor else { return }
        // The static preview keeps the equation's place until the field has applied the source,
        // so the swap shows the equation where it already was.
        let hiddenID = pendingEquationReveal == nil ? activeEquationID : nil
        textViews.values.forEach { if $0.editingEquationID != hiddenID { $0.editingEquationID = hiddenID } }
        if let id = activeEquationID, let (block, equation, range) = equationLocation(id),
           let view = textViews[block.id], let rect = view.rectForAttachment(at: range.location) {
            // `rectForAttachment` grows the attachment by 2pt so a click beside an equation still
            // lands on it; the overlay belongs on the attachment itself.
            let box = rect.insetBy(dx: 2, dy: 2)
            if equationAnchor?.blockID != block.id { equationAnchor = (block.id, box.minX) }
            let anchoredRect = CGRect(x: equationAnchor?.x ?? box.minX, y: box.minY, width: box.width, height: box.height)
            let target = view.convert(anchoredRect, to: self)
            // The static preview draws the math `fontSize * 0.2` inside its box, while the live
            // field wraps the same math in its own chrome. Line up the math, not the boxes:
            // matching top-left corners left the expression off by the difference, which read as
            // the text shifting the moment the caret appeared.
            let pad = CGFloat(equation.fontSize) * 0.2
            let inset = editor.contentInsets
            let origin = CGPoint(x: target.minX + (pad - inset.x) * block.scale,
                                 y: target.minY + (pad - inset.y) * block.scale)
            let available = max(1, min(view.frame.maxX - target.minX, view.frame.width))
            editor.setMaxWidth(available / block.scale)
            let width = min(available, max(28 * block.scale, editor.contentSize.width * block.scale))
            let fit = min(1, width / max(1, editor.contentSize.width * block.scale))
            // Width grows in steps so the web view isn't resized (and repainted blank) on every character.
            let step = 48 * block.scale
            let stepped = min(available, max(width, (width / step).rounded(.up) * step))
            let frame = NSRect(x: origin.x, y: origin.y,
                               width: stepped, height: max(28 * block.scale, editor.contentSize.height * block.scale * fit))
            if editor.frame != frame {
                editor.frame = frame
                editor.setBoundsSize(NSSize(width: frame.width / block.scale, height: frame.height / block.scale))
            }
        } else if let target = scribeCaretRect {
            let point = worldToView(target.origin)
            editor.frame = NSRect(x: point.x, y: point.y, width: TextBlock.defaultWidth, height: 60)
        } else if let made = makeScribeBlock() {
            let point = worldToView(made.block.origin)
            editor.frame = NSRect(x: point.x, y: point.y, width: made.block.width, height: 60)
            editor.setBoundsSize(NSSize(width: editor.frame.width / made.block.scale,
                                        height: editor.frame.height / made.block.scale))
        }
    }

    func beginMathRecognitionGroup() { equationGroupDepth += 1 }
    func endMathRecognitionGroup() {
        equationGroupDepth = max(0, equationGroupDepth - 1)
        guard equationGroupDepth == 0, !equationEdits.isEmpty else { return }
        let edits = equationEdits
        equationEdits = []
        ensureMathEditor().applyHandwriting(edits, autoCloseBrackets: settings.autoCloseBrackets)
    }
    func insertMathSymbol(id: UUID, latex: String, role: MathScript.Role) {
        equationPendingInputIDs.insert(id)
        equationEdits.append(MathLiveHandwritingEdit(id: id, latex: latex, role: role))
        if equationGroupDepth == 0 { endMathRecognitionGroup() }
    }
    func insertHandwriting(id: UUID, latex: String, role: MathScript.Role) {
        insertMathSymbol(id: id, latex: latex, role: role)
    }
    func reviseMathSymbol(id: UUID, latex: String) {
        equationEdits.append(MathLiveHandwritingEdit(id: id, latex: latex, role: .body, replaces: [id]))
        if equationGroupDepth == 0 { endMathRecognitionGroup() }
    }
    func replaceHandwriting(id: UUID, latex: String) { reviseMathSymbol(id: id, latex: latex) }
    func replaceMathSymbols(ids: [UUID], latex: String, coalescesUndo: Bool = false) {
        guard let id = ids.first else { return }
        equationEdits.append(MathLiveHandwritingEdit(id: id, latex: latex, role: .body,
                                                     replaces: ids, coalescesUndo: coalescesUndo))
        if equationGroupDepth == 0 { endMathRecognitionGroup() }
    }
    func navigateMathEquation(_ command: String) {
        // Right arrow / Tab / the panel's right zone create a space at the top level and
        // navigate inside a structure. The editor decides which and reports back, so the
        // writing cell advances exactly when a space is actually inserted.
        if command == "spaceRight" || command == "spaceAdvance" {
            mathLanes = []
            activeEquationEditor?.insertMathSpace(fallbackAdvance: command == "spaceAdvance") { [weak self] inserted in
                guard let self, inserted else { return }
                self.writeWordSpace()
            }
            return
        }
        // Mirrors `navigate` in editor.js: Right leaves every lane, Down/Up leave a matching one.
        if command == "down", mathLanes.last == .superscript || command == "up" && mathLanes.last == .subscript {
            mathLanes.removeLast()
        } else {
            mathLanes = []
        }
        activeEquationEditor?.navigate(command)
    }
    @discardableResult
    func insertMathFraction(operandIDs: [UUID] = [], removedParenthesisIDs: [UUID] = []) -> Bool {
        mathLanes = []
        equationEdits.append(MathLiveHandwritingEdit(id: UUID(), latex: "", isFraction: true,
                                                     operandIDs: operandIDs, removedParenthesisIDs: removedParenthesisIDs))
        if equationGroupDepth == 0 { endMathRecognitionGroup() }
        return true
    }
    /// Opens a structure with its slots (∑ ∫ lim √), or writes `indexLatex` as the index
    /// of the root the caret is in. The editor owns the templates and caret placement.
    @discardableResult
    func insertMathStructure(_ kind: MathStructure.Kind, id: UUID, indexLatex: String = "",
                             replaces: [UUID] = [], coalescesUndo: Bool = false) -> Bool {
        mathLanes = []
        equationPendingInputIDs.insert(id)
        equationEdits.append(MathLiveHandwritingEdit(id: id, latex: indexLatex, role: .body,
                                                     replaces: replaces, coalescesUndo: coalescesUndo,
                                                     structure: kind.rawValue))
        if equationGroupDepth == 0 { endMathRecognitionGroup() }
        return true
    }
    #if DEBUG
    var mathEditorForTesting: MathLiveEditorView? { activeEquationEditor }
    var reusableMathEditorForTesting: MathLiveEditorView? { reusableMathEditor }
    func openEquationForTesting(_ id: UUID) {
        guard let (block, equation, range) = equationLocation(id) else { return }
        openMathEquation(equation, in: block.id, at: range)
    }
    func appendScribeContentForTesting(_ content: NSAttributedString) { appendScribe(content) }
    func appendScribeContentForTesting(_ content: String) { appendScribe(content) }
    func applyEquationSourceForTesting(_ source: String, id: UUID, undoable: Bool = true) {
        activeEquationID = id
        saveMathSource(source, undoable: undoable)
    }
    #endif

    private var equationIsFinishing = false
    func finishMathEquation(insertNewline: Bool) {
        guard !equationIsFinishing else { return }
        endMathRecognitionGroup()
        guard let editor = activeEquationEditor else {
            if insertNewline { appendScribe("\n") }
            return
        }
        if mathFunctionRecognitionTask != nil {
            pendingMathEquationFinish = insertNewline
            return
        }
        if !mathFunctionRun.isEmpty {
            let run = mathFunctionRun
            mathFunctionRun = []
            mathFunctionWork?.cancel()
            mathFunctionWork = nil
            recognizeMathFunctionRun(run)
            if mathFunctionRecognitionTask != nil {
                pendingMathEquationFinish = insertNewline
                return
            }
        }
        equationIsFinishing = true
        editor.flush { [weak self, weak editor] in
            guard let self, self.activeEquationEditor === editor else { return }
            self.closeMathEditor(insertNewline: insertNewline)
        }
    }

    /// Escape exits both the web field and Scribe in one action, preserving source.
    private func exitMathEditing() {
        penKeyMonitor.cancel()
        cancelGesture()
        clearSelection()
        if activeMode.usesTabletInput { settings.inputMode = .pen }
        settings.tool = .pointer
        finishMathEquation(insertNewline: false)
    }

    private func closeMathEditor(insertNewline: Bool) {
        let closedID = activeEquationID
        defer { scheduleMathEditorIdleRelease() }
        equationIsFinishing = false
        pendingMathEquationFinish = nil
        pendingEquationReveal = nil
        textViews.values.forEach { $0.editingEquationID = nil }
        activeEquationEditor?.alphaValue = 1
        activeEquationEditor?.removeFromSuperview()
        activeEquationEditor = nil
        activeEquationID = nil
        activeEquationBlockID = nil
        equationAnchor = nil
        // Records from the finished equation must not intercept Delete on the
        // following blank line or supply operands to the next equation.
        invalidateMathRecognitionHistory()
        writtenLetters = []
        mathFractionRoot = nil
        mathActiveRowID = nil
        mathLineStats = nil
        mathResolverStats = nil
        mathPreviousSymbol = nil
        mathStartsAfterWordSpace = false
        mathCursorOwnsPlacement = false
        writingPanel?.bufferedStrokes = []
        discardEquationTextSelection()
        if insertNewline { appendScribe("\n") }
        window?.makeFirstResponder(self)
        if deleteAfterMathClose {
            deleteAfterMathClose = false
            // The emptied equation still holds a character; remove it, then the line break before it.
            if closedID.flatMap(equationLocation) != nil { scribeDelete() }
            scribeDelete()
        }
    }

    /// A ⌘A made while the equation field had focus selects the whole note on the
    /// document text view. It must not outlive the equation: otherwise the next
    /// Delete, meant for prose, clears the entire note including the expression.
    private func discardEquationTextSelection() {
        guard layout == .document, model.effectiveLayout == .document, let body = documentBodyView else { return }
        let selected = body.textView.selectedRange()
        guard selected.length > 0 else { return }
        let index = min(max(scribeDocumentIndex ?? body.textStorage.length, 0), body.textStorage.length)
        body.textView.setSelectedRange(NSRange(location: index, length: 0))
        clearSelection()
    }

    /// An empty block placed in the free area for Scribe text, and whether placing it needs a scroll.
    func makeScribeBlock() -> (block: TextBlock, needsScroll: Bool)? {
        let scale = TextBlock.scale(forMagnification: Double(magnification))
        let visible = worldRect(for: visibleRect.intersection(bounds))
        let content = model.textBlocks.map(\.bounds) + model.strokes(intersecting: visible).map(\.bounds)
        let width = TextBlock.defaultWidth * scale
        let lineHeight = 28 * scale
        let placement = ScribeText.blockOrigin(
            free: scribeFreeRect(left: WritingLayout.scribeLeftInset), size: CGSize(width: width, height: lineHeight),
            content: content, gap: lineHeight)
        let block = TextBlock(origin: placement.origin, width: width, scale: scale)
        return (block, placement.needsScroll)
    }

    private func scribeTargetDidChange() {
        refreshScribeTarget()
        if activeMode == .scribe { followWritingCell() }
    }

    /// The visible world rect clear of the floating toolbar (and Find bar), less `left` screen points
    /// at the left edge. The writing panel floats in its own window, so it takes no room here.
    func scribeFreeRect(left: CGFloat = 0) -> CGRect {
        let top = FloatingChromeLayout.height(findVisible: settings.find.isVisible) + WritingLayout.scribeFreePadding
        return WritingLayout.freeRect(visible: worldRect(for: visibleRect.intersection(bounds)), magnification: magnification,
                                      top: top, bottom: 0, left: left)
    }

    /// Update the caret at the end of the target's text and the panel's recent words.
    func refreshScribeTarget() {
        guard activeMode == .scribe else { return }
        let block = scribeTarget.flatMap { model.textBlock(id: $0) }
        let text = scribeCommittedText()
        let context: String
        if layout == .document, let prefix = scribeDocumentContext() {
            context = prefix
        } else {
            context = text
        }
        var caret: CGRect?
        if let block, let view = textViews[block.id] {
            let isBody = layout == .document && model.effectiveLayout == .document
            let c = isBody ? view.selectedCaretRect() : view.endCaretRect()
            // The document body is drawn below its stored origin (chrome clearance, formatting bar).
            let drop = isBody && block.id == documentBodyID ? documentBodyShift : 0
            caret = CGRect(x: block.origin.x + c.minX, y: block.origin.y + drop + c.minY, width: 0, height: c.height)
        }
        guard caret != scribeCaretRect else { return }
        for r in [scribeCaretRect, caret] { if let r { setNeedsDisplay(world: r) } }
        scribeCaretRect = caret
        scribeCaretVisible = true
        if scribeCaretBlink == nil, caret != nil {
            // Standard insertion-point rhythm; NSTextView exposes no public blink period.
            scribeCaretBlink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let r = self.scribeCaretRect else { return }
                self.scribeCaretVisible.toggle()
                self.setNeedsDisplay(world: r)
            }
        }
    }

    /// A thin caret where the next word will go.
    private func drawScribeCaret(in ctx: CGContext) {
        guard activeMode == .scribe, activeEquationEditor == nil, let r = scribeCaretRect, scribeCaretVisible else { return }
        let w = 1.5 / magnification
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
    }

    // MARK: Pen tap

    private func penWillHandle(_ event: PenEvent) {
        guard event.phase == .began else { return }
        if inputTool == .pen { writingStrokeBegan(at: event.point) }
        // A new stroke continues the pending letter.
        commitWork?.cancel()
        commitWork = nil
        wordWork?.cancel()
        wordWork = nil
        updateInputScale()
        if activeMode.usesLetterCell, let pattern = settings.touchHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    /// Smoothing runs in the units the user watches: panel points in Write mode, screen points otherwise.
    /// In Write mode the pen width is also in panel points, so ink shrinks with the letter.
    private func updateInputScale() {
        if activeMode.usesLetterCell, let s = writingPanel?.worldPerPoint {
            toolController.inputScale = s
            toolController.widthScale = s
        } else {
            toolController.inputScale = 1 / magnification
            toolController.widthScale = 1
        }
    }

    // MARK: Viewport follow

    /// Visible world rect the in-flight follow ends at.
    private var followTarget: CGRect?
    /// Scroll origin the follow is chasing; nil when idle.
    private var followOrigin: CGPoint?
    /// Drives the chase; nil when idle. One link per glide, however often the caret moves.
    private var followLink: CADisplayLink?
    /// Manual scrolling owns the viewport until the pen goes down again.
    private var followSuspended = false
    /// Chase stiffness: seconds for the glide to cover most of what is left.
    private static let followTimeConstant: TimeInterval = 0.07
    /// Close enough to call it arrived, in world points.
    private static let followStopDistance: CGFloat = 0.5
    /// Scroll origin when Scribe began; leaving eases back to it.
    private var scribeEntryOrigin: CGPoint?

    #if DEBUG
    var followOriginForTesting: CGPoint? { followOrigin }
    var isFollowingForTesting: Bool { followLink != nil }
    var reduceMotionForTesting: Bool?
    func suspendFollowForTesting() { suspendFollow() }
    func resumeFollowForTesting() { followSuspended = false }
    /// One chase frame without a display link, so tests and hand checks can step it.
    func followStepForTesting(dt: TimeInterval = 1.0 / 60) { followStep(dt: dt) }
    #endif

    /// Reduce Motion: jump to the target instead of gliding to it.
    private var reduceMotion: Bool {
        #if DEBUG
        if let reduceMotionForTesting { return reduceMotionForTesting }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Ease the clip view to `origin` (clamped), keeping `followTarget` current for the animation's length.
    private func animateScroll(to origin: CGPoint, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        let start = clip.bounds.origin
        guard target != start else { return }
        followTarget = worldRect(for: visibleRect).offsetBy(dx: target.x - start.x, dy: target.y - start.y)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(target)
        }, completionHandler: { [weak self] in
            scrollView.reflectScrolledClipView(clip)
            self?.followTarget = nil
        })
    }

    /// Aim the viewport at `origin` and chase it. The target is retargeted in place, so a
    /// burst of caret updates is one glide and nothing stacks; a manual scroll cancels it.
    private func chaseScroll(to origin: CGPoint, in scrollView: NSScrollView) {
        guard !followSuspended else { return }
        let clip = scrollView.contentView
        let want = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        #if DEBUG
        if activeMode == .scribe, abs(want.y - origin.y) > 0.5 {
            NSLog("DBG scribe follow: page clamps %.1f -> %.1f; the caret cannot clear the panel", origin.y, want.y)
        }
        #endif
        guard want != clip.bounds.origin else { return stopFollowingScroll() }
        followOrigin = want
        followTarget = worldRect(for: visibleRect).offsetBy(dx: want.x - clip.bounds.origin.x,
                                                            dy: want.y - clip.bounds.origin.y)
        guard !reduceMotion else { return settleFollow(in: scrollView) }
        guard followLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(followTick(_:)))
        link.add(to: .main, forMode: .common)
        followLink = link
    }

    /// One frame of the glide: a fraction of the distance left, whatever the refresh rate.
    @objc private func followTick(_ link: CADisplayLink) {
        followStep(dt: max(link.targetTimestamp - link.timestamp, 1.0 / 120))
    }

    /// Advance the chase by `dt`; arriving within half a point ends it at the target.
    private func followStep(dt: TimeInterval) {
        guard let scrollView = enclosingScrollView, let target = followOrigin else { return stopFollowingScroll() }
        let clip = scrollView.contentView
        guard let next = WritingLayout.chaseStep(from: clip.bounds.origin, to: target, dt: dt,
                                                 timeConstant: Self.followTimeConstant,
                                                 epsilon: Self.followStopDistance) else {
            return settleFollow(in: scrollView)
        }
        // Pixel-snapped; a sub-pixel step would snap back in place and stall the chase.
        let snapped = clip.constrainBoundsRect(NSRect(origin: next, size: clip.bounds.size)).origin
        guard snapped != clip.bounds.origin else { return settleFollow(in: scrollView) }
        clip.scroll(to: snapped)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Finish at the origin the chase was aiming for.
    private func settleFollow(in scrollView: NSScrollView) {
        defer { stopFollowingScroll() }
        guard let target = followOrigin else { return }
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Stop chasing; the clip stays where it is.
    private func stopFollowingScroll() {
        followLink?.invalidate()
        followLink = nil
        followOrigin = nil
        followTarget = nil
    }

    /// Scrolling by hand takes the viewport away from the follow, which stays off until the pen is down again.
    private func suspendFollow() {
        stopFollowingScroll()
        followSuspended = true
    }

    /// Back to the pre-Scribe scroll, unless that would push the caret off screen.
    private func restoreScrollAfterScribe(caret: CGRect?) {
        defer { scribeEntryOrigin = nil }
        stopFollowingScroll()
        guard let origin = scribeEntryOrigin, let scrollView = enclosingScrollView else { return }
        var target = origin
        if let caret {
            let clip = scrollView.contentView
            let visible = worldRect(for: NSRect(origin: origin, size: clip.bounds.size))
            let d = WritingLayout.followDelta(target: caret.insetBy(dx: 0, dy: -WritingLayout.followPadding / magnification),
                                              visible: visible)
            target.y += d.dy
        }
        if layout == .document && model.effectiveLayout == .document { target.x = scrollView.contentView.bounds.origin.x }
        animateScroll(to: target, in: scrollView)
    }

    /// Pan (no zoom) so the padded cell (Scribe: the target's caret) sits inside the viewport above the panel.
    private func followWritingCell(target: CGRect? = nil) {
        guard !followSuspended, let scrollView = enclosingScrollView else { return }
        guard let followRect = target ?? (activeMode == .scribe ? scribeCaretRect : writingCell?.rect) else {
            #if DEBUG
            if activeMode == .scribe {
                NSLog("DBG scribe follow: no caret rect (target %@)", scribeTarget?.uuidString ?? "nil")
            }
            #endif
            return
        }
        let m = magnification
        let visible = worldRect(for: visibleRect)
        var safe = visible
        if activeMode == .scribe {
            safe = scribeFreeRect()
        }
        var d: CGVector
        if activeMode == .scribe {
            // A line above the panel's top edge, in whole-line steps.
            d = WritingLayout.scribeFollowDelta(caret: followRect, free: safe, lineHeight: followRect.height,
                                                xInset: WritingLayout.followPadding / m)
        } else {
            // Write: start scrolling a couple of screen points before the cell meets the panel.
            let pad = WritingLayout.followPadding / m
            d = WritingLayout.followDelta(target: followRect.insetBy(dx: -pad, dy: -pad), visible: safe)
        }
        if layout == .document && model.effectiveLayout == .document { d.dx = 0 }
        guard d.dx != 0 || d.dy != 0 else { return }
        let start = scrollView.contentView.bounds.origin
        chaseScroll(to: CGPoint(x: start.x + d.dx, y: start.y + d.dy), in: scrollView)
    }

    // MARK: Write mode overlay

    private func writingOverlayRects() -> [CGRect] {
        guard let cell = writingCell else { return [] }
        let p = 4 / magnification
        return [cell.rect.insetBy(dx: -p, dy: -p)]
    }

    /// The cell outline: where the next letter goes.
    private func drawWritingOverlay(in ctx: CGContext) {
        guard let cell = writingCell else { return }
        let m = magnification
        let r = cell.rect
        ctx.setLineWidth(1 / m)
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
        let radius = min(4 / m, r.height / 4)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
    }

    private func setWritingPanelNeedsDisplay(world rect: CGRect) {
        guard activeMode.usesLetterCell, let panel = writingPanel, let w = panel.worldRect, rect.intersects(w) else { return }
        panel.needsDisplay = true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(settings.backgroundColor.cgColor)
        ctx.fill(dirtyRect)

        if layout == .document { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: origin, y: origin)
        let world = worldRect(for: dirtyRect)

        drawGrid(in: world, ctx: ctx)
        if activeMode == .write { drawWritingOverlay(in: ctx) }

        let skipSelected = movePreview != nil || selection.liveResize != nil
        inkRenderer.draw(in: ctx, world: world, level: StrokeLOD.level(for: magnification),
                         hidden: toolController.pendingErase, skipSelected: skipSelected,
                         selected: selection.selection, pending: pendingLetter + toolController.liveErasePieces)

        // Draw resizing preview if applicable
        if let (original, liveRect) = selection.liveResize {
            drawLiveResizePreview(in: ctx, world: world, original: original, rect: liveRect)
        }

        drawFindHighlights(in: ctx, world: world)
        if movePreview == nil { drawOutlines(in: ctx, world: world, offset: selection.moveOffset) }
        drawMarquee(in: ctx, world: world)
        if activeMode == .tablet { drawTabletOverlay(in: ctx) }
        drawScribeCaret(in: ctx)
    }

    /// Ink and chrome pass drawn above the live body in document layout.
    func drawDocumentOverlay(in ctx: CGContext, world: CGRect) {
        guard layout == .document else { return }
        if activeMode == .write { drawWritingOverlay(in: ctx) }
        let skipSelected = movePreview != nil || selection.liveResize != nil
        inkRenderer.draw(in: ctx, world: world, level: StrokeLOD.level(for: magnification),
                         hidden: toolController.pendingErase, skipSelected: skipSelected,
                         selected: selection.selection, pending: pendingLetter + toolController.liveErasePieces)

        // Draw resizing preview if applicable
        if let (original, liveRect) = selection.liveResize {
            drawLiveResizePreview(in: ctx, world: world, original: original, rect: liveRect)
        }

        drawFindHighlights(in: ctx, world: world)
        if movePreview == nil { drawOutlines(in: ctx, world: world, offset: selection.moveOffset) }
        drawMarquee(in: ctx, world: world)
        if activeMode == .tablet { drawTabletOverlay(in: ctx) }
        drawScribeCaret(in: ctx)
    }

    // MARK: Selection

    /// Screen-pixel padding around selection extents for outlines and the combined box.
    private static let selectionPad: CGFloat = 4

    private func bindSelection() {
        selection.onChange = { [weak self] rect in self?.selectionDidChange(rect) }
    }

    private func selectionDidChange(_ rect: CGRect) {
        updateCanConvert()
        var isMoving = false
        var isResizing = false
        if case .moving = selection.drag { isMoving = true }
        if selection.liveResize != nil { isResizing = true }

        let offset = isMoving ? selection.moveOffset : .zero
        if isMoving, offset != .zero, !selection.selection.isEmpty {
            if movePreview == nil { beginMovePreview() }
            moveMovePreview(by: offset)
        } else {
            endMovePreview(dirty: rect)
            setNeedsDisplay(world: selectionDirtyRect(rect))
        }

        if isResizing {
            setNeedsDisplay(world: selectionDirtyRect(rect))
        }

        if isMoving || textViewsOffset {
            for id in selection.selection {
                guard let view = textViews[id], let block = model.textBlock(id: id) else { continue }
                view.setFrameOrigin(worldToView(CGPoint(x: block.origin.x + offset.dx, y: block.origin.y + offset.dy)))
            }
        }
        textViewsOffset = isMoving
    }

    // MARK: Move preview

    /// Largest preview bitmap side in pixels; bigger selections render at reduced scale.
    private static let maxPreviewPixels: CGFloat = 8192

    /// Render the selected ink and outlines once into a layer below the text
    /// views, and hide them from `draw`; each drag frame then only repositions
    /// the layer instead of repainting the canvas.
    private func beginMovePreview() {
        let rootLayer = layout == .document ? inkOverlayView?.layer : layer
        guard let rootLayer else { return }
        let ids = selection.selection
        let extent = selectionDirtyRect(selection.selectionBounds)
        guard !extent.isNull, !extent.isEmpty else { return }
        let backing = window?.backingScaleFactor ?? 2
        var scale = magnification * backing
        scale = min(scale, Self.maxPreviewPixels / max(extent.width, extent.height))
        let size = CGSize(width: max(1, ceil(extent.width * scale)), height: max(1, ceil(extent.height * scale)))
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        // y-down world space, top row of the bitmap at the extent's minY.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / extent.width, y: -size.height / extent.height)
        ctx.translateBy(x: -extent.minX, y: -extent.minY)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let ink = model.strokes(intersecting: extent).filter { ids.contains($0.id) }
        inkRenderer.draw(ink, level: StrokeLOD.level(for: scale / backing), in: ctx)
        drawOutlines(in: ctx, world: extent, offset: .zero, magnification: scale / backing)
        guard let image = ctx.makeImage() else { return }

        let preview = CALayer()
        preview.contents = image
        preview.contentsScale = backing
        preview.contentsGravity = .resize
        preview.magnificationFilter = .nearest
        preview.anchorPoint = .zero
        preview.frame = viewRect(for: extent)
        rootLayer.insertSublayer(preview, at: 0)
        movePreview = (preview, extent)
        setNeedsDisplay(world: extent)
    }

    private func moveMovePreview(by offset: CGVector) {
        guard let (layer, origin) = movePreview else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: origin.minX + self.origin + offset.dx,
                                 y: origin.minY + self.origin + offset.dy)
        CATransaction.commit()
    }

    /// Drop the preview layer and repaint where the selection was and is now.
    private func endMovePreview(dirty: CGRect) {
        guard let (layer, origin) = movePreview else { return }
        movePreview = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        CATransaction.commit()
        setNeedsDisplay(world: origin)
        setNeedsDisplay(world: selectionDirtyRect(dirty))
    }

    private func selectionDirtyRect(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return rect }
        // Pad for outline stroke, antialiasing, and 8pt handles on all sides
        let pad = (Self.selectionPad + 2 + 4 / magnification) / magnification
        return rect.insetBy(dx: -pad, dy: -pad)
    }

    /// Selection bounds including the live move offset; `.null` when empty.
    private var liveSelectionBounds: CGRect {
        guard !selection.selection.isEmpty else { return .null }
        let offset = selection.moveOffset
        return selection.selectionBounds.offsetBy(dx: offset.dx, dy: offset.dy)
    }

    /// Compute CGAffineTransform to map strokes from original to new rect, preserving origin as reference.
    /// Used for live resize preview and committed scale.
    static func resizeTransform(from original: CGRect, to rect: CGRect) -> CGAffineTransform {
        guard !original.isEmpty else { return .identity }
        let scaleX = rect.width / original.width
        let scaleY = rect.height / original.height
        return CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scaleX, y: scaleY)
            .translatedBy(x: -original.minX, y: -original.minY)
    }

    /// Per-object outlines, plus a combined box for multiple, in world space.
    /// Text views are transparent, so outlines drawn here show around text too.
    /// When resizing, draw the outline at the live rect and add handles.
    private func drawOutlines(in ctx: CGContext, world: CGRect, offset: CGVector, magnification m: CGFloat? = nil) {
        let ids = selection.selection
        guard !ids.isEmpty else { return }
        let m = m ?? magnification
        let accent = NSColor.controlAccentColor
        let pad = 2 / m
        let cull = world.insetBy(dx: -2 * pad, dy: -2 * pad)

        // Determine the outline rect: use live resize rect if resizing, otherwise selection bounds with offset
        var outlineRect = selection.selectionBounds.offsetBy(dx: offset.dx, dy: offset.dy)
        if let (_, liveRect) = selection.liveResize {
            outlineRect = liveRect
        }

        // All object outlines go in one path so overlaps composite once
        // instead of darkening where rectangles cross.
        let outlines = CGMutablePath()
        var box = CGRect.null
        let live = selection.liveResize.map { Self.resizeTransform(from: $0.original, to: $0.rect) }
        func outline(_ r: CGRect) {
            let r = live.map { r.applying($0) } ?? r
            box = box.union(r)
            let o = r.offsetBy(dx: offset.dx, dy: offset.dy).insetBy(dx: -pad, dy: -pad)
            if o.intersects(cull) { outlines.addRect(o) }
        }
        for stroke in model.strokes where ids.contains(stroke.id) { outline(stroke.bounds) }
        for block in model.textBlocks where ids.contains(block.id) { outline(block.bounds) }
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(1 / m)
        // One object: a solid outline. Several: faint outlines inside a solid combined box.
        ctx.setStrokeColor(ids.count > 1 ? accent.withAlphaComponent(0.35).cgColor : accent.cgColor)
        ctx.addPath(outlines)
        ctx.strokePath()
        if ids.count > 1, !box.isNull {
            let p = Self.selectionPad / m
            ctx.setStrokeColor(accent.cgColor)
            ctx.stroke(box.offsetBy(dx: offset.dx, dy: offset.dy).insetBy(dx: -p, dy: -p))
        }

        // Draw handles when resizing or when canResize and not moving
        if selection.canResize && selection.liveResize == nil && selection.moveOffset == .zero {
            drawResizeHandles(in: ctx, at: selection.selectionBounds, magnification: m)
        } else if selection.liveResize != nil {
            drawResizeHandles(in: ctx, at: outlineRect, magnification: m)
        }
    }

    /// Draw 8-point square handles at the four corners, white fill with accent stroke.
    private func drawResizeHandles(in ctx: CGContext, at bounds: CGRect, magnification: CGFloat) {
        let handleSize = 8 / magnification
        let halfSize = handleSize / 2
        let accent = NSColor.controlAccentColor

        let corners: [CGPoint] = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.midX, y: bounds.minY),
            CGPoint(x: bounds.midX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.midY),
            CGPoint(x: bounds.maxX, y: bounds.midY)
        ]

        for corner in corners {
            let rect = CGRect(x: corner.x - halfSize, y: corner.y - halfSize, width: handleSize, height: handleSize)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / magnification)
            ctx.stroke(rect)
        }
    }

    /// Draw selected strokes transformed to the live resize rect.
    private func drawLiveResizePreview(in ctx: CGContext, world: CGRect, original: CGRect, rect: CGRect) {
        let transform = Self.resizeTransform(from: original, to: rect)
        let ids = selection.selection

        ctx.saveGState()
        defer { ctx.restoreGState() }

        let visible = model.strokes(intersecting: world).filter {
            ids.contains($0.id)
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for stroke in visible {
            // Transform each point and redraw
            let transformedPoints = stroke.points.map { point in
                let transformed = CGPoint(x: point.x, y: point.y).applying(transform)
                return StrokePoint(x: transformed.x, y: transformed.y, t: point.t)
            }
            let transformedStroke = Stroke(
                points: transformedPoints,
                color: stroke.color,
                width: stroke.width
            )
            ctx.setStrokeColor(transformedStroke.color.cgColor)
            ctx.setLineWidth(transformedStroke.width)
            ctx.addPath(transformedStroke.path)
            ctx.strokePath()
        }
    }

    private func drawMarquee(in ctx: CGContext, world: CGRect) {
        let m = magnification
        let accent = NSColor.controlAccentColor
        if let marquee = selection.marqueeRect, marquee.intersects(world.insetBy(dx: -2 / m, dy: -2 / m)) {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(marquee)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / m)
            ctx.setLineDash(phase: 0, lengths: [4 / m, 3 / m])
            ctx.stroke(marquee)
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    /// Drop selected ids that left the model. Re-entrant model callbacks are ignored.
    private var isPruning = false
    private func pruneSelection() {
        guard !isPruning, !selection.selection.isEmpty else { return }
        isPruning = true
        defer { isPruning = false }
        selection.pruneMissing()
    }

    private func clearSelection() {
        if !selection.selection.isEmpty { selection.clear() }
    }

    /// Grid spacing in world points: 24 doubled until dots are comfortably apart on screen.
    private func gridStep(for magnification: CGFloat) -> CGFloat {
        var step = Self.gridSpacing
        while step * magnification < Self.minGridScreenSpacing { step *= 2 }
        return step
    }

    private func drawGrid(in world: CGRect, ctx: CGContext) {
        let m = magnification
        let step = gridStep(for: m)
        let dot = 1.5 / m
        var rects: [CGRect] = []
        var y = (world.minY / step).rounded(.down) * step
        while y <= world.maxY {
            var x = (world.minX / step).rounded(.down) * step
            while x <= world.maxX {
                rects.append(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                x += step
            }
            y += step
        }
        ctx.setFillColor(Self.gridDotColor)
        ctx.fill(rects)
    }

    // MARK: Mouse input

    public override func hitTest(_ point: NSPoint) -> NSView? {
        if let editor = activeEquationEditor, !editor.isHidden,
           editor.frame.contains(convert(point, from: superview)) {
            // The frozen system pointer can be over the equation while the
            // finger is drawing elsewhere in the panel. Keep those contacts
            // on CanvasView rather than letting WebKit consume them.
            if activeMode.usesTabletInput, cursorLock.isLocked { return self }
            return editor.hitTest(convert(point, from: superview))
        }
        guard layout == .document else { return super.hitTest(point) }
        guard textTool, !penKeyMonitor.isPenDown, let body = documentBodyView else { return self }
        // Ink (and the selection's box and resize handles) stay grabbable over the text.
        let world = viewToWorld(convert(point, from: superview))
        let radius = Double(Self.hitRadius / magnification)
        if model.hitStrokes(at: world, radius: radius).isEmpty,
           selection.corner(at: world, radius: radius) == nil,
           selection.selection.isEmpty || !selection.selectionBounds.insetBy(dx: -radius, dy: -radius).contains(world) {
            return body.textView
        }
        return self
    }

    /// Relative mode draws at the pointer; an absolute-mode click puts the pen
    /// down at the mapped finger position while touches continue to supply motion.
    public override func mouseDown(with event: NSEvent) {
        NSLog("DBG-CLICK canvas.mouseDown")
        if settings.isToolMenuPresented {
            settings.toolMenu = nil
            return
        }
        if widthKeyHeld { return }
        let equationPoint = convert(event.locationInWindow, from: nil)
        if !penKeyMonitor.isPenDown,
           let hit = model.textBlocks.reversed().compactMap({ block -> (TextBlock, EquationAttachment, NSRange)? in
               guard let view = textViews[block.id],
                     let (equation, range) = view.equation(at: view.convert(equationPoint, from: self)) else { return nil }
               return (block, equation, range)
           }).first {
            openMathEquation(hit.1, in: hit.0.id, at: hit.2, at: equationPoint)
            return
        }
        if textTool, penKeyMonitor.isPenDown {
            pointerMoved(event)
            return
        }
        if activeMode.usesTabletInput {
            guard inputTool == .pen || inputTool == .eraser else { return }
            window?.makeFirstResponder(self)
            trackpadPressed = true
            tabletSource.penChanged(.down, timestamp: event.timestamp)
            settings.penIsDown = true
            return
        }
        // Clicks inside an editing block go to its text view, so this is a click outside.
        finishEditing(restoreFocus: false)
        window?.makeFirstResponder(self)
        // Finish any key-driven ink before the click takes over; preserve the toggle.
        relativeSource.penChanged(.up, timestamp: event.timestamp)
        cancelGesture() // a stale gesture whose mouseUp never arrived
        let viewPoint = convert(event.locationInWindow, from: nil)
        let world = viewToWorld(viewPoint)
        let block = layout == .document ? nil : model.textBlock(at: world)
        switch settings.tool {
        case .pointer:
            pendingTextTap = nil
            if let block {
                beginEditing(block, caretAt: viewPoint)
                return
            }
            pendingTextTap = layout == .canvas ? viewPoint : nil
            gesture = .select
            selection.pointerDown(at: world, extend: event.modifierFlags.contains(.shift),
                                  hitRadius: Double(Self.hitRadius / magnification))
        case .pen, .eraser:
            gesture = .draw
            updateInputScale()
            send(.began, event)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard activeMode == .pen else {
            updateCursor()
            return super.mouseMoved(with: event)
        }
        pointerMoved(event)
    }

    func pointerMoved(_ event: NSEvent) {
        let p = viewToWorld(convert(event.locationInWindow, from: nil))
        relativeSource.pointerMoved(to: p, timestamp: event.timestamp)
        updateCursor()
    }

    public override func mouseDragged(with event: NSEvent) {
        pendingTextTap = nil
        if activeMode == .pen, case .none = gesture { pointerMoved(event) }
        switch gesture {
        case .draw: send(.moved, event)
        case .select: selection.pointerDragged(to: worldPoint(event))
        case .none, .pan: break
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if activeMode.usesTabletInput {
            guard trackpadPressed else { return }
            trackpadPressed = false
            tabletSource.penChanged(penKeyDraws ? .down : .up, timestamp: event.timestamp)
            settings.penIsDown = penKeyDraws
            return
        }
        switch gesture {
        case .draw: send(.ended, event)
        case .select:
            selection.pointerUp(at: worldPoint(event))
            let point = convert(event.locationInWindow, from: nil)
            if let tap = pendingTextTap, selection.selection.isEmpty,
               hypot(tap.x - point.x, tap.y - point.y) <= 3 {
                beginDraft(atView: tap)
            }
        case .none, .pan: return
        }
        pendingTextTap = nil
        gesture = .none
        if penKeyDraws {
            relativeSource.penChanged(.down, timestamp: event.timestamp)
        }
    }

    private var inputTool: Tool {
        #if DEBUG
        if isCapturingGlyphs { return .pen }
        #endif
        return settings.tool
    }
    /// The pen key may draw; the eraser draws only on click and Text never draws.
    var penKeyDraws: Bool { penKeyMonitor.isPenDown && inputTool != .eraser && !textTool }
    /// In a document the selector is the typing state: clicks place the caret.
    var textTool: Bool { layout == .document && inputTool == .pointer }

    /// Hit tolerance for selecting strokes, in screen points.
    private static let hitRadius: CGFloat = 6

    private func worldPoint(_ event: NSEvent) -> CGPoint {
        viewToWorld(convert(event.locationInWindow, from: nil))
    }

    public override func rightMouseDown(with event: NSEvent) {
        if !activeMode.usesTabletInput { super.rightMouseDown(with: event) }
    }
    public override func rightMouseDragged(with event: NSEvent) {
        if !activeMode.usesTabletInput { super.rightMouseDragged(with: event) }
    }
    public override func rightMouseUp(with event: NSEvent) {
        if !activeMode.usesTabletInput { super.rightMouseUp(with: event) }
    }
    public override func otherMouseDown(with event: NSEvent) {
        guard !activeMode.usesTabletInput else { return }
        guard event.buttonNumber == 2, case .none = gesture else { return super.otherMouseDown(with: event) }
        gesture = .pan(last: event.locationInWindow)
        currentCursor().set()
    }
    public override func otherMouseDragged(with event: NSEvent) {
        guard !activeMode.usesTabletInput else { return }
        guard case .pan(let last) = gesture else { return super.otherMouseDragged(with: event) }
        pan(from: last, to: event.locationInWindow)
    }
    public override func otherMouseUp(with event: NSEvent) {
        guard !activeMode.usesTabletInput else { return }
        guard case .pan(let last) = gesture else { return super.otherMouseUp(with: event) }
        pan(from: last, to: event.locationInWindow)
        gesture = .none
        updateCursor()
    }

    // MARK: Gestures and touches

    /// Navigation gestures are swallowed only while a tablet stroke is in progress.
    private var swallowsNavigation: Bool { activeMode.usesTabletInput && tabletSource.isDrawing }

    public override func scrollWheel(with event: NSEvent) {
        if handleWidthScroll(event) { return }
        if !swallowsNavigation { suspendFollow(); super.scrollWheel(with: event) }
    }
    public override func magnify(with event: NSEvent) {
        if !swallowsNavigation { suspendFollow(); super.magnify(with: event) }
    }
    public override func smartMagnify(with event: NSEvent) {
        if !swallowsNavigation { suspendFollow(); super.smartMagnify(with: event) }
    }
    public override func rotate(with event: NSEvent) {
        if !swallowsNavigation { super.rotate(with: event) }
    }

    public override func touchesBegan(with event: NSEvent) { forwardTouches(event) }
    public override func touchesMoved(with event: NSEvent) { forwardTouches(event) }
    public override func touchesEnded(with event: NSEvent) { forwardTouches(event) }
    public override func touchesCancelled(with event: NSEvent) { forwardTouches(event) }

    private func forwardTouches(_ event: NSEvent) {
        guard activeMode.usesTabletInput, case .none = gesture else { return }
        let samples = event.touches(matching: .touching, in: self).map {
            TouchSample(id: AnyHashable($0.identity as! NSObject), normalized: $0.normalizedPosition, deviceSize: $0.deviceSize)
        }
        handleTouches(samples, timestamp: event.timestamp)
    }

    /// Shared touch entry point, independent of AppKit's unconstructible NSTouch.
    func handleTouches(_ samples: [TouchSample], timestamp: TimeInterval) {
        guard activeMode.usesTabletInput, !settings.isToolMenuPresented, !widthKeyHeld,
              case .none = gesture else { return }
        tabletSource.touchesChanged(samples, timestamp: timestamp)
    }

    private func send(_ phase: PenPhase, _ event: NSEvent) {
        let p = viewToWorld(convert(event.locationInWindow, from: nil))
        toolController.handle(PenEvent(phase: phase, point: p, timestamp: event.timestamp))
    }

    /// Abort an in-progress gesture (tool change, window resigning key).
    public func cancelGesture() {
        pendingTextTap = nil
        if trackpadPressed {
            trackpadPressed = false
            tabletSource.penChanged(.cancelled, timestamp: ProcessInfo.processInfo.systemUptime)
            settings.penIsDown = penKeyDraws
        }
        switch gesture {
        case .draw:
            toolController.handle(PenEvent(phase: .cancelled, point: .zero, timestamp: ProcessInfo.processInfo.systemUptime))
        case .select:
            selection.cancelDrag()
        case .pan:
            gesture = .none
            updateCursor()
        case .none:
            break
        }
        gesture = .none
    }

    /// Middle-mouse pan: move the clip view opposite to the drag, in document units.
    private func pan(from last: NSPoint, to current: NSPoint) {
        gesture = .pan(last: current)
        suspendFollow()
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let m = scrollView.magnification
        var origin = clip.bounds.origin
        origin.x -= (current.x - last.x) / m
        origin.y += (current.y - last.y) / m // window is y-up, document is y-down
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Text blocks
    //
    // One `TextBlockView` per model block, positioned in view coordinates.
    // Existing blocks are inert (hit-test transparent) unless being edited, and
    // the resize handle shows only while editing.

    private func applyFrame(of block: TextBlock, to view: TextBlockView?) {
        guard let view else { return }
        view.setFrameOrigin(worldToView(block.origin))
        view.setWidth(block.width)
    }

    func reconcileTextBlocks(_ ids: Set<UUID>) {
        guard layout == model.effectiveLayout else { return }
        if layout == .document {
            guard model.effectiveLayout == .document else { return }
            refreshDocumentBodyFromModel()
            refreshActiveEquation()
            return
        }
        for id in ids {
            guard let block = model.textBlock(id: id) else {
                if let view = textViews.removeValue(forKey: id) {
                    if session?.view === view { session = nil }
                    view.removeFromSuperview()
                }
                continue
            }
            let view = textViews[id] ?? makeTextView(for: block)
            applyFrame(of: block, to: view)
            if !view.isEditing {
                let contents = block.attributedString
                if !view.textStorage.isEqual(to: contents) { view.setContents(contents) }
                let height = Double(view.layoutHeight())
                if abs(block.height - height) > 0.01 {
                    var b = block
                    b.height = height
                    model.updateTextBlock(b, actionName: nil)
                }
            }
        }
        orderTextViews()
        refreshActiveEquation()
        restoreProvisionalIfNeeded()
        refreshScribeTarget()
    }

    /// Stack text views in model order (later = on top); views not in the model
    /// (a draft) stay above. The subviews setter reorders without removing views,
    /// so an editing text view keeps first responder.
    private func orderTextViews() {
        let ordered: [NSView] = model.textBlocks.compactMap { block in
            textViews[block.id].flatMap { $0.superview === self ? $0 : nil }
        }
        let orderedSet = Set(ordered.map(ObjectIdentifier.init))
        let desired = ordered + subviews.filter { !orderedSet.contains(ObjectIdentifier($0)) }
        guard !desired.elementsEqual(subviews, by: ===) else { return }
        subviews = desired
    }

    private func makeTextView(for block: TextBlock) -> TextBlockView {
        let view = configuredTextView(for: block)
        textViews[block.id] = view
        return view
    }

    func configuredTextView(for block: TextBlock) -> TextBlockView {
        let view = TextBlockView(blockID: block.id, width: CGFloat(block.width), scale: CGFloat(block.scale))
        view.defaultFontSize = CGFloat(settings.defaultFontSize)
        view.setWritingToolsEnabled(settings.writingToolsEnabled)
        // One cursor authority: the canvas morphs to the I-beam near text instead of
        // each text view claiming its whole rect.
        view.drawingCursor = { [weak self] in self?.currentCursor() }
        view.onEquationOpen = { [weak self, weak view] equation, range, point in
            guard let self, let view else { return }
            view.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            self.openMathEquation(equation, in: view.blockID, at: range, at: self.convert(point, from: view))
        }
        view.onEquationKey = { [weak self] equation, _, key in
            self?.editInlineEquation(equation, key: key) ?? false
        }
        if layout == .document, block.id == documentBodyID {
            documentBodyView = view
            view.setContents(block.attributedString)
            view.configureAsDocumentBody(pageHeight: frame.height, undoManager: model.undoManager)
            view.onFocusChange = { [weak self] focused in
                guard let self else { return }
                self.settings.isEditingText = focused
                self.refreshEditingTextFormatting()
                guard self.layout == .document else { return }
                self.penKeyMonitor.cancel()
                self.penKeyMonitor.penKey = self.settings.penKey == .space && focused
                    ? .option : self.settings.penKey
                self.penKeyMonitor.activation = focused ? .hold : self.settings.activation
            }
            view.onMouseDown = { [weak self] in self?.clearSelection() } // clicking text drops any ink selection
            view.onBeforeCopy = { [weak self] in self?.syncDocumentBody() }
            view.onPasteCanvasObjects = { [weak self] in self?.pasteDocumentCanvasObjects() ?? false }
            view.onSelectAll = { [weak self] in self?.selectAllDocumentContent() }
            view.onTextSelectionChanged = { [weak self] in
                self?.clearInkSelection()
                self?.refreshEditingTextFormatting()
            }
            view.onWillChangeText = { [weak self] range in self?.documentTextWillReplace(range) }
            view.onTextEdit = { [weak self] range, delta in
                guard let self, self.model.effectiveLayout == .document, !self.documentBodySyncSuspended else { return }
                self.onDocumentTextEdit?(range, delta)
                self.documentBodyTextDidEdit(range, delta)
            }
            view.onContentsChange = { [weak self] in
                guard let self, self.model.effectiveLayout == .document, !self.documentBodySyncSuspended else { return }
                self.onDocumentEdit?()
                self.scheduleDocumentBodySync()
            }
            view.onLayoutChange = { [weak self] in self?.documentBodyLayoutDidChange() }
            view.onCancel = { [weak self] in
                guard let self else { return }
                self.clearInkSelection()
                self.finishEditing()
            }
        } else {
            view.onCancel = { [weak self] in self?.finishEditing() }
            // Keep the formatting bar's style label and size field on the caret.
            view.onTextSelectionChanged = { [weak self] in self?.refreshEditingTextFormatting() }
        }
        view.onResizeEnd = { [weak self] width in self?.textViewDidResize(to: width) }
        addSubview(view)
        return view
    }

    /// New draft block whose caret lands at `point` (view coordinates).
    private func beginDraft(atView point: NSPoint) {
        penKeyMonitor.cancel()
        clearSelection()
        let scale = TextBlock.scale(forMagnification: Double(magnification))
        let s = CGFloat(scale)
        let origin = viewToWorld(NSPoint(x: point.x - TextBlockView.inset.width * s,
                                         y: point.y - (TextBlockView.inset.height + CGFloat(settings.defaultFontSize) * 1.8) * s))
        let block = TextBlock(origin: origin, width: TextBlock.defaultWidth * scale, scale: scale)
        let view = configuredTextView(for: block)
        applyFrame(of: block, to: view)
        view.setContents(NSAttributedString())
        session = EditSession(view: view, block: block, isDraft: true, baseline: NSAttributedString())
        view.beginEditing()
        refreshEditingTextFormatting()
    }

    private func beginEditing(_ block: TextBlock, caretAt point: NSPoint) {
        guard let view = textViews[block.id] else { return }
        penKeyMonitor.cancel()
        clearSelection()
        session = EditSession(view: view, block: block, isDraft: false,
                              baseline: NSAttributedString(attributedString: view.textStorage))
        view.beginEditing(caretAt: point)
        refreshEditingTextFormatting()
    }

    private func textViewDidResize(to width: CGFloat) {
        guard var s = session else { return }
        s.block.width = Double(width)
        session = s
        guard !s.isDraft, var block = model.textBlock(id: s.block.id) else { return }
        block.width = Double(width)
        model.updateTextBlock(block, actionName: "Resize Text")
    }

    /// Commit or discard the active edit. Draft: added if non-empty, else dropped.
    /// Existing: removed if emptied, updated if changed.
    public func finishEditing(restoreFocus: Bool = true) {
        if layout == .document {
            syncDocumentBody()
            if restoreFocus, window?.firstResponder === documentBodyView?.textView {
                window?.makeFirstResponder(self)
            }
            return
        }
        guard let s = session else { return }
        #if DEBUG
        NSLog("DBG finishEditing draft=%@ tool=%@ mode=%@\n%@", s.isDraft ? "y" : "n", settings.tool.rawValue, activeMode.rawValue,
              Thread.callStackSymbols.prefix(8).joined(separator: "\n"))
        #endif
        session = nil
        refreshEditingTextFormatting()
        let view = s.view
        let contents = NSAttributedString(attributedString: view.textStorage)
        let isEmpty = contents.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        view.endEditing()
        if restoreFocus, window?.firstResponder === view.textView { window?.makeFirstResponder(self) }

        let height = Double(view.layoutHeight())
        if s.isDraft {
            guard !isEmpty else {
                view.removeFromSuperview()
                return
            }
            var block = s.block
            block.width = Double(view.frame.width)
            block.height = height
            block.content = TextBlock.content(from: contents)
            textViews[block.id] = view
            model.addTextBlock(block, actionName: "Add Text")
        } else if let current = model.textBlock(id: s.block.id) {
            if isEmpty {
                model.removeTextBlock(id: current.id)
                return
            }
            var block = current
            block.height = height
            if !contents.isEqual(to: s.baseline) {
                block.content = TextBlock.content(from: contents)
                model.updateTextBlock(block, actionName: "Edit Text")
            } else {
                model.updateTextBlock(block, actionName: nil)
            }
        }
    }

    /// The text view the formatting bar acts on: the document body, or the block
    /// being edited on the canvas.
    var activeEditView: TextBlockView? {
        if layout == .document, model.effectiveLayout == .document, let view = documentBodyView { return view }
        return session?.view
    }

    /// Sends a formatting action to the text being edited, making sure the
    /// editor (not a toolbar control) is the first responder that receives it.
    public func performTextAction(_ action: Selector) {
        guard let view = activeEditView else { return }
        if layout == .document, model.effectiveLayout == .document { syncDocumentBody() }
        if window?.firstResponder !== view.textView { window?.makeFirstResponder(view.textView) }
        NSApp.sendAction(action, to: view.textView, from: nil)
        refreshEditingTextFormatting()
    }

    /// Sets the point size of the text being edited, from the formatting bar's size
    /// field (a typed value or a scroll step). With nothing being edited it sets the
    /// default for new text, so the field is never a dead control.
    public func setEditingTextFontSize(_ size: Double) {
        guard size.isFinite else { return }
        let range = CanvasSettings.fontSizeRange
        let clamped = min(max(size, range.lowerBound), range.upperBound)
        guard let view = activeEditView else {
            settings.defaultFontSize = clamped
            return
        }
        view.textView.setEditingFontSize(CGFloat(clamped))
        refreshEditingTextFormatting()
    }

    /// Mirror the caret's paragraph style, point size, traits and alignment into
    /// `settings`, so the formatting bar's controls track the text being edited.
    func refreshEditingTextFormatting() {
        guard let view = activeEditView else {
            settings.editingTextStyle = nil
            settings.editingFontSize = nil
            settings.editingIsBold = false
            settings.editingIsItalic = false
            settings.editingIsUnderline = false
            settings.editingAlignment = .natural
            return
        }
        let storage = view.textStorage
        let range = view.textView.selectedRange()
        // The selection's first character, or the typing attributes at a bare caret.
        let attributes = range.length > 0 && range.location < storage.length
            ? storage.attributes(at: range.location, effectiveRange: nil)
            : view.textView.typingAttributes
        let font = attributes[.font] as? NSFont
        settings.editingTextStyle = TextFormatting.paragraphStyleKind(for: font, base: CGFloat(settings.defaultFontSize))
        settings.editingFontSize = Double(font?.pointSize ?? CGFloat(settings.defaultFontSize))
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        settings.editingIsBold = traits.contains(.bold)
        settings.editingIsItalic = traits.contains(.italic)
        settings.editingIsUnderline = ((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        settings.editingAlignment = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
    }

    /// Window resigned key: keep editing if focus just moved to a sheet or the font panel.
    private func finishEditingIfWindowInactive() {
        guard session != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session != nil, let window = self.window, !window.isKeyWindow else { return }
            if window.attachedSheet != nil || NSApp.keyWindow is NSFontPanel { return }
            self.finishEditing(restoreFocus: false)
        }
    }

    // MARK: Cursors

    public override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: currentCursor())
    }

    func currentCursor() -> NSCursor {
        if settings.isToolMenuPresented {
            // The ring is the eraser's width readout. Keep it under the pointer while the
            // hold-to-adjust-width gesture is active, so scrolling shows the new size
            // instead of the ring vanishing into the arrow.
            return inputTool == .eraser && widthKeyHeld ? eraserCursor() : .arrow
        }

        // The floating toolbar uses the same dot-to-arrow transition for every tool.
        // Keep the eraser ring on the canvas, but let toolbar hover select its own cursor.
        if toolbarHovered { return Cursors.canvasToArrow[cursorFrame] }

        // A ring the size of the eraser disc, so its reach is visible before erasing.
        if inputTool == .eraser { return eraserCursor() }

        // Resize arrows over a corner handle, and for the whole of a resize drag.
        if settings.tool == .pointer, selection.canResize, #available(macOS 15.0, *) {
            var corner: SelectionController.Corner?
            if case .resizing(let c, _, _) = selection.drag {
                corner = c
            } else if case .idle = selection.drag, let window {
                let point = viewToWorld(convert(window.mouseLocationOutsideOfEventStream, from: nil))
                corner = selection.corner(at: point, radius: Double(Self.hitRadius / magnification))
            }
            switch corner {
            case .topLeft?: return .frameResize(position: .topLeft, directions: .all)
            case .topRight?: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft?: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight?: return .frameResize(position: .bottomRight, directions: .all)
            case .top?: return .frameResize(position: .top, directions: .all)
            case .bottom?: return .frameResize(position: .bottom, directions: .all)
            case .left?: return .frameResize(position: .left, directions: .all)
            case .right?: return .frameResize(position: .right, directions: .all)
            case nil: break
            }
        }

        if cursorFrame == 0 { return Cursors.canvasToIBeam[textCursorFrame] }
        return Cursors.canvasToArrow[cursorFrame]
    }

    /// Cursor updates must not overwrite the native cursor of an overlapping control.
    /// Text views are part of the canvas; the equation editor keeps its own cursor.
    private var pointerIsOverCanvas: Bool {
        guard let window, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let hit = content.hitTest(point) else { return false }
        if hit === self { return true }
        if let editor = activeEquationEditor, hit.isDescendant(of: editor) { return false }
        return hit.isDescendant(of: self)
    }

    /// Within `radius` view points of a laid-out text line (or anywhere in a box being edited).
    func pointNearText(_ point: NSPoint, radius: CGFloat = 12) -> Bool {
        for view in textViews.values where view.superview === self {
            guard view.frame.insetBy(dx: -radius, dy: -radius).contains(point) else { continue }
            if view.isEditing, view !== documentBodyView { return true }
            let textView = view.textView
            guard let manager = textView.layoutManager, let container = textView.textContainer,
                  textView.textStorage?.length ?? 0 > 0 else { continue }
            let origin = textView.textContainerOrigin
            let probe = textView.convert(NSRect(x: point.x - radius, y: point.y - radius,
                                                width: radius * 2, height: radius * 2), from: self)
                .offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = manager.glyphRange(forBoundingRect: probe, in: container)
            guard glyphs.length > 0 else { continue }
            var near = false
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, stop in
                if used.width > 0, used.intersects(probe) { near = true; stop.pointee = true }
            }
            if near { return true }
        }
        return false
    }

    /// Eraser disc radius on screen: the chosen pen width, scaled by zoom.
    private var eraserScreenRadius: CGFloat { CGFloat(max(settings.width, 0.5) / 2) * magnification }

    /// The eraser ring for the current animated radius, cached per whole size.
    private func eraserCursor() -> NSCursor {
        let radius = eraserCursorRadius > 0 ? eraserCursorRadius : eraserScreenRadius
        let key = max(1, Int((radius * 2).rounded()))
        if let hit = eraserCursorCache[key] { return hit }
        let cursor = Cursors.eraser(radius: radius)
        if eraserCursorCache.count > 240 { eraserCursorCache.removeAll() }
        eraserCursorCache[key] = cursor
        return cursor
    }

    /// Ease the eraser ring toward the current width so it grows and shrinks
    /// smoothly instead of snapping when the pen width changes.
    private func updateEraserCursor() {
        eraserCursorTarget = eraserScreenRadius
        guard inputTool == .eraser else {
            eraserCursorAnimation?.invalidate()
            eraserCursorAnimation = nil
            return
        }
        if eraserCursorRadius == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            eraserCursorRadius = eraserCursorTarget
            eraserCursorAnimation?.invalidate()
            eraserCursorAnimation = nil
            return
        }
        guard eraserCursorRadius != eraserCursorTarget, eraserCursorAnimation == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let diff = self.eraserCursorTarget - self.eraserCursorRadius
            if abs(diff) < 0.15 { self.eraserCursorRadius = self.eraserCursorTarget }
            else { self.eraserCursorRadius += diff * 0.35 }
            if !self.cursorLock.isLocked, self.pointerIsOverCanvas { self.currentCursor().set() }
            self.window?.invalidateCursorRects(for: self)
            if self.eraserCursorRadius == self.eraserCursorTarget {
                timer.invalidate()
                self.eraserCursorAnimation = nil
            }
        }
        eraserCursorAnimation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Morph between the canvas dot and the I-beam as the pointer nears or leaves text.
    private func animateTextCursor(near: Bool) {
        let target = near ? Cursors.canvasToIBeam.count - 1 : 0
        guard target != textCursorTarget || (textCursorAnimation == nil && textCursorFrame != target) else { return }
        textCursorTarget = target
        textCursorAnimation?.invalidate()
        textCursorAnimation = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            textCursorFrame = target
            return currentCursor().set()
        }
        let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if self.textCursorFrame != target { self.textCursorFrame += self.textCursorFrame < target ? 1 : -1 }
            if !self.cursorLock.isLocked, self.pointerIsOverCanvas, case .none = self.gesture { self.currentCursor().set() }
            if self.textCursorFrame == target {
                timer.invalidate()
                self.textCursorAnimation = nil
                self.window?.invalidateCursorRects(for: self)
            }
        }
        textCursorAnimation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Called by the floating toolbar; native cursor frames also work over SwiftUI controls.
    public func setToolbarHovered(_ hovered: Bool) {
        guard toolbarHovered != hovered else { return }
        toolbarHovered = hovered
        cursorAnimation?.invalidate()
        cursorAnimation = nil
        let target = hovered ? Cursors.canvasToArrow.count - 1 : 0
        guard !cursorLock.isLocked else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cursorFrame = target
            currentCursor().set()
            return
        }
        let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] timer in
            guard let self, let window = self.window, window.isKeyWindow,
                  window.frame.contains(NSEvent.mouseLocation),
                  !self.cursorLock.isLocked,
                  hovered || self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else {
                timer.invalidate()
                return
            }
            if !hovered, !self.pointerIsOverCanvas {
                timer.invalidate()
                self.cursorAnimation = nil
                self.cursorFrame = 0
                return
            }
            if self.cursorFrame != target { self.cursorFrame += self.cursorFrame < target ? 1 : -1 }
            self.currentCursor().set()
            if self.cursorFrame == target {
                timer.invalidate()
                self.cursorAnimation = nil
                window.invalidateCursorRects(for: self)
            }
        }
        cursorAnimation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateCursor() {
        guard let window else { return }
        updateEraserCursor()
        window.invalidateCursorRects(for: self)
        if layout == .document, let body = documentBodyView { window.invalidateCursorRects(for: body.textView) }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        var idle = false
        if case .none = gesture { idle = true }
        let overCanvas = visibleRect.contains(mouse) && pointerIsOverCanvas
        animateTextCursor(near: overCanvas && idle && !cursorLock.isLocked && !penKeyMonitor.isPenDown
                          && !toolbarHovered && pointNearText(mouse))
        if overCanvas, idle { currentCursor().set() }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        #if DEBUG
        if isCapturingGlyphs {
            if event.keyCode == PenKeyMonitor.escapeKeyCode { stopGlyphCapture(); return }
            if event.keyCode == Self.deleteKeyCode || event.keyCode == Self.leftArrowKeyCode {
                if !tabletSource.isDrawing { discardPendingLetter(); updateGlyphCapturePrompt() }
                return
            }
            // Allow the pen key, swallow ordinary editing and navigation shortcuts.
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return }
            if penKeyMonitor.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat) { return }
            return
        }
        #endif
        if settings.isToolMenuPresented, event.keyCode == PenKeyMonitor.escapeKeyCode {
            settings.toolMenu = nil
            return
        }
        if event.keyCode == PenKeyMonitor.escapeKeyCode, activeEquationEditor != nil {
            exitMathEditing()
            return
        }
        if event.keyCode == PenKeyMonitor.escapeKeyCode, !settings.find.isVisible {
            penKeyMonitor.cancel()
            cancelGesture()
            clearSelection()
            if activeMode.usesTabletInput { settings.inputMode = .pen }
            // Leaving Writing mode (or any drawing tool) lands on the selector.
            settings.tool = .pointer
            return
        }
        if !settings.isToolMenuPresented, !widthKeyHeld,
           !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
           penKeyMonitor.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat) {
            return
        }
        if event.keyCode == PenKeyMonitor.escapeKeyCode, settings.find.isVisible, case .none = gesture {
            hideFind()
            return
        }
        if handleWritingKey(event) { return }
        if handleSelectionKey(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .function])
        guard modifiers.isEmpty, performShortcut(event) else {
            super.keyDown(with: event)
            return
        }
    }

    /// The single-key tool and mode shortcuts. In a document's Text tool they
    /// are reached by holding the pen key (see `installDocumentEventMonitor`).
    /// Returns false if `event` isn't one.
    static let shortcutKeys: Set<String> = ["q", "w", "e", "1", "2", "3", "4", "[", "]"]

    func performShortcut(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers else { return false }
        switch key {
        case "1": settings.selectTool(.pointer)
        case "2": settings.toggleTool(.pen)
        case "3": settings.toggleTool(.eraser)
        case "4":
            if !event.isARepeat { settings.toggleWritingMode() }
        case "q" where session == nil:
            if !event.isARepeat { settings.isTextOptionsOpen.toggle() }
        case "w" where session == nil:
            if !event.isARepeat { settings.toggleToolMenu(.color) }
        case "e" where session == nil:
            guard !event.isARepeat else { return true }
            let opened = settings.toolMenu != .width
            settings.toggleToolMenu(.width)
            widthKeyHeld = true
            widthScrolled = false
            widthMenuOpenedByHold = opened
            refreshWidthCursor()
        case "[": settings.width = Self.clampWidth(settings.width * 0.8)
        case "]": settings.width = Self.clampWidth(settings.width * 1.25)
        default: return false
        }
        return true
    }

    public override func keyUp(with event: NSEvent) {
        if releaseWidthKey(event) { return }
        if penKeyMonitor.keyUp(keyCode: event.keyCode) { return }
        super.keyUp(with: event)
    }

    /// Consumed before navigation, including when the pointer is over a menu.
    func handleWidthScroll(_ event: NSEvent) -> Bool {
        guard widthKeyHeld else { return false }
        // Consume horizontal and momentum events too, so a width gesture never pans.
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            settings.adjustWidthForScroll(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
            widthScrolled = true
            refreshWidthCursor()
        }
        return true
    }

    /// While the eraser is active its ring is the width readout, so resize it live
    /// during a hold-and-scroll adjustment instead of waiting for the next mouse move.
    private func refreshWidthCursor() {
        guard inputTool == .eraser else { return }
        updateEraserCursor()
        window?.invalidateCursorRects(for: self)
        if !cursorLock.isLocked, pointerIsOverCanvas { currentCursor().set() }
    }

    private func releaseWidthKey(_ event: NSEvent) -> Bool {
        guard widthKeyHeld, event.keyCode == 14 || event.charactersIgnoringModifiers?.lowercased() == "e" else { return false }
        let close = widthScrolled && widthMenuOpenedByHold && settings.toolMenu == .width
        widthKeyHeld = false
        widthScrolled = false
        widthMenuOpenedByHold = false
        if close { settings.toolMenu = nil }
        return true
    }

    public override func flagsChanged(with event: NSEvent) {
        guard !settings.isToolMenuPresented, !widthKeyHeld else { return }
        let flags = event.modifierFlags
        penKeyMonitor.flagsChanged(option: flags.contains(.option), function: flags.contains(.function))
        super.flagsChanged(with: event)
    }

    /// Esc, Delete / Forward Delete and arrow nudges (Shift: 10 pt) for the selection.
    private func handleSelectionKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == PenKeyMonitor.escapeKeyCode {
            if case .select = gesture {
                cancelGesture()
                return true
            }
            guard !selection.selection.isEmpty else { return false }
            selection.clear()
            return true
        }
        guard !selection.selection.isEmpty, case .none = gesture else {
            // ⌘A in a document selects the body text too: Delete clears it as one step,
            // even when no ink is selected.
            if [Self.deleteKeyCode, Self.forwardDeleteKeyCode].contains(event.keyCode),
               documentTextIsFullySelected, case .none = gesture {
                deleteSelection()
                return true
            }
            return false
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case Self.deleteKeyCode, Self.forwardDeleteKeyCode: deleteSelection()
        case Self.leftArrowKeyCode: selection.nudge(by: CGVector(dx: -step, dy: 0))
        case Self.rightArrowKeyCode: selection.nudge(by: CGVector(dx: step, dy: 0))
        case Self.upArrowKeyCode: selection.nudge(by: CGVector(dx: 0, dy: -step))
        case Self.downArrowKeyCode: selection.nudge(by: CGVector(dx: 0, dy: step))
        default: return false
        }
        return true
    }

    private static let tabKeyCode: UInt16 = 48
    private static let returnKeyCode: UInt16 = 36
    private static let enterKeyCode: UInt16 = 76
    private static let deleteKeyCode: UInt16 = 51
    private static let forwardDeleteKeyCode: UInt16 = 117
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126
    private static let slashKeyCode: UInt16 = 44

    static func clampWidth(_ w: Double) -> Double { min(max(w, CanvasSettings.widthRange.lowerBound), CanvasSettings.widthRange.upperBound) }

    // MARK: Undo and edit actions

    /// Undo/redo first abort any in-progress gesture so it can't commit on top.
    /// In Write mode an uncommitted letter is undone first, without touching the model.
    @objc func undo(_ sender: Any?) {
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        cancelGesture()
        if activeMode == .scribe, !writtenLetters.isEmpty { return discardScribeLine() }
        if !pendingLetter.isEmpty { return discardPendingLetter() }
        if activeMode == .scribe, scribeQueue.dropLastPendingLine() { return }
        if activeMode == .scribe, scribeQueue.dropLast() { return }
        model.undoManager.undo()
        pruneSelection()
    }

    /// Undo the visible, uncommitted Scribe line before touching the model's undo stack.
    private func discardScribeLine() {
        wordWork?.cancel()
        wordWork = nil
        let first = writtenLetters.first
        writtenLetters = []
        if !pendingLetter.isEmpty { discardPendingLetter() }
        scribeLiveResult = nil
        scribeLiveDirty = false
        writingPanel?.bufferedStrokes = []
        if let first, let cell = writingCell { setWritingCell(Self.cell(cell, at: first.before)) }
        setScribeProvisional(nil)
    }

    @objc func redo(_ sender: Any?) {
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        cancelGesture()
        model.undoManager.redo()
        pruneSelection()
    }

    /// Selects every object, switching to the Pointer tool (except in documents).
    /// In documents, selects all text and strokes without changing the tool.
    @objc public override func selectAll(_ sender: Any?) {
        cancelGesture()
        if layout == .document {
            selectAllDocumentContent()
        } else {
            if settings.tool != .pointer { settings.tool = .pointer }
            selection.selectAll()
        }
    }

    @objc public func delete(_ sender: Any?) {
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        guard case .none = gesture else { return }
        deleteSelection()
    }

    /// True when the document body's whole text is selected (⌘A), with or without ink.
    private var documentTextIsFullySelected: Bool {
        guard layout == .document, model.effectiveLayout == .document, let body = documentBodyView else { return false }
        let range = body.textView.selectedRange()
        return range.length > 0 && range.length == body.textStorage.length
    }

    /// Deletes the selection; written letters it removes are forgotten (undoably),
    /// and the write cursor moves back if the trailing letters went.
    /// In documents, if the entire text is selected and strokes are selected, both are deleted.
    private func deleteSelection() {
        let fullTextSelected = documentTextIsFullySelected
        guard !selection.selection.isEmpty || fullTextSelected else { return }
        if writingCell != nil { registerWritingUndo() }

        // In documents, handle deletion of both text and strokes together.
        if fullTextSelected {
            deleteDocumentTextAndStrokes()
            reconcileWrittenLetters()
            return
        }

        selection.deleteSelection()
        reconcileWrittenLetters()
    }

    /// Delete the full text selection and selected strokes as one undo step.
    private func deleteDocumentTextAndStrokes() {
        guard layout == .document, let body = documentBodyView else { return }
        let textRange = body.textView.selectedRange()
        // Capture first: deleting the text changes the text selection, which clears the ink selection.
        let strokeIDs = selection.selection
        if textRange.length == 0 && strokeIDs.isEmpty { return }

        model.undoManager.beginUndoGrouping()
        defer { model.undoManager.endUndoGrouping() }
        selection.clear()
        if !strokeIDs.isEmpty { model.remove(ids: strokeIDs, actionName: "Delete") }
        if textRange.length > 0 { body.textView.deleteBackward(self) }
    }

    @objc public func bringToFront(_ sender: Any?) {
        guard layout == .canvas else { return }
        guard case .none = gesture else { return }
        selection.bringToFront()
    }

    @objc public func sendToBack(_ sender: Any?) {
        guard layout == .canvas else { return }
        guard case .none = gesture else { return }
        selection.sendToBack()
    }

    // MARK: Find
    //
    // The Find bar (SwiftUI, `settings.find`) holds the query; this view finds
    // matches (typed text now, handwriting via the indexer's cache), draws the
    // highlights and scrolls to the current one.

    private func bindFind() {
        let find = settings.find
        find.isVisible = false
        find.query = ""
        find.$query
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.runFind(scroll: true) }
            .store(in: &cancellables)
    }

    /// Show the bar (⌘F) and focus its field.
    public func showFind() {
        let find = settings.find
        find.isVisible = true
        find.focusToken += 1
        if !find.query.isEmpty, findMatches.isEmpty { runFind(scroll: true) }
    }

    /// Close the bar (Esc) and clear highlights.
    public func hideFind() {
        findTask?.cancel()
        refindWork?.cancel()
        settings.find.isVisible = false
        settings.find.isSearching = false
        setFindMatches([], index: 0)
        searchedQuery = ""
        window?.makeFirstResponder(self)
    }

    public func findNext() { stepFind(1) }
    public func findPrevious() { stepFind(-1) }

    private func stepFind(_ delta: Int) {
        guard settings.find.isVisible else { return showFind() }
        // A search is pending (typing, or ink still being read): run it now instead of stepping.
        if settings.find.query != searchedQuery { return runFind(scroll: true) }
        guard !findMatches.isEmpty else { return }
        let n = findMatches.count
        setFindMatches(findMatches, index: ((findIndex + delta) % n + n) % n)
        revealCurrentMatch()
    }

    private func scheduleRefind() {
        guard settings.find.isVisible, !searchedQuery.isEmpty else { return }
        refindWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runFind(scroll: false) }
        refindWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Typed matches show at once; handwriting matches follow once the indexer is current.
    private func runFind(scroll: Bool) {
        syncDocumentBody()
        findTask?.cancel()
        refindWork?.cancel()
        let find = settings.find
        let query = find.query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchedQuery = find.query
        guard find.isVisible, !query.isEmpty else {
            find.isSearching = false
            return setFindMatches([], index: 0)
        }
        let typed = refinedTextMatches(FindMatches.text(query, in: model.textBlocks))
        let indexer = handwritingIndexer
        let recognizer = indexer?.recognizer
        if recognizer == nil || indexer == nil {
            find.isSearching = false
            return applyFindMatches(FindMatches.ordered(typed), scroll: scroll)
        }
        find.isSearching = true
        applyFindMatches(FindMatches.ordered(typed), scroll: scroll)
        findTask = Task { @MainActor [weak self] in
            await indexer?.flushNow()
            guard !Task.isCancelled, let self else { return }
            let ink = await FindMatches.ink(query, cache: indexer?.cache, strokes: self.model.strokes, recognizer: recognizer)
            guard !Task.isCancelled else { return }
            self.settings.find.isSearching = false
            self.syncDocumentBody()
            let typed = self.refinedTextMatches(FindMatches.text(query, in: self.model.textBlocks))
            self.applyFindMatches(FindMatches.ordered(typed + ink), scroll: scroll)
        }
    }

    /// Install `matches`, keeping the current index (clamped); scroll when the current match changed.
    private func applyFindMatches(_ matches: [FindMatch], scroll: Bool) {
        let before = findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil
        let index = before == nil ? 0 : min(findIndex, max(matches.count - 1, 0))
        setFindMatches(matches, index: index)
        if scroll, !matches.isEmpty, matches[index] != before { revealCurrentMatch() }
    }

    private func setFindMatches(_ matches: [FindMatch], index: Int) {
        for m in findMatches + matches { setNeedsDisplay(world: m.bounds) }
        findMatches = matches
        findIndex = index
        settings.find.count = matches.count
        settings.find.index = index
    }

    /// Typed matches narrowed from their block to the matched substring.
    private func refinedTextMatches(_ matches: [FindMatch]) -> [FindMatch] {
        matches.map { match in
            guard case .text(let id, let range) = match.kind, let block = model.textBlock(id: id),
                  let view = textViews[id], let layout = view.textView.layoutManager,
                  let container = view.textView.textContainer else { return match }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            guard !rect.isEmpty else { return match }
            let inset = view.textView.textContainerOrigin
            rect = rect.offsetBy(dx: inset.x, dy: inset.y)
            let s = CGFloat(block.scale)
            var refined = match
            refined.bounds = CGRect(x: block.origin.x + rect.minX * s, y: block.origin.y + rect.minY * s,
                                    width: rect.width * s, height: rect.height * s)
            return refined
        }
    }

    /// Center the current match if it isn't fully visible; zoom is unchanged.
    private func revealCurrentMatch() {
        guard findMatches.indices.contains(findIndex), let scrollView = enclosingScrollView as? CanvasScrollView else { return }
        let bounds = findMatches[findIndex].bounds
        guard !worldRect(for: visibleRect).contains(bounds) else { return }
        if layout == .document {
            scrollView.centerOnDocument(worldY: bounds.midY)
        } else {
            scrollView.centerOn(world: CGPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    private func drawFindHighlights(in ctx: CGContext, world: CGRect) {
        guard settings.find.isVisible, !findMatches.isEmpty else { return }
        let m = magnification
        let pad = 2 / m
        for (i, match) in findMatches.enumerated() {
            let r = match.bounds.insetBy(dx: -pad, dy: -pad)
            guard r.intersects(world) else { continue }
            let path = CGPath(roundedRect: r, cornerWidth: 3 / m, cornerHeight: 3 / m, transform: nil)
            ctx.addPath(path)
            if i == findIndex {
                ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.4).cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(2 / m)
                ctx.strokePath()
            } else {
                ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.3).cgColor)
                ctx.fillPath()
            }
        }
    }

    // MARK: Convert to Text

    private var hasRecognizer: Bool { HandwritingRecognizers.system() != nil }

    private var canConvertToText: Bool {
        convertTask == nil && hasRecognizer && model.strokes.contains { selection.selection.contains($0.id) }
    }

    private func updateCanConvert() {
        let can = canConvertToText
        if settings.canConvertToText != can { settings.canConvertToText = can }
    }

    /// Recognizes the selected ink line by line in one undo step. Beeps and
    /// changes nothing if no text is recognized or the strokes changed meanwhile.
    @objc public func convertToText(_ sender: Any?) {
        guard case .none = gesture, canConvertToText, let recognizer = HandwritingRecognizers.system() else { return }
        finishEditing()
        let ids = Set(model.strokes.map(\.id)).intersection(selection.selection)
        let strokes = model.strokes.filter { ids.contains($0.id) }
        let cached = Dictionary(handwritingIndexer?.cache?.lines.map { ($0.digest, $0.text) } ?? [],
                                uniquingKeysWith: { a, _ in a })
        convertTask = Task { @MainActor [weak self] in
            let lines = await Task.detached(priority: .userInitiated) {
                let byID = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
                return HandwritingLines.group(strokes).map { line in
                    let lineStrokes = line.strokeIDs.compactMap { byID[$0] }
                    return (line: line, strokes: lineStrokes, digest: HandwritingCache.digest(of: lineStrokes))
                }
            }.value
            var texts: [String] = []
            for item in lines {
                guard !Task.isCancelled else { break }
                var text = cached[item.digest]
                if text == nil { text = await recognizer.text(for: item.strokes) }
                let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts.append(trimmed) }
            }
            self?.finishConvert(ids: ids, lines: lines.map(\.line), texts: texts)
        }
        updateCanConvert()
    }

    private func finishConvert(ids: Set<UUID>, lines: [HandwritingLine], texts: [String]) {
        convertTask = nil
        defer { updateCanConvert() }
        // Abort if the strokes changed while recognizing.
        let live = Set(model.strokes.map(\.id))
        guard ids.isSubset(of: live) else { return }
        guard !texts.isEmpty else { return NSSound.beep() }

        let ink = lines.reduce(CGRect.null) { $0.union($1.bounds) }
        let heights = lines.map(\.bounds.height).sorted()
        let size = min(max((heights[heights.count / 2] * 0.7).rounded(), 9), 72)
        var attributes = settings.defaultTextAttributes
        attributes[.font] = NSFont.systemFont(ofSize: size)
        let recognizedText = NSAttributedString(string: texts.joined(separator: "\n"), attributes: attributes)

        if layout == .document, let body = documentBodyView {
            syncDocumentBody()
            let (insertedText, anchorIndex) = documentConvertedText(recognizedText, forInk: ids)
            model.undoManager.beginUndoGrouping()
            let inserted = insertDocumentText(insertedText, at: anchorIndex, actionName: "Convert to Text")
            if inserted { model.remove(ids: ids, actionName: "Convert to Text") }
            model.undoManager.setActionName("Convert to Text")
            model.undoManager.endUndoGrouping()
            guard inserted else { return }
            selection.clear()
            window?.makeFirstResponder(body.textView)
            return
        }

        let content = TextBlock.content(from: recognizedText)
        let block = TextBlock(origin: ink.origin, width: max(ink.width, TextBlock.minWidth), content: content)

        if settings.tool != .pointer { settings.tool = .pointer }
        model.undoManager.beginUndoGrouping()
        if writingCell != nil { registerWritingUndo() }
        model.replace(strokeIDs: ids, with: block, actionName: "Convert to Text")
        model.undoManager.endUndoGrouping()
        reconcileWrittenLetters()
        selection.select([block.id])
    }

    // MARK: Clipboard

    /// Repeated pastes of the same pasteboard contents step further down-right.
    private var pasteChain: (changeCount: Int, count: Int)?

    @objc public func copy(_ sender: Any?) {
        guard case .none = gesture else { return }

        // In documents, copy both text and strokes if available
        if layout == .document, let body = documentBodyView {
            let textRange = body.textView.selectedRange()
            let hasText = textRange.length > 0
            let hasStrokes = !selection.selection.isEmpty

            if !hasText && !hasStrokes { return }

            var payload = ClipboardPayload()
            if hasText {
                let selectedText = body.textStorage.attributedSubstring(from: textRange)
                let block = TextBlock(id: UUID(), origin: .zero, width: Double(body.frame.width),
                                     content: TextBlock.content(from: NSMutableAttributedString(attributedString: selectedText)), scale: 1)
                payload.textBlocks = [block]
            }
            if hasStrokes {
                payload.strokes = model.strokes.filter { selection.selection.contains($0.id) }
            }
            payload.write(to: .general)
            pasteChain = (NSPasteboard.general.changeCount, 0)
            return
        }

        guard !selection.selection.isEmpty else { return }
        ClipboardPayload(model: model, ids: selection.selection).write(to: .general)
        pasteChain = (NSPasteboard.general.changeCount, 0)
    }

    @objc public func cut(_ sender: Any?) {
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        guard case .none = gesture else { return }

        // In documents, cut both text and strokes if both are selected
        if layout == .document, let body = documentBodyView {
            let textRange = body.textView.selectedRange()
            let hasText = textRange.length > 0
            let hasStrokes = !selection.selection.isEmpty

            if !hasText && !hasStrokes { return }

            copy(sender)

            model.undoManager.beginUndoGrouping()
            defer { model.undoManager.endUndoGrouping() }

            if hasText {
                body.textView.deleteBackward(self)
            }
            if hasStrokes {
                deleteSelection()
            }
            model.undoManager.setActionName("Cut")
            return
        }

        guard !selection.selection.isEmpty else { return }
        copy(sender)
        deleteSelection()
        model.undoManager.setActionName("Cut")
    }

    /// Pastes where the copied objects sit (stepped) while they're on screen,
    /// otherwise centered in the visible region.
    @objc public func paste(_ sender: Any?) {
        #if DEBUG
        if isCapturingGlyphs { return }
        #endif
        guard case .none = gesture else { return }
        if layout == .document {
            _ = pasteDocumentCanvasObjects()
            return
        }
        guard let payload = ClipboardPayload.read(from: .general), !payload.isEmpty else { return }
        let pb = NSPasteboard.general
        var count = pasteChain?.changeCount == pb.changeCount ? pasteChain!.count : 0
        let visible = worldRect(for: visibleRect)
        let delta: CGVector
        if payload.bounds.intersects(visible) {
            count += 1
            let o = ClipboardPayload.duplicateOffset
            delta = CGVector(dx: o.dx * CGFloat(count), dy: o.dy * CGFloat(count))
        } else {
            delta = CGVector(dx: visible.midX - payload.bounds.midX, dy: visible.midY - payload.bounds.midY)
        }
        pasteChain = (pb.changeCount, count)
        insertAndSelect(payload, offsetBy: delta, actionName: "Paste")
    }

    /// Canvas text blocks become formatted body text; pasted strokes stay ink.
    @discardableResult
    private func pasteDocumentCanvasObjects() -> Bool {
        guard layout == .document, case .none = gesture else { return false }
        let payload = ClipboardPayload.read(from: .general)
        if payload == nil, let plainText = NSPasteboard.general.string(forType: .string) {
            return insertDocumentText(NSAttributedString(string: plainText), actionName: "Paste")
        }
        guard let payload, !payload.isEmpty else { return false }

        let text = payload.attributedText
        let ink = ClipboardPayload(strokes: payload.strokes)
        let group = text.map { $0.length > 0 } == true && !ink.strokes.isEmpty
        if group { model.undoManager.beginUndoGrouping() }
        var handled = false
        if let text, text.length > 0 {
            handled = insertDocumentText(text, actionName: "Paste")
        }
        if !ink.strokes.isEmpty {
            finishEditing()
            if settings.tool != .pointer { settings.tool = .pointer }
            let visible = worldRect(for: visibleRect)
            var count = pasteChain?.changeCount == NSPasteboard.general.changeCount ? pasteChain!.count : 0
            let delta: CGVector
            if ink.bounds.intersects(visible) {
                count += 1
                let offset = ClipboardPayload.duplicateOffset
                delta = CGVector(dx: offset.dx * CGFloat(count), dy: offset.dy * CGFloat(count))
            } else {
                delta = CGVector(dx: visible.midX - ink.bounds.midX, dy: visible.midY - ink.bounds.midY)
            }
            pasteChain = (NSPasteboard.general.changeCount, count)
            selection.select(model.paste(ink, offsetBy: delta, actionName: "Paste"))
            handled = true
        }
        if group {
            model.undoManager.setActionName("Paste")
            model.undoManager.endUndoGrouping()
        }
        return handled
    }

    @objc public func duplicate(_ sender: Any?) {
        guard case .none = gesture, !selection.selection.isEmpty else { return }
        insertAndSelect(ClipboardPayload(model: model, ids: selection.selection),
                        offsetBy: ClipboardPayload.duplicateOffset, actionName: "Duplicate")
    }

    private func insertAndSelect(_ payload: ClipboardPayload, offsetBy delta: CGVector, actionName: String) {
        finishEditing()
        if settings.tool != .pointer { settings.tool = .pointer }
        let ids = model.paste(payload, offsetBy: delta, actionName: actionName)
        selection.select(ids)
    }

    private var hasObjects: Bool { !model.strokes.isEmpty || !model.textBlocks.isEmpty }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if !pendingLetter.isEmpty {
                item.title = model.undoManager.undoMenuTitle(forUndoActionName: "Write")
                return true
            }
            item.title = model.undoManager.undoMenuItemTitle
            return model.undoManager.canUndo
        case #selector(redo(_:)):
            item.title = model.undoManager.redoMenuItemTitle
            return model.undoManager.canRedo
        case #selector(selectAll(_:)):
            return hasObjects
        case #selector(paste(_:)):
            return NSPasteboard.general.availableType(from: [ClipboardPayload.pasteboardType]) != nil
        case #selector(convertToText(_:)):
            return canConvertToText
        case #selector(bringToFront(_:)), #selector(sendToBack(_:)):
            return layout == .canvas && !selection.selection.isEmpty
        case #selector(delete(_:)), #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)):
            return !selection.selection.isEmpty
        default:
            return true
        }
    }
}

/// Forwards pen events to the tool controller, letting the view see each event first.
private final class PenEventTap: PenEventSink {
    weak var target: PenEventSink?
    var willHandle: ((PenEvent) -> Void)?

    func handle(_ event: PenEvent) {
        willHandle?(event)
        target?.handle(event)
    }
}
