extends SceneTree
## Keyboard/gamepad regression: drives the main scene with synthetic input events only.
## Run: godot --headless --path godot --script res://tests/input_test.gd -- --isolated-store

var main
var fails := 0
var crowd_player: AudioStreamPlayer

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

func motion(axis: JoyAxis, values: Array) -> void:
	for value in values:
		var e := InputEventJoypadMotion.new()
		e.axis = axis
		e.axis_value = value
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

func test_fight_bindings() -> void:
	main.set_process(false)
	for binding in [
		[[KEY_SPACE, KEY_J], HM.Cmd.JAB],
		[[KEY_LEFT, KEY_A, KEY_K], HM.Cmd.HOOK],
		[[KEY_UP, KEY_W, KEY_I], HM.Cmd.UPPERCUT],
		[[KEY_RIGHT, KEY_D, KEY_L], HM.Cmd.DODGE],
		[[KEY_DOWN, KEY_S], HM.Cmd.BLOCK],
		[[KEY_SHIFT, KEY_P], HM.Cmd.PARRY],
	]:
		for code in binding[0]:
			main.pending.clear()
			await key(code)
			check(main.pending == [binding[1]], "keyboard binding queues exactly one move: " + OS.get_keycode_string(code))
	for binding in [
		[JOY_BUTTON_A, HM.Cmd.JAB], [JOY_BUTTON_X, HM.Cmd.HOOK],
		[JOY_BUTTON_Y, HM.Cmd.UPPERCUT], [JOY_BUTTON_B, HM.Cmd.DODGE],
		[JOY_BUTTON_LEFT_SHOULDER, HM.Cmd.BLOCK], [JOY_BUTTON_RIGHT_SHOULDER, HM.Cmd.PARRY],
		[JOY_BUTTON_DPAD_LEFT, HM.Cmd.HOOK], [JOY_BUTTON_DPAD_UP, HM.Cmd.UPPERCUT],
		[JOY_BUTTON_DPAD_RIGHT, HM.Cmd.DODGE], [JOY_BUTTON_DPAD_DOWN, HM.Cmd.BLOCK],
	]:
		main.pending.clear()
		await joy(binding[0])
		check(main.pending == [binding[1]], "Xbox button queues exactly one move: " + str(binding[0]))
	for binding in [[JOY_AXIS_TRIGGER_LEFT, HM.Cmd.BLOCK], [JOY_AXIS_TRIGGER_RIGHT, HM.Cmd.PARRY]]:
		main.pending.clear()
		await motion(binding[0], [0.0, 0.49])
		check(main.pending.is_empty(), "trigger ignores motion below deadzone")
		await motion(binding[0], [0.5, 0.8, 1.0])
		check(main.pending == [binding[1]], "held trigger queues once, not on every motion event")
		await motion(binding[0], [0.0, 0.7, 0.0])
		check(main.pending == [binding[1], binding[1]], "releasing trigger permits another move")
	main.pending.clear()
	var echo := InputEventKey.new()
	echo.physical_keycode = KEY_J
	echo.pressed = true
	echo.echo = true
	Input.parse_input_event(echo)
	await process_frame
	check(main.pending.is_empty(), "keyboard repeat does not queue another jab")
	main.set_process(true)

func check_binding_hints(style: String, controller: bool) -> void:
	main._sync_view()
	var expected := {"hm_guard": "LB / LT" if controller else "S / Down",
		"hm_jab": "A" if controller else "Space / J", "hm_dodge": "B" if controller else "D / L",
		"hm_pause": "Menu" if controller else "Esc"}
	if style == "twoHanded":
		expected.merge({"hm_hook": "X" if controller else "A / K",
			"hm_uppercut": "Y" if controller else "W / I", "hm_parry": "RB / RT" if controller else "Shift / P"})
	var found := {}
	for badge in main.ui.find_children("*", "PanelContainer", true, false):
		if not badge.has_meta("binding_action"):
			continue
		var action: String = badge.get_meta("binding_action")
		var label: Label = badge.get_child(0)
		found[action] = label.text
		check(badge.mouse_filter == Control.MOUSE_FILTER_IGNORE, "binding badges do not intercept touch")
		check(badge.get_meta("controller_glyph") == (controller and label.text in ["A", "B", "X", "Y"]),
			"ABXY use round glyphs; keyboard and shoulder hints use keycaps")
	check(found == expected, style + " displays matching " + ("Xbox" if controller else "keyboard") + " hints")
	for button in main.ui.find_children("*", "Button", true, false):
		if button.has_meta("fight_action"):
			check(button.focus_mode == Control.FOCUS_NONE, "labelled fight button cannot steal menu focus")

