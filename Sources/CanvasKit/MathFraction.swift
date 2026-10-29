import CoreGraphics
import Foundation

/// Pure state and geometry for stacked fractions in a math writing line.
public enum MathFraction {
    public static let slotScale: CGFloat = 0.8
    public static let fractionDepthLimit = 2

    public enum Slot: Equatable { case parent, numerator, denominator }
    public enum Key: Equatable { case up, down, left, right, tab, delete, other }
    public enum Trigger: Equatable {
        case slashKey
        case recognized(label: String, posterior: Double)
    }

    /// A committed letter reference plus the geometry needed by the pure layout rules.
    public struct Letter: Equatable {
        public let id: UUID
        public var label: String?
        public var extent: CGRect
        public var startsAfterWordSpace: Bool
        public var isBody: Bool

        public init(id: UUID, label: String?, extent: CGRect,
                    startsAfterWordSpace: Bool = false, isBody: Bool = true) {
            self.id = id
            self.label = label
            self.extent = extent
            self.startsAfterWordSpace = startsAfterWordSpace
            self.isBody = isBody
        }
    }

    /// Line statistics are kept separately for glyph placement and symbol resolution.
    public struct LineStats: Equatable {
        public var heights: [CGFloat]
        public var bottoms: [CGFloat]

        public init(heights: [CGFloat] = [], bottoms: [CGFloat] = []) {
            self.heights = heights
            self.bottoms = bottoms
        }

        public var medianHeight: CGFloat? { Self.median(heights) }
        public var baseline: CGFloat? { Self.median(bottoms) }

        public mutating func record(_ extent: CGRect) {
            guard !extent.isNull, extent.height.isFinite, extent.maxY.isFinite, extent.height > 0 else { return }
            if heights.count >= 8 { heights.removeFirst(); if !bottoms.isEmpty { bottoms.removeFirst() } }
            heights.append(extent.height)
            bottoms.append(extent.maxY)
        }

        fileprivate func scaled(from sourceBaseline: CGFloat, to targetBaseline: CGFloat,
                                factor: CGFloat) -> LineStats {
            LineStats(heights: heights.map { $0 * factor },
                      bottoms: bottoms.map { targetBaseline + ($0 - sourceBaseline) * factor })
        }

        fileprivate static func median(_ values: [CGFloat]) -> CGFloat? {
            let sorted = values.filter(\.isFinite).sorted()
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }
    }

    public struct Row: Equatable {
        public let id: UUID
        public var items: [Item]
        public var cell: LetterCell
        public var lineStats: LineStats
        public var resolverStats: LineStats
        /// Maps the original parent-row coordinates into this row's current coordinates.
        public var transform: CGAffineTransform

        public init(items: [Item] = [], cell: LetterCell,
                    lineStats: LineStats = LineStats(), resolverStats: LineStats = LineStats(),
                    id: UUID = UUID(), transform: CGAffineTransform = .identity) {
            self.id = id
            self.items = items
            self.cell = cell
            self.lineStats = lineStats
            self.resolverStats = resolverStats
            self.transform = transform
        }

        /// With fewer than two body heights, the line baseline is the centered-cell baseline:
        /// `midY + 0.5 × (0.4H) = top + 0.7H` in the existing y-down cell convention.
        public var cellBaseline: CGFloat { cell.top + 0.7 * cell.height }

        public var metrics: (height: CGFloat, baseline: CGFloat) {
            guard lineStats.heights.count >= 2,
                  let h = lineStats.medianHeight, h.isFinite, h > 0,
                  let b = lineStats.baseline, b.isFinite else {
                return (0.4 * cell.height, cellBaseline)
            }
            return (h, b)
        }

        public var bounds: CGRect {
            items.reduce(.null) { $0.union($1.bounds) }
        }
    }

    public indirect enum Item: Equatable {
        case letter(Letter)
        case fraction(Fraction)

        public var bounds: CGRect {
            switch self {
            case .letter(let letter): letter.extent
            case .fraction(let fraction): fraction.bounds
            }
        }

        public var startsAfterWordSpace: Bool {
            switch self {
            case .letter(let letter): letter.startsAfterWordSpace
            case .fraction(let fraction): fraction.startsAfterWordSpace
            }
        }

        public var letterIDs: [UUID] {
            switch self {
            case .letter(let letter): [letter.id]
            case .fraction(let fraction): fraction.letterIDs
            }
        }
    }

