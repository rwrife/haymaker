class_name OpponentBook
extends RefCounted
## Port of HaymakerKit OpponentBook / PatternEntry / CharacterRoster / Ladder.
## Pattern entries are dictionaries: {move, tell, impact, recover, stamina, damage}.

const MIN_TELL := 18
const MIN_RECOVER := 8

var id: String
var name: String
var sequence: Array
var min_gap: int
var gap_spread: int


func _init(p_id: String, p_name: String, p_sequence: Array, p_min_gap: int = 6, p_gap_spread: int = 8) -> void:
	assert(not p_sequence.is_empty())
	id = p_id
	name = p_name
	sequence = p_sequence
	min_gap = p_min_gap
	gap_spread = p_gap_spread


static func entry(move: int, tell: int, impact: int, recover: int, stamina: int, damage: int) -> Dictionary:
	return {"move": move, "tell": tell, "impact": impact, "recover": recover, "stamina": stamina, "damage": damage}


static func _rows(rows: Array) -> Array:
	var out := []
	for r in rows:
		out.append(entry(r[0], r[1], r[2], r[3], r[4], r[5]))
	return out


const J := HM.Move.JAB
const H := HM.Move.HOOK
const U := HM.Move.UPPERCUT
const B := HM.Move.BLOCK
const D := HM.Move.DODGE
const F := HM.Move.FEINT


static func goldie() -> OpponentBook:
	return OpponentBook.new("goldie", "Goldie Voltage", _rows([[J, 48, 12, 24, 4, 6], [J, 30, 10, 24, 4, 6], [H, 54, 16, 64, 9, 12]]), 14, 10)


static func nico() -> OpponentBook:
	return OpponentBook.new("nico", "Nico “Nightshift” Navarro", _rows([[B, 36, 60, 20, 4, 0], [J, 34, 10, 32, 4, 9], [F, 38, 0, 20, 2, 0], [U, 48, 14, 48, 10, 17]]), 40, 18)


static func atlas() -> OpponentBook:
	return OpponentBook.new("atlas", "Atlas “Undertow” Reed", _rows([[H, 64, 18, 48, 10, 18], [H, 52, 16, 44, 10, 18], [B, 40, 48, 28, 5, 0], [U, 66, 20, 60, 14, 23]]), 20, 8)


static func vera() -> OpponentBook:
	return OpponentBook.new("vera", "Vera Velvet", _rows([[B, 28, 78, 18, 5, 0], [J, 28, 10, 24, 4, 11], [B, 30, 54, 20, 5, 0], [U, 40, 12, 38, 10, 19]]), 24, 12)


static func duke() -> OpponentBook:
	return OpponentBook.new("duke", "Duke Doubletake", _rows([[F, 36, 0, 14, 2, 0], [H, 38, 12, 34, 8, 16], [F, 48, 0, 18, 2, 0], [J, 24, 8, 24, 4, 10], [U, 44, 14, 44, 11, 20]]), 18, 30)


static func sylvie() -> OpponentBook:
	return OpponentBook.new("sylvie", "Sylvie “Slipstream” Sloane", _rows([[D, 28, 24, 16, 4, 0], [J, 24, 8, 22, 4, 11], [D, 24, 20, 16, 4, 0], [H, 32, 10, 38, 8, 17]]), 16, 10)


static func cassian() -> OpponentBook:
	return OpponentBook.new("cassian", "Cassian “Saint” Sterling", _rows([[J, 28, 10, 24, 4, 12], [B, 26, 54, 20, 5, 0], [F, 30, 0, 16, 2, 0], [H, 36, 12, 32, 8, 18], [U, 42, 14, 40, 11, 21]]), 22, 8)


static func jaison() -> OpponentBook:
	return OpponentBook.new("jaison", "Jaison “Black Tie” Mercer", _rows([[B, 44, 48, 24, 4, 0], [J, 36, 10, 24, 4, 10], [D, 28, 24, 16, 4, 0], [J, 24, 8, 20, 4, 12], [H, 30, 10, 16, 8, 16], [U, 28, 12, 44, 11, 22]]), 14, 6)


static func hunter() -> OpponentBook:
	return OpponentBook.new("hunter", "Hunter “Redline” Mercer", _rows([[J, 26, 8, 12, 4, 11], [J, 18, 8, 12, 4, 12], [H, 30, 12, 16, 8, 17], [J, 24, 12, 60, 10, 22]]), 8, 12)


static func baxter() -> OpponentBook:
	return OpponentBook.new("baxter", "Bruiser Baxter", _rows([[J, 42, 12, 32, 5, 8], [H, 54, 16, 46, 10, 16], [F, 32, 0, 16, 3, 0], [J, 34, 10, 26, 5, 8], [B, 28, 65, 30, 6, 0], [U, 60, 18, 54, 14, 22]]), 32, 24)


static func twitch() -> OpponentBook:
	return OpponentBook.new("twitch", "Twitch", _rows([[J, 10, 4, 10, 4, 6], [J, 10, 4, 10, 4, 6], [F, 6, 0, 8, 3, 0], [B, 6, 18, 8, 6, 0], [J, 9, 4, 12, 4, 6], [H, 14, 6, 16, 8, 12]]), 6, 10)


static func anvil() -> OpponentBook:
	return OpponentBook.new("anvil", "Anvil", _rows([[H, 12, 6, 18, 9, 14], [F, 5, 0, 10, 4, 0], [J, 8, 4, 10, 5, 7], [U, 16, 8, 24, 14, 22], [H, 11, 6, 18, 9, 14], [J, 8, 4, 10, 5, 7]]), 4, 8)


