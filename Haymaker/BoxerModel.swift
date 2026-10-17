import SceneKit
import HaymakerKit

/// All supplied sculpts share the same named, 16-bone T-pose skeleton.
enum FighterModelAsset: String, CaseIterable {
    case mack, bruiser, goldie, nico, atlas, duke, sylvie, cassian
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

    func pose(_ status: FighterStatus, time: Float, recoil: Float, reducedMotion: Bool) {
        // Reset every joint so no rotation leaks from a previous state.
        for bone in bones { bone.simdOrientation = simd_quatf(angle: 0, axis: [0, 1, 0]) }
        bones[0].simdPosition = bindPositions[0]
        root.simdEulerAngles.z = 0
        let bob: Float = reducedMotion ? 0 : sin(time * 6) * 0.018
        bones[0].simdPosition.y += bob
        bones[1].simdEulerAngles.x = -min(max(recoil, 0), 0.12)
        // Chin stays rigid with the skull. Recoil is carried by the torso; the
        // head never translates or counter-twists against the broad neck.
        bones[3].simdEulerAngles.y = min(Self.maximumHeadYaw, max(-Self.maximumHeadYaw, isRival ? -0.025 : 0.025))
        var targets = [SIMD3<Float>(-0.17, 0.74, 0.14), SIMD3<Float>(0.17, 0.74, 0.14)]
        let progress = min(1, max(0, Float(status.ticksInCurrentState) / Float(max(1, status.stateDuration))))
        let arm = status.currentMove == .hook ? 1 : 0
        switch status.state {
        case .telling:
            targets[arm].z -= 0.055 * progress
            targets[arm].x *= 1 + 0.3 * progress
            bones[1].simdEulerAngles.y = status.currentMove == .feint ? sin(time * 18) * 0.06 : -0.07 * progress
        case .attacking:
            let extend = sin(progress * .pi / 2)
            if status.currentMove == .hook {
                targets[arm] = SIMD3<Float>(0.20 - extend * 0.24, 0.76, 0.14 + extend * 0.10)
            } else if status.currentMove == .uppercut {
                targets[arm] = SIMD3<Float>(-0.12, 0.65 + extend * 0.16, 0.13 + extend * 0.09)
            } else {
                targets[arm] = SIMD3<Float>(-0.11, 0.76, 0.14 + extend * 0.14)
            }
            bones[1].simdEulerAngles.y = extend * 0.08
        case .blocking, .parrying:
            targets = [SIMD3<Float>(-0.105, 0.80, 0.15), SIMD3<Float>(0.105, 0.80, 0.15)]
        case .dodging:
            bones[1].simdEulerAngles.z = reducedMotion ? 0 : 0.16
            bones[0].simdPosition.y -= 0.12
        case .knockedDown, .ko:
            root.simdEulerAngles.z = reducedMotion ? 0.2 : 1.05
        default:
            bones[1].simdEulerAngles.y = reducedMotion ? 0 : sin(time * 2.5) * 0.025
        }
        for side in 0..<2 { poseArm(side, target: targets[side] * 2.7) }
    }

    /// Two-bone IK preserves upper/lower arm lengths and keeps elbows away from
    /// the ribcage. Targets are in the spine's undeformed coordinate system.
    private func poseArm(_ side: Int, target: SIMD3<Float>) {
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
