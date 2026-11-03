extends Node
## Port of ContentView.swift: the app shell around the 3D arena. The engine is
## authoritative; this view only queues inputs and reads snapshots.

const GOLD := Color(0.98, 0.72, 0.25)
const GOLD_LIGHT := Color(1.0, 0.83, 0.42)
const ORANGE := Color(0.96, 0.49, 0.13)
const GREEN := Color(0.31, 0.92, 0.39)
const RED := Color(0.97, 0.24, 0.19)
const INK := Color(0.025, 0.04, 0.075)
const TICK := 1.0 / 60.0
const DESKTOP_CANVAS_MIN := Vector2(960, 540)
const DESKTOP_CANVAS_REFERENCE := Vector2(1280, 720)
const DESKTOP_SCALE_MAX := 2.0
const MOBILE_CANVAS_SIZE := Vector2i(430, 430)
const MENU_MAX := Vector2(640, 720)
const HUD_MAX_WIDTH := 960.0
const MIN_SCREEN_WIDTH := 0.3
const CROWD_AUDIO: AudioStreamMP3 = preload("res://assets/audio/boxing_crowd.mp3")
const PUNCH_CROWD_AUDIO: AudioStreamWAV = preload("res://assets/audio/punch_crowd.wav")
const TITLE_MUSIC: AudioStreamMP3 = preload("res://assets/music/title_intro.mp3")
const WIN_CHEER_AUDIO: AudioStreamMP3 = preload("res://assets/audio/win_cheer.mp3")

var arena: Arena
var layer: CanvasLayer
var ui: Control
var title_music_player: AudioStreamPlayer = null
var crowd_audio_player: AudioStreamPlayer
var win_cheer_player: AudioStreamPlayer

var engine: FightEngine = null
var input_log: Array = []
var pending: Array = []
var showing_career := false
var showing_versus := false
var showing_victory := false
var paused := false
var modal := ""
var detail_book: OpponentBook = null
var feedback := ""
var feedback_until := 0
var feedback_color := GOLD
var tick_accumulator := 0.0
var countdown := -1.0 # elapsed seconds while the 3-2-1 runs; < 0 when idle
var last_event_count := 0
var post_bout_elapsed := 0.0
var victory_elapsed := 0.0
var last_knockdown_value := 0
var portrait := true
var replay_matches := false

var _built_key := ""
var _last_frame := -1.0
var _refs := {}
var _fonts := {}
var _swipe_start = null
var _win_cheer_played := false


func _ready() -> void:
	crowd_audio_player = AudioStreamPlayer.new()
	crowd_audio_player.name = "CrowdAudioPlayer"
	crowd_audio_player.process_mode = Node.PROCESS_MODE_ALWAYS
	crowd_audio_player.stream = CROWD_AUDIO
	crowd_audio_player.volume_db = -12.0
	add_child(crowd_audio_player)
	crowd_audio_player.play()
	win_cheer_player = AudioStreamPlayer.new()
	win_cheer_player.name = "WinCheerPlayer"
	win_cheer_player.process_mode = Node.PROCESS_MODE_ALWAYS
	win_cheer_player.stream = WIN_CHEER_AUDIO
	add_child(win_cheer_player)
	arena = Arena.new(true)
	add_child(arena)
	layer = CanvasLayer.new()
	add_child(layer)
	var shade := TextureRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.texture = _vertical_gradient([Color(0, 0, 0, 0.8), Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(INK, 0.95)],
		[0.0, 0.33, 0.66, 1.0])
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	layer.add_child(shade)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)
	title_music_player = AudioStreamPlayer.new()
	title_music_player.name = "TitleMusicPlayer"
	title_music_player.stream = TITLE_MUSIC
	add_child(title_music_player)
	_update_title_music()
	register_input_actions()
	get_tree().root.size_changed.connect(_on_resize)
	_fit_desktop_window()
	_on_resize()


## Desktop launches as a wide 16:9 window scaled to the monitor; the window stays freely resizable to any aspect.
func _fit_desktop_window() -> void:
	if OS.has_feature("mobile") or DisplayServer.get_name() == "headless":
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var w := mini(int(usable.size.x * 0.8), int(usable.size.y * 0.8 * 16.0 / 9.0))
	var size := Vector2i(maxi(w, 640), maxi(int(w * 9.0 / 16.0), 360))
	DisplayServer.window_set_min_size(Vector2i(480, 320))
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_last_frame = -1.0
		if engine != null and not engine.is_over() and not showing_versus:
			paused = true


func _on_resize() -> void:
	var window := get_tree().root
	var canvas := ui_canvas_size(window.size, OS.has_feature("mobile"))
	if window.content_scale_size != canvas:
		window.content_scale_size = canvas
	var s := _view_size()
	var p := s.y > s.x
	if p != portrait or arena.camera == null:
		portrait = p
		arena.layout(portrait)
	_built_key = ""


## Desktop zoom stops at 2x, giving every logical panel cap an absolute pixel ceiling.
static func desktop_ui_scale(window_size: Vector2i) -> float:
	var compact := minf(1.0, minf(window_size.x / DESKTOP_CANVAS_MIN.x, window_size.y / DESKTOP_CANVAS_MIN.y))
	var zoom := clampf(minf(window_size.x / DESKTOP_CANVAS_REFERENCE.x,
		window_size.y / DESKTOP_CANVAS_REFERENCE.y), 1.0, DESKTOP_SCALE_MAX)
	return compact * zoom


## Mobile uses its own logical canvas regardless of physical resolution.
static func ui_canvas_size(window_size: Vector2i, mobile: bool) -> Vector2i:
	if mobile:
		return MOBILE_CANVAS_SIZE
	var scale := desktop_ui_scale(window_size)
	return Vector2i(ceilf(window_size.x / scale), ceilf(window_size.y / scale))


func _view_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func reduced() -> bool:
	return Game.reduced_motion


# MARK: - Frame loop (advanceFrame)

func _process(_delta: float) -> void:
	_sync_view()
	var now := Time.get_ticks_usec() / 1_000_000.0
	if engine == null:
		_last_frame = -1.0
		if not showing_career and modal == "":
			arena.render_title(now, reduced())
		return
	if modal != "" or showing_versus or (paused and not engine.is_over()):
		_last_frame = -1.0
		return
	var elapsed := minf(0.1, maxf(0.0, now - (_last_frame if _last_frame >= 0.0 else now)))
	_last_frame = now
	if showing_victory:
		if not reduced():
			victory_elapsed += elapsed
		arena.render_career_victory(victory_elapsed, reduced())
		return
	if engine.is_over():
		if post_bout_elapsed >= Arena.RESULTS_DELAY and Game.can_celebrate_victory():
			showing_victory = true
			victory_elapsed = 0.0
			arena.begin_career_victory(reduced())
			return
		if post_bout_elapsed >= Arena.POST_BOUT_RENDER_SECONDS:
			return
		post_bout_elapsed += elapsed
		arena.render(engine, reduced(), elapsed)
		_update_match_ui()
		return
	if countdown >= 0.0:
		var previous := _countdown_value()
		countdown = minf(2.7, countdown + elapsed)
		if countdown >= 2.7:
			countdown = -1.0
			tick_accumulator = 0.0
			_set_feedback("FIGHT!", GOLD, engine.total_ticks + 50)
			Game.haptic(1.0)
		elif _countdown_value() != previous:
			Game.haptic(1.0 if _countdown_value() == 1 else 0.6)
		arena.render(engine, reduced(), elapsed)
		_update_match_ui()
		return
	tick_accumulator += elapsed
	while tick_accumulator >= TICK:
		_advance()
		tick_accumulator -= TICK
		if engine.is_over():
			Game.save(engine, input_log)
			replay_matches = _replay_matches()
			break
	arena.render(engine, reduced(), elapsed, tick_accumulator * 60.0)
	var events: Array = engine.events
	for i in range(last_event_count, events.size()):
		var e: Dictionary = events[i]
		match e.type:
			"landed":
				_play_punch_crowd()
				var mine: bool = e.by == HM.Who.PLAYER
				feedback = ("COUNTER!" if e.counter else "CLEAN HIT!") if mine else "HIT!"
				feedback_color = GOLD if mine else RED
				Game.haptic(1.0 if e.counter else 0.6)
			"dodged":
				var mine: bool = e.attacker == HM.Who.PLAYER
				feedback = "MISSED!" if mine else "DODGED!"
				feedback_color = RED if mine else GREEN
			"parried":
				feedback = "PARRIED!"
				feedback_color = GREEN
			"blocked":
				feedback = "BLOCKED!"
				feedback_color = Color.WHITE
			"knockdown":
				feedback = "KNOCKDOWN!"
				feedback_color = GOLD
			"roundStart":
				feedback = "FIGHT!"
				feedback_color = GOLD
			"rise":
				if engine.phase != HM.Phase.FIGHTING:
					continue
				feedback = "FIGHT!"
				feedback_color = GOLD
			_:
				continue
		feedback_until = engine.total_ticks + 38
	last_event_count = events.size()
	var down := _knockdown_count()
	var value: int = down.value if not down.is_empty() else 0
	if value != last_knockdown_value and value > 0:
		Game.haptic(1.0 if value == 1 else 0.6)
	last_knockdown_value = value
	_update_match_ui()


func _play_punch_crowd() -> void:
	var player := AudioStreamPlayer.new()
	player.name = "PunchCrowdPlayer"
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	player.stream = PUNCH_CROWD_AUDIO
	player.finished.connect(player.queue_free)
	add_child(player)
	player.play()


func _play_win_cheer() -> void:
	if _win_cheer_played:
		return
	_win_cheer_played = true
	win_cheer_player.play()


func _advance() -> void:
	if engine.is_over():
		return
	var input: int = HM.Cmd.NONE if pending.is_empty() else pending.pop_front()
	input_log.append(input)
	engine.tick(input)


func submit(input: int) -> void:
	if engine == null or engine.is_over():
		return
	if pending.size() < 4:
		pending.append(input)


