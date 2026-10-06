import Testing
@testable import HaymakerKit

/// Bout configs small enough for tests to run instantly while keeping
/// the real tick machine intact.
let testConfig = EngineConfig(
    rounds: 3,
    roundTicks: 1_200,
    restTicks: 120,
    maxKnockdowns: 3,
    revivalHP: 30,
    counterMultiplier: 2,
    blockHoldTicks: 24,
    dodgeTicks: 8,
    whiffRecoverTicks: 6
)

/// A sparring-bell config: enormous HP and knockdown threshold so the
/// round clock is the only way the bout can end (for flow tests).
let clockConfig = EngineConfig(
    rounds: 3,
    roundTicks: 400,
    restTicks: 60,
    maxKnockdowns: 3,
    revivalHP: 30,
    counterMultiplier: 2,
    blockHoldTicks: 24,
    dodgeTicks: 8,
    whiffRecoverTicks: 6,
    damage: DamageConfig(
        maxHP: 100_000,
        maxStamina: 100,
        staminaRegenPerTick: 2,
        knockdownThreshold: 10_000,
        knockdownTicks: 90
    )
)

private struct TestStuckError: Error {}

/// Shared helpers for the tell-window resolution tables.
private enum Helpers {
    /// Drive the engine until the opponent is mid-tell on `move`.
    /// Seeds the scheduler at a chosen entry so the wait is short.
    static func catchTell(book: OpponentBook = .twitch, entryIndex: Int) throws -> (FightEngine, PatternEntry) {
        var engine = FightEngine(config: testConfig, seed: 42, book: book)
        engine.forceOpponentPattern(entryIndex: entryIndex)
        let entry = book.sequence[entryIndex]
        for _ in 0..<5_000 {
            if engine.opponent.state == .telling, engine.opponent.currentMove == entry.move {
                return (engine, entry)
            }
            engine.tick(.none)
        }
        throw TestStuckError()
    }

    /// Wait until the opponent is holding a guard with at least
    /// `margin` ticks left on it.
    static func waitForGuard(engine: inout FightEngine, margin: Int) throws {
        for _ in 0..<2_000 {
            if engine.opponent.state == .blocking,
               engine.opponent.stateDuration - engine.opponent.ticksInCurrentState >= margin {
                return
            }
            engine.tick(.none)
        }
        throw TestStuckError()
    }
}

@Suite("FightEngine: replay determinism")
struct FightEngineDeterminismTests {
    @Test("same seed + same input log reproduces the identical bout")
    func identicalReplay() {
        var rng = SeededRNG(seed: 0xB057)
        let inputs: [PlayerInput] = (0..<2_000).map { _ in
            PlayerInput.allCases[rng.next(lessThan: PlayerInput.allCases.count)]
        }
        let a = FightEngine.simulate(config: testConfig, seed: 42, book: .anvil, inputs: inputs)
        let b = FightEngine.simulate(config: testConfig, seed: 42, book: .anvil, inputs: inputs)
        #expect(a == b)
        #expect(a.events == b.events)
        #expect(a.score == b.score)
    }

    @Test("different seed -> different bout against the same input log")
    func differentSeedDifferentBout() {
        let inputs = [PlayerInput](repeating: .none, count: 5_000)
        let a = FightEngine.simulate(config: testConfig, seed: 1, book: .anvil, inputs: inputs)
        let b = FightEngine.simulate(config: testConfig, seed: 2, book: .anvil, inputs: inputs)
        #expect(a.events != b.events)
    }

    @Test("golden seed fixtures: exact fingerprints lock the engine shape")
    func goldenSeedFixtures() {
        // Regression anchor: if the tick math, scheduler, or scoring
        // changes shape, these numbers move and must be re-derived
        // deliberately (never accidentally).
        let idle = [PlayerInput](repeating: .none, count: 60_000)

        let twitch = FightEngine.simulate(config: testConfig, seed: 1, book: .twitch, inputs: idle)
        // A passive player vs Twitch gets chipped out before the bell.
        #expect(twitch.outcome == .playerLossByKO)
        #expect(twitch.ticksElapsed == 702)
        #expect(twitch.playerStats.landed == 0)
        #expect(twitch.playerStats.thrown == 0)
        #expect(twitch.opponentStats.landed > 0)
        #expect(twitch.opponentStats.thrown >= twitch.opponentStats.landed)
        #expect(twitch.score.points == 50)  // round 1 x 50, zero landed work, no finish bonus on a loss

        // Same bout against the sparring bell: the clock is the only
        // way out, and the decision is a pure score comparison.
        let spar = FightEngine.simulate(config: clockConfig, seed: 1, book: .twitch, inputs: idle)
        #expect(spar.outcome == .playerLossByDecision)
        #expect(spar.ticksElapsed == clockConfig.totalFightTicks)
        #expect(spar.score.points == 150)  // 3 rounds x 50, zero landed work

        let anvil = FightEngine.simulate(config: testConfig, seed: 2, book: .anvil, inputs: idle)
        #expect(anvil.outcome == .playerLossByKO)
        #expect(anvil.ticksElapsed < twitch.ticksElapsed)  // Anvil hits harder, faster
    }

