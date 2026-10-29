import CoreGraphics
import XCTest
@testable import CanvasKit

final class MathFractionTests: XCTestCase {
    private func letter(_ label: String?, _ x: CGFloat, _ y: CGFloat = 90,
                        _ width: CGFloat = 10, _ height: CGFloat = 12,
                        space: Bool = false, body: Bool = true) -> MathFraction.Item {
        .letter(MathFraction.Letter(id: UUID(), label: label,
                                    extent: CGRect(x: x, y: y, width: width, height: height),
                                    startsAfterWordSpace: space, isBody: body))
    }

    private func ref(_ item: MathFraction.Item) -> MathFraction.Letter {
        guard case .letter(let letter) = item else { fatalError("Expected a letter") }
        return letter
    }

    private func labels(_ items: [MathFraction.Item]) -> [String?] {
        items.map { item in if case .letter(let letter) = item { letter.label } else { nil } }
    }

    private func assertRectEqual(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 1e-8) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy)
    }

    private func row(_ items: [MathFraction.Item] = [], height: CGFloat = 32, top: CGFloat = 100,
                     heights: [CGFloat] = [], bottoms: [CGFloat] = []) -> MathFraction.Row {
        MathFraction.Row(items: items, cell: LetterCell(margin: 10, top: top, height: height),
                         lineStats: .init(heights: heights, bottoms: bottoms))
    }

    func testSlashTriggerUsesTopRankedLabelKeyAndNestingLimit() {
        XCTAssertTrue(MathFraction.shouldTrigger(.slashKey, nestingDepth: 0))
        XCTAssertFalse(MathFraction.shouldTrigger(.slashKey, nestingDepth: 0, hasPendingInk: true))
        // The decoder's top-ranked label decides, whatever its posterior.
        XCTAssertTrue(MathFraction.shouldTrigger(.recognized(label: "/", posterior: 0.8), nestingDepth: 1))
        XCTAssertTrue(MathFraction.shouldTrigger(.recognized(label: "/", posterior: 0.05), nestingDepth: 1))
        XCTAssertFalse(MathFraction.shouldTrigger(.recognized(label: "−", posterior: 0.99), nestingDepth: 0))
        XCTAssertFalse(MathFraction.shouldTrigger(.recognized(label: "/", posterior: 0.99), nestingDepth: 2))
    }

    func testOperandStopsAtOperatorsAndWordSpacesButKeepsScripts() {
        let terms = [letter("2", 0), letter("+", 12), letter("3", 24), letter("x", 36)]
        let operand = MathFraction.operand(in: row(terms))
        XCTAssertEqual(labels(Array(row(terms).items[operand.range])), ["3", "x"])

        let product = [letter("a", 0), letter("·", 12), letter("b", 24)]
        let productOperand = MathFraction.operand(in: row(product))
        XCTAssertEqual(labels(Array(row(product).items[productOperand.range])), ["b"])

        let power = [letter("x", 0), letter("2", 12, 80, 6, 6, body: false)]
        let powerOperand = MathFraction.operand(in: row(power))
        XCTAssertEqual(labels(Array(row(power).items[powerOperand.range])), ["x", "2"])

        let spaced = [letter("a", 0), letter("b", 40, space: true)]
        let spacedOperand = MathFraction.operand(in: row(spaced))
        XCTAssertEqual(spacedOperand.range, 1..<2)
    }

    func testBalancedOuterParenthesesAreRemovedOnlyWhenTheyAreTheWholeTerm() {
        let grouped = [letter("(", 0), letter("x", 12), letter("+", 24), letter("1", 36), letter(")", 48)]
        let groupRow = row(grouped)
        let group = MathFraction.operand(in: groupRow)
        XCTAssertEqual(group.range, 0..<5)
        XCTAssertEqual(group.removedParenthesisIDs, [ref(grouped[0]).id, ref(grouped[4]).id])
        XCTAssertEqual(labels(grouped.enumerated().filter { !group.removedParenthesisIDs.contains(ref($0.element).id) }.map(\.element)), ["x", "+", "1"])

        let attached = [letter("s", 0), letter("i", 10), letter("n", 20), letter("(", 30), letter("x", 40), letter(")", 50)]
        let attachedOperand = MathFraction.operand(in: row(attached))
        XCTAssertTrue(attachedOperand.removedParenthesisIDs.isEmpty)
        XCTAssertEqual(attachedOperand.range, 0..<6)

        let prefixed = [letter("2", 0), letter("(", 12), letter("x", 24), letter("+", 36), letter("1", 48), letter(")", 60)]
        let prefixedOperand = MathFraction.operand(in: row(prefixed))
        XCTAssertTrue(prefixedOperand.removedParenthesisIDs.isEmpty)
        XCTAssertEqual(prefixedOperand.range, 0..<6)

        let afterOperator = [letter("a", 0), letter("+", 12), letter("(", 24), letter("x", 36), letter(")", 48)]
        let afterOperatorOperand = MathFraction.operand(in: row(afterOperator))
        XCTAssertEqual(afterOperatorOperand.range, 2..<5)
        XCTAssertEqual(afterOperatorOperand.removedParenthesisIDs, [ref(afterOperator[2]).id, ref(afterOperator[4]).id])
    }

    func testEmptyOperandAtLineStartOrAfterOperatorStartsInNumerator() {
        let empty = row()
        let atStart = MathFraction.operand(in: empty)
        let startPlan = MathFraction.insertion(parent: empty, operand: atStart, barID: UUID())
        XCTAssertTrue(atStart.isEmpty)
        XCTAssertEqual(startPlan.activeSlot, .numerator)
        XCTAssertEqual(startPlan.fraction.bar.end.x - startPlan.fraction.bar.start.x, 0.9 * 0.4 * empty.cell.height, accuracy: 1e-8)
        XCTAssertEqual(startPlan.activeCell.cursorX, empty.cell.cursorX)
        XCTAssertEqual(MathFraction.handle(.down, in: .numerator, fraction: startPlan.fraction,
                                            parent: empty),
                       .move(to: .denominator, cursorX: startPlan.fraction.denominator.cell.cursorX))

        let withOperator = row([letter("+", 10)])
        let afterOperator = MathFraction.operand(in: withOperator)
        let plan = MathFraction.insertion(parent: withOperator, operand: afterOperator)
        XCTAssertTrue(afterOperator.isEmpty)
        XCTAssertEqual(plan.parentItems.count, 2)
        XCTAssertEqual(plan.activeSlot, .numerator)
    }

    func testFallbackAndRecordedMetricsAreExact() {
        let fallback = row()
        let fallbackMetrics = MathFraction.metrics(parent: fallback, left: 20, numeratorWidth: 10,
                                                    denominatorWidth: 4, barID: UUID())
        XCTAssertEqual(fallback.cellBaseline, 122.4, accuracy: 1e-8)
        XCTAssertEqual(fallbackMetrics.barY, 116, accuracy: 1e-8)
        XCTAssertEqual(fallbackMetrics.numeratorBaseline, 112.16, accuracy: 1e-8)
        XCTAssertEqual(fallbackMetrics.denominatorBaseline, 130.08, accuracy: 1e-8)
        XCTAssertEqual(fallbackMetrics.bar.end.x, 33.84, accuracy: 1e-8)

        let measured = row(height: 32, heights: [20, 24], bottoms: [100, 104])
        let metrics = MathFraction.metrics(parent: measured, left: 30, numeratorWidth: 20,
                                           denominatorWidth: 10, barID: UUID())
        XCTAssertEqual(metrics.barY, 92, accuracy: 1e-8)
        XCTAssertEqual(metrics.numeratorBaseline, 84.8, accuracy: 1e-8)
        XCTAssertEqual(metrics.denominatorBaseline, 118.4, accuracy: 1e-8)
        XCTAssertEqual(metrics.bar.end.x, 57.2, accuracy: 1e-8)
        XCTAssertEqual(metrics.numeratorOriginX, 33.6, accuracy: 1e-8)
        XCTAssertEqual(metrics.denominatorOriginX, 38.6, accuracy: 1e-8)
    }

    func testSlotCellsAndStatsAreIndependentAndScaled() {
        let parent = MathFraction.Row(
            items: [], cell: LetterCell(margin: 10, top: 100, height: 32),
            lineStats: .init(heights: [10], bottoms: [125]),
            resolverStats: .init(heights: [12], bottoms: [126]))
        let metrics = MathFraction.metrics(parent: parent, left: 10, numeratorWidth: 0,
                                           denominatorWidth: 0, hasOperand: false, barID: UUID())
        let slots = MathFraction.slotRows(parent: parent, metrics: metrics)
        XCTAssertEqual(slots.numerator.cell.height, 25.6, accuracy: 1e-8)
        XCTAssertEqual(slots.numerator.cellBaseline, metrics.numeratorBaseline, accuracy: 1e-8)
        XCTAssertEqual(slots.denominator.cellBaseline, metrics.denominatorBaseline, accuracy: 1e-8)
        XCTAssertEqual(slots.numerator.lineStats.heights, [8])
        XCTAssertEqual(slots.numerator.lineStats.baseline ?? 0, 114.24, accuracy: 1e-8)
        XCTAssertEqual(slots.numerator.resolverStats.heights[0], 9.6, accuracy: 1e-8)
        XCTAssertEqual(slots.numerator.resolverStats.baseline ?? 0, 115.04, accuracy: 1e-8)

        var updated = slots.denominator.lineStats
        updated.record(CGRect(x: 12, y: 50, width: 4, height: 6))
        XCTAssertEqual(updated.heights.count, 2)
        XCTAssertEqual(slots.denominator.lineStats.heights.count, 1)
    }

    func testInsertionReturnsScaleTransformsPinnedSlashAndRestorableSnapshot() throws {
        let source = [letter("(", 10), letter("x", 20), letter("+", 30), letter("1", 40), letter(")", 50)]
        let slashItem = letter("/", 65)
        var items = source
        items.append(slashItem)
        let parent = row(items)
        let slash = ref(slashItem)
        let operand = MathFraction.operand(in: parent, before: items.count - 1)
        let plan = MathFraction.insertion(parent: parent, operand: operand, slash: slash,
                                         slashIndex: items.count - 1, barID: UUID())
        XCTAssertEqual(plan.parentItems.count, 1)
        guard case .fraction(let fraction) = plan.parentItems[0] else { return XCTFail("Expected a fraction item") }
        XCTAssertEqual(labels(fraction.numerator.items), ["x", "+", "1"])
        XCTAssertEqual(plan.removedParenthesisIDs, [ref(source[0]).id, ref(source[4]).id])
        XCTAssertEqual(fraction.bar.start.x, 10, accuracy: 1e-8)
        XCTAssertEqual(plan.activeSlot, .denominator)
        XCTAssertEqual(Set(plan.transforms.map(\.letterID)), Set([ref(source[1]).id, ref(source[2]).id, ref(source[3]).id]))
        let transform = try XCTUnwrap(plan.transforms.first { $0.letterID == ref(source[1]).id }).affine
        let transformedBaseline = CGPoint(x: 20 * transform.a + 122.4 * transform.c + transform.tx,
                                          y: 20 * transform.b + 122.4 * transform.d + transform.ty)
        XCTAssertEqual(transformedBaseline.y, fraction.numerator.cellBaseline, accuracy: 1e-8)
        XCTAssertEqual(fraction.undoSnapshot?.parentItems, items)
        XCTAssertEqual(fraction.undoSnapshot?.slash?.id, slash.id)
    }

    func testSlashAfterThreeXMovesThreeXIntoNumerator() {
        let items = [letter("3", 10), letter("x", 22), letter("/", 36)]
        var cell = LetterCell(margin: 10, top: 100, height: 32)
        cell.cursorX = ref(items[2]).extent.maxX + LetterCell.letterGap * cell.height
        let parent = MathFraction.Row(items: items, cell: cell)
        let operand = MathFraction.operand(in: parent, before: 2)
        let plan = MathFraction.insertion(parent: parent, operand: operand,
                                         slash: ref(items[2]), slashIndex: 2)
        XCTAssertEqual(labels(plan.fraction.numerator.items), ["3", "x"])
        XCTAssertEqual(plan.activeSlot, .denominator)
        XCTAssertTrue(MathFraction.shouldTrigger(.recognized(label: "/", posterior: 0.95),
                                                  nestingDepth: 0))
    }

    func testRelayoutExpandsForWiderDenominatorAndRecentersBothRows() {
        let parent = row(height: 20)
        let numeratorItem = letter("x", 10, 90, 20, 8)
        let denominatorItem = letter("1", 0, 120, 30, 8)
        let barID = UUID()
        let numerator = MathFraction.Row(items: [numeratorItem], cell: LetterCell(margin: 10, top: 80, height: 16))
        let denominator = MathFraction.Row(items: [denominatorItem], cell: LetterCell(margin: 0, top: 110, height: 16))
        let fraction = MathFraction.Fraction(numerator: numerator, denominator: denominator,
                                             bar: .init(id: barID, start: CGPoint(x: 10, y: 90), end: CGPoint(x: 34, y: 90)))
        let layout = MathFraction.relayout(fraction, parent: parent)
        XCTAssertEqual(layout.metrics.bar.end.x - layout.metrics.bar.start.x, 30 + 0.3 * 8, accuracy: 1e-8)
        let targetMid = layout.metrics.bar.bounds.midX
        XCTAssertEqual(numerator.bounds.midX + layout.letterTranslations[ref(numeratorItem).id]!.dx,
                       targetMid, accuracy: 1e-8)
        XCTAssertEqual(denominator.bounds.midX + layout.letterTranslations[ref(denominatorItem).id]!.dx,
                       targetMid, accuracy: 1e-8)
        XCTAssertEqual(layout.numeratorCell.margin, numerator.cell.margin + layout.letterTranslations[ref(numeratorItem).id]!.dx, accuracy: 1e-8)
    }

    func testNestedBarsCellsAndStatsFollowOuterTransformsAndRelayout() throws {
        let innerNumID = UUID(), innerDenID = UUID(), innerBarID = UUID()
        let innerNum = MathFraction.Row(items: [letter("1", 14)],
                                        cell: LetterCell(margin: 14, top: 60, height: 16),
                                        lineStats: .init(heights: [5, 6], bottoms: [70, 72]), id: innerNumID)
        let innerDen = MathFraction.Row(items: [letter("2", 14, 90)],
                                        cell: LetterCell(margin: 14, top: 90, height: 16),
                                        lineStats: .init(heights: [5, 6], bottoms: [100, 102]), id: innerDenID)
        let innerBar = MathFraction.Bar(id: innerBarID, start: CGPoint(x: 10, y: 85), end: CGPoint(x: 30, y: 85))
        let inner = MathFraction.Fraction(numerator: innerNum, denominator: innerDen, bar: innerBar)
        let parent = row([.fraction(inner)])
        let operand = MathFraction.operand(in: parent)
        let plan = MathFraction.insertion(parent: parent, operand: operand, barID: UUID())
        let outer = plan.fraction
        let affine = try XCTUnwrap(plan.barTransforms[innerBarID])
        XCTAssertTrue(plan.nestedRows[innerNumID] != nil)
        XCTAssertTrue(plan.nestedRows[innerDenID] != nil)
        guard case .fraction(let transformedInner) = outer.numerator.items[0] else {
            return XCTFail("Expected the nested fraction to remain structured")
        }
        let expectedBarStart = CGPoint(x: innerBar.start.x * affine.a + innerBar.start.y * affine.c + affine.tx,
                                       y: innerBar.start.x * affine.b + innerBar.start.y * affine.d + affine.ty)
        XCTAssertEqual(transformedInner.bar.start, expectedBarStart)
        XCTAssertEqual(transformedInner.numerator.cell.height, innerNum.cell.height * 0.8, accuracy: 1e-8)
        XCTAssertEqual(transformedInner.numerator.lineStats.heights[0], 4, accuracy: 1e-8)

        var denominator = outer.denominator
        denominator.items = [letter("7", 80, 130, 50, 8)]
        let layout = MathFraction.relayout(.init(numerator: outer.numerator, denominator: denominator,
                                                 bar: outer.bar, undoSnapshot: outer.undoSnapshot), parent: parent)
        XCTAssertNotEqual(layout.barTranslations[innerBarID]?.dx, 0)
        XCTAssertTrue(layout.nestedRows[innerNumID] != nil)
        guard case .fraction(let recenteredInner) = layout.fraction.numerator.items[0] else {
            return XCTFail("Expected nested fraction after relayout")
        }
        XCTAssertEqual(recenteredInner.bar.start.x - transformedInner.bar.start.x,
                       try XCTUnwrap(layout.barTranslations[innerBarID]).dx, accuracy: 1e-8)
        XCTAssertEqual(layout.fraction.numerator.cellBaseline, outer.numerator.cellBaseline, accuracy: 1e-8)
    }

    func testNestedDissolveRestoresIntoOuterSlotAndMapsNewLetters() throws {
        let source = [letter("x", 20, 90)]
        let slash = letter("/", 34, 90)
        let sourceItems = source + [slash]
        var parentCell = LetterCell(margin: 10, top: 80, height: 32)
        parentCell.cursorX = ref(slash).extent.maxX + LetterCell.letterGap * parentCell.height
        let innerParent = MathFraction.Row(items: sourceItems, cell: parentCell,
                                            lineStats: .init(heights: [10, 12], bottoms: [100, 102]))
        let innerOperand = MathFraction.operand(in: innerParent, before: sourceItems.count - 1)
        let innerPlan = MathFraction.insertion(parent: innerParent, operand: innerOperand,
                                                slash: ref(slash), slashIndex: sourceItems.count - 1)

        let outerParent = MathFraction.Row(items: [.fraction(innerPlan.fraction)], cell: parentCell,
                                            lineStats: innerParent.lineStats)
        let outerOperand = MathFraction.operand(in: outerParent)
        let outerPlan = MathFraction.insertion(parent: outerParent, operand: outerOperand)
        guard case .fraction(var nested) = outerPlan.fraction.numerator.items[0] else {
            return XCTFail("Expected the original fraction to be nested")
        }
        let nestedSnapshot = try XCTUnwrap(nested.undoSnapshot)
        XCTAssertEqual(nestedSnapshot.parentTransform, outerPlan.fraction.numerator.transform)

        let newLetter = MathFraction.Letter(
            id: UUID(), label: "y",
            extent: CGRect(x: nested.numerator.cell.cursorX,
                           y: nested.numerator.cellBaseline - 8, width: 8, height: 8))
        nested.numerator.items.append(.letter(newLetter))
        let layout = MathFraction.relayout(nested, parent: outerPlan.fraction.numerator)
        nested = layout.fraction
        let currentX = try XCTUnwrap(nested.numerator.items.first { $0.letterIDs.contains(ref(source[0]).id) })
        let currentY = try XCTUnwrap(nested.numerator.items.first { $0.letterIDs.contains(newLetter.id) })

        let dissolve = try XCTUnwrap(MathFraction.dissolve(nested))
        let expectedParentX = try XCTUnwrap(nestedSnapshot.parentItems.first { $0.letterIDs.contains(ref(source[0]).id) })
        let restoredX = try XCTUnwrap(dissolve.parentItems.first { $0.letterIDs.contains(ref(source[0]).id) })
        let restoredY = try XCTUnwrap(dissolve.parentItems.first { $0.letterIDs.contains(newLetter.id) })
        assertRectEqual(restoredX.bounds, expectedParentX.bounds)
        XCTAssertEqual(dissolve.parentCell, nestedSnapshot.parentCell)
        XCTAssertEqual(dissolve.transformsToApply[ref(source[0]).id],
                       dissolve.transformsToApply[newLetter.id])
        assertRectEqual(restoredX.bounds,
                        currentX.bounds.applying(try XCTUnwrap(dissolve.transformsToApply[ref(source[0]).id])))
        assertRectEqual(restoredY.bounds,
                        currentY.bounds.applying(try XCTUnwrap(dissolve.transformsToApply[newLetter.id])))
        XCTAssertEqual(labels(dissolve.parentItems), ["x", "y", "/"])
    }

    func testRelayoutThenDissolveKeepsNewNumeratorLettersAndRestoresParenthesesAndSlash() throws {
        let source = [letter("(", 10), letter("x", 20), letter("+", 30), letter("1", 40), letter(")", 50)]
        let slash = letter("/", 65)
        let parentItems = source + [slash]
        let parent = row(parentItems)
        let operand = MathFraction.operand(in: parent, before: parentItems.count - 1)
        let plan = MathFraction.insertion(parent: parent, operand: operand, slash: ref(slash),
                                         slashIndex: parentItems.count - 1)
        var fraction = plan.fraction
        let newNumerator = letter("z", -20, 95, 50, 8)
        fraction.numerator.items.append(newNumerator)
        let layout = MathFraction.relayout(fraction, parent: parent)
        XCTAssertNotEqual(layout.letterTranslations[ref(newNumerator).id]?.dx, 0)
        fraction = layout.fraction

        let dissolved = try XCTUnwrap(MathFraction.dissolve(fraction))
        let restored = dissolved.parentItems
        XCTAssertEqual(labels(restored), ["(", "x", "+", "1", "z", ")", "/"])
        XCTAssertEqual(restored.map(\.letterIDs).flatMap { $0 }.count, 7)
        XCTAssertTrue(dissolved.transformsToApply[ref(newNumerator).id] != nil)
        XCTAssertEqual(dissolved.slash?.id, ref(slash).id)
        XCTAssertEqual(dissolved.parentItems.first?.letterIDs.first, ref(source[0]).id)
        XCTAssertEqual(dissolved.parentItems.last?.letterIDs.first, ref(slash).id)
        let restoredX = try XCTUnwrap(dissolved.parentItems.first { $0.letterIDs.contains(ref(source[1]).id) })
        guard case .letter(let x) = restoredX else { return XCTFail("Expected the original x") }
        XCTAssertEqual(x.extent.minX, ref(source[1]).extent.minX, accuracy: 1e-8)
        XCTAssertEqual(x.extent.minY, ref(source[1]).extent.minY, accuracy: 1e-8)
        XCTAssertEqual(x.extent.width, ref(source[1]).extent.width, accuracy: 1e-8)
        XCTAssertEqual(x.extent.height, ref(source[1]).extent.height, accuracy: 1e-8)
    }

    func testDissolveRestoresOriginalItemsTransformsParenSlashStatsAndCursor() throws {
        let source = [letter("(", 10), letter("x", 20), letter(")", 30)]
        let slashItem = letter("/", 45)
        let items = source + [slashItem]
        let parent = MathFraction.Row(items: items, cell: LetterCell(margin: 10, top: 20, height: 30),
                                      lineStats: .init(heights: [10, 12], bottoms: [40, 42]),
                                      resolverStats: .init(heights: [11, 13], bottoms: [41, 43]))
        var committedCell = parent.cell
        committedCell.cursorX = ref(slashItem).extent.maxX + LetterCell.letterGap * parent.cell.height
        let committedParent = MathFraction.Row(items: items, cell: committedCell,
                                               lineStats: parent.lineStats, resolverStats: parent.resolverStats)
        let operand = MathFraction.operand(in: committedParent, before: items.count - 1)
        let plan = MathFraction.insertion(parent: committedParent, operand: operand, slash: ref(slashItem),
                                         slashIndex: items.count - 1)
        let dissolve = try XCTUnwrap(MathFraction.dissolve(plan.fraction))
        XCTAssertEqual(dissolve.parentItems, items)
        let forward = try XCTUnwrap(plan.transforms.first).affine
        XCTAssertEqual(dissolve.transformsToApply[ref(source[1]).id], forward.inverted())
        XCTAssertEqual(dissolve.transformsToApply[ref(source[0]).id], .identity)
        XCTAssertEqual(dissolve.transformsToApply[ref(slashItem).id], .identity)
        XCTAssertEqual(dissolve.slash?.id, ref(slashItem).id)
        XCTAssertEqual(dissolve.removedBarID, plan.fraction.bar.id)
        XCTAssertEqual(dissolve.parentCell, committedParent.cell)
        XCTAssertEqual(dissolve.lineStats, committedParent.lineStats)
        XCTAssertEqual(dissolve.resolverStats, committedParent.resolverStats)
        XCTAssertEqual(dissolve.cursorX, committedParent.cell.cursorX)
    }

    func testNavigationDeleteAndLineSpacing() throws {
        let parent = row(height: 32, heights: [10, 12], bottoms: [100, 102])
        let numItem = letter("x", 10)
        let denItem = letter("2", 20)
        let numRow = MathFraction.Row(items: [numItem], cell: LetterCell(margin: 10, top: 70, height: 25.6))
        let denRow = MathFraction.Row(items: [denItem], cell: LetterCell(margin: 20, top: 100, height: 25.6))
        let bar = MathFraction.Bar(id: UUID(), start: CGPoint(x: 10, y: 80), end: CGPoint(x: 40, y: 80))
        let fraction = MathFraction.Fraction(numerator: numRow, denominator: denRow, bar: bar)
        XCTAssertEqual(MathFraction.handle(.down, in: .numerator, fraction: fraction, parent: parent),
                       .move(to: .denominator, cursorX: denRow.cell.cursorX))
        XCTAssertEqual(MathFraction.handle(.up, in: .denominator, fraction: fraction, parent: parent),
                       .move(to: .numerator, cursorX: numRow.cell.cursorX))
        XCTAssertEqual(MathFraction.handle(.delete, in: .numerator, fraction: fraction, parent: parent),
                       .deleteLetter(ref(numItem).id))
        for key in [MathFraction.Key.right, .tab] {
            guard case .leave(let cell, let line, let resolver) = MathFraction.handle(key, in: .denominator, fraction: fraction, parent: parent) else {
                return XCTFail("Expected to leave the fraction")
            }
            XCTAssertEqual(cell.cursorX, bar.maxX + LetterCell.letterGap * parent.cell.height, accuracy: 1e-8)
            XCTAssertEqual(line, parent.lineStats)
            XCTAssertEqual(resolver, parent.resolverStats)
        }
        let emptyDenominator = MathFraction.Fraction(numerator: numRow, denominator: MathFraction.Row(cell: denRow.cell),
                                                     bar: bar, undoSnapshot: .init(parentItems: [],
                                                                                  slash: nil, barID: bar.id, parentCell: parent.cell,
                                                                                  lineStats: parent.lineStats, resolverStats: parent.resolverStats,
                                                                                  operandRange: 0..<0, slashIndex: nil,
                                                                                  removedParenthesisIDs: [],
                                                                                  parentTransform: .identity,
                                                                                  cursorAfterSlash: 42))
        // Empty denominator with a numerator: Delete removes the bar (numerator returns to the parent).
        guard case .dissolve(let plan) = MathFraction.handle(.delete, in: .denominator,
                                                            fraction: emptyDenominator, parent: parent) else {
            return XCTFail("expected dissolve")
        }
        XCTAssertEqual(plan.removedBarID, bar.id)
        XCTAssertNil(plan.slash)
        let empty = MathFraction.Fraction(numerator: MathFraction.Row(cell: numRow.cell),
                                          denominator: MathFraction.Row(cell: denRow.cell), bar: bar)
        for slot in [MathFraction.Slot.numerator, .denominator] {
            XCTAssertEqual(MathFraction.handle(.delete, in: slot, fraction: empty, parent: parent),
                           .deleteFraction(bar.id))
        }
        XCTAssertEqual(MathFraction.nextLineTop(currentTop: 100, lowestInkMaxY: nil, cellHeight: 32), 138.4, accuracy: 1e-8)
        XCTAssertEqual(MathFraction.nextLineTop(currentTop: 100, lowestInkMaxY: 145, cellHeight: 32), 153, accuracy: 1e-8)
    }
}
