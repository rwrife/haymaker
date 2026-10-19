import Foundation
import simd
import HaymakerKit

/// Presentation director for a bout: feeds both fighters their engine state,
/// turns engine events into hit reactions and effect cues, adds taunts and the
/// post-bout celebration, and places the fighters so punches land on target.
/// Runs on its own presentation clock (the engine freezes during the 3-2-1).
/// UIKit-free so the offscreen QA harness can drive it.
@MainActor final class BoutChoreographer {
    struct Cue {
        enum Kind: Equatable {
            case impact(strong: Bool, counter: Bool)
            case blocked
            case dodge
            case parry
            case knockdown
        }
        let kind: Kind
        /// Stage-space position.
        let position: SIMD3<Float>
        let by: Combatant
    }

    /// Spacing between the fighters' roots and the per-punch step-in that puts
    /// the glove on the opponent's head at `contact`.
    struct Spacing: Equatable {
        var base: Float = 2.12
        /// Closest root distance at which the idle guards keep clear of each other.
        var clearance: Float = 0
        var slide: [Combatant: [Move: Float]] = [:]
        var hand: [Combatant: [Move: FighterBone]] = [:]

        func slide(_ fighter: Combatant, _ move: Move) -> Float { slide[fighter]?[move] ?? 0 }
    }

    static let postBoutCelebrationDelayKO = 0.9
    static let postBoutCelebrationDelayDecision = 0.5
    static let tauntDelay = 0.3
    static let tauntClearance = 0.7

    let hero: BoxerModel
    private(set) var rival: BoxerModel
    private(set) var clock: Double = 0
    private(set) var ringCenter = SIMD3<Float>(0, 0, 0.2)
    private(set) var axis = SIMD3<Float>(0, 0, -1)
    private(set) var spacing = Spacing()
    private var lastEventCount = 0
    private var endTime: Double?
    private var pending: [(kind: Cue.Kind, by: Combatant, move: Move)] = []
    /// Per attacker: the defender's head (defender rig space) the current punch is
    /// aimed at. Tracked while the punch flies, frozen once it lands or while the
    /// defender slips (so dodges still whiff).
    private var aimHead: [Combatant: (center: SIMD3<Float>, radius: Float)] = [:]
    /// Per attacker: what the glove actually aims at (defender rig space): the head,
    /// or the guard glove covering it while the defender blocks.
    private var aimPoint: [Combatant: (center: SIMD3<Float>, radius: Float)] = [:]
    /// Per fighter: how far its shown Hips trailed its clip at the end of last frame
    /// (`BoxerModel.hipsShift`), read by both attackers this frame alike.
    private var hipsShift: [Combatant: SIMD3<Float>] = [:]
    private var wasAttacking: [Combatant: Bool] = [:]
    /// Per attacker: the current punch was thrown while the defender was down.
    private var swingAtDowned: [Combatant: Bool] = [:]
    /// Each fighter's step (`step(_:)`) on the previous frame, and per attacker the
    /// step its punch winds up from: a punch steps `budget` from there (up to `limit` to land).
    private var lastStep: [Combatant: Float] = [:]
    /// Frames since a fighter held its ground against an incoming punch (while it lets go).
    private var loosed: [Combatant: Float] = [:]
    private var windupOrigin: [Combatant: (step: Float, budget: Float, limit: Float)] = [:]
    /// How much farther than its windup start a punch's root step still carries the Hips
    /// (they travel at most `AnimationTuning.windupHipsTravel` in a windup, the clip's drive included).
    private var windupCapacity: [Combatant: Float] = [:]
    /// A fighter stepping into a punch its attacker's footwork cannot carry to the head
    /// (the attacker's side is the key's other side): a counter lands because the head came to it.
    private var drawIn: [Combatant: Float] = [:]
    private var frameStep: Float = 0
    /// Extra separation (scene units) easing the fighters apart while a glove that
    /// is not landing a punch would sink into the other fighter's gloves or head
    /// (each fighter's share; a falling fighter takes it all and keeps it while down).
    var gloveSpread: Float { spread[.player, default: 0] + spread[.opponent, default: 0] }
    private var spread: [Combatant: Float] = [:]
    /// 0…1 how far an open (not defending) fighter's guard glove on the hook's side
    /// swings out as the hook comes in, so it lands on the head, not through the glove.
    private var give: [Combatant: Float] = [:]

    /// Per attacker and punch: the arm at contact (attacker rig space), used to
    /// re-solve the step-in against where the defender's head really is.
    private var contactReferences: [Combatant: [Move: BoxerModel.AimReference]] = [:]
    /// Per attacker and punch: the Hips' forward offset (rig z) at contact, which the
    /// windup's step need not cover.
    private var contactHips: [Combatant: [Move: Float]] = [:]

    init(hero: BoxerModel, rival: BoxerModel) {
        self.hero = hero
        self.rival = rival
        measure()
    }

    func replaceRival(_ model: BoxerModel) {
        rival = model
        measure()
    }

    private func measure() {
        spacing = Self.measureSpacing(hero: hero, rival: rival)
        contactReferences = [:]
        contactHips = [:]
        for (side, attacker) in [(Combatant.player, hero), (.opponent, rival)] {
            for (move, clip) in [(Move.jab, ClipID.jab), (.hook, .hook), (.uppercut, .uppercut)] {
                contactReferences[side, default: [:]][move] = Self.spacingReference(attacker, side: side, move: move, clip: clip)
                if let motion = attacker.motions[clip] {
                    let hips = motion.hipsPosition(at: Self.expectedContactLower(side: side, move: move, clip: motion))
                    contactHips[side, default: [:]][move] = motion.hipsPosition(at: 0).z + FighterAnimator.travelOffset(hips, clip: motion).y
                }
            }
        }
    }

