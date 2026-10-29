import Foundation

public extension RGBA {
    /// Choose the foreground with greater contrast against this opaque color.
    var prefersLightForeground: Bool {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance < 0.179
    }

    /// Hex (#RGB, #RGBA, #RRGGBB, #RRGGBBAA) or CSS rgb/rgba, including percentages.
    init?(colorCode: String) {
        let text = colorCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hex = text
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        if [3, 4, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let value = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let rgb = hasAlpha ? value >> 8 : value
            self.init(r: Double((rgb >> 16) & 255) / 255,
                      g: Double((rgb >> 8) & 255) / 255,
                      b: Double(rgb & 255) / 255,
                      a: hasAlpha ? Double(value & 255) / 255 : 1)
            return
        }
        let rgba = text.hasPrefix("rgba(")
        guard (rgba || text.hasPrefix("rgb(")), text.hasSuffix(")") else { return nil }
        let body = String(text.dropFirst(rgba ? 5 : 4).dropLast())
        let parts: [String]
        if body.contains(",") {
            parts = body.components(separatedBy: ",")
        } else {
            let sections = body.components(separatedBy: "/")
            guard sections.count <= 2 else { return nil }
            parts = sections[0].split(whereSeparator: { $0.isWhitespace }).map(String.init)
                + (sections.count == 2 ? [sections[1]] : [])
        }
        guard parts.count == 3 || parts.count == 4, !rgba || parts.count == 4 else { return nil }
        var values: [Double] = []
        for (index, part) in parts.enumerated() {
            let component = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let percent = component.hasSuffix("%")
            guard let value = Double(percent ? String(component.dropLast()) : component), value.isFinite else { return nil }
            let maximum: Double = percent ? 100 : (index == 3 ? 1 : 255)
            guard (0...maximum).contains(value) else { return nil }
            values.append(value / maximum)
        }
        self.init(r: values[0], g: values[1], b: values[2], a: values.count == 4 ? values[3] : 1)
    }

    var hexCode: String {
        let channels = [r, g, b] + (a < 1 ? [a] : [])
        return "#" + channels.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
    }
}
