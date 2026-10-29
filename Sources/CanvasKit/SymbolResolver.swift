import CoreGraphics
import Foundation

/// Resolves a classifier's merged vocabulary group using the original ink geometry.
public enum SymbolResolver {
    public enum Mode: Equatable {
        case math
        case text
    }

    /// Line context uses world coordinates; baseline is the typical bottom of body glyphs.
    public struct Context {
        public let medianHeight: CGFloat?
        public let baseline: CGFloat?
        public let mode: Mode
        public let previousSymbol: String?

        public init(medianHeight: CGFloat? = nil, baseline: CGFloat? = nil,
                    mode: Mode, previousSymbol: String? = nil) {
            self.medianHeight = medianHeight
            self.baseline = baseline
            self.mode = mode
            self.previousSymbol = previousSymbol
        }
    }

    private struct Entry: Decodable {
        let label: String
        let group: String
        let kind: String
    }

    private struct Vocabulary: Decodable {
        let classes: [Entry]
    }

    private static let entries: [Entry] = {
        guard let url = Bundle.module.url(forResource: "vocab", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data) else {
            return []
        }
        return vocabulary.classes
    }()

    private static let groups: [String: [Entry]] = Dictionary(grouping: entries, by: \.group)
    private static let kinds: [String: String] = Dictionary(uniqueKeysWithValues: entries.map { ($0.label, $0.kind) })

