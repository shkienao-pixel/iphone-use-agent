import Foundation

// This Store is deliberately in memory. This test never touches the Mac or
// simulator Keychain and the token actor cannot make a refresh HTTP request.
enum ChatGPTPlanHTTP {
    static func json(_ endpoint: String, fields: [String: String]) async throws -> [String: Any] {
        throw AgentError.message("Offline fixture forbids token refresh HTTP")
    }
    static func accept(_ response: [String: Any], previous: ChatGPTPlanProfile, nonce: String?) async throws -> ChatGPTPlanProfile {
        throw AgentError.message("Offline fixture forbids remote token acceptance")
    }
}
