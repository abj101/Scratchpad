import CoreML
import CoreVideo
import CryptoKit
import Foundation

/// Bundled classifier for math glyph classes and legacy v1 groups.
public final class MathGlyphClassifier {
    public static let shared = MathGlyphClassifier()

    public struct Prediction {
        public let group: String
        public let confidence: Double
        public let margin: Double
        public let probabilities: [String: Double]
    }

    public struct DecoderConfiguration {
        public let lambda: Double
        public let tauSub: Double
        public let tauRev: Double
        public let tauFill: Double
        public let disabledLabels: Set<String>

        public init(lambda: Double, tauSub: Double, tauRev: Double, disabledLabels: Set<String>,
                    tauFill: Double? = nil) {
            self.lambda = lambda
            self.tauSub = tauSub
            self.tauRev = tauRev
            self.tauFill = tauFill ?? tauRev
            self.disabledLabels = disabledLabels
        }
    }

    private struct Manifest: Decodable {
        let version: Int
        let classes: [String]?
        let mathVocabSHA256: String?
        let compiledBundleSHA256: String
        let temperature: Double?
        let lambda: Double?
        let tauSub: Double?
        let tauRev: Double?
        let tauFill: Double?
        let disabledLabels: [String]?
        let mathLMSHA256: String?
        let groups: [String]?
        let vocabSHA256: String?
        let threshold: Double?
        let margin: Double?

        enum CodingKeys: String, CodingKey {
            case version, classes, mathVocabSHA256, compiledBundleSHA256
            case temperature, lambda, tauSub, tauRev, tauFill, disabledLabels, mathLMSHA256, groups, threshold, margin
            case vocabSHA256, vocabSHA256Snake = "vocab_sha256"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            classes = try values.decodeIfPresent([String].self, forKey: .classes)
            mathVocabSHA256 = try values.decodeIfPresent(String.self, forKey: .mathVocabSHA256)
            compiledBundleSHA256 = try values.decode(String.self, forKey: .compiledBundleSHA256)
            temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
            lambda = try values.decodeIfPresent(Double.self, forKey: .lambda)
            tauSub = try values.decodeIfPresent(Double.self, forKey: .tauSub)
            tauRev = try values.decodeIfPresent(Double.self, forKey: .tauRev)
            tauFill = try values.decodeIfPresent(Double.self, forKey: .tauFill)
            disabledLabels = try values.decodeIfPresent([String].self, forKey: .disabledLabels)
            mathLMSHA256 = try values.decodeIfPresent(String.self, forKey: .mathLMSHA256)
            groups = try values.decodeIfPresent([String].self, forKey: .groups)
            vocabSHA256 = try values.decodeIfPresent(String.self, forKey: .vocabSHA256)
                ?? values.decodeIfPresent(String.self, forKey: .vocabSHA256Snake)
            threshold = try values.decodeIfPresent(Double.self, forKey: .threshold)
            margin = try values.decodeIfPresent(Double.self, forKey: .margin)
        }
    }

    private struct LegacyVocabulary: Decodable {
        struct Entry: Decodable {
            let label: String
            let group: String
        }
        let classes: [Entry]
    }

    private typealias LegacyPredictor = ([UInt8]) -> [String: Double]?
    private typealias MathPredictor = ([UInt8], [[Float]], [Float]) -> [Double]?

    private struct Runtime {
        let version: Int
        let groups: [String]
        let classes: [MathVocabulary.GlyphClass]
        let classByLabel: [String: String]
        let legacyGroupMembers: [String: [String]]
        let legacyDisabledLabels: Set<String>
        let decoderConfiguration: DecoderConfiguration
        let temperature: Double
        let legacyPredictor: LegacyPredictor?
        let mathPredictor: MathPredictor?
    }

    private let runtime: Runtime?
    private let confidenceThreshold = 0.85
    private let marginThreshold = 0.3

    private init() {
        runtime = Self.loadRuntime(bundle: .module, computeUnits: .all)
    }

    private init(runtime: Runtime?) {
        self.runtime = runtime
    }

