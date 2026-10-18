import SceneKit
import HaymakerKit

/// One fighter on screen: a skinned HMR2 rig driven by retargeted mocap clips.
/// The director maps engine state to clip motions; the animator crossfades and
/// layers them; this class writes the pose onto SceneKit bone nodes.
@MainActor final class BoxerModel {
    let root = SCNNode()
    let asset: FighterModelAsset
    let isRival: Bool
    let rig: FighterRigData
    let motions: FighterMotionSet
    let animator: FighterAnimator
    let director: FighterDirector
    /// Uniform scale of `root` (presentation size of the fighter).
    let scale: Float
    private let bones: [SCNNode]
    private var titleTime: Double?
    /// The director's most recent motion (diagnostics and QA captions).
    private(set) var lastMotion: Motion?
    /// The animator's pose this frame, before aim and floor contact.
    private(set) var animated: FighterPose
    /// What is on screen: the animated pose steered onto the target and kept above the floor.
    private(set) var pose: FighterPose
    /// Rig-space head (center, radius) in the idle guard: where opponents aim.
    let nominalHead: (center: SIMD3<Float>, radius: Float)
    /// Per punch: the punching arm at `contact`, in chest (Spine2) space.
    let aimReferences: [ClipID: AimReference]
    /// Rotation (radians) the last aim correction asked for, before weighting and clamping (QA).
    private(set) var lastAimDemand: Float = 0
    /// Keeps grounded feet planted and turns body travel into steps.
    private(set) var planter = FootPlanter()
    /// Canvas-space Hips (XZ) last frame, where the current windup started, and how
    /// far the shown Hips trail the animated ones (see `AnimationTuning.windupHipsPace`).
    private var hipsPace = HipsPace()
    private struct HipsPace {
        var last: SIMD2<Float>?
        var origin: SIMD2<Float>?
        var lag = SIMD2<Float>.zero
        /// The lag at contact and the time since, while it is made up.
        var release: (lag: SIMD2<Float>, age: Float)?
    }

    /// The punching arm at `contact` in the raw clip, in one frame of reference
    /// (chest space for steering, rig space for spacing).
    struct AimReference {
        let hand: FighterBone
        let arm: Int
        /// The clavicle (Shoulder bone) and its joint.
        var clavicle: Int { FighterSkeleton.parents[arm] }
        var forearm: Int { arm + 1 }
        let clavicleJoint: SIMD3<Float>
        let shoulder: SIMD3<Float>
        let elbow: SIMD3<Float>
        let glove: SIMD3<Float>
        let gloveRadius: Float
        /// Extreme skin points of the glove at `contact`, relative to `glove`: a glove
        /// is longer than it is wide, so contact uses its extent toward the target.
        let gloveProbes: [SIMD3<Float>]

        func extent(toward direction: SIMD3<Float>, turned rotation: simd_quatf) -> Float {
            gloveProbes.reduce(gloveRadius) { max($0, simd_dot(rotation.act($1), direction)) }
        }

        /// Re-expressed from chest space into the space of `chest` (e.g. rig space).
        func placed(in chest: FighterReach.Frame) -> AimReference {
            AimReference(hand: hand, arm: arm, clavicleJoint: chest.point(clavicleJoint), shoulder: chest.point(shoulder),
                         elbow: chest.point(elbow), glove: chest.point(glove), gloveRadius: gloveRadius, gloveProbes: gloveProbes.map { chest.rotation.act($0) })
        }
    }

    /// Where a punch is aimed, in the attacker's rig space.
    struct AimTarget {
        var center: SIMD3<Float>
        var radius: Float
    }

    /// An open guard glove swinging out of an incoming hook's path (`weight` 0…1).
    struct GuardGive {
        var arm: FighterBone
        var weight: Float
    }


    convenience init(isRival: Bool) {
        self.init(asset: isRival ? .bruiser : .mack, isRival: isRival)
    }

