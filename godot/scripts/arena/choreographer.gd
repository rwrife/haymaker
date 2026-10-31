class_name Choreographer
extends RefCounted
## Presentation director for a bout (simplified port of BoutChoreographer):
## feeds both fighters their engine state, turns engine events into reactions
## and effect cues, adds taunts / celebration and places the fighters.

const CELEBRATE_DELAY_KO := 0.9
const CELEBRATE_DELAY_DECISION := 0.5
const TAUNT_DELAY := 0.3
const TAUNT_CLEARANCE := 0.7
const STEP_PACE := 0.058
const HOOK_RANGE_SHARE := 0.3
const MAX_SPREAD := 0.3
const SPREAD_SPEED := 2.4
const HEAD_RADIUS := 0.24
const GLOVE_RADIUS := 0.15

var hero: Boxer
var rival: Boxer
var clock := 0.0
var ring_center := Vector3(0, 0, 0.2)
var axis := Vector3(0, 0, -1)
var base := 2.12
var slide := {} # side -> {move: float}
var hands := {} # side -> {move: bone}
var _last_event_count := 0
var _end_time = null
var _pending: Array = []
var _last_step := {}
var _spread := {HM.Who.PLAYER: 0.0, HM.Who.OPPONENT: 0.0}
var _frame_step := 0.0


func _init(p_hero: Boxer, p_rival: Boxer) -> void:
	hero = p_hero
	rival = p_rival
	measure()


func replace_rival(model: Boxer) -> void:
	rival = model
	measure()


func _model(side: int) -> Boxer:
	return hero if side == HM.Who.PLAYER else rival


static func _other(side: int) -> int:
	return HM.Who.OPPONENT if side == HM.Who.PLAYER else HM.Who.PLAYER


## Where the punching glove sits at contact in rig space (center), and the
## defender's guard head (rig space).
static func _contact_glove(b: Boxer, id: String) -> Vector3:
	var clip = b.motions[id]
	var p := FighterPose.make(b.rig.heads[0])
	clip.sample_into(clip.marker("contact", clip.last_frame() * 0.4), p)
	FighterAnimator.damp_travel(p, clip)
	var j := p.joints(b.rig.heads)
	var hand: int = b.animator.punching_hands[id]
	var fore: Vector3 = j[hand - 1]
	var wrist: Vector3 = j[hand]
	return wrist + (wrist - fore).normalized() * 0.1


static func _guard_head(b: Boxer) -> Vector3:
	var p := FighterPose.make(b.rig.heads[0])
	b.motions["idle"].sample_into(0.0, p)
	var j := p.joints(b.rig.heads)
	var head: Vector3 = j[5]
	return head + (head - (j[4] as Vector3)).normalized() * 0.12


func measure() -> void:
	var need := {}
	for side in [HM.Who.PLAYER, HM.Who.OPPONENT]:
		var attacker := _model(side)
		var defender := _model(_other(side))
		var h := _guard_head(defender)
		var s_a := attacker.fighter_scale
		var s_b := defender.fighter_scale
		need[side] = {}
		hands[side] = {}
		for pair in [[HM.Move.JAB, "jab"], [HM.Move.HOOK, "hook"], [HM.Move.UPPERCUT, "uppercut"]]:
			var g := _contact_glove(attacker, pair[1])
			hands[side][pair[0]] = attacker.animator.punching_hands[pair[1]]
			# Defender head in attacker space at root distance d: (-sB*hx, sB*hy, d - sB*hz).
			var dx := g.x * s_a + h.x * s_b
			var dy := g.y * s_a - h.y * s_b
			var r := (HEAD_RADIUS * s_b + GLOVE_RADIUS * s_a)
			var lateral2 := dx * dx + dy * dy
			var depth := sqrt(maxf(0.0, r * r - lateral2)) if lateral2 < r * r else r * 0.35
			need[side][pair[0]] = g.z * s_a + h.z * s_b + depth
	var jab: float = (need[HM.Who.PLAYER][HM.Move.JAB] + need[HM.Who.OPPONENT][HM.Move.JAB]) / 2.0
	var hook: float = (need[HM.Who.PLAYER][HM.Move.HOOK] + need[HM.Who.OPPONENT][HM.Move.HOOK]) / 2.0
	base = maxf(jab - HOOK_RANGE_SHARE * maxf(0.0, jab - hook), 1.55)
	for side in need:
		slide[side] = {}
		for move in need[side]:
			slide[side][move] = clampf(base - need[side][move], -0.3, 1.0)


func reset() -> void:
	clock = 0.0
	_last_event_count = 0
	_end_time = null
	_pending.clear()
	_last_step.clear()
	_spread = {HM.Who.PLAYER: 0.0, HM.Who.OPPONENT: 0.0}
	hero.reset_motion()
	rival.reset_motion()


