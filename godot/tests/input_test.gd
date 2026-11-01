extends SceneTree
## Keyboard/gamepad regression: drives the main scene with synthetic input events only.
## Run: godot --headless --path godot --script res://tests/input_test.gd -- --isolated-store

var main
var fails := 0

func _initialize() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	_run.call_deferred()

func joy(button: JoyButton) -> void:
	for p in [true, false]:
		var e := InputEventJoypadButton.new()
		e.button_index = button
		e.pressed = p
		e.pressure = 1.0 if p else 0.0
		Input.parse_input_event(e)
		await process_frame

func key(code: Key) -> void:
	for p in [true, false]:
		var e := InputEventKey.new()
		e.physical_keycode = code
		e.keycode = code
		e.pressed = p
		Input.parse_input_event(e)
		await process_frame

func wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func focused() -> String:
	var f = root.gui_get_focus_owner()
	return "" if f == null or not ("text" in f) else f.text

func shows(text: String) -> bool:
	return main.ui.find_children("*", "Label", true, false).any(func(l): return l.is_visible_in_tree() and l.text.contains(text))

func _run() -> void:
	await wait(0.3)
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine == null, "first press only reveals focus")
	check(focused().contains("STEP INTO THE RING"), "home focuses the start button")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine != null and main.showing_versus, "A on start opens versus")
	check(focused().contains("RING THE BELL"), "versus focuses ring the bell")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine != null and not main.showing_versus, "A rings the bell")
	var t := 0.0
	while not (main._fighting() and main.countdown < 0.0) and t < 10.0:
		await wait(0.1)
		t += 0.1
	check(main._fighting(), "fighting after countdown")
	await joy(JOY_BUTTON_X)
	await wait(0.2)
	await key(KEY_UP)
	await wait(0.2)
	check(main.input_log.has(HM.Cmd.HOOK) and main.input_log.has(HM.Cmd.UPPERCUT), "gamepad X hooks, Up arrow uppercuts")
	check(focused() == "", "no focused button mid-bout")
	await joy(JOY_BUTTON_START)
	await wait(0.1)
	check(main.paused, "Start pauses")
	check(focused().contains("RESUME"), "pause focuses resume")
	await joy(JOY_BUTTON_DPAD_DOWN)
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.modal == "settings", "D-pad down + A opens settings")
	await joy(JOY_BUTTON_B)
	await wait(0.1)
	check(main.modal == "" and main.paused, "B closes settings")
	await key(KEY_ESCAPE)
	await wait(0.1)
	check(not main.paused, "Esc resumes")
	var game = root.get_node("Game")
	var defeated: OpponentBook = game.opponent
	game.bouts = [{"mode": "career", "result": {"opponentID": defeated.id, "outcome": HM.Outcome.PLAYER_WIN_BY_KO,
		"score": {"points": 2691}, "roundsCompleted": 1, "ticksElapsed": 500,
		"playerStats": {"landed": 9, "thrown": 9, "counters": 4}}}]
	game._ladder_start = 0
	game.saved = true
	game.progression.tokens = 1
	main.engine.phase = HM.Phase.OVER
	main.engine.outcome = HM.Outcome.PLAYER_WIN_BY_KO
	main.post_bout_elapsed = Arena.RESULTS_DELAY
	main.replay_matches = true
	await wait(0.1)
	check(focused().begins_with("NEXT FIGHT"), "win focuses Next fight instead of Rematch")
	check(shows("FIGHT PRIZE TOKENS  1") and shows("FIGHTER STATS"), "win screen shows prize tokens and fighter stats")
	check(not (main._refs.primary as Button).disabled, "unspent tokens never lock Next fight")
	var primary: Button = main._refs.primary
	check(primary.get_index() == 0 and primary.get_parent().get_child(1).text == "REMATCH",
		"Next fight appears before secondary Rematch")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.showing_versus and game.opponent.id != defeated.id, "A on Next fight opens the next introduction")
	check(focused().contains("RING THE BELL"), "next introduction focuses ring the bell")
	check(shows("CHALLENGER STATS"), "versus shows the challenger stats")
	check(game.prize_tokens() == 1, "tokens carry into the next fight unspent")
	check(main.title_music_player != null and main.title_music_player.stream != null,
		"title music player is initialized with stream")
	main.session_reset()
	check(main.title_music_player.playing, "title music plays on home screen")
	main.start_bout()
	check(not main.title_music_player.playing, "title music stops during bout")
	main.session_reset()
	check(main.title_music_player.playing, "title music resumes after returning home")
	game.music_enabled = false
	main._update_title_music()
	check(not main.title_music_player.playing, "disabling music setting stops player")
	game.music_enabled = true
	main._update_title_music()
	check(main.title_music_player.playing, "re-enabling music setting resumes player")
	print("%d input failures" % fails)
	quit(1 if fails > 0 else 0)
