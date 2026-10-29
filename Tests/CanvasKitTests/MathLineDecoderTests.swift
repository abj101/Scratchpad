import Foundation
import XCTest
@testable import CanvasKit

final class MathLineDecoderTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Input: Decodable {
            let labelLikelihoods: [String: Double]
            let displayedLabel: String?
            let isVirtual: Bool
            let isPinned: Bool
        }

        struct Update: Decodable {
            let index: Int
            let label: String
            let marginal: Double
        }

        struct Alternative: Decodable {
            let label: String
            let marginal: Double
        }

        struct Expected: Decodable {
            let marginals: [[String: Double]]
            let substitution: Update?
            let revisions: [Update]
            let alternatives: [[Alternative]]
        }

        let name: String
        let symbols: [Input]
        let newestIndex: Int?
        let revisionIndices: [Int]?
        let lambda: Double?
        let tauSub: Double?
        let tauRev: Double?
        let tauFill: Double?
        let disabledLabels: [String]?
        let expected: Expected
    }

    func testPythonFixturesMatchBundledLanguageModelParity() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder-fixtures", withExtension: "json",
                                                  subdirectory: "decoder"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        let model = try XCTUnwrap(MathLanguageModel.bundled)
        XCTAssertEqual(fixtures.count, 18)

        for fixture in fixtures {
            let symbols = fixture.symbols.map {
                MathLineDecoder.Symbol(labelLikelihoods: $0.labelLikelihoods,
                                       displayedLabel: $0.displayedLabel,
                                       isVirtual: $0.isVirtual, isPinned: $0.isPinned)
            }
            let decoder = MathLineDecoder(
                languageModel: model,
                lambda: fixture.lambda ?? 0.6,
                tauSub: fixture.tauSub ?? 0.8,
                tauRev: fixture.tauRev ?? 0.9,
                disabledLabels: Set(fixture.disabledLabels ?? []),
                tauFill: fixture.tauFill
            )
            let actual = decoder.decode(symbols, newestIndex: fixture.newestIndex,
                                        revisionIndices: fixture.revisionIndices)
            XCTAssertEqual(actual.marginals.count, fixture.expected.marginals.count, fixture.name)
            for index in actual.marginals.indices {
                let expected = fixture.expected.marginals[index]
                XCTAssertEqual(Set(actual.marginals[index].keys), Set(expected.keys), fixture.name)
                for (label, probability) in expected {
                    XCTAssertEqual(actual.marginals[index][label]!, probability, accuracy: 1e-9,
                                   "\(fixture.name), token \(index), label \(label)")
                }
            }
            assertEqual(actual.substitution, fixture.expected.substitution, fixture.name)
            XCTAssertEqual(actual.revisions.count, fixture.expected.revisions.count, fixture.name)
            for (actualUpdate, expectedUpdate) in zip(actual.revisions, fixture.expected.revisions) {
                XCTAssertEqual(actualUpdate.index, expectedUpdate.index, fixture.name)
                XCTAssertEqual(actualUpdate.label, expectedUpdate.label, fixture.name)
                XCTAssertEqual(actualUpdate.marginal, expectedUpdate.marginal, accuracy: 1e-9, fixture.name)
            }
            for index in symbols.indices {
                let alternatives = actual.alternatives(at: index)
                let expected = fixture.expected.alternatives[index]
                XCTAssertEqual(alternatives.count, expected.count, fixture.name)
                for (actualItem, expectedItem) in zip(alternatives, expected) {
                    XCTAssertEqual(actualItem.label, expectedItem.label, fixture.name)
                    XCTAssertEqual(actualItem.marginal, expectedItem.marginal, accuracy: 1e-9, fixture.name)
                }
            }
        }
    }

    func testLineContextResolvesXAndTheMergedGlyphs() throws {
        let model = try XCTUnwrap(MathLanguageModel.bundled)
        let decoder = MathLineDecoder(languageModel: model)

        let xThenPlus = decoder.decode([
            symbol(["2": 1], displayed: "2"),
            symbol(["x": 0.5, "·": 0.5], displayed: "·"),
            symbol(["+": 1], displayed: "+"),
        ])
        XCTAssertEqual(xThenPlus.revisions.map(\.label), ["x"])

        let ringThenCos = decoder.decode([
            symbol(["c": 1], displayed: "c"),
            symbol(["0": 0.45, "o": 0.45, "°": 0.1], displayed: "0"),
            symbol(["s": 1], displayed: "s"),
        ])
        XCTAssertEqual(ringThenCos.revisions.map(\.label), ["o"])
        let alternatives = ringThenCos.alternatives(at: 1)
        XCTAssertEqual(alternatives.first?.label, "o")
        XCTAssertFalse(alternatives.contains { $0.label == "0" })
    }

    func testStubLanguageModelChoosesBarAsLAndRingsAsZeros() {
        let start = ["<s>", "<s>", "<s>"]
        let barModel = model(conditions: [
            (start, ["l": 0.999, "1": 0.0005, "|": 0.0005]),
        ])
        let bar = MathLineDecoder(languageModel: barModel).decode([
            symbol(["1": 1.0 / 3, "l": 1.0 / 3, "|": 1.0 / 3], displayed: "1"),
            symbol(["o": 1], displayed: "o"),
            symbol(["g": 1], displayed: "g"),
        ])
        XCTAssertTrue(bar.revisions.contains { $0.index == 0 && $0.label == "l" && $0.marginal >= 0.9 })

        let zeroModel = model(conditions: [
            (["<s>", "<s>", "4"], ["0": 0.999, "o": 0.0005, "°": 0.0005]),
            (["<s>", "4", "0"], ["0": 0.999, "o": 0.0005, "°": 0.0005]),
        ])
        let zeros = MathLineDecoder(languageModel: zeroModel).decode([
            symbol(["4": 1], displayed: "4"),
            symbol(["0": 0.45, "o": 0.45, "°": 0.1], displayed: "o"),
            symbol(["0": 0.45, "o": 0.45, "°": 0.1]),
        ])
        XCTAssertEqual(zeros.revisions.map(\.label), ["0"])
        XCTAssertEqual(zeros.substitution?.label, "0")
        XCTAssertGreaterThanOrEqual(zeros.substitution?.marginal ?? 0, 0.8)
    }

    func testRevisionThresholdsAndOnlyRecentCommitIDsCanChange() throws {
        let model = try XCTUnwrap(MathLanguageModel.bundled)
        let ratio = pow(19.0, 1.0 / 0.6)
        let pX = ratio / (1 + ratio)
        let exact95Model = self.model(conditions: [
            (["<s>", "<s>", "2"], ["x": pX, "·": 1 - pX]),
            (["<s>", "2", "x"], ["+": 0.5]),
            (["<s>", "2", "·"], ["+": 0.5]),
        ])
        let fires = MathLineDecoder(languageModel: exact95Model).decode([
            symbol(["2": 1], displayed: "2"),
            symbol(["x": 0.5, "·": 0.5], displayed: "·"),
            symbol(["+": 1], displayed: "+"),
        ])
        XCTAssertEqual(fires.revisions.first?.label, "x")
        XCTAssertEqual(fires.revisions.first?.marginal ?? 0, 0.95, accuracy: 1e-9)

        let blocked = MathLineDecoder(languageModel: model, lambda: 0).decode([
            symbol(["2": 1], displayed: "2"),
            symbol(["x": 0.8, "·": 0.2], displayed: "·"),
            symbol(["+": 1], displayed: "+"),
        ])
        XCTAssertEqual(blocked.marginals[1]["·"]!, 0.2, accuracy: 1e-12)
        XCTAssertFalse(blocked.revisions.contains { $0.index == 1 })

        let flattened = MathLineDecoder(languageModel: model, lambda: 0).decode([
            symbol(["x": 0.999, "·": 0.001], displayed: "·"),
            MathLineDecoder.Symbol(labelLikelihoods: ["/": 1], isVirtual: true),
            symbol(["0": 0.5, "o": 0.5], displayed: "o"),
            symbol(["x": 0.5, "·": 0.5], displayed: "·"),
            symbol(["+": 1], displayed: "+"),
        ], revisionIndices: [3, 2])
        XCTAssertEqual(flattened.marginals[0]["x"]!, 0.999, accuracy: 1e-12)
        XCTAssertFalse(flattened.revisions.contains { $0.index == 0 })
    }

    func testTwelveTokenReleaseLatencyWithBundledModel() throws {
        #if DEBUG
        throw XCTSkip("Run this gate with `swift test -c release --filter MathLineDecoderTests/testTwelveTokenReleaseLatencyWithBundledModel`.")
        #else
        let model = try XCTUnwrap(MathLanguageModel.bundled)
        let decoder = MathLineDecoder(languageModel: model)
        let labels = ["0", "o", "°", "1", "l"]
        let likelihoods = Dictionary(uniqueKeysWithValues: labels.map { ($0, 0.2) })
        let symbols = (0..<12).map { _ in symbol(likelihoods) }
        let coldStart = ProcessInfo.processInfo.systemUptime
        let coldResult = decoder.decode(symbols)
        let cold = ProcessInfo.processInfo.systemUptime - coldStart
        for _ in 0..<100 { _ = decoder.decode(symbols) }

        var samples: [Double] = []
        var sink = coldResult.marginals[11]["0"] ?? 0
        for _ in 0..<1_000 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = decoder.decode(symbols)
            samples.append(ProcessInfo.processInfo.systemUptime - start)
            sink += result.marginals[11]["0"] ?? 0
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let maximum = samples[samples.count - 1]
        XCTAssertGreaterThan(sink, 0)
        print("decoder latency: first \(cold * 1_000) ms; repeated median \(median * 1_000) ms; " +
              "p95 \(p95 * 1_000) ms; max \(maximum * 1_000) ms")
        XCTAssertLessThanOrEqual(cold, 0.0005, "12-token first call was \(cold * 1_000) ms")
        XCTAssertLessThanOrEqual(median, 0.0005, "12-token median was \(median * 1_000) ms")
        #endif
    }

    private func symbol(_ likelihoods: [String: Double], displayed: String? = nil) -> MathLineDecoder.Symbol {
        MathLineDecoder.Symbol(labelLikelihoods: likelihoods, displayedLabel: displayed)
    }

    private func model(conditions: [([String], [String: Double])]) -> MathLanguageModel {
        let labels = Array("0123456789abcdefghijklmnoprstuvwxyz+−·÷=≠<>≤≥±/!()[]|.,′√∫∑πθΔ∞→°").map(String.init)
        let vocabulary = ["<s>", "<unk>"] + labels
        let base = 1.0 / Double(vocabulary.count)
        var ngrams = Dictionary(uniqueKeysWithValues: vocabulary.map { (key([], $0), [log10(base), 0]) })
        for (context, probabilities) in conditions {
            for (label, probability) in probabilities {
                ngrams[key(context, label)] = [log10(probability), 0]
            }
        }
        return MathLanguageModel(vocab: vocabulary, ngrams: ngrams)
    }

    private func key(_ context: [String], _ word: String) -> String {
        context.joined(separator: "\u{001F}") + "\u{001E}" + word
    }

    private func assertEqual(_ actual: MathLineDecoder.Update?, _ expected: Fixture.Update?,
                             _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual?.index, expected?.index, name, file: file, line: line)
        XCTAssertEqual(actual?.label, expected?.label, name, file: file, line: line)
        if let actual, let expected {
            XCTAssertEqual(actual.marginal, expected.marginal, accuracy: 1e-9, name,
                           file: file, line: line)
        } else {
            XCTAssertEqual(actual == nil, expected == nil, name, file: file, line: line)
        }
    }
}