    public struct Bar: Equatable {
        public let id: UUID
        public var start: CGPoint
        public var end: CGPoint
        public var transform: CGAffineTransform

        public init(id: UUID, start: CGPoint, end: CGPoint, transform: CGAffineTransform = .identity) {
            self.id = id
            self.start = start
            self.end = end
            self.transform = transform
        }

        public var bounds: CGRect {
            CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                   width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        public var maxX: CGFloat { max(start.x, end.x) }
    }

    public struct Fraction: Equatable {
        public var numerator: Row
        public var denominator: Row
        public var bar: Bar
        public var startsAfterWordSpace: Bool
        public var undoSnapshot: UndoSnapshot?

        public init(numerator: Row, denominator: Row, bar: Bar,
                    startsAfterWordSpace: Bool = false, undoSnapshot: UndoSnapshot? = nil) {
            self.numerator = numerator
            self.denominator = denominator
            self.bar = bar
            self.startsAfterWordSpace = startsAfterWordSpace
            self.undoSnapshot = undoSnapshot
        }

        public var bounds: CGRect { numerator.bounds.union(denominator.bounds).union(bar.bounds) }
        public var letterIDs: [UUID] { numerator.items.flatMap(\.letterIDs) + denominator.items.flatMap(\.letterIDs) }
    }

    public struct Operand: Equatable {
        /// Indices in the row, with the upper bound exclusive.
        public let range: Range<Int>
        public let removedParenthesisIDs: [UUID]
        public let originalBounds: CGRect
        public let contentBounds: CGRect

        public var isEmpty: Bool { range.isEmpty }
    }

    public struct Metrics: Equatable {
        public let bar: Bar
        public let numeratorBaseline: CGFloat
        public let denominatorBaseline: CGFloat
        public let numeratorOriginX: CGFloat
        public let denominatorOriginX: CGFloat
        public let numeratorWidth: CGFloat
        public let denominatorWidth: CGFloat

        public var barY: CGFloat { bar.start.y }
        public var left: CGFloat { min(bar.start.x, bar.end.x) }
    }

    public struct SlotRows: Equatable {
        public var numerator: Row
        public var denominator: Row
    }

    public struct Transform: Equatable {
        public let letterID: UUID
        public let affine: CGAffineTransform
    }

    public struct UndoSnapshot: Equatable {
        public let parentItems: [Item]
        public let slash: Letter?
        public let barID: UUID
        public let parentCell: LetterCell
        public let lineStats: LineStats
        public let resolverStats: LineStats
        public let operandRange: Range<Int>
        public let slashIndex: Int?
        public let removedParenthesisIDs: [UUID]
        /// Maps the snapshot's parent-row coordinates into the parent's current coordinates.
        public let parentTransform: CGAffineTransform
        public let cursorAfterSlash: CGFloat
    }

    public struct InsertionPlan: Equatable {
        public let fraction: Fraction
        public let parentItems: [Item]
        public let operand: Operand
        public let transforms: [Transform]
        public let barTransforms: [UUID: CGAffineTransform]
        public let nestedRows: [UUID: RowLayout]
        public let activeSlot: Slot
        public let activeCell: LetterCell
        public let removedParenthesisIDs: [UUID]
    }

    public struct Layout: Equatable {
        public let metrics: Metrics
        public let letterTranslations: [UUID: CGVector]
        public let barTranslations: [UUID: CGVector]
        public let nestedRows: [UUID: RowLayout]
        public let numeratorCell: LetterCell
        public let denominatorCell: LetterCell
        /// The updated value state corresponding to the returned translations and bar.
        public let fraction: Fraction
    }

    public struct RowLayout: Equatable {
        public let id: UUID
        public let cell: LetterCell
        public let lineStats: LineStats
        public let resolverStats: LineStats
    }

    public struct DissolvePlan: Equatable {
        public let parentItems: [Item]
        /// Apply these to current slot strokes; the map is consistent for old and new letters.
        public let transformsToApply: [UUID: CGAffineTransform]
        public let barTransformsToApply: [UUID: CGAffineTransform]
        public let slash: Letter?
        public let removedBarID: UUID
        public let parentCell: LetterCell
        public let lineStats: LineStats
        public let resolverStats: LineStats
        public let cursorX: CGFloat
    }

