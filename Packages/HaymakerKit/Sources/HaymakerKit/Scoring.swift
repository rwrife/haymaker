/// Deterministic bout scoring + personal-best comparison.
///
/// Scores are integer arithmetic over the per-bout `FighterStats` —
/// same stats, same context, same points, on every platform, forever.
/// The personal-best model treats the bout ledger as append-only and
/// derives bests purely by comparison, so records can never be edited
/// or invented.

/// Bout situation the score is computed in.
public struct ScoringContext: Sendable, Codable, Hashable {
    public let round: Int
    public let roundsTotal: Int
    public let ticks: Int
    public let ticksTotal: Int
    public let finished: Bool
    public let byKO: Bool

    public init(
        round: Int,
        roundsTotal: Int,
        ticks: Int,
        ticksTotal: Int,
        finished: Bool,
        byKO: Bool
    ) {
        self.round = round
        self.roundsTotal = roundsTotal
        self.ticks = ticks
        self.ticksTotal = ticksTotal
        self.finished = finished
        self.byKO = byKO
    }
}

/// A fully decomposed deterministic score.
public struct BoutScore: Sendable, Codable, Hashable {
    public let landedPoints: Int
    public let defensePoints: Int
    public let damagePoints: Int
    public let roundPoints: Int
    public let timePoints: Int
    public let koBonus: Int
    public let finishBonus: Int
    public let points: Int

    public init(
        landedPoints: Int,
        defensePoints: Int,
        damagePoints: Int,
        roundPoints: Int,
        timePoints: Int,
        koBonus: Int,
        finishBonus: Int,
        points: Int
    ) {
        self.landedPoints = landedPoints
        self.defensePoints = defensePoints
        self.damagePoints = damagePoints
        self.roundPoints = roundPoints
        self.timePoints = timePoints
        self.koBonus = koBonus
        self.finishBonus = finishBonus
        self.points = points
    }
}

public enum Scoring {
    /// Integer landed-ratio on a 0...1_000 scale (empty bout = 0).
    static func landedRatio(landed: Int, thrown: Int) -> Int {
        guard thrown > 0 else { return 0 }
        return min(1_000, landed * 1_000 / thrown)
    }

    /// Deterministic score for one fighter's bout stats.
    public static func boutScore(stats: FighterStats, context: ScoringContext) -> BoutScore {
        let landedRatio = landedRatio(landed: stats.landed, thrown: stats.thrown)
        let landedPoints = stats.landed * 10 + landedRatio / 10

        // Defense rewards successful reads: full value for dodges and
        // parries, half for blocks; whiffed opponent swings count too.
        let defensePoints = (stats.dodgesMade + stats.parriesMade) * 15
            + stats.blocksMade * 7
            + stats.counters * 10

        // Damage differential, floor-clamped so a losing round still
        // scores its own landed work (never silent zeros).
        let damagePoints = max(0, stats.damageDealt - stats.damageTaken / 2)

        let roundPoints = context.round * 50
        let timePoints = context.finished ? max(0, (context.ticksTotal - context.ticks) / 20) : 0
        let koBonus = context.byKO ? 500 : 0
        let finishBonus = context.finished ? 200 : 0

        let points = landedPoints + defensePoints + damagePoints
            + roundPoints + timePoints + koBonus + finishBonus

        return BoutScore(
            landedPoints: landedPoints,
            defensePoints: defensePoints,
            damagePoints: damagePoints,
            roundPoints: roundPoints,
            timePoints: timePoints,
            koBonus: koBonus,
            finishBonus: finishBonus,
            points: points
        )
    }
}

// MARK: - Personal bests over an append-only ledger

/// One bout as recorded in the ledger. Records carry their opponent
/// id, so per-opponent derivation is enforceable, not caller-honored.
public struct LedgerEntry: Sendable, Codable, Hashable {
    public let opponentID: String
    public let seed: UInt64
    public let score: Int
    public let outcome: FightOutcome
    public let roundsCompleted: Int
    public let ticksElapsed: Int

    public init(
        opponentID: String,
        seed: UInt64,
        score: Int,
        outcome: FightOutcome,
        roundsCompleted: Int,
        ticksElapsed: Int
    ) {
        self.opponentID = opponentID
        self.seed = seed
        self.score = score
        self.outcome = outcome
        self.roundsCompleted = roundsCompleted
        self.ticksElapsed = ticksElapsed
    }

    init(from result: BoutResult) {
        self.init(
            opponentID: result.opponentID,
            seed: result.seed,
            score: result.score.points,
            outcome: result.outcome,
            roundsCompleted: result.roundsCompleted,
            ticksElapsed: result.ticksElapsed
        )
    }
}

