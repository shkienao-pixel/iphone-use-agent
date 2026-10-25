import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class IterationRegressionTests: XCTestCase {
    func testCancelledTakeCannotLeaveReusableTicket() async throws {
        let f = try Fixture(); let before = f.scene(); let ticket = try f.reserve(.message(f.message), before: before)
        let cancelled = Task { @MainActor in
            await Task.yield()
            return try f.coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.01))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation must stop the take") }
        catch is CancellationError { }
        expectError(.invalidTransition) {
            _ = try f.coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.02))
        }
        XCTAssertNil(try f.store.load().records[0].dispatchedAt)
    }

    func testOlderResultCannotOverwriteNewerPendingObservation() async throws {
        let f = try Fixture(); let effect = Effect.message(f.message); let ticket = try f.dispatch(effect)
        var recent = f.after(effect, items: [.init(id: "new", text: f.message, author: .myself, state: .pending)])
        recent.frame = f.stamp(0.3); recent.controls = []
        _ = try f.coordinator.verify(operationID: ticket.operationID, after: recent, now: f.now.addingTimeInterval(0.4))
        let older = f.after(effect, items: [.init(id: "new", text: f.message, author: .myself)])
        expectError(.staleObservation) {
            _ = try f.coordinator.verify(operationID: ticket.operationID, after: older, now: f.now.addingTimeInterval(0.4))
        }
        XCTAssertEqual(try f.store.load().records[0].status, .uncertain)
    }

    func testReusingSameResultFrameDoesNotCreateNewEvidence() async throws {
        let f = try Fixture(); let effect = Effect.message(f.message); let ticket = try f.dispatch(effect)
        let after = f.after(effect, items: [], empty: true)
        _ = try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3))
        let revision = try f.store.load().revision
        expectError(.staleObservation) {
            _ = try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.4))
        }
        XCTAssertEqual(try f.store.load().revision, revision)
    }

    func testSaveCannotDeletePendingHistory() async throws {
        let f = try Fixture(); _ = try f.reserve(.message(f.message))
        var next = try f.store.load(); let revision = next.revision
        next.records = []; next.revision += 1
        expectError(.inconsistentJournal) { try f.store.save(next, expectedRevision: revision) }
        XCTAssertEqual(try f.store.load().records.count, 1)
    }

    func testSaveCannotRewriteFrozenTaskRequest() async throws {
        let f = try Fixture(); _ = try f.reserve(.message(f.message))
        var next = try f.store.load(); let revision = next.revision
        next.records[0].task.originalRequest = "Different request"; next.revision += 1
        expectError(.inconsistentJournal) { try f.store.save(next, expectedRevision: revision) }
    }

    func testTerminalSuccessCannotReturnToPending() async throws {
        let f = try Fixture(); let effect = Effect.message(f.message); let ticket = try f.dispatch(effect)
        _ = try f.coordinator.verify(operationID: ticket.operationID,
            after: f.after(effect, items: [.init(id: "new", text: f.message, author: .myself)]), now: f.now.addingTimeInterval(0.3))
        var next = try f.store.load(); let revision = next.revision
        next.records[0].status = .pending; next.records[0].result = nil; next.revision += 1
        expectError(.inconsistentJournal) { try f.store.save(next, expectedRevision: revision) }
        XCTAssertEqual(try f.store.load().records[0].status, .verified)
    }

    func testArchiveCannotClaimLikeSuccessAgainstObservedState() async throws {
        let f = try Fixture(goal: .moment(clues: .init(bodyExcerpt: "正式介绍"), like: true, comment: nil, submit: true))
        _ = try f.dispatch(.like)
        var snapshot = try f.store.load()
        snapshot.records[0].status = .verified
        snapshot.records[0].result = f.after(.like, items: [], empty: true) // still notLikedBySelf
        expectError(.inconsistentJournal) { try snapshot.validate() }
    }
}
