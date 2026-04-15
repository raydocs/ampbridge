import Foundation
import Network

final class AmpBridgeServer {
    private enum UpstreamPathMode {
        case preserve
        case stripOpenAIProviderPrefix
    }

    private enum RewriteMode: Equatable {
        case none
        case openAIResponsesIfSSE
    }

    let config: AmpBridgeConfig
    private let writer = HTTPResponseWriter()
    private var listener: NWListener?
    private let session: URLSession

    init(config: AmpBridgeConfig = AmpBridgeConfig()) {
        self.config = config
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = config.upstreamRequestTimeout
        sessionConfiguration.timeoutIntervalForResource = config.upstreamResourceTimeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpShouldSetCookies = false
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: config.listenPort) else {
                fatalError("Invalid listen port")
            }
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("AmpBridge listening on 127.0.0.1:\(self.config.listenPort)")
                    print("AMP upstream: \(self.config.ampBaseURL)")
                    print("Local provider upstream: http://\(self.config.localProviderHost):\(self.config.localProviderPort)")
                case .failed(let error):
                    print("AmpBridge listener failed: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            fatalError("Failed to start listener: \(error)")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveNextChunk(from: connection, accumulatedData: Data())
    }

    private func receiveNextChunk(from connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("AmpBridge receive error: \(error)")
                connection.cancel()
                return
            }

            var combined = accumulatedData
            if let data, !data.isEmpty {
                combined.append(data)
            }

            if HTTPRequestParser.isCompleteRequest(combined) {
                self.processRequest(data: combined, connection: connection)
            } else if !isComplete {
                self.receiveNextChunk(from: connection, accumulatedData: combined)
            } else {
                self.processRequest(data: combined, connection: connection)
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let request = HTTPRequestParser.parse(data: data) else {
            writer.sendError(on: connection, statusCode: 400, message: "Bad Request")
            return
        }
        let route = RouteClassifier.classify(method: request.method, path: request.path)
        print("AmpBridge request: \(request.method) \(request.path) -> \(route)")

        switch route {
        case .auth:
            let loginPath = request.path.hasPrefix("/api/") ? String(request.path.dropFirst(4)) : request.path
            writer.sendRedirect(on: connection, location: config.ampBaseURL + loginPath)

        case .internalAPI:
            proxyOfficial(request: request, connection: connection)

        case .anthropicProvider:
            if config.allowAnthropicProvider {
                proxyOfficial(request: request, connection: connection)
            } else {
                writer.sendError(on: connection, statusCode: 501, message: "Anthropic provider disabled")
            }

        case .openAIResponses:
            if config.allowOpenAIProvider {
                proxyOpenAIResponses(request: request, connection: connection)
            } else {
                writer.sendError(on: connection, statusCode: 501, message: "OpenAI provider disabled")
            }

        case .openAIProviderPassthrough:
            if config.allowOpenAIProvider {
                proxyOpenAIProvider(request: request, connection: connection)
            } else {
                writer.sendError(on: connection, statusCode: 501, message: "OpenAI provider disabled")
            }

        case .providerOfficialPassthrough:
            proxyOfficial(request: request, connection: connection)

        case .passthroughLocal:
            proxyLocalProvider(request: request, connection: connection)

        case .unknown:
            proxyOfficial(request: request, connection: connection)
        }
    }

    private func proxyOfficial(request: HTTPRequest, connection: NWConnection) {
        proxy(
            request: request,
            baseURL: config.ampBaseURL,
            pathMode: .preserve,
            rewriteMode: .none,
            connection: connection
        )
    }

    private func proxyLocalProvider(request: HTTPRequest, connection: NWConnection) {
        proxy(
            request: request,
            baseURL: "http://\(config.localProviderHost):\(config.localProviderPort)",
            pathMode: .preserve,
            rewriteMode: .none,
            connection: connection
        )
    }

    private func proxyOpenAIProvider(request: HTTPRequest, connection: NWConnection) {
        proxy(
            request: request,
            baseURL: "http://\(config.localProviderHost):\(config.localProviderPort)",
            pathMode: .stripOpenAIProviderPrefix,
            rewriteMode: .none,
            connection: connection
        )
    }

    private func proxyOpenAIResponses(request: HTTPRequest, connection: NWConnection) {
        proxy(
            request: request,
            baseURL: "http://\(config.localProviderHost):\(config.localProviderPort)",
            pathMode: .stripOpenAIProviderPrefix,
            rewriteMode: .openAIResponsesIfSSE,
            connection: connection
        )
    }