func _replay_matches() -> bool:
	var replay := FightEngine.new(engine.config, engine.seed, engine.book)
	var index := 0
	var cap := engine.config.hard_tick_cap()
	while not replay.is_over() and replay.total_ticks < cap:
		replay.tick(input_log[index] if index < input_log.size() else HM.Cmd.NONE)
		index += 1
	return replay.outcome == engine.outcome and replay.player_stats.landed == engine.player_stats.landed \
		and replay.events == engine.events


func _set_feedback(text: String, color: Color, until: int) -> void:
	feedback = text
	feedback_color = color
	feedback_until = until


func _countdown_value() -> int:
	if countdown < 0.0:
		return 0
	return maxi(1, 3 - int(countdown / 0.9))


func _knockdown_count() -> Dictionary:
	if engine == null or engine.phase != HM.Phase.FIGHTING:
		return {}
	for pair in [[true, engine.player], [false, engine.opponent]]:
		var status: FightEngine.Status = pair[1]
		if status.state != HM.State.KNOCKED_DOWN:
			continue
		var value := HM.knockdown_value(status.ticks_in_state, status.state_duration)
		var progress := HM.knockdown_step_progress(status.ticks_in_state, status.state_duration)
		if value <= 0 or progress < 0.0:
			continue
		return {"value": value, "progress": progress, "player": pair[0]}
	return {}


# MARK: - Navigation (startBout / beginFight / sessionReset)

func start_bout() -> void:
	win_cheer_player.stop()
	_win_cheer_played = false
	showing_victory = false
	victory_elapsed = 0.0
	engine = Game.make_engine()
	_update_title_music()
	input_log = []
	pending = []
	arena.reset_for_next_bout(Game.opponent.asset(), reduced())
	showing_versus = true
	paused = false
	last_event_count = 0
	_last_frame = -1.0
	tick_accumulator = 0.0
	countdown = -1.0
	last_knockdown_value = 0
	post_bout_elapsed = 0.0
	replay_matches = false
	_set_feedback("", GOLD, 0)
	arena.render(engine, reduced(), 0.0)


func begin_fight() -> void:
	showing_versus = false
	_last_frame = -1.0
	tick_accumulator = 0.0
	countdown = 0.0
	_set_feedback("", GOLD, 0)
	Game.haptic(0.6)


func session_reset() -> void:
	win_cheer_player.stop()
	_win_cheer_played = false
	showing_victory = false
	victory_elapsed = 0.0
	showing_versus = false
	countdown = -1.0
	last_knockdown_value = 0
	engine = null
	post_bout_elapsed = 0.0
	arena.queue_free()
	arena = Arena.new(true)
	add_child(arena)
	move_child(arena, 0)
	arena.layout(portrait)
	paused = false
	_last_frame = -1.0
	feedback = ""
	_update_title_music()


func _update_title_music() -> void:
	if title_music_player == null or title_music_player.stream == null:
		return
	var should_play := (engine == null) and Game.music_enabled
	if should_play and not title_music_player.playing:
		title_music_player.play()
	elif not should_play and title_music_player.playing:
		title_music_player.stop()


func _begin(book: OpponentBook, mode: String) -> void:
	if Game.begin(book, mode):
		start_bout()


# MARK: - Keyboard / gamepad (desktop and controller extras; touch mirrors iOS)

const FIGHT_ACTIONS := {
	"hm_jab": HM.Cmd.JAB, "hm_hook": HM.Cmd.HOOK, "hm_uppercut": HM.Cmd.UPPERCUT,
	"hm_dodge": HM.Cmd.DODGE, "hm_guard": HM.Cmd.BLOCK, "hm_parry": HM.Cmd.PARRY,
}

var _nav_mode := false # true once keyboard/gamepad drives the UI; touch/mouse clears it


## Registers the fight bindings. Gamepad layout: A jab, X hook, Y uppercut, B dodge, LB/LT guard, RB/RT parry,
## D-pad mirrors the PUNCH swipes (left hook, up uppercut, right dodge, down guard), Start pauses.
static func register_input_actions() -> void:
	var bindings := {
		"hm_jab": [KEY_SPACE, KEY_J, JOY_BUTTON_A],
		"hm_hook": [KEY_LEFT, KEY_A, KEY_K, JOY_BUTTON_X, JOY_BUTTON_DPAD_LEFT],
		"hm_uppercut": [KEY_UP, KEY_W, KEY_I, JOY_BUTTON_Y, JOY_BUTTON_DPAD_UP],
		"hm_dodge": [KEY_RIGHT, KEY_D, KEY_L, JOY_BUTTON_B, JOY_BUTTON_DPAD_RIGHT],
		"hm_guard": [KEY_DOWN, KEY_S, JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_DPAD_DOWN, -JOY_AXIS_TRIGGER_LEFT - 1],
		"hm_parry": [KEY_SHIFT, KEY_P, JOY_BUTTON_RIGHT_SHOULDER, -JOY_AXIS_TRIGGER_RIGHT - 1],
		"hm_pause": [KEY_ESCAPE, JOY_BUTTON_START],
		"hm_fullscreen": [KEY_F11],
	}
	for action in bindings:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.5)
		for code in bindings[action]:
			var ev: InputEvent
			if code < 0:
				var axis := InputEventJoypadMotion.new()
				axis.axis = (-code - 1) as JoyAxis
				axis.axis_value = 1.0
				ev = axis
			elif code >= KEY_SPECIAL or (code >= KEY_A and code <= KEY_Z) or code == KEY_SPACE:
				var key := InputEventKey.new()
				key.physical_keycode = code as Key
				ev = key
			else:
				var joy := InputEventJoypadButton.new()
				joy.button_index = code as JoyButton
				ev = joy
			InputMap.action_add_event(action, ev)
	# Godot's default menu actions are keyboard-only for confirm/back; give gamepads A and B.
	for pair in [["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B]]:
		var joy := InputEventJoypadButton.new()
		joy.button_index = pair[1]
		if not InputMap.action_has_event(pair[0], joy):
			InputMap.action_add_event(pair[0], joy)


func _fighting() -> bool:
	return engine != null and not engine.is_over() and not showing_versus and not paused and modal == "" \
		and not showing_victory


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if _nav_mode:
			_nav_mode = false
			var focused := get_viewport().gui_get_focus_owner()
			if focused != null:
				focused.release_focus()
		return
	var nav: bool = (event is InputEventKey and event.pressed) or (event is InputEventJoypadButton and event.pressed) \
		or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5)
	if nav and not _nav_mode:
		_nav_mode = true
		if not _fighting():
			_focus_default()
			# The first key press only reveals focus, so it can't fire a button the player hasn't seen.
			if not (event.is_action("ui_cancel") or event.is_action("hm_pause") or event.is_action("hm_fullscreen")):
				get_viewport().set_input_as_handled()
				return
	# Moves are read before the GUI so Space/arrows/A never activate a menu button mid-bout.
	if _fighting() and not event.is_echo():
		for action in FIGHT_ACTIONS:
			if event.is_action_pressed(action):
				submit(FIGHT_ACTIONS[action])
				get_viewport().set_input_as_handled()
				return
		if event.is_action_pressed("hm_pause"):
			paused = true
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed("hm_fullscreen"):
		var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)
		get_viewport().set_input_as_handled()
		return
	if _fighting():
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("hm_pause"):
		if _go_back(event.is_action_pressed("hm_pause")):
			get_viewport().set_input_as_handled()


## Esc / gamepad B steps back one level, like the close and back buttons on each screen.
func _go_back(from_pause_key: bool) -> bool:
	if modal != "":
		_close_modal()
	elif engine != null and paused and not engine.is_over():
		paused = false
		_last_frame = -1.0
	elif showing_versus:
		if from_pause_key:
			return false
		session_reset()
	elif engine == null and showing_career:
		showing_career = false
	else:
		return false
	return true


## Gives keyboard/gamepad users a starting focus on the screen's primary button.
func _focus_default() -> void:
	if not _nav_mode or _fighting():
		return
	var owner := get_viewport().gui_get_focus_owner()
	if owner != null and owner.is_visible_in_tree() and ui.is_ancestor_of(owner):
		return
	var target: Control = null
	var primary = _refs.get("primary")
	if modal == "" and primary is BaseButton and is_instance_valid(primary) and not (primary as BaseButton).disabled \
			and (primary as Control).is_visible_in_tree():
		target = primary
	if target == null:
		# Later children (modals, overlays) sit on top, so start from the topmost layer that offers focus.
		var layers := ui.get_children()
		layers.reverse()
		for layer in layers:
			target = _first_focusable(layer)
			if target != null:
				break
	if target != null:
		target.grab_focus()


func _first_focusable(node: Node) -> Control:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return null
	if node is Control and (node as Control).focus_mode == Control.FOCUS_ALL \
			and not (node is BaseButton and (node as BaseButton).disabled):
		return node as Control
	for c in node.get_children():
		var found := _first_focusable(c)
		if found != null:
			return found
	return null


# MARK: - View building

func _view_key() -> String:
	var parts := [portrait, modal, Game.control_style, Game.error, Game.prize_tokens(), Game.progression.player]
	if showing_victory:
		parts.append("victory")
	elif engine != null:
		if showing_versus:
			parts.append("versus")
		else:
			var results := engine.is_over() and post_bout_elapsed >= Arena.RESULTS_DELAY
			parts.append_array(["match", not results, results and not Game.can_celebrate_victory(), paused and not engine.is_over(), Game.saved])
	elif showing_career:
		parts.append_array(["career", Game.ladder_complete(), Game.bouts.size()])
	else:
		parts.append("home")
	return str(parts)


