#if DEBUG
import Foundation
import CryptoKit
import Darwin

// Explicit development-only provisioning. Neither the credential nor provider
// response text is included in launch arguments, diagnostics, or receipts.
enum DebugCtripConfigImport {
    private struct Payload: Decodable {
        let version: Int
        let apiKey: String
    }

    private struct ImportReceipt: Encodable {
        let success: Bool
        let createdAt: Date
        let sourceRemoved: Bool
        let credentialVerified: Bool
    }

    private struct ConnectionReceipt: Encodable {
        let status: String
        let resultCharCount: Int
        let createdAt: Date
        let resultSHA256: String?
    }

    static func runIfRequested() -> String? {
        guard ProcessInfo.processInfo.arguments.contains("--import-ctrip-config-once") else { return nil }
        let source = URL.documentsDirectory.appendingPathComponent("ctrip-config.once.json", isDirectory: false)
        let receipt = URL.documentsDirectory.appendingPathComponent("ctrip-config-import.receipt.json", isDirectory: false)
        var success = false
        var credentialVerified = false
        defer {
            // unlink also removes an invalid symlink, without recursively removing
            // a directory supplied under this file name.
            _ = unlink(source.path)
            let removed = sourceIsAbsent(source)
            writeReceipt(ImportReceipt(success: success && removed, createdAt: Date(), sourceRemoved: removed,
                                       credentialVerified: credentialVerified), to: receipt)
        }

        do {
            let data = try protectedSourceData(at: source)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["version", "apiKey"]) else { throw ImportIssue.invalidFile }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let key = payload.apiKey
            guard payload.version == 1, (8...4096).contains(key.utf8.count),
                  key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw ImportIssue.invalidFile }

            // The plaintext must be gone before any persistent credential write.
            guard unlink(source.path) == 0, sourceIsAbsent(source) else { throw ImportIssue.cleanup }
            try CtripStore.saveAPIKey(key)
            credentialVerified = CtripStore.apiKey() == key
            success = credentialVerified
            return credentialVerified
                ? "携程授权码已导入本机钥匙串；可在携程设置中核对连接。"
                : "携程授权码已保存，但钥匙串读回未通过；请检查本机安全回执。"
        } catch {
            return "一次性携程配置导入失败；请检查本机安全回执后重试。"
        }
    }

    static func probeIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--test-ctrip-connection-once") else { return }
        let receipt = URL.documentsDirectory.appendingPathComponent("ctrip-connection.receipt.json", isDirectory: false)
        let key = CtripStore.apiKey()
        guard !key.isEmpty else {
            writeReceipt(ConnectionReceipt(status: "missing_credential", resultCharCount: 0,
                                           createdAt: Date(), resultSHA256: nil), to: receipt)
            return
        }
        do {
            let result = try await CtripClient(apiKey: key).query(query: "请推荐上海一日游适合参观的景点。仅查询旅游信息，不预订、不下单。")
            let digest = SHA256.hash(data: Data(result.utf8)).map { String(format: "%02x", $0) }.joined()
            writeReceipt(ConnectionReceipt(status: "ok", resultCharCount: result.count,
                                           createdAt: Date(), resultSHA256: digest), to: receipt)
        } catch is CancellationError {
            writeReceipt(ConnectionReceipt(status: "cancelled", resultCharCount: 0,
                                           createdAt: Date(), resultSHA256: nil), to: receipt)
        } catch {
            writeReceipt(ConnectionReceipt(status: "failed", resultCharCount: 0,
                                           createdAt: Date(), resultSHA256: nil), to: receipt)
        }
    }

    private enum ImportIssue: Error { case invalidFile, cleanup }

    private static func protectedSourceData(at url: URL) throws -> Data {
        // Refuse symlinks and check the opened file itself before reading bytes.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ImportIssue.invalidFile }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (1...16384).contains(metadata.st_size) else { throw ImportIssue.invalidFile }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var protectedSource = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedSource.setResourceValues(values)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 16385) ?? Data()
        guard (1...16384).contains(data.count) else { throw ImportIssue.invalidFile }
        return data
    }

    private static func sourceIsAbsent(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == -1 && errno == ENOENT
    }

    private static func writeReceipt<T: Encodable>(_ value: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
            var protectedReceipt = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedReceipt.setResourceValues(values)
        } catch { /* Receipt failures must not emit credentials or raw errors. */ }
    }
}
#endif
