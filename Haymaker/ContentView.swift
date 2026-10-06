import SwiftUI
import SpriteKit
import UIKit
import Combine
import HaymakerKit

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
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("settings.open")
            }
            .sheet(isPresented: $showingSettings) { settings }
        }
        .onReceive(clock) { _ in
            guard let session, !showingSettings, !session.engine.isOver, scenePhase == .active else { return }
            session.advance()
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
        VStack(spacing: 24) {
            Image(systemName: "figure.boxing")
                .font(.system(size: 82))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("The Twitch Bout")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Read Twitch’s arrow tells. Counter with a punch, or guard and dodge. Your inputs and the seed determine every result.")
                .multilineTextAlignment(.center)
            Button("Start bout") { startBout() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("bout.start")
        }
        .padding(28)
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
                meter("Twitch health", value: fight.opponent.hp, maximum: fight.config.damage.maxHP)
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
        VStack(spacing: 18) {
            Text("Bout results").font(.largeTitle.bold())
                .accessibilityIdentifier("bout.results")
            Text(session.engine.outcome?.rawValue ?? "Unknown outcome")
            Text("Landed \(session.engine.playerStats.landed) of \(session.engine.playerStats.thrown) punches")
            Text("Score \(session.engine.playerScore().points)")
            Text(session.replayMatches ? "Seeded replay verified" : "Replay mismatch")
            Button("Fight again") { startBout() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("bout.again")
        }
        .padding()
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
        session = FightSession(shortUITestBout: isUITest)
        scene = MatchScene(size: CGSize(width: 390, height: 510))
        lastEventCount = 0
        if let session { scene.render(session.engine, reducedMotion: effectiveReducedMotion, highContrast: colorblindCues) }
    }
}