    /// Test seam for the temporary v1 predictor and existing commit-path tests.
    internal convenience init(testGroups: [String], disabledLabels: Set<String> = [],
                              probabilitiesForRaster: @escaping ([UInt8]) -> [String: Double]?) {
        let groups = testGroups.sorted()
        let vocabulary = MathVocabulary.bundled
        let classes = vocabulary?.classes ?? []
        self.init(runtime: Runtime(
            version: 1,
            groups: groups,
            classes: classes,
            classByLabel: Self.classByLabel(classes),
            legacyGroupMembers: Self.loadLegacyGroupMembers(bundle: .module) ?? [:],
            legacyDisabledLabels: disabledLabels,
            decoderConfiguration: Self.defaultDecoderConfiguration,
            temperature: 1,
            legacyPredictor: probabilitiesForRaster,
            mathPredictor: nil
        ))
    }

    /// Test seam for deterministic v2 logits without loading a Core ML model.
    internal convenience init(testClasses: [MathVocabulary.GlyphClass], temperature: Double,
                              decoderConfiguration: DecoderConfiguration = MathGlyphClassifier.defaultDecoderConfiguration,
                              logitsForInputs: @escaping ([UInt8], [[Float]], [Float]) -> [Double]?) {
        self.init(runtime: Runtime(
            version: 2,
            groups: [],
            classes: testClasses,
            classByLabel: Self.classByLabel(testClasses),
            legacyGroupMembers: [:],
            legacyDisabledLabels: [],
            decoderConfiguration: decoderConfiguration,
            temperature: temperature,
            legacyPredictor: nil,
            mathPredictor: logitsForInputs
        ))
    }

    /// Load a model and manifest from a directory for the opt-in dummy-model check.
    internal convenience init(testRuntimeAt directory: URL, computeUnits: MLComputeUnits = .all) {
        self.init(runtime: Self.loadRuntime(
            modelURL: directory.appendingPathComponent("MathGlyphs.mlmodelc"),
            manifestURL: directory.appendingPathComponent("MathGlyphs-manifest.json"),
            mathVocabURL: Bundle.module.url(forResource: "math-vocab", withExtension: "json"),
            legacyVocabURL: Bundle.module.url(forResource: "vocab", withExtension: "json"),
            mathLMURL: Bundle.module.url(forResource: "MathLM", withExtension: "json"),
            computeUnits: computeUnits
        ))
    }

    private static let defaultDecoderConfiguration = DecoderConfiguration(
        lambda: 0.6, tauSub: 0.80, tauRev: 0.90, disabledLabels: []
    )

    public var isAvailable: Bool { runtime != nil }
    /// 1 = legacy grouped model, 2 = three-input model with `labelLikelihoods`.
    var runtimeVersion: Int? { runtime?.version }
    public var decoderConfiguration: DecoderConfiguration {
        runtime?.decoderConfiguration ?? Self.defaultDecoderConfiguration
    }

    /// Return the highest-probability legacy group with its runner-up margin.
    /// This remains for the v1 CanvasView path until decoder integration lands.
    public func classify(_ strokes: [Stroke]) -> Prediction? {
        guard !strokes.isEmpty else { return nil }
        return classify(raster: GlyphRaster.rasterize(strokes))
    }

    /// Shared path for legacy native fixture parity; pixels are raw white=255 raster bytes.
    func classify(raster pixels: [UInt8]) -> Prediction? {
        guard let runtime, runtime.version == 1,
              pixels.count == 1024,
              let values = runtime.legacyPredictor?(pixels),
              Self.validProbabilities(values, keys: runtime.groups) else { return nil }

        let ranked = runtime.groups.enumerated().sorted { lhs, rhs in
            let a = values[lhs.element]!, b = values[rhs.element]!
            return a == b ? lhs.offset < rhs.offset : a > b
        }
        guard let first = ranked.first else { return nil }
        let confidence = values[first.element]!
        let runnerUp = ranked.dropFirst().first.map { values[$0.element]! } ?? 0
        return Prediction(group: first.element, confidence: confidence,
                          margin: confidence - runnerUp, probabilities: values)
    }

