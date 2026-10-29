import Foundation

/// Rescores a math line's label likelihoods with the bundled order-4 language model.
public struct MathLineDecoder {
    public struct Symbol {
        public let labelLikelihoods: [String: Double]
        public let displayedLabel: String?
        public let isVirtual: Bool
        public let isPinned: Bool

        public init(labelLikelihoods: [String: Double], displayedLabel: String? = nil,
                    isVirtual: Bool = false, isPinned: Bool = false) {
            self.labelLikelihoods = labelLikelihoods
            self.displayedLabel = displayedLabel
            self.isVirtual = isVirtual
            self.isPinned = isPinned
        }
    }

    public struct Update: Equatable {
        public let index: Int
        public let label: String
        public let marginal: Double
    }

    public struct Result {
        public let marginals: [[String: Double]]
        public let substitution: Update?
        public let revisions: [Update]
        private let symbols: [Symbol]

        fileprivate init(symbols: [Symbol], marginals: [[String: Double]],
                         substitution: Update?, revisions: [Update]) {
            self.symbols = symbols
            self.marginals = marginals
            self.substitution = substitution
            self.revisions = revisions
        }

        /// The three strongest alternatives, excluding the displayed label and `<unk>`.
        public func alternatives(at index: Int) -> [(label: String, marginal: Double)] {
            guard symbols.indices.contains(index), marginals.indices.contains(index) else { return [] }
            let displayed = symbols[index].displayedLabel ?? "<unk>"
            return marginals[index]
                .filter { $0.key != displayed && $0.key != "<unk>" && $0.value >= 0.02 }
                .sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key < $1.key
                }
                .prefix(3)
                .map { (label: $0.key, marginal: $0.value) }
        }
    }

    private struct Candidate {
        let label: String
        let labelID: UInt8
        let likelihood: Double
    }

    private struct History {
        let first: Int
        let second: Int
        let third: Int
        let code: UInt32
    }

    private struct Edge {
        let nextIndex: Int
        let weight: Double
    }

    private let languageModel: MathLanguageModel
    private let lambda: Double
    private let tauSub: Double
    private let tauRev: Double
    private let tauFill: Double
    private let disabledLabels: Set<String>

    public init(languageModel: MathLanguageModel, lambda: Double = 0.6,
                tauSub: Double = 0.80, tauRev: Double = 0.90,
                disabledLabels: Set<String> = [], tauFill: Double? = nil) {
        self.languageModel = languageModel
        self.lambda = lambda
        self.tauSub = tauSub
        self.tauRev = tauRev
        self.tauFill = tauFill ?? tauRev
        self.disabledLabels = disabledLabels
    }

    /// Exact forward-backward over the last 12 tokens ending at this commit.
    /// An interior commit index uses its preceding reading-order context.
    public func decode(_ symbols: [Symbol], newestIndex: Int? = nil,
                       revisionIndices: [Int]? = nil) -> Result {
        let newest = newestIndex ?? symbols.count - 1
        guard !symbols.isEmpty, symbols.indices.contains(newest), !symbols[newest].isVirtual else {
            return Result(symbols: symbols, marginals: Array(repeating: [:], count: symbols.count),
                          substitution: nil, revisions: [])
        }

        let end = newest + 1
        let start = max(0, end - 12)
        let prefix = symbols[..<start].map(fixedLabel)
        let paddedContext = (["<s>", "<s>", "<s>"] + prefix).suffix(3)
        let rows = symbols[start..<end].map(candidates)
        let length = rows.count
        let startRow = paddedContext.map { label in
            Candidate(label: label, labelID: contextSymbolID(for: label), likelihood: 1)
        }
        var augmentedRows = startRow.map { [$0] }
        augmentedRows.append(contentsOf: rows)
        var states: [[History]] = []
        for position in 0...length {
            let first = augmentedRows[position]
            let second = augmentedRows[position + 1]
            let third = augmentedRows[position + 2]
            var layer: [History] = []
            for firstIndex in first.indices {
                for secondIndex in second.indices {
                    for thirdIndex in third.indices {
                        let code = (UInt32(first[firstIndex].labelID) << 14) |
                            (UInt32(second[secondIndex].labelID) << 7) |
                            UInt32(third[thirdIndex].labelID)
                        layer.append(History(first: firstIndex, second: secondIndex,
                                             third: thirdIndex, code: code))
                    }
                }
            }
            states.append(layer)
        }
        var edges: [[Edge]] = []
        var transitionWeights: [UInt32: Double] = [:]
        let lambdaNatural = lambda * log(10)
        for position in rows.indices {
            let nextCount = rows[position].count
            let thirdCount = augmentedRows[position + 2].count
            var layerEdges: [Edge] = []
            layerEdges.reserveCapacity(states[position].count * nextCount)
            for history in states[position] {
                for candidate in rows[position] {
                    let key = (history.code << 7) | UInt32(candidate.labelID)
                    let languageWeight: Double
                    if let cached = transitionWeights[key] {
                        languageWeight = cached
                    } else {
                        let logProbability = languageModel.logProb(wordID: candidate.labelID,
                                                                   historyCode: history.code)
                        let weight = logProbability == -.infinity ? 0 : exp(lambdaNatural * logProbability)
                        transitionWeights[key] = weight
                        languageWeight = weight
                    }
                    let candidateIndex = layerEdges.count % nextCount
                    let nextIndex = (history.second * thirdCount + history.third) * nextCount + candidateIndex
                    layerEdges.append(Edge(nextIndex: nextIndex,
                                           weight: candidate.likelihood * languageWeight))
                }
            }
            edges.append(layerEdges)
        }

        var forward = [[1.0]]
        var scales: [Double] = []
        for position in rows.indices {
            var layer = Array(repeating: 0.0, count: states[position + 1].count)
            let candidateCount = rows[position].count
            for stateIndex in states[position].indices {
                let prefixScore = forward[position][stateIndex]
                let base = stateIndex * candidateCount
                for candidateIndex in 0..<candidateCount {
                    let edge = edges[position][base + candidateIndex]
                    layer[edge.nextIndex] += prefixScore * edge.weight
                }
            }
            let scale = layer.reduce(0, +)
            if scale > 0 {
                for index in layer.indices { layer[index] /= scale }
            }
            scales.append(scale)
            forward.append(layer)
        }

        var backward = Array(repeating: [Double](), count: length + 1)
        backward[length] = Array(repeating: 1, count: states[length].count)
        for position in stride(from: length - 1, through: 0, by: -1) {
            var layer = Array(repeating: 0.0, count: states[position].count)
            let candidateCount = rows[position].count
            for stateIndex in states[position].indices {
                var score = 0.0
                let base = stateIndex * candidateCount
                for candidateIndex in 0..<candidateCount {
                    let edge = edges[position][base + candidateIndex]
                    let suffix = backward[position + 1][edge.nextIndex]
                    score += edge.weight * suffix
                }
                layer[stateIndex] = scales[position] > 0 ? score / scales[position] : 0
            }
            backward[position] = layer
        }

        var marginalRows = symbols[..<start].map { [fixedLabel($0): 1.0] }
        for position in rows.indices {
            var labelScores = Array(repeating: 0.0, count: rows[position].count)
            let candidateCount = rows[position].count
            for stateIndex in states[position].indices {
                let prefixScore = forward[position][stateIndex]
                let base = stateIndex * candidateCount
                for candidateIndex in 0..<candidateCount {
                    let edge = edges[position][base + candidateIndex]
                    let suffix = backward[position + 1][edge.nextIndex]
                    labelScores[candidateIndex] += prefixScore * edge.weight * suffix
                }
            }
            let total = labelScores.reduce(0, +)
            if total == 0 {
                marginalRows.append(Dictionary(uniqueKeysWithValues: rows[position].indices.map {
                    (rows[position][$0].label, 0)
                }))
            } else {
                marginalRows.append(Dictionary(uniqueKeysWithValues: rows[position].indices.map {
                    (rows[position][$0].label, labelScores[$0] / total)
                }))
            }
        }
        marginalRows.append(contentsOf: symbols[end...].map { [fixedLabel($0): 1.0] })

        func best(_ index: Int) -> (String, Double) {
            marginalRows[index].sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }.first.map { ($0.key, $0.value) } ?? ("<unk>", 0)
        }

        var substitution: Update?
        if !symbols[newest].isPinned {
            let (label, probability) = best(newest)
            if label != "<unk>", !disabledLabels.contains(label), probability >= tauSub {
                substitution = Update(index: newest, label: label, marginal: probability)
            }
        }

        let earlier = revisionIndices ?? Array(symbols.indices.prefix(newest)
            .filter { !symbols[$0].isVirtual }.suffix(2))
        let revisions = earlier.compactMap { index -> Update? in
            guard symbols.indices.contains(index), index != newest, !symbols[index].isVirtual else { return nil }
            let symbol = symbols[index]
            guard !symbol.isPinned else { return nil }
            let (label, probability) = best(index)
            let displayed = symbol.displayedLabel ?? "<unk>"
            let displayedProbability = marginalRows[index][displayed] ?? 0
            guard label != displayed, label != "<unk>", !disabledLabels.contains(label),
                  probability >= (symbol.displayedLabel == nil ? tauFill : tauRev),
                  symbol.displayedLabel == nil || displayedProbability <= 0.10 else { return nil }
            return Update(index: index, label: label, marginal: probability)
        }

        return Result(symbols: symbols, marginals: marginalRows,
                      substitution: substitution, revisions: revisions)
    }

    private func contextSymbolID(for label: String) -> UInt8 {
        // Named functions are single prefix tokens. The bundled LM predates
        // function words, so use its unary prefix context until the LM replan.
        if label == "q" { return languageModel.symbolID(for: "p") }
        if label == "{" { return languageModel.symbolID(for: "[") }
        if label == "}" { return languageModel.symbolID(for: "]") }
        return languageModel.symbolID(for: MathFunctionNames.names.contains(label) ? "√" : label)
    }

    private func candidates(_ symbol: Symbol) -> [Candidate] {
        if symbol.isPinned {
            let label = symbol.displayedLabel ?? "<unk>"
            return [Candidate(label: label, labelID: contextSymbolID(for: label), likelihood: 1)]
        }
        let entries = symbol.labelLikelihoods
            .filter { $0.value.isFinite && $0.value > 0 }
            .sorted { $0.key < $1.key }
        if symbol.isVirtual {
            let selected = entries.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }.first?.key ?? symbol.displayedLabel ?? "<unk>"
            return [Candidate(label: selected, labelID: contextSymbolID(for: selected), likelihood: 1)]
        }
        var total = 0.0
        for entry in entries { total += entry.value }
        guard total > 0 else {
            return [Candidate(label: "<unk>", labelID: contextSymbolID(for: "<unk>"), likelihood: 1)]
        }
        return entries.map {
            Candidate(label: $0.key, labelID: contextSymbolID(for: $0.key),
                      likelihood: $0.value / total)
        }
    }

    private func fixedLabel(_ symbol: Symbol) -> String {
        if symbol.isPinned { return symbol.displayedLabel ?? "<unk>" }
        if symbol.isVirtual { return candidates(symbol)[0].label }
        return symbol.displayedLabel ?? "<unk>"
    }

}