func test_binding_hints() -> void:
	main.set_process(false)
	var game = root.get_node("Game")
	var original_style: String = game.control_style
	var original_devices: PackedInt32Array = main._connected_joypads.duplicate()
	main._connected_joypads = PackedInt32Array()
	main._keyboard_hints = true
	for style in ["oneThumb", "twoHanded"]:
		game.control_style = style
		main._built_key = ""
		check_binding_hints(style, false)
		Input.joy_connection_changed.emit(99, true)
		check_binding_hints(style, true)
		Input.joy_connection_changed.emit(100, true)
		Input.joy_connection_changed.emit(99, false)
		check_binding_hints(style, true)
		Input.joy_connection_changed.emit(100, false)
		check_binding_hints(style, false)
	main._keyboard_hints = false
	main._built_key = ""
	main._sync_view()
	check(not main.ui.find_children("*", "PanelContainer", true, false).any(func(p): return p.has_meta("binding_action")),
		"touch-only mode keeps original touch labels")
	await key(KEY_J)
	check(main._keyboard_hints, "using a keyboard enables hints on a touch device")
	check_binding_hints("twoHanded", false)
	main.pending.clear()
	main._connected_joypads = original_devices
	game.control_style = original_style
	main._built_key = ""
	main.set_process(true)

func click_button(button: Button, touch: bool = false) -> void:
	var position := root.get_final_transform() * button.get_global_rect().get_center()
	var motion_event := InputEventMouseMotion.new()
	motion_event.position = position
	motion_event.global_position = position
	Input.parse_input_event(motion_event)
	await process_frame
	for pressed in [true, false]:
		if touch:
			var event := InputEventScreenTouch.new()
			event.position = position
			event.pressed = pressed
			Input.parse_input_event(event)
		else:
			var event := InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_LEFT
			event.position = position
			event.global_position = position
			event.pressed = pressed
			Input.parse_input_event(event)
		await process_frame

