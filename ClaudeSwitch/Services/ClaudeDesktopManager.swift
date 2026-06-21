import Foundation
import os.log

private let logger = Logger(subsystem: "com.claude.switch", category: "claude-desktop")

enum ClaudeDesktopManager {

    // MARK: - Status / Drift Detection

    /// Claude Desktop profile 的当前状态，用于检测漂移（被其他工具覆盖、模型名失效等）。
    struct Status {
        /// profile 文件是否存在
        let configured: Bool
        /// profile 的 inferenceGatewayBaseUrl 不含当前端口（被覆盖或端口已变）
        let baseURLDrift: Bool
        /// profile 的 inferenceModels 含非安全模型名（会触发 fail-all 拒收整组）
        let staleRawModels: Bool
        /// 当前 provider 解析后无可用路由
        let missingRouteMappings: Bool
    }

    static func status(port: Int, activeProvider: Provider?) -> Status {
        let paths = resolvePaths()
        let configured = FileManager.default.fileExists(atPath: paths.profilePath)

        var baseURLDrift = false
        var staleRawModels = false

        if let data = FileManager.default.contents(atPath: paths.profilePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let baseUrl = json["inferenceGatewayBaseUrl"] as? String,
               !baseUrl.contains(":\(port)") {
                baseURLDrift = true
            }
            if let models = json["inferenceModels"] as? [Any] {
                staleRawModels = models.contains { item in
                    let name: String? = {
                        if let s = item as? String { return s }
                        if let obj = item as? [String: Any] { return obj["name"] as? String }
                        return nil
                    }()
                    return name.map { !ModelRouteResolver.isClaudeSafeModelId($0) } ?? false
                }
            }
        }

        let missingRouteMappings: Bool
        if let provider = activeProvider, !provider.isOfficial {
            missingRouteMappings = ModelRouteResolver.resolveRoutes(for: provider).isEmpty
        } else {
            missingRouteMappings = false
        }

        return Status(
            configured: configured,
            baseURLDrift: baseURLDrift,
            staleRawModels: staleRawModels,
            missingRouteMappings: missingRouteMappings
        )
    }

    // MARK: - Apply Provider

    static func applyProvider(_ provider: Provider, port: Int, gatewayToken: String) throws {
        let paths = resolvePaths()
        let snapshot = snapshotFiles([paths.profilePath, paths.metaPath, paths.configPath])

        do {
            try ensureDirectoryExists(paths.configLibraryPath)
            try writeProfile(provider: provider, port: port, gatewayToken: gatewayToken, profilePath: paths.profilePath)
            try writeMeta(metaPath: paths.metaPath)
            try setDeploymentMode(paths.configPath, mode: "3p")
            logger.info("Applied provider to Claude Desktop config")
        } catch {
            restoreFiles(snapshot)
            logger.error("Rolled back Claude Desktop config after apply failure: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Restore Official

    static func restoreOfficial() throws {
        let paths = resolvePaths()

        // Remove our profile file
        try? FileManager.default.removeItem(atPath: paths.profilePath)

        // Update _meta.json: remove our entry, pick next available or clear
        try updateMetaForRemoval(metaPath: paths.metaPath)

        // Set deployment mode back to 1p
        try setDeploymentMode(paths.configPath, mode: "1p")

        logger.info("Restored Claude Desktop to official mode")
    }

    // MARK: - Paths

    private struct Paths {
        let configPath: String
        let configLibraryPath: String
        let profilePath: String
        let metaPath: String
    }

    private static func resolvePaths() -> Paths {
        let base = AppEnvironment.claudeDesktopPath
        return Paths(
            configPath: "\(base)/claude_desktop_config.json",
            configLibraryPath: "\(base)/configLibrary",
            profilePath: "\(base)/configLibrary/\(AppEnvironment.profileId).json",
            metaPath: "\(base)/configLibrary/_meta.json"
        )
    }

    // MARK: - Profile Writing

    private static func writeProfile(provider: Provider, port: Int, gatewayToken: String, profilePath: String) throws {
        let baseURL = "http://127.0.0.1:\(port)/claude-desktop"

        var profile: [String: Any] = [
            "coworkEgressAllowedHosts": ["*"],
            "disableDeepLinkRegistration": true,
            "disableDeploymentModeChooser": true,
            "disableEssentialTelemetry": true,
            "disableNonessentialServices": true,
            "disableNonessentialTelemetry": true,
            "inferenceGatewayApiKey": gatewayToken,
            "inferenceGatewayAuthScheme": "bearer",
            "inferenceGatewayBaseUrl": baseURL,
            "inferenceProvider": "gateway",
        ]

        // 用解析后的安全路由写入：不安全 routeId 自动借用安全名，真实上游名落到 labelOverride，
        // 避免触发 Claude Desktop 1.12603.1+ 的 fail-all 校验拒收整组模型。
        let routes = ModelRouteResolver.resolveRoutes(for: provider)
        let models: [Any] = routes.map { route in
            if route.labelOverride != nil || route.supports1m {
                var entry: [String: Any] = ["name": route.routeId]
                if let label = route.labelOverride {
                    entry["labelOverride"] = label
                }
                if route.supports1m {
                    entry["supports1m"] = true
                }
                return entry as Any
            } else {
                return route.routeId as Any
            }
        }
        profile["inferenceModels"] = models

        try writeJSON(profilePath, profile)
    }

    // MARK: - _meta.json Management

    private static func writeMeta(metaPath: String) throws {
        var meta = readJSON(metaPath) as? [String: Any] ?? [:]

        // Remove our existing entry if present
        var entries = meta["entries"] as? [[String: Any]] ?? []
        entries.removeAll { $0["id"] as? String == AppEnvironment.profileId }

        // Add our entry
        entries.append([
            "id": AppEnvironment.profileId,
            "name": AppEnvironment.profileName,
        ])

        meta["entries"] = entries
        meta["appliedId"] = AppEnvironment.profileId

        try writeJSON(metaPath, meta)
    }

    private static func updateMetaForRemoval(metaPath: String) throws {
        var meta = readJSON(metaPath) as? [String: Any] ?? [:]
        var entries = meta["entries"] as? [[String: Any]] ?? []

        // Remove our entry
        entries.removeAll { $0["id"] as? String == AppEnvironment.profileId }

        meta["entries"] = entries

        // If we were the applied one, pick the next available or clear
        if meta["appliedId"] as? String == AppEnvironment.profileId {
            meta["appliedId"] = entries.first?["id"] ?? ""
        }

        try writeJSON(metaPath, meta)
    }

    // MARK: - Deployment Mode

    private static func setDeploymentMode(_ configPath: String, mode: String) throws {
        var config = readJSON(configPath) as? [String: Any] ?? [:]
        config["deploymentMode"] = mode
        try writeJSON(configPath, config)
    }

    // MARK: - Helpers

    private static func ensureDirectoryExists(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private static func readJSON(_ path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func writeJSON(_ path: String, _ obj: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func snapshotFiles(_ paths: [String]) -> [String: Data?] {
        var snapshot: [String: Data?] = [:]
        for path in paths {
            snapshot[path] = FileManager.default.contents(atPath: path)
        }
        return snapshot
    }

    private static func restoreFiles(_ snapshot: [String: Data?]) {
        for (path, data) in snapshot {
            if let data {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } else if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
