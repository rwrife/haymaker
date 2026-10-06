/// Fixed-tick, integer-only fight simulation.
///
/// `FightEngine` is the authoritative rules layer for a bout. It has no
/// wall-clock, no floats, no system RNG: every tick consumes exactly one
/// `PlayerInput`, and the opponent's behavior comes solely from the
/// `PatternScheduler` seeded with the bout seed. Consequently the pair
/// (seed, input log) fully determines the bout — replays are exact and
/// cheat-checkable.
///
/// Timing model (all values in engine ticks):
/// - Opponent: seeded idle gap → tell window → (feint: recovery |
///   attack: impact → recovery).
/// - Player: one action per lockout. Attacks resolve at the end of
///   their windup; block/dodge/parry are stances with fixed windows.
/// - Resolution reads the defender's state at the resolving tick, so
///   defensive timing windows are the whole game.

/// Who is acting / being acted upon.
public enum Combatant: String, Sendable, Codable, Hashable, CaseIterable {
    case player
    case opponent
}

/// How the bout ended.
public enum FightOutcome: String, Sendable, Codable, Hashable {
    case playerWinByKO
    case playerWinByDecision
    case draw
    case playerLossByDecision
    case playerLossByKO

    public var isPlayerWin: Bool {
        self == .playerWinByKO || self == .playerWinByDecision
    }
}

/// Per-move timing/cost table for the player's attacks.
public struct MoveTiming: Sendable, Codable, Hashable {
    public let windup: Int
    public let recover: Int
    public let staminaCost: Int
    public let damage: Int

    public init(windup: Int, recover: Int, staminaCost: Int, damage: Int) {
        precondition(windup > 0 && recover > 0, "attack timings must be positive")
        self.windup = windup
        self.recover = recover
        self.staminaCost = staminaCost
        self.damage = damage
    }
}

/// The player's move table (one-thumb scheme stats).
public struct PlayerMoveTable: Sendable, Codable, Hashable {
    public let jab: MoveTiming
    public let hook: MoveTiming
    public let uppercut: MoveTiming

    public init(jab: MoveTiming, hook: MoveTiming, uppercut: MoveTiming) {
        self.jab = jab
        self.hook = hook
        self.uppercut = uppercut
    }

    /// Timing for an offensive player input; `nil` for defensive inputs.
    public func timing(for input: PlayerInput) -> MoveTiming? {
        switch input {
        case .jab: return jab
        case .hook: return hook
        case .uppercut: return uppercut
        case .none, .block, .dodge, .parry: return nil
        }
    }

    public static let standard = PlayerMoveTable(
        jab: MoveTiming(windup: 5, recover: 8, staminaCost: 5, damage: 8),
        hook: MoveTiming(windup: 8, recover: 14, staminaCost: 9, damage: 14),
        uppercut: MoveTiming(windup: 11, recover: 20, staminaCost: 14, damage: 22)
    )
}

/// Bout-flow configuration.
public struct EngineConfig: Sendable, Codable, Hashable {
    public let rounds: Int
    public let roundTicks: Int
    public let restTicks: Int
    /// Third knockdown ends the fight (three-knockdown rule).
    public let maxKnockdowns: Int
    /// HP granted when a fighter answers the count.
    public let revivalHP: Int
    /// Damage multiplier for landing during an opponent's tell.
    public let counterMultiplier: Int
    /// How long a held block stance lasts before re-input is required.
    public let blockHoldTicks: Int
    /// How long a dodge avoids an incoming impact.
    public let dodgeTicks: Int
    /// Recovery lockout after whiffing an attack on empty stamina.
    public let whiffRecoverTicks: Int
    public let playerTable: PlayerMoveTable
    public let damage: DamageConfig

    public init(
        rounds: Int = 3,
        roundTicks: Int = 3600,
        restTicks: Int = 600,
        maxKnockdowns: Int = 3,
        revivalHP: Int = 30,
        counterMultiplier: Int = 2,
        blockHoldTicks: Int = 24,
        dodgeTicks: Int = 8,
        whiffRecoverTicks: Int = 6,
        playerTable: PlayerMoveTable = .standard,
        damage: DamageConfig = .standard
    ) {
        precondition(rounds > 0 && roundTicks > 0, "rounds/roundTicks must be positive")
        precondition(maxKnockdowns > 0, "maxKnockdowns must be positive")
        self.rounds = rounds
        self.roundTicks = roundTicks
        self.restTicks = restTicks
        self.maxKnockdowns = maxKnockdowns
        self.revivalHP = revivalHP
        self.counterMultiplier = counterMultiplier
        self.blockHoldTicks = blockHoldTicks
        self.dodgeTicks = dodgeTicks
        self.whiffRecoverTicks = whiffRecoverTicks
        self.playerTable = playerTable
        self.damage = damage
    }