    /// Returns the top five label likelihoods after geometric member weighting.
    public func labelLikelihoods(strokes: [Stroke], bounds: CGRect,
                                 context: SymbolResolver.Context) -> [String: Double] {
        guard let runtime, !strokes.isEmpty else { return [:] }
        let pixels = GlyphRaster.rasterize(strokes)

        if runtime.version == 1 {
            guard let values = runtime.legacyPredictor?(pixels),
                  Self.validProbabilities(values, keys: runtime.groups) else { return [:] }
            let scores = Self.legacyLabelScores(values, runtime: runtime, bounds: bounds, context: context)
            return Self.topFive(scores, classes: runtime.classes)
        }

        guard runtime.version == 2, runtime.temperature.isFinite, runtime.temperature > 0,
              let features = GlyphSequence.encode(strokes),
              let globals = Self.strokeGlobals(features: features, strokes: strokes),
              let logits = runtime.mathPredictor?(pixels, features.strokePoints, globals),
              logits.count == runtime.classes.count,
              let classProbabilities = Self.softmax(logits, temperature: runtime.temperature) else { return [:] }

        var scores: [String: Double] = [:]
        for (index, glyphClass) in runtime.classes.enumerated() {
            let weights = SymbolResolver.memberWeights(class: glyphClass.id, bounds: bounds, context: context)
            let members = glyphClass.labels.compactMap { label -> (String, Double)? in
                guard let weight = weights[label], weight.isFinite, weight >= 0 else { return nil }
                return (label, weight)
            }
            let weightTotal = members.reduce(0.0) { $0 + $1.1 }
            guard weightTotal > 0, classProbabilities[index] > 0 else { continue }
            for (label, weight) in members {
                scores[label, default: 0] += classProbabilities[index] * weight / weightTotal
            }
        }
        return Self.topFive(scores, classes: runtime.classes)
    }

    /// Resolve an already computed legacy prediction without rasterizing the ink again.
    public func resolve(_ prediction: Prediction, originalBounds: CGRect,
                        context: SymbolResolver.Context) -> String? {
        guard let runtime, runtime.version == 1, accepts(prediction) else { return nil }
        return SymbolResolver.resolve(group: prediction.group, originalBounds: originalBounds,
                                      context: context, disabledLabels: runtime.legacyDisabledLabels)
    }

    public func resolve(_ strokes: [Stroke], originalBounds: CGRect,
                        context: SymbolResolver.Context) -> String? {
        guard let prediction = classify(strokes) else { return nil }
        return resolve(prediction, originalBounds: originalBounds, context: context)
    }

    func accepts(_ prediction: Prediction) -> Bool {
        prediction.confidence.isFinite && prediction.margin.isFinite
            && prediction.confidence >= confidenceThreshold
            && prediction.margin >= marginThreshold
    }

    private static func loadRuntime(bundle: Bundle, computeUnits: MLComputeUnits) -> Runtime? {
        guard let manifestURL = bundle.url(forResource: "MathGlyphs-manifest", withExtension: "json"),
              let modelURL = bundle.url(forResource: "MathGlyphs", withExtension: "mlmodelc"),
              let mathVocabURL = bundle.url(forResource: "math-vocab", withExtension: "json"),
              let legacyVocabURL = bundle.url(forResource: "vocab", withExtension: "json") else { return nil }
        return loadRuntime(modelURL: modelURL, manifestURL: manifestURL,
                           mathVocabURL: mathVocabURL, legacyVocabURL: legacyVocabURL,
                           mathLMURL: bundle.url(forResource: "MathLM", withExtension: "json"),
                           computeUnits: computeUnits)
    }

