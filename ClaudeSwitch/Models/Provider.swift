import Foundation

struct ModelRoute: Codable, Identifiable, Equatable {
    static let defaultClaudeModelIds = [
        "claude-sonnet-4-6",
        "claude-opus-4-7",
        "claude-haiku-4-5",
    ]

    var id = UUID()
    var routeId: String
    var upstreamModel: String
    var labelOverride: String?
    var supports1m: Bool

    enum CodingKeys: String, CodingKey {
        case routeId, upstreamModel, labelOverride, supports1m
    }

    static let defaultRoutes: [ModelRoute] = [
        ModelRoute(routeId: defaultClaudeModelIds[0], upstreamModel: "", labelOverride: nil, supports1m: true),
        ModelRoute(routeId: defaultClaudeModelIds[1], upstreamModel: "", labelOverride: nil, supports1m: true),
        ModelRoute(routeId: defaultClaudeModelIds[2], upstreamModel: "", labelOverride: nil, supports1m: true),
    ]

    var normalized: ModelRoute {
        var route = self
        route.routeId = route.routeId.trimmingCharacters(in: .whitespacesAndNewlines)
        route.upstreamModel = route.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
        route.labelOverride = route.labelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if route.labelOverride?.isEmpty == true {
            route.labelOverride = nil
        }
        return route
    }

    static func normalizedClaudeModelIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        let cleaned = ids.compactMap { raw -> String? in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seen.contains(id) else { return nil }
            seen.insert(id)
            return id
        }
        return cleaned.isEmpty ? defaultClaudeModelIds : cleaned
    }
}

struct Provider: Identifiable, Codable, Equatable {
    static let officialProviderId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var modelRoutes: [ModelRoute]
    var isOfficial: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, modelRoutes, isOfficial
    }

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String, modelRoutes: [ModelRoute] = ModelRoute.defaultRoutes, isOfficial: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelRoutes = modelRoutes
        self.isOfficial = isOfficial
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        modelRoutes = try container.decode([ModelRoute].self, forKey: .modelRoutes)
        isOfficial = try container.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
    }
}
