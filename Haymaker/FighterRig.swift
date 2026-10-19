import Foundation
import SceneKit
import os

/// Every fighter shares the same 22-bone Mixamo-style skeleton (HMR2).
enum FighterModelAsset: String, CaseIterable, Sendable {
    case mack, bruiser, goldie, nico, atlas, duke, sylvie, cassian, vera, jaison
}

/// Fixed bone order shared by `.fighter` rigs and `fighter.clips`.
/// "Left" is the character's anatomical left (+X); rigs face +Z, Y is up.
enum FighterBone: Int, CaseIterable, Sendable {
    case hips, spine, spine1, spine2, neck, head
    case leftShoulder, leftArm, leftForeArm, leftHand
    case rightShoulder, rightArm, rightForeArm, rightHand
    case leftUpLeg, leftLeg, leftFoot, leftToeBase
    case rightUpLeg, rightLeg, rightFoot, rightToeBase
}

enum FighterSkeleton {
    static let boneCount = 22
    static let names = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
                        "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
                        "RightShoulder", "RightArm", "RightForeArm", "RightHand",
                        "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
                        "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
    static let parents = [-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20]
    /// Bones whose rest direction is corrected during retargeting (see spec).
    static let limbBones: Set<Int> = [6, 7, 8, 10, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21]
    /// Gloves stay rigid relative to the forearm: they reuse its correction.
    static let correctionSource: [Int: Int] = [9: 8, 13: 12]
    /// Thighs, shins, feet and toes (driven by the lower-body clock and foot planting).
    static let lowerBones = [14, 15, 16, 17, 18, 19, 20, 21]
}

enum FighterAssetError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .missing(name): "missing asset \(name)"
        case let .invalid(reason): "invalid asset: \(reason)"
        }
    }
}

let fighterLog = Logger(subsystem: "Haymaker", category: "FighterAnimation")

/// Little-endian readers that never trap on short or misaligned data.
struct BinaryReader {
    let data: Data

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw FighterAssetError.invalid("read past end at \(offset)") }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func f32(_ offset: Int) throws -> Float { Float(bitPattern: try u32(offset)) }

    func vec3(_ offset: Int) throws -> SIMD3<Float> {
        SIMD3(try f32(offset), try f32(offset + 4), try f32(offset + 8))
    }

    func string(_ offset: Int, length: Int) throws -> String {
        guard offset >= 0, offset + length <= data.count else { throw FighterAssetError.invalid("string past end at \(offset)") }
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + length].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Parsed, validated HMR2 rig (pure data, safe to share across actors).
struct FighterRigData: Sendable {
    let name: String
    let heads: [SIMD3<Float>]
    let aims: [SIMD3<Float>]
    let vertexCount: Int
    let indexCount: Int
    /// Interleaved 60-byte vertices: position, normal, rgb, 4 weights, 4 u16 bone indices.
    let vertices: Data
    let indices: Data
    /// Rest-pose skin blob per bone (vertices it dominates), for contact and spacing.
    let blobs: [BoneBlob]

