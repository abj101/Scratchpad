import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import CanvasKit

/// Opt-in, release-only timing for the actual bundled classifier and resolver path.
final class MathGlyphLatencyTests: XCTestCase {
    private struct Sample {
        let label: String
        let classID: String
        let strokes: [Stroke]
        let bounds: CGRect
        let context: SymbolResolver.Context
    }

    private struct CommitCandidate {
        let sample: Sample
        let likelihoods: [String: Double]
        let expectedLabel: String?
        let expectedRevisions: [Int: String]
    }

    private let contextLabels = ["2", "x", "+", "3", "=", "6", "(", "1", ")", "+", "2", "·"]

    private struct CommitFixture {
        let scroll: CanvasScrollView
        let view: CanvasView
        let model: CanvasModel
        let initialCell: LetterCell
    }

    func testWarmedReleaseLatency() throws {
        guard ProcessInfo.processInfo.environment["RUN_MATH_GLYPH_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RUN_MATH_GLYPH_BENCHMARK=1 and run this test with the Release configuration.")
        }
        #if DEBUG
        XCTFail("The math glyph latency benchmark must run with the Release configuration.")
        #else

        let classifier = MathGlyphClassifier.shared
        guard classifier.isAvailable else {
            XCTFail("The checked, compiled MathGlyphs model and manifest are not available in this build.")
            return
        }
        let languageModel = try XCTUnwrap(MathLanguageModel.bundled)
        let samples = try makeSamples()
        XCTAssertGreaterThan(Set(samples.map(\.classID)).count, 3, "Benchmark inputs must cover at least four v2 classes.")
        let configuration = classifier.decoderConfiguration
        let decoder = MathLineDecoder(languageModel: languageModel,
                                      lambda: configuration.lambda, tauSub: configuration.tauSub,
                                      tauRev: configuration.tauRev,
                                      disabledLabels: configuration.disabledLabels, tauFill: configuration.tauFill)
        // The first Core ML prediction in a process pays one-time model load and compute-plan
        // preparation (a 9.3 ms outlier was seen once). It is warmup, not steady-state commit
        // latency, so it is measured and printed here but excluded from the 5 ms gate; the gated
        // samples below are all taken after the 24-call warmup per context.
        if let cold = samples.first {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = classifier.labelLikelihoods(strokes: cold.strokes, bounds: cold.bounds,
                                            context: cold.context)
            print("MATH_GLYPH_BENCHMARK first-call (cold, ungated) ms=\(milliseconds(DispatchTime.now().uptimeNanoseconds - start))")
        }

        let commitCandidates = samples.compactMap { sample -> CommitCandidate? in
            let likelihoods = classifier.labelLikelihoods(strokes: sample.strokes,
                                                           bounds: sample.bounds, context: sample.context)
            guard !likelihoods.isEmpty else { return nil }
            let decoded = decode(likelihoods, decoder: decoder)
            let keepsBlobInk = sample.strokes.count > 1
                && sample.bounds.width > 1.6 * (sample.context.medianHeight ?? sample.bounds.height)
            return CommitCandidate(sample: sample, likelihoods: likelihoods,
                                   expectedLabel: keepsBlobInk ? nil : decoded.substitution?.label,
                                   expectedRevisions: Dictionary(uniqueKeysWithValues:
                                       decoded.revisions.map { ($0.index, $0.label) }))
        }
        let plusSample = try XCTUnwrap(samples.first { $0.label == "+" })
        let plusClass = try XCTUnwrap(MathVocabulary.bundled?.classes.first { $0.labels == ["+"] })
        let revisionClassifier = MathGlyphClassifier(
            testClasses: [plusClass], temperature: 1, decoderConfiguration: configuration) { _, _, _ in [40] }
        let revisionResult = decode(["+": 1], decoder: decoder)
        guard let revision = revisionResult.revisions.first(where: { $0.index == contextLabels.count - 1 && $0.label == "x" }) else {
            XCTFail("The bundled 12-token context must resolve its displayed · to x after +.")
            return
        }
        let revisionCandidate = CommitCandidate(sample: plusSample, likelihoods: ["+": 1],
                                                expectedLabel: "+", expectedRevisions: [revision.index: revision.label])

