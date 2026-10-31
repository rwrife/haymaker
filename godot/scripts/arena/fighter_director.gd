class_name FighterDirector
extends RefCounted
## Chooses which clip/frame each fighter shows from its engine status
## (port of FighterDirector in FighterAnimator.swift).

const A = preload("res://scripts/arena/fighter_animator.gd")

var motions: Dictionary
var idle_phase := 0.0
var idle_rate := 1.0

var lunge := 0.0
var lunge_move := HM.Move.IDLE
var lunge_carry := 0.0
var carry_move := HM.Move.IDLE
var _carry_start := 0.0
var reach := 0.0
var carry_reach := 0.0
var strike := 0.0
var strike_duration := 0.0
var contact_in := -1.0
var down_times = null # {ground, rise}
var entered_action := false
var last_attack := HM.Move.IDLE

var _state_id = null # [state, start, move]
var _key := 0
var _tell_key := 0
var _attack_key := 0
var _swing_key := 0
var _cue_key := 0
var _told := false
var _whiffed := false
var _feint := false
var _tired_swing = null
var _tail = null # Dictionary
var _guard = null # {clip, key, anchor, load, fade}
var _knockdown = null # Dictionary
var _contact_time = null
var _idle_fade := A.IDLE_FADE
var _tell_fade := A.TELL_FADE
var _interrupt_fade = null
var _active_cue := {"type": "none"}
var _spent_cue := {"type": "none"}
var _last_frame := 0.0
var _strike_clocks := {}


func _init(motion_set: Dictionary, heads: Array, hands: Dictionary) -> void:
	motions = motion_set
	for id in A.PUNCH_CLIPS:
		if motions.has(id):
			_strike_clocks[id] = _make_clock(id, heads, hands[id])


func reset() -> void:
	lunge = 0.0
	lunge_carry = 0.0
	_carry_start = 0.0
	reach = 0.0
	carry_reach = 0.0
	strike = 0.0
	contact_in = -1.0
	down_times = null
	_state_id = null
	_tail = null
	_guard = null
	_knockdown = null
	_contact_time = null
	_feint = false
	_tired_swing = null
	_interrupt_fade = null
	_active_cue = {"type": "none"}
	_spent_cue = {"type": "none"}
	_idle_fade = A.IDLE_FADE


func _next_key() -> int:
	_key += 1
	return _key


func note_whiff(move: int) -> void:
	if move == last_attack:
		_whiffed = true


# MARK: - Strike clock (glove keeps travelling fast into contact)

func _make_clock(id: String, heads: Array, hand: int) -> PackedFloat32Array:
	var clip = motions[id]
	var count: int = clip.frame_count
	var tau := PackedFloat32Array()
	tau.resize(count)
	if count <= 1:
		return tau
	var points := []
	for f in count:
		var p := FighterPose.make(heads[0])
		clip.sample_into(float(f), p)
		points.append(p.joints(heads)[hand])
	var speed := []
	for f in count - 1:
		speed.append((points[f + 1] as Vector3).distance_to(points[f]))
	var chamber := clampi(int(clip.marker("chamber", clip.last_frame() * 0.2)), 0, count - 2)
	var contact := clampi(int(ceil(clip.marker("contact", clip.last_frame() * 0.4))), chamber + 1, count - 1)
	var peak_frame := chamber
	for f in range(chamber, contact):
		if speed[f] > speed[peak_frame]:
			peak_frame = f
	var peak := maxf(1e-4, speed[peak_frame])
	tau[0] = 0.0
	for f in range(1, count):
		var seg := f - 1
		var s := maxf(A.STRIKE_TAIL_FLOOR, speed[seg] / peak) if seg > peak_frame and seg < contact else 1.0
		tau[f] = tau[f - 1] + s
	return tau


static func _tau(tau: PackedFloat32Array, frame: float) -> float:
	if tau.size() <= 1:
		return frame
	var f := clampf(frame, 0.0, float(tau.size() - 1))
	var i := mini(tau.size() - 2, int(f))
	return tau[i] + (tau[i + 1] - tau[i]) * (f - float(i))


static func _frame_at(tau: PackedFloat32Array, t: float) -> float:
	if tau.size() <= 1:
		return t
	if t <= tau[0]:
		return 0.0
	var lo := 0
	var hi := tau.size() - 1
	if t >= tau[hi]:
		return float(hi)
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if tau[mid] <= t:
			lo = mid
		else:
			hi = mid
	var span := tau[hi] - tau[lo]
	return float(lo) + ((t - tau[lo]) / span if span > 1e-6 else 0.0)


