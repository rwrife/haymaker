import Foundation
import SceneKit
import os

/// Tripo3D-generated spectators (issue #42): four rigged ~5k-triangle bodies,
/// ten textures, and four baked clips. Format: ArtDirection/Crowd/README.md (CRW1).
enum CrowdBody: String, CaseIterable, Sendable {
    case casualMan = "casual-man", suitMan = "suit-man", casualWoman = "casual-woman", businessWoman = "business-woman"

    /// Texture looks per body (Haymaker/Models/crowd-<look>.jpg), all on the body's UV layout.
    var looks: [String] {
        switch self {
        case .casualMan: ["tee-gray", "polo-red", "tee-green"]
        case .suitMan: ["suit-charcoal", "suit-navy", "suit-brown"]
        case .casualWoman: ["tee-teal", "tee-yellow"]
        case .businessWoman: ["blazer-navy", "blazer-burgundy"]
        }
    }
}

enum CrowdClip: String, CaseIterable, Sendable {
    case sit, sitClap = "sit_clap", sitYell = "sit_yell", cheer
}

let crowdLog = Logger(subsystem: "Haymaker", category: "Crowd")

/// Parsed CRW1 asset (pure data). Root + the 22 Mixamo bones; Y up, facing +Z, unit height.
struct CrowdData: Sendable {
    struct Bone: Sendable {
        let parent: Int
        let translation: SIMD3<Float>
        let rotation: SIMD4<Float>   // quaternion x, y, z, w
        let inverseBind: [Float]     // 16, column-major
    }
    struct Clip: Sendable {
        let fps: Float
        let frames: Int
        let rotations: [SIMD4<Float>]   // frames × bones
        let hips: [SIMD3<Float>]        // frames
    }
    static let boneCount = 23
    static let hips = 1
    static let headerSize = 28, boneSize = 96, vertexSize = 56

    let height: Float
    /// Bench height under the seated pelvis (unit-height space).
    let seat: Float
    let bones: [Bone]
    let vertexCount: Int
    let indexCount: Int
    /// 56-byte vertices: position, normal, uv, 4 weights, 4 u16 bone indices.
    let vertices: Data
    let indices: Data   // u16
    let clips: [CrowdClip: Clip]

