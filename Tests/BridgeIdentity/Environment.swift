import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

// Shadow host APIs only for this executable. Never read system defaults or keys.
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
@MainActor enum ConnectionCredentialStore {
    static var values: [String: String] = [:]
    static var failNextSave = false
    static func read(_ account: String) -> String { values[account] ?? "" }
    static func save(_ value: String, account: String) throws {
        if failNextSave { failNextSave = false; throw AgentError.message("Offline credential write failure") }
        values[account] = value
    }
}
enum CtripStore { static let hasCredential = false; static let enabled = false }
enum MeituanConnectionStore { static let verified = false; static let configured = false }
struct MeituanPaotuiStore { static let shared = Self(); let configured = false; let ready = false }

@MainActor enum BridgeResponseProbe {
    struct Call { let endpoint: URL; let path: String; let method: String }
    static var calls: [Call] = []
    static var gate = false
    static var pending: CheckedContinuation<Void, Error>?
    static var nextPayload: Data?
    static let jobID = UUID().uuidString
    static func response(endpoint: URL, path: String, method: String) async throws -> Data {
        calls.append(Call(endpoint: endpoint, path: path, method: method))
        // Freeze the old server's payload before suspending its delivery.
        let payload: Data
        if let replacement = nextPayload { payload = replacement; nextPayload = nil }
        else if path == "v1/health" {
            payload = try JSONSerialization.data(withJSONObject: ["name": "Sela connections", "version": 1])
        } else if path.hasSuffix("/cancel") {
            payload = try JSONSerialization.data(withJSONObject: ["ok": true])
        } else if path.hasPrefix("v1/jobs/") || path.hasSuffix("/login") || path.hasSuffix("/install") {
            payload = try JSONSerialization.data(withJSONObject: ["id": jobID, "service": "feishu", "state": "authorizing", "message": "offline job"])
        } else {
            let pieces = path.split(separator: "/")
            let service = pieces.count > 2 ? String(pieces[2]) : "feishu"
            let disconnected = path.hasSuffix("/disconnect")
            payload = try JSONSerialization.data(withJSONObject: ["service": service, "installed": true, "connected": !disconnected,
                "state": disconnected ? "disconnected" : "connected", "message": endpoint.host ?? "offline"])
        }
        if gate { gate = false; try await withCheckedThrowingContinuation { pending = $0 } }
        return payload
    }
    static func resume(failing: Bool = false) {
        let continuation = pending; pending = nil
        if failing { continuation?.resume(throwing: AgentError.message("Offline bridge request failure")) }
        else { continuation?.resume() }
    }
}
@MainActor struct OfficeConnectionClient {
    let endpoint: URL
    let token: String
    static func validatedEndpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https" else { throw AgentError.message("offline invalid endpoint") }
        return url
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", as: T.Type = T.self) async throws -> T {
        try await JSONDecoder().decode(T.self, from: BridgeResponseProbe.response(endpoint: endpoint, path: path, method: method))
    }
}
