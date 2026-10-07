import XCTest

final class HaymakerUITests: XCTestCase {
    @MainActor
    func testBoutPlaythroughAndSettingsInspection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore"]
        app.launch()

        // 1. Settings check: inspect colorblind cues and reduced motion toggles.
        let settingsButton = app.buttons["settings.open"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button exists")
        settingsButton.tap()

        let colorblindToggle = app.switches["settings.colorblind"]
        XCTAssertTrue(colorblindToggle.waitForExistence(timeout: 5), "Colorblind cues toggle exists")

        let reducedMotionToggle = app.switches["settings.reducedMotion"]
        XCTAssertTrue(reducedMotionToggle.waitForExistence(timeout: 5), "Reduced motion toggle exists")

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Done button exists")
        doneButton.tap()

        // 2. Start the bout.
        let startButton = app.buttons["bout.start"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5), "Start bout button exists")
        startButton.tap()

        // 3. Verify arena HUD elements.
        let clock = app.staticTexts["bout.clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "Bout clock exists")

        let tell = app.staticTexts["bout.tell"]
        XCTAssertTrue(tell.waitForExistence(timeout: 5), "Tell indicator exists")

        let jabButton = app.buttons["bout.jab"]
        XCTAssertTrue(jabButton.waitForExistence(timeout: 5), "One-thumb jab button exists")

        // 4. Throw punches and verify at least one punch lands.
        let landedLabel = app.staticTexts["bout.landed"]
        XCTAssertTrue(landedLabel.waitForExistence(timeout: 5), "Landed punches counter exists")

        let punchDeadline = Date().addingTimeInterval(12)
        var hasLanded = false
        while Date() < punchDeadline {
            if jabButton.isHittable {
                jabButton.tap()
            }
            if landedLabel.exists,
               let count = Int(landedLabel.label.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""),
               count > 0 {
                hasLanded = true
                break
            }
            usleep(150_000)
        }
        XCTAssertTrue(hasLanded, "Player landed at least one punch during the bout")

        // 5. Reach results card (short test bout completes in ~10 seconds).
        let resultsHeader = app.staticTexts["bout.results"]
        // The engine clock finishes the bout. Do not query a disappearing jab
        // control during the results transition (the Apple run exposed this race).
        XCTAssertTrue(resultsHeader.waitForExistence(timeout: 25),
                      "Bout ended and transitioned to the results card")
        XCTAssertTrue(app.buttons["bout.again"].exists, "Fight again button is present on the results card")
    }
    @MainActor
    func testCareerLocksDetailsAndUnknownRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestIsolatedStore"]
        app.launch()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["career.start.anvil"].isEnabled)
        XCTAssertEqual(app.buttons["opponent.detail.twitch"].label, "Twitch bio and records")
        XCTAssertEqual(app.buttons["opponent.detail.anvil"].label, "Anvil bio and records")
        app.buttons["opponent.detail.twitch"].tap()
        XCTAssertTrue(app.staticTexts["records.unknown.twitch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'restless rhythm student'")).firstMatch.exists)
    }

    @MainActor
    func testSavedCareerResultAppearsInRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore", "-haymakerUITestJabEachTick"]
        app.launch()
        app.buttons["bout.start"].tap()
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["results.pb"].exists)
        app.buttons["records.open"].tap()
        XCTAssertTrue(app.staticTexts["Career bouts 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Recorded bouts 1'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["records.unknown.twitch"].exists)
        app.buttons["Done"].tap()
        app.buttons["career.home"].tap()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["career.status.twitch"].label, "Beaten")
        XCTAssertTrue(app.buttons["career.start.anvil"].isEnabled)
    }

    @MainActor
    func testEndlessSparringKeepsOpponentAndCountsRounds() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore"]
        app.launch()
        for _ in 0..<5 {
            if app.buttons["sparring.start.twitch"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["sparring.start.twitch"].tap()
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["sparring.stats"].label.contains("Run: 1 rounds"))
        app.buttons["sparring.next"].tap()
        XCTAssertTrue(app.staticTexts["bout.clock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["sparring.stats"].label.contains("Run: 2 rounds"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Twitch •'")).firstMatch.exists)
    }

}
