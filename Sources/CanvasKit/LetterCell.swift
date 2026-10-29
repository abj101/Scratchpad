import CoreGraphics

/// Write mode's letter cell: the whole trackpad maps onto one letter-sized box
/// sitting at a text cursor on a ruled line. World coordinates, y-down.
///
/// The cell spans the top (0) to the bottom (1) of a line; a letter may be written
/// anywhere in it. Lines are `linePitch`·H apart, so they never touch.
public struct LetterCell: Equatable {
    /// Line spacing as a multiple of the cell height.
    public static let linePitch: CGFloat = 1.2
    /// Gap after a committed letter, as a multiple of the cell height.
    public static let letterGap: CGFloat = 0.12
    /// Word space, as a multiple of the cell height.
    public static let wordSpace: CGFloat = 0.45

    /// Cell height H in world points (ascender top to descender bottom). Always > 0.
    public var height: CGFloat
    /// Trackpad width / height. Always > 0.
    public var deviceAspect: CGFloat
    /// World x of the line's left margin.
    public var margin: CGFloat
    /// World y of the current line's top (ascender line).
    public var top: CGFloat
    /// World x of the cell's left edge: where the next letter starts.
    public var cursorX: CGFloat

    /// Non-positive height defaults to 32; non-positive aspect defaults to 1.6.
    public init(margin: CGFloat, top: CGFloat, height: CGFloat = 32, deviceAspect: CGFloat = 1.6) {
        self.height = height > 0 ? height : 32
        self.deviceAspect = deviceAspect > 0 ? deviceAspect : 1.6
        self.margin = margin
        self.top = top
        self.cursorX = margin
    }

    // MARK: Geometry

    public var size: CGSize { CGSize(width: height * deviceAspect, height: height) }
    public var rect: CGRect { CGRect(origin: CGPoint(x: cursorX, y: top), size: size) }


    // MARK: Mutations

    /// Horizontal shift that puts `letter`'s left edge at the cursor; moves the
    /// cursor past the shifted letter plus `letterGap`.
    public mutating func commit(letter: CGRect) -> CGFloat {
        guard !letter.isNull else { return 0 }
        let dx = cursorX - letter.minX
        cursorX = letter.maxX + dx + Self.letterGap * height
        return dx
    }

    /// Vertical shift that centers `letter` on the line, so it reads the same wherever on
    /// the trackpad it was written. Its size is kept, so capitals stay taller.
    public func verticalOffset(for letter: CGRect) -> CGFloat {
        letter.isNull ? 0 : rect.midY - letter.midY
    }

    public mutating func space() { cursorX += Self.wordSpace * height }

    /// Next line, cursor at the left margin.
    public mutating func newLine() {
        top += Self.linePitch * height
        cursorX = margin
    }

    /// New line if the cell would pass `rightLimit` (and isn't already at the margin).
    public mutating func wrap(at rightLimit: CGFloat) {
        if rect.maxX > rightLimit, cursorX > margin { newLine() }
    }

    public mutating func setDeviceAspect(_ aspect: CGFloat) {
        if aspect > 0 { deviceAspect = aspect }
    }
}
