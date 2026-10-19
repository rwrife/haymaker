// Offscreen QA for the fighter animation stack (macOS + full Xcode).
// Loads every HMR2 rig and fighter.clips through the app's own loaders, drives
// the real director / animator / choreographer from a scripted FightEngine bout,
// checks continuity, contact, floor and deformation numerically, and renders
// contact sheets for review. Run through scripts/verify_fighter_rigs.sh.
import AppKit
import SceneKit
@testable import HaymakerKit

typealias UIColor = NSColor

// MARK: - Report

@MainActor final class Report {
    private(set) var failures: [String] = []
    private(set) var lines: [String] = []

    func check(_ ok: Bool, _ message: @autoclosure () -> String) {
        guard !ok else { return }
        let text = message()
        failures.append(text)
        log("FAIL: \(text)")
    }

    func log(_ text: String) {
        print(text)
        lines.append(text)
    }
}

func f3(_ x: Float) -> String { String(format: "%.3f", x) }
func f2(_ x: Float) -> String { String(format: "%.2f", x) }

// MARK: - CPU skinning (exact mesh positions for contact, floor and deformation)

struct Skin {
    let rest: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let weights: [SIMD4<Float>]
    let bones: [SIMD4<Int32>]
    let dominant: [Int]
    let heads: [SIMD3<Float>]
    let floor: Float
    let height: Float
    /// Triangle edges per region: rigid regions keep edges whose vertices are fully
    /// bound to one bone of the region (must never stretch); flex regions keep edges
    /// dominated by the region's bones (skinning stretch, reported as a percentile).
    let edges: [String: [(Int, Int, Float)]]
    /// Shell triangles (all three vertices dominated by the bone) of the head and gloves.
    let shells: [Int: [SIMD3<Int>]]
    var headTriangles: [SIMD3<Int>] { shells[5] ?? [] }

    static let rigidRegions: [String: Set<Int>] = ["gloves": [9, 13], "boots": [16, 17, 20, 21], "head": [5]]
    static let flexRegions: [String: Set<Int>] = ["legs": [14, 15, 18, 19], "arms": [6, 7, 8, 10, 11, 12], "neck": [4, 5]]

    init(_ rig: FighterRigData) {
        var rest = [SIMD3<Float>](), normals = [SIMD3<Float>](), weights = [SIMD4<Float>](), bones = [SIMD4<Int32>](), dominant = [Int]()
        rig.vertices.withUnsafeBytes { b in
            func f(_ o: Int) -> Float { Float(bitPattern: UInt32(littleEndian: b.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            func u(_ o: Int) -> Int32 { Int32(UInt16(littleEndian: b.loadUnaligned(fromByteOffset: o, as: UInt16.self))) }
            for v in 0..<rig.vertexCount {
                let o = v * 60
                rest.append(SIMD3(f(o), f(o + 4), f(o + 8)))
                normals.append(SIMD3(f(o + 12), f(o + 16), f(o + 20)))
                var w = SIMD4(f(o + 36), f(o + 40), f(o + 44), f(o + 48))
                let sum = w.sum()
                if sum > 0 { w /= sum }
                let i = SIMD4(u(o + 52), u(o + 54), u(o + 56), u(o + 58))
                var best = 0
                for lane in 1..<4 where w[lane] > w[best] { best = lane }
                weights.append(w)
                bones.append(i)
                dominant.append(Int(i[best]))
            }
        }
        var triangles = [SIMD3<Int>]()
        rig.indices.withUnsafeBytes { b in
            for t in 0..<(rig.indexCount / 3) {
                func i(_ k: Int) -> Int { Int(UInt32(littleEndian: b.loadUnaligned(fromByteOffset: (t * 3 + k) * 4, as: UInt32.self))) }
                triangles.append(SIMD3(i(0), i(1), i(2)))
            }
        }
        var edges: [String: [(Int, Int, Float)]] = [:]
        var bound = [Int](repeating: -1, count: rest.count)
        for v in rest.indices {
            for lane in 0..<4 where weights[v][lane] >= 0.99 { bound[v] = Int(bones[v][lane]) }
        }
        for (name, set) in Self.rigidRegions {
            var list: [(Int, Int, Float)] = []
            for t in triangles where set.contains(bound[t.x]) && bound[t.x] == bound[t.y] && bound[t.y] == bound[t.z] {
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    let length = simd_distance(rest[a], rest[b])
                    if length > 1e-4 { list.append((a, b, length)) }
                }
            }
            edges[name] = list
        }
        for (name, set) in Self.flexRegions {
            var list: [(Int, Int, Float)] = []
            for t in triangles where set.contains(dominant[t.x]) && set.contains(dominant[t.y]) && set.contains(dominant[t.z]) {
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    let length = simd_distance(rest[a], rest[b])
                    if length > 0.015 { list.append((a, b, length)) }
                }
            }
            edges[name] = list
        }
        self.rest = rest
        self.normals = normals
        self.weights = weights
        self.bones = bones
        self.dominant = dominant
        self.heads = rig.heads
        self.edges = edges
        var shells: [Int: [SIMD3<Int>]] = [:]
        for bone in [5, 9, 13] {
            shells[bone] = triangles.filter { dominant[$0.x] == bone && dominant[$0.y] == bone && dominant[$0.z] == bone }
        }
        self.shells = shells
        floor = rest.map(\.y).min() ?? 0
        height = (rest.map(\.y).max() ?? 0) - floor
    }

    func vertices(_ set: Set<Int>) -> [Int] { dominant.indices.filter { set.contains(dominant[$0]) } }

    func posed(_ pose: FighterPose, subset: [Int]? = nil) -> [SIMD3<Float>] {
        let globals = pose.globals(), joints = pose.joints(heads: heads)
        let rotations = globals.map { simd_float3x3($0) }
        let offsets = (0..<FighterSkeleton.boneCount).map { joints[$0] - rotations[$0] * heads[$0] }
        func skin(_ v: Int) -> SIMD3<Float> {
            var p = SIMD3<Float>.zero
            let w = weights[v], i = bones[v], r = rest[v]
            for lane in 0..<4 where w[lane] > 0 {
                let b = Int(i[lane])
                p += w[lane] * (rotations[b] * r + offsets[b])
            }
            return p
        }
        if let subset { return subset.map(skin) }
        return rest.indices.map(skin)
    }
}

func transformed(_ m: simd_float4x4, _ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    points.map { let p = m * SIMD4<Float>($0, 1); return SIMD3(p.x, p.y, p.z) }
}

/// Generalized winding number of `p` w.r.t. a triangle soup (≈1 inside a closed
/// shell, ≈0 outside, fractional near holes such as the neck cut).
func winding(_ p: SIMD3<Float>, _ triangles: [SIMD3<Int>], _ positions: [SIMD3<Float>]) -> Float {
    var total: Float = 0
    for t in triangles {
        let a = positions[t.x] - p, b = positions[t.y] - p, c = positions[t.z] - p
        let la = simd_length(a), lb = simd_length(b), lc = simd_length(c)
        let numerator = simd_dot(a, simd_cross(b, c))
        let denominator = la * lb * lc + simd_dot(a, b) * lc + simd_dot(a, c) * lb + simd_dot(b, c) * la
        total += 2 * atan2(numerator, denominator)
    }
    return total / (4 * .pi)
}

func minDistance(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
    var best = Float.infinity
    for p in a { for q in b { best = min(best, simd_distance_squared(p, q)) } }
    return best.squareRoot()
}

func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> { points.reduce(.zero, +) / Float(max(1, points.count)) }

// MARK: - Offscreen studio

@MainActor final class Studio {
    let scene = SCNScene()
    let camera = SCNNode()
    let renderer: SCNRenderer
    private var time: TimeInterval = 0

    init() {
        scene.background.contents = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
        let floor = SCNFloor()
        floor.reflectivity = 0
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.36, green: 0.37, blue: 0.42, alpha: 1)
        floor.materials = [material]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))
        // Half-unit marks on the canvas make spacing and root travel readable.
        for i in -8...8 {
            for (size, position) in [(SCNVector3(0.012, 0.002, 8), SCNVector3(CGFloat(i) * 0.5, 0.001, 0)),
                                     (SCNVector3(8, 0.002, 0.012), SCNVector3(0, 0.001, CGFloat(i) * 0.5))] {
                let mark = SCNNode(geometry: SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: 0))
                mark.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.5, alpha: 1)
                mark.position = position
                scene.rootNode.addChildNode(mark)
            }
        }
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 420
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.light!.castsShadow = true
        key.light!.shadowRadius = 2
        key.simdEulerAngles = SIMD3<Float>(-0.95, 0.45, 0)
        scene.rootNode.addChildNode(key)
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 350
        rim.simdEulerAngles = SIMD3<Float>(-0.4, .pi + 0.6, 0)
        scene.rootNode.addChildNode(rim)
        camera.camera = SCNCamera()
        camera.camera!.zNear = 0.05
        camera.camera!.zFar = 120
        scene.rootNode.addChildNode(camera)
        renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
    }

    func shot(_ size: CGSize, eye: SIMD3<Float>, target: SIMD3<Float>, fov: CGFloat = 40, ortho: Double? = nil,
              up: SIMD3<Float>? = nil) -> NSImage {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.simdPosition = eye
        camera.simdLook(at: target, up: up ?? SIMD3(0, 1, 0), localFront: SCNNode.simdLocalFront)
        camera.camera!.fieldOfView = fov
        camera.camera!.usesOrthographicProjection = ortho != nil
        if let ortho { camera.camera!.orthographicScale = ortho }
        SCNTransaction.commit()
        SCNTransaction.flush()
        if time == 0 { _ = renderer.snapshot(atTime: 0, with: CGSize(width: 16, height: 16), antialiasingMode: .none) }
        time += 1.0 / 60
        return renderer.snapshot(atTime: time, with: size, antialiasingMode: .multisampling4X)
    }
}

func writeSheet(_ cells: [(NSImage, String)], columns: Int, cell: CGSize, title: String, to url: URL) throws {
    guard !cells.isEmpty else { return }
    let rows = (cells.count + columns - 1) / columns
    let header: CGFloat = 34, caption: CGFloat = 22
    let width = Int(CGFloat(min(columns, cells.count)) * cell.width)
    let height = Int(header + CGFloat(rows) * (cell.height + caption))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let titleStyle: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.white]
    let captionStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1)]
    (title as NSString).draw(at: NSPoint(x: 10, y: CGFloat(height) - header + 8), withAttributes: titleStyle)
    for (i, item) in cells.enumerated() {
        let x = CGFloat(i % columns) * cell.width
        let top = CGFloat(height) - header - CGFloat(i / columns) * (cell.height + caption)
        item.0.draw(in: NSRect(x: x, y: top - cell.height, width: cell.width, height: cell.height))
        (item.1 as NSString).draw(at: NSPoint(x: x + 6, y: top - cell.height - caption + 4), withAttributes: captionStyle)
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])?.write(to: url)
}

// MARK: - Library and rigs

@MainActor func checkLibrary(_ report: Report) -> FighterClipLibrary? {
    guard let library = FighterClipLibrary.shared else {
        report.check(false, "fighter.clips did not load")
        return nil
    }
    let ordered: [ClipID: [String]] = [
        .jab: ["chamber", "contact", "recovered"], .hook: ["chamber", "contact", "recovered"],
        .uppercut: ["chamber", "contact", "recovered"], .block: ["guardUp", "holdEnd"], .bodyBlock: ["guardUp", "holdEnd"],
        .slip: ["slipped", "holdEnd"], .hitHead: ["impact", "recovered"], .hitBody: ["impact", "recovered"],
        .hitSide: ["impact", "recovered"], .knockdown: ["react", "ground", "settled"], .getUp: ["rise", "standing"],
        .victory: ["armsUp", "armsDown"],
    ]
    for id in ClipID.allCases {
        guard let clip = library.clips[id.rawValue] else {
            report.check(false, "clip \(id.rawValue) missing from fighter.clips")
            continue
        }
        report.check(clip.loops == (id == .idle || id == .warmup), "\(id.rawValue) loop flag")
        let marks = (ordered[id] ?? []).map { clip.markers[$0] }
        report.check(!marks.contains { $0 == nil }, "\(id.rawValue) markers \(ordered[id] ?? []) present")
        let values = marks.compactMap { $0 }
        report.check(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "\(id.rawValue) markers ordered \(values)")
        let summary = clip.markers.sorted { $0.value < $1.value }.map { "\($0.key) \(Int($0.value))" }.joined(separator: ", ")
        report.log("clip \(id.rawValue): \(clip.frameCount) frames @ \(Int(clip.fps)) fps\(clip.loops ? " loop" : "") [\(summary)]")
    }
    return library
}

struct ClipStats {
    var footSink: Float = 0
    var footSinkAt = ""
    var bodySink: Float = 0
    var hipsLow: Float = .infinity
    var deviation: [String: (Float, String)] = [:]
}

/// Every clip on one rig: finite, normalized, feet above the floor, rigid gloves/head, bounded leg stretch.
@MainActor func checkClips(_ asset: FighterModelAsset, rig: FighterRigData, report: Report) -> ClipStats {
    let motions = FighterMotionSet.shared(for: rig)
    let skin = Skin(rig)
    let feet = skin.vertices([16, 17, 20, 21])
    var stats = ClipStats()
    for id in ClipID.allCases {
        guard let clip = motions[id] else {
            report.check(false, "\(asset.rawValue): \(id.rawValue) not retargeted")
            continue
        }
        var bad = false
        var frame: Float = 0
        while frame <= clip.lastFrame {
            var pose = FighterPose(hips: rig.heads[0])
            clip.sample(frame, into: &pose)
            if !isFinite(pose.hips) || pose.rotations.contains(where: { !$0.vector.x.isFinite || abs(simd_length($0.vector) - 1) > 1e-3 }) {
                bad = true
            }
            let posed = skin.posed(pose)
            let label = "\(id.rawValue)@\(Int(frame))"
            if id != .knockdown && id != .getUp {
                let sink = skin.floor - feet.map { posed[$0].y }.min()!
                if sink > stats.footSink { stats.footSink = sink; stats.footSinkAt = label }
                stats.hipsLow = min(stats.hipsLow, pose.hips.y / rig.heads[0].y)
            } else {
                stats.bodySink = max(stats.bodySink, skin.floor - (posed.map(\.y).min() ?? 0))
            }
            for (region, edges) in skin.edges where !edges.isEmpty {
                var deviations = edges.map { abs(simd_distance(posed[$0.0], posed[$0.1]) / $0.2 - 1) }
                let value: Float
                if Skin.rigidRegions[region] != nil {
                    value = deviations.max() ?? 0
                } else {
                    deviations.sort()
                    value = deviations[min(deviations.count - 1, Int(Float(deviations.count) * 0.99))]
                }
                if value > (stats.deviation[region]?.0 ?? 0) { stats.deviation[region] = (value, label) }
            }
            for bone in [7, 8, 11, 12, 14, 15, 18, 19] {
                let axis = simd_normalize(rig.aims[bone] - rig.heads[bone])
                let q = pose.rotations[bone]
                let twist = abs(2 * atan2(simd_dot(q.imag, axis), q.real))
                let angle = min(twist, 2 * .pi - twist) * 180 / .pi
                let key = bone >= 14 ? "leg twist°" : "arm twist°"
                if angle > (stats.deviation[key]?.0 ?? 0) { stats.deviation[key] = (angle, "\(label) \(FighterSkeleton.names[bone])") }
            }
            frame += 1
        }
        report.check(!bad, "\(asset.rawValue): \(id.rawValue) produced a non-finite or unnormalized pose")
    }
    return stats
}

