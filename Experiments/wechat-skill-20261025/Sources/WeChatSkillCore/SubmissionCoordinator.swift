import Foundation

public struct DispatchTicket: Equatable, Sendable {
    public let operationID: UUID
    fileprivate let nonce: UUID
}
public enum Reservation: Equatable, Sendable { case dispatch(DispatchTicket), alreadySatisfied(UUID) }
public enum Verification: Equatable, Sendable { case verified, failed, uncertain(String) }

/// Pure decision/journal component. It never reads screens, taps, types, connects
/// BLE, calls a model, or invokes another project's service. Caller owns I/O.
@MainActor public final class SubmissionCoordinator {
    private let storage: any JournalStorage
    private let mode: EvaluationMode
    private let maxAge: TimeInterval
    private var contact: ContactBinding?
    private var moment: MomentBinding?
    private var boundTask: Data?
    private var tickets: [UUID: DispatchTicket] = [:]

    public init(storage: any JournalStorage, mode: EvaluationMode, maxObservationAge: TimeInterval = 5) throws {
        guard maxObservationAge.isFinite, maxObservationAge > 0 else { throw SkillError.invalidTask }
        self.storage = storage; self.mode = mode; self.maxAge = maxObservationAge
        _ = try storage.load()
    }

    /// Host calls this on pause, stop, cancellation or capture/device changes.
    /// Audit records survive; in-memory execution rights do not.
    public func invalidateLiveContext() {
        contact = nil; moment = nil; boundTask = nil; tickets.removeAll()
    }

    private func requireRunning() throws {
        do { try Task.checkCancellation() }
        catch { invalidateLiveContext(); throw error }
    }

    public func bindContact(_ binding: ContactBinding, task: SkillTask, now: Date) throws {
        try requireRunning()
        try binding.validate(task: task, mode: mode, now: now, maxAge: maxAge)
        contact = binding; boundTask = try task.canonicalData(); moment = nil; tickets.removeAll()
    }

    @discardableResult public func bindMoment(candidates: [MomentCandidate], task: SkillTask,
                                             frame: FrameStamp, now: Date) throws -> MomentBinding {
        try requireRunning()
        guard let contact, try task.canonicalData() == boundTask,
              case .moment(let clues, _, _, _) = task.goal else { throw SkillError.wrongMoment }
        try task.validate(); try frame.validate(mode: mode, now: now, maxAge: maxAge)
        guard frame.device == contact.profile.device, frame.stream == contact.profile.stream,
              frame.confirmedAt >= contact.profile.confirmedAt,
              frame.capturedAt > contact.profile.confirmedAt else { throw SkillError.wrongContact }
        guard case .unique(let id) = try TargetMatcher.moment(account: contact.account, clues: clues, candidates: candidates),
              let selected = candidates.first(where: { $0.localID == id }) else { throw SkillError.ambiguousTarget }
        let binding = MomentBinding(contactProofID: contact.proofID, candidate: selected)
        moment = binding; tickets.removeAll(); return binding
    }

    private func validateContext(_ observation: SceneObservation, task: SkillTask, effect: Effect, now: Date) throws {
        try task.validate(); try observation.validate(mode: mode, now: now, maxAge: maxAge)
        guard try task.canonicalData() == boundTask,
              let contact, contact.proofID == observation.contactProofID,
              exact(contact.account, observation.account),
              observation.frame.device == contact.profile.device, observation.frame.stream == contact.profile.stream,
              observation.frame.confirmedAt >= contact.profile.confirmedAt,
              observation.frame.capturedAt > contact.profile.confirmedAt,
              task.contact.expectedAccount.map({ exact($0, contact.account) }) ?? true,
              task.contact.expectedName.map({ exact($0, contact.name) }) ?? true
        else { throw SkillError.wrongContact }
        if effect.slot == "message" {
            guard observation.surface == .chat, observation.momentBindingID == nil else { throw SkillError.wrongMoment }
        } else {
            guard let moment, observation.momentBindingID == moment.id,
                  moment.contactProofID == contact.proofID,
                  case .moment(let clues, _, _, _) = task.goal,
                  TargetMatcher.quality(moment.candidate, account: contact.account, clues: clues) == .match,
                  [.momentDetail, .momentActions, .momentComposer].contains(observation.surface)
            else { throw SkillError.wrongMoment }
        }
    }

