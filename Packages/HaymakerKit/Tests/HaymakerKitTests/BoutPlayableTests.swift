import Testing
import HaymakerKit
@testable import HaymakerKit

@Suite("BoutPlayableEngineTests")
struct BoutPlayableEngineTests {
    @Test("Short UI-test bout configuration completes deterministically and verifies replay")
    func shortBoutDeterminism() {
        let config = EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0)
        var engine = FightEngine(config: config, seed: 0xCAFE_2026, book: .twitch)
        var inputLog: [PlayerInput] = []

        for _ in 0..<700 {
            if engine.isOver { break }
            let input: PlayerInput = .jab
            inputLog.append(input)
            engine.tick(input)
        }

        #expect(engine.isOver)
        #expect(engine.playerStats.thrown > 0)
        #expect(engine.playerStats.landed > 0)

        // Verify that exact replay reproduces identical outcome and events.
        let replay = FightEngine.simulate(
            config: config,
            seed: 0xCAFE_2026,
            book: .twitch,
            inputs: inputLog
        )
        #expect(replay.outcome == engine.outcome)
        #expect(replay.playerStats.landed == engine.playerStats.landed)
        #expect(replay.events == engine.events)
    }

    @Test("One-thumb control vector resolution maps gestures correctly")
    func oneThumbVectorMapping() {
        #expect(ControlInput.resolve(dx: 0, dy: 0) == .jab)
        #expect(ControlInput.resolve(dx: 5, dy: -5) == .jab)
        #expect(ControlInput.resolve(dx: -45, dy: 0) == .hook)
        #expect(ControlInput.resolve(dx: 0, dy: -50) == .uppercut)
        #expect(ControlInput.resolve(dx: 45, dy: 0) == .dodge)
        #expect(ControlInput.resolve(dx: 0, dy: 45) == .block)
    }
}

