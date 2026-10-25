import Foundation
import Security

enum CtripStore {
    static var connectionMode: CtripConnectionMode {
        get {
            UserDefaults.standard.string(forKey: "agent.ctrip.mode").flatMap(CtripConnectionMode.init(rawValue:)) ?? (hasCredential ? .legacy : .wendao)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "agent.ctrip.mode"); enabled = false }
    }
    private static let enabledKey = "agent.ctrip.enabled"
    private static let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PhoneAgent.ctrip",
        kSecAttrAccount as String: "wendao",
        kSecAttrSynchronizable as String: false
    ]

    static var enabled: Bool {
        get { isEnabled() }
        set { setEnabled(newValue) }
    }
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enabledKey)
    }

    // State checks request attributes only, never the authorization code itself.
    static var hasCredential: Bool {
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func apiKey() -> String {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8),
              (try? CtripClient.validatedToken(value)) != nil else { return "" }
        return value
    }

    static func saveAPIKey(_ value: String) throws {
        if value.isEmpty { try clearAPIKey(); return }
        let mode = connectionMode
        try saveAPIKey(value, defaults: .standard, persist: persistAPIKey)
        UserDefaults.standard.set(mode.rawValue, forKey: "agent.ctrip.mode")
    }

    // The injected writer verifies replacement/consent behavior without accessing Keychain.
    static func saveAPIKey(_ value: String, defaults: UserDefaults,
                           persist: (String) throws -> Void) throws {
        let token = try CtripClient.validatedToken(value)
        try persist(token)
        // A replacement code must obtain fresh consent, including when imported by Debug.
        setEnabled(false, defaults: defaults)
    }

    private static func persistAPIKey(_ token: String) throws {
        let values: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(identity.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AgentError.message("携程授权码未能保存到本机钥匙串") }
    }

    static func clearAPIKey() throws {
        enabled = false
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentError.message("未能移除本机携程授权码")
        }
    }
}
