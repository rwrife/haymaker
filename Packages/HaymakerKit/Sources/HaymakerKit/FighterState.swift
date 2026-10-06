/// Named states for a fighter's lifecycle during a bout.
///
/// Every state is reachable by name — the engine never "silently" fills
/// a field with zero; transitions are explicit and testable.
public enum FighterState: String, Sendable, Codable, Hashable {
    /// No action in progress; stamina regenerates.
    case idle
    /// Telegraphing an attack — the readable tell window.
    case telling
    /// Committed attack in flight.
    case attacking
    /// Post-attack recovery — vulnerable, cannot act.
    case recovering
    /// Guard stance — reduces incoming damage.
    case blocking
    /// Evasive dodge — avoids incoming damage entirely if timed.
    case dodging
    /// Parry window — a short, precisely-timed stance that fully avoids
    /// an incoming blow (distinct from dodge only in its tighter
    /// window; neither reflects damage in v0).
    case parrying
    /// Downed after taking a knockdown blow; countdown to rise or KO.
    case knockedDown
    /// Fight over — HP exhausted.
    case ko
}

/// Per-fighter mutable state during a bout.
///
/// All fields are integer-valued. No floats, no timers, no wall-clock.
public struct FighterStatus: Sendable, Codable, Hashable {
    public var state: FighterState
    public var hp: Int
    public var stamina: Int
    public var ticksInCurrentState: Int
    public var stateDuration: Int
    public var currentMove: Move
    public var currentDamage: Int
    public var knockdownCount: Int

    public init(
        state: FighterState = .idle,
        hp: Int = 100,
        stamina: Int = 100,
        ticksInCurrentState: Int = 0,
        stateDuration: Int = 0,
        currentMove: Move = .idle,
        currentDamage: Int = 0,
        knockdownCount: Int = 0
    ) {
        self.state = state
        self.hp = hp
        self.stamina = stamina
        self.ticksInCurrentState = ticksInCurrentState
        self.stateDuration = stateDuration
        self.currentMove = currentMove
        self.currentDamage = currentDamage
        self.knockdownCount = knockdownCount
    }
}

/// Static configuration for one fighter's damage model.
public struct DamageConfig: Sendable, Codable, Hashable {
    public let maxHP: Int
    public let maxStamina: Int
    public let staminaRegenPerTick: Int
    public let knockdownThreshold: Int
    public let knockdownTicks: Int
    public let blockDamageReduction: Int
    public let parryWindowTicks: Int

    public init(
        maxHP: Int = 100,
        maxStamina: Int = 100,
        staminaRegenPerTick: Int = 2,
        knockdownThreshold: Int = 25,
        knockdownTicks: Int = 90,
        blockDamageReduction: Int = 8,
        parryWindowTicks: Int = 6
    ) {
        self.maxHP = maxHP
        self.maxStamina = maxStamina
        self.staminaRegenPerTick = staminaRegenPerTick
        self.knockdownThreshold = knockdownThreshold
        self.knockdownTicks = knockdownTicks
        self.blockDamageReduction = blockDamageReduction
        self.parryWindowTicks = parryWindowTicks
    }

    public static let standard = DamageConfig()
}