    public static let standard = EngineConfig()

    /// Ticks in a full time-limit fight (rounds + non-negative rest between them).
    /// Non-positive rest values use the immediate next-round path in `endRound`.
    public var totalFightTicks: Int {
        rounds * roundTicks + (rounds - 1) * max(0, restTicks)
    }

    /// Absolute safety bound so `simulate` can never spin.
    public var hardTickCap: Int {
        totalFightTicks + damage.knockdownTicks + 4096
    }
}

/// Cumulative per-fighter bout statistics (scoring input).
public struct FighterStats: Sendable, Codable, Hashable {
    public var thrown = 0
    public var landed = 0
    public var whiffed = 0
    public var counters = 0
    public var blocksMade = 0
    public var dodgesMade = 0
    public var parriesMade = 0
    public var damageDealt = 0
    public var damageTaken = 0
    public var knockdownsScored = 0
    public var knockdownsSuffered = 0

    public init() {}
}

/// One recorded rules moment of a bout. Events are the replay-visible
/// truth: hit-feedback HUDs and results cards render from these.
public enum FightEvent: Sendable, Codable, Hashable {
    case landed(tick: Int, by: Combatant, move: Move, damage: Int, counter: Bool)
    case blocked(tick: Int, by: Combatant, move: Move, damage: Int)
    case dodged(tick: Int, attacker: Combatant, move: Move)
    case parried(tick: Int, attacker: Combatant, move: Move)
    case whiffed(tick: Int, by: Combatant, move: Move)
    case knockdown(tick: Int, fighter: Combatant, number: Int)
    case rise(tick: Int, fighter: Combatant)
    case roundStart(tick: Int, round: Int)
    case roundEnd(tick: Int, round: Int)
    case boutEnd(tick: Int, outcome: FightOutcome)
}

/// Complete, comparable result of a simulated bout.
public struct BoutResult: Sendable, Codable, Hashable {
    public let seed: UInt64
    public let opponentID: String
    public let outcome: FightOutcome
    public let roundsCompleted: Int
    public let ticksElapsed: Int
    public let playerHP: Int
    public let opponentHP: Int
    public let playerKnockdowns: Int
    public let opponentKnockdowns: Int
    public let playerStats: FighterStats
    public let opponentStats: FighterStats
    public let events: [FightEvent]
    public let score: BoutScore

    /// The exact per-tick input sequence the simulation consumed — one
    /// entry per simulated tick (`.none` padding included when the
    /// caller's log ran out). Re-simulating with the same seed + this
    /// log must reproduce byte-identical results.
    public let inputLog: [PlayerInput]
}

/// Fight-flow phase: live fighting or rest between rounds.
public enum BoutPhase: String, Sendable, Codable, Hashable {
    case fighting
    case resting
    case over
}

public struct FightEngine: Sendable {
    public let config: EngineConfig
    public let seed: UInt64
    public let book: OpponentBook

    public internal(set) var round: Int
    public internal(set) var tickInRound: Int
    public internal(set) var totalTicks: Int
    public internal(set) var phase: BoutPhase
    public internal(set) var player: FighterStatus
    public internal(set) var opponent: FighterStatus
    public internal(set) var playerStats: FighterStats
    public internal(set) var opponentStats: FighterStats
    public private(set) var events: [FightEvent]
    public internal(set) var outcome: FightOutcome?

    private var scheduler: PatternScheduler
    private var oppWaitingTicks: Int
    /// The entry the opponent is currently executing (nil when idle).
    /// Internal: the tell-window test tables read impact/damage from it.
    var oppActive: PatternEntry?
    private var restTicksLeft: Int

