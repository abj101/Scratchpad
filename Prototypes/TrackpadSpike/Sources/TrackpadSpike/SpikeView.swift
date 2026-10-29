import AppKit
import CoreGraphics

/// Phase-0 spike: can the MacBook trackpad be used as a drawing surface?
///
/// Modes:
///   1 = Relative Pen: normal cursor; while the pen is down, cursor motion draws.
///   2 = Tablet: cursor frozen + hidden; absolute finger position on the trackpad
///       (NSTouch.normalizedPosition) maps into an on-screen active region.
///
/// Smoothing defaults (One-Euro, units = points & seconds):
///   minCutoff = 1.5 Hz, beta = 0.02 (per pt/s), dCutoff = 1.0 Hz.
///   Every stroke always stores both raw and filtered points; `S` switches which
///   one is rendered (for all strokes), `R` overlays the raw polyline in red.
final class SpikeView: NSView {

    // MARK: - Types

    private enum Mode: String { case relativePen = "Relative Pen", tablet = "Tablet" }

    private enum PenKey: String, CaseIterable {
        case space = "Space", option = "Option", fn = "Fn"
        var next: PenKey {
            let all = PenKey.allCases
            let i = all.firstIndex(of: self) ?? 0
            return all[(i + 1) % all.count]
        }
    }

    private enum Activation: String { case hold = "Hold", toggle = "Toggle" }

    private struct Stroke {
        var raw: [CGPoint] = []
        var smooth: [CGPoint] = []
        var width: CGFloat
    }

    // MARK: - Constants

    private static let spaceKeyCode: UInt16 = 49
    private static let escKeyCode: UInt16 = 53
    private static let regionInset: CGFloat = 40
    private static let defaultTrackpadAspect: CGFloat = 1.6
    private static let defaultMinCutoff = 1.5
    private static let defaultBeta = 0.02
    private static let dCutoff = 1.0

    // MARK: - State

    private var mode: Mode = .relativePen
    private var penKey: PenKey = .space
    private var activation: Activation = .hold
    private var penDown = false
    private var keyHeld = false

    // Modifier tracking for flagsChanged edge detection.
    private var optionWasDown = false
    private var fnWasDown = false

    // Strokes
    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var strokeWidth: CGFloat = 2.5
    private var smoothingOn = true
    private var showRaw = false
    private var minCutoff = SpikeView.defaultMinCutoff
    private var beta = SpikeView.defaultBeta
    private var filter = OneEuroFilter2D(minCutoff: SpikeView.defaultMinCutoff,
                                         beta: SpikeView.defaultBeta,
                                         dCutoff: SpikeView.dCutoff)

    // Tablet / touch state
    private var trackedIdentity: (NSCopying & NSObjectProtocol)?
    private var gestureSuspended = false
    private var hoverPoint: CGPoint?
    private var touchCount = 0
    private var trackpadAspect: CGFloat = SpikeView.defaultTrackpadAspect
    private var trackpadSizeKnown = false

    // Cursor state (must stay balanced)
    private var cursorHidden = false
    private var cursorDissociated = false

    // Instrumentation
    private var touchEventTimes: [TimeInterval] = []
    private var mouseEventTimes: [TimeInterval] = []
    private var eventsWhileKeyHeld = 0
    private var lastInputTime: TimeInterval?
    private var keyPressTime: TimeInterval?
    private var firstInputAfterPressMs: Double?
    private var lastHoldSummary = "-"

    private var trackingArea: NSTrackingArea?
    private var hudTimer: Timer?
    private weak var observedWindow: NSWindow?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        allowedTouchTypes = []
        wantsRestingTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Belt and braces: never leave the cursor hidden / frozen.
        // (Timer retains self via target, so in practice teardown happens in
        // viewWillMove(toWindow: nil); this only covers unusual paths.)
        if cursorDissociated {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if cursorHidden {
            // NSView is only ever deallocated on the main thread in AppKit.
            MainActor.assumeIsolated { NSCursor.unhide() }
        }
    }

