import Testing
@testable import HaymakerKit

@Suite("Story character roster")
struct CharacterRosterTests {
    @Test func storyLadderAndAssets() {
        let roster = OpponentBook.careerRoster
        #expect(roster.map(\.id) == ["goldie", "nico", "atlas", "vera", "duke", "sylvie", "cassian", "baxter"])
        #expect(Set(roster.map(\.sequence)).count == 8)
        #expect(Set(roster.compactMap { $0.character?.asset }).count == 8)
        for book in roster {
            #expect(book.character != nil)
            #expect(book.bio != "No biography recorded.")
            #expect(book.character?.taunt.isEmpty == false)
        }
    }

    @Test(arguments: OpponentBook.careerRoster)
    func deterministicStoryBout(_ book: OpponentBook) {
        let config = EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0)
        let inputs = (0..<600).map { $0 % 30 == 0 ? PlayerInput.jab : .none }
        let first = FightEngine.simulate(config: config, seed: 42, book: book, inputs: inputs)
        #expect(first == FightEngine.simulate(config: config, seed: 42, book: book, inputs: inputs))
    }

    @Test func sylvieSlipsPunchesWithoutThrowingADodge() {
        let slip = PatternEntry(move: .dodge, tell: 1, impact: 60, recover: 1, staminaCost: 0, damage: 0)
        let book = OpponentBook(id: "slip-test", name: "Slip", sequence: [slip], minGap: 0, gapSpread: 0)
        let result = FightEngine.simulate(config: EngineConfig(rounds: 1, roundTicks: 60, restTicks: 0),
                                          seed: 1, book: book, inputs: Array(repeating: .jab, count: 60))
        #expect(result.opponentStats.thrown == 0)
        #expect(result.playerStats.landed == 0)
        #expect(result.opponentStats.dodgesMade > 0)
        #expect(result.events.contains { if case .dodged(_, .player, _) = $0 { true } else { false } })
    }
}
