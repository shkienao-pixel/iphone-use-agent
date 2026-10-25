import Foundation

public enum PreparationIntentKind: String, Codable, Sendable { case focus, openPasteMenu, selectAll, typeASCII, paste }

/// An audit intent, not an executable action. The before-frame retains observed
/// coordinates for inspection; they must never be replayed as execution input.
public struct PreparationIntent: Codable, Equatable, Sendable {
    public var kind: PreparationIntentKind
    public var before: DraftObservation
    public var text: String?
    public var releasedAt: Date
}

public struct DraftBindingRecord: Codable, Equatable, Sendable {
    public var scope: DraftScope
    public var contact: ContactBinding?
    public var moment: MomentBinding?
    public var boundAt: Date
}

func draftBytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
}

enum DraftStateRules {
    static func validate(_ observation: DraftObservation, scope: DraftScope, mode: EvaluationMode,
                         now: Date, maxAge: TimeInterval, fieldBindingID: UUID? = nil) throws {
        try observation.frame.validate(mode: mode, now: now, maxAge: maxAge)
        guard try draftBytes(observation.scope) == draftBytes(scope), observation.frame.device == scope.device,
              observation.frame.stream == scope.stream else { throw SkillError.wrongContact }
        guard !observation.blockingOverlay, observation.replyTarget == nil, observation.field.role == .textField,
              observation.fieldKind.rawValue == scope.purpose.rawValue,
              fieldBindingID.map({ $0 == observation.fieldBindingID }) ?? true,
              Set(observation.controls.map(\.id)).count == observation.controls.count,
              observation.controls.contains(observation.field) else { throw SkillError.wrongDraft }
        for control in observation.controls {
            try AtomicActionRules.validateControl(control, frame: observation.frame, controls: observation.controls, mode: mode)
        }
        if observation.ownership == .empty {
            guard observation.complete, observation.text == "" else { throw SkillError.invalidObservation }
        }
    }

    static func sameLogicalScope(_ lhs: DraftScope, _ rhs: DraftScope) -> Bool {
        lhs.taskID == rhs.taskID && lhs.purpose == rhs.purpose && exact(lhs.device, rhs.device) &&
        ((lhs.account == nil && rhs.account == nil) || (lhs.account.flatMap { a in rhs.account.map { exact(a, $0) } } == true))
    }

    static func validateBinding(_ binding: DraftBindingRecord, task: SkillTask, mode: EvaluationMode) throws {
        _ = try binding.scope.text(for: task)
        guard binding.boundAt.timeIntervalSince1970.isFinite else { throw SkillError.invalidObservation }
        if binding.scope.purpose == .contactSearch {
            guard binding.contact == nil, binding.moment == nil else { throw SkillError.wrongContact }; return
        }
        guard let contact = binding.contact, let account = binding.scope.account,
              exact(contact.account, account), contact.proofID == binding.scope.contactProofID,
              exact(contact.profile.device, binding.scope.device), contact.profile.stream == binding.scope.stream,
              contact.profile.confirmedAt <= binding.boundAt else { throw SkillError.wrongContact }
        try contact.validate(task: task, mode: mode, now: contact.profile.confirmedAt, maxAge: 1)
        if binding.scope.purpose == .momentComment {
            guard let moment = binding.moment, moment.id == binding.scope.momentBindingID,
                  moment.contactProofID == contact.proofID,
                  case .moment(let clues, _, _, _) = task.goal,
                  TargetMatcher.quality(moment.candidate, account: account, clues: clues) == .match
            else { throw SkillError.wrongMoment }
        } else if binding.moment != nil { throw SkillError.wrongMoment }
    }

    static func canResolve(_ intent: PreparationIntent, with observation: DraftObservation, desired: String) -> Bool {
        guard observation.complete, let text = observation.text, observation.composing == false,
              observation.frame.capturedAt > intent.releasedAt else { return false }
        if exact(text, desired) { return true }
        guard [.empty, .taskOwned].contains(observation.ownership) else { return false }
        switch intent.kind {
        case .focus: return observation.focused
        case .openPasteMenu:
            return observation.controls.contains { $0.role == .paste && $0.ownerFieldID == observation.field.id }
        case .selectAll: return observation.selection == .allText
        case .typeASCII, .paste: return intent.before.text.map { !exact($0, text) } == true
        }
    }
}

