class_name FightEngine
extends RefCounted
## Bit-exact GDScript port of HaymakerKit's deterministic FightEngine.
## 60 ticks per second, integer-only state. Events are dictionaries:
## {type: "landed"|"blocked"|"dodged"|"parried"|"whiffed"|"knockdown"|"rise"|"roundStart"|"roundEnd"|"boutEnd", tick, ...}

const TICKS_PER_SECOND := 60
const PLAYER_TABLE := {
	HM.Move.JAB: {"windup": 5, "recover": 8, "stamina": 5, "damage": 8},
	HM.Move.HOOK: {"windup": 8, "recover": 14, "stamina": 9, "damage": 14},
	HM.Move.UPPERCUT: {"windup": 11, "recover": 20, "stamina": 14, "damage": 22},
}


class Config:
	var rounds := 3
	var round_ticks := 3600
	var rest_ticks := 600
	var max_knockdowns := 3
	var revival_hp := 30
	var counter_multiplier := 2
	var block_hold_ticks := 24
	var dodge_ticks := 8
	var whiff_recover_ticks := 6
	var max_hp := 100
	var max_stamina := 100
	var stamina_regen := 2
	var knockdown_threshold := 25
	var knockdown_ticks := 180
	var block_reduction := 8
	var parry_window := 6

	func total_fight_ticks() -> int:
		return rounds * round_ticks + (rounds - 1) * maxi(0, rest_ticks)

	func hard_tick_cap() -> int:
		return total_fight_ticks() + maxi(0, knockdown_ticks) + 4096

	static func make(p_rounds: int = 3, p_round_ticks: int = 3600, p_rest_ticks: int = 600, p_dodge_ticks: int = 8) -> Config:
		var c := Config.new()
		c.rounds = p_rounds
		c.round_ticks = p_round_ticks
		c.rest_ticks = p_rest_ticks
		c.dodge_ticks = p_dodge_ticks
		return c

	static func career() -> Config:
		return make(3, 10800, 240, 20)

	static func sparring() -> Config:
		return make(1, 3600, 0)


class Status:
	var state := HM.State.IDLE
	var hp := 100
	var stamina := 100
	var ticks_in_state := 0
	var state_duration := 0
	var current_move := HM.Move.IDLE
	var current_damage := 0
	var knockdown_count := 0


class Stats:
	var thrown := 0
	var landed := 0
	var whiffed := 0
	var counters := 0
	var blocks_made := 0
	var dodges_made := 0
	var parries_made := 0
	var damage_dealt := 0
	var damage_taken := 0
	var knockdowns_scored := 0
	var knockdowns_suffered := 0

	func to_dict() -> Dictionary:
		return {"thrown": thrown, "landed": landed, "whiffed": whiffed, "counters": counters,
			"blocksMade": blocks_made, "dodgesMade": dodges_made, "parriesMade": parries_made,
			"damageDealt": damage_dealt, "damageTaken": damage_taken,
			"knockdownsScored": knockdowns_scored, "knockdownsSuffered": knockdowns_suffered}


var config: Config
var seed: int
var book: OpponentBook
var round := 1
var tick_in_round := 0
var total_ticks := 0
var phase := HM.Phase.FIGHTING
var player := Status.new()
var opponent := Status.new()
var player_stats := Stats.new()
var opponent_stats := Stats.new()
var events: Array = []
var outcome := -1
var opp_active = null # Dictionary pattern entry or null

var _rng: SeededRNG
var _next_index := 0
var _opp_waiting := 0
var _rest_left := 0


func _init(p_config: Config, p_seed: int, p_book: OpponentBook) -> void:
	config = p_config
	seed = p_seed
	book = p_book
	player.hp = config.max_hp
	player.stamina = config.max_stamina
	opponent.hp = config.max_hp
	opponent.stamina = config.max_stamina
	events = [{"type": "roundStart", "tick": 0, "round": 1}]
	_rng = SeededRNG.new(seed ^ 0x5EED1B0000000000)
	_opp_waiting = _next_gap()


