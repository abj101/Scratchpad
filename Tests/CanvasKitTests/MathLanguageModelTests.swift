import Foundation
import XCTest
@testable import CanvasKit

final class MathLanguageModelTests: XCTestCase {
    private struct Query: Decodable {
        let word: String
        let context: [String]
        let log10p: Double
    }

    private func key(_ context: [String], _ word: String) -> String {
        context.joined(separator: "\u{001F}") + "\u{001E}" + word
    }

    private func smallModel() -> MathLanguageModel {
        let vocab = ["<s>", "<unk>", "a", "b", "c"]
        let ngrams = [
            key([], "a"): [-1.0, -0.7],
            key([], "b"): [-2.0, 0.0],
            key([], "c"): [-3.0, 0.0],
            key([], "<unk>"): [-2.5, 0.0],
            key(["a"], "b"): [-0.2, 0.0],
            key(["b"], "a"): [-1.2, -0.4],
        ]
        return MathLanguageModel(vocab: vocab, ngrams: ngrams)
    }

    private func lineLogProb(_ labels: [String], model: MathLanguageModel) -> Double {
        var context = ["<s>", "<s>", "<s>"]
        var score = 0.0
        for label in labels {
            score += model.logProb(label, context: context)
            context.append(label)
            if context.count > 3 { context.removeFirst() }
        }
        return score
    }

    func testUnseenNgramsBackOffWithAccumulatedWeights() {
        let model = smallModel()
        XCTAssertEqual(model.logProb("b", context: ["a"]), -0.2, accuracy: 1e-12)
        XCTAssertEqual(model.logProb("c", context: ["a"]), -3.7, accuracy: 1e-12)
        XCTAssertEqual(model.logProb("c", context: ["b", "a"]), -4.1, accuracy: 1e-12)
    }

    func testUnknownTokensMapToUnkAndHistoryKeepsOnlyLastThree() {
        let model = smallModel()
        XCTAssertEqual(model.logProb("not-a-label", context: ["a"]),
                       model.logProb("<unk>", context: ["a"]), accuracy: 1e-12)
        XCTAssertEqual(model.logProb("c", context: ["not-a-label", "a"]),
                       model.logProb("c", context: ["<unk>", "a"]), accuracy: 1e-12)
        XCTAssertEqual(model.logProb("c", context: ["b", "b", "a", "a"]),
                       model.logProb("c", context: ["b", "a", "a"]), accuracy: 1e-12)
    }

    func testBundledModelMatchesPythonParityFixtures() throws {
        let model = try XCTUnwrap(MathLanguageModel.bundled)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lm-queries", withExtension: "json",
                                                  subdirectory: "lm"))
        let queries = try JSONDecoder().decode([Query].self, from: Data(contentsOf: url))
        XCTAssertEqual(queries.count, 50)
        for query in queries {
            XCTAssertEqual(model.logProb(query.word, context: query.context), query.log10p,
                           accuracy: 1e-9, "\(query.context) → \(query.word)")
        }
        XCTAssertGreaterThan(lineLogProb(["2", "x", "+", "4"], model: model),
                             lineLogProb(["2", "·", "+", "4"], model: model))
    }
}
