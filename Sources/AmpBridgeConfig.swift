import Foundation

struct AmpBridgeConfig {
    var listenPort: UInt16 = 8317
    var localProviderHost: String = "127.0.0.1"
    var localProviderPort: UInt16 = 8318
    var ampBaseURL: String = "https://ampcode.com"

    var allowAnthropicProvider: Bool = true
    var allowOpenAIProvider: Bool = true
}
