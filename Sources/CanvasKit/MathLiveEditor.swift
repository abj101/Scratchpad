import AppKit
import WebKit

/// Origin of an edit reported by the embedded MathLive field.
enum MathLiveEditOrigin: String { case keyboard, handwriting, handwritingRevision }

/// The end of a live field a key pressed against the equation in the note enters at.
enum MathLiveFieldEdge: String { case start, end }

struct MathLiveHandwritingEdit {
    let id: UUID
    let latex: String
    var role: MathScript.Role
    var replaces: [UUID]
    var isFraction: Bool
    var operandIDs: [UUID]
    var removedParenthesisIDs: [UUID]
    var coalescesUndo: Bool
    /// Spawns a MathLive structure instead of inserting `latex`: a structure name from
    /// `MathStructure.Kind` (`sum`, `int`, `lim`, `abs`, `sqrt`, `root`). For `root`, `latex` is
    /// the index symbol to write into the root at the caret.
    var structure: String?
    init(id: UUID, latex: String, role: MathScript.Role = .body, replaces: [UUID] = [],
         isFraction: Bool = false, operandIDs: [UUID] = [], removedParenthesisIDs: [UUID] = [],
         coalescesUndo: Bool = false, structure: String? = nil) {
        self.id = id; self.latex = latex; self.role = role; self.replaces = replaces
        self.isFraction = isFraction; self.operandIDs = operandIDs; self.removedParenthesisIDs = removedParenthesisIDs
        self.coalescesUndo = coalescesUndo; self.structure = structure
    }
}

