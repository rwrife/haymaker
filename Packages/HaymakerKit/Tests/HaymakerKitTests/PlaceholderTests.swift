import Testing
@testable import HaymakerKit

@Suite("Skeleton placeholder")
struct PlaceholderTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(HaymakerKit.domain == "HaymakerKit")
    }

    @Test("milestone marker is set for M1")
    func milestoneMarker() {
        #expect(HaymakerKit.milestone == "M1-skeleton")
    }
}