    @Test("simulate embeds the exact consumed input log (one entry per tick)")
    func inputLogExactness() {
        let long = [PlayerInput](repeating: .jab, count: 200_000)
        let result = FightEngine.simulate(config: testConfig, seed: 5, book: .twitch, inputs: long)
        // One log entry per simulated tick — no truncation, no padding drift.
        #expect(result.inputLog.count == result.ticksElapsed)
        // Short logs get padded to the tick count with .none and the
        // padded log still replays identically.
        let replay = FightEngine.simulate(config: testConfig, seed: 5, book: .twitch, inputs: result.inputLog)
        #expect(replay == result)
    }

    @Test("result retains the exact book and rules for replay after balance changes")
    func resultRetainsRules() {
        let custom = OpponentBook(
            id: "twitch", name: "Twitch test variant",
            sequence: [PatternEntry(move: .hook, tell: 2, impact: 2, recover: 4, staminaCost: 1, damage: 4)]
        )
        let rules = EngineConfig(rounds: 1, roundTicks: 50, restTicks: 0)
        let result = FightEngine.simulate(config: rules, seed: 7, book: custom, inputs: [])
        #expect(result.config == rules)
        #expect(result.book == custom)
        #expect(FightEngine.simulate(
            config: result.config, seed: result.seed, book: result.book, inputs: result.inputLog
        ) == result)
        #expect(FightEngine.simulate(config: rules, seed: 7, book: .twitch, inputs: []) != result)
    }
}

@Suite("FightEngine: tell-window resolution tables")
struct TellWindowResolutionTests {
    @Test("dodge timed to the impact tick avoids all damage")
    func dodgeAvoidsImpact() throws {
        // twitch entry 5 = hook (tell 10, impact 6)
        let (engine, entry) = try Helpers.catchTell(entryIndex: 5)
        var e = engine
        let hpBefore = e.player.hp

        // March until 5 ticks before impact fires, then dodge (window 8).
        var issued = false
        for _ in 0..<200 {
            if e.opponent.state == .telling {
                let toImpact = (e.opponent.stateDuration - e.opponent.ticksInCurrentState) + entry.impact
                if toImpact <= testConfig.dodgeTicks - 1, e.player.state == .idle {
                    e.tick(.dodge)
                    issued = true
                    break
                }
            }
            e.tick(.none)
        }
        #expect(issued, "expected to catch the dodge window (entry \(entry.move))")
        for _ in 0..<entry.impact + 2 { e.tick(.none) }
        #expect(e.playerStats.dodgesMade == 1)
        #expect(e.player.hp == hpBefore, "dodge must absorb the incoming hook")
    }

    @Test("guard held at impact eats damage down to the block reduction")
    func guardHoldsAtImpact() throws {
        let (engine, entry) = try Helpers.catchTell(entryIndex: 5)  // hook
        var e = engine
        let hpBefore = e.player.hp

        var issued = false
        for _ in 0..<200 {
            if e.opponent.state == .telling {
                let toImpact = (e.opponent.stateDuration - e.opponent.ticksInCurrentState) + entry.impact
                if toImpact <= testConfig.blockHoldTicks - 2, e.player.state == .idle {
                    e.tick(.block)
                    issued = true
                    break
                }
            }
            e.tick(.none)
        }
        #expect(issued)
        // Keep ticking until the hook actually resolves against the guard.
        for _ in 0..<60 where e.playerStats.blocksMade == 0 && e.outcome == nil { e.tick(.none) }
        #expect(e.playerStats.blocksMade == 1)
        #expect(e.player.hp == hpBefore - max(0, entry.damage - testConfig.damage.blockDamageReduction))
    }

