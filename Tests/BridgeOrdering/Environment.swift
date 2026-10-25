import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
@MainActor enum ConnectionCredentialStore {
    static var values: [String: String] = [:]
    static func read(_ account: String) -> String { values[account] ?? "" }
    static func save(_ value: String, account: String) throws { values[account] = value }
}
enum CtripStore { static let hasCredential = false; static let enabled = false }
enum MeituanConnectionStore { static let verified = false; static let configured = false }
struct MeituanPaotuiStore { static let shared = Self(); let configured = false; let ready = false }

@MainActor enum BridgeOrderingProbe {
    struct Plan { let id: UUID; let payload: Data?; let gated: Bool }
    struct Call { let id: UUID; let endpoint: URL; let path: String; let method: String }
    static var plans: [Plan] = []
    static var calls: [Call] = []
    static var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    static let jobID = UUID().uuidString
    static func plan(_ payload: Data? = nil, gated: Bool = true) -> UUID {
        let id = UUID(); plans.append(Plan(id: id, payload: payload, gated: gated)); return id
    }
    static func response(endpoint: URL, path: String, method: String) async throws -> Data {
        let plan = plans.isEmpty ? Plan(id: UUID(), payload: nil, gated: false) : plans.removeFirst()
        calls.append(Call(id: plan.id, endpoint: endpoint, path: path, method: method))
        // Freeze each independent response before any delivery is suspended.
        let data: Data
        if let payload = plan.payload { data = payload }
        else if path == "v1/health" {
            data = try JSONSerialization.data(withJSONObject: ["name": "Sela connections", "version": 1])
        } else if path.hasSuffix("/cancel") {
            data = try JSONSerialization.data(withJSONObject: ["ok": true])
        } else if path.hasPrefix("v1/jobs/") || path.hasSuffix("/login") || path.hasSuffix("/install") {
            data = try JSONSerialization.data(withJSONObject: ["id": jobID, "service": "feishu", "state": "authorizing", "message": "offline job"])
        } else {
            let parts = path.split(separator: "/"), disconnected = path.hasSuffix("/disconnect")
            data = try JSONSerialization.data(withJSONObject: ["service": parts.count > 2 ? String(parts[2]) : "feishu",
                "installed": true, "connected": !disconnected, "state": disconnected ? "disconnected" : "connected", "message": "current local reply"])
        }
        if plan.gated { try await withCheckedThrowingContinuation { pending[plan.id] = $0 } }
        return data
    }
    static func resume(_ id: UUID, failure: String? = nil) {
        guard let continuation = pending.removeValue(forKey: id) else { preconditionFailure("Missing local response gate") }
        if let failure { continuation.resume(throwing: AgentError.message(failure)) }
        else { continuation.resume() }
    }
}
@MainActor struct OfficeConnectionClient {
    let endpoint: URL
    let token: String
    static func validatedEndpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https" else { throw AgentError.message("offline invalid endpoint") }
        return url
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", as: T.Type = T.self) async throws -> T {
        try await JSONDecoder().decode(T.self, from: BridgeOrderingProbe.response(endpoint: endpoint, path: path, method: method))
    }
}