func is_over() -> bool:
	return outcome >= 0


func _next_gap() -> int:
	return book.min_gap + _rng.next_less_than(book.gap_spread + 1)


func _peek_entry() -> Dictionary:
	return book.sequence[_next_index]


func _next_entry() -> Dictionary:
	var e: Dictionary = book.sequence[_next_index]
	_next_index = (_next_index + 1) % book.sequence.size()
	return e


func _opp(key: String, fallback: int) -> int:
	return opp_active[key] if opp_active != null else fallback


# Test hooks (mirrors the internal `force*` helpers)
func force_opponent_pattern(entry_index: int) -> void:
	_next_index = entry_index
	opponent.state = HM.State.IDLE
	opponent.current_move = HM.Move.IDLE
	opponent.current_damage = 0
	_opp_waiting = 1


func force_player_knockdown(ticks_into: int = 0) -> void:
	_knock_down(HM.Who.PLAYER)
	player.ticks_in_state = ticks_into


func force_opponent_knockdown(ticks_into: int = 0) -> void:
	_knock_down(HM.Who.OPPONENT)
	opponent.ticks_in_state = ticks_into


func tick(input: int) -> void:
	if is_over():
		return
	total_ticks += 1
	if phase == HM.Phase.RESTING:
		_rest_left -= 1
		if _rest_left <= 0:
			phase = HM.Phase.FIGHTING
			round += 1
			tick_in_round = 0
			events.append({"type": "roundStart", "tick": total_ticks, "round": round})
		return
	_start_player_action(input)
	_advance_opponent_scheduler()
	player.ticks_in_state += 1
	opponent.ticks_in_state += 1
	_resolve_opponent_phase()
	if is_over():
		return
	_resolve_player_phase()
	if is_over():
		return
	_regen(player)
	_regen(opponent)
	tick_in_round += 1
	if tick_in_round >= config.round_ticks:
		_end_round()


func _start_player_action(input: int) -> void:
	if player.state != HM.State.IDLE:
		return
	match input:
		HM.Cmd.JAB, HM.Cmd.HOOK, HM.Cmd.UPPERCUT:
			var move := HM.input_as_move(input)
			var timing: Dictionary = PLAYER_TABLE[move]
			player.current_move = move
			player_stats.thrown += 1
			if player.stamina < timing.stamina:
				player.stamina = maxi(0, player.stamina - maxi(1, timing.stamina / 2))
				_enter_player_recovering(config.whiff_recover_ticks)
				player_stats.whiffed += 1
				events.append({"type": "whiffed", "tick": total_ticks, "by": HM.Who.PLAYER, "move": move})
			else:
				player.stamina -= timing.stamina
				player.state = HM.State.ATTACKING
				player.ticks_in_state = 0
				player.state_duration = timing.windup
				player.current_damage = timing.damage
		HM.Cmd.BLOCK:
			_set_player(HM.State.BLOCKING, config.block_hold_ticks, HM.Move.BLOCK)
		HM.Cmd.DODGE:
			_set_player(HM.State.DODGING, config.dodge_ticks, HM.Move.DODGE)
		HM.Cmd.PARRY:
			_set_player(HM.State.PARRYING, config.parry_window, HM.Move.PARRY)


func _set_player(state: int, duration: int, move: int) -> void:
	player.state = state
	player.ticks_in_state = 0
	player.state_duration = duration
	player.current_move = move
	player.current_damage = 0


func _enter_player_recovering(ticks: int) -> void:
	_set_player(HM.State.RECOVERING, ticks, HM.Move.IDLE)


func _enter_opponent_recovering(ticks: int) -> void:
	opponent.state = HM.State.RECOVERING
	opponent.ticks_in_state = 0
	opponent.state_duration = ticks
	opponent.current_move = HM.Move.IDLE
	opponent.current_damage = 0