    public func reserve(task: SkillTask, effect: Effect, observation: SceneObservation,
                        controlID: String? = nil, now: Date) throws -> Reservation {
        try requireRunning()
        guard effect.authorized(by: task) else { throw SkillError.unapprovedEffect }
        try validateContext(observation, task: task, effect: effect, now: now)
        var snapshot = try storage.load()
        let taskRecords = snapshot.records.filter { $0.task.id == task.id }
        guard try taskRecords.allSatisfy({ try $0.task.canonicalData() == task.canonicalData() }) else { throw SkillError.invalidTask }
        guard !taskRecords.contains(where: { $0.effect.slot == effect.slot }) else { throw SkillError.duplicateOperation }
        if case .comment = effect, case .moment(_, true, _, _) = task.goal {
            guard taskRecords.contains(where: { $0.effect == .like && [.verified, .alreadySatisfied].contains($0.status) })
            else { throw SkillError.invalidTransition }
        }
        let already = effect == .like && observation.like == .likedBySelf
        var control: ObservedControl?
        if !already {
            guard let controlID, let target = observation.controls.first(where: { $0.id == controlID }),
                  target.role == effect.role else { throw SkillError.invalidAction }
            try AtomicActionRules.validateControl(target, frame: observation.frame, controls: observation.controls, mode: mode)
            control = target
            if effect == .like {
                guard observation.surface == .momentActions, observation.like == .notLikedBySelf else { throw SkillError.invalidObservation }
            } else {
                guard effect.slot == "message" || observation.surface == .momentComposer else { throw SkillError.wrongMoment }
                guard let draft = observation.draft, draft.replyTarget == nil,
                      draft.kind == (effect.slot == "message" ? .message : .momentComment),
                      effect.text.map({ exact($0, draft.text) }) == true,
                      observation.controls.contains(where: { $0.id == draft.fieldID && $0.role == .textField })
                else { throw SkillError.wrongDraft }
            }
        }
        let id = UUID()
        let entry = OperationRecord(id: id, task: task, effect: effect, contact: contact!,
                                    moment: effect.slot == "message" ? nil : moment, before: observation,
                                    control: control, status: already ? .alreadySatisfied : .pending,
                                    reservedAt: now, dispatchedAt: nil, result: nil,
                                    detail: already ? "observed_already_liked_no_input" : "reserved_before_dispatch")
        snapshot.records.append(entry); let revision = snapshot.revision; snapshot.revision += 1
        try storage.save(snapshot, expectedRevision: revision)
        if already { return .alreadySatisfied(id) }
        let ticket = DispatchTicket(operationID: id, nonce: UUID()); tickets[id] = ticket
        return .dispatch(ticket)
    }

    /// Persist intent BEFORE handing the host one single tap. Returning this
    /// value does not establish that I/O occurred. Even a crash before the tap
    /// remains uncertain; no automatic replay or durable reusable ticket exists.
    public func take(_ ticket: DispatchTicket, current: SceneObservation, now: Date) throws -> AtomicAction {
        try requireRunning()
        guard tickets.removeValue(forKey: ticket.operationID) == ticket else { throw SkillError.invalidTransition }
        var snapshot = try storage.load()
        guard let index = snapshot.records.firstIndex(where: { $0.id == ticket.operationID }) else { throw SkillError.inconsistentJournal }
        let entry = snapshot.records[index]
        try validateContext(current, task: entry.task, effect: entry.effect, now: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard entry.status == .pending, entry.dispatchedAt == nil, let control = entry.control,
              try encoder.encode(current) == encoder.encode(entry.before), now >= entry.reservedAt else { throw SkillError.invalidTransition }
        snapshot.records[index].dispatchedAt = now
        snapshot.records[index].detail = "single_tap_released_to_host_result_unknown"
        let revision = snapshot.revision; snapshot.revision += 1
        try storage.save(snapshot, expectedRevision: revision)
        return .tap(control)
    }

    public func verify(operationID: UUID, after: SceneObservation, now: Date) throws -> Verification {
        try requireRunning()
        var snapshot = try storage.load()
        guard let index = snapshot.records.firstIndex(where: { $0.id == operationID }) else { throw SkillError.invalidTransition }
        let entry = snapshot.records[index]
        guard [.pending, .uncertain].contains(entry.status), (entry.recoveryReviews ?? []).isEmpty,
              let dispatchTime = entry.dispatchedAt else { throw SkillError.invalidTransition }
        try validateContext(after, task: entry.task, effect: entry.effect, now: now)
        guard entry.effect.slot != "comment" || [.momentDetail, .momentComposer].contains(after.surface)
        else { throw SkillError.wrongMoment }
        guard after.contactProofID == entry.before.contactProofID,
              after.momentBindingID == entry.before.momentBindingID,
              after.frame.id != entry.before.frame.id, after.frame.capturedAt > dispatchTime,
              after.frame.confirmedAt > entry.before.frame.confirmedAt else { throw SkillError.staleObservation }
        if let previous = entry.result {
            guard EffectEvidence.isNewer(after, than: previous) else { throw SkillError.staleObservation }
        }
        let verification = EffectEvidence.assess(entry, after: after)
        snapshot.records[index].result = after
        switch verification {
        case .verified: snapshot.records[index].status = .verified; snapshot.records[index].detail = "observed_effect_verified"
        case .failed: snapshot.records[index].status = .failed; snapshot.records[index].detail = "observed_new_item_failed"
        case .uncertain(let reason): snapshot.records[index].status = .uncertain; snapshot.records[index].detail = reason
        }
        let revision = snapshot.revision; snapshot.revision += 1
        try storage.save(snapshot, expectedRevision: revision); return verification
    }

    public func snapshot() throws -> JournalSnapshot { try storage.load() }
}