// MARK: - Scripted bout

struct Snapshot {
    var image: NSImage
    var label: String
}

@MainActor final class Bout {
    enum Intent: CustomStringConvertible {
        case takeHit(Move?), punch(Move), block, dodge, parry, punchGuard, knockdownRival, heroKnockdown, finishRival, loseByKO
        /// The hero chains these punches, each on the first idle frame after the last.
        case combo([Move])

        var description: String {
            switch self {
            case let .takeHit(move): "takeHit(\(move?.rawValue ?? "any"))"
            case let .punch(move): "punch(\(move.rawValue))"
            case .block: "block"
            case .dodge: "dodge"
            case .parry: "parry"
            case .punchGuard: "punchGuard"
            case .knockdownRival: "knockdownRival"
            case .heroKnockdown: "heroKnockdown"
            case .finishRival: "finishRival"
            case .loseByKO: "loseByKO"
            case let .combo(moves): "combo(\(moves.map(\.rawValue).joined(separator: "→")))"
            }
        }
    }

    struct Sample {
        var joints: [[SIMD3<Float>]]
        var states: [String]
        /// Per fighter: root transform and final pose (re-rendered after the bout from any camera).
        var roots: [simd_float4x4]
        var poses: [FighterPose]
        /// Per fighter: the director wants the feet planted (false while down / getting up).
        var planted: [Bool]
        var aims: [Float]
        /// Per fighter: the director's clip and frame (lower-body clock when it lags).
        var clips: [ClipID?]
        var clipFrames: [Float]
        /// Per fighter: director internals for HAYMAKER_EXDEBUG (arm frame, lunge, reach, aim).
        var notes: [String]
        /// Per fighter: the most stretched planted leg (hip-to-toe target / leg length).
        var stretch: [Float]
        /// Per fighter: the most stretched stepping (airborne) leg.
        var swing: [Float]
        /// Per fighter, per foot (left, right): mid release step (feet let go for a fall / get-up).
        var releases: [[Bool]]
    }

    /// A punch arriving (landed / blocked / dodged / parried) at sample `index`.
    struct Hit {
        let label: String
        let attacker: Int
        let move: Move
        let hand: FighterBone
        let index: Int
        let kind: String
    }

    /// The struck fighter starts a punch of its own within 3 frames of `hit`'s contact.
    func trades(_ hit: Hit) -> Bool {
        let defender = 1 - hit.attacker
        return (hit.index + 1...hit.index + 3).contains { i in
            samples.indices.contains(i) && samples[i].states[defender].hasPrefix("attacking")
                && !samples[i - 1].states[defender].hasPrefix("attacking")
        }
    }

    enum View { case side, top, front, zoomTop, zoomFront, zoomEnd }

    struct Contact {
        let label: String
        let gap: Float
        let depth: Float
        /// How deep the glove skin sits inside the head skin (nearest-surface estimate).
        let sink: Float
        /// How deep it sits inside the defender's gloves (a blocked punch meets the guard).
        let guardSink: Float
        var frame = 0
    }

    let report: Report
    let studio: Studio
    let hero: BoxerModel
    let rival: BoxerModel
    let choreo: BoutChoreographer
    let skins: [Skin]
    let gloves: [[Int]]
    let headVerts: [[Int]]
    let feetVerts: [[Int]]
    let contactVerts: [[Int]]
    var engine: FightEngine
    let reducedMotion: Bool
    /// Snapshot / close-up / filmstrip renders while the bout runs (the roster sweep only measures).
    var renders = true
    /// Debug tracing: `HAYMAKER_TRACE=a-b` (frames) and/or `HAYMAKER_TRACE_TAG=tag` or `tag@a-b,tag2@c-d`.
    func traced(_ frame: Int) -> Bool {
        let env = ProcessInfo.processInfo.environment
        func within(_ text: Substring?) -> Bool {
            guard let text else { return true }
            let range = text.split(separator: "-").compactMap { Int($0) }
            return range.count == 2 && (range[0]...range[1]).contains(frame)
        }
        guard let tags = env["HAYMAKER_TRACE_TAG"] else {
            return env["HAYMAKER_TRACE"] != nil && within(env["HAYMAKER_TRACE"].map { Substring($0) })
        }
        return tags.split(separator: ",").contains { entry in
            let parts = entry.split(separator: "@", maxSplits: 1)
            guard parts.first.map(String.init) == tag else { return false }
            return within(parts.count > 1 ? parts[1] : env["HAYMAKER_TRACE"].map { Substring($0) })
        }
    }

    /// Which bout this is in the log (`HAYMAKER_TRACE_TAG` limits tracing to one bout).
    var tag = ""
    private(set) var samples: [Sample] = []
    private(set) var contacts: [Contact] = []
    private(set) var hits: [Hit] = []
    private(set) var frame = 0
    var snapshots: [String: Snapshot] = [:]
    var strips: [String: [Snapshot]] = [:]
    /// Close side views of each punch arriving (landed / blocked), at `contact`.
    var closeups: [Snapshot] = []
    private var stripPlans: [(name: String, start: Int, offsets: [Int], side: Bool)] = []
    private var delayed: [(frame: Int, label: String)] = []
    var idleClearance: Float = .infinity
    /// Closest approach of the two fighters' shins/feet (skin vertices).
    var legClearance: Float = .infinity
    var legClearanceAt = ""
    var legContactFrames = 0
    let legVerts: [[Int]]
    /// Deepest overlap of torso/head blobs between the fighters.
    var bodyOverlap: Float = -.infinity
    var bodyOverlapAt = ""
    var bodyOverlapIndex = 0
    /// Deepest glove-in-glove and glove-in-head skin penetration over the bout.
    var gloveClash: Float = 0
    var gloveClashAt = ""
    var gloveClashIndex: (sample: Int, defender: Int)?
    var headClash: Float = 0
    var headClashAt = ""
    var headClashIndex: (sample: Int, defender: Int)?
    var aimDemands: [(String, Float)] = []
    var floorSink: Float = 0
    var floorSinkAt = ""
    var tauntFrames = 0
    /// Sample index of each knockdown and rise event (fighter 0 = hero).
    var knockdowns: [(index: Int, fighter: Int)] = []
    var rises: [(index: Int, fighter: Int)] = []
    /// Sample index where a player action was pressed on the first frame after a rise.
    var riseActions: [Int] = []
    let cell = CGSize(width: 300, height: 420)

    init(report: Report, studio: Studio, rival asset: FighterModelAsset, book: OpponentBook, seed: UInt64, reducedMotion: Bool = false) {
        self.report = report
        self.studio = studio
        self.reducedMotion = reducedMotion
        hero = BoxerModel(asset: .mack, isRival: false)
        rival = BoxerModel(asset: asset, isRival: true)
        choreo = BoutChoreographer(hero: hero, rival: rival)
        skins = [Skin(hero.rig), Skin(rival.rig)]
        gloves = skins.map { [$0.vertices([FighterBone.leftHand.rawValue]), $0.vertices([FighterBone.rightHand.rawValue])] }.map { $0[0] + $0[1] }
        headVerts = skins.map { $0.vertices([FighterBone.head.rawValue]) }
        feetVerts = skins.map { $0.vertices([16, 17, 20, 21]) }
        legVerts = skins.map { skin in skin.vertices([15, 16, 17, 19, 20, 21]).enumerated().filter { $0.offset % 4 == 0 }.map(\.element) }
        contactVerts = skins.map { skin in skin.vertices([5, 9, 13, 8, 12]).enumerated().filter { $0.offset % 3 == 0 }.map(\.element) }
        engine = FightEngine(config: EngineConfig(roundTicks: 10_800, restTicks: 240, dodgeTicks: 20), seed: seed, book: book)
        choreo.reset()
        choreo.restPose()
        studio.scene.rootNode.addChildNode(hero.root)
        studio.scene.rootNode.addChildNode(rival.root)
    }

    func remove() {
        hero.root.removeFromParentNode()
        rival.root.removeFromParentNode()
    }

    private func model(_ side: Combatant) -> BoxerModel { side == .player ? hero : rival }

    private func describe(_ status: FighterStatus) -> String {
        "\(status.state.rawValue)\(status.currentMove == .idle ? "" : "(\(status.currentMove.rawValue))") \(status.ticksInCurrentState)/\(status.stateDuration)"
    }

    // MARK: Frame pump

    /// One 60 Hz presentation frame; `tick` advances the engine first.
    func step(_ input: PlayerInput = .none, tick: Bool = true) -> [FightEvent] {
        let before = engine.events.count
        if tick { engine.tick(input) }
        _ = choreo.update(engine, dt: 1.0 / 60, tickFraction: 0, reducedMotion: reducedMotion)
        frame += 1
        let events = Array(engine.events.dropFirst(before))
        record(events)
        return events
    }

    private func record(_ events: [FightEvent]) {
        let joints = [hero, rival].map { model in
            transformed(model.root.simdTransform, model.pose.joints(heads: model.rig.heads))
        }
        samples.append(Sample(joints: joints, states: [describe(engine.player), describe(engine.opponent)],
                              roots: [hero.root.simdTransform, rival.root.simdTransform], poses: [hero.pose, rival.pose],
                              planted: [hero.director.feetPlanted, rival.director.feetPlanted], aims: [hero.director.aim, rival.director.aim],
                              clips: [hero.lastMotion?.clip, rival.lastMotion?.clip],
                              clipFrames: [hero, rival].map { $0.lastMotion.map { $0.lower ?? $0.frame } ?? 0 },
                              notes: [hero, rival].map { model in
                                  let d = model.director
                                  return "arm \(f2(model.lastMotion?.frame ?? 0)) lunge \(f2(d.lunge))×\(d.lungeMove) reach \(f2(d.reach)) aim \(f2(d.aim))"
                              },
                              stretch: [hero, rival].map { m in (0..<2).map { m.planter.phase($0) == .planted ? m.planter.stretch($0) : 0 }.max()! },
                              swing: [hero, rival].map { m in (0..<2).map { m.planter.phase($0) == .stepping ? m.planter.stretch($0) : 0 }.max()! },
                              releases: [hero, rival].map { m in m.planter.feet.map { $0.phase == .stepping && $0.releasing } }))
        if traced(frame) {
            for (name, model) in [("hero", hero), ("rival", rival)] {
                let m = model.lastMotion
                let other = name == "hero" ? rival : hero
                for hand in [FighterBone.leftHand, .rightHand] {
                    let g = model.blob(hand), gc = model.placed(g.center)
                    let gp = FighterReach.probes(hand.rawValue, pose: model.pose, rig: model.rig, around: g.center).map { model.placed($0 + g.center) - gc }
                    for bone in [FighterBone.head, .leftHand, .rightHand] {
                        let b = other.blob(bone), bc = other.placed(b.center)
                        let bp = FighterReach.probes(bone.rawValue, pose: other.pose, rig: other.rig, around: b.center).map { other.placed($0 + b.center) - bc }
                        let n = simd_normalize(gc - bc), d = simd_distance(gc, bc)
                        let clear = FighterReach.support(gp, radius: g.radius * model.scale, -n) + FighterReach.support(bp, radius: b.radius * other.scale, n)
                        if d < clear + 0.05 { print("trace \(frame) \(name) \(hand) vs \(bone): dist \(f3(d)) clear \(f3(clear)) (radii \(f3(g.radius * model.scale)) \(f3(b.radius * other.scale)))") }
                    }
                }
                if ProcessInfo.processInfo.environment["HAYMAKER_TRACE_FEET"] != nil {
                    for (k, foot) in model.planter.feet.enumerated() {
                        print("feet \(frame) \(name) \(k == 0 ? "L" : "R") \(foot.phase) lock \(f3(foot.lock.x)),\(f3(foot.lock.y)) from \(f3(foot.from.x)),\(f3(foot.from.y)) to \(f3(foot.to.x)),\(f3(foot.to.y)) u \(f2(foot.elapsed / max(1e-4, foot.duration))) dur \(f2(foot.duration)) strained \(foot.strained) over \(foot.overreach) chase \(f2(foot.chase)) rel \(foot.releasing) stretch \(f2(foot.stretch))")
                    }
                }
                if ProcessInfo.processInfo.environment["HAYMAKER_TRACE_ANIM"] != nil, let motion = model.lastMotion {
                    let toStage = model.root.simdTransform
                    let a = transformed(toStage, model.animated.joints(heads: model.rig.heads))
                    let raw = transformed(toStage, model.animator.sample(motion).joints(heads: model.rig.heads))
                    func v(_ p: SIMD3<Float>) -> String { "\(f3(p.x)),\(f3(p.y)),\(f3(p.z))" }
                    print("anim \(frame) \(name) L \(v(a[FighterBone.leftHand.rawValue])) R \(v(a[FighterBone.rightHand.rawValue])) rawL \(v(raw[FighterBone.leftHand.rawValue])) rawR \(v(raw[FighterBone.rightHand.rawValue])) hips \(v(a[0]))")
                }
                let sj = samples.last!.joints[name == "hero" ? 0 : 1]
                print("hands \(frame) \(name) L \(f3(sj[FighterBone.leftHand.rawValue].x)),\(f3(sj[FighterBone.leftHand.rawValue].y)),\(f3(sj[FighterBone.leftHand.rawValue].z)) R \(f3(sj[FighterBone.rightHand.rawValue].x)),\(f3(sj[FighterBone.rightHand.rawValue].y)),\(f3(sj[FighterBone.rightHand.rawValue].z)) aim \(f3(model.director.aim)) \(samples.last!.notes[name == "hero" ? 0 : 1])")
                print("trace \(frame) \(name) \(samples.last!.states[name == "hero" ? 0 : 1]) root \(model.root.simdPosition) hips \(model.pose.hips) head \(model.blob(.head).center) clip \(m?.clip.rawValue ?? "-") f \(m.map { f2($0.frame) } ?? "-") key \(m?.key ?? 0) fade \(m.map { f2($0.fade) } ?? "-") warp \(m.map { "\($0.warp.yaw) \($0.warp.offset)" } ?? "-") lunge \(f2(model.director.lunge)) reach \(f2(model.director.reach)) spread \(f3(choreo.gloveSpread)) feet \(model.planter.phase(0)) \(f2(model.planter.stretch(0))) \(model.planter.phase(1)) \(f2(model.planter.stretch(1))) toes \(samples.last!.joints[name == "hero" ? 0 : 1][17]) \(samples.last!.joints[name == "hero" ? 0 : 1][21])")
            }
        }
        for (side, model) in [hero, rival].enumerated() {
            let feet = transformed(model.root.simdTransform, skins[side].posed(model.pose, subset: feetVerts[side]))
            let sink = -(feet.map(\.y).min() ?? 0) + skins[side].floor * model.scale
            if sink > floorSink { floorSink = sink; floorSinkAt = "frame \(frame) \(side == 0 ? "hero" : "rival") \(samples.last!.states[side])" }
        }
        if engine.player.state == .idle, engine.opponent.state == .idle, frame % 6 == 0 {
            let a = transformed(hero.root.simdTransform, skins[0].posed(hero.pose, subset: contactVerts[0]))
            let b = transformed(rival.root.simdTransform, skins[1].posed(rival.pose, subset: contactVerts[1]))
            idleClearance = min(idleClearance, minDistance(a, b))
        }
        if frame % 2 == 0 {
            let a = transformed(hero.root.simdTransform, skins[0].posed(hero.pose, subset: legVerts[0]))
            let b = transformed(rival.root.simdTransform, skins[1].posed(rival.pose, subset: legVerts[1]))
            let gap = minDistance(a, b)
            if gap < 0.03 { legContactFrames += 2 }
            if gap < legClearance { legClearance = gap; legClearanceAt = "frame \(frame) \(samples.last!.states[0]) / \(samples.last!.states[1])" }
        }
        if case .taunt = hero.director.activeCue { tauntFrames += 1 }
        clashes()
        let bodyBones: [FighterBone] = [.hips, .spine, .spine1, .spine2, .head]
        let heroBody = bodyBones.map { hero.blob($0) }.map { (hero.placed($0.center), $0.radius * hero.scale) }
        let rivalBody = bodyBones.map { rival.blob($0) }.map { (rival.placed($0.center), $0.radius * rival.scale) }
        for (i, a) in heroBody.enumerated() {
            for (j, b) in rivalBody.enumerated() {
                let overlap = a.1 + b.1 - simd_distance(a.0, b.0)
                if overlap > bodyOverlap {
                    bodyOverlap = overlap
                    bodyOverlapIndex = samples.count - 1
                    bodyOverlapAt = "frame \(frame) hero \(bodyBones[i]) × rival \(bodyBones[j]); \(samples.last!.states[0]) / \(samples.last!.states[1])"
                }
            }
        }
        for event in events {
            switch event {
            case let .landed(_, by, move, _, counter):
                measure(by: by, move: move, label: "\(by == .player ? "hero" : "rival") \(move.rawValue) landed\(counter ? " (counter)" : "")")
            case let .blocked(_, by, move, _):
                measure(by: by, move: move, label: "\(by == .player ? "hero" : "rival") \(move.rawValue) blocked")
            case let .dodged(_, attacker, move):
                measure(by: attacker, move: move, label: "\(attacker == .player ? "hero" : "rival") \(move.rawValue) dodged")
            case let .parried(_, attacker, move):
                measure(by: attacker, move: move, label: "\(attacker == .player ? "hero" : "rival") \(move.rawValue) parried")
            case let .knockdown(_, fighter, _):
                knockdowns.append((samples.count - 1, fighter == .player ? 0 : 1))
            case let .rise(_, fighter):
                rises.append((samples.count - 1, fighter == .player ? 0 : 1))
            default:
                break
            }
        }
        for plan in stripPlans {
            let offset = frame - plan.start
            if plan.offsets.contains(offset) {
                strips[plan.name, default: []].append(Snapshot(image: shot(side: plan.side), label: "+\(offset)f \(stripCaption(plan.name))"))
            }
        }
        for item in delayed where item.frame == frame { capture(item.label) }
        delayed.removeAll { $0.frame <= frame }
    }