    init(asset: FighterModelAsset, isRival: Bool) {
        self.asset = asset
        self.isRival = isRival
        let nodes = FighterRigNodes.load(asset)
        rig = nodes.data
        bones = nodes.bones
        motions = FighterMotionSet.shared(for: nodes.data)
        if motions.clips.isEmpty { fighterLog.error("No animation clips for \(asset.rawValue, privacy: .public); holding rest pose") }
        animator = FighterAnimator(motions: motions)
        director = FighterDirector(motions: motions)
        // Different tempo and phase keep the two idles from bouncing in step.
        director.idleRate = isRival ? 0.93 : 1
        director.idlePhase = isRival ? 0.47 : 0
        // Near-equal statures so punches can physically land on the head; the rival is a touch bigger.
        scale = isRival ? 1.05 : 1.0
        root.name = asset.rawValue
        root.addChildNode(nodes.skeleton)
        root.addChildNode(nodes.mesh)
        root.simdScale = SIMD3<Float>(repeating: scale)
        // Heavy-trapped builds fold their neck skin on big head snaps.
        animator.neckFlex = asset == .atlas ? 0.6 : 0.75
        animated = animator.pose
        pose = animator.pose
        nominalHead = FighterReach.pose(motions, .idle, frame: 0).map { FighterReach.blob(FighterBone.head.rawValue, pose: $0, rig: nodes.data) }
            ?? (nodes.data.heads[FighterBone.head.rawValue], 0.3)
        var references: [ClipID: AimReference] = [:]
        for id in [ClipID.jab, .hook, .uppercut] {
            guard let clip = motions[id], let contact = FighterReach.pose(motions, id, frame: clip.marker("contact", clip.lastFrame)) else { continue }
            let hand = FighterReach.punchingHand(motions, clip: id)
            let arm = hand == .leftHand ? FighterBone.leftArm.rawValue : FighterBone.rightArm.rawValue
            let glove = FighterReach.blob(hand.rawValue, pose: contact, rig: nodes.data)
            let joints = contact.joints(heads: nodes.data.heads), globals = contact.globals()
            let chest = FighterReach.chest(contact, heads: nodes.data.heads).inverse
            let probes = nodes.data.blobs[hand.rawValue].probes.map { chest.rotation.act(joints[hand.rawValue] + globals[hand.rawValue].act($0) - glove.center) }
            references[id] = AimReference(hand: hand, arm: arm, clavicleJoint: chest.point(joints[FighterSkeleton.parents[arm]]),
                                          shoulder: chest.point(joints[arm]), elbow: chest.point(joints[arm + 1]),
                                          glove: chest.point(glove.center), gloveRadius: glove.radius,
                                          gloveProbes: probes)
        }
        aimReferences = references
        finish(aimAt: nil)
    }

    /// The punch at `contact` in rig space with the lower body at `lower` (a fast
    /// punch's step has not landed yet): what the spacing is solved against.
    func spacingReference(_ id: ClipID, lower: Float?) -> AimReference? {
        guard let reference = aimReferences[id], let clip = motions[id],
              var pose = FighterReach.pose(motions, id, frame: clip.marker("contact", clip.lastFrame)) else { return nil }
        if let lower, let legs = FighterReach.pose(motions, id, frame: lower) { FighterAnimator.mergeLower(&pose, legs) }
        FighterAnimator.dampTravel(&pose, clip: clip)
        return reference.placed(in: FighterReach.chest(pose, heads: rig.heads))
    }

    func resetMotion() {
        director.reset()
        animator.reset()
        planter.reset()
        hipsPace = HipsPace()
        titleTime = nil
    }

    /// Advance one presentation frame from the fighter's engine status.
    func update(_ status: FighterStatus, totalTicks: Int, tickFraction: Double, now: Double, dt: Double,
                reducedMotion: Bool, cue: FighterCue = .none) {
        let motion = director.update(.init(status: status, totalTicks: totalTicks, tickFraction: tickFraction, now: now, dt: dt,
                                           reducedMotion: reducedMotion, cue: cue))
        if director.enteredAction { animator.releaseReactions() }
        lastMotion = motion
        animated = animator.update(motion, dt: Float(dt), now: now, reducedMotion: reducedMotion)
        finish(aimAt: nil)
    }

    /// Title screen shadowboxing: the `warmup` loop (a still guard under Reduced Motion).
    func poseTitle(time: Double, reducedMotion: Bool) {
        let dt = titleTime.map { min(0.1, max(0, time - $0)) } ?? 0
        titleTime = time
        guard let clip = motions[.warmup] ?? motions[.idle] else { return }
        let frame = reducedMotion ? 0 : Float(time.truncatingRemainder(dividingBy: 3_600)) * clip.fps
        let motion = Motion(clip: clip.id, frame: frame, rate: reducedMotion ? 0 : clip.fps, key: -1, fade: 0.3)
        animated = animator.update(motion, dt: Float(dt), now: time, reducedMotion: reducedMotion)
        finish(aimAt: nil)
    }

