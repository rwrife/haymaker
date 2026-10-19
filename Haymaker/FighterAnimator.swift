import Foundation
import simd
import HaymakerKit

/// Presentation tuning (seconds unless noted). Animation never changes rules.
enum AnimationTuning {
    static let tellFade: Float = 0.10
    /// A tell that cuts a taunt short blends slower: the stance (feet) differs a lot.
    static let tauntInterruptFade: Float = 0.2
    /// Fraction of the tell window spent loading into the chamber pose; the rest holds it.
    static let tellLoadFraction = 0.72
    static let minimumTellLoad = 0.06
    /// Telegraph exaggeration: how far the tell winds up past `chamber`, away from `contact`.
    static func anticipation(_ move: Move) -> Float {
        switch move {
        case .hook: 0.45
        case .uppercut: 0.4
        default: 0.4
        }
    }
    static let maxAnticipationAngle: Float = 0.42
    static let playerPunchFade: Float = 0.06
    /// A hook thrown straight out of the guard skips the clip's long drop into the
    /// chamber: its glove has far to go to the cocked pose, so its arm blends in longer.
    static let playerHookArmFade: Float = 0.1
    /// Fastest an untold (player) punch extension may run versus the mocap.
    static let maxPunchSpeedup: Float = 2.5
    /// Fastest the lower body (step, Hips travel, legs) may run versus the mocap.
    static let maxLowerSpeedup: Float = 1.75
    /// A punch's approach is re-timed so the glove meets its target at full speed:
    /// the mocap's slow-down before `contact` plays at least this much faster.
    static let strikeTailFloor: Float = 0.25
    /// A told punch never strikes slower than this versus the mocap: a long impact
    /// window holds the loaded chamber first, then fires.
    static let slowestStrike: Float = 1.5
    /// After contact the arm snaps back to guard (the clip's `retracted` frame) in
    /// this long, never faster than `maxRetractSpeedup`; the body settles at
    /// `recoverSpeed` from there.
    static let retractTime = 0.2
    static let maxRetractSpeedup: Float = 4
    /// From halfway through that snap the punching arm settles fully onto its guard
    /// over this long (s) and stays there while the body finishes its recovery.
    static let guardArmTime: Float = 0.15
    static let recoverSpeed: Float = 1.15
    static let maxSettleSpeedup: Float = 2
    /// The glove counts as back on guard within this share of its punch travel.
    static let retractedShare: Float = 0.3
    static let whiffRetractStretch = 1.35
    static let whiffHold = 0.09
    static let whiffSlowdown: Float = 0.85
    static let punchExitFade: Float = 0.3
    static let guardFade: Float = 0.07
    static let parryFade: Float = 0.05
    /// Fades this short (s) blend linearly.
    static let evenFade: Float = 0.051
    static let slipFade: Float = 0.06
    static let guardLoad = 0.12
    static let parryLoad = 4.0 / 60
    static let maxSlipLoad = 0.22
    static let guardExitRate: Float = 1.25
    static let guardExitFade: Float = 0.3
    static let knockdownFade: Float = 0.1
    /// Fraction of the fall's horizontal travel kept (shorter walk back to the mark).
    static let knockdownTravel: Float = 1.0
    static let getUpFade: Float = 0.3
    static let getUpExitFade: Float = 0.45
    /// The get-up reaches `standing` this long before the engine's rise: the fight
    /// resumes on the rise tick, so the fighter must already be on guard.
    static let standingLead = 0.0
    /// Shortest time spent lying still; the fall and get-up speed up (up to
    /// `maxDownSpeedup`) to keep it inside the knockdown window.
    static let minimumLie = 0.45
    static let maxDownSpeedup = 1.35
    static let walkSpeed = 1.0
    /// An action thrown out of the get-up's last steps blends in at least this slowly.
    static let getUpInterruptFade: Float = 0.12
    /// ...but a punch's arm finishes its blend within this share of the windup.
    static let strikeFadeShare: Float = 0.6
    static let tauntFadeIn: Float = 0.25
    static let tauntFadeOut: Float = 0.3
    static let tauntLead: Float = 0.2
    static let victoryFade: Float = 0.35
    static let idleFade: Float = 0.25
    static let lungeRelease = 0.22
    /// Share of a punch clip's Hips travel (XZ, from its first frame) kept on screen.
    /// The mocap jab and uppercut lunge ~0.8–0.9 units behind a long lead step; a
    /// boxer's step-drag is shorter, and the scene's step-in covers the rest.
    static func punchTravel(_ clip: ClipID) -> Float {
        switch clip {
        case .jab, .uppercut: 0.5
        default: 1
        }
    }
    /// A punch's feet spread (ankle to ankle) eases out from the guard stance and never
    /// passes this share of it: the mocap's lunge step (up to 1.9× the stance) becomes
    /// a short lead step with the rear foot dragging up behind it.
    static let stanceLimit: Float = 1.1
    /// While a punch winds up the body (the Hips on the canvas) moves at most this
    /// far per 60 Hz frame, and at most `windupHipsTravel` from where it started: a
    /// fast strike is a step, not a lunge. Whatever it falls behind is made up over
    /// `hipsLagRelease` seconds after contact, while the punch recovers.
    static let windupHipsPace: Float = 0.062
    static let windupHipsTravel: Float = 0.46
    static let hipsLagRelease: Float = 0.3
    /// After contact the body never drives on toward the target (a lagging lower
    /// body would otherwise catch up through the rest of the step) and settles back
    /// over its stance in this long.
    static let travelReturn = 0.4
    /// How fast the punching arm lets go of the target after contact (seconds to zero).
    static let aimRelease = 0.08
    /// Hardest the arm may be steered off the mocap line (radians).
    static let maxAim: Float = 0.75
    /// Share of the steer taken by the clavicle (reach and shrug), and its cap.
    static let clavicleAimShare: Float = 0.45
    static let maxClavicleAim: Float = 0.3
    /// How far the glove sinks into the target at contact (rig units).
    static let aimBite: Float = 0.05
    /// How far a glove may press into a head's skin where the blob overhangs it (rig units).
    static let skinBite: Float = 0.035
    /// Until contact a punching glove stays this far (rig units) per second still to
    /// go off its target: it closes at a strike's speed rather than arriving early.
    static let contactLead: Float = 2.4
    /// How far a glove giving way to the other fighter's glove or head still overlaps it (rig units).
    static let gloveYieldBite: Float = 0.03
    /// Frames ahead a glove starts giving way to a part coming at it (each counting less).
    static let gloveYieldLead = 6
    /// A glove's give changes by at most `start + growth × last frame's change` per 60 Hz frame (rig units).
    static let gloveYieldStart: Float = 0.034
    static let gloveYieldGrowth: Float = 2.2
    /// On the stage a give never moves a glove or elbow faster than the animation already
    /// does, past `calmStart + calmGrowth × its speed the frame before` (rig units per 60 Hz frame).
    static let gloveYieldCalmStart: Float = 0.036
    static let gloveYieldCalmGrowth: Float = 2.3
    /// How far (rig units) an open guard glove drops and opens as a hook comes in on its side.
    static let guardDrop: Float = 0.3
    static let guardOpen: Float = 0.08
    /// Most the elbow may flex to stop a glove on a target that is closer than the punch reaches.
    static let maxElbowFlex: Float = 1.0
    /// Most the elbow may open to reach a target a bent-arm punch falls short of.
    static let maxElbowExtension: Float = 0.35
    static let reactionAttack: Float = 0.05
    static let reactionDecay: Float = 0.22
    static let reactionRelease: Float = 0.12
    /// A fresh reaction shows at least this long (s) before a new action releases it,
    /// so a fighter punching straight back still visibly takes the blow first.
    static let reactionShow: Float = 0.07
    /// Hit impulse: the head, neck and upper spine snap along the blow, peaking
    /// this long (s) after contact, whatever the fighter is doing.
    static let impulsePeak: Float = 0.05
    /// Peak snap (radians, shared by spine, neck and head) per landed punch.
    static func impulse(_ move: Move) -> Float {
        switch move {
        case .hook: 0.32
        case .uppercut: 0.34
        default: 0.24
        }
    }
    static let blockedImpulse: Float = 0.07
    /// A landed blow carries the head at least this far (stage units) along it within
    /// `braceFrames` frames of contact (on top of the impulse, which a fighter lunging
    /// into the blow can cancel), leaning spine, neck and head by `braceShares`, at most
    /// `braceMaxAngle` radians; the lean eases off `braceHold` per frame while held, then
    /// with a time constant of `braceRelease` seconds.
    static let braceTravel: Float = 0.045
    static let braceFrames = 2
    static let braceShares: [(bone: Int, share: Float)] = [(2, 0.12), (3, 0.2), (4, 0.3), (5, 0.38)]
    static let braceMaxAngle: Float = 0.3
    static let braceHold: Float = 0.8
    static let braceRelease: Float = 0.035
}