    static func parse(_ raw: Data, name: String) throws -> CrowdData {
        let data = raw.startIndex == 0 ? raw : Data(raw)
        let reader = BinaryReader(data: data)
        guard data.count >= headerSize, data.prefix(4) == Data("CRW1".utf8) else { throw FighterAssetError.invalid("\(name): expected CRW1") }
        let vertexCount = Int(try reader.u32(4)), indexCount = Int(try reader.u32(8))
        let boneCount = Int(try reader.u32(12)), clipCount = Int(try reader.u32(16))
        let height = try reader.f32(20), seat = try reader.f32(24)
        guard boneCount == Self.boneCount, vertexCount > 0, vertexCount < 65_535, indexCount > 0, indexCount % 3 == 0,
              height > 0, seat > 0, seat < height else { throw FighterAssetError.invalid("\(name): bad header") }
        var bones: [Bone] = []
        for bone in 0..<boneCount {
            let o = headerSize + bone * boneSize
            let parent = Int(Int32(bitPattern: try reader.u32(o)))
            guard parent < bone, (parent >= 0) == (bone > 0) else { throw FighterAssetError.invalid("\(name): bone \(bone) parent") }
            bones.append(Bone(parent: parent, translation: try reader.vec3(o + 4),
                              rotation: SIMD4(try reader.f32(o + 16), try reader.f32(o + 20), try reader.f32(o + 24), try reader.f32(o + 28)),
                              inverseBind: try (0..<16).map { try reader.f32(o + 32 + $0 * 4) }))
        }
        let vertexStart = headerSize + boneCount * boneSize
        let indexStart = vertexStart + vertexCount * vertexSize
        var offset = indexStart + indexCount * 2
        offset += (4 - offset % 4) % 4
        guard data.count >= offset else { throw FighterAssetError.invalid("\(name): truncated mesh") }
        let vertices = data.subdata(in: vertexStart..<indexStart)
        let indices = data.subdata(in: indexStart..<indexStart + indexCount * 2)
        let goodVertices: Bool = vertices.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            for v in 0..<vertexCount {
                var total: Float = 0
                for lane in 0..<4 {
                    let w = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: v * vertexSize + 32 + lane * 4, as: UInt32.self)))
                    let joint = Int(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: v * vertexSize + 48 + lane * 2, as: UInt16.self)))
                    guard w.isFinite, w >= -1e-4, joint < boneCount else { return false }
                    total += w
                }
                guard abs(total - 1) < 0.01 else { return false }
            }
            return true
        }
        let goodIndices: Bool = indices.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            for i in 0..<indexCount where Int(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))) >= vertexCount {
                return false
            }
            return true
        }
        guard goodVertices, goodIndices else { throw FighterAssetError.invalid("\(name): bad weights or indices") }
        var clips: [CrowdClip: Clip] = [:]
        for _ in 0..<clipCount {
            let id = try reader.string(offset, length: 16)
            let fps = try reader.f32(offset + 16), frames = Int(try reader.u32(offset + 20))
            offset += 24
            guard fps > 0, frames > 0, offset + frames * (boneCount * 16 + 12) <= data.count else { throw FighterAssetError.invalid("\(name): clip \(id)") }
            var rotations: [SIMD4<Float>] = []
            rotations.reserveCapacity(frames * boneCount)
            for i in 0..<(frames * boneCount) {
                let o = offset + i * 16
                rotations.append(SIMD4(try reader.f32(o), try reader.f32(o + 4), try reader.f32(o + 8), try reader.f32(o + 12)))
            }
            offset += frames * boneCount * 16
            let hips = try (0..<frames).map { try reader.vec3(offset + $0 * 12) }
            offset += frames * 12
            if let clip = CrowdClip(rawValue: id) { clips[clip] = Clip(fps: fps, frames: frames, rotations: rotations, hips: hips) }
        }
        guard offset == data.count, clips.count == CrowdClip.allCases.count else { throw FighterAssetError.invalid("\(name): clips") }
        return CrowdData(height: height, seat: seat, bones: bones, vertexCount: vertexCount, indexCount: indexCount,
                         vertices: vertices, indices: indices, clips: clips)
    }
}

/// Shared SceneKit resources for one body: geometry per look, skinning sources, and
/// one looping animation per bone per clip. Spectators only add nodes and players.
@MainActor final class CrowdBodyAssets {
    let body: CrowdBody
    let data: CrowdData
    let geometries: [SCNGeometry]
    private let weights: SCNGeometrySource
    private let boneIndices: SCNGeometrySource
    private let inverseBind: [NSValue]
    /// clip -> (bone, animation): orientation for every bone below Root, plus the hips position.
    let animations: [CrowdClip: [(bone: Int, animation: SCNAnimation)]]

    private static var cache: [CrowdBody: CrowdBodyAssets] = [:]
    private static var failed = false

