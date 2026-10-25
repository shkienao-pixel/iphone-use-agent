import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class ResultRecoveryFixture {
    let f: Fixture
    let effect: Effect
    let operationID: UUID
    var contact: ContactBinding
    var moment: MomentBinding?
    let before: SceneObservation
    init(effect: Effect = .message("hello"), baseline: [VisibleItem] = [], landmarks: Bool = true) throws {
        self.effect = effect
        let goal: TaskGoal
        switch effect {
        case .message(let text): goal = .message(text: text, submit: true)
        case .like: goal = .moment(clues: .init(bodyExcerpt: "正式介绍"), like: true, comment: nil, submit: true)
        case .comment(let text): goal = .moment(clues: .init(bodyExcerpt: "正式介绍"), like: false, comment: text, submit: true)
        }
        f = try Fixture(goal: goal)
        var initial = f.scene(effect: effect, items: baseline, empty: baseline.isEmpty, anchors: ["old-local-anchor"])
        if effect.slot == "message", landmarks {
            initial.landmarks = [.init(kind: baseline.isEmpty ? .conversationStart : .timestamp,
                text: baseline.isEmpty ? "fixture conversation start" : "29 Sep 10:00", frameID: initial.frame.id,
                source: .fixture, followingItemID: baseline.first?.id)]
        }
        before = initial; operationID = try f.dispatch(effect, before: initial).operationID
        let stream = UUID()
        contact = .init(account: f.contact.account, name: f.contact.name,
            profile: .init(device: "fixture-phone", stream: stream, capturedAt: f.now.addingTimeInterval(0.8),
                confirmedAt: f.now.addingTimeInterval(0.9), origin: .fixture))
        if var candidate = f.moment?.candidate {
            candidate.localID = "new-local-post"
            moment = .init(contactProofID: contact.proofID, candidate: candidate)
        }
    }
    func reader(store: (any JournalStorage)? = nil, candidates: [MomentCandidate]? = nil,
                coverage: ObservedRangeCoverage = .completeRequestedRange, bound: Double = 1) throws -> RecoveredResultReader {
        try RecoveredResultReader(storage: store ?? f.store, operationID: operationID, task: f.task,
            contact: contact, moment: moment, candidates: candidates ?? moment.map { [$0.candidate] } ?? [],
            coverage: coverage, mode: .offline, now: f.now.addingTimeInterval(bound))
    }
    func after(_ items: [VisibleItem] = [], offset: Double = 1.2, liked: LikeState = .unknown,
               timestamp: String = "29 Sep 10:00") -> SceneObservation {
        let frame = FrameStamp(device: "fixture-phone", stream: contact.profile.stream,
            capturedAt: f.now.addingTimeInterval(offset), confirmedAt: f.now.addingTimeInterval(offset), origin: .fixture)
        var after = SceneObservation(frame: frame, account: contact.account, contactProofID: contact.proofID,
            momentBindingID: moment?.id, surface: effect.slot == "message" ? .chat : .momentDetail,
            items: items, continuityAnchors: ["unrelated-new-local-anchor"], listVerifiedEmpty: items.isEmpty,
            correspondenceUnambiguous: true, like: liked)
        if effect.slot == "message" {
            after.landmarks = [.init(kind: before.items.isEmpty ? .conversationStart : .timestamp,
                text: before.items.isEmpty ? "fixture conversation start" : timestamp,
                frameID: frame.id, source: .fixture, followingItemID: items.first?.id)]
        }
        return after
    }
    func observe(_ reader: RecoveredResultReader, _ after: SceneObservation) throws -> Verification {
        try reader.observe(after, now: after.frame.confirmedAt.addingTimeInterval(0.1))
    }
    func selfItem(_ id: String = "fresh-result", state: ItemState = .normal) -> VisibleItem {
        .init(id: id, text: effect.text ?? "", author: .myself, state: state)
    }
}

