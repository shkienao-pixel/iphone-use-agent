import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class SubmissionTests: XCTestCase {
    func testDispatchReturnsOnlyOneTapAndPersistsFirst() async throws {
        let f = try Fixture(); let before = f.scene(); let ticket = try f.reserve(.message(f.message), before: before)
        XCTAssertEqual(try f.store.load().records[0].status, .pending)
        XCTAssertNil(try f.store.load().records[0].dispatchedAt)
        let action = try f.coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.01))
        guard case .tap(let control) = action else { return XCTFail("A submission must be exactly one tap") }
        XCTAssertEqual(control.role, .sendMessage)
        XCTAssertNotNil(try f.store.load().records[0].dispatchedAt)
    }
    func testTicketCannotBeConsumedTwice() async throws {
        let f = try Fixture(); let before = f.scene(); let ticket = try f.dispatch(.message(f.message), before: before)
        expectError(.invalidTransition) { _ = try f.coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.02)) }
    }
    func testNewOperationIDCannotBypassExistingTaskEffect() async throws {
        let f = try Fixture(); _ = try f.reserve(.message(f.message))
        expectError(.duplicateOperation) { _ = try f.reserve(.message(f.message)) }
    }
    func testDraftOnlyCannotSubmit() async throws {
        let f = try Fixture(goal: .message(text: "hello", submit: false))
        expectError(.unapprovedEffect) { _ = try f.reserve(.message("hello")) }
        XCTAssertTrue(try f.store.load().records.isEmpty)
    }
    func testCannotChangeAuthorizedText() async throws {
        let f = try Fixture()
        expectError(.unapprovedEffect) { _ = try f.reserve(.message("rephrased")) }
    }
    func testNormalizedUnicodeDraftIsNotExactOriginal() async throws {
        let f = try Fixture(goal: .message(text: "é", submit: true)); var before = f.scene(effect: .message("é"))
        before.draft?.text = "e\u{301}"
        expectError(.wrongDraft) { _ = try f.reserve(.message("é"), before: before) }
    }
    func testChangedDraftAfterReservationCannotUseTicket() async throws {
        let f = try Fixture(goal: .message(text: "é", submit: true)); let before = f.scene(effect: .message("é"))
        let ticket = try f.reserve(.message("é"), before: before); var changed = before
        changed.draft?.text = "e\u{301}"
        expectError(.invalidTransition) { _ = try f.coordinator.take(ticket, current: changed, now: f.now.addingTimeInterval(0.01)) }
        expectError(.invalidTransition) { _ = try f.coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.02)) }
    }
    func testWrongRecipientCannotReserve() async throws {
        let f = try Fixture(); var before = f.scene(); before.account = "Bob_ID"
        expectError(.wrongContact) { _ = try f.reserve(.message(f.message), before: before) }
    }
    func testAnotherTaskCannotReuseContactBinding() async throws {
        let f = try Fixture(); var other = f.task; other.id = UUID(); other.contact = .init(keyword: "Bob")
        expectError(.wrongContact) { _ = try f.coordinator.reserve(task: other, effect: .message(f.message), observation: f.scene(), controlID: "submit", now: f.now) }
    }
    func testChangedStreamCannotDispatch() async throws {
        let f = try Fixture(); var before = f.scene(); before.frame.stream = UUID()
        expectError(.wrongContact) { _ = try f.reserve(.message(f.message), before: before) }
    }
    func testBlockedFrameCannotDispatch() async throws {
        let f = try Fixture(); var before = f.scene(); before.blockingOverlay = true
        expectError(.invalidObservation) { _ = try f.reserve(.message(f.message), before: before) }
    }
    func testModelAuthoredControlCannotDispatch() async throws {
        let f = try Fixture(); var before = f.scene(); before.controls[1].source = .modelGuess
        expectError(.invalidObservation) { _ = try f.reserve(.message(f.message), before: before) }
    }
    func testCorrectNewSelfMessageVerifies() async throws {
        let f = try Fixture(); let ticket = try f.dispatch(.message(f.message))
        let after = f.after(.message(f.message), items: [.init(id: "new", text: f.message, author: .myself)])
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .verified)
    }
    func testEmptyComposerWithoutNewBubbleRemainsUncertain() async throws {
        let f = try Fixture(); let ticket = try f.dispatch(.message(f.message))
        let after = f.after(.message(f.message), items: [], empty: true)
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .uncertain("unique_new_self_item_missing"))
        expectError(.duplicateOperation) { _ = try f.reserve(.message(f.message)) }
    }
    func testOldSameTextBubbleIsNotNewSubmission() async throws {
        let f = try Fixture(); let old = VisibleItem(id: "old", text: f.message, author: .myself)
        let before = f.scene(items: [old], empty: false, anchors: ["old-anchor"])
        let ticket = try f.dispatch(.message(f.message), before: before)
        let after = f.after(.message(f.message), items: [old], anchors: ["old-anchor"])
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .uncertain("unique_new_self_item_missing"))
    }
    func testOtherPersonsSameTextIsNotSelfSubmission() async throws {
        let f = try Fixture(); let ticket = try f.dispatch(.message(f.message))
        let after = f.after(.message(f.message), items: [.init(id: "new", text: f.message, author: .other)])
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .uncertain("unique_new_self_item_missing"))
    }
    func testTwoNewSameTextBubblesAreAmbiguous() async throws {
        let f = try Fixture(); let ticket = try f.dispatch(.message(f.message))
        let after = f.after(.message(f.message), items: ["a","b"].map { .init(id: $0, text: f.message, author: .myself) })
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .uncertain("unique_new_self_item_missing"))
    }
    func testScrollingAwayCannotCreateNewnessEvidence() async throws {
        let f = try Fixture(); let old = VisibleItem(id: "old", text: "old text", author: .other)
        let before = f.scene(items: [old], empty: false, anchors: ["old-anchor"])
        let ticket = try f.dispatch(.message(f.message), before: before)
        let after = f.after(.message(f.message), items: [.init(id: "new", text: f.message, author: .myself)])
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .uncertain("viewport_continuity_missing"))
    }
    func testUncertainResultCanBeVerifiedByLaterReadWithoutResend() async throws {
        let f = try Fixture(); let ticket = try f.dispatch(.message(f.message))
        _ = try f.coordinator.verify(operationID: ticket.operationID, after: f.after(.message(f.message), items: [], empty: true), now: f.now.addingTimeInterval(0.3))
        var after = f.after(.message(f.message), items: [.init(id: "new", text: f.message, author: .myself)])
        after.frame = f.stamp(0.4); after.controls = []
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.5)), .verified)
        XCTAssertEqual(try f.store.load().records.count, 1)
    }
    func testPendingAndFailureIndicatorsDoNotBecomeSuccess() async throws {
        for state in [ItemState.pending, .failed] {
            let f = try Fixture(); let ticket = try f.dispatch(.message(f.message))
            let after = f.after(.message(f.message), items: [.init(id: "new", text: f.message, author: .myself, state: state)])
            let expected: Verification = state == .failed ? .failed : .uncertain("new_item_pending")
            XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), expected)
        }
    }
    func testSystemReconfirmationCannotMakeOldPixelsPostSubmitEvidence() async throws {
        let f = try Fixture(); let ticket = try f.dispatch(.message(f.message)); var after = f.after(.message(f.message), items: [.init(id: "new", text: f.message, author: .myself)])
        after.frame.capturedAt = f.now.addingTimeInterval(-0.1)
        expectError(.staleObservation) { _ = try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)) }
    }
    func testProcessRestartCannotRecreatePendingTicket() async throws {
        let f = try Fixture(); let before = f.scene(); let ticket = try f.reserve(.message(f.message), before: before)
        let restarted = try SubmissionCoordinator(storage: f.store, mode: .offline)
        try restarted.bindContact(f.contact, task: f.task, now: f.now)
        expectError(.invalidTransition) { _ = try restarted.take(ticket, current: before, now: f.now.addingTimeInterval(0.01)) }
        expectError(.duplicateOperation) { _ = try restarted.reserve(task: f.task, effect: .message(f.message), observation: before, controlID: "submit", now: f.now) }
    }
    func testReferenceScreenshotCannotBecomeLiveBinding() async throws {
        let f = try Fixture(mode: .live); var contact = f.contact; contact.profile.origin = .referenceImage
        expectError(.wrongProvenance) { try f.coordinator.bindContact(contact, task: f.task, now: f.now) }
        contact.profile.origin = .fixture
        expectError(.wrongProvenance) { try f.coordinator.bindContact(contact, task: f.task, now: f.now) }
    }
    func testLiveModeAcceptsHostDeclaredLiveSemanticInput() async throws {
        let f = try Fixture(mode: .live); var contact = f.contact; contact.profile.origin = .liveDevice
        try f.coordinator.bindContact(contact, task: f.task, now: f.now)
        // Synthetic construction tests a provenance branch, NOT a device capture.
        var before = f.scene(); before.frame.origin = .liveDevice
        before.controls = before.controls.map { var control = $0; control.source = .ocr; return control }
        guard case .dispatch = try f.coordinator.reserve(task: f.task, effect: .message(f.message), observation: before, controlID: "submit", now: f.now) else { return XCTFail() }
    }
    func testOldChatPixelsCannotInheritLaterProfileIdentity() async throws {
        let f = try Fixture(); var before = f.scene()
        before.frame.capturedAt = f.contact.profile.capturedAt.addingTimeInterval(-1)
        expectError(.wrongContact) { _ = try f.reserve(.message(f.message), before: before) }
    }
    func testPauseInvalidatesUnconsumedTicketButPreservesAudit() async throws {
        let f = try Fixture(); let before = f.scene(); let ticket = try f.reserve(.message(f.message), before: before)
        f.coordinator.invalidateLiveContext()
        expectError(.invalidTransition) { _ = try f.coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.01)) }
        XCTAssertEqual(try f.store.load().records[0].status, .pending)
        XCTAssertNil(try f.store.load().records[0].dispatchedAt)
    }
}
