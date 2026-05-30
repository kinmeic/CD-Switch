import Foundation

enum PresetProviders {
    static let officialProvider = Provider(
        id: Provider.officialProviderId,
        name: "Claude Desktop Official",
        baseURL: "",
        apiKey: "",
        modelRoutes: [],
        isOfficial: true
    )

    static func builtInProviders() -> [Provider] {
        [officialProvider]
    }
}
