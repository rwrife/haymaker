import SceneKit
import UIKit
import HaymakerKit

/// A real, articulated 3D arena. SceneKit's renderer is explicitly Metal.
/// Presentation reads the deterministic engine; animation never changes the rules.
@MainActor final class MatchScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let stage = SCNNode()
    private let rival = BoxerModel(isRival: true)
    private let hero = BoxerModel(isRival: false)
    private var lastEventCount = 0
    private var reducedMotion = false
    private var shake: Float = 0
    private var recoilRival: Float = 0
    private var recoilHero: Float = 0
    private var portrait = true
    private var lastTick = 0

    init() {
        scene.background.contents = UIColor(red: 0.014, green: 0.023, blue: 0.047, alpha: 1)
        scene.fogColor = UIColor(red: 0.015, green: 0.027, blue: 0.055, alpha: 1)
        scene.fogStartDistance = 15
        scene.fogEndDistance = 34
        scene.lightingEnvironment.contents = reflectionEnvironment()
        scene.lightingEnvironment.intensity = 0.65
        scene.rootNode.addChildNode(stage)
        buildRing()
        buildStadium()
        buildLighting()
        rival.root.position = SCNVector3(0.62, 0, -0.65)
        hero.root.position = SCNVector3(-0.65, 0, 1.05)
        hero.root.eulerAngles.y = .pi - 0.16
        rival.root.eulerAngles.y = 0.08
        stage.addChildNode(rival.root)
        stage.addChildNode(hero.root)
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 48
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 60
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = 0.1
        camera.camera?.bloomIntensity = 0.55
        camera.camera?.bloomThreshold = 1.1
        camera.camera?.bloomBlurRadius = 7
        camera.camera?.vignettingIntensity = 0.65
        camera.camera?.vignettingPower = 0.7
        camera.camera?.screenSpaceAmbientOcclusionIntensity = 0.7
        camera.camera?.screenSpaceAmbientOcclusionRadius = 0.25
        scene.rootNode.addChildNode(camera)
        rival.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: true)
        hero.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: true)
        layout(portrait: true)
    }

    func layout(portrait: Bool) {
        self.portrait = portrait
        camera.position = portrait ? SCNVector3(0, 2.95, 7.9) : SCNVector3(0, 2.55, 4.8)
        camera.look(at: SCNVector3(0, portrait ? 1.5 : 2.1, 0))
        camera.camera?.fieldOfView = portrait ? 43 : 38
    }

    func render(_ fight: FightEngine, reducedMotion: Bool, highContrast: Bool) {
        self.reducedMotion = reducedMotion
        let elapsed = max(0, fight.totalTicks - lastTick)
        lastTick = fight.totalTicks
        let decay = pow(Float(0.86), Float(elapsed))
        recoilHero *= decay
        recoilRival *= decay
        shake *= decay
        let t = Float(fight.totalTicks) / 60
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        rival.pose(fight.opponent, time: t, recoil: recoilRival, reducedMotion: reducedMotion)
        hero.pose(fight.player, time: t + 0.8, recoil: recoilHero, reducedMotion: reducedMotion)
        rival.root.position.x = 0.62
        hero.root.position.x = -0.65 + (fight.player.state == .dodging ? -0.62 : 0)
        hero.root.position.z = fight.player.state == .attacking ? 0.72 : 1.05
        rival.root.position.z = fight.opponent.state == .attacking ? -0.15 : -0.65
        if !reducedMotion {
            camera.position.x = sin(t * 91) * shake
            camera.position.y = (portrait ? 2.95 : 2.55) + cos(t * 77) * shake * 0.5
        } else { camera.position.x = 0; camera.position.y = portrait ? 2.95 : 2.55 }
        SCNTransaction.commit()
        if fight.events.count < lastEventCount { lastEventCount = 0 }
        for event in fight.events.dropFirst(lastEventCount) {
            switch event {
            case let .landed(_, by, _, damage, counter):
                if by == .player { recoilRival = 0.35 } else { recoilHero = 0.3 }
                if !reducedMotion {
                    shake = counter ? 0.085 : 0.045
                    impact(at: by == .player ? SCNVector3(0.4, 2.15, -0.15) : SCNVector3(-0.5, 1.9, 1.3), strong: damage > 15)
                }
            case .parried, .dodged:
                if !reducedMotion { trail() }
            default: break
            }
        }
        lastEventCount = fight.events.count
    }

    private func buildRing() {
        let ivory = material(UIColor(red: 0.79, green: 0.75, blue: 0.61, alpha: 1), roughness: 0.95)
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
            let color: UIColor = [.init(red: 0.045, green: 0.16, blue: 0.43, alpha: 1), .white, .init(red: 0.64, green: 0.02, blue: 0.03, alpha: 1), .white][index]
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
        let heads = skinTones.map { color -> SCNGeometry in let g = headGeometry.copy() as! SCNGeometry; let m = material(color); m.emission.contents = color; m.emission.intensity = 0.3; g.materials = [m]; return g }
        let bodies = shirtColors.map { color -> SCNGeometry in let g = SCNCapsule(capRadius: 0.15, height: 0.43); g.radialSegmentCount = 6; let m = material(color); m.emission.contents = color; m.emission.intensity = 0.3; g.materials = [m]; return g }
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
        ambient.light?.color = UIColor(red: 0.36, green: 0.43, blue: 0.6, alpha: 1)
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)
        spotlight(at: SCNVector3(-3, 6, 4), color: .init(red: 1, green: 0.87, blue: 0.68, alpha: 1), intensity: 1700, shadows: true)
        spotlight(at: SCNVector3(4, 5, -3), color: .init(red: 0.38, green: 0.62, blue: 1, alpha: 1), intensity: 2200, shadows: false)
        spotlight(at: SCNVector3(0, 7, 1), color: .white, intensity: 1300, shadows: false)
        for x: Float in [-6, 6] {
            spotlight(at: SCNVector3(x, 7, -5), color: .init(red: 0.5, green: 0.7, blue: 1, alpha: 1), intensity: 1400, shadows: false)
            let beam = SCNCone(topRadius: 0.06, bottomRadius: 1.6, height: 6.7)
            let haze = SCNMaterial()
            haze.lightingModel = .constant
            haze.diffuse.contents = UIColor(red: 0.43, green: 0.66, blue: 1, alpha: 0.085)
            haze.isDoubleSided = true
            haze.writesToDepthBuffer = false
            haze.blendMode = .add
            beam.materials = [haze]
            let cone = node(beam, at: SCNVector3(x * 0.8, 3.7, -5))
            cone.eulerAngles.z = x < 0 ? -0.18 : 0.18
            stage.addChildNode(cone)
        }
    }

    private func spotlight(at position: SCNVector3, color: UIColor, intensity: CGFloat, shadows: Bool) {
        let light = SCNNode()
        light.position = position
        light.light = SCNLight()
        light.light?.type = .spot
        light.light?.color = color
        light.light?.intensity = intensity
        light.light?.spotInnerAngle = 35
        light.light?.spotOuterAngle = 80
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
        emitter.runAction(.sequence([.wait(duration: 0.7), .removeFromParentNode()]))
    }

    private func trail() {
        let arc = SCNTorus(ringRadius: 0.62, pipeRadius: 0.015)
        let glow = material(.white)
        glow.lightingModel = .constant
        glow.emission.contents = UIColor.white
        arc.materials = [glow]
        let streak = node(arc, at: SCNVector3(-0.8, 1.45, 1.2))
        streak.scale = SCNVector3(1.3, 0.35, 1)
        stage.addChildNode(streak)
        streak.runAction(.sequence([.group([.scale(to: 1.9, duration: 0.22), .fadeOut(duration: 0.22)]), .removeFromParentNode()]))
    }
}

