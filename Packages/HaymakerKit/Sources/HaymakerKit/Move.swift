/// Core move vocabulary for Haymaker's deterministic match engine.
///
/// `Move` is the shared action alphabet for both fighters. The
/// `PlayerInput` type below is the subset a human can issue; the
/// opponent's book reuses `Move` directly.
public enum Move: String, Sendable, Codable, CaseIterable, Hashable {
    case idle
    case jab
    case hook
    case uppercut
    case block
    case dodge
    case parry
    case feint
}

/// The set of actions a human player can issue on a tick.
///
/// Deliberately kept distinct from `Move` so the engine can reject the
/// player-only semantic (e.g. `parry` timing) independently of the shared
/// alphabet without overloading the opponent book.
public enum PlayerInput: String, Sendable, Codable, CaseIterable, Hashable {
    case none
    case jab
    case hook
    case uppercut
    case block
    case dodge
    case parry

    /// Map a player input to its matching move. `parry` maps to itself.
    public var asMove: Move {
        switch self {
        case .none: return .idle
        case .jab: return .jab
        case .hook: return .hook
        case .uppercut: return .uppercut
        case .block: return .block
        case .dodge: return .dodge
        case .parry: return .parry
        }
    }

    /// Offensive moves cost stamina and deal damage; defensive moves do not.
    public var isAttack: Bool {
        switch self {
        case .jab, .hook, .uppercut: return true
        case .none, .block, .dodge, .parry: return false
        }
    }
}