func rest_pose() -> void:
	var idle := FightEngine.Status.new()
	for m in [hero, rival]:
		m.update(idle, 0, 0.0, clock, 0.0, true)
	_place(0.0, true, {HM.Who.PLAYER: HM.State.IDLE, HM.Who.OPPONENT: HM.State.IDLE})


static func _copy_status(s) -> FightEngine.Status:
	var c := FightEngine.Status.new()
	c.state = s.state
	c.hp = s.hp
	c.stamina = s.stamina
	c.ticks_in_state = s.ticks_in_state
	c.state_duration = s.state_duration
	c.current_move = s.current_move
	c.current_damage = s.current_damage
	c.knockdown_count = s.knockdown_count
	return c


## Advance presentation by dt and pose both fighters. Returns effect cues.
func update(fight: FightEngine, dt: float, tick_fraction: float, reduced: bool) -> Array:
	var step := clampf(dt, 0.0, 0.1)
	clock += step
	_frame_step = step
	if fight.events.size() < _last_event_count:
		_last_event_count = 0
	for i in range(_last_event_count, fight.events.size()):
		_handle(fight.events[i], fight)
	_last_event_count = fight.events.size()

	var hero_status := _copy_status(fight.player)
	var rival_status := _copy_status(fight.opponent)
	var hero_cue := {"type": "none"}
	var rival_cue := {"type": "none"}
	var frac := 0.0 if fight.is_over() else clampf(tick_fraction, 0.0, 0.999)
	var hero_clock := [fight.total_ticks, frac]
	var rival_clock := [fight.total_ticks, frac]
	if fight.outcome >= 0:
		if _end_time == null:
			_end_time = clock
		var by_ko: bool = fight.outcome == HM.Outcome.PLAYER_WIN_BY_KO or fight.outcome == HM.Outcome.PLAYER_LOSS_BY_KO
		var after: float = (clock - _end_time) * 60.0
		hero_status = _settle(hero_status, hero_clock, by_ko, after, fight.total_ticks)
		rival_status = _settle(rival_status, rival_clock, by_ko, after, fight.total_ticks)
		var start: float = _end_time + (CELEBRATE_DELAY_KO if by_ko else CELEBRATE_DELAY_DECISION)
		match fight.outcome:
			HM.Outcome.PLAYER_WIN_BY_KO, HM.Outcome.PLAYER_WIN_BY_DECISION:
				hero_cue = {"type": "celebrate", "start": start}
			HM.Outcome.PLAYER_LOSS_BY_KO, HM.Outcome.PLAYER_LOSS_BY_DECISION:
				rival_cue = {"type": "celebrate", "start": start}
	else:
		hero_cue = _taunt(rival, rival_status, reduced)
		rival_cue = _taunt(hero, hero_status, reduced)
	hero.update(hero_status, hero_clock[0], hero_clock[1], clock, step, reduced, hero_cue)
	rival.update(rival_status, rival_clock[0], rival_clock[1], clock, step, reduced, rival_cue)
	_place((float(fight.total_ticks) + frac) / 60.0, reduced,
		{HM.Who.PLAYER: hero_status.state, HM.Who.OPPONENT: rival_status.state})
	var cues := []
	for item in _pending:
		cues.append(_resolve(item))
	_pending.clear()
	return cues


func _settle(status: FightEngine.Status, clk: Array, by_ko: bool, after: float, total: int) -> FightEngine.Status:
	if status.state == HM.State.KO:
		return status
	var aged := status.ticks_in_state + int(after)
	if by_ko and status.state == HM.State.RECOVERING and aged < status.state_duration:
		clk[0] = total + int(after)
		clk[1] = after - floorf(after)
		status.ticks_in_state = aged
		return status
	return FightEngine.Status.new()


func _taunt(downed: Boxer, status, reduced: bool) -> Dictionary:
	if reduced or status.state != HM.State.KNOCKED_DOWN or downed.director.down_times == null:
		return {"type": "none"}
	var times: Dictionary = downed.director.down_times
	var start: float = times.ground + TAUNT_DELAY
	var until: float = times.rise - TAUNT_CLEARANCE
	if until - start >= 0.6:
		return {"type": "taunt", "start": start, "until": until}
	return {"type": "none"}