    static func parse(_ raw: Data, name: String) throws -> FighterRigData {
        let data = raw.startIndex == 0 ? raw : Data(raw)
        let reader = BinaryReader(data: data)
        guard data.count >= 16, data.prefix(4) == Data("HMR2".utf8) else {
            throw FighterAssetError.invalid("\(name): expected HMR2 header")
        }
        let vertexCount = Int(try reader.u32(4)), indexCount = Int(try reader.u32(8)), boneCount = Int(try reader.u32(12))
        guard boneCount == FighterSkeleton.boneCount else { throw FighterAssetError.invalid("\(name): \(boneCount) bones") }
        guard vertexCount > 0, indexCount > 0, indexCount % 3 == 0 else { throw FighterAssetError.invalid("\(name): empty mesh") }
        let vertexStart = 16 + boneCount * 28
        let indexStart = vertexStart + vertexCount * 60
        guard data.count == indexStart + indexCount * 4 else { throw FighterAssetError.invalid("\(name): payload size \(data.count)") }
        var heads: [SIMD3<Float>] = [], aims: [SIMD3<Float>] = []
        for bone in 0..<boneCount {
            let offset = 16 + bone * 28
            let parent = Int(Int32(bitPattern: try reader.u32(offset)))
            guard parent == FighterSkeleton.parents[bone] else { throw FighterAssetError.invalid("\(name): bone \(bone) parent \(parent)") }
            let head = try reader.vec3(offset + 4), aim = try reader.vec3(offset + 16)
            guard isFinite(head), isFinite(aim), simd_length(aim - head) > 1e-6 else {
                throw FighterAssetError.invalid("\(name): degenerate bone \(bone)")
            }
            heads.append(head)
            aims.append(aim)
        }
        let vertices = data.subdata(in: vertexStart..<indexStart)
        let indices = data.subdata(in: indexStart..<data.count)
        let badIndex = indices.withUnsafeBytes { buffer -> Bool in
            for i in 0..<indexCount where UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) >= UInt32(vertexCount) { return true }
            return false
        }
        guard !badIndex else { throw FighterAssetError.invalid("\(name): index out of range") }
        let badVertex = vertices.withUnsafeBytes { buffer -> String? in
            func float(_ offset: Int) -> Float { Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            for v in 0..<vertexCount {
                let base = v * 60
                // Position, normal, colour and weights must be finite; weights sum to 1.
                for lane in 0..<13 where !float(base + lane * 4).isFinite { return "vertex \(v) not finite" }
                let weights = (0..<4).map { float(base + 36 + $0 * 4) }
                guard weights.allSatisfy({ $0 >= -1e-4 }), abs(weights.reduce(0, +) - 1) < 0.01 else { return "vertex \(v) weights" }
                for lane in 0..<4 where buffer.loadUnaligned(fromByteOffset: base + 52 + lane * 2, as: UInt16.self).littleEndian >= UInt16(boneCount) {
                    return "vertex \(v) bone index out of range"
                }
            }
            return nil
        }
        if let badVertex { throw FighterAssetError.invalid("\(name): \(badVertex)") }
        let blobs = BoneBlob.measure(vertices: vertices, count: vertexCount, indices: indices, heads: heads, aims: aims)
        return FighterRigData(name: name, heads: heads, aims: aims, vertexCount: vertexCount, indexCount: indexCount,
                              vertices: vertices, indices: indices, blobs: blobs)
    }

    static func load(_ asset: FighterModelAsset, bundle: Bundle = .main) throws -> FighterRigData {
        guard let url = bundle.url(forResource: asset.rawValue, withExtension: "fighter") else {
            throw FighterAssetError.missing("\(asset.rawValue).fighter")
        }
        return try parse(Data(contentsOf: url), name: asset.rawValue)
    }

    /// Skeleton-only fallback (invisible mesh) built from the clip library's
    /// source rest pose, so a broken install degrades instead of crashing.
    static func skeletonOnly(from library: FighterClipLibrary?) -> FighterRigData {
        let scale: Float = 2.7
        let heads = (library?.sourceHeads ?? FighterRigData.unitSkeleton.heads).map { $0 * scale }
        let aims = (library?.sourceAims ?? FighterRigData.unitSkeleton.aims).map { $0 * scale }
        return FighterRigData(name: "fallback", heads: heads, aims: aims, vertexCount: 0, indexCount: 0, vertices: Data(), indices: Data(),
                              blobs: BoneBlob.measure(vertices: Data(), count: 0, heads: heads, aims: aims))
    }