/// A local, offline MathLive 0.111.0 field. CanvasView owns persistence and undo.
final class MathLiveEditorView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    var onChange: ((String, MathLiveEditOrigin) -> Void)?
    var onSelectionChange: (([[Int]]) -> Void)?
    var onExternalSelectionChange: (() -> Void)?
    var onUndo: (() -> Void)? { didSet { (webView as? MathLiveWKWebView)?.historyUndoManager.onUndo = onUndo } }
    var onRedo: (() -> Void)? { didSet { (webView as? MathLiveWKWebView)?.historyUndoManager.onRedo = onRedo } }
    var onFinish: ((Bool) -> Void)?
    var onDeleteAtStart: (() -> Void)?
    var onSizeChange: ((CGSize) -> Void)?
    /// The source the page has applied and laid out. The host keeps its static preview of
    /// an equation up until the field actually holds it, instead of revealing the field's
    /// stale contents (the previous equation, in the previous size) for a frame.
    var onLayoutApplied: ((String) -> Void)?
    private(set) var contentSize = CGSize(width: 1, height: 36)
    /// Where the math starts inside the field's own box, in text points. The field surrounds
    /// the math with its own chrome (container and content padding) while the host's static
    /// preview draws the same markup at its own padding, so the host needs this to put the
    /// live math exactly where the preview had it.
    private(set) var contentInsets = CGPoint.zero
    /// The scale the field applied to fit the room left on the line (1 when it fits).
    /// Unknown before the first layout, so layout code keeps its own estimate.
    private(set) var contentScale: CGFloat = 1
    var onFailure: ((Error) -> Void)?
    var noteUndoManager: UndoManager? { didSet { (webView as? MathLiveWKWebView)?.noteUndoManager = noteUndoManager } }
    private var pendingLatex: (String, CGFloat)?
    private var pendingScripts: [String] = []
    private var pendingFlush: [() -> Void] = []
    private(set) var latex = ""
    private(set) var fontSize: Double = Double(TextFormatting.bodySize)
    private(set) var isReady = false
    private var didFail = false
    /// The page never loaded, or its web content process died. A host that keeps one page
    /// alive across equations must replace the view instead of reusing a dead one.
    var hasFailed: Bool { didFail }

    init(latex: String = "", fontSize: CGFloat = TextFormatting.bodySize) {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        webView = MathLiveWKWebView(frame: .zero, configuration: configuration, historyUndoManager: MathLiveWKUndoManager())
        super.init(frame: .zero)
        controller.add(WeakScriptMessageHandler(self), name: "mathlive")
        (webView as? MathLiveWKWebView)?.historyUndoManager.onUndo = onUndo
        (webView as? MathLiveWKWebView)?.historyUndoManager.onRedo = onRedo
        (webView as? MathLiveWKWebView)?.onEscape = { [weak self] in self?.finishMathEquation(insertNewline: false) }
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.latex = latex
        self.fontSize = Double(fontSize)
        pendingLatex = (latex, fontSize)
        applySelectionColors()
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "MathLive") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { reportFailure(MathLiveEditorError.resourcesMissing) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.isReady, !self.didFail else { return }
            self.reportFailure(MathLiveEditorError.readinessTimeout)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    convenience init(latex: String, fontSize: Double) { self.init(latex: latex, fontSize: CGFloat(fontSize)) }

    func setLatex(_ latex: String, fontSize: CGFloat = TextFormatting.bodySize) {
        self.latex = latex
        self.fontSize = Double(fontSize)
        if !isReady { pendingLatex = (latex, fontSize); return }
        applySelectionColors()
        evaluate("window.mathLive.setLatex(\(jsString(latex)),\(fontSize))")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySelectionColors()
    }

    /// MathLive only paints its selection while the field has focus and defaults to a
    /// faint blue, so a selection made through the native commands looked invisible.
    /// Hand it the regular AppKit highlight color instead.
    private func applySelectionColors() {
        evaluate("window.mathLive.setSelectionColors(\(cssColor(NSColor.selectedContentBackgroundColor)),\(cssColor(NSColor.selectedTextColor)))")
    }
    private func cssColor(_ color: NSColor) -> String {
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        guard let c = resolved.usingColorSpace(.sRGB) else { return "\"#2878d0\"" }
        // CSS rgba() components are 0-255, not 0-1.
        return String(format: "\"rgba(%.2f,%.2f,%.2f,%.3f)\"", c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255, c.alphaComponent)
    }
    func setLatex(_ latex: String, fontSize: Double) { setLatex(latex, fontSize: CGFloat(fontSize)) }

    /// Inserts a recognized group as one source update so the model records one undo step.
    func applyHandwriting(_ edits: [MathLiveHandwritingEdit], autoCloseBrackets: Bool = false) {
        guard !edits.isEmpty else { return }
        let payload: [[String: Any]] = edits.map { [
            "id": $0.id.uuidString, "latex": $0.latex,
            "role": roleName($0.role), "replaces": $0.replaces.map(\.uuidString),
            "fraction": $0.isFraction, "operandIDs": $0.operandIDs.map(\.uuidString),
            "removedParenthesisIDs": $0.removedParenthesisIDs.map(\.uuidString),
            "coalescesUndo": $0.coalescesUndo,
            "structure": $0.structure ?? NSNull()
        ] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.mathLive.applyHandwriting(\(json),\(autoCloseBrackets))")
    }

    func replaceHandwriting(id: UUID, latex: String, role: MathScript.Role = .body) {
        applyHandwriting([MathLiveHandwritingEdit(id: id, latex: latex, role: role)])
    }

    private var maxWidth: CGFloat?
    func setMaxWidth(_ width: CGFloat) {
        guard width != maxWidth else { return }
        maxWidth = width
        evaluate("window.mathLive.setMaxWidth(\(width))")
    }
    func insertFraction() { evaluate("window.mathLive.insertFraction()") }
    func navigate(_ command: String) {
        let mapped: String
        switch command {
        case "left": mapped = "moveToPreviousChar"
        case "right": mapped = "moveToNextChar"
        case "up": mapped = "moveUp"
        case "down": mapped = "moveDown"
        case "delete": mapped = "deleteBackward"
        case "deleteForward": mapped = "deleteForward"
        case "selectAll": mapped = "selectAll"
        case "tab", "space", "advance":
            evaluate("window.mathLive.advance()")
            return
        default: return
        }
        evaluate("window.mathLive.navigate(\(jsString(mapped)))")
    }
    /// The right arrow / Tab / the panel's right zone: create a real space at the top
    /// level, or navigate when the caret is inside a fraction, delimiter, script or slot.
    /// `completion` reports whether a space was inserted, so the writing cell can advance.
    func insertMathSpace(fallbackAdvance: Bool, completion: @escaping (Bool) -> Void) {
        guard isReady, !didFail else { completion(false); return }
        let fallback = fallbackAdvance ? "advance" : "moveToNextChar"
        webView.callAsyncJavaScript("return window.mathLive.insertSpace(\(jsString(fallback)))",
                                    arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                completion((value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false)
            case .failure:
                completion(false)
            }
        }
    }
    func setSelection(_ ranges: [[Int]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ranges), let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.mathLive.setSelection(\(json))")
    }
    /// MathLive hit-tests in top-left CSS pixels, not AppKit's bottom-left web coordinates.
    /// The web view is sized by Auto Layout and is still empty the moment an equation opens,
    /// so lay it out first: converting through an empty web view sent a negative y and
    /// parked the caret before the first symbol instead of under the click.
    func focus(at point: CGPoint) {
        layoutSubtreeIfNeeded()
        let local = webView.convert(point, from: self)
        let y = webView.isFlipped ? local.y : webView.bounds.height - local.y
        evaluate("window.mathLive.focusAt(\(local.x),\(y))")
    }
    /// Puts the caret at one end of the field, entering the equation from the note.
    func focusBoundary(_ edge: MathLiveFieldEdge) {
        evaluate("window.mathLive.focusBoundary(\(jsString(edge.rawValue)))")
    }
    func requestUndo() { onUndo?() }
    func requestRedo() { onRedo?() }
    func finishMathEquation(insertNewline: Bool) { flush { [weak self] in self?.onFinish?(insertNewline) } }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            isReady = true
            if let (source, size) = pendingLatex { pendingLatex = nil; setLatex(source, fontSize: size) }
            let queued = pendingScripts; pendingScripts.removeAll()
            queued.forEach(evaluate)
            let flushes = pendingFlush; pendingFlush.removeAll()
            flushes.forEach(flush)
        case "change":
            guard let source = body["latex"] as? String,
                  let origin = MathLiveEditOrigin(rawValue: body["origin"] as? String ?? "keyboard") else { return }
            // MathLive emits delayed input events for programmatic handwriting.
            // An unchanged source is not a keyboard edit or an undo operation.
            if origin == .keyboard, source == latex { return }
            latex = source
            onChange?(source, origin)
        case "selection":
            onSelectionChange?(body["ranges"] as? [[Int]] ?? [])
            if body["external"] as? Bool == true { onExternalSelectionChange?() }
        case "size":
            guard let width = body["width"] as? Double, let height = body["height"] as? Double,
                  width.isFinite, height.isFinite, width > 0, height > 0 else { return }
            contentSize = CGSize(width: width, height: height)
            if let scale = body["scale"] as? Double, scale.isFinite, scale > 0 { contentScale = CGFloat(scale) }
            applyContentInsets(body)
            onSizeChange?(contentSize)
        case "layout":
            guard let source = body["latex"] as? String else { return }
            applyContentInsets(body)
            onLayoutApplied?(source)
        case "undo": onUndo?()
        case "redo": onRedo?()
        case "finish":
            if body["thenDelete"] as? Bool == true { flush { [weak self] in self?.onDeleteAtStart?() } }
            else { flush { [weak self] in self?.onFinish?(body["insertNewline"] as? Bool ?? false) } }
        case "failure": reportFailure(MathLiveEditorError.javascript(body["message"] as? String ?? "MathLive failed"))
        default: break
        }
    }

    private func applyContentInsets(_ body: [String: Any]) {
        guard let left = body["left"] as? Double, let top = body["top"] as? Double,
              left.isFinite, top.isFinite else { return }
        contentInsets = CGPoint(x: max(0, left), y: max(0, top))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { reportFailure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { reportFailure(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reportFailure(MathLiveEditorError.processTerminated) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }

    private func evaluate(_ javascript: String) {
        guard isReady else { pendingScripts.append(javascript); return }
        webView.evaluateJavaScript(javascript) { [weak self] _, error in if let error { self?.reportFailure(error) } }
    }
    /// Runs after all prior editor mutations and reports the final source before completion.
    func flush(completion: @escaping () -> Void) {
        if didFail { completion(); return }
        guard isReady else { pendingFlush.append(completion); return }
        webView.evaluateJavaScript("window.mathLive.latex()") { [weak self] value, error in
            if let error { self?.reportFailure(error); completion(); return }
            if let source = value as? String, source != self?.latex { self?.latex = source; self?.onChange?(source, .keyboard) }
            completion()
        }
    }
    private func reportFailure(_ error: Error) {
        guard !didFail else { return }
        didFail = true
        pendingScripts.removeAll()
        onFailure?(error)
        let flushes = pendingFlush; pendingFlush.removeAll()
        flushes.forEach { $0() }
    }
    private func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8), encoded.count >= 2 else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
    private func roleName(_ role: MathScript.Role) -> String {
        switch role { case .body: "body"; case .superscript: "superscript"; case .subscript: "subscript"; case .inherit: "inherit" }
    }
}

private final class MathLiveWKWebView: WKWebView {
    weak var noteUndoManager: UndoManager?
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    let historyUndoManager: MathLiveWKUndoManager
    init(frame: CGRect, configuration: WKWebViewConfiguration, historyUndoManager: MathLiveWKUndoManager) {
        self.historyUndoManager = historyUndoManager
        super.init(frame: frame, configuration: configuration)
        historyUndoManager.disableUndoRegistration()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    // A private manager blocks responder-chain fallback to WebKit or the window.
    // Menu undo/redo still routes explicitly into the note's history.
    override var undoManager: UndoManager? { historyUndoManager }
}

private final class MathLiveWKUndoManager: UndoManager {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    override var canUndo: Bool { onUndo != nil }
    override var canRedo: Bool { onRedo != nil }
    override func undo() { onUndo?() }
    override func redo() { onRedo?() }
}

private enum MathLiveEditorError: LocalizedError {
    case resourcesMissing, readinessTimeout, processTerminated
    case javascript(String)
    var errorDescription: String? {
        switch self {
        case .resourcesMissing: "Bundled MathLive resources are missing."
        case .readinessTimeout: "Bundled MathLive did not become ready."
        case .processTerminated: "The MathLive web content process terminated."
        case .javascript(let message): "MathLive JavaScript failed: \(message)"
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

struct MathLiveRenderedPreview {
    let pdfData: Data
    let size: CGSize
    let baseline: CGFloat?
    init(pdfData: Data, size: CGSize, baseline: CGFloat? = nil) {
        self.pdfData = pdfData; self.size = size; self.baseline = baseline
    }
    var pdf: Data { pdfData }
    var metrics: EquationPreviewMetrics {
        EquationPreviewMetrics(width: size.width, height: size.height, baseline: baseline ?? size.height * 0.8)
    }
}

/// Hidden, self-contained renderer. The note model rejects results made stale by later edits.
@MainActor final class MathLivePreviewRenderer: NSObject, WKNavigationDelegate {
    static let shared = MathLivePreviewRenderer()
    private let webView: WKWebView
    private var pending: [(String, CGFloat, (Result<MathLiveRenderedPreview, Error>) -> Void)] = []
    private var loaded = false
    private var loadError: Error?
    private var isRendering = false

    private override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 8192, height: 2048))
        super.init()
        // A transparent page background lets the PDF below keep its alpha, so a
        // selected equation shows the text view's highlight instead of a white box.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "MathLive") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { loadError = MathLiveEditorError.resourcesMissing }
    }

    func render(latex: String, fontSize: Double, completion: @escaping (Result<MathLiveRenderedPreview, Error>) -> Void) {
        if let loadError { completion(.failure(loadError)); return }
        pending.append((latex, CGFloat(fontSize), completion))
        if !loaded { DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.loaded, !self.pending.isEmpty else { return }
            self.failPending(MathLiveEditorError.readinessTimeout)
        } }
        guard loaded else { return }
        makePreview()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        makePreview()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failPending(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failPending(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failPending(MathLiveEditorError.processTerminated) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }

    private func failPending(_ error: Error) {
        loadError = error
        let callbacks = pending.map(\.2); pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }

    private func makePreview() {
        guard !isRendering, !pending.isEmpty else { return }
        isRendering = true
        let (source, size, completion) = pending.removeFirst()
        webView.callAsyncJavaScript("document.getElementById('field-container').style.display='none'; let preview=document.getElementById('preview-field'); if(!preview){preview=document.createElement('span');preview.id='preview-field';document.body.insertBefore(preview,document.getElementById('baseline'));} preview.style.display='inline-block'; preview.style.fontSize=`${size}px`; preview.style.padding=`${size * 0.2}px`; preview.innerHTML=MathLive.convertLatexToMarkup(latex); preview.getBoundingClientRect(); await Promise.race([document.fonts.ready,new Promise((_,reject)=>setTimeout(()=>reject(new Error('MathLive font timeout')),10000))]); if (!document.fonts.check(`${size}px KaTeX_Main`)) throw new Error('MathLive fonts failed to load'); const r=preview.getBoundingClientRect();const b=document.getElementById('baseline').getBoundingClientRect();if(latex.length && r.width<1)throw new Error('MathLive layout unavailable'); return {w:r.width,h:r.height,baseline:b.top-r.top};",
                                    arguments: ["latex": source, "size": Double(size)], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let dimensions = value as? [String: Any] else {
                if case .failure(let error) = result { completion(.failure(error)) }
                else { completion(.failure(MathLiveEditorError.javascript("Missing formula metrics"))) }
                self.isRendering = false; self.makePreview(); return
            }
            let width = max(1, dimensions["w"] as? Double ?? 1), height = max(1, dimensions["h"] as? Double ?? Double(size * 1.4))
            let baseline = max(0, min(height, dimensions["baseline"] as? Double ?? height * 0.8))
            let config = WKPDFConfiguration(); config.rect = CGRect(x: 0, y: 0, width: width, height: height)
            // Math is drawn into the text view, which paints the selection highlight
            // behind it; an opaque page would cover that highlight with white.
            config.allowTransparentBackground = true
            webView.createPDF(configuration: config) { [weak self] result in
                guard self != nil else { return }
                completion(result.map { MathLiveRenderedPreview(pdfData: $0, size: CGSize(width: width, height: height), baseline: baseline) })
                self?.isRendering = false
                self?.makePreview()
            }
        }
    }
}