/// Re-timing of a punch's approach: the mocap's glove slows down well before its
/// `contact` frame (nearly still for several frames), which on screen reads as a
/// glove resting on the target. Strike time runs at clip speed up to the glove's
/// peak speed, then runs through the slow-down in proportion to the glove's speed
/// (floored), so the glove is still travelling fast when it lands.
struct StrikeClock: Sendable {
    /// Strike time at each integer clip frame.
    let tau: [Float]

    init(_ motions: FighterMotionSet, clip id: ClipID) {
        guard let clip = motions[id], clip.frameCount > 1 else { tau = []; return }
        let hand = FighterReach.punchingHand(motions, clip: id).rawValue
        let count = clip.frameCount
        let points = (0..<count).map { FighterReach.pose(motions, id, frame: Float($0))?.joints(heads: motions.heads)[hand] ?? .zero }
        let speed = (0..<(count - 1)).map { simd_distance(points[$0 + 1], points[$0]) }
        let chamber = max(0, min(count - 2, Int(clip.marker("chamber", clip.lastFrame * 0.2))))
        let contact = max(chamber + 1, min(count - 1, Int(clip.marker("contact", clip.lastFrame * 0.4).rounded(.up))))
        let peakFrame = (chamber..<contact).max { speed[$0] < speed[$1] } ?? chamber
        let peak = max(1e-4, speed[peakFrame])
        var tau = [Float](repeating: 0, count: count)
        for f in 1..<count {
            let segment = f - 1
            let step = segment > peakFrame && segment < contact ? max(AnimationTuning.strikeTailFloor, speed[segment] / peak) : 1
            tau[f] = tau[f - 1] + step
        }
        self.tau = tau
    }

    func tau(at frame: Float) -> Float {
        guard tau.count > 1 else { return frame }
        let f = min(Float(tau.count - 1), max(0, frame)), i = min(tau.count - 2, Int(f))
        return tau[i] + (tau[i + 1] - tau[i]) * (f - Float(i))
    }

    func frame(at t: Float) -> Float {
        guard tau.count > 1 else { return t }
        if t <= tau[0] { return 0 }
        var lo = 0, hi = tau.count - 1
        if t >= tau[hi] { return Float(hi) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if tau[mid] <= t { lo = mid } else { hi = mid }
        }
        let span = tau[hi] - tau[lo]
        return Float(lo) + (span > 1e-6 ? (t - tau[lo]) / span : 0)
    }

    /// Strike time per clip frame around `frame`.
    func slope(at frame: Float) -> Float {
        guard tau.count > 1 else { return 1 }
        let i = min(tau.count - 2, max(0, Int(frame)))
        return max(1e-3, tau[i + 1] - tau[i])
    }
}

/// Yaw + translation applied to the Hips (rig space). Used to start the
/// get-up exactly where the fall ended, then walk back to the mark.
struct RootWarp: Equatable, Sendable {
    var yaw: Float = 0
    var offset: SIMD3<Float> = .zero
    static let identity = RootWarp()

    var isIdentity: Bool { abs(yaw) < 1e-5 && simd_length(offset) < 1e-5 }
    var rotation: simd_quatf { simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) }

    func apply(_ pose: inout FighterPose) {
        guard !isIdentity else { return }
        let q = rotation
        pose.hips = q.act(pose.hips) + offset
        pose.rotations[0] = simd_normalize(q * pose.rotations[0])
    }

    /// `self ∘ other`: apply `other` first.
    func composed(with other: RootWarp) -> RootWarp {
        RootWarp(yaw: yaw + other.yaw, offset: rotation.act(other.offset) + offset)
    }

    var inverse: RootWarp {
        let q = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
        return RootWarp(yaw: -yaw, offset: -q.act(offset))
    }

    static func lerp(_ a: RootWarp, _ b: RootWarp, _ t: Float) -> RootWarp {
        var delta = (b.yaw - a.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        return RootWarp(yaw: a.yaw + delta * t, offset: a.offset + (b.offset - a.offset) * t)
    }
}

/// What the director wants on screen this frame.
struct Motion: Sendable {
    var clip: ClipID
    var frame: Float
    /// Clip frames per presentation second (keeps an outgoing motion moving during a crossfade).
    var rate: Float
    /// Identity of a continuous motion; changing it starts a crossfade of `fade` seconds.
    var key: Int
    var fade: Float
    /// The punching arm's own crossfade: shorter (a punch out of a slow blend still
    /// lands) or longer (a glove with far to go to the clip's pose gets there smoothly).
    var armFade: Float?
    var anticipation: Float = 0
    /// 0…1 subtle breathing on a held pose.
    var hold: Float = 0
    var warp: RootWarp = .identity
    /// Lower-body clock (Hips translation and legs) when it lags `frame`: a punch's
    /// arm may run fast, but the step and the weight transfer never outpace life.
    var lower: Float?
    /// Fastest the lower clock may chase `frame` (clip frames per second).
    var lowerRate: Float = 0
    /// A punch snapping back to guard: the upper body blends straight from the
    /// `from` pose to the `to` pose (skipping the clip's follow-through between
    /// them, which would sweep through the opponent); the legs stay on `lower`.
    var snap: Snap?
    /// After a punch's contact: most forward Hips travel (rig Z, from the clip's first
    /// frame) and the share of the travel still shown as the body settles back.
    var travelCap: Float?
    var travelScale: Float = 1
    /// 0…1 the punching arm held on its guard (the clip's first frame) over the clip.
    var guardArm: Float = 0
    /// Clip frame for the other (non-punching) arm while the punching arm runs on the
    /// strike clock: it keeps the clip's even pace instead of snapping with the punch.
    var offArm: Float?

    struct Snap: Sendable {
        var from: Float
        var to: Float
        var weight: Float
    }
}

enum ReactionMask: Sendable {
    case full, torso

    func weight(_ bone: Int) -> Float {
        switch self {
        case .full: return 1
        case .torso:
            switch bone {
            case 1...5: return 1
            case 0: return 0.4
            case 6, 10: return 0.6
            case 7...9, 11...13: return 0.25
            default: return 0
            }
        }
    }
}

/// Layered pose player: base motion with crossfades, additive hit reactions and breathing.
final class FighterAnimator {
    let motions: FighterMotionSet
    private(set) var pose: FighterPose
    /// Scale on hit-reaction Neck/Head snaps (thick-necked skins fold on big tilts).
    var neckFlex: Float = 1
    private var basePose: FighterPose
    private var current: Motion?
    private enum Source { case live(Motion), frozen(FighterPose) }
    private var source: Source?
    private var fadeElapsed: Float = 0
    private var fadeDuration: Float = 0
    private var armFadeDuration: Float?

    private struct Telegraph {
        let chamber: Float
        let contact: Float
        let deltas: [simd_quatf]
        let angles: [Float]
    }
    private var telegraphs: [ClipID: Telegraph] = [:]
    /// Per punch clip: the punching arm chain and its guard (first-frame) rotations.
    private var guardArms: [ClipID: [(bone: Int, rotation: simd_quatf)]] = [:]
    private var offArms: [ClipID: [Int]] = [:]
    private static let telegraphBones = [1, 2, 3, 6, 7, 8, 10, 11, 12]
    /// Left-minus-right ankle XZ in the idle guard (the stance a punch's step narrows toward).
    let guardSpread: SIMD2<Float>

    private struct Reaction {
        let clip: RetargetedClip
        let end: Float
        var frame: Float
        let rate: Float
        let weight: Float
        let mask: ReactionMask
        var age: Float = 0
        var release: Float?
        let baseInverse: [simd_quatf]
        let baseHips: SIMD3<Float>
    }
    private var reactions: [Reaction] = []

    private struct Impulse {
        /// Rig-space tilt axis (the struck part tips along the blow) and head turn at peak.
        let axis: SIMD3<Float>
        let turn: Float
        let angle: Float
        var age: Float = 0
    }
    private var impulses: [Impulse] = []
    private static let impulseShares: [(bone: Int, share: Float)] = [(2, 0.12), (3, 0.2), (4, 0.3), (5, 0.38)]