/// Durable observations and intents only. Rebinding never reconstructs an input
/// ticket, clipboard lease, focus or selection permission from these archives.
public struct DraftCheckpoint: Codable, Equatable, Sendable {
    public var version = 1
    public var revision = 0
    public var id: UUID
    public var task: SkillTask
    public var origin: EvidenceOrigin
    public var bindings: [DraftBindingRecord]
    public var lastReadback: DraftObservation?
    public var pending: PreparationIntent?
    public var updatedAt: Date

    public func validate() throws {
        do {
            guard version == 1, revision >= 0, revision < Int.max, origin != .referenceImage,
                  let initial = bindings.first, updatedAt.timeIntervalSince1970.isFinite else { throw SkillError.inconsistentJournal }
            let mode: EvaluationMode = origin == .fixture ? .offline : .live
            let desired = try initial.scope.text(for: task)
            var priorDate: Date?
            for binding in bindings {
                try DraftStateRules.validateBinding(binding, task: task, mode: mode)
                guard DraftStateRules.sameLogicalScope(initial.scope, binding.scope),
                      binding.boundAt <= updatedAt, priorDate.map({ binding.boundAt > $0 }) ?? true
                else { throw SkillError.inconsistentJournal }
                priorDate = binding.boundAt
            }
            func validateObservation(_ observation: DraftObservation) throws {
                guard observation.frame.origin == origin,
                      let binding = try bindings.first(where: { try draftBytes($0.scope) == draftBytes(observation.scope) }),
                      observation.frame.capturedAt >= binding.boundAt,
                      observation.frame.confirmedAt <= updatedAt else { throw SkillError.inconsistentJournal }
                try DraftStateRules.validate(observation, scope: binding.scope, mode: mode,
                                           now: observation.frame.confirmedAt, maxAge: 1)
            }
            if let lastReadback { try validateObservation(lastReadback) }
            if let pending {
                try validateObservation(pending.before)
                guard pending.releasedAt.timeIntervalSince1970.isFinite,
                      pending.releasedAt >= pending.before.frame.confirmedAt, pending.releasedAt <= updatedAt
                else { throw SkillError.inconsistentJournal }
                switch pending.kind {
                case .focus, .openPasteMenu, .selectAll:
                    guard pending.text == nil else { throw SkillError.inconsistentJournal }
                case .typeASCII, .paste:
                    guard let old = pending.before.text, pending.before.complete, pending.before.composing == false,
                          [.empty, .taskOwned].contains(pending.before.ownership), let payload = pending.text, !payload.isEmpty,
                          pending.before.focused else { throw SkillError.inconsistentJournal }
                    let replacement = pending.before.selection == .allText
                    guard replacement || (desired.utf8.starts(with: old.utf8) && (old.isEmpty || pending.before.selection == .caretAtEnd))
                    else { throw SkillError.inconsistentJournal }
                    let remaining = replacement ? desired : String(decoding: desired.utf8.dropFirst(old.utf8.count), as: UTF8.self)
                    if pending.kind == .typeASCII {
                        guard payload.utf8.count <= 500, payload.utf8.allSatisfy({ (32...126).contains($0) }),
                              exact(payload, String(remaining.prefix(500))) else { throw SkillError.inconsistentJournal }
                    } else if !exact(payload, remaining) { throw SkillError.inconsistentJournal }
                }
            }
        } catch { throw SkillError.inconsistentJournal }
    }

