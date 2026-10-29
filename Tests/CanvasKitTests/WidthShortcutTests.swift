import AppKit
import XCTest
@testable import CanvasKit

final class WidthShortcutTests: XCTestCase {
    private func key(_ value: String, type: NSEvent.EventType = .keyDown, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                      timestamp: 1, windowNumber: 0, context: nil,
                                      characters: value, charactersIgnoringModifiers: value,
                                      isARepeat: repeatKey, keyCode: value == "e" ? 14 : 0))
    }

    private func scroll(_ delta: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                      wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testHoldEScrollAdjustsWidthAndReleaseClosesTemporaryMenu() throws {
        let settings = CanvasSettings()
        let view = CanvasView(model: CanvasModel(), settings: settings)
        settings.inputMode = .tablet
        defer { settings.inputMode = .pen }
        try view.keyDown(with: key("e"))
        XCTAssertEqual(settings.toolMenu, .width)
        XCTAssertFalse(view.isCursorLocked)
        try view.keyDown(with: key("e", repeatKey: true))
        XCTAssertEqual(settings.toolMenu, .width)
        let before = settings.width
        let event = try scroll(-10)
        let toolbarSettings = CanvasSettings()
        toolbarSettings.width = before
        toolbarSettings.adjustWidthForScroll(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
        XCTAssertTrue(view.handleWidthScroll(event))
        XCTAssertEqual(settings.width, toolbarSettings.width)
        XCTAssertGreaterThan(settings.width, before)
        try view.keyUp(with: key("e", type: .keyUp))
        XCTAssertNil(settings.toolMenu)
        XCTAssertFalse(try view.handleWidthScroll(scroll(-10)))
    }

    func testEraserRingStaysVisibleAndGrowsWhileHoldingWidthHotkey() throws {
        let settings = CanvasSettings()
        settings.tool = .eraser
        settings.width = 6
        let view = CanvasView(model: CanvasModel(), settings: settings)
        try view.keyDown(with: key("e"))
        XCTAssertEqual(settings.toolMenu, .width)
        let smallWidth = view.currentCursor().image.size.width
        XCTAssertFalse(view.currentCursor() === NSCursor.arrow, "The ring must stay under the pointer while adjusting width")
        XCTAssertTrue(view.handleWidthScroll(try scroll(-60)))
        XCTAssertGreaterThan(settings.width, 6)
        // The ring eases toward the new size; let its animation settle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(view.currentCursor() === NSCursor.arrow)
        XCTAssertGreaterThan(view.currentCursor().image.size.width, smallWidth, "The ring must grow as the width rises")
        try view.keyUp(with: key("e", type: .keyUp))
        XCTAssertNil(settings.toolMenu)
    }

    func testScrollSensitivityTracksGestureDelta() {
        let settings = CanvasSettings()
        settings.width = 50
        settings.adjustWidthForScroll(delta: -1, precise: true)
        XCTAssertEqual(settings.width, 50.1, accuracy: 0.0001)
        settings.adjustWidthForScroll(delta: -10, precise: true)
        XCTAssertEqual(settings.width, 51.1, accuracy: 0.0001)
        settings.adjustWidthForScroll(delta: 1, precise: false)
        XCTAssertEqual(settings.width, 48.6, accuracy: 0.0001)
    }

    func testWidthPreviewKeepsGrowingAcrossFullRange() {
        let settings = CanvasSettings()
        let widths = [0.5, 25, 50, 75, 100]
        let fractions = widths.map { width in
            settings.width = width
            return settings.widthPreviewFraction
        }
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        for (before, after) in zip(fractions, fractions.dropFirst()) {
            XCTAssertGreaterThan(after, before)
        }
        settings.width = 200
        XCTAssertEqual(settings.widthPreviewFraction, 1)
    }

    func testTapEStillTogglesMenu() throws {
        let settings = CanvasSettings()
        let view = CanvasView(model: CanvasModel(), settings: settings)
        try view.keyDown(with: key("e"))
        try view.keyUp(with: key("e", type: .keyUp))
        XCTAssertEqual(settings.toolMenu, .width)
        try view.keyDown(with: key("e"))
        try view.keyUp(with: key("e", type: .keyUp))
        XCTAssertNil(settings.toolMenu)
    }

    func testMenusFreeCursorAndSuspendTabletInputInEveryAbsoluteMode() throws {
        for mode in [InputMode.tablet, .write, .scribe] {
            let settings = CanvasSettings()
            settings.handwritingToText = mode == .scribe
            let model = CanvasModel()
            let view = CanvasView(model: model, settings: settings)
            settings.inputMode = mode
            defer { settings.inputMode = .pen }
            for shortcut in ["w", "e"] {
                try view.keyDown(with: key(shortcut))
                XCTAssertFalse(view.isCursorLocked, "Menu in \(mode)")
                XCTAssertTrue(view.currentCursor() === NSCursor.arrow)
                view.handleTouches([TouchSample(id: 1, normalized: CGPoint(x: 0.4, y: 0.5))], timestamp: 1)
                let pen = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil,
                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                    keyCode: PenKeyMonitor.spaceKeyCode))
                view.keyDown(with: pen)
                view.handleTouches([TouchSample(id: 1, normalized: CGPoint(x: 0.8, y: 0.5))], timestamp: 3)
                XCTAssertFalse(settings.penIsDown)
                XCTAssertNil(view.toolController.liveStroke)
                XCTAssertTrue(model.strokes.isEmpty)
                try view.keyUp(with: key(shortcut, type: .keyUp))
                XCTAssertEqual(settings.inputMode, mode)
            }
        }
    }
}
