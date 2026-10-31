class_name SeededRNG
extends RefCounted
## xorshift64* — bit-exact port of HaymakerKit's SeededRNG.
## GDScript ints are signed 64-bit; the helpers below emulate UInt64 maths.

const DEFAULT_SEED := -7046029254386353131 # 0x9E3779B97F4A7C15
const MULTIPLIER := 0x2545F4914F6CDD1D

var state: int


func _init(seed: int) -> void:
	state = DEFAULT_SEED if seed == 0 else seed


static func lsr(x: int, n: int) -> int:
	if n <= 0:
		return x
	return (x >> n) & ((1 << (64 - n)) - 1)


## Unsigned 64-bit `x % bound` for a positive bound.
static func umod(x: int, bound: int) -> int:
	if x >= 0:
		return x % bound
	var half := lsr(x, 1)
	return ((half % bound) * 2 + (x & 1)) % bound


func next() -> int:
	state ^= lsr(state, 12)
	state ^= state << 25
	state ^= lsr(state, 27)
	return state * MULTIPLIER


func next_less_than(bound: int) -> int:
	assert(bound > 0)
	return umod(next(), bound)
