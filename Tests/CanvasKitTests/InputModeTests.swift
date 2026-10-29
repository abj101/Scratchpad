import XCTest
@testable import CanvasKit

// MARK: - Recording sink for test assertions

final class RecordingSink: PenEventSink {
    var events: [PenEvent] = []

    func handle(_ event: PenEvent) {
        events.append(event)
    }

    var phases: [PenPhase] {
        events.map(\.phase)
    }
}

// MARK: - TabletMapping tests

final class TabletMappingTests: XCTestCase {

    func testDefaultAspect() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        XCTAssertEqual(mapping.deviceAspect, TabletMapping.defaultAspect)
    }

    func testSetDeviceSize() {
        var mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        mapping.setDeviceSize(CGSize(width: 200, height: 100))
        // Wide device (2:1 aspect)
        XCTAssertEqual(mapping.deviceAspect, 2.0)
    }

    func testSetDeviceSizeIgnoresNonPositive() {
        var mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let original = mapping.deviceAspect
        mapping.setDeviceSize(.zero)
        XCTAssertEqual(mapping.deviceAspect, original)
    }

    func testWorldPointNormalized00Bottom() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let world = mapping.worldPoint(normalized: CGPoint(x: 0, y: 0))
        // (0, 0) in normalized space is bottom-left, which should map to min X, max Y in world
        XCTAssertEqual(world.x, mapping.activeRect.minX)
        XCTAssertEqual(world.y, mapping.activeRect.maxY)
    }

    func testWorldPointNormalized11Top() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let world = mapping.worldPoint(normalized: CGPoint(x: 1, y: 1))
        // (1, 1) is top-right in normalized space
        XCTAssertEqual(world.x, mapping.activeRect.maxX)
        XCTAssertEqual(world.y, mapping.activeRect.minY)
    }

    func testWorldPointClampingBelow0() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let world = mapping.worldPoint(normalized: CGPoint(x: -0.5, y: -0.5))
        // Should clamp to 0...1 range
        XCTAssertEqual(world.x, mapping.activeRect.minX)
        XCTAssertEqual(world.y, mapping.activeRect.maxY)
    }

    func testWorldPointClampingAbove1() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let world = mapping.worldPoint(normalized: CGPoint(x: 1.5, y: 1.5))
        // Should clamp to 0...1 range
        XCTAssertEqual(world.x, mapping.activeRect.maxX)
        XCTAssertEqual(world.y, mapping.activeRect.minY)
    }

    func testActivateRectAspectFitWide() {
        // Wide visible rect, narrow trackpad (default 1.6 aspect = wide)
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 100)
        let mapping = TabletMapping(visibleWorldRect: wide, inset: 0)
        let active = mapping.activeRect

        // Active rect should be height-limited and centered
        XCTAssertLessThanOrEqual(active.height, 100)
        XCTAssertGreaterThan(active.width, 0)
        // Check it's centered
        XCTAssertEqual(active.minY + active.height / 2, wide.minY + wide.height / 2)
    }

    func testActivateRectAspectFitTall() {
        // Tall visible rect
        var mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 1000), inset: 0)
        mapping.setDeviceSize(CGSize(width: 100, height: 1000)) // Tall trackpad (0.1 aspect)
        let active = mapping.activeRect

        // Active rect should be width-limited
        XCTAssertLessThanOrEqual(active.width, 100)
        // Check it's centered horizontally
        XCTAssertEqual(active.minX + active.width / 2, 50)
    }

    func testInsetApplied() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let mapping = TabletMapping(visibleWorldRect: rect, inset: 20)
        let active = mapping.activeRect

        // 160×160 after inset, then aspect-fitted to the default 1.6 → 160×100, centered.
        XCTAssertEqual(active.width, 160, accuracy: 0.001)
        XCTAssertEqual(active.height, 100, accuracy: 0.001)
        XCTAssertEqual(active.midX, 100, accuracy: 0.001)
        XCTAssertEqual(active.midY, 100, accuracy: 0.001)
    }

    func testInsetEmptyDoesNotApply() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Inset too large; should not apply
        let mapping = TabletMapping(visibleWorldRect: rect, inset: 200)
        let active = mapping.activeRect

        // Should use full rect instead
        XCTAssertGreaterThan(active.width, 0)
        XCTAssertGreaterThan(active.height, 0)
    }

    func testZoomLevels() {
        var mapping0_5 = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        mapping0_5.visibleWorldRect = CGRect(x: 0, y: 0, width: 200, height: 200) // zoom 0.5

        let mapping1 = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let mapping4 = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 25, height: 25), inset: 0)

        // All should have activeRect with positive dimensions
        let active0_5 = mapping0_5.activeRect
        let active1 = mapping1.activeRect
        let active4 = mapping4.activeRect

        XCTAssertGreaterThan(active0_5.width, 0)
        XCTAssertGreaterThan(active1.width, 0)
        XCTAssertGreaterThan(active4.width, 0)
    }
}

