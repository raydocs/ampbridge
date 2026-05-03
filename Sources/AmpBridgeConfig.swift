import Foundation

struct AmpBridgeConfig {
    var listenPort: UInt16 = 8327
    var localProviderHost: String = "127.0.0.1"
    var localProviderPort: UInt16 = 8318
    var ampBaseURL: String = "https://ampcode.com"
    var upstreamRequestTimeout: TimeInterval = 600
    var upstreamResourceTimeout: TimeInterval = 3600
    var modeFilePath: String = ProcessInfo.processInfo.environment["AMPBRIDGE_MODE_FILE"]
        ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.config/ampbridge/mode")
    var providerRoutingMode: ProviderRoutingMode = ProviderRoutingMode.parse(ProcessInfo.processInfo.environment["AMPBRIDGE_PROVIDER_MODE"])
    var openAIModelOverride: String? = ProcessInfo.processInfo.environment["AMPBRIDGE_OPENAI_MODEL"]
    var anthropicModelOverride: String? = ProcessInfo.processInfo.environment["AMPBRIDGE_ANTHROPIC_MODEL"]

    var allowAnthropicProvider: Bool = true
    var allowOpenAIProvider: Bool = true
}