    /// Steer the punching arm onto `target` (scaled by the director's aim weight),
    /// keep the body above the floor, plant the feet (`plantFeet`: the frame's dt,
    /// once the root is placed) and write the pose to the bones. Called after
    /// `update` once both fighters are placed.
    func finish(aimAt target: AimTarget?, plantFeet dt: Float? = nil, guardGive give: GuardGive? = nil) {
        var out = animated
        lastAimDemand = 0
        if let dt { paceHips(&out, dt: dt) }
        if let give, give.weight > 0.001 {
            // Swing the upper arm outward about the chest's vertical axis: the glove
            // opens off the front of the face, where the hook lands.
            let r = FighterReach.chest(out, heads: rig.heads).rotation
            let outward: Float = give.arm == .leftArm ? 1 : -1
            let swing = simd_quatf(angle: AnimationTuning.guardGive * outward * give.weight, axis: SIMD3<Float>(0, 1, 0))
            Self.steer(&out, bone: give.arm.rawValue, by: r * swing * r.inverse)
        }
        if let target, director.aim > 0.001, let reference = aimReferences[director.aimClip] {
            // Solved in chest space: the arm follows the clip relative to the torso,
            // whatever the hips, lower body or a hit reaction are doing.
            let chest = FighterReach.chest(out, heads: rig.heads)
            let local = AimTarget(center: chest.inverse.point(target.center), radius: target.radius)
            let aim = Self.aimCorrection(reference, target: local)
            lastAimDemand = aim.demand
            let r = chest.rotation
            Self.steer(&out, bone: reference.clavicle, by: r * scaled(aim.clavicle, director.aim) * r.inverse)
            Self.steer(&out, bone: reference.forearm, by: r * scaled(aim.forearm, director.aim) * r.inverse)
            Self.steer(&out, bone: reference.arm, by: r * scaled(aim.arm, director.aim) * r.inverse)
        }
        // Lift the body if any part of the skin would dip below the canvas.
        let joints = out.joints(heads: rig.heads), globals = out.globals()
        var lowest = Float.infinity
        for bone in 0..<FighterSkeleton.boneCount {
            for probe in rig.blobs[bone].probes { lowest = min(lowest, joints[bone].y + globals[bone].act(probe).y) }
        }
        if lowest < 0 { out.hips.y -= lowest }
        if let dt {
            planter.solve(&out, heads: rig.heads, toStage: root.simdTransform, enabled: director.feetPlanted, dt: dt,
                          guardSpread: animator.guardSpread)
        }
        pose = out
        apply(out)
    }

    /// A punch's windup moves the body on the canvas no faster (and no farther) than
    /// a step, through the frame the glove lands; the lag it builds is made up
    /// smoothly as the punch recovers.
    private func paceHips(_ pose: inout FighterPose, dt: Float) {
        let toStage = root.simdTransform
        let placed = toStage * SIMD4<Float>(pose.hips, 1)
        let target = SIMD2<Float>(placed.x, placed.z)
        var shown = target
        let winding = director.windingUp, landing = !winding && hipsPace.origin != nil
        if winding || landing {
            let origin = hipsPace.origin ?? hipsPace.last ?? target
            hipsPace.origin = landing ? nil : origin
            hipsPace.release = nil
            if let last = hipsPace.last {
                let move = shown - last, length = simd_length(move), pace = AnimationTuning.windupHipsPace * dt * 60
                if length > pace { shown = last + move * (pace / length) }
            }
            let travel = shown - origin, distance = simd_length(travel)
            if distance > AnimationTuning.windupHipsTravel { shown = origin + travel * (AnimationTuning.windupHipsTravel / distance) }
            hipsPace.lag = target - shown
        } else if simd_length_squared(hipsPace.lag) > 0 {
            var release = hipsPace.release ?? (hipsPace.lag, 0)
            release.age += dt
            let left = 1 - smoothstep(release.age / AnimationTuning.hipsLagRelease)
            hipsPace.lag = left > 0 ? release.lag * left : .zero
            hipsPace.release = left > 0 ? release : nil
            shown = target - hipsPace.lag
        }
        hipsPace.last = shown
        guard simd_length_squared(shown - target) > 1e-12 else { return }
        let local = toStage.inverse * SIMD4<Float>(shown.x, placed.y, shown.y, 1)
        pose.hips.x = local.x
        pose.hips.z = local.z
    }