    /// All four bodies, or nil (logged once) if any asset is missing or damaged.
    static func all(bundle: Bundle = .main) -> [CrowdBodyAssets]? {
        if failed { return nil }
        do {
            return try CrowdBody.allCases.map { (body: CrowdBody) -> CrowdBodyAssets in
                if let cached = cache[body] { return cached }
                guard let url = bundle.url(forResource: body.rawValue, withExtension: "crowd") else { throw FighterAssetError.missing("\(body.rawValue).crowd") }
                let assets = try CrowdBodyAssets(body, CrowdData.parse(Data(contentsOf: url), name: body.rawValue), bundle: bundle)
                cache[body] = assets
                return assets
            }
        } catch {
            failed = true
            crowdLog.error("Crowd assets failed, stands stay empty: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private init(_ body: CrowdBody, _ data: CrowdData, bundle: Bundle) throws {
        self.body = body
        self.data = data
        let count = data.vertexCount, stride = CrowdData.vertexSize
        func source(_ semantic: SCNGeometrySource.Semantic, _ offset: Int, _ components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data.vertices, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                              componentsPerVector: components, bytesPerComponent: 4, dataOffset: offset, dataStride: stride)
        }
        let element = SCNGeometryElement(data: data.indices, primitiveType: .triangles, primitiveCount: data.indexCount / 3, bytesPerIndex: 2)
        let sources = [source(.vertex, 0, 3), source(.normal, 12, 3), source(.texcoord, 24, 2)]
        geometries = try body.looks.map { (look: String) -> SCNGeometry in
            guard let url = bundle.url(forResource: "crowd-\(look)", withExtension: "jpg"), let image = UIImage(contentsOfFile: url.path) else {
                throw FighterAssetError.missing("crowd-\(look).jpg")
            }
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = image
            material.diffuse.mipFilter = .linear
            material.roughness.contents = 0.85
            material.metalness.contents = 0.0
            // A touch of self-light keeps the dim stands readable, as the old crowd did.
            material.emission.contents = image
            material.emission.intensity = 0.08
            let geometry = SCNGeometry(sources: sources, elements: [element])
            geometry.materials = [material]
            return geometry
        }
        // SceneKit requires packed skinning buffers (see FighterRigNodes).
        var packedWeights = [Float](repeating: 0, count: count * 4)
        var packedIndices = [UInt16](repeating: 0, count: count * 4)
        data.vertices.withUnsafeBytes { buffer in
            for v in 0..<count {
                for lane in 0..<4 {
                    packedWeights[v * 4 + lane] = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: v * stride + 32 + lane * 4, as: UInt32.self)))
                    packedIndices[v * 4 + lane] = UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: v * stride + 48 + lane * 2, as: UInt16.self))
                }
            }
        }
        weights = SCNGeometrySource(data: packedWeights.withUnsafeBytes { Data($0) }, semantic: .boneWeights, vectorCount: count,
                                    usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        boneIndices = SCNGeometrySource(data: packedIndices.withUnsafeBytes { Data($0) }, semantic: .boneIndices, vectorCount: count,
                                        usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
        inverseBind = data.bones.map { bone in
            let m = bone.inverseBind
            let c0 = SIMD4<Float>(m[0], m[1], m[2], m[3]), c1 = SIMD4<Float>(m[4], m[5], m[6], m[7])
            let c2 = SIMD4<Float>(m[8], m[9], m[10], m[11]), c3 = SIMD4<Float>(m[12], m[13], m[14], m[15])
            let matrix = simd_float4x4(columns: (c0, c1, c2, c3))
            return NSValue(scnMatrix4: SCNMatrix4(matrix))
        }
        var animations: [CrowdClip: [(bone: Int, animation: SCNAnimation)]] = [:]
        for (id, clip) in data.clips {
            let duration = CFTimeInterval(Float(max(1, clip.frames - 1)) / clip.fps)
            func loop(_ keyPath: String, _ values: [NSValue]) -> SCNAnimation {
                let keyframes = CAKeyframeAnimation(keyPath: keyPath)
                keyframes.values = values
                keyframes.duration = duration
                keyframes.calculationMode = .linear
                keyframes.repeatCount = .infinity
                let animation = SCNAnimation(caAnimation: keyframes)
                animation.repeatCount = .infinity
                animation.isRemovedOnCompletion = false
                return animation
            }
            // Root never moves (the baker folds its motion into the hips).
            var tracks: [(bone: Int, animation: SCNAnimation)] = []
            for bone in 1..<CrowdData.boneCount {
                var values: [NSValue] = []
                for frame in 0..<clip.frames {
                    let q = clip.rotations[frame * CrowdData.boneCount + bone]
                    values.append(NSValue(scnVector4: SCNVector4(q.x, q.y, q.z, q.w)))
                }
                tracks.append((bone, loop("orientation", values)))
            }
            tracks.append((CrowdData.hips, loop("position", clip.hips.map { NSValue(scnVector3: SCNVector3($0)) })))
            animations[id] = tracks
        }
        self.animations = animations
    }

    /// A fresh skeleton and skinned mesh wearing `look`. Returns the root and its bone nodes.
    func instantiate(look: Int) -> (root: SCNNode, bones: [SCNNode]) {
        let root = SCNNode()
        let skeleton = SCNNode()
        root.addChildNode(skeleton)
        var bones: [SCNNode] = []
        for bone in data.bones {
            let node = SCNNode()
            node.simdPosition = bone.translation
            node.simdOrientation = simd_quatf(vector: bone.rotation)
            (bone.parent >= 0 ? bones[bone.parent] : skeleton).addChildNode(node)
            bones.append(node)
        }
        let mesh = SCNNode()
        let geometry = geometries[look % geometries.count].copy() as! SCNGeometry
        mesh.geometry = geometry
        mesh.castsShadow = false
        mesh.skinner = SCNSkinner(baseGeometry: geometry, bones: bones, boneInverseBindTransforms: inverseBind,
                                  boneWeights: weights, boneIndices: boneIndices)
        // Covers a standing cheer with raised arms; skinned bounds don't follow the pose.
        mesh.boundingBox = (SCNVector3(-0.6, -0.1, -0.6), SCNVector3(0.6, 1.4, 0.6))
        root.addChildNode(mesh)
        return (root, bones)
    }
}

