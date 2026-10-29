import XCTest
@testable import CanvasKit

final class PerformanceTests: XCTestCase {
    private func stroke(_ pts: [(Double, Double)], width: Double = 2.5) -> Stroke {
        Stroke(points: pts.enumerated().map { StrokePoint(x: $1.0, y: $1.1, t: Double($0)) }, color: .black, width: width)
    }

    // MARK: Cached bounds

    func testBoundsMatchPointsAndWidth() {
        let s = stroke([(0, 0), (10, 20), (-5, 4)], width: 4)
        XCTAssertEqual(s.bounds, CGRect(x: -9, y: -4, width: 23, height: 28))
        XCTAssertTrue(Stroke(points: [], color: .black, width: 1).bounds.isNull)
    }

    func testBoundsFollowMutation() {
        var s = stroke([(0, 0), (10, 10)])
        s.points.append(StrokePoint(x: 50, y: 0, t: 2))
        XCTAssertEqual(s.bounds.maxX, 50 + 1.25 + 2)
        s.width = 10
        XCTAssertEqual(s.bounds.minX, -7)
        s.points[0].x = -100
        XCTAssertEqual(s.bounds.minX, -107)
        s.translate(by: CGVector(dx: 5, dy: 7))
        XCTAssertEqual(s.bounds.minX, -102)
        XCTAssertEqual(s.bounds.minY, 0)
    }

    func testBoundsAfterModelTranslateAndUndo() {
        let s = stroke([(0, 0), (10, 10)])
        let model = CanvasModel(strokes: [s])
        let before = model.strokes[0].bounds
        model.translate(ids: [s.id], by: CGVector(dx: 100, dy: -50))
        XCTAssertEqual(model.strokes[0].bounds, before.offsetBy(dx: 100, dy: -50))
        model.undoManager.undo()
        XCTAssertEqual(model.strokes[0].bounds, before)
        XCTAssertEqual(model.strokes[0], s)
    }

    func testTranslateStrokesDoesNotRegisterUndo() {
        let s = stroke([(0, 0), (10, 10)])
        let model = CanvasModel(strokes: [s])
        var changed = CGRect.null
        model.onChange = { changed = $0 }

        model.translateStrokes([s.id: CGVector(dx: 5, dy: -3)])

        XCTAssertEqual(model.strokes[0].bounds, s.bounds.offsetBy(dx: 5, dy: -3))
        XCTAssertEqual(changed, s.bounds.union(s.bounds.offsetBy(dx: 5, dy: -3)))
        XCTAssertFalse(model.undoManager.canUndo)
    }