    public enum NavigationAction: Equatable {
        case move(to: Slot, cursorX: CGFloat)
        case leave(parentCell: LetterCell, lineStats: LineStats, resolverStats: LineStats)
        case deleteLetter(UUID)
        case deleteFraction(UUID)
        case dissolve(DissolvePlan)
        case none
    }

    /// A fraction trigger is allowed for the `/` key or whenever `/` is the decoder's
    /// top-ranked label for the glyph, whatever its posterior.
    public static func shouldTrigger(_ trigger: Trigger,
                                     nestingDepth: Int, hasPendingInk: Bool = false) -> Bool {
        guard nestingDepth < fractionDepthLimit else { return false }
        switch trigger {
        case .slashKey:
            return !hasPendingInk
        case .recognized(let label, _):
            return label == "/"
        }
    }

    /// Pull the trailing term back to its nearest body-level separator or word space.
    public static func operand(in row: Row, before endIndex: Int? = nil) -> Operand {
        let end = min(max(endIndex ?? row.items.count, 0), row.items.count)
        var start = end
        var parenthesisDepth = 0
        while start > 0 {
            let index = start - 1
            let item = row.items[index]
            if case .letter(let letter) = item, let label = letter.label {
                if parenthesisDepth == 0, letter.isBody, isSeparator(label) { break }
                if label == ")" { parenthesisDepth += 1 }
                else if label == "(" {
                    guard parenthesisDepth > 0 else { break }
                    parenthesisDepth -= 1
                }
                start = index
                if parenthesisDepth == 0, item.startsAfterWordSpace { break }
            } else {
                start = index
                if parenthesisDepth == 0, item.startsAfterWordSpace { break }
            }
        }

        let range = start..<end
        var removed: [UUID] = []
        if !range.isEmpty,
           case .letter(let first) = row.items[range.lowerBound], first.label == "(",
           case .letter(let last) = row.items[range.upperBound - 1], last.label == ")",
            matchingClose(in: row.items, forOpenAt: range.lowerBound, before: range.upperBound) == range.upperBound - 1 {
            removed = [first.id, last.id]
        }

        let originalBounds = bounds(of: row.items[start..<end])
        let stripped = Set(removed)
        let contentItems = row.items[start..<end].filter { item in
            guard case .letter(let letter) = item else { return true }
            return !stripped.contains(letter.id)
        }
        let contentBounds = bounds(of: contentItems)
        return Operand(range: start..<end, removedParenthesisIDs: removed,
                       originalBounds: originalBounds, contentBounds: contentBounds)
    }

    /// Bar and row baselines for a parent line. `left` remains the operand's original minX.
    public static func metrics(parent: Row, left: CGFloat, numeratorWidth: CGFloat,
                               denominatorWidth: CGFloat, hasOperand: Bool = true,
                               barID: UUID) -> Metrics {
        let (h, baseline) = parent.metrics
        let axis = baseline - 0.5 * h
        let numBaseline = axis - 0.30 * h
        let denBaseline = axis + 0.30 * h + slotScale * h
        let width = hasOperand ? max(numeratorWidth, denominatorWidth) + 0.3 * h : 0.9 * h
        let bar = Bar(id: barID, start: CGPoint(x: left, y: axis),
                      end: CGPoint(x: left + width, y: axis))
        let center = left + width / 2
        return Metrics(bar: bar, numeratorBaseline: numBaseline, denominatorBaseline: denBaseline,
                       numeratorOriginX: hasOperand ? center - numeratorWidth / 2 : left,
                       denominatorOriginX: center - denominatorWidth / 2,
                       numeratorWidth: numeratorWidth, denominatorWidth: denominatorWidth)
    }