/// Articulated mesh character with separate shoulders, elbows, torso, and head.
@MainActor private final class BoxerModel {
    let root = SCNNode()
    private let torso = SCNNode()
    private let head = SCNNode()
    private var shoulders: [SCNNode] = []
    private var elbows: [SCNNode] = []
    private let isRival: Bool
    private let skin: SCNMaterial
    private let darkSkin: SCNMaterial
    private let glove: SCNMaterial
    private let gold: SCNMaterial
    private let shorts: SCNMaterial

    init(isRival: Bool) {
        self.isRival = isRival
        skin = material(isRival ? .init(red: 0.72, green: 0.39, blue: 0.22, alpha: 1) : .init(red: 0.66, green: 0.43, blue: 0.28, alpha: 1), roughness: 0.52)
        darkSkin = material(.init(red: 0.35, green: 0.14, blue: 0.075, alpha: 1), roughness: 0.75)
        glove = material(isRival ? .init(red: 0.73, green: 0.013, blue: 0.025, alpha: 1) : .init(red: 0.025, green: 0.56, blue: 0.11, alpha: 1), metal: 0.25, roughness: 0.24)
        gold = material(isRival ? .init(red: 0.95, green: 0.61, blue: 0.09, alpha: 1) : .init(white: 0.8, alpha: 1), metal: 0.8, roughness: 0.3)
        shorts = material(isRival ? .init(red: 0.025, green: 0.095, blue: 0.36, alpha: 1) : .init(red: 0.016, green: 0.25, blue: 0.07, alpha: 1), metal: 0.15, roughness: 0.65)
        build()
        root.scale = isRival ? SCNVector3(1.13, 1.13, 1.13) : SCNVector3(0.96, 0.96, 0.96)
    }