    func reset() {
        clock = 0
        lastEventCount = 0
        endTime = nil
        pending.removeAll()
        aimHead.removeAll()
        hipsShift.removeAll()
        aimPoint.removeAll()
        wasAttacking.removeAll()
        swingAtDowned.removeAll()
        lastStep.removeAll()
        loosed.removeAll()
        windupOrigin.removeAll()
        windupCapacity.removeAll()
        drawIn.removeAll()
        spread.removeAll()
        give.removeAll()
        hero.resetMotion()
        rival.resetMotion()
    }

    /// Both fighters in a still guard at their marks (before the first frame of a bout).
    func restPose() {
        for model in [hero, rival] {
            model.update(FighterStatus(), totalTicks: 0, tickFraction: 0, now: clock, dt: 0, reducedMotion: true)
        }
        place(time: 0, reducedMotion: true, states: [.player: .idle, .opponent: .idle])
    }

    private func model(_ fighter: Combatant) -> BoxerModel { fighter == .player ? hero : rival }

    /// Advance presentation by `dt` seconds and pose both fighters.
    @discardableResult
    func update(_ fight: FightEngine, dt: Double, tickFraction: Double, reducedMotion: Bool) -> [Cue] {
        let step = min(0.1, max(0, dt))
        clock += step
        frameStep = Float(step)
        if fight.events.count < lastEventCount { lastEventCount = 0 }
        for event in fight.events.dropFirst(lastEventCount) { handle(event, fight: fight) }
        lastEventCount = fight.events.count

        var heroStatus = fight.player, rivalStatus = fight.opponent
        var heroCue = FighterCue.none, rivalCue = FighterCue.none
        let frac = fight.isOver ? 0 : min(0.999, max(0, tickFraction))
        var heroClock = (ticks: fight.totalTicks, fraction: frac), rivalClock = heroClock
        if let outcome = fight.outcome {
            if endTime == nil { endTime = clock }
            let byKO = outcome == .playerWinByKO || outcome == .playerLossByKO
            // The engine freezes at the end: the knockout punch still finishes its
            // recovery on presentation time; anyone else standing settles to guard
            // (a decision can freeze the engine mid-action).
            let after = (clock - (endTime ?? clock)) * 60
            func settle(_ status: inout FighterStatus, _ clock: inout (ticks: Int, fraction: Double)) {
                guard status.state != .ko else { return }
                let aged = status.ticksInCurrentState + Int(after)
                if byKO, status.state == .recovering, aged < status.stateDuration {
                    clock = (fight.totalTicks + Int(after), after - after.rounded(.down))
                    status.ticksInCurrentState = aged
                } else {
                    status = FighterStatus()
                }
            }
            settle(&heroStatus, &heroClock)
            settle(&rivalStatus, &rivalClock)
            let start = (endTime ?? clock) + (byKO ? Self.postBoutCelebrationDelayKO : Self.postBoutCelebrationDelayDecision)
            switch outcome {
            case .playerWinByKO, .playerWinByDecision: heroCue = .celebrate(start: start)
            case .playerLossByKO, .playerLossByDecision: rivalCue = .celebrate(start: start)
            case .draw: break
            }
        } else {
            heroCue = taunt(over: rival, downed: rivalStatus, reducedMotion: reducedMotion)
            rivalCue = taunt(over: hero, downed: heroStatus, reducedMotion: reducedMotion)
        }
        hero.update(heroStatus, totalTicks: heroClock.ticks, tickFraction: heroClock.fraction, now: clock, dt: step,
                    reducedMotion: reducedMotion, cue: heroCue)
        rival.update(rivalStatus, totalTicks: rivalClock.ticks, tickFraction: rivalClock.fraction, now: clock, dt: step,
                     reducedMotion: reducedMotion, cue: rivalCue)
        place(time: Float((Double(fight.totalTicks) + frac) / 60), reducedMotion: reducedMotion,
              states: [.player: heroStatus.state, .opponent: rivalStatus.state])
        let cues = pending.map(resolve)
        pending.removeAll()
        return cues
    }

    private func taunt(over downed: BoxerModel, downed status: FighterStatus, reducedMotion: Bool) -> FighterCue {
        guard !reducedMotion, status.state == .knockedDown, let times = downed.director.downTimes else { return .none }
        let start = times.ground + Self.tauntDelay, until = times.rise - Self.tauntClearance
        return until - start >= 0.6 ? .taunt(start: start, until: until) : .none
    }

    // MARK: - Events → reactions

