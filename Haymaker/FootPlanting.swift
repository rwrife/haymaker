import simd

/// Foot-contact tuning (stage units ≈ rig units; fighters are 2.7 tall).
enum FootTuning {
    /// How far the clip's foot may wander from a planted foot before it steps.
    static let stepDistance: Float = 0.2
    /// A planted foot may ease toward the clip's foot this fast (units per second).
    static let creep: Float = 0.12
    /// The clip's toe this far off the floor means the clip itself is stepping.
    static let liftOff: Float = 0.07
    /// The clip's toe this close to the floor is grounded.
    static let landing: Float = 0.04
    static let minStep: Float = 0.12
    static let maxStep: Float = 0.3
    static let stepPerUnit: Float = 0.35
    static let release: Float = 0.15
    /// Share of the step after which a grounded destination stops moving (no landing slide).
    static let destinationFreeze: Float = 0.6
    /// Hip-to-ankle stretch (share of leg length) that forces a step.
    static let strain: Float = 0.985
    /// The stretch is extrapolated this far ahead (seconds), so a fast lunge starts
    /// the trailing foot's step before the leg locks straight.
    static let strainLookahead: Float = 0.1
    /// A strained step (the body running away from it) stays in the air past this
    /// share and keeps chasing the clip's foot until the leg can reach the ground.
    static let chaseHold: Float = 0.8
    /// How fast a strained step's destination chases the clip's foot (units per second),
    /// ramped in and out over `chaseRamp` seconds so the foot never jerks.
    static let chaseFollow: Float = 10
    static let chaseRamp: Float = 0.08
    /// A step chases once its leg (extrapolated) can no longer reach it, and lets go
    /// below `chaseRelease` (a straight but reaching leg is fine: taunts, victory).
    static let chaseStrain: Float = 1.0
    static let chaseRelease: Float = 0.98
    /// Share of the leg length where the IK reach starts to saturate (soft knee lock).
    static let softKnee: Float = 0.96
    /// A lifted (free) foot follows the clip's foot at most this fast (units per second),
    /// so handing a foot between the planter and the clip never pops.
    static let freeFollow: Float = 3
    /// A step's destination follows the clip's foot at most this fast (units per second).
    static let destinationFollow: Float = 6
    /// Ankle-to-ankle spread (share of the guard stance) where a moving foot starts to
    /// be held in, and the most it may reach: the stance never splays into a lunge.
    static let stanceSoft: Float = 1.03
    static let stanceLimit: Float = 1.12
    /// A planted foot holding the other foot's step in drags up behind it once its own
    /// target is this far away (shorter moves stay planted).
    static let minDrag: Float = 0.05
}

/// Keeps grounded feet planted on the canvas while the body moves (root slides,
/// lunges, separation, crossfades, hit reactions) and turns larger moves into
/// short lifted steps. Runs on the final pose, in the root's parent (stage) space,
/// with two-bone leg IK; the feet keep the clip's orientation and height.
struct FootPlanter {
    enum Phase: Equatable, Sendable { case planted, stepping, free }

    struct Foot: Sendable {
        let upLeg: Int
        var phase: Phase = .free
        /// Stage XZ of the planted ball of the foot.
        var lock = SIMD2<Float>.zero
        var from = SIMD2<Float>.zero
        var to = SIMD2<Float>.zero
        /// Landing clock (held in the air while a strained step chases).
        var elapsed: Float = 0
        /// Travel clock: drives the step's XZ and never holds.
        var travel: Float = 0
        var duration: Float = FootTuning.minStep
        /// Displayed XZ of a step and where it is heading (after the stance hold).
        var at = SIMD2<Float>.zero
        var goal = SIMD2<Float>.zero
        /// Share of the remaining way to `goal` covered this frame.
        var advance: Float = 0
        /// Late in a grounded step its destination stays put (no landing slide).
        var settling = false
        var height: Float = 0
        var releasing = false
        /// Time since the foot was let go: it crossfades off its plant (or its step's own
        /// path) onto the clip's foot over `FootTuning.release`.
        var released: Float = 0
        var strained = false
        /// Last solved hip–ankle distance as a share of the leg's length.
        var stretch: Float = 0
        /// Its rate of change (per second), for the strain lookahead.
        var stretchRate: Float = 0
        /// The leg (extrapolated) cannot reach a step's landing spot: it chases the clip's foot.
        var overreach = false
        /// Hip-to-landing-spot distance (share of the leg's length) of a step, and its rate.
        var landing: Float = 0
        var landingRate: Float = 0
        /// 0…1 how hard a strained step chases the clip's foot.
        var chase: Float = 0
        /// `lock` holds the displayed position (set on the first solve).
        var placed = false
        var toe: Int { upLeg + 3 }
        var foot: Int { upLeg + 2 }
    }