    init(motions: FighterMotionSet) {
        self.motions = motions
        pose = FighterPose(hips: motions.heads[0])
        if let idle = motions[.idle] { idle.sample(0, into: &pose) }
        basePose = pose
        let ankles = pose.joints(heads: motions.heads)
        let left = ankles[FighterBone.leftFoot.rawValue], right = ankles[FighterBone.rightFoot.rawValue]
        guardSpread = SIMD2<Float>(left.x - right.x, left.z - right.z)
        for id in [ClipID.jab, .hook, .uppercut] {
            guard let clip = motions[id] else { continue }
            let chamber = clip.marker("chamber", clip.lastFrame * 0.2)
            let contact = clip.marker("contact", clip.lastFrame * 0.4)
            var deltas = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: FighterSkeleton.boneCount)
            var angles = [Float](repeating: 0, count: FighterSkeleton.boneCount)
            for bone in Self.telegraphBones {
                var delta = simd_normalize(clip.rotation(bone, at: contact).inverse * clip.rotation(bone, at: chamber))
                if delta.real < 0 { delta = simd_quatf(vector: -delta.vector) }
                deltas[bone] = delta
                angles[bone] = 2 * acos(min(1, delta.real))
            }
            telegraphs[id] = Telegraph(chamber: chamber, contact: contact, deltas: deltas, angles: angles)
            let side: FighterBone = FighterReach.punchingHand(motions, clip: id) == .leftHand ? .leftShoulder : .rightShoulder
            guardArms[id] = (side.rawValue...side.rawValue + 3).map { ($0, clip.rotation($0, at: 0)) }
            let other: FighterBone = side == .leftShoulder ? .rightShoulder : .leftShoulder
            offArms[id] = Array(other.rawValue...other.rawValue + 3)
        }
    }

    func reset() {
        current = nil
        source = nil
        reactions.removeAll()
        impulses.removeAll()
    }

    /// Sample a motion (clip pose + telegraph exaggeration + root warp) without layers.
    func sample(_ motion: Motion) -> FighterPose {
        var result = basePose
        guard let clip = motions[motion.clip] else { return result }
        if let snap = motion.snap {
            var contact = result, retracted = result, legs = result
            clip.sample(snap.from, into: &contact)
            clip.sample(snap.to, into: &retracted)
            result = FighterPose.blend(contact, retracted, snap.weight)
            clip.sample(motion.lower ?? motion.frame, into: &legs)
            Self.mergeLower(&result, legs)
        } else {
            clip.sample(motion.frame, into: &result)
        }
        if motion.snap == nil, let lower = motion.lower, abs(lower - motion.frame) > 1e-3 {
            var legs = result
            clip.sample(lower, into: &legs)
            Self.mergeLower(&result, legs)
        }
        if motion.snap == nil, let off = motion.offArm, abs(off - motion.frame) > 1e-3, let bones = offArms[motion.clip] {
            for bone in bones { result.rotations[bone] = clip.rotation(bone, at: off) }
        }
        Self.dampTravel(&result, clip: clip, cap: motion.travelCap, scale: motion.travelScale)
        if [ClipID.jab, .hook, .uppercut].contains(motion.clip) {
            Self.narrowStance(&result, heads: motions.heads, guardSpread: guardSpread)
        }
        if motion.guardArm > 0, let arm = guardArms[motion.clip] {
            for (bone, rotation) in arm { result.rotations[bone] = simd_slerp(result.rotations[bone], rotation, motion.guardArm) }
        }
        if motion.anticipation > 0, let telegraph = telegraphs[motion.clip] {
            let f = clip.wrap(motion.frame)
            let envelope = f <= telegraph.chamber
                ? smoothstep(f / max(1, telegraph.chamber))
                : 1 - smoothstep((f - telegraph.chamber) / max(0.5, (telegraph.contact - telegraph.chamber) * 0.6))
            let w = envelope * motion.anticipation
            if w > 0.001 {
                for bone in Self.telegraphBones {
                    let angle = telegraph.angles[bone]
                    let amount = angle * w > AnimationTuning.maxAnticipationAngle ? AnimationTuning.maxAnticipationAngle / max(angle, 1e-4) : w
                    result.rotations[bone] = simd_normalize(result.rotations[bone] * scaled(telegraph.deltas[bone], amount))
                }
            }
        }
        motion.warp.apply(&result)
        return result
    }

    /// Hips travel of `clip` relative to its first frame, kept at `punchTravel`,
    /// capped forward at `cap` and scaled by `scale` (the feet are planted by IK).
    static func travelOffset(_ hips: SIMD3<Float>, clip: RetargetedClip, cap: Float? = nil, scale: Float = 1) -> SIMD2<Float> {
        let base = clip.hipsPosition(at: 0), keep = AnimationTuning.punchTravel(clip.id)
        var d = SIMD2<Float>(hips.x - base.x, hips.z - base.z) * keep
        if let cap { d.y = min(d.y, cap) }
        return d * scale
    }

    static func dampTravel(_ pose: inout FighterPose, clip: RetargetedClip, cap: Float? = nil, scale: Float = 1) {
        guard AnimationTuning.punchTravel(clip.id) != 1 || cap != nil || scale != 1 else { return }
        let base = clip.hipsPosition(at: 0)
        let d = travelOffset(pose.hips, clip: clip, cap: cap, scale: scale)
        pose.hips.x = base.x + d.x
        pose.hips.z = base.z + d.y
    }

    /// Keep the feet's shared travel (it follows the Hips) but ease their spread out
    /// of the guard stance and cap it at `stanceLimit`: the feet move toward each
    /// other along the spread's widening, and the legs bend to the new feet.
    static func narrowStance(_ pose: inout FighterPose, heads: [SIMD3<Float>], guardSpread: SIMD2<Float>) {
        let left = FighterBone.leftFoot.rawValue, right = FighterBone.rightFoot.rawValue
        let joints = pose.joints(heads: heads)
        let spread = SIMD2<Float>(joints[left].x - joints[right].x, joints[left].z - joints[right].z)
        let base = simd_length(guardSpread), width = simd_length(spread)
        let limit = base * AnimationTuning.stanceLimit
        guard base > 1e-4, width > base else { return }
        // Soft cap (C1 at the guard width): widening past the guard saturates toward the limit.
        let wanted = base + (limit - base) * (1 - exp(-(width - base) / (limit - base)))
        let widening = spread - guardSpread
        let a = simd_length_squared(widening), b = simd_dot(guardSpread, widening)
        let c = base * base - wanted * wanted
        guard a > 1e-8 else { return }
        let s = min(1, max(0, (-b + max(0, b * b - a * c).squareRoot()) / a))
        let shift = widening * (s - 1) / 2
        let move = SIMD3<Float>(shift.x, 0, shift.y)
        FootPlanter.solveLeg(&pose, heads: heads, upLeg: FighterBone.leftUpLeg.rawValue,
                             toeTarget: joints[FighterBone.leftToeBase.rawValue] + move)
        FootPlanter.solveLeg(&pose, heads: heads, upLeg: FighterBone.rightUpLeg.rawValue,
                             toeTarget: joints[FighterBone.rightToeBase.rawValue] - move)
    }

    /// Hips travel and the legs' world orientation from `lower`; the Hips rotation
    /// (and everything above it) stays on the upper clock so the punch keeps its line.
    static func mergeLower(_ upper: inout FighterPose, _ lower: FighterPose) {
        upper.hips = lower.hips
        let reframe = upper.rotations[0].inverse * lower.rotations[0]
        for bone in FighterSkeleton.lowerBones {
            let parent = FighterSkeleton.parents[bone]
            upper.rotations[bone] = parent == 0 ? simd_normalize(reframe * lower.rotations[bone]) : lower.rotations[bone]
        }
    }

    @discardableResult
    func update(_ motion: Motion, dt: Float, now: Double, reducedMotion: Bool) -> FighterPose {
        let step = max(0, dt)
        if let current, current.key != motion.key {
            if source != nil, fadeElapsed < max(fadeDuration, armFadeDuration ?? 0) {
                source = .frozen(basePose)
            } else {
                source = .live(current)
            }
            fadeElapsed = 0
            fadeDuration = max(0.001, motion.fade)
            armFadeDuration = motion.armFade.map { max(0.001, $0) }
        }
        current = motion
        var out = sample(motion)
        if let active = source {
            fadeElapsed += step
            if fadeElapsed >= max(fadeDuration, armFadeDuration ?? 0) {
                source = nil
            } else {
                let from: FighterPose
                switch active {
                case var .live(outgoing):
                    outgoing.frame += outgoing.rate * step
                    if let lower = outgoing.lower {
                        let gap = outgoing.frame - lower, reach = outgoing.lowerRate * step
                        outgoing.lower = lower + min(reach, max(-reach, gap))
                    }
                    source = .live(outgoing)
                    from = sample(outgoing)
                case let .frozen(snapshot):
                    from = snapshot
                }
                let target = out
                // A fade over only a few frames ramps evenly: smoothstep's samples would
                // put half the blend into the middle frame.
                let blend = min(1, fadeElapsed / fadeDuration)
                out = FighterPose.blend(from, target, fadeDuration <= AnimationTuning.evenFade ? blend : smoothstep(blend))
                if let arm = armFadeDuration, let bones = guardArms[motion.clip] {
                    let weight = smoothstep(min(1, fadeElapsed / arm))
                    for (bone, _) in bones { out.rotations[bone] = slerpShortest(from.rotations[bone], target.rotations[bone], weight) }
                }
            }
        }
        basePose = out
        if motion.hold > 0, !reducedMotion {
            let breath = Float(sin(now * 2 * .pi * 0.32)) * 0.014 * motion.hold
            let q = simd_quatf(angle: breath, axis: SIMD3<Float>(1, 0, 0))
            out.rotations[2] = simd_normalize(out.rotations[2] * q)
            out.rotations[3] = simd_normalize(out.rotations[3] * q)
        }
        applyReactions(&out, dt: step)
        applyImpulses(&out, dt: step)
        pose = out
        return out
    }

    /// A blow's instant snap on the upper spine, neck and head, driven along `push`
    /// (rig space) and peaking `impulsePeak` after contact. Unlike clip reactions it
    /// survives the fighter starting a new action.
    func impulse(push: SIMD3<Float>, angle: Float) {
        guard angle > 0 else { return }
        var along = SIMD3<Float>(push.x, 0, push.z)
        along = simd_length(along) > 1e-3 ? simd_normalize(along) : SIMD3<Float>(0, 0, -1)
        let axis = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), along))
        if impulses.count >= 3 { impulses.removeFirst() }
        // A blow from the side also turns the face away.
        impulses.append(Impulse(axis: axis, turn: along.x * 0.6 * angle, angle: angle))
    }

    private func applyImpulses(_ out: inout FighterPose, dt: Float) {
        guard !impulses.isEmpty else { return }
        let peak = AnimationTuning.impulsePeak
        impulses.removeAll { $0.age > peak * 14 }
        // Age before advancing: the contact frame itself still shows the glove arriving.
        for impulse in impulses {
            let x = impulse.age / peak
            let envelope = x * exp(1 - x)
            guard envelope > 0.002 else { continue }
            for (bone, share) in Self.impulseShares {
                let w = envelope * share * (bone >= 4 ? 0.5 + 0.5 * neckFlex : 1)
                let q = simd_quatf(angle: impulse.turn * w, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: impulse.angle * w, axis: impulse.axis)
                let parent = out.globals()[FighterSkeleton.parents[bone]]
                out.rotations[bone] = simd_normalize(parent.inverse * q * parent * out.rotations[bone])
            }
        }
        for i in impulses.indices { impulses[i].age += dt }
    }

    /// Additive hit reaction: plays `id` from `impact` to `recovered`, relative to its impact frame.
    func react(_ id: ClipID, weight: Float, rate: Float, mask: ReactionMask) {
        guard let clip = motions[id], weight > 0 else { return }
        let start = clip.marker("impact", 0), end = clip.marker("recovered", clip.lastFrame)
        guard end > start else { return }
        let inverse = (0..<FighterSkeleton.boneCount).map { clip.rotation($0, at: start).inverse }
        if reactions.count >= 2 { reactions.removeFirst() }
        reactions.append(Reaction(clip: clip, end: end, frame: start, rate: clip.fps * rate, weight: weight, mask: mask,
                                  baseInverse: inverse, baseHips: clip.hipsPosition(at: start)))
    }

    /// Quickly fade reactions out (the engine moved the fighter into a new action).
    func releaseReactions() {
        for i in reactions.indices where reactions[i].release == nil {
            reactions[i].release = AnimationTuning.reactionRelease + max(0, AnimationTuning.reactionShow - reactions[i].age)
        }
    }

    var hasReaction: Bool { !reactions.isEmpty }

    private func applyReactions(_ out: inout FighterPose, dt: Float) {
        guard !reactions.isEmpty else { return }
        for i in reactions.indices {
            reactions[i].age += dt
            reactions[i].frame += reactions[i].rate * dt
            if let release = reactions[i].release { reactions[i].release = release - dt }
        }
        reactions.removeAll { $0.frame >= $0.end || ($0.release ?? 1) <= 0 }
        for reaction in reactions {
            let attack = smoothstep(reaction.age / AnimationTuning.reactionAttack)
            let decay = smoothstep((reaction.end - reaction.frame) / max(1, reaction.rate * AnimationTuning.reactionDecay))
            let release = reaction.release.map { smoothstep($0 / AnimationTuning.reactionRelease) } ?? 1
            let w = reaction.weight * attack * decay * release
            guard w > 0.001 else { continue }
            for bone in 0..<FighterSkeleton.boneCount {
                let m = reaction.mask.weight(bone) * w * (bone == 4 || bone == 5 ? neckFlex : 1)
                guard m > 0.001 else { continue }
                let delta = reaction.baseInverse[bone] * reaction.clip.rotation(bone, at: reaction.frame)
                out.rotations[bone] = simd_normalize(out.rotations[bone] * scaled(delta, m))
            }
            if reaction.mask == .full {
                out.hips += (reaction.clip.hipsPosition(at: reaction.frame) - reaction.baseHips) * w
            }
        }
    }
}

