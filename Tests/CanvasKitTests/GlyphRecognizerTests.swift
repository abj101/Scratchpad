import XCTest
@testable import CanvasKit

final class GlyphRecognizerTests: XCTestCase {
    /// Deterministic generator (SplitMix64) so jitter is reproducible.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Synthetic symbols (unit ≈ cell height 40, y-down)

    private static func line(_ a: CGPoint, _ b: CGPoint, _ n: Int = 16) -> [CGPoint] {
        (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private static let shapes: [String: (strokes: [[CGPoint]], height: Double)] = [
        "1": ([line(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 30))], 0.75),
        "−": ([line(CGPoint(x: 0, y: 0), CGPoint(x: 18, y: 0))], 0.05),
        "7": ([line(CGPoint(x: 0, y: 0), CGPoint(x: 18, y: 0)) + line(CGPoint(x: 18, y: 0), CGPoint(x: 6, y: 30)).dropFirst()], 0.75),
        "x": ([line(CGPoint(x: 0, y: 0), CGPoint(x: 16, y: 18)), line(CGPoint(x: 16, y: 0), CGPoint(x: 0, y: 18))], 0.45),
        "+": ([line(CGPoint(x: 0, y: 9), CGPoint(x: 18, y: 9)), line(CGPoint(x: 9, y: 0), CGPoint(x: 9, y: 18))], 0.45),
        "0": ([(0...40).map { i in
            let a = CGFloat(i) / 40 * 2 * .pi
            return CGPoint(x: 10 * sin(a), y: -15 * cos(a))
        }], 0.75),
    ]

    /// `label`'s shape with per-point jitter, a random scale and slant, as handwriting varies.
    private func variant(_ label: String, _ rng: inout Seeded, jitter: CGFloat = 1.2) -> GlyphSample {
        let shape = Self.shapes[label]!
        let scale = CGFloat.random(in: 0.85...1.15, using: &rng)
        let slant = CGFloat.random(in: -0.12...0.12, using: &rng)
        let strokes = shape.strokes.map { s in
            s.map { p in
                CGPoint(x: (p.x + slant * p.y) * scale + .random(in: -jitter...jitter, using: &rng),
                        y: p.y * scale + .random(in: -jitter...jitter, using: &rng))
            }
        }
        return GlyphSample(strokes: strokes, relativeHeight: shape.height * Double(scale))
    }

    private func trainedRecognizer(_ rng: inout Seeded) -> GlyphRecognizer {
        var templates: [String: [GlyphSample]] = [:]
        for label in Self.shapes.keys { templates[label] = (0..<3).map { _ in variant(label, &rng) } }
        return GlyphRecognizer(templates: templates)
    }

    // MARK: Recognition

    func testFreshVariantsAreRecognizedConfidently() {
        var rng = Seeded(state: 1)
        let recognizer = trainedRecognizer(&rng)
        for label in Self.shapes.keys.sorted() {
            for _ in 0..<10 {
                let r = recognizer.classify(variant(label, &rng))
                XCTAssertEqual(r?.label, label)
                if let r { XCTAssertTrue(GlyphRecognizer.isConfident(r), "\(label): \(r)") }
            }
        }
    }

    func testMinusAndOneStayDistinctAtTheSameSize() {
        var rng = Seeded(state: 2)
        let recognizer = trainedRecognizer(&rng)
        var minus = variant("−", &rng)
        minus.relativeHeight = 0.75 // shape alone must keep it from reading as "1"
        XCTAssertNotEqual(recognizer.classify(minus)?.label, "1")
    }

    func testScribbleIsNotConfident() {
        var rng = Seeded(state: 3)
        let recognizer = trainedRecognizer(&rng)
        let scribble = (0..<30).map { _ in CGPoint(x: .random(in: 0...20, using: &rng), y: .random(in: 0...30, using: &rng)) }
        let r = recognizer.classify(GlyphSample(strokes: [scribble], relativeHeight: 0.75))
        XCTAssertNotNil(r)
        if let r { XCTAssertFalse(GlyphRecognizer.isConfident(r), "\(r)") }
    }

    func testNoTemplatesOrNoInkGivesNil() {
        XCTAssertNil(GlyphRecognizer().classify(GlyphSample(strokes: [[.zero, CGPoint(x: 1, y: 1)]])))
        var rng = Seeded(state: 4)
        XCTAssertNil(trainedRecognizer(&rng).classify(GlyphSample(strokes: [[CGPoint]]())))
    }

    // MARK: Token mean

    func testMeanIsCloserToTheCleanShapeThanItsSamples() {
        var rng = Seeded(state: 5)
        let clean = GlyphRecognizer.cloud(Self.shapes["7"]!.strokes)!
        let samples = (0..<3).map { _ in variant("7", &rng, jitter: 2) }
        let mean = GlyphTemplates.mean(of: samples)!
        let meanDistance = GlyphRecognizer.distance(GlyphRecognizer.cloud(mean.strokes)!, clean)
        for s in samples {
            XCTAssertLessThan(meanDistance, GlyphRecognizer.distance(GlyphRecognizer.cloud(s.strokes)!, clean))
        }
    }

    func testMeanAlignsAReversedStroke() {
        var rng = Seeded(state: 6)
        var samples = (0..<3).map { _ in variant("1", &rng, jitter: 0.5) }
        samples[2].strokes[0].reverse()
        let mean = GlyphTemplates.mean(of: samples)!
        // A collapsed mean (strokes cancelling out) would be far shorter than one unit.
        let ys = mean.strokes[0].map(\.y)
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0.9)
    }

    // MARK: Rendering

    func testRenderFitsTheBoxWithFreshStrokes() {
        var rng = Seeded(state: 7)
        let mean = GlyphTemplates.mean(of: (0..<3).map { _ in variant("7", &rng) })!
        let box = CGRect(x: 100, y: 50, width: 24, height: 32)
        let original = [Stroke(points: [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 1, y: 1, t: 0.1)],
                               color: .black, width: 2)]
        let rendered = GlyphTemplates.render(mean, into: box, like: original)
        XCTAssertFalse(rendered.isEmpty)
        let ink = rendered.flatMap(\.points)
        let ys = ink.map(\.y), xs = ink.map(\.x)
        XCTAssertEqual(ys.max()! - ys.min()!, box.height, accuracy: 0.5)
        XCTAssertEqual((ys.max()! + ys.min()!) / 2, box.midY, accuracy: 0.5)
        XCTAssertEqual((xs.max()! + xs.min()!) / 2, box.midX, accuracy: 0.5)
        XCTAssertTrue(Set(rendered.map(\.id)).isDisjoint(with: original.map(\.id)))
        XCTAssertTrue(rendered.allSatisfy { $0.width == 2 })
        for s in rendered { XCTAssertEqual(s.points.map(\.t), s.points.map(\.t).sorted()) }
    }
}