func _handle(e: Dictionary, fight: FightEngine) -> void:
	match e.type:
		"landed":
			var by: int = e.by
			var defender := _other(by)
			var status = fight.player if defender == HM.Who.PLAYER else fight.opponent
			var move: int = e.move
			_pending.append({"kind": "impact", "strong": e.damage > 15 or move == HM.Move.UPPERCUT, "counter": e.counter, "by": by, "move": move})
			var push := _blow_direction(by, move)
			_model(defender).animator.impulse(push, FighterAnimator.impulse_for(move) * (1.2 if e.counter else 1.0))
			if status.state == HM.State.KNOCKED_DOWN or status.state == HM.State.KO:
				return
			var weight: float
			var rate: float
			var clip: String
			match move:
				HM.Move.HOOK:
					clip = "hitSide" if e.tick % 2 == 0 else "hitHead"
					weight = 0.85
					rate = 1.1
				HM.Move.UPPERCUT:
					clip = "hitHead"
					weight = 1.0
					rate = 0.95
				_:
					clip = "hitHead"
					weight = 0.55 if e.tick % 3 == 0 else 0.65
					rate = 1.35 if e.tick % 3 == 0 else 1.25
			if e.counter:
				weight = minf(1.0, weight + 0.15)
				rate *= 0.9
			_model(defender).animator.react(clip, weight, rate, "full")
		"blocked":
			var by: int = e.by
			var defender := _other(by)
			var up: bool = e.move == HM.Move.UPPERCUT
			_model(defender).animator.react("hitBody" if up else "hitHead", 0.45 if up else 0.32, 1.4, "torso")
			_model(defender).animator.impulse(_blow_direction(by, e.move), FighterAnimator.BLOCKED_IMPULSE)
			_pending.append({"kind": "blocked", "by": by, "move": e.move})
		"dodged":
			_model(e.attacker).director.note_whiff(e.move)
			_pending.append({"kind": "dodge", "by": e.attacker, "move": e.move})
		"parried":
			_model(e.attacker).director.note_whiff(e.move)
			_model(e.attacker).animator.react("hitSide", 0.3, 1.3, "torso")
			_pending.append({"kind": "parry", "by": e.attacker, "move": e.move})
		"whiffed":
			_model(e.by).director.note_whiff(e.move)
		"knockdown":
			_pending.append({"kind": "knockdown", "by": _other(e.fighter), "move": HM.Move.IDLE})


## Direction (defender rig space) a blow drives the head.
func _blow_direction(by: int, move: int) -> Vector3:
	var lateral := 0.0
	if move == HM.Move.HOOK:
		var hand: int = hands[by].get(move, 9)
		# Facing fighters mirror X: a right hook sweeps in from the defender's +X side.
		lateral = -0.45 if hand == 13 else 0.45
	return Vector3(lateral, 0.5 if move == HM.Move.UPPERCUT else 0.0, -1.7).normalized()


func _resolve(item: Dictionary) -> Dictionary:
	var attacker := _model(item.by)
	var defender := _model(_other(item.by))
	var head := defender.head_world()
	var hand: int = hands[item.by].get(item.move, 9)
	var glove := attacker.joint_world(hand)
	var cue := item.duplicate()
	match item.kind:
		"impact", "knockdown":
			var toward := glove - head
			var surface := toward.normalized() * HEAD_RADIUS * defender.fighter_scale if toward.length() > 1e-4 else Vector3.ZERO
			cue.position = head + surface
		"blocked":
			cue.position = glove
		_:
			cue.position = head
	return cue


func _step(side: int) -> float:
	var d: FighterDirector = _model(side).director
	return d.lunge * float(slide[side].get(d.lunge_move, 0.0)) + d.lunge_carry * float(slide[side].get(d.carry_move, 0.0))


func _place(time: float, reduced: bool, states: Dictionary) -> void:
	var orbit := 0.0 if reduced else sin(time * 0.32) * 0.34 + sin(time * 0.9) * 0.04
	var drift := 0.0 if reduced else sin(time * 0.21) * 0.55 + sin(time * 0.8) * 0.065
	var depth := 0.0 if reduced else sin(time * 0.27 + 1.1) * 0.32
	axis = Vector3(sin(0.64 + orbit), 0, -cos(0.64 + orbit))
	var center := Vector3(drift, 0, 0.2 + depth)
	ring_center = center
	var half := base / 2.0
	hero.rotation = Vector3(0, atan2(axis.x, axis.z), 0)
	rival.rotation = Vector3(0, atan2(-axis.x, -axis.z), 0)
	for side in [HM.Who.PLAYER, HM.Who.OPPONENT]:
		var wanted := _step(side)
		var paced := wanted
		if _last_step.has(side):
			var pace := STEP_PACE * _frame_step * 60.0
			var last: float = _last_step[side]
			paced = last + clampf(wanted - last, -pace, pace)
		_last_step[side] = paced
	# Ease apart while someone is down (the fall needs room).
	var down := func(s): return states[s] == HM.State.KNOCKED_DOWN or states[s] == HM.State.KO
	var pace := SPREAD_SPEED * _frame_step
	for side in [HM.Who.PLAYER, HM.Who.OPPONENT]:
		var target := MAX_SPREAD if down.call(side) else 0.0
		if not down.call(side) and not down.call(_other(side)) and states[side] != HM.State.ATTACKING:
			target = 0.0
		var now: float = _spread[side]
		_spread[side] = now + clampf(target - now, -pace * 0.5, pace)
	hero.position = center - axis * (half - _last_step[HM.Who.PLAYER] + _spread[HM.Who.PLAYER])
	rival.position = center + axis * (half - _last_step[HM.Who.OPPONENT] + _spread[HM.Who.OPPONENT])
