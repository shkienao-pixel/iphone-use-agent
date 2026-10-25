import Foundation
import CryptoKit
import Darwin

/// Every operation is locked across actors/processes; failed decoding never falls back to an empty archive.
final class DiskStore: @unchecked Sendable {
    let root: URL
    let maximumBytes = 64_000_000
    init(root: URL) throws {
        guard root.isFileURL else { throw MemoryError.unsafePath }
        if FileManager.default.fileExists(atPath: root.path),
           try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw MemoryError.unsafePath }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        var protectedRoot = self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        try lock {
            let path = try child("state.json")
            if FileManager.default.fileExists(atPath: path.path) { _ = try read() }
            else {
                let unknown = try FileManager.default.contentsOfDirectory(atPath: self.root.path)
                    .filter { $0 != ".lock" && !FoundationDocument.allCases.map(\.rawValue).contains($0) }
                guard unknown.isEmpty else { throw MemoryError.invalid("请选择独立的空目录创建记忆工作区。") }
                try write(Archive())
            }
            for kind in FoundationDocument.allCases {
                let path = try child(kind.rawValue)
                if !FileManager.default.fileExists(atPath: path.path) { try atomic(Data(kind.starter.utf8), to: path) }
            }
        }
    }
    func child(_ name: String) throws -> URL {
        guard !name.contains("/"), name != ".", name != ".." else { throw MemoryError.unsafePath }
        let path = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path.path),
           try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw MemoryError.unsafePath }
        return path
    }
    func lock<T>(_ operation: () throws -> T) throws -> T {
        let path = try child(".lock")
        let fd = Darwin.open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MemoryError.unsafePath }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MemoryError.invalid("无法锁定记忆档案。") }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    func snapshot() throws -> Archive { try lock { try read() } }
    func transaction<T>(_ update: (inout Archive) throws -> T) throws -> T {
        try lock {
            var state = try read()
            let result = try update(&state)
            guard state.revision < Int.max else { throw MemoryError.capacity }
            state.revision += 1
            try write(state)
            return result
        }
    }
    func snapshotUnlocked() throws -> Archive { try read() }
    private func read() throws -> Archive {
        let path = try child("state.json")
        do {
            guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes) < maximumBytes else { throw MemoryError.capacity }
            let data = try Data(contentsOf: path)
            guard data.count < maximumBytes else { throw MemoryError.capacity }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == 1, archive.revision >= 0,
                  Set(archive.conversations.map(\.id)).count == archive.conversations.count,
                  Set(archive.memories.map(\.id)).count == archive.memories.count,
                  Set(archive.works.map(\.id)).count == archive.works.count else { throw MemoryError.corruptArchive }
            return archive
        } catch let error as MemoryError { throw error }
        catch { throw MemoryError.corruptArchive }
    }
    private func write(_ archive: Archive) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(archive)
        guard bytes.count < maximumBytes else { throw MemoryError.capacity }
        try atomic(bytes, to: child("state.json"))
    }
    func atomic(_ bytes: Data, to path: URL) throws {
        #if os(iOS)
        try bytes.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: path, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func document(_ kind: FoundationDocument) throws -> DocumentSnapshot {
        let path = try child(kind.rawValue)
        guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 100_001) <= 100_000 else {
            throw MemoryError.invalid("基础资料过大：" + kind.rawValue)
        }
        let bytes = try Data(contentsOf: path)
        guard let text = String(data: bytes, encoding: .utf8), bytes.count <= 100_000 else {
            throw MemoryError.invalid("基础资料不是有效的 UTF-8 文本。")
        }
        return DocumentSnapshot(kind: kind, text: text, revision: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
