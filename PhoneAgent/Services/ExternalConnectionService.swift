import Foundation
import Security
import Combine

enum ConnectionCredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "PhoneAgent") + ".connections" }
    static func read(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("未能清除本机连接凭据") }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw AgentError.message("连接凭据未能保存到钥匙串（\(status)）") }
    }
}

private final class ConnectionRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct OfficeConnectionClient {
    let endpoint: URL
    let token: String

    static func validatedEndpoint(_ text: String) throws -> URL {
        #if DEBUG && (targetEnvironment(simulator))
        let allowsLoopback = true
        #else
        let allowsLoopback = false
        #endif
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/",
              components.scheme == "https" || (allowsLoopback && components.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              let url = components.url else { throw AgentError.message("请输入有效的 HTTPS 连接服务地址") }
        return url
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", as: T.Type = T.self) async throws -> T {
        guard !token.isEmpty, !token.contains("\n"), token.utf8.count <= 4096 else { throw AgentError.message("请先配置连接服务的配对码") }
        var request = URLRequest(url: endpoint.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ConnectionRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw AgentError.message("连接服务未返回有效响应") }
            guard (200...299).contains(response.statusCode) else {
                throw AgentError.message(response.statusCode == 403 ? "配对码不正确，请重新配对连接服务" : "连接操作未完成，请检查连接服务或稍后重试")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw AgentError.message("连接服务响应过大") }
                data.append(byte)
            }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw AgentError.message("连接服务返回格式不匹配，请更新服务") }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw AgentError.message("暂时无法连接服务，请检查网络和服务地址")
        }
    }
}

@MainActor
final class ExternalConnectionsCoordinator: ObservableObject, OfficeAuthorizationBackend {
    static let shared = ExternalConnectionsCoordinator()
    @Published private(set) var statuses: [String: OfficeConnectionStatus] = [:]
    @Published private(set) var bridgeMessage = ""
    @Published private(set) var bridgeAvailable = false
    @Published private(set) var revision = 0
    @Published private var pendingDisconnects: [String: UUID] = [:]
    @Published private var pendingStarts: [String: UUID] = [:]
    @Published private var unresolvedDisconnects: Set<String> = []
    private var statusRequests: [String: UUID] = [:]
    private var availabilityRequest = UUID()
    private struct ConnectionBusy: LocalizedError {
        var errorDescription: String? { "账号连接正在更新，请稍后检测" }
    }
    var endpointText: String { UserDefaults.standard.string(forKey: "connections.bridge.endpoint") ?? "" }
    var paired: Bool { !ConnectionCredentialStore.read("bridge-token").isEmpty }
    var authorizationContext: String {
        // Keep legacy pending grants usable until an explicit pairing save.
        // The persisted generation survives restarts and contains no credential.
        guard let pairing = UserDefaults.standard.string(forKey: "connections.bridge.pairingIdentity") else { return endpointText }
        return endpointText + "|pairing:" + pairing
    }

