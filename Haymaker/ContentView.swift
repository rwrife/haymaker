import SwiftUI
import UIKit
import Combine
import HaymakerKit

private enum ControlStyle: String, CaseIterable, Identifiable {
    case oneThumb = "One thumb"
    case twoHanded = "Two hands"
    var id: String { rawValue }
}

private enum RingStyle {
    static let gold = Color(red: 0.98, green: 0.72, blue: 0.25)
    static let green = Color(red: 0.31, green: 0.92, blue: 0.39)
    static let red = Color(red: 0.97, green: 0.24, blue: 0.19)
    static let ink = Color(red: 0.025, green: 0.04, blue: 0.075)
    static func type(_ size: CGFloat) -> Font { .custom("AvenirNextCondensed-Heavy", size: size) }
}

struct ContentView: View {
    @AppStorage("controlStyle") private var controlStyle = ControlStyle.oneThumb.rawValue
    @AppStorage("colorblindCues") private var colorblindCues = true
    @AppStorage("reducedMotion") private var reducedMotion = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("bestArcadeScore") private var bestScore = 0
    @State private var session: FightSession?
    @State private var scene = MatchScene()
    @State private var lastEventCount = 0
    @State private var showingSettings = false
    @State private var paused = false
    @State private var feedback = ""
    @State private var feedbackUntil = 0
    @State private var feedbackColor = RingStyle.gold
    @State private var lastFrame: TimeInterval?
    @State private var tickAccumulator: TimeInterval = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var effectiveReducedMotion: Bool { reducedMotion || systemReduceMotion }
    private let clock = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            ZStack {
                MetalArenaView(arena: scene, portrait: portrait, paused: paused || showingSettings || scenePhase != .active)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                LinearGradient(colors: [.black.opacity(0.8), .clear, .clear, RingStyle.ink.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if let session {
                    match(session, portrait: portrait)
                    if session.engine.isOver { results(session, portrait: portrait) }
                    else if paused { pauseMenu }
                } else { home(portrait: portrait) }
            }
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showingSettings) { settings }
            .statusBarHidden()
        }
        .onReceive(clock) { _ in advanceFrame() }
        .onChange(of: scenePhase) { _, phase in
            lastFrame = nil
            if phase != .active, session != nil, session?.engine.isOver == false { paused = true }
        }
        .onChange(of: showingSettings) { _, _ in lastFrame = nil }
        .onChange(of: paused) { _, _ in lastFrame = nil }
    }

    private func home(portrait: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("THE MAIN EVENT", systemImage: "sparkle")
                    .font(.system(size: 11, weight: .heavy)).tracking(3)
                    .foregroundStyle(RingStyle.gold)
                Spacer()
                settingsButton
            }
            .padding(.top, 10)
            Spacer(minLength: 18)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HAYMAKER").font(RingStyle.type(portrait ? 61 : 76)).italic()
                        .shadow(color: .black, radius: 8, y: 4)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("READ THE TELL. LAND THE COUNTER.")
                        .font(.system(size: 10, weight: .heavy)).tracking(2)
                        .foregroundStyle(RingStyle.gold)
                }
                Spacer(minLength: 0)
            }
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("BOUT 01  /  THE HEAVY HITTER").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(RingStyle.gold)
                    Text("BRUISER BAXTER").font(RingStyle.type(portrait ? 33 : 38)).italic()
                    Text("Big swings. Bigger openings. Make him miss.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                if bestScore > 0 {
                    VStack(alignment: .trailing) {
                        Text("PERSONAL BEST").font(.system(size: 9, weight: .bold)).tracking(1)
                        Text(bestScore.formatted()).font(RingStyle.type(26)).foregroundStyle(RingStyle.gold)
                    }
                }
            }
            .padding(.bottom, 20)
            Button(action: startBout) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("STEP INTO THE RING").font(RingStyle.type(22)).italic().tracking(1)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 22).frame(height: 62)
                .foregroundStyle(RingStyle.ink)
                .background(LinearGradient(colors: [Color(red: 1, green: 0.83, blue: 0.42), RingStyle.gold], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.45)))
            }
            .accessibilityIdentifier("bout.start")
            HStack(spacing: 16) {
                Label("3 ROUNDS", systemImage: "timer")
                Label("ALL SKILL", systemImage: "target")
                Label("OFFLINE", systemImage: "bolt.shield")
            }
            .font(.system(size: 9, weight: .heavy)).tracking(1)
            .foregroundStyle(.white.opacity(0.5)).padding(.top, 15).padding(.bottom, 12)
        }
        .padding(.horizontal, portrait ? 25 : 36)
    }

    private func match(_ session: FightSession, portrait: Bool) -> some View {
        let fight = session.engine
        return VStack(spacing: 0) {
            hud(fight, portrait: portrait)
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(RingStyle.red).frame(width: 5, height: 5)
                    Text("MAIN EVENT").tracking(2)
                }
                Spacer()
                Button { paused = true } label: {
                    Image(systemName: "pause.fill").frame(width: 44, height: 44)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Pause bout").accessibilityIdentifier("bout.pause")
            }
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.top, 5)
            Spacer(minLength: 0)
            if !feedback.isEmpty && fight.totalTicks < feedbackUntil {
                Text(feedback).font(RingStyle.type(portrait ? 32 : 38)).italic()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20).padding(.vertical, 5)
                    .background(feedbackColor, in: SlantedPanel())
                    .overlay(SlantedPanel().stroke(.black, lineWidth: 3))
                    .rotationEffect(.degrees(-3))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 5)
                    .accessibilityIdentifier("bout.feedback")
            }
            Spacer(minLength: 0)
            VStack(spacing: portrait ? 12 : 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tellTitle(fight)).font(RingStyle.type(18)).italic()
                            .foregroundStyle(tellColor(fight))
                            .accessibilityIdentifier("bout.tell")
                        if portrait { Text(tellHint(fight)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7)) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Landed: \(fight.playerStats.landed)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .accessibilityIdentifier("bout.landed")
                        Text("\(fight.playerStats.counters) COUNTERS").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(RingStyle.gold)
                    }
                }
                stamina(fight)
                if controlStyle == ControlStyle.oneThumb.rawValue {
                    oneThumbControls(session, portrait: portrait)
                } else { twoHandedControls(session, portrait: portrait) }
            }
            .padding(portrait ? 14 : 10)
            .background(LinearGradient(colors: [RingStyle.ink.opacity(0.6), RingStyle.ink.opacity(0.96)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.13)))
            .padding(.bottom, portrait ? 8 : 0)
        }
        .padding(.horizontal, portrait ? 16 : 24)
        .padding(.top, portrait ? 6 : 8)
    }

    private func hud(_ fight: FightEngine, portrait: Bool) -> some View {
        HStack(alignment: .top, spacing: portrait ? 10 : 22) {
            fighterHUD(name: "BRUISER BAXTER", hp: fight.opponent.hp, maxHP: fight.config.damage.maxHP, knockdowns: fight.playerStats.knockdownsScored, color: RingStyle.red, rival: true, compact: portrait)
            VStack(spacing: 0) {
                Text("ROUND \(fight.round)").font(RingStyle.type(portrait ? 15 : 18)).foregroundStyle(RingStyle.gold)
                Text(clockText(fight)).font(RingStyle.type(portrait ? 31 : 36)).monospacedDigit()
                    .accessibilityIdentifier("bout.clock")
                Text("OF \(fight.config.rounds)").font(.system(size: 8, weight: .heavy)).tracking(2).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: portrait ? 65 : 80)
            fighterHUD(name: "ROOK", hp: fight.player.hp, maxHP: fight.config.damage.maxHP, knockdowns: fight.opponentStats.knockdownsScored, color: RingStyle.green, rival: false, compact: portrait)
        }
    }

    private func fighterHUD(name: String, hp: Int, maxHP: Int, knockdowns: Int, color: Color, rival: Bool, compact: Bool) -> some View {
        VStack(alignment: rival ? .leading : .trailing, spacing: 4) {
            Text(name).font(RingStyle.type(compact ? 17 : 24)).lineLimit(1).minimumScaleFactor(0.6)
            GeometryReader { geometry in
                ZStack(alignment: rival ? .leading : .trailing) {
                    RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.7))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [color.opacity(0.6), color, color.opacity(0.9)], startPoint: .bottom, endPoint: .top))
                        .frame(width: max(0, geometry.size.width - 6) * CGFloat(max(0, hp)) / CGFloat(maxHP))
                        .padding(3)
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(LinearGradient(colors: [.white.opacity(0.8), .gray.opacity(0.6), .white.opacity(0.6)], startPoint: .top, endPoint: .bottom), lineWidth: 2))
                .shadow(color: color.opacity(0.35), radius: 7)
            }
            .frame(height: compact ? 17 : 21)
            HStack(spacing: 4) {
                if !rival { Spacer(minLength: 0) }
                ForEach(0..<3) { index in
                    Image(systemName: "star.fill")
                        .foregroundStyle(index < knockdowns ? RingStyle.gold : .white.opacity(0.18))
                }
                if rival { Spacer(minLength: 0) }
            }
            .font(.system(size: compact ? 11 : 14))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), health \(hp) of \(maxHP), \(knockdowns) knockdowns suffered")
    }

    private func stamina(_ fight: FightEngine) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill").foregroundStyle(RingStyle.green)
            Text("STAMINA").font(.system(size: 8, weight: .heavy)).tracking(1.4)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(fight.player.stamina < 20 ? RingStyle.red : RingStyle.green)
                        .frame(width: geometry.size.width * CGFloat(fight.player.stamina) / CGFloat(fight.config.damage.maxStamina))
                }
            }
            .frame(height: 5)
            Text("\(fight.player.stamina)").font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .font(.system(size: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stamina \(fight.player.stamina) of \(fight.config.damage.maxStamina)")
    }

    private func oneThumbControls(_ session: FightSession, portrait: Bool) -> some View {
        HStack(spacing: 10) {
            control("GUARD", icon: "shield.lefthalf.filled", hint: "HOLD THE LINE", input: .block, id: "bout.guard", session: session, color: .white, height: portrait ? 67 : 44)
                .frame(maxWidth: .infinity)
            Button { session.submit(.jab) } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 15, weight: .black))
                        Text("PUNCH").font(RingStyle.type(portrait ? 25 : 22)).italic()
                    }
                    if portrait { Text("TAP JAB · SWIPE COMBO").font(.system(size: 7, weight: .heavy)).tracking(0.6) }
                }
                .frame(maxWidth: .infinity).frame(height: portrait ? 67 : 44)
                .foregroundStyle(RingStyle.ink)
                .background(LinearGradient(colors: [RingStyle.gold, Color(red: 0.96, green: 0.49, blue: 0.13)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.45)))
            }
            .accessibilityLabel("Jab. Swipe left for hook, up for uppercut, right for dodge, down for guard.")
            .accessibilityIdentifier("bout.jab")
            .highPriorityGesture(DragGesture(minimumDistance: 26).onEnded { drag in
                session.submit(ControlInput.resolve(dx: Double(drag.translation.width), dy: Double(drag.translation.height)))
            })
            .accessibilityAction(named: "Hook") { session.submit(.hook) }
            .accessibilityAction(named: "Uppercut") { session.submit(.uppercut) }
            .frame(maxWidth: .infinity)
            control("DODGE", icon: "arrow.turn.up.left", hint: "MAKE HIM MISS", input: .dodge, id: "bout.dodge", session: session, color: RingStyle.green, height: portrait ? 67 : 44)
                .frame(maxWidth: .infinity)
        }
    }

    private func twoHandedControls(_ session: FightSession, portrait: Bool) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                control("JAB", icon: "arrow.up.right", input: .jab, id: "bout.jab", session: session, color: RingStyle.gold)
                control("HOOK", icon: "arrow.uturn.left", input: .hook, id: "bout.hook", session: session, color: RingStyle.gold)
                control("UPPERCUT", icon: "arrow.up", input: .uppercut, id: "bout.uppercut", session: session, color: RingStyle.gold)
            }
            HStack(spacing: 8) {
                control("GUARD", icon: "shield.fill", input: .block, id: "bout.guard", session: session)
                control("DODGE", icon: "arrow.turn.up.left", input: .dodge, id: "bout.dodge", session: session, color: RingStyle.green)
                control("PARRY", icon: "hand.raised.fill", input: .parry, id: "bout.parry", session: session)
            }
        }
    }

    private func control(_ title: String, icon: String, hint: String? = nil, input: PlayerInput, id: String, session: FightSession, color: Color = .white, height: CGFloat = 44) -> some View {
        Button { session.submit(input) } label: {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                    Text(title).font(RingStyle.type(16))
                }
                if let hint, height > 50 { Text(hint).font(.system(size: 6, weight: .heavy)).tracking(0.4).foregroundStyle(.white.opacity(0.45)) }
            }
            .frame(maxWidth: .infinity).frame(height: height)
            .foregroundStyle(color)
            .background(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.25)))
        }
        .accessibilityIdentifier(id)
    }

    private func results(_ session: FightSession, portrait: Bool) -> some View {
        let win = session.engine.outcome?.isPlayerWin == true
        let draw = session.engine.outcome == .draw
        return ZStack {
            RingStyle.ink.opacity(0.85).ignoresSafeArea()
            VStack(spacing: portrait ? 19 : 10) {
                Text("BOUT RESULTS").font(.system(size: 11, weight: .heavy)).tracking(4).foregroundStyle(RingStyle.gold)
                    .accessibilityIdentifier("bout.results")
                Text(draw ? "DRAW" : win ? "VICTORY" : "DEFEAT")
                    .font(RingStyle.type(portrait ? 64 : 50)).italic().foregroundStyle(win ? RingStyle.gold : .white)
                Text(outcomeDescription(session.engine.outcome)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 25) {
                    resultStat("SCORE", value: session.engine.playerScore().points.formatted())
                    resultStat("LANDED", value: "\(session.engine.playerStats.landed)/\(session.engine.playerStats.thrown)")
                    resultStat("COUNTERS", value: "\(session.engine.playerStats.counters)")
                }
                .padding(.vertical, 10)
                Button(action: startBout) {
                    Text("REMATCH").font(RingStyle.type(23)).italic().frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(RingStyle.ink).background(RingStyle.gold, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("bout.again")
                Button("BACK TO MAIN EVENT") { sessionReset() }
                    .font(.system(size: 11, weight: .heavy)).tracking(1.4).padding(8)
            }
            .frame(maxWidth: 400).padding(28)
        }
        .onAppear { bestScore = max(bestScore, session.engine.playerScore().points) }
    }

    private func resultStat(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(RingStyle.type(28)).foregroundStyle(RingStyle.gold)
            Text(title).font(.system(size: 8, weight: .heavy)).tracking(1.5).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var pauseMenu: some View {
        ZStack {
            RingStyle.ink.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("IN YOUR CORNER").font(RingStyle.type(38)).italic()
                Text("Take a breath. The ring can wait.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                Button { paused = false } label: {
                    Text("RESUME BOUT").font(RingStyle.type(22)).frame(width: 240, height: 55)
                        .foregroundStyle(RingStyle.ink).background(RingStyle.gold, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("bout.resume")
                Button("Settings") { showingSettings = true }.font(.headline)
                Button("Leave bout") { sessionReset() }.font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var settingsButton: some View {
        Button { showingSettings = true } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 18)).frame(width: 44, height: 44)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("Settings").accessibilityIdentifier("settings.open")
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Your corner") {
                    Picker("Controls", selection: $controlStyle) {
                        ForEach(ControlStyle.allCases) { style in Text(style.rawValue).tag(style.rawValue) }
                    }.accessibilityIdentifier("settings.controls")
                    Toggle("High contrast tell cues", isOn: $colorblindCues).accessibilityIdentifier("settings.colorblind")
                    Toggle("Reduced motion", isOn: $reducedMotion).accessibilityIdentifier("settings.reducedMotion")
                    Toggle("Haptics", isOn: $hapticsEnabled).accessibilityIdentifier("settings.haptics")
                }
                Section("Learn the rhythm") {
                    Text("Tap PUNCH for a jab. Swipe left for a hook, up for an uppercut, right to dodge, and down to guard. Two hands gives every move its own button.")
                    Text("Counter during Baxter’s windup for double damage. Dodge just before his glove lands. An uppercut breaks his guard. Feints are a trap—wait for the opening.")
                }
                Section {
                    Text("3D arena rendered with Metal. All fights and records stay on your device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(RingStyle.gold)
            .navigationTitle("Your corner")
            .toolbar { Button("Done") { showingSettings = false } }
        }
        .preferredColorScheme(.dark)
    }

    private func clockText(_ fight: FightEngine) -> String {
        if fight.phase == .resting { return "REST" }
        let seconds = max(0, fight.config.roundTicks - fight.tickInRound + 59) / 60
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func tellTitle(_ fight: FightEngine) -> String {
        if fight.phase == .resting { return "BACK TO YOUR CORNER" }
        switch fight.opponent.state {
        case .telling: return fight.opponent.currentMove == .feint ? "FEINT — DON’T BITE" : "\(fight.opponent.currentMove.rawValue.uppercased()) — WINDING UP"
        case .attacking: return "INCOMING!"
        case .blocking: return "GUARD UP"
        case .recovering: return "OPENING — GO!"
        case .knockedDown, .ko: return "BAXTER IS DOWN!"
        default: return "READ HIS NEXT MOVE"
        }
    }
    private func tellHint(_ fight: FightEngine) -> String {
        if fight.phase == .resting { return "Recover your stamina. Next round is coming." }
        switch fight.opponent.state {
        case .telling: return fight.opponent.currentMove == .feint ? "Wait for the real punch." : "Counter now, or prepare to dodge."
        case .attacking: return "Dodge or guard!"
        case .blocking: return "Swipe up. Uppercut breaks the guard."
        case .recovering: return "He missed his chance. Take yours."
        default: return "Watch the gloves. Find your rhythm."
        }
    }
    private func tellColor(_ fight: FightEngine) -> Color {
        if colorblindCues { return .white }
        return fight.opponent.state == .attacking ? RingStyle.red : fight.opponent.state == .recovering ? RingStyle.green : RingStyle.gold
    }
    private func outcomeDescription(_ outcome: FightOutcome?) -> String {
        switch outcome {
        case .playerWinByKO: return "Baxter goes down. You own the ring."
        case .playerWinByDecision: return "You take it on the judges’ scorecards."
        case .playerLossByKO: return "Baxter lands the knockout. Come back swinging."
        case .playerLossByDecision: return "Baxter takes the decision. Find his rhythm."
        default: return "Even on the scorecards. Settle it in a rematch."
        }
    }

    private func startBout() {
        session = FightSession(shortUITestBout: ProcessInfo.processInfo.arguments.contains("-haymakerUITestShortBout"))
        scene = MatchScene()
        paused = false
        lastEventCount = 0
        lastFrame = nil
        tickAccumulator = 0
        feedback = "FIGHT!"
        feedbackColor = RingStyle.gold
        feedbackUntil = 70
        if let session { scene.render(session.engine, reducedMotion: effectiveReducedMotion, highContrast: colorblindCues) }
    }

    private func sessionReset() {
        session = nil
        scene = MatchScene()
        paused = false
        lastFrame = nil
        feedback = ""
    }

    private func advanceFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let session, !showingSettings, !paused, !session.engine.isOver, scenePhase == .active else { lastFrame = nil; return }
        let elapsed = min(0.1, max(0, now - (lastFrame ?? now)))
        lastFrame = now
        tickAccumulator += elapsed
        while tickAccumulator >= 1.0 / 60.0 {
            session.advance()
            tickAccumulator -= 1.0 / 60.0
            if session.engine.isOver { break }
        }
        scene.render(session.engine, reducedMotion: effectiveReducedMotion, highContrast: colorblindCues)
        for event in session.engine.events.dropFirst(lastEventCount) {
            switch event {
            case let .landed(_, by, _, _, counter):
                feedback = by == .player ? (counter ? "COUNTER!" : "CLEAN HIT!") : "HIT!"
                feedbackColor = by == .player ? RingStyle.gold : RingStyle.red
                if hapticsEnabled { UIImpactFeedbackGenerator(style: counter ? .heavy : .medium).impactOccurred() }
            case .dodged: feedback = "DODGED!"; feedbackColor = RingStyle.green
            case .parried: feedback = "PARRIED!"; feedbackColor = RingStyle.green
            case .blocked: feedback = "BLOCKED!"; feedbackColor = .white
            case .knockdown: feedback = "KNOCKDOWN!"; feedbackColor = RingStyle.gold
            case .roundStart: feedback = "FIGHT!"; feedbackColor = RingStyle.gold
            default: continue
            }
            feedbackUntil = session.engine.totalTicks + 38
        }
        lastEventCount = session.engine.events.count
    }
}

private struct SlantedPanel: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 9, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - 9, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
