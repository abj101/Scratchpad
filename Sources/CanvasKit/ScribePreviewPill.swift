import AppKit

/// Scribe's floating text preview: a pill above the writing panel showing the target's
/// last words, then the word being written (live recognition) in a soft accent capsule.
/// Lives in the writing panel's own window, laid out by `WritingPanelView`; never takes events.
public final class ScribePreviewPill: NSView {
    static let height: CGFloat = 36
    /// Gap between the pill and the writing panel below it.
    static let gap: CGFloat = 10
    static let maxWidth: CGFloat = 560
    static let fontSize: CGFloat = 15
    private static let insetX: CGFloat = 18
    private static let previewPadX: CGFloat = 6

    /// The target's recent committed words.
    var context: String? { didSet { if context != oldValue { update(contextChanged: true) } } }
    /// The word being written, as it will be typed (may carry a leading space).
    var preview: String? { didSet { if preview != oldValue { update(previewChanged: true) } } }
    /// A short notice replacing the text, e.g. a failed recognition.
    var message: String? {
        didSet {
            guard message != oldValue else { return }
            update()
            if message != nil { shake() }
        }
    }

    /// Math: the model's best guesses for the last symbol, most likely first; `current` is the one shown.
    var candidates: [String] = [] { didSet { if candidates != oldValue { rebuildCandidates() } } }
    var current: String? { didSet { if current != oldValue { rebuildCandidates() } } }
    /// Called with the chosen candidate.
    var onSelect: ((String) -> Void)?
    private var candidateLayers: [CATextLayer] = []
    private var dividerLayers: [CALayer] = []
    private var hoveredCandidate: Int? { didSet { updateCandidateHover() } }