    private func handle(_ event: FightEvent, fight: FightEngine) {
        switch event {
        case let .landed(tick, by, move, damage, counter):
            let defender = by == .player ? Combatant.opponent : .player
            let status = defender == .player ? fight.player : fight.opponent
            pending.append((.impact(strong: damage > 15 || move == .uppercut, counter: counter), by, move))
            // The head snaps along the blow on the very next frame, even under a knockdown.
            let push = blowDirection(by: by, move: move)
            model(defender).animator.impulse(push: push, angle: AnimationTuning.impulse(move) * (counter ? 1.2 : 1))
            // A knockdown blow is carried by the fall itself.
            guard status.state != .knockedDown, status.state != .ko else { return }
            model(defender).braceForBlow(push: push)
            var weight: Float, rate: Float, clip: ClipID
            switch move {
            case .hook:
                clip = tick.isMultiple(of: 2) ? .hitSide : .hitHead
                weight = 0.85
                rate = 1.1
            case .uppercut:
                clip = .hitHead
                weight = 1
                rate = 0.95
            default:
                // Every punch is aimed at the head, so no body-hunch here (it would
                // drive the head into the glove); vary the jab's snap instead.
                clip = .hitHead
                weight = tick % 3 == 0 ? 0.55 : 0.65
                rate = tick % 3 == 0 ? 1.35 : 1.25
            }
            if counter {
                weight = min(1, weight + 0.15)
                rate *= 0.9
            }
            model(defender).react(clip, weight: weight, rate: rate)
        case let .blocked(_, by, move, _):
            let defender = by == .player ? Combatant.opponent : .player
            model(defender).react(move == .uppercut ? .hitBody : .hitHead, weight: move == .uppercut ? 0.45 : 0.32, rate: 1.4, mask: .torso)
            model(defender).animator.impulse(push: blowDirection(by: by, move: move), angle: AnimationTuning.blockedImpulse)
            pending.append((.blocked, by, move))
        case let .dodged(_, attacker, move):
            model(attacker).director.noteWhiff(move)
            pending.append((.dodge, attacker, move))
        case let .parried(_, attacker, move):
            model(attacker).director.noteWhiff(move)
            model(attacker).react(.hitSide, weight: 0.3, rate: 1.3, mask: .torso)
            pending.append((.parry, attacker, move))
        case let .whiffed(_, by, move):
            model(by).director.noteWhiff(move)
        case let .knockdown(_, fighter, _):
            pending.append((.knockdown, fighter == .player ? .opponent : .player, .idle))
        default:
            break
        }
    }

    /// Direction (defender rig space) a blow drives the defender's head: from the
    /// glove into the head, mostly backward, lifting for an uppercut.
    private func blowDirection(by side: Combatant, move: Move) -> SIMD3<Float> {
        let attacker = model(side), defender = model(side.other)
        let hand = spacing.hand[side]?[move] ?? .leftHand
        let glove = defender.local(attacker.placed(attacker.blob(hand).center))
        let into = defender.blob(.head).center - glove
        let normal = simd_length(into) > 1e-4 ? simd_normalize(into) : SIMD3<Float>(0, 0, -1)
        return simd_normalize(normal + SIMD3<Float>(0, move == .uppercut ? 0.5 : 0, -0.7))
    }

    private func resolve(_ item: (kind: Cue.Kind, by: Combatant, move: Move)) -> Cue {
        let attacker = model(item.by), defender = model(item.by == .player ? .opponent : .player)
        let head = defender.blob(.head)
        let headCenter = defender.placed(head.center)
        let hand = spacing.hand[item.by]?[item.move] ?? .leftHand
        let glove = attacker.placed(attacker.blob(hand).center)
        switch item.kind {
        case .impact, .knockdown:
            // On the head's surface, facing the glove.
            let toward = glove - headCenter
            let surface = simd_length(toward) > 1e-4 ? simd_normalize(toward) * head.radius * defender.scale : .zero
            return Cue(kind: item.kind, position: headCenter + surface, by: item.by)
        case .blocked:
            return Cue(kind: item.kind, position: glove, by: item.by)
        case .dodge, .parry:
            return Cue(kind: item.kind, position: headCenter, by: item.by)
        }
    }

    // MARK: - Placement

    private func place(time: Float, reducedMotion: Bool, states: [Combatant: FighterState]) {
        // Both fighters circle the same center and keep facing one another,
        // drifting a few steps around the canvas (never near the ropes) so the
        // ropes and crowd slide past behind them.
        let orbit: Float = reducedMotion ? 0 : sin(time * 0.32) * 0.34 + sin(time * 0.9) * 0.04
        let drift: Float = reducedMotion ? 0 : sin(time * 0.21) * 0.55 + sin(time * 0.8) * 0.065
        let depth: Float = reducedMotion ? 0 : sin(time * 0.27 + 1.1) * 0.32
        axis = SIMD3<Float>(sin(0.64 + orbit), 0, -cos(0.64 + orbit))
        let center = SIMD3<Float>(drift, 0, 0.20 + depth)
        ringCenter = center
        hipsShift = [.player: hero.hipsShift, .opponent: rival.hipsShift]
        // The clips carry their own weight shifts and root motion; the scene only
        // adds the step-in that makes each punch reach its target.
        let half = spacing.base / 2
        hero.root.simdEulerAngles = SIMD3<Float>(0, atan2(axis.x, axis.z), 0)
        rival.root.simdEulerAngles = SIMD3<Float>(0, atan2(-axis.x, -axis.z), 0)
        hero.root.simdPosition = center - axis * (half - step(.player))
        rival.root.simdPosition = center + axis * (half - step(.opponent))
        // Re-solve each punch's slide against where the defender's head really is.
        let struck = wasAttacking
        for side in [Combatant.player, .opponent] { track(side, state: states[side] ?? .idle, defenderState: states[side.other] ?? .idle,
                                                          center: center, half: half) }
        for side in [Combatant.player, .opponent] {
            var paced = pacedStep(side)
            // Caught on the way back out: a fighter does not drift off a punch already on its
            // way, nor before the frame it lands.
            let state = states[side] ?? .idle
            let incoming = states[side.other] == .attacking || struck[side.other] == true
            if incoming, state != .attacking, state != .dodging, let last = lastStep[side] {
                paced = max(paced, last)
                loosed[side] = 0
            } else if let frames = loosed[side], let last = lastStep[side] {
                // Let go of the hold as a step that gathers pace, not a jolt back to the mark.
                let pace = Self.stepPace * frameStep * 60 * min(1, (frames + 1) / Self.loosenFrames)
                if state != .attacking { paced = last + min(pace, max(-pace, paced - last)) }
                loosed[side] = frames + 1 >= Self.loosenFrames ? nil : frames + 1
            }
            lastStep[side] = paced
        }
        hero.root.simdPosition = center - axis * (half - (lastStep[.player] ?? 0))
        rival.root.simdPosition = center + axis * (half - (lastStep[.opponent] ?? 0))
        separate(states: states)
        hero.finish(aimAt: aimTarget(by: .player, states: states), plantFeet: frameStep, guardGive: guardGive(.player, states: states))
        rival.finish(aimAt: aimTarget(by: .opponent, states: states), plantFeet: frameStep, guardGive: guardGive(.opponent, states: states))
        hero.yieldGloves(to: rival, attacking: states[.player] == .attacking, dt: frameStep)
        rival.yieldGloves(to: hero, attacking: states[.opponent] == .attacking, dt: frameStep)
    }

