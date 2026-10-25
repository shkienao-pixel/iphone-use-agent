import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor private final class RecoveryFixture {
    let original: PreparationFixture
    let now: Date
    var contact: ContactBinding?
    var moment: MomentBinding?
    var scope: DraftScope
    let fieldBindingID = UUID()
    init(_ original: PreparationFixture, offset: Double = 1) {
        self.original = original; now = original.f.now.addingTimeInterval(offset)
        let stream = UUID()
        if original.scope.purpose != .contactSearch {
            contact = .init(account: original.f.contact.account, name: original.f.contact.name,
                profile: .init(device: "fixture-phone", stream: stream, capturedAt: now.addingTimeInterval(-0.2),
                               confirmedAt: now.addingTimeInterval(-0.1), origin: .fixture))
        }
        if let old = original.f.moment, let contact {
            var candidate = old.candidate; candidate.localID = "fresh-post"
            moment = .init(contactProofID: contact.proofID, candidate: candidate)
        }
        scope = .init(taskID: original.task.id, purpose: original.scope.purpose, device: "fixture-phone", stream: stream,
                      account: contact?.account, contactProofID: contact?.proofID, momentBindingID: moment?.id)
    }
    func restore(_ store: any DraftCheckpointStorage, journal: (any JournalStorage)? = nil,
                 candidates: [MomentCandidate]? = nil, coverage: DraftRecoveryCoverage = .completeRequestedRange) throws -> DraftPreparation {
        try DraftPreparation.restore(task: original.task, scope: scope, mode: .offline, storage: store,
            contact: contact, moment: moment, candidates: candidates ?? moment.map { [$0.candidate] } ?? [],
            coverage: coverage, submissionJournal: journal, now: now)
    }
    func observation(_ text: String, ownership: FieldAccess? = nil, offset: Double = 0.2) -> DraftObservation {
        let frame = FrameStamp(device: scope.device, stream: scope.stream, capturedAt: now.addingTimeInterval(offset),
                               confirmedAt: now.addingTimeInterval(offset), origin: .fixture)
        let field = ObservedControl(id: "fresh-field", frameID: frame.id, role: .textField,
            rect: .init(x: 0.2, y: 0.4, width: 0.6, height: 0.08), source: .fixture)
        return .init(frame: frame, scope: scope, fieldBindingID: fieldBindingID, field: field, controls: [field],
            text: text, complete: true, ownership: ownership ?? (text.isEmpty ? .empty : .taskOwned), focused: true,
            fieldKind: DraftFieldKind(rawValue: scope.purpose.rawValue)!, selection: .caretAtEnd, composing: false)
    }
    func next(_ preparation: DraftPreparation, _ observation: DraftObservation, keyboard: Bool = true,
              clipboard: ClipboardLease? = nil) throws -> PreparationDecision {
        try preparation.next(observation, keyboardAvailable: keyboard, clipboard: clipboard,
                             now: observation.frame.confirmedAt.addingTimeInterval(0.01))
    }
}

@MainActor final class DraftCheckpointIdentityRegressionTests: XCTestCase {
    func testOldProfilePixelsCannotBecomeFreshProofByChangingMetadata() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store); let r = RecoveryFixture(p)
        var old = p.f.contact.profile
        old.stream = r.scope.stream; old.confirmedAt = r.now.addingTimeInterval(-0.1)
        r.contact?.profile = old
        expectError(.wrongContact) { _ = try r.restore(store) }
    }
    func testArchivedMomentBindingUUIDCannotStandInForFreshIdentification() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(purpose: .momentComment, storage: store)
        let r = RecoveryFixture(p); r.moment?.id = p.f.moment!.id; r.scope.momentBindingID = p.f.moment!.id
        expectError(.wrongMoment) { _ = try r.restore(store) }
    }
}

