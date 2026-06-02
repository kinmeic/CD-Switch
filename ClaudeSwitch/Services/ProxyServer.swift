import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.claude.switch", category: "proxy")

// MARK: - HTTP Request

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data

    func headerValue(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    func bearerToken() -> String? {
        guard let auth = headerValue("authorization") else { return nil }
        let lower = auth.lowercased()
        if lower.hasPrefix("bearer ") {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

struct ProxyRequestLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let path: String
    let providerName: String?
    let status: Int
    let duration: TimeInterval
    let error: String?
}

struct RectifierConfig: Equatable {
    var enabled: Bool
    var requestThinkingSignature: Bool
    var requestThinkingBudget: Bool

    static let `default` = RectifierConfig(
        enabled: true,
        requestThinkingSignature: true,
        requestThinkingBudget: true
    )
}

// MARK: - ProxyServer

final class ProxyServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.claude.switch.proxy", qos: .userInitiated)
    private var gatewayToken: String = ""
    private var activeProvider: Provider?
    private var rectifierConfig: RectifierConfig = .default
    private let maxRequestBodyBytes = 10 * 1024 * 1024

    @Published var running = false
    @Published var port: Int = AppEnvironment.defaultPort
    @Published var requestCount: Int = 0
    @Published var lastError: String?
    @Published private(set) var requestLogs: [ProxyRequestLog] = []

    func start(port: Int, provider: Provider, gatewayToken: String) throws {
        guard let rawPort = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw NSError(
                domain: "ProxyServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Port must be between 1 and 65535"]
            )
        }

        stop()

        self.port = port
        self.activeProvider = provider
        self.gatewayToken = gatewayToken
        self.lastError = nil

        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.running = true
                    logger.info("Proxy listening on port \(port)")
                case .failed(let error):
                    self?.running = false
                    self?.lastError = error.localizedDescription
                    logger.error("Listener failed: \(error.localizedDescription)")
                case .cancelled:
                    self?.running = false
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.running = false
        }
    }

    func updateProvider(_ provider: Provider) {
        self.activeProvider = provider
    }

    func updateToken(_ token: String) {
        self.gatewayToken = token
    }

    func updateRectifierConfig(_ config: RectifierConfig) {
        self.rectifierConfig = config
    }

    func clearRequestLogs() {
        DispatchQueue.main.async {
            self.requestLogs.removeAll()
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                logger.error("Connection receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if nextBuffer.count > self.maxRequestBodyBytes {
                self.recordRequest(method: "?", path: "request", providerName: nil, status: 413, startedAt: Date(), error: "Request body too large")
                self.sendResponse(connection: connection, status: 413, body: self.errorBody("Request body too large"))
                return
            }

            if let request = self.parseHTTPRequest(nextBuffer) {
                self.queue.async {
                    self.processRequest(request: request, connection: connection, startedAt: Date())
                }
            } else if isComplete {
                self.recordRequest(method: "?", path: "request", providerName: nil, status: 400, startedAt: Date(), error: "Bad Request")
                self.sendResponse(connection: connection, status: 400, body: self.errorBody("Bad Request"))
            } else {
                self.receiveRequest(connection, buffer: nextBuffer)
            }
        }
    }

    private func processRequest(request: HTTPRequest, connection: NWConnection, startedAt: Date) {
        DispatchQueue.main.async { self.requestCount += 1 }

        // Strip query string for routing
        let path = request.path.components(separatedBy: "?").first ?? request.path
        let method = request.method

        logger.info("\(method) \(path)")

        if method == "GET" && (path == "/health" || path == "/claude-desktop/health") {
            recordRequest(method: method, path: path, providerName: nil, status: 200, startedAt: startedAt)
            sendResponse(connection: connection, status: 200, body: Data("{\"status\":\"ok\"}".utf8))
        } else if method == "HEAD" && isClaudeDesktopGatewayPath(path) {
            recordRequest(method: method, path: path, providerName: nil, status: 200, startedAt: startedAt)
            sendResponse(connection: connection, status: 200, body: Data(), includeBody: false)
        } else if method == "GET" && path.hasPrefix("/claude-desktop/v1/models") {
            handleModels(request: request, connection: connection, startedAt: startedAt)
        } else if method == "POST" && path == "/claude-desktop/v1/messages/count_tokens" {
            handleCountTokens(request: request, connection: connection, startedAt: startedAt)
        } else if method == "POST" && path == "/claude-desktop/v1/messages" {
            handleMessages(request: request, connection: connection, startedAt: startedAt)
        } else {
            logger.warning("Unhandled: \(method) \(path)")
            recordRequest(method: method, path: path, providerName: nil, status: 404, startedAt: startedAt, error: "Not Found")
            sendResponse(connection: connection, status: 404, body: errorBody("Not Found"))
        }
    }

    private func isClaudeDesktopGatewayPath(_ path: String) -> Bool {
        path == "/claude-desktop" ||
            path == "/claude-desktop/" ||
            path == "/cluade-desktop" ||
            path == "/cluade-desktop/"
    }

    // MARK: - Routes

    private func handleModels(request: HTTPRequest, connection: NWConnection, startedAt: Date) {
        guard validateAuth(request) else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 401, startedAt: startedAt, error: "Unauthorized")
            sendResponse(connection: connection, status: 401, body: errorBody("Unauthorized"))
            return
        }

        guard let provider = activeProvider else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 503, startedAt: startedAt, error: "No active provider")
            sendResponse(connection: connection, status: 503, body: errorBody("No active provider"))
            return
        }

        let models = provider.modelRoutes.map { route -> [String: Any] in
            var model: [String: Any] = [
                "type": "model",
                "id": route.routeId,
                "created_at": "2024-01-01T00:00:00Z",
            ]
            if route.supports1m {
                model["supports1m"] = true
            }
            return model
        }

        let response: [String: Any] = [
            "data": models,
            "has_more": false,
            "first_id": models.first?["id"] ?? "",
            "last_id": models.last?["id"] ?? "",
        ]

        let body = try! JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        recordRequest(method: request.method, path: request.path, providerName: provider.name, status: 200, startedAt: startedAt)
        sendResponse(connection: connection, status: 200, body: body, contentType: "application/json")
    }

    private func handleMessages(request: HTTPRequest, connection: NWConnection, startedAt: Date) {
        guard validateAuth(request) else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 401, startedAt: startedAt, error: "Unauthorized")
            sendResponse(connection: connection, status: 401, body: errorBody("Unauthorized"))
            return
        }

        guard let provider = activeProvider else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 503, startedAt: startedAt, error: "No active provider")
            sendResponse(connection: connection, status: 503, body: errorBody("No active provider"))
            return
        }

        let bodyData = requestBodyByMappingModelRoute(request.body, provider: provider)

        // Forward to upstream
        let isStreaming = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            .flatMap { $0["stream"] as? Bool } ?? false

        forwardToUpstream(
            provider: provider,
            path: "/v1/messages",
            body: bodyData,
            isStreaming: isStreaming,
            connection: connection,
            originalRequest: request,
            startedAt: startedAt
        )
    }

    private func handleCountTokens(request: HTTPRequest, connection: NWConnection, startedAt: Date) {
        guard validateAuth(request) else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 401, startedAt: startedAt, error: "Unauthorized")
            sendResponse(connection: connection, status: 401, body: errorBody("Unauthorized"))
            return
        }

        guard let provider = activeProvider else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 503, startedAt: startedAt, error: "No active provider")
            sendResponse(connection: connection, status: 503, body: errorBody("No active provider"))
            return
        }

        let bodyData = requestBodyByMappingModelRoute(request.body, provider: provider)
        forwardToUpstream(
            provider: provider,
            path: "/v1/messages/count_tokens",
            body: bodyData,
            isStreaming: false,
            connection: connection,
            originalRequest: request,
            startedAt: startedAt
        )
    }

    private func requestBodyByMappingModelRoute(_ body: Data, provider: Provider) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let modelId = json["model"] as? String,
              let route = provider.modelRoutes.first(where: { $0.routeId == modelId }) else {
            return body
        }

        json["model"] = route.upstreamModel
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    // MARK: - Upstream Forwarding

    private func forwardToUpstream(
        provider: Provider,
        path: String,
        body: Data,
        isStreaming: Bool,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date
    ) {
        guard let urlRequest = makeUpstreamRequest(provider: provider, path: path, body: body, isStreaming: isStreaming) else {
            recordRequest(method: originalRequest.method, path: originalRequest.path, providerName: provider.name, status: 502, startedAt: startedAt, error: "Invalid upstream URL")
            sendResponse(connection: connection, status: 502, body: errorBody("Invalid upstream URL"))
            return
        }

        if isStreaming {
            streamForward(request: urlRequest, provider: provider, path: path, body: body, connection: connection, originalRequest: originalRequest, startedAt: startedAt)
        } else {
            simpleForward(request: urlRequest, provider: provider, path: path, body: body, connection: connection, originalRequest: originalRequest, startedAt: startedAt)
        }
    }

    private func makeUpstreamRequest(provider: Provider, path: String, body: Data, isStreaming: Bool) -> URLRequest? {
        guard let url = URL(string: provider.baseURL + path) else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(provider.apiKey, forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        if isStreaming {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        return urlRequest
    }

    private func simpleForward(
        request: URLRequest,
        provider: Provider,
        path: String,
        body: Data,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date,
        rectifierRetried: Bool = false
    ) {
        let task = NetworkSessionManager.shared.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                let msg = "Upstream error: \(error.localizedDescription)"
                self.recordRequest(method: originalRequest.method, path: originalRequest.path, providerName: provider.name, status: 502, startedAt: startedAt, error: msg)
                self.sendResponse(connection: connection, status: 502, body: self.errorBody(msg))
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 502
            let body = data ?? Data()

            if status >= 400 {
                let upstreamMessage = self.extractUpstreamErrorMessage(from: body)
                if let retry = self.rectifiedBodyForRetry(
                    errorMessage: upstreamMessage,
                    body: body,
                    originalBody: request.httpBody ?? Data(),
                    rectifierRetried: rectifierRetried
                ), let retryRequest = self.makeUpstreamRequest(provider: provider, path: path, body: retry.body, isStreaming: false) {
                    logger.info("Rectifier applied \(retry.kind); retrying upstream request once")
                    self.simpleForward(
                        request: retryRequest,
                        provider: provider,
                        path: path,
                        body: retry.body,
                        connection: connection,
                        originalRequest: originalRequest,
                        startedAt: startedAt,
                        rectifierRetried: true
                    )
                    return
                }

                let enhanced = self.enhanceUpstreamError(status: status, body: body, provider: provider)
                self.recordRequest(
                    method: originalRequest.method,
                    path: originalRequest.path,
                    providerName: provider.name,
                    status: status,
                    startedAt: startedAt,
                    error: self.upstreamErrorSummary(status: status, message: upstreamMessage)
                )
                self.sendResponse(connection: connection, status: status, body: enhanced, contentType: "application/json")
            } else {
                self.recordRequest(method: originalRequest.method, path: originalRequest.path, providerName: provider.name, status: status, startedAt: startedAt)
                self.sendResponse(connection: connection, status: status, body: body, contentType: "application/json")
            }
        }
        task.resume()
    }

    private func streamForward(
        request: URLRequest,
        provider: Provider,
        path: String,
        body: Data,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date,
        rectifierRetried: Bool = false
    ) {
        Task { [weak self] in
            guard let self else { return }

            do {
                let (bytes, response) = try await NetworkSessionManager.shared.session.bytes(for: request)
                let httpResponse = response as? HTTPURLResponse
                let status = httpResponse?.statusCode ?? 502

                if status >= 400 {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                    }
                    let upstreamMessage = self.extractUpstreamErrorMessage(from: body)
                    if let retry = self.rectifiedBodyForRetry(
                        errorMessage: upstreamMessage,
                        body: body,
                        originalBody: request.httpBody ?? Data(),
                        rectifierRetried: rectifierRetried
                    ), let retryRequest = self.makeUpstreamRequest(provider: provider, path: path, body: retry.body, isStreaming: true) {
                        logger.info("Rectifier applied \(retry.kind); retrying streaming upstream request once")
                        self.streamForward(
                            request: retryRequest,
                            provider: provider,
                            path: path,
                            body: retry.body,
                            connection: connection,
                            originalRequest: originalRequest,
                            startedAt: startedAt,
                            rectifierRetried: true
                        )
                        return
                    }

                    let enhanced = self.enhanceUpstreamError(status: status, body: body, provider: provider)
                    self.recordRequest(
                        method: originalRequest.method,
                        path: originalRequest.path,
                        providerName: provider.name,
                        status: status,
                        startedAt: startedAt,
                        error: self.upstreamErrorSummary(status: status, message: upstreamMessage)
                    )
                    self.sendResponse(connection: connection, status: status, body: enhanced, contentType: "application/json")
                    return
                }

                let header = "HTTP/1.1 \(status) \(self.statusText(for: status))\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                try await self.sendContent(Data(header.utf8), connection: connection)

                var chunk = Data()
                chunk.reserveCapacity(4096)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 4096 {
                        try await self.sendContent(chunk, connection: connection)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty {
                    try await self.sendContent(chunk, connection: connection)
                }
                self.recordRequest(method: originalRequest.method, path: originalRequest.path, providerName: provider.name, status: status, startedAt: startedAt)
                connection.cancel()
            } catch {
                let msg = "Upstream error: \(error.localizedDescription)"
                self.recordRequest(method: originalRequest.method, path: originalRequest.path, providerName: provider.name, status: 502, startedAt: startedAt, error: msg)
                self.sendResponse(connection: connection, status: 502, body: self.errorBody(msg))
            }
        }
    }

    // MARK: - Rectifier

    private func rectifiedBodyForRetry(
        errorMessage: String?,
        body _: Data,
        originalBody: Data,
        rectifierRetried: Bool
    ) -> (body: Data, kind: String)? {
        guard rectifierConfig.enabled, !rectifierRetried else { return nil }

        if rectifierConfig.requestThinkingSignature,
           shouldRectifyThinkingSignature(errorMessage),
           let rectified = rectifyThinkingSignature(originalBody) {
            return (rectified, "thinking_signature")
        }

        if rectifierConfig.requestThinkingBudget,
           shouldRectifyThinkingBudget(errorMessage),
           let rectified = rectifyThinkingBudget(originalBody) {
            return (rectified, "thinking_budget")
        }

        return nil
    }

    private func shouldRectifyThinkingSignature(_ message: String?) -> Bool {
        guard let message = message?.lowercased(), !message.isEmpty else { return false }

        let indicators = [
            "invalid signature in thinking block",
            "thought signature not valid",
            "thought signature is not valid",
            "invalid thought signature",
            "must start with a thinking block",
            "expected `thinking` or `redacted_thinking`, but found `tool_use`",
            "signature: field required",
            "signature: extra inputs are not permitted",
            "thinking block cannot be modified",
            "redacted_thinking block cannot be modified",
            "illegal request",
            "invalid request",
        ]

        return indicators.contains { message.contains($0) }
    }

    private func shouldRectifyThinkingBudget(_ message: String?) -> Bool {
        guard let message = message?.lowercased(), !message.isEmpty else { return false }
        let hasBudgetTokens = message.contains("budget_tokens") || message.contains("budget tokens")
        let hasThinking = message.contains("thinking")
        let hasMinimumConstraint = message.contains("1024") ||
            message.contains("greater than or equal") ||
            message.contains("at least") ||
            message.contains(">=")
        return hasBudgetTokens && hasThinking && hasMinimumConstraint
    }

    private func rectifyThinkingSignature(_ body: Data) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        var changed = false

        if var messages = json["messages"] as? [[String: Any]] {
            for messageIndex in messages.indices {
                guard let content = messages[messageIndex]["content"] as? [[String: Any]] else { continue }
                var nextContent: [[String: Any]] = []
                var contentChanged = false

                for var block in content {
                    let type = block["type"] as? String
                    if type == "thinking" || type == "redacted_thinking" {
                        changed = true
                        contentChanged = true
                        continue
                    }
                    if block["signature"] != nil {
                        block.removeValue(forKey: "signature")
                        changed = true
                        contentChanged = true
                    }
                    nextContent.append(block)
                }

                if contentChanged {
                    messages[messageIndex]["content"] = nextContent
                }
            }
            json["messages"] = messages
        }

        if shouldRemoveTopLevelThinking(from: json) {
            json.removeValue(forKey: "thinking")
            changed = true
        }

        guard changed else { return nil }
        return try? JSONSerialization.data(withJSONObject: json)
    }

    private func shouldRemoveTopLevelThinking(from json: [String: Any]) -> Bool {
        guard let thinking = json["thinking"] as? [String: Any],
              thinking["type"] as? String == "enabled",
              let messages = json["messages"] as? [[String: Any]],
              let lastAssistant = messages.last(where: { ($0["role"] as? String) == "assistant" }),
              let content = lastAssistant["content"] as? [[String: Any]],
              let firstBlock = content.first else {
            return false
        }

        let firstType = firstBlock["type"] as? String
        guard firstType != "thinking", firstType != "redacted_thinking" else { return false }
        return content.contains { ($0["type"] as? String) == "tool_use" }
    }

    private func rectifyThinkingBudget(_ body: Data) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let thinking = json["thinking"] as? [String: Any],
           thinking["type"] as? String == "adaptive" {
            return nil
        }

        var changed = false
        var thinking = (json["thinking"] as? [String: Any]) ?? [:]

        if thinking["type"] as? String != "enabled" {
            thinking["type"] = "enabled"
            changed = true
        }

        if (thinking["budget_tokens"] as? Int) != 32_000 {
            thinking["budget_tokens"] = 32_000
            changed = true
        }

        json["thinking"] = thinking

        let maxTokens = json["max_tokens"] as? Int
        if maxTokens == nil || (maxTokens ?? 0) < 32_001 {
            json["max_tokens"] = 64_000
            changed = true
        }

        guard changed else { return nil }
        return try? JSONSerialization.data(withJSONObject: json)
    }

    private func extractUpstreamErrorMessage(from body: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let message = (json["error"] as? [String: Any])?["message"] as? String {
                return message
            }
            if let detail = (json["error"] as? [String: Any])?["detail"] as? String {
                return detail
            }
            if let message = json["message"] as? String {
                return message
            }
            if let detail = json["detail"] as? String {
                return detail
            }
            if let message = (json["base_resp"] as? [String: Any])?["status_msg"] as? String {
                return message
            }
        }
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func recordRequest(
        method: String,
        path: String,
        providerName: String?,
        status: Int,
        startedAt: Date,
        error: String? = nil
    ) {
        let log = ProxyRequestLog(
            timestamp: Date(),
            method: method,
            path: path.components(separatedBy: "?").first ?? path,
            providerName: providerName,
            status: status,
            duration: Date().timeIntervalSince(startedAt),
            error: error
        )

        DispatchQueue.main.async {
            self.requestLogs.insert(log, at: 0)
            if self.requestLogs.count > 100 {
                self.requestLogs.removeLast(self.requestLogs.count - 100)
            }
        }
    }

    // MARK: - Error Enhancement

    private func enhanceUpstreamError(status: Int, body: Data, provider: Provider) -> Data {
        let upstreamBody = parseJSONBody(body) ?? String(data: body, encoding: .utf8) ?? ""
        let errorJson = upstreamBody as? [String: Any] ?? [:]
        let upstreamError = errorJson["error"] as? [String: Any]
        let baseResp = errorJson["base_resp"] as? [String: Any]
        let upstreamMsg = extractUpstreamErrorMessage(from: body)
        let detail = upstreamMsg.map { ": \($0)" } ?? ""

        var error: [String: Any] = [
            "message": "Upstream provider '\(provider.name)' returned HTTP \(status)\(detail)",
            "type": upstreamError?["type"] as? String ?? "upstream_error",
            "provider": provider.name,
            "upstream_status": status,
            "upstream_body": upstreamBody,
        ]

        if let code = upstreamError?["code"] ?? baseResp?["status_code"] {
            error["code"] = code
        } else if status == 400 {
            error["code"] = "claude_switch_upstream_400"
        }

        if let param = upstreamError?["param"] {
            error["param"] = param
        }

        let enhanced: [String: Any] = [
            "error": error
        ]

        return (try? JSONSerialization.data(withJSONObject: enhanced)) ?? body
    }

    private func parseJSONBody(_ body: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: body)
    }

    private func upstreamErrorSummary(status: Int, message: String?) -> String {
        guard let message, !message.isEmpty else {
            return "Upstream returned HTTP \(status)"
        }
        return "Upstream returned HTTP \(status): \(message)"
    }

    // MARK: - Auth

    private func validateAuth(_ request: HTTPRequest) -> Bool {
        let expected = self.gatewayToken
        guard !expected.isEmpty else { return true }
        let match = request.bearerToken() == expected
        logger.info("Auth result: match=\(match)")
        return match
    }

    // MARK: - HTTP Parsing

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        guard let headerSection = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }

        let requestLineParts = firstLine.components(separatedBy: " ")
        guard requestLineParts.count >= 2 else { return nil }

        let method = requestLineParts[0]
        let path = requestLineParts[1]

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if let colonIdx = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name, value))
            }
        }

        let contentLength = headers
            .first { $0.0.lowercased() == "content-length" }
            .flatMap { Int($0.1) } ?? 0
        guard contentLength >= 0 else { return nil }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else { return nil }
        let bodyData = Data(data[bodyStart..<bodyEnd])

        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    // MARK: - Response Sending

    private func sendResponse(connection: NWConnection, status: Int, body: Data, contentType: String = "application/json", includeBody: Bool = true) {
        let statusText = statusText(for: status)
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        if includeBody {
            responseData.append(body)
        }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    private func sendContent(_ data: Data, connection: NWConnection) async throws {
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

    private func errorBody(_ message: String) -> Data {
        let json: [String: Any] = ["error": ["message": message, "type": "proxy_error"] as [String: Any]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{\"error\":{\"message\":\"\(message)\"}}".utf8)
    }
}
