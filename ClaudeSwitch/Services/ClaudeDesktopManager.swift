import Foundation
import os.log

private let logger = Logger(subsystem: "com.claude.switch", category: "claude-desktop")

enum ClaudeDesktopManager {

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

        let models: [Any] = provider.modelRoutes.map { route in
            let hasLabel = route.labelOverride?.isEmpty == false
            if hasLabel || route.supports1m {
                var entry: [String: Any] = ["name": route.routeId]
                if hasLabel {
                    entry["labelOverride"] = route.labelOverride
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
