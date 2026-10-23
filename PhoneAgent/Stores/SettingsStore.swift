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
        UserDefaults.standard.string(forKey: "agent.keyEndpoint") == endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func adoptLegacyCredential(for endpoint: String) {
        if UserDefaults.standard.string(forKey: "agent.keyEndpoint") == nil {
            UserDefaults.standard.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agent.keyEndpoint")
        }
    }
    static func apiKey(for endpoint: String? = nil) -> String {
        guard credentialMatches(endpoint ?? load().endpoint) else { return "" }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PhoneAgent.model", kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func saveAPIKey(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PhoneAgent.model", kSecAttrAccount as String: "api-key"]
        if key.isEmpty { SecItemDelete(query as CFDictionary); UserDefaults.standard.removeObject(forKey: "agent.keyEndpoint"); return }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw AgentError.message("API Key 保存失败：\(result)") }
        UserDefaults.standard.set(load().endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agent.keyEndpoint")
    }
}