    private static func loadRuntime(modelURL: URL?, manifestURL: URL?, mathVocabURL: URL?,
                                    legacyVocabURL: URL?, mathLMURL: URL?,
                                    computeUnits: MLComputeUnits) -> Runtime? {
        guard let modelURL, let manifestURL,
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.compiledBundleSHA256 == bundleSHA256(at: modelURL),
              let mathVocabURL,
              let mathVocabData = try? Data(contentsOf: mathVocabURL),
              let mathVocabulary = try? JSONDecoder().decode(MathVocabulary.self, from: mathVocabData),
              mathVocabulary.version == 2,
              let model = loadModel(at: modelURL, computeUnits: computeUnits) else { return nil }

        let classes = mathVocabulary.classes
        let labels = classes.flatMap(\.labels)
        guard Set(labels).count == labels.count else { return nil }
        let classByLabel = classByLabel(classes)

        switch manifest.version {
        case 1:
            guard let groups = manifest.groups, !groups.isEmpty,
                  groups == groups.sorted(), Set(groups).count == groups.count,
                  let vocabSHA256 = manifest.vocabSHA256,
                  let legacyVocabURL,
                  let legacyVocabData = try? Data(contentsOf: legacyVocabURL),
                  vocabSHA256 == sha256(legacyVocabData),
                  manifest.threshold == 0.85, manifest.margin == 0.3,
                  let legacyGroupMembers = legacyGroupMembers(legacyVocabData),
                  Set(legacyGroupMembers.keys) == Set(groups),
                  validateLegacyModel(model) else { return nil }

            let configuration = DecoderConfiguration(
                lambda: 0.6, tauSub: 0.80, tauRev: 0.90, disabledLabels: []
            )
            let predict: LegacyPredictor = { pixels in
                guard let pixelBuffer = pixelBuffer(pixels),
                      let features = try? MLDictionaryFeatureProvider(dictionary: [
                        "glyphImage": MLFeatureValue(pixelBuffer: pixelBuffer)
                      ]),
                      let result = try? model.prediction(from: features),
                      let dictionary = result.featureValue(for: "group_probs")?.dictionaryValue,
                      dictionary.count == groups.count else { return nil }
                var values: [String: Double] = [:]
                for (key, value) in dictionary {
                    guard let group = key as? String else { return nil }
                    values[group] = value.doubleValue
                }
                return values
            }
            return Runtime(version: 1, groups: groups, classes: classes,
                           classByLabel: classByLabel, legacyGroupMembers: legacyGroupMembers,
                           legacyDisabledLabels: Set(manifest.disabledLabels ?? []),
                           decoderConfiguration: configuration, temperature: 1,
                           legacyPredictor: predict, mathPredictor: nil)

        case 2:
            guard let manifestClasses = manifest.classes,
                  manifestClasses == classes.map(\.id),
                  manifestClasses == manifestClasses.sorted(),
                  let mathVocabSHA256 = manifest.mathVocabSHA256,
                  mathVocabSHA256 == sha256(mathVocabData),
                  let mathLMSHA256 = manifest.mathLMSHA256,
                  let mathLMURL,
                  let mathLMData = try? Data(contentsOf: mathLMURL),
                  mathLMSHA256 == sha256(mathLMData),
                  let temperature = manifest.temperature, temperature.isFinite, temperature > 0,
                  let lambda = manifest.lambda, lambda.isFinite, lambda >= 0,
                  let tauSub = manifest.tauSub, tauSub.isFinite, (0...1).contains(tauSub),
                  let tauRev = manifest.tauRev, tauRev.isFinite, (0...1).contains(tauRev),
                  validateMathModel(model, classCount: classes.count) else { return nil }
            let tauFill = manifest.tauFill ?? tauRev
            guard tauFill.isFinite, (0...1).contains(tauFill),
                  let manifestDisabledLabels = manifest.disabledLabels else { return nil }
            let disabled = Set(manifestDisabledLabels)
            guard disabled.isSubset(of: Set(labels)) else { return nil }

            let configuration = DecoderConfiguration(lambda: lambda, tauSub: tauSub,
                                                      tauRev: tauRev, disabledLabels: disabled, tauFill: tauFill)
            let predict: MathPredictor = { pixels, points, globals in
                guard let pixelBuffer = pixelBuffer(pixels),
                      let pointsArray = pointArray(points),
                      let globalsArray = globalArray(globals),
                      let features = try? MLDictionaryFeatureProvider(dictionary: [
                        "glyphImage": MLFeatureValue(pixelBuffer: pixelBuffer),
                        "strokePoints": MLFeatureValue(multiArray: pointsArray),
                        "strokeGlobals": MLFeatureValue(multiArray: globalsArray),
                      ]),
                      let result = try? model.prediction(from: features),
                      let logits = result.featureValue(for: "logits")?.multiArrayValue,
                      let embedding = result.featureValue(for: "embedding")?.multiArrayValue,
                      validTensor(logits, shape: [1, classes.count]),
                      validTensor(embedding, shape: [1, 256]) else { return nil }
                return (0..<classes.count).map {
                    logits[[NSNumber(value: 0), NSNumber(value: $0)]].doubleValue
                }
            }
            return Runtime(version: 2, groups: [], classes: classes,
                           classByLabel: classByLabel, legacyGroupMembers: [:],
                           legacyDisabledLabels: [], decoderConfiguration: configuration,
                           temperature: temperature, legacyPredictor: nil, mathPredictor: predict)

        default:
            return nil
        }
    }