    public init(config: EngineConfig = .standard, seed: UInt64, book: OpponentBook) {
        self.config = config
        self.seed = seed
        self.book = book
        self.round = 1
        self.tickInRound = 0
        self.totalTicks = 0
        self.phase = .fighting
        self.player = FighterStatus(hp: config.damage.maxHP, stamina: config.damage.maxStamina)
        self.opponent = FighterStatus(hp: config.damage.maxHP, stamina: config.damage.maxStamina)
        self.playerStats = FighterStats()
        self.opponentStats = FighterStats()
        self.events = [.roundStart(tick: 0, round: 1)]
        self.outcome = nil
        self.scheduler = PatternScheduler(book: book, seed: seed)
        self.oppActive = nil
        self.restTicksLeft = 0
        self.oppWaitingTicks = scheduler.nextGap()
    }

    public var isOver: Bool { outcome != nil }

    // MARK: - Deterministic scenario seams (internal, for state-table tests)

    /// Rewind the scheduler to `entryIndex` and make the opponent issue
    /// that pattern next. Setup for readable transition tables — the
    /// public replay contract only ever consumes `tick`/`simulate`.
    mutating func forceOpponentPattern(entryIndex: Int) {
        scheduler.rewind(to: entryIndex)
        opponent.state = .idle
        opponent.currentMove = .idle
        opponent.currentDamage = 0
        oppWaitingTicks = 1
    }

    /// Put the opponent into a committed attack that resolves next tick.
    mutating func forceOpponentImpact(move: Move, damage: Int) {
        opponent.state = .attacking
        opponent.currentMove = move
        opponent.currentDamage = damage
        opponent.stateDuration = 1
        opponent.ticksInCurrentState = 1
        oppActive = PatternEntry(move: move, tell: 1, impact: 1, recover: 8, staminaCost: 0, damage: damage)
    }

    /// Put the player into a committed attack that resolves next tick.
    mutating func forcePlayerImpact(move: Move, damage: Int) {
        player.state = .attacking
        player.currentMove = move
        player.currentDamage = damage
        player.stateDuration = 1
        player.ticksInCurrentState = 1
    }

    /// Knock the player down through the real rules path.
    mutating func forcePlayerKnockdown(ticksInto: Int = 0) {
        knockDown(.player)
        player.ticksInCurrentState = ticksInto
    }

    /// Knock the opponent down through the real rules path.
    mutating func forceOpponentKnockdown(ticksInto: Int = 0) {
        knockDown(.opponent)
        opponent.ticksInCurrentState = ticksInto
    }

    // MARK: - Tick pump

    /// Advance the bout by one tick with the player's input.
    ///
    /// Inputs issued while the player is locked out of a state are
    /// deliberately ignored: this keeps replay of noisy input logs
    /// exact (the log, not input *timing precision*, is the contract).
    mutating public func tick(_ input: PlayerInput) {
        guard outcome == nil else { return }
        totalTicks += 1

        if phase == .resting {
            restTicksLeft -= 1
            if restTicksLeft <= 0 {
                phase = .fighting
                round += 1
                tickInRound = 0
                events.append(.roundStart(tick: totalTicks, round: round))
            }
            return
        }

        startPlayerAction(input)
        advanceOpponentScheduler()

        player.ticksInCurrentState += 1
        opponent.ticksInCurrentState += 1

        resolveOpponentPhase()
        guard outcome == nil else { return }
        resolvePlayerPhase()
        guard outcome == nil else { return }

        applyRegen()

        tickInRound += 1
        if tickInRound >= config.roundTicks {
            endRound()
        }
    }

    /// Drain a full input log against the engine.
    mutating public func advance(with inputs: some Sequence<PlayerInput>) {
        for input in inputs {
            tick(input)
            if isOver { break }
        }
    }

    // MARK: - Player actions