    /// Rotate a bone about its joint by a rig-space rotation.
    static func steer(_ pose: inout FighterPose, bone: Int, by rotation: simd_quatf) {
        let parentGlobal = pose.globals()[FighterSkeleton.parents[bone]]
        pose.rotations[bone] = simd_normalize(parentGlobal.inverse * rotation * parentGlobal * pose.rotations[bone])
    }

    /// Steer a punch onto its target: the clavicle takes a share as a reach-and-shrug,
    /// the elbow flexes if the target is closer than the punch reaches (the glove
    /// stops on its surface instead of sinking in), then the smallest rotation about
    /// the shoulder brings the glove onto the target at `contact` (a little bite into
    /// it), clamped so the punch keeps its line. `demand` is the arm-only steer the
    /// mocap would have needed; `armDemand` what the arm still needs after the
    /// clavicle's share and the elbow (before clamping).
    static func aimCorrection(_ reference: AimReference, target: AimTarget)
        -> (clavicle: simd_quatf, forearm: simd_quatf, arm: simd_quatf, demand: Float, armDemand: Float, reachable: Bool) {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let direct = armCorrection(shoulder: reference.shoulder, glove: reference.glove,
                                   radius: reference.extent(toward: simd_normalize(target.center - reference.glove), turned: identity), target: target)
        var clavicle = identity
        if direct.demand > 1e-4 {
            let arc = shortestArc(from: simd_normalize(reference.shoulder - reference.clavicleJoint),
                                  to: simd_normalize(target.center - reference.clavicleJoint))
            let share = min(AnimationTuning.maxClavicleAim, direct.demand * AnimationTuning.clavicleAimShare, arc.angle)
            if arc.angle > 1e-4 { clavicle = simd_quatf(angle: share, axis: arc.axis) }
        }
        let pivot = reference.clavicleJoint
        let shoulder = pivot + clavicle.act(reference.shoulder - pivot)
        let elbow = pivot + clavicle.act(reference.elbow - pivot)
        var glove = pivot + clavicle.act(reference.glove - pivot)
        let forearm = elbowFlex(shoulder: shoulder, elbow: elbow, glove: glove, turned: clavicle, reference: reference, target: target)
        glove = elbow + forearm.act(glove - elbow)
        let turned = forearm * clavicle
        let arm = armCorrection(shoulder: shoulder, glove: glove,
                                radius: reference.extent(toward: simd_normalize(target.center - glove), turned: turned), target: target)
        return (clavicle, forearm, arm.rotation, direct.demand, arm.demand, arm.reachable)
    }

    /// Elbow flex (rotation about the elbow) that pulls a glove which would sink
    /// into the target back onto its surface along the punch line: a punch landing
    /// before full extension. Identity when the glove does not reach the target.
    private static func elbowFlex(shoulder: SIMD3<Float>, elbow: SIMD3<Float>, glove: SIMD3<Float>, turned: simd_quatf,
                                  reference: AimReference, target: AimTarget) -> simd_quatf {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let upper = simd_distance(elbow, shoulder), lower = simd_distance(glove, elbow)
        guard upper > 1e-4, lower > 1e-4 else { return identity }
        var axis = simd_cross(glove - elbow, shoulder - elbow)
        // A straight arm has no bend plane yet: flex upward (the elbow drops under it).
        let straight = simd_length(axis) < 0.08 * upper * lower
        if straight { axis = simd_cross(glove - elbow, SIMD3<Float>(0, 1, 0)) }
        guard simd_length(axis) > 1e-6 else { return identity }
        axis = simd_normalize(axis)
        func interior(_ length: Float) -> Float {
            acos(min(1, max(-1, (upper * upper + lower * lower - length * length) / (2 * upper * lower))))
        }
        var bend: Float = 0, current = glove
        for _ in 0..<3 {
            let reach = simd_distance(current, shoulder)
            guard reach > 1e-4 else { break }
            let direction = (current - shoulder) / reach, toCenter = target.center - shoulder
            let radius = reference.extent(toward: simd_normalize(target.center - current),
                                          turned: simd_quatf(angle: bend, axis: axis) * turned)
            let touch = max(0.01, radius + target.radius - AnimationTuning.aimBite)
            let along = simd_dot(direction, toCenter)
            let disc = along * along - simd_length_squared(toCenter) + touch * touch
            guard disc > 0 else { break }
            let wanted = max(abs(upper - lower) + 0.02, along - disc.squareRoot())
            guard wanted < reach - 1e-3 else { break }
            bend = min(AnimationTuning.maxElbowFlex, bend + interior(reach) - interior(wanted))
            current = elbow + simd_quatf(angle: bend, axis: axis).act(glove - elbow)
        }
        if bend == 0, !straight {
            // A bent-arm punch (uppercut, hook) a little short of the target opens the
            // elbow to reach it; the shoulder steer then lines the glove up.
            let reach = simd_distance(glove, shoulder)
            let radius = reference.extent(toward: simd_normalize(target.center - glove), turned: turned)
            let touch = max(0.01, radius + target.radius - AnimationTuning.aimBite)
            let wanted = min(upper + lower - 0.03, simd_distance(target.center, shoulder) - touch)
            if wanted > reach + 1e-3 { bend = -min(AnimationTuning.maxElbowExtension, interior(wanted) - interior(reach)) }
        }
        return abs(bend) > 1e-4 ? simd_quatf(angle: bend, axis: axis) : identity
    }