    private static func loadModel(at url: URL, computeUnits: MLComputeUnits) -> MLModel? {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try? MLModel(contentsOf: url, configuration: configuration)
    }

    private static func validateLegacyModel(_ model: MLModel) -> Bool {
        let description = model.modelDescription
        guard description.inputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName["glyphImage"],
              input.type == .image,
              input.imageConstraint?.pixelsWide == 32,
              input.imageConstraint?.pixelsHigh == 32,
              description.predictedProbabilitiesName == "group_probs",
              description.outputDescriptionsByName["group"] != nil,
              description.outputDescriptionsByName["group_probs"] != nil else { return false }
        return true
    }

    private static func validateMathModel(_ model: MLModel, classCount: Int) -> Bool {
        let description = model.modelDescription
        let inputs = description.inputDescriptionsByName
        let outputs = description.outputDescriptionsByName
        guard inputs.count == 3, outputs.count == 2,
              let image = inputs["glyphImage"], image.type == .image,
              image.imageConstraint?.pixelsWide == 32, image.imageConstraint?.pixelsHigh == 32,
              isTensor(inputs["strokePoints"], shape: [1, 128, 4]),
              isTensor(inputs["strokeGlobals"], shape: [1, 2]),
              isTensor(outputs["logits"], shape: [1, classCount]),
              isTensor(outputs["embedding"], shape: [1, 256]) else { return false }
        return true
    }

    private static func isTensor(_ description: MLFeatureDescription?, shape: [Int]) -> Bool {
        guard let description, description.type == .multiArray,
              let constraint = description.multiArrayConstraint,
              constraint.dataType == .float32,
              constraint.shape.map(\.intValue) == shape else { return false }
        return true
    }

    private static func validTensor(_ array: MLMultiArray, shape: [Int]) -> Bool {
        array.dataType == .float32 && array.shape.map(\.intValue) == shape
    }

    private static func pointArray(_ points: [[Float]]) -> MLMultiArray? {
        guard points.count == GlyphSequence.sampleCount, points.allSatisfy({ $0.count == 4 }),
              let array = try? MLMultiArray(shape: [1, 128, 4], dataType: .float32) else { return nil }
        let data = array.dataPointer.assumingMemoryBound(to: Float.self)
        let sampleStride = array.strides[1].intValue
        let featureStride = array.strides[2].intValue
        for sample in points.indices {
            for feature in 0..<4 {
                data[sample * sampleStride + feature * featureStride] = points[sample][feature]
            }
        }
        return array
    }

    private static func globalArray(_ globals: [Float]) -> MLMultiArray? {
        guard globals.count == 2,
              let array = try? MLMultiArray(shape: [1, 2], dataType: .float32) else { return nil }
        let data = array.dataPointer.assumingMemoryBound(to: Float.self)
        let stride = array.strides[1].intValue
        for index in 0..<2 { data[index * stride] = globals[index] }
        return array
    }

