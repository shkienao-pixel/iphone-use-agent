import Foundation

/// A new, read-only observation with independent live identity evidence. These
/// fields are supplied by the trusted host; they are not screenshot recognition.
public struct RecoveredResultObservation: Codable, Equatable, Sendable {
    public var readerID: UUID
    public var contact: ContactBinding
    public var moment: MomentBinding?
    public var candidates: [MomentCandidate]
    public var coverage: ObservedRangeCoverage
    public var boundAt: Date
    public var freshnessLimit: TimeInterval
    public var after: SceneObservation
    public var reviewedAt: Date
}

enum OrderedResultAlignment {
    enum Outcome { case unique([Int]), missing, ambiguous }
    static func match(_ before: SceneObservation, _ after: SceneObservation) -> Outcome {
        let old = before.items, current = after.items
        guard old.count <= current.count else { return .missing }
        func context(_ scene: SceneObservation, _ id: String) -> [(VisibleLandmark, Bool)] {
            (scene.landmarks ?? []).flatMap { landmark -> [(VisibleLandmark, Bool)] in
                var values: [(VisibleLandmark, Bool)] = []
                if landmark.followingItemID == id { values.append((landmark, true)) }
                if landmark.precedingItemID == id { values.append((landmark, false)) }
                return values
            }
        }
        let left = old.map { context(before, $0.id) }, right = current.map { context(after, $0.id) }
        func compatible(_ i: Int, _ j: Int) -> Bool {
            exact(old[i].text, current[j].text) && old[i].author == current[j].author && left[i].allSatisfy { anchor, direction in
                right[j].contains { candidate, candidateDirection in
                    direction == candidateDirection && anchor.kind == candidate.kind && exact(anchor.text, candidate.text)
                }
            }
        }
        // Count ordered embeddings, capped at two. Local item IDs are used only
        // within their own frame, never as persistent platform message IDs.
        var ways = Array(repeating: Array(repeating: UInt8(0), count: current.count + 1), count: old.count + 1)
        for j in 0...current.count { ways[old.count][j] = 1 }
        if !old.isEmpty && !current.isEmpty {
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: current.count - 1, through: 0, by: -1) {
                    let count = Int(ways[i][j + 1]) + (compatible(i, j) ? Int(ways[i + 1][j + 1]) : 0)
                    ways[i][j] = UInt8(min(2, count))
                }
            }
        }
        if ways[0][0] == 0 { return .missing }
        if ways[0][0] > 1 { return .ambiguous }
        var mapping: [Int] = [], i = 0, j = 0
        while i < old.count && j < current.count {
            if compatible(i, j) && ways[i + 1][j + 1] > 0 {
                mapping.append(j); i += 1
            }
            j += 1
        }
        return mapping.count == old.count ? .unique(mapping) : .missing
    }
}