    private func build() {
        root.addChildNode(torso)
        torso.position.y = 1.3
        let bodyMaterial = isRival ? skin : material(.init(red: 0.018, green: 0.13, blue: 0.065, alpha: 1), roughness: 0.9)
        if isRival, let sculpt = sculptedMesh("baxter-torso", material: skin) {
            torso.addChildNode(sculpt)
        } else {
            let body = loft(rings: [(0, 0.32, 0.2), (0.18, 0.36, 0.22), (0.43, 0.45, 0.24), (0.7, 0.56, 0.25), (0.85, 0.48, 0.22), (0.94, 0.21, 0.17)], material: bodyMaterial)
            torso.addChildNode(body)
            torso.addChildNode(ellipsoid(SCNVector3(0.15, 0.19, 0.15), at: SCNVector3(0, 1, 0), material: skin))
            for side: Float in [-1, 1] {
                torso.addChildNode(segment(from: SCNVector3(side * 0.32, 0.23, -0.19), to: SCNVector3(side * 0.36, 0.85, -0.19), radius: 0.01, material: gold))
            }
        }
        head.position = SCNVector3(0, 1.18, 0.02)
        torso.addChildNode(head)
        buildHead()
        for side: Float in [-1, 1] {
            let shoulder = SCNNode()
            shoulder.position = SCNVector3(side * 0.49, 0.73, 0)
            torso.addChildNode(shoulder)
            shoulders.append(shoulder)
            shoulder.addChildNode(ellipsoid(SCNVector3(0.215, 0.215, 0.22), at: SCNVector3(0, 0, 0), material: skin))
            shoulder.addChildNode(ellipsoid(SCNVector3(0.16, 0.27, 0.17), at: SCNVector3(0, -0.22, 0), material: skin))
            let elbow = SCNNode()
            elbow.position.y = -0.44
            shoulder.addChildNode(elbow)
            elbows.append(elbow)
            elbow.addChildNode(ellipsoid(SCNVector3(0.13, 0.14, 0.13), at: SCNVector3(0, 0, 0), material: skin))
            elbow.addChildNode(ellipsoid(SCNVector3(0.13, 0.23, 0.14), at: SCNVector3(0, -0.18, 0), material: skin))
            let cuff = SCNCylinder(radius: 0.15, height: 0.12)
            cuff.radialSegmentCount = 24
            cuff.materials = [gold]
            elbow.addChildNode(node(cuff, at: SCNVector3(0, -0.37, 0)))
            elbow.addChildNode(ellipsoid(SCNVector3(0.21, 0.25, 0.19), at: SCNVector3(0, -0.52, 0.035), material: glove))
            elbow.addChildNode(ellipsoid(SCNVector3(0.09, 0.16, 0.1), at: SCNVector3(-side * 0.17, -0.48, 0.12), material: glove))
            let seam = SCNTorus(ringRadius: 0.143, pipeRadius: 0.007)
            seam.materials = [gold]
            elbow.addChildNode(node(seam, at: SCNVector3(0, -0.32, 0)))
            // Individually modeled shorts legs, thighs, calves, and laced boots.
            let trunk = loft(rings: [(0, 0.25, 0.22), (0.25, 0.26, 0.23), (0.46, 0.2, 0.2)], material: shorts)
            trunk.position = SCNVector3(side * 0.21, 0.84, 0)
            root.addChildNode(trunk)
            root.addChildNode(ellipsoid(SCNVector3(0.2, 0.33, 0.18), at: SCNVector3(side * 0.26, 0.79, 0.01), material: skin))
            root.addChildNode(ellipsoid(SCNVector3(0.13, 0.29, 0.13), at: SCNVector3(side * 0.32, 0.4, 0.04), material: skin))
            let boot = material(isRival ? .init(red: 0.025, green: 0.055, blue: 0.18, alpha: 1) : .init(red: 0.018, green: 0.15, blue: 0.055, alpha: 1), metal: 0.15, roughness: 0.35)
            root.addChildNode(ellipsoid(SCNVector3(0.14, 0.2, 0.14), at: SCNVector3(side * 0.34, 0.22, 0.05), material: boot))
            root.addChildNode(ellipsoid(SCNVector3(0.16, 0.1, 0.26), at: SCNVector3(side * 0.34, 0.095, 0.16), material: boot))
            for i in 0..<5 {
                root.addChildNode(segment(from: SCNVector3(side * 0.34 - 0.065, 0.15 + Float(i) * 0.035, 0.19), to: SCNVector3(side * 0.34 + 0.065, 0.17 + Float(i) * 0.035, 0.19), radius: 0.009, material: gold))
            }
            root.addChildNode(segment(from: SCNVector3(side * 0.44, 0.87, 0), to: SCNVector3(side * 0.41, 1.27, 0), radius: 0.018, material: gold))
        }
        let waistband = loft(rings: [(0, 0.42, 0.23), (0.11, 0.39, 0.23)], material: gold)
        waistband.position.y = 1.28
        root.addChildNode(waistband)
    }