static func _slope(tau: PackedFloat32Array, frame: float) -> float:
	if tau.size() <= 1:
		return 1.0
	var i := clampi(int(frame), 0, tau.size() - 2)
	return maxf(1e-3, tau[i + 1] - tau[i])


# MARK: - Update

## input: {status, total_ticks, frac, now, dt, reduced, cue}
func update(input: Dictionary) -> A.Motion:
	entered_action = false
	contact_in = -1.0
	var status = input.status
	var id := [status.state, input.total_ticks - status.ticks_in_state, status.current_move]
	if _state_id == null or _state_id != id:
		var previous = _state_id
		_state_id = id
		var repeated: bool = previous != null and previous[0] == status.state and (status.state == HM.State.IDLE or status.state == HM.State.KO)
		if not repeated:
			_enter(status, previous, input)
	var m := _frame(input)
	if _interrupt_fade != null:
		m.fade = maxf(m.fade, _interrupt_fade)
		if status.state == HM.State.ATTACKING:
			m.arm_fade = minf(_interrupt_fade, strike_duration * A.STRIKE_FADE_SHARE)
		_interrupt_fade = null
	_update_lunge(input)
	_last_frame = m.frame
	return m


func _state_time(input: Dictionary) -> float:
	return (float(input.status.ticks_in_state) + input.frac) / 60.0


func _window(input: Dictionary) -> float:
	return float(maxi(1, input.status.state_duration)) / 60.0


static func punch_clip(move: int) -> String:
	match move:
		HM.Move.HOOK: return "hook"
		HM.Move.UPPERCUT: return "uppercut"
		_: return "jab"


func _marker(id: String, name: String, share: float) -> float:
	var clip = motions[id]
	return clip.marker(name, clip.last_frame() * share)


func _enter(status, previous, input: Dictionary) -> void:
	var now: float = input.now
	var prev_state: int = previous[0] if previous != null else HM.State.IDLE
	var prev_move: int = previous[2] if previous != null else HM.Move.IDLE
	_idle_fade = A.IDLE_FADE
	var leaving_taunt: bool = _active_cue.type == "taunt"
	if status.state != HM.State.IDLE:
		entered_action = true
		if _active_cue.type != "none":
			_spent_cue = _active_cue
		_active_cue = {"type": "none"}
	if status.state != HM.State.RECOVERING:
		_tired_swing = null
	if _knockdown != null and not status.state in [HM.State.IDLE, HM.State.KNOCKED_DOWN, HM.State.KO]:
		_knockdown = null
		_interrupt_fade = A.GET_UP_INTERRUPT_FADE
	match status.state:
		HM.State.IDLE:
			if prev_state == HM.State.KNOCKED_DOWN and _knockdown != null:
				_knockdown.risen = true
				if _knockdown.get_up_start == null or _knockdown.get_up_start > now:
					_knockdown.get_up_start = now
			elif prev_state in [HM.State.BLOCKING, HM.State.PARRYING, HM.State.DODGING]:
				_start_guard_exit(now)
			elif prev_state == HM.State.TELLING and prev_move in [HM.Move.FEINT, HM.Move.BLOCK, HM.Move.DODGE]:
				_idle_fade = 0.2
			_feint = false
			if prev_state != HM.State.KNOCKED_DOWN:
				down_times = null
		HM.State.TELLING:
			_tail = null
			_feint = false
			_tell_key = _next_key()
			_tell_fade = A.TAUNT_INTERRUPT_FADE if leaving_taunt else A.TELL_FADE
			if status.current_move == HM.Move.BLOCK or status.current_move == HM.Move.DODGE:
				var start: int = input.total_ticks - status.ticks_in_state
				var clip := "slip" if status.current_move == HM.Move.DODGE else ("block" if start % 2 == 0 else "bodyBlock")
				_guard = {"clip": clip, "key": _tell_key, "anchor": start, "load": maxf(0.1, _window(input)), "fade": _tell_fade}
			else:
				_guard = null
		HM.State.ATTACKING:
			_tail = null
			_whiffed = false
			_feint = false
			_carry_start = lunge + lunge_carry
			carry_reach = (lunge * reach + lunge_carry * carry_reach) / _carry_start if _carry_start > 1e-4 else 0.0
			carry_move = lunge_move
			last_attack = status.current_move
			_told = prev_state == HM.State.TELLING and prev_move == status.current_move
			_attack_key = _tell_key if _told else _next_key()
		HM.State.RECOVERING:
			if prev_state == HM.State.ATTACKING:
				_start_punch_recovery(input)
			elif prev_state == HM.State.TELLING and prev_move == HM.Move.FEINT:
				_feint = true
			elif prev_state in [HM.State.BLOCKING, HM.State.PARRYING, HM.State.DODGING]:
				_start_guard_exit(now)
			elif _tired_swing != null:
				_tail = null
				_swing_key = _next_key()
				last_attack = _tired_swing
			else:
				_feint = false
		HM.State.BLOCKING, HM.State.PARRYING, HM.State.DODGING:
			_tail = null
			if prev_state == HM.State.TELLING and _guard != null and _guard.key == _tell_key:
				return
			var clip := "slip" if status.state == HM.State.DODGING else "block"
			var c = motions[clip]
			var natural: float = c.marker("slipped" if clip == "slip" else "guardUp", 10.0) / c.fps
			var load: float
			var fade: float
			match status.state:
				HM.State.PARRYING:
					load = A.PARRY_LOAD
					fade = A.PARRY_FADE
				HM.State.DODGING:
					load = minf(minf(natural, _window(input) * 0.6), A.MAX_SLIP_LOAD)
					fade = A.SLIP_FADE
				_:
					load = minf(natural, A.GUARD_LOAD)
					fade = A.GUARD_FADE
			_guard = {"clip": clip, "key": _next_key(), "anchor": input.total_ticks - status.ticks_in_state, "load": load, "fade": fade}
		HM.State.KNOCKED_DOWN, HM.State.KO:
			_tail = null
			_guard = null
			_feint = false
			_start_knockdown(status, input)