    private func proxy(
        request: HTTPRequest,
        baseURL: String,
        pathMode: UpstreamPathMode,
        rewriteMode: RewriteMode,
        connection: NWConnection
    ) {
        let requestPath = upstreamPath(for: request.path, mode: pathMode)
        guard let url = URL(string: baseURL + requestPath) else {
            writer.sendError(on: connection, statusCode: 500, message: "Invalid upstream URL")
            return
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.httpBody = request.body

        let excludedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]
        for (name, value) in request.headers where !excludedHeaders.contains(name.lowercased()) {
            if upstream.value(forHTTPHeaderField: name) != nil {
                upstream.addValue(value, forHTTPHeaderField: name)
            } else {
                upstream.setValue(value, forHTTPHeaderField: name)
            }
        }
        upstream.setValue("close", forHTTPHeaderField: "Connection")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var didSendResponseHead = false

            do {
                let (bytes, response) = try await self.session.bytes(for: upstream)
                guard let http = response as? HTTPURLResponse else {
                    self.writer.sendError(on: connection, statusCode: 502, message: "Invalid upstream response")
                    return
                }

                let upstreamContentType = http.value(forHTTPHeaderField: "Content-Type")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let activeRewrite = rewriteMode == .openAIResponsesIfSSE && (upstreamContentType?.hasPrefix("text/event-stream") ?? false)
                let headersData = self.makeResponseHeaders(
                    from: http,
                    overrideContentType: activeRewrite ? "text/event-stream" : nil
                )
                try await self.sendData(headersData, on: connection)
                didSendResponseHead = true

                var iterator = bytes.makeAsyncIterator()

                if activeRewrite {
                    let rewriter = OpenAIResponsesStreamRewriter()
                    var buffer = Data()
                    var shouldCloseDownstream = false

                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        if self.shouldFlushSSEBuffer(buffer) {
                            let result = rewriter.process(buffer, isTransportComplete: false)
                            if !result.output.isEmpty {
                                try await self.sendData(result.output, on: connection)
                            }
                            buffer.removeAll(keepingCapacity: true)
                            if result.shouldCloseDownstream {
                                print("AmpBridge SSE close signal reached for \(request.path)")
                                shouldCloseDownstream = true
                                break
                            }
                        }
                    }

                    if !shouldCloseDownstream {
                        let finalResult = rewriter.process(buffer, isTransportComplete: true)
                        if !finalResult.output.isEmpty {
                            try await self.sendData(finalResult.output, on: connection)
                        }
                    }
                } else {
                    var buffer = Data()

                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        if buffer.count >= 4096 {
                            try await self.sendData(buffer, on: connection)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    if !buffer.isEmpty {
                        try await self.sendData(buffer, on: connection)
                    }
                }

                self.finishConnection(connection)
            } catch {
                print("AmpBridge upstream proxy failed: \(error)")
                if didSendResponseHead {
                    self.finishConnection(connection)
                } else {
                    self.writer.sendError(on: connection, statusCode: 502, message: "Bad Gateway")
                }
            }
        }
    }

    private func upstreamPath(for requestPath: String, mode: UpstreamPathMode) -> String {
        switch mode {
        case .preserve:
            return requestPath
        case .stripOpenAIProviderPrefix:
            let prefix = "/api/provider/openai"
            guard requestPath.hasPrefix(prefix) else {
                return requestPath
            }

            let suffix = String(requestPath.dropFirst(prefix.count))
            if suffix.isEmpty {
                return "/"
            }
            if suffix.hasPrefix("/") {
                return suffix
            }
            return "/\(suffix)"
        }
    }

    private func makeResponseHeaders(from response: HTTPURLResponse, overrideContentType: String?) -> Data {
        var text = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
        var emittedContentType = false

        for (keyAny, valueAny) in response.allHeaderFields {
            guard let key = keyAny as? String else { continue }
            let lower = key.lowercased()
            if lower == "content-length" || lower == "transfer-encoding" || lower == "connection" || lower == "content-encoding" { continue }
            if lower == "content-type" {
                emittedContentType = true
                if let overrideContentType {
                    text += "Content-Type: \(overrideContentType)\r\n"
                } else {
                    text += "\(key): \(valueAny)\r\n"
                }
            } else {
                text += "\(key): \(valueAny)\r\n"
            }
        }

        if let overrideContentType, !emittedContentType {
            text += "Content-Type: \(overrideContentType)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    private func shouldFlushSSEBuffer(_ buffer: Data) -> Bool {
        buffer.count >= 512 ||
        buffer.range(of: Data("\n\n".utf8)) != nil ||
        buffer.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    private func finishConnection(_ connection: NWConnection) {
        connection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
