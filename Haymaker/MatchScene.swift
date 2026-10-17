import SceneKit
import UIKit
import HaymakerKit

/// A real, articulated 3D arena. SceneKit's renderer is explicitly Metal.
/// Presentation reads the deterministic engine; animation never changes the rules.
@MainActor final class MatchScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let stage = SCNNode()
    private var rival = BoxerModel(isRival: true)
    private let hero = BoxerModel(isRival: false)
    private var lastEventCount = 0
    private var reducedMotion = false
    private var shake: Float = 0
    private var recoilRival: Float = 0
    private var recoilHero: Float = 0
    private var portrait = true
    private var lastTick = 0
    private var effects: [(node: SCNNode, expires: Int)] = []

    private var titleScreen: Bool
    private let mist = SCNNode()

    init(titleScreen: Bool = false) {
        self.titleScreen = titleScreen
        scene.background.contents = UIColor(red: 0.014, green: 0.023, blue: 0.047, alpha: 1)
        scene.fogColor = UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1)
        scene.fogStartDistance = 9
        scene.fogEndDistance = 30
        scene.fogDensityExponent = 1.4
        scene.lightingEnvironment.contents = reflectionEnvironment()
        scene.lightingEnvironment.intensity = 0.38
        scene.rootNode.addChildNode(stage)
        buildRing()
        buildStadium()
        buildLighting()
        buildMist()
        stage.addChildNode(rival.root)
        stage.addChildNode(hero.root)
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 48
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 60
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = -0.45
        camera.camera?.bloomIntensity = 0.3
        camera.camera?.bloomThreshold = 1.6
        camera.camera?.bloomBlurRadius = 7
        camera.camera?.vignettingIntensity = 0.65
        camera.camera?.vignettingPower = 0.7
        camera.camera?.screenSpaceAmbientOcclusionIntensity = 0.9
        camera.camera?.screenSpaceAmbientOcclusionRadius = 0.25
        scene.rootNode.addChildNode(camera)
        rival.resetMotion()
        hero.resetMotion()
        rival.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: true)
        hero.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: true)
        positionFighters(time: 0, reducedMotion: true)
        layout(portrait: true)
        if titleScreen { renderTitle(time: 0, reducedMotion: true) }
    }

    func resetForNextBout(book: OpponentBook) {
        if let key = book.character?.asset, let asset = FighterModelAsset(rawValue: key), rival.root.name != key {
            rival.root.removeFromParentNode()
            rival = BoxerModel(asset: asset, isRival: true)
            stage.addChildNode(rival.root)
        }
        // All child-list changes stay on the main actor, including effect cleanup.
        for effect in effects { effect.node.removeFromParentNode() }
        effects.removeAll()
        // Reuse the arena and renderer between rounds.
        titleScreen = false
        rival.root.isHidden = false
        hero.root.eulerAngles.y = .pi - 0.16
        layout(portrait: portrait)
        lastEventCount = 0
        lastTick = 0
        shake = 0
        recoilHero = 0
        recoilRival = 0
        rival.resetMotion()
        hero.resetMotion()
        rival.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: true)
        hero.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: true)
        positionFighters(time: 0, reducedMotion: true)
    }

    func layout(portrait: Bool) {
        self.portrait = portrait
        if titleScreen {
            camera.position = portrait ? SCNVector3(0, 2.9, 8.8) : SCNVector3(0, 2.7, 7.5)
            camera.look(at: SCNVector3(0, 1.55, 0))
            camera.camera?.fieldOfView = portrait ? 43 : 38
            return
        }
        camera.position = portrait ? SCNVector3(0, 2.95, 7.9) : SCNVector3(0, 2.55, 4.8)
        camera.look(at: SCNVector3(0, portrait ? 1.5 : 2.1, 0))
        camera.camera?.fieldOfView = portrait ? 43 : 38
    }

    /// Presentation-only shadowboxing: no bout, opponent, or career progress.
    func renderTitle(time: TimeInterval, reducedMotion: Bool) {
        guard titleScreen else { return }
        let t = reducedMotion ? Float(0) : Float(time.truncatingRemainder(dividingBy: 120))
        let tick = Int(t * 60)
        let phase = tick % 144
        let move: Move = [.jab, .hook, .uppercut][(tick / 144) % 3]
        var status = FighterStatus()
        if !reducedMotion {
            if phase < 24 {
                status = FighterStatus(state: .telling, ticksInCurrentState: phase, stateDuration: 24, currentMove: move)
            } else if phase < 42 {
                status = FighterStatus(state: .attacking, ticksInCurrentState: phase - 24, stateDuration: 18, currentMove: move)
            } else if phase < 66 {
                status = FighterStatus(state: .recovering, ticksInCurrentState: phase - 42, stateDuration: 24, currentMove: move)
            }
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        rival.root.isHidden = true
        hero.pose(status, time: t, recoil: 0, reducedMotion: reducedMotion)
        hero.root.position = SCNVector3(sin(t * 0.7) * (portrait ? 0.65 : 1.8), 0, sin(t * 0.45) * 0.35)
        hero.root.eulerAngles.y = .pi / 8 + sin(t * 0.7) * 0.18
        SCNTransaction.commit()
    }

    func render(_ fight: FightEngine, reducedMotion: Bool, highContrast: Bool) {
        self.reducedMotion = reducedMotion
        mist.isPaused = reducedMotion
        for effect in effects where effect.expires <= fight.totalTicks {
            effect.node.removeFromParentNode()
        }
        effects.removeAll { $0.expires <= fight.totalTicks }
        let elapsed = max(0, fight.totalTicks - lastTick)
        lastTick = fight.totalTicks
        let decay = pow(Float(0.86), Float(elapsed))
        recoilHero *= decay
        recoilRival *= decay
        shake *= decay
        if fight.events.count < lastEventCount { lastEventCount = 0 }
        for event in fight.events.dropFirst(lastEventCount) {
            switch event {
            case let .landed(_, by, _, damage, counter):
                if by == .player { recoilRival = 0.35 } else { recoilHero = 0.3 }
                if !reducedMotion {
                    shake = counter ? 0.085 : 0.045
                    impact(at: by == .player ? SCNVector3(0.4, 2.15, -0.15) : SCNVector3(-0.5, 1.9, 1.3), strong: damage > 15)
                }
            case let .dodged(_, attacker, _):
                if !reducedMotion { trail(rivalDodged: attacker == .player) }
            case .parried:
                if !reducedMotion { trail(rivalDodged: false) }
            default: break
            }
        }
        lastEventCount = fight.events.count
        let t = Float(fight.totalTicks) / 60
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        rival.pose(fight.opponent, time: t, recoil: recoilRival, reducedMotion: reducedMotion)
        hero.pose(fight.player, time: t + 0.8, recoil: recoilHero, reducedMotion: reducedMotion)
        positionFighters(time: t, reducedMotion: reducedMotion)
        if !reducedMotion {
            camera.position.x = sin(t * 91) * shake
            camera.position.y = (portrait ? 2.95 : 2.55) + cos(t * 77) * shake * 0.5
        } else { camera.position.x = 0; camera.position.y = portrait ? 2.95 : 2.55 }
        SCNTransaction.commit()
    }

    private func positionFighters(time: Float, reducedMotion: Bool) {
        // Both fighters circle the same center and keep facing one another.
        // Root travel follows the same strike/recovery curve as the gloves.
        let orbit: Float = reducedMotion ? 0 : sin(time * 0.55) * 0.10
        let drift: Float = reducedMotion ? 0 : sin(time * 0.8) * 0.065
        let axis = SIMD3<Float>(sin(0.64 + orbit), 0, -cos(0.64 + orbit))
        let center = SIMD3<Float>(drift, 0, 0.20)
        hero.root.simdPosition = center - axis * (1.06 - hero.forwardDrive * 0.25)
        rival.root.simdPosition = center + axis * (1.06 - rival.forwardDrive * 0.25)
        hero.root.simdPosition.x -= hero.slip * 0.24
        rival.root.simdPosition.x += rival.slip * 0.24
        let facing = rival.root.simdPosition - hero.root.simdPosition
        hero.root.eulerAngles.y = atan2(facing.x, facing.z)
        rival.root.eulerAngles.y = atan2(-facing.x, -facing.z)
    }

    private func buildRing() {
        let ivory = material(UIColor(red: 0.6, green: 0.56, blue: 0.45, alpha: 1), roughness: 0.95)
        let mat = SCNBox(width: 9.5, height: 0.16, length: 9.5, chamferRadius: 0.05)
        mat.materials = [ivory]
        stage.addChildNode(node(mat, at: SCNVector3(0, -0.08, 0)))
        let apron = SCNBox(width: 9.7, height: 0.7, length: 9.7, chamferRadius: 0.08)
        apron.materials = [material(.init(red: 0.025, green: 0.055, blue: 0.13, alpha: 1))]
        stage.addChildNode(node(apron, at: SCNVector3(0, -0.52, 0)))
        let navy = material(.init(red: 0.04, green: 0.11, blue: 0.24, alpha: 1), roughness: 0.8)
        let gold = material(.init(red: 0.75, green: 0.49, blue: 0.12, alpha: 1), metal: 0.5, roughness: 0.45)
        let crest = SCNTorus(ringRadius: 1.8, pipeRadius: 0.035)
        crest.materials = [navy]
        stage.addChildNode(node(crest, at: SCNVector3(0, 0.016, 0)))
        let crest2 = SCNTorus(ringRadius: 1.67, pipeRadius: 0.024)
        crest2.materials = [gold]
        stage.addChildNode(node(crest2, at: SCNVector3(0, 0.019, 0)))
        let logo = SCNText(string: "H", extrusionDepth: 0.002)
        logo.font = UIFont(name: "AvenirNext-HeavyItalic", size: 1.9)
        logo.flatness = 0.05
        logo.materials = [navy]
        let mark = node(logo, at: SCNVector3(-0.72, 0.025, 0.68))
        mark.eulerAngles.x = -.pi / 2
        stage.addChildNode(mark)
        for x: Float in [-4.5, 4.5] {
            for z: Float in [-4.5, 4.5] {
                let redCorner = x > 0
                let pad = material(redCorner ? .init(red: 0.62, green: 0.025, blue: 0.045, alpha: 1) : .init(red: 0.04, green: 0.18, blue: 0.55, alpha: 1), roughness: 0.4)
                let post = SCNBox(width: 0.28, height: 2.35, length: 0.28, chamferRadius: 0.05)
                post.materials = [material(.darkGray, metal: 0.9, roughness: 0.25)]
                stage.addChildNode(node(post, at: SCNVector3(x, 1.1, z)))
                for y: Float in [0.6, 1.15, 1.7] {
                    let cushion = SCNBox(width: 0.38, height: 0.32, length: 0.38, chamferRadius: 0.1)
                    cushion.materials = [pad]
                    stage.addChildNode(node(cushion, at: SCNVector3(x, y, z)))
                }
            }
        }
        for (index, y) in [Float(0.58), 1.08, 1.58, 2.08].enumerated() {
            let color: UIColor = [.init(red: 0.045, green: 0.16, blue: 0.43, alpha: 1), .init(white: 0.78, alpha: 1), .init(red: 0.64, green: 0.02, blue: 0.03, alpha: 1), .init(white: 0.78, alpha: 1)][index]
            let ropeMaterial = material(color, roughness: 0.6)
            for x: Float in [-4.5, 4.5] {
                stage.addChildNode(segment(from: SCNVector3(x, y, -4.5), to: SCNVector3(x, y, 4.5), radius: 0.038, material: ropeMaterial))
            }
            stage.addChildNode(segment(from: SCNVector3(-4.5, y, -4.5), to: SCNVector3(4.5, y, -4.5), radius: 0.038, material: ropeMaterial))

        }
    }

    private func buildStadium() {
        let arenaWall = SCNTube(innerRadius: 14, outerRadius: 14.2, height: 12)
        let wallMaterial = material(.init(red: 0.045, green: 0.075, blue: 0.13, alpha: 1), roughness: 1)
        wallMaterial.isDoubleSided = true
        arenaWall.materials = [wallMaterial]
        stage.addChildNode(node(arenaWall, at: SCNVector3(0, 4, -2)))
        let seating = material(.init(red: 0.018, green: 0.028, blue: 0.052, alpha: 1), roughness: 1)
        let skinTones: [UIColor] = [.init(red: 0.48, green: 0.30, blue: 0.21, alpha: 1), .init(red: 0.69, green: 0.48, blue: 0.32, alpha: 1), .init(red: 0.3, green: 0.17, blue: 0.12, alpha: 1)]
        let headGeometry = SCNSphere(radius: 0.13)
        headGeometry.segmentCount = 8
        let shirtColors: [UIColor] = [.init(red: 0.2, green: 0.3, blue: 0.4, alpha: 1), .init(red: 0.4, green: 0.09, blue: 0.08, alpha: 1), .init(red: 0.5, green: 0.39, blue: 0.1, alpha: 1), .init(red: 0.08, green: 0.2, blue: 0.16, alpha: 1)]
        let heads = skinTones.map { color -> SCNGeometry in let g = headGeometry.copy() as! SCNGeometry; let m = material(color); m.emission.contents = color; m.emission.intensity = 0.1; g.materials = [m]; return g }
        let bodies = shirtColors.map { color -> SCNGeometry in let g = SCNCapsule(capRadius: 0.15, height: 0.43); g.radialSegmentCount = 6; let m = material(color); m.emission.contents = color; m.emission.intensity = 0.1; g.materials = [m]; return g }
        for row in 0..<6 {
            let z = -6.3 - Float(row) * 1.18
            let y = Float(row) * 0.62
            let terrace = SCNBox(width: 27, height: 0.45, length: 1.1, chamferRadius: 0)
            terrace.materials = [seating]
            stage.addChildNode(node(terrace, at: SCNVector3(0, y - 0.32, z)))
            for column in 0..<42 {
                let x = Float(column) * 0.59 - 12.1
                let index = row * 42 + column
                let head = node(heads[index % heads.count], at: SCNVector3(x, y + 0.56, z))
                stage.addChildNode(head)
                stage.addChildNode(node(bodies[index % bodies.count], at: SCNVector3(x, y + 0.27, z)))
                if index % 7 == 0 {
                    let arm = segment(from: SCNVector3(x + 0.13, y + 0.38, z), to: SCNVector3(x + 0.24, y + 0.87, z), radius: 0.044, material: heads[index % heads.count].firstMaterial!)
                    stage.addChildNode(arm)
                }
            }
        }
        for x: Float in [-7, 7] {
            let banner = SCNBox(width: 1.2, height: 4, length: 0.04, chamferRadius: 0)
            banner.materials = [material(.init(red: 0.025, green: 0.065, blue: 0.13, alpha: 1))]
            stage.addChildNode(node(banner, at: SCNVector3(x, 5.3, -9.4)))
            let emblem = SCNText(string: "H", extrusionDepth: 0.01)
            emblem.font = UIFont(name: "AvenirNext-HeavyItalic", size: 1.1)
            emblem.materials = [material(.init(red: 0.83, green: 0.57, blue: 0.2, alpha: 1), metal: 0.8)]
            stage.addChildNode(node(emblem, at: SCNVector3(x - 0.43, 4.9, -9.34)))
        }
        let trussMaterial = material(.init(white: 0.16, alpha: 1), metal: 0.8)
        for z: Float in [-5, -9] {
            stage.addChildNode(segment(from: SCNVector3(-12, 4.9, z), to: SCNVector3(12, 4.9, z), radius: 0.1, material: trussMaterial))
            for x: Float in [-8, -4, 0, 4, 8] {
                let fixture = SCNSphere(radius: 0.14)
                let glow = material(.white)
                glow.emission.contents = UIColor(red: 0.65, green: 0.8, blue: 1, alpha: 1)
                glow.lightingModel = .constant
                glow.emission.intensity = 8
                fixture.materials = [glow]
                stage.addChildNode(node(fixture, at: SCNVector3(x, 4.75, z)))
            }
        }
    }

    private func buildLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(red: 0.3, green: 0.36, blue: 0.52, alpha: 1)
        ambient.light?.intensity = 330
        scene.rootNode.addChildNode(ambient)
        spotlight(at: SCNVector3(-3, 6, 4), color: .init(red: 1, green: 0.87, blue: 0.68, alpha: 1), intensity: 1000, shadows: true)
        spotlight(at: SCNVector3(4, 5, -3), color: .init(red: 0.38, green: 0.62, blue: 1, alpha: 1), intensity: 950, shadows: false)
        spotlight(at: SCNVector3(0, 7, 1), color: .init(white: 0.92, alpha: 1), intensity: 650, shadows: false)
        for x: Float in [-6, 6] {
            spotlight(at: SCNVector3(x, 7, -5), color: .init(red: 0.5, green: 0.7, blue: 1, alpha: 1), intensity: 700, shadows: false)
            let beam = SCNCone(topRadius: 0.06, bottomRadius: 1.6, height: 6.7)
            let haze = SCNMaterial()
            haze.lightingModel = .constant
            haze.diffuse.contents = UIColor(red: 0.43, green: 0.66, blue: 1, alpha: 0.06)
            haze.isDoubleSided = true
            haze.writesToDepthBuffer = false
            haze.blendMode = .add
            beam.materials = [haze]
            let cone = node(beam, at: SCNVector3(x * 0.8, 3.7, -5))
            cone.eulerAngles.z = x < 0 ? -0.18 : 0.18
            stage.addChildNode(cone)
        }
    }

    /// Slow, drifting smoke: a low ground bank around the ring plus a deeper
    /// haze layer through the rafters, so the lights read as cutting through a
    /// smoky arena. Pre-warmed so it is already in place on the first frame.
    private func buildMist() {
        let puff = Self.mistPuff()
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0.0, 0.25, 0.7, 1.0]
        let grow = CAKeyframeAnimation()
        grow.values = [0.8, 1.0, 1.35]
        grow.keyTimes = [0.0, 0.5, 1.0]

        func system(_ shape: SCNBox, rate: CGFloat, life: CGFloat, size: CGFloat, alpha: CGFloat, tint: UIColor, drift: SCNVector3) -> SCNParticleSystem {
            let s = SCNParticleSystem()
            s.particleImage = puff
            s.emitterShape = shape
            s.birthLocation = .volume
            s.birthRate = rate
            s.particleLifeSpan = life
            s.particleLifeSpanVariation = life * 0.3
            s.warmupDuration = TimeInterval(life)
            s.particleSize = size
            s.particleSizeVariation = size * 0.4
            s.particleVelocity = 0.25
            s.particleVelocityVariation = 0.15
            s.emittingDirection = drift
            s.spreadingAngle = 25
            s.particleAngularVelocity = 4
            s.particleAngularVelocityVariation = 6
            s.particleColor = tint.withAlphaComponent(alpha)
            s.blendMode = .alpha
            s.isLightingEnabled = false
            s.isLocal = false
            s.sortingMode = .distance
            s.propertyControllers = [
                .opacity: SCNParticlePropertyController(animation: fade),
                .size: SCNParticlePropertyController(animation: grow)
            ]
            return s
        }

        // Ground bank: hugs the canvas and the apron, keeps the fighters clear.
        let ground = SCNNode()
        ground.position = SCNVector3(0, 0.45, -1.5)
        ground.addParticleSystem(system(SCNBox(width: 20, height: 0.5, length: 16, chamferRadius: 0), rate: 3.2, life: 16, size: 4.2, alpha: 0.075,
                                        tint: UIColor(red: 0.62, green: 0.7, blue: 0.82, alpha: 1), drift: SCNVector3(1, 0, 0.25)))
        mist.addChildNode(ground)

        // Rafter haze: lit by the truss fixtures, thickest behind the ring.
        let rafters = SCNNode()
        rafters.position = SCNVector3(0, 3.6, -7)
        rafters.addParticleSystem(system(SCNBox(width: 24, height: 4, length: 8, chamferRadius: 0), rate: 2.4, life: 20, size: 7, alpha: 0.06,
                                         tint: UIColor(red: 0.5, green: 0.62, blue: 0.82, alpha: 1), drift: SCNVector3(-1, 0.05, 0.1)))
        mist.addChildNode(rafters)
        stage.addChildNode(mist)
    }

    /// A soft radial puff used for every smoke particle.
    private static func mistPuff() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 1, alpha: 1).cgColor, UIColor(white: 1, alpha: 0.35).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size.width / 2, options: [])
        }
    }

    private func spotlight(at position: SCNVector3, color: UIColor, intensity: CGFloat, shadows: Bool) {
        let light = SCNNode()
        light.position = position
        light.light = SCNLight()
        light.light?.type = .spot
        light.light?.color = color
        light.light?.intensity = intensity
        light.light?.spotInnerAngle = 28
        light.light?.spotOuterAngle = 68
        light.light?.attenuationStartDistance = 2
        light.light?.attenuationEndDistance = 24
        light.light?.castsShadow = shadows
        light.light?.shadowMode = .deferred
        light.light?.shadowSampleCount = 8
        light.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        light.light?.shadowColor = UIColor(white: 0, alpha: 0.6)
        light.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(light)
    }

    private func impact(at position: SCNVector3, strong: Bool) {
        let sparks = SCNParticleSystem()
        sparks.birthRate = strong ? 700 : 420
        sparks.emissionDuration = 0.025
        sparks.loops = false
        sparks.particleLifeSpan = 0.22
        sparks.particleLifeSpanVariation = 0.1
        sparks.particleSize = 0.025
        sparks.particleVelocity = 3.3
        sparks.particleVelocityVariation = 1.8
        sparks.spreadingAngle = 180
        sparks.particleColor = UIColor(red: 1, green: 0.76, blue: 0.24, alpha: 1)
        sparks.blendMode = .additive
        sparks.isLightingEnabled = false
        let emitter = SCNNode()
        emitter.position = position
        emitter.addParticleSystem(sparks)
        stage.addChildNode(emitter)
        effects.append((emitter, lastTick + 42))
    }

    private func trail(rivalDodged: Bool) {
        let arc = SCNTorus(ringRadius: 0.62, pipeRadius: 0.015)
        let glow = material(.white)
        glow.lightingModel = .constant
        glow.emission.contents = UIColor.white
        arc.materials = [glow]
        let streak = node(arc, at: rivalDodged ? SCNVector3(0.4, 1.8, -0.15) : SCNVector3(-0.8, 1.45, 1.2))
        streak.scale = SCNVector3(1.3, 0.35, 1)
        stage.addChildNode(streak)
        streak.runAction(.group([.scale(to: 1.9, duration: 0.22), .fadeOut(duration: 0.22)]))
        effects.append((streak, lastTick + 14))
    }
}

