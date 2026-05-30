import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: "com.claude.switch", category: "app")

final class AppState: ObservableObject {
    static let shared = AppState()

    var quitRequested = false

    @Published var providers: [Provider] {
        didSet { saveProviders() }
    }
    @Published var activeProviderId: UUID? {
        didSet { saveActiveProviderId() }
    }
    @Published var proxyPort: Int {
        didSet {
            AppEnvironment.shared.set(proxyPort, forKey: "proxyPort")
            restartProxyAfterPortChange(from: oldValue)
        }
    }
    @Published var gatewayToken: String {
        didSet {
            AppEnvironment.shared.set(gatewayToken, forKey: "gatewayToken")
            proxyServer.updateToken(gatewayToken)
        }
    }
    @Published var autoStartProxy: Bool {
        didSet { AppEnvironment.shared.set(autoStartProxy, forKey: "autoStartProxy") }
    }
    @Published var claudeDesktopPath: String {
        didSet { AppEnvironment.shared.set(claudeDesktopPath, forKey: "claudeDesktopPath") }
    }
    @Published var claudeModelIds: [String] {
        didSet {
            let normalized = ModelRoute.normalizedClaudeModelIds(claudeModelIds)
            if claudeModelIds != normalized {
                claudeModelIds = normalized
                return
            }
            AppEnvironment.shared.set(normalized, forKey: "claudeModelIds")
        }
    }
    @Published private(set) var proxyRunning = false
    @Published private(set) var requestLogs: [ProxyRequestLog] = []

    let proxyServer = ProxyServer()
    private var cancellables = Set<AnyCancellable>()

    var activeProvider: Provider? {
        providers.first { $0.id == activeProviderId }
    }

    var isApplied: Bool {
        guard activeProvider != nil else { return false }
        // Check if the profile file exists and matches
        let profilePath = "\(AppEnvironment.configLibraryPath)/\(AppEnvironment.profileId).json"
        guard FileManager.default.fileExists(atPath: profilePath) else { return false }
        guard let data = FileManager.default.contents(atPath: profilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseUrl = json["inferenceGatewayBaseUrl"] as? String else { return false }
        return baseUrl.contains(":\(proxyPort)")
    }

    private init() {
        let defaults = AppEnvironment.shared
        self.proxyPort = defaults.object(forKey: "proxyPort") as? Int ?? AppEnvironment.defaultPort
        self.autoStartProxy = defaults.bool(forKey: "autoStartProxy")
        self.claudeDesktopPath = defaults.string(forKey: "claudeDesktopPath") ?? AppEnvironment.defaultClaudeDesktopPath
        self.claudeModelIds = ModelRoute.normalizedClaudeModelIds(defaults.stringArray(forKey: "claudeModelIds") ?? ModelRoute.defaultClaudeModelIds)

        // Load or generate gateway token — persisted explicitly since didSet won't fire in init
        if let stored = defaults.string(forKey: "gatewayToken"), !stored.isEmpty {
            self.gatewayToken = stored
        } else {
            let newToken = "cs-\(UUID().uuidString.lowercased())"
            self.gatewayToken = newToken
            defaults.set(newToken, forKey: "gatewayToken")
        }

        // Load providers
        if let data = defaults.data(forKey: "providers"),
           let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            self.providers = decoded
        } else {
            self.providers = PresetProviders.builtInProviders()
        }

        self.activeProviderId = {
            if let str = defaults.string(forKey: "activeProviderId") {
                return UUID(uuidString: str)
            }
            return nil
        }()

        // Bind proxy state
        proxyServer.$running
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.proxyRunning = running
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        proxyServer.$requestLogs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] logs in
                self?.requestLogs = logs
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Provider Management

    func addProvider(_ provider: Provider) {
        var normalized = provider
        normalized.modelRoutes = normalized.modelRoutes.map(\.normalized)
        providers.append(normalized)
    }

    func removeProvider(_ provider: Provider) {
        providers.removeAll { $0.id == provider.id }
        if activeProviderId == provider.id {
            activeProviderId = nil
        }
    }