func _start_punch_recovery(input: Dictionary) -> void:
	var id := punch_clip(last_attack)
	var clip = motions[id]
	var contact: float = clip.marker("contact", clip.last_frame() * 0.4)
	var recovered: float = clip.marker("recovered", clip.last_frame())
	var retracted := minf(recovered, contact + (recovered - contact) * 0.3)
	var snap := maxf(A.RETRACT_TIME, (retracted - contact) / (clip.fps * A.MAX_RETRACT_SPEEDUP))
	if _whiffed:
		snap *= A.WHIFF_RETRACT_STRETCH
	var settle := _window(input) - snap - (A.WHIFF_HOLD if _whiffed else 0.0) - A.PUNCH_EXIT_FADE * 0.6
	var fitted: float = (recovered - retracted) / maxf(0.05, settle) / clip.fps
	var speed := clampf(fitted, A.RECOVER_SPEED, A.MAX_SETTLE_SPEEDUP)
	if _whiffed:
		speed *= A.WHIFF_SLOWDOWN
	var start: float = input.now - _state_time(input)
	_contact_time = start
	var travel_cap: float = FighterAnimator.punch_travel(id) * (clip.hips_at(contact).z - clip.hips_at(0.0).z)
	_tail = {"clip": id, "key": _attack_key, "frame0": contact, "now0": start, "snap_end": retracted, "snap_time": snap,
		"rate": clip.fps * speed, "hold": A.WHIFF_HOLD if _whiffed else 0.0, "end": recovered, "exit_fade": A.PUNCH_EXIT_FADE,
		"anticipation": A.anticipation_for(last_attack) if _told else 0.0, "travel_cap": travel_cap, "guard_arm": true}


func _start_guard_exit(now: float) -> void:
	if _guard == null:
		return
	var clip = motions[_guard.clip]
	var hold_end: float = clip.marker("holdEnd", clip.last_frame() * 0.5)
	var up: float = clip.marker("slipped" if _guard.clip == "slip" else "guardUp", clip.last_frame() * 0.3)
	_tail = {"clip": _guard.clip, "key": _guard.key, "frame0": maxf(minf(up, hold_end), minf(_last_frame, clip.last_frame())),
		"now0": now, "snap_end": -1.0, "snap_time": 0.0, "rate": clip.fps * A.GUARD_EXIT_RATE, "hold": 0.0,
		"end": clip.last_frame(), "exit_fade": A.GUARD_EXIT_FADE, "anticipation": 0.0, "travel_cap": INF, "guard_arm": false}
	_guard = null


