import Foundation
import os.log

private let logger = Logger(subsystem: "com.claude.switch", category: "route-resolver")

/// Claude Desktop 模型路由解析与请求映射。
///
/// Claude Desktop 1.12603.1+ 的 fail-all 校验器只放行 `claude-{sonnet,opus,haiku,fable}-*`
/// 这类安全名；profile 里出现一个不合规模型名会拒收整组。本类型负责：
/// 1. 校验 routeId 是否安全（`isClaudeSafeModelId`）；
/// 2. 把不安全的 routeId 借用为安全目录名，真实上游名落到 `labelOverride`（`resolveRoutes`）；
/// 3. 请求侧把 Claude Desktop 发来的 model 名映射回真实上游模型，兼容带日期后缀的全名、
///    `[1m]` 后缀、opus 新老别名、fable 降级到 opus（`mapRequestModel`）。
enum ModelRouteResolver {

    /// fail-all 校验器认可的角色前缀。
    static let safeRolePrefixes = ["sonnet", "opus", "haiku", "fable"]

    /// 默认安全路由目录（写入 profile 与 UI 选项共用）。
    /// fable 置末：非安全 route 借用安全名时按 sonnet→opus→haiku 顺序分配。
    static let defaultClaudeModelIds = [
        "claude-sonnet-4-6",
        "claude-opus-4-8",
        "claude-haiku-4-5",
        "claude-fable-5",
    ]

    /// opus 新老 routeId 在滚动发布期间互通。
    static let currentOpusRouteId = "claude-opus-4-8"
    static let legacyOpusRouteId = "claude-opus-4-7"

    /// 解析后的安全路由：routeId 安全、真实上游模型仅存内部、显示名写入 profile。
    struct ResolvedRoute: Equatable {
        let routeId: String
        let upstreamModel: String
        let labelOverride: String?
        let supports1m: Bool
    }

    // MARK: - Claude-safe 校验

    /// 是否为 Claude Desktop fail-all 校验器放行的安全模型名。
    static func isClaudeSafeModelId(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.contains("[1m]") else { return false }

        let routeTail: String
        if normalized.hasPrefix("anthropic/claude-") {
            routeTail = String(normalized.dropFirst("anthropic/claude-".count))
        } else if normalized.hasPrefix("claude-") {
            routeTail = String(normalized.dropFirst("claude-".count))
        } else {
            return false
        }

        // 角色前缀后必须还有实际模型标识，拒绝 claude-sonnet- 这类退化值
        guard !routeTail.isEmpty else { return false }
        return safeRolePrefixes.contains { role in
            routeTail.hasPrefix("\(role)-") && routeTail.count > "\(role)-".count
        }
    }

    // MARK: - Resolve（写入 profile 用）

    /// 把 provider 的原始路由解析为安全路由：不安全的 routeId 自动借用安全名，
    /// 真实上游名落到 `labelOverride`，确保不触发 Claude Desktop fail-all。
    static func resolveRoutes(for provider: Provider) -> [ResolvedRoute] {
        var reserved = Set<String>()
        var result: [ResolvedRoute] = []

        for route in provider.modelRoutes.map(\.normalized) {
            let routeId = route.routeId
            let upstream = route.upstreamModel
            guard !routeId.isEmpty, !upstream.isEmpty else { continue }

            let resolvedId: String
            let label: String?
            if isClaudeSafeModelId(routeId) {
                resolvedId = routeId
                label = route.labelOverride
            } else {
                // 借用一个未占用的安全目录名，真实上游名作显示名
                resolvedId = nextAvailableSafeRouteId(reserved: reserved, existing: result)
                label = route.labelOverride ?? upstream
            }
            reserved.insert(resolvedId.lowercased())

            result.append(ResolvedRoute(
                routeId: resolvedId,
                upstreamModel: upstream,
                labelOverride: label,
                supports1m: route.supports1m
            ))
        }

        // 同名去重：保留 supports1m 为真的那条
        result.sort { a, b in
            a.routeId.caseInsensitiveCompare(b.routeId) == .orderedSame
                ? (a.supports1m && !b.supports1m)
                : a.routeId.caseInsensitiveCompare(b.routeId) == .orderedAscending
        }
        var seen = Set<String>()
        result = result.filter { seen.insert($0.routeId.lowercased()).inserted }

        return result
    }