    private(set) var feet = [Foot(upLeg: FighterBone.leftUpLeg.rawValue), Foot(upLeg: FighterBone.rightUpLeg.rawValue)]
    private(set) var steps = 0

    mutating func reset() {
        feet = feet.map { Foot(upLeg: $0.upLeg) }
    }

    func phase(_ side: Int) -> Phase { feet[side].phase }
    func stretch(_ side: Int) -> Float { feet[side].stretch }

    /// Plant, step or release each foot and bend the legs to match.
    /// `toStage` maps rig space to stage space (the root's transform); `guardSpread`
    /// is the guard stance (left-minus-right ankle XZ, rig space).
    mutating func solve(_ pose: inout FighterPose, heads: [SIMD3<Float>], toStage: simd_float4x4, enabled: Bool, dt: Float,
                        guardSpread: SIMD2<Float>? = nil) {
        let fromStage = toStage.inverse
        let joints = pose.joints(heads: heads)
        var targets: [SIMD3<Float>?] = [nil, nil]
        // Stage XZ of each clip toe, and from the toe to its ankle (the feet keep their orientation).
        let flats = feet.map { foot -> SIMD2<Float> in
            let p = Self.transform(toStage, joints[foot.toe])
            return SIMD2<Float>(p.x, p.z)
        }
        let heels = feet.map { foot -> SIMD2<Float> in
            let d = Self.transform(toStage, joints[foot.foot]) - Self.transform(toStage, joints[foot.toe])
            return SIMD2<Float>(d.x, d.z)
        }
        let stance: Float = guardSpread.map {
            let v = toStage * SIMD4<Float>($0.x, 0, $0.y, 0)
            return simd_length(SIMD2<Float>(v.x, v.z))
        } ?? 0
        var landed = [false, false]
        var grounds: [Float] = [0, 0]
        // How straight the clip itself holds each leg: a pose standing tall (taunts, victory)
        // is not a strain, only reaching past it is.
        let natural = feet.map { foot -> Float in
            let length = simd_distance(heads[foot.upLeg + 1], heads[foot.upLeg]) + simd_distance(heads[foot.foot], heads[foot.upLeg + 1])
            return simd_distance(joints[foot.foot], joints[foot.upLeg]) / length
        }
        for i in feet.indices {
            var foot = feet[i]
            let animated = Self.transform(toStage, joints[foot.toe])
            let ground = Self.transform(toStage, SIMD3<Float>(joints[0].x, heads[foot.toe].y, joints[0].z)).y
            let lift = animated.y - ground
            grounds[i] = min(animated.y, ground + FootTuning.landing)
            let flat = flats[i]
            let other = feet[1 - i]
            let otherStepping = other.phase == .stepping
            if !foot.placed {
                foot.placed = true
                foot.lock = flat
            }
            if !enabled {
                switch foot.phase {
                case .planted: start(&foot, from: foot.lock, to: foot.lock, release: true)
                case .stepping:
                    if !foot.releasing {
                        foot.releasing = true
                        foot.released = 0
                    }
                case .free: break
                }
            } else {
                switch foot.phase {
                case .free:
                    foot.lock = Self.approach(foot.lock, flat, FootTuning.freeFollow * dt)
                    if lift < FootTuning.landing { foot.phase = .planted }
                case .planted:
                    let drift = flat - foot.lock, distance = simd_length(drift)
                    let creep = FootTuning.creep * dt
                    if distance > 1e-6 { foot.lock += drift * min(1, creep / distance) }
                    let error = simd_distance(flat, foot.lock)
                    let lifting = lift > FootTuning.liftOff
                    let forced = foot.strained || error > 2 * FootTuning.stepDistance
                    // The stance is (or the other foot is stepping) wider than it may be from here: drag
                    // this foot up behind (a planted pair gathers with the foot further from the clip).
                    let otherAt = other.phase == .planted ? other.lock : flats[1 - i]
                    let gather = other.phase != .planted || error > simd_distance(flats[1 - i], other.lock)
                    let holding = stance > 0 && gather && error > FootTuning.minDrag && !(otherStepping && other.releasing)
                        && simd_distance(otherAt + heels[1 - i], foot.lock + heels[i]) > stance * FootTuning.stanceLimit
                    if lifting || forced || holding || (error > FootTuning.stepDistance && !otherStepping) {
                        start(&foot, from: foot.lock, to: flat, release: false)
                    }
                case .stepping:
                    break
                }
            }
            if foot.phase == .stepping {
                let span = max(1e-4, foot.duration)
                // Only a step still well in the air starts chasing (a late chase would skate a low foot).
                let chasing = enabled && foot.overreach && !foot.releasing
                    && (foot.chase > 0 || foot.elapsed < FootTuning.chaseHold * span)
                let ramp = dt / FootTuning.chaseRamp
                foot.chase = chasing ? min(1, foot.chase + ramp) : max(0, foot.chase - ramp)
                if !chasing || foot.elapsed + dt < FootTuning.chaseHold * span {
                    foot.elapsed += dt
                } else {
                    foot.elapsed = max(foot.elapsed, min(foot.elapsed + dt, FootTuning.chaseHold * span))
                }
                let before = min(1, foot.travel / span)
                foot.travel = min(span, foot.travel + dt)
                let u = min(1, foot.elapsed / span), p = min(1, foot.travel / span)
                foot.settling = false
                if foot.releasing {
                    // The step's own path (or the plant) is what the foot crossfades off.
                } else if foot.chase > 0 {
                    let base = p < FootTuning.destinationFreeze ? FootTuning.destinationFollow : 0
                    let pace = base + (FootTuning.chaseFollow - base) * smoothstep(foot.chase)
                    foot.to = Self.approach(foot.to, flat, pace * dt)
                    foot.height = max(foot.height, min(0.1, simd_distance(foot.from, foot.to) * 0.35))
                } else if p < FootTuning.destinationFreeze {
                    // Track the clip's foot, but a crossfade jerking it can't jerk the step.
                    foot.to = Self.approach(foot.to, flat, FootTuning.destinationFollow * dt)
                } else if lift > FootTuning.landing {
                    // The clip lifts the foot again late in the step: follow it at a pace.
                    foot.to = Self.approach(foot.to, flat, FootTuning.freeFollow * dt)
                } else {
                    foot.settling = true
                }
                if !foot.settling { foot.goal = foot.to }
                // Cover this frame's share of the remaining way: a destination that moves
                // mid-step is spread over the rest of the step instead of jerking the foot.
                let eased = smoothstep(before)
                foot.advance = before >= 1 ? 1 : min(1, (smoothstep(p) - eased) / max(1e-4, 1 - eased))
                var xz = foot.at + (foot.goal - foot.at) * foot.advance
                var y = foot.height > 0 ? max(animated.y, ground + foot.height * sin(.pi * u)) : animated.y
                var done = u >= 1
                if foot.releasing {
                    // Blend onto the clip's (moving) foot as a whole, not a share of the way left
                    // each frame: the foot joins the fall at its pace instead of snapping on at the end.
                    foot.at = xz
                    foot.released += dt
                    let w = smoothstep(min(1, foot.released / FootTuning.release))
                    xz += (flat - xz) * w
                    y += (animated.y - y) * w
                    done = foot.released / FootTuning.release >= 1
                }
                targets[i] = SIMD3<Float>(xz.x, y, xz.y)
                if done {
                    foot.lock = xz
                    landed[i] = true
                    if foot.releasing || !enabled {
                        foot.phase = .free
                        foot.releasing = false
                    } else {
                        foot.phase = lift > FootTuning.landing ? .free : .planted
                    }
                }
            } else if foot.phase == .planted {
                targets[i] = SIMD3<Float>(foot.lock.x, animated.y, foot.lock.y)
            } else if enabled {
                targets[i] = SIMD3<Float>(foot.lock.x, animated.y, foot.lock.y)
            } else {
                foot.lock = flat
            }
            feet[i] = foot
        }
        if stance > 0, enabled { holdStance(&targets, heels: heels, stance: stance, landed: landed) }
        for i in feet.indices {
            guard let target = targets[i] else {
                feet[i].strained = false
                feet[i].overreach = false
                feet[i].stretch = 0
                feet[i].stretchRate = 0
                feet[i].landing = 0
                feet[i].landingRate = 0
                continue
            }
            let stretch = Self.solveLeg(&pose, heads: heads, upLeg: feet[i].upLeg, toeTarget: Self.transform(fromStage, target))
            if dt > 0, feet[i].stretch > 0 { feet[i].stretchRate = (stretch - feet[i].stretch) / dt }
            feet[i].stretch = stretch
            let predicted = stretch + max(0, feet[i].stretchRate) * FootTuning.strainLookahead
            feet[i].strained = predicted > max(FootTuning.strain, natural[i] + 0.015)
            guard feet[i].phase == .stepping, !feet[i].releasing else {
                feet[i].overreach = false
                feet[i].landing = 0
                feet[i].landingRate = 0
                continue
            }
            feet[i].at = SIMD2<Float>(target.x, target.z)
            // A step chases when its landing spot (not the foot in flight) runs out of the leg's reach.
            let spot = SIMD3<Float>(feet[i].goal.x, grounds[i], feet[i].goal.y)
            let landing = Self.reach(pose, heads: heads, upLeg: feet[i].upLeg, toeTarget: Self.transform(fromStage, spot))
            if dt > 0, feet[i].landing > 0 { feet[i].landingRate = (landing - feet[i].landing) / dt }
            feet[i].landing = landing
            let reaching = landing + max(0, feet[i].landingRate) * FootTuning.strainLookahead
            let strain = max(FootTuning.chaseStrain, natural[i] + 0.02), release = max(FootTuning.chaseRelease, natural[i] + 0.005)
            feet[i].overreach = reaching > (feet[i].overreach ? release : strain)
        }
    }