    @Test("punch landing inside a committed tell scores the counter multiplier")
    func counterLandsInTell() throws {
        // twitch entry 0 = jab tell (tell 10) — player jab windup 5 fits.
        let (engine, _) = try Helpers.catchTell(entryIndex: 0)
        var e = engine
        let jab = testConfig.playerTable.jab
        let oppHP = e.opponent.hp
        #expect(e.player.state == .idle)
        #expect(e.opponent.stateDuration - e.opponent.ticksInCurrentState >= jab.windup)

        e.tick(.jab)
        for _ in 0..<(jab.windup - 1) { e.tick(.none) }
        e.tick(.none)  // resolves while opponent is still telling
        guard case let .landed(_, by, move, dmg, counter)? = e.events.last else {
            Issue.record("expected a landed counter event, got \(String(describing: e.events.last))")
            return
        }
        #expect(by == .player)
        #expect(move == .jab)
        #expect(counter)
        #expect(dmg == jab.damage * testConfig.counterMultiplier)
        #expect(e.opponent.hp == oppHP - dmg)
        #expect(e.playerStats.counters == 1)
    }

    @Test("a feint never resolves into a landed or blocked blow")
    func feintsNeverHit() {
        for seed: UInt64 in 1...12 {
            let result = FightEngine.simulate(
                config: testConfig, seed: seed, book: .anvil,
                inputs: [PlayerInput](repeating: .none, count: testConfig.totalFightTicks)
            )
            for event in result.events {
                switch event {
                case let .landed(_, _, move, _, _):
                    #expect(move != .feint, "feint produced a landed blow (seed \(seed))")
                case let .blocked(_, _, move, _):
                    #expect(move != .feint, "feint produced a blocked blow (seed \(seed))")
                default:
                    break
                }
            }
        }
    }

    @Test("opponent guard pattern blocks jabs but breaks to the uppercut")
    func opponentGuardAndGuardBreak() throws {
        let jab = testConfig.playerTable.jab
        let upper = testConfig.playerTable.uppercut
        let reduction = testConfig.damage.blockDamageReduction

        // (a) Jab into the guard: full block reduction.
        let (engine, _) = try Helpers.catchTell(entryIndex: 3)  // twitch block (hold 18)
        var e = engine
        try Helpers.waitForGuard(engine: &e, margin: jab.windup + 3)
        let hpBefore = e.opponent.hp
        e.tick(.jab)
        for _ in 0..<jab.windup { e.tick(.none) }
        let afterJab = e.opponent.hp
        #expect(afterJab == hpBefore - max(0, jab.damage - reduction), "jab vs guard uses full reduction")
        #expect(e.opponentStats.blocksMade == 1, "guarded punch must award opponent defense credit")

        // (b) Uppercut into a fresh guard: halved reduction (guard break).
        let (engine2, _) = try Helpers.catchTell(entryIndex: 3)
        var e2 = engine2
        try Helpers.waitForGuard(engine: &e2, margin: upper.windup + 3)
        let hp2 = e2.opponent.hp
        e2.tick(.uppercut)
        for _ in 0..<upper.windup { e2.tick(.none) }
        let afterUpper = e2.opponent.hp
        #expect(afterUpper == hp2 - max(0, upper.damage - reduction / 2), "uppercut halves the guard")
    }

    @Test("opponent stamina economy gates commits: a locked opponent never overspends")
    func opponentStaminaEconomy() {
        // maxStamina 3 < Twitch's cheapest jab cost (4): the authored
        // economy must LOCK the opponent — it can never commit a
        // pattern it cannot pay for, so a full fight lands zero blows.
        let lockedConfig = EngineConfig(
            rounds: 1,
            roundTicks: 4_000,
            damage: DamageConfig(
                maxHP: 1_000_000,
                maxStamina: 3,
                staminaRegenPerTick: 2,
                knockdownThreshold: 100
            )
        )
        let locked = FightEngine.simulate(
            config: lockedConfig, seed: 3, book: .twitch,
            inputs: [PlayerInput](repeating: .dodge, count: 4_000)
        )
        #expect(locked.opponentStats.thrown == 0)
        #expect(locked.playerHP == 1_000_000)  // nothing ever landed
        #expect(locked.outcome == .draw)  // identical empty scorecards at the bell

        // maxStamina 5 ≥ jab cost 4: the same book must fight normally.
        let fightingConfig = EngineConfig(
            rounds: 1,
            roundTicks: 4_000,
            damage: DamageConfig(
                maxHP: 1_000_000,
                maxStamina: 5,
                staminaRegenPerTick: 2,
                knockdownThreshold: 100
            )
        )
        let fighting = FightEngine.simulate(
            config: fightingConfig, seed: 3, book: .twitch,
            inputs: [PlayerInput](repeating: .dodge, count: 4_000)
        )
        #expect(fighting.opponentStats.thrown > 0)
    }

