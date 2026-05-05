import Foundation
import Network

private enum UpstreamProxyError: Error, Equatable {
    case invalidResponse
}

private struct UpstreamChunkStream {
    let response: Task<HTTPURLResponse, Error>
    let chunks: UpstreamChunkSequence
    let task: URLSessionDataTask
    // Retains the delegated URLSession for the lifetime of this stream.
    let session: URLSession
    let delegate: UpstreamChunkStreamDelegate
}

private struct UpstreamChunkSequence: AsyncSequence {
    typealias Element = Data

    let delegate: UpstreamChunkStreamDelegate

    func makeAsyncIterator() -> Iterator {
        Iterator(delegate: delegate)
    }

    struct Iterator: AsyncIteratorProtocol {
        let delegate: UpstreamChunkStreamDelegate

        mutating func next() async throws -> Data? {
            try await delegate.nextChunk()
        }
    }
}

private final class UpstreamChunkStreamDelegate: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private let highWaterBytes = 1_048_576
    private let lowWaterBytes = 262_144
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var waitingChunkContinuation: CheckedContinuation<Data?, Error>?
    private var task: URLSessionDataTask?
    private var didResumeResponse = false
    private var isTaskSuspended = false
    private var isFinished = false
    private var completionError: Error?
    private var pendingChunks: [Data] = []
    private var pendingByteCount = 0

    func setTask(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func setResponseContinuation(_ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.lock()
        responseContinuation = continuation
        lock.unlock()
    }

    func nextChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            lock.lock()
            if !pendingChunks.isEmpty {
                let chunk = pendingChunks.removeFirst()
                pendingByteCount -= chunk.count
                let taskToResume = taskToResumeIfNeededLocked()
                lock.unlock()
                taskToResume?.resume()
                continuation.resume(returning: chunk)
            } else if isFinished {
                let error = completionError
                lock.unlock()
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            } else {
                waitingChunkContinuation = continuation
                lock.unlock()
            }
        }
    }

    func streamTerminated() {
        lock.lock()
        isFinished = true
        completionError = URLError(.cancelled)
        let taskToCancel = task
        let taskToResume = isTaskSuspended ? task : nil
        task = nil
        isTaskSuspended = false
        let waiter = waitingChunkContinuation
        waitingChunkContinuation = nil
        pendingChunks.removeAll(keepingCapacity: true)
        pendingByteCount = 0
        lock.unlock()
        taskToResume?.resume()
        taskToCancel?.cancel()
        waiter?.resume(throwing: URLError(.cancelled))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            resumeResponseIfNeeded(throwing: UpstreamProxyError.invalidResponse)
            finishChunks(throwing: UpstreamProxyError.invalidResponse)
            completionHandler(.cancel)
            return
        }

        resumeResponseIfNeeded(returning: http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        if let waiter = waitingChunkContinuation {
            waitingChunkContinuation = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }

        pendingChunks.append(data)
        pendingByteCount += data.count
        let taskToSuspend = taskToSuspendIfNeededLocked()
        lock.unlock()
        taskToSuspend?.suspend()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resumeResponseIfNeeded(throwing: error)
            finishChunks(throwing: error)
        } else {
            resumeResponseIfNeeded(throwing: UpstreamProxyError.invalidResponse)
            finishChunks(throwing: nil)
        }
        session.finishTasksAndInvalidate()
    }

    private func resumeResponseIfNeeded(returning response: HTTPURLResponse) {
        lock.lock()
        guard !didResumeResponse else {
            lock.unlock()
            return
        }
        didResumeResponse = true
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }

    private func resumeResponseIfNeeded(throwing error: Error) {
        lock.lock()
        guard !didResumeResponse else {
            lock.unlock()
            return
        }
        didResumeResponse = true
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func finishChunks(throwing error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        completionError = error
        let waiter = waitingChunkContinuation
        let shouldResumeWaiter = waiter != nil && pendingChunks.isEmpty
        waitingChunkContinuation = nil
        let taskToResume = taskToResumeIfNeededLocked()
        lock.unlock()

        if shouldResumeWaiter, let waiter {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
        taskToResume?.resume()
    }

    private func taskToSuspendIfNeededLocked() -> URLSessionDataTask? {
        guard pendingByteCount >= highWaterBytes, !isTaskSuspended else { return nil }
        isTaskSuspended = true
        return task
    }

    private func taskToResumeIfNeededLocked() -> URLSessionDataTask? {
        guard pendingByteCount <= lowWaterBytes, isTaskSuspended else { return nil }
        isTaskSuspended = false
        return task
    }
}

final class AmpBridgeServer {
    private enum UpstreamPathMode {
        case preserve
        case stripOpenAIProviderPrefix
    }

    private enum RewriteMode: Equatable {
        case none
        case anthropicProvider
        case openAIResponsesIfSSE
    }

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
                if currentProviderRoutingMode() == .official {
                    proxyOfficial(request: request, connection: connection)
                } else {
                    proxyAnthropicProvider(request: request, connection: connection)
                }
            } else {
                writer.sendError(on: connection, statusCode: 501, message: "Anthropic provider disabled")
            }

        case .openAIResponses:
            if config.allowOpenAIProvider {
                if currentProviderRoutingMode() == .official {
                    proxyOfficial(request: request, connection: connection)
                } else {
                    proxyOpenAIResponses(request: request, connection: connection)
                }
            } else {
                writer.sendError(on: connection, statusCode: 501, message: "OpenAI provider disabled")
            }

        case .openAIProviderPassthrough:
            if config.allowOpenAIProvider {
                if currentProviderRoutingMode() == .official {
                    proxyOfficial(request: request, connection: connection)
                } else {
                    proxyOpenAIProvider(request: request, connection: connection)
                }
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

    private func currentProviderRoutingMode() -> ProviderRoutingMode {
        if let fileMode = try? String(contentsOfFile: config.modeFilePath, encoding: .utf8),
           !fileMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ProviderRoutingMode.parse(fileMode)
        }
        return config.providerRoutingMode
    }

    private func rewrittenRequestBody(for request: HTTPRequest, rewriteMode: RewriteMode) -> Data {
        let modelOverride: String?
        let label: String
        switch rewriteMode {
        case .openAIResponsesIfSSE:
            modelOverride = config.openAIModelOverride
            label = "OpenAI"
        case .anthropicProvider:
            modelOverride = config.anthropicModelOverride
            label = "Anthropic"
        case .none:
            return request.body
        }

        guard let modelOverride else { return request.body }
        let rewrittenBody = ModelRequestBodyRewriter.rewriteModel(in: request.body, to: modelOverride)
        if rewrittenBody != request.body {
            print("AmpBridge \(label) model override: \(modelOverride) for \(request.path)")
        }
        return rewrittenBody
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

    private func proxyAnthropicProvider(request: HTTPRequest, connection: NWConnection) {
        proxy(
            request: request,
            baseURL: "http://\(config.localProviderHost):\(config.localProviderPort)",
            pathMode: .preserve,
            rewriteMode: .anthropicProvider,
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
        upstream.httpBody = rewrittenRequestBody(for: request, rewriteMode: rewriteMode)

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
                let stream = self.streamChunks(for: upstream)
                var shouldTerminateStream = true
                defer {
                    if shouldTerminateStream {
                        stream.delegate.streamTerminated()
                        stream.session.finishTasksAndInvalidate()
                    }
                }
                let http = try await stream.response.value

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

                if activeRewrite {
                    let rewriter = OpenAIResponsesStreamRewriter()
                    var buffer = Data()
                    var shouldCloseDownstream = false

                    for try await chunk in stream.chunks {
                        buffer.append(chunk)
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
                    for try await chunk in stream.chunks {
                        try await self.sendData(chunk, on: connection)
                    }
                }

                shouldTerminateStream = false
                self.finishConnection(connection)
            } catch {
                print("AmpBridge upstream proxy failed: \(error)")
                if didSendResponseHead {
                    self.finishConnection(connection)
                } else if (error as? UpstreamProxyError) == .invalidResponse {
                    self.writer.sendError(on: connection, statusCode: 502, message: "Invalid upstream response")
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

    private func streamChunks(for request: URLRequest) -> UpstreamChunkStream {
        let delegate = UpstreamChunkStreamDelegate()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = config.upstreamRequestTimeout
        sessionConfiguration.timeoutIntervalForResource = config.upstreamResourceTimeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpShouldSetCookies = false

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        delegate.setTask(task)
        let chunks = UpstreamChunkSequence(delegate: delegate)
        let response = Task<HTTPURLResponse, Error> {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                delegate.setResponseContinuation(continuation)
                task.resume()
            }
        }

        return UpstreamChunkStream(
            response: response,
            chunks: chunks,
            task: task,
            session: session,
            delegate: delegate
        )
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