    private init() {
        #if DEBUG
        let file = URL.documentsDirectory.appendingPathComponent("connection-setup.once.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8192 else { throw AgentError.message("连接配置文件过大") }
                struct Pairing: Decodable { let endpoint: String; let token: String }
                let pairing = try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: file))
                try saveBridge(endpoint: pairing.endpoint, token: pairing.token)
                try FileManager.default.removeItem(at: file)
            } catch { bridgeMessage = "连接服务配置导入失败，请重新配对" }
        }
        #endif
    }

    func saveBridge(endpoint: String, token: String) throws {
        let url = try OfficeConnectionClient.validatedEndpoint(endpoint)
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), key.utf8.count <= 4096 else { throw AgentError.message("请输入有效配对码") }
        try ConnectionCredentialStore.save(key, account: "bridge-token")
        UserDefaults.standard.set(url.absoluteString, forKey: "connections.bridge.endpoint")
        UserDefaults.standard.set(UUID().uuidString, forKey: "connections.bridge.pairingIdentity")
        statusRequests = [:]; pendingDisconnects = [:]; pendingStarts = [:]; unresolvedDisconnects = []; availabilityRequest = UUID()
        statuses = [:]; bridgeAvailable = false; bridgeMessage = ""; revision += 1
    }

    private func client() throws -> OfficeConnectionClient {
        try OfficeConnectionClient(endpoint: OfficeConnectionClient.validatedEndpoint(endpointText), token: ConnectionCredentialStore.read("bridge-token"))
    }
    private func validateContext(_ context: String) throws {
        try Task.checkCancellation()
        guard context == authorizationContext else { throw AgentError.message("连接服务配置已改变，请重新检测") }
    }
    private func validateStatus(_ value: OfficeConnectionStatus, service: ExternalAppService) throws {
        guard value.service == service.rawValue else { throw AgentError.message("连接服务返回了不匹配的账号状态") }
        guard !(value.connected && (!value.installed || value.state != "connected")),
              !(value.state == "connected" && !value.connected) else {
            throw AgentError.message("连接服务返回了矛盾的账号状态，请重新检测")
        }
    }
    private func publishUnavailable(_ message: String, request: UUID) {
        guard availabilityRequest == request else { return }
        bridgeAvailable = false; bridgeMessage = message
        // Keep inactive observations, but invalidate every active readiness proof
        // and in-flight read that predates this current connection failure.
        statuses = statuses.filter { !$0.value.connected }; statusRequests = [:]
    }
    func checkBridge() async {
        guard !Task.isCancelled else { return }
        let context = authorizationContext
        let request = UUID(); availabilityRequest = request
        struct Health: Decodable { let name: String; let version: Int }
        do {
            try validateContext(context)
            let health: Health = try await client().request("v1/health")
            try validateContext(context)
            guard availabilityRequest == request else { return }
            if health.version == 1 && health.name == "Sela connections" {
                bridgeAvailable = true; bridgeMessage = "连接服务已就绪"
            } else { publishUnavailable("连接服务版本不匹配", request: request) }
        } catch {
            guard !Task.isCancelled, context == authorizationContext, availabilityRequest == request else { return }
            publishUnavailable(error.localizedDescription, request: request)
        }
    }
    func refresh(_ service: ExternalAppService) async {
        guard !Task.isCancelled else { return }
        guard service.isCLI else { revision += 1; return }
        guard paired, !endpointText.isEmpty else {
            let request = UUID(); availabilityRequest = request
            publishUnavailable("先配置连接服务，再使用官方账号授权。", request: request)
            return
        }
        do {
            _ = try await verifiedStatus(service)
        } catch { /* The owning request publishes its own failure. Superseded reads and pending mutations publish nothing. */ }
    }
    func verifiedStatus(_ service: ExternalAppService) async throws -> OfficeConnectionStatus {
        let context = authorizationContext
        try validateContext(context)
        let key = service.rawValue
        guard pendingDisconnects[key] == nil, pendingStarts[key] == nil else { throw ConnectionBusy() }
        let request = UUID(), availability = UUID()
        statusRequests[key] = request; availabilityRequest = availability
        defer { if statusRequests[key] == request { statusRequests.removeValue(forKey: key) } }
        do {
            let value: OfficeConnectionStatus = try await client().request("v1/services/\(key)/status")
            try validateContext(context)
            guard statusRequests[key] == request, pendingDisconnects[key] == nil, pendingStarts[key] == nil else { throw CancellationError() }
            try validateStatus(value, service: service)
            statuses[key] = value
            if ["connected", "disconnected", "missing", "login"].contains(value.state) { unresolvedDisconnects.remove(key) }
            if availabilityRequest == availability || !bridgeAvailable { bridgeAvailable = true; bridgeMessage = "" }
            return value
        } catch {
            if !Task.isCancelled, context == authorizationContext,
               statusRequests[key] == request, pendingDisconnects[key] == nil, pendingStarts[key] == nil {
                if statuses[key]?.connected == true { statuses.removeValue(forKey: key) }
                publishUnavailable(error.localizedDescription, request: availability)
            }
            throw error
        }
    }
    func refreshAll() async {
        let context = authorizationContext
        for service in ExternalAppService.allCases where service.isCLI {
            guard !Task.isCancelled, context == authorizationContext else { return }; await refresh(service)
        }
        guard !Task.isCancelled, context == authorizationContext else { return }
        revision += 1
    }
    func start(_ service: ExternalAppService, install: Bool) async throws -> OfficeAuthorizationJob {
        let context = authorizationContext
        try validateContext(context)
        let key = service.rawValue
        guard pendingDisconnects[key] == nil, pendingStarts[key] == nil else { throw ConnectionBusy() }
        let operation = UUID(); pendingStarts[key] = operation
        statusRequests.removeValue(forKey: key); statuses.removeValue(forKey: key)
        defer { if pendingStarts[key] == operation { pendingStarts.removeValue(forKey: key) } }
        let job: OfficeAuthorizationJob = try await client().request("v1/services/\(service.rawValue)/\(install ? "install" : "login")", method: "POST")
        try validateContext(context)
        guard pendingStarts[key] == operation else { throw CancellationError() }
        return job
    }
    func poll(_ id: String) async throws -> OfficeAuthorizationJob {
        let context = authorizationContext
        try validateContext(context)
        let job: OfficeAuthorizationJob = try await client().request("v1/jobs/\(id)")
        try validateContext(context)
        return job
    }
    func cancel(_ id: String) async {
        guard !Task.isCancelled else { return }
        struct Result: Decodable { let ok: Bool }
        let _: Result? = try? await client().request("v1/jobs/\(id)/cancel", method: "POST")
    }
    func disconnect(_ service: ExternalAppService) async throws {
        let context = authorizationContext
        try validateContext(context)
        let key = service.rawValue
        guard pendingDisconnects[key] == nil, pendingStarts[key] == nil else { throw ConnectionBusy() }
        let operation = UUID(), availability = UUID()
        let priorInactive = statuses[key].flatMap { $0.connected ? nil : $0 }
        pendingDisconnects[key] = operation; availabilityRequest = availability
        statusRequests.removeValue(forKey: key); statuses.removeValue(forKey: key)
        unresolvedDisconnects.insert(key)
        defer { if pendingDisconnects[key] == operation { pendingDisconnects.removeValue(forKey: key) } }
        do {
            let result: OfficeConnectionStatus = try await client().request("v1/services/\(key)/disconnect", method: "POST")
            try validateContext(context)
            guard pendingDisconnects[key] == operation else { throw CancellationError() }
            try validateStatus(result, service: service)
            guard !result.connected, ["disconnected", "missing", "login"].contains(result.state) else {
                throw AgentError.message("尚未确认断开结果，请检测连接后核对")
            }
            statuses[key] = result; unresolvedDisconnects.remove(key)
            if availabilityRequest == availability { bridgeAvailable = true; bridgeMessage = "" }
        } catch {
            if context == authorizationContext, pendingDisconnects[key] == operation, let priorInactive {
                statuses[key] = priorInactive
            }
            if !Task.isCancelled, context == authorizationContext,
               pendingDisconnects[key] == operation, availabilityRequest == availability {
                publishUnavailable("断开结果未确认，请检测连接后核对", request: availability)
            }
            throw error
        }
    }
    func statusLabel(_ service: ExternalAppService) -> String {
        if service == .wps { return "按需选取" }
        if service == .ctrip { return CtripStore.hasCredential ? (CtripStore.enabled ? "已启用" : "已配置") : "未配置" }
        if service == .meituan { return MeituanPaotuiStore.shared.ready ? "跑腿已连接" : MeituanPaotuiStore.shared.configured ? "跑腿待检测" : MeituanConnectionStore.verified ? "旅行已连接" : MeituanConnectionStore.configured ? "待检测" : "未配置" }
        if pendingDisconnects[service.rawValue] != nil { return "断开中" }
        if pendingStarts[service.rawValue] != nil { return "连接更新中" }
        if unresolvedDisconnects.contains(service.rawValue) { return "待检测" }
        guard let value = statuses[service.rawValue] else { return "未连接" }
        switch value.state { case "connected": return "已连接"; case "missing": return "待准备"; case "authorizing": return "授权中"; case "error": return "检测失败"; case "disconnected": return "已断开"; default: return "待登录" }
    }
}

