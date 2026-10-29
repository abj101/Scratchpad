import CoreGraphics
import XCTest
@testable import CanvasKit

final class SymbolResolverTests: XCTestCase {
    private struct ResolverFixture: Decodable {
        struct Context: Decodable {
            let medianHeight: CGFloat?
            let baseline: CGFloat?
            let cellHeight: CGFloat?
            let mode: String?
        }

        let name: String
        let classID: String
        let bounds: [CGFloat]
        let context: Context
        let expected: [String: Double]
    }

    private func context(_ mode: SymbolResolver.Mode = .math, previous: String? = nil,
                         median: CGFloat? = 20, baseline: CGFloat? = 100) -> SymbolResolver.Context {
        SymbolResolver.Context(medianHeight: median, baseline: baseline, mode: mode,
                               previousSymbol: previous)
    }

    private func bounds(height: CGFloat, width: CGFloat = 10, midY: CGFloat = 91) -> CGRect {
        CGRect(x: 0, y: midY - height / 2, width: width, height: height)
    }

    func testCaseGroupsUseLineRelativeHeightAndLeaveMiddleBandUnresolved() {
        let groups = ["c", "k", "p", "s", "u", "v", "w", "y", "z"].map { "ambig_case_\($0)" }
        for group in groups {
            XCTAssertEqual(SymbolResolver.resolve(group: group, originalBounds: bounds(height: 12), context: context()),
                           String(group.last!))
            XCTAssertEqual(SymbolResolver.resolve(group: group, originalBounds: bounds(height: 18), context: context()),
                           String(group.last!).uppercased())
            XCTAssertNil(SymbolResolver.resolve(group: group, originalBounds: bounds(height: 15.6), context: context()))
        }
    }

