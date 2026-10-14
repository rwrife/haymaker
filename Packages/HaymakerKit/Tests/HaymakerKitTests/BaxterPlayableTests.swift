import Testing
@testable import HaymakerKit

@Suite("Baxter arcade bout")
struct BaxterPlayableTests {
    @Test("Reading windups and breaking guards wins the new bout and replays exactly")
    func counterStrategy() {
        let config = EngineConfig(roundTicks: 10800, restTicks: 240, dodgeTicks: 20)
        var engine = FightEngine(config: config, seed: 0xCAFE_2026, book: .baxter)
        var inputs: [PlayerInput] = []
        while !engine.isOver && inputs.count < config.hardTickCap {
            let input: PlayerInput
            if engine.player.state != .idle { input = .none }
            else if engine.opponent.state == .blocking { input = .uppercut }
            else if engine.opponent.state == .telling && engine.opponent.currentMove != .feint { input = .jab }
            else if engine.opponent.state == .attacking { input = .dodge }
            else { input = .none }
            inputs.append(input)
            engine.tick(input)
        }
        #expect(engine.outcome?.isPlayerWin == true)
        #expect(engine.playerStats.counters > 0)
        let replay = FightEngine.simulate(config: config, seed: engine.seed, book: .baxter, inputs: inputs)
        #expect(replay.events == engine.events)
        #expect(replay.outcome == engine.outcome)
        #expect(replay.playerStats == engine.playerStats)
    }
}