    private static func nextAvailableSafeRouteId(reserved: Set<String>, existing: [ResolvedRoute]) -> String {
        for candidate in defaultClaudeModelIds {
            let lower = candidate.lowercased()
            if !reserved.contains(lower) && !existing.contains(where: { $0.routeId.lowercased() == lower }) {
                return candidate
            }
        }
        var index = 2
        while true {
            let candidate = "\(defaultClaudeModelIds[0])-r\(index)"
            let lower = candidate.lowercased()
            if !reserved.contains(lower) && !existing.contains(where: { $0.routeId.lowercased() == lower }) {
                return candidate
            }
            index += 1
        }
    }

    // MARK: - Request mapping（请求侧反向映射）

    /// 把 Claude Desktop 发来的 model 名映射到真实上游模型。
    /// 匹配顺序：精确 → `[1m]` 剥离后精确 → opus 新老别名 → 角色关键词 → fable 降级到 opus。
    /// 未命中时返回原 body，让上游自行处理（与既有行为一致）。
    static func mapRequestModel(_ body: Data, provider: Provider) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = json["model"] as? String else {
            return body
        }

        let routes = resolveRoutes(for: provider)
        let requested = stripOneMSuffix(raw)

        // 1. 精确匹配（含 [1m] 剥离后）
        if let upstream = upstream(for: requested, in: routes) {
            return apply(upstream, to: json, fallback: body)
        }

        // 仅对安全模型名做角色回落，避免非 Claude 路由被误映射
        guard isClaudeSafeModelId(requested), let role = roleKeyword(requested) else {
            logger.warning("Unmapped model forwarded as-is: \(raw)")
            return body
        }

        // 2. opus 新老别名（滚动发布期间互通）
        if isOpusAlias(requested), let upstream = routes.first(where: { isOpusAlias($0.routeId) })?.upstreamModel {
            return apply(upstream, to: json, fallback: body)
        }

        // 3. 角色关键词匹配（带日期后缀的全名如 claude-haiku-4-5-20251001 归到同档）
        if let upstream = routes.first(where: { roleKeyword($0.routeId) == role })?.upstreamModel {
            return apply(upstream, to: json, fallback: body)
        }

        // 4. fable 降级到 opus（与官方分类器降级方向一致，避免 route_unknown 硬错误）
        if role == "fable", let upstream = routes.first(where: { roleKeyword($0.routeId) == "opus" })?.upstreamModel {
            logger.info("Fable request fell back to opus tier")
            return apply(upstream, to: json, fallback: body)
        }

        logger.warning("Unmapped model forwarded as-is: \(raw)")
        return body
    }

    private static func upstream(for requested: String, in routes: [ResolvedRoute]) -> String? {
        routes.first { $0.routeId.caseInsensitiveCompare(requested) == .orderedSame }?.upstreamModel
    }

    private static func apply(_ upstream: String, to json: [String: Any], fallback body: Data) -> Data {
        var mutated = json
        mutated["model"] = upstream
        return (try? JSONSerialization.data(withJSONObject: mutated)) ?? body
    }

    private static func stripOneMSuffix(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("[1m]") {
            return String(trimmed.dropLast("[1m]".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func isOpusAlias(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == currentOpusRouteId || normalized == legacyOpusRouteId
    }

    /// 按角色关键词（opus / haiku / fable / sonnet）归类一个 Claude 模型名/routeId。
    private static func roleKeyword(_ model: String) -> String? {
        let normalized = model.lowercased()
        if normalized.contains("opus") { return "opus" }
        if normalized.contains("haiku") { return "haiku" }
        if normalized.contains("fable") { return "fable" }
        if normalized.contains("sonnet") { return "sonnet" }
        return nil
    }
}