    func testCodableRoundTripKeepsBoundsAndEquality() throws {
        let s = stroke([(1, 2), (30, 40), (7, -9)], width: 3)
        let data = try JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("cachedbounds"))
        let back = try JSONDecoder().decode(Stroke.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.bounds, s.bounds)
        XCTAssertEqual(back.hashValue, s.hashValue)
    }

    // MARK: Drag timing

    private func makeCanvas(strokes count: Int, spread: Double = 1) -> (CanvasScrollView, CanvasModel, NSWindow) {
        var rng = SystemRandomNumberGenerator()
        var strokes: [Stroke] = []
        for _ in 0..<count {
            let cx = Double.random(in: -1500...1500, using: &rng) * spread, cy = Double.random(in: -1000...1000, using: &rng) * spread
            var x = cx, y = cy
            let pts = (0..<30).map { i -> (Double, Double) in
                x += Double.random(in: -6...6, using: &rng); y += Double.random(in: -6...6, using: &rng)
                return (x, y)
            }
            strokes.append(stroke(pts))
        }
        let model = CanvasModel(strokes: strokes)
        let settings = CanvasSettings()
        settings.tool = .pointer
        let scroll = CanvasScrollView(model: model, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        scroll.layoutSubtreeIfNeeded()
        scroll.centerOn(world: .zero)
        window.orderFrontRegardless()
        scroll.displayIfNeeded()
        return (scroll, model, window)
    }

    private func makeDocument(strokes: [Stroke]) -> (CanvasScrollView, CanvasModel, NSWindow) {
        let model = CanvasModel(strokes: strokes, layout: .document)
        let settings = CanvasSettings()
        settings.tool = .pointer
        let scroll = CanvasScrollView(model: model, settings: settings, layout: .document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 760)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        scroll.displayIfNeeded()
        return (scroll, model, window)
    }

    func testDocumentMovePreviewLayerLifecycle() {
        let strokes = (0..<50).map { i in
            let x = Double(60 + (i % 10) * 24)
            let y = Double(DocumentLayout.topInset) + 30 + Double(i / 10) * 24
            return stroke([(x, y), (x + 8, y + 6)])
        }
        let (scroll, model, window) = makeDocument(strokes: strokes)
        defer { window.close() }
        let canvas = scroll.canvasView
        let overlay: InkOverlayView = try! XCTUnwrap(canvas.inkOverlayView)
        XCTAssertTrue(canvas.subviews.last === overlay)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 100, y: 120)))
        canvas.settings.tool = Tool.pointer
        XCTAssertTrue(canvas.hitTest(NSPoint(x: 100, y: 120)) === canvas.documentBodyView?.textView)
        canvas.settings.tool = Tool.pointer

        let base = overlay.layer?.sublayers?.count ?? 0
        let ids = Set(model.strokes.prefix(10).map(\.id))
        canvas.selection.select(ids)
        let bounds = canvas.selection.selectionBounds
        let start = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.selection.pointerDown(at: start, extend: false, hitRadius: 6)
        canvas.selection.pointerDragged(to: CGPoint(x: start.x + 40, y: start.y + 10))
        XCTAssertEqual(overlay.layer?.sublayers?.count ?? 0, base + 1)
        canvas.selection.pointerDragged(to: CGPoint(x: start.x + 80, y: start.y + 20))
        XCTAssertEqual(overlay.layer?.sublayers?.count ?? 0, base + 1)
        canvas.selection.cancelDrag()
        XCTAssertEqual(overlay.layer?.sublayers?.count ?? 0, base)

        canvas.selection.pointerDown(at: start, extend: false, hitRadius: 6)
        canvas.selection.pointerDragged(to: CGPoint(x: start.x + 40, y: start.y + 10))
        canvas.selection.pointerUp(at: CGPoint(x: start.x + 40, y: start.y + 10))
        XCTAssertEqual(overlay.layer?.sublayers?.count ?? 0, base)
        XCTAssertEqual(model.strokes[0].bounds.minX, strokes[0].bounds.minX + 40, accuracy: 1e-9)
        XCTAssertEqual(model.strokes[0].bounds.minY, strokes[0].bounds.minY + 10, accuracy: 1e-9)
    }

    func testDocumentOverlayRendersTwoThousandStrokes() throws {
        let strokes = (0..<2_000).map { i -> Stroke in
            let x = Double(40 + (i % 40) * 16)
            let y = Double(DocumentLayout.topInset) + 16 + Double(i / 40) * 10
            return stroke([(x, y), (x + 6, y + 4), (x + 10, y + 1)])
        }
        let (scroll, model, window) = makeDocument(strokes: strokes)
        defer { window.close() }
        let overlay: InkOverlayView = try XCTUnwrap(scroll.canvasView.inkOverlayView)
        let rect = overlay.visibleRect
        let rep = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: rect))
        func redraw() { overlay.cacheDisplay(in: rect, to: rep) }
        for _ in 0..<3 { redraw() }
        var times: [Double] = []
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            redraw()
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        let sorted = times.sorted()
        print(String(format: "DOCINKPERF 2000 strokes mean %.2f ms  median %.2f ms  p95 %.2f ms  max %.2f ms",
                     times.reduce(0, +) / Double(times.count), sorted[times.count / 2],
                     sorted[Int(Double(times.count) * 0.95)], sorted.last!))
        XCTAssertEqual(model.strokes.count, 2_000)
        XCTAssertTrue(times.allSatisfy { $0 > 0 })

        let oldHeight = scroll.canvasView.frame.height
        scroll.centerOnDocument(worldY: oldHeight + scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.canvasView.frame.height, oldHeight)
        XCTAssertEqual(overlay.frame, scroll.canvasView.bounds)
    }

    func testMovePreviewLayerLifecycle() {
        let (scroll, model, window) = makeCanvas(strokes: 50)
        defer { window.close() }
        let canvas = scroll.canvasView
        let base = canvas.layer?.sublayers?.count ?? 0
        let ids = Set(model.strokes.prefix(10).map(\.id))
        canvas.selection.select(ids)
        let b = canvas.selection.selectionBounds
        let start = CGPoint(x: b.midX, y: b.midY)
        canvas.selection.pointerDown(at: start, extend: false, hitRadius: 6)
        XCTAssertEqual(canvas.layer?.sublayers?.count ?? 0, base)
        canvas.selection.pointerDragged(to: CGPoint(x: start.x + 40, y: start.y + 10))
        XCTAssertEqual(canvas.layer?.sublayers?.count ?? 0, base + 1)
        canvas.selection.pointerDragged(to: CGPoint(x: start.x + 80, y: start.y + 20))
        XCTAssertEqual(canvas.layer?.sublayers?.count ?? 0, base + 1)
        canvas.selection.cancelDrag()
        XCTAssertEqual(canvas.layer?.sublayers?.count ?? 0, base)
        XCTAssertEqual(canvas.selection.selectionBounds, b)

        let before = model.strokes[0].bounds
        canvas.selection.pointerDown(at: start, extend: false, hitRadius: 6)
        canvas.selection.pointerDragged(to: CGPoint(x: start.x + 40, y: start.y + 10))
        canvas.selection.pointerUp(at: CGPoint(x: start.x + 40, y: start.y + 10))
        XCTAssertEqual(canvas.layer?.sublayers?.count ?? 0, base)
        let moved = model.strokes[0].bounds, expected = before.offsetBy(dx: 40, dy: 10)
        XCTAssertEqual(moved.minX, expected.minX, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, expected.minY, accuracy: 1e-9)
        XCTAssertEqual(moved.width, expected.width, accuracy: 1e-9)
        XCTAssertEqual(moved.height, expected.height, accuracy: 1e-9)
        XCTAssertEqual(model.undoManager.undoActionName, "Move")
    }

    func testSelectionDragFrameCost() throws {
        let (scroll, model, window) = makeCanvas(strokes: 5000)
        defer { window.close() }
        let canvas = scroll.canvasView
        let ids = Set(model.strokes.prefix(2000).map(\.id))
        canvas.selection.select(ids)
        let b = canvas.selection.selectionBounds
        let start = CGPoint(x: b.midX, y: b.midY)
        canvas.selection.pointerDown(at: start, extend: false, hitRadius: 6)
        scroll.displayIfNeeded()

        let frames = 60
        var times: [Double] = []
        for i in 1...frames {
            let t0 = CFAbsoluteTimeGetCurrent()
            canvas.selection.pointerDragged(to: CGPoint(x: start.x + Double(i) * 8, y: start.y + Double(i) * 3))
            scroll.displayIfNeeded()
            CATransaction.flush()
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let sorted = times.sorted()
        print(String(format: "DRAGPERF mean %.2f ms  median %.2f ms  p95 %.2f ms  max %.2f ms",
                     times.reduce(0, +) / Double(frames), sorted[frames / 2], sorted[Int(Double(frames) * 0.95)], sorted.last!))
        canvas.selection.pointerUp(at: CGPoint(x: start.x + Double(frames) * 8, y: start.y + Double(frames) * 3))
        scroll.displayIfNeeded()
        XCTAssertEqual(model.strokes.count, 5000)
    }

    func testZoomedOutRedrawCost() throws {
        let (scroll, model, window) = makeCanvas(strokes: 3300, spread: 3)
        defer { window.close() }
        let canvas = scroll.canvasView
        for mag in [0.1, 0.25, 0.5] as [CGFloat] {
            scroll.magnification = mag
            scroll.centerOn(world: .zero)
            let rect = canvas.visibleRect
            let rep = canvas.bitmapImageRepForCachingDisplay(in: rect)!
            // Rasterize into a bitmap so the cost includes real Core Graphics stroking.
            func redraw() { canvas.cacheDisplay(in: rect, to: rep) }
            for _ in 0..<3 { redraw() }
            var times: [Double] = []
            for _ in 0..<20 {
                let t0 = CFAbsoluteTimeGetCurrent()
                redraw()
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            let sorted = times.sorted()
            print(String(format: "ZOOMPERF mag %.2f mean %.2f ms  median %.2f ms  p95 %.2f ms",
                         mag, times.reduce(0, +) / Double(times.count), sorted[times.count / 2],
                         sorted[Int(Double(times.count) * 0.95)]))
            XCTAssertTrue(times.allSatisfy { $0 > 0 })
        }
        XCTAssertEqual(model.strokes.count, 3300)
    }
}
