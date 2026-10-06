/// Deterministic, non-cryptographic PRNG used to drive opponent scheduling.
///
/// xorshift64* gives a fixed, portable, integer-only sequence from a single
/// 64-bit seed — the exact property the "same seed → same bout" contract
/// depends on. There is deliberately no system RNG and no time source here.
struct SeededRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        // xorshift must never be seeded with zero (it is a fixed point).
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform-ish value in `0..<bound`. `bound` must be > 0.
    mutating func next(lessThan bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return Int(next() % UInt64(bound))
    }
}
