import Foundation
import Testing
import GRDB
import HaymakerKit
@testable import HaymakerStore

@Suite("Local bout ledger")
struct HaymakerStoreTests {
    func result(_ book: OpponentBook = .twitch, inputs: [PlayerInput] = []) -> BoutResult {
        FightEngine.simulate(config: EngineConfig(rounds: 1, roundTicks: 120, restTicks: 0),
                             seed: UInt64.max, book: book, inputs: inputs)
    }

    @Test func appendReopenAndReplay() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bout = SavedBout(id: "one", mode: .sparring, runID: "run", runRound: 1, result: result())
        let store = try BoutStore(path: path)
        try store.append(bout)
        #expect(throws: (any Error).self) { try store.append(bout) }
        let records = try BoutStore(path: path).records()
        #expect(records.bouts.count == 1)
        let saved = try #require(records.bouts.first).result
        #expect(saved == FightEngine.simulate(config: saved.config, seed: saved.seed, book: saved.book, inputs: saved.inputLog))
        #expect(records.run("run").count == 1)
        #expect(records.ledger.best(for: "anvil") == nil)
    }

    @Test func migrateCommittedV1FixtureAndProtectHistory() throws {
        let fixture = try #require(Bundle.module.url(forResource: "v1", withExtension: "sqlite", subdirectory: "Fixtures"))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        // Migrate the committed historical row, preserving its bytes and rule snapshot.
        let database = try DatabaseQueue(path: copy.path)
        let payload = try database.read { db in
            let data = try Data.fetchOne(db, sql: "SELECT payload FROM bouts WHERE id = 'legacy'")
            return try #require(data)
        }
        let old = try JSONDecoder().decode(SavedBout.self, from: payload)
        #expect(old.id == "legacy")
        #expect(old.result == FightEngine.simulate(config: old.result.config, seed: old.result.seed,
                                                   book: old.result.book, inputs: old.result.inputLog))
        let store = try BoutStore(path: copy.path)
        #expect(try store.records().bouts.first?.result == old.result)
        try database.read { db in
            let storedPayload = try Data.fetchOne(db, sql: "SELECT payload FROM bouts")
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            #expect(storedPayload == payload)
            #expect(migrations == ["v1_bout_ledger", "v2_append_only"])
        }
        #expect(throws: (any Error).self) { try database.write { try $0.execute(sql: "UPDATE bouts SET id = 'changed'") } }
        #expect(throws: (any Error).self) { try database.write { try $0.execute(sql: "DELETE FROM bouts") } }
        #expect(throws: (any Error).self) {
            try database.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO bouts VALUES (?, ?)", arguments: [old.id, payload])
            }
        }
        try store.append(SavedBout(mode: .career, result: result(.anvil)))
        #expect(try BoutStore(path: copy.path).records().bouts.count == 2)
    }

    @Test func unknownRecordsAndCareerLocks() {
        let empty = Records()
        let loss = result()
        #expect(!loss.outcome.isPlayerWin)
        #expect(!Records(bouts: [SavedBout(mode: .career, result: loss)]).isUnlocked("anvil"))
        #expect(empty.fastestKO("twitch") == nil)
        #expect(empty.ledger.best(for: "twitch") == nil)
        #expect(empty.isUnlocked("twitch"))
        #expect(!empty.isUnlocked("anvil"))
        #expect(!empty.isUnlocked("unknown"))
        // Exhaustively find a deterministic winning input sequence rather than fabricate a result.
        let win = FightEngine.simulate(config: EngineConfig(rounds: 1, roundTicks: 600, restTicks: 0),
                                      seed: 42, book: .twitch, inputs: Array(repeating: .jab, count: 600))
        #expect(win.outcome == .playerWinByKO || win.outcome == .playerWinByDecision)
        let sparring = Records(bouts: [SavedBout(mode: .sparring, result: win)])
        #expect(!sparring.isUnlocked("anvil"))
        let career = Records(bouts: [SavedBout(mode: .career, result: win)])
        #expect(career.isUnlocked("anvil"))
        #expect(!career.isUnlocked("lattice"))
        #expect(career.ledger.comparison(for: win) == .noImprovement)
    }
    @Test func fullLadderUnlocksOnlyInOrderAndSparringRunsStaySeparate() throws {
        let store = try BoutStore()
        let config = EngineConfig.standard
        for (index, book) in OpponentBook.v0Roster.enumerated() {
            let before = try store.records()
            #expect(before.isUnlocked(book.id))
            if index + 1 < OpponentBook.v0Roster.count {
                #expect(!before.isUnlocked(OpponentBook.v0Roster[index + 1].id))
            }
            // One button press every 32 ticks (fewer than two presses/second), with no
            // hidden state mutation or custom move/damage configuration.
            var engine = FightEngine(config: config, seed: 0xCAFE_2026, book: book)
            var inputs: [PlayerInput] = []
            while !engine.isOver && inputs.count < config.hardTickCap {
                let input: PlayerInput = inputs.count % 32 == 0 ? .uppercut : .none
                inputs.append(input)
                engine.tick(input)
            }
            #expect(engine.isOver)
            let win = FightEngine.simulate(config: config, seed: engine.seed, book: book, inputs: inputs)
            #expect(win.config == .standard)
            #expect(win.events == engine.events)
            #expect(win.inputLog == inputs)
            #expect(win.outcome.isPlayerWin, "\(book.name): \(win.outcome)")
            try store.append(SavedBout(mode: .career, result: win))
        }
        let records = try store.records()
        #expect(OpponentBook.v0Roster.allSatisfy { records.isUnlocked($0.id) && records.wins($0.id, careerOnly: true) == 1 })
        try store.append(SavedBout(mode: .sparring, runID: "a", runRound: 1, result: result()))
        try store.append(SavedBout(mode: .sparring, runID: "a", runRound: 2, result: result()))
        try store.append(SavedBout(mode: .sparring, runID: "b", runRound: 1, result: result(.anvil)))
        #expect(try store.records().run("a").map(\.runRound) == [1, 2])
        #expect(try store.records().run("b").count == 1)
    }

}
