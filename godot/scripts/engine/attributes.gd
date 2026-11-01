class_name Attributes
extends RefCounted
## Fighter attributes, their boosts and career progression. Attributes are
## dictionaries {power, dexterity, speed}. Integer-only maths keeps boosted
## bouts deterministic and replayable.

const MAX_POINTS := 5
const ALL := ["power", "dexterity", "speed"]
const TITLES := {"power": "Power", "dexterity": "Dexterity", "speed": "Speed"}


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


## Integer `value * numerator / denominator`, rounded half up.
static func scaled_ticks(value: int, numerator: int, denominator: int) -> int:
	return (value * numerator + denominator / 2) / denominator


## Player boosts: power +10% damage, speed -8% windup/recover, dexterity -8%
## stamina cost and +10% dodge/parry/block-hold windows, per point.
static func boost_config(c: FightEngine.Config, a: Dictionary) -> FightEngine.Config:
	var out := c.copy()
	var reach: int = 10 + a.dexterity
	var quick: int = 100 - 8 * a.speed
	var thrift: int = 100 - 8 * a.dexterity
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
## and -8% idle gaps, dexterity +15% guard/dodge holds and -8% stamina cost.
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
		scaled_ticks(book.min_gap, patience, 100), scaled_ticks(book.gap_spread, patience, 100))


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
