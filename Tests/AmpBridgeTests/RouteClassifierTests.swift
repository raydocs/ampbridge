import Testing
@testable import AmpBridge

struct RouteClassifierTests {
    @Test("Explicit anthropic/openai provider routes are preserved")
    func explicitProviderRoutesRemainUnchanged() {
        #expect(RouteClassifier.classify(method: "POST", path: "/api/provider/anthropic/v1/messages") == .anthropicProvider)
        #expect(RouteClassifier.classify(method: "POST", path: "/api/provider/openai/v1/responses") == .openAIResponses)
        #expect(RouteClassifier.classify(method: "POST", path: "/api/provider/openai/v1/responses?stream=true") == .openAIResponses)
        #expect(RouteClassifier.classify(method: "GET", path: "/api/provider/openai/v1/models") == .openAIProviderPassthrough)
    }

    @Test("Unknown /api/provider/* routes passthrough to official AMP")
    func unknownProviderRoutesPassthroughOfficial() {
        #expect(RouteClassifier.classify(method: "POST", path: "/api/provider/google/v1/messages") == .providerOfficialPassthrough)
        #expect(RouteClassifier.classify(method: "POST", path: "/api/provider/foo/bar?x=1") == .providerOfficialPassthrough)
    }
}