@MainActor private func material(_ color: UIColor, metal: CGFloat = 0, roughness: CGFloat = 0.5) -> SCNMaterial {
    let result = SCNMaterial()
    result.lightingModel = .physicallyBased
    result.diffuse.contents = color
    result.metalness.contents = metal
    result.roughness.contents = roughness
    return result
}

@MainActor private func node(_ geometry: SCNGeometry, at position: SCNVector3) -> SCNNode {
    let result = SCNNode(geometry: geometry)
    result.position = position
    return result
}

private func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
    sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2))
}
private func midpoint(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
}

@MainActor private func segment(from a: SCNVector3, to b: SCNVector3, radius: CGFloat, material: SCNMaterial) -> SCNNode {
    let geometry = SCNCylinder(radius: radius, height: CGFloat(distance(a, b)))
    geometry.radialSegmentCount = 12
    geometry.materials = [material]
    let result = node(geometry, at: midpoint(a, b))
    result.look(at: b, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 1, 0))
    return result
}

/// A studio reflection environment for the PBR leather, satin, and gold surfaces.
@MainActor private func reflectionEnvironment() -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256))
    return renderer.image { context in
        let cg = context.cgContext
        let colors = [UIColor(red: 0.035, green: 0.07, blue: 0.14, alpha: 1).cgColor,
                      UIColor(red: 0.22, green: 0.29, blue: 0.4, alpha: 1).cgColor,
                      UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        }
        UIColor(white: 0.95, alpha: 1).setFill()
        cg.fill(CGRect(x: 75, y: 30, width: 95, height: 28))
        UIColor(red: 0.6, green: 0.77, blue: 1, alpha: 1).setFill()
        cg.fill(CGRect(x: 340, y: 55, width: 65, height: 48))
        UIColor(red: 1, green: 0.83, blue: 0.58, alpha: 1).setFill()
        cg.fill(CGRect(x: 175, y: 70, width: 38, height: 65))
    }
}