    private func guardGive(_ side: Combatant, states: [Combatant: FighterState]) -> BoxerModel.GuardGive? {
        let attacker = model(side.other), state = states[side] ?? .idle
        let open: Set<FighterState> = [.idle, .telling, .attacking, .recovering]
        let incoming = states[side.other] == .attacking && attacker.director.lungeMove == .hook && open.contains(state)
        let now = give[side, default: 0]
        // A guard thrown up against it closes the opening as fast as it opened.
        let rate = (incoming ? 1 / Self.giveIn : open.contains(state) ? -1 / Self.giveOut : -1 / Self.giveIn) * frameStep
        let weight = min(1, max(0, now + rate))
        give[side] = weight
        guard weight > 0, let hand = spacing.hand[side.other]?[.hook] else { return nil }
        // An attacker's right hook comes around the defender's left glove, and vice versa.
        return .init(arm: hand == .rightHand ? .leftArm : .rightArm, weight: smoothstep(weight))
    }

    /// The step this frame, moving the root no faster than footwork allows: a punch's
    /// lunge plus a re-solve after a snapping head (parry, reaction) never adds up to a skate.
    private func pacedStep(_ side: Combatant) -> Float {
        let wanted = step(side)
        guard let last = lastStep[side] else { return wanted }
        let pace = Self.stepPace * frameStep * 60
        return last + min(pace, max(-pace, wanted - last))
    }

    private func step(_ fighter: Combatant) -> Float {
        let director = model(fighter).director
        return director.lunge * (spacing.slide(fighter, director.lungeMove) + director.reach)
            + director.lungeCarry * (spacing.slide(fighter, director.carryMove) + director.carryReach)
            + (drawIn[fighter] ?? 0)
    }

