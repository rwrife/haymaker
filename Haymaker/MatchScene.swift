import SceneKit
import UIKit
import HaymakerKit

/// A real, articulated 3D arena. SceneKit's renderer is explicitly Metal.
/// Presentation reads the deterministic engine; animation never changes the rules.
@MainActor final class MatchScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let stage = SCNNode()
    /// Keep rendering this long after the bout ends (knockout fall, celebration).
    static let postBoutRenderSeconds = 6.0
    /// Delay before the results card covers the arena, so the finish is seen.
    static let resultsDelay = 2.2
    private var rival = BoxerModel(isRival: true)
    private let hero = BoxerModel(isRival: false)
    private let choreographer: BoutChoreographer
    private var reducedMotion = false
    private var shake: Float = 0
    private var portrait = true
    private var lastRender: CFTimeInterval?
    private var effects: [(node: SCNNode, expires: Double)] = []
    private var cameraFollow = SIMD3<Float>(repeating: 0)
    private var spectators: [CrowdMember] = []
    private var flashNodes: [SCNNode] = []
    /// 0…1: lifts with heavy blows and knockdowns, eases back between exchanges.
    private var excitement: Float = 0
    private var lastCrowdTime: Float?

    private var titleScreen: Bool
    private var careerVictory = false
    private let mist = SCNNode()

    init(titleScreen: Bool = false) {
        self.titleScreen = titleScreen
        choreographer = BoutChoreographer(hero: hero, rival: rival)
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
        camera.camera?.exposureOffset = -0.65
        camera.camera?.bloomIntensity = 0.12
        camera.camera?.bloomThreshold = 2.2
        camera.camera?.bloomBlurRadius = 5
        camera.camera?.vignettingIntensity = 0.65
        camera.camera?.vignettingPower = 0.7
        camera.camera?.screenSpaceAmbientOcclusionIntensity = 0.9
        camera.camera?.screenSpaceAmbientOcclusionRadius = 0.25
        scene.rootNode.addChildNode(camera)
        choreographer.reset()
        choreographer.restPose()
        layout(portrait: true)
        if titleScreen { renderTitle(time: 0, reducedMotion: true) }
    }

    func resetForNextBout(book: OpponentBook) {
        if let key = book.character?.asset, let asset = FighterModelAsset(rawValue: key), rival.root.name != key {
            rival.root.removeFromParentNode()
            rival = BoxerModel(asset: asset, isRival: true)
            stage.addChildNode(rival.root)
            choreographer.replaceRival(rival)
        }
        // All child-list changes stay on the main actor, including effect cleanup.
        for effect in effects { effect.node.removeFromParentNode() }
        effects.removeAll()
        // Reuse the arena and renderer between rounds.
        titleScreen = false
        careerVictory = false
        rival.root.isHidden = false
        hero.root.eulerAngles.y = .pi - 0.16
        layout(portrait: portrait)
        lastRender = nil
        shake = 0
        cameraFollow = .zero
        excitement = 0.15
        lastCrowdTime = nil
        animateCrowd(time: 0, reducedMotion: true)
        choreographer.reset()
        choreographer.restPose()
    }

    func layout(portrait: Bool) {
        self.portrait = portrait
        camera.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        if careerVictory {
            hero.root.position = portrait ? SCNVector3(0, 0, 0.5) : SCNVector3(-1.9, 0, 0.5)
            camera.position = portrait ? SCNVector3(0, 2.5, 8.4) : SCNVector3(0, 2.7, 7.5)
            camera.look(at: SCNVector3(0, portrait ? 0.6 : 1.55, 0))
            camera.camera?.fieldOfView = portrait ? 43 : 38
            return
        }
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
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        rival.root.isHidden = true
        hero.poseTitle(time: time, reducedMotion: reducedMotion)
        hero.root.position = SCNVector3(0, 0, portrait ? 0.85 : 0.55)
        hero.root.eulerAngles.y = .pi / 9
        animateCrowd(time: Float(time), reducedMotion: reducedMotion)
        SCNTransaction.commit()
    }

    func beginCareerVictory(reducedMotion: Bool) {
        careerVictory = true
        titleScreen = false
        rival.root.isHidden = true
        for effect in effects { effect.node.removeFromParentNode() }
        effects.removeAll()
        hero.resetMotion()
        hero.root.eulerAngles.y = .pi / 9
        layout(portrait: portrait)
        excitement = 1
        lastCrowdTime = nil
        for person in spectators { person.erupt() }
        renderCareerVictory(time: 0, reducedMotion: reducedMotion)
    }

    /// Presentation only: the completed engine and saved results never advance.
    func renderCareerVictory(time: TimeInterval, reducedMotion: Bool) {
        guard careerVictory else { return }
        mist.isPaused = reducedMotion
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        hero.poseVictory(time: time, reducedMotion: reducedMotion)
        animateCrowd(time: Float(time), reducedMotion: reducedMotion)
        SCNTransaction.commit()
    }

    /// Render one frame. `frameDelta` advances the presentation clock (animation keeps
    /// moving while the engine is frozen for a countdown or after the bout);
    /// `tickFraction` is the unconsumed part of the next engine tick (0…1).
    func render(_ fight: FightEngine, reducedMotion: Bool, highContrast: Bool, frameDelta: Double? = nil, tickFraction: Double = 0) {
        self.reducedMotion = reducedMotion
        mist.isPaused = reducedMotion
        let wall = CACurrentMediaTime()
        let dt = min(0.1, max(0, frameDelta ?? lastRender.map { wall - $0 } ?? 0))
        lastRender = wall
        shake *= pow(Float(0.86), Float(dt * 60))
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        let cues = choreographer.update(fight, dt: dt, tickFraction: min(1, max(0, tickFraction)), reducedMotion: reducedMotion)
        let now = choreographer.clock
        for effect in effects where effect.expires <= now { effect.node.removeFromParentNode() }
        effects.removeAll { $0.expires <= now }
        for cue in cues where !reducedMotion {
            let position = SCNVector3(cue.position)
            switch cue.kind {
            case let .impact(strong, counter):
                shake = max(shake, counter ? 0.085 : 0.045)
                impact(at: position, strong: strong)
                if strong || counter { excitement = min(1, excitement + (counter ? 0.2 : 0.12)) }
            case .knockdown:
                shake = max(shake, 0.07)
                excitement = 1
                for person in spectators { person.erupt() }
            case .dodge, .parry:
                trail(at: position)
            case .blocked:
                break
            }
        }
        let t = Float(now)
        updateCamera(time: t, elapsed: Float(dt), reducedMotion: reducedMotion)
        animateCrowd(time: t, reducedMotion: reducedMotion)
        SCNTransaction.commit()
    }

    private func updateCamera(time t: Float, elapsed: Float, reducedMotion: Bool) {
        guard !reducedMotion else {
            cameraFollow = .zero
            // Restore position AND aim after toggling Reduced Motion mid-bout.
            layout(portrait: portrait)
            return
        }
        // A ringside operator eases after the action, with a very small dolly
        // and pedestal drift. No roll, cuts or aggressive zooms during play.
        let blend = 1 - exp(-elapsed * 2.4)
        cameraFollow += (choreographer.ringCenter - cameraFollow) * blend
        let settle = min(t / 2, 1)
        let drift = sin(t * 0.23) * 0.09 + sin(t * 0.53) * 0.025
        camera.position = SCNVector3(
            cameraFollow.x * 0.55 + drift * settle + sin(t * 91) * shake,
            (portrait ? 2.95 : 2.55) + sin(t * 0.31) * 0.035 * settle + cos(t * 77) * shake * 0.5,
            (portrait ? 7.9 : 4.8) + sin(t * 0.19) * 0.10 * settle)
        camera.look(at: SCNVector3(cameraFollow.x * 0.8, (portrait ? 1.5 : 2.1) + sin(t * 0.27) * 0.015 * settle, cameraFollow.z * 0.5))
    }

    private func animateCrowd(time t: Float, reducedMotion: Bool) {
        // The presentation clock restarts each bout; treat a jump back as a fresh start.
        let dt = lastCrowdTime.map { t >= $0 ? min(0.25, t - $0) : 0 } ?? 0
        lastCrowdTime = t
        excitement = max(0.15, excitement - dt * 0.05)
        for person in spectators {
            person.paused = reducedMotion
            if !reducedMotion { person.update(dt: dt, excitement: excitement) }
        }
        for flash in flashNodes { flash.isHidden = true }
        guard !reducedMotion, !flashNodes.isEmpty else { return }
        // One localized flash in each four-second window, at a varying offset.
        // Hashing the window gives random-looking timing without touching the fight RNG,
        // allocating effects per frame, or running actions while paused.
        let window = Int(t / 4)
        var hash = UInt64(window) &+ 0x9E37_79B9_7F4A_7C15
        hash = (hash ^ (hash >> 30)) &* 0xBF58_476D_1CE4_E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        let onset = Float(hash % 1_600) / 1_000 + 0.4
        let age = t - Float(window) * 4 - onset
        if age >= 0, age < 0.10 {
            let flash = flashNodes[Int((hash >> 8) % UInt64(flashNodes.count))]
            flash.isHidden = false
            flash.opacity = CGFloat((1 - age / 0.10) * 0.85)
        }
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
        let benchMaterial = material(.init(red: 0.05, green: 0.06, blue: 0.09, alpha: 1), roughness: 0.9)
        let flashTexture = Self.mistPuff()
        // Tripo3D fans (issue #42): life-size next to the fighters, seated on stepped benches.
        // Each body is scaled so its seated pelvis lands on the bench, which also gives a natural
        // spread of heights between the four bodies.
        let crowd = CrowdBodyAssets.all() ?? []
        let rowRise: Float = 0.62, rowDepth: Float = 1.18, benchHeight: Float = 0.55, pitch: Float = 0.82
        var index = 0
        for row in 0..<6 {
            let z = -6.3 - Float(row) * rowDepth
            let ground = Float(row) * rowRise - 0.1
            let tread = SCNBox(width: 29, height: 0.45, length: CGFloat(rowDepth), chamferRadius: 0)
            tread.materials = [seating]
            stage.addChildNode(node(tread, at: SCNVector3(0, ground - 0.225, z)))
            let bench = SCNBox(width: 29, height: CGFloat(benchHeight), length: 0.72, chamferRadius: 0.03)
            bench.materials = [benchMaterial]
            stage.addChildNode(node(bench, at: SCNVector3(0, ground + benchHeight / 2, z - 0.42)))
            // Top row stays empty under the trusses; lower rows widen with depth to fill the
            // landscape frame. Portrait only ever sees the middle few seats of each row.
            guard row < 5, !crowd.isEmpty else { continue }
            let depth: Float = z + 2   // arena wall tube is centred at z = -2, radius 14
            let wallReach: Float = (196 - depth * depth).squareRoot() - 0.7
            let half: Float = min(9 + Float(row) * 0.7, wallReach)
            let seats = Int(half * 2 / pitch)
            for column in 0..<seats {
                defer { index += 1 }
                var hash = UInt64(index) &* 0x9E37_79B9_7F4A_7C15 &+ 0x2545_F491_4F6C_DD1D
                hash ^= hash >> 29
                // About one seat in nine stays empty, like a real house.
                guard hash % 9 != 0 else { continue }
                let assets = crowd[Int((hash >> 8) % UInt64(crowd.count))]
                let look = Int((hash >> 16) % UInt64(assets.body.looks.count))
                let person = CrowdMember(assets: assets, look: look, seed: hash)
                let jitter: Float = (Float((hash >> 24) % 100) / 100 - 0.5) * 0.12
                let x: Float = -half + (Float(column) + 0.5) * pitch + jitter
                let stature: Float = 0.97 + Float((hash >> 32) % 7) * 0.01
                let scale: Float = benchHeight / assets.data.seat * stature
                let turn: Float = (Float((hash >> 40) % 100) / 100 - 0.5) * 0.2
                person.root.simdScale = SIMD3<Float>(repeating: scale)
                person.root.simdPosition = SIMD3<Float>(x, ground + benchHeight - assets.data.seat * scale, z - 0.25)
                // Face the ring, like the old crowd, with a little individual variation.
                person.root.eulerAngles.y = atan2(-x, -z) * 0.45 + turn
                stage.addChildNode(person.root)
                spectators.append(person)
                if index % 11 == 0 {
                    let flashMaterial = SCNMaterial()
                    flashMaterial.lightingModel = .constant
                    flashMaterial.diffuse.contents = flashTexture
                    flashMaterial.emission.contents = UIColor(red: 0.72, green: 0.85, blue: 1, alpha: 1)
                    flashMaterial.emission.intensity = 2
                    flashMaterial.blendMode = .add
                    flashMaterial.writesToDepthBuffer = false
                    let plane = SCNPlane(width: 0.42, height: 0.42)
                    plane.materials = [flashMaterial]
                    let flash = node(plane, at: SCNVector3(x + 0.2, ground + 1.25, z + 0.1))
                    flash.constraints = [SCNBillboardConstraint()]
                    flash.isHidden = true
                    stage.addChildNode(flash)
                    flashNodes.append(flash)
                }
            }
        }
        for x: Float in [-7, 7] {
            let banner = SCNBox(width: 1.2, height: 4, length: 0.04, chamferRadius: 0)
            banner.materials = [material(.init(red: 0.025, green: 0.065, blue: 0.13, alpha: 1))]
            // Behind the last row so standing fans never clip through the banners.
            stage.addChildNode(node(banner, at: SCNVector3(x, 5.8, -13.3)))
            let emblem = SCNText(string: "H", extrusionDepth: 0.01)
            emblem.font = UIFont(name: "AvenirNext-HeavyItalic", size: 1.1)
            emblem.materials = [material(.init(red: 0.83, green: 0.57, blue: 0.2, alpha: 1), metal: 0.8)]
            stage.addChildNode(node(emblem, at: SCNVector3(x - 0.43, 5.4, -13.24)))
        }
        let trussMaterial = material(.init(white: 0.16, alpha: 1), metal: 0.8)
        for z: Float in [-5, -9] {
            stage.addChildNode(segment(from: SCNVector3(-12, 4.9, z), to: SCNVector3(12, 4.9, z), radius: 0.1, material: trussMaterial))
            for x: Float in [-8, -4, 0, 4, 8] {
                let fixture = SCNSphere(radius: 0.14)
                let glow = material(.white)
                glow.emission.contents = UIColor(red: 0.65, green: 0.8, blue: 1, alpha: 1)
                glow.lightingModel = .constant
                glow.emission.intensity = 3
                fixture.materials = [glow]
                stage.addChildNode(node(fixture, at: SCNVector3(x, 4.75, z)))
            }
        }
        animateCrowd(time: 0, reducedMotion: true)
    }

    private func buildLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(red: 0.3, green: 0.36, blue: 0.52, alpha: 1)
        ambient.light?.intensity = 330
        scene.rootNode.addChildNode(ambient)
        spotlight(at: SCNVector3(-3, 6, 4), color: .init(red: 1, green: 0.87, blue: 0.68, alpha: 1), intensity: 780, shadows: true)
        spotlight(at: SCNVector3(4, 5, -3), color: .init(red: 0.38, green: 0.62, blue: 1, alpha: 1), intensity: 620, shadows: false)
        spotlight(at: SCNVector3(0, 7, 1), color: .init(white: 0.85, alpha: 1), intensity: 180, shadows: false)
        for x: Float in [-6, 6] {
            spotlight(at: SCNVector3(x, 7, -5), color: .init(red: 0.5, green: 0.7, blue: 1, alpha: 1), intensity: 300, shadows: false)
            let beam = SCNCone(topRadius: 0.06, bottomRadius: 1.6, height: 6.7)
            let haze = SCNMaterial()
            haze.lightingModel = .constant
            haze.diffuse.contents = UIColor(red: 0.43, green: 0.66, blue: 1, alpha: 0.035)
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
        effects.append((emitter, choreographer.clock + 0.7))
    }

    private func trail(at position: SCNVector3) {
        let arc = SCNTorus(ringRadius: 0.62, pipeRadius: 0.015)
        let glow = material(.white)
        glow.lightingModel = .constant
        glow.emission.contents = UIColor.white
        arc.materials = [glow]
        let streak = node(arc, at: position)
        streak.scale = SCNVector3(1.3, 0.35, 1)
        stage.addChildNode(streak)
        streak.runAction(.group([.scale(to: 1.9, duration: 0.22), .fadeOut(duration: 0.22)]))
        effects.append((streak, choreographer.clock + 0.24))
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
