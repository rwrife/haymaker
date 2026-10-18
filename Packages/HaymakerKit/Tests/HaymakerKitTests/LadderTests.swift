import Testing
@testable import HaymakerKit

extension SeededRNG: RandomNumberGenerator {}

@Suite("Session ladder")
struct LadderTests {
    @Test func containsEveryStoryOpponentOnceWithBossLast() {
        for seed in UInt64(1)...50 {
            var rng = SeededRNG(seed: seed &* 0x9E37_79B9_7F4A_7C15)
            let ladder = Ladder.make(using: &rng)
            #expect(ladder.count == OpponentBook.careerRoster.count)
            #expect(Set(ladder.map(\.id)) == Set(OpponentBook.careerRoster.map(\.id)))
            #expect(ladder.last?.id == "baxter")
        }
    }

    @Test func sameSeedSameOrderAndSeedsDiffer() {
        var a = SeededRNG(seed: 7), b = SeededRNG(seed: 7)
        #expect(Ladder.make(using: &a) == Ladder.make(using: &b))
        let orders = (UInt64(1)...30).map { seed -> [String] in
            var rng = SeededRNG(seed: seed &* 0x9E37_79B9_7F4A_7C15)
            return Ladder.order(using: &rng).map(\.id)
        }
        #expect(Set(orders).count > 1)
        #expect(orders.contains { $0 != OpponentBook.careerRoster.map(\.id) })
    }

    @Test func everyContenderCanOpenTheLadder() {
        var openers = Set<String>()
        for seed in UInt64(1)...200 {
            var rng = SeededRNG(seed: seed &* 0x9E37_79B9_7F4A_7C15)
            openers.insert(Ladder.order(using: &rng)[0].id)
        }
        #expect(openers == Set(Ladder.contenders.map(\.id)))
    }

    @Test func difficultyRisesAcrossStages() {
        for book in OpponentBook.careerRoster {
            let easy = pressure(book.scaled(difficulty: 0))
            let middle = pressure(book.scaled(difficulty: 0.5))
            let hard = pressure(book.scaled(difficulty: 1))
            #expect(easy < middle, "\(book.id) middle stage is not harder than the first")
            #expect(middle < hard, "\(book.id) last stage is not harder than the middle")
        }
    }

    @Test func scalingKeepsIdentityAndReadableTells() {
        for book in OpponentBook.careerRoster {
            for difficulty in [0.0, 0.5, 1.0] {
                let scaled = book.scaled(difficulty: difficulty)
                #expect(scaled.id == book.id && scaled.name == book.name)
                #expect(scaled.character == book.character)
                #expect(scaled.sequence.map(\.move) == book.sequence.map(\.move))
                #expect(scaled.sequence.map(\.impact) == book.sequence.map(\.impact))
                #expect(scaled.sequence.map(\.staminaCost) == book.sequence.map(\.staminaCost))
                for (before, after) in zip(book.sequence, scaled.sequence) {
                    #expect(after.tell >= min(before.tell, OpponentBook.minimumTell))
                    #expect(after.damage > 0 || before.damage == 0)
                }
            }
        }
    }

    @Test func outOfRangeDifficultyIsClamped() {
        let book = OpponentBook.goldie
        #expect(book.scaled(difficulty: -3) == book.scaled(difficulty: 0))
        #expect(book.scaled(difficulty: 9) == book.scaled(difficulty: 1))
    }

    @Test func authoredLadderKeepsStoryOrderAndEveryStageIsPlayable() {
        let ladder = Ladder.authored()
        #expect(ladder.map(\.id) == OpponentBook.careerRoster.map(\.id))
        let config = EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0)
        let inputs = (0..<600).map { $0 % 30 == 0 ? PlayerInput.jab : .none }
        for book in ladder {
            let first = FightEngine.simulate(config: config, seed: 42, book: book, inputs: inputs)
            #expect(first == FightEngine.simulate(config: config, seed: 42, book: book, inputs: inputs))
        }
    }

    /// Higher is harder: damage dealt per tick of a full pattern cycle.
    private func pressure(_ book: OpponentBook) -> Double {
        let damage = book.sequence.reduce(0) { $0 + $1.damage }
        let ticks = book.sequence.reduce(0) { $0 + $1.tell + $1.impact + $1.recover + book.minGap }
        return Double(damage) / Double(ticks)
    }
}
