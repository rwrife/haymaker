import SpriteKit
import HaymakerKit

/// Original geometric canvas fighters. No rules or randomness live in SpriteKit.
@MainActor final class MatchScene: SKScene {
    private let rival = SKShapeNode(rectOf: CGSize(width: 116, height: 176), cornerRadius: 36)
    private let hero = SKShapeNode(rectOf: CGSize(width: 96, height: 140), cornerRadius: 30)
    private let rivalGlove = SKShapeNode(circleOfRadius: 27)
    private let heroGlove = SKShapeNode(circleOfRadius: 23)
    private let tell = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let floor = SKShapeNode(rectOf: CGSize(width: 360, height: 16), cornerRadius: 8)
    private var lastEventCount = 0

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.17, alpha: 1)
        scaleMode = .aspectFit
        floor.fillColor = UIColor(red: 0.21, green: 0.30, blue: 0.47, alpha: 1)
        floor.strokeColor = .clear
        floor.position = CGPoint(x: size.width / 2, y: 45)
        addChild(floor)
        rival.fillColor = UIColor(red: 0.96, green: 0.36, blue: 0.23, alpha: 1)
        rival.strokeColor = .white
        rival.lineWidth = 4
        rival.position = CGPoint(x: size.width / 2, y: 315)
        hero.fillColor = UIColor(red: 0.18, green: 0.73, blue: 0.85, alpha: 1)
        hero.strokeColor = .white
        hero.lineWidth = 4
        hero.position = CGPoint(x: size.width / 2, y: 140)
        rivalGlove.fillColor = .systemOrange
        rivalGlove.strokeColor = .white
        rivalGlove.position = CGPoint(x: -65, y: -38)
        heroGlove.fillColor = .systemTeal
        heroGlove.strokeColor = .white
        heroGlove.position = CGPoint(x: 58, y: 35)
        rival.addChild(rivalGlove)
        hero.addChild(heroGlove)
        addChild(rival)
        addChild(hero)
        tell.fontSize = 22
        tell.fontColor = .white
        tell.position = CGPoint(x: size.width / 2, y: 450)
        addChild(tell)
    }

    func render(_ fight: FightEngine, reducedMotion: Bool, highContrast: Bool) {
        rival.lineWidth = highContrast ? 6 : 3
        hero.lineWidth = highContrast ? 6 : 3
        let pulse = 1 + 0.08 * sin(Double(fight.totalTicks) / 5)
        tell.setScale(!reducedMotion && fight.opponent.state == .telling ? CGFloat(pulse) : 1)
        // Poses are pure projections of the engine snapshot. Shapes + words carry
        // the tell, not color alone; there is no SKAction driving fight state.
        let rivalPose = fight.opponent.state
        let heroPose = fight.player.state
        switch rivalPose {
        case .telling:
            let move = fight.opponent.currentMove
            tell.text = "\(symbol(for: move))  \(move.rawValue.uppercased()) — GET READY"
        case .attacking: tell.text = "!  INCOMING \(fight.opponent.currentMove.rawValue.uppercased())"
        case .blocking: tell.text = "⬡  GUARD — UPPERCUT"
        case .knockedDown, .ko: tell.text = "↓  DOWN"
        case .recovering: tell.text = "◇  OPENING"
        default: tell.text = "◇  WATCH THE TELL"
        }
        rivalGlove.position = CGPoint(x: rivalPose == .attacking ? -20 : -65, y: rivalPose == .attacking ? -80 : -38)
        heroGlove.position = CGPoint(x: heroPose == .attacking ? 42 : 58, y: heroPose == .attacking ? 78 : 35)
        hero.zRotation = heroPose == .dodging && !reducedMotion ? -0.14 : 0
        rival.zRotation = rivalPose == .knockedDown && !reducedMotion ? 0.45 : 0
        if fight.events.count > lastEventCount {
            let fresh = fight.events.dropFirst(lastEventCount)
            if !reducedMotion && fresh.contains(where: { event in
                if case .landed = event { return true }
                return false
            }) {
                let flash = SKShapeNode(rectOf: size)
                flash.position = CGPoint(x: size.width / 2, y: size.height / 2)
                flash.fillColor = .white
                flash.strokeColor = .clear
                flash.alpha = 0.34
                addChild(flash)
                flash.run(.sequence([.fadeOut(withDuration: 0.14), .removeFromParent()]))
                hero.run(.sequence([.moveBy(x: 4, y: 0, duration: 0.04), .moveBy(x: -4, y: 0, duration: 0.04)]))
            }
            lastEventCount = fight.events.count
        }
    }

    private func symbol(for move: Move) -> String {
        switch move {
        case .jab: "→"
        case .hook: "↶"
        case .uppercut: "↑"
        case .block: "⬡"
        case .feint: "?"
        default: "◇"
        }
    }
}