func _advance_opponent_scheduler() -> void:
	if opponent.state != HM.State.IDLE:
		return
	_opp_waiting -= 1
	if _opp_waiting <= 0:
		var peek := _peek_entry()
		if opponent.stamina < peek.stamina:
			_opp_waiting = 0
			return
		var committed := _next_entry()
		opponent.stamina -= committed.stamina
		opp_active = committed
		opponent.state = HM.State.TELLING
		opponent.ticks_in_state = 0
		opponent.state_duration = committed.tell
		opponent.current_move = committed.move
		opponent.current_damage = committed.damage
		_opp_waiting = _next_gap()


func _resolve_opponent_phase() -> void:
	var done := opponent.ticks_in_state >= opponent.state_duration
	if not done:
		return
	match opponent.state:
		HM.State.TELLING:
			if opponent.current_move == HM.Move.FEINT:
				_enter_opponent_recovering(_opp("recover", 8))
			elif opponent.current_move == HM.Move.BLOCK:
				opponent.state = HM.State.BLOCKING
				opponent.ticks_in_state = 0
				opponent.state_duration = _opp("impact", 12)
			elif opponent.current_move == HM.Move.DODGE:
				opponent.state = HM.State.DODGING
				opponent.ticks_in_state = 0
				opponent.state_duration = _opp("impact", 20)
			else:
				opponent.state = HM.State.ATTACKING
				opponent.ticks_in_state = 0
				opponent.state_duration = _opp("impact", 4)
				opponent_stats.thrown += 1
		HM.State.DODGING, HM.State.BLOCKING:
			_enter_opponent_recovering(_opp("recover", 8))
		HM.State.ATTACKING:
			_resolve_opponent_impact()
			_enter_opponent_recovering(_opp("recover", 8))
		HM.State.RECOVERING:
			opponent.state = HM.State.IDLE
			opponent.current_move = HM.Move.IDLE
			opponent.current_damage = 0
			opp_active = null
		HM.State.KNOCKED_DOWN:
			_answer_the_count(HM.Who.OPPONENT)


func _resolve_opponent_impact() -> void:
	var move := opponent.current_move
	var base := opponent.current_damage
	if player.state == HM.State.KNOCKED_DOWN:
		opponent_stats.whiffed += 1
		events.append({"type": "whiffed", "tick": total_ticks, "by": HM.Who.OPPONENT, "move": move})
		return
	match player.state:
		HM.State.DODGING:
			player_stats.dodges_made += 1
			opponent_stats.whiffed += 1
			events.append({"type": "dodged", "tick": total_ticks, "attacker": HM.Who.OPPONENT, "move": move})
		HM.State.PARRYING:
			player_stats.parries_made += 1
			opponent_stats.whiffed += 1
			events.append({"type": "parried", "tick": total_ticks, "attacker": HM.Who.OPPONENT, "move": move})
		HM.State.BLOCKING:
			var applied := HM.blocked_damage(base, config.block_reduction, move == HM.Move.UPPERCUT)
			player_stats.blocks_made += 1
			player.hp = maxi(0, player.hp - applied)
			player_stats.damage_taken += applied
			opponent_stats.damage_dealt += applied
			events.append({"type": "blocked", "tick": total_ticks, "by": HM.Who.OPPONENT, "move": move, "damage": applied})
			if player.hp <= 0:
				_knock_down(HM.Who.PLAYER, true)
		_:
			player.hp = maxi(0, player.hp - base)
			player_stats.damage_taken += base
			opponent_stats.damage_dealt += base
			opponent_stats.landed += 1
			events.append({"type": "landed", "tick": total_ticks, "by": HM.Who.OPPONENT, "move": move, "damage": base, "counter": false})
			if player.hp <= 0:
				_knock_down(HM.Who.PLAYER, true)
			elif base >= config.knockdown_threshold:
				_knock_down(HM.Who.PLAYER)
			if player.state == HM.State.KNOCKED_DOWN and player.ticks_in_state >= player.state_duration:
				_answer_the_count(HM.Who.PLAYER)


