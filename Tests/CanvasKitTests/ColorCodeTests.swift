import XCTest
@testable import CanvasKit

final class ColorCodeTests: XCTestCase {
    func testForegroundContrastFollowsBackgroundBrightness() throws {
        for code in ["#000000", "#213040", "#666666", "#0000FF"] {
            XCTAssertTrue(try XCTUnwrap(RGBA(colorCode: code)).prefersLightForeground, code)
        }
        for code in ["#FFFFFF", "#808080", "#FFFF00", "#00FF00"] {
            XCTAssertFalse(try XCTUnwrap(RGBA(colorCode: code)).prefersLightForeground, code)
        }
    }

    func testCommonColorCodes() throws {
        for code in ["#f80", "FF8800", "0xFF8800", "rgb(255, 136, 0)", "rgb(255 136 0)"] {
            XCTAssertEqual(try XCTUnwrap(RGBA(colorCode: code)).hexCode, "#FF8800", code)
        }
        for code in ["#f808", "#FF880088", "rgba(255, 136, 0, 0.5333333333)"] {
            XCTAssertEqual(try XCTUnwrap(RGBA(colorCode: code)).hexCode, "#FF880088", code)
        }
        XCTAssertEqual(RGBA(colorCode: " rgb(100% 0% 0% / 50%) ")?.hexCode, "#FF000080")
    }

    func testBackgroundColorPersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let settings = CanvasSettings()
        let persistence = SettingsPersistence(settings: settings, defaults: defaults)
        settings.backgroundColor = try XCTUnwrap(RGBA(colorCode: "#213040"))
        let restored = CanvasSettings()
        let restoredPersistence = SettingsPersistence(settings: restored, defaults: defaults)
        XCTAssertEqual(restored.backgroundColor, settings.backgroundColor)
        withExtendedLifetime((persistence, restoredPersistence)) {}
    }

    func testSavedColorSlotsPersistWithoutMovingOtherSlots() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CanvasSettings()
        let persistence = SettingsPersistence(settings: settings, defaults: defaults)
        settings.savedColors[1] = try XCTUnwrap(RGBA(colorCode: "#123456"))
        settings.savedColors[4] = try XCTUnwrap(RGBA(colorCode: "rgba(255, 0, 0, 0.5)"))
        settings.savedColors[1] = try XCTUnwrap(RGBA(colorCode: "#ABCDEF"))
        let restored = CanvasSettings()
        let restoredPersistence = SettingsPersistence(settings: restored, defaults: defaults)
        XCTAssertEqual(restored.savedColors, settings.savedColors)
        XCTAssertEqual(restored.savedColors[1]?.hexCode, "#ABCDEF")
        XCTAssertNil(restored.savedColors[0])
        XCTAssertNil(restored.savedColors[2])
        XCTAssertNil(restored.savedColors[3])
        withExtendedLifetime((persistence, restoredPersistence)) {}
    }

    func testMalformedSavedColorSlotCountKeepsEmptySlots() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([RGBA.black]), forKey: "settings.savedColors")
        let settings = CanvasSettings()
        let persistence = SettingsPersistence(settings: settings, defaults: defaults)
        XCTAssertEqual(settings.savedColors.count, 5)
        XCTAssertTrue(settings.savedColors.allSatisfy { $0 == nil })
        withExtendedLifetime(persistence) {}
    }

    func testRejectsInvalidColors() {
        for code in ["", "#12", "#GGGGGG", "rgb(256, 0, 0)", "rgb(-1, 0, 0)",
                     "rgb(1,,2)", "rgba(1,2,3)", "rgb(1 2 3 / 2)", "rgb(nan, 0, 0)",
                     "rgb(1 2 3 // .5)", "rgb(1,2,3) trailing"] {
            XCTAssertNil(RGBA(colorCode: code), code)
        }
    }
}
