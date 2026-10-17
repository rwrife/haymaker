import SceneKit
import HaymakerKit

/// All supplied sculpts share the same named, 16-bone T-pose skeleton.
enum FighterModelAsset: String, CaseIterable {
    case mack, bruiser, goldie, nico, atlas, duke, sylvie, cassian, vera
}

@MainActor final class BoxerModel {
    let root = SCNNode()
    private let bones: [SCNNode]
    private let bindPositions: [SIMD3<Float>]
    private let isRival: Bool
    static let maximumHeadYaw: Float = .pi / 60 // Three degrees, including hit reactions.

    convenience init(isRival: Bool) {
        self.init(asset: isRival ? .bruiser : .mack, isRival: isRival)
    }

    init(asset: FighterModelAsset, isRival: Bool) {
        self.isRival = isRival
        let rig = FighterRig.load(asset)
        bones = rig.bones
        bindPositions = rig.positions
        root.name = asset.rawValue
        root.addChildNode(rig.skeleton)
        root.addChildNode(rig.mesh)
        root.scale = isRival ? SCNVector3(1.13, 1.13, 1.13) : SCNVector3(0.96, 0.96, 0.96)
    }

    private var previousState: FighterState = .idle
    private var punchMove: Move = .idle
    private var hasWindup = false
    private(set) var forwardDrive: Float = 0
    private(set) var slip: Float = 0

    func resetMotion() {
        previousState = .idle
        punchMove = .idle
        hasWindup = false
        forwardDrive = 0
        slip = 0
    }