    func testCircleGroupUsesOriginalRelativeSizeAndVerticalPosition() {
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 95, width: 2, height: 2),
                                              context: context()), ".")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 87, width: 2, height: 2),
                                              context: context()), "·")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 80, width: 6, height: 6),
                                              context: context()), "°")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 82, width: 2, height: 2),
                                              context: context()), "°")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 87, width: 8, height: 8),
                                              context: context()), "∘")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 88, width: 12, height: 12),
                                              context: context()), "o")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 82, width: 18, height: 18),
                                              context: context()), "0")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 82, width: 18, height: 18),
                                              context: context(previous: "x")), "0")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 82, width: 18, height: 18),
                                              context: context(.text)), "O")
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_circle", originalBounds: bounds(height: 15.6), context: context()))
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_circle", originalBounds: CGRect(x: 0, y: 95, width: 2, height: 2),
                                            context: context(baseline: nil)))
    }

    func testDisabledIntendedMemberDoesNotFallThroughToAnotherCircleMember() {
        let fullSizeCircle = CGRect(x: 0, y: 82, width: 18, height: 18)
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_circle", originalBounds: fullSizeCircle,
                                            context: context(), disabledLabels: ["0"]))
    }

    func testOneBarAndTimesUseSizeAndMathContext() {
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_one_bar", originalBounds: bounds(height: 12), context: context()), "l")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_one_bar", originalBounds: bounds(height: 18), context: context()), "1")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_one_bar", originalBounds: bounds(height: 18), context: context(previous: "2")), "1")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_one_bar", originalBounds: CGRect(x: 0, y: 91, width: 2, height: 18),
                                              context: context()), "|")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_one_bar", originalBounds: bounds(height: 18), context: context(.text)), "I")
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_one_bar", originalBounds: bounds(height: 15.6), context: context()))

        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_x_times", originalBounds: bounds(height: 12), context: context()), "x")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_x_times", originalBounds: bounds(height: 18), context: context()), "x")
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_x_times", originalBounds: bounds(height: 18), context: context(previous: "2")))
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_x_times", originalBounds: CGRect(x: 0, y: 87, width: 8, height: 8),
                                              context: context(previous: "2")), "×")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_x_times", originalBounds: bounds(height: 18), context: context(.text)), "X")
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_x_times", originalBounds: bounds(height: 15.6), context: context()))
    }

    func testDashUsesBaselineAndWidthForPunctuation() {
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_dash", originalBounds: CGRect(x: 0, y: 99, width: 12, height: 2),
                                              context: context()), "_")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_dash", originalBounds: CGRect(x: 0, y: 89, width: 12, height: 2),
                                              context: context()), "−")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_dash", originalBounds: CGRect(x: 0, y: 89, width: 12, height: 2),
                                              context: context(.text)), "-")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_dash", originalBounds: CGRect(x: 0, y: 89, width: 32, height: 2),
                                              context: context(.text)), "—")
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_dash", originalBounds: CGRect(x: 0, y: 89, width: 12, height: 2),
                                            context: context(baseline: nil)))
    }

    func testCommaAndApostropheUseBaselinePosition() {
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_comma_quote", originalBounds: CGRect(x: 0, y: 78, width: 3, height: 4),
                                              context: context()), "'")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_comma_quote", originalBounds: CGRect(x: 0, y: 100, width: 4, height: 6),
                                              context: context()), ",")
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_comma_quote", originalBounds: CGRect(x: 0, y: 95, width: 3, height: 4),
                                            context: context()))
    }

    func testGreekRelationsAndSumsUseRelativeSizeAndMode() {
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_epsilon_in", originalBounds: bounds(height: 14), context: context(previous: "x")), "ε")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_epsilon_in", originalBounds: bounds(height: 18), context: context(previous: "+")), "∈")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_epsilon_in", originalBounds: bounds(height: 14), context: context(.text, previous: "x")), "ε")
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_epsilon_in", originalBounds: bounds(height: 15.6), context: context()))
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_sigma_sum", originalBounds: bounds(height: 18), context: context()), "Σ")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_sigma_sum", originalBounds: bounds(height: 28, midY: 90), context: context()), "∑")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_sigma_sum", originalBounds: bounds(height: 18), context: context(.text)), "Σ")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_pi_product", originalBounds: bounds(height: 18), context: context()), "Π")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_pi_product", originalBounds: bounds(height: 28, midY: 90), context: context()), "∏")
        XCTAssertEqual(SymbolResolver.resolve(group: "ambig_pi_product", originalBounds: bounds(height: 18), context: context(.text)), "Π")
    }

    func testVocabularyKindsSingletonsAndInvalidContext() {
        XCTAssertEqual(SymbolResolver.kind(for: "2"), "digit")
        XCTAssertEqual(SymbolResolver.kind(for: "·"), "operator")
        XCTAssertEqual(SymbolResolver.kind(for: "'"), "raised")
        XCTAssertEqual(SymbolResolver.kind(forGroup: "glyph_u0032"), "digit")
        XCTAssertEqual(SymbolResolver.kind(forGroup: "glyph_u002B"), "operator")
        XCTAssertNil(SymbolResolver.kind(forGroup: "ambig_case_c"))
        XCTAssertNil(SymbolResolver.kind(forGroup: "ambig_circle"))
        XCTAssertNil(SymbolResolver.kind(forGroup: "unknown"))
        XCTAssertEqual(SymbolResolver.resolve(group: "glyph_u0032", originalBounds: bounds(height: 12), context: context()), "2")
        XCTAssertNil(SymbolResolver.resolve(group: "glyph_u0032", originalBounds: bounds(height: 12), context: context(), disabledLabels: ["2"]))
        XCTAssertNil(SymbolResolver.resolve(group: "unknown", originalBounds: bounds(height: 12), context: context()))
        XCTAssertNil(SymbolResolver.resolve(group: "ambig_case_c", originalBounds: bounds(height: 12),
                                            context: context(median: nil)))
    }

    func testMemberWeightsMatchSharedFixtures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "resolver-fixtures", withExtension: "json",
                                                  subdirectory: "resolver"))
        let fixtures = try JSONDecoder().decode([ResolverFixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 24)

        for fixture in fixtures {
            XCTAssertEqual(fixture.bounds.count, 4, fixture.name)
            let bounds = CGRect(x: fixture.bounds[0], y: fixture.bounds[1],
                                width: fixture.bounds[2], height: fixture.bounds[3])
            let context = SymbolResolver.Context(medianHeight: fixture.context.medianHeight,
                                                baseline: fixture.context.baseline,
                                                mode: fixture.context.mode == "text" ? .text : .math)
            if fixture.name.hasSuffix("cell_height_fallback") {
                XCTAssertNil(fixture.context.medianHeight, fixture.name)
                XCTAssertNotNil(fixture.context.cellHeight, fixture.name)
            }
            let actual = SymbolResolver.memberWeights(class: fixture.classID, bounds: bounds, context: context)
            XCTAssertEqual(Set(actual.keys), Set(fixture.expected.keys), fixture.name)
            for (label, expected) in fixture.expected {
                XCTAssertEqual(actual[label]!, expected, accuracy: 1e-9, "\(fixture.name): \(label)")
            }
            XCTAssertEqual(actual.values.reduce(0, +), 1, accuracy: 1e-9, fixture.name)
        }
    }

    func testMathModePrefersDigitsForMergedClasses() {
        // No line context (first symbol on a line): the digit dominates.
        let ring = SymbolResolver.memberWeights(class: "ring", bounds: CGRect(x: 0, y: 0, width: 12, height: 14),
                                                context: SymbolResolver.Context(mode: .math))
        XCTAssertGreaterThan(ring["0"]!, 0.8)
        XCTAssertGreaterThan(ring["0"]!, 5 * ring["o"]!)
        let bar = SymbolResolver.memberWeights(class: "bar", bounds: CGRect(x: 0, y: 0, width: 3, height: 14),
                                               context: SymbolResolver.Context(mode: .math))
        XCTAssertGreaterThanOrEqual(bar["1"]!, 0.9)
        XCTAssertEqual(bar.values.reduce(0, +), 1, accuracy: 1e-9)
        // With line context a ring is a digit unless it is small and raised.
        let line = context()
        let plain = SymbolResolver.memberWeights(class: "ring", bounds: CGRect(x: 0, y: 90, width: 12, height: 14), context: line)
        XCTAssertGreaterThan(plain["0"]!, 0.89)
        let degree = SymbolResolver.memberWeights(class: "ring", bounds: CGRect(x: 0, y: 84, width: 5, height: 5), context: line)
        XCTAssertGreaterThan(degree["°"]!, 0.9)
        // Text mode keeps the neutral split.
        let text = SymbolResolver.memberWeights(class: "bar", bounds: .zero, context: context(.text))
        XCTAssertEqual(text, ["1": 0.5, "|": 0.5])
        XCTAssertNil(bar["l"])
        XCTAssertEqual(bar, ["1": 0.95, "|": 0.05])
    }

    func testF5SingletonWeightsBeforeResourceSwap() {
        for (classID, label) in [("glyph_u0071", "q"), ("glyph_u006C", "l")] {
            XCTAssertEqual(SymbolResolver.memberWeights(class: classID, bounds: .zero,
                                                        context: context()), [label: 1])
        }
    }
}