    private func buildHead() {
        let face = loft(rings: [(-0.18, 0.115, 0.13), (-0.1, 0.185, 0.15), (0.06, 0.22, 0.19), (0.23, 0.2, 0.17), (0.33, 0.14, 0.13)], material: skin)
        head.addChildNode(sculptedMesh("boxer-head", material: skin) ?? face)
        let white = material(.init(white: 0.92, alpha: 1), roughness: 0.45)
        let dark = material(.init(red: 0.024, green: 0.012, blue: 0.01, alpha: 1), roughness: 0.75)
        let hair = material(isRival ? .init(red: 0.21, green: 0.085, blue: 0.024, alpha: 1) : .init(red: 0.012, green: 0.019, blue: 0.019, alpha: 1), roughness: 0.63)
        for side: Float in [-1, 1] {
            head.addChildNode(ellipsoid(SCNVector3(0.064, 0.028, 0.018), at: SCNVector3(side * 0.097, 0.12, 0.171), material: darkSkin))
            head.addChildNode(ellipsoid(SCNVector3(0.046, 0.022, 0.016), at: SCNVector3(side * 0.095, 0.121, 0.187), material: white))
            head.addChildNode(ellipsoid(SCNVector3(0.014, 0.019, 0.011), at: SCNVector3(side * 0.082, 0.121, 0.207), material: dark))
            let brow = ellipsoid(SCNVector3(0.08, 0.021, 0.027), at: SCNVector3(side * 0.098, 0.165, 0.189), material: hair)
            brow.eulerAngles.z = side * 0.21
            head.addChildNode(brow)
        }
        head.addChildNode(ellipsoid(SCNVector3(0.083, 0.023, 0.015), at: SCNVector3(0, -0.058, 0.16), material: dark))
        head.addChildNode(ellipsoid(SCNVector3(0.067, 0.01, 0.013), at: SCNVector3(0, -0.048, 0.173), material: white))
        head.addChildNode(ellipsoid(SCNVector3(0.21, 0.18, 0.18), at: SCNVector3(0, 0.26, -0.04), material: hair))
        // Swept tapered locks, with layered silhouettes instead of a spherical hair cap.
        let locks = isRival ? 23 : 14
        for i in 0..<locks {
            let angle = Float(i) * 2.399
            let radius: Float = i < 8 ? 0.1 : 0.18
            let start = SCNVector3(cos(angle) * radius, 0.27 + Float(i % 3) * 0.026, sin(angle) * radius * 0.65 - 0.025)
            let end = SCNVector3(start.x * 1.55 + 0.07, start.y + (isRival ? 0.22 : 0.07) + Float(i % 4) * 0.022, start.z - (isRival ? 0.17 : 0.065))
            let control = SCNVector3(start.x * 1.35, start.y + (isRival ? 0.24 : 0.12), start.z - 0.04)
            let strand = sweptLock(from: start, control: control, to: end, width: isRival ? 0.068 : 0.047, material: hair)
            head.addChildNode(strand)
        }
    }

