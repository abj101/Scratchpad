import XCTest
@testable import CanvasKit

final class WritingLayoutTests: XCTestCase {
    func testScribePanelSizeStaysStableWhenDeviceAspectArrives() {
        let initial = LetterCell(margin: 0, top: 0, height: 32, deviceAspect: 1.6)
        for aspect: CGFloat in [1.5, 1.65, 2.0] {
            let measured = LetterCell(margin: 0, top: 0, height: 32, deviceAspect: aspect)
            let world = WritingLayout.scribePanelWorldRect(for: measured)
            XCTAssertTrue(world.contains(measured.rect))
            let expected = WritingLayout.panelSize(world: WritingLayout.scribePanelWorldRect(for: initial).size)
            let actual = WritingLayout.panelSize(world: world.size)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.001)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.001)
        }
    }

    private let acc: CGFloat = 1e-9

    private func assertRect(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: acc, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: acc, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: acc, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: acc, file: file, line: line)
    }

    private func stroke(_ pts: [(Double, Double)], width: Double = 2) -> Stroke {
        Stroke(points: pts.enumerated().map { StrokePoint(x: $1.0, y: $1.1, t: Double($0) * 0.01) },
               color: .black, width: width)
    }

    // MARK: initialCell

    func testInitialCellAtUnitMagnification() {
        let visible = CGRect(x: 200, y: 300, width: 800, height: 400)
        let cell = WritingLayout.initialCell(visible: visible, magnification: 1, height: 40, deviceAspect: 2)
        XCTAssertEqual(cell.margin, 248, accuracy: acc)
        XCTAssertEqual(cell.top, 400, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 248, accuracy: acc)
        XCTAssertEqual(cell.height, 40, accuracy: acc)
        XCTAssertEqual(cell.deviceAspect, 2, accuracy: acc)
    }

    func testInitialCellScalesMarginByMagnification() {
        let visible = CGRect(x: 200, y: 300, width: 400, height: 200)
        let cell = WritingLayout.initialCell(visible: visible, magnification: 2, height: 16, deviceAspect: 1.5)
        XCTAssertEqual(cell.margin, 224, accuracy: acc)
        XCTAssertEqual(cell.top, 350, accuracy: acc)
        XCTAssertEqual(cell.cursorX, cell.margin, accuracy: acc)
        XCTAssertEqual(cell.height, 16, accuracy: acc)
        XCTAssertEqual(cell.deviceAspect, 1.5, accuracy: acc)
    }

    func testDocumentCellUsesVisibleCaretOrVisibleColumnOrigin() {
        let visible = CGRect(x: 0, y: 200, width: 900, height: 600)
        let column = CGRect(x: 28, y: 72, width: 844, height: 2000)
        XCTAssertEqual(WritingLayout.documentCellOrigin(
            visible: visible, column: column, caret: CGRect(x: 180, y: 340, width: 0, height: 24)),
                       CGPoint(x: 180, y: 340))
        XCTAssertEqual(WritingLayout.documentCellOrigin(
            visible: visible, column: column, caret: CGRect(x: 180, y: 40, width: 0, height: 24)),
                       CGPoint(x: 28, y: 200))
    }

    // MARK: rightLimit

    func testRightLimitIsVisibleMaxXMinusMargin() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let cell = LetterCell(margin: 48, top: 0, height: 20, deviceAspect: 2)
        XCTAssertEqual(WritingLayout.rightLimit(visible: visible, magnification: 1, cell: cell), 952, accuracy: acc)
        XCTAssertEqual(WritingLayout.rightLimit(visible: visible, magnification: 2, cell: cell), 976, accuracy: acc)
    }

    func testRightLimitNeverLessThanTwoCellWidthsFromMargin() {
        let visible = CGRect(x: 0, y: 0, width: 100, height: 600)
        let cell = LetterCell(margin: 48, top: 0, height: 20, deviceAspect: 2)
        // visible.maxX - 48 = 52, but margin + 2 * 40 = 128.
        XCTAssertEqual(WritingLayout.rightLimit(visible: visible, magnification: 1, cell: cell), 128, accuracy: acc)
    }

    // MARK: letterExtent

    func testLetterExtentSingleStrokeGrownByHalfWidth() {
        let r = WritingLayout.letterExtent([stroke([(10, 20), (30, 25), (20, 50)], width: 4)])
        assertRect(r, CGRect(x: 8, y: 18, width: 24, height: 34))
    }

    func testLetterExtentUnionOfStrokes() {
        let a = stroke([(0, 0), (10, 10)], width: 2)
        let b = stroke([(40, 5), (50, 30)], width: 6)
        let r = WritingLayout.letterExtent([a, b])
        // a: (-1,-1)-(11,11); b: (37,2)-(53,33).
        assertRect(r, CGRect(x: -1, y: -1, width: 54, height: 34))
    }

    func testLetterExtentSinglePointStroke() {
        let r = WritingLayout.letterExtent([stroke([(5, 5)], width: 2)])
        assertRect(r, CGRect(x: 4, y: 4, width: 2, height: 2))
    }

    func testLetterExtentEmptyIsNull() {
        XCTAssertTrue(WritingLayout.letterExtent([]).isNull)
        XCTAssertTrue(WritingLayout.letterExtent([stroke([])]).isNull)
    }

    // MARK: panelWorldRect

    func testPanelWorldRectExtendsLeftByOneCellWidthWithVerticalPad() {
        var cell = LetterCell(margin: 100, top: 50, height: 10, deviceAspect: 2)
        cell.cursorX = 130
        let rect = WritingLayout.panelWorldRect(for: cell)
        let r = cell.rect // (130, 50, 20, 10)
        XCTAssertEqual(rect.maxX, r.maxX, accuracy: acc)
        XCTAssertEqual(rect.width, 2 * r.width, accuracy: acc)
        XCTAssertEqual(rect.minX, r.minX - r.width, accuracy: acc)
        XCTAssertEqual(rect.minY, r.minY - 0.8, accuracy: acc)
        XCTAssertEqual(rect.maxY, r.maxY + 0.8, accuracy: acc)
        XCTAssertEqual(rect.height, r.height + 1.6, accuracy: acc)
    }

    // MARK: panelSize

    func testPanelSizeUsesFixedWidthAndWorldAspect() {
        for world in [CGSize(width: 200, height: 100), CGSize(width: 100, height: 200)] {
            let size = WritingLayout.panelSize(world: world)
            XCTAssertEqual(size.width, WritingLayout.panelWidth, accuracy: acc)
            XCTAssertEqual(size.height / size.width, world.height / world.width, accuracy: acc)
        }
    }

    func testPanelSizeStaysTheSameForTheSameWorldAspect() {
        XCTAssertEqual(WritingLayout.panelSize(world: CGSize(width: 200, height: 100)),
                       WritingLayout.panelSize(world: CGSize(width: 400, height: 200)))
    }

    func testPanelSizeZeroForEmptyWorld() {
        XCTAssertEqual(WritingLayout.panelSize(world: .zero), .zero)
        XCTAssertEqual(WritingLayout.panelSize(world: CGSize(width: 0, height: 10)), .zero)
        XCTAssertEqual(WritingLayout.panelSize(world: CGSize(width: 10, height: 0)), .zero)
    }

    // MARK: followDelta

    private let visible = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testFollowDeltaZeroWhenInside() {
        let d = WritingLayout.followDelta(target: CGRect(x: 10, y: 10, width: 20, height: 20), visible: visible)
        XCTAssertEqual(d.dx, 0, accuracy: acc)
        XCTAssertEqual(d.dy, 0, accuracy: acc)
    }

    func testFollowDeltaWhenTargetSticksOutRight() {
        let d = WritingLayout.followDelta(target: CGRect(x: 90, y: 10, width: 20, height: 20), visible: visible)
        XCTAssertEqual(d.dx, 10, accuracy: acc)
        XCTAssertEqual(d.dy, 0, accuracy: acc)
    }

    func testFollowDeltaWhenTargetSticksOutBottom() {
        let d = WritingLayout.followDelta(target: CGRect(x: 10, y: 90, width: 20, height: 20), visible: visible)
        XCTAssertEqual(d.dx, 0, accuracy: acc)
        XCTAssertEqual(d.dy, 10, accuracy: acc)
    }

    func testFollowDeltaWhenTargetSticksOutLeft() {
        let d = WritingLayout.followDelta(target: CGRect(x: -15, y: 10, width: 20, height: 20), visible: visible)
        XCTAssertEqual(d.dx, -15, accuracy: acc)
        XCTAssertEqual(d.dy, 0, accuracy: acc)
    }

    func testFollowDeltaWhenTargetSticksOutTop() {
        let d = WritingLayout.followDelta(target: CGRect(x: 10, y: -5, width: 20, height: 20), visible: visible)
        XCTAssertEqual(d.dx, 0, accuracy: acc)
        XCTAssertEqual(d.dy, -5, accuracy: acc)
    }

    func testFollowDeltaTargetLargerThanVisibleAlignsLeadingEdge() {
        let d = WritingLayout.followDelta(target: CGRect(x: 20, y: 30, width: 200, height: 200), visible: visible)
        XCTAssertEqual(d.dx, 20, accuracy: acc)
        XCTAssertEqual(d.dy, 30, accuracy: acc)
    }

    // MARK: Scribe follow

    /// Free area 72 from the top of a 100pt viewport, so it ends at 172. A 10pt line means the
    /// caret rests with its bottom at 162 — one line above the panel's top edge.
    private let scribeFree = CGRect(x: 0, y: 72, width: 100, height: 100)

    func testScribeFollowDoesNothingWhileTheCaretHasRoom() {
        let d = WritingLayout.scribeFollowDelta(caret: CGRect(x: 10, y: 100, width: 0, height: 10),
                                                free: scribeFree, lineHeight: 10, xInset: 0)
        XCTAssertEqual(d.dx, 0, accuracy: acc)
        XCTAssertEqual(d.dy, 0, accuracy: acc)
    }

    func testScribeFollowLiftsTheCaretOneLineAboveThePanel() {
        // Crossed the resting line by anything up to a whole line: one step, so a new line is
        // one steady glide rather than a per-character nudge.
        for y in [153.0, 160.0, 162.0] {
            let d = WritingLayout.scribeFollowDelta(caret: CGRect(x: 10, y: y, width: 0, height: 10),
                                                    free: scribeFree, lineHeight: 10, xInset: 0)
            XCTAssertEqual(d.dy, 10, accuracy: acc, "caret at \(y)")
        }
    }

    func testScribeFollowStepsInWholeLines() {
        let d = WritingLayout.scribeFollowDelta(caret: CGRect(x: 10, y: 165, width: 0, height: 10),
                                                free: scribeFree, lineHeight: 10, xInset: 0)
        XCTAssertEqual(d.dy, 20, accuracy: acc)
    }

    func testScribeFollowPadsTheCaretSidewaysOnly() {
        let caret = CGRect(x: 10, y: 100, width: 0, height: 10)
        let padded = WritingLayout.scribeFollowDelta(caret: caret, free: scribeFree, lineHeight: 10, xInset: 24)
        XCTAssertEqual(padded.dx, -14, accuracy: acc)
        XCTAssertEqual(padded.dy, 0, accuracy: acc)
    }

    func testScribeFollowBringsACaretScrolledOffTheTopBack() {
        let d = WritingLayout.scribeFollowDelta(caret: CGRect(x: 10, y: 40, width: 0, height: 10),
                                                free: scribeFree, lineHeight: 10, xInset: 0)
        XCTAssertEqual(d.dy, -32, accuracy: acc)
    }

    // MARK: Chase

    func testChaseStepTakesAFractionOfWhatIsLeft() {
        let step = try? XCTUnwrap(WritingLayout.chaseStep(from: .zero, to: CGPoint(x: 0, y: 100),
                                                          dt: 1.0 / 60, timeConstant: 0.07))
        XCTAssertNotNil(step)
        XCTAssertGreaterThan(step?.y ?? 0, 0)
        XCTAssertLessThan(step?.y ?? 0, 100)
    }

    func testChaseStepIsFrameRateIndependent() {
        let slow = WritingLayout.chaseStep(from: .zero, to: CGPoint(x: 0, y: 100), dt: 1.0 / 60, timeConstant: 0.07)
        let half = WritingLayout.chaseStep(from: .zero, to: CGPoint(x: 0, y: 100), dt: 1.0 / 120, timeConstant: 0.07)
        let fast = half.flatMap { WritingLayout.chaseStep(from: $0, to: CGPoint(x: 0, y: 100),
                                                          dt: 1.0 / 120, timeConstant: 0.07) }
        XCTAssertEqual(slow?.y ?? 0, fast?.y ?? 0, accuracy: 0.1)
    }

    func testChaseStepReAimsAtANewTargetWithoutOvershooting() throws {
        var position = CGPoint.zero
        for _ in 0..<4 {
            position = try XCTUnwrap(WritingLayout.chaseStep(from: position, to: CGPoint(x: 0, y: 40),
                                                              dt: 1.0 / 60, timeConstant: 0.07))
        }
        let midGlide = position.y
        XCTAssertGreaterThan(midGlide, 0)

        // A new goal mid-flight: the next frame heads for it from where the glide is now.
        let goal = CGPoint(x: 0, y: 120)
        let next = try XCTUnwrap(WritingLayout.chaseStep(from: position, to: goal, dt: 1.0 / 60, timeConstant: 0.07))
        XCTAssertGreaterThan(next.y, midGlide)
        XCTAssertLessThan(next.y, goal.y)

        var frames = 0
        while let step = WritingLayout.chaseStep(from: position, to: goal, dt: 1.0 / 60, timeConstant: 0.07) {
            position = step
            frames += 1
            XCTAssertLessThanOrEqual(position.y, goal.y, "the chase never passes its target")
        }
        XCTAssertLessThanOrEqual(goal.y - position.y, 0.5 + acc, "the chase stops on the target")
        XCTAssertLessThan(frames, 60, "about a third of a second at 60 Hz")
    }

    // MARK: strokeSink

    private func drawLine(_ tc: ToolController) {
        tc.handle(PenEvent(phase: .began, point: CGPoint(x: 0, y: 0), timestamp: 0))
        for i in 1...5 {
            tc.handle(PenEvent(phase: .moved, point: CGPoint(x: Double(i) * 10, y: Double(i) * 10),
                               timestamp: Double(i) * 0.1))
        }
        tc.handle(PenEvent(phase: .ended, point: CGPoint(x: 50, y: 50), timestamp: 0.5))
    }

    func testStrokeSinkReceivesStrokeInsteadOfModel() {
        let model = CanvasModel()
        let settings = CanvasSettings()
        settings.tool = .pen
        let tc = ToolController(model: model, settings: settings)
        tc.smoothingEnabled = false
        var received: [Stroke] = []
        tc.strokeSink = { received.append($0) }
        drawLine(tc)
        XCTAssertEqual(received.count, 1)
        XCTAssertGreaterThanOrEqual(received[0].points.count, 5)
        XCTAssertTrue(model.strokes.isEmpty)
    }

    func testNoSinkAddsStrokeToModel() {
        let model = CanvasModel()
        let settings = CanvasSettings()
        settings.tool = .pen
        let tc = ToolController(model: model, settings: settings)
        tc.smoothingEnabled = false
        drawLine(tc)
        XCTAssertEqual(model.strokes.count, 1)
    }
}