func test_get_up_controls() -> void:
	main.set_process(false)
	var previous_engine: FightEngine = main.engine
	var previous_log: Array = main.input_log
	var game = root.get_node("Game")
	var previous_style: String = game.control_style
	var previous_devices: PackedInt32Array = main._connected_joypads.duplicate()
	var previous_reduced: bool = game.reduced_motion
	var book := OpponentBook.new("recovery", "Recovery", [OpponentBook.entry(HM.Move.FEINT, 10000, 1, 1, 0, 0)], 10000, 0, 1000)
	for style in ["oneThumb", "twoHanded"]:
		game.control_style = style
		main.engine = FightEngine.new(FightEngine.Config.new(), 42, book)
		main.input_log = []
		main.pending.clear()
		main.engine.force_player_knockdown()
		main._built_key = ""
		main._sync_view()
		for i in 3:
			await process_frame
		check(main._refs.recovery.is_visible_in_tree() and not main._refs.fight_controls.visible,
			style + " replaces fight controls with recovery")
		check(shows("GET BACK UP") and shows("MACK IS DOWN") and shows("0 / 15 PRESSES"),
			"recovery has a persistent notification and visible target")
		check(main._knockdown_count().value == 6 and main._refs.get_up.focus_mode == Control.FOCUS_NONE,
			"recovery starts at six seconds and cannot take menu focus")
		check(main._countdown_color(6) == Color.WHITE and main._countdown_color(1) == main.RED,
			"recovery countdown only turns red near timeout")
		await key(KEY_SPACE)
		main._advance()
		await key(KEY_J)
		main._advance()
		await joy(JOY_BUTTON_A)
		main._advance()
		check(main.engine.player.get_up_presses == 3, "Space, J and Xbox A each count once")
		var echo := InputEventKey.new()
		echo.physical_keycode = KEY_SPACE
		echo.pressed = true
		echo.echo = true
		Input.parse_input_event(echo)
		await process_frame
		main._advance()
		check(main.engine.player.get_up_presses == 3, "holding a punch key cannot generate recovery presses")
		await joy(JOY_BUTTON_X)
		await key(KEY_UP)
		await joy(JOY_BUTTON_B)
		check(main.pending.is_empty(), "other attacks and dodge cannot advance recovery")
		await click_button(main._refs.get_up)
		main._advance()
		check(main.engine.player.get_up_presses == 4 and main.pending.is_empty(), "mouse Get back up click counts exactly once")
		await click_button(main._refs.get_up, true)
		main._advance()
		check(main.engine.player.get_up_presses == 5 and main.pending.is_empty(), "touch Get back up tap counts exactly once")
		main._update_match_ui()
		check(shows("5 / 15 PRESSES") and is_equal_approx(main._refs.recovery_bar.value, 5.0 / 15.0),
			"tap label and meter follow engine progress")

		await joy(JOY_BUTTON_START)
		main._sync_view()
		main.submit(HM.Cmd.JAB)
		check(main.paused and main.pending.is_empty() and main._refs.get_up.disabled,
			"pause disables recovery input without discarding progress")
		var paused_recovery_ticks: int = main.engine.player.ticks_in_state
		main.set_process(true)
		await wait(0.12)
		main.set_process(false)
		check(main.engine.player.ticks_in_state == paused_recovery_ticks, "pause freezes the recovery timer")
		await key(KEY_ESCAPE)
		main._sync_view()
		check(not main.paused and main.engine.player.get_up_presses == 5, "resume preserves recovery progress")
		main.modal = "settings"
		main.submit(HM.Cmd.JAB)
		check(main.pending.is_empty(), "settings cannot queue recovery inputs")
		main.modal = ""

		# UI rebuilds (controller changes, resize/settings) must not restart the engine's count.
		main._connected_joypads = PackedInt32Array([99])
		game.reduced_motion = true
		main._built_key = ""
		main._sync_view()
		check(main.engine.player.get_up_presses == 5 and main._refs.recovery.visible,
			"controller/reduced-motion rebuild preserves recovery")
		check(main._refs.get_up.find_children("*", "Label", true, false).any(func(l): return l.text == "A"),
			"recovery uses the primary Xbox A hint")
		for i in 10:
			await key(KEY_SPACE)
			main._advance()
		main._update_match_ui()
		check(main.engine.player.state == HM.State.IDLE and not main._refs.recovery.visible
			and main._refs.fight_controls.visible, "fifteenth press restores fight controls")
		check(main.engine.player_stats.thrown == 0, "get-up presses never throw a punch")
		main.engine.force_player_knockdown()
		main._update_match_ui()
		check(shows("0 / 20 PRESSES") and main._knockdown_count().value == 6,
			"second knockdown resets progress and raises the target to 20")
		main._connected_joypads = previous_devices

	main.engine = FightEngine.new(FightEngine.Config.new(), 42, book)
	main.engine.opponent.state = HM.State.ATTACKING
	main.engine.opponent.state_duration = 1
	main.engine.opponent.current_move = HM.Move.HOOK
	main.engine.opponent.current_damage = 30
	main.pending = [HM.Cmd.NONE, HM.Cmd.JAB, HM.Cmd.JAB]
	main._advance()
	check(main.engine.player.state == HM.State.KNOCKED_DOWN and main.pending.is_empty(),
		"knockdown discards punches queued before Mack fell")
	main.engine.player.get_up_presses = 14
	main.pending = [HM.Cmd.JAB, HM.Cmd.JAB]
	main._advance()
	check(main.engine.player.state == HM.State.IDLE and main.pending.is_empty(),
		"recovery discards extra presses rather than throwing an accidental punch")
	main._advance()
	check(main.engine.player_stats.thrown == 0, "no queued punch leaks into the resumed fight")

	# Presentation never starts an automatic get-up before Mack earns it.
	main.engine.force_player_knockdown()
	main.arena.render(main.engine, false, 0.1)
	var director: FighterDirector = main.arena.choreographer.hero.director
	check(director._knockdown.get_up_start == null, "Mack's get-up animation waits for earned recovery")
	var anchor: float = director._knockdown.anchor
	for i in 360:
		main.engine.tick(HM.Cmd.NONE)
	main.arena.render(main.engine, false, 0.1)
	check(director._knockdown.get_up_start == null and director._knockdown.anchor == anchor,
		"failed recovery keeps Mack down without replaying the fall")
	main._update_match_ui()
	check(not main._refs.recovery.visible, "timeout removes the recovery button")
	main.engine = FightEngine.new(FightEngine.Config.new(), 42, book)
	main.engine.force_player_knockdown()
	main.arena.render(main.engine, false, 0.1)
	for i in 15:
		main.engine.tick(HM.Cmd.JAB)
	main.arena.render(main.engine, false, 0.1)
	check(director._knockdown.risen and director._knockdown.get_up_start != null,
		"earned recovery starts Mack's get-up animation")
	main.engine = previous_engine
	main.input_log = previous_log
	main.pending.clear()
	main.arena.reset_for_next_bout(game.opponent.asset(), previous_reduced)
	game.control_style = previous_style
	game.reduced_motion = previous_reduced
	main._connected_joypads = previous_devices
	main._built_key = ""
	main.set_process(true)

