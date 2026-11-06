class_name Attributes
extends RefCounted
## Fighter attributes, their boosts and career progression. Attributes are
## dictionaries {power, dexterity, speed}. Integer-only maths keeps boosted
## bouts deterministic and replayable.

const MAX_POINTS := 5
## Matchups can push an attribute past the trainable cap, up to this.
const MAX_EFFECTIVE := 7
const ALL := ["power", "dexterity", "speed"]
const TITLES := {"power": "Power", "dexterity": "Dexterity", "speed": "Speed"}
## Rock–paper–scissors: each attribute beats the one it maps to. Speed out-tempos
## Power's slow, heavy shots; Power breaks through Dexterity's guard and slips;
## Dexterity's tight guard and stamina outlast Speed's flurries.
const BEATS := {"speed": "power", "power": "dexterity", "dexterity": "speed"}


static func make(power: int = 0, dexterity: int = 0, speed: int = 0) -> Dictionary:
	return {"power": clampi(power, 0, MAX_POINTS), "dexterity": clampi(dexterity, 0, MAX_POINTS), "speed": clampi(speed, 0, MAX_POINTS)}


static func zero() -> Dictionary:
	return make()


static func total(a: Dictionary) -> int:
	return a.power + a.dexterity + a.speed


static func is_zero(a: Dictionary) -> bool:
	return total(a) == 0


static func can_raise(a: Dictionary, attribute: String) -> bool:
	return a[attribute] < MAX_POINTS


static func open(a: Dictionary) -> Array:
	return ALL.filter(func(k): return can_raise(a, k))


static func summary(a: Dictionary) -> String:
	return "PWR %d · DEX %d · SPD %d" % [a.power, a.dexterity, a.speed]


## The attribute that beats `attribute`.
static func countered_by(attribute: String) -> String:
	for k in BEATS:
		if BEATS[k] == attribute:
			return k
	return ""


## Signed shift for one attribute: half (rounded away from zero) of the points
## it beats minus the points that beat it, limited by the points invested.
static func _edge(points: int, prey: int, threat: int) -> int:
	var delta := mini(points, prey) - mini(points, threat)
	return (delta + 1) / 2 if delta >= 0 else -((1 - delta) / 2)


## Effective attributes after the rock–paper–scissors matchup. Each attribute
## gains from the opponent's points in the attribute it beats and loses to their
## points in the attribute that beats it. Zero is an identity and mirrored
## builds shift both fighters alike.
static func matchup(player: Dictionary, opponent: Dictionary) -> Dictionary:
	var p := {}
	var o := {}
	for a in ALL:
		var prey: String = BEATS[a]
		var threat := countered_by(a)
		p[a] = clampi(player[a] + _edge(player[a], opponent[prey], opponent[threat]), 0, MAX_EFFECTIVE)
		o[a] = clampi(opponent[a] + _edge(opponent[a], player[prey], player[threat]), 0, MAX_EFFECTIVE)
	return {"player": p, "opponent": o}


## Net matchup edge for the player: positive favors the player.
static func edge(player: Dictionary, opponent: Dictionary) -> int:
	var m := matchup(player, opponent)
	return (total(m.player) - total(player)) - (total(m.opponent) - total(opponent))


## Short notes naming each attribute clash in this matchup, player first.
static func clashes(player: Dictionary, opponent: Dictionary) -> Array:
	var out := []
	for a in ALL:
		var prey: String = BEATS[a]
		if player[a] > 0 and opponent[prey] > 0:
			out.append("Your %s beats their %s" % [TITLES[a], TITLES[prey]])
	for a in ALL:
		var prey: String = BEATS[a]
		if opponent[a] > 0 and player[prey] > 0:
			out.append("Their %s beats your %s" % [TITLES[a], TITLES[prey]])
	return out


## Integer `value * numerator / denominator`, rounded half up.
static func scaled_ticks(value: int, numerator: int, denominator: int) -> int:
	return (value * numerator + denominator / 2) / denominator