static func career_roster() -> Array:
	return [goldie(), nico(), atlas(), vera(), duke(), sylvie(), cassian(), jaison(), hunter(), baxter()]


static func by_id(book_id: String) -> OpponentBook:
	for b in career_roster():
		if b.id == book_id:
			return b
	return goldie()


func scaled(difficulty: float) -> OpponentBook:
	var d := clampf(difficulty, 0.0, 1.0)
	var pace := 1.35 - 0.60 * d
	var patience := 1.9 - 1.35 * d
	var power := 0.7 + 0.55 * d
	var entries := []
	for e in sequence:
		entries.append(entry(e.move, _ticks(e.tell, pace, MIN_TELL), e.impact, _ticks(e.recover, pace, MIN_RECOVER),
			e.stamina, 0 if e.damage == 0 else maxi(int(roundf(float(e.damage) * power)), 1)))
	return OpponentBook.new(id, name, entries, _ticks(min_gap, patience, 0), _ticks(gap_spread, patience, 0))


static func _ticks(value: int, factor: float, floor_value: int) -> int:
	return maxi(int(roundf(float(value) * factor)), mini(value, floor_value))


static func ladder_stages(order: Array) -> Array:
	var last := maxi(order.size() - 1, 1)
	var out := []
	for i in order.size():
		out.append(order[i].scaled(float(i) / float(last)))
	return out


static func authored_ladder() -> Array:
	return ladder_stages(career_roster())


static func random_ladder() -> Array:
	var contenders := career_roster()
	contenders.pop_back()
	contenders.shuffle()
	contenders.append(baxter())
	return ladder_stages(contenders)


# Presentation profile (CharacterProfile)
func asset() -> String:
	return "bruiser" if id == "baxter" else id


func bio() -> String:
	return PROFILES.get(id, ["", "", ""])[0]


func style() -> String:
	return PROFILES.get(id, ["", "", ""])[1]


func taunt() -> String:
	return PROFILES.get(id, ["", "", ""])[2]


const PROFILES := {
	"goldie": ["An arcade repair whiz boxing to fund a traveling arcade. Goldie turns every bout into a high-score chase, but her relentless combinations leave openings when she overcommits.",
		"COMBINATION PRESSURE", "Hope you brought spare change. This combo doesn't take refunds!"],
	"nico": ["A night-bus driver who notices every hesitation. Nico saves his energy, lets impatient fighters commit, and answers with precise counters. He's fighting for fewer shifts and more time in the gym.",
		"PATIENT COUNTERPUNCHER", "Last bus home leaves in three rounds. I'll make sure you catch it."],
	"atlas": ["A harbor salvage diver carrying a champion father's complicated legacy. Atlas brings patient heavyweight pressure and deliberate hooks. Move around his power instead of trading with it.",
		"HEAVYWEIGHT PRESSURE", "I've lifted shipwrecks lighter than that guard. Let's see if it floats."],
	"vera": ["After years preparing champions behind the scenes, Vera is claiming her own spotlight in her late forties. Her disciplined high guard and exact counters make careless attacks expensive.",
		"HIGH GUARD • EXACT COUNTERS", "I used to charge champions for this lesson. You're getting the full price."],
	"duke": ["A former carnival performer building a new stage for his old troupe. Duke's feints and shifting rhythms turn the obvious threat into a distraction. Watch his shoulders, not the advertised glove.",
		"FEINTS • MISDIRECTION", "Watch this glove. The other one's just here for the surprise ending."],
	"sylvie": ["A former speed skater finding a new competitive identity. Sylvie slips away and fires quick counters, but her favorite exits can be read. Patience beats a race to every exchange.",
		"EVASION • QUICK COUNTERS", "You brought boxing shoes to a speed-skating problem. Cute."],
	"cassian": ["A former titleholder whose victory saved his neighborhood gym. Behind the flawless public image, Cassian is an exacting contender testing balance, timing, and what happens when a perfect plan breaks.",
		"TIMING • LAYERED DEFENSE", "I polished my footwork for this. Please don't scuff the masterpiece."],
	"jaison": ["Jaison Elias Mercer grew up above Mercer & Son, learning that confidence comes from preparation. A charity exhibition revealed his counterpunching talent and earned Vera Velvet's mentorship. Quiet, dryly funny and meticulous, he repairs his waistcoat after every bout and intends to be announced as champion. The Final Fitting pairs a short body hook with a sharp uppercut.",
		"PRECISE COUNTERS • THE FINAL FITTING", "Let’s get this sorted."],
	"hunter": ["Hunter Rowan Mercer learned to box holding pads for his brother Jaison after closing Mercer & Son. Easygoing outside the ring and fiercely competitive inside it, Redline wants a name of his own. He fights in torn-sleeve black formalwear and the crimson tie from his first night in Jaison’s corner. Closing Time drives two quick jabs into a body hook and stepping right. His relentless, shifting pressure leaves him open to a patient counter. Both brothers want the championship; neither has settled what happens if they get there together.",
		"RELENTLESS PRESSURE • CLOSING TIME", "Try keeping up."],
	"baxter": ["The theatrical reigning champion was once a generous small-gym mentor. Baxter protects his reputation with heavyweight pressure, big windups, feints, guarded pauses and punishing counters. Earn his corner.",
		"FINAL BOSS • COMPLETE PRESSURE", "You want this corner? Earn it. And try not to dent the spotlight."],
}
