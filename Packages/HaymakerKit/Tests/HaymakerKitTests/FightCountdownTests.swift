import Testing
@testable import HaymakerKit

@Suite("FightCountdown: the 3-2-1 beat")
struct FightCountdownTests {
    @Test("starts on 3 and is not finished")
    func startsOnThree() {
        let countdown = FightCountdown()
        #expect(countdown.value == 3)
        #expect(!countdown.isFinished)
        #expect(countdown.stepProgress == 0)
    }

    @Test("counts 3, 2, 1 then finishes")
    func countsDown() {
        var countdown = FightCountdown(from: 3, stepSeconds: 1)
        #expect(countdown.value == 3)
        countdown.advance(by: 1.01)
        #expect(countdown.value == 2)
        countdown.advance(by: 1.0)
        #expect(countdown.value == 1)
        countdown.advance(by: 1.0)
        #expect(countdown.value == nil)
        #expect(countdown.isFinished)
        #expect(countdown.stepProgress == 1)
    }

    @Test("a long frame clamps at the end and never overshoots")
    func clampsOnLongFrame() {
        var countdown = FightCountdown()
        countdown.advance(by: 60)
        #expect(countdown.isFinished)
        #expect(countdown.elapsed == countdown.totalSeconds)
        #expect(countdown.value == nil)
    }

    @Test("negative time is ignored")
    func ignoresNegativeTime() {
        var countdown = FightCountdown()
        countdown.advance(by: -5)
        #expect(countdown.elapsed == 0)
        #expect(countdown.value == 3)
    }

    @Test("step progress runs 0 to 1 within each number")
    func stepProgressWithinNumber() {
        var countdown = FightCountdown(from: 3, stepSeconds: 1)
        countdown.advance(by: 0.5)
        #expect(abs(countdown.stepProgress - 0.5) < 0.0001)
        countdown.advance(by: 1.0)
        #expect(countdown.value == 2)
        #expect(abs(countdown.stepProgress - 0.5) < 0.0001)
    }

    @Test("default cadence is three beats of 0.9s")
    func defaultCadence() {
        let countdown = FightCountdown()
        #expect(countdown.from == 3)
        #expect(abs(countdown.totalSeconds - 2.7) < 0.0001)
    }

    @Test("knockdown count spreads 3, 2, 1 across the whole window")
    func knockdownCountSpansWindow() {
        // 90-tick window (the default): 30 ticks per number.
        #expect(FightCountdown.knockdownValue(elapsedTicks: 0, windowTicks: 90) == 3)
        #expect(FightCountdown.knockdownValue(elapsedTicks: 29, windowTicks: 90) == 3)
        #expect(FightCountdown.knockdownValue(elapsedTicks: 30, windowTicks: 90) == 2)
        #expect(FightCountdown.knockdownValue(elapsedTicks: 59, windowTicks: 90) == 2)
        #expect(FightCountdown.knockdownValue(elapsedTicks: 60, windowTicks: 90) == 1)
        #expect(FightCountdown.knockdownValue(elapsedTicks: 89, windowTicks: 90) == 1)
    }

    @Test("knockdown count is absent outside the window")
    func knockdownCountOutsideWindow() {
        #expect(FightCountdown.knockdownValue(elapsedTicks: 90, windowTicks: 90) == nil)
        #expect(FightCountdown.knockdownValue(elapsedTicks: -1, windowTicks: 90) == nil)
        #expect(FightCountdown.knockdownValue(elapsedTicks: 0, windowTicks: 0) == nil)
        #expect(FightCountdown.knockdownStepProgress(elapsedTicks: 90, windowTicks: 90) == nil)
    }

    @Test("knockdown count never skips or repeats a number as ticks advance")
    func knockdownCountIsMonotonic() {
        for window in [1, 2, 3, 7, 90, 241] {
            var last = 3
            for tick in 0..<window {
                let value = FightCountdown.knockdownValue(elapsedTicks: tick, windowTicks: window)
                #expect(value != nil)
                #expect((value ?? 0) <= last)
                #expect((value ?? 0) >= 1)
                last = value ?? last
            }
        }
    }

    @Test("knockdown step progress restarts at each number")
    func knockdownStepProgress() {
        #expect(FightCountdown.knockdownStepProgress(elapsedTicks: 0, windowTicks: 90) == 0)
        #expect(FightCountdown.knockdownStepProgress(elapsedTicks: 30, windowTicks: 90) == 0)
        let mid = FightCountdown.knockdownStepProgress(elapsedTicks: 15, windowTicks: 90) ?? -1
        #expect(abs(mid - 0.5) < 0.0001)
    }

    @Test("degenerate inputs are sanitized")
    func sanitizesInputs() {
        let countdown = FightCountdown(from: 0, stepSeconds: 0)
        #expect(countdown.from == 1)
        #expect(countdown.stepSeconds > 0)
        #expect(countdown.value == 1)
    }
}
