/// HaymakerKit — pure-domain match engine for Haymaker.
///
/// Issue #1 (M1) ships only the skeleton namespace so CI has a real,
/// testable target. Issue #2 (M2) lands the PatternBook scheduler,
/// FightEngine round flow, DamageModel stamina/KO state machine, and
/// deterministic Scoring here — every fight a pure function of
/// (seed, player inputs), with no UIKit/SpriteKit imports.
public enum HaymakerKit {
    /// Namespace marker for the domain layer.
    public static let domain = "HaymakerKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M1-skeleton"
}