    /// While a punch flies, follow the defender's head (unless it is slipping) and
    /// adjust the attacker's slide by how far that head is from the guard head at
    /// the defender's mark, which is what the static spacing was solved against.
    private func track(_ side: Combatant, state: FighterState, defenderState: FighterState, center: SIMD3<Float>, half: Float) {
        let attacking = state == .attacking, entering = attacking && wasAttacking[side] != true
        // The glove lands on the first frame after the attack state ends: track that frame too.
        let landing = !attacking && wasAttacking[side] == true
        wasAttacking[side] = attacking
        guard attacking || landing else {
            // Drawn in by the last punch: the blow (or the next exchange) sends the fighter back out.
            if let drawn = drawIn[side.other], drawn > 0 { drawIn[side.other] = max(0, drawn - Self.drawInRelease * frameStep * 60) }
            return
        }
        let attacker = model(side), defender = model(side.other)
        if entering {
            // A fighter still reeling from the last blow gathers itself as the next one comes:
            // the follow-up meets the head near its guard, not chasing it back across the ring.
            defender.animator.releaseReactions()
            // Footwork, not a lunge: the body covers at most `windupPace` per frame of
            // the strike, the Hips' own drive toward contact included.
            let frames = Float(attacker.director.strikeDuration * 60)
            let drive = max(0, (contactHips[side]?[attacker.director.lungeMove] ?? 0) - attacker.animated.hips.z) * attacker.scale
            let limit = min(Self.maxWindupStep, max(0.05, Self.windupPaceLimit * frames))
            windupOrigin[side] = (lastStep[side] ?? 0, min(limit, max(0.05, Self.windupPace * frames - drive)), limit)
            windupCapacity[side] = max(0, AnimationTuning.windupHipsTravel - Self.windupHipsMargin - drive)
        }
        if entering { swingAtDowned[side] = defenderState == .knockedDown || defenderState == .ko }
        if swingAtDowned[side] == true {
            // Nobody punches a fighter on the canvas: the engine's swing at a downed
            // fighter is thrown at the air where a standing head would be.
            if entering || aimHead[side] == nil { aimHead[side] = defender.nominalHead }
        } else if defenderState != .dodging {
            var head = defender.blob(.head, in: defender.animated)
            // Where the head will be shown: the defender's paced Hips still trail its clip.
            head.center += hipsShift[side.other] ?? .zero
            if !entering, let previous = aimHead[side] {
                // Follow a snapping head (parry, reaction) at a pace the arm can track.
                let move = head.center - previous.center, length = simd_length(move), pace = Self.headTrackSpeed * frameStep
                aimHead[side] = (length > pace ? previous.center + move * (pace / length) : head.center, head.radius)
            } else {
                aimHead[side] = (head.center, head.radius)
            }
        } else if entering || aimHead[side] == nil {
            aimHead[side] = defender.nominalHead
        }
        guard let head = aimHead[side] else { return }
        // A blocked punch lands on the guard glove covering the punch line.
        let wanted = defenderState == .blocking ? guardCover(of: defender, head: head, against: attacker, side: side) ?? head : head
        if !entering, let previous = aimPoint[side] {
            let move = wanted.center - previous.center, length = simd_length(move), pace = Self.headTrackSpeed * frameStep
            aimPoint[side] = (length > pace ? previous.center + move * (pace / length) : wanted.center, wanted.radius)
        } else {
            aimPoint[side] = wanted
        }
        let toward = side == .player ? axis : -axis
        let mark = center + toward * half
        // Prefer the step the punch winds up from (no return to neutral and back between
        // chained punches), within the windup's budget.
        let slide = spacing.slide(side, attacker.director.lungeMove)
        let origin = windupOrigin[side] ?? (step: 0, budget: Self.maxWindupStep, limit: Self.maxWindupStep)
        let stay = origin.step - slide - gloveSpread
        let solved = aimPoint[side].flatMap { reachSolve(side, aimed: defender.placed($0.center), radius: $0.radius * defender.scale,
                                                          center: center, half: half, toward: toward,
                                                          stay: stay, budget: origin.budget, limit: origin.limit) }
        let target: Float
        if let solved {
            target = min(Self.maxReach, max(-Self.maxRetreat, solved + gloveSpread))
        } else {
            let offset = defender.placed(head.center) - (mark + simd_act(defender.root.simdOrientation, defender.nominalHead.center * defender.scale))
            // A blocked punch is thrown to the guard, which stands out in front of the head.
            let cover = defenderState == .blocking ? max(0, (aimPoint[side]?.radius ?? head.radius) - head.radius) * defender.scale : 0
            target = min(Self.maxReach, max(-Self.maxRetreat, simd_dot(offset, toward) + gloveSpread - cover))
        }
        // A root step past what the windup carries the Hips to only spreads the stance:
        // the rest of the way, the defender comes to the punch (at a step's pace).
        var reach = target
        if let capacity = windupCapacity[side] {
            let carried = origin.step + capacity - slide
            let over = reach - carried
            reach = min(reach, carried)
            let drawn = drawIn[side.other] ?? 0
            let drawable = defenderState != .dodging && defenderState != .knockedDown && defenderState != .ko && swingAtDowned[side] != true
            drawIn[side.other] = drawable ? min(Self.maxDrawIn, max(0, drawn + over * Self.drawInGain * frameStep * 60))
                : max(0, drawn - Self.drawInRelease * frameStep * 60)
        }
        // Footwork, not teleporting: a defender's sudden snap (parry, reaction) is followed at a pace.
        // The root moves by lunge × reach: early in the lunge the reach can settle faster.
        let pace = Self.reachSpeed * frameStep / max(0.25, attacker.director.lunge)
        attacker.director.reach = entering ? reach : attacker.director.reach + min(pace, max(-pace, reach - attacker.director.reach))
    }

