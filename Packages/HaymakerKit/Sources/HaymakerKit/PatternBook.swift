import Foundation

/// Data-driven opponent telegraph sequences.
///
/// A `PatternBook` is pure data: an opponent id, a fixed sequence of
/// pattern entries (move + tell window + impact + recovery), and a
/// seeded inter-move gap policy. The fight engine only ever asks the
/// scheduler "what's next?" — nothing else sees the RNG except gap
/// spacing, which keeps the readable tell rhythm intact while still
/// varying pacing deterministically per seed.
///
/// Speed is expressed in engine ticks (integer-only, no wall-clock).
/// Longer `tell` = easier to read; tighter `tell` = harder opponent.

/// One entry in an opponent's move book.
public struct PatternEntry: Sendable, Codable, Hashable {
    /// The move the opponent commits to after its tell.
    public let move: Move
    /// Length of the readable tell window, in ticks.
    public let tell: Int
    /// Ticks between commit and impact once the tell completes.
    public let impact: Int
    /// Vulnerable recovery window after impact (or after a feint).
    public let recover: Int
    /// Stamina cost to throw this move.
    public let staminaCost: Int
    /// Base damage at impact (before defense/counter modifiers).
    public let damage: Int

    public init(
        move: Move,
        tell: Int,
        impact: Int,
        recover: Int,
        staminaCost: Int,
        damage: Int
    ) {
        precondition(tell > 0 && impact >= 0 && recover > 0, "pattern windows must be positive (impact may be 0 for feints)")
        precondition(staminaCost >= 0, "stamina cost must be non-negative")
        precondition(move == .feint || impact > 0, "only feints may have zero impact")
        precondition(move == .feint || move == .block || damage > 0, "only feints/blocks may have zero damage")
        self.move = move
        self.tell = tell
        self.impact = impact
        self.recover = recover
        self.staminaCost = staminaCost
        self.damage = damage
    }
}

/// One opponent's full book.
public struct OpponentBook: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// The repeating telegraph sequence.
    public let sequence: [PatternEntry]
    /// Minimum idle gap ticks between committed patterns.
    public let minGap: Int
    /// Extra gap ticks chosen from `0...spread` per pattern via the
    /// bout's seeded RNG.
    public let gapSpread: Int

    public init(
        id: String,
        name: String,
        sequence: [PatternEntry],
        minGap: Int = 6,
        gapSpread: Int = 8
    ) {
        precondition(!sequence.isEmpty, "an opponent book needs at least one pattern")
        precondition(minGap >= 0 && gapSpread >= 0, "gaps must be non-negative")
        self.id = id
        self.name = name
        self.sequence = sequence
        self.minGap = minGap
        self.gapSpread = gapSpread
    }
}

/// Deterministic scheduler that walks an `OpponentBook` in order.
///
/// The sequence pointer is strictly positional — same book, same count
/// of issued patterns, always the same moves in the same order. The
/// seeded RNG is only consulted for the idle gap *before* each entry,
/// so "same seed → same bout" holds for both rhythm and content.
public struct PatternScheduler: Sendable {
    public let book: OpponentBook
    private var nextIndex: Int
    private var rng: SeededRNG

    public init(book: OpponentBook, seed: UInt64) {
        self.book = book
        self.nextIndex = 0
        self.rng = SeededRNG(seed: seed ^ 0x5EED_1B00_0000_0000)
    }

    /// Number of patterns issued so far (test hook for determinism).
    public private(set) var issuedCount: Int = 0

    /// Next entry in sequence order. Never random in *content*.
    public mutating func nextEntry() -> PatternEntry {
        let entry = book.sequence[nextIndex]
        nextIndex = (nextIndex + 1) % book.sequence.count
        issuedCount += 1
        return entry
    }

    /// Look at the next entry WITHOUT consuming it — the engine peeks
    /// the stamina cost before committing, so an exhausted opponent
    /// visibly pauses instead of burning a sequence slot.
    func peekEntry() -> PatternEntry {
        book.sequence[nextIndex]
    }

