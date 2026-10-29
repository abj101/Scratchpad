import Foundation

/// Pen-key state machine. Fed plain key inputs (no AppKit event types) and
/// reports pen transitions through `onTransition`.
///
/// - Hold: pen is down while the key is held. Toggle: each press flips the pen.
/// - Key repeats are ignored.
/// - `cancel()` (Esc, window/app resigning) forces the pen up with `.cancelled`
///   and forgets physical key state.
/// - Changing `penKey` or `activation` behaves like `cancel()`.
public final class PenKeyMonitor {
    public static let spaceKeyCode: UInt16 = 49
    public static let escapeKeyCode: UInt16 = 53

    public var penKey: PenKey {
        didSet { if penKey != oldValue { cancel() } }
    }
    public var activation: PenActivation {
        didSet { if activation != oldValue { cancel() } }
    }
    public private(set) var isPenDown = false
    /// Fired on every pen state change (never with a no-op transition).
    public var onTransition: ((PenTransition) -> Void)?

    public init(penKey: PenKey = .space, activation: PenActivation = .hold) {
        self.penKey = penKey
        self.activation = activation
    }

    // MARK: Physical key state

    private var spaceHeld = false
    private var optionHeld = false
    private var fnHeld = false

    // MARK: Input

    /// Returns true if the key belongs to the monitor (the pen key, including its
    /// repeats) and must not be passed on. Esc is not handled here; call `cancel()`.
    @discardableResult
    public func keyDown(keyCode: UInt16, isRepeat: Bool) -> Bool {
        guard keyCode == Self.spaceKeyCode, penKey == .space else { return false }
        if !isRepeat && !spaceHeld {
            spaceHeld = true
            press()
        }
        return true
    }

    /// Returns true if the key belongs to the monitor.
    @discardableResult
    public func keyUp(keyCode: UInt16) -> Bool {
        guard keyCode == Self.spaceKeyCode, penKey == .space else { return false }
        if spaceHeld {
            spaceHeld = false
            release()
        }
        return true
    }

    /// Current modifier state after a flagsChanged event.
    public func flagsChanged(option: Bool, function: Bool) {
        let wasOption = optionHeld, wasFn = fnHeld
        optionHeld = option
        fnHeld = function
        switch penKey {
        case .option: edge(was: wasOption, now: option)
        case .fn: edge(was: wasFn, now: function)
        case .space: break
        }
    }

    /// Puts the pen down without a key press (e.g. the cursor entering the writing zone).
    public func engage() { set(down: true) }

    /// Pen up with `.cancelled` (if down) and clear held-key state.
    public func cancel() {
        spaceHeld = false
        optionHeld = false
        fnHeld = false
        if isPenDown {
            isPenDown = false
            onTransition?(.cancelled)
        }
    }

    // MARK: Transitions

    private func edge(was: Bool, now: Bool) {
        if now && !was { press() } else if !now && was { release() }
    }

    private func press() {
        switch activation {
        case .hold: set(down: true)
        case .toggle: set(down: !isPenDown)
        }
    }

    private func release() {
        if activation == .hold { set(down: false) }
    }

    private func set(down: Bool) {
        guard down != isPenDown else { return }
        isPenDown = down
        onTransition?(down ? .down : .up)
    }
}