func smoothstep(_ x: Float) -> Float {
    let t = min(1, max(0, x))
    return t * t * (3 - 2 * t)
}

func easeOut(_ x: Double) -> Double {
    let t = min(1, max(0, x))
    return 1 - (1 - t) * (1 - t)
}

func easeInOut(_ x: Double) -> Double {
    let t = min(1, max(0, x))
    return t * t * (3 - 2 * t)
}

/// A punch snapping back off its target: fastest at once, settling onto the guard.
func snapBack(_ x: Double) -> Double {
    let t = 1 - min(1, max(0, x))
    return 1 - t * t * t
}

/// Presentation cue chosen by the bout choreographer for an idle fighter.
enum FighterCue: Equatable, Sendable {
    case none
    /// Taunt over a downed opponent: the victory `armsUp`…`armsDown` segment, released at `until`.
    case taunt(start: Double, until: Double)
    /// Post-bout celebration (the full victory clip) from `start`.
    case celebrate(start: Double)
}

/// Maps one fighter's deterministic engine state onto clip motions.
final class FighterDirector {
    struct Input {
        var status: FighterStatus
        var totalTicks: Int
        var tickFraction: Double
        var now: Double
        var dt: Double
        var reducedMotion: Bool
        var cue: FighterCue = .none
    }

    /// Knockdown timeline on the presentation clock.
    struct DownTimes: Equatable {
        let ground: Double
        let rise: Double
    }

    let motions: FighterMotionSet
    /// Idle loop desynchronisation so the two fighters never bounce in step.
    var idlePhase: Double = 0
    var idleRate: Double = 1

    /// 0…1 slide toward the target for the current punch (1 at contact).
    private(set) var lunge: Float = 0
    private(set) var lungeMove: Move = .idle
    /// What is left of the previous punch's slide when a new punch starts
    /// before it released (blends out as the new one comes in, so the root never jumps).
    private(set) var lungeCarry: Float = 0
    private(set) var carryMove: Move = .idle
    private var carryStart: Float = 0
    /// Extra slide (scene units) the choreographer asks for so the current punch
    /// meets the defender's head where it really is; `carryReach` is the previous
    /// punch's share, released with `lungeCarry`.
    var reach: Float = 0
    private(set) var carryReach: Float = 0
    /// 0…1 how strongly the punching arm is steered onto the target (1 at contact).
    private(set) var aim: Float = 0
    private(set) var aimClip: ClipID = .jab
    /// Seconds until the winding-up punch lands (nil when no punch is on its way).
    private(set) var contactIn: Double?
    private(set) var downTimes: DownTimes?
    /// True on the frame the fighter entered a new non-idle engine state.
    private(set) var enteredAction = false
    private(set) var lastAttack: Move = .idle

    private struct StateID: Equatable {
        let state: FighterState
        let start: Int
        let move: Move
    }

    private struct Tail {
        let clip: ClipID
        let key: Int
        let frame0: Float
        let now0: Double
        /// Optional eased first leg `frame0` → `snapEnd` over `snapTime` (a punch snapping back to guard).
        var snapEnd: Float?
        var snapTime: Double = 0
        let rate: Float
        let hold: Double
        let end: Float
        let exitFade: Float
        let anticipation: Float
        /// A punch's recovery: forward Hips travel cap (see `Motion.travelCap`).
        var travelCap: Float?
        /// A punch's recovery: the punching arm settles on its guard (see `Motion.guardArm`).
        var guardArm = false