    /// Approximate Mixamo rest skeleton (sculpt units, ~1.0 tall).
    private static let unitSkeleton: (heads: [SIMD3<Float>], aims: [SIMD3<Float>]) = {
        let heads: [SIMD3<Float>] = [
            [0, 0.569, 0], [0, 0.616, -0.009], [0, 0.671, -0.009], [0, 0.733, -0.009], [0, 0.803, -0.009], [0, 0.835, 0.0],
            [0.03, 0.78, -0.01], [0.11, 0.78, -0.02], [0.27, 0.78, -0.02], [0.42, 0.78, -0.02],
            [-0.03, 0.78, -0.01], [-0.11, 0.78, -0.02], [-0.27, 0.78, -0.02], [-0.42, 0.78, -0.02],
            [0.07, 0.53, 0], [0.07, 0.29, 0], [0.07, 0.05, -0.01], [0.07, 0.01, 0.06],
            [-0.07, 0.53, 0], [-0.07, 0.29, 0], [-0.07, 0.05, -0.01], [-0.07, 0.01, 0.06],
        ]
        var aims = heads
        for bone in 0..<heads.count {
            if bone + 1 < heads.count, FighterSkeleton.parents[bone + 1] == bone { aims[bone] = heads[bone + 1] }
        }
        aims[5] = heads[5] + [0, 0.16, 0]
        aims[9] = heads[9] + [0.1, 0, 0]
        aims[13] = heads[13] + [-0.1, 0, 0]
        aims[17] = heads[17] + [0, 0, 0.05]
        aims[21] = heads[21] + [0, 0, 0.05]
        return (heads, aims)
    }()
}

/// Approximate sphere of skin a bone carries (e.g. a glove or the head), in rest pose.
struct BoneBlob: Sendable {
    /// Center relative to the bone head (rest orientation is identity, so posed center = joint + G·offset).
    let offset: SIMD3<Float>
    let radius: Float
    /// Extreme skin points (relative to the bone head) in 14 directions: the
    /// lowest one after posing approximates where this part meets the floor.
    let probes: [SIMD3<Float>]
    /// Extreme skin points in 96 directions: a close hull where a contact must be exact
    /// (a glove stopping on a head at any angle the elbow turns it).
    let hull: [SIMD3<Float>]
    /// The head's skin: its distance from the center over a cube map of directions
    /// (bone frame, `skinGrid`² cells a face). Where a head is no sphere (the jaw, the
    /// ears, the cut down to the neck) a glove stops on the skin itself. Empty elsewhere.
    let skin: [Float]

    static let skinGrid = 12

    /// How far `point` (bone frame, relative to the center) is inside the skin.
    func depth(of point: SIMD3<Float>) -> Float {
        let length = simd_length(point), n = Self.skinGrid
        guard length > 1e-5, skin.count == 6 * n * n else { return radius - length }
        let (face, u, v) = Self.cubeFace(point)
        // Bilinear between the four nearest cell centres on the face.
        func axis(_ t: Float) -> (Int, Int, Float) {
            let s = min(Float(n - 1), max(0, (t + 1) / 2 * Float(n) - 0.5))
            let i = min(n - 2, Int(s))
            return (i, i + 1, s - Float(i))
        }
        let (i0, i1, fu) = axis(u), (j0, j1, fv) = axis(v), base = face * n * n
        let top = skin[base + j0 * n + i0] * (1 - fu) + skin[base + j0 * n + i1] * fu
        let bottom = skin[base + j1 * n + i0] * (1 - fu) + skin[base + j1 * n + i1] * fu
        return top * (1 - fv) + bottom * fv - length
    }

    /// The cube face `direction` points through and where on it (both in −1…1).
    static func cubeFace(_ d: SIMD3<Float>) -> (face: Int, u: Float, v: Float) {
        let a = abs(d)
        if a.x >= a.y, a.x >= a.z { return (d.x > 0 ? 0 : 1, d.y / a.x, d.z / a.x) }
        if a.y >= a.z { return (d.y > 0 ? 2 : 3, d.x / a.y, d.z / a.y) }
        return (d.z > 0 ? 4 : 5, d.x / a.z, d.y / a.z)
    }

    /// The direction through the centre of cube cell `index`.
    static func cubeDirection(_ index: Int) -> SIMD3<Float> {
        let n = skinGrid, face = index / (n * n), j = (index / n) % n, i = index % n
        let u = (Float(i) + 0.5) / Float(n) * 2 - 1, v = (Float(j) + 0.5) / Float(n) * 2 - 1
        let sign: Float = face % 2 == 0 ? 1 : -1
        switch face / 2 {
        case 0: return simd_normalize(SIMD3(sign, u, v))
        case 1: return simd_normalize(SIMD3(u, sign, v))
        default: return simd_normalize(SIMD3(u, v, sign))
        }
    }

