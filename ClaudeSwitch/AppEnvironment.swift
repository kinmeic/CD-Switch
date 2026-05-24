import Foundation

enum AppEnvironment {
    static let suiteName = "com.claude.switch"
    static let shared: UserDefaults = {
        UserDefaults(suiteName: suiteName) ?? .standard
    }()

    static let profileId = "00000000-0000-4000-8000-000000157210"
    static let profileName = "ClaudeSwitch"
    static let defaultPort = 16826

    static var defaultClaudeDesktopPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Claude-3p").path
    }

    static var claudeDesktopPath: String {
        AppEnvironment.shared.string(forKey: "claudeDesktopPath") ?? defaultClaudeDesktopPath
    }

    static var configLibraryPath: String {
        "\(claudeDesktopPath)/configLibrary"
    }

    static var claudeDesktopConfigPath: String {
        "\(claudeDesktopPath)/claude_desktop_config.json"
    }
}