enum RecoveredResultEvidence {
    static func boundary(_ record: OperationRecord, previous: RecoveredResultObservation?) -> Date {
        max(record.reservedAt, record.dispatchedAt ?? record.reservedAt,
            record.result?.frame.confirmedAt ?? record.reservedAt, previous?.reviewedAt ?? record.reservedAt)
    }
    static func validate(_ record: OperationRecord, review: RecoveredResultObservation,
                         previous: RecoveredResultObservation?) throws {
        guard let releasedAt = record.dispatchedAt, review.freshnessLimit.isFinite, review.freshnessLimit > 0,
              review.boundAt.timeIntervalSince1970.isFinite, review.reviewedAt.timeIntervalSince1970.isFinite,
              review.reviewedAt >= review.boundAt else { throw SkillError.invalidTransition }
        let mode: EvaluationMode = record.before.frame.origin == .fixture ? .offline : .live
        try review.contact.validate(task: record.task, mode: mode, now: review.boundAt, maxAge: review.freshnessLimit)
        try review.after.validate(mode: mode, now: review.reviewedAt, maxAge: review.freshnessLimit)
        guard exact(review.contact.account, record.contact.account),
              review.contact.profile.device == record.before.frame.device,
              review.after.frame.device == review.contact.profile.device,
              review.after.frame.stream == review.contact.profile.stream,
              review.after.contactProofID == review.contact.proofID,
              exact(review.after.account, record.contact.account),
              review.after.frame.capturedAt > releasedAt,
              review.after.frame.capturedAt > review.contact.profile.confirmedAt,
              review.after.frame.capturedAt >= review.boundAt else { throw SkillError.wrongContact }
        if let previous, previous.readerID == review.readerID {
            guard try draftBytes(previous.contact) == draftBytes(review.contact),
                  try draftBytes(previous.moment) == draftBytes(review.moment),
                  try draftBytes(previous.candidates) == draftBytes(review.candidates),
                  previous.coverage == review.coverage, previous.boundAt == review.boundAt,
                  previous.freshnessLimit == review.freshnessLimit,
                  review.reviewedAt > previous.reviewedAt,
                  EffectEvidence.isNewer(review.after, than: previous.after) else { throw SkillError.staleObservation }
        } else {
            let latest = boundary(record, previous: previous)
            guard review.boundAt > latest, review.contact.profile.capturedAt > latest,
                  review.contact.profile.confirmedAt > latest,
                  review.contact.proofID != (previous?.contact.proofID ?? record.contact.proofID),
                  review.contact.profile.id != (previous?.contact.profile.id ?? record.contact.profile.id)
            else { throw SkillError.staleObservation }
        }
        switch record.effect {
        case .message:
            guard review.moment == nil, review.after.momentBindingID == nil, review.after.surface == .chat,
                  review.candidates.isEmpty else { throw SkillError.wrongMoment }
        case .like, .comment:
            guard let moment = review.moment, moment.contactProofID == review.contact.proofID,
                  review.after.momentBindingID == moment.id else { throw SkillError.wrongMoment }
            if previous?.readerID != review.readerID {
                guard moment.id != (previous?.moment?.id ?? record.moment?.id) else { throw SkillError.wrongMoment }
            }
            try MomentRebindingEvidence.verifyMoment(original: record.moment, fresh: moment, candidates: review.candidates,
                account: record.contact.account, coverage: review.coverage)
            if record.effect == .like {
                guard [.momentDetail, .momentActions].contains(review.after.surface) else { throw SkillError.wrongMoment }
            } else {
                guard [.momentDetail, .momentComposer].contains(review.after.surface) else { throw SkillError.wrongMoment }
            }
        }
    }

    static func assess(_ record: OperationRecord, after: SceneObservation) -> Verification {
        if record.effect == .like {
            return after.like == .likedBySelf ? .verified : .uncertain("recovered_like_state_not_confirmed")
        }
        let before = record.before
        guard before.correspondenceUnambiguous, after.correspondenceUnambiguous else { return .uncertain("recovered_item_correspondence_ambiguous") }
        if record.effect.slot == "message" {
            guard let anchors = before.landmarks, !anchors.isEmpty else { return .uncertain("baseline_landmarks_missing") }
            if before.items.isEmpty {
                guard before.listVerifiedEmpty, anchors.contains(where: { old in
                    old.kind == .conversationStart && (after.landmarks ?? []).contains { fresh in
                        fresh.kind == old.kind && exact(fresh.text, old.text)
                    }
                }) else { return .uncertain("recovered_empty_history_not_proven") }
            }
        }
        if before.items.isEmpty && !before.listVerifiedEmpty { return .uncertain("recovered_empty_history_not_proven") }
        let preserved: [Int]
        switch OrderedResultAlignment.match(before, after) {
        case .missing: return .uncertain("recovered_history_not_retained")
        case .ambiguous: return .uncertain("recovered_history_alignment_ambiguous")
        case .unique(let mapping): preserved = mapping
        }
        let indices = Set(preserved)
        let newItems = after.items.enumerated().filter { index, item in
            !indices.contains(index) && item.author == .myself && record.effect.text.map { exact($0, item.text) } == true
        }.map(\.element)
        guard newItems.count == 1 else { return .uncertain("recovered_unique_new_self_item_missing") }
        switch newItems[0].state {
        case .normal: return .verified
        case .failed: return .failed
        case .pending: return .uncertain("recovered_new_item_pending")
        }
    }
}

