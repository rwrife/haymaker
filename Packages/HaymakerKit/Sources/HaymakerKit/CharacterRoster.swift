import Foundation

/// Story and presentation data shared by the ladder, introductions and arena.
/// Asset keys name both the supplied PNG and its matching rig.
public struct CharacterProfile: Sendable, Hashable {
    public let asset: String
    public let bio: String
    public let style: String
    public let taunt: String
}

public extension OpponentBook {
    /// The story ladder. Prototype books remain available for historical replays.
    static let careerRoster: [OpponentBook] = [.goldie, .nico, .atlas, .vera, .duke, .sylvie, .cassian, .baxter]

    static let goldie = OpponentBook(id: "goldie", name: "Goldie Voltage", sequence: [
        punch(.jab, 48, 12, 24, 4, 6), punch(.jab, 30, 10, 24, 4, 6),
        punch(.hook, 54, 16, 64, 9, 12)
    ], minGap: 14, gapSpread: 10)

    static let nico = OpponentBook(id: "nico", name: "Nico “Nightshift” Navarro", sequence: [
        punch(.block, 36, 60, 20, 4, 0), punch(.jab, 34, 10, 32, 4, 9),
        punch(.feint, 38, 0, 20, 2, 0), punch(.uppercut, 48, 14, 48, 10, 17)
    ], minGap: 40, gapSpread: 18)

    static let atlas = OpponentBook(id: "atlas", name: "Atlas “Undertow” Reed", sequence: [
        punch(.hook, 64, 18, 48, 10, 18), punch(.hook, 52, 16, 44, 10, 18),
        punch(.block, 40, 48, 28, 5, 0), punch(.uppercut, 66, 20, 60, 14, 23)
    ], minGap: 20, gapSpread: 8)

    static let vera = OpponentBook(id: "vera", name: "Vera Velvet", sequence: [
        punch(.block, 28, 78, 18, 5, 0), punch(.jab, 28, 10, 24, 4, 11),
        punch(.block, 30, 54, 20, 5, 0), punch(.uppercut, 40, 12, 38, 10, 19)
    ], minGap: 24, gapSpread: 12)

    static let duke = OpponentBook(id: "duke", name: "Duke Doubletake", sequence: [
        punch(.feint, 36, 0, 14, 2, 0), punch(.hook, 38, 12, 34, 8, 16),
        punch(.feint, 48, 0, 18, 2, 0), punch(.jab, 24, 8, 24, 4, 10),
        punch(.uppercut, 44, 14, 44, 11, 20)
    ], minGap: 18, gapSpread: 30)

    static let sylvie = OpponentBook(id: "sylvie", name: "Sylvie “Slipstream” Sloane", sequence: [
        punch(.dodge, 28, 24, 16, 4, 0), punch(.jab, 24, 8, 22, 4, 11),
        punch(.dodge, 24, 20, 16, 4, 0), punch(.hook, 32, 10, 38, 8, 17)
    ], minGap: 16, gapSpread: 10)

    static let cassian = OpponentBook(id: "cassian", name: "Cassian “Saint” Sterling", sequence: [
        punch(.jab, 28, 10, 24, 4, 12), punch(.block, 26, 54, 20, 5, 0),
        punch(.feint, 30, 0, 16, 2, 0), punch(.hook, 36, 12, 32, 8, 18),
        punch(.uppercut, 42, 14, 40, 11, 21)
    ], minGap: 22, gapSpread: 8)

    private static func punch(_ move: Move, _ tell: Int, _ impact: Int, _ recover: Int,
                              _ stamina: Int, _ damage: Int) -> PatternEntry {
        PatternEntry(move: move, tell: tell, impact: impact, recover: recover, staminaCost: stamina, damage: damage)
    }

    var character: CharacterProfile? {
        switch id {
        case "goldie": CharacterProfile(asset: "goldie",
            bio: "An arcade repair whiz boxing to fund a traveling arcade. Goldie turns every bout into a high-score chase, but her relentless combinations leave openings when she overcommits.",
            style: "COMBINATION PRESSURE", taunt: "Hope you brought spare change. This combo doesn't take refunds!")
        case "nico": CharacterProfile(asset: "nico",
            bio: "A night-bus driver who notices every hesitation. Nico saves his energy, lets impatient fighters commit, and answers with precise counters. He's fighting for fewer shifts and more time in the gym.",
            style: "PATIENT COUNTERPUNCHER", taunt: "Last bus home leaves in three rounds. I'll make sure you catch it.")
        case "atlas": CharacterProfile(asset: "atlas",
            bio: "A harbor salvage diver carrying a champion father's complicated legacy. Atlas brings patient heavyweight pressure and deliberate hooks. Move around his power instead of trading with it.",
            style: "HEAVYWEIGHT PRESSURE", taunt: "I've lifted shipwrecks lighter than that guard. Let's see if it floats.")
        case "vera": CharacterProfile(asset: "vera",
            bio: "After years preparing champions behind the scenes, Vera is claiming her own spotlight in her late forties. Her disciplined high guard and exact counters make careless attacks expensive.",
            style: "HIGH GUARD • EXACT COUNTERS", taunt: "I used to charge champions for this lesson. You're getting the full price.")
        case "duke": CharacterProfile(asset: "duke",
            bio: "A former carnival performer building a new stage for his old troupe. Duke's feints and shifting rhythms turn the obvious threat into a distraction. Watch his shoulders, not the advertised glove.",
            style: "FEINTS • MISDIRECTION", taunt: "Watch this glove. The other one's just here for the surprise ending.")
        case "sylvie": CharacterProfile(asset: "sylvie",
            bio: "A former speed skater finding a new competitive identity. Sylvie slips away and fires quick counters, but her favorite exits can be read. Patience beats a race to every exchange.",
            style: "EVASION • QUICK COUNTERS", taunt: "You brought boxing shoes to a speed-skating problem. Cute.")
        case "cassian": CharacterProfile(asset: "cassian",
            bio: "A former titleholder whose victory saved his neighborhood gym. Behind the flawless public image, Cassian is an exacting contender testing balance, timing, and what happens when a perfect plan breaks.",
            style: "TIMING • LAYERED DEFENSE", taunt: "I polished my footwork for this. Please don't scuff the masterpiece.")
        case "baxter": CharacterProfile(asset: "bruiser",
            bio: "The theatrical reigning champion was once a generous small-gym mentor. Baxter protects his reputation with heavyweight pressure, big windups, feints, guarded pauses and punishing counters. Earn his corner.",
            style: "FINAL BOSS • COMPLETE PRESSURE", taunt: "You want this corner? Earn it. And try not to dent the spotlight.")
        default: nil
        }
    }
}