func _resolve_player_phase() -> void:
	var done := player.ticks_in_state >= player.state_duration
	match player.state:
		HM.State.ATTACKING:
			if done:
				_resolve_player_impact()
				_enter_player_recovering(_player_recover())
		HM.State.RECOVERING:
			if done:
				player.state = HM.State.IDLE
				player.current_move = HM.Move.IDLE
				player.current_damage = 0
		HM.State.BLOCKING, HM.State.DODGING, HM.State.PARRYING:
			if done:
				player.state = HM.State.IDLE
				player.current_move = HM.Move.IDLE
		HM.State.KNOCKED_DOWN:
			if done:
				_answer_the_count(HM.Who.PLAYER)


func _player_recover() -> int:
	if PLAYER_TABLE.has(player.current_move):
		return PLAYER_TABLE[player.current_move].recover
	return config.whiff_recover_ticks


func _resolve_player_impact() -> void:
	var move := player.current_move
	var base := player.current_damage
	if opponent.state == HM.State.KNOCKED_DOWN:
		player_stats.whiffed += 1
		events.append({"type": "whiffed", "tick": total_ticks, "by": HM.Who.PLAYER, "move": move})
		return
	if opponent.state == HM.State.DODGING:
		opponent_stats.dodges_made += 1
		player_stats.whiffed += 1
		events.append({"type": "dodged", "tick": total_ticks, "attacker": HM.Who.PLAYER, "move": move})
		return
	var is_counter := opponent.state == HM.State.TELLING and opponent.current_move != HM.Move.FEINT
	var damage := base * config.counter_multiplier if is_counter else base
	var blocked := false
	if opponent.state == HM.State.BLOCKING:
		damage = HM.blocked_damage(damage, config.block_reduction, move == HM.Move.UPPERCUT)
		blocked = true
	opponent.hp = maxi(0, opponent.hp - damage)
	player_stats.damage_dealt += damage
	opponent_stats.damage_taken += damage
	if is_counter:
		player_stats.counters += 1
	if blocked:
		opponent_stats.blocks_made += 1
		events.append({"type": "blocked", "tick": total_ticks, "by": HM.Who.PLAYER, "move": move, "damage": damage})
		if opponent.hp <= 0:
			_knock_down(HM.Who.OPPONENT, true)
	else:
		player_stats.landed += 1
		events.append({"type": "landed", "tick": total_ticks, "by": HM.Who.PLAYER, "move": move, "damage": damage, "counter": is_counter})
		if opponent.hp <= 0:
			_knock_down(HM.Who.OPPONENT, true)
		elif damage >= config.knockdown_threshold:
			_knock_down(HM.Who.OPPONENT)


func _knock_down(fighter: int, ko: bool = false) -> void:
	var status: Status = player if fighter == HM.Who.PLAYER else opponent
	var down_number := status.knockdown_count + 1
	var is_ko := ko or down_number >= config.max_knockdowns
	events.append({"type": "knockdown", "tick": total_ticks, "fighter": fighter, "number": down_number})
	if fighter == HM.Who.PLAYER:
		opponent_stats.knockdowns_scored += 1
		player_stats.knockdowns_suffered += 1
	else:
		player_stats.knockdowns_scored += 1
		opponent_stats.knockdowns_suffered += 1
	status.knockdown_count += 1
	status.current_move = HM.Move.IDLE
	status.current_damage = 0
	if is_ko:
		status.state = HM.State.KO
		status.hp = 0
	else:
		status.state = HM.State.KNOCKED_DOWN
		status.ticks_in_state = 0
		status.state_duration = config.knockdown_ticks
	if fighter == HM.Who.OPPONENT:
		opp_active = null
	if is_ko:
		_finish(HM.Outcome.PLAYER_LOSS_BY_KO if fighter == HM.Who.PLAYER else HM.Outcome.PLAYER_WIN_BY_KO)


func _answer_the_count(fighter: int) -> void:
	var status: Status = player if fighter == HM.Who.PLAYER else opponent
	if status.state != HM.State.KNOCKED_DOWN:
		return
	status.hp = maxi(status.hp, config.revival_hp)
	status.stamina = config.max_stamina / 2
	status.state = HM.State.IDLE
	status.ticks_in_state = 0
	if fighter == HM.Who.OPPONENT:
		_opp_waiting = _next_gap()
	events.append({"type": "rise", "tick": total_ticks, "fighter": fighter})


