import Foundation

final class AmpBridgeServer {
    let config: AmpBridgeConfig

    init(config: AmpBridgeConfig = AmpBridgeConfig()) {
        self.config = config
    }

    func start() {
        print("AmpBridge scaffold")
        print("listen: 127.0.0.1:\(config.listenPort)")
        print("amp upstream: \(config.ampBaseURL)")
        print("local provider upstream: http://\(config.localProviderHost):\(config.localProviderPort)")
        print("anthropic enabled: \(config.allowAnthropicProvider)")
        print("openai enabled: \(config.allowOpenAIProvider)")
        print("status: scaffold only, routing implementation pending")
    }
}