    /// A foot in the air (stepping or following the clip) never splays the stance wider
    /// than `stanceLimit` × the guard: past `stanceSoft` its destination is eased in
    /// toward the other foot (planted feet never slide), and a step lands there.
    private mutating func holdStance(_ targets: inout [SIMD3<Float>?], heels: [SIMD2<Float>], stance: Float, landed: [Bool]) {
        let soft = stance * FootTuning.stanceSoft, limit = stance * FootTuning.stanceLimit
        for i in feet.indices {
            guard var target = targets[i] else { continue }
            var foot = feet[i]
            let stepping = foot.phase == .stepping && !foot.releasing
            guard stepping || foot.phase == .free || landed[i] else { continue }
            guard let other = targets[1 - i] else { continue }
            let anchor = SIMD2<Float>(other.x, other.z) + heels[1 - i]
            // `to` keeps tracking the clip unheld (so holding never compounds); the hold is reapplied each frame.
            let held = { (p: SIMD2<Float>) -> SIMD2<Float> in
                let d = p + heels[i] - anchor, width = simd_length(d)
                guard width > soft else { return p }
                let wanted = soft + (limit - soft) * (1 - exp(-(width - soft) / (limit - soft)))
                return p - d * (1 - wanted / width)
            }
            let xz: SIMD2<Float>
            if foot.settling && (stepping || landed[i]) {
                // A settling step keeps the hold it froze with; it only gives way past the limit.
                let d = foot.goal + heels[i] - anchor, width = simd_length(d)
                guard width > limit else { continue }
                foot.goal -= d * (1 - limit / width)
                if stepping {
                    xz = foot.at + (foot.goal - foot.at) * foot.advance
                } else {
                    foot.lock = foot.goal
                    xz = foot.lock
                }
            } else if stepping {
                foot.goal = held(foot.to)
                xz = foot.at + (foot.goal - foot.at) * foot.advance
            } else {
                foot.lock = held(foot.lock)
                xz = foot.lock
            }
            target.x = xz.x
            target.z = xz.y
            targets[i] = target
            feet[i] = foot
        }
        // Steps leaving a wide stance (or feet pivoting under it) still close: whatever is
        // in the air takes in the spread past the limit, a planted or landing foot never moves.
        guard let a = targets[0], let b = targets[1] else { return }
        let d = SIMD2<Float>(a.x, a.z) + heels[0] - SIMD2<Float>(b.x, b.z) - heels[1], width = simd_length(d)
        guard width > limit else { return }
        let free = feet.indices.map { i in
            !landed[i] && (feet[i].phase == .free || (feet[i].phase == .stepping && !feet[i].releasing)) ? Float(1) : 0
        }
        let shares = free[0] + free[1]
        guard shares > 0 else { return }
        let close = d / width * (width - limit) / shares
        for i in feet.indices where free[i] > 0 {
            let move = i == 0 ? -close : close
            targets[i]?.x += move.x
            targets[i]?.z += move.y
            if feet[i].phase == .free { feet[i].lock += move }
        }
    }

