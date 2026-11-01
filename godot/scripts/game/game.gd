extends Node
## Port of CareerSession + the app's settings. All history stays on the device:
## bouts are appended (never rewritten) as JSON lines in user://bouts.jsonl.

const BASE_SEED := 0xCAFE2026
const RECORDS_PATH := "user://bouts.jsonl"
const SETTINGS_PATH := "user://settings.cfg"

# Settings (mirrors @AppStorage in ContentView).
var control_style := "oneThumb" # or "twoHanded"
var colorblind_cues := true
var reduced_motion := false
var haptics_enabled := true
var music_enabled := true

var bouts: Array = [] # SavedBout dicts: {id, mode, runID, runRound, result}
var history_loaded := false
var error := ""
var comparison := ""
var saved := false
var opponent: OpponentBook
var ladder: Array = []
var mode := "career"
var run_id := ""
var run_round := 1
var has_unsaved_result := false
var _ladder_start := 0
var _pending = null
var _records_path := RECORDS_PATH
## This ladder's attribute progression; in memory only, reset with a new ladder.
var progression := Attributes.Progression.new()
var _progression_seed := 0


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--isolated-store"):
		_records_path = ""
	_load_settings()
	ladder = OpponentBook.authored_ladder() if _records_path == "" else OpponentBook.random_ladder()
	opponent = ladder[0]
	_progression_seed = _make_progression_seed()
	reload_history()


# MARK: - Settings

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	control_style = cfg.get_value("corner", "controlStyle", control_style)
	colorblind_cues = cfg.get_value("corner", "colorblindCues", colorblind_cues)
	reduced_motion = cfg.get_value("corner", "reducedMotion", reduced_motion)
	haptics_enabled = cfg.get_value("corner", "hapticsEnabled", haptics_enabled)
	music_enabled = cfg.get_value("corner", "musicEnabled", music_enabled)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("corner", "controlStyle", control_style)
	cfg.set_value("corner", "colorblindCues", colorblind_cues)
	cfg.set_value("corner", "reducedMotion", reduced_motion)
	cfg.set_value("corner", "hapticsEnabled", haptics_enabled)
	cfg.set_value("corner", "musicEnabled", music_enabled)
	cfg.save(SETTINGS_PATH)


func haptic(strength: float) -> void:
	if haptics_enabled and OS.has_feature("mobile"):
		Input.vibrate_handheld(int(15 + 25 * strength), strength)


# MARK: - Records

func reload_history() -> void:
	if has_unsaved_result:
		return
	var loaded: Array = []
	if _records_path != "" and FileAccess.file_exists(_records_path):
		var f := FileAccess.open(_records_path, FileAccess.READ)
		if f == null:
			error = "Local records unavailable: %s" % error_string(FileAccess.get_open_error())
			return
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line == "":
				continue
			var parsed = JSON.parse_string(line)
			if parsed is Dictionary:
				loaded.append(parsed)
	var first_load := not history_loaded
	bouts = loaded
	history_loaded = true
	if first_load:
		_ladder_start = bouts.size()
	error = ""