func _tail_frame(tail: Dictionary, now: float) -> float:
	var t := maxf(0.0, now - tail.now0 - tail.hold)
	if tail.snap_end < 0.0 or tail.snap_time <= 0.0:
		return minf(tail.end, tail.frame0 + t * tail.rate)
	if t < tail.snap_time:
		return tail.frame0 + (tail.snap_end - tail.frame0) * A.snap_back(t / tail.snap_time)
	return minf(tail.end, tail.snap_end + (t - tail.snap_time) * tail.rate)


func _tail_finished(tail: Dictionary, now: float) -> bool:
	return _tail_frame(tail, now) >= tail.end - tail.exit_fade * tail.rate * 0.6


func _tail_motion(tail: Dictionary, now: float) -> A.Motion:
	var t := maxf(0.0, now - tail.now0 - tail.hold)
	var m := A.Motion.make(tail.clip, _tail_frame(tail, now), tail.rate, tail.key, A.IDLE_FADE, tail.anticipation)
	if tail.snap_end >= 0.0 and tail.snap_time > 0.0 and t < tail.snap_time:
		m.snap_from = tail.frame0
		m.snap_to = tail.snap_end
		m.snap_weight = A.snap_back(t / tail.snap_time)
		m.frame = tail.frame0 + (tail.snap_end - tail.frame0) * m.snap_weight
	if tail.travel_cap != INF:
		m.travel_cap = tail.travel_cap
		m.travel_scale = 1.0 - A.ease_in_out((now - tail.now0) / A.TRAVEL_RETURN)
	if tail.guard_arm:
		m.guard_arm = A.smoothstep01((t - tail.snap_time * 0.5) / A.GUARD_ARM_TIME)
	return m


func _start_knockdown(status, input: Dictionary) -> void:
	var ko: bool = status.state == HM.State.KO
	var anchor: float = input.now if ko else input.now - _state_time(input)
	var window := INF if ko else _window(input)
	var fall = motions["knockdown"]
	var rise = motions["getUp"]
	var react: float = fall.marker("react", 0.0)
	var settled: float = fall.marker("settled", fall.last_frame())
	var fall_time: float = maxf(0.0, settled - react) / fall.fps
	var up_time: float = rise.marker("standing", rise.last_frame()) / rise.fps
	var speed := 1.0
	if not ko:
		var budget := window - A.MINIMUM_LIE
		speed = minf(A.MAX_DOWN_SPEEDUP, maxf(1.0, (fall_time + up_time) / maxf(0.1, budget)))
	var get_up_start = null
	if not ko:
		get_up_start = maxf(anchor + window - up_time / speed, anchor + fall_time / speed)
	_knockdown = {"key": _next_key(), "get_up_key": _next_key(), "anchor": anchor, "fall_rate": fall.fps * speed,
		"get_up_rate": rise.fps * speed, "get_up_start": get_up_start, "risen": false}
	down_times = {"ground": anchor + (_ground_frame() - react) / (fall.fps * speed), "rise": anchor + window}


func _ground_frame() -> float:
	var fall = motions["knockdown"]
	var marker: float = fall.marker("ground", fall.last_frame())
	var standing: float = fall.hips[0].y
	var lowest := standing
	for h in fall.hips:
		lowest = minf(lowest, h.y)
	var threshold := lowest + (standing - lowest) * 0.15
	var react := int(fall.marker("react", 0.0))
	for i in range(react, fall.hips.size()):
		if fall.hips[i].y <= threshold:
			return minf(marker, float(i))
	return marker


func _frame(input: Dictionary) -> A.Motion:
	match input.status.state:
		HM.State.IDLE:
			return _settle(input)
		HM.State.TELLING:
			if _guard != null and _guard.key == _tell_key:
				return _guard_motion(input)
			return _tell_motion(input)
		HM.State.ATTACKING:
			return _attack_motion(input)
		HM.State.RECOVERING:
			if _feint:
				return _feint_motion(input)
			if _tired_swing != null:
				return _swing_motion(input)
			return _settle(input)
		HM.State.BLOCKING, HM.State.PARRYING, HM.State.DODGING:
			if _guard != null:
				return _guard_motion(input)
			return _settle(input)
		_:
			return _down_motion(input)


func _tell_motion(input: Dictionary) -> A.Motion:
	var move: int = input.status.current_move
	var id := punch_clip(move)
	var chamber := _marker(id, "chamber", 0.2)
	var load := maxf(A.MINIMUM_TELL_LOAD, _window(input) * A.TELL_LOAD_FRACTION)
	var u := _state_time(input) / load
	return A.Motion.make(id, chamber * A.ease_in_out(u), chamber / load if u < 1.0 else 0.0, _tell_key, _tell_fade,
		A.anticipation_for(move), 1.0 if u >= 1.0 else 0.0)


