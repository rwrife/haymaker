import Foundation

/// The "3… 2… 1…" beat that gates the action: shown before a bout begins
/// and again after a knockdown is answered, before the fighters may swing.
///
/// A pure value type (no UI, no clock of its own) so the cadence is
/// testable off-device. The host feeds it real elapsed seconds each frame
/// and renders `value` / `stepProgress`; while it is running the host does
/// not advance the engine.
public struct FightCountdown: Sendable, Equatable {
    public static let defaultFrom = 3
    public static let defaultStepSeconds: TimeInterval = 0.9

    /// The first number shown (counts down to 1).
    public let from: Int
    /// How long each number stays on screen.
    public let stepSeconds: TimeInterval
    public private(set) var elapsed: TimeInterval = 0

    public init(from: Int = FightCountdown.defaultFrom,
                stepSeconds: TimeInterval = FightCountdown.defaultStepSeconds) {
        self.from = max(1, from)
        self.stepSeconds = max(0.05, stepSeconds)
    }

    public var totalSeconds: TimeInterval { Double(from) * stepSeconds }

    public var isFinished: Bool { elapsed >= totalSeconds }

    /// The number currently showing (`from`…1), or nil once finished.
    public var value: Int? {
        guard !isFinished else { return nil }
        return max(1, from - Int(elapsed / stepSeconds))
    }

    /// 0…1 progress through the number currently showing; drives the
    /// slam-in animation. 1 once finished.
    public var stepProgress: Double {
        guard !isFinished else { return 1 }
        let into = elapsed.truncatingRemainder(dividingBy: stepSeconds)
        return min(1, max(0, into / stepSeconds))
    }

    // MARK: - Knockdown count (tick-driven, engine keeps running)

    /// The number to show while a downed fighter's knockdown window runs: `from`…1
    /// spread evenly across `windowTicks`, so the count lands on 1 just as the
    /// fighter gets back up. Nil outside the window. Driven by engine ticks (not a
    /// wall clock) so it stays in step with the animation and freezes on pause.
    public static func knockdownValue(elapsedTicks: Int, windowTicks: Int, from: Int = defaultFrom) -> Int? {
        guard windowTicks > 0, elapsedTicks >= 0, elapsedTicks < windowTicks else { return nil }
        let beats = max(1, from)
        return max(1, beats - (elapsedTicks * beats) / windowTicks)
    }

    /// 0…1 progress through the number currently showing during a knockdown window
    /// (0 right as the number changes). Nil outside the window.
    public static func knockdownStepProgress(elapsedTicks: Int, windowTicks: Int, from: Int = defaultFrom) -> Double? {
        guard windowTicks > 0, elapsedTicks >= 0, elapsedTicks < windowTicks else { return nil }
        let scaled = Double(elapsedTicks) * Double(max(1, from)) / Double(windowTicks)
        return min(1, max(0, scaled - scaled.rounded(.down)))
    }

    /// Advance by real elapsed seconds. Negative input is ignored and the
    /// total is clamped so a long frame can never overshoot the end.
    public mutating func advance(by seconds: TimeInterval) {
        elapsed = min(totalSeconds, elapsed + max(0, seconds))
    }
}
