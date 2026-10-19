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
    private var victoryTime: Double?
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
    /// How far the last frame's pacing and floor lift moved the Hips off the animated ones
    /// (rig space): the shown body is still about that far off its clip this frame.
    private(set) var hipsShift = SIMD3<Float>.zero
    /// The other fighter's gloves and head last frame (stage space), for `yieldGloves`.
    private var yieldTrack: [SIMD3<Float>] = []
    /// Each glove's current give (chest space).
    private var yieldShift: [(shift: SIMD3<Float>, step: SIMD3<Float>, elbow: SIMD3<Float>, elbowStep: SIMD3<Float>)] =
        [(.zero, .zero, .zero, .zero), (.zero, .zero, .zero, .zero)]
    /// Each glove's and elbow's stage position as shown the last two frames.
    private var yieldMotion: [(before: [SIMD3<Float>]?, last: [SIMD3<Float>]?)] = [(nil, nil), (nil, nil)]
    /// A landed blow's head travel, made good whatever the fighter starts doing (see `braceForBlow`).
    private var brace: Brace?
    private struct Brace {
        /// Stage-space head (blob center) the frame before contact, and the blow's direction (stage, horizontal).
        let anchor: SIMD3<Float>
        let push: SIMD3<Float>
        /// Frames since contact, and the extra lean (radians) shown.
        var frames = 0
        var angle: Float = 0
    }
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
        /// The head's skin as posed now (where the target is a head): a glove only
        /// stops short of the blob once it reaches the skin too.
        var skin: Skin? = nil
        /// Thrown at the air where a head would be (a slipped or downed opponent): there
        /// is no surface for the glove to stop on.
        var air = false
    }

    /// A part's skin placed in another fighter's frame of reference.
    struct Skin {
        var center: SIMD3<Float>
        var rotation: simd_quatf
        var scale: Float
        let blob: BoneBlob
        /// How far off the skin a glove still has to stay (a blow's lead before contact).
        var standoff: Float = 0

        func depth(of point: SIMD3<Float>) -> Float {
            blob.depth(of: rotation.inverse.act(point - center) / scale) * scale
        }

        func placed(in frame: FighterReach.Frame) -> Skin {
            Skin(center: frame.inverse.point(center), rotation: simd_normalize(frame.inverse.rotation * rotation), scale: scale, blob: blob,
                 standoff: standoff)
        }
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
        hipsShift = .zero
        brace = nil
        yieldTrack = []
        yieldShift = [(.zero, .zero, .zero, .zero), (.zero, .zero, .zero, .zero)]
        yieldMotion = [(nil, nil), (nil, nil)]
        titleTime = nil
        victoryTime = nil
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

    /// The victory clip starts and ends in guard, so it can repeat throughout the finale.
    func poseVictory(time: Double, reducedMotion: Bool) {
        let dt = victoryTime.map { min(0.1, max(0, time - $0)) } ?? 0
        victoryTime = time
        guard let clip = motions[.victory] else { return }
        let duration = Double(max(1, clip.lastFrame) / clip.fps)
        let frame = reducedMotion ? clip.marker("armsUp", 0) : Float(time.truncatingRemainder(dividingBy: duration)) * clip.fps
        let motion = Motion(clip: .victory, frame: frame, rate: reducedMotion ? 0 : clip.fps, key: -2, fade: AnimationTuning.victoryFade)
        lastMotion = motion
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
        if let dt {
            paceHips(&out, dt: dt)
            braceHead(&out, dt: dt)
        }
        let giving = give.map { give -> Float in
            // A glove this fighter is punching with comes back up as its punch aims.
            let hand: FighterBone = give.arm == .leftArm ? .leftHand : .rightHand
            return aimReferences[director.aimClip]?.hand == hand ? give.weight * (1 - director.aim) : give.weight
        } ?? 0
        if let give, giving > 0.001 {
            // The glove drops and opens a little off the front of the face, where the
            // hook lands, and out of the arc it sweeps in on: the hand that let it in.
            let chest = FighterReach.chest(out, heads: rig.heads), r = chest.rotation
            let outward: Float = give.arm == .leftArm ? 1 : -1
            let arm = liveArm(give.arm == .leftArm ? .leftHand : .rightHand, pose: out, chest: chest)
            let drop = SIMD3<Float>(outward * AnimationTuning.guardOpen, -AnimationTuning.guardDrop, 0) * giving
            if let solve = Self.reach(arm, to: arm.glove + drop) {
                Self.steer(&out, bone: arm.forearm, by: r * solve.forearm * r.inverse)
                Self.steer(&out, bone: arm.arm, by: r * solve.arm * r.inverse)
            }
        }
        if let target, director.aim > 0.001, let reference = aimReferences[director.aimClip] {
            // Solved in chest space: the arm follows the clip relative to the torso,
            // whatever the hips, lower body or a hit reaction are doing.
            let chest = FighterReach.chest(out, heads: rig.heads)
            let local = AimTarget(center: steeringFrame(chest).inverse.point(target.center), radius: target.radius)
            let aim = Self.aimCorrection(reference, target: local)
            lastAimDemand = aim.demand
            let r = chest.rotation
            Self.steer(&out, bone: reference.clavicle, by: r * scaled(aim.clavicle, director.aim) * r.inverse)
            Self.steer(&out, bone: reference.forearm, by: r * scaled(aim.forearm, director.aim) * r.inverse)
            Self.steer(&out, bone: reference.arm, by: r * scaled(aim.arm, director.aim) * r.inverse)
            // The glove arrives with the blow and stops on the target's surface: the arm
            // as posed (which a reaction or the lower body's lag can carry off the
            // contact pose) swings off the target just enough, and until contact keeps
            // a lead that closes at a punch's speed instead of arriving early.
            let lead = Float(director.contactIn ?? 0) * AnimationTuning.contactLead
            let live = liveArm(reference.hand, pose: out, chest: chest, hull: true)
            let skin = target.skin.map { var skin = $0.placed(in: chest); skin.standoff = lead; return skin }
            // Thrown at the air, a straight blow or hook has nothing to stop on; a rising
            // blow still swings up past the guard instead of through it.
            let swing = director.aimClip == .uppercut
            let clear = target.air && !swing ? nil : Self.clearance(live, target: AimTarget(center: chest.inverse.point(target.center), radius: target.radius + lead, skin: skin),
                                                                    swing: swing)
            if let clear {
                Self.steer(&out, bone: reference.forearm, by: r * clear.forearm * r.inverse)
                Self.steer(&out, bone: reference.arm, by: r * clear.arm * r.inverse)
            }
        }
        // Lift the body if any part of the skin would dip below the canvas.
        let joints = out.joints(heads: rig.heads), globals = out.globals()
        var lowest = Float.infinity
        for bone in 0..<FighterSkeleton.boneCount {
            for probe in rig.blobs[bone].probes { lowest = min(lowest, joints[bone].y + globals[bone].act(probe).y) }
        }
        if lowest < 0 { out.hips.y -= lowest }
        if let dt {
            // Only the placed frame (paced and lifted) counts: the unplaced preview in `update` has no pacing.
            hipsShift = out.hips - animated.hips
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

    /// A blow lands (`push`: the impulse's rig-space direction). Over the next frames the
    /// head is carried at least `AnimationTuning.braceTravel` along the blow from where it
    /// was before contact: a fighter stepping or punching into the blow still visibly
    /// takes it, before its own motion takes over.
    func braceForBlow(push: SIMD3<Float>) {
        let stage = root.simdOrientation.act(push)
        let along = SIMD3<Float>(stage.x, 0, stage.z)
        guard simd_length(along) > 1e-4 else { return }
        brace = Brace(anchor: placed(blob(.head).center), push: simd_normalize(along), angle: brace?.angle ?? 0)
    }

    private func braceHead(_ pose: inout FighterPose, dt: Float) {
        guard var b = brace else { return }
        let push = root.simdOrientation.inverse.act(b.push)
        let axis = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), push))
        // The contact frame (0) still shows the glove arriving.
        let frame = b.frames
        b.frames += 1
        if frame > 0, frame <= AnimationTuning.braceFrames {
            let head = blob(.head, in: pose).center, joints = pose.joints(heads: rig.heads)
            let moved = simd_dot(placed(head) - b.anchor, b.push)
            var gain: Float = 0
            for (bone, share) in AnimationTuning.braceShares { gain += share * simd_dot(simd_cross(axis, head - joints[bone]), push) }
            gain *= scale
            let need = gain > 0.05 ? max(0, AnimationTuning.braceTravel - moved) / gain : 0
            b.angle = min(AnimationTuning.braceMaxAngle, max(need, b.angle * AnimationTuning.braceHold))
        } else {
            b.angle *= exp(-dt / AnimationTuning.braceRelease)
        }
        guard b.angle > 0.002 || frame < AnimationTuning.braceFrames else {
            brace = nil
            return
        }
        brace = b
        for (bone, share) in AnimationTuning.braceShares {
            let parent = pose.globals()[FighterSkeleton.parents[bone]]
            let q = simd_quatf(angle: b.angle * share, axis: axis)
            pose.rotations[bone] = simd_normalize(parent.inverse * q * parent * pose.rotations[bone])
        }
    }

    /// Rotate a bone about its joint by a rig-space rotation.
    static func steer(_ pose: inout FighterPose, bone: Int, by rotation: simd_quatf) {
        let parentGlobal = pose.globals()[FighterSkeleton.parents[bone]]
        pose.rotations[bone] = simd_normalize(parentGlobal.inverse * rotation * parentGlobal * pose.rotations[bone])
    }

    /// The chest frame a winding-up punch is steered in: the chest as it will be
    /// turned at `contact` (the clip's torso rotation from now to contact applied to
    /// the chest as it is now). Solving against the chest of this frame instead would
    /// swing the arm about while the torso still twists into the punch.
    private func steeringFrame(_ chest: FighterReach.Frame) -> FighterReach.Frame {
        guard director.windingUp, let motion = lastMotion, motion.snap == nil, motion.clip == director.aimClip,
              let clip = motions[motion.clip] else { return chest }
        let contact = clip.marker("contact", clip.lastFrame * 0.4)
        guard motion.frame < contact, let now = FighterReach.pose(motions, clip.id, frame: motion.frame),
              let then = FighterReach.pose(motions, clip.id, frame: contact) else { return chest }
        let turn = FighterReach.chest(then, heads: rig.heads).rotation * FighterReach.chest(now, heads: rig.heads).rotation.inverse
        return FighterReach.Frame(origin: chest.origin, rotation: simd_normalize(turn * chest.rotation))
    }

    /// An arm as posed now, in chest space.
    private func liveArm(_ hand: FighterBone, pose: FighterPose, chest: FighterReach.Frame, hull: Bool = false) -> AimReference {
        let joints = pose.joints(heads: rig.heads), globals = pose.globals(), inverse = chest.inverse
        let arm = hand == .leftHand ? FighterBone.leftArm.rawValue : FighterBone.rightArm.rawValue
        let glove = FighterReach.blob(hand.rawValue, pose: pose, rig: rig)
        let probes = (hull ? rig.blobs[hand.rawValue].hull : rig.blobs[hand.rawValue].probes).map { inverse.rotation.act(joints[hand.rawValue] + globals[hand.rawValue].act($0) - glove.center) }
        return AimReference(hand: hand, arm: arm, clavicleJoint: inverse.point(joints[FighterSkeleton.parents[arm]]),
                            shoulder: inverse.point(joints[arm]), elbow: inverse.point(joints[arm + 1]),
                            glove: inverse.point(glove.center), gloveRadius: glove.radius, gloveProbes: probes)
    }

    /// Once both fighters are posed: this fighter's free gloves (a punch counts once
    /// its aim lets go) give way to the other fighter's gloves and head they would
    /// sink into — a guard pushed back by the blow, a glove sliding off a glove. A part
    /// coming in fast is met a few frames early, so the glove gives over several frames.
    func yieldGloves(to other: BoxerModel, attacking: Bool, dt: Float) {
        var out = pose
        let chest = FighterReach.chest(out, heads: rig.heads), inverse = chest.inverse, r = chest.rotation
        let turn = inverse.rotation * root.simdOrientation.inverse * other.root.simdOrientation
        let ratio = other.scale / scale
        let bones: [FighterBone] = [.leftHand, .rightHand, .head], hands: [FighterBone] = [.leftHand, .rightHand]
        // Tracked in stage space: the other fighter's parts, then this fighter's gloves.
        let placed = bones.map { other.placed(other.blob($0).center) } + hands.map { self.placed(blob($0, in: out).center) }
        let previous = yieldTrack.count == placed.count ? yieldTrack : placed
        yieldTrack = placed
        let obstacles = bones.indices.map { i in
            let blob = other.blob(bones[i])
            let probes = FighterReach.probes(bones[i].rawValue, pose: other.pose, rig: other.rig, around: blob.center).map { turn.act($0) * ratio }
            let center = inverse.point(local(placed[i]))
            return (center: center, velocity: center - inverse.point(local(previous[i])), radius: blob.radius * ratio, probes: probes)
        }
        let punching = director.aim > 0.001 || attacking ? aimReferences[director.aimClip]?.hand : nil
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var changed = false
        for (index, hand) in hands.enumerated() {
            let weight: Float = hand != punching ? 1 : attacking ? 0 : 1 - director.aim
            let arm = liveArm(hand, pose: out, chest: chest)
            let own = arm.glove - inverse.point(local(previous[bones.count + index]))
            var push = SIMD3<Float>.zero
            for obstacle in obstacles {
                // Away from where the part is now; how far by where it is headed.
                let off = arm.glove - obstacle.center
                guard simd_length(off) > 1e-4 else { continue }
                let away = simd_normalize(off)
                var deepest: Float = 0
                for ahead in 0...AnimationTuning.gloveYieldLead {
                    let share = 1 - Float(ahead) / Float(AnimationTuning.gloveYieldLead + 1)
                    let center = obstacle.center + (obstacle.velocity - own) * Float(ahead)
                    let gap = arm.glove - center, distance = simd_length(gap)
                    let n = distance > 1e-4 ? gap / distance : away
                    let touch = arm.extent(toward: -n, turned: identity)
                        + FighterReach.support(obstacle.probes, radius: obstacle.radius, n) - AnimationTuning.gloveYieldBite
                    deepest = max(deepest, (touch - distance) * share)
                }
                push += away * deepest
            }
            // A give builds up (and lets go) over a few frames: each frame's change of the
            // glove's and the elbow's offset is at most a little more than the last, so
            // neither jumps in or out in one frame (a near-straight arm's elbow swings
            // much farther than its glove gives).
            let now = yieldShift[index], frames = dt * 60
            func limit(_ last: SIMD3<Float>) -> Float {
                (AnimationTuning.gloveYieldStart + AnimationTuning.gloveYieldGrowth * simd_length(last)) * frames
            }
            func solved(_ shift: SIMD3<Float>) -> (arm: simd_quatf, forearm: simd_quatf, elbow: SIMD3<Float>)? {
                guard simd_length(shift) > 1e-4, let solve = Self.reach(arm, to: arm.glove + shift) else { return nil }
                return (solve.arm, solve.forearm, arm.shoulder + solve.arm.act(arm.elbow - arm.shoulder) - arm.elbow)
            }
            // On the stage, the give never makes the glove or elbow move faster than the
            // animation already does, past a safe pace.
            let history = yieldMotion[index]
            func calm(_ joint: Int, _ offset: SIMD3<Float>) -> Bool {
                guard let last = history.last?[joint] else { return true }
                let animated = self.placed(chest.point(joint == 0 ? arm.glove : arm.elbow))
                let pace = history.before.map { simd_distance(last, $0[joint]) } ?? 0
                let allowed = max(simd_distance(animated, last), (AnimationTuning.gloveYieldCalmStart + AnimationTuning.gloveYieldCalmGrowth * pace) * frames)
                return simd_distance(self.placed(chest.point((joint == 0 ? arm.glove : arm.elbow) + offset)), last) <= allowed + 1e-4
            }
            var step = push * weight - now.shift
            if simd_length(step) > limit(now.step) { step *= limit(now.step) / simd_length(step) }
            var solve = solved(now.shift + step)
            for _ in 0..<6 where simd_length((solve?.elbow ?? .zero) - now.elbow) > limit(now.elbowStep)
                || !calm(0, now.shift + step) || !calm(1, solve?.elbow ?? .zero) {
                step *= 0.5
                solve = solved(now.shift + step)
            }
            let shift = now.shift + step, elbow = solve?.elbow ?? .zero, per = max(frames, 1e-3)
            yieldShift[index] = (shift, step / per, elbow, (elbow - now.elbow) / per)
            yieldMotion[index] = (history.last, [self.placed(chest.point(arm.glove + shift)), self.placed(chest.point(arm.elbow + elbow))])
            guard let solve else { continue }
            Self.steer(&out, bone: arm.forearm, by: r * solve.forearm * r.inverse)
            Self.steer(&out, bone: arm.arm, by: r * solve.arm * r.inverse)
            changed = true
        }
        guard changed else { return }
        pose = out
        apply(out)
    }

    /// Two-bone reach (chest space): the elbow bends or opens so the glove sits as far
    /// from the shoulder as `goal`, then the upper arm turns it onto `goal`.
    static func reach(_ arm: AimReference, to goal: SIMD3<Float>) -> (arm: simd_quatf, forearm: simd_quatf)? {
        let shoulder = arm.shoulder, elbow = arm.elbow, glove = arm.glove
        let upper = simd_distance(elbow, shoulder), lower = simd_distance(glove, elbow)
        let reach = simd_distance(glove, shoulder)
        guard upper > 1e-4, lower > 1e-4, reach > 1e-4, simd_distance(goal, shoulder) > 1e-4 else { return nil }
        var axis = simd_cross(glove - elbow, shoulder - elbow)
        if simd_length(axis) < 0.08 * upper * lower { axis = simd_cross(glove - elbow, SIMD3<Float>(0, 1, 0)) }
        guard simd_length(axis) > 1e-6 else { return nil }
        axis = simd_normalize(axis)
        func interior(_ length: Float) -> Float {
            acos(min(1, max(-1, (upper * upper + lower * lower - length * length) / (2 * upper * lower))))
        }
        let wanted = min(upper + lower - 1e-3, max(abs(upper - lower) + 0.02, simd_distance(goal, shoulder)))
        let forearm = simd_quatf(angle: interior(reach) - interior(min(upper + lower - 1e-3, wanted)), axis: axis)
        let bent = elbow + forearm.act(glove - elbow)
        return (shortestArc(from: simd_normalize(bent - shoulder), to: simd_normalize(goal - shoulder)), forearm)
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

    /// Shorten a punch that would sink into `target` (all chest space): the elbow
    /// bends and the upper arm turns so the glove stays on its line from the shoulder
    /// and stops where that line meets the target's surface. A rising punch (`swing`)
    /// instead keeps its bend and swings off the target about the shoulder: still on
    /// its way up under the chin. Nil when the glove is clear.
    static func clearance(_ arm: AimReference, target: AimTarget, swing: Bool = false) -> (arm: simd_quatf, forearm: simd_quatf)? {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let shoulder = arm.shoulder, elbow = arm.elbow, glove = arm.glove
        let upper = simd_distance(elbow, shoulder), lower = simd_distance(glove, elbow)
        let reach = simd_distance(glove, shoulder)
        guard upper > 1e-4, lower > 1e-4, reach > 1e-4 else { return nil }
        func touch(_ at: SIMD3<Float>, turned: simd_quatf) -> Float {
            let toward = target.center - at
            guard simd_length(toward) > 1e-4 else { return target.radius + arm.gloveRadius }
            return max(0.01, arm.extent(toward: simd_normalize(toward), turned: turned) + target.radius - AnimationTuning.aimBite)
        }
        // How far the glove at `at` is off sinking: on a head, past the skin's bite;
        // anything else, past the blob's.
        func gap(_ at: SIMD3<Float>, turned: simd_quatf) -> Float {
            guard let skin = target.skin else { return simd_distance(at, target.center) - touch(at, turned: turned) }
            let depth = arm.gloveProbes.reduce(-Float.infinity) { max($0, skin.depth(of: at + turned.act($1))) }
            return AnimationTuning.skinBite - skin.standoff - depth
        }
        guard gap(glove, turned: identity) < 0 else { return nil }
        if swing, let swung = swingClear() { return (swung, identity) }
        // The arm turned off the target about the shoulder by the least angle that clears it.
        func swingClear() -> simd_quatf? {
            let pivot = simd_cross(glove - shoulder, target.center - shoulder)
            guard simd_length(pivot) > 1e-6 else { return nil }
            let away = simd_normalize(pivot)
            func turned(_ angle: Float) -> (turn: simd_quatf, gap: Float) {
                let turn = simd_quatf(angle: -angle, axis: away)
                return (turn, gap(shoulder + turn.act(glove - shoulder), turned: turn))
            }
            var clear: Float = .pi / 2, sinking: Float = 0
            guard turned(clear).gap >= 0 else { return nil }
            for _ in 0..<12 {
                let mid = (clear + sinking) / 2
                if turned(mid).gap >= 0 { clear = mid } else { sinking = mid }
            }
            return turned(clear).turn
        }
        var axis = simd_cross(glove - elbow, shoulder - elbow)
        // A straight arm has no bend plane yet: the elbow drops under it.
        if simd_length(axis) < 0.08 * upper * lower { axis = simd_cross(glove - elbow, SIMD3<Float>(0, 1, 0)) }
        guard simd_length(axis) > 1e-6 else { return nil }
        axis = simd_normalize(axis)
        func interior(_ length: Float) -> Float {
            acos(min(1, max(-1, (upper * upper + lower * lower - length * length) / (2 * upper * lower))))
        }
        let direction = (glove - shoulder) / reach
        let along = simd_dot(direction, target.center - shoulder)
        // The glove at `wanted` from the shoulder on its line, the elbow bent to get it there.
        func folded(_ wanted: Float) -> (arm: simd_quatf, forearm: simd_quatf, gap: Float) {
            let forearm = simd_quatf(angle: interior(reach) - interior(wanted), axis: axis)
            let bent = elbow + forearm.act(glove - elbow)
            // Turn the arm back onto the glove's line.
            let turn = shortestArc(from: simd_normalize(bent - shoulder), to: direction)
            let placed = shoulder + turn.act(bent - shoulder)
            return (turn, forearm, gap(placed, turned: turn * forearm))
        }
        // The glove turns as the elbow bends (its extent toward the target changes):
        // bisect for the fold that just touches the surface, short of the target's center.
        var clear = abs(upper - lower) + 0.02, sinking = min(reach, max(clear, along))
        guard sinking < reach - 1e-4 || folded(sinking).gap < 0 else { return nil }
        if folded(clear).gap < 0 { return { let f = folded(clear); return (f.arm, f.forearm) }() }
        if folded(sinking).gap >= 0 {
            guard sinking < reach - 1e-4 else { return nil }
            clear = sinking
        } else {
            for _ in 0..<10 {
                let mid = (clear + sinking) / 2
                if folded(mid).gap >= 0 { clear = mid } else { sinking = mid }
            }
        }
        guard clear < reach - 1e-4 else { return nil }
        let result = folded(clear)
        return (result.arm, result.forearm)
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
    /// A bone's extreme skin points as posed, relative to `center` (`hull`: the close 96-point set).
    static func probes(_ bone: Int, pose: FighterPose, rig: FighterRigData, around center: SIMD3<Float>, hull: Bool = false) -> [SIMD3<Float>] {
        let joint = pose.joints(heads: rig.heads)[bone], turn = pose.globals()[bone]
        return (hull ? rig.blobs[bone].hull : rig.blobs[bone].probes).map { joint + turn.act($0) - center }
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