static func punch_start(clip, window: float, told: bool) -> float:
	var chamber: float = clip.marker("chamber", clip.last_frame() * 0.2)
	var contact: float = clip.marker("contact", clip.last_frame() * 0.4)
	return chamber if told else minf(chamber, maxf(0.0, contact - window * clip.fps * A.MAX_PUNCH_SPEEDUP))


func _attack_motion(input: Dictionary) -> A.Motion:
	var id := punch_clip(last_attack)
	var clip = motions[id]
	var chamber := _marker(id, "chamber", 0.2)
	var contact := _marker(id, "contact", 0.4)
	var window := _window(input)
	var start := chamber if _told else punch_start(clip, window, false)
	var tau: PackedFloat32Array = _strike_clocks[id]
	var t0 := _tau(tau, start)
	var t1 := _tau(tau, contact)
	var hold := 0.0
	var duration := window
	if _told:
		duration = minf(window, (t1 - t0) / (clip.fps * A.SLOWEST_STRIKE))
		hold = window - duration
		duration = maxf(1.0 / 120.0, duration)
	var t := _state_time(input)
	strike = clampf((t - hold) / duration, 0.0, 1.0)
	strike_duration = duration
	contact_in = maxf(0.0, hold + duration - t)
	var frame := _frame_at(tau, t0 + (t1 - t0) * strike)
	var holding := t < hold
	var rate := 0.0 if holding else (t1 - t0) / duration / _slope(tau, frame)
	var m := A.Motion.make(id, frame, rate, _attack_key, A.PLAYER_PUNCH_FADE,
		A.anticipation_for(last_attack) if _told else 0.0, 1.0 if holding else 0.0)
	m.off_arm = start + (contact - start) * strike
	if id == "hook" and not _told:
		m.arm_fade = A.PLAYER_HOOK_ARM_FADE
	return m


func _feint_motion(input: Dictionary) -> A.Motion:
	var chamber := _marker("jab", "chamber", 0.2)
	var contact := _marker("jab", "contact", 0.4)
	var t := _state_time(input)
	var frame: float
	if t < 0.2:
		frame = chamber + (contact - chamber) * 0.3 * sin(PI * t / 0.2)
	else:
		frame = chamber * (1.0 - A.ease_in_out((t - 0.2) / 0.3))
	return A.Motion.make("jab", frame, 0.0, _tell_key, _tell_fade, A.anticipation_for(HM.Move.FEINT))


func _swing_motion(input: Dictionary) -> A.Motion:
	var id := punch_clip(last_attack)
	var chamber := _marker(id, "chamber", 0.2)
	var contact := _marker(id, "contact", 0.4)
	var r := sin(PI * minf(1.0, _state_time(input) / 0.35))
	return A.Motion.make(id, chamber + (contact - chamber) * 0.55 * r, 0.0, _swing_key, 0.08)


func _guard_motion(input: Dictionary) -> A.Motion:
	var clip = motions[_guard.clip]
	var up: float = clip.marker("slipped" if _guard.clip == "slip" else "guardUp", clip.last_frame() * 0.3)
	var hold_end := maxf(up, clip.marker("holdEnd", up))
	var elapsed: float = (float(input.total_ticks - _guard.anchor) + input.frac) / 60.0
	var frame: float
	var rate: float
	if elapsed < _guard.load or input.status.state == HM.State.TELLING:
		frame = up * A.ease_out(elapsed / _guard.load)
		rate = up / _guard.load if elapsed < _guard.load else 0.0
	else:
		var state_end: int = input.total_ticks - input.status.ticks_in_state + input.status.state_duration
		var span := maxf(1.0 / 60.0, float(state_end - _guard.anchor) / 60.0 - _guard.load)
		rate = minf(clip.fps, (hold_end - up) / span)
		frame = minf(hold_end, up + rate * (elapsed - _guard.load))
	return A.Motion.make(_guard.clip, minf(frame, clip.last_frame()), rate, _guard.key, _guard.fade, 0.0,
		0.6 if elapsed >= _guard.load else 0.0)


