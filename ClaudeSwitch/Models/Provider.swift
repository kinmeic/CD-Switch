import Foundation

enum ModelRole: String, Codable, CaseIterable {
    case sonnet = "claude-sonnet-4-6"
    case opus = "claude-opus-4-7"
    case haiku = "claude-haiku-4-5"

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        }
    }
}

struct ModelRoute: Codable, Identifiable, Equatable {
    var id = UUID()
    var routeId: String
    var upstreamModel: String
    var labelOverride: String?
    var supports1m: Bool

    enum CodingKeys: String, CodingKey {
        case routeId, upstreamModel, labelOverride, supports1m
    }

    var role: ModelRole {
        get { ModelRole(rawValue: routeId) ?? .haiku }
        set { routeId = newValue.rawValue }
    }

    static let defaultRoutes: [ModelRoute] = [
        ModelRoute(routeId: "claude-sonnet-4-6", upstreamModel: "", labelOverride: nil, supports1m: true),
        ModelRoute(routeId: "claude-opus-4-7", upstreamModel: "", labelOverride: nil, supports1m: true),
        ModelRoute(routeId: "claude-haiku-4-5", upstreamModel: "", labelOverride: nil, supports1m: true),
    ]
}

struct Provider: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var modelRoutes: [ModelRoute]

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String, modelRoutes: [ModelRoute] = ModelRoute.defaultRoutes) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelRoutes = modelRoutes
    }

    static func == (lhs: Provider, rhs: Provider) -> Bool {
        lhs.id == rhs.id
    }
}
