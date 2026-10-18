import Foundation

/// A session's career ladder: the story opponents in a random order, each
/// stage tuned slightly harder than the one before.
///
/// Pure and deterministic given a random number generator, so the app can pass
/// the system generator while tests pass a seeded one. Nothing here touches the
/// fight engine's own seeded RNG.
public enum Ladder {
    /// The champion always closes the ladder.
    public static var finalBoss: OpponentBook { .baxter }

    /// Everyone except the final boss, in authored order.
    public static var contenders: [OpponentBook] {
        OpponentBook.careerRoster.filter { $0.id != finalBoss.id }
    }

    /// Contenders shuffled, followed by the final boss. Unscaled.
    public static func order<G: RandomNumberGenerator>(using generator: inout G) -> [OpponentBook] {
        contenders.shuffled(using: &generator) + [finalBoss]
    }

    /// Scales each book by its position: stage 0 is a little gentler than the
    /// authored book, the last stage a little harder.
    public static func stages(for order: [OpponentBook]) -> [OpponentBook] {
        let last = max(order.count - 1, 1)
        return order.enumerated().map { index, book in
            book.scaled(difficulty: Double(index) / Double(last))
        }
    }

    /// A fresh random, progressively harder ladder.
    public static func make<G: RandomNumberGenerator>(using generator: inout G) -> [OpponentBook] {
        stages(for: order(using: &generator))
    }

    /// The authored story order with the same difficulty curve. Used for
    /// predictable UI tests.
    public static func authored() -> [OpponentBook] {
        stages(for: OpponentBook.careerRoster)
    }
}

public extension OpponentBook {
    /// A copy tuned to `difficulty` in `0...1` (0 easiest, 1 hardest).
    ///
    /// Tells, recoveries and idle gaps shrink and damage grows. Impact timing
    /// and stamina cost are untouched, and tells never drop below
    /// `minimumTell`, so every punch stays readable. The id and name are kept,
    /// so portraits, bios and records still match the character.
    func scaled(difficulty: Double) -> OpponentBook {
        let d = min(max(difficulty, 0), 1)
        let timing = 1.12 - 0.34 * d
        let power = 0.88 + 0.32 * d
        func ticks(_ value: Int, floor: Int) -> Int { max(Int((Double(value) * timing).rounded()), min(value, floor)) }
        let entries = sequence.map { entry in
            PatternEntry(
                move: entry.move,
                tell: ticks(entry.tell, floor: Self.minimumTell),
                impact: entry.impact,
                recover: ticks(entry.recover, floor: Self.minimumRecover),
                staminaCost: entry.staminaCost,
                damage: entry.damage == 0 ? 0 : max(Int((Double(entry.damage) * power).rounded()), 1)
            )
        }
        return OpponentBook(id: id, name: name, sequence: entries,
                            minGap: ticks(minGap, floor: 0), gapSpread: ticks(gapSpread, floor: 0))
    }

    /// Shortest tell a scaled book may have, in ticks.
    static let minimumTell = 18
    /// Shortest recovery a scaled book may have, in ticks.
    static let minimumRecover = 8
}
