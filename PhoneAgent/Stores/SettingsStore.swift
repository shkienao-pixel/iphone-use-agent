import Foundation
import Security

enum SettingsStore {
    static func load() -> AgentSettings {
        guard let data = UserDefaults.standard.data(forKey: "agent.settings"),
              let value = try? JSONDecoder().decode(AgentSettings.self, from: data) else { return AgentSettings() }
        return value
    }
    static func save(_ settings: AgentSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "agent.settings") }
    }
    static func calibration() -> PointerCalibration? {
        guard let data = UserDefaults.standard.data(forKey: "agent.calibration") else { return nil }
        return try? JSONDecoder().decode(PointerCalibration.self, from: data)
    }
    static func saveCalibration(_ value: PointerCalibration?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "agent.calibration")
    }
    static func credentialMatches(_ endpoint: String) -> Bool {
        (try? credentialRepository.key(for: endpoint)).map { !$0.isEmpty } ?? false
    }
    static func adoptLegacyCredential(for endpoint: String) {
        if UserDefaults.standard.string(forKey: "agent.keyEndpoint") == nil,
           (try? ModelEndpointPolicy.url(endpoint)) != nil,
           (try? readCredential(account: ModelCredentialRepository.legacyAccount)) != nil {
            UserDefaults.standard.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agent.keyEndpoint")
        }
    }
    static func apiKey(for endpoint: String? = nil) -> String {
        let settings = load()
        if settings.usesChatGPTPlan {
            guard (endpoint ?? settings.endpoint) == ChatGPTPlanProtocol.endpoint else { return "" }
            return ChatGPTPlanStore.readinessToken()
        }
        return (try? credentialRepository.key(for: endpoint ?? settings.endpoint)) ?? ""
    }
    private static var credentialRepository: ModelCredentialRepository {
        ModelCredentialRepository(read: { try readCredential(account: $0) },
            write: { try writeCredential($1, account: $0) }, delete: { try deleteCredential(account: $0) },
            legacyEndpoint: { UserDefaults.standard.string(forKey: "agent.keyEndpoint") },
            clearLegacyEndpoint: { UserDefaults.standard.removeObject(forKey: "agent.keyEndpoint") })
    }
    private static func readCredential(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PhoneAgent.model", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AgentError.message("API Key 暂时无法读取，请解锁设备后重试")
        }
        return key
    }
    static func saveAPIKey(_ key: String) throws {
        try saveAPIKey(key, for: load().endpoint)
    }
    static func saveAPIKey(_ key: String, for endpoint: String) throws {
        _ = try ModelEndpointPolicy.url(endpoint)
        try credentialRepository.save(key, for: endpoint)
    }
    static func removeAPIKey(for endpoint: String) throws {
        _ = try ModelEndpointPolicy.url(endpoint)
        try credentialRepository.remove(for: endpoint)
    }
    private static func writeCredential(_ key: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PhoneAgent.model", kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw AgentError.message("API Key 保存失败：\(result)") }
    }
    private static func deleteCredential(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PhoneAgent.model", kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentError.message("API Key 移除失败，请解锁设备后重试")
        }
    }
}