private enum DraftWriteFault: Error { case injected }
@MainActor private final class FaultingDraftStore: DraftCheckpointStorage {
    let backing = MemoryDraftCheckpoint()
    var writes = 0
    var failAt: Int?
    var persistThenThrow = false
    func load() throws -> DraftCheckpoint? { try backing.load() }
    func save(_ next: DraftCheckpoint, expectedRevision: Int?) throws {
        writes += 1
        if writes == failAt {
            if persistThenThrow { try backing.save(next, expectedRevision: expectedRevision) }
            throw DraftWriteFault.injected
        }
        try backing.save(next, expectedRevision: expectedRevision)
    }
}

@MainActor final class DraftCheckpointTests: XCTestCase {
    func testCheckpointPreservesRequestAndPartialReadbackBeforeRestart() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store)
        _ = try p.action(p.observation())
        _ = try p.next(p.observation("he", offset: 0.2)) // suffix proposed, never consumed
        let saved = try XCTUnwrap(store.load())
        XCTAssertTrue(exact(saved.task.originalRequest, p.task.originalRequest))
        XCTAssertEqual(saved.lastReadback?.text, "he"); XCTAssertNil(saved.pending)
        p.preparation.invalidate()
        let r = RecoveryFixture(p); let resumed = try r.restore(store); let current = r.observation("he")
        guard case .action(let ticket) = try r.next(resumed, current) else { return XCTFail() }
        guard case .inputASCII(let field, let suffix) = try resumed.take(ticket, current: current, keyboardAvailable: true,
            now: current.frame.confirmedAt.addingTimeInterval(0.02)) else { return XCTFail() }
        XCTAssertEqual(suffix, "llo"); XCTAssertEqual(field.id, "fresh-field")
        XCTAssertEqual(try store.load()?.bindings.count, 2)
    }
    func testUnknownInputIsNotReplayedWhenRestoredFieldIsStillEmpty() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store)
        _ = try p.action(p.observation()); p.preparation.invalidate()
        let r = RecoveryFixture(p); let resumed = try r.restore(store)
        XCTAssertEqual(try r.next(resumed, r.observation("")), .hold(.inputResultUncertain))
        XCTAssertEqual(try store.load()?.pending?.text, "hello")
    }
    func testInputCompletedWhileStoppedIsVerifiedByFreshReadback() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store)
        _ = try p.action(p.observation()); p.preparation.invalidate()
        let r = RecoveryFixture(p); let resumed = try r.restore(store); let current = r.observation("hello")
        XCTAssertEqual(try r.next(resumed, current), .verified(text: "hello", frameID: current.frame.id))
        XCTAssertNil(try store.load()?.pending)
    }
    func testPartialInputWhileStoppedGeneratesOnlyFreshSuffixAction() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store)
        _ = try p.action(p.observation())
        let r = RecoveryFixture(p); let resumed = try r.restore(store); let current = r.observation("he")
        guard case .action(let ticket) = try r.next(resumed, current) else { return XCTFail() }
        guard case .inputASCII(_, let suffix) = try resumed.take(ticket, current: current, keyboardAvailable: true,
            now: current.frame.confirmedAt.addingTimeInterval(0.02)) else { return XCTFail() }
        XCTAssertEqual(suffix, "llo"); XCTAssertEqual(try store.load()?.pending?.text, "llo")
    }
    func testOldProposedTicketCannotBeUsedInRestoredSession() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store)
        guard case .action(let old) = try p.next(p.observation()) else { return XCTFail() }
        let r = RecoveryFixture(p); let resumed = try r.restore(store)
        expectError(.invalidTransition) {
            _ = try resumed.take(old, current: r.observation(""), keyboardAvailable: true, now: r.now.addingTimeInterval(0.3))
        }
        XCTAssertNil(try store.load()?.pending)
    }
    func testRestorationDoesNotRecoverClipboardLeaseOrPasteWholeOriginal() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(text: "你好世界", storage: store)
        _ = try p.action(p.observation(paste: true), keyboard: false, clipboard: p.lease("你好世界"))
        let r = RecoveryFixture(p); let resumed = try r.restore(store)
        XCTAssertEqual(try r.next(resumed, r.observation("你好"), keyboard: false), .needsClipboardPreparation("世界"))
    }
    func testExternalDraftIsPreservedAfterRestart() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store)
        _ = try p.next(p.observation("he"))
        let r = RecoveryFixture(p); let resumed = try r.restore(store)
        XCTAssertEqual(try r.next(resumed, r.observation("其他草稿", ownership: .foreignDraft)), .hold(.foreignDraft))
    }
    func testSubmittingTaskRequiresActualSubmissionJournalOnRecovery() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(submit: true, storage: store)
        let r = RecoveryFixture(p); let resumed = try r.restore(store)
        XCTAssertEqual(try r.next(resumed, r.observation("")), .hold(.submissionStateUnknown))
    }
    func testPendingSubmittedMessageBlocksRefillingEmptyComposer() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(submit: true, storage: store)
        _ = try p.next(p.observation("hello")); _ = try p.f.dispatch(.message("hello"))
        let r = RecoveryFixture(p); let resumed = try r.restore(store, journal: p.f.store)
        XCTAssertEqual(try r.next(resumed, r.observation("")), .hold(.submissionNeedsReview))
        XCTAssertEqual(try p.f.store.load().records.count, 1)
    }
    func testVerifiedSubmittedMessageDoesNotRestartPreparation() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(submit: true, storage: store)
        let effect = Effect.message("hello"); let ticket = try p.f.dispatch(effect)
        _ = try p.f.coordinator.verify(operationID: ticket.operationID,
            after: p.f.after(effect, items: [.init(id: "new", text: "hello", author: .myself)]), now: p.f.now.addingTimeInterval(0.3))
        let r = RecoveryFixture(p); let resumed = try r.restore(store, journal: p.f.store)
        XCTAssertEqual(try r.next(resumed, r.observation("")), .hold(.effectAlreadyCompleted))
    }
    func testEmptySubmissionJournalAllowsNewPreparationUnderOriginalAuthorization() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(submit: true, storage: store)
        let r = RecoveryFixture(p); let resumed = try r.restore(store, journal: p.f.store)
        guard case .action = try r.next(resumed, r.observation("")) else { return XCTFail() }
    }
    func testChangedOriginalTaskCannotResumeExistingCheckpoint() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store); let r = RecoveryFixture(p)
        var changed = p.task; changed.originalRequest = "Changed user instruction"
        expectError(.invalidTask) {
            _ = try DraftPreparation.restore(task: changed, scope: r.scope, mode: .offline, storage: store, contact: r.contact, now: r.now)
        }
    }
    func testFreshProfileMustBeForOriginalAccount() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store); let r = RecoveryFixture(p)
        r.contact?.account = "Bob_ID"
        expectError(.wrongContact) { _ = try r.restore(store) }
    }
    func testArchivedProfileProofIDCannotBeReusedAsFreshBinding() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store); let r = RecoveryFixture(p)
        r.contact?.proofID = p.f.contact.proofID; r.scope.contactProofID = p.f.contact.proofID
        expectError(.wrongContact) { _ = try r.restore(store) }
    }
    func testCommentRecoveryRequiresFreshUniqueFullPostEvidence() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(text: "越做越好👏", purpose: .momentComment, storage: store)
        _ = try p.next(p.observation("越做"), keyboard: false)
        let r = RecoveryFixture(p); let resumed = try r.restore(store)
        XCTAssertEqual(try r.next(resumed, r.observation("越做"), keyboard: false), .needsClipboardPreparation("越好👏"))
    }
    func testPartialPostSearchCoverageCannotAuthorizeRestoredCommentEditing() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(purpose: .momentComment, storage: store)
        let r = RecoveryFixture(p)
        expectError(.incompleteTarget) { _ = try r.restore(store, coverage: .partial) }
        XCTAssertEqual(try store.load()?.bindings.count, 1)
    }
    func testTwoIdenticalPostCandidatesCannotBeReboundByPosition() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(purpose: .momentComment, storage: store)
        let r = RecoveryFixture(p); let candidate = try XCTUnwrap(r.moment?.candidate)
        var duplicate = candidate; duplicate.localID = "another-post"
        expectError(.wrongMoment) { _ = try r.restore(store, candidates: [candidate, duplicate]) }
    }
    func testSimilarExcerptButDifferentCompleteBodyDoesNotMatchArchivedPost() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(purpose: .momentComment, storage: store)
        let r = RecoveryFixture(p); r.moment?.candidate.body += " 新内容"
        expectError(.wrongMoment) { _ = try r.restore(store) }
    }
    func testReadbackBeforeFreshRebindingCannotBecomeCurrentEvidence() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store)
        let r = RecoveryFixture(p); let resumed = try r.restore(store)
        expectError(.staleObservation) { _ = try r.next(resumed, r.observation("hello", offset: -0.01)) }
    }
    func testIntentPersistenceFailureReturnsNoActionAndInvalidatesSession() async throws {
        for persisted in [false, true] {
            let store = FaultingDraftStore(); store.failAt = 3; store.persistThenThrow = persisted
            let p = try PreparationFixture(storage: store); let before = p.observation()
            guard case .action(let ticket) = try p.next(before) else { return XCTFail() }
            XCTAssertThrowsError(try p.preparation.take(ticket, current: before, keyboardAvailable: true, now: p.f.now.addingTimeInterval(0.02)))
            expectError(.invalidTransition) { _ = try p.next(p.observation(offset: 0.2)) }
            XCTAssertEqual(try store.load()?.pending != nil, persisted)
        }
    }
    func testPendingTextCannotBeRewrittenInArchive() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store); _ = try p.action(p.observation())
        var changed = try XCTUnwrap(store.load()); changed.pending?.text = "Different text"
        expectError(.inconsistentJournal) { try changed.validate() }
    }
    func testUnresolvedIntentCannotBeClearedBySavingUnchangedReadback() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store); _ = try p.action(p.observation())
        var changed = try XCTUnwrap(store.load()); let revision = changed.revision
        changed.pending = nil; changed.revision += 1
        expectError(.inconsistentJournal) { try store.save(changed, expectedRevision: revision) }
    }
    func testNewConstructorCannotSilentlyResetExistingDraftStore() async throws {
        let store = MemoryDraftCheckpoint(); _ = try PreparationFixture(storage: store)
        expectError(.invalidTransition) { _ = try PreparationFixture(storage: store) }
    }
    func testFileCheckpointRoundTripAndStaleWriterRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try FileDraftCheckpoint(directory: directory); let p = try PreparationFixture(storage: first)
        _ = try p.next(p.observation("he"))
        let second = try FileDraftCheckpoint(directory: directory)
        var recent = try XCTUnwrap(second.load()); var stale = recent
        let revision = recent.revision; recent.revision += 1; recent.updatedAt += 0.1
        try second.save(recent, expectedRevision: revision)
        stale.revision += 1
        expectError(.revisionConflict) { try first.save(stale, expectedRevision: revision) }
        XCTAssertEqual(try second.load()?.lastReadback?.text, "he")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("draft.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testCorruptCheckpointFileIsNeverOverwrittenByNewSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-draft-corrupt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileDraftCheckpoint(directory: directory); let file = directory.appendingPathComponent("draft.json")
        let bad = Data("{broken".utf8); try bad.write(to: file)
        XCTAssertThrowsError(try PreparationFixture(storage: store)); XCTAssertEqual(try Data(contentsOf: file), bad)
    }
    func testCancelledRestoreDoesNotAppendBindingOrChangeCheckpoint() async throws {
        let store = MemoryDraftCheckpoint(); let p = try PreparationFixture(storage: store); let r = RecoveryFixture(p)
        let before = try XCTUnwrap(store.load())
        let work = Task { @MainActor in
            await Task.yield()
            return try r.restore(store)
        }
        work.cancel()
        do { _ = try await work.value; XCTFail() } catch is CancellationError { }
        XCTAssertEqual(try store.load(), before)
    }
}
