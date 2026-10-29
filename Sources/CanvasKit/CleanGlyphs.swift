import CoreGraphics
import Foundation

/// The bundled Hershey stroke templates used for clean glyph rendering.
public enum CleanGlyphs {
    static var resourceBundle: Bundle { Bundle.module }

    private struct Glyph: Decodable {
        let baseline: Double
        let advance: Double
        let strokes: [[[Double]]]
    }

    private static let glyphs: [String: Glyph] = {
        guard let url = resourceBundle.url(forResource: "HersheyGlyphs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let glyphs = try? JSONDecoder().decode([String: Glyph].self, from: data) else {
            return [:]
        }
        return glyphs
    }()

    /// Supported labels, sorted for deterministic callers such as sample capture.
    public static var labels: [String] { glyphs.keys.sorted() }

    /// Returns the glyph's Hershey stroke paths, or nil when the label is unsupported.
    /// Coordinates preserve Hershey's x-right, y-down axis; placement metrics are in the resource.
    public static func strokes(for label: String) -> [[CGPoint]]? {
        guard let glyph = glyphs[label] else { return nil }
        return glyph.strokes.map { stroke in
            stroke.map { point in CGPoint(x: CGFloat(point[0]), y: CGFloat(point[1])) }
        }
    }

    static func metrics(for label: String) -> (baseline: Double, advance: Double)? {
        guard let glyph = glyphs[label] else { return nil }
        return (glyph.baseline, glyph.advance)
    }
}
