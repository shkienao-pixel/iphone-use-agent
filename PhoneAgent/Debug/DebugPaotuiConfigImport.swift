#if DEBUG
import Foundation
import Darwin

/// Cable-paired, one-use development import. No credential arguments, logs,
/// screenshots or model context. Production uses native Passport authorization.
@MainActor enum DebugPaotuiConfigImport {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--import-paotui-config-once") else { return }
        let source = URL.documentsDirectory.appendingPathComponent("paotui-config.once.json")
        let receipt = URL.documentsDirectory.appendingPathComponent("paotui-import.receipt.json")
        var success = false
        defer {
            _ = unlink(source.path)
            var state = stat()
            let removed = lstat(source.path, &state) == -1 && errno == ENOENT
            if let data = try? JSONSerialization.data(withJSONObject: ["success": success && removed, "sourceRemoved": removed]) {
                try? data.write(to: receipt, options: [.atomic, .completeFileProtection])
            }
        }
        do {
            let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), (1...16384).contains(info.st_size) else { return }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: source.path)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let bytes = try handle.read(upToCount: 16385), bytes.count <= 16384,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == ["version", "token"], object["version"] as? Int == 1,
                  let token = object["token"] as? String, !token.isEmpty else { return }
            guard unlink(source.path) == 0 else { return }
            try MeituanPaotuiStore.shared.installCredential(token)
            success = MeituanPaotuiStore.shared.configured
        } catch { /* No raw error can echo a credential. */ }
    }
}
#endif
