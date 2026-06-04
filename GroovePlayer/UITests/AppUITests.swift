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

    private func tapIfHittable(_ id: String, timeout: TimeInterval = 2) {
        let b = app.buttons[id].firstMatch
        if b.waitForExistence(timeout: timeout) && b.isHittable { b.tap() }
    }

    /// Broad "play around" sweep — drives the crash-prone actions (audio render,
    /// on-device extraction, file export, step buttons, slot add/delete, field
    /// edits) and asserts the app is still alive at the end.
    func testSmokeNoCrashAcrossActions() {
        XCTAssertTrue(app.staticTexts["MIDI version"].waitForExistence(timeout: 8))
        tapIfHittable("MIDI 2.0"); tapIfHittable("MIDI 1.0")

        // Generate: extraction + audio + export.
        tapTab("Generate")
        tapIfHittable("Analyze Amen", timeout: 4)
        tapIfHittable("Play current groove")
        tapIfHittable("Play target")
        tapIfHittable("Export .STT")
        tapIfHittable("Export .MGM")

        // .STT full: render the all-beats overview (after analysis changed the data).
        tapTab(".STT full")
        XCTAssertTrue(app.staticTexts["All beats (display only)"].waitForExistence(timeout: 4))

        // .STT beats: edit, nudge with several step buttons, select a beat, preview.
        tapTab(".STT beats")
        tapIfHittable("Edit")
        for label in ["+1024", "+128", "+16", "+1", "0", "+10", "+.1", "+1/4", "+1/2", "+1"] {
            tapIfHittable(label)
        }
        app.buttons["beat-5"].firstMatch.tap()
        tapIfHittable("Preview")

        // .MGM: add the current .STT to a slot, then delete a slot.
        tapTab(".MGM")
        tapIfHittable("addToSlot")
        tapIfHittable("deleteSlot")

        // Light field edit (project settings).
        let tempo = app.textFields["tempo"].firstMatch
        if tempo.waitForExistence(timeout: 2) { tempo.tap(); tempo.typeText("0") }

        tapTab("Welcome")
        XCTAssertTrue(app.staticTexts["MIDI version"].waitForExistence(timeout: 8),
                      "app appears to have crashed during the interaction sweep")
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