func _append(bout: Dictionary) -> bool:
	if _records_path == "":
		return true
	var f: FileAccess
	if FileAccess.file_exists(_records_path):
		f = FileAccess.open(_records_path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(_records_path, FileAccess.WRITE)
	if f == null:
		error = "Could not save local result: %s" % error_string(FileAccess.get_open_error())
		return false
	f.store_line(JSON.stringify(bout))
	f.close()
	return true


static func outcome_of(bout: Dictionary) -> int:
	return int(bout.result.outcome)


func wins(opponent_id: String, career_only: bool = false, source = null) -> int:
	var n := 0
	for b in (bouts if source == null else source):
		if b.result.opponentID == opponent_id and (not career_only or b.mode == "career") and HM.is_player_win(outcome_of(b)):
			n += 1
	return n


func history(opponent_id: String) -> Array:
	return bouts.filter(func(b): return b.result.opponentID == opponent_id)


func ledger() -> Array:
	return bouts.map(func(b): return {"opponentID": b.result.opponentID, "score": int(b.result.score.points),
		"outcome": outcome_of(b), "roundsCompleted": int(b.result.roundsCompleted), "ticksElapsed": int(b.result.ticksElapsed)})


func best(opponent_id: String):
	return Scoring.best_for(ledger(), opponent_id)


func fastest_ko(opponent_id: String):
	var out = null
	for b in history(opponent_id):
		if outcome_of(b) == HM.Outcome.PLAYER_WIN_BY_KO and (out == null or b.result.ticksElapsed < out.ticksElapsed):
			out = b.result
	return out


func run_bouts() -> Array:
	if run_id == "":
		return []
	return bouts.filter(func(b): return b.mode == "sparring" and b.get("runID", "") == run_id)


# MARK: - Ladder

func _ladder_records() -> Array:
	return bouts.slice(_ladder_start)


func is_beaten(id: String) -> bool:
	return wins(id, true, _ladder_records()) > 0


func is_unlocked(id: String) -> bool:
	if not history_loaded:
		return false
	for book in ladder:
		if book.id == id:
			return true
		if not is_beaten(book.id):
			return false
	return false


func ladder_complete() -> bool:
	return history_loaded and ladder.all(func(b): return is_beaten(b.id))


func can_celebrate_victory() -> bool:
	return saved and mode == "career" and ladder_complete() and not bouts.is_empty() \
		and HM.is_player_win(outcome_of(bouts[-1]))


func ladder_summary() -> Dictionary:
	var s := {"bouts": 0, "wins": 0, "score": 0, "landed": 0, "thrown": 0, "counters": 0, "knockouts": 0}
	for b in _ladder_records():
		if b.mode != "career":
			continue
		s.bouts += 1
		var o := outcome_of(b)
		if HM.is_player_win(o): s.wins += 1
		if o == HM.Outcome.PLAYER_WIN_BY_KO: s.knockouts += 1
		s.score += int(b.result.score.points)
		s.landed += int(b.result.playerStats.landed)
		s.thrown += int(b.result.playerStats.thrown)
		s.counters += int(b.result.playerStats.counters)
	return s


func next_ladder_book():
	for book in ladder:
		if is_unlocked(book.id) and not is_beaten(book.id):
			return book
	return null


func new_ladder() -> bool:
	if has_unsaved_result:
		return false
	ladder = OpponentBook.authored_ladder() if _records_path == "" else OpponentBook.random_ladder()
	_ladder_start = bouts.size()
	progression = Attributes.Progression.new()
	_progression_seed = _make_progression_seed()
	return true


## Random challenger training each ladder; the isolated store gets a fixed seed.
func _make_progression_seed() -> int:
	return 0x7EA12026 if _records_path == "" else randi()


## The book actually fought: career bouts face the challenger's trained attributes.
func fight_book() -> OpponentBook:
	return opponent.boosted(progression.attributes_for(opponent.id)) if mode == "career" else opponent


## Career bouts use the player's trained attributes; sparring stays a level field.
func fight_attributes() -> Dictionary:
	return progression.player if mode == "career" else Attributes.zero()


func prize_tokens() -> int:
	return progression.tokens


func can_spend(attribute: String) -> bool:
	return progression.can_spend(attribute)


func spend(attribute: String) -> bool:
	return progression.spend(attribute)


# MARK: - Bouts

func begin(book: OpponentBook, p_mode: String) -> bool:
	if has_unsaved_result or (p_mode == "career" and not history_loaded):
		return false
	opponent = book
	mode = p_mode
	run_id = _uuid() if p_mode == "sparring" else ""
	run_round = 1
	_reset_result()
	return true


func next_round() -> bool:
	if not saved:
		return false
	run_round += 1
	_reset_result()
	return true


func _reset_result() -> void:
	saved = false
	comparison = ""
	_pending = null


func bout_seed() -> int:
	return BASE_SEED + run_round - 1


func make_engine() -> FightEngine:
	var config := FightEngine.Config.sparring() if mode == "sparring" else FightEngine.Config.career()
	return FightEngine.new(config.boosted(fight_attributes()), bout_seed(), fight_book())


func save(engine: FightEngine, input_log: Array) -> void:
	if not engine.is_over() or saved:
		return
	has_unsaved_result = true
	if _pending == null:
		var result := FightEngine.simulate(engine.config, engine.seed, engine.book, input_log)
		var best_entry = best(engine.book.id)
		comparison = Scoring.compare(int(result.score.points), int(result.outcome), int(result.roundsCompleted),
			int(result.ticksElapsed), best_entry)
		_pending = {"id": _uuid(), "mode": mode, "runID": run_id if mode == "sparring" else null,
			"runRound": run_round if mode == "sparring" else null, "result": result}
	var won: Dictionary = _pending
	var first_ladder_win: bool = mode == "career" and HM.is_player_win(outcome_of(won)) \
		and ladder.any(func(b): return b.id == won.result.opponentID) and not is_beaten(won.result.opponentID)
	if not _append(_pending):
		return
	bouts.append(_pending)
	saved = true
	has_unsaved_result = false
	error = ""
	if first_ladder_win:
		var remaining := ladder.map(func(b): return b.id).filter(func(id): return not is_beaten(id))
		progression.record_win(remaining, _progression_seed + ladder.size() - remaining.size())


static func _uuid() -> String:
	var b := PackedByteArray()
	for i in 16:
		b.append(randi() & 0xFF)
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	var h := b.hex_encode().to_upper()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20)]
