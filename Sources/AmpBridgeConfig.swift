import Foundation

struct AmpBridgeConfig {
    var listenPort: UInt16 = 8327
    var localProviderHost: String = "127.0.0.1"
    var localProviderPort: UInt16 = 8318
    var ampBaseURL: String = "https://ampcode.com"
    var upstreamRequestTimeout: TimeInterval = 600
    var upstreamResourceTimeout: TimeInterval = 3600

    var allowAnthropicProvider: Bool = true
    var allowOpenAIProvider: Bool = true
}
