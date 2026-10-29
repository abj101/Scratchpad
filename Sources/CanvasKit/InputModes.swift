import AppKit

// MARK: - Input mode settings
//
// Phase 2 contract. Every source converts its own coordinates to world space and
// emits PenEvents into a PenEventSink (the ToolController). Nothing downstream
// knows which source sent them.

/// How trackpad/mouse input becomes ink.
public enum InputMode: String, CaseIterable, Codable {
    /// Relative: the cursor moves normally; while the pen key is down, motion draws.
    case pen
    /// Absolute: the whole trackpad maps to the visible canvas region.
    case tablet
    /// Absolute onto a word-sized writing box that advances along a ruled line.
    case write
    /// Write mode's letter cell, but the handwriting only shows in the panel and
    /// is recognized into a text block.
    case scribe

    public var displayName: String {
        switch self {
        case .pen: "Pen"
        case .tablet: "Absolute"
        case .write: "Write"
        case .scribe: "Scribe"
        }
    }

    /// Tablet, Write and Scribe modes share the absolute trackpad source, cursor lock and Esc exit.
    public var usesTabletInput: Bool { self == .tablet || usesLetterCell }

    /// Write and Scribe map the trackpad onto one letter-sized cell shown in the panel.
    public var usesLetterCell: Bool { self == .write || self == .scribe }

    /// Scribe needs a handwriting recognizer (macOS 27+); the other modes always work.
    public var isAvailable: Bool { self != .scribe || HandwritingRecognizers.system() != nil }
}

/// The keyboard key that puts the pen down in Pen and Absolute modes.
public enum PenKey: String, CaseIterable, Codable {
    case space, option, fn

    public var displayName: String {
        switch self {
        case .space: "Space"
        case .option: "Option"
        case .fn: "Fn"
        }
    }
}

/// Where a new writing panel appears along the bottom of the screen.
public enum WritingPanelPlacement: String, CaseIterable, Codable {
    case left, middle, right

    public var displayName: String { rawValue.capitalized }
}

public enum PenActivation: String, CaseIterable, Codable {
    /// Pen is down while the key is held.
    case hold
    /// Each press flips the pen.
    case toggle

    public var displayName: String {
        switch self {
        case .hold: "Hold"
        case .toggle: "Toggle"
        }
    }
}

public extension InputMode {
    /// Short toolbar hint for keyboard-controlled drawing.
    func hint(penKey: PenKey, activation: PenActivation) -> String? {
        let verb = usesLetterCell ? "write" : "draw"
        let action = activation == .hold ? "Hold \(penKey.displayName) to \(verb)"
                                         : "Press \(penKey.displayName) to toggle pen"
        switch self {
        case .pen: return "\(action) · Esc lifts pen"
        case .tablet: return "\(action) · Esc to exit"
        case .write: return "\(action) · → next word · Return new line · Esc to exit"
        case .scribe: return "\(action) · → or Tab ends a word · Return new line · Delete · Esc to exit"
        }
    }
}

// MARK: - Pen transitions

/// Output of `PenKeyMonitor`, input to every `PenInputSource`.
public enum PenTransition: Equatable {
    /// Pen key pressed (Hold) or toggled on.
    case down
    /// Pen key released (Hold) or toggled off: finish any stroke normally.
    case up
    /// Esc, window/app resigning, or a pen-key/activation change: pen up and
    /// discard any stroke in progress.
    case cancelled
}

// MARK: - Touch samples

/// One touching finger, independent of NSTouch so tablet logic is unit-testable.
public struct TouchSample: Equatable {
    /// Stable per-finger identity (wrap `NSTouch.identity` as `AnyHashable(identity as! NSObject)`).
    public var id: AnyHashable
    /// 0...1 on each axis, origin bottom-left (as `NSTouch.normalizedPosition`).
    public var normalized: CGPoint
    /// Physical trackpad size in points; `.zero` if unknown.
    public var deviceSize: CGSize

    public init(id: AnyHashable, normalized: CGPoint, deviceSize: CGSize = .zero) {
        self.id = id; self.normalized = normalized; self.deviceSize = deviceSize
    }
}

// MARK: - Input source protocol

/// A non-click input source (relative pen, tablet). Owned and driven by
/// `CanvasView`, which forwards pen transitions from its `PenKeyMonitor`.
public protocol PenInputSource: AnyObject {
    /// Receives world-space PenEvents.
    var sink: PenEventSink? { get set }
    /// True between an emitted `.began` and the matching `.ended`/`.cancelled`.
    var isDrawing: Bool { get }

    /// Called when this source becomes the active mode.
    func activate(in view: CanvasView)
    /// Called when leaving this mode or tearing down. Must emit `.cancelled` if
    /// drawing and release every resource it acquired. Idempotent.
    func deactivate()

    /// Pen key state changed.
    func penChanged(_ transition: PenTransition, timestamp: TimeInterval)
    /// Abort any stroke in progress (emits `.cancelled` if drawing); pen state is untouched.
    func cancelStroke(timestamp: TimeInterval)
}
