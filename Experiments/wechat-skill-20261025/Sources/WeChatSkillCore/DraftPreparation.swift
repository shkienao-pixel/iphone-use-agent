import Foundation

public enum DraftPurpose: String, Codable, Sendable { case contactSearch, message, momentComment }

/// Created by the trusted host after identifying the page, account and post.
/// These semantic identifiers are not inferred or authenticated by this package.
public struct DraftScope: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var purpose: DraftPurpose
    public var device: String
    public var stream: UUID
    public var account: String?
    public var contactProofID: UUID?
    public var momentBindingID: UUID?
    public init(taskID: UUID, purpose: DraftPurpose, device: String, stream: UUID,
                account: String? = nil, contactProofID: UUID? = nil, momentBindingID: UUID? = nil) {
        self.taskID = taskID; self.purpose = purpose; self.device = device; self.stream = stream
        self.account = account; self.contactProofID = contactProofID; self.momentBindingID = momentBindingID
    }
    func text(for task: SkillTask) throws -> String {
        try task.validate()
        guard taskID == task.id, nonblank(device) else { throw SkillError.invalidTask }
        if purpose == .contactSearch {
            guard account == nil, contactProofID == nil, momentBindingID == nil else { throw SkillError.wrongContact }
            return task.contact.keyword
        }
        guard let account, nonblank(account), contactProofID != nil,
              task.contact.expectedAccount.map({ exact($0, account) }) ?? true else { throw SkillError.wrongContact }
        switch (purpose, task.goal) {
        case (.message, .message(let text, _)):
            guard momentBindingID == nil else { throw SkillError.wrongMoment }; return text
        case (.momentComment, .moment(_, _, let text?, _)):
            guard momentBindingID != nil else { throw SkillError.wrongMoment }; return text
        default: throw SkillError.invalidTask
        }
    }
}

public enum DraftSelection: String, Codable, Sendable { case caretAtEnd, allText, other, unknown }
public enum DraftFieldKind: String, Codable, Sendable { case contactSearch, message, momentComment, reply, unknown }
public struct DraftObservation: Codable, Equatable, Sendable {
    public var frame: FrameStamp
    public var scope: DraftScope
    /// Host-established correspondence for one composer across current frames.
    public var fieldBindingID: UUID
    public var field: ObservedControl
    public var controls: [ObservedControl]
    public var text: String?
    public var complete: Bool
    public var ownership: FieldAccess
    public var fieldKind: DraftFieldKind
    public var focused: Bool
    public var selection: DraftSelection
    public var composing: Bool?
    public var replyTarget: String?
    public var blockingOverlay: Bool
    public init(frame: FrameStamp, scope: DraftScope, fieldBindingID: UUID, field: ObservedControl,
                controls: [ObservedControl], text: String?, complete: Bool, ownership: FieldAccess,
                focused: Bool, fieldKind: DraftFieldKind = .unknown, selection: DraftSelection = .unknown, composing: Bool? = nil,
                replyTarget: String? = nil, blockingOverlay: Bool = false) {
        self.frame = frame; self.scope = scope; self.fieldBindingID = fieldBindingID; self.field = field
        self.controls = controls; self.text = text; self.complete = complete; self.ownership = ownership
        self.fieldKind = fieldKind
        self.focused = focused; self.selection = selection; self.composing = composing
        self.replyTarget = replyTarget; self.blockingOverlay = blockingOverlay
    }
}

public struct PreparationTicket: Equatable, Sendable {
    public let id: UUID
    fileprivate let nonce: UUID
}
public enum DraftHold: String, Codable, Sendable {
    case freshReadbackRequired, unreadableText, inputMethodComposing, inputResultUncertain
    case focusUnconfirmed, pasteMenuUnconfirmed, selectionUnconfirmed, foreignDraft
    case unknownOwnership, caretOrSelectionRequired, correctionRequired
    case submissionStateUnknown, submissionNeedsReview, effectAlreadyCompleted
}
public enum PreparationDecision: Equatable, Sendable {
    case action(PreparationTicket)
    case verified(text: String, frameID: UUID)
    /// Host prepares this exact suffix with existing foreground tools. This is
    /// neither a user permission request nor an actual clipboard write.
    case needsClipboardPreparation(String)
    case hold(DraftHold)
}