// MARK: - PenKeyMonitor tests

final class PenKeyMonitorTests: XCTestCase {

    func testHoldModeSpaceKey() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        // Space down
        monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertEqual(monitor.isPenDown, true)
        XCTAssertEqual(transitions, [.down])

        // Space up
        transitions.removeAll()
        monitor.keyUp(keyCode: PenKeyMonitor.spaceKeyCode)
        XCTAssertEqual(monitor.isPenDown, false)
        XCTAssertEqual(transitions, [.up])
    }

    func testToggleModeSpaceKey() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .toggle)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        // First press
        monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertEqual(monitor.isPenDown, true)
        XCTAssertEqual(transitions, [.down])

        // Release (no emission)
        transitions.removeAll()
        monitor.keyUp(keyCode: PenKeyMonitor.spaceKeyCode)
        XCTAssertEqual(transitions, [])
        XCTAssertEqual(monitor.isPenDown, true)

        // Second press (toggle off)
        transitions.removeAll()
        monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertEqual(monitor.isPenDown, false)
        XCTAssertEqual(transitions, [.up])
    }

    func testKeyRepeatsIgnored() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        // First press
        monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertEqual(transitions.count, 1)

        // Repeat (should be ignored)
        transitions.removeAll()
        let consumed = monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: true)
        XCTAssertEqual(transitions, [])
        XCTAssertTrue(consumed)
    }

    func testNonPenKeyReturnsFalse() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .hold)
        let consumed = monitor.keyDown(keyCode: 123, isRepeat: false)
        XCTAssertFalse(consumed)
    }

    func testCancel() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertEqual(monitor.isPenDown, true)

        transitions.removeAll()
        monitor.cancel()
        XCTAssertEqual(monitor.isPenDown, false)
        XCTAssertEqual(transitions, [.cancelled])
    }

    func testCancelWhenNotDown() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.cancel()
        XCTAssertEqual(transitions, [])
    }

    func testChangePenKeyWhileDown() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertEqual(transitions, [.down])

        transitions.removeAll()
        monitor.penKey = .option
        // Changing penKey while down should emit cancelled
        XCTAssertEqual(monitor.isPenDown, false)
        XCTAssertEqual(transitions, [.cancelled])
    }

    func testChangeActivationWhileDown() {
        let monitor = PenKeyMonitor(penKey: .space, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false)
        XCTAssertEqual(transitions, [.down])

        transitions.removeAll()
        monitor.activation = .toggle
        // Changing activation while down should emit cancelled
        XCTAssertEqual(monitor.isPenDown, false)
        XCTAssertEqual(transitions, [.cancelled])
    }
}

// MARK: - RelativeInputSource tests

final class RelativeInputSourceTests: XCTestCase {

    func testPenDownArmsWithoutDrawing() {
        let source = RelativeInputSource()
        let sink = RecordingSink()
        source.sink = sink

        source.pointerLocation = { CGPoint(x: 10, y: 20) }
        source.penChanged(.down, timestamp: 1.0)

        XCTAssertEqual(source.isPenDown, true)
        XCTAssertEqual(source.isDrawing, false)
        XCTAssertEqual(sink.events.count, 0, "a key press alone must not place ink")
    }

