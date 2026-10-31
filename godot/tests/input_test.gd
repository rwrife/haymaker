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
	print("%d input failures" % fails)
	quit(1 if fails > 0 else 0)
