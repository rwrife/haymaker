import Testing
@testable import HaymakerKit

@Suite("Story character roster")
struct CharacterRosterTests {
    @Test func storyLadderAndAssets() {
        let roster = OpponentBook.careerRoster
        #expect(roster.map(\.id) == ["goldie", "nico", "atlas", "vera", "duke", "sylvie", "cassian", "jaison", "hunter", "baxter"])
        #expect(Set(roster.map(\.sequence)).count == 10)
        #expect(Set(roster.compactMap { $0.character?.asset }).count == 10)
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

    @Test func jaisonMeasuresThenLandsTheFinalFitting() {
        let result = FightEngine.simulate(config: EngineConfig(rounds: 1, roundTicks: 650, restTicks: 0),
                                          seed: 42, book: .jaison, inputs: Array(repeating: .none, count: 650))
        let punches = result.events.compactMap { event -> Move? in
            if case let .landed(_, .opponent, move, _, _) = event { return move }
            return nil
        }
        // Guard and slip do not count as punches; the first offensive cycle
        // measures with jabs before the signature hook–uppercut combination.
        #expect(Array(punches.prefix(4)) == [.jab, .jab, .hook, .uppercut])
        #expect(OpponentBook.jaison.character?.taunt == "Let’s get this sorted.")
        #expect(Ladder.contenders.contains { $0.id == "jaison" })
    }

    @Test func hunterPressureHasAPunishableFinish() {
        let book = OpponentBook.hunter
        let result = FightEngine.simulate(config: EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0),
                                          seed: 7, book: book, inputs: Array(repeating: .jab, count: 600))
        #expect(result.playerStats.counters > 0)
        #expect(result.opponentStats.thrown > 0)
        #expect(book.sequence.last!.recover > book.sequence.dropLast().map(\.recover).max()!)
        #expect(book.character?.taunt == "Try keeping up.")
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