    /// Seed slot cells and their independent stats from the parent row.
    public static func slotRows(parent: Row, metrics: Metrics,
                                numeratorItems: [Item] = [], denominatorItems: [Item] = []) -> SlotRows {
        let (_, baseline) = parent.metrics
        let slotHeight = parent.cell.height * slotScale
        func slotTransform(originX: CGFloat, targetBaseline: CGFloat) -> CGAffineTransform {
            let anchor = CGPoint(x: originX, y: baseline)
            return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                .concatenating(CGAffineTransform(scaleX: slotScale, y: slotScale))
                .concatenating(CGAffineTransform(translationX: anchor.x, y: targetBaseline))
        }
        func row(_ items: [Item], targetBaseline: CGFloat, originX: CGFloat,
                 width: CGFloat, line: LineStats, resolver: LineStats) -> Row {
            var cell = LetterCell(margin: originX, top: targetBaseline - 0.7 * slotHeight,
                                  height: slotHeight, deviceAspect: parent.cell.deviceAspect)
            cell.cursorX = originX + (items.isEmpty ? 0 : width + LetterCell.letterGap * slotHeight)
            return Row(items: items, cell: cell,
                       lineStats: line.scaled(from: baseline, to: targetBaseline, factor: slotScale),
                       resolverStats: resolver.scaled(from: baseline, to: targetBaseline, factor: slotScale),
                       transform: parent.transform.concatenating(
                        slotTransform(originX: originX, targetBaseline: targetBaseline)))
        }
        return SlotRows(
            numerator: row(numeratorItems, targetBaseline: metrics.numeratorBaseline,
                           originX: metrics.numeratorOriginX, width: metrics.numeratorWidth,
                           line: parent.lineStats,
                           resolver: parent.resolverStats),
            denominator: row(denominatorItems, targetBaseline: metrics.denominatorBaseline,
                             originX: metrics.denominatorOriginX, width: metrics.denominatorWidth,
                             line: parent.lineStats,
                             resolver: parent.resolverStats))
    }

    /// Prepare all pure outputs for replacing a trailing operand and slash with a fraction.
    public static func insertion(parent: Row, operand: Operand, slash: Letter? = nil,
                                 slashIndex: Int? = nil, barID: UUID = UUID(),
                                 cursorAfterSlash: CGFloat? = nil) -> InsertionPlan {
        let selected = Array(parent.items[operand.range])
        let strippedIDs = Set(operand.removedParenthesisIDs)
        let numeratorItems = selected.filter { item in
            if case .letter(let letter) = item { return !strippedIDs.contains(letter.id) }
            return true
        }
        let width = operand.contentBounds.isNull ? 0 : operand.contentBounds.width * slotScale
        let left = operand.isEmpty ? parent.cell.cursorX : operand.originalBounds.minX
        let metrics = self.metrics(parent: parent, left: left, numeratorWidth: width,
                                   denominatorWidth: 0, hasOperand: !operand.isEmpty, barID: barID)
        let (_, baseline) = parent.metrics
        let anchorX = operand.contentBounds.isNull ? left : operand.originalBounds.minX
        let anchor = CGPoint(x: anchorX, y: baseline)
        let scaled = operand.contentBounds.isNull ? .null : scaledRect(operand.contentBounds, about: anchor, by: slotScale)
        let dx = scaled.isNull ? 0 : metrics.bar.bounds.midX - scaled.midX
        let dy = metrics.numeratorBaseline - baseline
        let affine = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: slotScale, y: slotScale))
            .concatenating(CGAffineTransform(translationX: anchor.x + dx, y: anchor.y + dy))
        var transforms: [UUID: CGAffineTransform] = [:]
        for id in numeratorItems.flatMap(\.letterIDs) { transforms[id] = affine }
        let transformedItems = numeratorItems.map { applying(affine, to: $0) }
        var rows = slotRows(parent: parent, metrics: metrics, numeratorItems: transformedItems)
        rows.numerator.transform = parent.transform.concatenating(affine)

