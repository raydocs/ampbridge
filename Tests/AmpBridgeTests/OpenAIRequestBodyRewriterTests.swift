import Foundation
import Testing
@testable import AmpBridge

struct OpenAIRequestBodyRewriterTests {
    @Test func rewritesTopLevelModel() throws {
        let body = try #require("""
        {"model":"gpt-5.4","input":"hello","reasoning":{"effort":"xhigh"}}
        """.data(using: .utf8))

        let rewritten = OpenAIRequestBodyRewriter.rewriteModel(in: body, to: "gpt-5.5")
        let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])

        #expect(object["model"] as? String == "gpt-5.5")
        let reasoning = try #require(object["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "xhigh")
    }

    @Test func leavesInvalidJSONUnchanged() throws {
        let body = try #require("not-json".data(using: .utf8))
        #expect(OpenAIRequestBodyRewriter.rewriteModel(in: body, to: "gpt-5.5") == body)
    }
}