    static let hullDirections: [SIMD3<Float>] = (0..<96).map { i in
        let y = 1 - (Float(i) + 0.5) / 48, r = (1 - y * y).squareRoot(), phi = Float(i) * 2.399963
        return SIMD3<Float>(cos(phi) * r, y, sin(phi) * r)
    }

    private static let probeDirections: [SIMD3<Float>] = {
        var directions: [SIMD3<Float>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
        for x: Float in [-1, 1] { for y: Float in [-1, 1] { for z: Float in [-1, 1] { directions.append(simd_normalize(SIMD3(x, y, z))) } } }
        return directions
    }()

    static func measure(vertices: Data, count: Int, indices: Data = Data(), heads: [SIMD3<Float>], aims: [SIMD3<Float>]) -> [BoneBlob] {
        let bones = heads.count
        var sum = [SIMD3<Float>](repeating: .zero, count: bones)
        var square = [Float](repeating: 0, count: bones)
        var total = [Float](repeating: 0, count: bones)
        let directions = probeDirections, around = hullDirections
        var extremes = [[(Float, SIMD3<Float>)]](repeating: directions.map { _ in (-Float.infinity, .zero) }, count: bones)
        var hulls = [[(Float, SIMD3<Float>)]](repeating: around.map { _ in (-Float.infinity, .zero) }, count: bones)
        vertices.withUnsafeBytes { buffer in
            for v in 0..<count {
                var best = 0, weight: Float = 0
                for lane in 0..<4 {
                    let w = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60 + 36 + lane * 4, as: UInt32.self)))
                    if w > weight { weight = w; best = Int(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60 + 52 + lane * 2, as: UInt16.self))) }
                }
                guard weight >= 0.6, best < bones else { continue }
                let p = SIMD3<Float>(Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60, as: UInt32.self))),
                                     Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60 + 4, as: UInt32.self))),
                                     Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60 + 8, as: UInt32.self))))
                sum[best] += p
                square[best] += simd_length_squared(p)
                total[best] += 1
                if weight >= 0.8 {
                    for (k, direction) in directions.enumerated() {
                        let reach = simd_dot(p, direction)
                        if reach > extremes[best][k].0 { extremes[best][k] = (reach, p - heads[best]) }
                    }
                    for (k, direction) in around.enumerated() {
                        let reach = simd_dot(p, direction)
                        if reach > hulls[best][k].0 { hulls[best][k] = (reach, p - heads[best]) }
                    }
                }
            }
        }
        let shapes: [(offset: SIMD3<Float>, radius: Float)] = (0..<bones).map { bone in
            guard total[bone] >= 8 else { return ((aims[bone] - heads[bone]) * 0.5, simd_length(aims[bone] - heads[bone]) * 0.5) }
            let mean = sum[bone] / total[bone]
            // RMS distance from the centroid ≈ radius for a closed surface.
            let variance = max(0, square[bone] / total[bone] - simd_length_squared(mean))
            return (mean - heads[bone], sqrt(variance))
        }
        let skins = (0..<bones).map { bone in
            bone == FighterBone.head.rawValue ? headSkin(vertices: vertices, count: count, indices: indices, bone: bone,
                                                         center: heads[bone] + shapes[bone].offset) : []
        }
        return (0..<bones).map { bone in
            let probes = extremes[bone].filter { $0.0.isFinite }.map(\.1)
            let hull = hulls[bone].filter { $0.0.isFinite }.map(\.1)
            return BoneBlob(offset: shapes[bone].offset, radius: shapes[bone].radius, probes: probes, hull: hull, skin: skins[bone])
        }
    }

    /// The skin of the triangles `bone` dominates (every corner's heaviest weight): its
    /// farthest crossing along the ray through each cube cell's centre from `center`.
    /// Cells it leaves open (the cut down to the neck) are capped flat across the opening.
    private static func headSkin(vertices: Data, count: Int, indices: Data, bone: Int, center: SIMD3<Float>) -> [Float] {
        let n = skinGrid, cells = 6 * n * n
        guard count > 0, indices.count >= 12 else { return [] }
        var dominant = [Int](repeating: -1, count: count)
        var points = [SIMD3<Float>](repeating: .zero, count: count)
        vertices.withUnsafeBytes { buffer in
            func float(_ offset: Int) -> Float { Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            for v in 0..<count {
                var best = 0, weight = -Float.infinity
                for lane in 0..<4 {
                    let w = float(v * 60 + 36 + lane * 4)
                    if w > weight { weight = w; best = Int(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60 + 52 + lane * 2, as: UInt16.self))) }
                }
                dominant[v] = best
                points[v] = SIMD3(float(v * 60), float(v * 60 + 4), float(v * 60 + 8)) - center
            }
        }
        // Bin each triangle into the cells it covers (sampled densely enough to miss none
        // whose centre ray it crosses), then cast only against a cell's own triangles.
        var binned = [[SIMD3<Float>]](repeating: [], count: cells)
        let spacing: Float = 0.004
        indices.withUnsafeBytes { buffer in
            for t in 0..<(indices.count / 12) {
                let corner = (0..<3).map { Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: t * 12 + $0 * 4, as: UInt32.self))) }
                guard corner.allSatisfy({ $0 < count && dominant[$0] == bone }) else { continue }
                let a = points[corner[0]], b = points[corner[1]], c = points[corner[2]]
                let edge = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
                let steps = max(1, Int((edge / spacing).rounded(.up)))
                var covered = Set<Int>()
                for i in 0...steps {
                    for j in 0...(steps - i) {
                        let p = a + (b - a) * (Float(i) / Float(steps)) + (c - a) * (Float(j) / Float(steps))
                        guard simd_length(p) > 1e-5 else { continue }
                        let (face, u, v) = cubeFace(p)
                        let x = min(n - 1, max(0, Int((u + 1) / 2 * Float(n)))), y = min(n - 1, max(0, Int((v + 1) / 2 * Float(n))))
                        covered.insert(face * n * n + y * n + x)
                    }
                }
                for cell in covered { binned[cell].append(contentsOf: [a, b, c]) }
            }
        }
        var skin = [Float](repeating: -.infinity, count: cells)
        for cell in 0..<cells {
            let ray = cubeDirection(cell), triangles = binned[cell]
            for k in stride(from: 0, to: triangles.count, by: 3) {
                let a = triangles[k], e1 = triangles[k + 1] - a, e2 = triangles[k + 2] - a
                let p = simd_cross(ray, e2), det = simd_dot(e1, p)
                guard abs(det) > 1e-12 else { continue }
                let u = simd_dot(-a, p) / det
                guard u >= 0, u <= 1 else { continue }
                let q = simd_cross(-a, e1), v = simd_dot(ray, q) / det
                guard v >= 0, u + v <= 1 else { continue }
                skin[cell] = max(skin[cell], simd_dot(e2, q) / det)
            }
        }
        let open = skin.indices.filter { !skin[$0].isFinite }
        guard open.count < cells else { return [] }
        // Along a direction d a flat cap n·x = h lies at h / (n·d): its reciprocal is
        // linear in d, so relaxing 1/r over the opening to the mean of its neighbours
        // stretches a flat cap across it.
        let directions = (0..<cells).map(cubeDirection)
        var reciprocal = skin.map { $0.isFinite ? 1 / $0 : 0 }
        let mean = reciprocal.reduce(0, +) / Float(cells - open.count)
        for k in open { reciprocal[k] = mean }
        let neighbours = open.map { k in
            directions.indices.filter { $0 != k }
                .sorted { simd_dot(directions[$0], directions[k]) > simd_dot(directions[$1], directions[k]) }.prefix(6)
        }
        for _ in 0..<200 {
            for (e, k) in open.enumerated() { reciprocal[k] = neighbours[e].reduce(0) { $0 + reciprocal[$1] } / Float(neighbours[e].count) }
        }
        // No flesh to press into across the cut: the cap stands proud by a glove's bite.
        for k in open { skin[k] = 1 / max(reciprocal[k], 1e-3) + capMargin }
        return skin
    }

    /// How far the flat cap over a head's neck cut stands proud of the cut.
    static let capMargin: Float = 0.04
}

