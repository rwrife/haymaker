import Foundation
import GRDB
import HaymakerKit

public enum BoutMode: String, Codable, Sendable { case career, sparring }

/// Snapshots preserve the rules and inputs needed to replay historical bouts.
public struct SavedBout: Codable, Sendable, Identifiable {
    public let id: String
    public let mode: BoutMode
    public let runID: String?
    public let runRound: Int?
    public let result: BoutResult

    public init(id: String = UUID().uuidString, mode: BoutMode, runID: String? = nil,
                runRound: Int? = nil, result: BoutResult) {
        self.id = id; self.mode = mode; self.runID = runID; self.runRound = runRound; self.result = result
    }
}

public struct Records: Sendable {
    public let bouts: [SavedBout]
    public init(bouts: [SavedBout] = []) { self.bouts = bouts }
    public var ledger: BoutLedger {
        var ledger = BoutLedger()
        for bout in bouts { ledger.append(bout.result) }
        return ledger
    }
    public func wins(_ opponentID: String, careerOnly: Bool = false) -> Int {
        bouts.filter { $0.result.opponentID == opponentID && (!careerOnly || $0.mode == .career)
            && $0.result.outcome.isPlayerWin }.count
    }
    public func isUnlocked(_ opponentID: String) -> Bool {
        guard let index = OpponentBook.v0Roster.firstIndex(where: { $0.id == opponentID }) else { return false }
        return OpponentBook.v0Roster.prefix(index).allSatisfy { wins($0.id, careerOnly: true) > 0 }
    }
    public func fastestKO(_ opponentID: String) -> BoutResult? {
        history(opponentID).map(\.result).filter { $0.outcome == .playerWinByKO }
            .min { $0.ticksElapsed < $1.ticksElapsed }
    }
    public func history(_ opponentID: String) -> [SavedBout] { bouts.filter { $0.result.opponentID == opponentID } }
    public func run(_ id: String) -> [SavedBout] { bouts.filter { $0.mode == .sparring && $0.runID == id } }
}

/// All history is local. Database triggers enforce immutability even outside this API.
public final class BoutStore: Sendable {
    private let database: DatabaseQueue
    public init(path: String = ":memory:") throws {
        database = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_bout_ledger") { db in
            try db.execute(sql: "CREATE TABLE bouts (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        }
        migrator.registerMigration("v2_append_only") { db in
            try db.execute(sql: """
                CREATE TRIGGER bouts_no_replace BEFORE INSERT ON bouts
                WHEN EXISTS (SELECT 1 FROM bouts WHERE id = NEW.id OR rowid = NEW.rowid)
                BEGIN SELECT RAISE(ABORT, 'append-only ledger'); END;
                CREATE TRIGGER bouts_no_update BEFORE UPDATE ON bouts BEGIN SELECT RAISE(ABORT, 'append-only ledger'); END;
                CREATE TRIGGER bouts_no_delete BEFORE DELETE ON bouts BEGIN SELECT RAISE(ABORT, 'append-only ledger'); END;
                """)
        }
        try migrator.migrate(database)
    }
    public func append(_ bout: SavedBout) throws {
        let data = try JSONEncoder().encode(bout)
        try database.write { db in
            try db.execute(sql: "INSERT INTO bouts (id, payload) VALUES (?, ?)", arguments: [bout.id, data])
        }
    }
    public func records() throws -> Records {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM bouts ORDER BY rowid")
            return Records(bouts: try rows.map { row in
                let data: Data = row["payload"]
                return try JSONDecoder().decode(SavedBout.self, from: data)
            })
        }
    }
}
