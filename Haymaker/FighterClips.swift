import Foundation
import simd

/// Clip names in `fighter.clips` (HMC1). See ArtDirection/Animations.
enum ClipID: String, CaseIterable, Sendable {
    case idle, jab, hook, uppercut, block, bodyBlock, slip, hitHead, hitBody, hitSide
    case knockdown, getUp, victory, warmup
}

/// One source clip: per frame the posed Hips head (source units) and, per
/// bone, the global rest-relative delta Δ = G_anim · G_rest⁻¹.
struct FighterClip: Sendable {
    let name: String
    let fps: Float
    let frameCount: Int
    let loops: Bool
    let markers: [String: Float]
    let hips: [SIMD3<Float>]
    /// frameCount × 22 quaternions (x, y, z, w).
    let deltas: [SIMD4<Float>]
}

/// The shared HMC1 clip library, parsed once from the app bundle.
struct FighterClipLibrary: Sendable {
    let sourceHeads: [SIMD3<Float>]
    let sourceAims: [SIMD3<Float>]
    let clips: [String: FighterClip]

    static let shared: FighterClipLibrary? = {
        guard let url = Bundle.main.url(forResource: "fighter", withExtension: "clips") else {
            fighterLog.error("fighter.clips is missing; fighters will hold their bind pose")
            return nil
        }
        do {
            return try parse(Data(contentsOf: url))
        } catch {
            fighterLog.error("fighter.clips failed to load: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    static func parse(_ raw: Data) throws -> FighterClipLibrary {
        let data = raw.startIndex == 0 ? raw : Data(raw)
        let reader = BinaryReader(data: data)
        guard data.count >= 16, data.prefix(4) == Data("HMC1".utf8) else { throw FighterAssetError.invalid("expected HMC1 header") }
        let boneCount = Int(try reader.u32(4)), clipCount = Int(try reader.u32(8))
        guard boneCount == FighterSkeleton.boneCount else { throw FighterAssetError.invalid("clip library has \(boneCount) bones") }
        guard clipCount > 0, clipCount < 1024 else { throw FighterAssetError.invalid("clip count \(clipCount)") }
        var offset = 16
        var heads: [SIMD3<Float>] = [], aims: [SIMD3<Float>] = []
        for _ in 0..<boneCount {
            heads.append(try reader.vec3(offset))
            aims.append(try reader.vec3(offset + 12))
            offset += 24
        }
        var clips: [String: FighterClip] = [:]
        for _ in 0..<clipCount {
            let name = try reader.string(offset, length: 24)
            let fps = try reader.f32(offset + 24)
            let frameCount = Int(try reader.u32(offset + 28))
            let flags = try reader.u32(offset + 32)
            let markerCount = Int(try reader.u32(offset + 36))
            offset += 40
            guard fps.isFinite, fps > 0, frameCount > 0, frameCount < 100_000, markerCount < 64 else {
                throw FighterAssetError.invalid("clip \(name) header")
            }
            var markers: [String: Float] = [:]
            for _ in 0..<markerCount {
                let marker = try reader.string(offset, length: 16)
                let frame = try reader.f32(offset + 16)
                guard frame.isFinite else { throw FighterAssetError.invalid("clip \(name) marker \(marker)") }
                markers[marker] = min(max(0, frame), Float(frameCount - 1))
                offset += 20
            }
            let stride = (3 + boneCount * 4) * 4
            guard offset + frameCount * stride <= data.count else { throw FighterAssetError.invalid("clip \(name) truncated") }
            var hips: [SIMD3<Float>] = [], deltas: [SIMD4<Float>] = []
            hips.reserveCapacity(frameCount)
            deltas.reserveCapacity(frameCount * boneCount)
            for _ in 0..<frameCount {
                let position = try reader.vec3(offset)
                guard isFinite(position) else { throw FighterAssetError.invalid("clip \(name) hips") }
                hips.append(position)
                for bone in 0..<boneCount {
                    let base = offset + 12 + bone * 16
                    var q = SIMD4<Float>(try reader.f32(base), try reader.f32(base + 4), try reader.f32(base + 8), try reader.f32(base + 12))
                    let length = simd_length(q)
                    guard length.isFinite, length > 0.5 else { throw FighterAssetError.invalid("clip \(name) quaternion") }
                    q /= length
                    deltas.append(q)
                }
                offset += stride
            }
            clips[name] = FighterClip(name: name, fps: fps, frameCount: frameCount, loops: flags & 1 != 0, markers: markers, hips: hips, deltas: deltas)
        }
        guard offset == data.count else { throw FighterAssetError.invalid("trailing bytes in clip library") }
        return FighterClipLibrary(sourceHeads: heads, sourceAims: aims, clips: clips)
    }
}

/// A clip retargeted onto one rig: SceneKit-ready local rotations and Hips
/// positions (rig units), precomputed once per rig so a frame costs a lerp.
struct RetargetedClip: Sendable {
    let id: ClipID
    let fps: Float
    let frameCount: Int
    let loops: Bool
    /// Loop period in frames (frameCount, or frameCount − 1 when the last frame duplicates the first).
    let period: Float
    let markers: [String: Float]
    let local: [simd_quatf]
    let hips: [SIMD3<Float>]

    var lastFrame: Float { Float(frameCount - 1) }

    func marker(_ name: String, _ fallback: Float) -> Float { markers[name] ?? fallback }

    /// Normalised frame (wrapping loops, clamping one-shots).
    func wrap(_ frame: Float) -> Float {
        guard frame.isFinite else { return 0 }
        if loops, period > 0 {
            let wrapped = frame.truncatingRemainder(dividingBy: period)
            return wrapped < 0 ? wrapped + period : wrapped
        }
        return min(max(0, frame), lastFrame)
    }

    func sample(_ frame: Float, into pose: inout FighterPose) {
        let f = wrap(frame)
        let i0 = min(Int(f), frameCount - 1)
        let i1 = loops ? (i0 + 1) % frameCount : min(i0 + 1, frameCount - 1)
        let t = f - Float(i0)
        let b0 = i0 * FighterSkeleton.boneCount, b1 = i1 * FighterSkeleton.boneCount
        for bone in 0..<FighterSkeleton.boneCount {
            pose.rotations[bone] = nlerp(local[b0 + bone], local[b1 + bone], t)
        }
        pose.hips = hips[i0] + (hips[i1] - hips[i0]) * t
    }

    func rotation(_ bone: Int, at frame: Float) -> simd_quatf {
        let f = wrap(frame)
        let i0 = min(Int(f), frameCount - 1)
        let i1 = loops ? (i0 + 1) % frameCount : min(i0 + 1, frameCount - 1)
        return nlerp(local[i0 * FighterSkeleton.boneCount + bone], local[i1 * FighterSkeleton.boneCount + bone], f - Float(i0))
    }

    func hipsPosition(at frame: Float) -> SIMD3<Float> {
        let f = wrap(frame)
        let i0 = min(Int(f), frameCount - 1)
        let i1 = loops ? (i0 + 1) % frameCount : min(i0 + 1, frameCount - 1)
        return hips[i0] + (hips[i1] - hips[i0]) * (f - Float(i0))
    }
}

/// All clips retargeted onto a single rig.
struct FighterMotionSet: Sendable {
    let rigName: String
    let heads: [SIMD3<Float>]
    let clips: [ClipID: RetargetedClip]

    subscript(_ id: ClipID) -> RetargetedClip? { clips[id] }

    init(rig: FighterRigData, library: FighterClipLibrary?) {
        rigName = rig.name
        heads = rig.heads
        guard let library else { clips = [:]; return }
        let count = FighterSkeleton.boneCount
        // C(b): shortest arc from the rig's bone direction to Mixamo's.
        var correction = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: count)
        for bone in FighterSkeleton.limbBones {
            let target = simd_normalize(rig.aims[bone] - rig.heads[bone])
            let source = simd_normalize(library.sourceAims[bone] - library.sourceHeads[bone])
            correction[bone] = shortestArc(from: target, to: source)
        }
        for (bone, from) in FighterSkeleton.correctionSource { correction[bone] = correction[from] }
        let sourceHips = library.sourceHeads[0]
        let scale = sourceHips.y > 1e-5 ? rig.heads[0].y / sourceHips.y : 1
        var result: [ClipID: RetargetedClip] = [:]
        for id in ClipID.allCases {
            guard let clip = library.clips[id.rawValue] else { continue }
            var local = [simd_quatf](), hips = [SIMD3<Float>]()
            local.reserveCapacity(clip.frameCount * count)
            var global = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: count)
            for frame in 0..<clip.frameCount {
                for bone in 0..<count {
                    let delta = clip.deltas[frame * count + bone]
                    global[bone] = simd_quatf(vector: delta) * correction[bone]
                }
                for bone in 0..<count {
                    let parent = FighterSkeleton.parents[bone]
                    var q = simd_normalize(parent >= 0 ? global[parent].inverse * global[bone] : global[bone])
                    if frame > 0, simd_dot(q.vector, local[(frame - 1) * count + bone].vector) < 0 { q = simd_quatf(vector: -q.vector) }
                    local.append(q)
                }
                hips.append(rig.heads[0] + (clip.hips[frame] - sourceHips) * scale)
            }
            var period = Float(clip.frameCount)
            if clip.loops, clip.frameCount > 2 {
                let last = (clip.frameCount - 1) * count
                let duplicate = (0..<count).allSatisfy { abs(simd_dot(local[$0].vector, local[last + $0].vector)) > 0.99995 }
                    && simd_distance(hips[0], hips[clip.frameCount - 1]) < 0.002
                if duplicate { period = Float(clip.frameCount - 1) }
            }
            let maxFrame = Float(clip.frameCount - 1)
            result[id] = RetargetedClip(id: id, fps: clip.fps, frameCount: clip.frameCount, loops: clip.loops, period: period,
                                        markers: clip.markers.mapValues { min($0, maxFrame) }, local: local, hips: hips)
        }
        clips = result
    }

