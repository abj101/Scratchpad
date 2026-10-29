import XCTest
@testable import CanvasKit

final class GlyphSequenceTests: XCTestCase {
    private struct FixtureManifest: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let name: String
        let strokes: [[[Double]]]
        let strokePoints: [[Float]]
        let sampleCounts: [Int]
    }

    func testPythonFixturesMatchWithinTolerance() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "fixtures", withExtension: "json", subdirectory: "sequence"
        ))
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(manifest.fixtures.count, 12)

        for fixture in manifest.fixtures {
            let actual = try XCTUnwrap(encode(fixture.strokes), fixture.name)
            XCTAssertEqual(actual.sampleCounts, fixture.sampleCounts, fixture.name)
            XCTAssertEqual(actual.strokePoints.count, 128, fixture.name)
            XCTAssertEqual(fixture.strokePoints.count, 128, fixture.name)
            for index in 0..<128 {
                XCTAssertEqual(actual.strokePoints[index].count, 4, fixture.name)
                XCTAssertEqual(fixture.strokePoints[index].count, 4, fixture.name)
                for feature in 0..<4 {
                    XCTAssertEqual(actual.strokePoints[index][feature], fixture.strokePoints[index][feature],
                                   accuracy: 1e-5, "\(fixture.name) sample \(index), feature \(feature)")
                }
            }
        }
    }

    func testHamiltonAllocationWorkedExamples() throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(try XCTUnwrap(fixtures["dot_tap"]).sampleCounts, [128])
        XCTAssertEqual(try XCTUnwrap(fixtures["three_taps"]).sampleCounts, [43, 43, 42])
        XCTAssertEqual(try XCTUnwrap(fixtures["seventy_strokes"]).sampleCounts,
                       [Int](repeating: 2, count: 64))
        let seventy = try XCTUnwrap(fixtures["seventy_strokes"])
        let first64 = Array(seventy.strokes.prefix(64))
        let all = try XCTUnwrap(encode(seventy.strokes))
        let prefix = try XCTUnwrap(encode(first64))
        XCTAssertEqual(all.sampleCounts, prefix.sampleCounts)
        XCTAssertEqual(all.strokePoints, prefix.strokePoints)

        XCTAssertEqual(try XCTUnwrap(GlyphSequence.encode([line(length: 3), line(length: 1)])).sampleCounts,
                       [95, 33])
        XCTAssertEqual(try XCTUnwrap(GlyphSequence.encode([
            line(length: 1), line(length: 1), line(length: 1),
        ])).sampleCounts, [43, 43, 42])
    }

    func testEmptyAndInvalidInputsReturnNil() {
        XCTAssertNil(GlyphSequence.encode([]))
        XCTAssertNil(GlyphSequence.encode([stroke([])]))
        XCTAssertNil(GlyphSequence.encode([stroke([(Double.nan, 0)])]))
        XCTAssertNil(GlyphSequence.encode([stroke([(Double.infinity, 0)])]))
        XCTAssertNil(GlyphSequence.encode([stroke([(200_001, 0)])]))
    }

    func testConsecutiveDuplicatesDoNotChangeFeatures() throws {
        let withDuplicate = try XCTUnwrap(GlyphSequence.encode([
            stroke([(0, 0), (1, 0), (1, 0), (2, 0)]),
        ]))
        let withoutDuplicate = try XCTUnwrap(GlyphSequence.encode([
            stroke([(0, 0), (1, 0), (2, 0)]),
        ]))
        XCTAssertEqual(withDuplicate.sampleCounts, withoutDuplicate.sampleCounts)
        for (actual, expected) in zip(withDuplicate.strokePoints, withoutDuplicate.strokePoints) {
            for feature in 0..<4 {
                XCTAssertEqual(actual[feature], expected[feature], accuracy: 1e-5)
            }
        }
    }

    private func loadFixtures() throws -> [String: Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "fixtures", withExtension: "json", subdirectory: "sequence"
        ))
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: manifest.fixtures.map { ($0.name, $0) })
    }

    private func encode(_ paths: [[[Double]]]) -> GlyphSequence.Features? {
        GlyphSequence.encode(paths.map { stroke($0.map { ($0[0], $0[1]) }) })
    }

    private func line(length: Double) -> Stroke {
        stroke([(0, 0), (length, 0)])
    }

    private func stroke(_ points: [(Double, Double)]) -> Stroke {
        Stroke(points: points.enumerated().map { index, point in
            StrokePoint(x: point.0, y: point.1, t: Double(index))
        }, color: .black, width: 1)
    }
}