func _run() -> void:
	await wait(0.3)
	crowd_player = main.crowd_audio_player
	check(crowd_player.stream is AudioStreamMP3 and crowd_player.stream.loop,
		"supplied crowd recording is configured to loop")
	check(is_equal_approx(crowd_player.volume_db, -12.0), "crowd plays at -12 dB background volume")
	check_crowd("home")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine == null, "first press only reveals focus")
	check(focused().contains("STEP INTO THE RING"), "home focuses the start button")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine != null and main.showing_versus, "A on start opens versus")
	check_crowd("versus")
	check(focused().contains("RING THE BELL"), "versus focuses ring the bell")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine != null and not main.showing_versus, "A rings the bell")
	check_crowd("countdown")
	var t := 0.0
	while not (main._fighting() and main.countdown < 0.0) and t < 10.0:
		await wait(0.1)
		t += 0.1
	check(main._fighting(), "fighting after countdown")
	check_crowd("fight")
	await test_fight_bindings()
	await test_binding_hints()
	await test_get_up_controls()
	await joy(JOY_BUTTON_X)
	await wait(0.2)
	await key(KEY_UP)
	await wait(0.2)
	check(main.input_log.has(HM.Cmd.HOOK) and main.input_log.has(HM.Cmd.UPPERCUT), "gamepad X hooks, Up arrow uppercuts")
	check(focused() == "", "no focused button mid-bout")
	await joy(JOY_BUTTON_START)
	await wait(0.1)
	check(main.paused, "Xbox Menu (Start) pauses")
	check(main.ui.find_children("*", "Button", true, false).any(func(b): return b.text == "Return to title"),
		"Xbox Menu opens a pause menu with Return to title")
	check(main.ui.find_children("*", "Button", true, false).any(func(b): return b.text == "Quit game"),
		"pause menu includes Quit game")
	var paused_ticks: int = main.engine.total_ticks
	await joy(JOY_BUTTON_X)
	await motion(JOY_AXIS_TRIGGER_LEFT, [0.7, 0.0])
	await wait(0.1)
	check(main.engine.total_ticks == paused_ticks and main.pending.is_empty(), "paused bout neither advances nor queues fight inputs")
	check_crowd("pause")
	check(focused().contains("RESUME"), "pause focuses resume")
	await joy(JOY_BUTTON_DPAD_DOWN)
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.modal == "settings", "D-pad down + A opens settings")
	check_crowd("settings")
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
	check_crowd("results")
	check(shows("FIGHT PRIZE TOKENS  1") and shows("FIGHTER STATS"), "win screen shows prize tokens and fighter stats")
	check(not (main._refs.primary as Button).disabled, "unspent tokens never lock Next fight")
	var primary: Button = main._refs.primary
	check(primary.get_index() == 0 and primary.get_parent().get_child(1).text == "REMATCH",
		"Next fight appears before secondary Rematch")
	await joy(JOY_BUTTON_DPAD_DOWN)
	check(focused() == "REMATCH", "D-pad down moves from Next fight to Rematch")
	await joy(JOY_BUTTON_DPAD_DOWN)
	check(focused() == "CAREER LADDER", "D-pad down reaches Career ladder")
	await joy(JOY_BUTTON_DPAD_RIGHT)
	check(focused() == "EXIT TO TITLE", "D-pad right reaches Exit to title beside Career ladder")
	await joy(JOY_BUTTON_DPAD_UP)
	check(focused() == "REMATCH", "D-pad up returns to Rematch")
	await joy(JOY_BUTTON_DPAD_UP)
	check(focused().begins_with("NEXT FIGHT"), "D-pad up returns to Next fight")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.showing_versus and game.opponent.id != defeated.id, "A on Next fight opens the next introduction")
	check(focused().contains("RING THE BELL"), "next introduction focuses ring the bell")
	check(shows("CHALLENGER STATS"), "versus shows the challenger stats")
	check(game.prize_tokens() == 1, "tokens carry into the next fight unspent")
	check(main.title_music_player != null and main.title_music_player.stream != null,
		"title music player is initialized with stream")
	check(main.title_music_player.stream is AudioStreamMP3
		and main.title_music_player.stream.resource_path == "res://assets/music/title_intro.mp3"
		and main.title_music_player.stream.loop, "replacement intro song is loaded and loops")
	main.session_reset()
	check(main.title_music_player.playing, "title music plays on home screen")
	check_crowd("return home")
	var position := crowd_player.get_playback_position()
	main.start_bout()
	check(not main.title_music_player.playing, "title music stops during bout")
	check(crowd_player.get_playback_position() >= position, "starting a bout does not restart crowd audio")
	main.session_reset()
	check(main.title_music_player.playing, "title music resumes after returning home")
	game.music_enabled = false
	main._update_title_music()
	check(not main.title_music_player.playing, "disabling music setting stops player")
	check_crowd("music disabled")
	game.music_enabled = true
	main._update_title_music()
	check(main.title_music_player.playing, "re-enabling music setting resumes player")
	var song_duration: float = main.title_music_player.stream.get_length()
	check(song_duration > 1.0, "replacement intro song has playable duration")
	main.title_music_player.seek(song_duration - 0.1)
	await wait(0.5)
	check(main.title_music_player.playing and main.title_music_player.get_playback_position() < 1.0,
		"replacement intro song loops without stopping")
	check_crowd("intro music loop boundary")
	paused = true
	await wait(0.2)
	check_crowd("scene tree paused")
	paused = false
	var duration := crowd_player.stream.get_length()
	check(duration > 1.0, "crowd recording has playable duration")
	crowd_player.seek(duration - 0.1)
	await wait(0.5)
	check_crowd("loop boundary")
	check(crowd_player.get_playback_position() < 1.0, "crowd wraps to the beginning without stopping")
	main.start_bout()
	main.begin_fight()
	main.countdown = -1.0
	main.showing_career = true
	await wait(0.1)
	await joy(JOY_BUTTON_START)
	await wait(0.1)
	await joy(JOY_BUTTON_DPAD_DOWN)
	await joy(JOY_BUTTON_DPAD_DOWN)
	check(focused() == "Return to title", "D-pad reaches Return to title")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine == null and not main.showing_career and not main.paused,
		"Return to title ends the active bout and shows the title, not the career screen")
	check(main.title_music_player.playing, "returning to title resumes title music")
	check_crowd("pause to title")
	await test_results_navigation(game)
	main.start_bout()
	main.begin_fight()
	main.countdown = -1.0
	await wait(0.1)
	await joy(JOY_BUTTON_START)
	await wait(0.1)
	for i in 3:
		await joy(JOY_BUTTON_DPAD_DOWN)
	check(focused() == "Quit game", "D-pad reaches Quit game")
	print("%d input failures" % fails)
	if fails > 0:
		quit(1)
		return
	for pressed in [true, false]:
		var accept := InputEventJoypadButton.new()
		accept.button_index = JOY_BUTTON_A
		accept.pressed = pressed
		Input.parse_input_event(accept)
	create_timer(0.2).timeout.connect(func():
		check(false, "Quit game must terminate the application")
		quit(1))