    @Test("knocking the player down does not shorten the opponent's committed recovery")
    func knockdownPreservesOpponentPattern() {
        var engine = FightEngine(config: testConfig, seed: 2, book: .twitch)
        // Opponent commits the authored hook (twitch entry 5, recover 16).
        engine.forceOpponentPattern(entryIndex: 5)
        for _ in 0..<200 where engine.opponent.state != .attacking { engine.tick(.none) }
        #expect(engine.opponent.state == .attacking)

        // Player goes down while the hook is in flight (direct state —
        // the exact moment the old bug cleared oppActive).
        engine.forcePlayerKnockdown()
        #expect(engine.player.state == .knockedDown)

        // The hook still resolves and the opponent recovers with the
        // AUTHORED window (16), not the fallback default (8).
        var sawRecover = false
        for _ in 0..<40 {
            engine.tick(.none)
            if engine.opponent.state == .recovering {
                #expect(engine.opponent.stateDuration == 16, "recovery must use the authored entry")
                sawRecover = true
                break
            }
        }
        #expect(sawRecover, "opponent should reach recovery after its hook")
    }

    @Test("whiff: exhausted swings cost reduced stamina and deal no damage")
    func exhaustedWhiff() {
        var engine = FightEngine(config: testConfig, seed: 4, book: .twitch)
        engine.player.stamina = 0
        let hpOpp = engine.opponent.hp
        engine.tick(.jab)
        #expect(engine.player.state == .recovering)
        #expect(engine.playerStats.whiffed == 1)
        #expect(engine.playerStats.thrown == 1)
        #expect(engine.opponent.hp == hpOpp)
        #expect(engine.player.stamina == 1)  // floored drain, then +1 half-regen while recovering
    }
}

@Suite("FightEngine: damage state machine")
struct DamageStateMachineTests {
    @Test("three knockdowns end the fight as KO, with named events")
    func threeKnockdownsKO() {
        // Tall-HP sparring config: natural opponent blows (≤22 dmg)
        // can never reach the 100 knockdown threshold or zero 1000 HP,
        // so ONLY the forced 150-damage blows can score knockdowns and
        // the three-count rule is what ends the fight.
        let countConfig = EngineConfig(
            rounds: 1,
            roundTicks: 100_000,
            restTicks: 60,
            maxKnockdowns: 3,
            revivalHP: 300,
            damage: DamageConfig(
                maxHP: 1_000,
                maxStamina: 100,
                staminaRegenPerTick: 2,
                knockdownThreshold: 100,
                knockdownTicks: 90
            )
        )
        var engine = FightEngine(config: countConfig, seed: 6, book: .anvil)
        var spacer = 0
        for _ in 0..<10_000 where engine.outcome == nil {
            // Force one survivable knockdown blow every ~120 idle
            // ticks: 150 ≥ threshold but leaves HP above zero, so the
            // fighter answers the count and the tally climbs.
            if engine.player.state == .idle, engine.opponent.state == .idle, spacer >= 120 {
                engine.forceOpponentImpact(move: .uppercut, damage: 150)
                spacer = 0
            }
            spacer += 1
            engine.tick(.none)
        }
        #expect(engine.outcome == .playerLossByKO)
        #expect(engine.player.knockdownCount == 3)
        #expect(engine.player.state == .ko)
        let downs = engine.events.filter { if case .knockdown = $0 { true } else { false } }
        #expect(downs.count == 3)
        #expect(engine.playerStats.knockdownsSuffered == 3)
    }

    @Test("a downed fighter rises with at least revivalHP after the count")
    func riseAnswersCount() {
        var engine = FightEngine(config: testConfig, seed: 6, book: .twitch)
        engine.player.hp = 5
        engine.forcePlayerKnockdown()
        for _ in 0..<testConfig.damage.knockdownTicks { engine.tick(.none) }
        #expect(engine.player.state == .idle)
        #expect(engine.player.hp >= testConfig.revivalHP)
        #expect(engine.outcome == nil)
        #expect(engine.events.contains { if case .rise = $0 { true } else { false } })
    }

