import Foundation

enum BridgeRoute: Equatable {
    case auth
    case internalAPI
    case anthropicMessages
    case openAIResponses
    case openAIChatCompletions
    case unsupportedProvider
    case passthroughLocal
    case unknown
}

enum RouteClassifier {
    static func classify(method: String, path: String) -> BridgeRoute {
        if path.hasPrefix("/auth/cli-login") || path.hasPrefix("/api/auth/cli-login") {
            return .auth
        }
        if path.hasPrefix("/api/internal") {
            return .internalAPI
        }
        if path.hasPrefix("/api/provider/anthropic/v1/messages") {
            return .anthropicMessages
        }
        if path.hasPrefix("/api/provider/openai/v1/responses") {
            return .openAIResponses
        }
        if path.hasPrefix("/api/provider/openai/v1/chat/completions") {
            return .openAIChatCompletions
        }
        if path.hasPrefix("/api/provider/") {
            return .unsupportedProvider
        }
        if path.hasPrefix("/v1/") || path.hasPrefix("/api/v1/") {
            return .passthroughLocal
        }
        return .unknown
    }
}
