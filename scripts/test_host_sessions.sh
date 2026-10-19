#!/usr/bin/env bash
# Compile the actual app session adapters against the packages on a Swift host.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=${HAYMAKER_PROBE_SCRATCH:-$TMPDIR}
mkdir -p "$scratch"
probe=$(mktemp -d "$scratch/hm4-session-probe.XXXXXX")
trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe/Sources/Probe"
cp "$root/Haymaker/CareerSession.swift" "$root/Haymaker/FightSession.swift" "$probe/Sources/Probe/"
ln -s "$root/Packages" "$probe/Packages"
cat > "$probe/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Probe", platforms: [.macOS(.v14)], dependencies: [.package(path: "Packages/HaymakerKit"), .package(path: "Packages/HaymakerStore")], targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "HaymakerKit", package: "HaymakerKit"), .product(name: "HaymakerStore", package: "HaymakerStore")])])
PACKAGE
cat > "$probe/Sources/Probe/Probe.swift" <<'SWIFT'
import Foundation
import HaymakerKit
import HaymakerStore
@main struct Probe {
    @MainActor static func main() throws {
        struct Failure: Error {}
        var failing = true
        var ids: [String] = []
        let career = CareerSession(storeFactory: { try BoutStore() }, appendBout: { store, bout in
            ids.append(bout.id)
            if failing { throw Failure() }
            try store.append(bout)
        })
        precondition(career.begin(.twitch, mode: .sparring))
        let fight = FightSession(shortUITestBout: true)
        for _ in 0..<700 { fight.advance() }
        precondition(fight.engine.isOver)
        career.save(fight)
        let run = career.runID
        precondition(!career.saved && career.hasUnsavedResult && career.error != nil)
        precondition(!career.begin(.anvil, mode: .career) && !career.nextRound())
        precondition(career.runID == run && career.runRound == 1 && career.opponent.id == "twitch")
        failing = false
        career.save(fight)
        precondition(career.saved && !career.hasUnsavedResult && career.error == nil)
        precondition(ids.count == 2 && ids[0] == ids[1] && career.records.bouts.count == 1)
        career.save(fight)
        precondition(ids.count == 2)
        precondition(career.nextRound())
        let paused = FightSession()
        paused.submit(.jab)
        for flags in [(true, false, true), (false, true, true), (true, true, true), (false, false, false)] {
            for _ in 0..<120 {
                precondition(!paused.advanceIfActive(settingsPresented: flags.0, recordsPresented: flags.1, sceneActive: flags.2))
            }
            precondition(paused.engine.totalTicks == 0 && paused.inputLog.isEmpty)
            precondition(paused.engine.player.hp == EngineConfig.standard.damage.maxHP)
        }
        precondition(paused.advanceIfActive(settingsPresented: false, recordsPresented: false, sceneActive: true))
        precondition(paused.engine.totalTicks == 1 && paused.inputLog == [.jab])
        precondition(!fight.advanceIfActive(settingsPresented: false, recordsPresented: false, sceneActive: true))
        print("PASS: Records/Settings/background pause ticks, health and queued input; dismissal resumes; completed bouts stay stopped")
        var unavailable = true
        let history = CareerSession(storeFactory: {
            if unavailable { throw Failure() }
            return try BoutStore()
        })
        precondition(!history.historyLoaded && history.error != nil)
        precondition(!history.begin(.twitch, mode: .career))
        history.reloadHistory()
        precondition(!history.historyLoaded)
        unavailable = false
        history.reloadHistory()
        precondition(history.historyLoaded && history.error == nil && history.records.bouts.isEmpty)
        precondition(history.begin(.twitch, mode: .career))
        print("PASS: unavailable history blocks career; failed reload stays unavailable; successful empty load enables career")
        print("PASS: failed save prevents begin/nextRound; retry preserves ID; saves once; saved navigation resumes")

        func complete(_ book: OpponentBook, attacking: Bool = true) -> FightSession {
            let session = FightSession(seed: 0xCAFE_2026, book: book, shortUITestBout: true)
            for _ in 0..<session.engine.config.hardTickCap {
                if session.engine.isOver { break }
                if attacking { session.submit(.jab) }
                session.advance()
            }
            precondition(session.engine.isOver && session.replayMatches)
            return session
        }
        let ladderStore = try BoutStore()
        try ladderStore.append(SavedBout(mode: .career, result: FightEngine.simulate(
            seed: 7, book: .goldie, inputs: []
        )))
        var failFinalSave = false
        let ladder = CareerSession(storeFactory: { ladderStore }, appendBout: { store, bout in
            if failFinalSave { throw Failure() }
            try store.append(bout)
        }, ladderFactory: Ladder.authored)
        precondition(ladder.ladderSummary.bouts == 0 && !ladder.canCelebrateVictory)
        precondition(ladder.begin(.goldie, mode: .sparring))
        ladder.save(complete(.goldie))
        precondition(ladder.saved && ladder.ladderSummary.bouts == 0 && !ladder.ladderComplete)

        var expected: [BoutResult] = []
        let loss = complete(ladder.ladder[0], attacking: false)
        precondition(!loss.engine.outcome!.isPlayerWin)
        precondition(ladder.begin(ladder.ladder[0], mode: .career))
        ladder.save(loss)
        expected.append(ladder.records.bouts.last!.result)
        precondition(!ladder.ladderComplete && !ladder.canCelebrateVictory)
        for (index, book) in ladder.ladder.enumerated() {
            precondition(ladder.nextLadderBook?.id == book.id)
            precondition(ladder.begin(book, mode: .career))
            let win = complete(book)
            precondition(win.engine.outcome!.isPlayerWin, "UI-test jab driver must beat \(book.id)")
            failFinalSave = index == ladder.ladder.count - 1
            ladder.save(win)
            if failFinalSave {
                precondition(!ladder.saved && !ladder.ladderComplete && !ladder.canCelebrateVictory)
                precondition(!ladder.newLadder())
                failFinalSave = false
                ladder.save(win)
            }
            precondition(ladder.saved && ladder.isBeaten(book.id))
            expected.append(ladder.records.bouts.last!.result)
            precondition(ladder.canCelebrateVictory == (index == ladder.ladder.count - 1))
        }
        precondition(ladder.ladderComplete && ladder.nextLadderBook == nil)
        let summary = ladder.ladderSummary
        precondition(summary.bouts == ladder.ladder.count + 1 && summary.wins == ladder.ladder.count)
        precondition(summary.score == expected.reduce(0) { $0 + $1.score.points })
        precondition(summary.landed == expected.reduce(0) { $0 + $1.playerStats.landed })
        precondition(summary.thrown == expected.reduce(0) { $0 + $1.playerStats.thrown })
        precondition(summary.counters == expected.reduce(0) { $0 + $1.playerStats.counters })
        precondition(summary.knockouts == expected.filter { $0.outcome == .playerWinByKO }.count)
        precondition(ladder.begin(.goldie, mode: .sparring))
        ladder.save(complete(.goldie))
        precondition(!ladder.canCelebrateVictory && ladder.ladderSummary.bouts == expected.count)
        let savedCount = ladder.records.bouts.count
        precondition(ladder.newLadder())
        precondition(!ladder.ladderComplete && !ladder.canCelebrateVictory && ladder.ladderSummary.bouts == 0)
        precondition(ladder.nextLadderBook?.id == "goldie" && ladder.records.bouts.count == savedCount)
        print("PASS: \(ladder.ladder.count) real wins complete the ladder only after a successful final save; sparring never ends career")
        print("PASS: finale totals include ladder losses, exclude older history and sparring; End game resets progress, not records")
    }
}
SWIFT
flags=(--package-path "$probe" -j 4)
if [[ $(uname -s) == Linux ]]; then flags+=(-Xswiftc -DGRDBCUSTOMSQLITE); fi
swift run "${flags[@]}"
