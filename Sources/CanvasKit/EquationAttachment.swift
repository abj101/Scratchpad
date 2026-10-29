import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Cached layout measurements for an equation's PDF preview, in text points.
public struct EquationPreviewMetrics: Codable, Equatable {
    public let width: Double
    public let height: Double
    /// Baseline measured from the top of the preview.
    public let baseline: Double

    private static let maximumDimension = 16_384.0

    public init(width: Double, height: Double, baseline: Double) {
        self.width = Self.dimension(width)
        self.height = Self.dimension(height)
        self.baseline = baseline.isFinite ? min(max(baseline, 0), self.height) : self.height
    }

    private static func dimension(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 1), maximumDimension) : 1
    }

    private enum CodingKeys: String, CodingKey { case width, height, baseline }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try c.decode(Double.self, forKey: .width),
                  height: try c.decode(Double.self, forKey: .height),
                  baseline: try c.decode(Double.self, forKey: .baseline))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(baseline, forKey: .baseline)
    }
}

/// Editable math stored as a single inline attachment. LaTeX is authoritative;
/// the PDF and its metrics are disposable rendered layout data.
public final class EquationAttachment: NSTextAttachment {
    private static let contentType = "com.scratchpad.equation"

    public let id: UUID
    public let latex: String
    public let fontSize: Double
    public let previewPDF: Data?
    public let previewMetrics: EquationPreviewMetrics?

    public init(id: UUID = UUID(), latex: String, fontSize: Double,
                previewPDF: Data? = nil, previewMetrics: EquationPreviewMetrics? = nil) {
        self.id = id
        self.latex = latex
        self.fontSize = Self.canonicalFontSize(fontSize)
        self.previewPDF = previewPDF
        self.previewMetrics = previewMetrics
        super.init(data: Self.encodedContent(id: id, latex: latex, fontSize: self.fontSize,
                                             previewPDF: previewPDF, previewMetrics: previewMetrics),
                   ofType: Self.contentType)
        let preview = previewPDF.flatMap(Self.previewImage)
        image = preview
        if image == nil { image = Self.sourceImage(latex, fontSize: self.fontSize) }
        bounds = Self.bounds(for: preview == nil ? nil : previewMetrics, latex: latex, fontSize: self.fontSize)
    }

    public override convenience init(data contentData: Data?, ofType uti: String?) {
        if let contentData,
           let payload = try? JSONDecoder().decode(Payload.self, from: contentData) {
            self.init(id: payload.id, latex: payload.latex, fontSize: payload.fontSize,
                      previewPDF: payload.previewPDF, previewMetrics: payload.previewMetrics)
        } else {
            self.init(id: UUID(), latex: "", fontSize: 16,
                      previewPDF: uti == UTType.pdf.identifier ? contentData : nil)
        }
    }

    public required init?(coder: NSCoder) {
        guard let idString = coder.decodeObject(of: NSString.self, forKey: "equation.id") as String?,
              let id = UUID(uuidString: idString),
              let latex = coder.decodeObject(of: NSString.self, forKey: "equation.latex") as String? else { return nil }
        self.id = id
        self.latex = latex
        let size = coder.decodeDouble(forKey: "equation.fontSize")
        self.fontSize = Self.canonicalFontSize(size)
        self.previewPDF = coder.decodeObject(of: NSData.self, forKey: "equation.preview") as Data?
        if let w = coder.decodeObject(of: NSNumber.self, forKey: "equation.width"),
           let h = coder.decodeObject(of: NSNumber.self, forKey: "equation.height"),
           let b = coder.decodeObject(of: NSNumber.self, forKey: "equation.baseline") {
            self.previewMetrics = EquationPreviewMetrics(width: w.doubleValue, height: h.doubleValue,
                                                         baseline: b.doubleValue)
        } else {
            self.previewMetrics = nil
        }
        super.init(data: Self.encodedContent(id: id, latex: latex, fontSize: fontSize,
                                             previewPDF: previewPDF, previewMetrics: previewMetrics),
                   ofType: Self.contentType)
        let preview = previewPDF.flatMap(Self.previewImage)
        image = preview
        if image == nil { image = Self.sourceImage(latex, fontSize: fontSize) }
        bounds = Self.bounds(for: preview == nil ? nil : previewMetrics, latex: latex, fontSize: fontSize)
    }