    private func stripCaption(_ name: String) -> String {
        let side = name.hasPrefix("rival") ? 1 : 0
        return samples.last!.states[side]
    }

    private func measure(by side: Combatant, move: Move, label: String) {
        let attacker = side == .player ? 0 : 1, defender = 1 - attacker
        let a = model(side), d = model(side == .player ? .opponent : .player)
        let hand = choreo.spacing.hand[side]?[move] ?? .leftHand
        let glove = transformed(a.root.simdTransform, skins[attacker].posed(a.pose, subset: skins[attacker].vertices([hand.rawValue])))
        let head = transformed(d.root.simdTransform, skins[defender].posed(d.pose, subset: headVerts[defender]))
        let blob = d.blob(.head)
        let center = d.placed(blob.center), radius = blob.radius * d.scale
        let depth = glove.map { radius - simd_distance($0, center) }.max() ?? 0
        // Depth of glove skin inside the head shell: glove vertices with a winding
        // number above ½ against the head's triangles, by distance to the head skin.
        let shell = transformed(d.root.simdTransform, skins[defender].posed(d.pose))
        contacts.append(Contact(label: label, gap: minDistance(glove, head), depth: depth,
                                sink: penetration(glove, into: defender, bone: 5, shell: shell),
                                guardSink: max(penetration(glove, into: defender, bone: 9, shell: shell),
                                               penetration(glove, into: defender, bone: 13, shell: shell)), frame: frame))
        let kind = ["landed", "blocked", "dodged", "parried"].first { label.contains($0) } ?? "?"
        hits.append(Hit(label: label, attacker: attacker, move: move, hand: hand, index: samples.count - 1, kind: kind))
        aimDemands.append((label, a.lastAimDemand))
    }

    /// Deepest of `points` inside fighter `side`'s shell of `bone` (posed `shell`, stage space).
    private func penetration(_ points: [SIMD3<Float>], into side: Int, bone: Int, shell: [SIMD3<Float>]) -> Float {
        let surface = skins[side].vertices([bone]).map { shell[$0] }
        let lo = surface.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let hi = surface.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        var deepest: Float = 0
        for g in points where all(g .> lo) && all(g .< hi) {
            guard abs(winding(g, skins[side].shells[bone] ?? [], shell)) > 0.5 else { continue }
            deepest = max(deepest, surface.map { simd_distance(g, $0) }.min() ?? 0)
        }
        return deepest
    }

    /// Every frame: any glove of one fighter inside the other's gloves or head.
    private func clashes() {
        let models = [hero, rival]
        var shells: [Int: [SIMD3<Float>]] = [:]
        for a in 0..<2 {
            let attacker = models[a], d = 1 - a, defender = models[d]
            for hand in [FighterBone.leftHand, .rightHand] {
                let g = attacker.blob(hand), gc = attacker.placed(g.center), gr = g.radius * attacker.scale
                for bone in [FighterBone.head, .leftHand, .rightHand] {
                    let b = defender.blob(bone)
                    guard simd_distance(gc, defender.placed(b.center)) < gr + b.radius * defender.scale else { continue }
                    if shells[d] == nil { shells[d] = transformed(defender.root.simdTransform, skins[d].posed(defender.pose)) }
                    let points = transformed(attacker.root.simdTransform, skins[a].posed(attacker.pose, subset: skins[a].vertices([hand.rawValue])))
                    let depth = penetration(points, into: d, bone: bone.rawValue, shell: shells[d]!)
                    let label = "frame \(frame) \(a == 0 ? "hero" : "rival") \(hand) into \(bone); \(samples.last!.states[0]) / \(samples.last!.states[1])"
                    if depth > 0.07, ProcessInfo.processInfo.environment["HAYMAKER_CLASHES"] != nil { print("clash \(f3(depth)) \(label)") }
                    if bone == .head {
                        if depth > headClash { headClash = depth; headClashAt = label; headClashIndex = (samples.count - 1, d) }
                    } else if depth > gloveClash {
                        gloveClash = depth
                        gloveClashAt = label
                        gloveClashIndex = (samples.count - 1, d)
                    }
                }
            }
        }
    }

    // MARK: Rendering

    func shot(side: Bool) -> NSImage {
        let c = choreo.ringCenter, axis = choreo.axis
        if side {
            var perpendicular = SIMD3<Float>(axis.z, 0, -axis.x)
            if perpendicular.z < 0 { perpendicular = -perpendicular }
            // Frame the pair (a knocked-down fighter slides well back from the ring center).
            var m = (hero.placed(hero.pose.hips) + rival.placed(rival.pose.hips)) / 2
            m.y = 0
            return studio.shot(cell, eye: m + perpendicular * 7.4 + SIMD3(0, 1.5, 0), target: m + SIMD3(0, 1.1, 0), fov: 36)
        }
        // The game's portrait broadcast camera.
        return studio.shot(cell, eye: SIMD3(c.x * 0.55, 2.95, 7.9), target: SIMD3(c.x * 0.8, 1.5, c.z * 0.5), fov: 43)
    }

    /// Re-pose both fighters as at sample `index` and shoot from a camera fixed on sample `anchor`.
    func render(_ index: Int, view: View, anchor: Int, size: CGSize, focus: Int? = nil) -> NSImage {
        let sample = samples[index]
        for (k, model) in [hero, rival].enumerated() {
            model.root.simdTransform = sample.roots[k]
            model.apply(sample.poses[k])
        }
        let ref = samples[anchor]
        let hips = (0..<2).map { k -> SIMD3<Float> in
            let p = ref.roots[k].columns.3
            return SIMD3(p.x, 0, p.z)
        }
        let mid = (hips[0] + hips[1]) / 2
        var axis = hips[1] - hips[0]
        axis = simd_length(axis) > 1e-3 ? simd_normalize(axis) : SIMD3(1, 0, 0)
        var perpendicular = SIMD3<Float>(axis.z, 0, -axis.x)
        if perpendicular.z < 0 { perpendicular = -perpendicular }
        let head: SIMD3<Float> = {
            let k = focus ?? hits.first { $0.index == anchor }.map { 1 - $0.attacker } ?? 1
            let model = k == 0 ? hero : rival
            let p = sample.roots[k] * SIMD4<Float>(FighterReach.blob(FighterBone.head.rawValue, pose: sample.poses[k], rig: model.rig).center, 1)
            return SIMD3(p.x, p.y, p.z)
        }()
        switch view {
        case .zoomTop:
            return studio.shot(size, eye: head + SIMD3(0, 6, 0), target: head, ortho: 0.5, up: -perpendicular)
        case .zoomFront:
            return studio.shot(size, eye: head + perpendicular * 12, target: head, ortho: 0.5)
        case .zoomEnd:
            // Along the fight axis, from behind the defender's shoulder line.
            let k = focus ?? hits.first { $0.index == anchor }.map { 1 - $0.attacker } ?? 1
            let away = k == 1 ? axis : -axis
            return studio.shot(size, eye: head + away * 12 + SIMD3(0, 0.3, 0), target: head, ortho: 0.5)
        case .side:
            return studio.shot(size, eye: mid + perpendicular * 7.4 + SIMD3(0, 1.5, 0), target: mid + SIMD3(0, 1.1, 0), fov: 36)
        case .front:
            return studio.shot(size, eye: mid + perpendicular * 12 + SIMD3(0, 1.45, 0), target: mid + SIMD3(0, 1.45, 0), ortho: 1.55)
        case .top:
            return studio.shot(size, eye: mid + SIMD3(0, 12, 0), target: mid, ortho: 1.55, up: -perpendicular)
        }
    }

    func closeup(by side: Combatant, move: Move, label: String) {
        guard renders else { return }
        let a = model(side), d = model(side == .player ? .opponent : .player)
        let hand = choreo.spacing.hand[side]?[move] ?? .leftHand
        let point = (a.placed(a.blob(hand).center) + d.placed(d.blob(.head).center)) / 2
        let axis = choreo.axis
        // Look from the punching arm's side so the arm isn't hidden behind a body.
        var perpendicular = SIMD3<Float>(axis.z, 0, -axis.x)
        let arm = hand == .leftHand ? FighterBone.leftArm : .rightArm
        let shoulder = a.placed(a.pose.joints(heads: a.rig.heads)[arm.rawValue])
        if simd_dot(shoulder - a.root.simdPosition, perpendicular) < 0 { perpendicular = -perpendicular }
        let size = CGSize(width: 420, height: 420)
        let image = studio.shot(size, eye: point + perpendicular * 3.2 + SIMD3(0, 0.25, 0), target: point - SIMD3(0, 0.15, 0), fov: 32)
        closeups.append(Snapshot(image: image, label: "\(label) (frame \(frame))"))
    }

    func capture(_ label: String, side: Bool = false) {
        guard renders, snapshots[label] == nil else { return }
        snapshots[label] = Snapshot(image: shot(side: side), label: label)
    }

    func later(_ frames: Int, _ label: String) { delayed.append((frame + frames, label)) }

    func strip(_ name: String, offsets: [Int], side: Bool = true) {
        guard renders, !stripPlans.contains(where: { $0.name == name }) else { return }
        stripPlans.append((name, frame, offsets, side))
        if offsets.contains(0) { strips[name, default: []].append(Snapshot(image: shot(side: side), label: "+0f \(stripCaption(name))")) }
    }

    // MARK: Script

    func countdown(_ frames: Int) { for _ in 0..<frames { _ = step(tick: false) } }

    /// The hero throws a jab on the first frame after getting up (the get-up's
    /// walk home must hand over to it without a pop).
    private var jabOnRise = false

    /// Only the pre-bout 3-2-1 freezes the engine; a knockdown's count runs inside
    /// the live fight and the bout resumes on the `.rise` tick.
    func run(_ intents: [Intent]) {
        countdown(30)
        capture("idle (guard)")
        countdown(60)
        for intent in intents {
            var done = false
            var ticks = 0
            while !done, ticks < 2_400, !engine.isOver {
                ticks += 1
                var input = decide(intent)
                if jabOnRise, engine.player.state == .idle {
                    jabOnRise = false
                    input = .jab
                    riseActions.append(samples.count)
                }
                let events = step(input)
                watch(events)
                done = completes(intent, events)
                if events.contains(where: { if case .rise(_, .player) = $0 { true } else { false } }) { jabOnRise = true }
            }
            report.check(done, "scenario intent \(intent) did not complete (\(ticks) ticks)")
            intentLog.append("\(intent) \(done ? "" : "✗")\(ticks)")
            if engine.isOver { break }
        }
        if engine.isOver {
            countdown(Int(MatchSceneTiming.postBoutRenderSeconds * 60))
        } else {
            // Let the last punch recover before the checks read it.
            for _ in 0..<60 where !engine.isOver { watch(step(.none)) }
            // ...and end the recording between steps (a step cut off by the end can't be judged).
            let stepping = { [self] in [hero, rival].contains { m in (0..<2).contains { m.planter.phase($0) == .stepping } } }
            for _ in 0..<30 where !engine.isOver && stepping() { watch(step(.none)) }
        }
    }

