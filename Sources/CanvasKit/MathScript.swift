import CoreGraphics

/// Classifies math symbols as body text, superscripts or subscripts by the writing-cell zone they were written in.
enum MathScript {
    enum Role: Equatable {
        case body
        case superscript
        case `subscript`
        /// Middle-zone ink: stay in the current lane (body or whichever script is open).
        case inherit
    }

    /// Writing-cell zones as fractions of the cell height: upper (superscript) above `upperEdge`,
    /// lower (subscript) below `lowerEdge`, body between. The panel draws its dotted lines here too.
    static let upperEdge: CGFloat = 0.3
    static let lowerEdge: CGFloat = 0.7

    /// The zone holding most of the ink's points (ties go to the middle). Marks that are always body
    /// (`.`, `·`, low or raised kinds) count as middle ink, so they stay in the current lane.
    static func zoneRole(ys: [CGFloat], cell: LetterCell, label: String, kind: String) -> Role {
        var up = 0, down = 0, mid = 0
        let body = ["raised", "low"].contains(kind) || ["°", "·", "′", ".", ","].contains(label)
        for y in ys {
            let f = (y - cell.top) / cell.height
            if body { mid += 1 } else if f < upperEdge { up += 1 } else if f > lowerEdge { down += 1 } else { mid += 1 }
        }
        if up > mid, up >= down { return .superscript }
        if down > mid { return .subscript }
        return .inherit
    }
}