    func testPenUpWithoutMovementLeavesNoStroke() {
        let source = RelativeInputSource()
        let sink = RecordingSink()
        source.sink = sink

        source.pointerLocation = { CGPoint(x: 10, y: 20) }
        source.penChanged(.down, timestamp: 1.0)
        source.pointerMoved(to: CGPoint(x: 10, y: 20), timestamp: 1.1) // no actual movement
        source.penChanged(.up, timestamp: 2.0)

        XCTAssertEqual(source.isPenDown, false)
        XCTAssertEqual(sink.events.count, 0)
    }

    func testPenUpEndsStroke() {
        let source = RelativeInputSource()
        let sink = RecordingSink()
        source.sink = sink

        source.pointerLocation = { CGPoint(x: 10, y: 20) }
        source.penChanged(.down, timestamp: 1.0)
        source.pointerMoved(to: CGPoint(x: 15, y: 25), timestamp: 1.1)

        sink.events.removeAll()
        source.penChanged(.up, timestamp: 2.0)

        XCTAssertEqual(source.isPenDown, false)
        XCTAssertEqual(sink.phases, [.ended])
    }

    func testPointerMovedWhilePenUp() {
        let source = RelativeInputSource()
        let sink = RecordingSink()
        source.sink = sink

        source.pointerLocation = { CGPoint(x: 10, y: 20) }
        source.pointerMoved(to: CGPoint(x: 15, y: 25), timestamp: 1.0)

        XCTAssertEqual(sink.events.count, 0)
    }

    func testFirstMovementBeginsAtArmingPoint() {
        let source = RelativeInputSource()
        let sink = RecordingSink()
        source.sink = sink

        source.pointerLocation = { CGPoint(x: 10, y: 20) }
        source.penChanged(.down, timestamp: 1.0)
        source.pointerMoved(to: CGPoint(x: 15, y: 25), timestamp: 1.1)

        XCTAssertEqual(sink.phases, [.began, .moved])
        XCTAssertEqual(sink.events[0].point, CGPoint(x: 10, y: 20))
        XCTAssertEqual(sink.events[1].point, CGPoint(x: 15, y: 25))

        sink.events.removeAll()
        source.pointerMoved(to: CGPoint(x: 20, y: 30), timestamp: 1.2)
        XCTAssertEqual(sink.phases, [.moved])
    }

    func testCancelStroke() {
        let source = RelativeInputSource()
        let sink = RecordingSink()
        source.sink = sink

        source.pointerLocation = { CGPoint(x: 10, y: 20) }
        source.penChanged(.down, timestamp: 1.0)
        source.pointerMoved(to: CGPoint(x: 15, y: 25), timestamp: 1.1)

        sink.events.removeAll()
        source.cancelStroke(timestamp: 1.5)

        XCTAssertEqual(source.isDrawing, false)
        XCTAssertEqual(sink.phases, [.cancelled])
    }

    func testPointerMovedWhenLocationUnknown() {
        let source = RelativeInputSource()
        let sink = RecordingSink()
        source.sink = sink

        source.pointerLocation = { nil }
        source.penChanged(.down, timestamp: 1.0)

        XCTAssertEqual(source.isDrawing, false)
        XCTAssertEqual(sink.events.count, 0)

        // Now provide location
        source.pointerLocation = { CGPoint(x: 10, y: 20) }
        source.pointerMoved(to: CGPoint(x: 10, y: 20), timestamp: 1.1)

        XCTAssertEqual(source.isDrawing, true)
        XCTAssertEqual(sink.phases, [.began])
    }
}

// MARK: - TabletInputSource tests

final class TabletInputSourceTests: XCTestCase {

    func testFingerDownBeginsStroke() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let source = TabletInputSource(mapping: mapping)
        let sink = RecordingSink()
        source.sink = sink

