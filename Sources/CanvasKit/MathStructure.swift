import Foundation

/// Math structures that MathLive renders with slots of their own: an operator whose
/// limits sit above and below, or a root with a radicand bar and an optional index.
///
/// This is the pure half of the feature: it maps the label the recognizer produced to
/// the structure to spawn. The LaTeX templates and the caret/slot behaviour live in the
/// bundled editor (`Resources/MathLive/editor.js`), which owns every MathLive edit.
public enum MathStructure {
    public enum Kind: String, CaseIterable {
        /// `\sum\limits_{}^{}` — limits above and below.
        case summation = "sum"
        /// `\int\limits_{}^{}` — limits above and below (an integral is adjacent by default).
        case integral = "int"
        /// `\lim_{}` — the condition renders below the operator.
        case limit = "lim"
        /// `||` — paired absolute-value bars, with the caret between them.
        case absoluteValue = "abs"
        /// `\sqrt{}` — the radicand bar, with the caret in the radicand.
        case squareRoot = "sqrt"
        /// `\sqrt[n]{}` — the index of the root the caret is currently inside.
        case rootIndex = "root"
    }

    /// Structures a recognized symbol spawns. The root index is built from a symbol the
    /// user wrote into a root, never committed on its own.
    public static func kind(forLabel label: String) -> Kind? {
        switch label {
        case "∑": return .summation
        case "∫": return .integral
        case "lim": return .limit
        case "abs": return .absoluteValue
        case "√": return .squareRoot
        default: return nil
        }
    }
}