    private func ease(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    func pose(_ status: FighterStatus, time: Float, recoil: Float, reducedMotion: Bool) {
        for bone in bones {
            bone.simdOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
            bone.simdScale = SIMD3<Float>(repeating: 1)
        }
        bones[0].simdPosition = bindPositions[0]
        root.simdEulerAngles.z = 0
        let progress = min(1, max(0, Float(status.ticksInCurrentState) / Float(max(1, status.stateDuration))))
        let down = status.state == .knockedDown || status.state == .ko
        let rhythm: Float = reducedMotion || down ? 0 : 1
        // A slower respiratory cycle gently expands the chest and raises the
        // shoulders independently of the quicker boxing weight shift.
        let breath = (sin(time * 2.1) + 1) * 0.5 * rhythm
        bones[1].simdScale = SIMD3<Float>(1 + breath * 0.008, 1 + breath * 0.005, 1 + breath * 0.012)
        let beat = time * 4.6
        let sway = sin(beat) * rhythm
        let bounce = (1 - cos(beat * 2)) * 0.012 * rhythm
        var targets = [SIMD3<Float>(-0.17, 0.75, 0.15), SIMD3<Float>(0.17, 0.75, 0.13)]
        let guardTargets = targets
        var reachAmount: Float = 0
        var chamber: Float = 0
        var twist: Float = 0
        forwardDrive = 0
        slip = 0

        if status.state == .telling || status.state == .attacking {
            if status.state != previousState {
                hasWindup = status.state == .telling || previousState == .telling
            }
            punchMove = status.currentMove
        } else if status.state != .recovering || (previousState != .attacking && previousState != .telling && previousState != .recovering) {
            punchMove = .idle
        }
        let offensive = punchMove == .jab || punchMove == .hook || punchMove == .uppercut || punchMove == .feint
        if offensive {
            switch status.state {
            case .telling:
                chamber = ease(progress)
            case .attacking:
                // The player's windup is inside attacking; opponents already
                // chambered during their authored, readable tell window.
                chamber = hasWindup ? 1 : ease(progress / 0.22)
                reachAmount = ease((progress - (hasWindup ? 0 : 0.22)) / (hasWindup ? 1 : 0.78))
            case .recovering:
                reachAmount = punchMove == .feint ? 0 : 1 - ease(progress)
                chamber = punchMove == .feint ? 1 - ease(progress) : reachAmount
            default: break
            }
            let arm = punchMove == .hook ? 1 : 0
            let sign: Float = arm == 0 ? -1 : 1
            var loaded = guardTargets[arm]
            loaded.x += sign * 0.045
            loaded.z -= 0.055
            if punchMove == .uppercut { loaded.y -= 0.11 }
            let start = simd_mix(guardTargets[arm], loaded, SIMD3<Float>(repeating: chamber))
            let contact: SIMD3<Float>
            switch punchMove {
            case .hook: contact = SIMD3<Float>(-0.08, 0.79, 0.32)
            case .uppercut: contact = SIMD3<Float>(-0.10, 0.83, 0.32)
            default: contact = SIMD3<Float>(-0.10, 0.77, 0.39)
            }
            targets[arm] = simd_mix(start, contact, SIMD3<Float>(repeating: reachAmount))
            // A hook travels around the guard rather than along a straight jab.
            if punchMove == .hook { targets[arm].x += sin(reachAmount * .pi) * 0.12 }
            twist = sign * (0.10 * chamber * (1 - reachAmount) - 0.18 * reachAmount)
            forwardDrive = reachAmount
        }
        switch status.state {
        case .blocking, .parrying:
            let raised = ease(Float(status.ticksInCurrentState) / 4)
            for side in 0..<2 {
                let high = SIMD3<Float>(side == 0 ? -0.105 : 0.105, 0.80, 0.15)
                targets[side] = simd_mix(targets[side], high, SIMD3<Float>(repeating: raised))
            }
        case .dodging:
            slip = sin(progress * .pi)
        case .knockedDown, .ko:
            root.simdEulerAngles.z = reducedMotion ? 0.2 : 1.05
        default: break
        }
        bones[0].simdPosition += SIMD3<Float>(sway * 0.026 - slip * 0.12, -0.085 - bounce - slip * 0.12, 0)
        bones[0].simdEulerAngles.y = twist * 0.35
        bones[1].simdEulerAngles = SIMD3<Float>(-min(max(recoil, 0), 0.3) + reachAmount * 0.035,
                                               twist + sway * 0.025, sway * 0.025 + slip * 0.16)
        // The jaw stays rigid with the skull, with only a bounded head yaw.
        bones[3].simdEulerAngles.y = isRival ? -0.025 : 0.025
        for side in 0..<2 {
            targets[side].y += sway * (side == 0 ? 0.004 : -0.004)
            poseArm(side, target: targets[side] * 2.7, reachAmount: reachAmount, punching: offensive && side == (punchMove == .hook ? 1 : 0))
            let phase = beat + (side == 0 ? 0 : Float.pi)
            // Alternating short shuffles: lift only the advancing foot. The
            // support leg is solved against the mat, not dragged by hip bob.
            let lift = pow(max(0, sin(phase)), 2) * 0.045 * rhythm
            let foot = bindPositions[12 + side * 3] + SIMD3<Float>(side == 0 ? -0.045 : 0.045,
                lift, (side == 0 ? 0.14 : -0.14) + cos(phase) * 0.045 * rhythm + reachAmount * 0.035)
            poseLeg(side, target: foot)
        }
        previousState = status.state
    }

    /// Solve in hip-local space so the feet counteract pelvis weight shifts.
    private func poseLeg(_ side: Int, target: SIMD3<Float>) {
        let hip = 10 + side * 3
        let knee = hip + 1
        let foot = hip + 2
        let targetInHips = bones[0].simdOrientation.inverse.act(target - bones[0].simdPosition)
        let origin = bindPositions[hip] - bindPositions[0]
        let upperAxis = bindPositions[knee] - bindPositions[hip]
        let lowerAxis = bindPositions[foot] - bindPositions[knee]
        let delta = targetInHips - origin
        let direction = simd_normalize(delta)
        let upper = simd_length(upperAxis), lower = simd_length(lowerAxis)
        let reach = min(upper + lower - 0.001, max(abs(upper - lower) + 0.001, simd_length(delta)))
        let along = (upper * upper - lower * lower + reach * reach) / (2 * reach)
        let pole = SIMD3<Float>(0, 0, 1)
        let bend = simd_normalize(pole - direction * simd_dot(pole, direction))
        let joint = direction * along + bend * sqrt(max(0, upper * upper - along * along))
        let upperRotation = simd_quatf(from: simd_normalize(upperAxis), to: simd_normalize(joint))
        let lowerRotation = simd_quatf(from: simd_normalize(lowerAxis), to: simd_normalize(direction * reach - joint))
        bones[hip].simdOrientation = upperRotation
        bones[knee].simdOrientation = upperRotation.inverse * lowerRotation
        bones[foot].simdOrientation = (bones[0].simdOrientation * lowerRotation).inverse
    }

    /// Two-bone IK preserves upper/lower arm lengths and keeps elbows away from
    /// the ribcage. Targets are in the spine's undeformed coordinate system.
    private func poseArm(_ side: Int, target: SIMD3<Float>, reachAmount: Float, punching: Bool) {
        let shoulder = 4 + side * 3
        let elbow = shoulder + 1
        let hand = shoulder + 2
        let origin = bindPositions[shoulder]
        let upper = simd_distance(origin, bindPositions[elbow])
        let lower = simd_distance(bindPositions[elbow], bindPositions[hand])
        let delta = target - origin
        let direction = simd_normalize(delta)
        let reach = min(upper + lower - 0.001, max(abs(upper - lower) + 0.001, simd_length(delta)))
        let along = (upper * upper - lower * lower + reach * reach) / (2 * reach)
        let pole = SIMD3<Float>(side == 0 ? -0.5 : 0.5, -1, 0)
        let bend = simd_normalize(pole - direction * simd_dot(pole, direction))
        let joint = origin + direction * along + bend * sqrt(max(0, upper * upper - along * along))
        let end = origin + direction * reach
        let restAxis = SIMD3<Float>(side == 0 ? -1 : 1, 0, 0)
        let upperRotation = simd_quatf(from: restAxis, to: simd_normalize(joint - origin))
        let lowerRotation = simd_quatf(from: restAxis, to: simd_normalize(end - joint))
        bones[shoulder].simdOrientation = upperRotation
        bones[elbow].simdOrientation = upperRotation.inverse * lowerRotation
        // T-pose glove thumbs point down when the forearm is simply aimed at
        // the guard. Roll each wrist half a turn around its outward bind axis
        // so thumbs sit inward/up; gradually turn the fist over on a punch.
        let roll = simd_quatf(angle: .pi + (punching ? reachAmount * .pi / 3 : 0), axis: restAxis)
        bones[hand].simdOrientation = roll
    }
}

/// HMR1 is built offline by scripts/rig_fighters.py. Vertex colors, normals
/// and packed skinning buffers go directly to SceneKit's Metal skinning path.
@MainActor private struct FighterRig {
    let bones: [SCNNode]
    let positions: [SIMD3<Float>]
    let skeleton: SCNNode
    let mesh: SCNNode