/// One spectator: crossfades between looping clips on its own random schedule.
@MainActor final class CrowdMember {
    let root: SCNNode
    private let bones: [SCNNode]
    private let assets: CrowdBodyAssets
    private(set) var clip: CrowdClip = .sit
    private var remaining: Float = 0
    private var cheerSoon = false
    private var generation = 0
    private var rng: UInt64
    private var players: [SCNAnimationPlayer] = []
    var paused = false { didSet { if paused != oldValue { for player in players { player.paused = paused } } } }

    init(assets: CrowdBodyAssets, look: Int, seed: UInt64) {
        self.assets = assets
        rng = seed
        let made = assets.instantiate(look: look)
        root = made.root
        bones = made.bones
        remaining = random() * 6
        play(random() < 0.7 ? .sit : .sitClap, blend: 0)
    }

    /// SplitMix64: spectator randomness never touches the fight RNG.
    private func random() -> Float {
        rng = rng &+ 0x9E37_79B9_7F4A_7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
    }

    /// Advance the schedule by `dt` seconds. `excitement` (0…1) favours clapping, yelling and standing.
    func update(dt: Float, excitement: Float) {
        remaining -= dt
        guard remaining <= 0 else { return }
        let pick: CrowdClip
        if cheerSoon {
            pick = .cheer
            cheerSoon = false
        } else if clip == .cheer {
            pick = random() < 0.7 ? .sit : .sitClap   // sit back down after standing
        } else {
            let roll: Float = random(), calm: Float = 0.45 * (1 - excitement)
            if roll < calm { pick = .sit }
            else if roll < calm + 0.28 { pick = .sitClap }
            else if roll < calm + 0.45 { pick = .sitYell }
            else { pick = .cheer }
        }
        remaining = pick == .cheer ? 2.5 + random() * 3 : 3 + random() * 7
        if pick != clip { play(pick, blend: pick == .cheer || clip == .cheer ? 0.8 : 0.5) }
    }

    /// Most of the stands jump up within a moment of a knockdown or the title win.
    func erupt() {
        guard clip != .cheer, random() < 0.6 else { return }
        cheerSoon = true
        remaining = random() * 0.8
    }

    private func play(_ id: CrowdClip, blend: CGFloat) {
        guard let animations = assets.animations[id] else { return }
        let old = "crowd\(generation)"
        generation += 1
        let key = "crowd\(generation)"
        let phase = TimeInterval(random()) * 20
        let speed: CGFloat = 0.9 + CGFloat(random()) * 0.2
        var fresh: [SCNAnimationPlayer] = []
        for track in animations {
            let node = bones[track.bone]
            let copy = track.animation.copy() as! SCNAnimation
            copy.timeOffset = phase
            copy.blendInDuration = TimeInterval(blend)
            let player = SCNAnimationPlayer(animation: copy)
            player.speed = speed
            player.paused = paused
            node.addAnimationPlayer(player, forKey: key)
            player.play()
            fresh.append(player)
            if generation > 1 { node.removeAnimation(forKey: old, blendOutDuration: blend) }
        }
        players = fresh
        clip = id
    }
}