    /// Extra step-in (scene units, on top of the punch's static slide) at which the
    /// punch at contact meets `aimed` (stage space) with a comfortable steer: the
    /// same solve as the static spacing, against the head (or guard) where it really
    /// is — leaning, turned, or stepping away. The step stays within `budget` of
    /// `stay` (where the root stands as the punch winds up) if the punch still lands
    /// from there with a looser steer; it only goes further (up to `limit`) when it
    /// would miss. Nil if no step in range reaches it.
    private func reachSolve(_ side: Combatant, aimed: SIMD3<Float>, radius: Float, center: SIMD3<Float>, half: Float,
                            toward: SIMD3<Float>, stay: Float, budget: Float, limit: Float) -> Float? {
        let attacker = model(side), move = attacker.director.lungeMove
        guard let reference = contactReferences[side]?[move] else { return nil }
        let root = center - toward * (half - spacing.slide(side, move))
        let local = simd_act(attacker.root.simdOrientation.inverse, aimed - root) / attacker.scale
        let comfort = Self.comfortAim[move] ?? 0.2
        func lands(_ shift: Float, within allowed: Float) -> (ok: Bool, demand: Float) {
            let target = BoxerModel.AimTarget(center: local - SIMD3<Float>(0, 0, shift / attacker.scale), radius: radius / attacker.scale)
            let aim = BoxerModel.aimCorrection(reference, target: target)
            return (aim.reachable && aim.armDemand <= allowed, aim.reachable ? aim.armDemand : .infinity)
        }
        func refine(_ miss: Float, _ hit: Float) -> Float {
            var miss = miss, hit = hit
            for _ in 0..<3 {
                let mid = (miss + hit) / 2
                if lands(mid, within: comfort).ok { hit = mid } else { miss = mid }
            }
            return hit
        }
        // The comfortable steps form a range: from the farthest the punch reaches
        // (arm extended) to the closest it still lands (elbow bent, a short punch).
        // Stay put if the punch lands from here, else step in or back just enough,
        // a margin inside the range (the live pose drifts a little from the reference).
        var best: (demand: Float, shift: Float)?
        var far: Float?, near: Float?
        var shift = -Self.maxRetreat
        while shift <= Self.maxReach + 1e-4 {
            let probe = lands(shift, within: comfort)
            if probe.ok {
                if far == nil { far = shift > -Self.maxRetreat ? refine(shift - 0.04, shift) : shift }
                near = shift
            } else {
                if let n = near { near = refine(shift, n); break }
                if probe.demand < best?.demand ?? .infinity { best = (probe.demand, shift) }
            }
            shift += 0.04
        }
        let wanted: Float
        if let far, let near {
            // Only the far part of the range: a punch smothered at very close range
            // (elbow fully bent, heads together) steps back to land instead.
            let low = far + Self.reachMargin, high = min(near - Self.reachMargin, far + (near - far) * Self.closeRangeShare)
            wanted = low <= high ? min(high, max(low, 0)) : low
        } else if let best {
            wanted = best.shift + Self.reachMargin
        } else {
            return nil
        }
        let lowest = stay - budget, highest = stay + budget
        if wanted >= lowest, wanted <= highest { return wanted }
        // Past the windup's footwork: take the step inside it that still lands with a
        // looser steer, else the shortest step beyond it that does.
        let loose = comfort + Self.looseAim
        var probe = min(highest, max(lowest, wanted))
        let direction: Float = wanted > probe ? 1 : -1
        let end = min(stay + limit, max(stay - limit, wanted))
        while (end - probe) * direction > 0 {
            if lands(probe, within: loose).ok { return probe }
            probe += direction * 0.02
        }
        return end
    }

    /// A blocked punch stops on the guard: the defender's head (defender rig space)
    /// grown by how far the guard gloves stand out in front of it toward the
    /// attacker's punching shoulder.
    private func guardCover(of defender: BoxerModel, head: (center: SIMD3<Float>, radius: Float), against attacker: BoxerModel,
                            side: Combatant) -> (center: SIMD3<Float>, radius: Float)? {
        guard let hand = spacing.hand[side]?[attacker.director.lungeMove] else { return nil }
        let shoulder = defender.local(attacker.placed(attacker.animated.joints(heads: attacker.rig.heads)[hand.rawValue - 2]))
        let toward = shoulder - head.center
        guard simd_length(toward) > 1e-4 else { return nil }
        let n = simd_normalize(toward)
        var front = head.radius
        for bone in [FighterBone.leftHand, .rightHand] {
            let glove = defender.blob(bone, in: defender.animated)
            front = max(front, simd_dot(glove.center - head.center, n) + glove.radius)
        }
        return (head.center, min(head.radius + 0.35, front))
    }

    /// Push the fighters apart along the axis if their torsos or heads would overlap,
    /// and ease them apart (at a walking pace) while a glove would sink into the
    /// other fighter's gloves or head — e.g. an attacker still lunged in after a
    /// slipped punch. A punching glove only counts once its aim has let go.
    private func separate(states: [Combatant: FighterState]) {
        var wanted: Float = 0
        let heroParts = parts(of: .player, state: states[.player] ?? .idle)
        let rivalParts = parts(of: .opponent, state: states[.opponent] ?? .idle)
        for p in heroParts {
            for q in rivalParts where p.bone != .head || q.bone != .head {
                let weight = min(p.weight, q.weight)
                guard weight > 0 else { continue }
                let d = q.center - p.center, distance = simd_length(d), along = simd_dot(d, axis)
                let n = distance > 1e-4 ? d / distance : axis
                let reach = FighterReach.support(p.probes, radius: p.radius, n) + FighterReach.support(q.probes, radius: q.radius, -n) + Self.gloveMargin
                let lateral = simd_length_squared(d - along * axis)
                guard lateral < reach * reach else { continue }
                wanted = max(wanted, weight * ((reach * reach - lateral).squareRoot() - along))
            }
        }
        // Held while a punch flies or is still aimed (its slide is solved against the spacing),
        // unless the punch dropped its target: a falling fighter needs the room.
        func down(_ side: Combatant) -> Bool { states[side] == .knockedDown || states[side] == .ko }
        let held = states.values.contains(.attacking)
            || (hero.director.aim >= 0.5 && !down(.opponent)) || (rival.director.aim >= 0.5 && !down(.player))
        if !held {
            let pace = Self.spreadSpeed * frameStep, goal = min(Self.maxSpread, wanted)
            func ease(_ side: Combatant, to target: Float, pace: Float) {
                let now = spread[side, default: 0]
                spread[side] = now + min(pace, max(-pace, target - now))
            }
            if let fallen = [Combatant.player, .opponent].first(where: down), !down(fallen.other) {
                // The punch knocks the falling fighter back; it never slides back while lying
                // there, only once the get-up walks it home.
                let needed = max(0, goal - spread[fallen.other, default: 0])
                let rising = model(fallen).lastMotion?.clip == .getUp
                ease(fallen, to: rising ? needed : max(spread[fallen, default: 0], needed), pace: pace * (rising ? 1 : 1.5))
            } else {
                ease(.player, to: goal / 2, pace: pace)
                ease(.opponent, to: goal / 2, pace: pace)
            }
        }
        hero.root.simdPosition -= axis * spread[.player, default: 0]
        rival.root.simdPosition += axis * spread[.opponent, default: 0]

        let bones: [FighterBone] = [.hips, .spine, .spine1, .spine2, .head]
        let a = bones.map { hero.blob($0, in: hero.animated) }.map { (hero.placed($0.center), $0.radius * hero.scale) }
        let b = bones.map { rival.blob($0, in: rival.animated) }.map { (rival.placed($0.center), $0.radius * rival.scale) }
        var push: Float = 0
        for p in a {
            for q in b {
                let d = q.0 - p.0, along = simd_dot(d, axis)
                let side = d - along * axis, reach = p.1 + q.1 + Self.bodyMargin
                let lateral = simd_length_squared(side)
                guard lateral < reach * reach else { continue }
                push = max(push, (reach * reach - lateral).squareRoot() - along)
            }
        }
        guard push > 0 else { return }
        hero.root.simdPosition -= axis * (push / 2)
        rival.root.simdPosition += axis * (push / 2)
    }