    private var pressedFor: Int?
    /// Each scripted intent and the ticks it took (✗ = timed out).
    private(set) var intentLog: [String] = []
    /// Punches of the current `.combo` thrown so far, and the sample its first one started on.
    private var comboThrown = 0
    private(set) var comboStart: Int?

    /// Consecutive frames the rival has stood idle (between its patterns).
    private var rivalIdleFrames = 0
    /// Patterns the harness slotted into a book that never throws them.
    private(set) var guests: [String] = []

    /// A scripted scenario needs a pattern this book never issues (Goldie never blocks,
    /// Sylvie never uppercuts): once the rival has idled for its book's minimum gap,
    /// commit a guest pattern exactly as the scheduler commits its own — timed like the
    /// book's slowest punch (or a typical guard hold) — so every scenario runs on every rig.
    private func guest(_ move: Move) {
        guard !engine.book.sequence.contains(where: { $0.move == move }), engine.opponent.state == .idle,
              engine.player.state == .idle, rivalIdleFrames >= max(engine.book.minGap, 12) else { return }
        let punches = engine.book.sequence.filter { [.jab, .hook, .uppercut].contains($0.move) }
        let entry = move == .block
            ? PatternEntry(move: .block, tell: 36, impact: 54, recover: 20, staminaCost: 0, damage: 0)
            : PatternEntry(move: move, tell: punches.map(\.tell).max() ?? 40, impact: punches.map(\.impact).max() ?? 14,
                           recover: punches.map(\.recover).max() ?? 40, staminaCost: 0, damage: 12)
        engine.opponent.state = .telling
        engine.opponent.ticksInCurrentState = 0
        engine.opponent.stateDuration = entry.tell
        engine.opponent.currentMove = entry.move
        engine.opponent.currentDamage = entry.damage
        engine.oppActive = entry
        guests.append("\(move.rawValue) @\(samples.count)")
    }

    private func decide(_ intent: Intent) -> PlayerInput {
        rivalIdleFrames = engine.opponent.state == .idle ? rivalIdleFrames + 1 : 0
        // Keep both fighters standing through scenarios that aren't about finishing the bout.
        if case .loseByKO = intent {} else { engine.player.hp = max(engine.player.hp, 50) }
        if case .finishRival = intent {} else { engine.opponent.hp = max(engine.opponent.hp, 50) }
        let me = engine.player, them = engine.opponent
        let punching = [Move.jab, .hook, .uppercut].contains(them.currentMove)
        let remaining = them.stateDuration - them.ticksInCurrentState
        func press(_ input: PlayerInput, _ name: String? = nil) -> PlayerInput {
            guard me.state == .idle else { return .none }
            if let name { strip(name, offsets: Array(stride(from: 0, through: 33, by: 3))) }
            return input
        }
        switch intent {
        case let .takeHit(move):
            if let move, them.state == .attacking, them.currentMove != move, them.ticksInCurrentState == 0 { return press(.block) }
            if let move { guest(move) }
            return .none
        case let .punch(move):
            guard me.state == .idle, [.idle, .recovering].contains(them.state) else { return .none }
            return press(PlayerInput(rawValue: move.rawValue) ?? .jab, move == .jab ? "hero jab → idle" : nil)
        case .block:
            if them.state == .attacking, punching, them.ticksInCurrentState == 0 { return press(.block, "hero block") }
        case .dodge:
            if them.state == .attacking, punching, remaining <= engine.config.dodgeTicks - 6, remaining >= 4 { return press(.dodge, "hero slip") }
        case .parry:
            if them.state == .attacking, punching, remaining == 3 { return press(.parry) }
        case .punchGuard:
            if them.state == .blocking, remaining >= 12 { return press(.jab) }
            guest(.block)
        case .knockdownRival:
            engine.opponent.hp = max(engine.opponent.hp, 70)
            engine.player.stamina = engine.config.damage.maxStamina
            if them.state == .telling, punching, them.ticksInCurrentState == 1, them.stateDuration >= 14 { return press(.uppercut) }
        case .heroKnockdown:
            engine.player.hp = max(engine.player.hp, 60)
        case .finishRival:
            engine.opponent.hp = min(engine.opponent.hp, 4)
            engine.player.stamina = engine.config.damage.maxStamina
            if them.state == .telling, punching, them.ticksInCurrentState == 1, them.stateDuration >= 10 { return press(.hook) }
        case .loseByKO:
            if them.state == .attacking, punching { engine.player.hp = 1 }
        case let .combo(moves):
            engine.opponent.hp = max(engine.opponent.hp, 70)
            engine.player.hp = max(engine.player.hp, 60)
            engine.player.stamina = engine.config.damage.maxStamina
            guard comboThrown < moves.count, me.state == .idle else { break }
            // Open on a quiet rival; the rest follow on the first idle frame.
            if comboThrown == 0, !(them.state == .idle || (them.state == .recovering && remaining >= 40)) { break }
            if comboThrown == 0 { comboStart = samples.count }
            comboThrown += 1
            return press(PlayerInput(rawValue: moves[comboThrown - 1].rawValue) ?? .jab)
        }
        return .none
    }

    private func completes(_ intent: Intent, _ events: [FightEvent]) -> Bool {
        for event in events {
            switch (intent, event) {
            case let (.takeHit(want), .landed(_, .opponent, move, _, _)) where want == nil || want == move: return true
            case let (.punch(want), .landed(_, .player, move, _, _)) where want == move: return true
            case (.block, .blocked(_, .opponent, _, _)): return true
            case (.dodge, .dodged(_, .opponent, _)): return true
            case (.parry, .parried(_, .opponent, _)): return true
            case (.punchGuard, .blocked(_, .player, _, _)): return true
            case (.knockdownRival, .rise(_, .opponent)): return true
            case (.heroKnockdown, .landed(_, .opponent, _, _, _)):
                // The blow that just landed puts the hero down (through the real rules path).
                let before = engine.events.count
                engine.forcePlayerKnockdown()
                watch(Array(engine.events.dropFirst(before)))
            case (.heroKnockdown, .rise(_, .player)): return true
            case (.finishRival, .boutEnd), (.loseByKO, .boutEnd): return true
            case let (.combo(moves), .landed(_, .player, move, _, _)), let (.combo(moves), .blocked(_, .player, move, _)),
                 let (.combo(moves), .dodged(_, .player, move)), let (.combo(moves), .parried(_, .player, move)),
                 let (.combo(moves), .whiffed(_, .player, move)):
                if comboThrown == moves.count, move == moves.last { return true }
            default: break
            }
        }
        return false
    }

    /// Snapshot the moments the QA sheet shows.
    private func watch(_ events: [FightEvent]) {
        let me = engine.player, them = engine.opponent
        if them.state == .telling, [.jab, .hook, .uppercut].contains(them.currentMove), them.ticksInCurrentState == them.stateDuration - 1 {
            capture("rival \(them.currentMove.rawValue) tell")
        }
        if me.state == .blocking, me.ticksInCurrentState == 10 { capture("hero block") }
        if me.state == .dodging, me.ticksInCurrentState == 12 { capture("hero slip") }
        if me.state == .parrying, me.ticksInCurrentState == 3 { capture("hero parry") }
        if them.state == .blocking, them.ticksInCurrentState == 14 { capture("rival block") }
        if them.state == .knockedDown {
            switch them.ticksInCurrentState {
            case 60: capture("rival down (ground)")
            case 110: capture("hero taunt over downed rival")
            case 165: capture("rival getting up")
            default: break
            }
        }
        if me.state == .knockedDown {
            switch me.ticksInCurrentState {
            case 60: capture("hero down (ground)")
            case 165: capture("hero getting up")
            default: break
            }
        }
        for event in events {
            switch event {
            case let .landed(_, by, move, _, counter):
                capture("\(by == .player ? "hero" : "rival") \(move.rawValue) contact")
                closeup(by: by, move: move, label: "\(by == .player ? "hero" : "rival") \(move.rawValue) landed\(counter ? " (counter)" : "")")
                later(8, by == .player ? "rival hit reaction (\(move.rawValue))" : "hero hit reaction (\(move.rawValue))")
                if by == .opponent, move == .uppercut { strip("hero hit by uppercut", offsets: Array(stride(from: 0, through: 33, by: 3))) }
                if by == .player, move == .hook { strip("rival hit by hook", offsets: Array(stride(from: 0, through: 33, by: 3))) }
                _ = counter
            case let .blocked(_, by, move, _):
                capture("\(by == .player ? "hero" : "rival") \(move.rawValue) blocked")
                closeup(by: by, move: move, label: "\(by == .player ? "hero" : "rival") \(move.rawValue) blocked")
            case let .dodged(_, attacker, move):
                capture("\(attacker == .player ? "hero" : "rival") \(move.rawValue) slipped")
            case let .knockdown(_, fighter, _):
                let name = fighter == .opponent ? "rival knockdown → get-up → guard" : "hero knockdown → get-up → guard"
                strip(name, offsets: Array(stride(from: 0, through: 180 + 162 + 30, by: 16)))
            case .boutEnd:
                later(60, "KO fall (+1.0 s)")
                later(150, "victory (+2.5 s)")
                later(250, "victory (+4.2 s)")
            default:
                break
            }
        }
    }
}

/// Mirrors MatchScene's post-bout window without pulling UIKit into the harness.
enum MatchSceneTiming {
    static let postBoutRenderSeconds = 6.0
}

// MARK: - Main