        func frame(_ now: Double) -> Float {
            let t = max(0, now - now0 - hold)
            guard let snapEnd, snapTime > 0 else { return min(end, frame0 + Float(t) * rate) }
            if t < snapTime { return frame0 + (snapEnd - frame0) * Float(snapBack(t / snapTime)) }
            return min(end, snapEnd + Float(t - snapTime) * rate)
        }

        func rate(_ now: Double) -> Float {
            let t = now - now0 - hold
            guard t >= 0 else { return 0 }
            if let snapEnd, t < snapTime {
                let u = t / snapTime
                return (snapEnd - frame0) * Float(3 * (1 - u) * (1 - u) / snapTime)
            }
            return rate
        }

        func finished(_ now: Double) -> Bool { frame(now) >= end - exitFade * rate * 0.6 }
        func motion(_ now: Double) -> Motion {
            var motion = Motion(clip: clip, frame: frame(now), rate: rate(now), key: key, fade: AnimationTuning.idleFade,
                                anticipation: anticipation)
            let t = max(0, now - now0 - hold)
            if let snapEnd, snapTime > 0, t < snapTime {
                motion.snap = .init(from: frame0, to: snapEnd, weight: Float(snapBack(t / snapTime)))
            }
            if let travelCap {
                motion.travelCap = travelCap
                motion.travelScale = 1 - Float(easeInOut((now - now0) / AnimationTuning.travelReturn))
            }
            if guardArm {
                motion.guardArm = smoothstep((Float(t - snapTime * 0.5)) / AnimationTuning.guardArmTime)
            }
            return motion
        }
    }

    private struct GuardSequence {
        let clip: ClipID
        let key: Int
        let anchorTick: Int
        let load: Double
        let fade: Float
    }

    private struct Knockdown {
        let key: Int
        let getUpKey: Int
        let anchor: Double
        let fallRate: Float
        let getUpRate: Float
        var getUpStart: Double?
        var getUpFrame: Float = 0
        var risen = false
    }

    /// Getting up where the fall ended, then walking back to the mark.
    private struct Recovery {
        /// Places getUp frame 0 onto the lying pose.
        let start: RootWarp
        /// Places idle onto the end of the get-up (identity when the clips line up).
        let align: RootWarp
        var walkStart: Double?
        var walkDuration: Double = 1
        var exited = false

        func getUpWarp(_ now: Double) -> RootWarp {
            guard let walkStart else { return start }
            let t = Float(easeInOut((now - walkStart) / walkDuration))
            return RootWarp.lerp(start, align.inverse, t)
        }

        func ambientWarp(_ now: Double) -> RootWarp { getUpWarp(now).composed(with: align) }

        func walked(_ now: Double) -> Bool { walkStart.map { now - $0 >= walkDuration } ?? false }

        mutating func startWalk(_ now: Double) {
            let total = start.composed(with: align)
            let distance = Double(simd_length(total.offset)) + Double(abs(total.yaw)) * 0.5
            walkStart = now
            walkDuration = min(1.8, max(0.6, distance / AnimationTuning.walkSpeed))
        }
    }

    private var stateID: StateID?
    private var serial = 1
    private var tellKey = 0
    private var tellFade = AnimationTuning.tellFade
    private var attackKey = 0
    private var told = false
    private var whiffed = false
    private var tiredSwing: Move?
    private var swingKey = 0
    private var feint = false
    private var tail: Tail?
    private var guardSequence: GuardSequence?
    private var knockdown: Knockdown?
    private var recovery: Recovery?
    private var idleFade = AnimationTuning.idleFade
    /// Slowest fade the next motion may take (an action cutting the get-up short).
    private var interruptFade: Float?
    private var cueKey = 0
    private(set) var activeCue: FighterCue = .none
    private var spentCue: FighterCue = .none
    private var contactTime: Double?
    private var lastFrame: Float = 0
    /// Lower-body clock chasing the motion's frame (see `Motion.lower`).
    private var lowerKey = Int.min
    private var lowerClip = ClipID.idle
    private var lowerFrame: Float = 0
    /// Per punch clip: the first frame after `contact` with the glove back near its guard.
    let retractedFrames: [ClipID: Float]
    /// Per punch clip: the approach re-timed to land at full glove speed.
    let strikeClocks: [ClipID: StrikeClock]
    /// 0…1 progress of the current punch's strike (0 while a told punch holds its chamber).
    private var strike: Float = 0
    /// Seconds the current punch's strike (the lunge) takes from its chamber to contact.
    private(set) var strikeDuration: Double = 0
    /// False while the feet must follow the clip freely (falling, lying, getting up).
    private(set) var feetPlanted = true
    /// True while a punch winds up (the engine's attacking state).
    var windingUp: Bool { stateID?.state == .attacking }

    init(motions: FighterMotionSet) {
        self.motions = motions
        var retracted: [ClipID: Float] = [:], clocks: [ClipID: StrikeClock] = [:]
        for id in [ClipID.jab, .hook, .uppercut] {
            if let frame = FighterReach.retractedFrame(motions, clip: id) { retracted[id] = frame }
            if motions[id] != nil { clocks[id] = StrikeClock(motions, clip: id) }
        }
        retractedFrames = retracted
        strikeClocks = clocks
    }

    func reset() {
        stateID = nil
        tail = nil
        guardSequence = nil
        knockdown = nil
        recovery = nil
        downTimes = nil
        lastAttack = .idle
        whiffed = false
        tiredSwing = nil
        feint = false
        contactTime = nil
        lunge = 0
        lungeMove = .idle
        lungeCarry = 0
        carryStart = 0
        carryMove = .idle
        reach = 0
        carryReach = 0
        aim = 0
        activeCue = .none
        spentCue = .none
        idleFade = AnimationTuning.idleFade
        interruptFade = nil
        tellFade = AnimationTuning.tellFade
        lowerKey = .min
        feetPlanted = true
    }

    private func nextKey() -> Int {
        serial += 1
        return serial
    }

    /// The punch met air (dodge, parry, downed target) or was an exhausted swing.
    func noteWhiff(_ move: Move) {
        switch stateID?.state {
        case .attacking?, .telling?: whiffed = true
        default: tiredSwing = move
        }
    }

    // MARK: - Frame

    func update(_ input: Input) -> Motion {
        enteredAction = false
        contactIn = nil
        let status = input.status
        let id = StateID(state: status.state, start: input.totalTicks - status.ticksInCurrentState, move: status.currentMove)
        if id != stateID {
            let previous = stateID
            stateID = id
            // The engine does not age idle fighters between rounds, and a KO is terminal.
            let repeated = previous?.state == status.state && (status.state == .idle || status.state == .ko)
            if !repeated { enter(status, previous: previous, input: input) }
        }
        var motion = frame(input)
        if let fade = interruptFade {
            motion.fade = max(motion.fade, fade)
            // A punch still has to be all punch by contact: its arm blends in faster.
            if status.state == .attacking { motion.armFade = min(fade, Float(strikeDuration) * AnimationTuning.strikeFadeShare) }
            interruptFade = nil
        }
        if let recovery, motion.clip != .getUp || recovery.exited {
            motion.warp = recovery.ambientWarp(input.now).composed(with: motion.warp)
            if recovery.exited, recovery.walked(input.now) { self.recovery = nil }
        }
        motion = followLower(motion, dt: input.dt)
        updateFeet(input, motion: motion)
        updateLunge(input)
        updateAim(input, motion: motion)
        lastFrame = motion.frame
        return motion
    }

    /// The lower body chases the motion's frame no faster than `maxLowerSpeedup`
    /// (a fast punch's step lands late and catches up during the recovery).
    private func followLower(_ motion: Motion, dt: Double) -> Motion {
        var motion = motion
        guard let clip = motions[motion.clip], !clip.loops, motion.key == lowerKey, motion.clip == lowerClip else {
            lowerKey = motion.key
            lowerClip = motion.clip
            lowerFrame = motion.frame
            return motion
        }
        let cap = clip.fps * AnimationTuning.maxLowerSpeedup
        let reach = cap * Float(max(0, dt)), gap = motion.frame - lowerFrame
        lowerFrame += min(reach, max(-reach, gap))
        if abs(motion.frame - lowerFrame) > 1e-3 {
            motion.lower = lowerFrame
            motion.lowerRate = cap
        }
        return motion
    }

    /// Feet follow the clip freely from the knockdown until the get-up is standing.
    private func updateFeet(_ input: Input, motion: Motion) {
        switch input.status.state {
        case .knockedDown, .ko:
            feetPlanted = false
        default:
            if motion.clip == .getUp, let rise = motions[.getUp] {
                feetPlanted = (motion.lower ?? motion.frame) >= rise.marker("standing", rise.lastFrame)
            } else {
                feetPlanted = true
            }
        }
    }

