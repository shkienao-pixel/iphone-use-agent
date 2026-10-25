import Foundation
import Security

enum ChatGPTPlanStore {
    struct Document: Codable {
        var version = 1
        var hostID: String
        var selectedID: UUID?
        var profiles: [ChatGPTPlanProfile] = []
    }
    private static let lock = NSRecursiveLock()
    private static let service = "PhoneAgent.chatgpt-plan"
    private static func readUnlocked() throws -> Document? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "profiles", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 1_000_000,
              let value = try? JSONDecoder().decode(Document.self, from: data), value.version == 1,
              value.profiles.count <= 12 else { throw ChatGPTPlanError.message("ChatGPT 登录资料暂时无法读取，原记录已保留") }
        return value
    }
    private static func writeUnlocked(_ value: Document) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_000_000 else { throw ChatGPTPlanError.message("ChatGPT 登录资料过大") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "profiles"]
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ChatGPTPlanError.message("ChatGPT 登录资料未能安全保存") }
    }
    static func document(create: Bool = false) throws -> Document? {
        lock.lock(); defer { lock.unlock() }
        if let value = try readUnlocked() { return value }
        guard create else { return nil }
        let value = Document(hostID: "urn:uuid:" + UUID().uuidString.lowercased())
        try writeUnlocked(value); return value
    }
    static func selected() -> ChatGPTPlanProfile? {
        guard let doc = try? document(), let id = doc.selectedID else { return nil }
        return doc.profiles.first { $0.id == id }
    }
    // HTTP clients resolve the live access token through ChatGPTPlanTokens.
    // Readiness and stale-result checks bind the account/grant, not its bearer.
    static func readinessToken() -> String { selected()?.authorizationBinding ?? "" }
    static func active(_ id: UUID) -> Bool { selected()?.id == id }
    static func select(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var doc = try readUnlocked(), doc.profiles.contains(where: { $0.id == id }) else { throw ChatGPTPlanError.message("ChatGPT 账户不存在") }
        doc.selectedID = id; try writeUnlocked(doc)
    }
    static func stage(id: UUID, clientID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var doc = try readUnlocked() else { throw ChatGPTPlanError.message("ChatGPT 本机资料不存在") }
        if let old = doc.profiles.first(where: { $0.id == id }) {
            guard old.clientID == clientID else { throw ChatGPTPlanError.message("ChatGPT 账户注册已改变") }
        } else {
            guard doc.profiles.count < 12 else { throw ChatGPTPlanError.message("已保存的 ChatGPT 账户过多") }
            doc.profiles.append(ChatGPTPlanProfile(id: id, clientID: clientID))
        }
        if doc.selectedID == nil { doc.selectedID = id }
        try writeUnlocked(doc)
    }
    static func save(_ profile: ChatGPTPlanProfile, expectedRefreshToken: String? = nil, select: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard var doc = try readUnlocked(), let index = doc.profiles.firstIndex(where: { $0.id == profile.id }),
              doc.profiles[index].clientID == profile.clientID else { throw ChatGPTPlanError.message("ChatGPT 账户注册已改变") }
        if let expectedRefreshToken {
            guard doc.profiles[index].refreshToken == expectedRefreshToken,
                  doc.profiles[index].authorizationID == profile.authorizationID else { throw CancellationError() }
        }
        doc.profiles[index] = profile
        if select { doc.selectedID = profile.id }
        try writeUnlocked(doc)
    }
    static func clearCredentials(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var doc = try readUnlocked(), let index = doc.profiles.firstIndex(where: { $0.id == id }) else { return }
        doc.profiles[index].accessToken = nil; doc.profiles[index].refreshToken = nil; doc.profiles[index].idToken = nil
        doc.profiles[index].scopes = []; doc.profiles[index].expiresAt = nil
        // Keep the registration selected so reconnecting reuses its issued
        // client ID. Cleared tokens/scopes still make readiness false.
        try writeUnlocked(doc)
    }
}