    public override class var supportsSecureCoding: Bool { true }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(id.uuidString as NSString, forKey: "equation.id")
        coder.encode(latex as NSString, forKey: "equation.latex")
        coder.encode(fontSize, forKey: "equation.fontSize")
        if let previewPDF { coder.encode(previewPDF as NSData, forKey: "equation.preview") }
        if let previewMetrics {
            coder.encode(NSNumber(value: previewMetrics.width), forKey: "equation.width")
            coder.encode(NSNumber(value: previewMetrics.height), forKey: "equation.height")
            coder.encode(NSNumber(value: previewMetrics.baseline), forKey: "equation.baseline")
        }
    }

    public override func attachmentBounds(for textContainer: NSTextContainer?,
                                         proposedLineFragment lineFrag: CGRect,
                                         glyphPosition position: CGPoint,
                                         characterIndex charIndex: Int) -> CGRect {
        var fit: CGFloat = 1
        let containerWidth = textContainer?.size.width ?? 0
        if containerWidth.isFinite, containerWidth > 0, bounds.width > containerWidth {
            fit = containerWidth / bounds.width
        }
        // The line's left edge stays where the equation starts: when it reaches the
        // page edge the preview shrinks into the space left of it instead of wrapping
        // to the next line, which would move the whole line sideways.
        if lineFrag.width.isFinite, lineFrag.width > 0 {
            let remaining = lineFrag.maxX - position.x
            if remaining.isFinite, remaining > 0, bounds.width * fit > remaining {
                fit = remaining / bounds.width
            }
        }
        guard fit < 1 else { return bounds }
        return CGRect(x: 0, y: bounds.minY * fit,
                      width: bounds.width * fit, height: bounds.height * fit)
    }

    /// A fresh ID keeps duplicated equations independently editable.
    public func duplicate() -> EquationAttachment {
        EquationAttachment(latex: latex, fontSize: fontSize, previewPDF: previewPDF,
                           previewMetrics: previewMetrics)
    }

    private static func bounds(for metrics: EquationPreviewMetrics?, latex: String, fontSize: Double) -> CGRect {
        if let metrics {
            return CGRect(x: 0, y: metrics.baseline - metrics.height,
                          width: metrics.width, height: metrics.height)
        }
        let font = NSFont.systemFont(ofSize: fontSize)
        let size = (latex as NSString).size(withAttributes: [.font: font])
        let height = max(size.height, font.ascender - font.descender)
        return CGRect(x: 0, y: font.descender, width: max(size.width, fontSize), height: height)
    }

    private static func canonicalFontSize(_ size: Double) -> Double {
        size.isFinite && size > 0 ? min(size, 512) : 16
    }

    private struct Payload: Codable {
        var id: UUID
        var latex: String
        var fontSize: Double
        var previewPDF: Data?
        var previewMetrics: EquationPreviewMetrics?
    }

    private static func encodedContent(id: UUID, latex: String, fontSize: Double,
                                       previewPDF: Data?, previewMetrics: EquationPreviewMetrics?) -> Data {
        (try? JSONEncoder().encode(Payload(id: id, latex: latex, fontSize: fontSize,
                                           previewPDF: previewPDF, previewMetrics: previewMetrics))) ?? Data()
    }

    private static func previewImage(_ data: Data) -> NSImage? {
        guard let provider = CGDataProvider(data: data as CFData), CGPDFDocument(provider) != nil else { return nil }
        return NSImage(data: data)
    }

    private static func sourceImage(_ latex: String, fontSize: Double) -> NSImage {
        let font = NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let size = (latex as NSString).size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: max(size.width, fontSize), height: max(size.height, fontSize)))
        image.lockFocus()
        (latex as NSString).draw(at: .zero, withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}

public extension NSAttributedString {
    /// Plain text representation used by system clipboard clients.
    var equationPlainText: String {
        let result = NSMutableString(string: string)
        var replacements: [(NSRange, String)] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, _ in
            if let equation = value as? EquationAttachment { replacements.append((range, equation.latex)) }
        }
        for (range, latex) in replacements.reversed() { result.replaceCharacters(in: range, with: latex) }
        return result as String
    }

    /// Rich copy with new equation identities while preserving styles and previews.
    func duplicatingEquations() -> NSAttributedString {
        var equations: [(NSRange, EquationAttachment)] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, _ in
            if let equation = value as? EquationAttachment { equations.append((range, equation)) }
        }
        guard !equations.isEmpty else { return self }
        let result = NSMutableAttributedString(attributedString: self)
        for (range, equation) in equations {
            result.addAttribute(.attachment, value: equation.duplicate(), range: range)
        }
        return result
    }
}