func isFinite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

/// SceneKit nodes for one rig: 22 bone nodes in a hierarchy (identity rest
/// orientation, offsets head − parentHead) plus the skinned mesh.
@MainActor struct FighterRigNodes {
    let data: FighterRigData
    let bones: [SCNNode]
    let skeleton: SCNNode
    let mesh: SCNNode

    init(_ data: FighterRigData) {
        self.data = data
        let skeleton = SCNNode()
        skeleton.name = "skeleton"
        var bones: [SCNNode] = [], inverseBind: [NSValue] = []
        for bone in 0..<FighterSkeleton.boneCount {
            let parent = FighterSkeleton.parents[bone]
            let node = SCNNode()
            node.name = FighterSkeleton.names[bone]
            node.simdPosition = data.heads[bone] - (parent >= 0 ? data.heads[parent] : .zero)
            (parent >= 0 ? bones[parent] : skeleton).addChildNode(node)
            bones.append(node)
            var inverse = matrix_identity_float4x4
            inverse.columns.3 = SIMD4<Float>(-data.heads[bone], 1)
            inverseBind.append(NSValue(scnMatrix4: SCNMatrix4(inverse)))
        }
        let mesh = SCNNode()
        mesh.name = "skinnedMesh"
        if data.vertexCount > 0 {
            let vertexCount = data.vertexCount
            func source(_ semantic: SCNGeometrySource.Semantic, _ offset: Int) -> SCNGeometrySource {
                SCNGeometrySource(data: data.vertices, semantic: semantic, vectorCount: vertexCount, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: offset, dataStride: 60)
            }
            let element = SCNGeometryElement(data: data.indices, primitiveType: .triangles, primitiveCount: data.indexCount / 3, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: [source(.vertex, 0), source(.normal, 12), source(.color, 24)], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor.white
            material.roughness.contents = 0.65
            geometry.materials = [material]
            mesh.geometry = geometry
            // SceneKit requires packed skinning buffers; interleaved sources
            // can silently yield a nil skinner even when geometry renders.
            var weights = [Float](repeating: 0, count: vertexCount * 4)
            var indices = [UInt16](repeating: 0, count: vertexCount * 4)
            data.vertices.withUnsafeBytes { buffer in
                for v in 0..<vertexCount {
                    for lane in 0..<4 {
                        weights[v * 4 + lane] = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60 + 36 + lane * 4, as: UInt32.self)))
                        indices[v * 4 + lane] = UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: v * 60 + 52 + lane * 2, as: UInt16.self))
                    }
                }
            }
            let weightSource = SCNGeometrySource(data: weights.withUnsafeBytes { Data($0) }, semantic: .boneWeights, vectorCount: vertexCount,
                                                 usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let indexSource = SCNGeometrySource(data: indices.withUnsafeBytes { Data($0) }, semantic: .boneIndices, vectorCount: vertexCount,
                                                usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
            mesh.skinner = SCNSkinner(baseGeometry: geometry, bones: bones, boneInverseBindTransforms: inverseBind,
                                      boneWeights: weightSource, boneIndices: indexSource)
            if mesh.skinner == nil { fighterLog.error("SceneKit rejected skinning sources for \(data.name, privacy: .public)") }
            // Generous bounds: knockdowns travel ~1.4 units and lie flat.
            mesh.boundingBox = (SCNVector3(-3.6, -0.4, -4.2), SCNVector3(3.6, 3.4, 3.6))
        }
        self.bones = bones
        self.skeleton = skeleton
        self.mesh = mesh
    }

    /// Load `asset`, falling back to Mack and finally to an invisible
    /// skeleton rather than crashing on a damaged bundle.
    private static var reportedFailures: Set<FighterModelAsset> = []

    static func load(_ asset: FighterModelAsset, bundle: Bundle = .main) -> FighterRigNodes {
        do {
            return FighterRigNodes(try FighterRigData.load(asset, bundle: bundle))
        } catch {
            if reportedFailures.insert(asset).inserted {
                fighterLog.error("Fighter rig \(asset.rawValue, privacy: .public) failed, using a fallback: \(String(describing: error), privacy: .public)")
            }
        }
        if asset != .mack, let mack = try? FighterRigData.load(.mack, bundle: bundle) {
            return FighterRigNodes(mack)
        }
        return FighterRigNodes(.skeletonOnly(from: FighterClipLibrary.shared))
    }
}
