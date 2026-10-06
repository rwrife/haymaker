import Testing
@testable import HaymakerKit

@Suite("Scoring: deterministic components")
struct ScoringTests {
    @Test("empty bout scores zero landed work, never negative")
    func emptyBout() {
        let score = Scoring.boutScore(
            stats: FighterStats(),
            context: ScoringContext(round: 1, roundsTotal: 3, ticks: 100, ticksTotal: 3600, finished: false, byKO: false)
        )
        #expect(score.landedPoints == 0)
        #expect(score.defensePoints == 0)
        #expect(score.damagePoints == 0)
        #expect(score.koBonus == 0)
        #expect(score.finishBonus == 0)
        #expect(score.points >= 0)
    }

    @Test("landed ratio scales to 1000 and clamps")
    func landedRatio() {
        #expect(Scoring.landedRatio(landed: 0, thrown: 0) == 0)
        #expect(Scoring.landedRatio(landed: 7, thrown: 14) == 500)
        #expect(Scoring.landedRatio(landed: 14, thrown: 14) == 1_000)
        #expect(Scoring.landedRatio(landed: 20, thrown: 14) == 1_000)  // clamp guard
    }

    @Test("component arithmetic is exact integers")
    func exactArithmetic() {
        var stats = FighterStats()
        stats.thrown = 20
        stats.landed = 10           // ratio 500 -> 10*10 + 50 = 150
        stats.dodgesMade = 2        // 2*15
        stats.parriesMade = 1       // 1*15
        stats.blocksMade = 3        // 3*7
        stats.counters = 2          // 2*10  -> defense 30+15+21+20 = 86
        stats.damageDealt = 60
        stats.damageTaken = 30      // 60 - 15 = 45

        let score = Scoring.boutScore(
            stats: stats,
            context: ScoringContext(round: 2, roundsTotal: 3, ticks: 1_000, ticksTotal: 3_720, finished: false, byKO: false)
        )
        #expect(score.landedPoints == 150)
        #expect(score.defensePoints == 86)
        #expect(score.damagePoints == 45)
        #expect(score.roundPoints == 100)
        #expect(score.timePoints == 0)
        #expect(score.points == 150 + 86 + 45 + 100)
    }

    @Test("KO + finish bonuses apply only to a finished/KO'd bout")
    func bonuses() {
        var stats = FighterStats()
        stats.landed = 1
        stats.thrown = 1
        let base = ScoringContext(round: 1, roundsTotal: 3, ticks: 500, ticksTotal: 3_720, finished: false, byKO: false)
        let finished = ScoringContext(round: 1, roundsTotal: 3, ticks: 500, ticksTotal: 3_720, finished: true, byKO: false)
        let ko = ScoringContext(round: 1, roundsTotal: 3, ticks: 500, ticksTotal: 3_720, finished: true, byKO: true)

        let s0 = Scoring.boutScore(stats: stats, context: base)
        let s1 = Scoring.boutScore(stats: stats, context: finished)
        let s2 = Scoring.boutScore(stats: stats, context: ko)
        // finished adds finish bonus (200) + time bonus ((3720-500)/20 = 161).
        #expect(s1.timePoints == 161)
        #expect(s1.points == s0.points + 200 + 161)
        #expect(s2.points == s1.points + 500)  // KO bonus on top
        #expect(s2.koBonus == 500)
    }

    @Test("damage differential never goes negative into silent zeros")
    func damageFloor() {
        var stats = FighterStats()
        stats.damageTaken = 999  // getting shellacked
        let score = Scoring.boutScore(
            stats: stats,
            context: ScoringContext(round: 1, roundsTotal: 3, ticks: 1, ticksTotal: 2, finished: false, byKO: false)
        )
        #expect(score.damagePoints == 0)
        #expect(score.roundPoints == 50)  // rounds always earn their named share
    }
}

@Suite("BoutLedger: append-only records + derived personal bests")
struct BoutLedgerTests {
    private func bout(
        opponent: String = "twitch",
        points: Int,
        outcome: FightOutcome,
        rounds: Int = 3,
        ticks: Int = 3_720
    ) -> BoutResult {
        let zero = Scoring.boutScore(
            stats: FighterStats(),
            context: ScoringContext(round: rounds, roundsTotal: 3, ticks: ticks, ticksTotal: 3_720, finished: false, byKO: false)
        )
        let score = BoutScore(
            landedPoints: zero.landedPoints, defensePoints: zero.defensePoints,
            damagePoints: zero.damagePoints, roundPoints: zero.roundPoints,
            timePoints: zero.timePoints, koBonus: zero.koBonus,
            finishBonus: zero.finishBonus, points: points
        )
        return BoutResult(
            config: .standard, book: opponent == "anvil" ? .anvil : .twitch,
            seed: 7, opponentID: opponent, outcome: outcome,
            roundsCompleted: rounds, ticksElapsed: ticks,
            playerHP: 50, opponentHP: 50,
            playerKnockdowns: 0, opponentKnockdowns: 0,
            playerStats: FighterStats(), opponentStats: FighterStats(),
            events: [], score: score, inputLog: []
        )
    }