func _sync_view() -> void:
	var key := _view_key()
	if key == _built_key:
		return
	_built_key = key
	for c in ui.get_children():
		ui.remove_child(c) # detach now so focus can't stay on a button that is about to be freed
		c.queue_free()
	_refs = {}
	if showing_victory:
		_build_victory()
	elif engine != null:
		if showing_versus:
			_build_versus()
		else:
			if not engine.is_over() or post_bout_elapsed < Arena.RESULTS_DELAY:
				_build_match()
			if engine.is_over():
				if post_bout_elapsed >= Arena.RESULTS_DELAY and not Game.can_celebrate_victory():
					_build_results()
			elif paused:
				_build_pause()
	elif showing_career:
		_build_career()
	else:
		_build_home()
	match modal:
		"settings": _build_settings()
		"records": _build_records()
		"detail": _build_detail(detail_book)
	_update_match_ui()
	_focus_default.call_deferred()


# MARK: - Styling helpers

func _sys_font(names: Array, weight: int, italic: bool, stretch: int) -> SystemFont:
	var key := "%s/%d/%s/%d" % [names[0], weight, italic, stretch]
	if _fonts.has(key):
		return _fonts[key]
	var f := SystemFont.new()
	f.font_names = PackedStringArray(names)
	f.font_weight = weight
	f.font_italic = italic
	f.font_stretch = stretch
	f.allow_system_fallback = true
	_fonts[key] = f
	return f


## RingStyle.type: Avenir Next Condensed Heavy.
func ring_font(italic: bool = false, weight: int = 800) -> Font:
	return _sys_font(["Avenir Next Condensed", "Bahnschrift", "Roboto Condensed", "sans-serif-condensed", "Arial Narrow"], weight, italic, 75)


func sys_font(weight: int = 800) -> Font:
	return _sys_font(["SF Pro Text", "Segoe UI", "Roboto", "sans-serif", "Arial"], weight, false, 100)


func mono_font() -> Font:
	return _sys_font(["SF Mono", "Consolas", "Roboto Mono", "monospace", "Courier New"], 700, false, 100)


func _tracked(font: Font, tracking: float) -> Font:
	if tracking == 0.0:
		return font
	var v := FontVariation.new()
	v.base_font = font
	v.spacing_glyph = int(round(tracking))
	return v


func lbl(text: String, size: float, color: Color = Color.WHITE, font: Font = null, tracking: float = 0.0,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _tracked(font if font != null else sys_font(), tracking))
	l.add_theme_font_size_override("font_size", int(round(size)))
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 10
	return l


func shadowed(l: Label, color: Color = Color.BLACK, offset: Vector2 = Vector2(0, 4), size: int = 8) -> Label:
	l.add_theme_color_override("font_shadow_color", color)
	l.add_theme_constant_override("shadow_offset_x", int(offset.x))
	l.add_theme_constant_override("shadow_offset_y", int(offset.y))
	l.add_theme_constant_override("shadow_outline_size", size)
	return l