func show_results(game, outcome: int, tokens: int) -> void:
	main.start_bout()
	main.begin_fight()
	main.countdown = -1.0
	game.saved = true
	game.progression.tokens = tokens
	main.engine.phase = HM.Phase.OVER
	main.engine.outcome = outcome
	main.post_bout_elapsed = Arena.RESULTS_DELAY
	main.replay_matches = true
	main._built_key = ""
	await wait(0.1)

func test_results_navigation(game) -> void:
	await show_results(game, HM.Outcome.PLAYER_LOSS_BY_KO, 2)
	check(focused() == "REMATCH", "loss focuses Rematch")
	var stat: Button = main._refs.attributes[0]
	var stat_name: String = stat.text.get_slice(" ", 0)
	stat.grab_focus()
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(game.prize_tokens() == 1 and focused().begins_with(stat_name),
		"spending a token keeps focus on the upgraded stat")
	await show_results(game, HM.Outcome.PLAYER_LOSS_BY_KO, 0)
	var landed_disabled := false
	for button in [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_DOWN]:
		for i in 3:
			await joy(button)
			var f = root.gui_get_focus_owner()
			landed_disabled = landed_disabled or f == null or (f is BaseButton and f.disabled)
	check(not landed_disabled, "results D-pad never focuses a disabled stat button")
	check(focused() == "CAREER LADDER", "D-pad down settles on the bottom action row")
	await joy(JOY_BUTTON_DPAD_RIGHT)
	check(focused() == "EXIT TO TITLE", "D-pad right reaches Exit to title")
	await joy(JOY_BUTTON_A)
	await wait(0.1)
	check(main.engine == null and not main.showing_career, "Exit to title leaves the results for the title screen")
	check(main.title_music_player.playing, "exiting results resumes title music")

func check_crowd(screen: String) -> void:
	check(main.crowd_audio_player == crowd_player and crowd_player.playing and not crowd_player.stream_paused,
		"same crowd player continues through " + screen)