        let snapshot = UndoSnapshot(parentItems: parent.items,
                                    slash: slash, barID: barID, parentCell: parent.cell,
                                    lineStats: parent.lineStats, resolverStats: parent.resolverStats,
                                    operandRange: operand.range, slashIndex: slashIndex,
                                    removedParenthesisIDs: operand.removedParenthesisIDs,
                                    parentTransform: parent.transform,
                                    cursorAfterSlash: cursorAfterSlash ?? (slash == nil ? metrics.bar.maxX : parent.cell.cursorX))
        let fraction = Fraction(numerator: rows.numerator, denominator: rows.denominator,
                                bar: metrics.bar, startsAfterWordSpace: selected.first?.startsAfterWordSpace ?? false,
                                undoSnapshot: snapshot)
        var remaining = Array(parent.items[..<operand.range.lowerBound])
        remaining.append(.fraction(fraction))
        let suffixStart = slashIndex.map { min($0 + 1, parent.items.count) } ?? operand.range.upperBound
        if suffixStart < parent.items.count { remaining.append(contentsOf: parent.items[suffixStart...]) }
        let activeSlot: Slot = operand.isEmpty ? .numerator : .denominator
        let activeCell = activeSlot == .numerator ? rows.numerator.cell : rows.denominator.cell
        let barTransforms = Dictionary(uniqueKeysWithValues: numeratorItems.flatMap(barIDs).map { ($0, affine) })
        let nestedRows = collectRows(in: rows.numerator) + collectRows(in: rows.denominator)
        return InsertionPlan(fraction: fraction, parentItems: remaining, operand: operand,
                             transforms: transforms.map { Transform(letterID: $0.key, affine: $0.value) }
                                .sorted { $0.letterID.uuidString < $1.letterID.uuidString },
                             barTransforms: barTransforms,
                             nestedRows: Dictionary(uniqueKeysWithValues: nestedRows.map { ($0.id, $0) }),
                             activeSlot: activeSlot, activeCell: activeCell,
                             removedParenthesisIDs: operand.removedParenthesisIDs)
    }

    /// Recenter both slots on the current bar and return translations for every letter.
    public static func relayout(_ fraction: Fraction, parent: Row) -> Layout {
        let numBounds = fraction.numerator.bounds
        let denBounds = fraction.denominator.bounds
        let numWidth = numBounds.isNull ? 0 : numBounds.width
        let denWidth = denBounds.isNull ? 0 : denBounds.width
        let hasItems = !fraction.numerator.items.isEmpty || !fraction.denominator.items.isEmpty
        let metrics = self.metrics(parent: parent, left: fraction.bar.start.x,
                                   numeratorWidth: numWidth, denominatorWidth: denWidth,
                                   hasOperand: hasItems, barID: fraction.bar.id)
        let numDX = numBounds.isNull ? 0 : metrics.bar.bounds.midX - numBounds.midX
        let denDX = denBounds.isNull ? 0 : metrics.bar.bounds.midX - denBounds.midX
        var translations: [UUID: CGVector] = [:]
        for id in fraction.numerator.items.flatMap(\.letterIDs) { translations[id] = CGVector(dx: numDX, dy: 0) }
        for id in fraction.denominator.items.flatMap(\.letterIDs) { translations[id] = CGVector(dx: denDX, dy: 0) }
        let oldBarPositions = nestedBarPositions(in: fraction.numerator.items + fraction.denominator.items)
        let numerator = applying(CGAffineTransform(translationX: numDX, y: 0), to: fraction.numerator)
        let denominator = applying(CGAffineTransform(translationX: denDX, y: 0), to: fraction.denominator)
        var bar = metrics.bar
        bar.transform = fraction.bar.transform
        let updated = Fraction(numerator: numerator, denominator: denominator, bar: bar,
                               startsAfterWordSpace: fraction.startsAfterWordSpace,
                               undoSnapshot: fraction.undoSnapshot)
        let newBarPositions = nestedBarPositions(in: numerator.items + denominator.items)
        var barTranslations: [UUID: CGVector] = [:]
        for (id, point) in oldBarPositions {
            if let newPoint = newBarPositions[id] {
                barTranslations[id] = CGVector(dx: newPoint.x - point.x, dy: newPoint.y - point.y)
            }
        }
        let rowLayouts = collectRows(in: numerator) + collectRows(in: denominator)
        return Layout(metrics: metrics, letterTranslations: translations,
                      barTranslations: barTranslations,
                      nestedRows: Dictionary(uniqueKeysWithValues: rowLayouts.map { ($0.id, $0) }),
                      numeratorCell: numerator.cell, denominatorCell: denominator.cell,
                      fraction: updated)
    }

    public static func dissolve(_ fraction: Fraction, restoringSlash: Bool = true) -> DissolvePlan? {
        guard let snapshot = fraction.undoSnapshot else { return nil }
        // Return current numerator ink to its current parent row, including any outer
        // transforms applied after this fraction was created.
        let restoreTransform = fraction.numerator.transform.inverted().concatenating(snapshot.parentTransform)
        var content = fraction.numerator.items.map { applying(restoreTransform, to: $0) }
        if snapshot.removedParenthesisIDs.count == 2 {
            let removed = Set(snapshot.removedParenthesisIDs)
            let parentheses = snapshot.parentItems[snapshot.operandRange].compactMap { item -> Item? in
                guard case .letter(let letter) = item, removed.contains(letter.id) else { return nil }
                return item
            }
            if let open = parentheses.first { content.insert(open, at: 0) }
            if let close = parentheses.last, close != parentheses.first { content.append(close) }
        }
        let afterOperand = snapshot.slashIndex.map { min($0 + 1, snapshot.parentItems.count) }
            ?? snapshot.operandRange.upperBound
        var restored = Array(snapshot.parentItems[..<snapshot.operandRange.lowerBound])
        restored.append(contentsOf: content)
        if restoringSlash, let slash = snapshot.slash { restored.append(.letter(slash)) }
        if afterOperand < snapshot.parentItems.count {
            restored.append(contentsOf: snapshot.parentItems[afterOperand...])
        }
        var transforms = Dictionary(uniqueKeysWithValues: fraction.numerator.items.flatMap(\.letterIDs).map { ($0, restoreTransform) })
        for id in snapshot.removedParenthesisIDs { transforms[id] = .identity }
        if restoringSlash, let slash = snapshot.slash { transforms[slash.id] = .identity }
        let barTransforms = Dictionary(uniqueKeysWithValues: fraction.numerator.items.flatMap(barIDs).map { ($0, restoreTransform) })
        // Deleting the bar leaves the cursor right after the returned numerator.
        let cursorX: CGFloat? = restoringSlash || content.isEmpty ? nil
            : content.reduce(CGRect.null) { $0.union($1.bounds) }.maxX
                + LetterCell.letterGap * snapshot.parentCell.height
        return DissolvePlan(parentItems: restored,
                            transformsToApply: transforms, barTransformsToApply: barTransforms,
                            slash: restoringSlash ? snapshot.slash : nil, removedBarID: snapshot.barID,
                            parentCell: snapshot.parentCell, lineStats: snapshot.lineStats,
                            resolverStats: snapshot.resolverStats,
                            cursorX: cursorX ?? snapshot.cursorAfterSlash)
    }

    public static func handle(_ key: Key, in slot: Slot, fraction: Fraction,
                              parent: Row) -> NavigationAction {
        switch key {
        case .down where slot == .numerator:
            return .move(to: .denominator, cursorX: fraction.denominator.cell.cursorX)
        case .up where slot == .denominator:
            return .move(to: .numerator, cursorX: fraction.numerator.cell.cursorX)
        case .right, .tab:
            var cell = parent.cell
            cell.cursorX = fraction.bar.maxX + LetterCell.letterGap * parent.cell.height
            return .leave(parentCell: cell, lineStats: parent.lineStats, resolverStats: parent.resolverStats)
        case .left:
            var cell = parent.cell
            cell.cursorX = fraction.bar.start.x
            return .leave(parentCell: cell, lineStats: parent.lineStats, resolverStats: parent.resolverStats)
        case .delete:
            let row = slot == .numerator ? fraction.numerator : fraction.denominator
            if let last = row.items.last {
                switch last {
                case .letter(let letter): return .deleteLetter(letter.id)
                case .fraction(let nested): return .deleteFraction(nested.bar.id)
                }
            }
            // Order: denominator items, the bar, numerator items, then earlier symbols.
            if slot == .denominator {
                if !fraction.numerator.items.isEmpty,
                   let plan = dissolve(fraction, restoringSlash: false) {
                    return .dissolve(plan)
                }
                return .deleteFraction(fraction.bar.id)
            }
            if fraction.denominator.items.isEmpty { return .deleteFraction(fraction.bar.id) }
            return .move(to: .denominator, cursorX: fraction.denominator.cell.cursorX)
        default:
            return .none
        }
    }

    /// Avoid colliding with unusually tall ink when starting the next line.
    public static func nextLineTop(currentTop: CGFloat, lowestInkMaxY: CGFloat?,
                                   cellHeight: CGFloat, linePitch: CGFloat = LetterCell.linePitch) -> CGFloat {
        max(currentTop + linePitch * cellHeight,
            (lowestInkMaxY ?? -.greatestFiniteMagnitude) + 0.25 * cellHeight)
    }

    private static func bounds(of items: some Sequence<Item>) -> CGRect {
        items.reduce(.null) { $0.union($1.bounds) }
    }

    private static func applying(_ transform: CGAffineTransform, to row: Row) -> Row {
        var row = row
        row.items = row.items.map { applying(transform, to: $0) }
        row.cell = applying(transform, to: row.cell)
        row.lineStats = applying(transform, to: row.lineStats)
        row.resolverStats = applying(transform, to: row.resolverStats)
        row.transform = row.transform.concatenating(transform)
        return row
    }

    private static func applying(_ transform: CGAffineTransform, to cell: LetterCell) -> LetterCell {
        var cell = cell
        cell.margin = apply(CGPoint(x: cell.margin, y: 0), transform).x
        cell.cursorX = apply(CGPoint(x: cell.cursorX, y: 0), transform).x
        cell.top = apply(CGPoint(x: 0, y: cell.top), transform).y
        cell.height *= abs(transform.d)
        return cell
    }

    private static func applying(_ transform: CGAffineTransform, to stats: LineStats) -> LineStats {
        LineStats(heights: stats.heights.map { $0 * abs(transform.d) },
                  bottoms: stats.bottoms.map { apply(CGPoint(x: 0, y: $0), transform).y })
    }

    static func applying(_ transform: CGAffineTransform, to item: Item) -> Item {
        switch item {
        case .letter(var letter):
            letter.extent = letter.extent.applying(transform)
            return .letter(letter)
        case .fraction(var fraction):
            fraction.numerator = applying(transform, to: fraction.numerator)
            fraction.denominator = applying(transform, to: fraction.denominator)
            fraction.bar.start = fraction.bar.start.applying(transform)
            fraction.bar.end = fraction.bar.end.applying(transform)
            fraction.bar.transform = fraction.bar.transform.concatenating(transform)
            fraction.undoSnapshot = fraction.undoSnapshot.map { applying(transform, to: $0) }
            return .fraction(fraction)
        }
    }

    private static func applying(_ transform: CGAffineTransform, to snapshot: UndoSnapshot) -> UndoSnapshot {
        let point = apply(CGPoint(x: snapshot.cursorAfterSlash, y: 0), transform)
        return UndoSnapshot(parentItems: snapshot.parentItems.map { applying(transform, to: $0) },
                            slash: snapshot.slash.map { letter in
                                var letter = letter
                                letter.extent = letter.extent.applying(transform)
                                return letter
                            },
                            barID: snapshot.barID, parentCell: applying(transform, to: snapshot.parentCell),
                            lineStats: applying(transform, to: snapshot.lineStats),
                            resolverStats: applying(transform, to: snapshot.resolverStats),
                            operandRange: snapshot.operandRange, slashIndex: snapshot.slashIndex,
                            removedParenthesisIDs: snapshot.removedParenthesisIDs,
                            parentTransform: snapshot.parentTransform.concatenating(transform),
                            cursorAfterSlash: point.x)
    }

    private static func nestedBarPositions(in items: [Item]) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        for item in items {
            if case .fraction(let fraction) = item {
                positions[fraction.bar.id] = fraction.bar.start
                positions.merge(nestedBarPositions(in: fraction.numerator.items + fraction.denominator.items)) { first, _ in first }
            }
        }
        return positions
    }

    private static func collectRows(in row: Row) -> [RowLayout] {
        [RowLayout(id: row.id, cell: row.cell, lineStats: row.lineStats, resolverStats: row.resolverStats)] +
            row.items.flatMap { item -> [RowLayout] in
                guard case .fraction(let fraction) = item else { return [] }
                return collectRows(in: fraction.numerator) + collectRows(in: fraction.denominator)
            }
    }

    private static func isSeparator(_ label: String) -> Bool {
        ["+", "−", "=", "≠", "<", ">", "≤", "≥", "±", "÷", "·"].contains(label)
    }

    private static func matchingClose(in items: [Item], forOpenAt open: Int, before end: Int) -> Int? {
        var depth = 0
        for index in open..<end {
            guard case .letter(let letter) = items[index] else { continue }
            if letter.label == "(" { depth += 1 }
            if letter.label == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func barIDs(in item: Item) -> [UUID] {
        guard case .fraction(let fraction) = item else { return [] }
        return [fraction.bar.id] + fraction.numerator.items.flatMap(barIDs) + fraction.denominator.items.flatMap(barIDs)
    }

    private static func scaledRect(_ rect: CGRect, about point: CGPoint, by scale: CGFloat) -> CGRect {
        CGRect(x: point.x + (rect.minX - point.x) * scale,
               y: point.y + (rect.minY - point.y) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    private static func apply(_ point: CGPoint, _ transform: CGAffineTransform) -> CGPoint {
        CGPoint(x: point.x * transform.a + point.y * transform.c + transform.tx,
                y: point.x * transform.b + point.y * transform.d + transform.ty)
    }

}
