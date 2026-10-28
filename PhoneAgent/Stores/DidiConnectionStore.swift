import Foundation
import Security
import Combine

/// Shared by all ride cards. The revision revokes work already in flight when
/// another card replaces or explicitly removes the connection.
@MainActor protocol DidiCredentialStoring: AnyObject {
    var revision: UUID { get }
    var revisions: AnyPublisher<UUID, Never> { get }
    var canRestore: Bool { get }
    var hasPendingRemoval: Bool { get }
    func beginConnectionAttempt() -> UUID
    func load() throws -> String?
    func save(_ credential: String, revision: UUID) throws
    func remove() throws
}

@MainActor final class DidiConnectionStore: DidiCredentialStoring {
    static let shared = DidiConnectionStore()
    @Published private(set) var revision = UUID()
    private static let enabledKey = "agent.didi.savedConnectionEnabled"
    private static let pendingRemovalKey = "agent.didi.savedConnectionRemovalPending"
    private let defaults: UserDefaults
    private let readCredential: () throws -> String?
    private let writeCredential: (String) throws -> Void
    private let deleteCredential: () throws -> Void

    private convenience init() {
        self.init(defaults: .standard, read: Self.keychainRead, write: Self.keychainWrite, delete: Self.keychainDelete)
    }

    /// Offline tests supply memory-only operations and isolated preferences.
    init(defaults: UserDefaults, read: @escaping () throws -> String?,
         write: @escaping (String) throws -> Void, delete: @escaping () throws -> Void) {
        self.defaults = defaults
        readCredential = read; writeCredential = write; deleteCredential = delete
    }

    var revisions: AnyPublisher<UUID, Never> { $revision.eraseToAnyPublisher() }
    var hasPendingRemoval: Bool { defaults.bool(forKey: Self.pendingRemovalKey) }
    var canRestore: Bool { defaults.bool(forKey: Self.enabledKey) && !hasPendingRemoval }

    func beginConnectionAttempt() -> UUID {
        revision = UUID()
        return revision
    }

    func load() throws -> String? {
        guard canRestore else { return nil }
        let value = try readCredential()
        if value == nil {
            defaults.set(false, forKey: Self.enabledKey)
            revision = UUID()
        }
        return value
    }

    func save(_ credential: String, revision expected: UUID) throws {
        guard revision == expected else { throw CancellationError() }
        guard !credential.isEmpty else { throw DidiCredentialStoreError.save }
        do { try writeCredential(credential) }
        catch { throw DidiCredentialStoreError.save }
        // Never report a remembered connection until Keychain confirms saving.
        defaults.set(false, forKey: Self.pendingRemovalKey)
        defaults.set(true, forKey: Self.enabledKey)
    }

    func remove() throws {
        // Persist the revocation first. A locked/unavailable Keychain must not
        // allow a removed connection to reappear after the next app launch.
        defaults.set(true, forKey: Self.pendingRemovalKey)
        defaults.set(false, forKey: Self.enabledKey)
        revision = UUID()
        do { try deleteCredential() }
        catch { throw DidiCredentialStoreError.remove }
        defaults.set(false, forKey: Self.pendingRemovalKey)
    }

    private static let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PhoneAgent.didi",
        kSecAttrAccount as String: "mcp-production",
        kSecAttrSynchronizable as String: false,
    ]

    private static func keychainRead() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw DidiCredentialStoreError.read
        }
        return value
    }

    private static func keychainWrite(_ credential: String) throws {
        let values: [String: Any] = [
            kSecValueData as String: Data(credential.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(identity.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DidiCredentialStoreError.save }
    }

    private static func keychainDelete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DidiCredentialStoreError.remove }
    }
}

enum DidiCredentialStoreError: LocalizedError {
    case read, save, remove
    var errorDescription: String? {
        switch self {
        case .read: "暂时无法读取已保存的滴滴连接，请解锁手机后重试。"
        case .save: "滴滴连接未能安全保存，请稍后重试。"
        case .remove: "已断开滴滴，但未能删除保存的信息，请重试删除。"
        }
    }
}