    @MainActor private static var cache: [String: FighterMotionSet] = [:]

    /// Retargeting is shared by every BoxerModel using the same rig.
    @MainActor static func shared(for rig: FighterRigData) -> FighterMotionSet {
        if let cached = cache[rig.name], cached.heads == rig.heads { return cached }
        let motions = FighterMotionSet(rig: rig, library: FighterClipLibrary.shared)
        cache[rig.name] = motions
        return motions
    }
}

/// Local bone rotations plus the Hips node position (rig units).
struct FighterPose: Sendable {
    var hips: SIMD3<Float>
    var rotations: [simd_quatf]

    init(hips: SIMD3<Float>) {
        self.hips = hips
        rotations = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: FighterSkeleton.boneCount)
    }

    /// Global rotations G(b) (rig space).
    func globals() -> [simd_quatf] {
        var result = rotations
        for bone in 1..<FighterSkeleton.boneCount { result[bone] = result[FighterSkeleton.parents[bone]] * rotations[bone] }
        return result
    }

    /// Posed joint positions (rig space) for QA, spacing and effects.
    func joints(heads: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let global = globals()
        var result = heads
        result[0] = hips
        for bone in 1..<FighterSkeleton.boneCount {
            let parent = FighterSkeleton.parents[bone]
            result[bone] = result[parent] + global[parent].act(heads[bone] - heads[parent])
        }
        return result
    }

    static func blend(_ a: FighterPose, _ b: FighterPose, _ t: Float) -> FighterPose {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var out = a
        out.hips = a.hips + (b.hips - a.hips) * t
        for bone in 0..<FighterSkeleton.boneCount { out.rotations[bone] = slerpShortest(a.rotations[bone], b.rotations[bone], t) }
        return out
    }
}

func shortestArc(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
    let d = simd_dot(a, b)
    if d > 0.999999 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
    if d < -0.999999 {
        var axis = simd_cross(SIMD3<Float>(1, 0, 0), a)
        if simd_length(axis) < 1e-4 { axis = simd_cross(SIMD3<Float>(0, 1, 0), a) }
        return simd_quatf(angle: .pi, axis: simd_normalize(axis))
    }
    return simd_quatf(from: a, to: b)
}

func nlerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
    if t <= 0 { return a }
    if t >= 1 { return simd_dot(a.vector, b.vector) < 0 ? simd_quatf(vector: -b.vector) : b }
    let bv = simd_dot(a.vector, b.vector) < 0 ? -b.vector : b.vector
    return simd_quatf(vector: simd_normalize(a.vector + (bv - a.vector) * t))
}

func slerpShortest(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
    let bq = simd_dot(a.vector, b.vector) < 0 ? simd_quatf(vector: -b.vector) : b
    return simd_normalize(simd_slerp(a, bq, t))
}

/// q raised to a power along its shortest arc (q^t), for additive layers.
func scaled(_ q: simd_quatf, _ t: Float) -> simd_quatf {
    let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    return slerpShortest(identity, q, t)
}