    func validateTransition(from previous: Self?, expectedRevision: Int?) throws {
        try validate()
        guard let previous else {
            guard expectedRevision == nil, revision == 0, bindings.count == 1, lastReadback == nil, pending == nil
            else { throw SkillError.revisionConflict }; return
        }
        try previous.validate()
        guard expectedRevision == previous.revision, previous.revision < Int.max, revision == previous.revision + 1 else { throw SkillError.revisionConflict }
        guard id == previous.id, try task.canonicalData() == previous.task.canonicalData(), origin == previous.origin,
              updatedAt >= previous.updatedAt, bindings.count >= previous.bindings.count,
              bindings.count <= previous.bindings.count + 1,
              try draftBytes(Array(bindings.prefix(previous.bindings.count))) == draftBytes(previous.bindings)
        else { throw SkillError.inconsistentJournal }
        if let old = previous.lastReadback, try draftBytes(old) != draftBytes(lastReadback) {
            guard let newer = lastReadback, newer.frame.id != old.frame.id,
                  newer.frame.confirmedAt > old.frame.confirmedAt, newer.frame.capturedAt >= old.frame.capturedAt
            else { throw SkillError.inconsistentJournal }
        }
        if bindings.count > previous.bindings.count {
            guard try draftBytes(lastReadback) == draftBytes(previous.lastReadback),
                  try draftBytes(pending) == draftBytes(previous.pending) else { throw SkillError.inconsistentJournal }
        } else if let old = previous.pending {
            if pending == nil {
                guard let lastReadback, DraftStateRules.canResolve(old, with: lastReadback,
                    desired: try bindings[0].scope.text(for: task)) else { throw SkillError.inconsistentJournal }
            } else if try draftBytes(pending) != draftBytes(old) { throw SkillError.inconsistentJournal }
        } else if let pending {
            guard let before = previous.lastReadback, try draftBytes(before) == draftBytes(pending.before),
                  try draftBytes(lastReadback) == draftBytes(before) else { throw SkillError.inconsistentJournal }
        }
    }
}

@MainActor public protocol DraftCheckpointStorage: AnyObject {
    func load() throws -> DraftCheckpoint?
    func save(_ next: DraftCheckpoint, expectedRevision: Int?) throws
}

@MainActor public final class MemoryDraftCheckpoint: DraftCheckpointStorage {
    private var checkpoint: DraftCheckpoint?
    public init() {}
    public func load() throws -> DraftCheckpoint? { try checkpoint?.validate(); return checkpoint }
    public func save(_ next: DraftCheckpoint, expectedRevision: Int?) throws {
        try next.validateTransition(from: checkpoint, expectedRevision: expectedRevision); checkpoint = next
    }
}

@MainActor public final class FileDraftCheckpoint: DraftCheckpointStorage {
    private let file: LockedJSONFile<DraftCheckpoint>
    public init(directory: URL) throws { file = try LockedJSONFile(directory: directory, name: "draft") }
    public func load() throws -> DraftCheckpoint? { let value = try file.load(); try value?.validate(); return value }
    public func save(_ next: DraftCheckpoint, expectedRevision: Int?) throws {
        try file.update { old in try next.validateTransition(from: old, expectedRevision: expectedRevision); return next }
    }
}

public enum ObservedRangeCoverage: String, Codable, Sendable { case completeRequestedRange, partial, unknown }
public typealias DraftRecoveryCoverage = ObservedRangeCoverage

enum MomentRebindingEvidence {
    static func verifyMoment(original: MomentBinding?, fresh: MomentBinding?, candidates: [MomentCandidate],
                             account: String, coverage: DraftRecoveryCoverage) throws {
        guard coverage == .completeRequestedRange, let original, let fresh,
              original.candidate.bodyComplete, nonblank(original.candidate.body),
              fresh.candidate.bodyComplete else { throw SkillError.incompleteTarget }
        let wanted = original.candidate
        let clues = MomentClues(dateLabel: wanted.dateLabel, explicitYear: wanted.explicitYear,
                               bodyExcerpt: wanted.body, mediaDescription: wanted.mediaDescription)
        guard case .unique(let id) = try TargetMatcher.moment(account: account, clues: clues, candidates: candidates),
              id == fresh.candidate.localID,
              let candidate = candidates.first(where: { $0.localID == id }),
              try draftBytes(candidate) == draftBytes(fresh.candidate), exact(candidate.body, wanted.body),
              (candidate.dateLabel.map({ actual in wanted.dateLabel.map { exact(actual, $0) } ?? true }) ?? (wanted.dateLabel == nil)),
              candidate.explicitYear == wanted.explicitYear else { throw SkillError.wrongMoment }
    }
}
