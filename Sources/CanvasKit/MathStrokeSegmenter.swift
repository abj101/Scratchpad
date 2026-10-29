import CoreGraphics
import Foundation

/// Splits the strokes pending in math input into symbols before classification, so quickly
/// written neighbours (`2x`, `15`) are not read as one glyph.
///
/// Only boundaries between time-consecutive strokes are considered, and only where the
/// strokes before and after the boundary do not overlap horizontally (within a tolerance
/// relative to the ink height). Crossing or stacked strokes (`+`, `x`, `=`, `≥`, `4`) have
/// no such boundary and stay whole. A clear gap (15% of the normal symbol height) forces
/// a split; near-touching groups compete on summed log best-likelihood with a mild prior.
enum MathStrokeSegmenter {
    /// Overlap tolerance as a share of the ink height.
    static let overlapTolerance: CGFloat = 0.10
    /// Log-prior against each additional symbol (about a 0.8 probability factor).
    static let splitPenalty = 0.223
    /// Above this many candidate boundaries, split at every one without scoring.
    static let scoredBoundaryLimit = 6

    /// `score` returns the classifier's best label likelihood (0...1) for a stroke group.
    static func segment(_ strokes: [Stroke], normalHeight: CGFloat? = nil,
                        score: ([Stroke]) -> Double) -> [[Stroke]] {
        let count = strokes.count
        guard count >= 2 else { return [strokes] }
        let boxes = strokes.map { WritingLayout.letterExtent([$0]) }
        let height = boxes.map { $0.height }.max() ?? 0
        // A real inter-symbol gap wins over a confident guess for the merged blob.
        let gap = 0.15 * (normalHeight ?? max(height, WritingLayout.letterExtent(strokes).height))
        var suffix = boxes
        for k in stride(from: count - 2, through: 0, by: -1) {
            suffix[k] = boxes[k].union(suffix[k + 1])
        }
        var forcedCuts = [0]
        var current = boxes[0]
        for k in 1..<count {
            // A later crossbar may bridge two earlier strokes (for example π).
            if suffix[k].minX > current.maxX + gap {
                forcedCuts.append(k)
                current = boxes[k]
            } else {
                current = current.union(boxes[k])
            }
        }
        if forcedCuts.count > 1 {
            forcedCuts.append(count)
            return zip(forcedCuts, forcedCuts.dropFirst()).flatMap {
                segment(Array(strokes[$0..<$1]), normalHeight: normalHeight, score: score)
            }
        }
        let tolerance = overlapTolerance * max(height, WritingLayout.letterExtent(strokes).height)

        var boundaries: [Int] = []
        for k in 1..<count {
            let left = boxes[..<k].reduce(CGRect.null) { $0.union($1) }
            let right = boxes[k...].reduce(CGRect.null) { $0.union($1) }
            if right.minX - left.maxX > -tolerance { boundaries.append(k) }
        }
        guard !boundaries.isEmpty else { return [strokes] }

        let cuts = [0] + boundaries + [count]
        if boundaries.count > scoredBoundaryLimit { return groups(strokes, cuts: cuts) }

        var cache: [Int: Double] = [:]
        func segmentScore(_ from: Int, _ to: Int) -> Double {
            let key = from * 1000 + to
            if let cached = cache[key] { return cached }
            let value = log(max(score(Array(strokes[cuts[from]..<cuts[to]])), 1e-6))
            cache[key] = value
            return value
        }

        var best = [Double](repeating: -.infinity, count: cuts.count)
        var previous = [Int](repeating: 0, count: cuts.count)
        best[0] = 0
        for i in 1..<cuts.count {
            for j in 0..<i {
                let total = best[j] + segmentScore(j, i) - (j > 0 ? splitPenalty : 0)
                if total > best[i] { best[i] = total; previous[i] = j }
            }
        }
        var chosen = [cuts.count - 1]
        while let last = chosen.last, last > 0 { chosen.append(previous[last]) }
        return groups(strokes, cuts: chosen.reversed().map { cuts[$0] })
    }

    private static func groups(_ strokes: [Stroke], cuts: [Int]) -> [[Stroke]] {
        zip(cuts, cuts.dropFirst()).map { Array(strokes[$0..<$1]) }
    }
}
