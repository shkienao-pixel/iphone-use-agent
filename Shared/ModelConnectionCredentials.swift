import Foundation
import CryptoKit

enum ModelCredentialIssue: LocalizedError {
    case endpoint, model, key
    var errorDescription: String? {
        switch self {
        case .endpoint: return "请填写有效的完整 HTTPS 模型接口地址"
        case .model: return "请填写模型 ID"
        case .key: return "请填写 API Key；停用请使用“移除 Key”"
        }
    }
}

struct ModelConnectionSaveRequest {
    let endpoint: String
    let model: String
    let key: String

    init(endpoint: String, model: String, key: String, validateEndpoint: (String) throws -> URL) throws {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try validateEndpoint(endpoint)
        guard !model.isEmpty else { throw ModelCredentialIssue.model }
        guard !key.isEmpty else { throw ModelCredentialIssue.key }
        self.endpoint = endpoint; self.model = model; self.key = key
    }
}

/// Credential operations are scoped to an exact endpoint. Old installations'
/// single Key remains readable only through its original endpoint binding.
/// A failed scoped read must throw, rather than resurrecting an older Key.
struct ModelCredentialRepository {
    static let legacyAccount = "api-key"
    let read: (String) throws -> String?
    let write: (String, String) throws -> Void
    let delete: (String) throws -> Void
    let legacyEndpoint: () -> String?
    let clearLegacyEndpoint: () -> Void

    static func account(for endpoint: String) -> String {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return "api-key.endpoint." + digest
    }

    func key(for endpoint: String) throws -> String {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return "" }
        if let key = try read(Self.account(for: endpoint)) { return key }
        guard legacyEndpoint()?.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint else { return "" }
        return try read(Self.legacyAccount) ?? ""
    }

    func save(_ key: String, for endpoint: String) throws {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { throw ModelCredentialIssue.endpoint }
        guard !key.isEmpty else { throw ModelCredentialIssue.key }
        try write(Self.account(for: endpoint), key)
    }

    func remove(for endpoint: String) throws {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { throw ModelCredentialIssue.endpoint }
        try delete(Self.account(for: endpoint))
        if legacyEndpoint()?.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint {
            try delete(Self.legacyAccount)
            clearLegacyEndpoint()
        }
    }
}

/// An automatically loaded Key cannot travel to another endpoint. Explicitly
/// typed, unsaved input remains editable while the user finishes the address.
struct ModelCredentialDraft {
    private(set) var value = ""
    private(set) var endpoint = ""
    private(set) var manuallyEdited = false
    private(set) var retainedAfterEndpointChange = false

    mutating func loadSaved(_ key: String, for endpoint: String) {
        value = key; self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        manuallyEdited = false; retainedAfterEndpointChange = false
    }

    mutating func edit(_ key: String) {
        value = key; manuallyEdited = true
        if key.isEmpty { retainedAfterEndpointChange = false }
    }

    mutating func endpointChanged(to endpoint: String, savedKey: String) {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint != self.endpoint else { return }
        if manuallyEdited && !value.isEmpty {
            self.endpoint = endpoint; retainedAfterEndpointChange = true
        } else { loadSaved(savedKey, for: endpoint) }
    }
}