    private mutating func start(_ foot: inout Foot, from: SIMD2<Float>, to: SIMD2<Float>, release: Bool) {
        let distance = simd_distance(from, to)
        foot.phase = .stepping
        foot.from = from
        foot.to = to
        foot.at = from
        foot.goal = to
        foot.settling = false
        foot.advance = 0
        foot.travel = 0
        foot.landing = 0
        foot.landingRate = 0
        foot.elapsed = 0
        foot.releasing = release
        foot.released = 0
        foot.duration = release ? FootTuning.release
            : min(FootTuning.maxStep, FootTuning.minStep + distance * FootTuning.stepPerUnit)
        foot.height = release ? 0 : min(0.1, max(0.03, distance * 0.35))
        if !release { steps += 1 }
    }

    static func approach(_ from: SIMD2<Float>, _ to: SIMD2<Float>, _ limit: Float) -> SIMD2<Float> {
        let d = to - from, length = simd_length(d)
        return length <= limit ? to : from + d * (limit / length)
    }

    static func transform(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(p, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    /// Hip-to-ankle distance (share of the leg's length) for a toe target, keeping the clip's foot orientation.
    static func reach(_ pose: FighterPose, heads: [SIMD3<Float>], upLeg: Int, toeTarget: SIMD3<Float>) -> Float {
        let leg = upLeg + 1, foot = upLeg + 2, toe = upLeg + 3
        let globals = pose.globals(), joints = pose.joints(heads: heads)
        let ankleTarget = toeTarget - globals[foot].act(heads[toe] - heads[foot])
        let length = simd_distance(heads[leg], heads[upLeg]) + simd_distance(heads[foot], heads[leg])
        return simd_distance(ankleTarget, joints[upLeg]) / length
    }

    /// Two-bone IK: bend the knee to the needed hip–ankle distance, swing the thigh
    /// onto the target, and keep the foot's rig-space orientation from the clip.
    /// Returns the requested hip–ankle distance as a share of the leg's length.
    @discardableResult
    static func solveLeg(_ pose: inout FighterPose, heads: [SIMD3<Float>], upLeg: Int, toeTarget: SIMD3<Float>) -> Float {
        let leg = upLeg + 1, foot = upLeg + 2, toe = upLeg + 3
        let globals = pose.globals(), joints = pose.joints(heads: heads)
        let footGlobal = globals[foot]
        let ankleTarget = toeTarget - footGlobal.act(heads[toe] - heads[foot])
        let hip = joints[upLeg], knee = joints[leg], ankle = joints[foot]
        let thigh = simd_distance(heads[leg], heads[upLeg]), shin = simd_distance(heads[foot], heads[leg])
        let wanted = simd_distance(ankleTarget, hip)
        // Soft IK: near full extension the reach saturates smoothly, so a leg passing
        // through straight never snaps the knee.
        let longest = (thigh + shin) * 0.999, soft = (thigh + shin) * FootTuning.softKnee
        var reach = max(wanted, abs(thigh - shin) + 1e-3)
        if reach > soft { reach = soft + (longest - soft) * (1 - exp(-(reach - soft) / (longest - soft))) }
        let toHip = hip - knee, toAnkle = ankle - knee
        let current = acos(min(1, max(-1, simd_dot(simd_normalize(toHip), simd_normalize(toAnkle)))))
        let desired = acos(min(1, max(-1, (thigh * thigh + shin * shin - reach * reach) / (2 * thigh * shin))))
        var hinge = simd_cross(toHip, toAnkle)
        if simd_length(hinge) < 1e-5 { hinge = globals[upLeg].act(SIMD3<Float>(-1, 0, 0)) }
        let kneeTurn = simd_quatf(angle: desired - current, axis: simd_normalize(hinge))
        pose.rotations[leg] = simd_normalize(globals[upLeg].inverse * kneeTurn * globals[upLeg] * pose.rotations[leg])
        let bentAnkle = knee + kneeTurn.act(toAnkle)
        let hipTurn = shortestArc(from: simd_normalize(bentAnkle - hip), to: simd_normalize(ankleTarget - hip))
        let hips = globals[FighterSkeleton.parents[upLeg]]
        pose.rotations[upLeg] = simd_normalize(hips.inverse * hipTurn * hips * pose.rotations[upLeg])
        let legGlobal = hipTurn * kneeTurn * globals[leg]
        pose.rotations[foot] = simd_normalize(legGlobal.inverse * footGlobal)
        return wanted / (thigh + shin)
    }
}
