#if DEBUG
import XCTest
@testable import CanvasKit

final class GlyphCaptureTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private let ink = Stroke(points: [StrokePoint(x: 12.25, y: -3, t: 0), StrokePoint(x: 13, y: 6, t: 0.125)],
                             color: RGBA(r: 0.2, g: 0.4, b: 0.8, a: 0.7), width: 2.5)
    private let cell = CGRect(x: 10, y: -5, width: 32, height: 40)

    func testRawRecordResumeFivePerLabelAndRedo() throws {
        let capture = try GlyphCapture(directory: directory, labels: ["-", "−"])
        try capture.save([ink], cell: cell)
        let first = try XCTUnwrap(capture.files["-"]?.first)
        let data = try Data(contentsOf: first)
        let record = try JSONDecoder().decode(GlyphCapture.Record.self, from: data)
        XCTAssertEqual(record.label, "-")
        XCTAssertEqual(record.codepoints, ["U+002D"])
        XCTAssertEqual(record.writer, "ayush")
        XCTAssertEqual(record.split, "test")
        XCTAssertEqual(record.strokes, [[[12.25, -3, 0], [13, 6, 0.125]]])
        XCTAssertEqual(record.cell, [10, -5, 32, 40])
        XCTAssertEqual(record.styles[0].width, 2.5)
        XCTAssertEqual(record.styles[0].color, ink.color)
        for _ in 0..<4 { try capture.save([ink], cell: cell) }
        XCTAssertEqual(capture.count, 5)
        XCTAssertEqual(capture.label, "−")
        XCTAssertEqual(capture.sampleNumber, 1)
        XCTAssertEqual(Set(capture.files["-"]!).count, 5)
        XCTAssertEqual(try Data(contentsOf: first), data)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("invalid.json"))
        let resumed = try GlyphCapture(directory: directory, labels: ["-", "−"])
        XCTAssertEqual(resumed.count, 5)
        XCTAssertEqual(resumed.label, "−")
        try resumed.save([ink], cell: cell)
        let last = try XCTUnwrap(resumed.files["−"]?.last)
        try resumed.redoLast()
        XCTAssertFalse(FileManager.default.fileExists(atPath: last.path))
        XCTAssertEqual(resumed.count, 5)
        XCTAssertEqual(resumed.label, "−")
        XCTAssertEqual(resumed.sampleNumber, 1)
        XCTAssertEqual(CleanGlyphs.labels.count, 158)
        XCTAssertEqual(GlyphCapture.codepoints("−"), ["U+2212"])
    }

    func testInvalidAndFailedWritesDoNotAdvance() throws {
        let capture = try GlyphCapture(directory: directory, labels: ["x"])
        XCTAssertThrowsError(try capture.save([], cell: cell))
        XCTAssertEqual(capture.count, 0)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory) // deterministic ENOTDIR, even with elevated privileges
        XCTAssertThrowsError(try capture.save([ink], cell: cell))
        XCTAssertEqual(capture.label, "x")
        XCTAssertEqual(capture.sampleNumber, 1)
        XCTAssertEqual(capture.count, 0)
    }

    func testCanvasExplicitSaveAndRestoreWithoutNoteEdits() throws {
        let settings = CanvasSettings()
        settings.handwritingToText = true
        settings.scribeMath = true
        settings.width = 3.75
        settings.tool = .pointer
        let model = CanvasModel()
        model.add(ink)
        model.undoManager.removeAllActions()
        let view = CanvasView(model: model, settings: settings)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let panel = WritingPanelView(model: model, toolController: view.toolController)
        view.writingPanel = panel
        view.startGlyphCapture(directory: directory)
        XCTAssertTrue(view.isCapturingGlyphs)
        XCTAssertEqual(settings.inputMode, .write)
        XCTAssertFalse(settings.handwritingToText)
        let captureCell = try XCTUnwrap(panel.cell)
        view.saveGlyphCaptureSample() // empty is ignored
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 0)
        view.toolController.strokeSink?(ink)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(view.pendingLetter, [ink]) // idle must not commit
        XCTAssertEqual(model.strokes, [ink])
        XCTAssertFalse(model.undoManager.canUndo)
        settings.inputMode = .pen // safe while capture is active; never flushes the draft
        settings.tool = .eraser
        XCTAssertTrue(view.penKeyMonitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false))
        XCTAssertTrue(view.penKeyDraws)
        XCTAssertTrue(settings.penIsDown)
        view.penKeyMonitor.cancel()
        settings.tool = .pointer
        XCTAssertTrue(view.penKeyMonitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false))
        view.penKeyMonitor.cancel()
        XCTAssertEqual(view.toolController.toolOverride, .pen)
        view.undo(nil)
        view.delete(nil)
        XCTAssertEqual(view.pendingLetter, [ink])
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        view.saveGlyphCaptureSample()
        XCTAssertEqual(view.pendingLetter, [ink])
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.saveGlyphCaptureSample()
        XCTAssertTrue(view.pendingLetter.isEmpty)
        let capture = try GlyphCapture(directory: directory)
        XCTAssertEqual(capture.count, 1)
        let saved = try XCTUnwrap(capture.files[CleanGlyphs.labels[0]]?.first)
        let record = try JSONDecoder().decode(GlyphCapture.Record.self, from: Data(contentsOf: saved))
        XCTAssertEqual(record.strokes, [[[12.25, -3, 0], [13, 6, 0.125]]])
        XCTAssertEqual(record.cell, [captureCell.rect.minX, captureCell.rect.minY, captureCell.rect.width, captureCell.rect.height])
        view.redoLastGlyphCaptureSample()
        XCTAssertEqual(try GlyphCapture(directory: directory).count, 0)
        view.stopGlyphCapture()
        XCTAssertFalse(view.isCapturingGlyphs)
        XCTAssertEqual(settings.inputMode, .pen)
        XCTAssertTrue(settings.handwritingToText)
        XCTAssertTrue(settings.scribeMath)
        XCTAssertEqual(settings.tool, .pointer)
        XCTAssertEqual(settings.width, 3.75)
        XCTAssertEqual(model.strokes, [ink])
        XCTAssertFalse(model.undoManager.canUndo)
        XCTAssertNil(panel.cell)
    }

    func testCancelRestoresExistingWriteCellAndDraftNeverTouchesNote() throws {
        let settings = CanvasSettings()
        settings.handwritingToText = false
        let model = CanvasModel()
        let view = CanvasView(model: model, settings: settings)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let panel = WritingPanelView(model: model, toolController: view.toolController)
        view.writingPanel = panel
        settings.inputMode = .write
        let original = try XCTUnwrap(panel.cell)
        view.startGlyphCapture(directory: directory)
        XCTAssertNotEqual(panel.cell, original)
        view.toolController.strokeSink?(ink)
        view.stopGlyphCapture()
        XCTAssertEqual(panel.cell, original)
        XCTAssertEqual(settings.inputMode, .write)
        XCTAssertTrue(view.pendingLetter.isEmpty)
        XCTAssertTrue(model.strokes.isEmpty)
        XCTAssertFalse(model.undoManager.canUndo)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 0)
        view.startGlyphCapture(directory: directory)
        XCTAssertTrue(view.isCapturingGlyphs)
        view.stopGlyphCapture()
        XCTAssertEqual(panel.cell, original)
    }

    func testRealTouchAndPenKeyCaptureIgnoresToolbarToolChanges() throws {
        let settings = CanvasSettings()
        let model = CanvasModel()
        let scroll = CanvasScrollView(model: model, settings: settings)
        scroll.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
        scroll.tile()
        let view = scroll.canvasView
        view.toolController.smoothingEnabled = false
        view.startGlyphCapture(directory: directory)
        defer { view.stopGlyphCapture() }
        let rect = try XCTUnwrap(view.writingPanel?.cell?.rect)
        for (index, tool) in [Tool.eraser, .pointer].enumerated() {
            settings.tool = tool
            let start = Double(index * 10)
            view.handleTouches([TouchSample(id: 1, normalized: CGPoint(x: 0.4, y: 0.5))], timestamp: start + 1)
            XCTAssertTrue(view.penKeyMonitor.keyDown(keyCode: PenKeyMonitor.spaceKeyCode, isRepeat: false))
            view.handleTouches([TouchSample(id: 1, normalized: CGPoint(x: 0.6, y: 0.5))], timestamp: start + 3)
            view.handleTouches([TouchSample(id: 1, normalized: CGPoint(x: 0.65, y: 0.5))], timestamp: start + 3.5)
            XCTAssertTrue(view.penKeyMonitor.keyUp(keyCode: PenKeyMonitor.spaceKeyCode))
            view.handleTouches([], timestamp: start + 4)
            XCTAssertEqual(view.pendingLetter.count, index + 1)
            let stroke = view.pendingLetter[index]
            XCTAssertEqual(stroke.points.count, 2)
            XCTAssertEqual(stroke.points[0].x, rect.minX + 0.6 * rect.width, accuracy: 1e-9)
            XCTAssertEqual(stroke.points[1].x, rect.minX + 0.65 * rect.width, accuracy: 1e-9)
            XCTAssertEqual(stroke.points[0].y, rect.midY, accuracy: 1e-9)
            XCTAssertEqual(stroke.points.map(\.t), [0, 0.5])
            XCTAssertTrue(model.strokes.isEmpty)
            XCTAssertTrue(model.textBlocks.isEmpty)
            XCTAssertFalse(model.undoManager.canUndo)
        }
        let raw = view.pendingLetter.map { $0.points.map { [$0.x, $0.y, $0.t] } }
        view.saveGlyphCaptureSample()
        XCTAssertTrue(view.pendingLetter.isEmpty)
        let resumed = try GlyphCapture(directory: directory)
        XCTAssertEqual(resumed.count, 1)
        let url = try XCTUnwrap(resumed.files[CleanGlyphs.labels[0]]?.first)
        let saved = try JSONDecoder().decode(GlyphCapture.Record.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.strokes, raw)
        XCTAssertEqual(saved.styles.count, 2)
        XCTAssertEqual(model.strokes.count, 0)
        XCTAssertEqual(model.textBlocks.count, 0)
    }

    func testRefusesPendingInkAndInProgressSave() throws {
        let view = CanvasView(model: CanvasModel(), settings: CanvasSettings())
        view.pendingLetter = [ink]
        view.startGlyphCapture(directory: directory)
        XCTAssertFalse(view.isCapturingGlyphs)
        XCTAssertEqual(view.pendingLetter, [ink])
        view.pendingLetter = []
        view.startGlyphCapture(directory: directory)
        view.toolController.strokeSink?(ink)
        view.toolController.handle(PenEvent(phase: .began, point: CGPoint(x: 1, y: 2), timestamp: 10))
        view.saveGlyphCaptureSample()
        XCTAssertEqual(view.pendingLetter, [ink])
        XCTAssertEqual(try GlyphCapture(directory: directory).count, 0)
        view.stopGlyphCapture()
        XCTAssertTrue(view.pendingLetter.isEmpty)
    }
}
#endif
