import Foundation

enum OpenAIRequestBodyRewriter {
    static func rewriteModel(in body: Data, to model: String) -> Data {
        guard !body.isEmpty else { return body }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }

        var rewritten = object
        guard rewritten["model"] as? String != model else { return body }
        rewritten["model"] = model

        guard JSONSerialization.isValidJSONObject(rewritten),
              let data = try? JSONSerialization.data(withJSONObject: rewritten, options: []) else {
            return body
        }
        return data
    }
}
