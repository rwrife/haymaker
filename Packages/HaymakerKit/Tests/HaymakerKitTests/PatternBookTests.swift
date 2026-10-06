import Testing
@testable import HaymakerKit

@Suite("PatternBook: sequence order + seeded gap determinism")
struct PatternBookTests {
    @Test("v0 roster carries the first two authored opponents in order")
    func roster() {
        #expect(OpponentBook.v0Roster.map(\.id) == ["twitch", "anvil"])
        #expect(OpponentBook.twitch.sequence.count == 6)
        #expect(OpponentBook.anvil.sequence.count == 6)
    }

    @Test("feints carry zero impact/damage; blocks hold with zero damage; attacks carry both")
    func feintShape() {
        for book in OpponentBook.v0Roster {
            for entry in book.sequence {
                switch entry.move {
                case .feint:
                    #expect(entry.impact == 0 && entry.damage == 0)
                case .block:
                    #expect(entry.impact > 0 && entry.damage == 0)
                default:
                    #expect(entry.impact > 0 && entry.damage > 0)
                }
            }
        }
    }

    @Test("scheduler walks the book in fixed sequence order and wraps forever")
    func sequenceWalk() {
        let book = OpponentBook.anvil
        var scheduler = PatternScheduler(book: book, seed: 42)
        for i in 0..<(book.sequence.count * 3 + 2) {
            let entry = scheduler.nextEntry()
            #expect(entry.move == book.sequence[i % book.sequence.count].move)
        }
        #expect(scheduler.issuedCount == book.sequence.count * 3 + 2)
    }

    @Test("same seed -> same gap sequence; different seed -> different gaps")
    func gapDeterminism() {
        var a = PatternScheduler(book: .twitch, seed: 7)
        var b = PatternScheduler(book: .twitch, seed: 7)
        var gapsA: [Int] = []
        var gapsB: [Int] = []
        for _ in 0..<64 { gapsA.append(a.nextGap()); gapsB.append(b.nextGap()) }
        #expect(gapsA == gapsB)

        var c = PatternScheduler(book: .twitch, seed: 8)
        let gapsC = (0..<64).map { _ in c.nextGap() }
        #expect(gapsA != gapsC)
    }

    @Test("gaps stay inside [minGap, minGap + gapSpread]")
    func gapBounds() {
        for seed: UInt64 in [0, 1, 999, .max] {
            var scheduler = PatternScheduler(book: .anvil, seed: seed)
            for _ in 0..<200 {
                let gap = scheduler.nextGap()
                #expect(gap >= OpponentBook.anvil.minGap)
                #expect(gap <= OpponentBook.anvil.minGap + OpponentBook.anvil.gapSpread)
            }
        }
    }
}

@Suite("SeededRNG: determinism + bounds")
struct SeededRNGTests {
    @Test("same seed reproduces the same 64-value stream")
    func sameStream() {
        var a = SeededRNG(seed: 1234)
        var b = SeededRNG(seed: 1234)
        let streamA = (0..<64).map { _ in a.next() }
        let streamB = (0..<64).map { _ in b.next() }
        #expect(streamA == streamB)
    }

    @Test("zero seed is not a fixed point")
    func zeroSeedGuard() {
        var rng = SeededRNG(seed: 0)
        #expect(rng.next() != 0)
    }

    @Test("bounded draws stay in range")
    func boundedRange() {
        var rng = SeededRNG(seed: 77)
        for _ in 0..<1_000 {
            #expect(rng.next(lessThan: 9) >= 0)
            #expect(rng.next(lessThan: 9) < 9)
        }
    }
}