    func pose(_ status: FighterStatus, time: Float, recoil: Float, reducedMotion: Bool) {
        let bob: Float = reducedMotion ? 0 : sin(time * 6) * 0.025
        torso.position.y = 1.3 + bob
        torso.eulerAngles.x = -recoil
        torso.eulerAngles.z = 0
        root.eulerAngles.z = 0
        head.eulerAngles.y = isRival ? -0.12 : 0.1
        for (i, shoulder) in shoulders.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            shoulder.eulerAngles = SCNVector3(-0.7, 0, side * 0.28)
            elbows[i].eulerAngles.x = -1.6
        }
        switch status.state {
        case .telling:
            let p = Float(status.ticksInCurrentState) / Float(max(1, status.stateDuration))
            let index = status.currentMove == .hook ? 1 : 0
            shoulders[index].eulerAngles.x = -0.4 + p * 0.45
            shoulders[index].eulerAngles.z = index == 1 ? 0.8 : -0.6
            torso.eulerAngles.y = status.currentMove == .feint ? 0.15 * sin(time * 18) : -0.18 * p
        case .attacking:
            let progress = Float(status.ticksInCurrentState) / Float(max(1, status.stateDuration))
            let extend = sin(min(1, progress) * .pi / 2)
            let index = status.currentMove == .hook ? 1 : 0
            shoulders[index].eulerAngles.x = -0.7 - extend * 0.8
            shoulders[index].eulerAngles.z = status.currentMove == .hook ? 0.25 - extend * 0.7 : -0.12
            elbows[index].eulerAngles.x = status.currentMove == .uppercut ? -1.4 : -1.6 + extend * 1.5
            torso.eulerAngles.y = extend * 0.18
        case .blocking, .parrying:
            shoulders[0].eulerAngles = SCNVector3(-1.1, -0.3, -0.12)
            shoulders[1].eulerAngles = SCNVector3(-1.1, 0.3, 0.12)
            elbows.forEach { $0.eulerAngles.x = -1.9 }
        case .dodging:
            torso.eulerAngles.z = reducedMotion ? 0 : 0.32
            torso.position.y -= 0.18
        case .knockedDown, .ko:
            root.eulerAngles.z = reducedMotion ? 0.2 : 1.05
        default:
            torso.eulerAngles.y = reducedMotion ? 0 : sin(time * 2.5) * 0.035
        }
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

@MainActor private func ellipsoid(_ scale: SCNVector3, at position: SCNVector3, material: SCNMaterial) -> SCNNode {
    let geometry = SCNSphere(radius: 1)
    geometry.segmentCount = 24
    geometry.materials = [material]
    let result = node(geometry, at: position)
    result.scale = scale
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

/// Smooth indexed surface of elliptical rings; used for sculpted torsos, jaws, and fabric.
@MainActor private func loft(rings: [(Float, Float, Float)], material: SCNMaterial) -> SCNNode {
    let count = 32
    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var indices: [UInt32] = []
    for (row, ring) in rings.enumerated() {
        let previous = rings[max(0, row - 1)]
        let next = rings[min(rings.count - 1, row + 1)]
        let dy = max(0.001, next.0 - previous.0)
        for i in 0..<count {
            let angle = Float(i) * 2 * .pi / Float(count)
            vertices.append(SCNVector3(cos(angle) * ring.1, ring.0, sin(angle) * ring.2))
            let n = SCNVector3(cos(angle) / ring.1, -((next.1 - previous.1) * cos(angle) * cos(angle) / ring.1 + (next.2 - previous.2) * sin(angle) * sin(angle) / ring.2) / dy, sin(angle) / ring.2)
            let length = sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
            normals.append(SCNVector3(n.x / length, n.y / length, n.z / length))
            if row > 0 {
                let a = UInt32((row - 1) * count + i)
                let b = UInt32((row - 1) * count + (i + 1) % count)
                let c = UInt32(row * count + i)
                let d = UInt32(row * count + (i + 1) % count)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
    }
    // Close end caps so punches and camera movement never reveal hollow meshes.
    for (row, upward) in [(0, false), (rings.count - 1, true)] {
        let center = UInt32(vertices.count)
        vertices.append(SCNVector3(0, rings[row].0, 0))
        normals.append(SCNVector3(0, upward ? 1 : -1, 0))
        for i in 0..<count {
            let a = UInt32(row * count + i)
            let b = UInt32(row * count + (i + 1) % count)
            indices.append(contentsOf: upward ? [center, b, a] : [center, a, b])
        }
    }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geometry.materials = [material]
    geometry.subdivisionLevel = 0
    return SCNNode(geometry: geometry)
}

@MainActor private func sculptedMesh(_ name: String, material: SCNMaterial) -> SCNNode? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "obj"),
          let meshScene = try? SCNScene(url: url, options: nil) else { return nil }
    let root = SCNNode()
    for child in meshScene.rootNode.childNodes { root.addChildNode(child.clone()) }
    root.enumerateChildNodes { node, _ in node.geometry?.materials = [material] }
    return root
}

@MainActor private func sweptLock(from a: SCNVector3, control b: SCNVector3, to c: SCNVector3, width: Float, material: SCNMaterial) -> SCNNode {
    let rows = 9, sides = 10
    var points: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [UInt32] = []
    let av = SIMD3<Float>(a.x, a.y, a.z), bv = SIMD3<Float>(b.x, b.y, b.z), cv = SIMD3<Float>(c.x, c.y, c.z)
    for row in 0..<rows {
        let t = Float(row) / Float(rows - 1)
        let center = (1-t)*(1-t)*av + 2*(1-t)*t*bv + t*t*cv
        let tangent = simd_normalize(2*(1-t)*(bv-av) + 2*t*(cv-bv))
        let right = simd_normalize(simd_cross(tangent, SIMD3<Float>(0, 0, 1)))
        let forward = simd_cross(tangent, right)
        let radius = width * pow(max(0.025, 1-t), 0.75)
        for i in 0..<sides {
            let angle = Float(i) * 2 * .pi / Float(sides)
            let normal = right*cos(angle) + forward*sin(angle)
            let p = center + radius * normal
            points.append(SCNVector3(p.x, p.y, p.z))
            normals.append(SCNVector3(normal.x, normal.y, normal.z))
            if row > 0 {
                let a = UInt32((row-1)*sides+i), b = UInt32((row-1)*sides+(i+1)%sides)
                let c = UInt32(row*sides+i), d = UInt32(row*sides+(i+1)%sides)
                indices.append(contentsOf: [a,b,c,b,d,c])
            }
        }
    }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points), SCNGeometrySource(normals: normals)], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geometry.materials = [material]
    return SCNNode(geometry: geometry)
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