        // Two side-by-side symbols pending together: segmentation scoring plus both commits.
        let twoSample = try XCTUnwrap(samples.first { $0.label == "2" })
        let exSample = try XCTUnwrap(samples.first { $0.label == "x" })
        let shift = twoSample.bounds.maxX + 0.3 * twoSample.bounds.height - exSample.bounds.minX
        let shifted = exSample.strokes.map { stroke -> Stroke in
            var copy = stroke
            copy.translate(by: CGVector(dx: shift, dy: 0))
            return copy
        }
        let splitSample = Sample(label: "2x", classID: twoSample.classID,
                                 strokes: twoSample.strokes + shifted,
                                 bounds: WritingLayout.letterExtent(twoSample.strokes + shifted),
                                 context: twoSample.context)
        var splitCommitTimes: [UInt64] = []

        // Warm the v2 class-to-label resolver, the 12-token decoder, and the full commit path.
        for candidate in commitCandidates {
            for _ in 0..<24 {
                let likelihoods = classifier.labelLikelihoods(strokes: candidate.sample.strokes,
                                                               bounds: candidate.sample.bounds,
                                                               context: candidate.sample.context)
                _ = decode(likelihoods, decoder: decoder).substitution?.label
            }
        }

        let commitFixture = InputMode.scribe.isAvailable && !commitCandidates.isEmpty
            ? try makeCommitFixture() : nil
        if let commitFixture {
            for candidate in commitCandidates {
                for _ in 0..<24 {
                    prepareCommit(commitFixture, sample: candidate.sample)
                    commitFixture.view.commitPendingLetter(follow: false)
                    assertCommitMatches(candidate, in: commitFixture.view)
                    resetCommit(commitFixture)
                }
            }
            for _ in 0..<24 {
                prepareCommit(commitFixture, sample: splitSample)
                commitFixture.view.commitPendingLetter(follow: false)
                resetCommit(commitFixture)
            }
            for _ in 0..<24 {
                prepareCommit(commitFixture, sample: revisionCandidate.sample)
                commitFixture.view.mathGlyphClassifier = revisionClassifier
                commitFixture.view.commitPendingLetter(follow: false)
                assertCommitMatches(revisionCandidate, in: commitFixture.view)
                resetCommit(commitFixture)
            }
        }

        let iterations = 100
        let capacity = iterations * commitCandidates.count
        var likelihoodTimes: [UInt64] = []; likelihoodTimes.reserveCapacity(capacity)
        var decoderTimes: [UInt64] = []; decoderTimes.reserveCapacity(capacity)
        var pipelineTimes: [UInt64] = []; pipelineTimes.reserveCapacity(capacity)
        var commitTimes: [UInt64] = []; commitTimes.reserveCapacity(iterations * commitCandidates.count)
        var revisionCommitTimes: [UInt64] = []; revisionCommitTimes.reserveCapacity(iterations)
        var consumedLabels = 0

        for _ in 0..<iterations {
            for candidate in commitCandidates {
                let likelihoodStart = DispatchTime.now().uptimeNanoseconds
                let likelihoods = classifier.labelLikelihoods(strokes: candidate.sample.strokes,
                                                               bounds: candidate.sample.bounds,
                                                               context: candidate.sample.context)
                likelihoodTimes.append(DispatchTime.now().uptimeNanoseconds - likelihoodStart)

                let decoderStart = DispatchTime.now().uptimeNanoseconds
                let decoded = decode(likelihoods, decoder: decoder).substitution?.label
                decoderTimes.append(DispatchTime.now().uptimeNanoseconds - decoderStart)
                consumedLabels += decoded?.utf8.count ?? 0
                pipelineTimes.append(likelihoodTimes.last! + decoderTimes.last!)
            }

            if let commitFixture {
                for candidate in commitCandidates {
                    prepareCommit(commitFixture, sample: candidate.sample)
                    let commitStart = DispatchTime.now().uptimeNanoseconds
                    commitFixture.view.commitPendingLetter(follow: false)
                    commitTimes.append(DispatchTime.now().uptimeNanoseconds - commitStart)
                    assertCommitMatches(candidate, in: commitFixture.view)
                    resetCommit(commitFixture)
                }
                prepareCommit(commitFixture, sample: splitSample)
                let splitStart = DispatchTime.now().uptimeNanoseconds
                commitFixture.view.commitPendingLetter(follow: false)
                splitCommitTimes.append(DispatchTime.now().uptimeNanoseconds - splitStart)
                XCTAssertEqual(commitFixture.view.writtenLetters.count, contextLabels.count + 2,
                               "2 and x must commit as two symbols")
                resetCommit(commitFixture)

                prepareCommit(commitFixture, sample: revisionCandidate.sample)
                commitFixture.view.mathGlyphClassifier = revisionClassifier
                let revisionStart = DispatchTime.now().uptimeNanoseconds
                commitFixture.view.commitPendingLetter(follow: false)
                revisionCommitTimes.append(DispatchTime.now().uptimeNanoseconds - revisionStart)
                assertCommitMatches(revisionCandidate, in: commitFixture.view)
                resetCommit(commitFixture)
            }
        }

