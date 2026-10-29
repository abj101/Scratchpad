import XCTest
@testable import CanvasKit

final class ScribeWidthTests: XCTestCase {
    func testDefaultWidthAndPersistence() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CanvasSettings()
        XCTAssertEqual(settings.scribeDefaultWidth, 10)
        let persistence = SettingsPersistence(settings: settings, defaults: defaults)
        settings.scribeDefaultWidth = 12.5
        let restored = CanvasSettings()
        let restoredPersistence = SettingsPersistence(settings: restored, defaults: defaults)
        XCTAssertEqual(restored.scribeDefaultWidth, 12.5)
        withExtendedLifetime((persistence, restoredPersistence)) {}
    }

    func testInvalidStoredWidthsKeepDefault() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in [-10.0, 0.0, 101.0, Double.nan, Double.infinity] {
            defaults.set(value, forKey: "settings.scribeDefaultWidth")
            let settings = CanvasSettings()
            let persistence = SettingsPersistence(settings: settings, defaults: defaults)
            XCTAssertEqual(settings.scribeDefaultWidth, 10)
            withExtendedLifetime(persistence) {}
        }
    }

    func testScribeStartsAtDefaultAndRestoresDrawingWidth() throws {
        try XCTSkipUnless(InputMode.scribe.isAvailable)
        let settings = CanvasSettings()
        settings.width = 3
        settings.handwritingToText = true
        let view = CanvasView(model: CanvasModel(), settings: settings)
        settings.inputMode = .write // Write toolbar choice enters Scribe with conversion on.
        defer { settings.inputMode = .pen; withExtendedLifetime(view) {} }
        XCTAssertEqual(settings.width, 10)
        settings.width = 15 // An in-session adjustment doesn't overwrite the default.
        settings.inputMode = .pen
        XCTAssertEqual(settings.width, 3)
        XCTAssertEqual(settings.scribeDefaultWidth, 10)
        settings.scribeDefaultWidth = 12.5
        settings.inputMode = .scribe
        XCTAssertEqual(settings.width, 12.5)
        settings.inputMode = .pen
        XCTAssertEqual(settings.width, 3)
    }
}
