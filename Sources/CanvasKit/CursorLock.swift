import AppKit

/// The only place allowed to hide or freeze the cursor.
///
/// `lock(centeredIn:)` warps the cursor to the view's center, dissociates mouse
/// movement from the cursor and hides it; each step is guarded by its own flag
/// so `unlock()` always balances exactly. `unlock()` is idempotent and runs in
/// `deinit`. Never leave the user with a frozen or hidden cursor.
public final class CursorLock {
    public private(set) var isLocked = false
    /// True while any lock is held; read by window chrome that must stay out of the way.
    public private(set) static var isAnyLocked = false

    private var didWarp = false
    private var didDissociate = false
    private var didHide = false

    public init() {}

    deinit { unlock() }

    public func lock(centeredIn view: NSView) {
        warpToCenter(of: view)
        if !didDissociate {
            CGAssociateMouseAndMouseCursorPosition(0)
            didDissociate = true
        }
        if !didHide {
            NSCursor.hide()
            didHide = true
        }
        isLocked = didDissociate || didHide
        Self.isAnyLocked = isLocked
    }

    public func unlock() {
        if didDissociate {
            CGAssociateMouseAndMouseCursorPosition(1)
            didDissociate = false
        }
        if didHide {
            NSCursor.unhide()
            didHide = false
        }
        isLocked = false
        Self.isAnyLocked = false
    }

    // MARK: Warp

    /// Cocoa screen coordinates are bottom-left/y-up on the primary screen; CG
    /// global coordinates are top-left/y-down.
    private func warpToCenter(of view: NSView) {
        guard let point = Self.globalPoint(NSPoint(x: view.visibleRect.midX, y: view.visibleRect.midY), in: view) else { return }
        CGWarpMouseCursorPosition(point)
    }

    /// `point` (in `view`'s coordinates) in CG global coordinates.
    public static func globalPoint(_ point: NSPoint, in view: NSView) -> CGPoint? {
        guard let window = view.window, let primary = NSScreen.screens.first else { return nil }
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        return CGPoint(x: screenPoint.x, y: primary.frame.maxY - screenPoint.y)
    }
}
