import Foundation

enum BridgeRoute: Equatable {
    case auth
    case internalAPI
    case anthropicProvider
    case openAIResponses
    case openAIProviderPassthrough
    case passthroughLocal
    case providerOfficialPassthrough
    case unknown
}

enum RouteClassifier {
    static func classify(method: String, path: String) -> BridgeRoute {
        if matchesSegmentPrefix(path, prefix: "/auth/cli-login") || matchesSegmentPrefix(path, prefix: "/api/auth/cli-login") {
            return .auth
        }
        if matchesSegmentPrefix(path, prefix: "/api/internal") {
            return .internalAPI
        }
        if path.hasPrefix("/api/provider/anthropic/") {
            return .anthropicProvider
        }
        if matchesSegmentPrefix(path, prefix: "/api/provider/openai/v1/responses") {
            return .openAIResponses
        }
        if path.hasPrefix("/api/provider/openai/") {
            return .openAIProviderPassthrough
        }
        if path.hasPrefix("/v1/") || path.hasPrefix("/api/v1/") {
            return .passthroughLocal
        }
        if path.hasPrefix("/api/provider/") {
            return .providerOfficialPassthrough
        }
        return .unknown
    }

    private static func matchesSegmentPrefix(_ path: String, prefix: String) -> Bool {
        guard path.hasPrefix(prefix) else {
            return false
        }
        guard path.count > prefix.count else {
            return true
        }

        let nextCharacter = path[path.index(path.startIndex, offsetBy: prefix.count)]
        return nextCharacter == "/" || nextCharacter == "?"
    }
}
