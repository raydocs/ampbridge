import Foundation
import Network

final class AmpBridgeServer {
    let config: AmpBridgeConfig
    private let writer = HTTPResponseWriter()
    private var listener: NWListener?

    init(config: AmpBridgeConfig = AmpBridgeConfig()) {
        self.config = config
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
            guard let data, !data.isEmpty else {
                if isComplete { connection.cancel() }
                return
            }

            var combined = accumulatedData
            combined.append(data)

            if self.hasCompleteRequest(in: combined) {
                self.processRequest(data: combined, connection: connection)
            } else if !isComplete {
                self.receiveNextChunk(from: connection, accumulatedData: combined)
            } else {
                self.processRequest(data: combined, connection: connection)
            }
        }
    }

    private func hasCompleteRequest(in data: Data) -> Bool {
        guard let requestString = String(data: data, encoding: .utf8),
              let headerEndRange = requestString.range(of: "\r\n\r\n") else {
            return false
        }
        let headerEndIndex = requestString.distance(from: requestString.startIndex, to: headerEndRange.upperBound)
        let headerPart = String(requestString.prefix(headerEndIndex))
        if let contentLengthLine = headerPart.components(separatedBy: "\r\n").first(where: { $0.lowercased().starts(with: "content-length:") }),
           let raw = contentLengthLine.split(separator: ":", maxSplits: 1).last,
           let contentLength = Int(raw.trimmingCharacters(in: .whitespaces)) {
            let bodyLength = data.count - headerEndIndex
            return bodyLength >= contentLength
        }
        return true
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

        case .anthropicMessages:
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

        case .openAIChatCompletions:
            proxyLocalProvider(request: request, connection: connection)

        case .unsupportedProvider:
            writer.sendError(on: connection, statusCode: 501, message: "Unsupported provider")

        case .passthroughLocal:
            proxyLocalProvider(request: request, connection: connection)

        case .unknown:
            proxyOfficial(request: request, connection: connection)
        }
    }

    private func proxyOfficial(request: HTTPRequest, connection: NWConnection) {
        proxy(request: request, baseURL: config.ampBaseURL, rewriteSSE: false, connection: connection)
    }

    private func proxyLocalProvider(request: HTTPRequest, connection: NWConnection) {
        proxy(request: request, baseURL: "http://\(config.localProviderHost):\(config.localProviderPort)", rewriteSSE: false, connection: connection)
    }

    private func proxyOpenAIResponses(request: HTTPRequest, connection: NWConnection) {
        proxy(request: request, baseURL: "http://\(config.localProviderHost):\(config.localProviderPort)", rewriteSSE: true, connection: connection)
    }

    private func proxy(request: HTTPRequest, baseURL: String, rewriteSSE: Bool, connection: NWConnection) {
        guard let url = URL(string: baseURL + request.path) else {
            writer.sendError(on: connection, statusCode: 500, message: "Invalid upstream URL")
            return
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.httpBody = request.body
        let excludedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]
        for (name, value) in request.headers where !excludedHeaders.contains(name.lowercased()) {
            upstream.setValue(value, forHTTPHeaderField: name)
        }
        upstream.setValue("close", forHTTPHeaderField: "Connection")

        let session = URLSession(configuration: .ephemeral)
        let rewriter = rewriteSSE ? OpenAIResponsesStreamRewriter() : nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await session.bytes(for: upstream)
                guard let http = response as? HTTPURLResponse else {
                    self.writer.sendError(on: connection, statusCode: 502, message: "Invalid upstream response")
                    return
                }

                let headersData = self.makeResponseHeaders(from: http, forceStreaming: rewriteSSE)
                self.writer.sendRaw(on: connection, data: headersData, close: false)

                var iterator = bytes.makeAsyncIterator()
                var buffer = Data()
                while let byte = try await iterator.next() {
                    buffer.append(byte)
                    if rewriteSSE {
                        if buffer.count >= 4096 {
                            let out = rewriter?.process(buffer, isComplete: false) ?? buffer
                            if !out.isEmpty {
                                try await self.sendData(out, on: connection)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    } else {
                        if buffer.count >= 4096 {
                            try await self.sendData(buffer, on: connection)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                }

                let finalOut = rewriteSSE ? (rewriter?.process(buffer, isComplete: true) ?? buffer) : buffer
                if !finalOut.isEmpty {
                    try await self.sendData(finalOut, on: connection)
                }
                connection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } catch {
                print("AmpBridge upstream proxy failed: \(error)")
                self.writer.sendError(on: connection, statusCode: 502, message: "Bad Gateway")
            }
        }
    }

    private func makeResponseHeaders(from response: HTTPURLResponse, forceStreaming: Bool) -> Data {
        var text = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
        for (keyAny, valueAny) in response.allHeaderFields {
            guard let key = keyAny as? String else { continue }
            let lower = key.lowercased()
            if lower == "content-length" || lower == "transfer-encoding" || lower == "connection" { continue }
            if forceStreaming && lower == "content-type" {
                text += "Content-Type: text/event-stream\r\n"
                continue
            }
            text += "\(key): \(valueAny)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
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