    private mutating func startPlayerAction(_ input: PlayerInput) {
        guard player.state == .idle else { return }
        switch input {
        case .none:
            break
        case .jab, .hook, .uppercut:
            guard let timing = config.playerTable.timing(for: input) else { return }
            player.currentMove = input.asMove
            playerStats.thrown += 1
            if player.stamina < timing.staminaCost {
                // Exhausted swing: no damage, short lockout, half cost.
                player.stamina = max(0, player.stamina - max(1, timing.staminaCost / 2))
                enterPlayerRecovering(config.whiffRecoverTicks)
                playerStats.whiffed += 1
                events.append(.whiffed(tick: totalTicks, by: .player, move: input.asMove))
            } else {
                player.stamina -= timing.staminaCost
                player.state = .attacking
                player.ticksInCurrentState = 0
                player.stateDuration = timing.windup
                player.currentDamage = timing.damage
            }
        case .block:
            player.state = .blocking
            player.ticksInCurrentState = 0
            player.stateDuration = config.blockHoldTicks
            player.currentMove = .block
            player.currentDamage = 0
        case .dodge:
            player.state = .dodging
            player.ticksInCurrentState = 0
            player.stateDuration = config.dodgeTicks
            player.currentMove = .dodge
            player.currentDamage = 0
        case .parry:
            player.state = .parrying
            player.ticksInCurrentState = 0
            player.stateDuration = config.damage.parryWindowTicks
            player.currentMove = .parry
            player.currentDamage = 0
        }
    }

    private mutating func enterPlayerRecovering(_ ticks: Int) {
        player.state = .recovering
        player.ticksInCurrentState = 0
        player.stateDuration = ticks
        player.currentMove = .idle
        player.currentDamage = 0
    }

    // MARK: - Opponent scheduling

    private mutating func advanceOpponentScheduler() {
        guard opponent.state == .idle else { return }
        oppWaitingTicks -= 1
        if oppWaitingTicks <= 0 {
            let entry = scheduler.peekEntry()
            guard opponent.stamina >= entry.staminaCost else {
                // Gassed: the opponent visibly holds and regenerates
                // until it can commit. Deterministic — no RNG here.
                oppWaitingTicks = 0
                return
            }
            let committed = scheduler.nextEntry()
            opponent.stamina -= committed.staminaCost
            oppActive = committed
            opponent.state = .telling
            opponent.ticksInCurrentState = 0
            opponent.stateDuration = committed.tell
            opponent.currentMove = committed.move
            opponent.currentDamage = committed.damage
            oppWaitingTicks = scheduler.nextGap()
        }
    }

    // MARK: - Phase resolution

    private mutating func resolveOpponentPhase() {
        switch opponent.state {
        case .telling where opponent.ticksInCurrentState >= opponent.stateDuration:
            if opponent.currentMove == .feint {
                // Feint: never resolves into an impact, only recovery.
                enterOpponentRecovering(oppActive?.recover ?? 8)
            } else if opponent.currentMove == .block {
                // Guard pattern: raise the guard and hold it for the
                // entry's `impact` window. Player punches resolve
                // against the block; uppercuts break it.
                opponent.state = .blocking
                opponent.ticksInCurrentState = 0
                opponent.stateDuration = oppActive?.impact ?? 12
            } else {
                opponent.state = .attacking
                opponent.ticksInCurrentState = 0
                opponent.stateDuration = oppActive?.impact ?? 4
                opponentStats.thrown += 1
            }
        case .blocking where opponent.ticksInCurrentState >= opponent.stateDuration:
            enterOpponentRecovering(oppActive?.recover ?? 8)
        case .attacking where opponent.ticksInCurrentState >= opponent.stateDuration:
            resolveOpponentImpact()
            enterOpponentRecovering(oppActive?.recover ?? 8)
            guard outcome == nil else { return }
        case .recovering where opponent.ticksInCurrentState >= opponent.stateDuration:
            opponent.state = .idle
            opponent.currentMove = .idle
            opponent.currentDamage = 0
            oppActive = nil
        case .knockedDown where opponent.ticksInCurrentState >= opponent.stateDuration:
            answerTheCount(.opponent)
        default:
            break
        }
    }

    private mutating func enterOpponentRecovering(_ ticks: Int) {
        opponent.state = .recovering
        opponent.ticksInCurrentState = 0
        opponent.stateDuration = ticks
        opponent.currentMove = .idle
        opponent.currentDamage = 0
    }

