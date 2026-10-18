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

    @Test("degenerate inputs are sanitized")
    func sanitizesInputs() {
        let countdown = FightCountdown(from: 0, stepSeconds: 0)
        #expect(countdown.from == 1)
        #expect(countdown.stepSeconds > 0)
        #expect(countdown.value == 1)
    }
}