@MainActor private final class FailingReviewStore: JournalStorage {
    let backing: MemoryJournal
    let persist: Bool
    init(_ backing: MemoryJournal, persist: Bool) { self.backing = backing; self.persist = persist }
    func load() throws -> JournalSnapshot { try backing.load() }
    func save(_ next: JournalSnapshot, expectedRevision: Int) throws {
        if persist { try backing.save(next, expectedRevision: expectedRevision) }
        throw SkillError.storageBusy
    }
}

@MainActor final class ResultRecoveryTests: XCTestCase {
    func testFreshEmptyHistoryResultIsVerifiedWithoutRewritingOriginalEvidence() async throws {
        let p = try ResultRecoveryFixture(); let reader = try p.reader()
        XCTAssertEqual(try p.observe(reader, p.after([p.selfItem()])), .verified)
        let record = try p.f.store.load().records[0]
        XCTAssertNil(record.result); XCTAssertEqual(record.before, p.before)
        XCTAssertEqual(record.recoveryReviews?.count, 1)
        XCTAssertNotEqual(record.recoveryReviews?.first?.after.contactProofID, record.before.contactProofID)
    }
    func testOrderedHistorySurvivesChangedLocalItemIDs() async throws {
        let old = VisibleItem(id: "old-1", text: "earlier", author: .other)
        let p = try ResultRecoveryFixture(baseline: [old]); let reader = try p.reader()
        let current = VisibleItem(id: "new-id-1", text: old.text, author: .other)
        XCTAssertEqual(try p.observe(reader, p.after([current, p.selfItem()])), .verified)
    }
    func testTimestampNeighborsDisambiguateRepeatedSameText() async throws {
        let old = VisibleItem(id: "old-same", text: "hello", author: .myself)
        let p = try ResultRecoveryFixture(baseline: [old]); let reader = try p.reader()
        var after = p.after([.init(id: "old-now-different-id", text: "hello", author: .myself), p.selfItem()])
        after.landmarks?.append(.init(kind: .timestamp, text: "29 Sep 10:01", frameID: after.frame.id,
                                      source: .fixture, followingItemID: "fresh-result"))
        XCTAssertEqual(try p.observe(reader, after), .verified)
    }
    func testOldSameTextStillCannotCountAsNewSend() async throws {
        let old = VisibleItem(id: "old", text: "hello", author: .myself)
        let p = try ResultRecoveryFixture(baseline: [old]); let reader = try p.reader()
        XCTAssertEqual(try p.observe(reader, p.after([.init(id: "new-local-id", text: "hello", author: .myself)])),
                       .uncertain("recovered_unique_new_self_item_missing"))
    }
    func testLegacyLocalAnchorIDsAloneDoNotEstablishRecoveryContinuity() async throws {
        let p = try ResultRecoveryFixture(landmarks: false); let reader = try p.reader()
        var after = p.after([p.selfItem()]); after.continuityAnchors = p.before.continuityAnchors
        XCTAssertEqual(try p.observe(reader, after), .uncertain("baseline_landmarks_missing"))
    }
    func testRepeatedHistoryWithTwoValidMappingsRemainsUnknown() async throws {
        let old = VisibleItem(id: "old", text: "earlier", author: .other)
        let p = try ResultRecoveryFixture(baseline: [old]); let reader = try p.reader()
        var after = p.after([.init(id: "a", text: "earlier", author: .other),
                             .init(id: "b", text: "earlier", author: .other), p.selfItem()])
        after.landmarks?.append(.init(kind: .timestamp, text: "29 Sep 10:00", frameID: after.frame.id, source: .fixture, followingItemID: "b"))
        XCTAssertEqual(try p.observe(reader, after), .uncertain("recovered_history_alignment_ambiguous"))
    }
    func testWrongTimestampCannotReuseMatchingMessageText() async throws {
        let p = try ResultRecoveryFixture(baseline: [.init(id: "old", text: "earlier", author: .other)])
        XCTAssertEqual(try p.observe(p.reader(), p.after([.init(id: "fresh-old", text: "earlier", author: .other), p.selfItem()], timestamp: "different day")),
                       .uncertain("recovered_history_not_retained"))
    }
    func testOtherPersonSameTextAndFailureStateAreSeparated() async throws {
        let other = try ResultRecoveryFixture()
        XCTAssertEqual(try other.observe(other.reader(), other.after([.init(id: "new", text: "hello", author: .other)])),
                       .uncertain("recovered_unique_new_self_item_missing"))
        let failed = try ResultRecoveryFixture()
        XCTAssertEqual(try failed.observe(failed.reader(), failed.after([failed.selfItem(state: .failed)])), .failed)
    }
    func testLaterReadCanResolvePendingWithoutNewProfileOrSubmission() async throws {
        let p = try ResultRecoveryFixture(); let reader = try p.reader()
        XCTAssertEqual(try p.observe(reader, p.after([p.selfItem(state: .pending)])), .uncertain("recovered_new_item_pending"))
        XCTAssertEqual(try p.observe(reader, p.after([p.selfItem()], offset: 2.2)), .verified)
        let record = try p.f.store.load().records[0]
        XCTAssertEqual(record.recoveryReviews?.count, 2); XCTAssertEqual(record.dispatchedAt, p.f.now.addingTimeInterval(0.01))
    }
    func testReplayedRecoveryFrameCannotOverwriteNewerResult() async throws {
        let p = try ResultRecoveryFixture(); let reader = try p.reader(); let pending = p.after([p.selfItem(state: .pending)])
        _ = try p.observe(reader, pending)
        let revision = try p.f.store.load().revision
        expectError(.staleObservation) { _ = try p.observe(reader, pending) }
        XCTAssertEqual(try p.f.store.load().revision, revision)
    }
    func testLikeAndTopLevelCommentResolveIndependently() async throws {
        let like = try ResultRecoveryFixture(effect: .like)
        XCTAssertEqual(try like.observe(like.reader(), like.after(liked: .likedBySelf)), .verified)
        let comment = try ResultRecoveryFixture(effect: .comment("越做越好👏"))
        XCTAssertEqual(try comment.observe(comment.reader(), comment.after([comment.selfItem()])), .verified)
        XCTAssertEqual(try comment.f.store.load().records.map(\.effect), [.comment("越做越好👏")])
    }
    func testUnknownLikeStateDoesNotToggleOrClaimSuccess() async throws {
        let p = try ResultRecoveryFixture(effect: .like); let reader = try p.reader()
        XCTAssertEqual(try p.observe(reader, p.after()), .uncertain("recovered_like_state_not_confirmed"))
        XCTAssertEqual(try p.f.store.load().records.count, 1)
    }
    func testPostCoverageAndDuplicateCandidatesPreventRecovery() async throws {
        let p = try ResultRecoveryFixture(effect: .comment("hello"))
        expectError(.incompleteTarget) { _ = try p.reader(coverage: .partial) }
        let first = try XCTUnwrap(p.moment?.candidate); var duplicate = first; duplicate.localID = "other-post"
        expectError(.wrongMoment) { _ = try p.reader(candidates: [first, duplicate]) }
    }
    func testChangedCompletePostCannotMatchByExcerpt() async throws {
        let p = try ResultRecoveryFixture(effect: .comment("hello")); p.moment?.candidate.body += " different post"
        expectError(.wrongMoment) { _ = try p.reader() }
    }
    func testOldIdentityEvidenceAndWrongAccountAreRejected() async throws {
        let old = try ResultRecoveryFixture(); old.contact = old.f.contact
        expectError(.wrongContact) { _ = try old.reader() }
        let wrong = try ResultRecoveryFixture(); wrong.contact.account = "Bob_ID"
        expectError(.wrongContact) { _ = try wrong.reader() }
    }
    func testModelAuthoredLandmarkCannotEstablishHistory() async throws {
        let p = try ResultRecoveryFixture(); let reader = try p.reader(); var after = p.after([p.selfItem()])
        after.landmarks?[0].source = .modelGuess
        expectError(.invalidObservation) { _ = try p.observe(reader, after) }
        XCTAssertNil(try p.f.store.load().records[0].recoveryReviews)
    }
    func testAnotherReaderRequiresNewProofAndInvalidatesOldReviewTimeline() async throws {
        let p = try ResultRecoveryFixture(); let first = try p.reader()
        _ = try p.observe(first, p.after([p.selfItem(state: .pending)]))
        let newStream = UUID()
        p.contact = .init(account: "Alice_ID", name: "Alice", profile:
            .init(device: "fixture-phone", stream: newStream, capturedAt: p.f.now.addingTimeInterval(1.8),
                  confirmedAt: p.f.now.addingTimeInterval(1.9), origin: .fixture))
        let second = try p.reader(bound: 2)
        XCTAssertEqual(try p.observe(second, p.after([p.selfItem(state: .pending)], offset: 2.2)), .uncertain("recovered_new_item_pending"))
        expectError { _ = try p.observe(first, p.after([p.selfItem()], offset: 3.2)) }
    }
    func testTerminalRecoveredStateCannotBeResetOrReviewedAgain() async throws {
        let p = try ResultRecoveryFixture(); let reader = try p.reader(); _ = try p.observe(reader, p.after([p.selfItem()]))
        expectError(.invalidTransition) { _ = try p.observe(reader, p.after([p.selfItem()], offset: 2.2)) }
        var changed = try p.f.store.load(); let revision = changed.revision
        changed.records[0].recoveryReviews = nil; changed.records[0].status = .pending; changed.revision += 1
        expectError(.inconsistentJournal) { try p.f.store.save(changed, expectedRevision: revision) }
    }
    func testRecoveredArchiveRechecksEvidenceInsteadOfTrustingStatus() async throws {
        let p = try ResultRecoveryFixture(); _ = try p.observe(p.reader(), p.after([p.selfItem()]))
        var changed = try p.f.store.load(); changed.records[0].recoveryReviews?[0].after.items[0].author = .other
        expectError(.inconsistentJournal) { try changed.validate() }
    }
    func testRecoveryNeverRecreatesDispatchTicketOrAllowsDuplicateReservation() async throws {
        let p = try ResultRecoveryFixture(); _ = try p.observe(p.reader(), p.after([p.selfItem()]))
        let coordinator = try SubmissionCoordinator(storage: p.f.store, mode: .offline)
        try coordinator.bindContact(p.contact, task: p.f.task, now: p.f.now.addingTimeInterval(1))
        var scene = p.after(); scene.controls = [p.f.control(.textField, stamp: scene.frame, id: "field"), p.f.control(.sendMessage, stamp: scene.frame, id: "submit")]
        scene.draft = .init(fieldID: "field", text: "hello", kind: .message)
        expectError(.duplicateOperation) {
            _ = try coordinator.reserve(task: p.f.task, effect: p.effect, observation: scene, controlID: "submit", now: p.f.now.addingTimeInterval(1.3))
        }
    }
    func testUnreleasedReservationCannotBeInventedAsSubmittedEffect() async throws {
        let f = try Fixture(); _ = try f.reserve(.message(f.message))
        var contact = f.contact; contact.proofID = UUID(); contact.profile = f.stamp(0.8)
        expectError(.invalidTransition) {
            _ = try RecoveredResultReader(storage: f.store, operationID: try f.store.load().records[0].id,
                task: f.task, contact: contact, mode: .offline, now: f.now.addingTimeInterval(1))
        }
    }
    func testWriteFailureInvalidatesReaderWithoutRetryingInput() async throws {
        for persists in [false, true] {
            let p = try ResultRecoveryFixture(); let store = FailingReviewStore(p.f.store, persist: persists)
            let reader = try p.reader(store: store)
            expectError(.storageBusy) { _ = try p.observe(reader, p.after([p.selfItem()])) }
            expectError(.invalidTransition) { _ = try p.observe(reader, p.after([p.selfItem()], offset: 2.2)) }
            XCTAssertEqual(try p.f.store.load().records[0].status, persists ? .verified : .pending)
        }
    }
    func testCancellationDoesNotAppendReviewAndStopsReader() async throws {
        let p = try ResultRecoveryFixture(); let reader = try p.reader()
        let work = Task { @MainActor in await Task.yield(); return try p.observe(reader, p.after([p.selfItem()])) }
        work.cancel()
        do { _ = try await work.value; XCTFail() } catch is CancellationError { }
        XCTAssertNil(try p.f.store.load().records[0].recoveryReviews)
        expectError(.invalidTransition) { _ = try p.observe(reader, p.after([p.selfItem()])) }
    }
    func testRecoveredSubmissionClosesDraftRecoveryWithoutRefilling() async throws {
        let drafts = MemoryDraftCheckpoint(); let p = try PreparationFixture(submit: true, storage: drafts)
        _ = try p.next(p.observation("hello"))
        var before = p.f.scene(effect: .message("hello"))
        before.landmarks = [.init(kind: .conversationStart, text: "fixture start", frameID: before.frame.id, source: .fixture)]
        let id = try p.f.dispatch(.message("hello"), before: before).operationID
        let stream = UUID()
        let contact = ContactBinding(account: "Alice_ID", name: "Alice", profile:
            .init(device: "fixture-phone", stream: stream, capturedAt: p.f.now.addingTimeInterval(0.8),
                  confirmedAt: p.f.now.addingTimeInterval(0.9), origin: .fixture))
        let scope = DraftScope(taskID: p.task.id, purpose: .message, device: "fixture-phone", stream: stream,
                               account: contact.account, contactProofID: contact.proofID)
        let resumed = try DraftPreparation.restore(task: p.task, scope: scope, mode: .offline, storage: drafts,
            contact: contact, submissionJournal: p.f.store, now: p.f.now.addingTimeInterval(1))
        func draft(_ offset: Double) -> DraftObservation {
            let frame = FrameStamp(device: scope.device, stream: stream, capturedAt: p.f.now.addingTimeInterval(offset),
                                   confirmedAt: p.f.now.addingTimeInterval(offset), origin: .fixture)
            let field = p.f.control(.textField, stamp: frame, id: "fresh-field")
            return .init(frame: frame, scope: scope, fieldBindingID: UUID(), field: field, controls: [field], text: "",
                complete: true, ownership: .empty, focused: true, fieldKind: .message, selection: .caretAtEnd, composing: false)
        }
        XCTAssertEqual(try resumed.next(draft(1.2), keyboardAvailable: true, now: p.f.now.addingTimeInterval(1.3)), .hold(.submissionNeedsReview))
        let reader = try RecoveredResultReader(storage: p.f.store, operationID: id, task: p.task, contact: contact,
                                               mode: .offline, now: p.f.now.addingTimeInterval(1))
        let frame = FrameStamp(device: scope.device, stream: stream, capturedAt: p.f.now.addingTimeInterval(1.4),
                               confirmedAt: p.f.now.addingTimeInterval(1.4), origin: .fixture)
        let after = SceneObservation(frame: frame, account: contact.account, contactProofID: contact.proofID, surface: .chat,
            items: [.init(id: "fresh-result", text: "hello", author: .myself)], correspondenceUnambiguous: true,
            landmarks: [.init(kind: .conversationStart, text: "fixture start", frameID: frame.id, source: .fixture, followingItemID: "fresh-result")])
        XCTAssertEqual(try reader.observe(after, now: p.f.now.addingTimeInterval(1.5)), .verified)
        XCTAssertEqual(try resumed.next(draft(1.6), keyboardAvailable: true, now: p.f.now.addingTimeInterval(1.7)), .hold(.effectAlreadyCompleted))
        XCTAssertEqual(try p.f.store.load().records.count, 1)
    }
}
