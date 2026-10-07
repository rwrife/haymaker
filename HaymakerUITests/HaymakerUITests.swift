import XCTest

final class HaymakerUITests: XCTestCase {
    @MainActor
    func testBoutPlaythroughAndSettingsInspection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-haymakerUITestShortBout"]
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
    func testMetalArenaLandscapePauseAndControls() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        app.buttons["bout.start"].tap()
        XCTAssertTrue(app.staticTexts["bout.clock"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["bout.guard"].waitForExistence(timeout: 5))
        app.buttons["bout.guard"].tap()
        app.buttons["bout.dodge"].tap()
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Game fills landscape")
        XCTAssertTrue(app.buttons["bout.jab"].isHittable)
        XCTAssertTrue(app.buttons["bout.dodge"].isHittable)
        let arena = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        arena.name = "Metal arena landscape"
        arena.lifetime = .keepAlways
        add(arena)
        app.buttons["bout.pause"].tap()
        XCTAssertTrue(app.buttons["bout.resume"].waitForExistence(timeout: 3))
        let stoppedClock = app.staticTexts["bout.clock"].label
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(app.staticTexts["bout.clock"].label, stoppedClock, "Pause freezes the engine clock")
        app.buttons["bout.resume"].tap()
        XCTAssertTrue(app.buttons["bout.jab"].waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertGreaterThan(app.frame.height, app.frame.width, "Game returns to portrait")
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Metal arena portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
    }

}