    static func load(_ asset: FighterModelAsset) -> FighterRig {
        guard let url = Bundle.main.url(forResource: asset.rawValue, withExtension: "fighter"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("Missing bundled fighter rig: \(asset.rawValue)")
        }
        func uint(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        func float(_ offset: Int) -> Float { Float(bitPattern: uint(offset)) }
        precondition(data.count >= 16 && data.prefix(4) == Data("HMR1".utf8), "Invalid fighter header")
        let vertexCount = Int(uint(4)), indexCount = Int(uint(8)), boneCount = Int(uint(12))
        precondition(boneCount == 16 && indexCount % 3 == 0)
        let vertexStart = 16 + boneCount * 16
        let indexStart = vertexStart + vertexCount * 60
        precondition(data.count == indexStart + indexCount * 4, "Invalid fighter payload")
        let names = ["hips", "spine", "neck", "head", "leftShoulder", "leftElbow", "leftHand", "rightShoulder", "rightElbow", "rightHand", "leftHip", "leftKnee", "leftFoot", "rightHip", "rightKnee", "rightFoot"]
        let skeleton = SCNNode()
        skeleton.name = "skeleton"
        var bones: [SCNNode] = [], positions: [SIMD3<Float>] = [], inverseBind: [NSValue] = []
        for i in 0..<boneCount {
            let offset = 16 + i * 16
            let parent = Int(Int32(bitPattern: uint(offset)))
            precondition(parent >= -1 && parent < i)
            let position = SIMD3<Float>(float(offset + 4), float(offset + 8), float(offset + 12))
            let bone = SCNNode()
            bone.name = names[i]
            bone.simdPosition = position - (parent >= 0 ? positions[parent] : .zero)
            (parent >= 0 ? bones[parent] : skeleton).addChildNode(bone)
            bones.append(bone)
            positions.append(position)
            var inverse = matrix_identity_float4x4
            inverse.columns.3 = SIMD4<Float>(-position, 1)
            inverseBind.append(NSValue(scnMatrix4: SCNMatrix4(inverse)))
        }
        let vertices = data.subdata(in: vertexStart..<indexStart)
        func source(_ semantic: SCNGeometrySource.Semantic, _ offset: Int, _ components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: vertices, semantic: semantic, vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4, dataOffset: offset, dataStride: 60)
        }
        let element = SCNGeometryElement(data: data.subdata(in: indexStart..<data.count), primitiveType: .triangles, primitiveCount: indexCount / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [source(.vertex, 0, 3), source(.normal, 12, 3), source(.color, 24, 3)], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor.white
        material.roughness.contents = 0.65
        geometry.materials = [material]
        let mesh = SCNNode(geometry: geometry)
        mesh.name = "skinnedMesh"
        // SceneKit requires packed skinning buffers here; interleaved sources
        // can silently return a nil skinner even when geometry renders correctly.
        var weights = [Float](), indices = [UInt16]()
        for i in 0..<vertexCount {
            for lane in 0..<4 {
                weights.append(float(vertexStart + i * 60 + 36 + lane * 4))
                let offset = vertexStart + i * 60 + 52 + lane * 2
                indices.append(data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) })
            }
        }
        let weightSource = SCNGeometrySource(data: weights.withUnsafeBytes { Data($0) }, semantic: .boneWeights, vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let indexSource = SCNGeometrySource(data: indices.withUnsafeBytes { Data($0) }, semantic: .boneIndices, vectorCount: vertexCount, usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
        mesh.skinner = SCNSkinner(baseGeometry: geometry, bones: bones, boneInverseBindTransforms: inverseBind, boneWeights: weightSource, boneIndices: indexSource)
        precondition(mesh.skinner != nil, "SceneKit rejected fighter skinning sources")
        // Keep the mesh eligible for culling after its T-pose arms move forward.
        mesh.boundingBox = (SCNVector3(-1.6, -0.2, -1.2), SCNVector3(1.6, 3.1, 1.2))
        return FighterRig(bones: bones, positions: positions, skeleton: skeleton, mesh: mesh)
    }
}
