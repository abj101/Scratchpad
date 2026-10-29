import AppKit
import XCTest
@testable import CanvasKit

final class WritingPanelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suite = "WritingPanelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func note() throws -> NSWindow {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 100,
                                                  y: screen.visibleFrame.midY - 100,
                                                  width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testResizeKeepsTopLeftAndOtherNotesRestoreLastPlacement() throws {
        let note = try note()
        let otherNote = try self.note()
        let panel = WritingPanelWindow(defaults: defaults)
        let otherPanel = WritingPanelWindow(defaults: defaults)
        defer { panel.hide(); otherPanel.hide() }
        panel.show(beside: note, size: NSSize(width: 544, height: 200))
        let placed = panel.frame.offsetBy(dx: -60, dy: 40)
        panel.setFrame(placed, display: false)
        panel.savePosition()
        panel.show(beside: note, size: NSSize(width: 600, height: 350))
        XCTAssertEqual(panel.frame.minX, placed.minX)
        XCTAssertEqual(panel.frame.maxY, placed.maxY)
        XCTAssertTrue(panel.parent === note)

        // Temporary frame changes must not replace the user's saved position.
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 100, y: panel.frame.minY + 100))
        panel.hide()
        for _ in 0..<2 {
            panel.show(beside: note, size: NSSize(width: 544, height: 200))
            XCTAssertEqual(panel.frame.minX, placed.minX)
            XCTAssertEqual(panel.frame.maxY, placed.maxY)
            panel.hide()
        }
        otherPanel.show(beside: otherNote, size: NSSize(width: 544, height: 300))
        XCTAssertEqual(otherPanel.frame.minX, placed.minX)
        XCTAssertEqual(otherPanel.frame.maxY, placed.maxY)
    }

    func testPartialOffscreenPlacementStaysAndEntirelyOffscreenPlacementRecovers() throws {
        let note = try note()
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = WritingPanelWindow(defaults: defaults)
        defer { panel.hide() }
        let size = NSSize(width: 544, height: 200)
        let partial = NSRect(x: screen.frame.minX - 100, y: screen.frame.midY,
                             width: size.width, height: size.height)
        panel.setFrame(partial, display: false)
        panel.savePosition()
        panel.show(beside: note, size: size)
        XCTAssertEqual(panel.frame, partial)
        panel.hide()
        panel.setFrameOrigin(NSPoint(x: 1_000_000, y: 1_000_000))
        panel.savePosition()
        panel.show(beside: note, size: size)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) })
    }

    func testPanelSizeAndPositionIgnoreCanvasResize() throws {
        let savedPosition = UserDefaults.standard.object(forKey: "WritingPanelTopLeft")
        defer { UserDefaults.standard.set(savedPosition, forKey: "WritingPanelTopLeft") }
        let note = try note()
        let scroll = CanvasScrollView(model: CanvasModel(), settings: CanvasSettings())
        note.contentView = scroll
        let panel = scroll.writingPanel
        panel.cell = LetterCell(margin: 0, top: 0, height: 32, deviceAspect: 1.6)
        panel.isHidden = false
        defer { scroll.writingWindow.hide() }
        let frame = scroll.writingWindow.frame
        XCTAssertEqual(panel.frame.width, WritingLayout.panelWidth)
        for size in [NSSize(width: 20, height: 20), NSSize(width: 1000, height: 800)] {
            scroll.setFrameSize(size)
            scroll.tile()
            XCTAssertEqual(scroll.writingWindow.frame, frame)
            XCTAssertEqual(panel.frame.width, WritingLayout.panelWidth)
        }
    }

    func testNewPanelSpawnsAtBottomPlacementAndPlacementChangeResetsPosition() throws {
        let note = try note()
        let area = try XCTUnwrap(note.screen ?? NSScreen.main).visibleFrame
        let size = NSSize(width: 544, height: 200)
        let panel = WritingPanelWindow(defaults: defaults)
        defer { panel.hide() }
        panel.show(beside: note, size: size, placement: .middle)
        XCTAssertEqual(panel.frame.midX, area.midX, accuracy: 1)
        XCTAssertLessThan(panel.frame.minY - area.minY, 40)
        XCTAssertFalse(panel.frame.intersects(note.frame.insetBy(dx: 1, dy: 1)))

        panel.setFrameOrigin(NSPoint(x: area.minX + 300, y: area.midY))
        panel.savePosition()
        panel.show(beside: note, size: size, placement: .left)
        XCTAssertLessThan(panel.frame.minX - area.minX, 20)
        panel.show(beside: note, size: size, placement: .right)
        XCTAssertLessThan(area.maxX - panel.frame.maxX, 20)
    }
}
