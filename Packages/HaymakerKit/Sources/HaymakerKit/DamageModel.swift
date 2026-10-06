/// The stamina + damage state machine rules, extracted as pure statics.
///
/// `FightEngine` owns the mutable fighter states; `DamageModel` owns the
/// *rules* that move between them. Every transition is decided by a
/// named rule here — the engine never invents values inline, which is
/// what keeps knockdown/KO behavior readable and testable in isolation.
public enum DamageModel {
    /// Damage actually applied when a blow of `base` lands on a
    /// blocking defender. `guardBreak` (uppercuts) halves the guard's
    /// reduction. Never below zero.
    public static func blockedDamage(base: Int, reduction: Int, guardBreak: Bool) -> Int {
        let effective = guardBreak ? reduction / 2 : reduction
        return max(0, base - effective)
    }

    /// Counter multiplier for a punch landing inside a committed tell.
    public static func counterDamage(base: Int, multiplier: Int) -> Int {
        base * multiplier
    }

    /// Does this landed blow score a knockdown (heavy single hit)?
    public static func isKnockdownBlow(damage: Int, threshold: Int) -> Bool {
        damage >= threshold
    }

    /// Does this blow end the fighter outright (HP floored to zero)?
    public static func isOutOfCold(hpAfterBlow: Int) -> Bool {
        hpAfterBlow <= 0
    }

    /// Three-knockdown rule: does knockdown number `count` end the fight?
    public static func isThreeCountKO(knockdownCount: Int, maxKnockdowns: Int) -> Bool {
        knockdownCount >= maxKnockdowns
    }

    /// HP a fighter gets back when answering the count (floor — they
    /// never come back worse than the blow left them, and never below
    /// the revival floor).
    public static func revivalHP(current: Int, floor: Int) -> Int {
        max(current, floor)
    }

    /// Stamina economy per state: full regen idle, half regen while
    /// guarding or recovering, none while committed to an action.
    public static func staminaRegen(state: FighterState, full: Int) -> Int {
        switch state {
        case .idle: return full
        case .blocking, .recovering: return max(1, full / 2)
        default: return 0
        }
    }
}
