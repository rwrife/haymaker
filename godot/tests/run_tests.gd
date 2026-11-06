extends SceneTree
## Headless engine test suite mirroring Packages/HaymakerKit/Tests.
## Run: godot --headless --path godot --script res://tests/run_tests.gd

var failures := 0
var checks := 0


func expect(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		printerr("FAIL: ", label)


func test_config() -> FightEngine.Config:
	return FightEngine.Config.make(3, 1200, 120)


func clock_config() -> FightEngine.Config:
	var c := FightEngine.Config.make(3, 400, 60)
	c.max_hp = 100000
	c.knockdown_threshold = 10000
	c.knockdown_ticks = 90
	return c


func idle_inputs(n: int) -> Array:
	var a := []
	a.resize(n)
	a.fill(HM.Cmd.NONE)
	return a


func _init() -> void:
	test_rng()
	test_damage_model()
	test_golden_fixtures()
	test_determinism()
	test_controls_and_countdown()
	test_ladder()
	test_secret_opponent()
	test_secret_career()
	test_scoring()
	test_stamina()
	test_roster_playable()
	test_progression()
	test_matchup()
	test_difficulty()
	test_combo_knockdowns()
	test_player_get_up()
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func test_rng() -> void:
	var r := SeededRNG.new(0)
	expect(r.state == SeededRNG.DEFAULT_SEED, "zero seed remap")
	expect(SeededRNG.lsr(-1, 60) == 15, "logical shift")
	expect(SeededRNG.umod(-1, 10) == 5, "unsigned mod of 2^64-1 % 10 == 5")
	var a := SeededRNG.new(7)
	var b := SeededRNG.new(7)
	for i in 100:
		expect(a.next() == b.next(), "rng deterministic")
	for i in 1000:
		var v := a.next_less_than(13)
		expect(v >= 0 and v < 13, "bounded")


func test_damage_model() -> void:
	expect(HM.blocked_damage(12, 8, false) == 4, "block 12")
	expect(HM.blocked_damage(6, 8, false) == 0, "block 6")
	expect(HM.blocked_damage(12, 8, true) == 8, "guard break")
	expect(HM.stamina_regen(HM.State.IDLE, 2) == 2, "regen idle")
	expect(HM.stamina_regen(HM.State.BLOCKING, 2) == 1, "regen block")
	expect(HM.stamina_regen(HM.State.RECOVERING, 2) == 1, "regen recover")
	expect(HM.stamina_regen(HM.State.ATTACKING, 2) == 0, "regen attack")


func test_golden_fixtures() -> void:
	var idle := idle_inputs(60000)
	var twitch := FightEngine.simulate(test_config(), 1, OpponentBook.twitch(), idle)
	expect(twitch.outcome == HM.Outcome.PLAYER_LOSS_BY_KO, "twitch KO")
	expect(twitch.ticksElapsed == 702, "twitch golden ticks 702 (got %d)" % twitch.ticksElapsed)
	expect(twitch.playerStats.landed == 0 and twitch.playerStats.thrown == 0, "passive player")
	expect(twitch.opponentStats.landed > 0, "twitch landed")
	expect(twitch.score.points == 50, "twitch points 50 (got %d)" % twitch.score.points)
	var spar := FightEngine.simulate(clock_config(), 1, OpponentBook.twitch(), idle)
	expect(spar.outcome == HM.Outcome.PLAYER_LOSS_BY_DECISION, "spar decision")
	expect(spar.ticksElapsed == clock_config().total_fight_ticks(), "spar ticks")
	expect(spar.score.points == 150, "spar points 150")
	var anvil := FightEngine.simulate(test_config(), 2, OpponentBook.anvil(), idle)
	expect(anvil.outcome == HM.Outcome.PLAYER_LOSS_BY_KO, "anvil KO")
	expect(anvil.ticksElapsed < twitch.ticksElapsed, "anvil faster")


func test_determinism() -> void:
	var inputs := []
	for i in 3000:
		inputs.append([HM.Cmd.JAB, HM.Cmd.NONE, HM.Cmd.BLOCK, HM.Cmd.HOOK, HM.Cmd.DODGE, HM.Cmd.UPPERCUT][(i * 7) % 6])
	var a := FightEngine.simulate(test_config(), 42, OpponentBook.anvil(), inputs)
	var b := FightEngine.simulate(test_config(), 42, OpponentBook.anvil(), inputs)
	expect(a == b, "same seed same result")
	var live := FightEngine.new(test_config(), 42, OpponentBook.anvil())
	var replay := FightEngine.new(test_config(), 42, OpponentBook.anvil())
	for i in 3000:
		live.tick(inputs[i])
		replay.tick(inputs[i])
	expect(live.events.size() > 0 and live.events == replay.events, "replayed event logs match")


func test_controls_and_countdown() -> void:
	expect(HM.resolve_swipe(0, -80) == HM.Cmd.UPPERCUT, "swipe up")
	expect(HM.resolve_swipe(-80, 0) == HM.Cmd.HOOK, "swipe left")
	expect(HM.resolve_swipe(80, 0) == HM.Cmd.DODGE, "swipe right")
	expect(HM.resolve_swipe(0, 80) == HM.Cmd.BLOCK, "swipe down")
	expect(HM.resolve_swipe(4, 4) == HM.Cmd.JAB, "tap")
	expect(HM.knockdown_value(0, 90) == 3 and HM.knockdown_value(29, 90) == 3, "kd 3")
	expect(HM.knockdown_value(30, 90) == 2 and HM.knockdown_value(59, 90) == 2, "kd 2")
	expect(HM.knockdown_value(60, 90) == 1 and HM.knockdown_value(89, 90) == 1, "kd 1")
	expect(HM.knockdown_value(90, 90) == 0, "kd done")
	expect(HM.knockdown_value(0, 360, 6) == 6 and HM.knockdown_value(359, 360, 6) == 1, "six-second recovery countdown")


func combo_engine() -> FightEngine:
	var book := OpponentBook.new("combo", "Combo", [OpponentBook.entry(HM.Move.FEINT, 10000, 1, 1, 0, 0)],
		10000, 0, 1000)
	return FightEngine.new(test_config(), 42, book)


func combo_hit(e: FightEngine, at_tick: int, damage: int = 8) -> void:
	e.total_ticks = at_tick
	e.player.current_move = HM.Move.JAB
	e.player.current_damage = damage
	e._resolve_player_impact()


func test_combo_knockdowns() -> void:
	var e := combo_engine()
	e.opponent.state = HM.State.TELLING
	e.opponent.current_move = HM.Move.JAB
	combo_hit(e, 0, 33)
	expect(e.opponent.hp == 934 and e.opponent.knockdown_count == 0, "even a boosted heavy counter cannot knock down alone")
	e = combo_engine()
	for t in [0, 60, 120]:
		combo_hit(e, t)
	expect(e.opponent.knockdown_count == 0, "three hits are not a knockdown")
	combo_hit(e, 180)
	expect(e.opponent.state == HM.State.KNOCKED_DOWN and e.opponent.knockdown_count == 1, "four hits in exactly three seconds knock down")
	expect(e.player_stats.knockdowns_scored == 1 and e._combo_hit_ticks.is_empty(), "knockdown scores once and clears combo")
	for i in e.config.knockdown_ticks:
		e.tick(HM.Cmd.NONE)
	expect(e.opponent.state == HM.State.IDLE, "opponent still rises automatically after three seconds")
	combo_hit(e, e.total_ticks)
	expect(e.opponent.knockdown_count == 1, "revival needs a fresh combo")

	e = combo_engine()
	for t in [0, 60, 120, 181]:
		combo_hit(e, t)
	expect(e.opponent.knockdown_count == 0, "four hits taking one tick too long do not knock down")
	e = combo_engine()
	for t in [0, 100, 150, 181, 200]:
		combo_hit(e, t)
	expect(e.opponent.knockdown_count == 1, "rolling window retains the latest four consecutive hits")
	e = combo_engine()
	combo_hit(e, 0)
	for i in 181:
		e.tick(HM.Cmd.NONE)
	expect(e._combo_hit_ticks.is_empty(), "combo expires without another attack")

	for interruption in ["block", "idle guard", "dodge", "exhaustion", "hit", "round"]:
		e = combo_engine()
		for t in [0, 20, 40]:
			combo_hit(e, t)
		match interruption:
			"block":
				e.opponent.state = HM.State.BLOCKING
				combo_hit(e, 50)
			"idle guard":
				e.book.guard = 4
				combo_hit(e, 50)
				e.book.guard = 0
			"dodge":
				e.opponent.state = HM.State.DODGING
				combo_hit(e, 50)
			"exhaustion":
				e.player.stamina = 0
				e.tick(HM.Cmd.UPPERCUT)
			"hit":
				e.opponent.current_move = HM.Move.JAB
				e.opponent.current_damage = 8
				e._resolve_opponent_impact()
			"round":
				e._end_round()
		e.opponent.state = HM.State.IDLE
		combo_hit(e, 60)
		expect(e.opponent.knockdown_count == 0 and e._combo_hit_ticks.size() == 1, interruption + " breaks the combo")
	for defense in [HM.State.BLOCKING, HM.State.DODGING, HM.State.PARRYING]:
		e = combo_engine()
		for t in [0, 20, 40]:
			combo_hit(e, t)
		e.player.state = defense
		e.opponent.current_move = HM.Move.JAB
		e.opponent.current_damage = 10
		e._resolve_opponent_impact()
		combo_hit(e, 60)
		expect(e.opponent.knockdown_count == 1, "successful defense preserves the combo")
	for blocking in [false, true]:
		e = combo_engine()
		e.opponent.hp = 1
		e.opponent.state = HM.State.BLOCKING if blocking else HM.State.IDLE
		combo_hit(e, 1, 22)
		expect(e.outcome == HM.Outcome.PLAYER_WIN_BY_KO, "zero-health knockout does not require a combo")
	e = combo_engine()
	for down in 3:
		for hit in 4:
			combo_hit(e, e.total_ticks + 15)
		if down < 2:
			for i in e.config.knockdown_ticks:
				e.tick(HM.Cmd.NONE)
	expect(e.outcome == HM.Outcome.PLAYER_WIN_BY_KO and e.opponent.knockdown_count == 3, "third combo knockdown is a TKO")

	# Exercise real windups/recoveries, not just the impact helper.
	e = combo_engine()
	for i in 100:
		e.tick(HM.Cmd.HOOK if e.player.state == HM.State.IDLE else HM.Cmd.NONE)
		if e.opponent.state == HM.State.KNOCKED_DOWN:
			break
	expect(e.player_stats.landed == 4 and e.opponent.knockdown_count == 1, "four normally scheduled hooks knock down")


func test_player_get_up() -> void:
	var e := combo_engine()
	e.force_player_knockdown()
	expect(e.player.get_up_required == 15 and e.player.state_duration == 360, "first recovery requires 15 presses in six seconds")
	var waiting := e._opp_waiting
	for i in 359:
		e.tick(HM.Cmd.NONE)
	expect(not e.is_over() and e.player.state == HM.State.KNOCKED_DOWN, "Mack never rises without presses")
	expect(e.tick_in_round == 0 and e._opp_waiting == waiting, "recovery freezes bout clock and opponent scheduler")
	e.tick(HM.Cmd.NONE)
	expect(e.outcome == HM.Outcome.PLAYER_LOSS_BY_KO and e.total_ticks == 360, "missed recovery loses at exactly six seconds")
	expect(e.player.knockdown_count == 1 and e.opponent_stats.knockdowns_scored == 1, "failed count does not score a second knockdown")
	expect(not e.events.any(func(v): return v.type == "rise"), "failed recovery emits no rise")
	var event_count := e.events.size()
	e.tick(HM.Cmd.JAB)
	expect(e.events.size() == event_count and e.player.state == HM.State.KO, "late presses cannot revive a KO")

	e = combo_engine()
	e.force_player_knockdown()
	for command in [HM.Cmd.HOOK, HM.Cmd.UPPERCUT, HM.Cmd.BLOCK, HM.Cmd.DODGE, HM.Cmd.PARRY]:
		e.tick(command)
	expect(e.player.get_up_presses == 0, "only the primary punch counts for recovery")
	for i in 14:
		e.tick(HM.Cmd.JAB)
	expect(e.player.state == HM.State.KNOCKED_DOWN and e.player.get_up_presses == 14, "fourteen presses cannot recover")
	e.tick(HM.Cmd.JAB)
	expect(e.player.state == HM.State.IDLE and e.events[-1].type == "rise", "fifteenth press recovers")
	expect(e.player_stats.thrown == 0 and e.player_stats.landed == 0 and e.player.stamina == 50, "recovery presses are not punches")
	e.force_player_knockdown()
	expect(e.player.get_up_required == 20 and e.player.get_up_presses == 0, "second recovery increases to 20 with progress reset")
	for i in 19:
		e.tick(HM.Cmd.JAB)
	expect(e.player.state == HM.State.KNOCKED_DOWN, "nineteen presses cannot recover on second down")
	e.tick(HM.Cmd.JAB)
	expect(e.player.state == HM.State.IDLE, "twentieth press recovers on second down")
	e.force_player_knockdown()
	expect(e.outcome == HM.Outcome.PLAYER_LOSS_BY_KO and e.player.get_up_required == 0, "third knockdown remains a TKO")

	e = combo_engine()
	e.force_player_knockdown()
	for i in 359:
		e.tick(HM.Cmd.JAB if i < 14 else HM.Cmd.NONE)
	e.tick(HM.Cmd.JAB)
	expect(e.player.state == HM.State.IDLE and not e.is_over(), "final required press on the last tick succeeds")
	e = combo_engine()
	e.config.rounds = 1
	e.tick_in_round = e.config.round_ticks - 1
	e.force_player_knockdown()
	e._end_round()
	expect(e.player.state == HM.State.KNOCKED_DOWN and not e.is_over(), "round bell cannot grant a free recovery")
	for i in 360:
		e.tick(HM.Cmd.NONE)
	expect(e.outcome == HM.Outcome.PLAYER_LOSS_BY_KO, "final-round recovery timeout is a KO, not a decision")
	e = combo_engine()
	e.tick_in_round = e.config.round_ticks - 1
	e.force_player_knockdown()
	for i in 15:
		e.tick(HM.Cmd.JAB)
	e.tick(HM.Cmd.NONE)
	expect(e.phase == HM.Phase.RESTING and e.round == 1, "round ends normally after an earned recovery")

	e = combo_engine()
	e.opponent.state = HM.State.ATTACKING
	e.opponent.state_duration = 1
	e.opponent.current_move = HM.Move.HOOK
	e.opponent.current_damage = 30
	e.tick(HM.Cmd.NONE)
	for i in 30:
		e.tick(HM.Cmd.NONE)
	expect(e.player.state == HM.State.KNOCKED_DOWN and e.opponent.state == HM.State.IDLE,
		"opponent finishes retracting the knockdown punch and waits")
	expect(e.player_stats.damage_taken == 30 and e.opponent_stats.whiffed == 0,
		"opponent never attacks a downed Mack")

	var config := test_config()
	config.max_hp = 1000
	var book := OpponentBook.new("recovery", "Recovery", [OpponentBook.entry(HM.Move.HOOK, 1, 1, 10, 0, 30)], 1, 0, 1000)
	var live := FightEngine.new(config, 21, book)
	var replay := FightEngine.new(config.copy(), 21, book)
	var inputs := []
	while not live.is_over() and live.total_ticks < config.hard_tick_cap():
		var command := HM.Cmd.JAB if live.player.state == HM.State.KNOCKED_DOWN and live.total_ticks % 12 == 0 else HM.Cmd.NONE
		inputs.append(command)
		live.tick(command)
		replay.tick(command)
	expect(live.events == replay.events and live.result() == replay.result(), "combo and recovery state replay deterministically")
	expect(live.events.filter(func(v): return v.type == "rise").size() == 2, "recorded input earns both recoveries before TKO")
	expect(FightEngine.simulate(config, 21, book, inputs) == live.result(), "simulate replays recovery presses through completion")


func _pressure(book: OpponentBook) -> float:
	var dmg := 0
	var ticks := 0
	for e in book.sequence:
		dmg += e.damage
		ticks += e.tell + e.impact + e.recover + book.min_gap
	return float(dmg) / float(ticks)


func test_ladder() -> void:
	for i in 20:
		var ladder := OpponentBook.random_ladder()
		expect(ladder.size() == 10, "ladder size")
		expect(ladder[-1].id == "baxter", "boss last")
		expect(not ladder.any(func(b): return b.id == "tycoon"), "tycoon hidden from the normal ladder")
	var authored := OpponentBook.authored_ladder()
	var ids := authored.map(func(b): return b.id)
	expect(ids == OpponentBook.career_roster().map(func(b): return b.id), "authored order")
	for book in OpponentBook.all_roster():
		expect(book.bio() != "" and book.style() != "" and book.taunt() != "", "%s has a profile" % book.id)
		expect(_pressure(book.scaled(0)) < _pressure(book.scaled(0.5)), "%s harder mid" % book.id)
		expect(_pressure(book.scaled(0.5)) < _pressure(book.scaled(1)), "%s harder end" % book.id)
		for d in [0.0, 0.5, 1.0]:
			var s: OpponentBook = book.scaled(d)
			for k in book.sequence.size():
				expect(s.sequence[k].tell >= mini(book.sequence[k].tell, OpponentBook.MIN_TELL), "readable tell")
				expect(s.sequence[k].damage > 0 or book.sequence[k].damage == 0, "damage kept")


func test_secret_opponent() -> void:
	var result := {"opponentID": "goldie", "outcome": HM.Outcome.PLAYER_WIN_BY_KO,
		"playerStats": {"knockdownsScored": 2, "damageTaken": 0}}
	expect(OpponentBook.reveals_tycoon(result), "two knockdowns and no damage reveal tycoon")
	result.playerStats.knockdownsScored = 3
	expect(OpponentBook.reveals_tycoon(result), "three knockdowns also qualify")
	result.playerStats.knockdownsScored = 1
	expect(not OpponentBook.reveals_tycoon(result), "one knockdown does not qualify")
	result.playerStats.knockdownsScored = 0
	expect(not OpponentBook.reveals_tycoon(result), "no knockdowns do not qualify")
	result.playerStats.knockdownsScored = 2
	result.playerStats.damageTaken = 1
	expect(not OpponentBook.reveals_tycoon(result), "even one point of chip damage disqualifies")
	result.playerStats.damageTaken = 0
	for outcome in [HM.Outcome.DRAW, HM.Outcome.PLAYER_LOSS_BY_KO, HM.Outcome.PLAYER_LOSS_BY_DECISION]:
		result.outcome = outcome
		expect(not OpponentBook.reveals_tycoon(result), "only a win qualifies")
	result.outcome = HM.Outcome.PLAYER_WIN_BY_DECISION
	expect(OpponentBook.reveals_tycoon(result), "clean decision win can qualify")
	result.opponentID = "tycoon"
	expect(not OpponentBook.reveals_tycoon(result), "tycoon cannot reveal himself")
	expect(OpponentBook.by_id("tycoon").id == "tycoon", "secret book remains addressable")
	expect(not OpponentBook.career_roster().any(func(b): return b.id == "tycoon"), "sparring roster hides tycoon")


func secret_session() -> Node:
	var game := preload("res://scripts/game/game.gd").new()
	game._records_path = ""
	game.history_loaded = true
	game.ladder = OpponentBook.authored_ladder()
	game.opponent = game.ladder[0]
	return game


func save_clean_win(game: Node, book: OpponentBook) -> void:
	var config := FightEngine.Config.make(1, 2000, 0)
	config.max_knockdowns = 2
	config.knockdown_threshold = 8
	config.knockdown_ticks = 1
	var harmless := OpponentBook.new(book.id, book.name,
		[OpponentBook.entry(HM.Move.FEINT, 100, 0, 100, 0, 0)])
	var engine := FightEngine.new(config, 42, harmless)
	var inputs := []
	while not engine.is_over() and inputs.size() < config.hard_tick_cap():
		inputs.append(HM.Cmd.JAB)
		engine.tick(HM.Cmd.JAB)
	expect(engine.player_stats.knockdowns_scored == 2 and engine.player_stats.damage_taken == 0,
		"secret fixture produces exactly two clean knockdowns")
	game.save(engine, inputs)


func test_secret_career() -> void:
	var game := secret_session()
	expect(not game.tycoon_revealed() and not game.is_unlocked("tycoon"), "secret starts locked")
	expect(not game.record_roster().any(func(b): return b.id == "tycoon"), "fresh records hide secret")
	expect(not game.begin(OpponentBook.tycoon(), "career"), "cannot begin unrevealed bonus")
	expect(not game.begin(OpponentBook.tycoon(), "sparring"), "cannot spar with secret")
	var opener: OpponentBook = game.ladder[0]
	var next: OpponentBook = game.ladder[1]
	expect(game.begin(opener, "career"), "begin qualifying career bout")
	game._records_path = "user://missing-secret-test-directory/bouts.jsonl"
	save_clean_win(game, opener)
	expect(not game.saved and game.has_unsaved_result and not game.tycoon_revealed(),
		"failed save cannot reveal bonus")
	expect(not game.new_ladder(), "unsaved result cannot be discarded by new ladder")
	game._records_path = ""
	save_clean_win(game, opener)
	expect(game.saved and game.tycoon_revealed() and game.ladder.size() == 11, "retry save reveals once")
	expect(game.next_ladder_book().id == "tycoon" and game.ladder[2] == next, "bonus is next without rescaling others")
	expect(not game.is_unlocked(next.id), "bonus gates remaining career")
	expect(game.prize_tokens() == 1 and Attributes.total(game.progression.attributes_for("tycoon")) == 1,
		"qualifying win rewards player and trains bonus")
	expect(game.record_roster().any(func(b): return b.id == "tycoon"), "revealed bonus appears in records")
	save_clean_win(game, opener)
	expect(game.bouts.size() == 1 and game.ladder.size() == 11, "repeated save is idempotent")
	expect(game.begin(opener, "career"), "qualifying rematch allowed")
	save_clean_win(game, opener)
	expect(game.ladder.size() == 11 and game.prize_tokens() == 1, "rematch cannot repeat reveal or prize")
	expect(game.begin(game.next_ladder_book(), "career"), "revealed bonus can begin")
	var loss := FightEngine.new(FightEngine.Config.make(1, 600, 0), 42, OpponentBook.tycoon())
	while not loss.is_over():
		loss.tick(HM.Cmd.NONE)
	game.save(loss, [])
	expect(not HM.is_player_win(loss.outcome) and game.next_ladder_book().id == "tycoon"
		and not game.ladder_complete(), "lost bonus stays available")
	expect(game.begin(game.next_ladder_book(), "career"), "bonus can be retried after loss")
	save_clean_win(game, OpponentBook.tycoon())
	expect(game.next_ladder_book().id == next.id and game.ladder.size() == 11, "bonus win resumes normal ladder")
	expect(game.prize_tokens() == 2, "first bonus win earns normal nonfinal prize")
	expect(game.new_ladder() and not game.tycoon_revealed() and game.ladder.size() == 10, "new ladder hides bonus again")
	expect(not game.is_unlocked("tycoon") and game.record_roster().any(func(b): return b.id == "tycoon"),
		"new ladder keeps historical records, not access")
	game.free()

	game = secret_session()
	game.ladder = [OpponentBook.baxter().scaled(1.0)]
	expect(game.begin(game.ladder[0], "career"), "begin final regular bout")
	save_clean_win(game, game.opponent)
	expect(not game.can_celebrate_victory() and game.next_ladder_book().id == "tycoon",
		"qualifying final boss win delays finale")
	expect(game.begin(game.next_ladder_book(), "career"), "begin final bonus")
	save_clean_win(game, game.opponent)
	expect(game.can_celebrate_victory() and game.next_ladder_book() == null, "bonus win completes career")
	expect(game.ladder_summary().wins == 2, "finale includes bonus win")
	game.free()

	game = secret_session()
	expect(game.begin(game.opponent, "sparring"), "begin sparring fixture")
	save_clean_win(game, game.opponent)
	expect(not game.tycoon_revealed() and game.prize_tokens() == 0, "clean sparring cannot reveal bonus")
	game.free()


func test_scoring() -> void:
	var stats := FightEngine.Stats.new()
	var s := Scoring.bout_score(stats, 1, 0, 1000, false, false)
	expect(s.points == 50, "empty score")
	stats.landed = 5
	stats.thrown = 10
	stats.dodges_made = 2
	stats.blocks_made = 1
	stats.counters = 1
	stats.damage_dealt = 60
	stats.damage_taken = 20
	s = Scoring.bout_score(stats, 2, 400, 1000, true, true)
	expect(s.landedPoints == 100, "landed pts")
	expect(s.defensePoints == 47, "defense pts")
	expect(s.damagePoints == 50, "damage pts")
	expect(s.timePoints == 30, "time pts")
	expect(s.points == 100 + 47 + 50 + 100 + 30 + 500 + 200, "total")
	var best := {"score": 100, "outcome": HM.Outcome.PLAYER_WIN_BY_DECISION, "roundsCompleted": 3, "ticksElapsed": 900}
	expect(Scoring.compare(50, HM.Outcome.DRAW, 3, 900, null) == "firstBout", "first")
	expect(Scoring.compare(101, HM.Outcome.DRAW, 3, 900, best) == "newPersonalBest", "pb")
	expect(Scoring.compare(100, HM.Outcome.PLAYER_WIN_BY_KO, 3, 900, best) == "matchedBetterFinish", "better finish")
	expect(Scoring.compare(100, HM.Outcome.PLAYER_WIN_BY_DECISION, 3, 900, best) == "noImprovement", "no improvement")


func test_stamina() -> void:
	var e := FightEngine.new(test_config(), 1, OpponentBook.twitch())
	e.player.stamina = 50
	e.tick(HM.Cmd.NONE)
	expect(e.player.stamina == 52, "idle regen")
	e.player.stamina = 50
	e.tick(HM.Cmd.BLOCK)
	expect(e.player.stamina == 51, "block half regen")
	e = FightEngine.new(test_config(), 1, OpponentBook.twitch())
	e.player.stamina = 50
	e.tick(HM.Cmd.JAB)
	expect(e.player.stamina == 45, "jab cost")
	e = FightEngine.new(test_config(), 1, OpponentBook.twitch())
	e.player.stamina = 2
	e.tick(HM.Cmd.UPPERCUT)
	expect(e.player_stats.whiffed == 1 and e.player_stats.thrown == 1, "exhausted whiff")


func test_roster_playable() -> void:
	var config := FightEngine.Config.make(1, 600, 0)
	var inputs := []
	for i in 600:
		inputs.append(HM.Cmd.JAB if i % 30 == 0 else HM.Cmd.NONE)
	for book in OpponentBook.authored_ladder() + [OpponentBook.tycoon().scaled(1.0)]:
		var a := FightEngine.simulate(config, 42, book, inputs)
		expect(a == FightEngine.simulate(config, 42, book, inputs), "%s replay" % book.id)
	# Career config: a jab every 20 ticks should finish the bout within cap.
	var career := FightEngine.simulate(FightEngine.Config.career(), 0xCAFE2026, OpponentBook.goldie(), [])
	expect(career.ticksElapsed > 0, "career runs")

func test_progression() -> void:
	var base := FightEngine.Config.make()
	var same := base.boosted(Attributes.zero())
	expect(same.dodge_ticks == base.dodge_ticks and same.parry_window == base.parry_window
		and same.player_table == base.player_table, "zero attributes keep config")
	for book in OpponentBook.authored_ladder():
		expect(book.boosted(Attributes.zero()) == book, "zero attributes keep %s" % book.id)
	var a := Attributes.make(9, -2, 3)
	expect(a == {"power": 5, "dexterity": 0, "speed": 3}, "attributes clamp")
	var power: Dictionary = base.boosted(Attributes.make(5)).player_table
	expect(power[HM.Move.JAB].damage == 12 and power[HM.Move.HOOK].damage == 21 and power[HM.Move.UPPERCUT].damage == 33, "power damage")
	var speed: Dictionary = base.boosted(Attributes.make(0, 0, 5)).player_table
	expect(speed[HM.Move.JAB].windup == 3 and speed[HM.Move.JAB].recover == 5, "speed jab")
	expect(speed[HM.Move.UPPERCUT].windup == 7 and speed[HM.Move.UPPERCUT].recover == 12, "speed uppercut")
	var dex := base.boosted(Attributes.make(0, 5))
	expect(dex.dodge_ticks == 12 and dex.block_hold_ticks == 36 and dex.parry_window == 9, "dex windows")
	expect(dex.player_table[HM.Move.JAB].stamina == 3 and dex.player_table[HM.Move.UPPERCUT].stamina == 8, "dex stamina")
	expect(base.player_table[HM.Move.JAB].damage == 8, "boost leaves source config alone")
	var book: OpponentBook = OpponentBook.authored_ladder()[5]
	var strong := book.boosted(Attributes.make(5, 5, 5))
	for i in book.sequence.size():
		var o: Dictionary = book.sequence[i]
		var n: Dictionary = strong.sequence[i]
		expect(n.damage >= o.damage and (o.damage == 0 or n.damage > o.damage), "opponent power")
		expect(n.tell <= o.tell and n.tell >= mini(o.tell, OpponentBook.MIN_TELL), "opponent tell floor")
		expect(n.recover <= o.recover and n.recover >= mini(o.recover, OpponentBook.MIN_RECOVER), "opponent recover floor")
		var defensive: bool = o.move == HM.Move.BLOCK or o.move == HM.Move.DODGE
		expect(n.impact > o.impact if defensive else n.impact == o.impact, "opponent guard hold")
	expect(strong.min_gap <= book.min_gap and strong.gap_spread <= book.gap_spread, "opponent gaps")

	var p := Attributes.Progression.new()
	var ids := OpponentBook.authored_ladder().map(func(b): return b.id)
	p.record_win(ids.slice(1), 42)
	expect(p.tokens == 1 and Attributes.is_zero(p.attributes_for(ids[0])), "win awards one token")
	for id in ids.slice(1):
		expect(Attributes.total(p.attributes_for(id)) == 1, "remaining %s trained" % id)
	expect(p.spend("speed") and not p.spend("power"), "spend once")
	p.record_win([], 43)
	expect(p.tokens == 0, "final win awards nothing")
	var x := Attributes.Progression.new()
	var y := Attributes.Progression.new()
	for r in 20:
		expect(x.record_win(["x", "y"], r) == y.record_win(["x", "y"], r), "seeded training")
	expect(x.attributes_for("x") == Attributes.make(5, 5, 5) and x.record_win(["x"], 99).is_empty(), "training caps")
	var capped := Attributes.Progression.new()
	capped.player = Attributes.make(5, 5, 4)
	capped.record_win(["x"], 1)
	expect(capped.tokens == 1 and not capped.spend("power") and capped.spend("speed"), "spend skips maxed")
	capped.record_win(["x"], 2)
	expect(capped.tokens == 0, "maxed fighter forfeits")

	# Career journey, spending power, dexterity, speed in turn: a jab masher can
	# take the opener but the matched, trained finale punishes mashing.
	var ladder := OpponentBook.authored_ladder()
	var run := Attributes.Progression.new()
	var jabs := []
	jabs.resize(FightEngine.Config.career().hard_tick_cap())
	jabs.fill(HM.Cmd.JAB)
	for i in ladder.size():
		if i > 0:
			expect(run.spend(Attributes.ALL[(i - 1) % 3]), "spend before bout %d" % i)
		if i == 0 or i == ladder.size() - 1:
			var m := Attributes.matchup(run.player, run.attributes_for(ladder[i].id))
			var fought: OpponentBook = ladder[i].boosted(m.opponent)
			var config := FightEngine.Config.career().boosted(m.player)
			var result := FightEngine.simulate(config, 0xCAFE2026, fought, jabs)
			if i == 0:
				expect(HM.is_player_win(int(result.outcome)), "jab masher beats the opener")
			else:
				expect(not HM.is_player_win(int(result.outcome)), "jab masher loses to trained %s" % ladder[i].id)
		var remaining := ids.slice(i + 1)
		run.record_win(remaining, 0x7EA12026 + ladder.size() - remaining.size())
	expect(run.tokens == 0 and Attributes.total(run.player) == ladder.size() - 1, "player trained every bout")
	expect(Attributes.total(run.attributes_for("baxter")) == ladder.size() - 1, "final boss trained after every win")


func test_matchup() -> void:
	var z := Attributes.zero()
	var m := Attributes.matchup(z, z)
	expect(m.player == z and m.opponent == z, "zero matchup identity")
	var mirror := Attributes.make(2, 3, 1)
	m = Attributes.matchup(mirror, mirror)
	expect(m.player == m.opponent, "mirrored matchup is even")
	var single := Attributes.make(0, 4)
	m = Attributes.matchup(single, single)
	expect(m.player == single and m.opponent == single, "single-attribute mirror unchanged")
	m = Attributes.matchup(Attributes.make(0, 0, 5), Attributes.make(0, 5, 0))
	expect(m.player == Attributes.make(0, 0, 2) and m.opponent.dexterity == 7, "dexterity outlasts speed")
	m = Attributes.matchup(Attributes.make(5), Attributes.make(0, 5))
	expect(m.player.power == 7 and m.opponent.dexterity == 2, "power breaks dexterity")
	m = Attributes.matchup(Attributes.make(0, 0, 5), Attributes.make(5))
	expect(m.player.speed == 7 and m.opponent.power == 2, "speed out-tempos power")
	expect(Attributes.edge(Attributes.make(5), Attributes.make(0, 5)) > 0, "favorable edge")
	expect(Attributes.edge(Attributes.make(0, 0, 5), Attributes.make(0, 5)) < 0, "tough edge")
	expect(Attributes.edge(mirror, mirror) == 0 and Attributes.edge(Attributes.make(5), z) == 0, "even edge")
	expect(Attributes.clashes(Attributes.make(0, 0, 3), Attributes.make(1, 2)) ==
		["Your Speed beats their Power", "Their Dexterity beats your Speed"], "clash notes")
	for a in Attributes.ALL:
		expect(Attributes.BEATS[Attributes.countered_by(a)] == a, "%s has a counter" % a)

	var dex := FightEngine.Config.make().boosted(Attributes.make(0, 5))
	expect(dex.armor == 2, "dex armor")
	var goldie := OpponentBook.goldie()
	var trained := goldie.boosted(Attributes.make(0, 4))
	expect(trained.armor == 2 and trained.punish == 40 and trained.max_hp == goldie.max_hp, "opponent dex armor and punish")


func test_difficulty() -> void:
	for book in OpponentBook.career_roster():
		expect(book.max_hp == 100 and book.guard == 0 and book.punish == 0 and book.armor == 0, "%s raw book is neutral" % book.id)
		var prev: OpponentBook = book.scaled(0)
		expect(prev.max_hp > 100 and prev.punish > 0, "%s opener tougher than raw" % book.id)
		for step in range(1, 10):
			var s: OpponentBook = book.scaled(step / 9.0)
			expect(s.max_hp > prev.max_hp and s.guard >= prev.guard and s.punish > prev.punish, "%s ramps at %d" % [book.id, step])
			prev = s
		expect(prev.guard > book.scaled(0).guard, "%s guard ramps" % book.id)
	var authored := OpponentBook.authored_ladder()
	var hp_steps := []
	for i in range(1, authored.size()):
		hp_steps.append(authored[i].max_hp - authored[i - 1].max_hp)
	expect(hp_steps[-1] > hp_steps[0], "ladder ramp accelerates")

	var src := OpponentBook.goldie()
	var tough := OpponentBook.new(src.id, src.name, src.sequence, src.min_gap, src.gap_spread, 200, 4, 50, 0)
	var e := FightEngine.new(test_config(), 1, tough)
	expect(e.opponent.hp == 200, "opponent hp from book")
	expect(e._revival_hp(HM.Who.OPPONENT) == 60 and e._revival_hp(HM.Who.PLAYER) == 30, "revival scales with max hp")
	# Idle guard soaks part of a punch and provokes the next attack.
	e.opponent.state = HM.State.IDLE
	e._opp_waiting = 50
	e.player.current_move = HM.Move.JAB
	e.player.current_damage = 8
	e._resolve_player_impact()
	expect(e.opponent.hp == 196 and e.events[-1].type == "blocked", "idle guard")
	expect(e._opp_waiting <= 1, "guard invites attack")
	# Only the first punch into a tell is a counter.
	e.opponent.state = HM.State.TELLING
	e.opponent.current_move = HM.Move.JAB
	e._tell_countered = false
	e._resolve_player_impact()
	expect(e.opponent.hp == 180 and e.events[-1].counter, "first counter doubles")
	e._resolve_player_impact()
	expect(e.opponent.hp == 172 and not e.events[-1].counter, "second hit is not a counter")
	# Getting caught mid-punch is punished; armor soaks the rest.
	e.player.state = HM.State.RECOVERING
	e.player.hp = 100
	e.opponent.state = HM.State.ATTACKING
	e.opponent.current_move = HM.Move.JAB
	e.opponent.current_damage = 10
	e._resolve_opponent_impact()
	expect(e.player.hp == 85 and e.events[-1].counter and e.opponent_stats.counters == 1, "punished mid-punch")
	e.player.state = HM.State.IDLE
	e.player.hp = 100
	e.config.armor = 3
	e._resolve_opponent_impact()
	expect(e.player.hp == 93 and not e.events[-1].counter, "armor soaks clean hits")
	e.config.armor = 50
	e.player.hp = 100
	e._resolve_opponent_impact()
	expect(e.player.hp == 99, "armor leaves at least 1")
	var finisher := FightEngine.new(test_config(), 1, tough)
	finisher.opponent.state = HM.State.IDLE
	finisher.opponent.hp = 5
	finisher.player.current_move = HM.Move.JAB
	finisher.player.current_damage = 8
	finisher._resolve_player_impact()
	expect(finisher.opponent.hp == 0 and finisher.events.any(func(v): return v.type == "landed"), "finishing blow breaks the guard")