func box(bg: Color, radius: float = 8.0, border: Color = Color(0, 0, 0, 0), border_width: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(border_width)
	s.anti_aliasing = true
	return s


func btn(text: String, on_press: Callable, bg: Color, fg: Color, font: Font, size: float, height: float,
		border: Color = Color(0, 0, 0, 0), radius: float = 8.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = height
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", int(size))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(state, fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.35))
	var normal := box(bg, radius, border)
	var pressed := box(bg.darkened(0.18) if bg.a > 0.0 else Color(1, 1, 1, 0.08), radius, border)
	var disabled := box(Color(bg, bg.a * 0.4), radius, Color(border, border.a * 0.4))
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", normal)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", focus_ring(radius))
	b.pressed.connect(on_press)
	return b


func focus_ring(radius: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = GOLD_LIGHT
	s.set_border_width_all(2)
	s.set_corner_radius_all(int(radius) + 3)
	s.set_expand_margin_all(3)
	s.anti_aliasing = true
	return s


func link(text: String, on_press: Callable, color: Color = GOLD, size: float = 15) -> Button:
	var b := btn(text, on_press, Color(0, 0, 0, 0), color, sys_font(600), size, 32)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return b


func vbox(sep: float = 0.0) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", int(sep))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


func hbox(sep: float = 0.0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", int(sep))
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


func spacer(expand: bool = true, min_size: float = 0.0) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.custom_minimum_size = Vector2(min_size, min_size)
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


func fill(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func panel(style: StyleBox, child: Control = null, pad: float = 0.0) -> PanelContainer:
	var p := PanelContainer.new()
	if pad > 0.0 and style is StyleBoxFlat:
		(style as StyleBoxFlat).set_content_margin_all(pad)
	p.add_theme_stylebox_override("panel", style)
	if child != null:
		p.add_child(child)
	return p


func fit_panel_width(control: Control, preferred: float, maximum: float, available: float) -> void:
	var minimum := 0.0 if OS.has_feature("mobile") else minf(_view_size().x * MIN_SCREEN_WIDTH, minf(maximum, available))
	control.custom_minimum_size.x = minf(maxf(preferred, minimum), minf(maximum, available))
	control.set_meta("width_min", minimum)
	control.set_meta("width_max", maximum)


func dim(color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	return r


## Center bounded content within the safe area; backgrounds still cover the viewport.
func safe_root(h: float, top: float = 0.0, bottom: float = 0.0, parent: Control = null,
		max_size: Vector2 = Vector2.ZERO) -> MarginContainer:
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var inset := _safe_insets()
	var available := _view_size() - inset.position - inset.size - Vector2(h * 2.0, top + bottom)
	if OS.has_feature("mobile"):
		max_size = Vector2.ZERO
	var bounded := available
	if max_size.x > 0.0:
		bounded.x = minf(available.x, max_size.x)
	if max_size.y > 0.0:
		bounded.y = minf(available.y, max_size.y)
	var extra := (available - bounded) / 2.0
	m.add_theme_constant_override("margin_left", int(h + inset.position.x + extra.x))
	m.add_theme_constant_override("margin_right", int(h + inset.size.x + extra.x))
	m.add_theme_constant_override("margin_top", int(top + inset.position.y + extra.y))
	m.add_theme_constant_override("margin_bottom", int(bottom + inset.size.y + extra.y))
	m.set_meta("content_size", bounded)
	m.set_meta("max_size", max_size)
	(parent if parent != null else ui).add_child(m)
	return m


## Safe-area insets in canvas units: position = (left, top), size = (right, bottom).
func _safe_insets() -> Rect2:
	var win := DisplayServer.window_get_size()
	var safe := DisplayServer.get_display_safe_area()
	if win.x <= 0 or safe.size.x <= 0 or not OS.has_feature("mobile"):
		return Rect2()
	var scale := _view_size().x / float(win.x)
	return Rect2(safe.position.x * scale, safe.position.y * scale,
		maxf(0.0, (win.x - safe.end.x) * scale), maxf(0.0, (win.y - safe.end.y) * scale))


func _vertical_gradient(colors: Array, offsets: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	t.width = 4
	t.height = 256
	return t


func settings_button() -> Button:
	var b := btn("⚙", func(): _open_modal("settings"), Color(1, 1, 1, 0.1), Color.WHITE, sys_font(), 20, 44, Color(0, 0, 0, 0), 10)
	b.custom_minimum_size = Vector2(44, 44)
	b.tooltip_text = "Settings"
	return b


func _open_modal(name: String) -> void:
	modal = name
	_last_frame = -1.0


func _close_modal() -> void:
	modal = ""
	_last_frame = -1.0


func portrait_image(asset: String, height: float) -> Control:
	var frame := PanelContainer.new()
	frame.set_meta("portrait_asset", asset)
	var bg := StyleBoxTexture.new()
	var g := GradientTexture2D.new()
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(GOLD, 0.18).blend(Color(INK, 0.82)), INK])
	g.gradient = grad
	g.fill_from = Vector2(0, 0)
	g.fill_to = Vector2(1, 1)
	bg.texture = g
	frame.add_theme_stylebox_override("panel", bg)
	frame.clip_contents = true
	if height > 0.0:
		frame.custom_minimum_size.y = height
	var tex := Control.new()
	var path := "res://assets/portraits/%s.png" % asset
	var texture: Texture2D = load(path) if ResourceLoader.exists(path) else null
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Keyed per bout so UI rebuilds continue the zoom instead of restarting it.
	var key := "%s:%d" % [asset, engine.get_instance_id() if engine != null else 0]
	if not _portrait_zoom_since.has(key):
		_portrait_zoom_since[key] = Time.get_ticks_msec()
	var t := 1.0 if Game.reduced_motion else \
		clampf((Time.get_ticks_msec() - int(_portrait_zoom_since[key])) / 1000.0 / PORTRAIT_ZOOM_SECONDS, 0.0, 1.0)
	var zoom := [lerpf(PORTRAIT_ZOOM_START, PORTRAIT_ZOOM_END, t)]
	if t < 1.0:
		tex.create_tween().tween_method(func(v: float):
			zoom[0] = v
			tex.queue_redraw(), zoom[0], PORTRAIT_ZOOM_END, PORTRAIT_ZOOM_SECONDS * (1.0 - t)) \
			.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tex.draw.connect(func():
		if texture != null:
			tex.draw_texture_rect(texture, portrait_draw_rect(tex.size, texture.get_size(), zoom[0]), false))
	tex.resized.connect(tex.queue_redraw)
	frame.add_child(tex)
	var outline := Panel.new()
	outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = Color(GOLD, 0.55)
	s.set_border_width_all(1)
	outline.add_theme_stylebox_override("panel", s)
	frame.add_child(outline)
	return frame


## Portrait heads sit in the top fifth of the art, slightly right of centre.
const PORTRAIT_HEAD := Rect2(0.45, 0.0, 0.3, 0.22)

## Portraits open zoomed 2x on the head and ease out to 1.5x.
const PORTRAIT_ZOOM_START := 2.0
const PORTRAIT_ZOOM_END := 1.5
const PORTRAIT_ZOOM_SECONDS := 12.0
var _portrait_zoom_since := {}

## Zoom onto the head: `zoom` times the full-width fit, never so far that the top
## fifth of the art spills out of short panels. Covers the width when it can;
## very wide, short panels centre the art instead of cropping the head.
static func portrait_draw_rect(panel_size: Vector2, texture_size: Vector2, zoom: float = PORTRAIT_ZOOM_END) -> Rect2:
	var fit := minf(panel_size.x / texture_size.x, panel_size.y / (texture_size.y * 0.30))
	var head_fit := panel_size.y / (texture_size.y * PORTRAIT_HEAD.size.y)
	var scale := minf(maxf(panel_size.x / texture_size.x, fit * zoom), head_fit)
	var drawn := texture_size * scale
	var focus := (PORTRAIT_HEAD.position.x + PORTRAIT_HEAD.size.x / 2.0) * drawn.x
	var x := (panel_size.x - drawn.x) / 2.0 if drawn.x < panel_size.x else clampf(panel_size.x / 2.0 - focus, panel_size.x - drawn.x, 0.0)
	return Rect2(Vector2(x, 0), drawn)


# MARK: - Home

func _build_home() -> void:
	var root := safe_root(25.0 if portrait else 36.0, 10.0, 12.0, null, Vector2(960, 720))
	var col := vbox()
	root.add_child(col)
	var top := hbox()
	top.add_child(lbl("✦  THE MAIN EVENT", 11, GOLD, sys_font(), 3))
	top.add_child(spacer())
	top.add_child(settings_button())
	col.add_child(top)
	col.add_child(spacer(false, 18))
	var mobile := OS.has_feature("mobile")
	var title_size := (61.0 if portrait else 76.0) if mobile else 140.0
	var title := shadowed(lbl("HAYMAKER", title_size, Color.WHITE, ring_font(true, 800 if mobile else 950)))
	if not mobile:
		title.add_theme_constant_override("outline_size", 2)
		title.add_theme_color_override("font_outline_color", Color.WHITE)
	_refs.title = title
	col.add_child(title)
	col.add_child(lbl("READ THE TELL. LAND THE COUNTER.", 10, GOLD, sys_font(), 2))
	col.add_child(spacer())
	if Game.error != "":
		col.add_child(lbl(Game.error, 14, RED, null, 0, HORIZONTAL_ALIGNMENT_CENTER, true))
	var center := CenterContainer.new()
	var buttons := vbox(10)
	fit_panel_width(buttons, 400, MENU_MAX.x, root.get_meta("content_size").x)
	var start := btn("⚡  STEP INTO THE RING                →", func():
		var first = Game.next_ladder_book()
		_begin(first if first != null else Game.ladder[0], "career"), GOLD, INK, ring_font(true), 22, 62, Color(1, 1, 1, 0.45))
	var start_style := _rounded_gradient([GOLD_LIGHT, GOLD], 8, Color(1, 1, 1, 0.45))
	start.add_theme_stylebox_override("normal", start_style)
	start.add_theme_stylebox_override("hover", start_style)
	buttons.add_child(start)
	_refs.primary = start
	buttons.add_child(btn("CAREER", func(): showing_career = true, Color(INK, 0.8), Color.WHITE, ring_font(), 20, 48, Color(GOLD, 0.5)))
	center.add_child(buttons)
	col.add_child(center)
	var footer := hbox(16)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	for t in ["◷ 3 ROUNDS", "◎ ALL SKILL", "⛨ OFFLINE"]:
		footer.add_child(lbl(t, 9, Color(1, 1, 1, 0.5), sys_font(), 1))
	col.add_child(spacer(false, 15))
	col.add_child(footer)


func _rounded_gradient(colors: Array, radius: float, border: Color) -> StyleBoxFlat:
	# Godot's StyleBoxFlat has no gradient; blend the two stops for a faithful flat fill.
	var s := box((colors[0] as Color).lerp(colors[1], 0.55), radius, border)
	s.shadow_color = Color(0, 0, 0, 0)
	return s


# MARK: - Career ladder

func _build_career() -> void:
	ui.add_child(dim(Color(INK, 0.92)))
	var root := safe_root(25.0 if portrait else 36.0, 10.0, 8.0, null, MENU_MAX)
	var col := vbox(12)
	root.add_child(col)
	var top := hbox()
	top.add_child(btn("‹  HOME", func(): showing_career = false, Color(0, 0, 0, 0), GOLD, sys_font(600), 16, 44))
	top.add_child(spacer())
	top.add_child(settings_button())
	col.add_child(top)
	if Game.error != "":
		col.add_child(lbl(Game.error, 14, RED, null, 0, HORIZONTAL_ALIGNMENT_CENTER, true))
	col.add_child(lbl("CAREER LADDER", 23, GOLD, ring_font(), 0, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(lbl("A new random order every session. Each bout is tougher than the last.", 12,
		Color(1, 1, 1, 0.7), sys_font(500), 0, HORIZONTAL_ALIGNMENT_CENTER, true))
	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := vbox(8)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	col.add_child(scroll)
	list.add_child(_progression_panel(portrait))
	if Game.ladder_complete():
		list.add_child(lbl("Career complete — all %d opponents beaten" % Game.ladder.size(), 15, Color.WHITE, sys_font(600), 0, HORIZONTAL_ALIGNMENT_LEFT, true))
		list.add_child(link("NEW LADDER", func():
			Game.new_ladder()
			_built_key = ""))
	for i in Game.ladder.size():
		var book: OpponentBook = Game.ladder[i]
		var row := hbox(8)
		var info := vbox(1)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_child(lbl("BOUT %d OF %d" % [i + 1, Game.ladder.size()], 11, GOLD, sys_font(600)))
		info.add_child(lbl(book.name, 20, Color.WHITE, ring_font(), 0, HORIZONTAL_ALIGNMENT_LEFT, true))
		var status := "History unavailable" if not Game.history_loaded else ("Beaten" if Game.is_beaten(book.id) else \
			("Ready" if Game.is_unlocked(book.id) else "Locked — beat previous opponents"))
		info.add_child(lbl(status, 12, Color.WHITE, sys_font(500)))
		var trained := Game.progression.attributes_for(book.id)
		if not Game.is_beaten(book.id) and not Attributes.is_zero(trained):
			info.add_child(lbl(Attributes.summary(trained), 11, GOLD_LIGHT, sys_font(600)))
		var b := book
		info.add_child(link("%s bio and records" % book.name, func():
			detail_book = b
			_open_modal("detail"), GOLD, 12))
		row.add_child(info)
		var start := btn("Start bout" if i == 0 else "Fight %s" % book.name.split(" ")[0], func(): _begin(b, "career"),
			Color(0, 0, 0, 0), GOLD, sys_font(600), 15, 44)
		start.disabled = not Game.is_unlocked(book.id)
		start.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(start)
		if not start.disabled and not Game.is_beaten(book.id) and not _refs.has("primary"):
			_refs.primary = start
		list.add_child(panel(box(Color(INK, 0.7), 8), row, 8))
	list.add_child(spacer(false, 6))
	list.add_child(lbl("ENDLESS SPARRING", 20, GOLD, ring_font()))
	list.add_child(lbl("Practice one opponent in seeded one-round bouts.", 12, Color.WHITE, sys_font(500)))
	for book in OpponentBook.career_roster():
		var b: OpponentBook = book
		list.add_child(link("Spar with %s" % b.name, func(): _begin(b, "sparring")))
	col.add_child(btn("RECORDS", func(): _open_modal("records"), Color(0, 0, 0, 0), GOLD, sys_font(600), 16, 44))


# MARK: - Versus dialog

func _build_versus() -> void:
	var book := Game.opponent
	ui.add_child(dim(Color(INK, 0.98)))
	var root := safe_root(24.0, 8.0 if portrait else 14.0, 8.0 if portrait else 14.0, null,
		Vector2(480, 720) if portrait else Vector2(850, 520))
	var header := hbox()
	header.add_child(lbl("THE CHALLENGER APPROACHES", 10, GOLD, sys_font(), 2))
	header.add_child(spacer())
	var close := btn("✕", session_reset, Color(0, 0, 0, 0), Color.WHITE, sys_font(), 20, 44)
	close.custom_minimum_size.x = 44
	close.tooltip_text = "Return without starting bout"
	header.add_child(close)
	header.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var intro := vbox(12 if portrait else 8)
	intro.add_child(lbl("VS", 42 if portrait else 34, GOLD, ring_font(true)))
	intro.add_child(lbl(book.name.to_upper(), 34 if portrait else 28, Color.WHITE, ring_font(), 0, HORIZONTAL_ALIGNMENT_LEFT, true))
	intro.add_child(lbl(book.style() if book.style() != "" else "CHALLENGER", 10, GOLD, sys_font(), 1.5))
	intro.add_child(lbl("“%s”" % (book.taunt() if book.taunt() != "" else "Meet me in the ring."), 19 if portrait else 16,
		Color.WHITE, sys_font(600), 0, HORIZONTAL_ALIGNMENT_LEFT, true))
	if Game.mode == "career":
		intro.add_child(_challenger_stats(Game.progression.attributes_for(book.id)))
	var fight := btn("RING THE BELL  →", begin_fight, GOLD, INK, ring_font(), 19, 54 if portrait else 48)
	_refs.primary = fight
	var size: Vector2 = root.get_meta("content_size")
	if portrait:
		var scroll := ScrollContainer.new()
		scroll.follow_focus = true
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		root.add_child(scroll)
		var col := vbox(18)
		col.custom_minimum_size = Vector2(size.x - scroll.get_v_scroll_bar().get_combined_minimum_size().x, size.y)
		scroll.add_child(col)
		col.add_child(header)
		col.add_child(portrait_image(book.asset() + "-intro", minf(size.y * 0.38, 310.0)))
		col.add_child(intro)
		col.add_child(spacer())
		col.add_child(fight)
	else:
		var center := CenterContainer.new()
		root.add_child(center)
		var row := hbox(24)
		row.custom_minimum_size = size
		center.add_child(row)
		var face := portrait_image(book.asset() + "-intro", 0.0)
		face.custom_minimum_size.x = minf(size.x * 0.43, 360.0)
		row.add_child(face)
		var col := vbox(10)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(header)
		col.add_child(spacer())
		col.add_child(intro)
		col.add_child(spacer())
		col.add_child(fight)
		row.add_child(col)


## The challenger's trained attributes for this ladder.
func _challenger_stats(a: Dictionary) -> Control:
	var col := vbox(6)
	col.add_child(lbl("CHALLENGER STATS", 11, GOLD, sys_font(), 1.5))
	var row := hbox(6)
	for attribute in Attributes.ALL:
		var value: int = a[attribute]
		var cell := vbox(2)
		cell.add_child(lbl(Attributes.TITLES[attribute].to_upper(), 10, Color.WHITE, sys_font(600)))
		cell.add_child(lbl("●".repeat(value) + "○".repeat(Attributes.MAX_POINTS - value), 12, GOLD, sys_font()))
		row.add_child(fill(cell))
	col.add_child(row)
	if Attributes.is_zero(a):
		col.add_child(lbl("Untrained — no wins on this ladder yet.", 11, Color(1, 1, 1, 0.7), sys_font(500), 0,
			HORIZONTAL_ALIGNMENT_LEFT, true))
	return panel(box(Color(INK, 0.7), 8, Color(GOLD, 0.4)), col, 8)


# MARK: - Match HUD + controls

class Bar extends Control:
	var value := 1.0
	var color := Color.WHITE
	var from_right := false
	var capsule := false
	var low_color = null

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if capsule:
			draw_style_box(_rounded(Color(1, 1, 1, 0.1), size.y / 2.0), r)
			if value > 0.0:
				draw_style_box(_rounded(color, size.y / 2.0), Rect2(0, 0, size.x * value, size.y))
			return
		var back := _rounded(Color(0, 0, 0, 0.7), 4)
		back.border_color = Color(1, 1, 1, 0.75)
		back.set_border_width_all(2)
		draw_style_box(back, r)
		var w := maxf(0.0, size.x - 6.0) * clampf(value, 0.0, 1.0)
		if w > 0.0:
			var x := size.x - 3.0 - w if from_right else 3.0
			draw_style_box(_rounded(color, 2), Rect2(x, 3, w, size.y - 6))
			draw_rect(Rect2(x + 1, 4, maxf(0.0, w - 2), (size.y - 6) * 0.3), Color(1, 1, 1, 0.18))

	static func _rounded(c: Color, radius: float) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = c
		s.set_corner_radius_all(int(radius))
		s.anti_aliasing = true
		return s


func _fighter_hud(name: String, color: Color, rival: bool, compact: bool, key: String) -> Control:
	var col := vbox(4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var align := HORIZONTAL_ALIGNMENT_LEFT if rival else HORIZONTAL_ALIGNMENT_RIGHT
	var n := lbl(name, 17 if compact else 24, Color.WHITE, ring_font(), 0, align)
	n.clip_text = true
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(n)
	var bar := Bar.new()
	bar.color = color
	bar.from_right = not rival
	bar.custom_minimum_size.y = 17 if compact else 21
	col.add_child(bar)
	var star_row := hbox(4)
	star_row.alignment = BoxContainer.ALIGNMENT_BEGIN if rival else BoxContainer.ALIGNMENT_END
	var stars := []
	for i in 3:
		var s := lbl("★", 11 if compact else 14, GOLD, sys_font())
		stars.append(s)
		star_row.add_child(s)
	col.add_child(star_row)
	_refs[key + "_bar"] = bar
	_refs[key + "_stars"] = stars
	return col


func _build_match() -> void:
	var size := _view_size()
	var roomy := size.y >= 600.0
	var wide := size.x >= 780.0
	var root := safe_root(16.0 if portrait else 24.0, 6.0 if portrait else 8.0, 8.0 if portrait else 0.0,
		null, Vector2(HUD_MAX_WIDTH, 0))
	var col := vbox()
	root.add_child(col)
	var hud := hbox(10 if portrait else 22)
	hud.add_child(_fighter_hud(Game.opponent.name.to_upper(), RED, true, portrait, "opp"))
	var mid := vbox(0)
	mid.custom_minimum_size.x = 65 if portrait else 80
	var round := lbl("ROUND 1", 15 if portrait else 18, GOLD, ring_font(), 0, HORIZONTAL_ALIGNMENT_CENTER)
	var clock := lbl("0:00", 31 if portrait else 36, Color.WHITE, ring_font(), 0, HORIZONTAL_ALIGNMENT_CENTER)
	mid.add_child(round)
	mid.add_child(clock)
	mid.add_child(lbl("OF %d" % engine.config.rounds, 8, Color(1, 1, 1, 0.5), sys_font(), 2, HORIZONTAL_ALIGNMENT_CENTER))
	hud.add_child(mid)
	hud.add_child(_fighter_hud("MACK", GREEN, false, portrait, "me"))
	col.add_child(hud)
	var bar := hbox(5)
	bar.add_child(lbl("●  MAIN EVENT", 9, Color(1, 1, 1, 0.65), sys_font(), 2))
	bar.add_child(spacer())
	var pause := btn("❚❚", func(): paused = true, Color(0, 0, 0, 0.4), Color(1, 1, 1, 0.8), sys_font(), 14, 44)
	pause.custom_minimum_size.x = 44
	pause.focus_mode = Control.FOCUS_NONE
	pause.tooltip_text = "Pause bout"
	pause.disabled = engine.is_over()
	bar.add_child(pause)
	col.add_child(bar)
	col.add_child(spacer())
	var fb_holder := CenterContainer.new()
	fb_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fb := lbl("", 32 if portrait else 38, Color.BLACK, ring_font(true))
	var fb_style := box(GOLD, 0, Color.BLACK, 3)
	fb_style.skew = Vector2(0.18, 0)
	fb_style.content_margin_left = 22
	fb_style.content_margin_right = 22
	fb_style.content_margin_top = 2
	fb_style.content_margin_bottom = 2
	fb_style.shadow_color = Color(0, 0, 0, 0.5)
	fb_style.shadow_size = 4
	fb_style.shadow_offset = Vector2(0, 5)
	var fb_panel := panel(fb_style, fb)
	fb_panel.rotation = deg_to_rad(-3)
	fb_panel.visible = false
	fb_holder.add_child(fb_panel)
	col.add_child(fb_holder)
	col.add_child(spacer())
	_refs.round = round
	_refs.clock = clock
	_refs.feedback = fb
	_refs.feedback_panel = fb_panel
	_refs.feedback_style = fb_style
	# Bottom console
	var console := vbox(12 if portrait else 6)
	var tell_row := hbox()
	var tell_col := vbox(3)
	tell_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tell := lbl("", 18, Color.WHITE, ring_font(true))
	tell_col.add_child(tell)
	var hint := lbl("", 10, Color(1, 1, 1, 0.7), sys_font(500))
	hint.visible = portrait
	tell_col.add_child(hint)
	tell_row.add_child(tell_col)
	var stat_col := vbox(3)
	var landed := lbl("Landed: 0", 11, Color.WHITE, mono_font(), 0, HORIZONTAL_ALIGNMENT_RIGHT)
	var counters := lbl("0 COUNTERS", 9, GOLD, sys_font(700), 1, HORIZONTAL_ALIGNMENT_RIGHT)
	stat_col.add_child(landed)
	stat_col.add_child(counters)
	tell_row.add_child(stat_col)
	console.add_child(tell_row)
	var stam := hbox(9)
	stam.add_child(lbl("⚡", 10, GREEN))
	stam.add_child(lbl("STAMINA", 8, Color.WHITE, sys_font(), 1.4))
	var stam_bar := Bar.new()
	stam_bar.capsule = true
	stam_bar.custom_minimum_size.y = 5
	stam_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stam_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stam.add_child(stam_bar)
	var stam_value := lbl("100", 10, Color.WHITE, mono_font())
	stam.add_child(stam_value)
	console.add_child(stam)
	_refs.tell = tell
	_refs.hint = hint
	_refs.landed = landed
	_refs.counters = counters
	_refs.stamina_bar = stam_bar
	_refs.stamina_value = stam_value
	if Game.control_style == "oneThumb":
		console.add_child(_one_thumb_controls(roomy))
	else:
		console.add_child(_two_handed_controls(roomy, wide))
	var console_style := box(Color(INK, 0.85), 14, Color(1, 1, 1, 0.13))
	console_style.set_content_margin_all(14 if portrait else 10)
	var console_panel := panel(console_style, console)
	var console_center := CenterContainer.new()
	console_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fit_panel_width(console_panel, HUD_MAX_WIDTH, HUD_MAX_WIDTH, root.get_meta("content_size").x)
	console_center.add_child(console_panel)
	col.add_child(console_center)
	# Overlays: countdown (blocking) and knockdown count (non-blocking).
	var cd := Control.new()
	cd.set_anchors_preset(Control.PRESET_FULL_RECT)
	cd.mouse_filter = Control.MOUSE_FILTER_STOP
	cd.add_child(dim(Color(0, 0, 0, 0.45)))
	var cd_center := CenterContainer.new()
	cd_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	cd_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cd_col := vbox(6)
	cd_col.add_child(lbl("GET READY", 13, Color(1, 1, 1, 0.75), sys_font(), 6, HORIZONTAL_ALIGNMENT_CENTER))
	var cd_value := shadowed(lbl("3", 220 if portrait else 170, Color.WHITE, ring_font(true), 0, HORIZONTAL_ALIGNMENT_CENTER), Color(1, 1, 1, 0.6), Vector2.ZERO, 28)
	cd_col.add_child(cd_value)
	cd_center.add_child(cd_col)
	cd.add_child(cd_center)
	ui.add_child(cd)
	_refs.countdown = cd
	_refs.countdown_value = cd_value
	var kd := vbox(0)
	kd.set_anchors_preset(Control.PRESET_TOP_WIDE)
	kd.offset_top = 112 if portrait else 84
	kd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var kd_caption := shadowed(lbl("", 12, Color(1, 1, 1, 0.85), sys_font(), 4, HORIZONTAL_ALIGNMENT_CENTER), Color.BLACK, Vector2.ZERO, 6)
	var kd_value := shadowed(lbl("3", 120 if portrait else 92, Color.WHITE, ring_font(true), 0, HORIZONTAL_ALIGNMENT_CENTER), Color.WHITE, Vector2.ZERO, 20)
	kd.add_child(kd_caption)
	kd.add_child(kd_value)
	ui.add_child(kd)
	_refs.knockdown = kd
	_refs.knockdown_caption = kd_caption
	_refs.knockdown_value = kd_value


func _control(title: String, hint: String, input: int, color: Color, height: float) -> Button:
	var b := btn("", func(): submit(input), Color(1, 1, 1, 0.08), color, ring_font(), 16, height, Color(color, 0.25), 9)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE # moves come from the input map, never from focus activation
	_stack_label(b, title, ring_font(), 16, color, hint if height > 50.0 else "", 6, Color(1, 1, 1, 0.45))
	return b


## Replaces a button's text with a centred title over a small hint line, like the SwiftUI VStack labels.
func _stack_label(b: Button, title: String, font: Font, size: float, color: Color, hint: String, hint_size: float, hint_color: Color) -> void:
	b.text = ""
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := vbox(2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := lbl(title, size, color, font, 0.0, HORIZONTAL_ALIGNMENT_CENTER)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(t)
	if hint != "":
		var h := lbl(hint, hint_size, hint_color, sys_font(900), 0.6, HORIZONTAL_ALIGNMENT_CENTER)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(h)
	center.add_child(col)
	b.add_child(center)


func _one_thumb_controls(roomy: bool) -> Control:
	var h := 67.0 if roomy else 44.0
	var row := hbox(10)
	row.add_child(_control("⛨ GUARD", "HOLD THE LINE", HM.Cmd.BLOCK, Color.WHITE, h))
	var punch := btn("", func(): pass, GOLD, INK, ring_font(true), 25 if roomy else 22, h, Color(1, 1, 1, 0.45), 9)
	_stack_label(punch, "⚡ PUNCH", ring_font(true), 25 if roomy else 22, INK, "TAP JAB · SWIPE COMBO" if roomy else "", 7, INK)
	var grad := _rounded_gradient([GOLD, ORANGE], 9, Color(1, 1, 1, 0.45))
	punch.add_theme_stylebox_override("normal", grad)
	punch.add_theme_stylebox_override("hover", grad)
	punch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	punch.focus_mode = Control.FOCUS_NONE
	punch.tooltip_text = "Jab. Swipe left for hook, up for uppercut, right for dodge, down for guard."
	punch.gui_input.connect(_on_punch_input)
	row.add_child(punch)
	row.add_child(_control("↶ DODGE", "MAKE HIM MISS", HM.Cmd.DODGE, GREEN, h))
	return row


## Tap = jab; a drag of at least 26 points resolves through ControlInput.
func _on_punch_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_swipe_start = mb.position
		elif _swipe_start != null:
			var d: Vector2 = mb.position - _swipe_start
			_swipe_start = null
			submit(HM.resolve_swipe(d.x, d.y) if d.length() >= 26.0 else HM.Cmd.JAB)


func _two_handed_controls(roomy: bool, wide: bool) -> Control:
	var h := 60.0 if roomy else 44.0
	var grid := GridContainer.new()
	grid.columns = 6 if wide else 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 7)
	grid.add_child(_control("↗ JAB", "", HM.Cmd.JAB, GOLD, h))
	grid.add_child(_control("↺ HOOK", "", HM.Cmd.HOOK, GOLD, h))
	grid.add_child(_control("↑ UPPERCUT", "", HM.Cmd.UPPERCUT, GOLD, h))
	grid.add_child(_control("⛨ GUARD", "", HM.Cmd.BLOCK, Color.WHITE, h))
	grid.add_child(_control("↶ DODGE", "", HM.Cmd.DODGE, GREEN, h))
	grid.add_child(_control("✋ PARRY", "", HM.Cmd.PARRY, Color.WHITE, h))
	return grid


func _update_match_ui() -> void:
	if engine == null or not _refs.has("clock"):
		return
	var f := engine
	(_refs.opp_bar as Bar).value = float(maxi(0, f.opponent.hp)) / float(f.config.max_hp)
	(_refs.me_bar as Bar).value = float(maxi(0, f.player.hp)) / float(f.config.max_hp)
	(_refs.opp_bar as Bar).queue_redraw()
	(_refs.me_bar as Bar).queue_redraw()
	_set_stars(_refs.opp_stars, f.player_stats.knockdowns_scored)
	_set_stars(_refs.me_stars, f.opponent_stats.knockdowns_scored)
	_refs.round.text = "ROUND %d" % f.round
	_refs.clock.text = _clock_text(f)
	var fb_visible := feedback != "" and f.total_ticks < feedback_until
	_refs.feedback_panel.visible = fb_visible
	if fb_visible:
		_refs.feedback.text = feedback
		(_refs.feedback_style as StyleBoxFlat).bg_color = feedback_color
		var p: Control = _refs.feedback_panel
		p.pivot_offset = p.size / 2.0
	_refs.tell.text = _tell_title(f)
	_refs.tell.add_theme_color_override("font_color", _tell_color(f))
	_refs.hint.text = _tell_hint(f)
	_refs.landed.text = "Landed: %d" % f.player_stats.landed
	_refs.counters.text = "%d COUNTERS" % f.player_stats.counters
	var sb: Bar = _refs.stamina_bar
	sb.value = float(f.player.stamina) / float(f.config.max_stamina)
	sb.color = RED if f.player.stamina < 20 else GREEN
	sb.queue_redraw()
	_refs.stamina_value.text = str(f.player.stamina)
	# Countdown
	var cd: Control = _refs.countdown
	cd.visible = countdown >= 0.0 and not paused and not f.is_over()
	if cd.visible:
		var value := _countdown_value()
		var progress := fmod(countdown, 0.9) / 0.9
		var slam := 1.0 - minf(1.0, progress * 3.5)
		var l: Label = _refs.countdown_value
		l.text = str(value)
		var c := _countdown_color(value)
		l.add_theme_color_override("font_color", c)
		l.add_theme_color_override("font_shadow_color", Color(c, 0.6))
		l.pivot_offset = l.size / 2.0
		l.scale = Vector2.ONE * (1.0 if reduced() else 1.0 + 1.1 * slam * slam)
		l.modulate.a = 1.0 if reduced() or progress <= 0.82 else maxf(0.25, 1.0 - (progress - 0.82) * 4.0)
	var kd: Control = _refs.knockdown
	var down := _knockdown_count() if countdown < 0.0 and not paused and not f.is_over() else {}
	kd.visible = not down.is_empty()
	if kd.visible:
		var slam := 1.0 - minf(1.0, float(down.progress) * 3.5)
		var v: Label = _refs.knockdown_value
		v.text = str(down.value)
		var c := _countdown_color(down.value)
		v.add_theme_color_override("font_color", c)
		v.add_theme_color_override("font_shadow_color", Color(c, 0.6))
		v.pivot_offset = v.size / 2.0
		v.scale = Vector2.ONE * (1.0 if reduced() else 1.0 + 0.7 * slam * slam)
		_refs.knockdown_caption.text = "GET UP!" if down.player else "%s IS DOWN" % Game.opponent.name.to_upper()


func _set_stars(stars: Array, count: int) -> void:
	for i in stars.size():
		(stars[i] as Label).add_theme_color_override("font_color", GOLD if i < count else Color(1, 1, 1, 0.18))


func _countdown_color(value: int) -> Color:
	match value:
		3: return Color.WHITE
		2: return GOLD
	return RED


func _clock_text(f: FightEngine) -> String:
	if f.phase == HM.Phase.RESTING:
		return "REST"
	var seconds := maxi(0, f.config.round_ticks - f.tick_in_round + 59) / 60
	return "%d:%02d" % [seconds / 60, seconds % 60]


func _tell_title(f: FightEngine) -> String:
	if f.phase == HM.Phase.RESTING:
		return "BACK TO YOUR CORNER"
	match f.opponent.state:
		HM.State.TELLING:
			return "FEINT — DON’T BITE" if f.opponent.current_move == HM.Move.FEINT else "%s — WINDING UP" % HM.MOVE_NAMES[f.opponent.current_move].to_upper()
		HM.State.ATTACKING: return "INCOMING!"
		HM.State.BLOCKING: return "GUARD UP"
		HM.State.DODGING: return "SLIPPING — WAIT FOR THE EXIT"
		HM.State.RECOVERING: return "OPENING — GO!"
		HM.State.KNOCKED_DOWN, HM.State.KO: return "%s IS DOWN!" % f.book.name.to_upper()
	return "READ THE NEXT MOVE"


func _tell_hint(f: FightEngine) -> String:
	if f.phase == HM.Phase.RESTING:
		return "Recover your stamina. Next round is coming."
	match f.opponent.state:
		HM.State.TELLING:
			return "Wait for the real punch." if f.opponent.current_move == HM.Move.FEINT else "Counter now, or prepare to dodge."
		HM.State.ATTACKING: return "Dodge or guard!"
		HM.State.BLOCKING: return "Swipe up. Uppercut breaks the guard."
		HM.State.DODGING: return "Save your punch. Catch the recovery."
		HM.State.RECOVERING: return "They missed their chance. Take yours."
	return "Watch the gloves. Find your rhythm."


func _tell_color(f: FightEngine) -> Color:
	if Game.colorblind_cues:
		return Color.WHITE
	if f.opponent.state == HM.State.ATTACKING:
		return RED
	return GREEN if f.opponent.state == HM.State.RECOVERING else GOLD


# MARK: - Pause

func _build_pause() -> void:
	ui.add_child(dim(Color(INK, 0.9)))
	var root := safe_root(24, 16, 16, null, MENU_MAX)
	var center := CenterContainer.new()
	var col := vbox(20)
	fit_panel_width(col, 320, MENU_MAX.x, root.get_meta("content_size").x)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(lbl("IN YOUR CORNER", 38, Color.WHITE, ring_font(true), 0, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(lbl("Take a breath. The ring can wait.", 13, Color(1, 1, 1, 0.6), sys_font(500), 0, HORIZONTAL_ALIGNMENT_CENTER))
	var resume := btn("RESUME BOUT", func():
		paused = false
		_last_frame = -1.0, GOLD, INK, ring_font(), 22, 55)
	resume.custom_minimum_size.x = 240
	_refs.primary = resume
	col.add_child(resume)
	col.add_child(btn("Settings", func(): _open_modal("settings"), Color(0, 0, 0, 0), GOLD, sys_font(600), 17, 36))
	col.add_child(btn("Leave bout", session_reset, Color(0, 0, 0, 0), Color(1, 1, 1, 0.6), sys_font(500), 15, 36))
	center.add_child(col)
	root.add_child(center)


# MARK: - Results

func _outcome_description(outcome: int) -> String:
	var name := Game.opponent.name
	match outcome:
		HM.Outcome.PLAYER_WIN_BY_KO: return "%s goes down. You own the ring." % name
		HM.Outcome.PLAYER_WIN_BY_DECISION: return "You take it on the judges’ scorecards."
		HM.Outcome.PLAYER_LOSS_BY_KO: return "%s lands the knockout. Come back swinging." % name
		HM.Outcome.PLAYER_LOSS_BY_DECISION: return "%s takes the decision. Find their rhythm." % name
	return "Even on the scorecards. Settle it in a rematch."


func _result_stat(title: String, value: String) -> Control:
	var col := vbox(3)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(lbl(value, 28, GOLD, ring_font(), 0, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(lbl(title, 8, Color(1, 1, 1, 0.6), sys_font(), 1.5, HORIZONTAL_ALIGNMENT_CENTER))
	return col


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


func _results_summary(win: bool, draw: bool, p: bool) -> Control:
	var align := HORIZONTAL_ALIGNMENT_CENTER if p else HORIZONTAL_ALIGNMENT_LEFT
	var col := vbox(19 if p else 8)
	col.add_child(lbl("BOUT RESULTS", 11, GOLD, sys_font(), 4, align))
	col.add_child(lbl("DRAW" if draw else ("VICTORY" if win else "DEFEAT"), 64 if p else 52, GOLD if win else Color.WHITE, ring_font(true), 0, align))
	col.add_child(lbl(engine.book.name, 17, Color(1, 1, 1, 0.65), sys_font(600), 0, align))
	col.add_child(lbl(_outcome_description(engine.outcome), 13, Color(1, 1, 1, 0.65), sys_font(500), 0, align, true))
	col.add_child(lbl("Seeded replay verified" if replay_matches else "Replay mismatch", 12, Color.WHITE, sys_font(500), 0, align))
	if Game.saved and Game.comparison != "":
		col.add_child(lbl("Previous personal best stands" if Game.comparison == "noImprovement" else "Personal best recorded",
			17 if p else 15, Color.WHITE, sys_font(500), 0, align))
	if Game.error != "":
		col.add_child(lbl(Game.error, 14, RED, null, 0, align, true))
		col.add_child(link("Retry saving", func():
			Game.save(engine, input_log)
			_built_key = ""))
	return col


func _bout_stats(p: bool) -> Control:
	var row := hbox(25)
	row.add_child(_result_stat("SCORE", _thousands(int(engine.player_score().points))))
	row.add_child(_result_stat("LANDED", "%d/%d" % [engine.player_stats.landed, engine.player_stats.thrown]))
	row.add_child(_result_stat("COUNTERS", str(engine.player_stats.counters)))
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 10 if p else 4)
	m.add_theme_constant_override("margin_bottom", 10 if p else 4)
	m.add_child(row)
	return m


func _sparring_stats(p: bool) -> Control:
	var runs := Game.run_bouts()
	var score := 0
	var landed := 0
	for b in runs:
		score += int(b.result.score.points)
		landed += int(b.result.playerStats.landed)
	return lbl("Run: %d rounds • score %d • landed %d" % [runs.size(), score, landed], 15 if p else 12, Color.WHITE, sys_font(500),
		0, HORIZONTAL_ALIGNMENT_CENTER if p else HORIZONTAL_ALIGNMENT_LEFT, true)


func _results_buttons(p: bool) -> Control:
	var col := vbox(12 if p else 8)
	var win := HM.is_player_win(engine.outcome)
	var advance: Button = null
	if Game.mode == "sparring":
		advance = btn("NEXT SPARRING ROUND", func():
			if Game.next_round():
				start_bout(), GOLD if win else Color(INK, 0.8), INK if win else GOLD, ring_font(true),
			23 if win else 19, (56 if p else 52) if win else 44, Color(GOLD_LIGHT, 0.8))
	elif win:
		var next_book = Game.next_ladder_book()
		if next_book != null and next_book.id != Game.opponent.id:
			var nb: OpponentBook = next_book
			advance = btn("NEXT FIGHT  →", func(): _begin(nb, "career"), GOLD, INK, ring_font(true), 23,
				56 if p else 52, Color(GOLD_LIGHT, 0.8))
	if advance != null:
		advance.disabled = not Game.saved
	var advance_primary := advance != null and win
	if advance_primary:
		col.add_child(advance)
		_refs.primary = advance
	var rematch := btn("REMATCH", func(): _begin(Game.opponent, Game.mode),
		Color(INK, 0.8) if advance_primary else GOLD, GOLD if advance_primary else INK, ring_font(true),
		19 if advance_primary else 23, 44 if advance_primary else (52 if p else 46), Color(GOLD, 0.5))
	rematch.disabled = not Game.saved
	col.add_child(rematch)
	if not advance_primary:
		_refs.primary = rematch
		if advance != null:
			col.add_child(advance)
	var home := btn("CAREER LADDER", func():
		session_reset()
		showing_career = true, Color(0, 0, 0, 0), Color.WHITE, _tracked(sys_font(), 1.4), 11, 36 if p else 30)
	home.disabled = not Game.saved
	col.add_child(home)
	return col


## Fight prize token total and Mack's fighter stats; tokens are spent here.
func _progression_panel(p: bool) -> Control:
	var align := HORIZONTAL_ALIGNMENT_CENTER if p else HORIZONTAL_ALIGNMENT_LEFT
	var col := vbox(6)
	var tokens := Game.prize_tokens()
	var head := hbox(8)
	head.add_child(fill(lbl("FIGHTER STATS", 11, GOLD, sys_font(), 1.5, align)))
	head.add_child(lbl("FIGHT PRIZE TOKENS  %d" % tokens, 11, GOLD if tokens > 0 else Color(1, 1, 1, 0.6), sys_font(),
		1.5, HORIZONTAL_ALIGNMENT_RIGHT))
	col.add_child(head)
	var row := hbox(6)
	for attribute in Attributes.ALL:
		var a: String = attribute
		var value: int = Game.progression.player[a]
		var pips := "●".repeat(value) + "○".repeat(Attributes.MAX_POINTS - value)
		var b := btn("%s  +\n%s" % [Attributes.TITLES[a].to_upper(), pips] if Game.can_spend(a) else
			"%s\n%s" % [Attributes.TITLES[a].to_upper(), pips], func():
			if Game.spend(a):
				_built_key = "", Color(INK, 0.8), Color.WHITE, sys_font(600), 12, 50, Color(GOLD, 0.6))
		b.disabled = not Game.can_spend(a)
		b.tooltip_text = "Spend a fight prize token on %s" % Attributes.TITLES[a]
		row.add_child(fill(b))
	col.add_child(row)
	var note := "Spend a token to train an attribute (max %d each)." % Attributes.MAX_POINTS if tokens > 0 \
		else "Win a new career fight to earn a fight prize token."
	col.add_child(lbl(note, 11, Color(1, 1, 1, 0.7), sys_font(500), 0, align, true))
	return panel(box(Color(INK, 0.7), 8, Color(GOLD, 0.4)), col, 8)


func _build_results() -> void:
	var win := HM.is_player_win(engine.outcome)
	if win:
		_play_win_cheer()
	var draw := engine.outcome == HM.Outcome.DRAW
	var result_asset := engine.book.asset() + "-defeated" if win else "mack-defeated"
	ui.add_child(dim(Color(INK, 0.85)))
	var root := safe_root(0, 0, 0, null, Vector2(456, 720) if portrait else Vector2(780, 520))
	var size: Vector2 = root.get_meta("content_size")
	if portrait:
		var scroll := ScrollContainer.new()
		scroll.follow_focus = true
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		root.add_child(scroll)
		var center := CenterContainer.new()
		center.custom_minimum_size.y = size.y
		center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(center)
		var col := vbox(19)
		col.custom_minimum_size.x = size.x - 56.0 - scroll.get_v_scroll_bar().get_combined_minimum_size().x
		col.add_child(_results_summary(win, draw, true))
		if not draw:
			col.add_child(portrait_image(result_asset, minf(size.y * 0.3, 240.0)))
		col.add_child(_bout_stats(true))
		if Game.mode == "sparring":
			col.add_child(_sparring_stats(true))
		elif Game.saved:
			col.add_child(_progression_panel(true))
		col.add_child(_results_buttons(true))
		var m := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + side, 28)
		m.add_child(col)
		center.add_child(m)
		return
	var center := CenterContainer.new()
	root.add_child(center)
	var row := hbox(28 if win else 32)
	row.custom_minimum_size = Vector2(size.x, size.y - 32.0)
	center.add_child(row)
	if not draw:
		var left := vbox(10)
		left.custom_minimum_size.x = minf(350.0, size.x * 0.38)
		var face := portrait_image(result_asset, 0.0)
		face.size_flags_vertical = Control.SIZE_EXPAND_FILL
		left.add_child(face)
		left.add_child(_results_buttons(false))
		row.add_child(left)
		var scroll := ScrollContainer.new()
		scroll.follow_focus = true
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var right := vbox(8)
		right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		right.add_child(_results_summary(win, draw, false))
		right.add_child(_bout_stats(false))
		if Game.mode == "sparring":
			right.add_child(_sparring_stats(false))
		elif Game.saved:
			right.add_child(_progression_panel(false))
		scroll.add_child(right)
		row.add_child(scroll)
	else:
		var summary := _results_summary(win, draw, false)
		summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		summary.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(summary)
		var actions := vbox(10)
		actions.custom_minimum_size.x = 360
		actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		actions.add_child(_bout_stats(false))
		if Game.mode == "sparring":
			actions.add_child(_sparring_stats(false))
		elif Game.saved:
			actions.add_child(_progression_panel(false))
		actions.add_child(_results_buttons(false))
		row.add_child(actions)


# MARK: - Career victory

func _build_victory() -> void:
	_play_win_cheer()
	var stats := Game.ladder_summary()
	var root := safe_root(24, 16, 16, null, Vector2(960, 720))
	var size: Vector2 = root.get_meta("content_size")
	var col := vbox(14 if portrait else 8)
	col.add_child(lbl("CAREER COMPLETE", 11, GOLD, sys_font(), 3, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(lbl("VICTORY", 48 if portrait else 36, GOLD, ring_font(true), 0, HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(lbl("Mack owns the ring. All %d opponents defeated." % Game.ladder.size(), 15 if portrait else 12, Color.WHITE,
		sys_font(500), 0, HORIZONTAL_ALIGNMENT_CENTER, true))
	col.add_child(lbl("FIGHTER STATS", 10, Color.WHITE, sys_font(), 2, HORIZONTAL_ALIGNMENT_CENTER))
	var grid := GridContainer.new()
	grid.columns = 2 if portrait else 3
	grid.add_theme_constant_override("v_separation", 12 if portrait else 8)
	grid.add_child(_result_stat("TOTAL SCORE", _thousands(stats.score)))
	grid.add_child(_result_stat("WINS / BOUTS", "%d/%d" % [stats.wins, stats.bouts]))
	grid.add_child(_result_stat("LANDED / THROWN", "%d/%d" % [stats.landed, stats.thrown]))
	grid.add_child(_result_stat("ACCURACY", ("%d%%" % (stats.landed * 100 / stats.thrown)) if stats.thrown > 0 else "—"))
	grid.add_child(_result_stat("KNOCKOUTS", str(stats.knockouts)))
	grid.add_child(_result_stat("COUNTERS", str(stats.counters)))
	col.add_child(grid)
	var end_game := btn("END GAME", func():
		if Game.new_ladder():
			session_reset()
			showing_career = false, GOLD, INK, ring_font(), 23 if portrait else 20, 48 if portrait else 44)
	col.add_child(end_game)
	_refs.primary = end_game
	var style := box(Color(INK, 0.9), 16, Color(GOLD, 0.6))
	style.set_content_margin_all(20 if portrait else 16)
	var dialog := panel(style, col)
	fit_panel_width(dialog, 420, MENU_MAX.x, size.x)
	var outer := vbox()
	outer.add_child(spacer())
	var row := hbox()
	if portrait:
		row.alignment = BoxContainer.ALIGNMENT_CENTER
	else:
		row.add_child(spacer())
	row.add_child(dialog)
	outer.add_child(row)
	root.add_child(outer)


# MARK: - Sheets (settings, records, opponent detail)

func _sheet(title: String) -> VBoxContainer:
	ui.add_child(dim(Color(0, 0, 0, 0.5)))
	var root := safe_root(0 if portrait else 24, 24 if portrait else 16, 0 if portrait else 16, null, MENU_MAX)
	var style := box(Color(0.08, 0.085, 0.1), 14)
	var mobile_sheet := portrait and OS.has_feature("mobile")
	style.corner_radius_bottom_left = 0 if mobile_sheet else 14
	style.corner_radius_bottom_right = 0 if mobile_sheet else 14
	style.set_content_margin_all(18)
	var sheet := panel(style)
	sheet.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(sheet)
	var col := vbox(12)
	sheet.add_child(col)
	var top := hbox()
	top.add_child(lbl(title, 30, Color.WHITE, sys_font(800)))
	top.add_child(spacer())
	top.add_child(btn("Done", _close_modal, Color(0, 0, 0, 0), GOLD, sys_font(700), 17, 40))
	col.add_child(top)
	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var list := vbox(14)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	return list


func _section(list: VBoxContainer, header: String) -> VBoxContainer:
	if header != "":
		list.add_child(lbl(header.to_upper(), 12, Color(1, 1, 1, 0.5), sys_font(600), 0.5))
	var inner := vbox(10)
	list.add_child(panel(box(Color(0.15, 0.155, 0.17), 10), inner, 12))
	return inner


func _row_text(parent: Control, text: String, color: Color = Color.WHITE, size: float = 15) -> void:
	parent.add_child(lbl(text, size, color, sys_font(500), 0, HORIZONTAL_ALIGNMENT_LEFT, true))


func _toggle(parent: Control, text: String, value: bool, on_change: Callable) -> void:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = value
	c.focus_mode = Control.FOCUS_ALL
	c.add_theme_stylebox_override("focus", focus_ring(8))
	c.add_theme_font_override("font", sys_font(500))
	c.add_theme_font_size_override("font_size", 15)
	c.toggled.connect(on_change)
	parent.add_child(c)


func _build_settings() -> void:
	var list := _sheet("Your corner")
	var corner := _section(list, "Your corner")
	var picker := hbox(8)
	picker.add_child(fill(lbl("Controls", 15, Color.WHITE, sys_font(500))))
	for style in [["oneThumb", "One thumb"], ["twoHanded", "Two hands"]]:
		var id: String = style[0]
		var selected := Game.control_style == id
		var b := btn(style[1], func():
			Game.control_style = id
			Game.save_settings(), Color(GOLD, 0.9) if selected else Color(1, 1, 1, 0.08), INK if selected else Color.WHITE,
			sys_font(600), 14, 32, Color(0, 0, 0, 0), 7)
		b.custom_minimum_size.x = 100
		picker.add_child(b)
	corner.add_child(picker)
	_toggle(corner, "High contrast tell cues", Game.colorblind_cues, func(v):
		Game.colorblind_cues = v
		Game.save_settings())
	_toggle(corner, "Reduced motion", Game.reduced_motion, func(v):
		Game.reduced_motion = v
		Game.save_settings())
	_toggle(corner, "Haptics", Game.haptics_enabled, func(v):
		Game.haptics_enabled = v
		Game.save_settings())
	_toggle(corner, "Music", Game.music_enabled, func(v):
		Game.music_enabled = v
		Game.save_settings()
		_update_title_music())
	var learn := _section(list, "Learn the rhythm")
	_row_text(learn, "Tap PUNCH for a jab. Swipe left for a hook, up for an uppercut, right to dodge, and down to guard. Two hands gives every move its own button.")
	_row_text(learn, "Counter during an opponent’s windup for double damage. Dodge just before the glove lands. An uppercut breaks the guard. Feints are a trap—wait for the opening.")
	if not OS.has_feature("mobile"):
		_row_text(learn, "Keyboard: Space jabs, ← hook, ↑ uppercut, → dodge, ↓ guard, Shift or P parries, Esc pauses, F11 toggles full screen. WASD mirrors the arrows, and J/K/I/L jab, hook, uppercut, and dodge.")
	_row_text(learn, "Gamepad: A jabs, X hook, Y uppercut, B dodge, LB/LT guard, RB/RT parry, Start pauses. The D-pad also throws hook, uppercut, dodge, and guard. Menus use the D-pad or stick with A to select and B to go back.")
	var about := _section(list, "")
	_row_text(about, "3D arena rendered with Godot. All fights and records stay on your device.", Color(1, 1, 1, 0.55), 13)


func _record_summary(parent: Control, book: OpponentBook) -> void:
	var hist := Game.history(book.id)
	if not Game.history_loaded:
		_row_text(parent, "History unavailable — personal best unknown")
		return
	var best_entry = Game.best(book.id)
	if best_entry == null:
		_row_text(parent, "No recorded bouts — personal best unknown")
		return
	_row_text(parent, "Best score %d • round %d • %d ticks" % [best_entry.score, best_entry.roundsCompleted, best_entry.ticksElapsed])
	_row_text(parent, "Recorded bouts %d • wins %d" % [hist.size(), Game.wins(book.id)])
	var ko = Game.fastest_ko(book.id)
	if ko != null:
		_row_text(parent, "Fastest winning KO: round %d • %d ticks" % [int(ko.roundsCompleted), int(ko.ticksElapsed)])
	else:
		_row_text(parent, "Fastest winning KO unknown — none recorded")
	var thrown := 0
	var landed := 0
	for b in hist:
		thrown += int(b.result.playerStats.thrown)
		landed += int(b.result.playerStats.landed)
	_row_text(parent, ("Hit ratio %d%%" % (landed * 100 / thrown)) if thrown > 0 else "Hit ratio unknown — no punches thrown")


func _build_records() -> void:
	var list := _sheet("Records")
	var head := _section(list, "")
	if Game.history_loaded:
		_row_text(head, "Career bouts %d" % Game.bouts.filter(func(b): return b.mode == "career").size())
	else:
		_row_text(head, Game.error if Game.error != "" else "Local records unavailable", RED)
		head.add_child(link("Retry loading records", func():
			Game.reload_history()
			_built_key = ""))
	for book in OpponentBook.career_roster():
		_record_summary(_section(list, book.name), book)


func _build_detail(book: OpponentBook) -> void:
	if book == null:
		return
	var list := _sheet(book.name)
	var s := _section(list, "")
	_row_text(s, book.bio())
	var moves := []
	for e in book.sequence:
		moves.append(HM.MOVE_NAMES[e.move])
	_row_text(s, "Pattern: " + " → ".join(moves))
	_record_summary(s, book)