    private mutating func resolveOpponentImpact() {
        let move = opponent.currentMove
        let base = opponent.currentDamage

        if player.state == .knockedDown {
            // A downed fighter cannot be hit — the count is running.
            opponentStats.whiffed += 1
            events.append(.whiffed(tick: totalTicks, by: .opponent, move: move))
            return
        }
        switch player.state {
        case .dodging:
            playerStats.dodgesMade += 1
            opponentStats.whiffed += 1
            events.append(.dodged(tick: totalTicks, attacker: .opponent, move: move))
        case .parrying:
            playerStats.parriesMade += 1
            opponentStats.whiffed += 1
            events.append(.parried(tick: totalTicks, attacker: .opponent, move: move))
        case .blocking:
            let applied = DamageModel.blockedDamage(
                base: base,
                reduction: config.damage.blockDamageReduction,
                guardBreak: guardBreak(move: move)
            )
            playerStats.blocksMade += 1
            player.hp = max(0, player.hp - applied)
            playerStats.damageTaken += applied
            opponentStats.damageDealt += applied
            events.append(.blocked(tick: totalTicks, by: .opponent, move: move, damage: applied))
            if DamageModel.isOutOfCold(hpAfterBlow: player.hp) { knockDown(.player, ko: true) }
        default:
            player.hp = max(0, player.hp - base)
            playerStats.damageTaken += base
            opponentStats.damageDealt += base
            opponentStats.landed += 1
            events.append(.landed(tick: totalTicks, by: .opponent, move: move, damage: base, counter: false))
            if DamageModel.isOutOfCold(hpAfterBlow: player.hp) {
                knockDown(.player, ko: true)
            } else if DamageModel.isKnockdownBlow(damage: base, threshold: config.damage.knockdownThreshold) {
                knockDown(.player)
            }
            checkKnockdownEnd(.player)
        }
    }

    private mutating func resolvePlayerPhase() {
        switch player.state {
        case .attacking where player.ticksInCurrentState >= player.stateDuration:
            resolvePlayerImpact()
            enterPlayerRecovering(playerTableRecover())
            guard outcome == nil else { return }
        case .recovering where player.ticksInCurrentState >= player.stateDuration:
            player.state = .idle
            player.currentMove = .idle
            player.currentDamage = 0
        case .blocking, .dodging, .parrying:
            if player.ticksInCurrentState >= player.stateDuration {
                player.state = .idle
                player.currentMove = .idle
            }
        case .knockedDown where player.ticksInCurrentState >= player.stateDuration:
            answerTheCount(.player)
        default:
            break
        }
    }

    private func playerTableRecover() -> Int {
        switch player.currentMove {
        case .jab: return config.playerTable.jab.recover
        case .hook: return config.playerTable.hook.recover
        case .uppercut: return config.playerTable.uppercut.recover
        default: return config.whiffRecoverTicks
        }
    }

    private mutating func resolvePlayerImpact() {
        let move = player.currentMove
        let base = player.currentDamage

        if opponent.state == .knockedDown {
            // You cannot punch a man already on the canvas. The swing
            // still counts as thrown (it was) and whiffed (it missed).
            playerStats.whiffed += 1
            events.append(.whiffed(tick: totalTicks, by: .player, move: move))
            return
        }

        // Counter: landing during a *committed* tell. Landing on a feint
        // tell is the feint's whole point — no counter bonus there.
        let isCounter = opponent.state == .telling && opponent.currentMove != .feint
        var damage = isCounter
            ? DamageModel.counterDamage(base: base, multiplier: config.counterMultiplier)
            : base

        var blocked = false
        if opponent.state == .blocking {
            damage = DamageModel.blockedDamage(
                base: damage,
                reduction: config.damage.blockDamageReduction,
                guardBreak: guardBreak(move: move)
            )
            blocked = true
        }

        opponent.hp = max(0, opponent.hp - damage)
        playerStats.damageDealt += damage
        opponentStats.damageTaken += damage
        if isCounter { playerStats.counters += 1 }

        if blocked {
            events.append(.blocked(tick: totalTicks, by: .player, move: move, damage: damage))
            if DamageModel.isOutOfCold(hpAfterBlow: opponent.hp) { knockDown(.opponent, ko: true) }
        } else {
            playerStats.landed += 1
            events.append(.landed(tick: totalTicks, by: .player, move: move, damage: damage, counter: isCounter))
            if DamageModel.isOutOfCold(hpAfterBlow: opponent.hp) {
                knockDown(.opponent, ko: true)
            } else if DamageModel.isKnockdownBlow(damage: damage, threshold: config.damage.knockdownThreshold) {
                knockDown(.opponent)
            }
        }
    }

    /// Uppercuts are the guard-break move: they halve block reduction.
    private func guardBreak(move: Move) -> Bool { move == .uppercut }

