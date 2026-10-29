import CoreGraphics
import Foundation

/// Word-level recognition is deliberately limited to these math function tokens.
enum MathFunctionNames {
    static let names: Set<String> = ["sin", "cos", "tan", "sec", "csc", "cot", "log", "ln", "exp",
                                     "lim", "max", "min", "arcsin", "arccos", "arctan", "sinh",
                                     "cosh", "tanh", "det", "mod", "abs"]

    /// Vertical-stroke labels that share one glyph class: a bar can be `l` (or the stem of `i`).
    static let barLabels: Set<String> = ["1", "l", "|", "I"]
    /// Labels a small mark above an `i` stem can take.
    static let dotLabels: Set<String> = [".", "·", "′", ",", "°", "o", "0"]

    static func isBarClass(_ guesses: [String: Double]) -> Bool {
        guard let top = guesses.max(by: { $0.value < $1.value })?.key, barLabels.contains(top) else { return false }
        // Judge by the whole likelihood row, not only the displayed label.
        return guesses.filter { barLabels.contains($0.key) || $0.key == "i" }.values.reduce(0, +) >= 0.5
    }

    static func letters(in guesses: [String: Double]) -> Set<Character>? {
        guard let top = guesses.max(by: { $0.value < $1.value })?.key, top != "<unk>" else { return nil }
        if isBarClass(guesses) { return ["l", "i"] }
        let letters = Set(guesses.filter { $0.value >= 0.02 && isLetter($0.key) }
            .compactMap { $0.key.lowercased().first })
        if isLetter(top) {
            guard guesses.filter({ isLetter($0.key) }).values.reduce(0, +) >= 0.5 else { return nil }
            return letters
        }
        let lean: [String: Character] = ["0": "o", "9": "g"]
        guard let letter = lean[top], letters.contains(letter) else { return nil }
        return [letter]
    }

    static func isLetter(_ label: String) -> Bool {
        label.utf8.count == 1 && label.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }

    static func candidates(for guesses: [[String: Double]]) -> Set<String> {
        let letters = guesses.compactMap(letters(in:))
        guard letters.count == guesses.count else { return [] }
        return names.filter { name in
            name.count == letters.count && zip(name, letters).allSatisfy { $1.contains($0) }
        }
    }

    static func canRecognize(_ guesses: [[String: Double]], isBlob: Bool) -> Bool {
        guard let top = guesses.first?.max(by: { $0.value < $1.value })?.key,
              guesses.allSatisfy({ letters(in: $0) != nil }) else { return false }
        if isBlob {
            let first = ["1": "l", "|": "l", "I": "l", "0": "o", "9": "g"][top] ?? top.lowercased()
            return names.contains { $0.hasPrefix(first) }
        }
        let letterCount = guesses.filter { isLetter($0.max(by: { $0.value < $1.value })?.key ?? "") }.count
        // Mixed digit/letter pairs such as x1 are not word runs. Leaned digits
        // remain eligible when their letter guesses actually spell a function.
        if letterCount > guesses.count / 2 { return names.contains { $0.count == guesses.count } }
        return !candidates(for: guesses).isEmpty
    }

    static func match(_ text: String?, guesses: [[String: Double]], isBlob: Bool = false) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if names.contains(text) { return text }
        guard !isBlob else { return nil }
        let matches = candidates(for: guesses).filter { oneEdit(text, $0) }
        return matches.count == 1 ? matches.first : nil
    }

    private static func oneEdit(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count <= b.count { j += 1 }
            if a.count >= b.count { i += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    /// Compose the existing upright clean glyphs into one renderable template.
    static func glyph(for name: String) -> (paths: [[CGPoint]], baseline: Double)? {
        guard names.contains(name) else { return nil }
        var paths: [[CGPoint]] = []
        var x: CGFloat = 0
        for letter in name {
            guard let strokes = CleanGlyphs.strokes(for: String(letter)),
                  let metrics = CleanGlyphs.metrics(for: String(letter)) else { return nil }
            paths += strokes.map { $0.map { CGPoint(x: $0.x + x, y: $0.y - metrics.baseline) } }
            x += metrics.advance
        }
        return (paths, 0)
    }
}
