import Testing
@testable import AmpBridge

struct ProviderRoutingModeTests {
    @Test func parsesOfficialAliases() {
        #expect(ProviderRoutingMode.parse("official") == .official)
        #expect(ProviderRoutingMode.parse("native") == .official)
        #expect(ProviderRoutingMode.parse("official-api") == .official)
    }

    @Test func defaultsToLocal() {
        #expect(ProviderRoutingMode.parse(nil) == .local)
        #expect(ProviderRoutingMode.parse("local") == .local)
        #expect(ProviderRoutingMode.parse("anything-else") == .local)
    }
}
