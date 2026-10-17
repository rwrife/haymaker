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
let package = Package(name: "Probe", dependencies: [.package(path: "Packages/HaymakerKit"), .package(path: "Packages/HaymakerStore")], targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "HaymakerKit", package: "HaymakerKit"), .product(name: "HaymakerStore", package: "HaymakerStore")])])
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
    }
}
SWIFT
flags=()
if [[ $(uname -s) == Linux ]]; then flags=(-Xswiftc -DGRDBCUSTOMSQLITE); fi
swift run --package-path "$probe" -j 4 "${flags[@]}"