    // MARK: - Damage state machine (named transitions, no silent fills)

    private mutating func knockDown(_ fighter: Combatant, ko: Bool = false) {
        // Mutate one fighter at a time WITHOUT inout member captures:
        // the nested finish() path touches other `self` properties, so
        // exclusive `&player`/`&opponent` borrows would violate
        // exclusivity. Plain branch-duplicated mutation keeps it legal.
        let downNumber = (fighter == .player ? player.knockdownCount : opponent.knockdownCount) + 1
        let isKO = ko || DamageModel.isThreeCountKO(knockdownCount: downNumber, maxKnockdowns: config.maxKnockdowns)
        let scorer: Combatant = fighter == .player ? .opponent : .player

        events.append(.knockdown(tick: totalTicks, fighter: fighter, number: downNumber))
        if scorer == .player { playerStats.knockdownsScored += 1 } else { opponentStats.knockdownsScored += 1 }
        if fighter == .player { playerStats.knockdownsSuffered += 1 } else { opponentStats.knockdownsSuffered += 1 }

        if fighter == .player {
            player.knockdownCount += 1
            player.currentMove = .idle
            player.currentDamage = 0
            if isKO {
                player.state = .ko
                player.hp = 0
            } else {
                player.state = .knockedDown
                player.ticksInCurrentState = 0
                player.stateDuration = config.damage.knockdownTicks
            }
            // NOTE: the opponent's in-flight pattern KEEPS its identity —
            // knocking the player down must not shorten the opponent's
            // authored recovery window.
        } else {
            opponent.knockdownCount += 1
            opponent.currentMove = .idle
            opponent.currentDamage = 0
            if isKO {
                opponent.state = .ko
                opponent.hp = 0
            } else {
                opponent.state = .knockedDown
                opponent.ticksInCurrentState = 0
                opponent.stateDuration = config.damage.knockdownTicks
            }
            // The opponent's pending pattern is cancelled by the count.
            oppActive = nil
        }

        if isKO {
            finish(outcome: fighter == .player ? .playerLossByKO : .playerWinByKO)
        }
    }

    /// Resolve the count at the end of a knockdown window: rise. (The
    /// terminal KO paths — out cold or three-down — are decided at the
    /// moment of the knockdown itself, never silently here.)
    private mutating func answerTheCount(_ fighter: Combatant) {
        let downed = fighter == .player ? player : opponent
        guard downed.state == .knockedDown else { return }
        switch fighter {
        case .player:
            player.hp = DamageModel.revivalHP(current: player.hp, floor: config.revivalHP)
            player.stamina = config.damage.maxStamina / 2
            player.state = .idle
            player.ticksInCurrentState = 0
        case .opponent:
            opponent.hp = DamageModel.revivalHP(current: opponent.hp, floor: config.revivalHP)
            opponent.stamina = config.damage.maxStamina / 2
            opponent.state = .idle
            opponent.ticksInCurrentState = 0
            oppWaitingTicks = scheduler.nextGap()
        }
        events.append(.rise(tick: totalTicks, fighter: fighter))
    }

    /// Safety pass: catches a fighter whose knockdown window should be
    /// expiring on the same tick as other resolutions.
    private mutating func checkKnockdownEnd(_ fighter: Combatant) {
        let status = fighter == .player ? player : opponent
        if status.state == .knockedDown, status.ticksInCurrentState >= status.stateDuration {
            answerTheCount(fighter)
        }
    }

    // MARK: - Stamina economy

    private mutating func applyRegen() {
        let full = config.damage.staminaRegenPerTick
        regen(into: &player, full: full)
        regen(into: &opponent, full: full)
    }

    private func regen(into status: inout FighterStatus, full: Int) {
        let gain = DamageModel.staminaRegen(state: status.state, full: full)
        status.stamina = min(config.damage.maxStamina, status.stamina + gain)
    }

    // MARK: - Round flow