        XCTAssertGreaterThan(consumedLabels, 0)
        XCTAssertEqual(likelihoodTimes.count, capacity)
        XCTAssertEqual(decoderTimes.count, capacity)
        XCTAssertEqual(pipelineTimes.count, capacity)
        if commitFixture != nil {
            XCTAssertEqual(commitTimes.count, iterations * commitCandidates.count)
            XCTAssertEqual(revisionCommitTimes.count, iterations)
        }

        print("MATH_GLYPH_BENCHMARK condition=Release; computeUnits=all; warmup=24/context; iterations=\(iterations); v2Labels=\(samples.count); callsPerStage=\(capacity); v2Classes=\(Set(samples.map(\.classID)).count); contextSymbols=12; revisionTargets=2; resolvedCommitSamples=\(commitCandidates.filter { $0.expectedLabel != nil }.count); modelSHA256=\(compiledModelHash() ?? "unavailable"); hardware={\(hardwareDescription())}; pipeline=labelLikelihoods+12-token decode; commitScope=commitPendingLetter including model-inference commits plus separate bundled-decoder revision seam")
        print(summary("v2 label likelihoods", likelihoodTimes))
        print(summary("12-token decoder", decoderTimes))
        print(summary("likelihoods+decoder", pipelineTimes))
        XCTAssertLessThan(decoderTimes.max() ?? 0, 500_000,
                          "Every 12-token forward-backward decode must stay below 0.5 ms.")
        if commitFixture != nil, !commitTimes.isEmpty {
            print(summary("full commit with bundled classifier", commitTimes))
            XCTAssertLessThan(commitTimes.max() ?? 0, 5_000_000,
                              "Every warmed 12-token full commit must stay below 5 ms.")
            print(summary("segmented 2-symbol commit (2x pending, whole group)", splitCommitTimes))
            XCTAssertLessThan(splitCommitTimes.max() ?? 0, 5_000_000,
                              "A warmed pending group that splits into two symbols must commit below 5 ms in total.")
            print(summary("12-token revision commit (classifier seam)", revisionCommitTimes))
            XCTAssertLessThan(revisionCommitTimes.max() ?? 0, 5_000_000,
                              "Every warmed 12-token commit that renders a revision must stay below 5 ms.")
            XCTAssertLessThan((commitTimes.max() ?? 0) + (revisionCommitTimes.max() ?? 0), 5_000_000,
                              "Bundled classification plus revision rendering must stay below 5 ms.")
        } else {
            print("full commit SKIPPED: math Write path unavailable or v2 classifier returned no label likelihoods")
        }
        #endif
    }

    private func makeSamples() throws -> [Sample] {
        let vocabulary = try XCTUnwrap(MathVocabulary.bundled)
        let labels = vocabulary.labels.filter { $0.kind != "junk" }
        return try labels.map { entry in
            let label = entry.label
            let paths = try XCTUnwrap(CleanGlyphs.strokes(for: label))
            let strokes = paths.enumerated().compactMap { strokeIndex, path -> Stroke? in
                guard !path.isEmpty else { return nil }
                let points = path.enumerated().map { index, point in
                    StrokePoint(x: Double(point.x), y: Double(point.y), t: Double(strokeIndex + index) / 300)
                }
                return Stroke(points: points, color: .black, width: 2)
            }
            guard !strokes.isEmpty else { throw XCTSkip("Missing Hershey strokes for \(label).") }
            let bounds = WritingLayout.letterExtent(strokes)
            let baseline = CGFloat(CleanGlyphs.metrics(for: label)?.baseline ?? 9)
            let context = SymbolResolver.Context(medianHeight: 18, baseline: baseline, mode: .math)
            return Sample(label: label, classID: entry.classID, strokes: strokes,
                          bounds: bounds, context: context)
        }
    }

    private func decode(_ likelihoods: [String: Double], decoder: MathLineDecoder) -> MathLineDecoder.Result {
        let context = contextLabels.enumerated().map { index, label in
            let distribution: [String: Double] = index == contextLabels.count - 1
                ? ["x": 0.5, "·": 0.5] : [label: 1]
            return MathLineDecoder.Symbol(labelLikelihoods: distribution,
                                          displayedLabel: label, isVirtual: false, isPinned: false)
        }
        var symbols = context
        symbols.append(MathLineDecoder.Symbol(labelLikelihoods: likelihoods))
        let newest = symbols.count - 1
        return decoder.decode(symbols, newestIndex: newest,
                              revisionIndices: [newest - 1, newest - 2])
    }

    private func assertCommitMatches(_ candidate: CommitCandidate, in view: CanvasView) {
        if candidate.expectedLabel == nil && view.writtenLetters.count == contextLabels.count {
            XCTAssertEqual(view.unresolvedMathStrokes.map(\.id), candidate.sample.strokes.map(\.id))
            return
        }
        XCTAssertEqual(view.writtenLetters.count, contextLabels.count + 1)
        XCTAssertEqual(view.writtenLetters.last?.displayed, candidate.expectedLabel,
                       "\(candidate.sample.label): width=\(candidate.sample.bounds.width), beforeHeight=\(view.writtenLetters.last?.beforeResolverStats?.medianHeight ?? -1), blob=\(view.writtenLetters.last?.isWideMathBlob ?? false)")
        for (index, label) in candidate.expectedRevisions {
            XCTAssertEqual(view.writtenLetters[index].displayed, label)
        }
    }

    private func makeCommitFixture() throws -> CommitFixture {
        let settings = CanvasSettings()
        settings.handwritingToText = true
        settings.scribeMath = true
        let model = CanvasModel()
        let scroll = CanvasScrollView(model: model, settings: settings)
        scroll.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        scroll.tile()
        settings.inputMode = .write
        guard settings.offersScribeZones else {
            throw XCTSkip("Scribe math mode is unavailable, so the commit renderer cannot be benchmarked.")
        }
        let view = scroll.canvasView
        view.mathFunctionRecognizer = nil
        let cell = try XCTUnwrap(view.writingCell)
        return CommitFixture(scroll: scroll, view: view, model: model, initialCell: cell)
    }

    private func prepareCommit(_ fixture: CommitFixture, sample: Sample) {
        resetCommit(fixture)
        fixture.view.mathGlyphClassifier = MathGlyphClassifier.shared
        fixture.view.writingCell = fixture.initialCell
        fixture.view.writingPanel?.cell = fixture.initialCell
        fixture.view.pendingLetter = sample.strokes
        fixture.view.writingRightLimit = .greatestFiniteMagnitude
        var stats = MathInkTidy.LineStats()
        if let height = sample.context.medianHeight, let baseline = sample.context.baseline {
            stats.record(CGRect(x: 0, y: baseline - height, width: height, height: height))
        }
        var row = MathFraction.Row(cell: fixture.initialCell,
                                   lineStats: MathFraction.LineStats(heights: stats.heights, bottoms: stats.bottoms),
                                   resolverStats: MathFraction.LineStats(heights: stats.heights, bottoms: stats.bottoms))
        var cell = fixture.initialCell
        var records: [CanvasView.WrittenLetter] = []
        var strokes: [Stroke] = []
        for (index, label) in contextLabels.enumerated() {
            let before = cell
            let x = cell.cursorX
            let stroke = Stroke(points: [StrokePoint(x: x + 1, y: cell.top + 8, t: 0),
                                         StrokePoint(x: x + 7, y: cell.top + 26, t: 0.1)],
                                color: .black, width: 2)
            let extent = WritingLayout.letterExtent([stroke])
            cell.cursorX = extent.maxX + LetterCell.letterGap * cell.height
            let id = UUID()
            let likelihoods: [String: Double] = index == contextLabels.count - 1
                ? ["x": 0.5, "·": 0.5] : [label: 1]
            row.items.append(.letter(MathFraction.Letter(id: id, label: label, extent: extent)))
            records.append(CanvasView.WrittenLetter(id: id, ids: [], before: before, after: cell,
                                                      originalStrokes: [stroke],
                                                      likelihoods: likelihoods, displayed: label, role: .body,
                                                      extent: extent, rowID: row.id,
                                                      beforeLineStats: stats, beforeResolverStats: stats))
            strokes.append(stroke)
        }
        row.cell = cell
        _ = strokes
        fixture.view.writtenLetters = records
        fixture.view.mathFractionRoot = row
        fixture.view.mathActiveRowID = row.id
        fixture.view.mathStartsAfterWordSpace = false
        fixture.view.writingCell = cell
        fixture.view.writingPanel?.cell = cell
        fixture.view.mathLineStats = stats
        fixture.view.mathResolverStats = stats
        fixture.view.mathPreviousSymbol = sample.context.previousSymbol
    }

    private func resetCommit(_ fixture: CommitFixture) {
        if !fixture.model.strokes.isEmpty {
            fixture.model.remove(ids: Set(fixture.model.strokes.map(\.id)), actionName: "Benchmark reset")
        }
        fixture.model.undoManager.removeAllActions()
        fixture.view.pendingLetter = []
        fixture.view.unresolvedMathStrokes = []
        fixture.view.writtenLetters = []
        fixture.view.mathFractionRoot = nil
        fixture.view.mathActiveRowID = nil
        fixture.view.mathStartsAfterWordSpace = false
        fixture.view.writingCell = fixture.initialCell
        fixture.view.writingPanel?.cell = fixture.initialCell
        fixture.view.writingRightLimit = .greatestFiniteMagnitude
        fixture.view.mathLineStats = nil
        fixture.view.mathResolverStats = nil
        fixture.view.mathPreviousSymbol = nil
    }

    private func percentile(_ values: [UInt64], _ percentile: Double) -> UInt64 {
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(sorted.count, rank) - 1]
    }

    private func summary(_ name: String, _ values: [UInt64]) -> String {
        "\(name) ms p50=\(milliseconds(percentile(values, 0.50))) p95=\(milliseconds(percentile(values, 0.95))) p99=\(milliseconds(percentile(values, 0.99))) max=\(milliseconds(values.max() ?? 0)) n=\(values.count)"
    }

    private func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.4f", Double(nanoseconds) / 1_000_000)
    }

    private func compiledModelHash() -> String? {
        guard let url = CleanGlyphs.resourceBundle.url(forResource: "MathGlyphs-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["compiledBundleSHA256"] as? String ?? manifest["compiled_bundle_sha256"] as? String
    }

    private func hardwareDescription() -> String {
        let model = sysctl("hw.model") ?? "unknown"
        let chip = sysctl("machdep.cpu.brand_string") ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let process = ProcessInfo.processInfo
        return "hw.model=\(model),chip=\(chip),arch=\(architecture),os=\(process.operatingSystemVersionString),logicalCPUs=\(process.processorCount)"
    }

    private func sysctl(_ name: String) -> String? {
        name.withCString { key in
            var length = 0
            guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return nil }
            var value = [CChar](repeating: 0, count: length)
            let result = value.withUnsafeMutableBufferPointer { buffer in
                sysctlbyname(key, buffer.baseAddress, &length, nil, 0)
            }
            return result == 0 ? String(cString: value) : nil
        }
    }
}
