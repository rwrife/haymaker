import Testing
@testable import HaymakerStore

@Suite("HaymakerStore skeleton tests")
struct HaymakerStoreTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(HaymakerStore.domain == "HaymakerStore")
    }

    @Test("milestone marker is M1-skeleton")
    func milestoneMarker() {
        #expect(HaymakerStore.milestone == "M1-skeleton")
    }
}