private final class ChatGPTNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ChatGPTPlanHTTP {
    static func revoke(_ profile: ChatGPTPlanProfile) async -> Bool {
        guard let refresh = profile.refreshToken else { return true }
        do {
            let metadata = try await json("https://auth.openai.com/.well-known/openid-configuration")
            guard let text = metadata["revocation_endpoint"] as? String, let url = URL(string: text), url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil, url.port == nil else { return false }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 20
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ChatGPTPlanProtocol.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": profile.clientID])
            let session = URLSession(configuration: .ephemeral, delegate: ChatGPTNoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
    static func json(_ url: String, fields: [String: String]? = nil, bearer: String? = nil) async throws -> [String: Any] {
        guard let endpoint = URL(string: url), endpoint.scheme == "https", ["auth.openai.com", "api.openai.com"].contains(endpoint.host),
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil, endpoint.port == nil else { throw ChatGPTPlanError.message("ChatGPT 官方接口地址无效") }
        var request = URLRequest(url: endpoint); request.timeoutInterval = 45
        if let fields { request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = ChatGPTPlanProtocol.form(fields) }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral, delegate: ChatGPTNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 1_000_000 else { throw ChatGPTPlanError.message("ChatGPT 登录服务响应无效") }
        guard (200...299).contains(http.statusCode) else { throw ChatGPTPlanResponses.failure(code: nil, status: http.statusCode) }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTPlanError.message("ChatGPT 登录服务响应格式无效") }
        return value
    }
    static func accept(_ data: [String: Any], previous: ChatGPTPlanProfile, nonce: String?) async throws -> ChatGPTPlanProfile {
        guard let access = data["access_token"] as? String, !access.isEmpty, access.utf8.count <= 32_768,
              let expiry = data["expires_in"] as? Double, expiry > 0, expiry <= 172_800,
              (data["token_type"] as? String)?.lowercased() == "bearer" else { throw ChatGPTPlanError.message("ChatGPT 未返回有效的登录授权") }
        var value = previous
        if let token = data["id_token"] as? String {
            let keys = try await json("https://auth.openai.com/.well-known/jwks.json")
            let identity = try ChatGPTPlanProtocol.validateIDToken(token, jwks: JSONSerialization.data(withJSONObject: keys), clientID: previous.clientID, nonce: nonce)
            guard previous.subject == nil || (previous.subject == identity.subject && previous.issuer == identity.issuer) else { throw ChatGPTPlanError.message("ChatGPT 返回的账户与所选连接不一致") }
            value.subject = identity.subject; value.issuer = identity.issuer; value.email = identity.email; value.idToken = token
        } else if nonce != nil || previous.subject == nil { throw ChatGPTPlanError.message("ChatGPT 未返回可核验的身份") }
        value.accessToken = access
        if let refresh = data["refresh_token"] as? String {
            guard !refresh.isEmpty, refresh.utf8.count <= 32_768 else { throw ChatGPTPlanError.message("ChatGPT 续期授权无效") }
            value.refreshToken = refresh
        }
        if let scope = data["scope"] as? String { value.scopes = scope.split(separator: " ").map(String.init) }
        else if nonce != nil { value.scopes = [] }
        value.expiresAt = Date().addingTimeInterval(expiry)
        // A fresh OAuth authorization starts a new grant even for the same
        // account. Ordinary refresh retains the existing grant identity.
        if nonce != nil { value.authorizationID = UUID() }
        return value
    }
}

actor ChatGPTPlanTokens {
    static let shared = ChatGPTPlanTokens()
    private struct Flight { let id: UUID; let task: Task<ChatGPTPlanProfile, Error> }
    private var refreshing: [UUID: Flight] = [:]
    func valid(_ id: UUID) async throws -> ChatGPTPlanProfile {
        try Task.checkCancellation()
        guard let profile = ChatGPTPlanStore.selected(), profile.id == id, profile.sharing else { throw ChatGPTPlanError.message("请登录 ChatGPT 并允许 Sela 使用你的计划用量") }
        if let expiry = profile.expiresAt, expiry.timeIntervalSinceNow > 60 { return profile }
        let flight: Flight
        if let pending = refreshing[id] { flight = pending }
        else {
            let task = Task {
                guard let refresh = profile.refreshToken else { throw ChatGPTPlanError.message("ChatGPT 授权已过期，请重新登录") }
                let response = try await ChatGPTPlanHTTP.json(ChatGPTPlanProtocol.tokenEndpoint, fields: ["grant_type": "refresh_token", "client_id": profile.clientID, "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
                let replacement = try await ChatGPTPlanHTTP.accept(response, previous: profile, nonce: nil)
                guard ChatGPTPlanStore.active(id) else { throw CancellationError() }
                try ChatGPTPlanStore.save(replacement, expectedRefreshToken: refresh, select: false)
                return replacement
            }
            flight = Flight(id: UUID(), task: task)
            refreshing[id] = flight
        }
        defer { if refreshing[id]?.id == flight.id { refreshing[id] = nil } }
        let result = try await flight.task.value
        try Task.checkCancellation()
        guard ChatGPTPlanStore.active(id), result.sharing else { throw CancellationError() }
        return result
    }
}
