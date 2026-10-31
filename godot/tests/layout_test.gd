extends SceneTree
## Run with --isolated-store; omit --headless to exercise the rendered desktop UI.

const SIZES := [Vector2i(480, 320), Vector2i(1280, 720), Vector2i(1920, 1080),
	Vector2i(3840, 2160), Vector2i(5120, 1440), Vector2i(1080, 1920)]

var main
var game
var failures := 0
var checks := 0


func _initialize() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.set_process(false)
	_run.call_deferred()


func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", description)


func settle() -> void:
	for i in 4:
		await process_frame


func clear_ui() -> void:
	for child in main.ui.get_children():
		main.ui.remove_child(child)
		child.queue_free()
	main._refs = {}


func collect_portraits(node: Node) -> Array:
	var assets := []
	if node.has_meta("portrait_asset"):
		assets.append(node.get_meta("portrait_asset"))
	for child in node.get_children():
		assets.append_array(collect_portraits(child))
	return assets


func test_portrait_framing() -> void:
	for filename in DirAccess.get_files_at("res://assets/portraits"):
		if not filename.ends_with(".png"):
			continue
		var texture: Texture2D = load("res://assets/portraits/" + filename)
		check(texture != null, "portrait is bundled: " + filename)
		for panel_size in [Vector2(300, 340), Vector2(360, 520), Vector2(382, 300), Vector2(640, 200)]:
			var drawn: Rect2 = main.portrait_draw_rect(panel_size, texture.get_size())
			var upper := Rect2(drawn.position, Vector2(drawn.size.x, drawn.size.y * 0.3))
			check(Rect2(Vector2.ZERO, panel_size).grow(0.01).encloses(upper),
				"entire upper 30% remains visible: " + filename)
			check(drawn.position.x >= -0.01 and drawn.end.x <= panel_size.x + 0.01,
				"no sideways portrait clipping: " + filename)
func winning_bout(book: OpponentBook) -> Dictionary:
	return {"mode": "career", "result": {"opponentID": book.id, "outcome": HM.Outcome.PLAYER_WIN_BY_KO,
		"score": {"points": 2691}, "roundsCompleted": 1, "ticksElapsed": 500,
		"playerStats": {"landed": 9, "thrown": 9, "counters": 4}}}


func check_controls(node: Node, viewport_rect: Rect2, in_scroll: bool = false) -> void:
	if node is Control and node.has_meta("width_min"):
		check(node.size.x >= node.get_meta("width_min") - 1.0, "panel meets 30% width minimum")
		check(node.size.x <= node.get_meta("width_max") + 1.0, "panel respects hard pixel maximum")
	if node is ScrollContainer:
		in_scroll = true
		var scroll := node as ScrollContainer
		check(scroll.get_child(0).size.x <= scroll.size.x + 1.0, "scroll content fits horizontally")
	if node is BaseButton:
		var button := node as BaseButton
		var rect := button.get_global_rect()
		check(rect.position.x >= -1.0 and rect.end.x <= viewport_rect.end.x + 1.0,
			"button fits viewport horizontally: " + button.text)
		if not in_scroll:
			check(rect.position.y >= -1.0 and rect.end.y <= viewport_rect.end.y + 1.0,
				"button fits viewport vertically: " + button.text)
	for child in node.get_children():
		check_controls(child, viewport_rect, in_scroll)


func check_layout(screen: String) -> void:
	var viewport_rect := root.get_visible_rect()
	for child in main.ui.get_children():
		if not child.has_meta("max_size"):
			continue
		var cap: Vector2 = child.get_meta("max_size")
		var content: Control = child.get_child(0)
		if cap.x > 0:
			check(content.size.x <= cap.x + 1.0, screen + " maximum width")
			check(content.size.x >= minf(viewport_rect.size.x * 0.3, cap.x) - 1.0,
				screen + " 30% width minimum with cap precedence")
			check(content.size.x * content.get_global_transform_with_canvas().get_scale().x <= cap.x * 2.0 + 1.0,
				screen + " absolute physical pixel ceiling")
		if cap.y > 0:
			check(content.size.y <= cap.y + 1.0, screen + " maximum height")
		var rect := content.get_global_rect()
		check(viewport_rect.grow(1).encloses(rect), screen + " content stays in viewport")
	check_controls(main.ui, viewport_rect)