enum MeituanConnectionStore {
    static var endpoint: String { ConnectionCredentialStore.read("meituan-endpoint") }
    static var credential: String { ConnectionCredentialStore.read("meituan-token") }
    static var configured: Bool { !endpoint.isEmpty }
    static var verified: Bool { configured && UserDefaults.standard.bool(forKey: "connections.meituan.verified") }
    static var capabilities: [String] { UserDefaults.standard.stringArray(forKey: "connections.meituan.tools") ?? [] }
    static func save(endpoint: String, token: String) throws {
        _ = try MeituanMCPClient.validatedEndpoint(endpoint)
        guard !token.contains("\n"), token.utf8.count <= 8192 else { throw AgentError.message("授权凭据格式不正确") }
        // Clear verification before replacing either half of the connection.
        UserDefaults.standard.set(false, forKey: "connections.meituan.verified")
        UserDefaults.standard.removeObject(forKey: "connections.meituan.tools")
        try ConnectionCredentialStore.save(token, account: "meituan-token")
        try ConnectionCredentialStore.save(endpoint, account: "meituan-endpoint")
    }
    static func verified(tools: [String]) {
        UserDefaults.standard.set(tools, forKey: "connections.meituan.tools")
        UserDefaults.standard.set(true, forKey: "connections.meituan.verified")
    }
    static func disconnect() throws {
        UserDefaults.standard.set(false, forKey: "connections.meituan.verified")
        UserDefaults.standard.removeObject(forKey: "connections.meituan.tools")
        try ConnectionCredentialStore.save("", account: "meituan-endpoint")
        try ConnectionCredentialStore.save("", account: "meituan-token")
    }
}