    private mutating func endRound() {
        events.append(.roundEnd(tick: totalTicks, round: round))
        // The bell saves a downed fighter: answer the count at once,
        // but the knockdown count itself is kept.
        if player.state == .knockedDown {
            player.hp = DamageModel.revivalHP(current: player.hp, floor: config.revivalHP)
            player.stamina = config.damage.maxStamina
            player.state = .idle
            events.append(.rise(tick: totalTicks, fighter: .player))
        }
        if opponent.state == .knockedDown {
            opponent.hp = DamageModel.revivalHP(current: opponent.hp, floor: config.revivalHP)
            opponent.stamina = config.damage.maxStamina
            opponent.state = .idle
            oppActive = nil
            oppWaitingTicks = scheduler.nextGap()
            events.append(.rise(tick: totalTicks, fighter: .opponent))
        }
        guard outcome == nil else { return }

        if round >= config.rounds {
            finishByDecision()
        } else if config.restTicks <= 0 {
            // No rest window configured: start the next round on the
            // very next tick so the clock stays exactly totalFightTicks.
            beginNextRound()
        } else {
            phase = .resting
            restTicksLeft = config.restTicks
            player.state = .idle
            player.currentMove = .idle
            player.stamina = config.damage.maxStamina
            opponent.state = .idle
            opponent.currentMove = .idle
            opponent.stamina = config.damage.maxStamina
        }
    }

    /// Advance the clock into the next round (used for rest = 0).
    private mutating func beginNextRound() {
        phase = .fighting
        round += 1
        tickInRound = 0
        player.state = .idle
        player.currentMove = .idle
        player.stamina = config.damage.maxStamina
        opponent.state = .idle
        opponent.currentMove = .idle
        opponent.stamina = config.damage.maxStamina
        events.append(.roundStart(tick: totalTicks, round: round))
    }

    private mutating func finishByDecision() {
        let pScore = Scoring.boutScore(stats: playerStats, context: decisionContext(finished: false))
        let oScore = Scoring.boutScore(stats: opponentStats, context: decisionContext(finished: false))
        let result: FightOutcome
        if pScore.points > oScore.points { result = .playerWinByDecision }
        else if oScore.points > pScore.points { result = .playerLossByDecision }
        else { result = .draw }
        finish(outcome: result)
    }

    private func decisionContext(finished: Bool) -> ScoringContext {
        ScoringContext(
            round: round,
            roundsTotal: config.rounds,
            ticks: totalTicks,
            ticksTotal: config.totalFightTicks,
            finished: finished,
            byKO: false
        )
    }

    private mutating func finish(outcome result: FightOutcome) {
        outcome = result
        phase = .over
        events.append(.boutEnd(tick: totalTicks, outcome: result))
    }

    /// Final player score for the bout (with finish bonuses if the
    /// player won; losses and draws score no finish bonus).
    public func playerScore() -> BoutScore {
        Scoring.boutScore(
            stats: playerStats,
            context: ScoringContext(
                round: round,
                roundsTotal: config.rounds,
                ticks: totalTicks,
                ticksTotal: config.totalFightTicks,
                finished: outcome?.isPlayerWin == true,
                byKO: outcome == .playerWinByKO
            )
        )
    }
}

// MARK: - One-shot simulation (the replay contract)

public extension FightEngine {
    /// Simulate a full bout from (seed, input log). The result embeds
    /// the exact input log it consumed, so re-simulating with the same
    /// seed + log must reproduce byte-identical results.
    static func simulate(
        config: EngineConfig = .standard,
        seed: UInt64,
        book: OpponentBook,
        inputs: [PlayerInput]
    ) -> BoutResult {
        var engine = FightEngine(config: config, seed: seed, book: book)
        var index = 0
        var consumed: [PlayerInput] = []
        let cap = config.hardTickCap
        while !engine.isOver && engine.totalTicks < cap {
            let input: PlayerInput = index < inputs.count ? inputs[index] : .none
            engine.tick(input)
            consumed.append(input)
            index += 1
        }
        let outcome = engine.outcome ?? .draw
        return BoutResult(
            seed: seed,
            opponentID: book.id,
            outcome: outcome,
            roundsCompleted: engine.round,
            ticksElapsed: engine.totalTicks,
            playerHP: engine.player.hp,
            opponentHP: engine.opponent.hp,
            playerKnockdowns: engine.player.knockdownCount,
            opponentKnockdowns: engine.opponent.knockdownCount,
            playerStats: engine.playerStats,
            opponentStats: engine.opponentStats,
            events: engine.events,
            score: engine.playerScore(),
            inputLog: consumed
        )
    }
}