        source.penChanged(.down, timestamp: 1.0)
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 1.0)

        XCTAssertEqual(sink.phases, [.began])
        XCTAssertEqual(source.isDrawing, true)
    }

    func testFingerLiftEndsStroke() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let source = TabletInputSource(mapping: mapping)
        let sink = RecordingSink()
        source.sink = sink

        source.penChanged(.down, timestamp: 1.0)
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 1.0)

        sink.events.removeAll()
        source.touchesChanged([], timestamp: 1.1)

        XCTAssertEqual(sink.phases, [.ended])
        XCTAssertEqual(source.isDrawing, false)
    }

    func testFingerLiftMidStroke() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let source = TabletInputSource(mapping: mapping)
        let sink = RecordingSink()
        source.sink = sink

        source.penChanged(.down, timestamp: 1.0)
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 1.0)

        sink.events.removeAll()
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.6, y: 0.6))], timestamp: 1.05)

        let hasMoved = sink.phases.contains(.moved)
        XCTAssertTrue(hasMoved)

        sink.events.removeAll()
        source.touchesChanged([], timestamp: 1.1)

        XCTAssertEqual(sink.phases, [.ended])
    }

    private func finger(_ id: Int, _ x: Double, _ y: Double) -> TouchSample {
        TouchSample(id: AnyHashable(id), normalized: CGPoint(x: x, y: y))
    }

    func testTwoFingersWithPenUpSuspends() {
        let source = TabletInputSource(mapping: TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0))
        let sink = RecordingSink()
        source.sink = sink

        source.touchesChanged([finger(1, 0.5, 0.5)], timestamp: 1.0)
        source.touchesChanged([finger(1, 0.5, 0.5), finger(2, 0.3, 0.3)], timestamp: 1.05)

        XCTAssertTrue(source.isSuspended)
        XCTAssertNil(source.hoverPoint)

        // Pen goes down with no stale suspension left once only one finger remains.
        source.touchesChanged([], timestamp: 1.1)
        XCTAssertFalse(source.isSuspended)
    }

    func testExtraContactWhilePenDownIsIgnored() {
        let source = TabletInputSource(mapping: TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0))
        let sink = RecordingSink()
        source.sink = sink

        source.penChanged(.down, timestamp: 1.0)
        source.touchesChanged([finger(1, 0.5, 0.5)], timestamp: 1.0)
        sink.events.removeAll()

        // A palm lands low on the pad; the drawing finger moves on.
        source.touchesChanged([finger(1, 0.6, 0.5), finger(2, 0.5, 0.05)], timestamp: 1.05)

        XCTAssertEqual(sink.phases, [.moved])
        XCTAssertFalse(source.isSuspended)
        XCTAssertTrue(source.isDrawing)
    }

    func testPenDownWithTwoContactsDrawsWithTheHighestOne() {
        let source = TabletInputSource(mapping: TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0))
        let sink = RecordingSink()
        source.sink = sink

        source.touchesChanged([finger(1, 0.5, 0.1)], timestamp: 1.0)
        source.touchesChanged([finger(1, 0.5, 0.1), finger(2, 0.5, 0.8)], timestamp: 1.02)
        XCTAssertTrue(source.isSuspended)

        source.penChanged(.down, timestamp: 1.05)

        XCTAssertFalse(source.isSuspended)
        XCTAssertEqual(sink.phases, [], "armed, not drawing, until the finger moves")

        source.touchesChanged([finger(1, 0.5, 0.1), finger(2, 0.6, 0.8)], timestamp: 1.1)
        XCTAssertTrue(source.isDrawing)
        XCTAssertEqual(sink.phases, [.began])
        XCTAssertLessThan(sink.events.last?.point.y ?? 100, 50, "uses the upper contact (world y is down)")
    }

    func testResumesAfterAllFingersLift() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let source = TabletInputSource(mapping: mapping)
        let sink = RecordingSink()
        source.sink = sink

        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 1.0)

        // Two fingers
        source.touchesChanged([
            TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5)),
            TouchSample(id: AnyHashable(2), normalized: CGPoint(x: 0.3, y: 0.3))
        ], timestamp: 1.05)

        XCTAssertTrue(source.isSuspended)

        // Both lift
        sink.events.removeAll()
        source.touchesChanged([], timestamp: 1.1)

        XCTAssertFalse(source.isSuspended)
        XCTAssertEqual(sink.phases, [])

        // Touch again
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.7, y: 0.7))], timestamp: 1.15)

        XCTAssertFalse(source.isSuspended)
        XCTAssertFalse(source.isDrawing, "pen is up")
        XCTAssertNotNil(source.hoverPoint)
    }

    func testDifferentFingerStartsNewStroke() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let source = TabletInputSource(mapping: mapping)
        let sink = RecordingSink()
        source.sink = sink

        source.penChanged(.down, timestamp: 1.0)
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 1.0)

        XCTAssertEqual(sink.phases, [.began])

        sink.events.removeAll()
        // Different finger touches (without lifting first)
        source.touchesChanged([TouchSample(id: AnyHashable(2), normalized: CGPoint(x: 0.3, y: 0.3))], timestamp: 1.05)

        // Should end first stroke and begin new one
        XCTAssertTrue(sink.phases.contains(.ended))
        XCTAssertTrue(sink.phases.contains(.began))
    }

    func testJumpWithoutConnectingLine() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let source = TabletInputSource(mapping: mapping)
        let sink = RecordingSink()
        source.sink = sink

        source.penChanged(.down, timestamp: 1.0)
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.2, y: 0.2))], timestamp: 1.0)

        // First stroke at one point
        XCTAssertEqual(sink.phases, [.began])

        sink.events.removeAll()
        // Lift and touch elsewhere with different id
        source.touchesChanged([], timestamp: 1.05)

        source.touchesChanged([TouchSample(id: AnyHashable(2), normalized: CGPoint(x: 0.8, y: 0.8))], timestamp: 1.1)

        // Should have ended first stroke and begun second at new location
        let phases = sink.phases
        XCTAssertTrue(phases.contains(.ended))
        XCTAssertTrue(phases.contains(.began))

        // Find the began event and check it's at the new location
        if let beganIdx = phases.lastIndex(of: .began) {
            let beganEvent = sink.events[beganIdx]
            let newPoint = mapping.worldPoint(normalized: CGPoint(x: 0.8, y: 0.8))
            XCTAssertEqual(beganEvent.point.x, newPoint.x, accuracy: 1)
            XCTAssertEqual(beganEvent.point.y, newPoint.y, accuracy: 1)
        }
    }

    func testPenDownWhileHovering() {
        let mapping = TabletMapping(visibleWorldRect: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 0)
        let source = TabletInputSource(mapping: mapping)
        let sink = RecordingSink()
        source.sink = sink

        // Finger down (no pen yet)
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 1.0)

        XCTAssertEqual(sink.events.count, 0)

        // Now pen down
        sink.events.removeAll()
        source.penChanged(.down, timestamp: 1.05)

        // A resting finger must not stamp a dot: nothing until it moves.
        XCTAssertEqual(sink.phases, [])
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.501, y: 0.5))], timestamp: 1.06)
        XCTAssertEqual(sink.phases, [])

        // Real movement starts the stroke at the finger's current position.
        source.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.6, y: 0.5))], timestamp: 1.1)
        XCTAssertEqual(sink.phases, [.began])
        let p = mapping.worldPoint(normalized: CGPoint(x: 0.6, y: 0.5))
        XCTAssertEqual(sink.events[0].point.x, p.x, accuracy: 1)
        XCTAssertEqual(sink.events[0].point.y, p.y, accuracy: 1)

        // Lifting after a toggle-on with no movement draws nothing.
        let quiet = RecordingSink()
        let other = TabletInputSource(mapping: mapping)
        other.sink = quiet
        other.touchesChanged([TouchSample(id: AnyHashable(1), normalized: CGPoint(x: 0.5, y: 0.5))], timestamp: 2.0)
        other.penChanged(.down, timestamp: 2.05)
        other.touchesChanged([], timestamp: 2.1)
        XCTAssertEqual(quiet.phases, [])
    }
}

