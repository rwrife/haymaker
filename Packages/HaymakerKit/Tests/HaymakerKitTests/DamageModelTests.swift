import Testing
@testable import HaymakerKit

@Suite("DamageModel: pure rule table")
struct DamageModelTests {
    @Test("blocked damage subtracts the reduction and clamps at zero")
    func blocked() {
        #expect(DamageModel.blockedDamage(base: 12, reduction: 8, guardBreak: false) == 4)
        #expect(DamageModel.blockedDamage(base: 6, reduction: 8, guardBreak: false) == 0)
        // Guard break halves the reduction: 12 - 4 = 8.
        #expect(DamageModel.blockedDamage(base: 12, reduction: 8, guardBreak: true) == 8)
    }

    @Test("counter multiplies base damage")
    func counter() {
        #expect(DamageModel.counterDamage(base: 8, multiplier: 2) == 16)
        #expect(DamageModel.counterDamage(base: 22, multiplier: 1) == 22)
    }

    @Test("knockdown / out-cold / three-count thresholds are named predicates")
    func thresholds() {
        #expect(DamageModel.isKnockdownBlow(damage: 25, threshold: 25))
        #expect(!DamageModel.isKnockdownBlow(damage: 24, threshold: 25))
        #expect(DamageModel.isOutOfCold(hpAfterBlow: 0))
        #expect(!DamageModel.isOutOfCold(hpAfterBlow: 1))
        #expect(DamageModel.isThreeCountKO(knockdownCount: 3, maxKnockdowns: 3))
        #expect(!DamageModel.isThreeCountKO(knockdownCount: 2, maxKnockdowns: 3))
    }

    @Test("revival floors HP upward, never downward")
    func revival() {
        #expect(DamageModel.revivalHP(current: 5, floor: 30) == 30)
        #expect(DamageModel.revivalHP(current: 42, floor: 30) == 42)
    }

    @Test("stamina regen by state: idle full, guard/recover half, action none")
    func regen() {
        #expect(DamageModel.staminaRegen(state: .idle, full: 2) == 2)
        #expect(DamageModel.staminaRegen(state: .blocking, full: 2) == 1)
        #expect(DamageModel.staminaRegen(state: .recovering, full: 2) == 1)
        for state: FighterState in [.telling, .attacking, .dodging, .parrying, .knockedDown, .ko] {
            #expect(DamageModel.staminaRegen(state: state, full: 2) == 0)
        }
    }
}
