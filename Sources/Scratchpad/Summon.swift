import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Brings the note window forward from any app. While summoned it floats above other windows on every
/// Space until it is put away (the shortcut again, or closing it).
@MainActor enum Summon {
    /// The note window; registered by the edge chrome when it attaches.
    static weak var window: NSWindow?

    /// Settings toggle: a summoned note may appear over other apps' full-screen Spaces.
    static let overFullScreenKey = "showOverFullScreen"
    static var showsOverFullScreen: Bool { UserDefaults.standard.object(forKey: overFullScreenKey) as? Bool ?? true }

    /// The shortcut and the menu bar icon: put away a note that is up, otherwise summon it.
    static func toggle() {
        guard let window else { return }
        if isSummoned { putAway(window) } else { show(window) }
    }

    static let backdropChanged = Notification.Name("SummonBackdropChanged")

    private static var isSummoned: Bool { (window?.isVisible ?? false) && window?.level == summonLevel && fadingOut == nil }
    /// The put-away fade in progress, if any; a show bumps `generation`, so an overtaken fade does not
    /// order the window out when it finishes.
    private static var fadingOut: Int?
    private static var generation = 0
    private static let fade: TimeInterval = 0.16
    /// Above `.floating`, which some full-screen apps (players, presentations) sit over.
    private static let summonLevel = NSWindow.Level.statusBar

    static func show(_ window: NSWindow) {
        generation += 1
        fadingOut = nil
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.level = summonLevel
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.canJoinAllSpaces)
        // The edge ring and writing panel are child windows; they must float with the note.
        window.childWindows?.forEach {
            $0.level = summonLevel
            $0.hidesOnDeactivate = false
            $0.collectionBehavior.insert(.canJoinAllSpaces)
        }
        // macOS only puts a menu-bar-style (accessory) app's windows over another app's full-screen Space;
        // a regular app is pulled back to its own desktop instead. Normally already set by `putAway`, so the
        // policy does not change right before activating (which can drop the activation).
        if showsOverFullScreen && NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        let appearing = !window.isVisible || window.alphaValue < 1
        if !window.isVisible { setAlpha(0, window) }
        SummonStatusItem.setInUse(true)
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        if appearing { animate(1, window) }
        guard !NSApp.isActive else { return }
        // Activation lands later, and unhiding hands key to whichever window was key before (Settings,
        // Notes or the edge ring); take it back for the note once the app is active, in one step.
        activeObserver.map(NotificationCenter.default.removeObserver)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    activeObserver.map(NotificationCenter.default.removeObserver)
                    activeObserver = nil
                    if window.isVisible { window.makeKeyAndOrderFront(nil) }
                }
            }
        NSApp.activate()
    }

    private static var activeObserver: NSObjectProtocol?

    /// Another app was activated or the Space changed: re-raise a summoned note so it stays in front, and
    /// repaint it, since the canvas layer only redraws on request and comes back black after a Space switch.
    static func keepFront() {
        guard let window, window.isVisible, window.level == summonLevel, fadingOut == nil else { return }
        NotificationCenter.default.post(name: backdropChanged, object: nil)
        // Our own activation needs no re-raise (it flickers the note); another app's, or a Space change, does.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           window.isOnActiveSpace { return }
        // Re-assert the Space behavior, in case it was reset, so the note follows into other full-screen Spaces.
        for w in [window] + (window.childWindows ?? []) { w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary]) }
        window.orderFrontRegardless()
        for w in [window] + (window.childWindows ?? []) { w.contentView.map(redraw) }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }

    /// Fades the note out, then hides the app so focus goes back to the app that was in front before.
    static func putAway(_ window: NSWindow) {
        let id = generation
        fadingOut = id
        SummonStatusItem.setInUse(false)
        animate(0, window) {
            guard fadingOut == id else { return }
            fadingOut = nil
            window.orderOut(nil)
            setAlpha(1, window)
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.childWindows?.forEach { $0.level = .normal; $0.collectionBehavior.remove(.canJoinAllSpaces) }
            NSApp.hide(nil)
            // Stays accessory while put away when summoning over full-screen apps (see `show`).
            NSApp.setActivationPolicy(showsOverFullScreen ? .accessory : .regular)
        }
    }

    /// The note and its child windows (edge ring, writing panel) together.
    private static func setAlpha(_ alpha: CGFloat, _ window: NSWindow) {
        ([window] + (window.childWindows ?? [])).forEach { $0.alphaValue = alpha }
    }

    private static func animate(_ alpha: CGFloat, _ window: NSWindow, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            ctx.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
            ([window] + (window.childWindows ?? [])).forEach { $0.animator().alphaValue = alpha }
        }, completionHandler: { MainActor.assumeIsolated { done?() } })
    }
}