// MARK: - Additional coverage

final class TabletMappingCornerTests: XCTestCase {

    func testCornersAndEdges() {
        // 160×100 visible rect matches the default aspect exactly, so activeRect == visible rect.
        let rect = CGRect(x: -80, y: -50, width: 160, height: 100)
        let mapping = TabletMapping(visibleWorldRect: rect, inset: 0)
        XCTAssertEqual(mapping.activeRect, rect)

        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 1), CGPoint(x: -80, y: -50)), // top-left
            (CGPoint(x: 1, y: 1), CGPoint(x: 80, y: -50)),  // top-right
            (CGPoint(x: 0, y: 0), CGPoint(x: -80, y: 50)),  // bottom-left
            (CGPoint(x: 1, y: 0), CGPoint(x: 80, y: 50)),   // bottom-right
            (CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: -50)), // top edge
            (CGPoint(x: 0, y: 0.5), CGPoint(x: -80, y: 0)), // left edge
            (CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0, y: 0)), // center
        ]
        for (n, expected) in cases {
            let p = mapping.worldPoint(normalized: n)
            XCTAssertEqual(p.x, expected.x, accuracy: 0.001, "\(n)")
            XCTAssertEqual(p.y, expected.y, accuracy: 0.001, "\(n)")
        }
    }
}