    private static func armCorrection(shoulder: SIMD3<Float>, glove: SIMD3<Float>, radius: Float, target: AimTarget)
        -> (rotation: simd_quatf, demand: Float, reachable: Bool) {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let arm = glove - shoulder, toTarget = target.center - shoulder
        let length = simd_length(arm), distance = simd_length(toTarget)
        guard length > 1e-4, distance > 1e-4 else { return (identity, 0, false) }
        let u = arm / length, v = toTarget / distance
        let between = acos(min(1, max(-1, simd_dot(u, v))))
        let touch = max(0.01, radius + target.radius - AnimationTuning.aimBite)
        let slack = (length * length + distance * distance - touch * touch) / (2 * length * distance)
        let allowed = slack >= 1 ? 0 : (slack <= -1 ? Float.pi : acos(slack))
        let reachable = abs(distance - length) < touch
        let demand = max(0, between - allowed)
        guard demand > 1e-4 else { return (identity, 0, reachable) }
        let axis = simd_cross(u, v)
        guard simd_length(axis) > 1e-5 else { return (identity, demand, reachable) }
        return (simd_quatf(angle: min(demand, AnimationTuning.maxAim), axis: simd_normalize(axis)), demand, reachable)
    }

    func react(_ clip: ClipID, weight: Float, rate: Float, mask: ReactionMask = .full) {
        animator.react(clip, weight: weight, rate: rate, mask: mask)
    }

    func apply(_ pose: FighterPose) {
        bones[0].simdPosition = pose.hips
        for bone in 0..<FighterSkeleton.boneCount { bones[bone].simdOrientation = pose.rotations[bone] }
    }

    // MARK: - Measurements (rig space → parent/stage space)

    /// Posed blob (center, radius) of a bone in rig space.
    func blob(_ bone: FighterBone, in pose: FighterPose? = nil) -> (center: SIMD3<Float>, radius: Float) {
        FighterReach.blob(bone.rawValue, pose: pose ?? self.pose, rig: rig)
    }