    @Test("KO is a named state — never a silent zero-fill")
    func namedStates() {
        var engine = FightEngine(config: testConfig, seed: 6, book: .twitch)
        engine.opponent.hp = 0
        engine.forcePlayerImpact(move: .jab, damage: 1)
        engine.tick(.none)
        #expect(engine.opponent.state == .ko)
        #expect(engine.outcome == .playerWinByKO)
        #expect(engine.opponent.knockdownCount == 1)
        #expect(engine.player.state == .recovering)
    }

    @Test("no punching a downed fighter: impacts against .knockedDown whiff")
    func downedCannotBeHit() {
        var engine = FightEngine(config: testConfig, seed: 2, book: .twitch)
        engine.opponent.hp = 40
        engine.forceOpponentKnockdown(ticksInto: 10)
        engine.forcePlayerImpact(move: .hook, damage: 14)
        engine.tick(.none)
        #expect(engine.opponent.hp == 40)
        #expect(engine.playerStats.whiffed == 1)
    }

    @Test("stamina economy: idle regens full, blocking half, attacking none")
    func staminaEconomy() {
        var engine = FightEngine(config: testConfig, seed: 2, book: .twitch)
        engine.player.stamina = 50
        engine.player.state = .idle
        engine.tick(.none)
        #expect(engine.player.stamina == 52)  // +2 idle regen

        engine.player.stamina = 50
        engine.player.state = .idle
        engine.tick(.block)
        #expect(engine.player.state == .blocking)
        #expect(engine.player.stamina == 51)  // defense is free: 0 cost + 1 half regen

        engine.player.stamina = 50
        engine.player.state = .idle
        engine.tick(.jab)
        #expect(engine.player.stamina == 45)  // -5 cost, no regen while attacking
    }
}

@Suite("FightEngine: round flow")
struct RoundFlowTests {
    @Test("non-positive rest uses the same two-round clock as zero rest")
    func nonPositiveRestDoesNotSkipFight() {
        for rest in [0, -5_000] {
            let config = EngineConfig(rounds: 2, roundTicks: 1, restTicks: rest)
            let result = FightEngine.simulate(config: config, seed: 11, book: .twitch, inputs: [])
            #expect(result.ticksElapsed == 2)
            #expect(result.roundsCompleted == 2)
            #expect(result.events.contains { if case .boutEnd = $0 { true } else { false } })
        }
    }

    @Test("negative knockdown window cannot skip a bout before its first tick")
    func negativeKnockdownWindowDoesNotShortCircuit() {
        let config = EngineConfig(
            rounds: 1, roundTicks: 1,
            damage: DamageConfig(knockdownTicks: -5_000)
        )
        let result = FightEngine.simulate(config: config, seed: 11, book: .twitch, inputs: [])
        #expect(result.ticksElapsed == 1)
        #expect(result.events.contains { if case .boutEnd = $0 { true } else { false } })
    }

    @Test("round clock advances, rest separates rounds")
    func roundClock() {
        var engine = FightEngine(config: clockConfig, seed: 11, book: .twitch)
        #expect(engine.round == 1)
        #expect(engine.phase == .fighting)
        for _ in 0..<clockConfig.roundTicks + 2 where engine.phase == .fighting {
            engine.tick(.none)
        }
        #expect(engine.phase == .resting)
        #expect(engine.events.contains { if case .roundEnd(_, let r) = $0 { r == 1 } else { false } })
        for _ in 0..<clockConfig.restTicks + 2 where engine.phase == .resting {
            engine.tick(.none)
        }
        #expect(engine.round == 2)
        #expect(engine.phase == .fighting)
    }

    @Test("full time-limit fight runs exactly totalFightTicks and ends by decision")
    func timeLimitDecision() {
        let result = FightEngine.simulate(
            config: clockConfig, seed: 3, book: .twitch,
            inputs: [PlayerInput](repeating: .none, count: 100_000)
        )
        #expect(result.ticksElapsed == clockConfig.totalFightTicks)
        #expect(result.outcome == .playerLossByDecision)
        #expect(result.roundsCompleted == clockConfig.rounds)
    }

    @Test("the bell saves a downed fighter into the next round")
    func bellSave() {
        var engine = FightEngine(config: testConfig, seed: 8, book: .twitch)
        engine.tickInRound = testConfig.roundTicks - 1
        engine.player.hp = 0
        engine.forcePlayerKnockdown(ticksInto: 5)
        engine.tick(.none)
        #expect(engine.player.state == .idle)
        #expect(engine.player.hp >= testConfig.revivalHP)
        #expect(engine.outcome == nil)
        #expect(engine.player.knockdownCount == 1)  // count survives the bell
    }
}