/// The derived personal best for one opponent.
public struct PersonalBest: Sendable, Codable, Hashable {
    public let opponentID: String
    public let seed: UInt64
    public let score: Int
    public let outcome: FightOutcome
    public let roundsCompleted: Int
    public let ticksElapsed: Int

    public init(opponentID: String, seed: UInt64, score: Int, outcome: FightOutcome, roundsCompleted: Int, ticksElapsed: Int) {
        self.opponentID = opponentID
        self.seed = seed
        self.score = score
        self.outcome = outcome
        self.roundsCompleted = roundsCompleted
        self.ticksElapsed = ticksElapsed
    }

    init(opponentID: String, entry: LedgerEntry) {
        self.init(
            opponentID: opponentID,
            seed: entry.seed,
            score: entry.score,
            outcome: entry.outcome,
            roundsCompleted: entry.roundsCompleted,
            ticksElapsed: entry.ticksElapsed
        )
    }
}

/// How a finished bout compares against the stored best.
public enum BestComparison: String, Sendable, Codable, Hashable {
    /// No history for this opponent yet — every bout sets the first best.
    case firstBout
    /// Strictly better than the stored best (wins break ties on score).
    case newPersonalBest
    /// Matched the stored best score but improved the finish (e.g. KO
    /// where the best went to decision, or fewer rounds).
    case matchedBetterFinish
    /// No improvement — the old record stands.
    case noImprovement

    public var shouldStore: Bool {
        switch self {
        case .firstBout, .newPersonalBest, .matchedBetterFinish: return true
        case .noImprovement: return false
        }
    }
}

/// Append-only bout ledger. Entries are never removed or edited; the
/// personal best for any opponent is *derived* by folding the ledger
/// with `BestRecord.compare`, never stored as an independent truth.
public struct BoutLedger: Sendable, Codable, Hashable {
    public private(set) var entries: [LedgerEntry]

    public init(entries: [LedgerEntry] = []) {
        self.entries = entries
    }

    /// The only mutation: append one finished bout.
    public mutating func append(_ result: BoutResult) {
        entries.append(LedgerEntry(from: result))
    }

    /// Derived best for one opponent — `nil` iff that opponent has no
    /// recorded bouts. Opponent identity is enforced by filtering on
    /// `opponentID`, so one opponent's record can never leak into
    /// another's.
    public func best(for opponentID: String) -> PersonalBest? {
        var running: PersonalBest?
        for entry in entries where entry.opponentID == opponentID {
            let candidate = PersonalBest(opponentID: opponentID, entry: entry)
            guard let current = running else { running = candidate; continue }
            let verdict = BestRecord.compare(
                score: candidate.score, outcome: candidate.outcome,
                roundsCompleted: candidate.roundsCompleted, ticksElapsed: candidate.ticksElapsed,
                to: current
            )
            if verdict.shouldStore { running = candidate }
        }
        return running
    }

    /// How a bout measures against this opponent's derived best.
    public func comparison(for result: BoutResult) -> BestComparison {
        BestRecord.compare(
            score: result.score.points, outcome: result.outcome,
            roundsCompleted: result.roundsCompleted, ticksElapsed: result.ticksElapsed,
            to: best(for: result.opponentID)
        )
    }
}

public enum BestRecord {
    /// Compare a candidate record against the current best. Pure and
    /// total: a `nil` best is a legal input with a defined answer.
    public static func compare(
        score: Int,
        outcome: FightOutcome,
        roundsCompleted: Int,
        ticksElapsed: Int,
        to best: PersonalBest?
    ) -> BestComparison {
        guard let best else { return .firstBout }
        if score > best.score { return .newPersonalBest }
        if score == best.score, betterFinish(
            outcome: outcome, roundsCompleted: roundsCompleted, ticksElapsed: ticksElapsed,
            than: best
        ) { return .matchedBetterFinish }
        return .noImprovement
    }

    /// Tie-break ordering for equal scores: KO beats decision, decision
    /// beats draw/loss classes, fewer rounds beats more, fewer ticks
    /// beats more.
    static func betterFinish(
        outcome: FightOutcome,
        roundsCompleted: Int,
        ticksElapsed: Int,
        than best: PersonalBest
    ) -> Bool {
        let incoming = finishRank(outcome)
        let stored = finishRank(best.outcome)
        if incoming != stored { return incoming > stored }
        if roundsCompleted != best.roundsCompleted { return roundsCompleted < best.roundsCompleted }
        return ticksElapsed < best.ticksElapsed
    }

    static func finishRank(_ outcome: FightOutcome) -> Int {
        switch outcome {
        case .playerWinByKO: return 3
        case .playerWinByDecision: return 2
        case .draw: return 1
        case .playerLossByDecision, .playerLossByKO: return 0
        }
    }
}
