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
		if cap.y > 0:
			check(content.size.y <= cap.y + 1.0, screen + " maximum height")
		var rect := content.get_global_rect()
		check(viewport_rect.grow(1).encloses(rect), screen + " content stays in viewport")
	check_controls(main.ui, viewport_rect)


func _run() -> void:
	game = root.get_node("Game")
	await settle()
	for window_size in SIZES:
		var canvas: Vector2i = main.ui_canvas_size(window_size, false)
		check(main.ui_canvas_size(window_size, true) == Vector2i(430, 430),
			"mobile logical canvas remains independent of physical resolution")
		check(canvas.x >= 960 and canvas.y >= 540, "compact desktop canvas minimum")
		if window_size.x >= 960 and window_size.y >= 540:
			check(canvas == window_size, "large desktop uses native pixels without upscaling")
		root.size = window_size
		main._on_resize()
		await settle()
		check(main.portrait == (window_size.y > window_size.x), "orientation follows window")
		for screen in ["home", "career", "versus", "oneThumb", "twoHanded", "pause",
				"win", "loss", "draw", "victory", "settings", "records", "detail"]:
			clear_ui()
			main.session_reset()
			game.opponent = game.ladder[0]
			main.engine = FightEngine.new(FightEngine.Config.make(3, 1200, 120), 1, game.opponent)
			match screen:
				"home": main._build_home()
				"career": main._build_career()
				"versus": main._build_versus()
				"oneThumb", "twoHanded":
					game.control_style = screen
					main._build_match()
				"pause": main._build_pause()
				"win", "loss", "draw":
					main.engine.outcome = HM.Outcome.PLAYER_WIN_BY_KO if screen == "win" else (
						HM.Outcome.PLAYER_LOSS_BY_KO if screen == "loss" else HM.Outcome.DRAW)
					main._build_results()
				"victory": main._build_victory()
				"settings": main._build_settings()
				"records": main._build_records()
				"detail": main._build_detail(game.opponent)
			await settle()
			check_layout("%s %s" % [window_size, screen])
		print("Layout journeys: ", window_size)
	print("%d layout checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
