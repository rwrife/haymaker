import XCTest

final class HaymakerUITests: XCTestCase {
    @MainActor
    func testBoutPlaythroughAndSettingsInspection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore", "-haymakerUITestJabEachTick"]
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
        app.buttons["opponent.detail.twitch"].tap()
        XCTAssertTrue(app.staticTexts["records.unknown.twitch"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSavedCareerResultAppearsInRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore", "-haymakerUITestJabEachTick"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        app.buttons["bout.start"].tap()
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["results.pb"].waitForExistence(timeout: 5))
        let home = app.buttons["career.home"]
        for _ in 0..<4 where !home.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(home.isHittable, "Career return remains reachable on compact screens")
        home.tap()
        app.buttons["records.open"].tap()
        XCTAssertTrue(app.staticTexts["Career bouts 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["records.unknown.twitch"].exists)
        app.buttons["Done"].tap()
        XCTAssertEqual(app.staticTexts["career.status.twitch"].label, "Beaten")
        XCTAssertTrue(app.buttons["career.start.anvil"].isEnabled)
    }

    @MainActor
    func testEndlessSparringKeepsOpponentAndCountsRounds() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let spar = app.buttons["sparring.start.twitch"]
        let ladder = app.scrollViews["career.scroll"]
        XCTAssertTrue(ladder.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if spar.exists && spar.isHittable { break }
            ladder.swipeUp()
        }
        XCTAssertTrue(spar.isHittable, "Sparring action must become visible in ladder scroller")
        spar.tap()
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["sparring.stats"].label.contains("Run: 1 rounds"))
        app.buttons["sparring.next"].tap()
        XCTAssertTrue(app.staticTexts["bout.clock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["sparring.stats"].label.contains("Run: 2 rounds"))
    }

    // Rotation re-creates the SwiftUI controls (the portrait flag flips with the
    // geometry), which invalidates any element XCUI found mid-animation. Never
    // touch a control until the frame settles in the requested orientation.
    @MainActor
    private func settleOrientation(_ app: XCUIApplication, landscape: Bool) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        var stableReads = 0
        for _ in 0..<16 {
            if (app.frame.width > app.frame.height) == landscape {
                stableReads += 1
                if stableReads >= 2 { return }
            } else {
                stableReads = 0
                XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThanOrEqual(stableReads, 2, "Orientation never settled")
    }

    @MainActor
    func testMetalArenaLandscapePauseAndControls() throws {
        let app = XCUIApplication()
        // Start with the engine frozen (paused): a live short bout ends mid-test
        // and the results card swallows the pause menu (CI run 38942392854).
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestStartPaused"]
        app.launch()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        app.buttons["bout.start"].tap()
        XCTAssertTrue(app.staticTexts["bout.clock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bout.resume"].waitForExistence(timeout: 5))
        settleOrientation(app, landscape: true)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Game fills landscape")
        let arena = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        arena.name = "Metal arena landscape paused"
        arena.lifetime = .keepAlways
        add(arena)
        let stoppedClock = app.staticTexts["bout.clock"].label
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(app.staticTexts["bout.clock"].label, stoppedClock, "Pause freezes the engine clock")
        app.buttons["bout.resume"].tap()
        XCTAssertTrue(app.buttons["bout.jab"].waitForExistence(timeout: 3))
        settleOrientation(app, landscape: false)
        XCTAssertGreaterThan(app.frame.height, app.frame.width, "Game returns to portrait")
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Metal arena portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
    }

}