    private let font = NSFont.systemFont(ofSize: ScribePreviewPill.fontSize)
    private let contextLayer = CATextLayer()
    private let previewLayer = CATextLayer()
    private let highlightLayer = CALayer()
    private let messageLayer = CATextLayer()
    private let landingLayer = CALayer()
    /// Faded gray band behind the hovered candidate, the full pill height.
    private let hoverLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The canvas is always light; match it.
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = CanvasView.canvasColor.cgColor
        layer.borderWidth = 1
        layer.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)

        highlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        highlightLayer.opacity = 0
        landingLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        landingLayer.opacity = 0
        hoverLayer.backgroundColor = NSColor(white: 0, alpha: 0.07).cgColor
        hoverLayer.opacity = 0
        hoverLayer.actions = ["position": NSNull(), "bounds": NSNull()]
        for text in [contextLayer, previewLayer, messageLayer] {
            text.font = font
            text.fontSize = font.pointSize
            text.truncationMode = .start
        }
        contextLayer.alignmentMode = .right
        contextLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        previewLayer.foregroundColor = NSColor.labelColor.cgColor
        messageLayer.alignmentMode = .center
        messageLayer.truncationMode = .end
        [landingLayer, hoverLayer, highlightLayer, contextLayer, previewLayer, messageLayer].forEach(layer.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    /// The candidate under `point` (pill coordinates); the whole pill height counts.
    private func candidate(at point: NSPoint) -> String? {
        guard message == nil, bounds.contains(point) else { return nil }
        let index = candidateLayers.firstIndex { point.x >= $0.frame.minX && point.x < $0.frame.maxX }
        return index.map { candidates[$0] }
    }

    /// The candidate under a window point, for clicks that reach another view first.
    func candidate(atWindowPoint point: NSPoint) -> String? {
        isHidden ? nil : candidate(at: convert(point, from: nil))
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // DBG-CLICK
        NSLog("DBG-CLICK pill.hitTest sup=%@ local=%@ cands=%d msg=%@ hidden=%d", NSStringFromPoint(point), NSStringFromPoint(convert(point, from: superview)), candidates.count, message ?? "nil", isHidden ? 1 : 0)
        guard !isHidden, candidate(at: convert(point, from: superview)) != nil else { return nil }
        return self
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredCandidate = candidateLayers.firstIndex { point.x >= $0.frame.minX && point.x < $0.frame.maxX }
    }

    public override func mouseExited(with event: NSEvent) { hoveredCandidate = nil }

    public override func mouseDown(with event: NSEvent) {
        NSLog("DBG-CLICK pill.mouseDown candidate=%@", candidate(at: convert(event.locationInWindow, from: nil)) ?? "nil")
        if let label = candidate(at: convert(event.locationInWindow, from: nil)) { onSelect?(label) }
    }

    private func rebuildCandidates() {
        (candidateLayers + dividerLayers).forEach { $0.removeFromSuperlayer() }
        hoveredCandidate = nil
        candidateLayers = candidates.map { label in
            let text = CATextLayer()
            text.font = font
            text.fontSize = font.pointSize
            text.string = label
            text.alignmentMode = .center
            // The pill is always light; resolve to dark ink before storing it in the layer.
            text.foregroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            text.contentsScale = window?.backingScaleFactor ?? 2
            layer?.addSublayer(text)
            return text
        }
        dividerLayers = candidates.dropFirst().map { _ in
            let line = CALayer()
            line.backgroundColor = NSColor(white: 0, alpha: 0.15).cgColor
            layer?.addSublayer(line)
            return line
        }
        update()
    }

    private func updateCandidateHover() {
        guard let index = hoveredCandidate, candidateLayers.indices.contains(index), message == nil else {
            hoverLayer.opacity = 0
            return
        }
        let cell = candidateLayers[index].frame
        hoverLayer.frame = CGRect(x: cell.minX, y: 0, width: cell.width, height: bounds.height)
        hoverLayer.opacity = 1
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in [contextLayer, previewLayer, messageLayer] { text.contentsScale = scale }
    }

    /// Centered `gap` above `panel` (a sibling frame), as wide as the panel up to `maxWidth`.
    func layout(above panel: CGRect, in container: NSView) {
        let width = min(panel.width, Self.maxWidth)
        let y = container.isFlipped ? panel.minY - Self.gap - Self.height : panel.maxY + Self.gap
        let frame = CGRect(x: panel.midX - width / 2, y: y, width: width, height: Self.height).integral
        guard frame != self.frame else { return }
        self.frame = frame
        layer?.cornerRadius = Self.height / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.height / 2, cornerHeight: Self.height / 2, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }

    // MARK: Content

    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Frame of the preview word in pill coordinates (where a finished word lands); the
    /// right end of the text area when there is none.
    var previewTextRect: CGRect {
        let y = (bounds.height - lineHeight) / 2
        guard let word = trimmedPreview else {
            return CGRect(x: bounds.maxX - Self.insetX, y: y, width: 0, height: lineHeight)
        }
        let w = min(width(of: word), bounds.width - 2 * Self.insetX)
        return CGRect(x: bounds.maxX - Self.insetX - w, y: y, width: w, height: lineHeight)
    }

    private var trimmedPreview: String? {
        guard let p = preview?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return p
    }

    private func update(contextChanged: Bool = false, previewChanged: Bool = false) {
        guard bounds.width > 0 else { return }
        let showMessage = message != nil
        let showCandidates = !showMessage && !candidates.isEmpty
        let word = showCandidates ? nil : trimmedPreview
        let y = (bounds.height - lineHeight) / 2
        let inner = bounds.width - 2 * Self.insetX

        messageLayer.string = message
        messageLayer.foregroundColor = NSColor.systemOrange.cgColor
        messageLayer.frame = CGRect(x: Self.insetX, y: y, width: inner, height: lineHeight)
        messageLayer.opacity = showMessage ? 1 : 0

        if contextChanged { contextLayer.add(Self.fade, forKey: "contents") }
        if previewChanged, word != nil { previewLayer.add(Self.fade, forKey: "contents") }

        let previewRect = previewTextRect
        let space = word == nil ? 0 : width(of: " ") + Self.previewPadX
        let placeholder = false
        contextLayer.string = placeholder ? "Write on the trackpad" : context
        contextLayer.foregroundColor = (placeholder ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor).cgColor
        contextLayer.alignmentMode = placeholder ? .center : .right
        contextLayer.frame = CGRect(x: Self.insetX, y: y, width: max(0, previewRect.minX - space - Self.insetX), height: lineHeight)
        contextLayer.opacity = showMessage || showCandidates ? 0 : 1
        layoutCandidates(visible: showCandidates, y: y)

        previewLayer.string = word
        previewLayer.frame = previewRect
        previewLayer.opacity = showMessage || word == nil ? 0 : 1
        highlightLayer.frame = previewRect.insetBy(dx: -Self.previewPadX, dy: -3)
        highlightLayer.cornerRadius = highlightLayer.frame.height / 2
        highlightLayer.opacity = showMessage || word == nil ? 0 : 1
    }

    /// Candidates centered in the pill, each padded and separated by a vertical line.
    private func layoutCandidates(visible: Bool, y: CGFloat) {
        let pad = Self.insetX
        let widths = candidates.map { width(of: $0) + 2 * pad }
        var x = (bounds.width - widths.reduce(0, +)) / 2
        for (i, text) in candidateLayers.enumerated() {
            text.frame = CGRect(x: x, y: y, width: widths[i], height: lineHeight)
            text.opacity = visible ? 1 : 0
            if i > 0 {
                dividerLayers[i - 1].frame = CGRect(x: x, y: bounds.height * 0.25, width: 1, height: bounds.height * 0.5)
                dividerLayers[i - 1].opacity = visible ? 1 : 0
            }
            x += widths[i]
        }
        updateCandidateHover()
    }

    private static var fade: CATransition {
        let t = CATransition()
        t.type = .fade
        t.duration = 0.18
        return t
    }

    // MARK: Animations

    /// A small spring pop on the preview word, as a finished word lands in it.
    func popPreview() {
        guard trimmedPreview != nil, !Self.reduceMotion else { return }
        for target in [previewLayer, highlightLayer] {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 1.12
            pop.toValue = 1
            pop.damping = 12
            pop.stiffness = 300
            pop.initialVelocity = 0
            pop.duration = pop.settlingDuration
            target.add(pop, forKey: "pop")
        }
    }

    /// A brief accent glow over `rect` (pill coordinates), where a finished word landed.
    func flash(_ rect: CGRect) {
        guard rect.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        landingLayer.frame = rect.insetBy(dx: -Self.previewPadX, dy: -3)
        landingLayer.cornerRadius = landingLayer.frame.height / 2
        CATransaction.commit()
        let glow = CABasicAnimation(keyPath: "opacity")
        glow.fromValue = 1
        glow.toValue = 0
        glow.duration = 0.5
        glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        landingLayer.add(glow, forKey: "flash")
    }

    /// The macOS "nope" shake.
    private func shake() {
        guard !Self.reduceMotion, let layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 7, -5, 3, -1, 0]
        shake.duration = 0.4
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shake, forKey: "shake")
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
