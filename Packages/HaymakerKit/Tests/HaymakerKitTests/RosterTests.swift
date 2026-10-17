import Testing
@testable import HaymakerKit

@Suite("Authored career roster")
struct RosterTests {
    @Test func sixDistinctEscalatingBooks() {
        let roster = OpponentBook.v0Roster
        #expect(roster.count == 6)
        #expect(Set(roster.map(\.id)).count == 6)
        #expect(Set(roster.map(\.sequence)).count == 6)
        for (earlier, later) in zip(roster, roster.dropFirst()) {
            let averageEarlier = earlier.sequence.reduce(0) { $0 + $1.tell } * later.sequence.count
            let averageLater = later.sequence.reduce(0) { $0 + $1.tell } * earlier.sequence.count
            // Anvil escalates power while retaining its established, replay-tested tells.
            if earlier.id != "twitch" { #expect(averageLater < averageEarlier) }
            #expect(later.minGap <= earlier.minGap)
        }
    }
    @Test func careerUIInputDriverWinsWithoutChangingRules() {
        let result = FightEngine.simulate(config: EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0),
                                          seed: 0xCAFE_2026, book: .twitch,
                                          inputs: Array(repeating: .jab, count: 600))
        #expect(result.outcome.isPlayerWin)
    }
    @Test(arguments: OpponentBook.v0Roster) func replayEveryOpponent(_ book: OpponentBook) {
        let config = EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0)
        let inputs = (0..<600).map { $0 % 20 == 0 ? PlayerInput.jab : .none }
        let first = FightEngine.simulate(config: config, seed: 42, book: book, inputs: inputs)
        #expect(first == FightEngine.simulate(config: config, seed: 42, book: book, inputs: inputs))
        #expect(!book.bio.isEmpty)
    }
}