    /// Lower-body frame at `contact` for a punch flown over `ticks` (QA and spacing).
    static func contactLowerFrame(_ clip: RetargetedClip, ticks: Int, told: Bool) -> Float {
        let contact = clip.marker("contact", clip.lastFrame * 0.4)
        let window = Float(max(1, ticks)) / 60
        let start = punchStart(clip, window: window, told: told)
        let flight = told ? min(window, (contact - start) / (clip.fps * AnimationTuning.slowestStrike)) : window
        return min(contact, start + clip.fps * AnimationTuning.maxLowerSpeedup * flight)
    }

    /// Seconds a punch holds its chamber before striking, and the strike's duration.
    static func strikePlan(span: Float, fps: Float, window: Double, told: Bool) -> (hold: Double, duration: Double) {
        guard told else { return (0, window) }
        let duration = min(window, Double(span / (fps * AnimationTuning.slowestStrike)))
        return (window - duration, max(1.0 / 120, duration))
    }

    /// Untold punches skip ahead to fit the window, but never past `chamber`:
    /// the jab's lead-foot step lifts right after it and must not be blended away.
    static func punchStart(_ clip: RetargetedClip, window: Float, told: Bool) -> Float {
        let chamber = clip.marker("chamber", clip.lastFrame * 0.2)
        let contact = clip.marker("contact", clip.lastFrame * 0.4)
        return told ? chamber : min(chamber, max(0, contact - window * clip.fps * AnimationTuning.maxPunchSpeedup))
    }

    private func stateTime(_ input: Input) -> Double {
        (Double(input.status.ticksInCurrentState) + input.tickFraction) / 60
    }

    private func window(_ input: Input) -> Double { Double(max(1, input.status.stateDuration)) / 60 }

    private func punchClip(_ move: Move) -> ClipID {
        switch move {
        case .hook: .hook
        case .uppercut: .uppercut
        default: .jab
        }
    }

    // MARK: - Entering states

    private func enter(_ status: FighterStatus, previous: StateID?, input: Input) {
        let now = input.now
        let previousState = previous?.state ?? .idle
        let previousMove = previous?.move ?? .idle
        idleFade = AnimationTuning.idleFade
        var leavingTaunt = false
        if case .taunt = activeCue { leavingTaunt = true }
        if status.state != .idle {
            enteredAction = true
            if activeCue != .none { spentCue = activeCue }
            activeCue = .none
        }
        if status.state != .recovering { tiredSwing = nil }
        if knockdown != nil, ![.idle, .knockedDown, .ko].contains(status.state) { abandonGetUp(now) }
        switch status.state {
        case .idle:
            if previousState == .knockedDown, var down = knockdown {
                down.risen = true
                if down.getUpStart.map({ $0 > now }) ?? true { down.getUpStart = now }
                knockdown = down
            } else if [.blocking, .parrying, .dodging].contains(previousState) {
                startGuardExit(now)
            } else if previousState == .telling, previousMove == .feint || previousMove == .block || previousMove == .dodge {
                idleFade = 0.2
            }
            feint = false
            if previousState != .knockedDown { downTimes = nil }
        case .telling:
            tail = nil
            feint = false
            tellKey = nextKey()
            tellFade = leavingTaunt ? AnimationTuning.tauntInterruptFade : AnimationTuning.tellFade
            if status.currentMove == .block || status.currentMove == .dodge {
                let start = input.totalTicks - status.ticksInCurrentState
                let clip: ClipID = status.currentMove == .dodge ? .slip : (start.isMultiple(of: 2) ? .block : .bodyBlock)
                guardSequence = GuardSequence(clip: clip, key: tellKey, anchorTick: start, load: max(0.1, window(input)),
                                              fade: tellFade)
            } else {
                guardSequence = nil
            }
        case .attacking:
            tail = nil
            whiffed = false
            feint = false
            carryStart = lunge + lungeCarry
            carryReach = carryStart > 1e-4 ? (lunge * reach + lungeCarry * carryReach) / carryStart : 0
            carryMove = lungeMove
            lastAttack = status.currentMove
            told = previousState == .telling && previousMove == status.currentMove
            attackKey = told ? tellKey : nextKey()
        case .recovering:
            if previousState == .attacking {
                startPunchRecovery(input)
            } else if previousState == .telling, previousMove == .feint {
                feint = true
            } else if [.blocking, .parrying, .dodging].contains(previousState) {
                startGuardExit(now)
            } else if let move = tiredSwing {
                tail = nil
                swingKey = nextKey()
                lastAttack = move
            } else {
                feint = false
            }
        case .blocking, .parrying, .dodging:
            tail = nil
            if previousState == .telling, let sequence = guardSequence, sequence.key == tellKey { break }
            let clip: ClipID = status.state == .dodging ? .slip : .block
            let natural = Double((motions[clip]?.marker(clip == .slip ? "slipped" : "guardUp", 10) ?? 10) / (motions[clip]?.fps ?? 30))
            let load: Double
            let fade: Float
            switch status.state {
            case .parrying:
                load = AnimationTuning.parryLoad
                fade = AnimationTuning.parryFade
            case .dodging:
                load = min(natural, window(input) * 0.6, AnimationTuning.maxSlipLoad)
                fade = AnimationTuning.slipFade
            default:
                load = min(natural, AnimationTuning.guardLoad)
                fade = AnimationTuning.guardFade
            }
            guardSequence = GuardSequence(clip: clip, key: nextKey(), anchorTick: input.totalTicks - status.ticksInCurrentState,
                                          load: load, fade: fade)
        case .knockedDown, .ko:
            tail = nil
            guardSequence = nil
            recovery = nil
            feint = false
            startKnockdown(status, input: input)
        }
    }

    /// The fight resumed on the rise and the fighter acts at once: drop the rest of
    /// the get-up (the action blends in from it) and keep walking the root home under it.
    private func abandonGetUp(_ now: Double) {
        guard let down = knockdown else { return }
        if recovery == nil { recovery = makeRecovery(lyingAt: fallFrame(down, at: down.getUpStart ?? now)) }
        if var recovery {
            if recovery.walkStart == nil { recovery.startWalk(now) }
            recovery.exited = true
            self.recovery = recovery
        }
        knockdown = nil
        interruptFade = AnimationTuning.getUpInterruptFade
    }

    private func startPunchRecovery(_ input: Input) {
        let id = punchClip(lastAttack)
        guard let clip = motions[id] else { tail = nil; return }
        let contact = clip.marker("contact", clip.lastFrame * 0.4)
        let recovered = clip.marker("recovered", clip.lastFrame)
        // Snap the glove back to guard about as fast as it went out; the body settles slower.
        let retracted = min(recovered, max(contact, retractedFrames[id] ?? (contact + (recovered - contact) * 0.6)))
        var snap = max(AnimationTuning.retractTime, Double(retracted - contact) / Double(clip.fps * AnimationTuning.maxRetractSpeedup))
        if whiffed { snap *= AnimationTuning.whiffRetractStretch }
        // The body settles back over its stance by the end of the engine's recovery
        // window where it can (both fighters back at their spacing), never faster
        // than `maxSettleSpeedup` and never slower than `recoverSpeed`.
        let settle = window(input) - snap - (whiffed ? AnimationTuning.whiffHold : 0)
            - Double(AnimationTuning.punchExitFade) * 0.6
        let fitted = Float(Double(recovered - retracted) / max(0.05, settle)) / clip.fps
        var speed = min(AnimationTuning.maxSettleSpeedup, max(AnimationTuning.recoverSpeed, fitted))
        if whiffed { speed *= AnimationTuning.whiffSlowdown }
        let start = input.now - stateTime(input)
        contactTime = start
        let lower = lowerClip == id ? lowerFrame : contact
        tail = Tail(clip: id, key: attackKey, frame0: contact, now0: start, snapEnd: retracted, snapTime: snap, rate: clip.fps * speed,
                    hold: whiffed ? AnimationTuning.whiffHold : 0, end: recovered, exitFade: AnimationTuning.punchExitFade,
                    anticipation: told ? AnimationTuning.anticipation(lastAttack) : 0,
                    travelCap: FighterAnimator.travelOffset(clip.hipsPosition(at: lower), clip: clip).y, guardArm: true)
    }