    /// A fighter's gloves and head in stage space (blob, extreme points) with how
    /// much each counts for `separate`.
    private func parts(of side: Combatant, state: FighterState) -> [(bone: FighterBone, center: SIMD3<Float>, radius: Float,
                                                                    probes: [SIMD3<Float>], weight: Float)] {
        let model = model(side), director = model.director
        let punching = director.aim > 0.001 || state == .attacking ? model.aimReferences[director.aimClip]?.hand : nil
        let turn = model.root.simdOrientation
        return [FighterBone.leftHand, .rightHand, .head].map { bone in
            let blob = model.blob(bone, in: model.animated)
            let probes = FighterReach.probes(bone.rawValue, pose: model.animated, rig: model.rig, around: blob.center)
                .map { simd_act(turn, $0 * model.scale) }
            let weight: Float = bone != punching ? 1 : state == .attacking ? 0 : 1 - director.aim
            return (bone, model.placed(blob.center), blob.radius * model.scale, probes, weight)
        }
    }

    private func aimTarget(by side: Combatant, states: [Combatant: FighterState]) -> BoxerModel.AimTarget? {
        let attacker = model(side), defender = model(side.other)
        guard attacker.director.aim > 0.001, let head = aimPoint[side] ?? aimHead[side] else { return nil }
        var target = BoxerModel.AimTarget(center: attacker.local(defender.placed(head.center)), radius: head.radius * defender.scale / attacker.scale)
        let defending = states[side.other] ?? .idle
        target.air = defending == .dodging || swingAtDowned[side] == true
        if defending != .blocking, !target.air {
            let bone = FighterBone.head.rawValue, pose = defender.animated
            let turn = attacker.root.simdOrientation.inverse * defender.root.simdOrientation * pose.globals()[bone]
            target.skin = .init(center: attacker.local(defender.placed(defender.blob(.head, in: pose).center + (hipsShift[side.other] ?? .zero))), rotation: simd_normalize(turn),
                                scale: defender.scale / attacker.scale, blob: defender.rig.blobs[bone])
        }
        return target
    }

    static let maxReach: Float = 0.5
    /// Fastest the root steps along the fight axis (scene units per 60 Hz frame).
    static let stepPace: Float = 0.058
    /// Frames over which a fighter let off holding its ground gathers its full stepping pace.
    static let loosenFrames: Float = 4
    /// Most a punch's windup moves the root (scene units), and per frame of its strike.
    static let maxWindupStep: Float = 0.4
    static let windupPace: Float = 0.045
    /// Per frame of the strike, the most a windup steps to make a punch land at all.
    static let windupPaceLimit: Float = 0.051
    /// Room (scene units) kept under the windup's Hips travel when solving its step.
    static let windupHipsMargin: Float = 0.01
    /// Most a defender steps into a punch that falls short (scene units), how fast that
    /// step follows the shortfall (share per 60 Hz frame) and lets go after it (units per frame).
    static let maxDrawIn: Float = 0.2
    static let drawInGain: Float = 0.5
    static let drawInRelease: Float = 0.008
    /// Extra steer (radians) a punch accepts to land without stepping past its windup's footwork.
    static let looseAim: Float = 0.12
    /// How much closer than the bare touch a live step-in solve stands.
    static let reachMargin: Float = 0.03
    /// Share of the punch's landing range (from full extension in) a fighter will
    /// throw from without stepping.
    static let closeRangeShare: Float = 0.5
    /// Neutral spacing: this share of the way from jab range toward hook range.
    static let hookRangeShare: Float = 0.3
    /// Least gap between the idle guards at neutral spacing (scene units).
    static let guardGap: Float = 0.06
    /// Seconds for `give` to open fully as a hook flies and to close after it.
    static let giveIn: Float = 0.12
    static let giveOut: Float = 0.3
    static let maxRetreat: Float = 0.8
    static let bodyMargin: Float = 0.02
    static let gloveMargin: Float = 0.01
    /// How fast `gloveSpread` opens or closes (scene units/s) and its ceiling.
    static let spreadSpeed: Float = 2.4
    static let maxSpread: Float = 0.3
    static let reachSpeed: Float = 3.2
    static let headTrackSpeed: Float = 5