func _run() -> void:
	game = root.get_node("Game")
	await settle()
	main.set_process(false)
	test_portrait_framing()
	for window_size in SIZES:
		var canvas: Vector2i = main.ui_canvas_size(window_size, false)
		check(main.ui_canvas_size(window_size, true) == Vector2i(430, 430),
			"mobile logical canvas remains independent of physical resolution")
		check(canvas.x >= 960 and canvas.y >= 540, "compact desktop canvas minimum")
		var scale: float = main.desktop_ui_scale(window_size)
		check(scale <= 2.0, "desktop zoom has a hard maximum")
		if window_size == Vector2i(3840, 2160):
			check(scale == 2.0 and canvas == Vector2i(1920, 1080), "4K uses readable 2x UI zoom")
		root.size = window_size
		main._on_resize()
		await settle()
		check(main.portrait == (window_size.y > window_size.x), "orientation follows window")
		for screen in ["home", "career", "versus", "oneThumb", "twoHanded", "pause",
				"win", "loss", "draw", "sparring", "sparringLoss", "victory", "settings", "records", "detail"]:
			clear_ui()
			main.session_reset()
			game.opponent = game.ladder[0]
			game.mode = "career"
			game.bouts = []
			game._ladder_start = 0
			game.saved = true
			main.replay_matches = true
			main.engine = FightEngine.new(FightEngine.Config.make(3, 1200, 120), 1, game.opponent)
			match screen:
				"home": main._build_home()
				"career": main._build_career()
				"versus": main._build_versus()
				"oneThumb", "twoHanded":
					game.control_style = screen
					main._build_match()
				"pause": main._build_pause()
				"win", "loss", "draw", "sparring", "sparringLoss":
					main.engine.outcome = HM.Outcome.PLAYER_WIN_BY_KO if screen in ["win", "sparring"] else (
						HM.Outcome.PLAYER_LOSS_BY_KO if screen in ["loss", "sparringLoss"] else HM.Outcome.DRAW)
					main.engine.phase = HM.Phase.OVER
					if screen == "win":
						game.bouts.append(winning_bout(game.opponent))
					elif screen in ["sparring", "sparringLoss"]:
						game.mode = "sparring"
					main._build_results()
				"victory": main._build_victory()
				"settings": main._build_settings()
				"records": main._build_records()
				"detail": main._build_detail(game.opponent)
			await settle()
			check_layout("%s %s" % [window_size, screen])
			if screen == "home":
				check(main._refs.title.get_theme_font_size("font_size") == 140, "larger desktop title")
				check(main._refs.title.get_theme_font("font").font_weight == 950, "heavier desktop title")
			if screen in ["win", "sparring"]:
				var advance: Button = main._refs.primary
				check(advance.text.begins_with("NEXT"), "advance is primary result action")
				check(advance.get_index() == 0, "advance appears before rematch")
				var rematch: Button = advance.get_parent().get_child(1)
				check(rematch.text == "REMATCH" and advance.custom_minimum_size.y > rematch.custom_minimum_size.y,
					"rematch is smaller secondary action")
			if screen == "win":
				check(collect_portraits(main.ui) == [game.opponent.asset() + "-defeated"], "win shows defeated opponent")
			elif screen == "loss":
				check(collect_portraits(main.ui) == ["mack-defeated"], "loss shows defeated Mack")
			elif screen == "draw":
				check(collect_portraits(main.ui).is_empty(), "draw does not imply a defeated fighter")
			if screen in ["loss", "draw", "sparringLoss"]:
				check(main._refs.primary.text == "REMATCH", "loss/draw keeps Rematch primary")
		game.bouts = []
		for book in game.ladder:
			game.opponent = book
			main.engine = FightEngine.new(FightEngine.Config.make(3, 1200, 120), 1, book)
			main.engine.phase = HM.Phase.OVER
			main.engine.outcome = HM.Outcome.PLAYER_WIN_BY_KO
			game.bouts.append(winning_bout(book))
			for screen in ["versus", "win", "detail"]:
				clear_ui()
				if screen == "versus":
					main._build_versus()
				elif screen == "win":
					main._build_results()
				else:
					main._build_detail(book)
				await settle()
				check_layout("%s %s %s" % [window_size, book.id, screen])
		print("Layout journeys: ", window_size)
	print("%d layout checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
