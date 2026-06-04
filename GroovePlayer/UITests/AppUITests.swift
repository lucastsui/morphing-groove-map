// XCUITest flows driving the SwiftUI app on a simulator: tab navigation, the
// MIDI 1.0/2.0 toggle, the Edit→step-button gating, and the .MGM slot list.
// The iPad top tab bar can surface a label as more than one element, so taps
// use `.firstMatch` and assertions use `waitForExistence`.
import XCTest

final class AppUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    private func tapTab(_ name: String) {
        let b = app.buttons[name].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 8), "tab '\(name)' not found")
        b.tap()
    }

    private func containsText(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    func testTabsNavigate() {
        XCTAssertTrue(app.staticTexts["MIDI version"].waitForExistence(timeout: 8))   // Welcome
        tapTab(".STT beats")
        XCTAssertTrue(app.staticTexts["Select Current Beat"].waitForExistence(timeout: 5))
        tapTab(".MGM")
        XCTAssertTrue(app.staticTexts["Slot files"].waitForExistence(timeout: 5))
        tapTab("Generate")
        XCTAssertTrue(app.staticTexts["Import"].waitForExistence(timeout: 5))         // GroupBox label
    }

    func testMIDIToggleUpdatesRange() {
        XCTAssertTrue(app.staticTexts["MIDI version"].waitForExistence(timeout: 8))
        app.buttons["MIDI 2.0"].firstMatch.tap()
        XCTAssertTrue(containsText("16-bit").waitForExistence(timeout: 5))
        app.buttons["MIDI 1.0"].firstMatch.tap()
        XCTAssertTrue(containsText("7-bit").waitForExistence(timeout: 5))
    }

    func testEditEnablesStepButtons() {
        tapTab(".STT beats")
        let plus128 = app.buttons["+128"].firstMatch
        XCTAssertTrue(plus128.waitForExistence(timeout: 8))
        XCTAssertFalse(plus128.isEnabled)            // disabled until Edit
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(plus128.isEnabled)
        app.buttons["beat-2"].firstMatch.tap()       // selecting a beat shouldn't crash
    }

    func testMGMShowsDefaultSlots() {
        tapTab(".MGM")
        XCTAssertTrue(app.staticTexts["Slot files"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["No Swing"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Amen Break.STT"].firstMatch.exists)
    }
}
