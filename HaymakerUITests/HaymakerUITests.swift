import XCTest

final class HaymakerUITests: XCTestCase {
    @MainActor
    func testAdaptiveControlsStayInsideWindowAfterRotation() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestIsolatedStore", "-controlStyle", "Two hands"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["bout.start"].tap()
        dismissVersus(app)
        // The opening 3-2-1 countdown is modal: controls exist but cannot be
        // hit until the bell (CI run 39717086927). Wait for the bell via the
        // jab button's hittability, not a fixed sleep, then check the layout.
        let jab = app.buttons["bout.jab"]
        XCTAssertTrue(jab.waitForExistence(timeout: 5))
        let bellDeadline = Date().addingTimeInterval(15)
        while !jab.isHittable, Date() < bellDeadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        for landscape in [false, true] {
            settleOrientation(app, landscape: landscape)
            for id in ["bout.jab", "bout.hook", "bout.uppercut", "bout.guard", "bout.dodge", "bout.parry"] {
                let button = app.buttons[id]
                XCTAssertTrue(button.waitForExistence(timeout: 5))
                XCTAssertTrue(button.isHittable, id)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame), id)
            }
        }
    }

    @MainActor
    func testBoutPlaythroughAndSettingsInspection() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore", "-haymakerUITestJabEachTick", "-haymakerUITestStartPaused"]
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
        dismissVersus(app)

        // Inspect the HUD while paused so a short KO cannot remove it between AX queries.
        let clock = app.staticTexts["bout.clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "Bout clock exists")

        let tell = app.staticTexts["bout.tell"]
        XCTAssertTrue(tell.waitForExistence(timeout: 5), "Tell indicator exists")

        let jabButton = app.buttons["bout.jab"]
        XCTAssertTrue(jabButton.waitForExistence(timeout: 5), "One-thumb jab button exists")

        let landedLabel = app.staticTexts["bout.landed"]
        XCTAssertTrue(landedLabel.waitForExistence(timeout: 5), "Landed punches counter exists")
        let resume = app.buttons["bout.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()

        // The deterministic driver submits real jabs; inspect their durable result, not a disappearing HUD.
        let resultsHeader = app.staticTexts["bout.results"]
        XCTAssertTrue(resultsHeader.waitForExistence(timeout: 25),
                      "Bout ended and transitioned to the results card")
        let finalLanded = app.staticTexts["results.landed"]
        XCTAssertTrue(finalLanded.waitForExistence(timeout: 5))
        let count = try XCTUnwrap(finalLanded.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first,
                                 "Results report a numeric landed-punch count")
        XCTAssertGreaterThan(count, 0, "Player landed at least one punch during the bout")
        XCTAssertTrue(app.buttons["bout.again"].exists, "Fight again button is present on the results card")
    }

    @MainActor
    func testTitleAndSeparateCareerScreenInBothOrientations() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestIsolatedStore"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for landscape in [false, true] {
            settleOrientation(app, landscape: landscape)
            let start = app.buttons["bout.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            XCTAssertTrue(start.isHittable)
            XCTAssertLessThanOrEqual(start.frame.width, 401)
            XCTAssertFalse(app.scrollViews["career.scroll"].exists)
            XCTAssertTrue(app.staticTexts["HAYMAKER"].exists)
            app.buttons["career.open"].tap()
            XCTAssertTrue(app.scrollViews["career.scroll"].waitForExistence(timeout: 5))
            XCTAssertFalse(start.exists)
            XCTAssertTrue(app.buttons["settings.open"].isHittable)
            app.buttons["career.back"].tap()
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = landscape ? "Shadowboxing title landscape" : "Shadowboxing title portrait"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testCareerLocksDetailsAndUnknownRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestIsolatedStore"]
        app.launch()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        app.buttons["career.open"].tap()
        XCTAssertTrue(app.scrollViews["career.scroll"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["career.start.nico"].isEnabled)
        app.buttons["opponent.detail.goldie"].tap()
        XCTAssertTrue(app.staticTexts["records.unknown.goldie"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSavedCareerResultAppearsInRecords() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore", "-haymakerUITestJabEachTick"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        app.buttons["bout.start"].tap()
        dismissVersus(app)
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["results.pb"].waitForExistence(timeout: 5))
        let home = app.buttons["career.home"]
        for _ in 0..<4 where !home.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(home.isHittable, "Career return remains reachable on compact screens")
        home.tap()
        app.buttons["records.open"].tap()
        XCTAssertTrue(app.staticTexts["Career bouts 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["records.unknown.goldie"].exists)
        app.buttons["Done"].tap()
        XCTAssertEqual(app.staticTexts["career.status.goldie"].label, "Beaten")
        XCTAssertTrue(app.buttons["career.start.nico"].isEnabled)
    }

    @MainActor
    func testDefeatedPortraitsSurpriseNextFightAndCareerFinale() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore", "-haymakerUITestJabEachTick"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        app.buttons["bout.start"].tap()
        let roster = ["goldie", "nico", "atlas", "vera", "duke", "sylvie", "cassian", "jaison", "hunter", "baxter"]
        let bouts = roster.count + 1
        for (index, id) in roster.enumerated() {
            XCTAssertTrue(app.images["versus.portrait.\(id)"].waitForExistence(timeout: 5))
            dismissVersus(app)
            if index == roster.count - 1 { break }
            XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
            XCTAssertTrue(app.images["results.portrait.\(id)"].exists, "Show the defeated fighter, not their intro portrait")
            XCTAssertFalse(app.staticTexts["career.victory"].exists)
            if index == 0 {
                let rematch = app.buttons["bout.again"]
                scrollToButton(rematch, in: app)
                rematch.tap()
                XCTAssertTrue(app.images["versus.portrait.goldie"].waitForExistence(timeout: 5))
                dismissVersus(app)
                XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
                XCTAssertTrue(app.images["results.portrait.goldie"].exists)
            }
            settleOrientation(app, landscape: index.isMultiple(of: 2))
            let next = app.buttons["career.next"]
            scrollToButton(next, in: app)
            XCTAssertEqual(next.label, "NEXT FIGHT", "Do not reveal the next opponent in the button or its accessibility label")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Defeated \(id)"
            shot.lifetime = .keepAlways
            add(shot)
            next.tap()
        }
        XCTAssertTrue(app.staticTexts["career.victory"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.staticTexts["bout.results"].exists, "The last win opens the career finale instead of another bout card")
        XCTAssertFalse(app.buttons["career.next"].exists)
        XCTAssertFalse(app.buttons["bout.again"].exists)
        for landscape in [false, true] {
            settleOrientation(app, landscape: landscape)
            let endGame = app.buttons["career.endGame"]
            scrollToButton(endGame, in: app)
            XCTAssertTrue(app.frame.contains(endGame.frame), "The full End game button stays on screen in both orientations")
            XCTAssertGreaterThanOrEqual(endGame.frame.height, 44)
            XCTAssertTrue(app.staticTexts["career.victory.wins"].label.contains("\(bouts)/\(bouts)"), "Final stats include the rematch")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = landscape ? "Career finale landscape" : "Career finale portrait"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.buttons["career.endGame"].tap()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["career.victory"].exists)
        app.buttons["career.open"].tap()
        XCTAssertEqual(app.staticTexts["career.status.goldie"].label, "Ready")
        XCTAssertFalse(app.buttons["career.start.nico"].isEnabled)
        app.buttons["records.open"].tap()
        XCTAssertTrue(app.staticTexts["Career bouts \(bouts)"].waitForExistence(timeout: 5), "End game preserves the local ledger")
    }

    @MainActor
    private func scrollToButton(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<8 where !button.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(button.isHittable)
    }

    @MainActor
    func testEndlessSparringKeepsOpponentAndCountsRounds() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        app.buttons["career.open"].tap()
        let spar = app.buttons["sparring.start.goldie"]
        let ladder = app.scrollViews["career.scroll"]
        XCTAssertTrue(ladder.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if spar.exists && spar.isHittable { break }
            ladder.swipeUp()
        }
        XCTAssertTrue(spar.isHittable, "Sparring action must become visible in ladder scroller")
        spar.tap()
        dismissVersus(app)
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["sparring.stats"].label.contains("Run: 1 rounds"))
        app.buttons["sparring.next"].tap()
        dismissVersus(app)
        XCTAssertTrue(app.staticTexts["bout.clock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["sparring.stats"].label.contains("Run: 2 rounds"))
    }

    @MainActor
    func testNonDefaultOpponentsReachLiveSparringBouts() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["career.open"].waitForExistence(timeout: 5))
        app.buttons["career.open"].tap()
        let ladder = app.scrollViews["career.scroll"]
        // Capture every opponent with a supplied UV texture; Mack is on the title screen.
        for id in ["goldie", "nico", "atlas", "vera", "duke", "sylvie", "cassian", "jaison", "hunter", "baxter"] {
            XCTAssertTrue(ladder.waitForExistence(timeout: 5))
            let spar = app.buttons["sparring.start.\(id)"]
            for _ in 0..<15 {
                if spar.exists && spar.isHittable { break }
                ladder.swipeUp()
            }
            XCTAssertTrue(spar.isHittable)
            spar.tap()
            XCTAssertTrue(app.staticTexts["versus.opponent"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["versus.portrait.\(id)"].exists)
            let bell = app.buttons["versus.fight"].firstMatch
            XCTAssertTrue(bell.waitForExistence(timeout: 5))
            XCTAssertTrue(bell.isHittable)
            bell.tap()
            XCTAssertTrue(app.staticTexts["bout.clock"].waitForExistence(timeout: 5),
                          "Live bout started against \(id)")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Live bout \(id)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
            let next = app.buttons["sparring.next"]
            for _ in 0..<8 where !next.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(next.isHittable)
            next.tap()
            XCTAssertTrue(app.staticTexts["versus.opponent"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["versus.portrait.\(id)"].exists)
            app.buttons["versus.cancel"].tap()
            XCTAssertTrue(ladder.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func dismissVersus(_ app: XCUIApplication) {
        let bell = app.buttons["versus.fight"]
        XCTAssertTrue(bell.waitForExistence(timeout: 5))
        bell.tap()
    }

    @MainActor
    func testVersusWaitsForBellAndReturnsOnRematch() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestIsolatedStore"]
        app.launch()
        app.buttons["bout.start"].tap()
        XCTAssertTrue(app.staticTexts["versus.opponent"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["versus.opponent"].label, "GOLDIE VOLTAGE")
        XCTAssertTrue(app.staticTexts["versus.taunt"].label.contains("spare change"))
        XCTAssertFalse(app.buttons["bout.jab"].exists)
        let portraitShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portraitShot.name = "Versus portrait close-up portrait"
        portraitShot.lifetime = .keepAlways
        add(portraitShot)
        Thread.sleep(forTimeInterval: 11)
        XCTAssertFalse(app.staticTexts["bout.results"].exists)
        XCTAssertTrue(app.buttons["versus.fight"].isHittable)
        settleOrientation(app, landscape: true)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertFalse(app.scrollViews.firstMatch.exists, "Landscape versus screen should fit without a scroll view")
        XCTAssertTrue(app.buttons["versus.fight"].isHittable)
        XCTAssertTrue(app.buttons["versus.cancel"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Versus portrait close-up landscape"
        shot.lifetime = .keepAlways
        add(shot)
        dismissVersus(app)
        XCTAssertTrue(app.staticTexts["bout.clock"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["bout.results"].exists, "Waiting at the versus screen must not consume the bout")
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
        let again = app.buttons["bout.again"]
        XCTAssertFalse(app.scrollViews.firstMatch.exists, "Landscape results should fit without a scroll view")
        XCTAssertTrue(again.isHittable, "Rematch button fits on screen in landscape without scrolling")
        XCTAssertTrue(app.buttons["career.home"].isHittable, "Career ladder button fits on screen in landscape without scrolling")
        again.tap()
        XCTAssertTrue(app.staticTexts["versus.opponent"].waitForExistence(timeout: 5))
        app.buttons["versus.cancel"].tap()
        XCTAssertTrue(app.buttons["bout.start"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFightStartsWithThreeTwoOneCountdown() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestShortBout", "-haymakerUITestCountdown", "-haymakerUITestIsolatedStore"]
        app.launch()
        app.buttons["bout.start"].tap()
        dismissVersus(app)
        let countdown = app.staticTexts["bout.countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 2), "A 3-2-1 countdown gates the opening bell")
        XCTAssertFalse(app.staticTexts["bout.results"].exists)
        // The countdown ends on its own and the fight carries on to the results card.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: countdown)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(app.staticTexts["bout.results"].waitForExistence(timeout: 25))
    }

    @MainActor
    func testEveryStoryOpponentHasAnIntroduction() {
        let app = XCUIApplication()
        app.launchArguments = ["-haymakerUITestIsolatedStore"]
        app.launch()
        app.buttons["career.open"].tap()
        let ladder = app.scrollViews["career.scroll"]
        for id in ["goldie", "nico", "atlas", "vera", "duke", "sylvie", "cassian", "jaison", "hunter", "baxter"] {
            let spar = app.buttons["sparring.start.\(id)"]
            for _ in 0..<15 {
                if spar.exists && spar.isHittable { break }
                ladder.swipeUp()
            }
            XCTAssertTrue(spar.isHittable)
            spar.tap()
            XCTAssertTrue(app.staticTexts["versus.opponent"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["versus.portrait.\(id)"].exists)
            XCTAssertTrue(app.staticTexts["versus.taunt"].exists)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Versus \(id)"
            shot.lifetime = .keepAlways
            add(shot)
            app.buttons["versus.cancel"].tap()
            XCTAssertTrue(ladder.waitForExistence(timeout: 5))
        }
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
        dismissVersus(app)
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