@main struct Verify {
    @MainActor static func main() throws {
        let report = Report()
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/fighter-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // 1. Assets.
        guard let library = checkLibrary(report) else { exit(1) }
        _ = library
        var rigs: [FighterModelAsset: FighterRigData] = [:]
        for asset in FighterModelAsset.allCases {
            do {
                let rig = try FighterRigData.load(asset)
                rigs[asset] = rig
                let model = BoxerModel(asset: asset, isRival: asset != .mack)
                let skinner = model.root.childNode(withName: "skinnedMesh", recursively: true)?.skinner
                report.check(skinner?.bones.count == FighterSkeleton.boneCount, "\(asset.rawValue): skinner has 22 bones")
                if let bones = skinner?.bones {
                    for bone in 1..<bones.count {
                        report.check(bones[bone].parent === bones[FighterSkeleton.parents[bone]], "\(asset.rawValue): bone \(bone) parent")
                    }
                }
                let skin = Skin(rig)
                report.log("rig \(asset.rawValue): \(rig.vertexCount) vertices, height \(f3(skin.height)), floor \(f3(skin.floor)), hips \(f3(rig.heads[0].y))")
            } catch {
                report.check(false, "\(asset.rawValue): \(error)")
            }
        }

        // 2. Every clip on every rig.
        report.log("\nclip sweep, raw clips (rigid parts: max |edge stretch|; legs/arms/neck: 99th-percentile |edge stretch|; twist about the bone axis):")
        for asset in FighterModelAsset.allCases {
            guard let rig = rigs[asset] else { continue }
            let stats = checkClips(asset, rig: rig, report: report)
            let deviation = stats.deviation.keys.sorted().map { "\($0) \(f3(stats.deviation[$0]?.0 ?? 0)) (\(stats.deviation[$0]?.1 ?? "-"))" }
            report.log("  \(asset.rawValue): foot sink \(f3(stats.footSink)) (\(stats.footSinkAt)), lying sink \(f3(stats.bodySink)), hips ≥ \(f2(stats.hipsLow))× rest; \(deviation.joined(separator: ", "))")
            report.check(stats.footSink < 0.05, "\(asset.rawValue): feet sink \(f3(stats.footSink)) below the floor at \(stats.footSinkAt)")
            for region in Skin.rigidRegions.keys.sorted() {
                let value = stats.deviation[region]?.0 ?? 0
                report.check(value < 0.01, "\(asset.rawValue): rigid \(region) deform by \(f3(value)) at \(stats.deviation[region]?.1 ?? "")")
            }
            report.check(stats.hipsLow > 0.45, "\(asset.rawValue): hips drop to \(f2(stats.hipsLow))× rest height outside knockdown")
        }

        // 3. Stance / retarget sanity on Mack.
        if let mack = rigs[.mack] {
            let motions = FighterMotionSet.shared(for: mack)
            if ProcessInfo.processInfo.environment["HAYMAKER_CLIPSPEED"] != nil {
                for id in [ClipID.jab, .hook, .uppercut] {
                    guard let clip = motions[id] else { continue }
                    let hand = FighterReach.punchingHand(motions, clip: id).rawValue
                    let pts = (0..<clip.frameCount).map { FighterReach.pose(motions, id, frame: Float($0))!.joints(heads: motions.heads)[hand] }
                    let sp = (0..<(clip.frameCount - 1)).map { simd_distance(pts[$0 + 1], pts[$0]) }
                    print("clipspeed \(id) chamber \(clip.marker("chamber", 0)) contact \(clip.marker("contact", 0)) " + sp.enumerated().map { "\($0.offset):\(f3($0.element))" }.joined(separator: " "))
                }
            }
            if let idle = FighterReach.pose(motions, .idle, frame: 0) {
                let left = FighterReach.blob(FighterBone.leftHand.rawValue, pose: idle, rig: mack).center
                let right = FighterReach.blob(FighterBone.rightHand.rawValue, pose: idle, rig: mack).center
                let head = FighterReach.blob(FighterBone.head.rawValue, pose: idle, rig: mack).center
                let chest = idle.joints(heads: mack.heads)[FighterBone.spine2.rawValue]
                let forward = idle.rotations[0].act(SIMD3<Float>(0, 0, 1))
                report.log("\nMack idle: head \(head), lead glove \(left), rear glove \(right), hips yaw \(f2(atan2(forward.x, forward.z) * 180 / .pi))°")
                report.check(left.y > chest.y && right.y > chest.y, "guard: gloves above the chest")
                report.check(left.z > chest.z && right.z > chest.z, "guard: gloves in front of the chest")
            }
            for id in [ClipID.jab, .hook, .uppercut] {
                guard let clip = motions[id], let chamber = FighterReach.pose(motions, id, frame: clip.marker("chamber", 0)),
                      let contact = FighterReach.pose(motions, id, frame: clip.marker("contact", 0)) else { continue }
                let hand = FighterReach.punchingHand(motions, clip: id)
                let a = FighterReach.blob(hand.rawValue, pose: chamber, rig: mack).center
                let b = FighterReach.blob(hand.rawValue, pose: contact, rig: mack).center
                let travel = b - a
                report.log("  \(id.rawValue): \(hand) chamber \(a) → contact \(b), travel heading \(f2(atan2(travel.x, travel.z) * 180 / .pi))°")
            }
            report.check(FighterReach.punchingHand(motions, clip: .jab) == .leftHand, "jab is thrown with the lead (left) glove")
            let director = FighterDirector(motions: motions)
            report.log("  retracted (glove back within \(Int(AnimationTuning.retractedShare * 100))% of its travel): "
                + [ClipID.jab, .hook, .uppercut].map { "\($0.rawValue) \(director.retractedFrames[$0].map { f2($0) } ?? "-")" }.joined(separator: ", "))
        }

        let studio = Studio()
        let cell = CGSize(width: 300, height: 420)

        // 4. Guard grid of all fighters.
        var grid: [(NSImage, String)] = []
        for asset in FighterModelAsset.allCases {
            let model = BoxerModel(asset: asset, isRival: asset != .mack)
            model.update(FighterStatus(), totalTicks: 0, tickFraction: 0, now: 0, dt: 0, reducedMotion: true)
            model.root.simdEulerAngles = SIMD3<Float>(0, 0.5, 0)
            studio.scene.rootNode.addChildNode(model.root)
            grid.append((studio.shot(cell, eye: SIMD3(0, 1.45, 6.3), target: SIMD3(0, 1.3, 0), fov: 34), "\(asset.rawValue) guard (×\(f2(model.scale)))"))
            model.root.removeFromParentNode()
        }
        try writeSheet(grid, columns: 5, cell: cell, title: "Guard (idle frame 0) — all fighters", to: out.appendingPathComponent("guard-grid.png"))

        // 5. Every clip, key frames, on Mack and Bruiser.
        for asset in [FighterModelAsset.mack, .bruiser] {
            let model = BoxerModel(asset: asset, isRival: false)
            studio.scene.rootNode.addChildNode(model.root)
            var cells: [(NSImage, String)] = []
            for id in ClipID.allCases {
                guard let clip = model.motions[id] else { continue }
                var frames = Array(Set(clip.markers.values.map { $0 } + [0, clip.lastFrame])).sorted()
                while frames.count < 6 { frames.append(clip.lastFrame * Float(frames.count) / 6); frames = Array(Set(frames)).sorted() }
                for frame in frames.prefix(6) {
                    let name = clip.markers.first { $0.value == frame }?.key ?? "f\(Int(frame))"
                    guard let pose = FighterReach.pose(model.motions, id, frame: frame) else { continue }
                    model.apply(pose)
                    model.root.simdEulerAngles = SIMD3<Float>(0, 0.9, 0)
                    cells.append((studio.shot(CGSize(width: 220, height: 300), eye: SIMD3(0, 1.4, 7.4), target: SIMD3(0, 1.1, 0), fov: 34),
                                  "\(id.rawValue) \(name)"))
                }
            }
            model.root.removeFromParentNode()
            try writeSheet(cells, columns: 6, cell: CGSize(width: 220, height: 300), title: "\(asset.rawValue): clip key frames",
                           to: out.appendingPathComponent("clips-\(asset.rawValue).png"))
        }

        // 6. Static contact and spacing for Mack against every opponent.
        report.log("\nspacing (scene units, roots on the fight axis) and glove→head gap at contact vs an idle defender:")
        for asset in FighterModelAsset.allCases {
            let hero = BoxerModel(asset: .mack, isRival: false), rival = BoxerModel(asset: asset, isRival: true)
            let spacing = BoutChoreographer.measureSpacing(hero: hero, rival: rival)
            let skins = [Skin(hero.rig), Skin(rival.rig)]
            var parts: [String] = []
            for (side, attacker, defender) in [(Combatant.player, 0, 1), (.opponent, 1, 0)] {
                let models = [hero, rival]
                for (move, id) in [(Move.jab, ClipID.jab), (.hook, .hook), (.uppercut, .uppercut)] {
                    guard let clip = models[attacker].motions[id],
                          var contact = FighterReach.pose(models[attacker].motions, id, frame: clip.marker("contact", 0)),
                          let legs = FighterReach.pose(models[attacker].motions, id,
                                                       frame: BoutChoreographer.expectedContactLower(side: side, move: move, clip: clip)),
                          let idle = FighterReach.pose(models[defender].motions, .idle, frame: 0),
                          let reference = BoutChoreographer.spacingReference(models[attacker], side: side, move: move, clip: id) else { continue }
                    FighterAnimator.mergeLower(&contact, legs)
                    let hand = spacing.hand[side]?[move] ?? .leftHand
                    let distance = spacing.base - spacing.slide(side, move)
                    // Steer exactly as the game does at contact (aim weight 1).
                    let target = BoutChoreographer.headTarget(attacker: models[attacker], defender: models[defender], distance: distance)
                    let aim = BoxerModel.aimCorrection(reference, target: target)
                    BoxerModel.steer(&contact, bone: reference.clavicle, by: aim.clavicle)
                    BoxerModel.steer(&contact, bone: reference.forearm, by: aim.forearm)
                    BoxerModel.steer(&contact, bone: reference.arm, by: aim.arm)
                    func place(_ model: Int, _ z: Float) -> simd_float4x4 {
                        var m = simd_float4x4(diagonal: SIMD4(models[model].scale, models[model].scale, models[model].scale, 1))
                        if model != attacker { m = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))) * m }
                        m.columns.3 = SIMD4(0, 0, z, 1)
                        return m
                    }
                    let glove = transformed(place(attacker, 0), skins[attacker].posed(contact, subset: skins[attacker].vertices([hand.rawValue])))
                    let head = transformed(place(defender, distance), skins[defender].posed(idle, subset: skins[defender].vertices([5])))
                    let gap = minDistance(glove, head)
                    func deg(_ q: simd_quatf) -> Int { Int((q.angle * 180 / .pi).rounded()) }
                    parts.append("\(side == .player ? "M" : "R")\(move.rawValue.prefix(1))=\(f3(gap))@\(deg(aim.clavicle))+\(deg(aim.arm))°")
                    report.check(aim.armDemand <= AnimationTuning.maxAim + 0.02, "\(asset.rawValue): \(side == .player ? "Mack" : asset.rawValue) \(move.rawValue) needs \(Int(aim.armDemand * 180 / .pi))° of arm steer")
                    report.check(gap < 0.12, "\(asset.rawValue): \(side == .player ? "Mack" : asset.rawValue) \(move.rawValue) misses the head by \(f3(gap)) at contact")
                }
            }
            let slides = [Combatant.player, .opponent].map { side in
                [Move.jab, .hook, .uppercut].map { f2(spacing.slide(side, $0)) }.joined(separator: "/")
            }
            report.log("  mack vs \(asset.rawValue): base \(f3(spacing.base)) (guards clear at \(f3(spacing.clearance))); slide M \(slides[0]) R \(slides[1]); gaps \(parts.joined(separator: " "))")
        }

        // 7. Scripted engine bout (Mack vs Bruiser/Baxter), checks and QA renders.
        report.log("\nscripted bout: Mack vs Bruiser (Baxter book, career config)")
        var roster: [String: (bout: String, combo: String)] = [:]
        let bout = Bout(report: report, studio: studio, rival: .bruiser, book: .baxter, seed: 11)
        bout.tag = "bout"
        bout.run(boutScript)
        let mainSummary = analyse(bout, report: report)
        try renderHistory(bout, out: out)
        let order = ["idle (guard)", "rival jab tell", "rival jab contact", "rival hook tell", "rival hook contact", "rival hook blocked",
                     "rival uppercut tell", "rival uppercut contact", "hero jab contact", "hero hook contact", "hero uppercut contact",
                     "hero block", "hero slip", "hero parry", "rival block", "hero jab blocked", "hero hit reaction (jab)",
                     "hero hit reaction (uppercut)", "rival hit reaction (hook)", "rival down (ground)", "hero taunt over downed rival",
                     "rival getting up", "hero down (ground)", "hero getting up", "KO fall (+1.0 s)", "victory (+2.5 s)", "victory (+4.2 s)"]
        var frames = order.compactMap { bout.snapshots[$0] }.map { ($0.image, $0.label) }
        frames += bout.snapshots.keys.filter { !order.contains($0) }.sorted().compactMap { bout.snapshots[$0] }.map { ($0.image, $0.label) }
        try writeSheet(frames, columns: 6, cell: cell, title: "Mack vs Bruiser — match frames (game camera)", to: out.appendingPathComponent("match-frames.png"))
        try writeSheet(bout.closeups.map { ($0.image, $0.label) }, columns: 4, cell: CGSize(width: 420, height: 420),
                       title: "Mack vs Bruiser — punches arriving (side close-up at contact)", to: out.appendingPathComponent("contacts.png"))
        try writeStrips(bout, prefix: "strip-", out: out)
        bout.remove()

        // 7b. A chained hero jab → hook → uppercut: each follow-up closes with a short step.
        let combo = Bout(report: report, studio: studio, rival: .bruiser, book: .baxter, seed: 11)
        combo.tag = "combo"
        combo.run([.combo([.jab, .hook, .uppercut])])
        roster["baxter"] = (mainSummary, analyse(combo, report: report, name: "combo"))
        try renderCombo(combo, out: out, report: report)
        combo.remove()

        // 7c. Roster sweep: the same scripted bout and combo against every career opponent's
        // own book (tell / impact / recovery windows) and rig. Baxter is the bout above.
        for book in OpponentBook.careerRoster where book.id != "baxter" {
            guard let key = book.character?.asset, let asset = FighterModelAsset(rawValue: key) else {
                report.check(false, "career opponent \(book.id) has no fighter model")
                continue
            }
            report.log("\nscripted bout: Mack vs \(asset.rawValue) (\(book.id) book)")
            let sweep = Bout(report: report, studio: studio, rival: asset, book: book, seed: 11)
            // The final boss gets the full match-frames sheet and filmstrips for review.
            sweep.renders = book.id == "jaison"
            sweep.tag = "bout-\(book.id)"
            sweep.run(boutScript)
            let summary = analyse(sweep, report: report, name: "bout-\(book.id)")
            if sweep.renders {
                let frames = sweep.snapshots.values.sorted { $0.label < $1.label }.map { ($0.image, $0.label) }
                try writeSheet(frames, columns: 6, cell: cell, title: "Mack vs \(asset.rawValue) — match frames (game camera)",
                               to: out.appendingPathComponent("match-frames-\(book.id).png"))
                try writeStrips(sweep, prefix: "strip-\(book.id)-", out: out)
                try renderHistory(sweep, out: out.appendingPathComponent(book.id, isDirectory: true))
            }
            sweep.remove()
            let chain = Bout(report: report, studio: studio, rival: asset, book: book, seed: 11)
            chain.renders = false
            chain.tag = "combo-\(book.id)"
            chain.run([.combo([.jab, .hook, .uppercut])])
            roster[book.id] = (summary, analyse(chain, report: report, name: "combo-\(book.id)"))
            chain.remove()
        }
        report.log("\nroster sweep (Mack vs each career opponent, own book and rig):")
        for book in OpponentBook.careerRoster {
            guard let line = roster[book.id] else { continue }
            report.log("  \(book.id): bout \(line.bout)")
            report.log("  \(String(repeating: " ", count: book.id.count)): combo \(line.combo)")
        }

        // 8. The hero loses by KO: the fall stays down, the rival celebrates.
        let loss = Bout(report: report, studio: studio, rival: .bruiser, book: .baxter, seed: 5)
        loss.run([.loseByKO])
        report.check(loss.engine.outcome == .playerLossByKO, "loss scenario ends by KO (\(String(describing: loss.engine.outcome)))")
        analyse(loss, report: report, name: "loss")
        try writeSheet(loss.snapshots.values.sorted { $0.label < $1.label }.map { ($0.image, $0.label) }, columns: 6, cell: cell,
                       title: "Mack KO'd — rival celebrates", to: out.appendingPathComponent("loss-frames.png"))
        loss.remove()

        // 9. Reduced Motion: no idle bounce, readable actions.
        let still = BoxerModel(asset: .mack, isRival: false)
        still.update(FighterStatus(), totalTicks: 0, tickFraction: 0, now: 0, dt: 1.0 / 60, reducedMotion: true)
        let a = still.pose
        for i in 1...120 { still.update(FighterStatus(), totalTicks: i, tickFraction: 0, now: Double(i) / 60, dt: 1.0 / 60, reducedMotion: true) }
        let drift = zip(a.joints(heads: still.rig.heads), still.pose.joints(heads: still.rig.heads)).map { simd_distance($0, $1) }.max() ?? 0
        report.check(drift < 1e-4, "reduced motion idle is still (drift \(f3(drift)))")
        let guardGlove = still.blob(.leftHand).center
        for i in 0..<40 {
            still.update(FighterStatus(state: .telling, ticksInCurrentState: i, stateDuration: 40, currentMove: .jab), totalTicks: 200 + i,
                         tickFraction: 0, now: 2 + Double(i) / 60, dt: 1.0 / 60, reducedMotion: true)
        }
        report.check(simd_distance(still.blob(.leftHand).center, guardGlove) > 0.03, "reduced motion keeps the jab tell readable")
        still.resetMotion()
        still.poseTitle(time: 0.4, reducedMotion: true)
        let title = still.pose.joints(heads: still.rig.heads)
        still.poseTitle(time: 4.2, reducedMotion: true)
        report.check(zip(title, still.pose.joints(heads: still.rig.heads)).allSatisfy { simd_distance($0, $1) < 1e-4 }, "reduced motion title is still")
        still.resetMotion()
        still.poseTitle(time: 10, reducedMotion: false)
        let w0 = still.blob(.leftHand).center
        still.poseTitle(time: 10.6, reducedMotion: false)
        report.check(simd_distance(still.blob(.leftHand).center, w0) > 0.05, "title warm-up animates the gloves")

        try (report.lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if report.failures.isEmpty {
            print("\nAll fighter animation checks passed. Renders: \(out.path)")
        } else {
            print("\n\(report.failures.count) check(s) failed. Renders: \(out.path)")
            exit(1)
        }
    }

    /// Pops are one-frame displacement spikes: a joint moving much further in one
    /// frame than in the frames either side (a snap the eye reads as a glitch).
    /// Peak velocity change is reported for context (fast punches legitimately accelerate hard).
    /// Runs every check on a recorded bout; returns a one-line summary for the roster table.
    @discardableResult
    @MainActor static func analyse(_ bout: Bout, report: Report, name: String = "bout") -> String {
        let failuresBefore = report.failures.count
        let samples = bout.samples
        var pops: [(Float, String)] = []
        var peakAccel: [(Float, String)] = []
        for side in 0..<2 where samples.count > 3 {
            var frameAccel: (Float, Int, Int) = (0, 0, 0)
            for t in 2..<(samples.count - 1) {
                var worstHere: (Float, Int) = (0, 0)
                for joint in 0..<FighterSkeleton.boneCount {
                    let p = (t - 2...t + 1).map { samples[$0].joints[side][joint] }
                    let v0 = simd_distance(p[1], p[0]), v1 = simd_distance(p[2], p[1]), v2 = simd_distance(p[3], p[2])
                    let accel = simd_length((p[2] - p[1]) - (p[1] - p[0]))
                    if accel > worstHere.0 { worstHere = (accel, joint) }
                    let popRatio = v1 / (0.04 + 2.5 * max(v0, v2))
                    if popRatio > 0.8, ProcessInfo.processInfo.environment["HAYMAKER_POPS"] != nil {
                        report.log("  near-pop \(f2(popRatio)) \(side == 0 ? "hero" : "rival") \(FighterSkeleton.names[joint]) frame \(t): \(f3(v0)) \(f3(v1)) \(f3(v2)); \(samples[t - 1].states[side]) → \(samples[t].states[side])")
                    }
                    if v1 > 0.04 + 2.5 * max(v0, v2) {
                        pops.append((v1, "\(side == 0 ? "hero" : "rival") \(FighterSkeleton.names[joint]) frame \(t): moved \(f3(v1)) vs \(f3(v0))/\(f3(v2)) around it; \(samples[t - 1].states[side]) → \(samples[t].states[side])"))
                    }
                }
                if worstHere.0 > frameAccel.0 { frameAccel = (worstHere.0, worstHere.1, t) }
                if t % 30 == 0 || t == samples.count - 2 {
                    if frameAccel.0 > 0 {
                        let f = frameAccel.2
                        peakAccel.append((frameAccel.0, "\(side == 0 ? "hero" : "rival") \(FighterSkeleton.names[frameAccel.1]) frame \(f): \(samples[f - 1].states[side]) → \(samples[f].states[side])"))
                    }
                    frameAccel = (0, 0, 0)
                }
            }
        }
        footwork(bout, report: report, name: name)
        releaseSteps(bout, report: report, name: name)
        legStretch(bout, report: report, name: name)
        let windup = windups(bout, report: report, name: name)
        let stance = stanceWidth(bout, report: report, name: name)
        report.log("\(name): \(samples.count) frames; \(pops.count) one-frame pops")
        for pop in pops.sorted(by: { $0.0 > $1.0 }).prefix(10) { report.log("  pop \(pop.1)") }
        report.log("\(name): largest per-frame velocity changes (units/frame²):")
        for item in peakAccel.sorted(by: { $0.0 > $1.0 }).prefix(8) { report.log("  \(f3(item.0)) \(item.1)") }
        report.check(pops.isEmpty, "\(name): \(pops.count) one-frame pops")
        report.log("\(name): floor sink \(f3(bout.floorSink)) (\(bout.floorSinkAt)); idle clearance \(f3(bout.idleClearance)); taunt frames \(bout.tauntFrames)")
        report.check(bout.floorSink < 0.06, "\(name): feet sink \(f3(bout.floorSink)) below the canvas at \(bout.floorSinkAt)")
        report.check(bout.idleClearance > 0.0 || bout.idleClearance == .infinity, "\(name): fighters interpenetrate in guard")
        report.log("\(name): closest shin/foot approach \(f3(bout.legClearance)) (\(bout.legClearanceAt)); ~\(bout.legContactFrames) frames within 0.03")
        report.log("\(name): deepest torso/head blob overlap \(f3(bout.bodyOverlap)) (\(bout.bodyOverlapAt))")
        report.check(bout.bodyOverlap < 0.08, "\(name): bodies overlap by \(f3(bout.bodyOverlap)) at \(bout.bodyOverlapAt)")
        report.log("\(name): deepest glove inside a glove \(f3(bout.gloveClash)) (\(bout.gloveClashAt)); inside a head \(f3(bout.headClash)) (\(bout.headClashAt))")
        // Padded gloves pressing on gloves (blocks, parries, punches through the guard) measure up
        // to ~0.1 of skin overlap (about a third of a glove's width) for a few frames; deeper reads as clipping.
        report.check(bout.gloveClash < 0.1, "\(name): a glove sinks \(f3(bout.gloveClash)) into a glove at \(bout.gloveClashAt)")
        report.check(bout.headClash < 0.08, "\(name): a glove sinks \(f3(bout.headClash)) into a head at \(bout.headClashAt)")
        report.log("\(name): aim demand at contact: " + bout.aimDemands.map { "\($0.0) \(Int(($0.1 * 180 / .pi).rounded()))°" }.joined(separator: ", "))
        for contact in bout.contacts {
            report.log("  contact \(contact.label) @\(contact.frame): glove→head gap \(f3(contact.gap)), glove skin inside head skin \(f3(contact.sink)), inside guard gloves \(f3(contact.guardSink)), depth into head blob \(f3(contact.depth))")
            report.check(contact.sink < 0.08, "\(name): \(contact.label) sinks \(f3(contact.sink)) into the head")
            report.check(contact.guardSink < 0.08, "\(name): \(contact.label) sinks \(f3(contact.guardSink)) into the guard gloves")
            if contact.label.contains("landed") {
                report.check(contact.gap <= 0.02, "\(name): \(contact.label) lands \(f3(contact.gap)) short of the head")
            }
        }
        retraction(bout, report: report, name: name)
        exchanges(bout, report: report, name: name)
        rising(bout, report: report, name: name)
        let kinds = ["landed", "blocked", "dodged", "parried"].map { kind in "\(bout.hits.filter { $0.kind == kind }.count) \(kind)" }
        let gaps = bout.contacts.filter { $0.label.contains("landed") }.map(\.gap).max() ?? 0
        report.log("\(name): intents " + bout.intentLog.joined(separator: ", ")
                   + (bout.guests.isEmpty ? "" : "; guest patterns (not in this book): " + bout.guests.joined(separator: ", ")))
        return "\(samples.count) frames; \(kinds.joined(separator: " / ")); \(bout.knockdowns.count) knockdowns; "
            + "windup max \(f3(windup.travel))/\(f3(windup.speed)) per frame; stance ≤ \(f2(stance))×; pops \(pops.count); "
            + "worst landed gap \(f3(gaps)); glove-in-glove \(f3(bout.gloveClash)), in head \(f3(bout.headClash)); "
            + "\(report.failures.count - failuresBefore) failures"
    }

    /// Thresholds for the exchange checks (scene units / frames at 60 Hz).
    enum ExchangeLimits {
        /// A release step (fall / get-up) lands in a frame covering at most this × the
        /// pace around it, and never moves faster than `releasePeak` × its mean pace.
        static let releaseLanding: Float = 1.3
        static let releasePeak: Float = 3.0
        /// Release steps shorter than this (total toe travel) or landing frames under
        /// `releaseLandingFloor` are too small to read as a jump.
        static let releaseMinTravel: Float = 0.03
        static let releaseLandingFloor: Float = 0.01
        /// Torso blobs (hips…chest) never closer than this while both stand.
        static let torsoGap: Float = 0.06
        /// Head centers never closer than this while both stand.
        static let headDistance: Float = 0.45
        /// A landed punch moves the defender's head this far off its course within 3 frames.
        static let reaction: Float = 0.03
        /// A planted leg's hip-to-toe target never past this share of the leg length.
        static let legStretch: Float = 1.03
        /// A stepping (airborne) leg may trail straight behind a lunge — the foot lags
        /// its step target a little — but not by more than this.
        static let swingStretch: Float = 1.12
        /// Glove within `dwellDistance` of its target: frames before / after contact.
        static let dwellDistance: Float = 0.08
        static let dwellBefore = 3
        static let dwellAfter = 4
        /// Hips spacing back within this of neutral when the attacker's recovery ends.
        /// Root distance back within this of neutral, with the attacker's clip back in idle, within `settleFrames` of contact.
        static let neutralSpacing: Float = 0.06
        static let settleFrames = 60
        /// Root and hips horizontal travel over an attack windup (through contact):
        /// in total and per frame.
        static let windupTravel: Float = 0.5
        static let windupSpeed: Float = 0.07
        /// Ankle-to-ankle horizontal width never wider than this share of the guard stance.
        static let stanceWidth: Float = 1.15
    }

    /// Stage-space blob of `bone` for fighter `side` at sample `i`.
    @MainActor static func blob(_ bout: Bout, _ i: Int, _ side: Int, _ bone: FighterBone) -> (center: SIMD3<Float>, radius: Float) {
        let model = side == 0 ? bout.hero : bout.rival
        let sample = bout.samples[i]
        let b = FighterReach.blob(bone.rawValue, pose: sample.poses[side], rig: model.rig)
        let p = sample.roots[side] * SIMD4<Float>(b.center, 1)
        return (SIMD3<Float>(p.x, p.y, p.z), b.radius * model.scale)
    }

    /// Closest skin-to-skin distance between the two torsos (Hips…Spine2-dominated vertices).
    @MainActor static func torsoGap(_ bout: Bout, _ i: Int) -> Float {
        let sets = (0..<2).map { side in
            bout.skins[side].vertices([0, 1, 2, 3]).enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        }
        let a = transformed(bout.samples[i].roots[0], bout.skins[0].posed(bout.samples[i].poses[0], subset: sets[0]))
        let b = transformed(bout.samples[i].roots[1], bout.skins[1].posed(bout.samples[i].poses[1], subset: sets[1]))
        return minDistance(a, b)
    }

    @MainActor static func headDistance(_ bout: Bout, _ i: Int) -> Float {
        simd_distance(blob(bout, i, 0, .head).center, blob(bout, i, 1, .head).center)
    }

    @MainActor static func rootSpacing(_ bout: Bout, _ i: Int) -> Float {
        let a = bout.samples[i].roots[0].columns.3, b = bout.samples[i].roots[1].columns.3
        return simd_length(SIMD2(a.x - b.x, a.z - b.z))
    }

    /// Per punch: body spacing at contact and through the recovery, the defender's
    /// reaction latency, and how long the glove dwells on its target.
    @MainActor static func exchanges(_ bout: Bout, report: Report, name: String) {
        let samples = bout.samples
        func standing(_ i: Int) -> Bool {
            !samples[i].states.contains { $0.hasPrefix("knockedDown") || $0.hasPrefix("ko") }
        }
        // Neutral spacing: hips distance with both fighters idle in guard.
        let idleFrames = samples.indices.filter { i in samples[i].states.allSatisfy { $0.hasPrefix("idle") } }
        let neutral = idleFrames.isEmpty ? 0 : idleFrames.map { rootSpacing(bout, $0) }.sorted()[idleFrames.count / 2]
        var minContactGap = Float.infinity, minContactHead = Float.infinity, minRecoverGap = Float.infinity, minRecoverHead = Float.infinity
        var lines: [String] = []
        for hit in bout.hits {
            let attacker = hit.attacker, defender = 1 - attacker
            var end = hit.index
            while end + 1 < samples.count, end - hit.index < 90, samples[end + 1].states[attacker].hasPrefix("recovering") { end += 1 }
            let span = (max(0, hit.index - 6)...end).filter { standing($0) }
            guard standing(hit.index) else { continue }
            let contactGap = torsoGap(bout, hit.index), contactHead = headDistance(bout, hit.index)
            var recoverGap = Float.infinity, recoverHead = Float.infinity, worstAt = hit.index
            for i in span {
                let g = torsoGap(bout, i), h = headDistance(bout, i)
                if g < recoverGap { recoverGap = g; worstAt = i }
                recoverHead = min(recoverHead, h)
            }
            minContactGap = min(minContactGap, contactGap)
            minContactHead = min(minContactHead, contactHead)
            minRecoverGap = min(minRecoverGap, recoverGap)
            minRecoverHead = min(minRecoverHead, recoverHead)
            // This exchange's neutral: both idle in guard during the two seconds before it.
            let calm = idleFrames.filter { $0 >= hit.index - 120 && $0 <= hit.index - 10 }.map { rootSpacing(bout, $0) }.sorted()
            let local = calm.isEmpty ? neutral : calm[calm.count / 2]
            // Back at the neutral distance (roots) with the attacker's clip back in its idle.
            var home: Int?
            var undisturbed = true
            for i in hit.index..<min(samples.count, hit.index + ExchangeLimits.settleFrames + 30) {
                if i > end, !(samples[i].states[attacker].hasPrefix("idle") && standing(i)) { undisturbed = false; break }
                if abs(rootSpacing(bout, i) - local) <= ExchangeLimits.neutralSpacing, samples[i].clips[attacker] == .idle { home = i; break }
            }
            var line = "\(hit.label) @\(hit.index): torso gap \(f3(contactGap)) / head-head \(f3(contactHead)) at contact; "
                + "min \(f3(recoverGap)) (+\(worstAt - hit.index)f) / \(f3(recoverHead)) through recovery (+\(end - hit.index)f); "
                + "back to neutral spacing (\(f2(local))) " + (home.map { "at +\($0 - hit.index)f" } ?? (undisturbed ? "never" : "— next action first"))
            report.check(recoverGap >= ExchangeLimits.torsoGap,
                         "\(name): \(hit.label) torsos \(f3(recoverGap)) apart at +\(worstAt - hit.index)f (limit \(f2(ExchangeLimits.torsoGap)))")
            report.check(recoverHead >= ExchangeLimits.headDistance,
                         "\(name): \(hit.label) heads \(f3(recoverHead)) apart (limit \(f2(ExchangeLimits.headDistance)))")
            if undisturbed, standing(hit.index) {
                report.check((home ?? .max) - hit.index <= ExchangeLimits.settleFrames,
                             "\(name): \(hit.label) not back to neutral spacing within \(ExchangeLimits.settleFrames) frames of contact")
            }
            if hit.kind == "landed" {
                // The head driven along the punch: its travel from the frame before contact
                // along the glove's path (bent toward the attacker→defender line).
                let head = (hit.index - 1...min(samples.count - 1, hit.index + 3)).map { blob(bout, $0, defender, .head).center }
                let hand = hit.hand.rawValue
                var path = samples[hit.index].joints[attacker][hand] - samples[max(0, hit.index - 2)].joints[attacker][hand]
                let between = samples[hit.index].roots[defender].columns.3 - samples[hit.index].roots[attacker].columns.3
                var across = SIMD3<Float>(between.x, 0, between.z)
                across = simd_length(across) > 1e-4 ? simd_normalize(across) : .zero
                path = simd_length(path) > 1e-4 ? simd_normalize(path) : .zero
                let push = simd_length(path + across) > 1e-4 ? simd_normalize(path + across) : across
                var latency: Int?
                var peak: Float = 0
                for k in 1..<head.count {
                    let off = simd_dot(head[k] - head[0], push)
                    peak = max(peak, off)
                    if latency == nil, off >= ExchangeLimits.reaction { latency = k - 1 }
                }
                line += "; head reacts +\(latency.map(String.init) ?? ">3")f (\(f3(peak)) by +3f)"
                report.check(latency != nil, "\(name): \(hit.label) head moves only \(f3(peak)) within 3 frames of contact")
            }
            if hit.kind == "landed" || hit.kind == "blocked" {
                let model = attacker == 0 ? bout.hero : bout.rival, target = defender == 0 ? bout.hero : bout.rival
                let skin = bout.skins[attacker], other = bout.skins[defender]
                let glove = skin.vertices([hit.hand.rawValue]).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                let headSet = other.vertices([FighterBone.head.rawValue]).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                let guardSet = other.vertices([FighterBone.leftHand.rawValue, FighterBone.rightHand.rawValue]).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                _ = (model, target)
                var distance: [Int: Float] = [:], speed: [Int: Float] = [:]
                var previous: SIMD3<Float>?
                for i in max(0, hit.index - 16)...min(samples.count - 1, hit.index + 15) {
                    let g = transformed(samples[i].roots[attacker], skin.posed(samples[i].poses[attacker], subset: glove))
                    var t = transformed(samples[i].roots[defender], other.posed(samples[i].poses[defender], subset: headSet))
                    if hit.kind == "blocked" { t += transformed(samples[i].roots[defender], other.posed(samples[i].poses[defender], subset: guardSet)) }
                    distance[i] = minDistance(g, t)
                    let c = centroid(g)
                    if let previous { speed[i] = simd_distance(c, previous) }
                    previous = c
                }
                var before = 0, after = 0
                var i = hit.index - 1
                while let d = distance[i], d <= ExchangeLimits.dwellDistance { before += 1; i -= 1 }
                i = hit.index + 1
                while let d = distance[i], d <= ExchangeLimits.dwellDistance { after += 1; i += 1 }
                let approach = (hit.index - 12...hit.index).compactMap { speed[$0] }
                let peakSpeed = approach.max() ?? 0
                let peakAt = (hit.index - 12...hit.index).first { speed[$0] == peakSpeed }.map { $0 - hit.index } ?? 0
                if ProcessInfo.processInfo.environment["HAYMAKER_EXDEBUG"] != nil {
                    let series = (hit.index - 10...hit.index + 8).map { i -> String in
                        let h = blob(bout, min(samples.count - 1, i), defender, .head).center
                        let r = samples[min(samples.count - 1, i)].roots[defender].columns.3
                        return "\(i - hit.index):d\(distance[i].map(f3) ?? "-") s\(speed[i].map(f3) ?? "-") head(\(f2(h.x)),\(f2(h.y)),\(f2(h.z))) root(\(f2(r.x)),\(f2(r.z))) \(samples[min(samples.count - 1, i)].clips[attacker]?.rawValue ?? "-")@\(f2(samples[min(samples.count - 1, i)].clipFrames[attacker])) \(samples[min(samples.count - 1, i)].notes[attacker])"
                    }
                    print("EX \(hit.label) @\(hit.index)\n   " + series.joined(separator: "\n   "))
                }
                line += "; glove ≤\(f2(ExchangeLimits.dwellDistance)) of target \(before)f before / \(after)f after, "
                    + "speed into contact \(f3(speed[hit.index] ?? 0)) (peak \(f3(peakSpeed)) at \(peakAt)f)"
                if !samples[hit.index].states[attacker].hasPrefix("knockedDown") {
                    report.check(before <= ExchangeLimits.dwellBefore, "\(name): \(hit.label) glove sits on the target \(before) frames before contact")
                    report.check(after <= ExchangeLimits.dwellAfter, "\(name): \(hit.label) glove stays on the target \(after) frames after contact")
                }
            }
            lines.append(line)
        }
        report.log("\(name): exchanges (neutral root spacing \(f3(neutral))); min torso gap \(f3(minContactGap)) / head-head \(f3(minContactHead)) at contact, "
                   + "\(f3(minRecoverGap)) / \(f3(minRecoverHead)) through recovery")
        for line in lines { report.log("  " + line) }
    }

    /// Knockdowns: standing by the rise tick, taunts back to guard before it, and an
    /// action straight after the rise blending in without a pop.
    @MainActor static func rising(_ bout: Bout, report: Report, name: String) {
        let samples = bout.samples
        for rise in bout.rises {
            let f = rise.fighter, who = f == 0 ? "hero" : "rival"
            let model = f == 0 ? bout.hero : bout.rival
            let standing = model.motions[.getUp]?.marker("standing", 49) ?? 49
            let down = bout.knockdowns.last { $0.fighter == f && $0.index < rise.index }?.index ?? 0
            let up = (down..<samples.count).first { i in
                let started = samples[down...i].contains { $0.clips[f] == .getUp }
                return started && (samples[i].clips[f] != .getUp || samples[i].clipFrames[f] >= standing - 0.01)
            }
            let lag = up.map { $0 - rise.index }
            report.log("\(name): \(who) rise @\(rise.index): get-up reaches standing at \(lag.map { ($0 >= 0 ? "+" : "") + String($0) } ?? "never")f")
            report.check((lag ?? 99) <= 2, "\(name): \(who) is not standing by the rise (+\(lag.map(String.init) ?? "never")f)")
            let other = 1 - f
            if let lastTaunt = (down..<rise.index).last(where: { samples[$0].clips[other] == .victory }) {
                let clear = rise.index - lastTaunt
                report.log("\(name): \(other == 0 ? "hero" : "rival") taunt over the downed \(who) leaves the victory clip \(clear)f before the rise")
                report.check(clear >= Int(AnimationTuning.tauntFadeOut * 60), "\(name): taunt still blending out at the rise (\(clear)f before)")
            }
            if let next = (rise.index..<min(samples.count, rise.index + 240)).first(where: { !samples[$0].states[f].hasPrefix("idle") }) {
                report.log("\(name): \(who) first action after the rise: \(samples[next].states[f]) at +\(next - rise.index)f")
            }
        }
        for start in bout.riseActions {
            var worst: (Float, String) = (0, "")
            for t in max(2, start - 2)..<min(samples.count - 1, start + 40) {
                for joint in 0..<FighterSkeleton.boneCount {
                    let p = (t - 2...t + 1).map { samples[$0].joints[0][joint] }
                    let v0 = simd_distance(p[1], p[0]), v1 = simd_distance(p[2], p[1]), v2 = simd_distance(p[3], p[2])
                    let excess = v1 - 2.5 * max(v0, v2)
                    if excess > worst.0 { worst = (excess, "\(FighterSkeleton.names[joint]) +\(t - start)f") }
                }
            }
            report.log("\(name): hero jab pressed on the first frame after the rise (@\(start)): worst velocity spike \(f3(worst.0)) \(worst.1)")
            report.check(worst.0 <= 0.04, "\(name): post-rise jab pops (\(f3(worst.0)) at \(worst.1))")
        }
    }

    /// Feet: every toe run (consecutive frames where the toe moves > 0.004/frame or
    /// is lifted > 0.025 above its planted height) must be a real step (≥ 6 frames,
    /// lifted ≥ 0.02) or stay a slow creep (≤ 0.02/frame). Frames where the director
    /// releases the feet (knockdown, KO, getting up) are exempt.
    /// Planted legs never asked to reach past their length (a straight leg with the
    /// foot hanging off its plant reads as a rubber leg).
    @MainActor static func legStretch(_ bout: Bout, report: Report, name: String) {
        var worst: [String: (Float, Int)] = [:]
        var over = 0
        var episodes: [(fighter: Int, start: Int, end: Int, peak: Float, state: String)] = []
        var swingWorst: Float = 0, swingOver = 0
        for (i, sample) in bout.samples.enumerated() {
            for f in 0..<2 where sample.planted[f] {
                let state = String(sample.states[f].prefix { $0 != " " })
                swingWorst = max(swingWorst, sample.swing[f])
                let swinging = sample.swing[f] > ExchangeLimits.swingStretch
                if swinging { swingOver += 1 }
                if sample.stretch[f] > worst[state]?.0 ?? 0 { worst[state] = (sample.stretch[f], i) }
                let stretch = max(sample.stretch[f], sample.swing[f])
                guard sample.stretch[f] > ExchangeLimits.legStretch || swinging else { continue }
                over += sample.stretch[f] > ExchangeLimits.legStretch ? 1 : 0
                if let last = episodes.lastIndex(where: { $0.fighter == f }), episodes[last].end >= i - 2 {
                    episodes[last].end = i
                    episodes[last].peak = max(episodes[last].peak, stretch)
                } else {
                    episodes.append((f, i, i, stretch, sample.states[f]))
                }
            }
        }
        for e in episodes {
            report.log("  STRETCH \(e.fighter == 0 ? "hero" : "rival") \(e.start)-\(e.end) peak \(f2(e.peak)) from \(e.state)")
        }
        report.log("\(name): planted-leg stretch (hip-to-toe / leg length) max per state: "
                   + worst.keys.sorted().map { "\($0) \(f2(worst[$0]!.0))@\(worst[$0]!.1)" }.joined(separator: ", ")
                   + "; \(over) fighter-frames over \(f2(ExchangeLimits.legStretch)); stepping legs max \(f2(swingWorst)), \(swingOver) frames over \(f2(ExchangeLimits.swingStretch))")
        report.check(over == 0, "\(name): \(over) fighter-frames with a planted leg stretched past \(f2(ExchangeLimits.legStretch))")
        report.check(swingOver == 0, "\(name): \(swingOver) fighter-frames with a stepping leg stretched past \(f2(ExchangeLimits.swingStretch))")
    }

    /// A punch closes distance with a short step: over each attack windup (from the
    /// frame before it through the contact frame) neither the root nor the hips
    /// travel more than `windupTravel` horizontally, nor faster than `windupSpeed`.
    @discardableResult
    @MainActor static func windups(_ bout: Bout, report: Report, name: String) -> (travel: Float, speed: Float) {
        let samples = bout.samples
        func xz(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2(p.x, p.z) }
        var worst: [String: (travel: Float, speed: Float)] = [:]
        var over: [String] = []
        for f in 0..<2 {
            var i = 1
            while i < samples.count {
                guard samples[i].states[f].hasPrefix("attacking"), !samples[i - 1].states[f].hasPrefix("attacking") else { i += 1; continue }
                let start = i - 1
                var end = i
                while end + 1 < samples.count, samples[end + 1].states[f].hasPrefix("attacking") { end += 1 }
                let last = min(samples.count - 1, end + 1)
                let label = "\(f == 0 ? "hero" : "rival") \(samples[i].states[f].prefix { $0 != " " })"
                var travel: Float = 0, speed: Float = 0, at = start, travelBy = "root", speedBy = "root"
                let root = { (k: Int) in SIMD2<Float>(samples[k].roots[f].columns.3.x, samples[k].roots[f].columns.3.z) }
                let hips = { (k: Int) in xz(samples[k].joints[f][0]) }
                for (part, position) in [("root", root), ("hips", hips)] {
                    for k in (start + 1)...last {
                        let d = simd_distance(position(k), position(start))
                        if d > travel { travel = d; travelBy = part }
                        let v = simd_distance(position(k), position(k - 1))
                        if v > speed { speed = v; at = k; speedBy = part }
                    }
                }
                worst[label] = (max(worst[label]?.travel ?? 0, travel), max(worst[label]?.speed ?? 0, speed))
                if travel > ExchangeLimits.windupTravel || speed > ExchangeLimits.windupSpeed {
                    over.append("\(label) @\(start + 1)-\(last): travel \(f3(travel)) (\(travelBy)), peak \(f3(speed))/frame (\(speedBy)) at \(at - start)f")
                }
                i = end + 1
            }
        }
        report.log("\(name): attack windup root/hips travel (max, max per frame): "
                   + worst.keys.sorted().map { "\($0) \(f3(worst[$0]!.travel))/\(f3(worst[$0]!.speed))" }.joined(separator: ", "))
        for line in over { report.log("  WINDUP \(line)") }
        report.check(over.isEmpty, "\(name): \(over.count) attack windups travel over \(f2(ExchangeLimits.windupTravel)) or faster than \(f2(ExchangeLimits.windupSpeed))/frame")
        return (worst.values.map(\.travel).max() ?? 0, worst.values.map(\.speed).max() ?? 0)
    }

    /// The stance never goes wider than `stanceWidth` × the guard stance (idle frame 0)
    /// while the feet are planted.
    @discardableResult
    @MainActor static func stanceWidth(_ bout: Bout, report: Report, name: String) -> Float {
        let samples = bout.samples
        let guards: [Float] = [bout.hero, bout.rival].map { model in
            guard let idle = FighterReach.pose(model.motions, .idle, frame: 0) else { return 1 }
            let j = idle.joints(heads: model.rig.heads)
            return simd_distance(SIMD2(j[16].x, j[16].z), SIMD2(j[20].x, j[20].z)) * model.scale
        }
        var worst: [String: (Float, Int)] = [:]
        var episodes: [(fighter: Int, start: Int, end: Int, peak: Float, state: String)] = []
        var over = 0
        for (i, sample) in samples.enumerated() {
            for f in 0..<2 where sample.planted[f] {
                let j = sample.joints[f]
                let ratio = simd_distance(SIMD2(j[16].x, j[16].z), SIMD2(j[20].x, j[20].z)) / guards[f]
                let state = String(sample.states[f].prefix { $0 != " " })
                if ratio > worst[state]?.0 ?? 0 { worst[state] = (ratio, i) }
                guard ratio > ExchangeLimits.stanceWidth else { continue }
                over += 1
                if let last = episodes.lastIndex(where: { $0.fighter == f }), episodes[last].end >= i - 2 {
                    episodes[last].end = i
                    episodes[last].peak = max(episodes[last].peak, ratio)
                } else {
                    episodes.append((f, i, i, ratio, sample.states[f]))
                }
            }
        }
        report.log("\(name): stance width / guard stance (hero \(f3(guards[0])), rival \(f3(guards[1]))) max per state: "
                   + worst.keys.sorted().map { "\($0) \(f2(worst[$0]!.0))@\(worst[$0]!.1)" }.joined(separator: ", "))
        for e in episodes {
            report.log("  WIDE \(e.fighter == 0 ? "hero" : "rival") \(e.start)-\(e.end) peak \(f2(e.peak)) from \(e.state)")
        }
        report.check(over == 0, "\(name): \(over) fighter-frames with the stance wider than \(f2(ExchangeLimits.stanceWidth))× the guard stance")
        return worst.values.map(\.0).max() ?? 0
    }

    @MainActor static func footwork(_ bout: Bout, report: Report, name: String) {
        let samples = bout.samples
        guard samples.count > 2 else { return }
        var violations: [(Float, String)] = []
        var worstByState: [String: (Float, String)] = [:]
        var stepCount = 0, shortest = Int.max, slowestLanding: Float = 0
        func key(_ state: String) -> String { String(state.split(separator: " ").first ?? "") }
        for side in 0..<2 {
            let who = side == 0 ? "hero" : "rival"
            for toe in [FighterBone.leftToeBase.rawValue, FighterBone.rightToeBase.rawValue] {
                let heights = samples.indices.filter { samples[$0].planted[side] }.map { samples[$0].joints[side][toe].y }.sorted()
                let ground = heights.isEmpty ? 0 : heights[heights.count / 20]
                var run: (start: Int, lift: Float, speed: Float, at: Int)? = nil
                var runFrames: [(Int, Float, Float, Float)] = []
                func close(_ end: Int) {
                    guard let r = run else { return }
                    run = nil
                    let length = end - r.start
                    let step = r.lift >= 0.02 && length >= 6
                    if step {
                        stepCount += 1
                        shortest = min(shortest, length)
                        // Takeoff / landing: the toe must not slide while it is still (or again) on the canvas.
                        for (t, liftA, liftB, speed) in runFrames where liftA < 0.003 && liftB < 0.003 {
                            slowestLanding = max(slowestLanding, speed)
                            if speed > 0.02 {
                                violations.append((speed, "\(who) \(FighterSkeleton.names[toe]) frame \(t): slides \(f3(speed)) on the canvas inside a step (\(samples[t].states[side]))"))
                            }
                        }
                    } else if r.speed > 0.02 {
                        let what = r.lift >= 0.02 ? "\(length)-frame step (< 6)" : "grounded skate"
                        violations.append((r.speed, "\(who) \(FighterSkeleton.names[toe]) frames \(r.start)–\(end - 1): \(what), peak \(f3(r.speed))/frame at \(r.at) (\(samples[r.at].states[side]))"))
                    }
                    if !step {
                        for (t, _, _, speed) in runFrames {
                            let k = "\(who) \(key(samples[t].states[side]))"
                            if speed > (worstByState[k]?.0 ?? 0) { worstByState[k] = (speed, "frame \(t)") }
                        }
                    }
                    runFrames = []
                }
                for t in 1..<samples.count {
                    let a = samples[t - 1].joints[side][toe], b = samples[t].joints[side][toe]
                    guard samples[t].planted[side], samples[t - 1].planted[side] else {
                        run = nil
                        runFrames = []
                        continue
                    }
                    let speed = simd_length(SIMD2(b.x - a.x, b.z - a.z))
                    let liftA = a.y - ground, liftB = b.y - ground
                    if speed > 0.004 || liftB > 0.025 {
                        if run == nil { run = (t, 0, 0, t) }
                        run!.lift = max(run!.lift, liftA, liftB)
                        if speed > run!.speed { run!.speed = speed; run!.at = t }
                        runFrames.append((t, liftA, liftB, speed))
                    } else {
                        close(t)
                        let k = "\(who) \(key(samples[t].states[side]))"
                        if speed > (worstByState[k]?.0 ?? 0) { worstByState[k] = (speed, "frame \(t)") }
                    }
                }
                close(samples.count)
            }
        }
        report.log("\(name): footwork — \(stepCount) steps (shortest \(shortest == .max ? 0 : shortest) frames), worst takeoff/landing slide \(f3(slowestLanding)); max toe slide outside steps per state:")
        report.log("  " + worstByState.keys.sorted().map { "\($0) \(f3(worstByState[$0]!.0))" }.joined(separator: ", "))
        for item in violations.sorted(by: { $0.0 > $1.0 }).prefix(12) { report.log("  FOOT \(item.1)") }
        report.check(violations.isEmpty, "\(name): \(violations.count) foot slides / short steps (see FOOT lines)")
    }

    /// A foot let go for a fall or a get-up crossfades off its plant onto the clip's foot:
    /// in the frame it lands the toe covers at most `ExchangeLimits.releaseLanding` × the
    /// faster of the release's fastest earlier frame and the free foot's next frame (no
    /// last-frame snap), and no frame more than `ExchangeLimits.releasePeak` × that pace.
    @MainActor static func releaseSteps(_ bout: Bout, report: Report, name: String) {
        let samples = bout.samples
        guard samples.count > 2 else { return }
        var count = 0, worstLanding: Float = 0, worstPeak: Float = 0
        var violations: [(Float, String)] = []
        for side in 0..<2 {
            let who = side == 0 ? "hero" : "rival"
            for (foot, toe) in [FighterBone.leftToeBase.rawValue, FighterBone.rightToeBase.rawValue].enumerated() {
                func move(_ f: Int) -> Float {
                    let a = samples[f - 1].joints[side][toe], b = samples[f].joints[side][toe]
                    return simd_length(SIMD2(b.x - a.x, b.z - a.z))
                }
                var t = 1
                while t < samples.count {
                    guard samples[t].releases[side][foot] else { t += 1; continue }
                    let start = t
                    while t < samples.count, samples[t].releases[side][foot] { t += 1 }
                    // `t` is the frame the foot lands (the planter frees it that frame).
                    guard t + 1 < samples.count else { break }
                    let moves = (start...t).map(move), after = move(t + 1)
                    let total = moves.reduce(0, +)
                    guard moves.count >= 3, total >= ExchangeLimits.releaseMinTravel else { continue }
                    count += 1
                    let pace = max(moves.dropLast().max() ?? 0, after, 1e-4)
                    let landing = moves.last! / pace
                    let peak = moves.dropLast().max()! / max(1e-4, total / Float(moves.count))
                    worstLanding = max(worstLanding, landing)
                    worstPeak = max(worstPeak, peak)
                    if moves.last! > ExchangeLimits.releaseLandingFloor, landing > ExchangeLimits.releaseLanding || peak > ExchangeLimits.releasePeak {
                        violations.append((landing, "\(who) \(FighterSkeleton.names[toe]) frames \(start)–\(t) (\(samples[start].states[side])): "
                                           + "travel \(f3(total)), per frame \(moves.map(f3).joined(separator: " ")) | then \(f3(after)); "
                                           + "landing \(f2(landing))× the pace around it, peak \(f2(peak))× the mean"))
                    }
                }
            }
        }
        report.log("\(name): release steps — \(count) checked (landing frame ≤ \(f2(worstLanding))× the pace around it, fastest frame ≤ \(f2(worstPeak))× the mean)")
        for item in violations.sorted(by: { $0.0 > $1.0 }).prefix(8) { report.log("  RELEASE \(item.1)") }
        report.check(violations.isEmpty, "\(name): \(violations.count) release steps snap into their landing (see RELEASE lines)")
    }

    /// After contact the punching glove must come back toward guard (chest space)
    /// within 0.3 s, and the aim must let go within ~0.1 s.
    @MainActor static func retraction(_ bout: Bout, report: Report, name: String) {
        let samples = bout.samples
        var parts: [String] = []
        for hit in bout.hits {
            let model = hit.attacker == 0 ? bout.hero : bout.rival
            let heads = model.rig.heads
            func hand(_ i: Int) -> SIMD3<Float> {
                let pose = samples[i].poses[hit.attacker]
                return FighterReach.chest(pose, heads: heads).inverse.point(pose.joints(heads: heads)[hit.hand.rawValue])
            }
            guard let guardPoint = FighterReach.chestHand(model.motions, .idle, frame: 0, hand: hit.hand) else { continue }
            let travel = simd_distance(hand(hit.index), guardPoint)
            var back: Int?, released: Int?
            var interrupted = false
            for t in hit.index..<min(samples.count, hit.index + 60) {
                let state = samples[t].states[hit.attacker]
                if state.hasPrefix("knockedDown") || state.hasPrefix("ko") { interrupted = true }
                if back == nil, simd_distance(hand(t), guardPoint) <= AnimationTuning.retractedShare * travel { back = t - hit.index }
                if released == nil, samples[t].aims[hit.attacker] < 0.01 { released = t - hit.index }
            }
            let seconds = back.map { Float($0) / 60 }
            parts.append("\(hit.label) \(seconds.map { f2($0) + "s" } ?? "—") (aim off +\(released.map(String.init) ?? "—")f)")
            guard !interrupted else { continue }
            let limit: Float = hit.kind == "landed" || hit.kind == "blocked" ? 0.3 : 0.45
            report.check((seconds ?? 9) <= limit, "\(name): \(hit.label) glove takes \(seconds.map(f2) ?? "> 1") s to come back to guard (limit \(f2(limit)))")
            report.check((released ?? 99) <= 8, "\(name): \(hit.label) aim still on \(released ?? 99) frames after contact")
        }
        report.log("\(name): glove back within \(Int(AnimationTuning.retractedShare * 100))% of its travel after contact: " + parts.joined(separator: ", "))
    }

    /// The scripted bout every opponent fights.
    static let boutScript: [Bout.Intent] = [.takeHit(nil), .punch(.jab), .punch(.hook), .block, .punch(.uppercut), .dodge, .punchGuard,
                                            .parry, .takeHit(.uppercut), .knockdownRival, .heroKnockdown, .finishRival]

    @MainActor static func writeStrips(_ bout: Bout, prefix: String, out: URL) throws {
        for (name, shots) in bout.strips.sorted(by: { $0.key < $1.key }) {
            let file = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
                .replacingOccurrences(of: "--", with: "-")
            try writeSheet(shots.map { ($0.image, $0.label) }, columns: min(8, shots.count), cell: CGSize(width: 240, height: 320),
                           title: "Filmstrip: \(name) (side camera)", to: out.appendingPathComponent("\(prefix)\(file).png"))
        }
    }

    /// Every frame of the hero's chained punches, from the first windup to 20 frames after the last contact.
    @MainActor static func renderCombo(_ bout: Bout, out: URL, report: Report) throws {
        let samples = bout.samples
        let punches = bout.hits.filter { $0.attacker == 0 }
        guard let start = bout.comboStart, let last = punches.last else {
            report.check(false, "combo: the chain was thrown")
            return
        }
        let anchor = punches.dropFirst().first?.index ?? last.index
        report.log("combo: " + punches.map { "\($0.move.rawValue) \($0.kind) @\($0.index)" }.joined(separator: ", "))
        let range = max(0, start - 6)...min(samples.count - 1, last.index + 20)
        let size = CGSize(width: 200, height: 270)
        let contacts = Dictionary(punches.map { ($0.index, $0.move.rawValue) }, uniquingKeysWith: { a, _ in a })
        let cells = range.map { i in
            (bout.render(i, view: .side, anchor: anchor, size: size),
             "\(i - start >= 0 ? "+" : "")\(i - start)f \(samples[i].states[0])\(contacts[i].map { " · \($0) contact" } ?? "")")
        }
        try writeSheet(cells, columns: 10, cell: size,
                       title: "Every frame, +0f = jab pressed: hero jab → hook → uppercut chain (side camera fixed at the hook's contact)",
                       to: out.appendingPathComponent("dense-hero-combo.png"))
    }

    /// Dense per-frame filmstrips (0.6 s around contact) of each punch, and top-down +
    /// front (orthographic) exchanges, re-rendered from the recorded bout.
    @MainActor static func renderHistory(_ bout: Bout, out: URL) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let samples = bout.samples
        for (attacker, who) in [(0, "hero"), (1, "rival")] {
            for move in [Move.jab, .hook, .uppercut] {
                let candidates = bout.hits.filter { $0.attacker == attacker && $0.move == move }
                guard let hit = candidates.first(where: { $0.kind == "landed" }) ?? candidates.first(where: { $0.kind == "blocked" }) ?? candidates.first
                else { continue }
                let range = max(0, hit.index - 12)...min(samples.count - 1, hit.index + 23)
                let size = CGSize(width: 200, height: 270)
                let cells = range.map { i in
                    (bout.render(i, view: .side, anchor: hit.index, size: size), "\(i - hit.index >= 0 ? "+" : "")\(i - hit.index)f \(samples[i].states[attacker])")
                }
                try writeSheet(cells, columns: 9, cell: size, title: "Every frame, contact = +0f: \(hit.label) (side camera fixed at contact)",
                               to: out.appendingPathComponent("dense-\(who)-\(move.rawValue).png"))
            }
        }
        var zoom: [(NSImage, String)] = []
        for hit in bout.hits where hit.kind == "landed" || hit.kind == "blocked" {
            let size = CGSize(width: 260, height: 260)
            for (view, name) in [(Bout.View.zoomTop, "top"), (.zoomFront, "front"), (.zoomEnd, "behind defender")] {
                zoom.append((bout.render(hit.index, view: view, anchor: hit.index, size: size), "\(hit.label) — \(name)"))
            }
        }
        try writeSheet(zoom, columns: 6, cell: CGSize(width: 260, height: 260),
                       title: "Glove on head at contact (orthographic, 1.0 unit tall, centered on the defender's head)",
                       to: out.appendingPathComponent("contact-zoom.png"))
        var clashes: [(NSImage, String)] = []
        for (name, worst) in [("glove in glove", bout.gloveClashIndex), ("glove in head", bout.headClashIndex)] {
            guard let worst else { continue }
            let size = CGSize(width: 220, height: 220)
            for i in (worst.sample - 3)...(worst.sample + 3) where samples.indices.contains(i) {
                for view in [Bout.View.zoomTop, .zoomFront] {
                    clashes.append((bout.render(i, view: view, anchor: worst.sample, size: size, focus: worst.defender),
                                    "\(name) \(i - worst.sample >= 0 ? "+" : "")\(i - worst.sample)f \(view == .zoomTop ? "top" : "front")"))
                }
            }
        }
        if !clashes.isEmpty {
            try writeSheet(clashes, columns: 14, cell: CGSize(width: 220, height: 220),
                           title: "Deepest glove clashes (±3 frames; top / front, 1.0 unit, centered on the struck fighter's head)",
                           to: out.appendingPathComponent("clashes.png"))
        }
        var exchanges: [(String, Int)] = []
        func pick(_ name: String, _ match: (Bout.Hit) -> Bool) {
            if let hit = bout.hits.first(where: match) { exchanges.append((name, hit.index)) }
        }
        pick("hero-jab-landed") { $0.attacker == 0 && $0.move == .jab && $0.kind == "landed" }
        pick("rival-hook-landed") { $0.attacker == 1 && $0.move == .hook && $0.kind == "landed" }
        pick("rival-uppercut-landed") { $0.attacker == 1 && $0.move == .uppercut && $0.kind == "landed" }
        pick("hero-hook-counter") { $0.attacker == 0 && $0.move == .hook && $0.label.contains("counter") }
        exchanges.append(("closest-bodies", bout.bodyOverlapIndex))
        // A trade: the struck fighter punches straight back (every frame).
        if let hit = bout.hits.first(where: { $0.kind == "landed" && bout.trades($0) }) { exchanges.append(("trade", hit.index)) }
        for (name, index) in exchanges {
            let indices = (name == "trade" ? Array(index - 4...index + 9) : Array(stride(from: index - 9, through: index + 12, by: 3)))
                .filter { samples.indices.contains($0) }
            let size = CGSize(width: 300, height: 260)
            let top = indices.map { (bout.render($0, view: .top, anchor: index, size: size), "top \($0 - index >= 0 ? "+" : "")\($0 - index)f") }
            let front = indices.map { (bout.render($0, view: .front, anchor: index, size: size), "front \($0 - index >= 0 ? "+" : "")\($0 - index)f") }
            try writeSheet(top + front, columns: indices.count, cell: size,
                           title: "\(name) (+0f = contact / closest): top-down (hero left) and front elevation, orthographic, 0.5-unit grid",
                           to: out.appendingPathComponent("exchange-\(name).png"))
        }
    }
}
