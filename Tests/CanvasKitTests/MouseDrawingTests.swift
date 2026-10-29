import AppKit
import XCTest
@testable import CanvasKit

final class MouseDrawingTests: XCTestCase {
    func testClickDragAddsCanvasInkOnlyInRelativeMode() throws {
        for mode in InputMode.allCases {
            let settings = CanvasSettings()
            settings.inputMode = mode
            settings.handwritingToText = mode == .scribe
            let model = CanvasModel()
            let view = CanvasView(model: model, settings: settings)
            view.toolController.smoothingEnabled = false
            func event(_ type: NSEvent.EventType, x: CGFloat, time: TimeInterval) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 100),
                                               modifierFlags: [], timestamp: time, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            view.mouseDown(with: try event(.leftMouseDown, x: 100, time: 1))
            view.mouseDragged(with: try event(.leftMouseDragged, x: 120, time: 2))
            view.mouseUp(with: try event(.leftMouseUp, x: 140, time: 3))
            XCTAssertEqual(model.strokes.count, mode == .pen ? 1 : 0, "Click behavior in \(mode)")
            if mode == .pen {
                XCTAssertEqual(model.strokes.first?.points.count, 2)
                XCTAssertEqual(model.strokes.first?.width, settings.width)
            }
            XCTAssertEqual(settings.inputMode, mode)
            XCTAssertFalse(settings.penIsDown)
            XCTAssertNil(view.toolController.liveStroke)
        }
    }

    func testTrackpadPressDrawsInAbsoluteAndWritingModes() throws {
        for mode in [InputMode.tablet, .write, .scribe] {
            let settings = CanvasSettings()
            let model = CanvasModel()
            let scrollView = CanvasScrollView(model: model, settings: settings)
            scrollView.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
            scrollView.tile()
            let view = scrollView.canvasView
            settings.handwritingToText = mode == .scribe
            settings.inputMode = mode
            view.toolController.smoothingEnabled = false
            func touch(_ x: CGFloat, _ time: TimeInterval) {
                view.handleTouches([TouchSample(id: 1, normalized: CGPoint(x: x, y: 0.5))], timestamp: time)
            }
            func click(_ type: NSEvent.EventType, _ time: TimeInterval) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero,
                    modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
            }
            touch(0.4, 1)
            XCTAssertNil(view.toolController.liveStroke)
            view.mouseDown(with: try click(.leftMouseDown, 2))
            XCTAssertTrue(settings.penIsDown, "Press in \(mode)")
            // Absolute input waits for deliberate movement before laying ink.
            touch(0.6, 3)
            XCTAssertNotNil(view.toolController.liveStroke, "Stroke starts in \(mode)")
            touch(0.65, 3.5)
            XCTAssertGreaterThan(view.toolController.liveStroke?.points.count ?? 0, 1, "Movement in \(mode)")
            view.mouseUp(with: try click(.leftMouseUp, 4))
            XCTAssertFalse(settings.penIsDown)
            XCTAssertNil(view.toolController.liveStroke)
            XCTAssertEqual(model.strokes.count, mode == .tablet ? 1 : 0)
            touch(0.7, 5)
            XCTAssertNil(view.toolController.liveStroke, "Release stops ink in \(mode)")
            view.mouseDown(with: try click(.leftMouseDown, 6))
            touch(0.8, 7)
            XCTAssertNotNil(view.toolController.liveStroke)
            view.cancelGesture()
            XCTAssertFalse(settings.penIsDown)
            XCTAssertNil(view.toolController.liveStroke)
        }
    }

    func testClickDrawingPreservesRelativePenToggle() throws {
        let settings = CanvasSettings()
        settings.activation = .toggle
        let model = CanvasModel()
        let view = CanvasView(model: model, settings: settings)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                modifierFlags: [], timestamp: 1, windowNumber: 0,
                                                context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                                isARepeat: false, keyCode: PenKeyMonitor.spaceKeyCode))
        view.keyDown(with: key)
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero,
                                                  modifierFlags: [], timestamp: 1.1, windowNumber: 0,
                                                  context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                                  isARepeat: false, keyCode: PenKeyMonitor.spaceKeyCode))
        view.keyUp(with: keyUp)
        XCTAssertTrue(settings.penIsDown)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 100, y: 100),
                                                       modifierFlags: [], timestamp: 2, windowNumber: 0,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else { view.mouseUp(with: event) }
        }
        XCTAssertTrue(settings.penIsDown)
        XCTAssertEqual(model.strokes.count, 1)
        view.keyDown(with: key)
        XCTAssertFalse(settings.penIsDown)
    }

    func testEraserIgnoresPenKeyAndErasesOnlyOnClick() throws {
        let settings = CanvasSettings()
        settings.activation = .toggle
        let model = CanvasModel()
        let view = CanvasView(model: model, settings: settings)
        let stroke = Stroke(points: [StrokePoint(x: 0, y: 10, t: 0), StrokePoint(x: 40, y: 10, t: 1)],
                            color: .black, width: 2)
        model.undoManager.groupsByEvent = false
        model.undoManager.beginUndoGrouping()
        model.add(stroke)
        model.undoManager.endUndoGrouping()
        settings.tool = .eraser
        view.relativeSource.pointerLocation = { CGPoint(x: 5, y: 10) }

        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
            keyCode: PenKeyMonitor.spaceKeyCode))
        view.keyDown(with: key)
        view.relativeSource.pointerMoved(to: CGPoint(x: 20, y: 10), timestamp: 1.1)
        view.relativeSource.pointerMoved(to: CGPoint(x: 35, y: 10), timestamp: 1.2)
        XCTAssertFalse(settings.penIsDown)
        XCTAssertTrue(model.contains(id: stroke.id), "the pen key must not erase")
        XCTAssertFalse(view.penKeyDraws)
    }

    func testToggleStrokeCommitsBeforeSwitchingInputMode() throws {
        let settings = CanvasSettings()
        settings.activation = .toggle
        let model = CanvasModel()
        let view = CanvasView(model: model, settings: settings)
        view.toolController.smoothingEnabled = false
        view.relativeSource.pointerLocation = { CGPoint(x: 10, y: 10) }

        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
            keyCode: PenKeyMonitor.spaceKeyCode))
        view.keyDown(with: key)
        view.relativeSource.pointerMoved(to: CGPoint(x: 20, y: 10), timestamp: 1.1)
        XCTAssertNotNil(view.toolController.liveStroke)

        settings.inputMode = .tablet

        let stroke = try XCTUnwrap(model.strokes.first)
        XCTAssertTrue(model.allIDs.contains(stroke.id))
        XCTAssertEqual(model.hitObject(at: CGPoint(x: 15, y: 10), radius: 2), stroke.id)
        view.selection.pointerDown(at: CGPoint(x: 15, y: 10), extend: false, hitRadius: 2)
        XCTAssertEqual(view.selection.selection, [stroke.id])
        view.selection.deleteSelection()
        XCTAssertFalse(model.contains(id: stroke.id))
        XCTAssertNil(view.toolController.liveStroke)
    }

    func testWritingModeAndOptionKeysWithoutCommandShortcuts() throws {
        let settings = CanvasSettings()
        let view = CanvasView(model: CanvasModel(), settings: settings)
        func press(_ key: String, flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 18))
            view.keyDown(with: event)
        }
        // 4 enters and leaves Writing mode; leaving lands on the selector.
        for conversion in [false, true] {
            settings.handwritingToText = conversion
            try press("4")
            XCTAssertEqual(settings.inputMode, .scribe)
            try press("4")
            XCTAssertEqual(settings.inputMode, .pen)
            XCTAssertEqual(settings.tool, .pointer)
        }
        try press("4", flags: .command)
        XCTAssertEqual(settings.inputMode, .pen)
        // Options: Q text options, W color, E width.
        try press("q")
        XCTAssertTrue(settings.isTextOptionsOpen)
        try press("q")
        XCTAssertFalse(settings.isTextOptionsOpen)
        try press("w")
        XCTAssertEqual(settings.toolMenu, .color)
        try press("w")
        XCTAssertNil(settings.toolMenu)
        try press("e")
        XCTAssertEqual(settings.toolMenu, .width)
    }

    func testPickingAToolLeavesWritingMode() throws {
        let settings = CanvasSettings()
        let view = CanvasView(model: CanvasModel(), settings: settings)
        func press(_ key: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 18))
            view.keyDown(with: event)
        }
        try press("4")
        XCTAssertEqual(settings.inputMode, .scribe)
        try press("2")
        XCTAssertEqual(settings.inputMode, .pen, "Picking the pen must leave Writing mode")
        XCTAssertEqual(settings.tool, .pen)
        try press("4")
        XCTAssertEqual(settings.inputMode, .scribe)
        try press("1")
        XCTAssertEqual(settings.inputMode, .pen)
        XCTAssertEqual(settings.tool, .pointer, "Select exits Writing mode")
    }

    func testNumberToolShortcuts() throws {
        let settings = CanvasSettings()
        let view = CanvasView(model: CanvasModel(), settings: settings)
        for (key, tool) in [("1", Tool.pointer), ("2", .pen), ("3", .eraser)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            view.keyDown(with: event)
            XCTAssertEqual(settings.tool, tool)
        }
    }

    func testOptionMenusToggleWithoutChangingToolOrMode() throws {
        let settings = CanvasSettings()
        let view = CanvasView(model: CanvasModel(), settings: settings)
        settings.tool = .eraser
        settings.inputMode = .tablet
        let cases: [(String, NSEvent.ModifierFlags, FloatingToolMenu?)] = [
            ("w", .command, nil), ("w", [], .color), ("w", [], nil),
            ("e", [], .width), ("w", [], .color), ("e", [], .width), ("e", [], nil),
        ]
        for (key, flags, menu) in cases {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 8))
            view.keyDown(with: event)
            XCTAssertEqual(settings.toolMenu, menu)
            XCTAssertEqual(settings.tool, .eraser)
            XCTAssertEqual(settings.inputMode, .tablet)
        }
    }

    func testLegacyClickPreferenceLoadsAsPen() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("click", forKey: "settings.inputMode")
        let settings = CanvasSettings()
        _ = SettingsPersistence(settings: settings, defaults: defaults)
        XCTAssertEqual(settings.inputMode, .pen)
    }
}