/// Only prepares a field. No submitting, I/O, or durable execution tickets.
@MainActor public final class DraftPreparation {
    private let task: SkillTask
    private let desired: String
    private let scope: DraftScope
    private let mode: EvaluationMode
    private let maxAge: TimeInterval
    private var fieldBindingID: UUID?
    private var latest: DraftObservation?
    private var issued: (ticket: PreparationTicket, action: AtomicAction, before: DraftObservation, clipboardText: String?)?
    private var pending: PreparationIntent?
    private var invalidated = false
    private var storage: (any DraftCheckpointStorage)?
    private var checkpoint: DraftCheckpoint?
    private var submissionJournal: (any JournalStorage)?
    private var recovering = false
    private var boundAt: Date?

    public init(task: SkillTask, scope: DraftScope, mode: EvaluationMode, maxObservationAge: TimeInterval = 5,
                checkpointStorage: (any DraftCheckpointStorage)? = nil, contact: ContactBinding? = nil,
                moment: MomentBinding? = nil, now: Date = Date()) throws {
        try Task.checkCancellation()
        guard maxObservationAge.isFinite, maxObservationAge > 0 else { throw SkillError.invalidTask }
        self.task = task; desired = try scope.text(for: task); self.scope = scope; self.mode = mode; maxAge = maxObservationAge
        if let checkpointStorage {
            guard try checkpointStorage.load() == nil else { throw SkillError.invalidTransition }
            let binding = try makeBinding(contact: contact, moment: moment, now: now)
            let initial = DraftCheckpoint(id: UUID(), task: task, origin: mode == .offline ? .fixture : .liveDevice,
                bindings: [binding], lastReadback: nil, pending: nil, updatedAt: now)
            try checkpointStorage.save(initial, expectedRevision: nil)
            storage = checkpointStorage; checkpoint = initial; boundAt = now
        }
    }

    /// Explicitly rebinds fresh host evidence; no archived tickets, coordinates,
    /// clipboard leases, focus, or selection state become execution rights.
    public static func restore(task: SkillTask, scope: DraftScope, mode: EvaluationMode,
                               storage: any DraftCheckpointStorage, contact: ContactBinding? = nil,
                               moment: MomentBinding? = nil, candidates: [MomentCandidate] = [],
                               coverage: DraftRecoveryCoverage = .unknown,
                               submissionJournal: (any JournalStorage)? = nil,
                               now: Date, maxObservationAge: TimeInterval = 5) throws -> DraftPreparation {
        try Task.checkCancellation()
        guard let saved = try storage.load(), let original = saved.bindings.first, let last = saved.bindings.last,
              try saved.task.canonicalData() == task.canonicalData(),
              saved.origin == (mode == .offline ? .fixture : .liveDevice),
              DraftStateRules.sameLogicalScope(original.scope, scope) else { throw SkillError.invalidTask }
        let session = try DraftPreparation(task: task, scope: scope, mode: mode, maxObservationAge: maxObservationAge)
        let binding = try session.makeBinding(contact: contact, moment: moment, now: now)
        guard now > last.boundAt else { throw SkillError.staleObservation }
        if scope.purpose != .contactSearch {
            guard let contact, contact.proofID != last.scope.contactProofID,
                  contact.profile.id != last.contact?.profile.id,
                  contact.profile.capturedAt > saved.updatedAt,
                  contact.profile.confirmedAt > saved.updatedAt else { throw SkillError.wrongContact }
        }
        if scope.purpose == .momentComment {
            guard let account = scope.account else { throw SkillError.wrongContact }
            guard moment?.id != last.scope.momentBindingID else { throw SkillError.wrongMoment }
            try MomentRebindingEvidence.verifyMoment(original: original.moment, fresh: moment, candidates: candidates,
                                           account: account, coverage: coverage)
        }
        session.storage = storage; session.checkpoint = saved; session.pending = saved.pending
        session.submissionJournal = submissionJournal; session.recovering = true; session.boundAt = now
        try session.persist(now: now) { $0.bindings.append(binding) }
        return session
    }

    private func makeBinding(contact: ContactBinding?, moment: MomentBinding?, now: Date) throws -> DraftBindingRecord {
        if scope.purpose != .contactSearch {
            guard let contact else { throw SkillError.wrongContact }
            try contact.validate(task: task, mode: mode, now: now, maxAge: maxAge)
        }
        let record = DraftBindingRecord(scope: scope, contact: contact, moment: moment, boundAt: now)
        try DraftStateRules.validateBinding(record, task: task, mode: mode); return record
    }