/// The menu bar icon: a click calls the note window forward.
@MainActor enum SummonStatusItem {
    private static var item: NSStatusItem?
    private static let clicks = Clicks()

    static func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "long.text.page.and.pencil", accessibilityDescription: "Scratchpad")
        item.button?.target = clicks
        item.button?.action = #selector(Clicks.clicked)
        self.item = item
        setInUse(false)
    }

    /// Dimmed while the note is put away.
    static func setInUse(_ inUse: Bool) { item?.button?.alphaValue = inUse ? 1 : 0.5 }

    private final class Clicks: NSObject {
        // Next turn of the run loop: shown mid-click, the note is swept away when the full-screen app's
        // menu bar slides back up.
        @MainActor @objc func clicked() { DispatchQueue.main.async { MainActor.assumeIsolated { Summon.toggle() } } }
    }
}

/// Closing the note window with its close button or Cmd-W puts it away instead, so the app keeps running
/// (the menu bar icon and shortcut bring it back). Wraps SwiftUI's window delegate and forwards everything
/// but `windowShouldClose` to it.
@MainActor final class CloseToHide: NSObject, NSWindowDelegate {
    private static var current: CloseToHide?
    private let original: NSWindowDelegate?

    static func install(on window: NSWindow) {
        guard !(window.delegate is CloseToHide) else { return }
        let proxy = CloseToHide(original: window.delegate)
        current = proxy
        window.delegate = proxy
    }

    private init(original: NSWindowDelegate?) {
        self.original = original
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Summon.putAway(sender)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }
}

/// The global shortcut that calls Scratchpad forward, stored in UserDefaults and set in Settings.
@MainActor enum SummonShortcut {
    private static let keyCodeKey = "summonShortcutKeyCode"
    private static let modifiersKey = "summonShortcutModifiers"
    private static let labelKey = "summonShortcutLabel"
    private static var hotKey: EventHotKeyRef?
    private static var handlerInstalled = false

    /// The shortcut's text, such as "⌃⌥Space"; empty when cleared.
    static var label: String { UserDefaults.standard.string(forKey: labelKey) ?? "" }

    /// Registers the saved shortcut, defaulting to Command-' on first launch (and replacing the old ⌃⌥Space default).
    static func register() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: labelKey) == nil || defaults.string(forKey: labelKey) == "⌃⌥Space" {
            defaults.set(Int(kVK_ANSI_Quote), forKey: keyCodeKey)
            defaults.set(Int(cmdKey), forKey: modifiersKey)
            defaults.set("⌘'", forKey: labelKey)
        }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard !label.isEmpty else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { Summon.toggle() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5350_4b59), id: 1)
        RegisterEventHotKey(UInt32(defaults.integer(forKey: keyCodeKey)), UInt32(defaults.integer(forKey: modifiersKey)),
                            id, GetApplicationEventTarget(), 0, &hotKey)
    }

    /// Saves a new shortcut and registers it. An empty `label` clears it.
    static func set(keyCode: Int = 0, modifiers: Int = 0, label: String) {
        let defaults = UserDefaults.standard
        defaults.set(keyCode, forKey: keyCodeKey)
        defaults.set(modifiers, forKey: modifiersKey)
        defaults.set(label, forKey: labelKey)
        register()
    }

    /// The Carbon modifier bits and display text for a key press with `flags`.
    static func encode(_ flags: NSEvent.ModifierFlags, key: String) -> (modifiers: Int, label: String) {
        var carbon = 0
        var label = ""
        if flags.contains(.control) { carbon |= controlKey; label += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; label += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; label += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; label += "⌘" }
        return (carbon, label + (key == " " ? "Space" : key.uppercased()))
    }
}

/// Settings row: click, then press the new shortcut (it needs a modifier). Esc cancels; Clear turns it off.
struct SummonShortcutRecorder: View {
    @State private var label = SummonShortcut.label
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Show Scratchpad") {
            HStack(spacing: 6) {
                Button(recording ? "Press shortcut…" : (label.isEmpty ? "None" : label)) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 110)
                if !label.isEmpty && !recording {
                    Button("Clear") {
                        SummonShortcut.set(label: "")
                        label = ""
                    }
                }
            }
        }
        .help("Brings Scratchpad forward from any app, and puts it away when pressed again")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == kVK_Escape { stop(); return nil }
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard !flags.isDisjoint(with: [.command, .control, .option]),
                      let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
                let encoded = SummonShortcut.encode(flags, key: key)
                SummonShortcut.set(keyCode: Int(event.keyCode), modifiers: encoded.modifiers, label: encoded.label)
                label = encoded.label
                stop()
                return nil
            }
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