final class PenKeyModifierTests: XCTestCase {

    func testOptionHoldViaFlags() {
        let monitor = PenKeyMonitor(penKey: .option, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.flagsChanged(option: false, function: true) // other modifier ignored
        monitor.flagsChanged(option: true, function: true)
        monitor.flagsChanged(option: true, function: false) // still held, no edge
        monitor.flagsChanged(option: false, function: false)
        XCTAssertEqual(transitions, [.down, .up])
        // Space is not the pen key, so it must pass through.
        XCTAssertFalse(monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false))
    }

    func testFnToggleViaFlags() {
        let monitor = PenKeyMonitor(penKey: .fn, activation: .toggle)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.flagsChanged(option: false, function: true)
        monitor.flagsChanged(option: false, function: false)
        XCTAssertTrue(monitor.isPenDown)
        monitor.flagsChanged(option: false, function: true)
        monitor.flagsChanged(option: false, function: false)
        XCTAssertFalse(monitor.isPenDown)
        XCTAssertEqual(transitions, [.down, .up])
    }

    func testCancelWhileModifierHeldNeedsFreshPress() {
        let monitor = PenKeyMonitor(penKey: .option, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.flagsChanged(option: true, function: false)
        monitor.cancel() // e.g. window resigned key while Option held
        monitor.flagsChanged(option: false, function: false) // stale release ignored
        XCTAssertEqual(transitions, [.down, .cancelled])
        XCTAssertFalse(monitor.isPenDown)
    }

    func testSpaceKeyReturnsAfterTemporaryOptionMode() {
        let monitor = PenKeyMonitor(penKey: .option, activation: .hold)
        var transitions: [PenTransition] = []
        monitor.onTransition = { transitions.append($0) }

        monitor.flagsChanged(option: true, function: false)
        monitor.penKey = .space
        XCTAssertEqual(transitions, [.down, .cancelled])
        monitor.flagsChanged(option: true, function: false)
        XCTAssertFalse(monitor.isPenDown)
        XCTAssertTrue(monitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false))
        XCTAssertTrue(monitor.isPenDown)
    }
}

// MARK: - InputMode

final class InputModeTests: XCTestCase {
    func testAllCasesOrder() {
        XCTAssertEqual(InputMode.allCases, [.pen, .tablet, .write, .scribe])
    }

    func testWriteDisplayName() {
        XCTAssertEqual(InputMode.write.displayName, "Write")
    }

    func testUsesTabletInputOnlyForTabletAndWrite() {
        XCTAssertFalse(InputMode.pen.usesTabletInput)
        XCTAssertTrue(InputMode.tablet.usesTabletInput)
        XCTAssertTrue(InputMode.write.usesTabletInput)
    }

    func testWriteHintHoldSpace() {
        XCTAssertEqual(InputMode.write.hint(penKey: .space, activation: .hold),
                       "Hold Space to write · → next word · Return new line · Esc to exit")
    }

    func testWriteHintToggleSpace() throws {
        let hint = try XCTUnwrap(InputMode.write.hint(penKey: .space, activation: .toggle))
        XCTAssertTrue(hint.hasPrefix("Press Space to toggle pen"))
        XCTAssertTrue(hint.contains("Return new line"))
    }

}
