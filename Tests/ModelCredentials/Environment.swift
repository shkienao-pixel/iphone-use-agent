import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct AgentSettings: Codable {
    var endpoint = "https://fixture.invalid/custom"
    var usesChatGPTPlan = false
}
enum ChatGPTPlanProtocol { static let endpoint = "https://api.openai.com/v1/responses" }
enum ChatGPTPlanStore { static func readinessToken() -> String { "synthetic-plan-token" } }
struct PointerCalibration: Codable {}
