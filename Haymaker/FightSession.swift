import Foundation
import Observation
import HaymakerKit

/// The only owner of mutable rules state. The scene reads snapshots; it never ticks the engine.
@MainActor @Observable final class FightSession {
    private(set) var engine: FightEngine
    private(set) var inputLog: [PlayerInput] = []
    private(set) var lastEvent: FightEvent?
    private var pending: [PlayerInput] = []

    init(seed: UInt64 = 0xCAFE_2026, shortUITestBout: Bool = false) {
        let config = shortUITestBout
            ? EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0)
            : EngineConfig(roundTicks: 10800, restTicks: 240, dodgeTicks: 20)
        engine = FightEngine(config: config, seed: seed, book: shortUITestBout ? .twitch : .baxter)
    }

    func submit(_ input: PlayerInput) {
        guard !engine.isOver else { return }
        // Bound input buffering so rapid touch events cannot queue stale attacks for minutes.
        if pending.count < 4 { pending.append(input) }
    }

    func advance() {
        guard !engine.isOver else { return }
        let input = pending.isEmpty ? PlayerInput.none : pending.removeFirst()
        inputLog.append(input)
        let eventCount = engine.events.count
        var fighting = engine
        fighting.tick(input)
        engine = fighting // explicit reassignment so @Observable notifies
        if engine.events.count > eventCount {
            lastEvent = engine.events.last
        }
    }

    var replayMatches: Bool {
        guard engine.isOver else { return false }
        let replay = FightEngine.simulate(
            config: engine.config, seed: engine.seed, book: engine.book, inputs: inputLog
        )
        return replay.outcome == engine.outcome && replay.playerStats.landed == engine.playerStats.landed
            && replay.events == engine.events
    }
}