    private func startGuardExit(_ now: Double) {
        guard let sequence = guardSequence, let clip = motions[sequence.clip] else { return }
        let holdEnd = clip.marker("holdEnd", clip.lastFrame * 0.5)
        // Carry on from where the guard is (a short parry may not have reached `holdEnd`).
        let up = clip.marker(sequence.clip == .slip ? "slipped" : "guardUp", clip.lastFrame * 0.3)
        tail = Tail(clip: sequence.clip, key: sequence.key, frame0: max(min(up, holdEnd), min(lastFrame, clip.lastFrame)), now0: now,
                    rate: clip.fps * AnimationTuning.guardExitRate, hold: 0, end: clip.lastFrame,
                    exitFade: AnimationTuning.guardExitFade, anticipation: 0)
        guardSequence = nil
    }

    private func startKnockdown(_ status: FighterStatus, input: Input) {
        let ko = status.state == .ko
        // A KO keeps the previous state's tick count; anchor it on this frame.
        let anchor = ko ? input.now : input.now - stateTime(input)
        let window = ko ? Double.infinity : window(input)
        let fall = motions[.knockdown], rise = motions[.getUp]
        let react = fall?.marker("react", 0) ?? 0
        let settled = fall?.marker("settled", fall?.lastFrame ?? 0) ?? 0
        let fallTime = Double(max(0, settled - react)) / Double(fall?.fps ?? 30)
        let upTime = Double(rise?.marker("standing", rise?.lastFrame ?? 0) ?? 0) / Double(rise?.fps ?? 30)
        var speed = 1.0
        if !ko {
            let budget = window - AnimationTuning.standingLead - AnimationTuning.minimumLie
            speed = min(AnimationTuning.maxDownSpeedup, max(1, (fallTime + upTime) / max(0.1, budget)))
        }
        let fallRate = Float(Double(fall?.fps ?? 30) * speed)
        var getUpStart: Double?
        if !ko {
            getUpStart = max(anchor + window - AnimationTuning.standingLead - upTime / speed, anchor + fallTime / speed)
        }
        knockdown = Knockdown(key: nextKey(), getUpKey: nextKey(), anchor: anchor, fallRate: fallRate,
                              getUpRate: Float(Double(rise?.fps ?? 30) * speed), getUpStart: getUpStart)
        downTimes = DownTimes(ground: anchor + Double(groundFrame() - react) / Double(fallRate), rise: anchor + window)
    }

    /// When the body lands: the `ground` marker, or earlier if the hips are already down.
    private func groundFrame() -> Float {
        guard let fall = motions[.knockdown] else { return 0 }
        let marker = fall.marker("ground", fall.lastFrame)
        let standing = fall.hips.first?.y ?? 0
        let lowest = fall.hips.map(\.y).min() ?? 0
        let threshold = lowest + (standing - lowest) * 0.15
        let react = Int(fall.marker("react", 0))
        let landed = fall.hips.indices.first { $0 >= react && fall.hips[$0].y <= threshold }.map(Float.init) ?? marker
        return min(marker, landed)
    }

    // MARK: - Per-state motion

    private func frame(_ input: Input) -> Motion {
        switch input.status.state {
        case .idle:
            return settle(input)
        case .telling:
            if let sequence = guardSequence, sequence.key == tellKey { return guardMotion(sequence, input: input) }
            return tellMotion(input)
        case .attacking:
            return attackMotion(input)
        case .recovering:
            if feint { return feintMotion(input) }
            if tiredSwing != nil { return swingMotion(input) }
            return settle(input)
        case .blocking, .parrying, .dodging:
            if let sequence = guardSequence { return guardMotion(sequence, input: input) }
            return settle(input)
        case .knockedDown, .ko:
            return downMotion(input)
        }
    }

    private func tellMotion(_ input: Input) -> Motion {
        let move = input.status.currentMove
        let id = punchClip(move)
        guard let clip = motions[id] else { return idleLoop(input) }
        let chamber = clip.marker("chamber", clip.lastFrame * 0.2)
        let load = max(AnimationTuning.minimumTellLoad, window(input) * AnimationTuning.tellLoadFraction)
        let u = stateTime(input) / load
        return Motion(clip: id, frame: chamber * Float(easeInOut(u)), rate: u < 1 ? chamber / Float(load) : 0, key: tellKey,
                      fade: tellFade, anticipation: AnimationTuning.anticipation(move), hold: u >= 1 ? 1 : 0)
    }

    private func attackMotion(_ input: Input) -> Motion {
        let id = punchClip(lastAttack)
        guard let clip = motions[id] else { return idleLoop(input) }
        let chamber = clip.marker("chamber", clip.lastFrame * 0.2)
        let contact = clip.marker("contact", clip.lastFrame * 0.4)
        let window = window(input)
        let start = told ? chamber : Self.punchStart(clip, window: Float(window), told: false)
        let clock = strikeClocks[id] ?? StrikeClock(motions, clip: id)
        let t0 = clock.tau(at: start), t1 = clock.tau(at: contact)
        let plan = Self.strikePlan(span: t1 - t0, fps: clip.fps, window: window, told: told)
        let t = stateTime(input)
        strike = Float(min(1, max(0, (t - plan.hold) / plan.duration)))
        strikeDuration = plan.duration
        contactIn = max(0, plan.hold + plan.duration - t)
        let frame = clock.frame(at: t0 + (t1 - t0) * strike)
        let holding = t < plan.hold
        let rate = holding ? 0 : (t1 - t0) / Float(plan.duration) / clock.slope(at: frame)
        var motion = Motion(clip: id, frame: frame, rate: rate, key: attackKey, fade: AnimationTuning.playerPunchFade,
                            anticipation: told ? AnimationTuning.anticipation(lastAttack) : 0, hold: holding ? 1 : 0)
        motion.offArm = start + (contact - start) * strike
        if id == .hook, !told { motion.armFade = AnimationTuning.playerHookArmFade }
        return motion
    }

    /// Feint: a short jab twitch out of the loaded tell, then back to guard.
    private func feintMotion(_ input: Input) -> Motion {
        guard let clip = motions[.jab] else { return idleLoop(input) }
        let chamber = clip.marker("chamber", clip.lastFrame * 0.2)
        let contact = clip.marker("contact", clip.lastFrame * 0.4)
        let t = stateTime(input)
        let frame = t < 0.2
            ? chamber + (contact - chamber) * 0.3 * Float(sin(.pi * t / 0.2))
            : chamber * Float(1 - easeInOut((t - 0.2) / 0.3))
        return Motion(clip: .jab, frame: frame, rate: 0, key: tellKey, fade: tellFade,
                      anticipation: AnimationTuning.anticipation(.feint))
    }

    /// Exhausted swing: a weak half-punch that never reaches full extension.
    private func swingMotion(_ input: Input) -> Motion {
        let id = punchClip(lastAttack)
        guard let clip = motions[id] else { return idleLoop(input) }
        let chamber = clip.marker("chamber", clip.lastFrame * 0.2)
        let contact = clip.marker("contact", clip.lastFrame * 0.4)
        let reach = Float(sin(.pi * min(1, stateTime(input) / 0.35)))
        return Motion(clip: id, frame: chamber + (contact - chamber) * 0.55 * reach, rate: 0, key: swingKey, fade: 0.08)
    }

    private func guardMotion(_ sequence: GuardSequence, input: Input) -> Motion {
        guard let clip = motions[sequence.clip] else { return idleLoop(input) }
        let up = clip.marker(sequence.clip == .slip ? "slipped" : "guardUp", clip.lastFrame * 0.3)
        let holdEnd = max(up, clip.marker("holdEnd", up))
        let elapsed = (Double(input.totalTicks - sequence.anchorTick) + input.tickFraction) / 60
        let frame: Float
        let rate: Float
        if elapsed < sequence.load || input.status.state == .telling {
            frame = up * Float(easeOut(elapsed / sequence.load))
            rate = elapsed < sequence.load ? up / Float(sequence.load) : 0
        } else {
            // Stretch the hold over the rest of the state, but never play it faster than life.
            let stateEnd = input.totalTicks - input.status.ticksInCurrentState + input.status.stateDuration
            let span = max(1.0 / 60, Double(stateEnd - sequence.anchorTick) / 60 - sequence.load)
            rate = min(clip.fps, (holdEnd - up) / Float(span))
            frame = min(holdEnd, up + rate * Float(elapsed - sequence.load))
        }
        return Motion(clip: sequence.clip, frame: min(frame, clip.lastFrame), rate: rate, key: sequence.key, fade: sequence.fade,
                      hold: elapsed >= sequence.load ? 0.6 : 0)
    }

    // MARK: - Knockdown and get-up