    // MARK: - NSView config

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
        super.updateTrackingAreas()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let old = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
            observedWindow = nil
        }
        if newWindow == nil {
            exitTablet()
            hudTimer?.invalidate()
            hudTimer = nil
            NotificationCenter.default.removeObserver(self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillGoAway(_:)),
                                               name: NSApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillGoAway(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
        observedWindow = window
        if hudTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(hudTick(_:)),
                          userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            hudTimer = t
        }
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        releaseKeyState()
        if mode == .tablet { switchMode(.relativePen) }
    }

    @objc private func appWillGoAway(_ note: Notification) {
        releaseKeyState()
        if mode == .tablet { switchMode(.relativePen) }
    }

    @objc private func hudTick(_ timer: Timer) {
        needsDisplay = true
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Mode switching

    private func switchMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        endStroke()
        if mode == .tablet { exitTablet() }
        mode = newMode
        if newMode == .tablet { enterTablet() }
        needsDisplay = true
    }

    private func enterTablet() {
        resetTouchState()
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        warpCursorToCenter()
        if !cursorDissociated {
            CGAssociateMouseAndMouseCursorPosition(0)
            cursorDissociated = true
        }
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    /// Idempotent; safe to call from any teardown path.
    private func exitTablet() {
        if cursorDissociated {
            CGAssociateMouseAndMouseCursorPosition(1)
            cursorDissociated = false
        }
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        allowedTouchTypes = []
        resetTouchState()
        if mode == .tablet {
            endStroke()
            mode = .relativePen
        }
    }

    private func warpCursorToCenter() {
        guard let window = window, let primary = NSScreen.screens.first else { return }
        let centerInWindow = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let screenPt = window.convertPoint(toScreen: centerInWindow)
        // Cocoa global coords: origin bottom-left of primary screen, y up.
        // CG global coords: origin top-left of primary screen, y down.
        let global = CGPoint(x: screenPt.x, y: primary.frame.maxY - screenPt.y)
        CGWarpMouseCursorPosition(global)
    }

    private func resetTouchState() {
        trackedIdentity = nil
        gestureSuspended = false
        hoverPoint = nil
        touchCount = 0
    }

    // MARK: - Pen state

    private func penKeyPressed() {
        let t = now
        keyHeld = true
        keyPressTime = t
        eventsWhileKeyHeld = 0
        firstInputAfterPressMs = nil
        switch activation {
        case .hold: setPen(true)
        case .toggle: setPen(!penDown)
        }
        needsDisplay = true
    }

    private func penKeyReleased() {
        guard keyHeld else { return }
        keyHeld = false
        if let kp = keyPressTime {
            let dur = now - kp
            let first = firstInputAfterPressMs.map { String(format: "%.0fms", $0) } ?? "none"
            lastHoldSummary = String(format: "%d ev in %.2fs, 1st after %@", eventsWhileKeyHeld, dur, first)
        }
        if activation == .hold { setPen(false) }
        needsDisplay = true
    }

    /// Clear physical-key state without leaving the pen stuck down in Hold mode.
    private func releaseKeyState() {
        if keyHeld { penKeyReleased() }
        optionWasDown = false
        fnWasDown = false
    }

    private func setPen(_ down: Bool) {
        guard down != penDown else { return }
        penDown = down
        if down {
            let t = now
            switch mode {
            case .relativePen:
                if let window = window {
                    let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    beginStroke(at: p, t: t)
                }
            case .tablet:
                if let hp = hoverPoint, !gestureSuspended, trackedIdentity != nil {
                    beginStroke(at: hp, t: t)
                }
            }
        } else {
            endStroke()
        }
        needsDisplay = true
    }

    // MARK: - Stroke building

    private func beginStroke(at p: CGPoint, t: TimeInterval) {
        endStroke()
        filter.setParams(minCutoff: minCutoff, beta: beta, dCutoff: Self.dCutoff)
        filter.reset()
        current = Stroke(width: strokeWidth)
        appendPoint(p, t: t)
    }

    private func appendPoint(_ p: CGPoint, t: TimeInterval) {
        guard current != nil else { return }
        let f = filter.filter(p, t: t)
        current?.raw.append(p)
        current?.smooth.append(f)
    }

    private func endStroke() {
        if let s = current, !s.raw.isEmpty {
            strokes.append(s)
        }
        current = nil
    }

    // MARK: - Instrumentation

    private func noteInput(t: TimeInterval, isTouch: Bool) {
        if isTouch { touchEventTimes.append(t) } else { mouseEventTimes.append(t) }
        lastInputTime = t
        if keyHeld {
            eventsWhileKeyHeld += 1
            if firstInputAfterPressMs == nil, let kp = keyPressTime {
                firstInputAfterPressMs = max(0, (t - kp) * 1000)
            }
        }
    }

    private func rate(_ times: inout [TimeInterval], at t: TimeInterval) -> Int {
        let cutoff = t - 1.0
        if let idx = times.firstIndex(where: { $0 >= cutoff }) {
            if idx > 0 { times.removeFirst(idx) }
        } else {
            times.removeAll()
        }
        return times.count
    }

    // MARK: - Mouse events

    private func handlePointerMotion(_ event: NSEvent) {
        noteInput(t: event.timestamp, isTouch: false)
        if mode == .relativePen, penDown {
            let p = convert(event.locationInWindow, from: nil)
            if current == nil {
                beginStroke(at: p, t: event.timestamp)
            } else {
                appendPoint(p, t: event.timestamp)
            }
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { handlePointerMotion(event) }
    override func mouseDragged(with event: NSEvent) { handlePointerMotion(event) }
    override func rightMouseDragged(with event: NSEvent) { handlePointerMotion(event) }

    override func mouseDown(with event: NSEvent) {
        // Tablet: swallow (tap-to-click must do nothing). Relative: clicks don't draw.
        if mode == .relativePen { window?.makeFirstResponder(self) }
    }
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {
        if mode == .relativePen { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if mode == .relativePen { super.rightMouseUp(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) {
        if mode == .relativePen { super.otherMouseDown(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        if mode == .relativePen { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) {
        if mode == .relativePen { super.magnify(with: event) }
    }
    override func rotate(with event: NSEvent) {
        if mode == .relativePen { super.rotate(with: event) }
    }
    override func smartMagnify(with event: NSEvent) {
        if mode == .relativePen { super.smartMagnify(with: event) }
    }

    // MARK: - Touch events (Tablet)

    override func touchesBegan(with event: NSEvent) { handleTouches(event) }
    override func touchesMoved(with event: NSEvent) { handleTouches(event) }
    override func touchesEnded(with event: NSEvent) { handleTouches(event) }
    override func touchesCancelled(with event: NSEvent) { handleTouches(event) }

    private func activeRegion() -> CGRect {
        let r = bounds.insetBy(dx: Self.regionInset, dy: Self.regionInset)
        guard r.width > 0, r.height > 0 else { return bounds }
        let aspect = trackpadAspect
        var w = r.width
        var h = w / aspect
        if h > r.height {
            h = r.height
            w = h * aspect
        }
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    private func mapTouch(_ touch: NSTouch) -> CGPoint {
        let r = activeRegion()
        let n = touch.normalizedPosition
        return CGPoint(x: r.minX + n.x * r.width, y: r.minY + (1 - n.y) * r.height)
    }

    private func handleTouches(_ event: NSEvent) {
        guard mode == .tablet else { return }
        let t = event.timestamp
        noteInput(t: t, isTouch: true)
        defer { needsDisplay = true }

        let touching = event.touches(matching: .touching, in: self)
        touchCount = touching.count

        if let any = touching.first {
            let ds = any.deviceSize
            if ds.width > 0, ds.height > 0 {
                trackpadAspect = ds.width / ds.height
                trackpadSizeKnown = true
            }
        }

        if touching.isEmpty {
            // All fingers lifted: end stroke, leave gesture state.
            endStroke()
            resetTouchState()
            return
        }

        if touching.count >= 2 {
            if !gestureSuspended {
                endStroke()
                gestureSuspended = true
            }
            trackedIdentity = nil
            hoverPoint = nil
            return
        }

        if gestureSuspended { return } // wait for all fingers to lift

        // Exactly one touch.
        guard let touch = touching.first else { return }
        let p = mapTouch(touch)

        if let tracked = trackedIdentity, tracked.isEqual(touch.identity) {
            hoverPoint = p
            if penDown {
                if current == nil { beginStroke(at: p, t: t) } else { appendPoint(p, t: t) }
            }
        } else {
            // New finger (or tracked finger replaced): never connect across the jump.
            endStroke()
            trackedIdentity = touch.identity
            hoverPoint = p
            if penDown { beginStroke(at: p, t: t) }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.spaceKeyCode {
            if penKey == .space && !event.isARepeat { penKeyPressed() }
            return
        }
        if event.keyCode == Self.escKeyCode {
            releaseKeyState()
            setPen(false)
            if mode == .tablet { switchMode(.relativePen) }
            needsDisplay = true
            return
        }
        if event.isARepeat, let c = event.charactersIgnoringModifiers,
           !["-", "=", "[", "]", ";", "'"].contains(c) {
            return
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return }
        switch chars {
        case "1": switchMode(.relativePen)
        case "2": switchMode(.tablet)
        case "k":
            releaseKeyState()
            setPen(false)
            penKey = penKey.next
            // Re-sync modifier edge state with the new key.
            optionWasDown = event.modifierFlags.contains(.option)
            fnWasDown = event.modifierFlags.contains(.function)
        case "t":
            activation = (activation == .hold) ? .toggle : .hold
            setPen(false)
        case "s": smoothingOn.toggle()
        case "r": showRaw.toggle()
        case "[": minCutoff = max(0.01, minCutoff * 0.8)
        case "]": minCutoff = min(100, minCutoff * 1.25)
        case ";": beta = max(0.0001, beta * 0.8)
        case "'": beta = min(10, beta * 1.25)
        case "-": strokeWidth = max(0.5, strokeWidth / 1.2)
        case "=": strokeWidth = min(20, strokeWidth * 1.2)
        case "z":
            if current != nil { current = nil } else if !strokes.isEmpty { strokes.removeLast() }
        case "c":
            strokes.removeAll()
            current = nil
        default:
            return // silently ignore; no beep
        }
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == Self.spaceKeyCode {
            if penKey == .space { penKeyReleased() }
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let optionDown = flags.contains(.option)
        let fnDown = flags.contains(.function)
        defer {
            optionWasDown = optionDown
            fnWasDown = fnDown
        }
        switch penKey {
        case .option:
            if optionDown && !optionWasDown { penKeyPressed() }
            if !optionDown && optionWasDown { penKeyReleased() }
        case .fn:
            if fnDown && !fnWasDown { penKeyPressed() }
            if !fnDown && fnWasDown { penKeyReleased() }
        case .space:
            break
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    private func strokePath(_ pts: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.line(to: first) // dot (round cap renders it)
            return path
        }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            path.curve(to: mid, controlPoint: a) // quadratic (macOS 14+)
        }
        if let last = pts.last { path.line(to: last) }
        return path
    }

    private func drawStroke(_ s: Stroke) {
        if showRaw, s.raw.count > 0 {
            let raw = NSBezierPath()
            raw.move(to: s.raw[0])
            for p in s.raw.dropFirst() { raw.line(to: p) }
            if s.raw.count == 1 { raw.line(to: s.raw[0]) }
            raw.lineWidth = 0.75
            raw.lineCapStyle = .round
            raw.lineJoinStyle = .round
            NSColor.systemRed.withAlphaComponent(0.45).setStroke()
            raw.stroke()
        }
        let path = strokePath(smoothingOn ? s.smooth : s.raw)
        path.lineWidth = s.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        if mode == .tablet {
            let region = NSBezierPath(rect: activeRegion().insetBy(dx: 0.5, dy: 0.5))
            region.lineWidth = 1
            region.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
            region.stroke()
        }

        for s in strokes { drawStroke(s) }
        if let c = current { drawStroke(c) }

        if mode == .tablet, let hp = hoverPoint, !gestureSuspended, current == nil {
            let r: CGFloat = max(6, strokeWidth + 4)
            let circle = NSBezierPath(ovalIn: CGRect(x: hp.x - r, y: hp.y - r, width: 2 * r, height: 2 * r))
            circle.lineWidth = 1
            NSColor.systemBlue.setStroke()
            circle.stroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: hp.x - r - 4, y: hp.y)); cross.line(to: CGPoint(x: hp.x + r + 4, y: hp.y))
            cross.move(to: CGPoint(x: hp.x, y: hp.y - r - 4)); cross.line(to: CGPoint(x: hp.x, y: hp.y + r + 4))
            cross.lineWidth = 0.75
            cross.stroke()
        }

        drawHUD()
        drawHelp()
    }

    private func touchStateString() -> String {
        if mode == .tablet {
            if gestureSuspended { return "gesture" }
            if current != nil { return "drawing" }
            if trackedIdentity != nil { return "hover" }
            return "idle"
        }
        return current != nil ? "drawing" : "idle"
    }

    private func drawHUD() {
        let t = now
        let touchHz = rate(&touchEventTimes, at: t)
        let mouseHz = rate(&mouseEventTimes, at: t)
        let msSince = lastInputTime.map { String(format: "%.0f", max(0, (t - $0) * 1000)) } ?? "-"
        let aspect = trackpadSizeKnown ? String(format: "%.3f", trackpadAspect)
                                       : String(format: "%.1f (default)", trackpadAspect)

        var lines: [String] = []
        lines.append("Mode:        \(mode.rawValue)")
        lines.append("Pen key:     \(penKey.rawValue)  [\(activation.rawValue)]")
        lines.append("Pen:         \(penDown ? "DOWN" : "UP")   key held: \(keyHeld ? "yes" : "no")")
        if mode == .tablet {
            lines.append("Touches:     \(touchCount)   aspect: \(aspect)")
        }
        lines.append("State:       \(touchStateString())")
        lines.append("Touch rate:  \(touchHz) Hz   Mouse rate: \(mouseHz) Hz")
        lines.append("Input evts while key held: \(eventsWhileKeyHeld)")
        lines.append("Last hold:   \(lastHoldSummary)")
        lines.append("ms since last input: \(msSince)")
        lines.append(String(format: "Smoothing:   %@  minCutoff %.3f  beta %.4f",
                            smoothingOn ? "on " : "off", minCutoff, beta))
        lines.append(String(format: "Width:       %.2f   raw overlay: %@   strokes: %d",
                            strokeWidth, showRaw ? "on" : "off", strokes.count))

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs)
        let size = text.boundingRect(with: NSSize(width: 10_000, height: 10_000),
                                     options: [.usesLineFragmentOrigin]).size
        let pad: CGFloat = 8
        let box = CGRect(x: 10, y: 10, width: ceil(size.width) + 2 * pad, height: ceil(size.height) + 2 * pad)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(with: CGRect(x: box.minX + pad, y: box.minY + pad, width: ceil(size.width), height: ceil(size.height)),
                  options: [.usesLineFragmentOrigin])
    }

    private func drawHelp() {
        let help = "1 Relative  2 Tablet  K pen key  T hold/toggle  Esc lift/exit  S smooth  R raw  "
                 + "[ ] minCutoff  ; ' beta  - = width  Z undo  C clear"
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.darkGray]
        let text = NSAttributedString(string: help, attributes: attrs)
        let size = text.size()
        let pad: CGFloat = 5
        let box = CGRect(x: 10, y: bounds.maxY - size.height - 2 * pad - 8,
                         width: size.width + 2 * pad, height: size.height + 2 * pad)
        NSColor(white: 0.95, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad))
    }
}
