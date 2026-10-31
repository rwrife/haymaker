class_name Scoring
extends RefCounted
## Port of HaymakerKit Scoring / BestRecord.


static func landed_ratio(landed: int, thrown: int) -> int:
	if thrown <= 0:
		return 0
	return mini(1000, landed * 1000 / thrown)


static func bout_score(stats, round: int, ticks: int, ticks_total: int, finished: bool, by_ko: bool) -> Dictionary:
	var landed_points: int = stats.landed * 10 + landed_ratio(stats.landed, stats.thrown) / 10
	var defense_points: int = (stats.dodges_made + stats.parries_made) * 15 + stats.blocks_made * 7 + stats.counters * 10
	var damage_points: int = maxi(0, stats.damage_dealt - stats.damage_taken / 2)
	var round_points := round * 50
	var time_points := maxi(0, (ticks_total - ticks) / 20) if finished else 0
	var ko_bonus := 500 if by_ko else 0
	var finish_bonus := 200 if finished else 0
	return {
		"landedPoints": landed_points, "defensePoints": defense_points, "damagePoints": damage_points,
		"roundPoints": round_points, "timePoints": time_points, "koBonus": ko_bonus, "finishBonus": finish_bonus,
		"points": landed_points + defense_points + damage_points + round_points + time_points + ko_bonus + finish_bonus,
	}


static func finish_rank(outcome: int) -> int:
	match outcome:
		HM.Outcome.PLAYER_WIN_BY_KO: return 3
		HM.Outcome.PLAYER_WIN_BY_DECISION: return 2
		HM.Outcome.DRAW: return 1
	return 0


## Returns "firstBout", "newPersonalBest", "matchedBetterFinish" or "noImprovement".
static func compare(score: int, outcome: int, rounds_completed: int, ticks_elapsed: int, best) -> String:
	if best == null:
		return "firstBout"
	if score > best.score:
		return "newPersonalBest"
	if score == best.score and _better_finish(outcome, rounds_completed, ticks_elapsed, best):
		return "matchedBetterFinish"
	return "noImprovement"


static func _better_finish(outcome: int, rounds_completed: int, ticks_elapsed: int, best: Dictionary) -> bool:
	var incoming := finish_rank(outcome)
	var stored := finish_rank(best.outcome)
	if incoming != stored:
		return incoming > stored
	if rounds_completed != best.roundsCompleted:
		return rounds_completed < best.roundsCompleted
	return ticks_elapsed < best.ticksElapsed


## Personal best over ledger entries ({score, outcome, roundsCompleted, ticksElapsed, opponentID}).
static func best_for(entries: Array, opponent_id: String):
	var running = null
	for e in entries:
		if e.opponentID != opponent_id:
			continue
		if running == null:
			running = e
			continue
		if compare(e.score, e.outcome, e.roundsCompleted, e.ticksElapsed, running) != "noImprovement":
			running = e
	return running
