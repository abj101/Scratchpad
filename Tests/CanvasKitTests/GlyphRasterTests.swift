import XCTest
@testable import CanvasKit

final class GlyphRasterTests: XCTestCase {
    private struct FixtureManifest: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let name: String
        let strokes: [[[Double]]]
        let pixels: Data
    }

    func testRasterizeMatchesPythonFixturesByteForByte() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "fixtures", withExtension: "json", subdirectory: "raster"
        ))
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url))

        XCTAssertEqual(manifest.fixtures.count, 6)
        for fixture in manifest.fixtures {
            let strokes = fixture.strokes.map { path in
                Stroke(
                    points: path.map { StrokePoint(x: $0[0], y: $0[1], t: 0) },
                    color: .black,
                    width: 1
                )
            }
            let actual = GlyphRaster.rasterize(strokes)
            XCTAssertEqual(actual.count, 32 * 32, fixture.name)
            XCTAssertEqual(actual, Array(fixture.pixels), fixture.name)
        }
    }

    func testRasterizeKnownHorizontalStrokeAndPointCoverage() {
        let line = Stroke(points: [
            StrokePoint(x: 0, y: 0, t: 0),
            StrokePoint(x: 1, y: 0, t: 1),
        ], color: .black, width: 1)
        let linePixels = GlyphRaster.rasterize([line])
        let blackIndices = Set(linePixels.enumerated().compactMap { index, value in
            value == 0 ? index : nil
        })
        let expectedIndices = Set((15...16).flatMap { y in
            (2...29).map { y * 32 + $0 }
        })
        XCTAssertEqual(blackIndices.count, 56)
        XCTAssertEqual(blackIndices, expectedIndices)

        let dot = Stroke(points: [StrokePoint(x: -4, y: 9, t: 0)], color: .black, width: 1)
        XCTAssertEqual(GlyphRaster.rasterize([dot]).filter { $0 == 0 }.count, 4)
    }
}
