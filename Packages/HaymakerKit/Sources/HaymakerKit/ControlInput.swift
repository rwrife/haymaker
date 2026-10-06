/// Pure mapping of one-thumb drag vectors to the input alphabet.
/// SpriteKit/SwiftUI never decide fight outcomes; they submit this action.
public enum ControlInput {
    public static func resolve(dx: Double, dy: Double) -> PlayerInput {
        if dy < -32 && abs(dy) > abs(dx) { return .uppercut }
        if dx < -32 { return .hook }
        if dx > 32 { return .dodge }
        if dy > 32 { return .block }
        return .jab
    }
}
