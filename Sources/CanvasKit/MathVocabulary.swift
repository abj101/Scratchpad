import Foundation

/// The v2 math labels and the classifier's ordered output classes.
public struct MathVocabulary: Decodable {
    public struct GlyphClass: Decodable {
        public let id: String
        public let labels: [String]
    }

    public struct Label: Decodable {
        public let label: String
        public let classID: String
        public let kind: String
        public let hershey: String
        public let latex: [String]

        enum CodingKeys: String, CodingKey {
            case label, kind, hershey, latex
            case classID = "class"
        }
    }

    public let version: Int
    public let classes: [GlyphClass]
    public let labels: [Label]

    public static func load(from bundle: Bundle) -> MathVocabulary? {
        guard let url = bundle.url(forResource: "math-vocab", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public static let bundled = load(from: .module)
}
