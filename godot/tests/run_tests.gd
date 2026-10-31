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
	test_scoring()
	test_stamina()
	test_roster_playable()
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
	var authored := OpponentBook.authored_ladder()
	var ids := authored.map(func(b): return b.id)
	expect(ids == OpponentBook.career_roster().map(func(b): return b.id), "authored order")
	for book in OpponentBook.career_roster():
		expect(_pressure(book.scaled(0)) < _pressure(book.scaled(0.5)), "%s harder mid" % book.id)
		expect(_pressure(book.scaled(0.5)) < _pressure(book.scaled(1)), "%s harder end" % book.id)
		for d in [0.0, 0.5, 1.0]:
			var s: OpponentBook = book.scaled(d)
			for k in book.sequence.size():
				expect(s.sequence[k].tell >= mini(book.sequence[k].tell, OpponentBook.MIN_TELL), "readable tell")
				expect(s.sequence[k].damage > 0 or book.sequence[k].damage == 0, "damage kept")


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
	for book in OpponentBook.authored_ladder():
		var a := FightEngine.simulate(config, 42, book, inputs)
		expect(a == FightEngine.simulate(config, 42, book, inputs), "%s replay" % book.id)
	# Career config: a jab every 20 ticks should finish the bout within cap.
	var career := FightEngine.simulate(FightEngine.Config.career(), 0xCAFE2026, OpponentBook.goldie(), [])
	expect(career.ticksElapsed > 0, "career runs")