func _down_motion(input: Dictionary) -> A.Motion:
	if _knockdown == null:
		return _idle_loop(input)
	var now: float = input.now
	var rise = motions["getUp"]
	if _knockdown.get_up_start != null and now >= _knockdown.get_up_start:
		var standing: float = rise.marker("standing", rise.last_frame())
		var f := minf(standing, (now - _knockdown.get_up_start) * _knockdown.get_up_rate)
		return A.Motion.make("getUp", f, _knockdown.get_up_rate if f < standing else 0.0, _knockdown.get_up_key, A.GET_UP_FADE)
	var frame := _fall_frame(now)
	var fall = motions["knockdown"]
	var still: bool = frame >= fall.last_frame()
	return A.Motion.make("knockdown", frame, 0.0 if still else _knockdown.fall_rate, _knockdown.key, A.KNOCKDOWN_FADE, 0.0,
		0.5 if still else 0.0)


func _fall_frame(now: float) -> float:
	var fall = motions["knockdown"]
	return minf(fall.last_frame(), fall.marker("react", 0.0) + maxf(0.0, now - _knockdown.anchor) * _knockdown.fall_rate)


func _rising_motion(input: Dictionary) -> A.Motion:
	if _knockdown == null or not _knockdown.risen:
		return null
	var now: float = input.now
	var rise = motions["getUp"]
	var standing: float = rise.marker("standing", rise.last_frame())
	var start: float = _knockdown.get_up_start
	var f: float = (now - start) * _knockdown.get_up_rate
	if f < rise.last_frame() - rise.fps * 0.45 * 0.6:
		return A.Motion.make("getUp", minf(rise.last_frame(), f), _knockdown.get_up_rate, _knockdown.get_up_key, A.GET_UP_FADE)
	_knockdown = null
	_idle_fade = 0.45
	return null


func _settle(input: Dictionary) -> A.Motion:
	var now: float = input.now
	var rising := _rising_motion(input)
	if rising != null:
		return rising
	if _tail != null:
		if not _tail_finished(_tail, now):
			return _tail_motion(_tail, now)
		_idle_fade = _tail.exit_fade
		_tail = null
	var cue: Dictionary = input.cue
	if cue != _active_cue and _active_cue.type == "taunt":
		_idle_fade = A.TAUNT_FADE_OUT
	if cue.type == "taunt" and now >= cue.start and now < cue.until and not input.reduced and cue != _spent_cue:
		var victory = motions["victory"]
		if _active_cue != cue:
			_active_cue = cue
			_cue_key = _next_key()
		var arms_up: float = victory.marker("armsUp", victory.last_frame() * 0.2)
		var arms_down: float = victory.marker("armsDown", victory.last_frame() * 0.8)
		var frame := minf(arms_down, arms_up - victory.fps * A.TAUNT_LEAD + (now - cue.start) * victory.fps)
		return A.Motion.make("victory", frame, victory.fps, _cue_key, A.TAUNT_FADE_IN)
	if cue.type == "celebrate" and now >= cue.start and cue != _spent_cue:
		var victory = motions["victory"]
		if _active_cue != cue:
			_active_cue = cue
			_cue_key = _next_key()
		var frame: float = (now - cue.start) * victory.fps
		if frame < victory.last_frame() - victory.fps * 0.5:
			return A.Motion.make("victory", frame, victory.fps, _cue_key, A.VICTORY_FADE)
		_spent_cue = cue
		_idle_fade = 0.5
	if _active_cue.type == "taunt":
		_spent_cue = _active_cue
	_active_cue = {"type": "none"}
	return _idle_loop(input)


func _idle_loop(input: Dictionary) -> A.Motion:
	var clip = motions["idle"]
	if input.reduced:
		return A.Motion.make("idle", 0.0, 0.0, 0, _idle_fade)
	var frame: float = (input.now * idle_rate + idle_phase) * clip.fps
	return A.Motion.make("idle", frame, clip.fps * idle_rate, 0, _idle_fade)


func _update_lunge(input: Dictionary) -> void:
	if input.status.state == HM.State.ATTACKING:
		var p := strike
		lunge_move = last_attack
		lunge = p * p * (2.0 - p)
		lunge_carry = _carry_start * (1.0 - lunge)
		_contact_time = null
	else:
		lunge_carry = maxf(0.0, lunge_carry - input.dt / A.LUNGE_RELEASE)
		if _contact_time != null:
			var t: float = input.now - _contact_time
			lunge = 1.0 - A.ease_in_out(t / A.LUNGE_RELEASE) if t < A.LUNGE_RELEASE else 0.0
			if lunge == 0.0:
				_contact_time = null
		else:
			lunge = maxf(0.0, lunge - input.dt / A.LUNGE_RELEASE)
