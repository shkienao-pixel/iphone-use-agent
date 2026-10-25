import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Internal shared persistence primitive; no workflow or execution policy.
@MainActor final class LockedJSONFile<Value: Codable> {
    let directory: URL
    private let name: String
    private var file: URL { directory.appendingPathComponent(name + ".json") }
    init(directory: URL, name: String) throws {
        self.directory = directory; self.name = name
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    private func locked<T>(_ work: () throws -> T) throws -> T {
        let descriptor = open(directory.appendingPathComponent(name + ".lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SkillError.storageBusy }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SkillError.storageBusy }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try work()
    }
    private func readUnlocked() throws -> Value? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
    }
    func load() throws -> Value? { try locked { try readUnlocked() } }
    func update(_ replacement: (Value?) throws -> Value) throws {
        try locked {
            let next = try replacement(readUnlocked())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
