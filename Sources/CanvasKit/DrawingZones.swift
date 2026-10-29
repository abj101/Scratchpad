import AppKit

// MARK: - Model

/// A rectangle of ink in a document note. Body text wraps around it (beside it
/// and below it), so ink never sits on top of text. The zone follows the
/// paragraph it is anchored to: `rect.minY` is always the reference y of
/// `paragraphIndex` plus `dy`.
public struct DrawingZone: Codable, Hashable, Identifiable {
    public var id: UUID
    public var strokeIDs: Set<UUID>
    /// World coordinates: the union of the strokes' bounds, outset by `DrawingZones.padding`.
    public var rect: CGRect
    /// Character index of the start of the anchor paragraph in the body.
    public var paragraphIndex: Int
    /// `rect.minY` minus the reference y of `paragraphIndex`.
    public var dy: Double

    public init(id: UUID = UUID(), strokeIDs: Set<UUID>, rect: CGRect, paragraphIndex: Int = 0, dy: Double = 0) {
        self.id = id
        self.strokeIDs = strokeIDs
        self.rect = rect
        self.paragraphIndex = paragraphIndex
        self.dy = dy
    }
}

/// The small part of text layout that zone placement needs. World coordinates.
protocol ZoneLayoutQuerying {
    var characterCount: Int { get }
    /// World y of the top of the first line.
    var textTop: CGFloat { get }
    /// The text column in world coordinates.
    var columnRect: CGRect { get }
    /// 0, and the index right after every "\n" (so `characterCount` when the text ends with one).
    var paragraphStarts: [Int] { get }
    /// World maxY of the line fragment that contains the character at `index`.
    func lineBottom(ofCharacterAt index: Int) -> CGFloat?
}

// MARK: - Pure logic

enum DrawingZones {
    /// Outset between a zone's strokes and its rect.
    static let padding: CGFloat = 8
    /// A stroke within this distance of a zone joins it.
    static let joinDistance: CGFloat = 16
    /// Text narrower than this beside a zone is not worth laying out.
    static let minimumSideWidth: CGFloat = 96
    /// Reflow ignores sub-point drift.
    static let moveTolerance: CGFloat = 0.5

    // MARK: Rects

    static func rect(for strokes: [Stroke]) -> CGRect? {
        let union = strokes.reduce(CGRect.null) { $0.union($1.bounds) }
        return union.isNull ? nil : union.insetBy(dx: -padding, dy: -padding)
    }

    // MARK: Anchors

    /// Reference y for the paragraph starting at `paragraph`: the body text top
    /// for the first paragraph, otherwise the bottom of the line that ends the
    /// paragraph before it. It only depends on lines above the paragraph.
    static func reference(of paragraph: Int, in layout: ZoneLayoutQuerying) -> CGFloat {
        guard paragraph > 0 else { return layout.textTop }
        return layout.lineBottom(ofCharacterAt: min(paragraph, layout.characterCount) - 1) ?? layout.textTop
    }

