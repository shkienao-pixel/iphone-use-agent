import Foundation

public enum SkillError: Error, Equatable {
    case invalidTask, invalidObservation, wrongProvenance, staleObservation
    case wrongContact, wrongMoment, ambiguousTarget, incompleteTarget
    case invalidAction, unavailableInput, unapprovedEffect, wrongDraft
    case duplicateOperation, invalidTransition, inconsistentJournal, revisionConflict, storageBusy
}

/// Swift String equality permits Unicode canonical equivalence. User text and
/// account evidence use UTF-8 equality, preserving the exact supplied spelling.
public func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
func nonblank(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

public enum EvidenceOrigin: String, Codable, Sendable { case liveDevice, referenceImage, fixture }
public enum EvaluationMode: Sendable { case live, offline }

public struct FrameStamp: Codable, Equatable, Sendable {
    public var id: UUID
    public var device: String
    public var stream: UUID
    public var capturedAt: Date
    public var confirmedAt: Date
    public var origin: EvidenceOrigin

    public init(id: UUID = UUID(), device: String, stream: UUID, capturedAt: Date,
                confirmedAt: Date, origin: EvidenceOrigin) {
        self.id = id; self.device = device; self.stream = stream
        self.capturedAt = capturedAt; self.confirmedAt = confirmedAt; self.origin = origin
    }

    public func validate(mode: EvaluationMode, now: Date, maxAge: TimeInterval) throws {
        guard nonblank(device), maxAge.isFinite, maxAge > 0,
              [capturedAt, confirmedAt, now].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              capturedAt <= confirmedAt, confirmedAt <= now else { throw SkillError.invalidObservation }
        guard now.timeIntervalSince(confirmedAt) <= maxAge else { throw SkillError.staleObservation }
        guard origin == (mode == .live ? .liveDevice : .fixture) else { throw SkillError.wrongProvenance }
    }
}

public struct ContactQuery: Codable, Equatable, Sendable {
    public var keyword: String
    public var expectedName: String?
    public var expectedAccount: String?
    public init(keyword: String, expectedName: String? = nil, expectedAccount: String? = nil) {
        self.keyword = keyword; self.expectedName = expectedName; self.expectedAccount = expectedAccount
    }
    public func validate() throws {
        guard nonblank(keyword), expectedName.map(nonblank) ?? true,
              expectedAccount.map(nonblank) ?? true else { throw SkillError.invalidTask }
    }
}

public struct MomentClues: Codable, Equatable, Sendable {
    public var dateLabel: String?
    public var explicitYear: Int?
    public var bodyExcerpt: String?
    public var mediaDescription: String?
    public init(dateLabel: String? = nil, explicitYear: Int? = nil,
                bodyExcerpt: String? = nil, mediaDescription: String? = nil) {
        self.dateLabel = dateLabel; self.explicitYear = explicitYear
        self.bodyExcerpt = bodyExcerpt; self.mediaDescription = mediaDescription
    }
    public func validate() throws {
        guard [dateLabel, bodyExcerpt, mediaDescription].contains(where: { $0 != nil }),
              [dateLabel, bodyExcerpt, mediaDescription].allSatisfy({ $0.map(nonblank) ?? true }),
              explicitYear.map({ (1...9999).contains($0) && dateLabel != nil }) ?? true
        else { throw SkillError.invalidTask }
    }
}

public enum TaskGoal: Codable, Equatable, Sendable {
    case findContact
    case message(text: String, submit: Bool)
    case moment(clues: MomentClues, like: Bool, comment: String?, submit: Bool)
}
public enum EntryRoute: String, Codable, Sendable { case contactProfile, friendsFeed }

public struct SkillTask: Codable, Equatable, Sendable {
    public var id: UUID
    public var originalRequest: String
    public var contact: ContactQuery
    public var route: EntryRoute
    public var goal: TaskGoal
    public init(id: UUID = UUID(), originalRequest: String, contact: ContactQuery,
                route: EntryRoute = .contactProfile, goal: TaskGoal) {
        self.id = id; self.originalRequest = originalRequest; self.contact = contact
        self.route = route; self.goal = goal
    }
    public func validate() throws {
        try contact.validate()
        guard nonblank(originalRequest) else { throw SkillError.invalidTask }
        switch goal {
        case .findContact: guard route == .contactProfile else { throw SkillError.invalidTask }
        case .message(let text, _):
            guard nonblank(text), route == .contactProfile else { throw SkillError.invalidTask }
        case .moment(let clues, let like, let comment, _):
            try clues.validate()
            guard like || comment != nil, comment.map(nonblank) ?? true else { throw SkillError.invalidTask }
        }
    }
    /// Stable bytes, not Swift's Unicode-normalizing Equatable comparison.
    func canonicalData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Created only after a trusted host adapter has recognized an actual profile.
/// This value is a semantic contract, not a pixel detector or authentication token.
public struct ContactBinding: Codable, Equatable, Sendable {
    public var proofID: UUID
    public var account: String
    public var name: String
    public var profile: FrameStamp
    public init(proofID: UUID = UUID(), account: String, name: String, profile: FrameStamp) {
        self.proofID = proofID; self.account = account; self.name = name; self.profile = profile
    }
    public func validate(task: SkillTask, mode: EvaluationMode, now: Date, maxAge: TimeInterval) throws {
        try task.validate(); try profile.validate(mode: mode, now: now, maxAge: maxAge)
        guard nonblank(account), nonblank(name),
              task.contact.expectedAccount.map({ exact($0, account) }) ?? true,
              task.contact.expectedName.map({ exact($0, name) }) ?? true else { throw SkillError.wrongContact }
    }
}

/// A host-issued local binding for this run. Never a platform post ID or URL.
public struct MomentBinding: Codable, Equatable, Sendable {
    public var id: UUID
    public var contactProofID: UUID
    public var candidate: MomentCandidate
    public init(id: UUID = UUID(), contactProofID: UUID, candidate: MomentCandidate) {
        self.id = id; self.contactProofID = contactProofID; self.candidate = candidate
    }
}
