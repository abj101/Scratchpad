import SwiftUI
import CanvasKit

/// Window-edge hover state shared by the traffic-light hider and the border overlay.
final class WindowChromeState: ObservableObject {
    @Published var showsBorder = false
    /// The note title in the top band is being edited; that panel is key meanwhile.
    @Published var isEditingTitle = false
    /// Renames the open note; set by `ContentView`.
    var rename: ((String) -> Void)?
    var toggleSettings: (() -> Void)?
    /// Creates a note in the current folder and opens it; set by `ContentView`.
    var newNote: (() -> Void)?
    /// The note library popover content; set by `ContentView`.
    var libraryView: (() -> AnyView)?
    /// Drives the tool strip in the border; set by `ContentView`.
    @Published var settings: CanvasSettings?
}

/// Hides the window's native close / minimize / zoom buttons and drives the edge chrome
/// (`WindowChromeState.showsBorder`) from the pointer position.
/// Background of the window's content; it has no visible content of its own.
struct AutoHideTrafficLights: NSViewRepresentable {
    let state: WindowChromeState

    func makeNSView(context: Context) -> NSView { HostView(state: state) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? HostView)?.refresh() }

    private final class HostView: NSView {
        private let state: WindowChromeState
        private let hider: Hider
        private let overlay: WindowEdgeOverlay
        private var observers: [NSObjectProtocol] = []
        private var monitor: Any?
        private var globalMonitor: Any?

        init(state: WindowChromeState) {
            self.state = state
            hider = Hider(state: state)
            overlay = WindowEdgeOverlay(state: state)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            hider.window = window
            if Summon.window !== window, let window {
                Summon.window = window
                // Starts out summoned, so it stays in front from launch, not only after the shortcut.
                DispatchQueue.main.async { Summon.show(window) }
            }
            overlay.attach(to: window)
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
            guard let window else { return }
            // Any pointer motion in this window re-checks the hot zone.
            window.acceptsMouseMovedEvents = true
            // Events over the edge band arrive with the overlay panel as their window, so this
            // monitor deliberately does not filter by window; the app has only one.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.pointerMoved()
                return event
            }
            // The local monitor never sees the pointer once it is outside the window,
            // which is where the edge border is triggered from.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                self?.pointerMoved()
            }
            refresh()
            // Settings / Notes opening, closing or taking key changes whether the ring stays on.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    for delay in [0.05, 0.3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refresh() } }
                })
            }
            // The titlebar is laid out just after the window appears.
            for delay in [0.1, 0.4, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
            }
            // AppKit restyles the buttons as the window is activated or resized, so
            // re-apply right away and again once it has finished.
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
                         NSWindow.didResignMainNotification,
                         NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        self?.refresh()
                        for delay in [0.05, 0.3] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refresh() }
                        }
                    })
            }
            // Full-screen transitions get their own handlers: the border is suspended for the whole
            // animation, and the native buttons are only shown while the window is full screen.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.overlay.setSuspended(true)
                    self.hider.isFullScreen = true
                    self.hider.install()
                })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.hider.isFullScreen = true
                })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.hider.isFullScreen = false
                    self.overlay.setSuspended(false)
                    self.refresh()
                })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            overlay.detach()
        }

        private func pointerMoved() {
            hider.pointerMoved()
            overlay.updateMouseInteractivity(showsBorder: state.showsBorder)
        }

        func refresh() {
            // No full-screen Space of its own: the expand button zooms instead, so the edge ring stays around
            // the window. Auxiliary (not None) lets a summoned note show over another app's full-screen Space.
            window?.collectionBehavior.subtract([.fullScreenPrimary, .fullScreenNone, .fullScreenAuxiliary])
            window?.collectionBehavior.insert(Summon.showsOverFullScreen ? .fullScreenAuxiliary : .fullScreenNone)
            if let window { CloseToHide.install(on: window) }
            hider.install()
            overlay.syncFrame()
            overlay.updateMouseInteractivity(showsBorder: state.showsBorder)
        }
    }

    private final class Hider {
        weak var window: NSWindow?
        weak var state: WindowChromeState?
        /// Set across the full-screen transition; keeps the native buttons visible and the border off.
        var isFullScreen = false
        private static let edgeSlop: CGFloat = 12
        private static let showDwell: TimeInterval = 0.15
        private var showDelay: DispatchWorkItem?

        init(state: WindowChromeState) {
            self.state = state
        }

        private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        /// Re-applies the current state. Called from the refresh loops, since AppKit restyles the buttons.
        func install() {
            updateBorderState()
            hideNativeButtons()
        }

        /// The band's own buttons replace these, except in full screen where the system title bar shows them.
        private func hideNativeButtons() {
            for type in Self.types {
                let button = window?.standardWindowButton(type)
                button?.isHidden = !isFullScreen
                button?.alphaValue = 1
            }
        }

        /// The Settings or Notes window is up: the ring stays on, whichever window is key.
        private func companionOpen(besides window: NSWindow) -> Bool {
            !isFullScreen && NSApp.windows.contains {
                $0 !== window && $0.parent !== window && $0.isVisible && ($0.title == "Notes" || $0.title.contains("Settings"))
            }
        }

        private func borderWanted() -> Bool {
            guard let window else { return false }
            let p = window.mouseLocationOutsideOfEventStream
            // The tool strip sits outside the window on its side, wider than the edge slop.
            let withinWindow = p.x >= -max(Self.edgeSlop, WindowEdgeBorder.leftInset) &&
                p.x <= window.frame.width + max(Self.edgeSlop, WindowEdgeBorder.rightInset) &&
                p.y >= -max(Self.edgeSlop, WindowEdgeBorder.bottomInset) &&
                p.y <= window.frame.height + WindowEdgeBorder.topBand + Self.edgeSlop
            let nearEdge = p.x <= Self.edgeSlop || p.x >= window.frame.width - Self.edgeSlop ||
                p.y <= Self.edgeSlop || p.y >= window.frame.height - Self.edgeSlop
            // Editing the title makes the border panel key, so the border must not read that as inactive.
            let editing = state?.isEditingTitle == true
            if UserDefaults.standard.bool(forKey: "alwaysShowBorder"), !isFullScreen, !window.styleMask.contains(.fullScreen) { return true }
            return editing || companionOpen(besides: window) || (window.isKeyWindow && !isFullScreen && !window.styleMask.contains(.fullScreen) &&
                !CursorLock.isAnyLocked &&
                ((withinWindow && nearEdge) || window.inLiveResize))
        }

        private func updateBorderState() {
            guard window != nil else { return }
            guard borderWanted() else {
                showDelay?.cancel()
                showDelay = nil
                if state?.showsBorder == true { state?.showsBorder = false }
                return
            }
            // Passing through an edge on the way elsewhere shouldn't flash the ring; show once the pointer lingers.
            guard state?.showsBorder != true, showDelay == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.showDelay = nil
                if self.borderWanted() { self.state?.showsBorder = true }
            }
            showDelay = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDwell, execute: work)
        }

        func pointerMoved() { updateBorderState() }
    }
}