    private static func strokeGlobals(features: GlyphSequence.Features, strokes: [Stroke]) -> [Float]? {
        var count = 0
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for stroke in strokes where !stroke.points.isEmpty {
            if count == GlyphSequence.maximumStrokeCount { break }
            count += 1
            for point in stroke.points {
                guard point.x.isFinite, point.y.isFinite else { return nil }
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
        }
        guard count == features.sampleCounts.count, count > 0 else { return nil }
        let width = max(maxX - minX, 1e-6)
        let height = max(maxY - minY, 1e-6)
        let logRatio = min(3, max(-3, log(width / height)))
        return [Float(Double(min(count, 6)) / 6), Float(logRatio / 3)]
    }

    private static func legacyLabelScores(_ probabilities: [String: Double], runtime: Runtime,
                                          bounds: CGRect, context: SymbolResolver.Context) -> [String: Double] {
        var scores: [String: Double] = [:]
        for group in runtime.groups {
            guard let probability = probabilities[group], probability > 0,
                  var members = runtime.legacyGroupMembers[group] else { continue }
            if group == "ambig_x_times" { members = members.filter { $0 == "x" } }
            var mathLabels: [String] = []
            for member in members {
                let label: String
                switch member {
                case "-": label = "−"
                case "'": label = "′"
                default: label = member
                }
                if runtime.classByLabel[label] != nil, !mathLabels.contains(label) {
                    mathLabels.append(label)
                }
            }
            guard !mathLabels.isEmpty else { continue }

            let weighted = mathLabels.map { label -> (String, Double) in
                guard let classID = runtime.classByLabel[label] else { return (label, 0) }
                let weight = SymbolResolver.memberWeights(class: classID, bounds: bounds, context: context)[label] ?? 0
                return (label, weight)
            }
            let total = weighted.reduce(0.0) { $0 + $1.1 }
            guard total > 0 else { continue }
            for (label, weight) in weighted {
                scores[label, default: 0] += probability * weight / total
            }
        }
        return scores
    }

    private static func softmax(_ logits: [Double], temperature: Double) -> [Double]? {
        guard !logits.isEmpty, logits.allSatisfy(\.isFinite), temperature.isFinite, temperature > 0 else {
            return nil
        }
        let scaled = logits.map { $0 / temperature }
        guard let maximum = scaled.max() else { return nil }
        let exponentials = scaled.map { exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        return exponentials.map { $0 / total }
    }

    private static func topFive(_ scores: [String: Double],
                                classes: [MathVocabulary.GlyphClass]) -> [String: Double] {
        let order = classes.flatMap(\.labels)
        let orderByLabel = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        // Keep junk in the lattice so it competes with recognizable labels.
        let ranked = scores.filter { $0.value.isFinite && $0.value > 0 }.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return (orderByLabel[lhs.key] ?? .max) < (orderByLabel[rhs.key] ?? .max)
            }
            return lhs.value > rhs.value
        }.prefix(5)
        let total = ranked.reduce(0.0) { $0 + $1.value }
        guard total.isFinite, total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: ranked.map { ($0.key, $0.value / total) })
    }

    private static func validProbabilities(_ values: [String: Double], keys: [String]) -> Bool {
        Set(values.keys) == Set(keys)
            && values.values.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && abs(values.values.reduce(0, +) - 1) <= 0.01
    }

    private static func classByLabel(_ classes: [MathVocabulary.GlyphClass]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: classes.flatMap { glyphClass in
            glyphClass.labels.map { ($0, glyphClass.id) }
        })
    }

    private static func loadLegacyGroupMembers(bundle: Bundle) -> [String: [String]]? {
        guard let url = bundle.url(forResource: "vocab", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return legacyGroupMembers(data)
    }

    private static func legacyGroupMembers(_ data: Data) -> [String: [String]]? {
        guard let vocab = try? JSONDecoder().decode(LegacyVocabulary.self, from: data) else { return nil }
        var members: [String: [String]] = [:]
        for entry in vocab.classes { members[entry.group, default: []].append(entry.label) }
        return members
    }

    private static func pixelBuffer(_ pixels: [UInt8]) -> CVPixelBuffer? {
        guard pixels.count == 32 * 32 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_OneComponent8,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<32 {
            for column in 0..<32 {
                destination[row * rowBytes + column] = pixels[row * 32 + column]
            }
        }
        return buffer
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bundleSHA256(at url: URL) -> String? {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: url.path), !paths.isEmpty else {
            return nil
        }
        var hash = SHA256()
        for path in paths.sorted() {
            let fileURL = url.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let data = try? Data(contentsOf: fileURL) else { continue }
            hash.update(data: Data(path.utf8))
            hash.update(data: Data(SHA256.hash(data: data)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
