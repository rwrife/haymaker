class_name HM
extends RefCounted
## Shared enums and helpers mirroring HaymakerKit's value types.

enum Move { IDLE, JAB, HOOK, UPPERCUT, BLOCK, DODGE, PARRY, FEINT }
enum Cmd { NONE, JAB, HOOK, UPPERCUT, BLOCK, DODGE, PARRY }
enum State { IDLE, TELLING, ATTACKING, RECOVERING, BLOCKING, DODGING, PARRYING, KNOCKED_DOWN, KO }
enum Outcome { PLAYER_WIN_BY_KO, PLAYER_WIN_BY_DECISION, DRAW, PLAYER_LOSS_BY_DECISION, PLAYER_LOSS_BY_KO }
enum Phase { FIGHTING, RESTING, OVER }
enum Who { PLAYER, OPPONENT }

const MOVE_NAMES := ["idle", "jab", "hook", "uppercut", "block", "dodge", "parry", "feint"]
const INPUT_NAMES := ["none", "jab", "hook", "uppercut", "block", "dodge", "parry"]
const OUTCOME_NAMES := ["playerWinByKO", "playerWinByDecision", "draw", "playerLossByDecision", "playerLossByKO"]


static func input_as_move(input: int) -> int:
	match input:
		Cmd.JAB: return Move.JAB
		Cmd.HOOK: return Move.HOOK
		Cmd.UPPERCUT: return Move.UPPERCUT
		Cmd.BLOCK: return Move.BLOCK
		Cmd.DODGE: return Move.DODGE
		Cmd.PARRY: return Move.PARRY
	return Move.IDLE


static func input_is_attack(input: int) -> bool:
	return input == Cmd.JAB or input == Cmd.HOOK or input == Cmd.UPPERCUT


static func is_player_win(outcome: int) -> bool:
	return outcome == Outcome.PLAYER_WIN_BY_KO or outcome == Outcome.PLAYER_WIN_BY_DECISION


static func outcome_from_name(name: String) -> int:
	return maxi(0, OUTCOME_NAMES.find(name))


## ControlInput.resolve — swipe classification for one-thumb punches.
static func resolve_swipe(dx: float, dy: float) -> int:
	if dy < -32.0 and absf(dy) > absf(dx):
		return Cmd.UPPERCUT
	if dx < -32.0:
		return Cmd.HOOK
	if dx > 32.0:
		return Cmd.DODGE
	if dy > 32.0:
		return Cmd.BLOCK
	return Cmd.JAB


## FightCountdown.knockdownValue — returns 0 when outside the window.
static func knockdown_value(elapsed_ticks: int, window_ticks: int, from: int = 3) -> int:
	if window_ticks <= 0 or elapsed_ticks < 0 or elapsed_ticks >= window_ticks:
		return 0
	var beats := maxi(1, from)
	return maxi(1, beats - (elapsed_ticks * beats) / window_ticks)


static func knockdown_step_progress(elapsed_ticks: int, window_ticks: int, from: int = 3) -> float:
	if window_ticks <= 0 or elapsed_ticks < 0 or elapsed_ticks >= window_ticks:
		return -1.0
	var scaled := float(elapsed_ticks) * float(maxi(1, from)) / float(window_ticks)
	return clampf(scaled - floorf(scaled), 0.0, 1.0)


# DamageModel
static func blocked_damage(base: int, reduction: int, guard_break: bool) -> int:
	var effective := reduction / 2 if guard_break else reduction
	return maxi(0, base - effective)


static func stamina_regen(state: int, full: int) -> int:
	match state:
		State.IDLE: return full
		State.BLOCKING, State.RECOVERING: return maxi(1, full / 2)
	return 0