    private func downMotion(_ input: Input) -> Motion {
        guard var down = knockdown else { return idleLoop(input) }
        let now = input.now
        if let start = down.getUpStart, now >= start, let rise = motions[.getUp] {
            if recovery == nil { recovery = makeRecovery(lyingAt: fallFrame(down, at: start)) }
            let standing = rise.marker("standing", rise.lastFrame)
            down.getUpFrame = min(standing, Float(now - start) * down.getUpRate)
            knockdown = down
            return Motion(clip: .getUp, frame: down.getUpFrame, rate: down.getUpFrame < standing ? down.getUpRate : 0,
                          key: down.getUpKey, fade: AnimationTuning.getUpFade, warp: recovery?.getUpWarp(now) ?? .identity)
        }
        let frame = fallFrame(down, at: now)
        let still = motions[.knockdown].map { frame >= $0.lastFrame } ?? true
        return Motion(clip: .knockdown, frame: frame, rate: still ? 0 : down.fallRate, key: down.key,
                      fade: AnimationTuning.knockdownFade, hold: still ? 0.5 : 0, warp: travelWarp(frame))
    }

    private func fallFrame(_ down: Knockdown, at now: Double) -> Float {
        guard let fall = motions[.knockdown] else { return 0 }
        return min(fall.lastFrame, fall.marker("react", 0) + Float(max(0, now - down.anchor)) * down.fallRate)
    }

    /// Optionally shortens the fall's horizontal travel.
    private func travelWarp(_ frame: Float) -> RootWarp {
        guard AnimationTuning.knockdownTravel < 1, let fall = motions[.knockdown] else { return .identity }
        var delta = fall.hipsPosition(at: frame) - fall.hipsPosition(at: fall.marker("react", 0))
        delta.y = 0
        return RootWarp(yaw: 0, offset: -delta * (1 - AnimationTuning.knockdownTravel))
    }

    private func makeRecovery(lyingAt fallFrame: Float) -> Recovery {
        guard let fall = motions[.knockdown], let rise = motions[.getUp] else { return Recovery(start: .identity, align: .identity) }
        var lying = FighterPose(hips: motions.heads[0]), first = lying, last = lying, idle = lying
        fall.sample(fallFrame, into: &lying)
        travelWarp(fallFrame).apply(&lying)
        rise.sample(0, into: &first)
        rise.sample(rise.lastFrame, into: &last)
        motions[.idle]?.sample(0, into: &idle)
        // Lying: heading of the body axis (hips → neck); standing: the hips' facing.
        func bodyHeading(_ pose: FighterPose) -> Float {
            let joints = pose.joints(heads: motions.heads)
            let axis = joints[FighterBone.neck.rawValue] - joints[FighterBone.hips.rawValue]
            return simd_length(SIMD2(axis.x, axis.z)) > 1e-3 ? atan2(axis.x, axis.z) : 0
        }
        func facing(_ pose: FighterPose) -> Float {
            let forward = pose.rotations[0].act(SIMD3<Float>(0, 0, 1))
            return simd_length(SIMD2(forward.x, forward.z)) > 1e-3 ? atan2(forward.x, forward.z) : 0
        }
        func placing(_ from: FighterPose, onto to: FighterPose, yaw: Float) -> RootWarp {
            let q = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            let moved = q.act(from.hips)
            return RootWarp(yaw: yaw, offset: SIMD3<Float>(to.hips.x - moved.x, 0, to.hips.z - moved.z))
        }
        let start = placing(first, onto: lying, yaw: bodyHeading(lying) - bodyHeading(first))
        let align = placing(idle, onto: last, yaw: facing(last) - facing(idle))
        return Recovery(start: start.isIdentity ? .identity : start, align: align.isIdentity ? .identity : align)
    }

    /// Post-rise continuation of the get-up, walking back to the mark from `standing`.
    private func risingMotion(_ input: Input) -> Motion? {
        guard var down = knockdown, down.risen, let rise = motions[.getUp] else { return nil }
        let now = input.now
        if recovery == nil { recovery = makeRecovery(lyingAt: fallFrame(down, at: down.getUpStart ?? now)) }
        down.getUpFrame += down.getUpRate * Float(max(0, input.dt))
        knockdown = down
        let standing = rise.marker("standing", rise.lastFrame)
        if var recovery, recovery.walkStart == nil, down.getUpFrame >= standing {
            recovery.startWalk(now)
            self.recovery = recovery
        }
        if down.getUpFrame < rise.lastFrame - AnimationTuning.getUpExitFade * down.getUpRate {
            return Motion(clip: .getUp, frame: down.getUpFrame, rate: down.getUpRate, key: down.getUpKey,
                          fade: AnimationTuning.getUpFade, warp: recovery?.getUpWarp(now) ?? .identity)
        }
        knockdown = nil
        recovery?.exited = true
        if recovery?.walkStart == nil { recovery?.walkStart = now }
        idleFade = AnimationTuning.getUpExitFade
        return nil
    }

    // MARK: - Idle, tails and cues

    private func settle(_ input: Input) -> Motion {
        let now = input.now
        if let rising = risingMotion(input) { return rising }
        if let tail {
            if !tail.finished(now) { return tail.motion(now) }
            idleFade = tail.exitFade
            self.tail = nil
        }
        if input.cue != activeCue, case .taunt = activeCue { idleFade = AnimationTuning.tauntFadeOut }
        switch input.cue {
        case let .taunt(start, until) where now >= start && now < until && !input.reducedMotion && input.cue != spentCue:
            if let victory = motions[.victory] {
                if activeCue != input.cue { activeCue = input.cue; cueKey = nextKey() }
                let armsUp = victory.marker("armsUp", victory.lastFrame * 0.2)
                let armsDown = victory.marker("armsDown", victory.lastFrame * 0.8)
                let frame = min(armsDown, armsUp - victory.fps * AnimationTuning.tauntLead + Float(now - start) * victory.fps)
                return Motion(clip: .victory, frame: frame, rate: victory.fps, key: cueKey, fade: AnimationTuning.tauntFadeIn)
            }
        case let .celebrate(start) where now >= start && input.cue != spentCue:
            if let victory = motions[.victory] {
                if activeCue != input.cue { activeCue = input.cue; cueKey = nextKey() }
                let frame = Float(now - start) * victory.fps
                if frame < victory.lastFrame - victory.fps * 0.5 {
                    return Motion(clip: .victory, frame: frame, rate: victory.fps, key: cueKey, fade: AnimationTuning.victoryFade)
                }
                spentCue = input.cue
                idleFade = 0.5
            }
        default:
            break
        }
        if activeCue != .none, case .taunt = activeCue { spentCue = activeCue }
        activeCue = .none
        return idleLoop(input)
    }

    private func idleLoop(_ input: Input) -> Motion {
        guard let clip = motions[.idle] else { return Motion(clip: .idle, frame: 0, rate: 0, key: 0, fade: idleFade) }
        if input.reducedMotion { return Motion(clip: .idle, frame: 0, rate: 0, key: 0, fade: idleFade) }
        let frame = Float((input.now * idleRate + idlePhase) * Double(clip.fps))
        return Motion(clip: .idle, frame: frame, rate: clip.fps * Float(idleRate), key: 0, fade: idleFade)
    }

    // MARK: - Root slide toward the target during punches

    private func updateLunge(_ input: Input) {
        switch input.status.state {
        case .attacking:
            // The body drives through contact (no ease-out into the target).
            let p = strike
            lungeMove = lastAttack
            lunge = p * p * (2 - p)
            // The previous punch's step hands over to this one along a single path
            // (held through a told punch's chamber, no dip back toward neutral).
            lungeCarry = carryStart * (1 - lunge)
            contactTime = nil
        default:
            lungeCarry = max(0, lungeCarry - Float(input.dt / AnimationTuning.lungeRelease))
            if let contactTime {
                let t = input.now - contactTime
                lunge = t < AnimationTuning.lungeRelease ? 1 - Float(easeInOut(t / AnimationTuning.lungeRelease)) : 0
                if lunge == 0 { self.contactTime = nil }
            } else {
                lunge = max(0, lunge - Float(input.dt / AnimationTuning.lungeRelease))
            }
        }
    }

    // MARK: - Steering the punch onto the target

    /// Full steer at contact; after it the arm lets go of the target at once (the
    /// glove snaps back to guard instead of following a recoiling head).
    private func updateAim(_ input: Input, motion: Motion) {
        if input.status.state == .attacking {
            aim = smoothstep(strike)
            aimClip = punchClip(lastAttack)
        } else if let contactTime {
            // Fully on target at contact, then let go at once.
            aim = 1 - smoothstep(Float((input.now - contactTime) / AnimationTuning.aimRelease))
        } else {
            aim = max(0, aim - Float(input.dt / AnimationTuning.aimRelease))
        }
    }
}
