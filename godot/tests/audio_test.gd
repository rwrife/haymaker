extends SceneTree
## Run: godot --headless --path godot --script res://tests/audio_test.gd -- --isolated-store

var main
var fails := 0


func _initialize() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	_run.call_deferred()


func check(condition: bool, label: String) -> void:
	print(("ok   " if condition else "FAIL ") + label)
	if not condition:
		fails += 1


func reactions() -> Array[AudioStreamPlayer]:
	var players: Array[AudioStreamPlayer] = []
	for child in main.get_children():
		if child is AudioStreamPlayer and child.stream == main.PUNCH_CROWD_AUDIO:
			players.append(child)
	return players


func present_events() -> void:
	main._last_frame = -1.0
	main._process(0.0)


func show_result(outcome: int) -> void:
	main.start_bout()
	main.showing_versus = false
	main.engine.phase = HM.Phase.OVER
	main.engine.outcome = outcome
	main.post_bout_elapsed = Arena.RESULTS_DELAY
	main._built_key = ""
	present_events()


func _run() -> void:
	await process_frame
	main.set_process(false)
	var game = root.get_node("Game")
	game.music_enabled = false
	main.start_bout()
	main.begin_fight()
	main.countdown = -1.0
	check(absf(main.PUNCH_CROWD_AUDIO.get_length() - 6.0) < 0.0001,
		"punch crowd excerpt lasts exactly six seconds")
	check(main.PUNCH_CROWD_AUDIO.loop_mode == AudioStreamWAV.LOOP_DISABLED,
		"punch crowd reaction is a one-shot")
	check(main.PUNCH_CROWD_AUDIO.format == AudioStreamWAV.FORMAT_16_BITS
		and main.PUNCH_CROWD_AUDIO.data.size() == 288000 * 2 * 2,
		"import preserves the boosted PCM without lossy compression")
	check(reactions().is_empty(), "no punch reactions before a landed punch")
	check(not main.WIN_CHEER_AUDIO.loop and main.WIN_CHEER_AUDIO.get_length() > 1.0,
		"supplied winning-screen cheer is a playable one-shot")
	check(not main.win_cheer_player.playing, "winning-screen cheer does not play during a bout")
	main.engine.events = [
		{"type": "landed", "tick": 0, "by": HM.Who.PLAYER, "move": HM.Move.JAB, "damage": 8, "counter": false},
		{"type": "landed", "tick": 0, "by": HM.Who.OPPONENT, "move": HM.Move.JAB, "damage": 8, "counter": false},
		{"type": "dodged", "tick": 0, "attacker": HM.Who.PLAYER, "move": HM.Move.JAB},
		{"type": "blocked", "tick": 0, "by": HM.Who.OPPONENT, "move": HM.Move.JAB, "damage": 2},
		{"type": "parried", "tick": 0, "attacker": HM.Who.OPPONENT, "move": HM.Move.JAB},
		{"type": "whiffed", "tick": 0, "by": HM.Who.PLAYER, "move": HM.Move.JAB},
	]
	main.last_event_count = 0
	present_events()
	check(reactions().size() == 2, "both fighters trigger reactions; blocks, dodges, parries and misses do not")
	check(reactions().all(func(player): return player.playing),
		"simultaneous hits play independently even when music is disabled")
	present_events()
	check(reactions().size() == 2, "processed hits are not played again on the next frame")
	main.engine.events.append(
		{"type": "landed", "tick": 1, "by": HM.Who.PLAYER, "move": HM.Move.HOOK, "damage": 16, "counter": true})
	present_events()
	check(reactions().size() == 3, "counter reaction overlaps without interrupting earlier hits")
	paused = true
	await create_timer(0.2).timeout
	check(reactions().all(func(player): return player.playing and not player.stream_paused),
		"active reactions continue while the scene tree is paused")
	paused = false
	check(main.crowd_audio_player.playing, "punch reactions never stop background crowd ambience")
	for player in reactions():
		player.seek(5.9)
	await create_timer(0.5).timeout
	check(reactions().is_empty(), "finished reactions free their audio players instead of looping")
	main.start_bout()
	main.begin_fight()
	main.countdown = -1.0
	main.engine.player.state = HM.State.ATTACKING
	main.engine.player.state_duration = 1
	main.engine.player.ticks_in_state = 0
	main.engine.player.current_move = HM.Move.JAB
	main.engine.player.current_damage = 8
	main.engine.opponent.hp = 1
	main.tick_accumulator = main.TICK
	present_events()
	check(main.engine.is_over() and reactions().size() == 1,
		"the knockout-ending punch still triggers its reaction")
	check(not main.win_cheer_player.playing, "win cheer waits for the winning screen, not the knockout")
	main.post_bout_elapsed = Arena.RESULTS_DELAY
	present_events()
	check(main.win_cheer_player.playing and main.crowd_audio_player.playing,
		"knockout winning screen plays cheer over continuous crowd ambience")
	main.win_cheer_player.seek(main.WIN_CHEER_AUDIO.get_length() - 0.1)
	await create_timer(0.5).timeout
	check(not main.win_cheer_player.playing, "win cheer ends instead of looping")
	main._built_key = ""
	present_events()
	check(not main.win_cheer_player.playing, "rebuilding a winning screen does not replay its cheer")
	show_result(HM.Outcome.PLAYER_WIN_BY_DECISION)
	check(main.win_cheer_player.playing, "decision win starts a fresh winning-screen cheer")
	show_result(HM.Outcome.PLAYER_LOSS_BY_KO)
	check(not main.win_cheer_player.playing, "knockout defeat stops the previous cheer and does not cheer")
	show_result(HM.Outcome.PLAYER_LOSS_BY_DECISION)
	check(not main.win_cheer_player.playing, "decision defeat does not cheer")
	show_result(HM.Outcome.DRAW)
	check(not main.win_cheer_player.playing, "draw does not cheer")
	show_result(HM.Outcome.PLAYER_WIN_BY_KO)
	main.start_bout()
	check(not main.win_cheer_player.playing and not main._win_cheer_played,
		"starting the next bout stops and resets the victory cheer")
	main.showing_versus = false
	main.engine.phase = HM.Phase.OVER
	main.engine.outcome = HM.Outcome.PLAYER_WIN_BY_KO
	game.ladder = [game.opponent]
	game.bouts = [{"mode": "career", "result": main.engine.result()}]
	game._ladder_start = 0
	game.saved = true
	main.post_bout_elapsed = Arena.RESULTS_DELAY
	present_events()
	present_events()
	check(main.showing_victory and main.crowd_audio_player.playing,
		"background crowd continues into the career finale")
	check(main.win_cheer_player.playing, "career winning screen also plays the victory cheer")
	main.win_cheer_player.seek(0.5)
	var position: float = main.win_cheer_player.get_playback_position()
	main._built_key = ""
	present_events()
	check(main.win_cheer_player.get_playback_position() >= position,
		"career winning-screen rebuild does not restart the cheer")
	main.session_reset()
	check(main.crowd_audio_player.playing and not main.win_cheer_player.playing,
		"returning home preserves ambience but stops the victory cheer")
	main.queue_free()
	await process_frame
	print("%d audio failures" % fails)
	quit(1 if fails > 0 else 0)