## Player boosts: power +10% damage, speed -8% windup/recover, dexterity -8%
## stamina cost and +10% dodge/parry/block-hold windows per point, plus 1
## armor per two points.
static func boost_config(c: FightEngine.Config, a: Dictionary) -> FightEngine.Config:
	var out := c.copy()
	var reach: int = 10 + a.dexterity
	var quick: int = 100 - 8 * a.speed
	var thrift: int = 100 - 8 * a.dexterity
	out.armor = c.armor + a.dexterity / 2
	out.block_hold_ticks = scaled_ticks(c.block_hold_ticks, reach, 10)
	out.dodge_ticks = scaled_ticks(c.dodge_ticks, reach, 10)
	out.parry_window = scaled_ticks(c.parry_window, reach, 10)
	var table := {}
	for move in c.player_table:
		var t: Dictionary = c.player_table[move]
		table[move] = {
			"windup": maxi(1, scaled_ticks(t.windup, quick, 100)),
			"recover": maxi(1, scaled_ticks(t.recover, quick, 100)),
			"stamina": 0 if t.stamina == 0 else maxi(1, scaled_ticks(t.stamina, thrift, 100)),
			"damage": scaled_ticks(t.damage, 10 + a.power, 10),
		}
	out.player_table = table
	return out


## Opponent boosts: power +10% damage, speed -6% tells/recoveries (floored)
## and -8% idle gaps, dexterity +15% guard/dodge holds, -8% stamina cost and
## +10% punish per point, plus 1 armor per two points.
static func boost_book(book: OpponentBook, a: Dictionary) -> OpponentBook:
	if is_zero(a):
		return book
	var quick: int = 100 - 6 * a.speed
	var patience: int = 100 - 8 * a.speed
	var thrift: int = 100 - 8 * a.dexterity
	var entries := []
	for e in book.sequence:
		var defensive: bool = e.move == HM.Move.BLOCK or e.move == HM.Move.DODGE
		entries.append(OpponentBook.entry(e.move,
			maxi(scaled_ticks(e.tell, quick, 100), mini(e.tell, OpponentBook.MIN_TELL)),
			scaled_ticks(e.impact, 20 + 3 * a.dexterity, 20) if defensive else e.impact,
			maxi(scaled_ticks(e.recover, quick, 100), mini(e.recover, OpponentBook.MIN_RECOVER)),
			0 if e.stamina == 0 else maxi(1, scaled_ticks(e.stamina, thrift, 100)),
			0 if e.damage == 0 else maxi(1, scaled_ticks(e.damage, 10 + a.power, 10))))
	return OpponentBook.new(book.id, book.name, entries,
		scaled_ticks(book.min_gap, patience, 100), scaled_ticks(book.gap_spread, patience, 100),
		book.max_hp, book.guard, book.punish + 10 * a.dexterity, book.armor + a.dexterity / 2)


## One career ladder's progression.
class Progression:
	var player := Attributes.zero()
	## Fight prize tokens waiting to be spent on the player's attributes.
	var tokens := 0
	var opponents := {}

	func attributes_for(opponent_id: String) -> Dictionary:
		return opponents.get(opponent_id, Attributes.zero())

	## Awards the post-win prizes: one fight prize token for the player, one point trained into
	## a seeded pick for every remaining challenger. The final win awards none.
	func record_win(remaining: Array, seed: int) -> Dictionary:
		var trained := {}
		if remaining.is_empty():
			return trained
		if Attributes.total(player) + tokens < Attributes.MAX_POINTS * Attributes.ALL.size():
			tokens += 1
		var rng := SeededRNG.new(seed ^ 0x7A1A000000000000)
		for id in remaining:
			var a: Dictionary = attributes_for(id).duplicate()
			var open := Attributes.open(a)
			if open.is_empty():
				continue
			var pick: String = open[rng.next_less_than(open.size())]
			a[pick] += 1
			opponents[id] = a
			trained[id] = pick
		return trained

	func can_spend(attribute: String) -> bool:
		return tokens > 0 and Attributes.can_raise(player, attribute)

	func spend(attribute: String) -> bool:
		if not can_spend(attribute):
			return false
		player = player.duplicate()
		player[attribute] += 1
		tokens -= 1
		return true