    @Test("empty ledger -> firstBout for any opponent, and it always stores")
    func firstBout() {
        let ledger = BoutLedger()
        #expect(ledger.best(for: "twitch") == nil)
        #expect(ledger.comparison(for: bout(points: 100, outcome: .playerLossByDecision)) == .firstBout)
    }

    @Test("append is the only mutation: entries accumulate in order")
    func appendOnly() {
        var ledger = BoutLedger()
        ledger.append(bout(points: 100, outcome: .playerLossByDecision))
        ledger.append(bout(points: 500, outcome: .playerWinByDecision))
        #expect(ledger.entries.count == 2)
        #expect(ledger.entries.map(\.score) == [100, 500])  // order preserved
    }

    @Test("best is derived from the ledger, not caller-supplied")
    func derivedBest() {
        var ledger = BoutLedger()
        ledger.append(bout(points: 300, outcome: .playerLossByDecision))
        ledger.append(bout(points: 900, outcome: .playerWinByKO, rounds: 2, ticks: 2_500))
        ledger.append(bout(points: 150, outcome: .playerLossByKO))
        let best = ledger.best(for: "twitch")
        #expect(best?.score == 900)
        #expect(best?.outcome == .playerWinByKO)
        #expect(best?.opponentID == "twitch")
    }

    @Test("opponent identity is enforced: records never leak between books")
    func opponentIsolation() {
        var ledger = BoutLedger()
        ledger.append(bout(opponent: "twitch", points: 900, outcome: .playerWinByKO))
        ledger.append(bout(opponent: "anvil", points: 200, outcome: .playerLossByDecision))
        #expect(ledger.best(for: "twitch")?.score == 900)
        #expect(ledger.best(for: "anvil")?.score == 200)
        // A 500-point Anvil bout is a new best for Anvil even though
        // it loses to Twitch's 900.
        #expect(ledger.comparison(for: bout(opponent: "anvil", points: 500, outcome: .playerWinByDecision)) == .newPersonalBest)
        #expect(ledger.comparison(for: bout(opponent: "twitch", points: 500, outcome: .playerWinByDecision)) == .noImprovement)
    }

    @Test("comparison verdicts: higher score, equal-score finish ties, none")
    func verdicts() {
        var ledger = BoutLedger()
        ledger.append(bout(points: 500, outcome: .playerWinByDecision))
        #expect(ledger.comparison(for: bout(points: 501, outcome: .playerLossByDecision)) == .newPersonalBest)
        #expect(ledger.comparison(for: bout(points: 499, outcome: .playerWinByKO)) == .noImprovement)
        // Equal score, better finish rank (KO > decision).
        #expect(ledger.comparison(for: bout(points: 500, outcome: .playerWinByKO)) == .matchedBetterFinish)
        // Equal score + rank, fewer rounds.
        #expect(ledger.comparison(for: bout(points: 500, outcome: .playerWinByDecision, rounds: 2, ticks: 2_500)) == .matchedBetterFinish)
        // Exact duplicate improves nothing.
        #expect(ledger.comparison(for: bout(points: 500, outcome: .playerWinByDecision)) == .noImprovement)
    }

    @Test("equal score and rank: fewer ticks after equal rounds")
    func tieBreakTime() {
        var ledger = BoutLedger()
        ledger.append(bout(points: 500, outcome: .playerWinByDecision, rounds: 3, ticks: 3_000))
        #expect(ledger.comparison(for: bout(points: 500, outcome: .playerWinByDecision, rounds: 3, ticks: 2_900)) == .matchedBetterFinish)
        #expect(ledger.comparison(for: bout(points: 500, outcome: .playerWinByDecision, rounds: 3, ticks: 3_100)) == .noImprovement)
    }

    @Test("draw best is outranked by any decision win")
    func drawRanking() {
        var ledger = BoutLedger()
        ledger.append(bout(points: 500, outcome: .draw))
        #expect(ledger.comparison(for: bout(points: 500, outcome: .playerWinByDecision)) == .matchedBetterFinish)
        #expect(ledger.comparison(for: bout(points: 500, outcome: .playerLossByKO)) == .noImprovement)
    }

    @Test("noImprovement never changes the stored best")
    func storeGate() {
        var ledger = BoutLedger()
        ledger.append(bout(points: 900, outcome: .playerWinByKO))
        let verdict = ledger.comparison(for: bout(points: 100, outcome: .playerLossByKO))
        #expect(verdict == .noImprovement)
        #expect(!verdict.shouldStore)
        // Appending anyway keeps the fold result at the old best.
        ledger.append(bout(points: 100, outcome: .playerLossByKO))
        #expect(ledger.best(for: "twitch")?.score == 900)
    }
}