    /// The last paragraph start whose reference is at or above `minY`, and the
    /// zone's offset from that reference.
    static func chooseAnchor(forMinY minY: CGFloat, in layout: ZoneLayoutQuerying) -> (paragraphIndex: Int, dy: Double) {
        let starts = layout.paragraphStarts
        var low = 0
        var high = starts.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if reference(of: starts[mid], in: layout) <= minY {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let paragraph = starts.isEmpty ? 0 : starts[best]
        return (paragraph, Double(minY - reference(of: paragraph, in: layout)))
    }

    /// Moves an index through a text edit (`editedRange` in pre-edit
    /// coordinates), then snaps it to the start of the paragraph containing it.
    /// `paragraphStarts` describes the text after the edit.
    static func shiftedIndex(_ index: Int, editedRange: NSRange, changeInLength: Int,
                             paragraphStarts: [Int], characterCount: Int) -> Int {
        var shifted = index
        let oldEnd = NSMaxRange(editedRange)
        if editedRange.length == 0 {
            if index >= editedRange.location { shifted += changeInLength }
        } else if index >= oldEnd {
            shifted += changeInLength
        } else if index >= editedRange.location {
            shifted = editedRange.location
        }
        shifted = min(max(shifted, 0), characterCount)
        return snapped(shifted, to: paragraphStarts)
    }

    static func snapped(_ index: Int, to paragraphStarts: [Int]) -> Int {
        var low = 0
        var high = paragraphStarts.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if paragraphStarts[mid] <= index {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return paragraphStarts.isEmpty ? 0 : paragraphStarts[best]
    }

    // MARK: Reflow

    /// One reflow pass: the translation each off-target zone needs, vertically
    /// to `reference + dy` and horizontally back into the column.
    static func reflowMoves(_ zones: [DrawingZone], in layout: ZoneLayoutQuerying) -> [UUID: CGVector] {
        var moves: [UUID: CGVector] = [:]
        let column = layout.columnRect
        for zone in zones {
            let targetY = reference(of: zone.paragraphIndex, in: layout) + CGFloat(zone.dy)
            var dy = targetY - zone.rect.minY
            if abs(dy) <= moveTolerance { dy = 0 }
            var dx: CGFloat = 0
            let overflow = zone.rect.maxX - column.maxX
            if overflow > moveTolerance {
                dx = -min(overflow, max(0, zone.rect.minX - column.minX))
            }
            if dx != 0 || dy != 0 { moves[zone.id] = CGVector(dx: dx, dy: dy) }
        }
        return moves
    }

    /// World-space rectangles the text must avoid. A side with less than
    /// `minimumSideWidth` of text beside the zone is closed off, so text
    /// never forms a sliver there; a zone with both sides closed spans the
    /// whole column and text goes below it.
    static func exclusionRects(_ zones: [DrawingZone], column: CGRect) -> [CGRect] {
        zones.map { zone in
            let rect = zone.rect
            let leftClosed = rect.minX - column.minX < minimumSideWidth
            let rightClosed = column.maxX - rect.maxX < minimumSideWidth
            let minX = leftClosed ? min(column.minX, rect.minX) : rect.minX
            let maxX = rightClosed ? max(column.maxX, rect.maxX) : rect.maxX
            return CGRect(x: minX, y: rect.minY, width: maxX - minX, height: rect.height)
        }
    }

    // MARK: Creating, joining, removing

    struct Update {
        var zones: [DrawingZone]
        /// Zones whose rect changed and so need a new anchor.
        var touched: Set<UUID>
    }

    /// Adds strokes to nearby zones (merging every zone one stroke bridges),
    /// or starts a new zone for them.
    static func adding(_ added: [Stroke], to zones: [DrawingZone], strokesByID: [UUID: Stroke]) -> Update {
        var result = zones
        var touched = Set<UUID>()
        for stroke in added {
            let reach = stroke.bounds.insetBy(dx: -joinDistance, dy: -joinDistance)
            let matches = result.indices.filter { result[$0].rect.intersects(reach) }
            var merged: DrawingZone
            if let first = matches.first {
                merged = result[first]
                for index in matches.dropFirst() { merged.strokeIDs.formUnion(result[index].strokeIDs) }
                let ids = Set(matches.map { result[$0].id })
                touched.subtract(ids)
                result.removeAll { ids.contains($0.id) }
            } else {
                merged = DrawingZone(strokeIDs: [], rect: .zero)
            }
            merged.strokeIDs.insert(stroke.id)
            merged.rect = rect(for: merged.strokeIDs.compactMap { strokesByID[$0] }) ?? merged.rect
            result.append(merged)
            touched.insert(merged.id)
        }
        return Update(zones: result, touched: touched)
    }

    /// Drops removed strokes, shrinks rects to what remains and deletes empty zones.
    static func removing(_ ids: Set<UUID>, from zones: [DrawingZone], strokesByID: [UUID: Stroke]) -> Update {
        var result: [DrawingZone] = []
        var touched = Set<UUID>()
        for var zone in zones {
            guard !zone.strokeIDs.isDisjoint(with: ids) else { result.append(zone); continue }
            zone.strokeIDs.subtract(ids)
            guard let rect = rect(for: zone.strokeIDs.compactMap({ strokesByID[$0] })) else { continue }
            zone.rect = rect
            result.append(zone)
            touched.insert(zone.id)
        }
        return Update(zones: result, touched: touched)
    }

    /// Recomputes the rects of zones holding any of `ids` (strokes moved or resized).
    static func refreshing(_ ids: Set<UUID>, in zones: [DrawingZone], strokesByID: [UUID: Stroke]) -> Update {
        var result = zones
        var touched = Set<UUID>()
        for index in result.indices where !result[index].strokeIDs.isDisjoint(with: ids) {
            result[index].strokeIDs = result[index].strokeIDs.filter { strokesByID[$0] != nil }
            guard let rect = rect(for: result[index].strokeIDs.compactMap({ strokesByID[$0] })) else { continue }
            result[index].rect = rect
            touched.insert(result[index].id)
        }
        result.removeAll { $0.strokeIDs.isEmpty }
        return Update(zones: result, touched: touched)
    }

    /// Recomputes every rect from the strokes' current positions, dropping
    /// strokes that no longer exist and zones left empty.
    static func resynchronized(_ zones: [DrawingZone], strokesByID: [UUID: Stroke]) -> [DrawingZone] {
        zones.compactMap { zone in
            var copy = zone
            copy.strokeIDs = zone.strokeIDs.filter { strokesByID[$0] != nil }
            guard let rect = rect(for: copy.strokeIDs.compactMap { strokesByID[$0] }) else { return nil }
            copy.rect = rect
            return copy
        }
    }

    /// Groups strokes into zones by the join-distance rule (used to migrate
    /// notes that predate zones). Anchors are not assigned.
    static func grouping(_ strokes: [Stroke]) -> [DrawingZone] {
        let order = strokes.indices.sorted { strokes[$0].bounds.minX < strokes[$1].bounds.minX }
        var parent = Array(strokes.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for (position, i) in order.enumerated() {
            let reach = strokes[i].bounds.insetBy(dx: -joinDistance, dy: -joinDistance)
            for j in order[(position + 1)...] {
                if strokes[j].bounds.minX > reach.maxX { break }
                if strokes[j].bounds.intersects(reach) { parent[find(j)] = find(i) }
            }
        }
        var groups: [Int: [Stroke]] = [:]
        for i in strokes.indices { groups[find(i), default: []].append(strokes[i]) }
        return groups.values.compactMap { members in
            guard let rect = rect(for: members) else { return nil }
            return DrawingZone(strokeIDs: Set(members.map(\.id)), rect: rect)
        }.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }
}

// MARK: - Legacy sketch spacers

/// Notes saved before drawing zones reserved space for sketches with an
/// invisible attachment paragraph. Only migration still reads them.
enum SketchSpacer {
    static let marker = NSAttributedString.Key("com.scratchpad.sketch-spacer")

    static func ranges(in storage: NSAttributedString) -> [NSRange] {
        guard storage.length > 0 else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(marker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let value = value as? NSNumber, value.doubleValue > 0 { ranges.append(range) }
        }
        return ranges
    }

    /// Removes each spacer attachment and the "\n" that follows it.
    static func strip(from storage: NSMutableAttributedString) {
        for range in ranges(in: storage).reversed() {
            var length = range.length
            if NSMaxRange(range) < storage.length,
               (storage.string as NSString).character(at: NSMaxRange(range)) == 10 { length += 1 }
            storage.deleteCharacters(in: NSRange(location: range.location, length: length))
        }
    }
}