    /// Stage-space point to this fighter's rig space.
    func local(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let p = root.simdTransform.inverse * SIMD4<Float>(point, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    /// Rig-space point to the root's parent space (the stage).
    func placed(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let p = root.simdTransform * SIMD4<Float>(point, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }
}

/// Reach and contact measurements shared by the choreographer and the QA harness.
enum FighterReach {
    /// A rigid frame (origin + rotation): `point` maps its local coordinates out.
    struct Frame {
        var origin: SIMD3<Float>
        var rotation: simd_quatf

        func point(_ p: SIMD3<Float>) -> SIMD3<Float> { origin + rotation.act(p) }
        var inverse: Frame { Frame(origin: rotation.inverse.act(-origin), rotation: rotation.inverse) }
    }

    /// The chest (Spine2) frame of a pose, in rig space.
    static func chest(_ pose: FighterPose, heads: [SIMD3<Float>]) -> Frame {
        let bone = FighterBone.spine2.rawValue
        return Frame(origin: pose.joints(heads: heads)[bone], rotation: pose.globals()[bone])
    }

    /// A hand joint in chest space at `frame` of a clip.
    static func chestHand(_ motions: FighterMotionSet, _ id: ClipID, frame: Float, hand: FighterBone) -> SIMD3<Float>? {
        guard let pose = pose(motions, id, frame: frame) else { return nil }
        return chest(pose, heads: motions.heads).inverse.point(pose.joints(heads: motions.heads)[hand.rawValue])
    }

    /// First frame after `contact` where the punching glove is back within
    /// `retractedShare` of its travel from the clip's opening guard (chest space).
    static func retractedFrame(_ motions: FighterMotionSet, clip id: ClipID) -> Float? {
        guard let clip = motions[id] else { return nil }
        let hand = punchingHand(motions, clip: id)
        let contact = clip.marker("contact", clip.lastFrame * 0.4), recovered = clip.marker("recovered", clip.lastFrame)
        guard let start = chestHand(motions, id, frame: 0, hand: hand),
              let out = chestHand(motions, id, frame: contact, hand: hand) else { return nil }
        let travel = simd_distance(out, start)
        var frame = contact
        while frame < recovered {
            frame += 0.25
            if let p = chestHand(motions, id, frame: frame, hand: hand),
               simd_distance(p, start) <= AnimationTuning.retractedShare * travel { return frame }
        }
        return recovered
    }
    /// A bone's extreme skin points as posed, relative to `center`.
    static func probes(_ bone: Int, pose: FighterPose, rig: FighterRigData, around center: SIMD3<Float>) -> [SIMD3<Float>] {
        let joint = pose.joints(heads: rig.heads)[bone], turn = pose.globals()[bone]
        return rig.blobs[bone].probes.map { joint + turn.act($0) - center }
    }

    /// Support distance of a part toward `direction` from its extreme points (never
    /// much under its blob radius, as 14 probes undersample in between).
    static func support(_ probes: [SIMD3<Float>], radius: Float, _ direction: SIMD3<Float>) -> Float {
        probes.reduce(radius * 0.8) { max($0, simd_dot($1, direction)) }
    }

    static func blob(_ bone: Int, pose: FighterPose, rig: FighterRigData) -> (center: SIMD3<Float>, radius: Float) {
        let joints = pose.joints(heads: rig.heads)
        let globals = pose.globals()
        let blob = rig.blobs[bone]
        return (joints[bone] + globals[bone].act(blob.offset), blob.radius)
    }

    static func pose(_ motions: FighterMotionSet, _ clip: ClipID, frame: Float) -> FighterPose? {
        guard let clip = motions[clip] else { return nil }
        var pose = FighterPose(hips: motions.heads[0])
        clip.sample(frame, into: &pose)
        return pose
    }

    /// The glove that travels most (relative to the chest) from `chamber` to `contact`.
    static func punchingHand(_ motions: FighterMotionSet, clip id: ClipID) -> FighterBone {
        guard let clip = motions[id] else { return .leftHand }
        let chamber = clip.marker("chamber", 0), contact = clip.marker("contact", clip.lastFrame)
        func travel(_ hand: FighterBone) -> Float {
            guard let a = chestHand(motions, id, frame: chamber, hand: hand),
                  let b = chestHand(motions, id, frame: contact, hand: hand) else { return 0 }
            return simd_distance(a, b)
        }
        return travel(.leftHand) >= travel(.rightHand) ? .leftHand : .rightHand
    }

    /// Center-to-center separation along the fight axis at which a blob of fighter A
    /// (rig space, scale sA) just touches a blob of B (facing A, scale sB), less `bite`.
    static func separation(_ a: (center: SIMD3<Float>, radius: Float), scaleA sA: Float,
                           _ b: (center: SIMD3<Float>, radius: Float), scaleB sB: Float, bite: Float = 0) -> Float {
        // B faces A: its +X and +Z map to A's −X and −Z.
        let lateral = sA * a.center.x + sB * b.center.x
        let vertical = sB * b.center.y - sA * a.center.y
        let reach = max(0, sA * a.radius + sB * b.radius - bite)
        return sA * a.center.z + sB * b.center.z + sqrt(max(0, reach * reach - lateral * lateral - vertical * vertical))
    }
}
