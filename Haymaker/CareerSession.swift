import Foundation
import Observation
import HaymakerKit
import HaymakerStore

@MainActor @Observable final class CareerSession {
    private var store: BoutStore?
    private(set) var records = Records()
    private(set) var historyLoaded = false
    private(set) var error: String?
    private(set) var comparison: BestComparison?
    private(set) var saved = false
    var opponent = OpponentBook.goldie
    /// This session's career ladder: random order, each stage harder than the last.
    private(set) var ladder: [OpponentBook]
    /// Number of saved bouts before this ladder began, so progress only counts bouts fought on it.
    private var ladderStart: Int?
    var mode = BoutMode.career
    private(set) var runID: String?
    private(set) var runRound = 1
    private var pendingBout: SavedBout?
    private(set) var hasUnsavedResult = false
    let baseSeed: UInt64 = 0xCAFE_2026

    private let storeFactory: () throws -> BoutStore
    private let appendBout: (BoutStore, SavedBout) throws -> Void
    private let ladderFactory: () -> [OpponentBook]

    init(storeFactory: @escaping () throws -> BoutStore = CareerSession.openStore,
         appendBout: @escaping (BoutStore, SavedBout) throws -> Void = { try $0.append($1) },
         ladderFactory: @escaping () -> [OpponentBook] = CareerSession.makeLadder) {
        self.storeFactory = storeFactory
        self.appendBout = appendBout
        self.ladderFactory = ladderFactory
        ladder = ladderFactory()
        do {
            let openedStore = try storeFactory()
            records = try openedStore.records()
            store = openedStore
            historyLoaded = true
            ladderStart = records.bouts.count
        } catch { self.error = "Local records unavailable: \(error.localizedDescription)" }
    }
    func reloadHistory() {
        guard !hasUnsavedResult else { return }
        do {
            let reopened = try storeFactory()
            records = try reopened.records()
            store = reopened
            historyLoaded = true
            if ladderStart == nil { ladderStart = records.bouts.count }
            error = nil
        } catch { self.error = "Local records unavailable: \(error.localizedDescription)" }
    }
    /// Random order each session; UI tests get the authored order so journeys stay predictable.
    nonisolated private static func makeLadder() -> [OpponentBook] {
        if ProcessInfo.processInfo.arguments.contains("-haymakerUITestIsolatedStore") {
            return Ladder.authored()
        }
        var generator = SystemRandomNumberGenerator()
        return Ladder.make(using: &generator)
    }
    /// Career wins on the current ladder only; earlier sessions have different orders and difficulty.
    private var ladderRecords: Records { Records(bouts: Array(records.bouts.dropFirst(ladderStart ?? 0))) }
    func isBeaten(_ id: String) -> Bool { ladderRecords.wins(id, careerOnly: true) > 0 }
    func isUnlocked(_ id: String) -> Bool { historyLoaded && ladderRecords.isUnlocked(id, in: ladder) }
    var ladderComplete: Bool { historyLoaded && ladder.allSatisfy { isBeaten($0.id) } }
    /// The first unlocked opponent on the ladder that has not been beaten yet.
    var nextLadderBook: OpponentBook? { ladder.first { isUnlocked($0.id) && !isBeaten($0.id) } }
    /// Draws a fresh random ladder and starts progress over.
    @discardableResult func newLadder() -> Bool {
        guard !hasUnsavedResult else { return false }
        ladder = ladderFactory()
        ladderStart = records.bouts.count
        return true
    }
    nonisolated private static func openStore() throws -> BoutStore {
        if ProcessInfo.processInfo.arguments.contains("-haymakerUITestIsolatedStore") {
            return try BoutStore()
        }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        return try BoutStore(path: directory.appendingPathComponent("bouts.sqlite").path)
    }
    @discardableResult func begin(_ book: OpponentBook, mode: BoutMode) -> Bool {
        guard !hasUnsavedResult, mode != .career || historyLoaded else { return false }
        opponent = book; self.mode = mode
        runID = mode == .sparring ? UUID().uuidString : nil
        runRound = 1; resetResult()
        return true
    }
    @discardableResult func nextRound() -> Bool {
        guard saved else { return false }
        runRound += 1; resetResult()
        return true
    }
    private func resetResult() { saved = false; comparison = nil; pendingBout = nil }
    var seed: UInt64 { baseSeed &+ UInt64(runRound - 1) }
    var runBouts: [SavedBout] { runID.map { records.run($0) } ?? [] }
    func save(_ session: FightSession) {
        guard session.engine.isOver, !saved else { return }
        hasUnsavedResult = true
        do {
            if store == nil {
                let reopened = try storeFactory()
                records = try reopened.records()
                store = reopened
                historyLoaded = true
                if ladderStart == nil { ladderStart = records.bouts.count }
            }
            guard let store else { return }
            if pendingBout == nil {
                let result = FightEngine.simulate(config: session.engine.config, seed: session.engine.seed,
                                                 book: session.engine.book, inputs: session.inputLog)
                comparison = records.ledger.comparison(for: result)
                pendingBout = SavedBout(mode: mode, runID: runID, runRound: mode == .sparring ? runRound : nil, result: result)
            }
            guard let bout = pendingBout else { return }
            try appendBout(store, bout)
            records = Records(bouts: records.bouts + [bout])
            saved = true
            hasUnsavedResult = false
            error = nil
        } catch { self.error = "Could not save local result: \(error.localizedDescription)" }
    }
}
