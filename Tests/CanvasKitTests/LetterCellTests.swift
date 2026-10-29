import XCTest
@testable import CanvasKit

final class LetterCellTests: XCTestCase {
    private let acc: CGFloat = 1e-9

    /// Height 10, aspect 2: a 20 x 10 cell with its top-left at (100, 50).
    private func makeCell() -> LetterCell {
        LetterCell(margin: 100, top: 50, height: 10, deviceAspect: 2)
    }

    // MARK: init

    func testInitDefaults() {
        let cell = LetterCell(margin: 5, top: 7)
        XCTAssertEqual(cell.height, 32, accuracy: acc)
        XCTAssertEqual(cell.deviceAspect, 1.6, accuracy: acc)
        XCTAssertEqual(cell.margin, 5, accuracy: acc)
        XCTAssertEqual(cell.top, 7, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 5, accuracy: acc)
    }

    func testInitClampsNonPositiveHeightAndAspect() {
        for bad: CGFloat in [0, -3] {
            let cell = LetterCell(margin: 0, top: 0, height: bad, deviceAspect: bad)
            XCTAssertEqual(cell.height, 32, accuracy: acc)
            XCTAssertEqual(cell.deviceAspect, 1.6, accuracy: acc)
        }
    }

    func testInitKeepsPositiveValues() {
        let cell = makeCell()
        XCTAssertEqual(cell.height, 10, accuracy: acc)
        XCTAssertEqual(cell.deviceAspect, 2, accuracy: acc)
        XCTAssertEqual(cell.cursorX, cell.margin, accuracy: acc)
    }

    // MARK: Geometry

    func testSizeAndRect() {
        var cell = makeCell()
        XCTAssertEqual(cell.size.width, 20, accuracy: acc)
        XCTAssertEqual(cell.size.height, 10, accuracy: acc)
        XCTAssertEqual(cell.rect.minX, 100, accuracy: acc)
        XCTAssertEqual(cell.rect.minY, 50, accuracy: acc)
        XCTAssertEqual(cell.rect.width, 20, accuracy: acc)
        XCTAssertEqual(cell.rect.height, 10, accuracy: acc)
        cell.cursorX = 130
        XCTAssertEqual(cell.rect.minX, 130, accuracy: acc)
        XCTAssertEqual(cell.rect.maxX, 150, accuracy: acc)
    }

    func testVerticalOffsetCentersLetterWhereverWritten() {
        let cell = makeCell()
        for y in [cell.rect.minY, cell.rect.midY - 2, cell.rect.maxY - 3] {
            let letter = CGRect(x: 0, y: y, width: 4, height: 3)
            XCTAssertEqual(letter.midY + cell.verticalOffset(for: letter), cell.rect.midY, accuracy: acc)
        }
        XCTAssertEqual(cell.verticalOffset(for: .null), 0)
    }

    // MARK: commit

    func testCommitShiftsLeftEdgeToCursorAndAdvances() {
        var cell = makeCell()
        let letter = CGRect(x: 300, y: 50, width: 15, height: 10)
        let dx = cell.commit(letter: letter)
        XCTAssertEqual(dx, -200, accuracy: acc)
        XCTAssertEqual(letter.minX + dx, 100, accuracy: acc)
        // shifted maxX = 115, plus 0.12 * 10.
        XCTAssertEqual(cell.cursorX, letter.maxX + dx + 1.2, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 116.2, accuracy: acc)
    }

    func testCommitMovesRightwardWhenLetterLeftOfCursor() {
        var cell = makeCell()
        cell.cursorX = 150
        let dx = cell.commit(letter: CGRect(x: 120, y: 0, width: 10, height: 10))
        XCTAssertEqual(dx, 30, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 150 + 10 + 1.2, accuracy: acc)
    }

    func testCommitNullLetterIsNoOp() {
        var cell = makeCell()
        cell.cursorX = 140
        let dx = cell.commit(letter: .null)
        XCTAssertEqual(dx, 0, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 140, accuracy: acc)
    }

    // MARK: space

    func testSpaceAdvancesByWordSpace() {
        var cell = makeCell()
        cell.space()
        XCTAssertEqual(cell.cursorX, 104.5, accuracy: acc)
        cell.space()
        XCTAssertEqual(cell.cursorX, 109, accuracy: acc)
        XCTAssertEqual(cell.top, 50, accuracy: acc)
    }

    // MARK: newLine

    func testNewLineDropsByPitchAndResetsCursor() {
        var cell = makeCell()
        cell.cursorX = 180
        let previousBottom = cell.rect.maxY
        cell.newLine()
        XCTAssertEqual(cell.top, 62, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 100, accuracy: acc)
        XCTAssertGreaterThan(cell.rect.minY, previousBottom)
        XCTAssertEqual(cell.margin, 100, accuracy: acc)
    }

    // MARK: wrap

    func testWrapNoOpUnderOrAtLimit() {
        var cell = makeCell()
        cell.cursorX = 150 // rect.maxX = 170
        cell.wrap(at: 200)
        XCTAssertEqual(cell.top, 50, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 150, accuracy: acc)
        cell.wrap(at: 170)
        XCTAssertEqual(cell.top, 50, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 150, accuracy: acc)
    }

    func testWrapStartsNewLineWhenOverLimit() {
        var cell = makeCell()
        cell.cursorX = 150
        cell.wrap(at: 160)
        XCTAssertEqual(cell.top, 62, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 100, accuracy: acc)
    }

    func testWrapNoOpAtMarginEvenWhenCellWiderThanLimit() {
        var cell = makeCell() // cursor at margin; rect.maxX = 120
        cell.wrap(at: 110)
        XCTAssertEqual(cell.top, 50, accuracy: acc)
        XCTAssertEqual(cell.cursorX, 100, accuracy: acc)
    }

    // MARK: setDeviceAspect

    func testSetDeviceAspect() {
        var cell = makeCell()
        cell.setDeviceAspect(3)
        XCTAssertEqual(cell.deviceAspect, 3, accuracy: acc)
        XCTAssertEqual(cell.size.width, 30, accuracy: acc)
        cell.setDeviceAspect(0)
        cell.setDeviceAspect(-1)
        XCTAssertEqual(cell.deviceAspect, 3, accuracy: acc)
    }
}