    /// Rewind the sequence pointer to `entryIndex`. Internal seam used
    /// by the engine's deterministic scenario setup (state tables in
    /// tests) — never part of the public replay contract.
    mutating func rewind(to entryIndex: Int) {
        precondition(book.sequence.indices.contains(entryIndex), "pattern index out of range")
        nextIndex = entryIndex
    }

    /// Seeded idle gap to wait before the next entry becomes live.
    public mutating func nextGap() -> Int {
        book.minGap + rng.next(lessThan: book.gapSpread + 1)
    }
}

// MARK: - v0 roster (the first two authored opponents)
//
// All names are original codenames — no real boxers, gyms, or
// existing-game characters are referenced anywhere.

public extension OpponentBook {
    /// Bout 1 — a fast, telegraphic jab boxer. Long tells, light
    /// damage, teaches dodge-and-counter timing.
    static let twitch = OpponentBook(
        id: "twitch",
        name: "Twitch",
        sequence: [
            PatternEntry(move: .jab, tell: 10, impact: 4, recover: 10, staminaCost: 4, damage: 6),
            PatternEntry(move: .jab, tell: 10, impact: 4, recover: 10, staminaCost: 4, damage: 6),
            PatternEntry(move: .feint, tell: 6, impact: 0, recover: 8, staminaCost: 3, damage: 0),
            PatternEntry(move: .block, tell: 6, impact: 18, recover: 8, staminaCost: 6, damage: 0),
            PatternEntry(move: .jab, tell: 9, impact: 4, recover: 12, staminaCost: 4, damage: 6),
            PatternEntry(move: .hook, tell: 14, impact: 6, recover: 16, staminaCost: 8, damage: 12),
        ],
        minGap: 6,
        gapSpread: 10
    )

    /// Bout 2 — a heavy-hitting power puncher. Shorter tells, feints
    /// that punish greedy counters, long recoveries to exploit.
    static let anvil = OpponentBook(
        id: "anvil",
        name: "Anvil",
        sequence: [
            PatternEntry(move: .hook, tell: 12, impact: 6, recover: 18, staminaCost: 9, damage: 14),
            PatternEntry(move: .feint, tell: 5, impact: 0, recover: 10, staminaCost: 4, damage: 0),
            PatternEntry(move: .jab, tell: 8, impact: 4, recover: 10, staminaCost: 5, damage: 7),
            PatternEntry(move: .uppercut, tell: 16, impact: 8, recover: 24, staminaCost: 14, damage: 22),
            PatternEntry(move: .hook, tell: 11, impact: 6, recover: 18, staminaCost: 9, damage: 14),
            PatternEntry(move: .jab, tell: 8, impact: 4, recover: 10, staminaCost: 5, damage: 7),
        ],
        minGap: 4,
        gapSpread: 8
    )

    /// The v0 authored roster in ladder order.
    static let v0Roster: [OpponentBook] = [.twitch, .anvil]
}

// A readable, heavyweight arcade rhythm for the Metal arena. Existing roster
// books remain unchanged so stored engine snapshots and replays stay valid.
public extension OpponentBook {
    static let baxter = OpponentBook(
        id: "baxter", name: "Bruiser Baxter",
        sequence: [
            PatternEntry(move: .jab, tell: 42, impact: 12, recover: 32, staminaCost: 5, damage: 8),
            PatternEntry(move: .hook, tell: 54, impact: 16, recover: 46, staminaCost: 10, damage: 16),
            PatternEntry(move: .feint, tell: 32, impact: 0, recover: 16, staminaCost: 3, damage: 0),
            PatternEntry(move: .jab, tell: 34, impact: 10, recover: 26, staminaCost: 5, damage: 8),
            PatternEntry(move: .block, tell: 28, impact: 65, recover: 30, staminaCost: 6, damage: 0),
            PatternEntry(move: .uppercut, tell: 60, impact: 18, recover: 54, staminaCost: 14, damage: 22),
        ], minGap: 32, gapSpread: 24
    )
}