    /// Comfortable steer (radians) for each punch at its contact distance: the
    /// spacing is solved so the arm only bends this far off the mocap line.
    static let comfortAim: [Move: Float] = [.jab: 0.3, .hook: 0.3, .uppercut: 0.2]

    /// Measure reach from the actual clips and skins: per punch, the farthest
    /// distance at which the glove meets the opponent's head with a comfortable
    /// steer; jabs set the base spacing (never closer than the guards allow) and the
    /// other punches step in or back from it.
    static func measureSpacing(hero: BoxerModel, rival: BoxerModel) -> Spacing {
        var result = Spacing()
        guard let heroIdle = FighterReach.pose(hero.motions, .idle, frame: 0),
              let rivalIdle = FighterReach.pose(rival.motions, .idle, frame: 0) else { return result }
        var need: [Combatant: [Move: Float]] = [:]
        for (side, attacker, defender) in [(Combatant.player, hero, rival), (.opponent, rival, hero)] {
            for (move, clipID) in [(Move.jab, ClipID.jab), (.hook, .hook), (.uppercut, .uppercut)] {
                guard let reference = spacingReference(attacker, side: side, move: move, clip: clipID) else { continue }
                result.hand[side, default: [:]][move] = reference.hand
                need[side, default: [:]][move] = contactDistance(reference, attacker: attacker, defender: defender,
                                                                 comfort: comfortAim[move] ?? 0.2)
            }
        }
        var clearance: Float = 0
        let gloves = [FighterBone.leftHand.rawValue, FighterBone.rightHand.rawValue]
        for a in gloves + [FighterBone.head.rawValue] {
            for b in gloves + [FighterBone.head.rawValue] where !(a == FighterBone.head.rawValue && b == FighterBone.head.rawValue) {
                let ha = FighterReach.blob(a, pose: heroIdle, rig: hero.rig), rb = FighterReach.blob(b, pose: rivalIdle, rig: rival.rig)
                let padded = (center: ha.center, radius: ha.radius + 0.03)
                clearance = max(clearance, FighterReach.separation(padded, scaleA: hero.scale, rb, scaleB: rival.scale))
            }
        }
        func average(_ move: Move) -> Float? {
            let values = [need[.player]?[move], need[.opponent]?[move]].compactMap { $0 }
            return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
        }
        // Stand between jab and hook range: the long, lunging jab steps back a little
        // and the short hook steps in less (no long lunge for a hook after a jab).
        let jab = average(.jab) ?? result.base
        let hook = average(.hook) ?? jab
        result.clearance = clearance
        result.base = max(jab - Self.hookRangeShare * max(0, jab - hook), clearance + Self.guardGap)
        for (side, moves) in need {
            for (move, separation) in moves {
                result.slide[side, default: [:]][move] = min(1.0, max(-0.3, result.base - separation))
            }
        }
        return result
    }

    /// Typical opponent chamber→contact window (ticks); the patterns use 3–8.
    static let typicalOpponentImpactTicks = 5

    /// The punch at contact as it will really be on screen: the lower body still
    /// catching up with a fast arm (player windups, a told opponent's strike).
    static func spacingReference(_ attacker: BoxerModel, side: Combatant, move: Move, clip id: ClipID) -> BoxerModel.AimReference? {
        guard let clip = attacker.motions[id] else { return nil }
        return attacker.spacingReference(id, lower: expectedContactLower(side: side, move: move, clip: clip))
    }

    /// Lower-body frame at contact for a typical punch of this side.
    static func expectedContactLower(side: Combatant, move: Move, clip: RetargetedClip) -> Float {
        let table = PlayerMoveTable.standard
        let ticks = side == .player ? (move == .hook ? table.hook : move == .uppercut ? table.uppercut : table.jab).windup
            : typicalOpponentImpactTicks
        return FighterDirector.contactLowerFrame(clip, ticks: ticks, told: side == .opponent)
    }

    /// Defender's head in the attacker's rig space when the roots stand `distance` apart, facing.
    static func headTarget(attacker: BoxerModel, defender: BoxerModel, distance: Float) -> BoxerModel.AimTarget {
        let h = defender.nominalHead.center, sA = attacker.scale, sB = defender.scale
        return .init(center: SIMD3<Float>(-sB * h.x, sB * h.y, distance - sB * h.z) / sA, radius: defender.nominalHead.radius * sB / sA)
    }

    /// Farthest root distance at which the punch lands with no more than `comfort`
    /// arm steer, else the distance needing the least.
    static func contactDistance(_ reference: BoxerModel.AimReference, attacker: BoxerModel, defender: BoxerModel,
                                comfort: Float) -> Float {
        var best: (demand: Float, distance: Float) = (.infinity, 2.12)
        var distance: Float = 3.6
        while distance > 0.9 {
            let target = headTarget(attacker: attacker, defender: defender, distance: distance)
            let aim = BoxerModel.aimCorrection(reference, target: target)
            if aim.reachable {
                if aim.armDemand <= comfort { return distance }
                if aim.armDemand < best.demand { best = (aim.armDemand, distance) }
            }
            distance -= 0.01
        }
        return best.distance
    }
}

private extension Combatant {
    var other: Combatant { self == .player ? .opponent : .player }
}
