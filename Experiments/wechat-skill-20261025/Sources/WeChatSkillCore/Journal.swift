import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum Effect: Codable, Equatable, Sendable {
    case message(String), like, comment(String)
    var slot: String {
        switch self { case .message: "message"; case .like: "like"; case .comment: "comment" }
    }
    var text: String? { switch self { case .message(let text), .comment(let text): text; case .like: nil } }
    var role: ControlRole { switch self { case .message: .sendMessage; case .like: .like; case .comment: .sendComment } }
    func authorized(by task: SkillTask) -> Bool {
        switch (task.goal, self) {
        case (.message(let wanted, true), .message(let actual)): return exact(wanted, actual)
        case (.moment(_, true, _, true), .like): return true
        case (.moment(_, _, let wanted?, true), .comment(let actual)): return exact(wanted, actual)
        default: return false
        }
    }
}
public enum OperationStatus: String, Codable, Sendable { case pending, uncertain, verified, alreadySatisfied, failed }
public struct OperationRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var task: SkillTask
    public var effect: Effect
    public var contact: ContactBinding
    public var moment: MomentBinding?
    public var before: SceneObservation
    public var control: ObservedControl?
    public var status: OperationStatus
    public var reservedAt: Date
    public var dispatchedAt: Date?
    public var result: SceneObservation?
    public var detail: String
}
public struct JournalSnapshot: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var revision: Int = 0
    public var records: [OperationRecord] = []
    public init() {}
    public func validate() throws {
        guard version == 1, revision >= 0, Set(records.map(\.id)).count == records.count else { throw SkillError.inconsistentJournal }
        var slots = Set<String>(), taskBytes: [UUID: Data] = [:]
        for entry in records {
            try entry.task.validate()
            let bytes = try entry.task.canonicalData()
            guard entry.effect.authorized(by: entry.task), nonblank(entry.contact.account),
                  exact(entry.before.account, entry.contact.account),
                  entry.before.contactProofID == entry.contact.proofID,
                  entry.reservedAt.timeIntervalSince1970.isFinite,
                  entry.before.frame.confirmedAt <= entry.reservedAt,
                  entry.dispatchedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= entry.reservedAt }) ?? true,
                  slots.insert(entry.task.id.uuidString + ":" + entry.effect.slot).inserted,
                  taskBytes[entry.task.id].map({ $0 == bytes }) ?? true,
                  entry.status != .verified || (entry.dispatchedAt != nil && entry.result != nil),
                  entry.status != .failed || (entry.dispatchedAt != nil && entry.result != nil),
                  entry.status != .alreadySatisfied || (entry.effect == .like && entry.before.like == .likedBySelf && entry.dispatchedAt == nil)
            else { throw SkillError.inconsistentJournal }
            if entry.effect != .like || entry.status != .alreadySatisfied {
                guard let control = entry.control, control.role == entry.effect.role,
                      control.frameID == entry.before.frame.id, entry.before.controls.contains(control)
                else { throw SkillError.inconsistentJournal }
            }
            if entry.effect.slot != "message" {
                guard let moment = entry.moment, moment.id == entry.before.momentBindingID,
                      moment.contactProofID == entry.contact.proofID,
                      moment.candidate.ownerAccount.map({ exact($0, entry.contact.account) }) == true
                else { throw SkillError.inconsistentJournal }
            }
            taskBytes[entry.task.id] = bytes
        }
    }
}

/// All writes compare the previous revision. A store must make this check and
/// replacement indivisible. Loading JSON alone never grants a dispatch permit.
@MainActor public protocol JournalStorage: AnyObject {
    func load() throws -> JournalSnapshot
    func save(_ next: JournalSnapshot, expectedRevision: Int) throws
}

@MainActor public final class MemoryJournal: JournalStorage {
    private var snapshot = JournalSnapshot()
    public init() {}
    public func load() throws -> JournalSnapshot { try snapshot.validate(); return snapshot }
    public func save(_ next: JournalSnapshot, expectedRevision: Int) throws {
        try next.validate()
        guard snapshot.revision == expectedRevision, next.revision == expectedRevision + 1 else { throw SkillError.revisionConflict }
        snapshot = next
    }
}

/// Explicit caller-owned directory, no default location or global configuration.
/// Serializes competing writers with a nonblocking file lock and atomic replace.
@MainActor public final class FileJournal: JournalStorage {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("operations.json") }
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    private func locked<T>(_ work: () throws -> T) throws -> T {
        let path = directory.appendingPathComponent("operations.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SkillError.storageBusy }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SkillError.storageBusy }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try work()
    }
    private func readUnlocked() throws -> JournalSnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return JournalSnapshot() }
        let snapshot = try JSONDecoder().decode(JournalSnapshot.self, from: Data(contentsOf: file))
        try snapshot.validate(); return snapshot
    }
    public func load() throws -> JournalSnapshot { try locked { try readUnlocked() } }
    public func save(_ next: JournalSnapshot, expectedRevision: Int) throws {
        try locked {
            let previous = try readUnlocked(); try next.validate()
            guard previous.revision == expectedRevision, next.revision == expectedRevision + 1 else { throw SkillError.revisionConflict }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
