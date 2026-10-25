import Foundation

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
    public var recoveryReviews: [RecoveredResultObservation]? = nil
}
public struct JournalSnapshot: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var revision: Int = 0
    public var records: [OperationRecord] = []
    public init() {}
    public func validate() throws {
        guard version == 1, revision >= 0, revision < Int.max,
              Set(records.map(\.id)).count == records.count else { throw SkillError.inconsistentJournal }
        var slots = Set<String>(), taskBytes: [UUID: Data] = [:]
        for entry in records {
            try entry.validateEvidence()
            let bytes = try entry.task.canonicalData()
            guard slots.insert(entry.task.id.uuidString + ":" + entry.effect.slot).inserted,
                  taskBytes[entry.task.id].map({ $0 == bytes }) ?? true
            else { throw SkillError.inconsistentJournal }
            taskBytes[entry.task.id] = bytes
        }
    }

    /// One save changes at most one operation phase. Existing task/target/input
    /// evidence is immutable and terminal outcomes cannot be reset.
    func validateTransition(from previous: Self, expectedRevision: Int) throws {
        guard previous.revision == expectedRevision, expectedRevision < Int.max,
              revision == expectedRevision + 1 else { throw SkillError.revisionConflict }
        try previous.validate(); try validate()
        guard records.count >= previous.records.count, records.count <= previous.records.count + 1 else { throw SkillError.inconsistentJournal }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var changed = 0
        for (old, next) in zip(previous.records, records) {
            guard old.id == next.id, try old.immutableData() == next.immutableData() else { throw SkillError.inconsistentJournal }
            if try encoder.encode(old) == encoder.encode(next) { continue }
            changed += 1
            let previousReviews = old.recoveryReviews ?? [], nextReviews = next.recoveryReviews ?? []
            if nextReviews.count > previousReviews.count {
                guard [.pending, .uncertain].contains(old.status), nextReviews.count == previousReviews.count + 1,
                      try draftBytes(Array(nextReviews.prefix(previousReviews.count))) == draftBytes(previousReviews),
                      old.dispatchedAt != nil, next.dispatchedAt == old.dispatchedAt,
                      try draftBytes(next.result) == draftBytes(old.result) else { throw SkillError.inconsistentJournal }
                continue
            }
            guard previousReviews.isEmpty, nextReviews.isEmpty,
                  try draftBytes(old.recoveryReviews) == draftBytes(next.recoveryReviews) else { throw SkillError.inconsistentJournal }
            switch (old.status, next.status) {
            case (.pending, .pending):
                guard old.dispatchedAt == nil, next.dispatchedAt != nil, next.result == nil else { throw SkillError.inconsistentJournal }
            case (.pending, .uncertain), (.pending, .verified), (.pending, .failed),
                 (.uncertain, .uncertain), (.uncertain, .verified), (.uncertain, .failed):
                guard let releasedAt = old.dispatchedAt, next.dispatchedAt == releasedAt,
                      let after = next.result else { throw SkillError.inconsistentJournal }
                if let prior = old.result {
                    guard EffectEvidence.isNewer(after, than: prior) else { throw SkillError.inconsistentJournal }
                }
            default: throw SkillError.inconsistentJournal
            }
        }
        let added = records.count - previous.records.count
        guard changed + added <= 1 else { throw SkillError.inconsistentJournal }
        if added == 1, let entry = records.last {
            guard [.pending, .alreadySatisfied].contains(entry.status), entry.dispatchedAt == nil, entry.result == nil,
                  (entry.recoveryReviews ?? []).isEmpty
            else { throw SkillError.inconsistentJournal }
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
        try next.validateTransition(from: snapshot, expectedRevision: expectedRevision)
        snapshot = next
    }
}

/// Explicit caller-owned directory, no default location or global configuration.
/// Serializes competing writers with a nonblocking file lock and atomic replace.
@MainActor public final class FileJournal: JournalStorage {
    public let directory: URL
    private let file: LockedJSONFile<JournalSnapshot>
    public init(directory: URL) throws {
        self.directory = directory
        file = try LockedJSONFile(directory: directory, name: "operations")
    }
    public func load() throws -> JournalSnapshot {
        let snapshot = try file.load() ?? JournalSnapshot(); try snapshot.validate(); return snapshot
    }
    public func save(_ next: JournalSnapshot, expectedRevision: Int) throws {
        try file.update { previous in
            try next.validateTransition(from: previous ?? JournalSnapshot(), expectedRevision: expectedRevision)
            return next
        }
    }
}
