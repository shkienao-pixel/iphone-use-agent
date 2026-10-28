import Foundation

struct AgentSettings: Sendable {
    var usesChatGPTPlan = false
    var endpoint = "https://api.openai.com/v1/chat/completions"
    var model = "gpt-6.1-sol"
    var providerName: String? = nil
    var useMemories: Bool? = true
    var jsonMode = true
    var legacyTokenLimit = false
    var responseTokenLimit = 4096
    var consent = true
}
enum AgentError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum PrivacyConsent {
    static func allowed(_ settings: AgentSettings) -> Bool { settings.consent }
    static func recipient(_ settings: AgentSettings) -> String { settings.providerName ?? "OpenAI" }
}
enum SettingsStore {
    static func load() -> AgentSettings { AgentSettings() }
    static func apiKey(for endpoint: String) -> String { "" }
}
enum ModelEndpointPolicy {
    static func url(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, let url = parts.url else { throw AgentError.message("Invalid endpoint") }
        return url
    }
}
