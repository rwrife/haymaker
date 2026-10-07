import SwiftUI
import SpriteKit
import UIKit
import Combine
import HaymakerKit
import HaymakerStore

private enum ControlStyle: String, CaseIterable, Identifiable {
    case oneThumb = "One thumb"
    case twoHanded = "Two hands"
    var id: String { rawValue }
}

struct ContentView: View {
    @AppStorage("controlStyle") private var controlStyle = ControlStyle.oneThumb.rawValue
    @AppStorage("colorblindCues") private var colorblindCues = true
    @AppStorage("reducedMotion") private var reducedMotion = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var career = CareerSession()
    @State private var showingRecords = false
    @State private var session: FightSession?
    @State private var scene = MatchScene(size: CGSize(width: 390, height: 510))
    @State private var lastEventCount = 0
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var effectiveReducedMotion: Bool { reducedMotion || systemReduceMotion }
    private let clock = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    if session.engine.isOver { results(session) }
                    else { arena(session) }
                } else { home }
            }
            .navigationTitle("Haymaker")
            .toolbar {
                Button("Records") { showingRecords = true }.accessibilityIdentifier("records.open")
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("settings.open")
            }
            .sheet(isPresented: $showingSettings) { settings }
            .sheet(isPresented: $showingRecords) { recordsWall }
        }
        .onReceive(clock) { _ in
            guard let session, session.advanceIfActive(settingsPresented: showingSettings,
                recordsPresented: showingRecords, sceneActive: scenePhase == .active) else { return }
            if session.engine.isOver { career.save(session) }
            scene.render(session.engine, reducedMotion: effectiveReducedMotion, highContrast: colorblindCues)
            if session.engine.events.count > lastEventCount {
                if hapticsEnabled && session.engine.events.dropFirst(lastEventCount).contains(where: {
                    if case .landed = $0 { return true }
                    return false
                }) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                lastEventCount = session.engine.events.count
            }
        }
    }

    private var home: some View {
        List {
            if let error = career.error { Text(error).foregroundStyle(.red) }
            Section("Career ladder") {
                if career.historyLoaded && OpponentBook.v0Roster.allSatisfy({ career.records.wins($0.id, careerOnly: true) > 0 }) {
                    Text("Career complete — all six opponents beaten")
                }
                ForEach(OpponentBook.v0Roster) { book in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.name).font(.headline)
                        Text(!career.historyLoaded ? "History unavailable" : career.records.wins(book.id, careerOnly: true) > 0 ? "Beaten" :
                             (career.records.isUnlocked(book.id) ? "Ready" : "Locked — beat the previous opponents"))
                            .accessibilityIdentifier("career.status.\(book.id)")
                        NavigationLink("\(book.name) bio and records") { opponentDetail(book) }
                            .accessibilityIdentifier("opponent.detail.\(book.id)")
                        Button(book.id == "twitch" ? "Start bout" : "Fight \(book.name)") {
                            if career.begin(book, mode: .career) { startBout() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!career.historyLoaded || !career.records.isUnlocked(book.id))
                        .accessibilityIdentifier(book.id == "twitch" ? "bout.start" : "career.start.\(book.id)")
                    }
                }
            }
            Section("Endless sparring") {
                Text("Practice one opponent in seeded one-round bouts. Continue for as many rounds as you like.")
                ForEach(OpponentBook.v0Roster) { book in
                    Button("Spar with \(book.name)") { if career.begin(book, mode: .sparring) { startBout() } }
                        .accessibilityIdentifier("sparring.start.\(book.id)")
                }
            }
        }
    }

    private func opponentDetail(_ book: OpponentBook) -> some View {
        List {
            Text(book.bio)
            Text("Pattern: " + book.sequence.map { $0.move.rawValue }.joined(separator: " → "))
            recordSummary(book)
        }.navigationTitle(book.name)
    }

    @ViewBuilder private func recordSummary(_ book: OpponentBook) -> some View {
        let history = career.records.history(book.id)
        if !career.historyLoaded {
            Text("History unavailable — personal best unknown")
                .accessibilityIdentifier("records.unavailable.\(book.id)")
        } else if let best = career.records.ledger.best(for: book.id) {
            Text("Best score \(best.score) • round \(best.roundsCompleted) • \(best.ticksElapsed) ticks")
            Text("Recorded bouts \(history.count) • wins \(career.records.wins(book.id))")
            if let knockout = career.records.fastestKO(book.id) {
                Text("Fastest winning KO: round \(knockout.roundsCompleted) • \(knockout.ticksElapsed) ticks")
            } else { Text("Fastest winning KO unknown — none recorded") }
            let thrown = history.reduce(0) { $0 + $1.result.playerStats.thrown }
            let landed = history.reduce(0) { $0 + $1.result.playerStats.landed }
            Text(thrown > 0 ? "Hit ratio \(landed * 100 / thrown)%" : "Hit ratio unknown — no punches thrown")
        } else {
            Text("No recorded bouts — personal best unknown")
                .accessibilityIdentifier("records.unknown.\(book.id)")
        }
    }

    private var recordsWall: some View {
        NavigationStack {
            List {
                if career.historyLoaded {
                    Text("Career bouts \(career.records.bouts.filter { $0.mode == .career }.count)")
                } else {
                    Text(career.error ?? "Local records unavailable").foregroundStyle(.red)
                    Button("Retry loading records") { career.reloadHistory() }
                }
                ForEach(OpponentBook.v0Roster) { book in
                    Section(book.name) { recordSummary(book) }
                }
            }
            .navigationTitle("Records")
            .accessibilityIdentifier("records.wall")
            .toolbar { Button("Done") { showingRecords = false } }
        }
    }

    private func arena(_ session: FightSession) -> some View {
        let fight = session.engine
        return ScrollView {
        VStack(spacing: 6) {
            HStack {
                Text("Round \(fight.round) / \(fight.config.rounds)")
                Spacer()
                Text(fight.phase == .resting ? "REST" : "\(max(0, fight.config.roundTicks - fight.tickInRound) / 60)s")
                    .accessibilityIdentifier("bout.clock")
            }
            .font(.headline.monospacedDigit())
            HStack {
                meter("Your health", value: fight.player.hp, maximum: fight.config.damage.maxHP)
                meter("\(fight.book.name) health", value: fight.opponent.hp, maximum: fight.config.damage.maxHP)
            }
            meter("Your stamina", value: fight.player.stamina, maximum: fight.config.damage.maxStamina)
            HStack {
                Text("Tell: \(fight.opponent.state == .telling ? fight.opponent.currentMove.rawValue : "watch")")
                    .accessibilityIdentifier("bout.tell")
                Spacer()
                if fight.opponent.state == .telling {
                    Text("\(max(0, fight.opponent.stateDuration - fight.opponent.ticksInCurrentState)) ticks")
                }
            }
            .font(.headline)
            SpriteView(scene: scene)
                .frame(height: 300)
                .accessibilityHidden(true) // HUD text and control labels carry equivalent information.
            Text("Landed: \(fight.playerStats.landed)")
                .font(.headline.monospacedDigit())
                .accessibilityIdentifier("bout.landed")
            if controlStyle == ControlStyle.oneThumb.rawValue { oneThumbControls(session) }
            else { twoHandedControls(session) }
        }
        .padding(.horizontal, 14)
        }
    }

    private func meter(_ title: String, value: Int, maximum: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title): \(value) / \(maximum)")
                .font(.caption.bold())
            ProgressView(value: Double(value), total: Double(maximum))
                .tint(title.contains("stamina") ? .cyan : .orange)
        }
        .accessibilityElement(children: .combine)
    }

    private func oneThumbControls(_ session: FightSession) -> some View {
        VStack(spacing: 6) {
            Text("Tap jab • drag left hook • drag up uppercut • swipe right dodge • swipe down guard")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button { session.submit(.jab) } label: {
                Text("Jab — drag for combo").frame(maxWidth: .infinity, minHeight: 64)
            }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("bout.jab")
                .simultaneousGesture(DragGesture(minimumDistance: 26).onEnded { drag in
                    session.submit(ControlInput.resolve(dx: Double(drag.translation.width), dy: Double(drag.translation.height)))
                })
                .accessibilityAction(named: "Hook") { session.submit(.hook) }
                .accessibilityAction(named: "Uppercut") { session.submit(.uppercut) }
            HStack {
                action("Guard", input: .block, id: "bout.guard", session: session)
                action("Dodge", input: .dodge, id: "bout.dodge", session: session)
            }
        }
    }

    private func twoHandedControls(_ session: FightSession) -> some View {
        VStack(spacing: 8) {
            HStack {
                action("Jab", input: .jab, id: "bout.jab", session: session)
                action("Hook", input: .hook, id: "bout.hook", session: session)
                action("Uppercut", input: .uppercut, id: "bout.uppercut", session: session)
            }
            HStack {
                action("Guard", input: .block, id: "bout.guard", session: session)
                action("Dodge", input: .dodge, id: "bout.dodge", session: session)
                action("Parry", input: .parry, id: "bout.parry", session: session)
            }
        }
    }

    private func action(_ title: String, input: PlayerInput, id: String, session: FightSession) -> some View {
        Button(title) { session.submit(input) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 50)
            .accessibilityIdentifier(id)
    }

    private func results(_ session: FightSession) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Bout results").font(.largeTitle.bold()).accessibilityIdentifier("bout.results")
                Text("\(session.engine.book.name) • \(session.engine.outcome?.rawValue ?? "Unknown outcome")")
                Text("Landed \(session.engine.playerStats.landed) of \(session.engine.playerStats.thrown) punches")
                Text("Damage dealt \(session.engine.playerStats.damageDealt) • taken \(session.engine.playerStats.damageTaken)")
                Text("Round \(session.engine.round) • \(session.engine.totalTicks) ticks • score \(session.engine.playerScore().points)")
                Text(session.replayMatches ? "Seeded replay verified" : "Replay mismatch")
                if career.saved {
                    Text(career.comparison?.shouldStore == true ? "Personal best recorded" : "Previous personal best stands")
                        .accessibilityIdentifier("results.pb")
                }
                if let error = career.error {
                    Text(error).foregroundStyle(.red)
                    Button("Retry saving") { career.save(session) }
                }
                if career.mode == .sparring {
                    Text("Run: \(career.runBouts.count) rounds • score \(career.runBouts.reduce(0) { $0 + $1.result.score.points }) • landed \(career.runBouts.reduce(0) { $0 + $1.result.playerStats.landed })")
                        .accessibilityIdentifier("sparring.stats")
                    Button("Next sparring round") { if career.nextRound() { startBout() } }
                        .disabled(!career.saved).accessibilityIdentifier("sparring.next")
                } else if let next = OpponentBook.v0Roster.first(where: {
                    career.records.isUnlocked($0.id) && career.records.wins($0.id, careerOnly: true) == 0
                }), next.id != career.opponent.id {
                    Button("Next career bout: \(next.name)") { if career.begin(next, mode: .career) { startBout() } }
                        .disabled(!career.saved).accessibilityIdentifier("career.next")
                }
                Button("Fight again") { if career.begin(career.opponent, mode: career.mode) { startBout() } }
                    .disabled(!career.saved).buttonStyle(.borderedProminent).accessibilityIdentifier("bout.again")
                Button("Career ladder") { if career.saved { self.session = nil } }
                    .disabled(!career.saved).accessibilityIdentifier("career.home")
            }.padding()
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Picker("Controls", selection: $controlStyle) {
                    ForEach(ControlStyle.allCases) { style in Text(style.rawValue).tag(style.rawValue) }
                }
                .accessibilityIdentifier("settings.controls")
                Toggle("Shape and text tell cues", isOn: $colorblindCues)
                    .accessibilityIdentifier("settings.colorblind")
                Toggle("Reduced motion", isOn: $reducedMotion)
                    .accessibilityIdentifier("settings.reducedMotion")
                Toggle("Haptics", isOn: $hapticsEnabled)
                    .accessibilityIdentifier("settings.haptics")
                Text("Tell shapes and text remain on for every player; this setting records your preference for future visual themes.")
                    .font(.footnote)
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { showingSettings = false } }
        }
    }

    private func startBout() {
        let isUITest = ProcessInfo.processInfo.arguments.contains("-haymakerUITestShortBout")
        session = FightSession(seed: career.seed, book: career.opponent, sparring: career.mode == .sparring, shortUITestBout: isUITest)
        scene = MatchScene(size: CGSize(width: 390, height: 510))
        lastEventCount = 0
        if let session { scene.render(session.engine, reducedMotion: effectiveReducedMotion, highContrast: colorblindCues) }
    }
}