/// Read-only with respect to the phone: no reserve/take/action methods. It may
/// only append observations and resolve one already-released journal operation.
@MainActor public final class RecoveredResultReader {
    private let storage: any JournalStorage
    private let operationID: UUID
    private let taskBytes: Data
    private let template: RecoveredResultObservation
    private var invalidated = false
    public init(storage: any JournalStorage, operationID: UUID, task: SkillTask, contact: ContactBinding,
                moment: MomentBinding? = nil, candidates: [MomentCandidate] = [],
                coverage: ObservedRangeCoverage = .unknown, mode: EvaluationMode, now: Date,
                maxObservationAge: TimeInterval = 5) throws {
        try Task.checkCancellation()
        let snapshot = try storage.load()
        guard let record = snapshot.records.first(where: { $0.id == operationID }),
              [.pending, .uncertain].contains(record.status), record.dispatchedAt != nil,
              try task.canonicalData() == record.task.canonicalData() else { throw SkillError.invalidTransition }
        guard record.before.frame.origin == (mode == .offline ? .fixture : .liveDevice),
              maxObservationAge.isFinite, maxObservationAge > 0 else { throw SkillError.wrongProvenance }
        try contact.validate(task: task, mode: mode, now: now, maxAge: maxObservationAge)
        let previous = record.recoveryReviews?.last
        let boundary = RecoveredResultEvidence.boundary(record, previous: previous)
        guard now > boundary, contact.profile.capturedAt > boundary, contact.profile.confirmedAt > boundary,
              contact.proofID != (previous?.contact.proofID ?? record.contact.proofID),
              contact.profile.id != (previous?.contact.profile.id ?? record.contact.profile.id),
              exact(contact.account, record.contact.account), contact.profile.device == record.before.frame.device
        else { throw SkillError.wrongContact }
        if record.effect.slot != "message" {
            guard let moment, moment.contactProofID == contact.proofID,
                  moment.id != (previous?.moment?.id ?? record.moment?.id) else { throw SkillError.wrongMoment }
            try MomentRebindingEvidence.verifyMoment(original: record.moment, fresh: moment, candidates: candidates,
                account: contact.account, coverage: coverage)
        } else if moment != nil || !candidates.isEmpty { throw SkillError.wrongMoment }
        self.storage = storage; self.operationID = operationID; taskBytes = try task.canonicalData()
        // A template only: after is replaced by the actual new observation before
        // validation/persistence. No original pixels or timestamps are rewritten.
        template = .init(readerID: UUID(), contact: contact, moment: moment, candidates: candidates, coverage: coverage,
            boundAt: now, freshnessLimit: maxObservationAge, after: record.before, reviewedAt: now)
    }
    public func invalidate() { invalidated = true }
    public func observe(_ after: SceneObservation, now: Date) throws -> Verification {
        do { try Task.checkCancellation() } catch { invalidate(); throw error }
        guard !invalidated else { throw SkillError.invalidTransition }
        var snapshot = try storage.load()
        guard let index = snapshot.records.firstIndex(where: { $0.id == operationID }) else { throw SkillError.invalidTransition }
        let record = snapshot.records[index]
        guard [.pending, .uncertain].contains(record.status), try record.task.canonicalData() == taskBytes else { throw SkillError.invalidTransition }
        var review = template; review.after = after; review.reviewedAt = now
        try RecoveredResultEvidence.validate(record, review: review, previous: record.recoveryReviews?.last)
        let outcome = RecoveredResultEvidence.assess(record, after: after)
        snapshot.records[index].recoveryReviews = (record.recoveryReviews ?? []) + [review]
        switch outcome {
        case .verified: snapshot.records[index].status = .verified; snapshot.records[index].detail = "observed_recovered_effect_verified"
        case .failed: snapshot.records[index].status = .failed; snapshot.records[index].detail = "observed_recovered_item_failed"
        case .uncertain(let reason): snapshot.records[index].status = .uncertain; snapshot.records[index].detail = reason
        }
        let revision = snapshot.revision; snapshot.revision += 1
        do { try storage.save(snapshot, expectedRevision: revision) }
        catch { invalidate(); throw error }
        return outcome
    }
}
