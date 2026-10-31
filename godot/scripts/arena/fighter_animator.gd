class_name FighterAnimator
extends RefCounted
## Layered pose player: base motion with crossfades, additive hit reactions,
## impulses and breathing (port of FighterAnimator.swift).

const TELEGRAPH_BONES := [1, 2, 3, 6, 7, 8, 10, 11, 12]
const IMPULSE_SHARES := [[2, 0.12], [3, 0.2], [4, 0.3], [5, 0.38]]
const PUNCH_CLIPS := ["jab", "hook", "uppercut"]

# AnimationTuning
const TELL_FADE := 0.10
const TAUNT_INTERRUPT_FADE := 0.2
const TELL_LOAD_FRACTION := 0.72
const MINIMUM_TELL_LOAD := 0.06
const MAX_ANTICIPATION_ANGLE := 0.42
const PLAYER_PUNCH_FADE := 0.06
const PLAYER_HOOK_ARM_FADE := 0.1
const MAX_PUNCH_SPEEDUP := 2.5
const STRIKE_TAIL_FLOOR := 0.25
const SLOWEST_STRIKE := 1.5
const RETRACT_TIME := 0.2
const MAX_RETRACT_SPEEDUP := 4.0
const GUARD_ARM_TIME := 0.15
const RECOVER_SPEED := 1.15
const MAX_SETTLE_SPEEDUP := 2.0
const WHIFF_RETRACT_STRETCH := 1.35
const WHIFF_HOLD := 0.09
const WHIFF_SLOWDOWN := 0.85
const PUNCH_EXIT_FADE := 0.3
const GUARD_FADE := 0.07
const PARRY_FADE := 0.05
const EVEN_FADE := 0.051
const SLIP_FADE := 0.06
const GUARD_LOAD := 0.12
const PARRY_LOAD := 4.0 / 60.0
const MAX_SLIP_LOAD := 0.22
const GUARD_EXIT_RATE := 1.25
const GUARD_EXIT_FADE := 0.3
const KNOCKDOWN_FADE := 0.1
const GET_UP_FADE := 0.3
const MINIMUM_LIE := 0.45
const MAX_DOWN_SPEEDUP := 1.35
const GET_UP_INTERRUPT_FADE := 0.12
const STRIKE_FADE_SHARE := 0.6
const TAUNT_FADE_IN := 0.25
const TAUNT_FADE_OUT := 0.3
const TAUNT_LEAD := 0.2
const VICTORY_FADE := 0.35
const IDLE_FADE := 0.25
const LUNGE_RELEASE := 0.22
const TRAVEL_RETURN := 0.4
const REACTION_ATTACK := 0.05
const REACTION_DECAY := 0.22
const REACTION_RELEASE := 0.12
const REACTION_SHOW := 0.07
const IMPULSE_PEAK := 0.05
const BLOCKED_IMPULSE := 0.07


static func anticipation_for(move: int) -> float:
	match move:
		HM.Move.HOOK: return 0.45
		_: return 0.4


static func impulse_for(move: int) -> float:
	match move:
		HM.Move.HOOK: return 0.32
		HM.Move.UPPERCUT: return 0.34
		_: return 0.24


static func punch_travel(clip_id: String) -> float:
	return 0.5 if clip_id == "jab" or clip_id == "uppercut" else 1.0