    func updateProvider(_ provider: Provider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            var normalized = provider
            normalized.modelRoutes = normalized.modelRoutes.map(\.normalized)
            let isActiveProvider = normalized.id == activeProviderId
            providers[idx] = normalized
            objectWillChange.send()
            if proxyServer.running, isActiveProvider {
                syncRunningProxy(provider: normalized, showRestartNotice: true)
            }
        }
    }

    func duplicateProvider(_ provider: Provider) -> Provider {
        var copy = provider
        copy.id = UUID()
        copy.name = "\(provider.name) Copy"
        addProvider(copy)
        return copy
    }

    func setActive(_ provider: Provider) {
        guard activeProviderId != provider.id else { return }
        activeProviderId = provider.id
        if proxyServer.running, let activeProvider {
            syncRunningProxy(provider: activeProvider, showRestartNotice: true)
        }
    }

    // MARK: - Proxy

    func startProxy() {
        guard let provider = activeProvider else {
            proxyServer.lastError = "Select a provider before starting proxy"
            logger.warning("No active provider selected")
            return
        }

        let preflightErrors = preflightErrors(provider: provider)
        guard preflightErrors.isEmpty else {
            proxyServer.lastError = preflightErrors.joined(separator: "\n")
            logger.error("Preflight failed: \(preflightErrors.joined(separator: "; "))")
            return
        }

        // Apply config before starting
        do {
            try ClaudeDesktopManager.applyProvider(provider, port: proxyPort, gatewayToken: gatewayToken)
        } catch {
            proxyServer.lastError = "Failed to apply Claude Desktop config: \(error.localizedDescription)"
            logger.error("Failed to apply config: \(error.localizedDescription)")
            return
        }

        do {
            try proxyServer.start(port: proxyPort, provider: provider, gatewayToken: gatewayToken)
            logger.info("Started proxy on port \(self.proxyPort)")
        } catch {
            proxyServer.lastError = "Failed to start proxy: \(error.localizedDescription)"
            logger.error("Failed to start proxy: \(error.localizedDescription)")
        }
    }

    func stopProxy() {
        proxyServer.stop()
        logger.info("Stopped proxy")
    }

    func requestQuit() {
        quitRequested = true
        NSApp.terminate(nil)
    }

    // MARK: - Persistence

    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            AppEnvironment.shared.set(data, forKey: "providers")
        }
    }

    private func saveActiveProviderId() {
        AppEnvironment.shared.set(activeProviderId?.uuidString, forKey: "activeProviderId")
    }

    private func restartProxyAfterPortChange(from oldPort: Int) {
        guard oldPort != proxyPort, proxyServer.running else { return }
        guard (1...65535).contains(proxyPort) else {
            proxyServer.lastError = "Port must be between 1 and 65535"
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.startProxy()
        }
    }

    private func syncRunningProxy(provider: Provider, showRestartNotice: Bool) {
        let preflightErrors = preflightErrors(provider: provider)
        guard preflightErrors.isEmpty else {
            proxyServer.lastError = preflightErrors.joined(separator: "\n")
            logger.error("Preflight failed while updating running proxy: \(preflightErrors.joined(separator: "; "))")
            return
        }

        do {
            try ClaudeDesktopManager.applyProvider(provider, port: proxyPort, gatewayToken: gatewayToken)
            proxyServer.updateProvider(provider)
            logger.info("Updated running proxy provider and Claude Desktop config")
            if showRestartNotice {
                showClaudeDesktopRestartNotice()
            }
        } catch {
            proxyServer.lastError = "Failed to apply Claude Desktop config: \(error.localizedDescription)"
            logger.error("Failed to apply config while updating running proxy: \(error.localizedDescription)")
        }
    }

    private func showClaudeDesktopRestartNotice() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Claude Desktop Restart Required"
            alert.informativeText = "Restart Claude Desktop for changes to take effect."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func preflightErrors(provider: Provider) -> [String] {
        var errors: [String] = []

        if !(1...65535).contains(proxyPort) {
            errors.append("Port must be between 1 and 65535")
        } else if !proxyServer.running || proxyServer.port != proxyPort {
            let occupants = portOccupants(proxyPort)
            if !occupants.isEmpty {
                errors.append("Port \(proxyPort) is already in use by \(occupants.joined(separator: ", "))")
            }
        }

        let trimmedBaseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmedBaseURL),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host != nil {
            // Valid enough for a provider endpoint.
        } else {
            errors.append("Active provider has an invalid Base URL")
        }

        if provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Active provider API key is empty")
        }

        if provider.modelRoutes.isEmpty {
            errors.append("Active provider has no model routes")
        } else if provider.modelRoutes.contains(where: { $0.routeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            errors.append("Every model route needs a Claude Desktop model ID")
        } else if provider.modelRoutes.contains(where: { $0.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            errors.append("Every model route needs an actual upstream model")
        }

        let configLibraryURL = URL(fileURLWithPath: AppEnvironment.configLibraryPath)
        let configParentURL = configLibraryURL.deletingLastPathComponent()
        let checkURL = FileManager.default.fileExists(atPath: configLibraryURL.path) ? configLibraryURL : configParentURL
        if !FileManager.default.isWritableFile(atPath: checkURL.path) {
            errors.append("Claude Desktop config directory is not writable: \(checkURL.path)")
        }

        return errors
    }

    private func portOccupants(_ port: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                return "\(parts[0]) (pid \(parts[1]))"
            }
    }

    // MARK: - Test Connection

    func testConnection(provider: Provider, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: provider.baseURL + "/v1/messages") else {
            completion(.failure(NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(provider.apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let testBody: [String: Any] = [
            "model": provider.modelRoutes.first?.upstreamModel ?? "claude-haiku-4-5",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: testBody)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 || status == 400 || status == 401 || status == 403 {
                let msg: String
                if status == 200 {
                    msg = "Connection successful (HTTP 200)"
                } else if status == 401 || status == 403 {
                    msg = "API key rejected (HTTP \(status))"
                } else {
                    msg = "Server reachable (HTTP \(status))"
                }
                DispatchQueue.main.async { completion(.success(msg)) }
            } else {
                let msg = "Unexpected response (HTTP \(status))"
                DispatchQueue.main.async { completion(.failure(NSError(domain: "test", code: status, userInfo: [NSLocalizedDescriptionKey: msg]))) }
            }
        }.resume()
    }
}