func _regen(status: Status) -> void:
	status.stamina = mini(config.max_stamina, status.stamina + HM.stamina_regen(status.state, config.stamina_regen))


func _end_round() -> void:
	events.append({"type": "roundEnd", "tick": total_ticks, "round": round})
	if player.state == HM.State.KNOCKED_DOWN:
		player.hp = maxi(player.hp, config.revival_hp)
		player.stamina = config.max_stamina
		player.state = HM.State.IDLE
		events.append({"type": "rise", "tick": total_ticks, "fighter": HM.Who.PLAYER})
	if opponent.state == HM.State.KNOCKED_DOWN:
		opponent.hp = maxi(opponent.hp, config.revival_hp)
		opponent.stamina = config.max_stamina
		opponent.state = HM.State.IDLE
		opp_active = null
		_opp_waiting = _next_gap()
		events.append({"type": "rise", "tick": total_ticks, "fighter": HM.Who.OPPONENT})
	if is_over():
		return
	if round >= config.rounds:
		_finish_by_decision()
	elif config.rest_ticks <= 0:
		_begin_next_round()
	else:
		phase = HM.Phase.RESTING
		_rest_left = config.rest_ticks
		for s in [player, opponent]:
			s.state = HM.State.IDLE
			s.current_move = HM.Move.IDLE
			s.stamina = config.max_stamina


func _begin_next_round() -> void:
	phase = HM.Phase.FIGHTING
	round += 1
	tick_in_round = 0
	for s in [player, opponent]:
		s.state = HM.State.IDLE
		s.current_move = HM.Move.IDLE
		s.stamina = config.max_stamina
	events.append({"type": "roundStart", "tick": total_ticks, "round": round})


func _finish_by_decision() -> void:
	var p := Scoring.bout_score(player_stats, round, total_ticks, config.total_fight_ticks(), false, false)
	var o := Scoring.bout_score(opponent_stats, round, total_ticks, config.total_fight_ticks(), false, false)
	if p.points > o.points:
		_finish(HM.Outcome.PLAYER_WIN_BY_DECISION)
	elif o.points > p.points:
		_finish(HM.Outcome.PLAYER_LOSS_BY_DECISION)
	else:
		_finish(HM.Outcome.DRAW)


func _finish(result: int) -> void:
	outcome = result
	phase = HM.Phase.OVER
	events.append({"type": "boutEnd", "tick": total_ticks, "outcome": result})


func player_score() -> Dictionary:
	return Scoring.bout_score(player_stats, round, total_ticks, config.total_fight_ticks(),
		outcome >= 0 and HM.is_player_win(outcome), outcome == HM.Outcome.PLAYER_WIN_BY_KO)


## FightEngine.simulate — replays an input log and returns a BoutResult-like dictionary.
static func simulate(p_config: Config, p_seed: int, p_book: OpponentBook, inputs: Array) -> Dictionary:
	var engine := FightEngine.new(p_config, p_seed, p_book)
	var index := 0
	var cap := p_config.hard_tick_cap()
	while not engine.is_over() and engine.total_ticks < cap:
		engine.tick(inputs[index] if index < inputs.size() else HM.Cmd.NONE)
		index += 1
	return engine.result()


func result() -> Dictionary:
	return {
		"opponentID": book.id,
		"seed": seed,
		"outcome": outcome if outcome >= 0 else HM.Outcome.DRAW,
		"roundsCompleted": round,
		"ticksElapsed": total_ticks,
		"playerHP": player.hp,
		"opponentHP": opponent.hp,
		"playerKnockdowns": player.knockdown_count,
		"opponentKnockdowns": opponent.knockdown_count,
		"playerStats": player_stats.to_dict(),
		"opponentStats": opponent_stats.to_dict(),
		"score": player_score(),
	}
