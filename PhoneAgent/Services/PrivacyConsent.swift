import Foundation

// Consent follows the actual recipient. Changing endpoints requires consent again.
enum PrivacyConsent {
    static let revision = 7
    private static let key = "agent.aiConsent.v1"
    struct Grant: Codable { let endpoint: String; let provider: String; let revision: Int }
    static func recipient(_ settings: AgentSettings) -> String {
        if let name = settings.providerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let host = URLComponents(string: settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? "未配置服务商"
        if host == "api.openai.com" { return "OpenAI" }
        if host == "ark.cn-beijing.volces.com" { return "火山方舟" }
        return host
    }
    static func allowed(_ settings: AgentSettings, defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: key), let grant = try? JSONDecoder().decode(Grant.self, from: data) else { return false }
        return grant.endpoint == settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) &&
            grant.provider == recipient(settings) && grant.revision == revision
    }
    static func grant(_ settings: AgentSettings, defaults: UserDefaults = .standard) {
        let value = Grant(endpoint: settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines), provider: recipient(settings), revision: revision)
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
    static func revoke(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
