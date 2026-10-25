#if DEBUG
import Foundation

// Local, opt-in provisioning for this development build. The credential never
// appears in a launch argument, receipt, diagnostic message or UserDefaults.
enum DebugModelConfigImport {
    private struct Payload: Decodable {
        let version: Int
        let apiKey: String
    }
    private struct Receipt: Encodable {
        let version = 1
        let status: String
        let createdAt: Date
        let sourceRemoved: Bool
        let credentialPresent: Bool
        let credentialMatches: Bool
        let credentialVerified: Bool?
        let modelReady: Bool
        let requiresDataConsent: Bool
    }

    static func runIfRequested() -> String? {
        guard ProcessInfo.processInfo.arguments.contains("--import-model-config-once") else { return nil }
        let files = FileManager.default
        let directory = URL.documentsDirectory
        let source = directory.appendingPathComponent("model-config.once.json", isDirectory: false)
        let receipt = directory.appendingPathComponent("model-config-import.receipt.json", isDirectory: false)
        var status = "failed"
        var credentialVerified: Bool? = nil
        defer {
            // Also remove invalid files; a later launch must not replay them.
            try? files.removeItem(at: source)
            let removed = (try? files.attributesOfItem(atPath: source.path)) == nil
            let settings = SettingsStore.load()
            let present = !SettingsStore.apiKey(for: settings.endpoint).isEmpty
            let matches = SettingsStore.credentialMatches(settings.endpoint)
            let endpointValid = (try? ModelEndpointPolicy.url(settings.endpoint))?.path.hasSuffix("/chat/completions") == true
            let ready = endpointValid && !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && present
            writeReceipt(.init(status: removed ? status : "cleanup_failed", createdAt: Date(), sourceRemoved: removed,
                               credentialPresent: present, credentialMatches: matches, credentialVerified: credentialVerified,
                               modelReady: ready, requiresDataConsent: !PrivacyConsent.allowed(settings)), to: receipt)
        }

        do {
            let attributes = try files.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, (1...16384).contains(size.intValue) else {
                throw ImportIssue.invalidFile
            }
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: source.path)
            var protectedSource = source
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedSource.setResourceValues(values)
            let data = try Data(contentsOf: source)
            guard data.count <= 16384,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["version", "apiKey"]) else { throw ImportIssue.invalidFile }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let key = payload.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard payload.version == 1, !key.isEmpty, key.utf8.count <= 4096,
                  key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw ImportIssue.invalidFile }

            // Delete before touching persistent settings, so a failed cleanup
            // cannot leave a successfully imported plaintext credential behind.
            try files.removeItem(at: source)
            let defaults = UserDefaults.standard
            let previousSettings = defaults.data(forKey: "agent.settings")
            let previousEndpoint = defaults.string(forKey: "agent.keyEndpoint")
            var settings = SettingsStore.load()
            settings.endpoint = "https://api.openai.com/v1/chat/completions"
            settings.providerName = "OpenAI"
            settings.modelAuthentication = "api_key"
            settings.model = "gpt-6.1-sol"
            settings.maxResponseTokens = 4096
            settings.legacyTokenLimit = false
            settings.jsonMode = true
            // Importing a credential must preserve the user's long-task policy.
            settings.systemToolsEnabled = false
            settings.toolsOnly = false
            settings.previewOnly = false
            settings.confirmEachStep = false
            settings.spokenFeedback = false
            SettingsStore.save(settings)
            do {
                // saveAPIKey binds the credential to SettingsStore.load().endpoint.
                try SettingsStore.saveAPIKey(key)
            } catch {
                if let previousSettings { defaults.set(previousSettings, forKey: "agent.settings") }
                else { defaults.removeObject(forKey: "agent.settings") }
                if let previousEndpoint { defaults.set(previousEndpoint, forKey: "agent.keyEndpoint") }
                else { defaults.removeObject(forKey: "agent.keyEndpoint") }
                throw ImportIssue.keychain
            }
            // Only a boolean leaves this scope; never log the credential readback.
            credentialVerified = SettingsStore.apiKey(for: settings.endpoint) == key
            // Do not grant or revoke consent. Its existing endpoint/recipient/
            // revision checks decide whether the confirmation page is required.
            status = credentialVerified == true ? "imported" : "keychain_readback_failed"
            return credentialVerified == true
                ? "模型配置已导入钥匙串；请核对接收方及 AI 数据使用授权。"
                : "模型配置已保存，但钥匙串读回未通过；请检查本机安全回执。"
        } catch {
            // Never include decoder errors, file contents or the credential.
            return "一次性模型配置导入失败；请检查本机安全回执后重试。"
        }
    }

    private enum ImportIssue: Error { case invalidFile, keychain }

    private static func writeReceipt(_ value: Receipt, to url: URL) {
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
            var protectedReceipt = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedReceipt.setResourceValues(values)
        } catch { /* No plaintext logging, including for receipt failures. */ }
    }
}
#endif