static func smoothstep01(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func ease_out(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t)


static func ease_in_out(x: float) -> float:
	return smoothstep01(x)


static func snap_back(x: float) -> float:
	var t := 1.0 - clampf(x, 0.0, 1.0)
	return 1.0 - t * t * t


class Motion:
	var clip := "idle"
	var frame := 0.0
	var rate := 0.0
	var key := 0
	var fade := 0.25
	var arm_fade := -1.0
	var anticipation := 0.0
	var hold := 0.0
	var warp_yaw := 0.0
	var warp_offset := Vector3.ZERO
	var snap_from := 0.0
	var snap_to := 0.0
	var snap_weight := -1.0
	var travel_cap := INF
	var travel_scale := 1.0
	var guard_arm := 0.0
	var off_arm := -1.0

	static func make(c: String, f: float, r: float, k: int, fd: float, antic := 0.0, hld := 0.0) -> Motion:
		var m := Motion.new()
		m.clip = c
		m.frame = f
		m.rate = r
		m.key = k
		m.fade = fd
		m.anticipation = antic
		m.hold = hld
		return m

	func dup() -> Motion:
		var m := Motion.new()
		for p in ["clip", "frame", "rate", "key", "fade", "arm_fade", "anticipation", "hold", "warp_yaw", "warp_offset",
				"snap_from", "snap_to", "snap_weight", "travel_cap", "travel_scale", "guard_arm", "off_arm"]:
			m.set(p, get(p))
		return m


var motions: Dictionary
var heads: Array
var pose: FighterPose
var neck_flex := 1.0
var _base: FighterPose
var _current: Motion = null
var _source_live: Motion = null
var _source_frozen: FighterPose = null
var _fade_elapsed := 0.0
var _fade_duration := 0.0
var _arm_fade_duration := -1.0
var _telegraphs := {}
var guard_arms := {} # clip -> [[bone, Quaternion]]
var _off_arms := {}
var punching_hands := {} # clip -> bone index
var _reactions: Array = []
var _impulses: Array = []


func _init(motion_set: Dictionary, rig_heads: Array) -> void:
	motions = motion_set
	heads = rig_heads
	pose = FighterPose.make(heads[0])
	if motions.has("idle"):
		motions["idle"].sample_into(0.0, pose)
	_base = pose.copy()
	for id in PUNCH_CLIPS:
		if not motions.has(id):
			continue
		var clip = motions[id]
		var chamber: float = clip.marker("chamber", clip.last_frame() * 0.2)
		var contact: float = clip.marker("contact", clip.last_frame() * 0.4)
		var deltas := []
		var angles := []
		deltas.resize(FighterAssets.BONE_COUNT)
		deltas.fill(Quaternion())
		angles.resize(FighterAssets.BONE_COUNT)
		angles.fill(0.0)
		for bone in TELEGRAPH_BONES:
			var delta: Quaternion = (clip.rotation(bone, contact).inverse() * clip.rotation(bone, chamber)).normalized()
			if delta.w < 0.0:
				delta = -delta
			deltas[bone] = delta
			angles[bone] = 2.0 * acos(minf(1.0, delta.w))
		_telegraphs[id] = {"chamber": chamber, "contact": contact, "deltas": deltas, "angles": angles}
		var hand := punching_hand(id)
		punching_hands[id] = hand
		var side := 6 if hand == 9 else 10
		var other := 10 if side == 6 else 6
		var arm := []
		for b in range(side, side + 4):
			arm.append([b, clip.rotation(b, 0.0)])
		guard_arms[id] = arm
		_off_arms[id] = range(other, other + 4)


func pose_at(id: String, frame: float) -> FighterPose:
	var p := FighterPose.make(heads[0])
	motions[id].sample_into(frame, p)
	return p


## The hand that travels furthest from guard to contact.
func punching_hand(id: String) -> int:
	var clip = motions[id]
	var a := pose_at(id, 0.0).joints(heads)
	var b := pose_at(id, clip.marker("contact", clip.last_frame() * 0.4)).joints(heads)
	var left: float = (b[9] - b[0]).distance_to(a[9] - a[0])
	var right: float = (b[13] - b[0]).distance_to(a[13] - a[0])
	return 9 if left >= right else 13


func reset() -> void:
	_current = null
	_source_live = null
	_source_frozen = null
	_reactions.clear()
	_impulses.clear()


static func damp_travel(p: FighterPose, clip, cap := INF, travel_scale := 1.0) -> void:
	if punch_travel(clip.id) == 1.0 and cap == INF and travel_scale == 1.0:
		return
	var base: Vector3 = clip.hips_at(0.0)
	var keep := punch_travel(clip.id)
	var d := Vector2(p.hips.x - base.x, p.hips.z - base.z) * keep
	d.y = minf(d.y, cap)
	d *= travel_scale
	p.hips.x = base.x + d.x
	p.hips.z = base.z + d.y


func sample(m: Motion) -> FighterPose:
	var result := _base.copy()
	if not motions.has(m.clip):
		return result
	var clip = motions[m.clip]
	if m.snap_weight >= 0.0:
		var contact := result.copy()
		var retracted := result.copy()
		clip.sample_into(m.snap_from, contact)
		clip.sample_into(m.snap_to, retracted)
		result = FighterPose.blend(contact, retracted, m.snap_weight)
		var legs := result.copy()
		clip.sample_into(m.frame, legs)
		result.merge_lower(legs)
	else:
		clip.sample_into(m.frame, result)
		if m.off_arm >= 0.0 and absf(m.off_arm - m.frame) > 1e-3 and _off_arms.has(m.clip):
			for bone in _off_arms[m.clip]:
				result.rot[bone] = clip.rotation(bone, m.off_arm)
	damp_travel(result, clip, m.travel_cap, m.travel_scale)
	if m.guard_arm > 0.0 and guard_arms.has(m.clip):
		for entry in guard_arms[m.clip]:
			result.rot[entry[0]] = FighterPose.slerp_short(result.rot[entry[0]], entry[1], m.guard_arm)
	if m.anticipation > 0.0 and _telegraphs.has(m.clip):
		var tg: Dictionary = _telegraphs[m.clip]
		var f: float = clip.wrap_frame(m.frame)
		var envelope: float
		if f <= tg.chamber:
			envelope = smoothstep01(f / maxf(1.0, tg.chamber))
		else:
			envelope = 1.0 - smoothstep01((f - tg.chamber) / maxf(0.5, (tg.contact - tg.chamber) * 0.6))
		var w := envelope * m.anticipation
		if w > 0.001:
			for bone in TELEGRAPH_BONES:
				var angle: float = tg.angles[bone]
				var amount := MAX_ANTICIPATION_ANGLE / maxf(angle, 1e-4) if angle * w > MAX_ANTICIPATION_ANGLE else w
				result.rot[bone] = (result.rot[bone] * FighterPose.scaled(tg.deltas[bone], amount)).normalized()
	if absf(m.warp_yaw) > 1e-5 or m.warp_offset.length() > 1e-5:
		var q := Quaternion(Vector3.UP, m.warp_yaw)
		result.hips = q * result.hips + m.warp_offset
		result.rot[0] = (q * result.rot[0]).normalized()
	return result


func update(m: Motion, dt: float, now: float, reduced_motion: bool) -> FighterPose:
	var step := maxf(0.0, dt)
	if _current != null and _current.key != m.key:
		if (_source_live != null or _source_frozen != null) and _fade_elapsed < maxf(_fade_duration, _arm_fade_duration):
			_source_frozen = _base
			_source_live = null
		else:
			_source_live = _current.dup()
			_source_frozen = null
		_fade_elapsed = 0.0
		_fade_duration = maxf(0.001, m.fade)
		_arm_fade_duration = maxf(0.001, m.arm_fade) if m.arm_fade >= 0.0 else -1.0
	_current = m
	var out := sample(m)
	if _source_live != null or _source_frozen != null:
		_fade_elapsed += step
		if _fade_elapsed >= maxf(_fade_duration, _arm_fade_duration):
			_source_live = null
			_source_frozen = null
		else:
			var from: FighterPose
			if _source_live != null:
				_source_live.frame += _source_live.rate * step
				from = sample(_source_live)
			else:
				from = _source_frozen
			var target := out
			var b := minf(1.0, _fade_elapsed / _fade_duration)
			out = FighterPose.blend(from, target, b if _fade_duration <= EVEN_FADE else smoothstep01(b))
			if _arm_fade_duration > 0.0 and guard_arms.has(m.clip):
				var weight := smoothstep01(minf(1.0, _fade_elapsed / _arm_fade_duration))
				for entry in guard_arms[m.clip]:
					out.rot[entry[0]] = FighterPose.slerp_short(from.rot[entry[0]], target.rot[entry[0]], weight)
	_base = out
	out = out.copy()
	if m.hold > 0.0 and not reduced_motion:
		var breath := sin(now * TAU * 0.32) * 0.014 * m.hold
		var q := Quaternion(Vector3.RIGHT, breath)
		out.rot[2] = (out.rot[2] * q).normalized()
		out.rot[3] = (out.rot[3] * q).normalized()
	_apply_reactions(out, step)
	_apply_impulses(out, step)
	pose = out
	return out


func impulse(push: Vector3, angle: float) -> void:
	if angle <= 0.0:
		return
	var along := Vector3(push.x, 0, push.z)
	along = along.normalized() if along.length() > 1e-3 else Vector3(0, 0, -1)
	var axis := Vector3.UP.cross(along).normalized()
	if _impulses.size() >= 3:
		_impulses.pop_front()
	_impulses.append({"axis": axis, "turn": along.x * 0.6 * angle, "angle": angle, "age": 0.0})


func _apply_impulses(out: FighterPose, dt: float) -> void:
	if _impulses.is_empty():
		return
	_impulses = _impulses.filter(func(i): return i.age <= IMPULSE_PEAK * 14.0)
	for imp in _impulses:
		var x: float = imp.age / IMPULSE_PEAK
		var envelope := x * exp(1.0 - x)
		if envelope <= 0.002:
			continue
		for share in IMPULSE_SHARES:
			var bone: int = share[0]
			var w: float = envelope * share[1] * ((0.5 + 0.5 * neck_flex) if bone >= 4 else 1.0)
			var q := Quaternion(Vector3.UP, imp.turn * w) * Quaternion(imp.axis, imp.angle * w)
			var parent: Quaternion = out.globals()[FighterAssets.PARENTS[bone]]
			out.rot[bone] = (parent.inverse() * q * parent * out.rot[bone]).normalized()
	for imp in _impulses:
		imp.age += dt


static func mask_weight(mask: String, bone: int) -> float:
	if mask == "full":
		return 1.0
	if bone >= 1 and bone <= 5:
		return 1.0
	if bone == 0:
		return 0.4
	if bone == 6 or bone == 10:
		return 0.6
	if (bone >= 7 and bone <= 9) or (bone >= 11 and bone <= 13):
		return 0.25
	return 0.0


func react(id: String, weight: float, rate: float, mask: String) -> void:
	if not motions.has(id) or weight <= 0.0:
		return
	var clip = motions[id]
	var start: float = clip.marker("impact", 0.0)
	var end: float = clip.marker("recovered", clip.last_frame())
	if end <= start:
		return
	var inverse := []
	for b in FighterAssets.BONE_COUNT:
		inverse.append(clip.rotation(b, start).inverse())
	if _reactions.size() >= 2:
		_reactions.pop_front()
	_reactions.append({"clip": clip, "end": end, "frame": start, "rate": clip.fps * rate, "weight": weight, "mask": mask,
		"age": 0.0, "release": INF, "inv": inverse, "hips": clip.hips_at(start)})


func release_reactions() -> void:
	for r in _reactions:
		if r.release == INF:
			r.release = REACTION_RELEASE + maxf(0.0, REACTION_SHOW - r.age)


func _apply_reactions(out: FighterPose, dt: float) -> void:
	if _reactions.is_empty():
		return
	for r in _reactions:
		r.age += dt
		r.frame += r.rate * dt
		if r.release != INF:
			r.release -= dt
	_reactions = _reactions.filter(func(r): return r.frame < r.end and r.release > 0.0)
	for r in _reactions:
		var attack := smoothstep01(r.age / REACTION_ATTACK)
		var decay := smoothstep01((r.end - r.frame) / maxf(1.0, r.rate * REACTION_DECAY))
		var release := smoothstep01(r.release / REACTION_RELEASE) if r.release != INF else 1.0
		var w: float = r.weight * attack * decay * release
		if w <= 0.001:
			continue
		for bone in FighterAssets.BONE_COUNT:
			var m: float = mask_weight(r.mask, bone) * w * (neck_flex if bone == 4 or bone == 5 else 1.0)
			if m <= 0.001:
				continue
			var delta: Quaternion = r.inv[bone] * r.clip.rotation(bone, r.frame)
			out.rot[bone] = (out.rot[bone] * FighterPose.scaled(delta, m)).normalized()
		if r.mask == "full":
			out.hips += (r.clip.hips_at(r.frame) - r.hips) * w
