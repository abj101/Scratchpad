import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainFrame = NSRect(x: 0, y: 0, width: 1100, height: 750)
        let window = NSWindow(
            contentRect: mainFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trackpad Spike"
        window.center()

        // Set content view to SpikeView
        let contentFrame = window.contentRect(forFrameRect: window.frame)
        window.contentView = SpikeView(frame: contentFrame)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)

        self.mainWindow = window

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Create and set menu bar
let mainMenu = NSMenu()

// App menu
let appMenu = NSMenu()
let quitItem = NSMenuItem(
    title: "Quit TrackpadSpike",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
)
appMenu.addItem(quitItem)

let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

app.mainMenu = mainMenu

// Set up and run
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
