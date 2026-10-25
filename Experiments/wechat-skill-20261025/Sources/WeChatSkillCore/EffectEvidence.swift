import Foundation

/// Shared by live decision-making and archive validation. It validates semantic
/// consistency, not the authenticity of host-produced observations.
enum EffectEvidence {
    static func validateAfter(_ record: OperationRecord, after: SceneObservation) throws {
        guard let releasedAt = record.dispatchedAt,
              after.frame.origin == record.before.frame.origin,
              after.frame.device == record.before.frame.device,
              after.frame.stream == record.before.frame.stream,
              exact(after.account, record.contact.account),
              after.contactProofID == record.before.contactProofID,
              after.momentBindingID == record.before.momentBindingID,
              after.frame.id != record.before.frame.id,
              after.frame.capturedAt > releasedAt,
              after.frame.confirmedAt > record.before.frame.confirmedAt
        else { throw SkillError.inconsistentJournal }
        try after.validate(mode: after.frame.origin == .fixture ? .offline : .live,
                           now: after.frame.confirmedAt, maxAge: 1)
        switch record.effect {
        case .message:
            guard after.surface == .chat else { throw SkillError.inconsistentJournal }
        case .comment:
            guard [.momentDetail, .momentComposer].contains(after.surface) else { throw SkillError.inconsistentJournal }
        case .like:
            guard [.momentDetail, .momentActions].contains(after.surface) else { throw SkillError.inconsistentJournal }
        }
    }

    static func isNewer(_ after: SceneObservation, than previous: SceneObservation) -> Bool {
        after.frame.id != previous.frame.id && after.frame.capturedAt > previous.frame.capturedAt &&
        after.frame.confirmedAt > previous.frame.confirmedAt
    }

    static func assess(_ record: OperationRecord, after: SceneObservation) -> Verification {
        if record.effect == .like {
            return after.like == .likedBySelf ? .verified : .uncertain("like_state_not_confirmed")
        }
        let before = record.before
        guard before.correspondenceUnambiguous, after.correspondenceUnambiguous else { return .uncertain("item_correspondence_ambiguous") }
        let anchors = Set(before.continuityAnchors)
        guard before.listVerifiedEmpty || (!anchors.isEmpty && anchors.isSubset(of: Set(after.continuityAnchors)))
        else { return .uncertain("viewport_continuity_missing") }
        guard before.items.allSatisfy({ old in
            after.items.contains { $0.id == old.id && exact($0.text, old.text) && $0.author == old.author }
        }) else { return .uncertain("prior_items_not_retained") }
        let oldIDs = Set(before.items.map(\.id))
        let newItems = after.items.filter { item in
            !oldIDs.contains(item.id) && item.author == .myself &&
            record.effect.text.map({ exact($0, item.text) }) == true
        }
        guard newItems.count == 1 else { return .uncertain("unique_new_self_item_missing") }
        switch newItems[0].state {
        case .normal: return .verified
        case .failed: return .failed
        case .pending: return .uncertain("new_item_pending")
        }
    }
}

extension OperationRecord {
    func immutableData() throws -> Data {
        var frozen = self
        frozen.status = .pending; frozen.dispatchedAt = nil; frozen.result = nil; frozen.detail = ""; frozen.recoveryReviews = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(frozen)
    }

    func validateEvidence() throws {
        do {
            let mode: EvaluationMode = before.frame.origin == .fixture ? .offline : .live
            try contact.validate(task: task, mode: mode, now: contact.profile.confirmedAt, maxAge: 1)
            try before.validate(mode: mode, now: before.frame.confirmedAt, maxAge: 1)
            guard effect.authorized(by: task), nonblank(detail),
                  exact(before.account, contact.account), before.contactProofID == contact.proofID,
                  before.frame.device == contact.profile.device, before.frame.stream == contact.profile.stream,
                  before.frame.capturedAt > contact.profile.confirmedAt,
                  reservedAt.timeIntervalSince1970.isFinite, before.frame.confirmedAt <= reservedAt,
                  dispatchedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= reservedAt }) ?? true
            else { throw SkillError.inconsistentJournal }
            if effect.slot == "message" {
                guard before.surface == .chat, before.momentBindingID == nil, moment == nil else { throw SkillError.inconsistentJournal }
            } else {
                guard let moment, moment.id == before.momentBindingID, moment.contactProofID == contact.proofID,
                      case .moment(let clues, _, _, _) = task.goal,
                      TargetMatcher.quality(moment.candidate, account: contact.account, clues: clues) == .match
                else { throw SkillError.inconsistentJournal }
            }
            if status == .alreadySatisfied {
                guard effect == .like, before.like == .likedBySelf, dispatchedAt == nil,
                      result == nil, control == nil, (recoveryReviews ?? []).isEmpty, [.momentDetail, .momentActions].contains(before.surface)
                else { throw SkillError.inconsistentJournal }
                return
            }
            guard let control, control.role == effect.role, before.controls.contains(control) else { throw SkillError.inconsistentJournal }
            if effect == .like {
                guard before.surface == .momentActions, before.like == .notLikedBySelf else { throw SkillError.inconsistentJournal }
            } else {
                guard effect.slot == "message" || before.surface == .momentComposer,
                      let draft = before.draft, draft.replyTarget == nil,
                      draft.kind == (effect.slot == "message" ? .message : .momentComment),
                      effect.text.map({ exact($0, draft.text) }) == true,
                      before.controls.contains(where: { $0.id == draft.fieldID && $0.role == .textField })
                else { throw SkillError.inconsistentJournal }
            }
            if status == .pending {
                guard result == nil, (recoveryReviews ?? []).isEmpty else { throw SkillError.inconsistentJournal }
                return
            }
            if let reviews = recoveryReviews, !reviews.isEmpty {
                if let result {
                    try EffectEvidence.validateAfter(self, after: result)
                    guard case .uncertain = EffectEvidence.assess(self, after: result) else { throw SkillError.inconsistentJournal }
                }
                var previous: RecoveredResultObservation?
                for review in reviews {
                    if let previous {
                        guard case .uncertain = RecoveredResultEvidence.assess(self, after: previous.after) else { throw SkillError.inconsistentJournal }
                    }
                    try RecoveredResultEvidence.validate(self, review: review, previous: previous); previous = review
                }
                guard let last = reviews.last else { throw SkillError.inconsistentJournal }
                switch (status, RecoveredResultEvidence.assess(self, after: last.after)) {
                case (.verified, .verified), (.failed, .failed): return
                case (.uncertain, .uncertain(let reason)):
                    guard exact(detail, reason) else { throw SkillError.inconsistentJournal }; return
                default: throw SkillError.inconsistentJournal
                }
            }
            guard let result else { throw SkillError.inconsistentJournal }
            try EffectEvidence.validateAfter(self, after: result)
            switch (status, EffectEvidence.assess(self, after: result)) {
            case (.verified, .verified), (.failed, .failed): break
            case (.uncertain, .uncertain(let reason)):
                guard exact(detail, reason) else { throw SkillError.inconsistentJournal }
            default: throw SkillError.inconsistentJournal
            }
        } catch { throw SkillError.inconsistentJournal }
    }
}