    private func persist(now: Date, _ change: (inout DraftCheckpoint) -> Void) throws {
        guard let storage, var next = checkpoint else { return }
        let revision = next.revision
        change(&next); next.updatedAt = now; next.revision += 1
        do { try storage.save(next, expectedRevision: revision); checkpoint = next }
        catch { invalidate(); throw error }
    }

    private func submissionHold() throws -> DraftHold? {
        guard recovering, scope.purpose != .contactSearch else { return nil }
        let submits: Bool
        switch task.goal {
        case .message(_, let submit), .moment(_, _, _, let submit): submits = submit
        case .findContact: submits = false
        }
        guard submits else { return nil }
        guard let submissionJournal else { return .submissionStateUnknown }
        let entries = try submissionJournal.load().records.filter { $0.task.id == task.id }
        guard try entries.allSatisfy({ try $0.task.canonicalData() == task.canonicalData() }) else { throw SkillError.invalidTask }
        let slot = scope.purpose == .message ? "message" : "comment"
        if let relevant = entries.first(where: { $0.effect.slot == slot }) {
            return [.verified, .alreadySatisfied].contains(relevant.status) ? .effectAlreadyCompleted : .submissionNeedsReview
        }
        if entries.contains(where: { [.pending, .uncertain, .failed].contains($0.status) }) { return .submissionNeedsReview }
        return nil
    }
    public func invalidate() { invalidated = true; issued = nil; pending = nil }
    private func requireRunning() throws {
        do { try Task.checkCancellation() }
        catch { invalidate(); throw error }
        guard !invalidated else { throw SkillError.invalidTransition }
    }
    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        try draftBytes(value)
    }
    private func validate(_ observation: DraftObservation, now: Date) throws {
        try DraftStateRules.validate(observation, scope: scope, mode: mode, now: now, maxAge: maxAge, fieldBindingID: fieldBindingID)
        guard boundAt.map({ observation.frame.capturedAt >= $0 }) ?? true else { throw SkillError.staleObservation }
    }
    private func capabilities(_ observation: DraftObservation, keyboard: Bool, clipboard: ClipboardLease?) -> InputCapabilities {
        .init(keyboard: keyboard, fieldAccess: observation.ownership, focused: observation.focused,
              clipboard: clipboard, focusedFieldID: observation.focused ? observation.field.id : nil)
    }
    private func issue(_ action: AtomicAction, observation: DraftObservation, keyboard: Bool,
                       clipboard: ClipboardLease?, now: Date) throws -> PreparationDecision {
        try AtomicActionRules.validateOrdinary(action, frame: observation.frame, controls: observation.controls,
            capabilities: capabilities(observation, keyboard: keyboard, clipboard: clipboard), mode: mode, now: now, maxAge: maxAge)
        let ticket = PreparationTicket(id: UUID(), nonce: UUID())
        let usesClipboard: Bool
        switch action {
        case .tap(let control): usesClipboard = control.role == .paste
        case .editingKey(_, .paste): usesClipboard = true
        default: usesClipboard = false
        }
        issued = (ticket, action, observation, usesClipboard ? clipboard?.text : nil); return .action(ticket)
    }

    public func next(_ observation: DraftObservation, keyboardAvailable: Bool, clipboard: ClipboardLease? = nil,
                     now: Date) throws -> PreparationDecision {
        try requireRunning(); try validate(observation, now: now)
        if let hold = try submissionHold() { issued = nil; return .hold(hold) }
        if let issued, try bytes(issued.before) == bytes(observation) { return .action(issued.ticket) }
        if let latest {
            guard observation.frame.id != latest.frame.id, observation.frame.confirmedAt > latest.frame.confirmedAt,
                  observation.frame.capturedAt >= latest.frame.capturedAt else { throw SkillError.staleObservation }
        }
        issued = nil; latest = observation; fieldBindingID = observation.fieldBindingID
        try persist(now: now) { $0.lastReadback = observation }
        if let pending, observation.frame.capturedAt <= pending.releasedAt { return .hold(.freshReadbackRequired) }
        guard observation.complete, let text = observation.text else { return .hold(.unreadableText) }
        guard observation.composing == false else { return .hold(.inputMethodComposing) }
        if exact(text, desired) {
            if pending != nil { try persist(now: now) { $0.pending = nil } }
            pending = nil; return .verified(text: text, frameID: observation.frame.id)
        }
        if observation.ownership == .foreignDraft { return .hold(.foreignDraft) }
        if observation.ownership == .unknown { return .hold(.unknownOwnership) }
        if let pending {
            switch pending.kind {
            case .focus:
                guard observation.focused else { return .hold(.focusUnconfirmed) }
            case .openPasteMenu:
                guard observation.controls.contains(where: {
                    $0.role == .paste && $0.ownerFieldID == observation.field.id
                }) else { return .hold(.pasteMenuUnconfirmed) }
            case .selectAll:
                guard observation.selection == .allText else { return .hold(.selectionUnconfirmed) }
            default:
                guard pending.before.text.map({ !exact($0, text) }) == true else { return .hold(.inputResultUncertain) }
            }
            try persist(now: now) { $0.pending = nil }
            self.pending = nil
        }
        if !observation.focused {
            return try issue(.tap(observation.field), observation: observation, keyboard: keyboardAvailable, clipboard: clipboard, now: now)
        }
        let isPrefix = desired.utf8.starts(with: text.utf8)
        let replacing = observation.selection == .allText
        if !text.isEmpty && !replacing && (!isPrefix || observation.selection != .caretAtEnd) {
            guard keyboardAvailable else { return .hold(isPrefix ? .caretOrSelectionRequired : .correctionRequired) }
            return try issue(.editingKey(observation.field, key: .selectAll), observation: observation,
                             keyboard: true, clipboard: clipboard, now: now)
        }
        let payload = replacing ? desired : String(decoding: desired.utf8.dropFirst(text.utf8.count), as: UTF8.self)
        if keyboardAvailable && payload.utf8.allSatisfy({ (32...126).contains($0) }) {
            return try issue(.inputASCII(observation.field, text: String(payload.prefix(500))), observation: observation,
                             keyboard: true, clipboard: clipboard, now: now)
        }
        guard let clipboard, clipboard.usable(at: now), exact(clipboard.text, payload) else {
            return .needsClipboardPreparation(payload)
        }
        if keyboardAvailable {
            return try issue(.editingKey(observation.field, key: .paste), observation: observation,
                             keyboard: true, clipboard: clipboard, now: now)
        }
        if let paste = observation.controls.first(where: { $0.role == .paste && $0.ownerFieldID == observation.field.id }) {
            return try issue(.tap(paste), observation: observation, keyboard: false, clipboard: clipboard, now: now)
        }
        return try issue(.longPress(observation.field), observation: observation, keyboard: false, clipboard: clipboard, now: now)
    }

    /// The returned primitive is uncertain until a separate fresh readback.
    public func take(_ ticket: PreparationTicket, current: DraftObservation, keyboardAvailable: Bool,
                     clipboard: ClipboardLease? = nil, now: Date) throws -> AtomicAction {
        try requireRunning()
        let proposal = issued; issued = nil
        guard let proposal, proposal.ticket == ticket else { throw SkillError.invalidTransition }
        guard try submissionHold() == nil else { throw SkillError.unapprovedEffect }
        try validate(current, now: now)
        guard try bytes(current) == bytes(proposal.before) else { throw SkillError.invalidTransition }
        if let expected = proposal.clipboardText {
            guard clipboard.map({ exact($0.text, expected) && $0.usable(at: now) }) == true else { throw SkillError.unavailableInput }
        }
        try AtomicActionRules.validateOrdinary(proposal.action, frame: current.frame, controls: current.controls,
            capabilities: capabilities(current, keyboard: keyboardAvailable, clipboard: clipboard), mode: mode, now: now, maxAge: maxAge)
        let kind: PreparationIntentKind
        let payload: String?
        switch proposal.action {
        case .tap(let control) where control.role == .textField: kind = .focus; payload = nil
        case .longPress: kind = .openPasteMenu; payload = nil
        case .editingKey(_, .selectAll): kind = .selectAll; payload = nil
        case .inputASCII(_, let text): kind = .typeASCII; payload = text
        case .editingKey(_, .paste): kind = .paste; payload = proposal.clipboardText
        case .tap(let control) where control.role == .paste: kind = .paste; payload = proposal.clipboardText
        default: throw SkillError.invalidAction
        }
        let intent = PreparationIntent(kind: kind, before: current, text: payload, releasedAt: now)
        try persist(now: now) { $0.pending = intent }
        pending = intent
        return proposal.action
    }
}