    /// Returns the selected member, or nil when the evidence is insufficient or it is disabled.
    /// Disabled labels are checked after resolution so another group member is never substituted.
    public static func resolve(group: String, originalBounds: CGRect, context: Context,
                               disabledLabels: Set<String> = []) -> String? {
        guard let members = groups[group], !members.isEmpty else { return nil }
        let bounds = originalBounds.standardized
        guard !bounds.isNull, !bounds.isInfinite,
              [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
              bounds.width >= 0, bounds.height >= 0,
              bounds.width > 0 || bounds.height > 0 else { return nil }

        let label: String?
        if members.count == 1 {
            label = members[0].label
        } else {
            switch group {
            case "ambig_circle": label = resolveCircle(bounds, context: context)
            case "ambig_one_bar": label = resolveOneBar(bounds, context: context)
            case "ambig_x_times": label = resolveXTimes(bounds, context: context)
            case "ambig_dash": label = resolveDash(bounds, context: context)
            case "ambig_comma_quote": label = resolveCommaQuote(bounds, context: context)
            case "ambig_epsilon_in": label = resolveEpsilonIn(bounds, context: context)
            case "ambig_pi_product": label = resolveTallOperator(bounds, context: context, letter: "Π", op: "∏")
            case "ambig_sigma_sum": label = resolveTallOperator(bounds, context: context, letter: "Σ", op: "∑")
            case let name where name.hasPrefix("ambig_case_"):
                label = resolveCase(bounds, group: members, context: context)
            default: label = nil
            }
        }

        guard let label, members.contains(where: { $0.label == label }),
              !disabledLabels.contains(label) else { return nil }
        return label
    }

    /// Distributes a classifier class score across its math labels using line geometry.
    public static func memberWeights(`class` classID: String, bounds originalBounds: CGRect,
                                     context: Context) -> [String: Double] {
        if classID == "junk" { return ["<unk>": 1] }
        if classID == "glyph_u006C" { return ["l": 1] }
        if classID == "glyph_u0071" { return ["q": 1] }
        if classID == "glyph_u007B" { return ["{": 1] }
        if classID == "glyph_u007D" { return ["}": 1] }
        guard let members = MathVocabulary.bundled?.classes.first(where: { $0.id == classID })?.labels,
              !members.isEmpty else { return [:] }
        if members.count == 1 { return [members[0]: 1] }
        let math = context.mode == .math
        if classID == "bar" {
            // Cursive l has its own F5 class; a straight bar is 1 or |.
            if math { return ["1": 0.95, "|": 0.05] }
            return ["1": 0.5, "|": 0.5]
        }

        let neutral: [String: Double]
        switch classID {
        case "dot": neutral = [".": 0.5, "·": 0.5]
        case "tick": neutral = [",": 0.5, "′": 0.5]
        case "ring":
            neutral = math ? ["0": 0.855, "o": 0.095, "°": 0.05] : ["0": 0.45, "o": 0.45, "°": 0.1]
        default: return Dictionary(uniqueKeysWithValues: members.map { ($0, 1.0 / Double(members.count)) })
        }

        guard let h = lineHeight(context),
              let baseline = context.baseline, baseline.isFinite else { return neutral }

        let bounds = originalBounds.standardized
        guard !bounds.isNull, !bounds.isInfinite,
              [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite) else { return neutral }
        let raised = Double((baseline - bounds.midY) / h)
        let size = Double(max(bounds.width, bounds.height) / h)

        switch classID {
        case "dot":
            let raisedDot = sigmoid((raised - 0.30))
            return [".": 1 - raisedDot, "·": raisedDot]
        case "tick":
            let prime = sigmoid(raised - 0.45)
            return [",": 1 - prime, "′": prime]
        case "ring":
            let degree = sigmoid(raised - 0.55) * sigmoid(0.45 - size)
            if math { return ["0": 0.9 * (1 - degree), "o": 0.1 * (1 - degree), "°": degree] }
            return ["0": (1 - degree) / 2, "o": (1 - degree) / 2, "°": degree]
        default:
            return [:]
        }
    }

    /// Vocabulary placement kind (`digit`, `lower`, `upper`, `operator`, `punct`, `raised`, `low`).
    public static func kind(for label: String) -> String? { kinds[label] }

    /// Returns a group's kind only when every member shares it; mixed or unknown groups return nil.
    public static func kind(forGroup group: String) -> String? {
        guard let members = groups[group], let kind = members.first?.kind,
              members.allSatisfy({ $0.kind == kind }) else { return nil }
        return kind
    }

    private static func resolveCase(_ bounds: CGRect, group: [Entry], context: Context) -> String? {
        guard let ratio = heightRatio(bounds, context: context) else { return nil }
        if ratio <= 0.72 { return group.first(where: { $0.kind == "lower" })?.label }
        if ratio >= 0.86 { return group.first(where: { $0.kind == "upper" })?.label }
        return nil
    }

    private static func resolveCircle(_ bounds: CGRect, context: Context) -> String? {
        guard let ratio = heightRatio(bounds, context: context),
              let height = lineHeight(context), let baseline = context.baseline,
              baseline.isFinite else { return nil }
        let raised = (baseline - bounds.midY) / height
        let diameter = max(bounds.width, bounds.height) / height

        // Position separates punctuation dots from raised degree marks, including tiny loops.
        if raised >= 0.72, ratio <= 0.42 { return "°" }
        if diameter <= 0.18 {
            if raised <= 0.28 { return "." }
            if context.mode == .math, raised >= 0.32, raised <= 0.68 { return "·" }
            return nil
        }
        if context.mode == .math, ratio >= 0.22, ratio <= 0.48, raised >= 0.32, raised <= 0.55 {
            return "∘"
        }
        if ratio >= 0.52, ratio <= 0.74 { return "o" }
        guard ratio >= 0.82 else { return nil }
        if context.mode == .text { return "O" }
        return "0"
    }

    private static func resolveOneBar(_ bounds: CGRect, context: Context) -> String? {
        guard let ratio = heightRatio(bounds, context: context) else { return nil }
        if ratio <= 0.72 { return "l" }
        guard ratio >= 0.86 else { return nil }
        if let baseline = context.baseline, baseline.isFinite,
           let height = lineHeight(context), (bounds.maxY - baseline) / height >= 0.08 {
            return "|"
        }
        if context.mode == .text { return "I" }
        return "1"
    }

    private static func resolveXTimes(_ bounds: CGRect, context: Context) -> String? {
        guard let ratio = heightRatio(bounds, context: context) else { return nil }
        if context.mode == .math,
           let height = lineHeight(context), let baseline = context.baseline, baseline.isFinite {
            let raised = (baseline - bounds.midY) / height
            if ratio >= 0.32, ratio <= 0.52, raised >= 0.40, raised <= 0.60 { return "×" }
        }
        if ratio <= 0.72 { return "x" }
        guard ratio >= 0.86 else { return nil }
        if context.mode == .text { return "X" }
        // A full-height x and multiplication sign can look alike. Immediate commit has no
        // right-hand context to distinguish them safely after an operand.
        return previousCompletesOperand(context.previousSymbol) ? nil : "x"
    }

    private static func resolveDash(_ bounds: CGRect, context: Context) -> String? {
        guard let height = lineHeight(context), let baseline = context.baseline,
              baseline.isFinite else { return nil }
        let raised = (baseline - bounds.midY) / height
        if raised <= 0.12 { return "_" }
        guard raised >= 0.28, raised <= 0.72 else { return nil }
        if context.mode == .math { return "−" }
        return bounds.width / height >= 1.4 ? "—" : "-"
    }

    private static func resolveCommaQuote(_ bounds: CGRect, context: Context) -> String? {
        guard let height = lineHeight(context), let baseline = context.baseline,
              baseline.isFinite else { return nil }
        let gap = (baseline - bounds.maxY) / height
        if gap >= 0.08 { return "'" }
        if gap <= -0.08 { return "," }
        return nil
    }

    private static func resolveEpsilonIn(_ bounds: CGRect, context: Context) -> String? {
        guard let ratio = heightRatio(bounds, context: context) else { return nil }
        if ratio <= 0.72 { return "ε" }
        if ratio >= 0.86, context.mode == .math { return "∈" }
        return nil
    }

    private static func resolveTallOperator(_ bounds: CGRect, context: Context,
                                            letter: String, op: String) -> String? {
        guard let ratio = heightRatio(bounds, context: context),
              let baseline = context.baseline, baseline.isFinite,
              let height = lineHeight(context) else { return nil }
        if ratio <= 0.95 { return letter }
        let descender = (bounds.maxY - baseline) / height
        if context.mode == .math, ratio >= 1.15, descender >= 0.08 { return op }
        return nil
    }

    private static func lineHeight(_ context: Context) -> CGFloat? {
        guard let height = context.medianHeight, height.isFinite, height > 0 else { return nil }
        return height
    }

    private static func sigmoid(_ value: Double) -> Double {
        let scaled = value / 0.05
        if scaled >= 0 { return 1 / (1 + exp(-scaled)) }
        let exponential = exp(scaled)
        return exponential / (1 + exponential)
    }

    private static func heightRatio(_ bounds: CGRect, context: Context) -> CGFloat? {
        guard let height = lineHeight(context), bounds.height.isFinite else { return nil }
        return bounds.height / height
    }

    private static func previousCompletesOperand(_ symbol: String?) -> Bool {
        guard let symbol, symbol.count == 1, let character = symbol.first else { return false }
        if character.isLetter || character.isNumber { return true }
        return [")", "]", "}", "°", "′", "!", "∞", "∘"].contains(symbol)
    }
}
