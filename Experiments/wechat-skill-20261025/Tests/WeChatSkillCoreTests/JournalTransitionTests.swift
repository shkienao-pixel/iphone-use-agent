import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class JournalTransitionTests: XCTestCase {
    func testSingleSaveCannotReleaseTwoAtomicEffects() async throws {
        let store = MemoryJournal(); let a = try Fixture(store: store), b = try Fixture(store: store)
        _ = try a.reserve(.message(a.message)); _ = try b.reserve(.message(b.message))
        var next = try store.load(); let revision = next.revision
        for index in next.records.indices { next.records[index].dispatchedAt = a.now.addingTimeInterval(0.01) }
        next.revision += 1
        expectError(.inconsistentJournal) { try store.save(next, expectedRevision: revision) }
        XCTAssertTrue(try store.load().records.allSatisfy { $0.dispatchedAt == nil })
    }
    func testCannotReorderOperationHistory() async throws {
        let store = MemoryJournal(); let a = try Fixture(store: store), b = try Fixture(store: store)
        _ = try a.reserve(.message(a.message)); _ = try b.reserve(.message(b.message))
        var next = try store.load(); let revision = next.revision
        next.records.reverse(); next.revision += 1
        expectError(.inconsistentJournal) { try store.save(next, expectedRevision: revision) }
    }
    func testCannotChangeAlreadyReleasedTimestamp() async throws {
        let f = try Fixture(); _ = try f.dispatch(.message(f.message))
        var next = try f.store.load(); let revision = next.revision
        next.records[0].dispatchedAt = f.now.addingTimeInterval(0.02); next.revision += 1
        expectError(.inconsistentJournal) { try f.store.save(next, expectedRevision: revision) }
    }
    func testCannotSkipReservationToCreateDispatchedRecord() async throws {
        let f = try Fixture(); _ = try f.dispatch(.message(f.message))
        var next = try f.store.load(); next.revision = 1
        let empty = MemoryJournal()
        expectError(.inconsistentJournal) { try empty.save(next, expectedRevision: 0) }
    }
    func testFreshPendingItemCanBecomeVerifiedWithoutAnotherDispatch() async throws {
        let f = try Fixture(); let effect = Effect.message(f.message); let ticket = try f.dispatch(effect)
        let pending = f.after(effect, items: [.init(id: "new", text: f.message, author: .myself, state: .pending)])
        _ = try f.coordinator.verify(operationID: ticket.operationID, after: pending, now: f.now.addingTimeInterval(0.3))
        var normal = f.after(effect, items: [.init(id: "new", text: f.message, author: .myself)])
        normal.frame = f.stamp(0.4); normal.controls = []
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: normal, now: f.now.addingTimeInterval(0.5)), .verified)
        let snapshot = try f.store.load()
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records[0].dispatchedAt, f.now.addingTimeInterval(0.01))
    }
    func testArchiveCannotClaimOldSameTextIsNewMessage() async throws {
        let f = try Fixture(); let old = VisibleItem(id: "old", text: f.message, author: .myself)
        _ = try f.dispatch(.message(f.message), before: f.scene(items: [old], empty: false, anchors: ["anchor"]))
        var next = try f.store.load()
        next.records[0].status = .verified
        next.records[0].result = f.after(.message(f.message), items: [old], anchors: ["anchor"])
        expectError(.inconsistentJournal) { try next.validate() }
    }
    func testFileStoreAlsoRejectsHistoryDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-transition-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try Fixture(); let store = try FileJournal(directory: directory)
        let coordinator = try SubmissionCoordinator(storage: store, mode: .offline)
        try coordinator.bindContact(f.contact, task: f.task, now: f.now)
        _ = try coordinator.reserve(task: f.task, effect: .message(f.message), observation: f.scene(), controlID: "submit", now: f.now)
        let before = try Data(contentsOf: directory.appendingPathComponent("operations.json"))
        var next = try store.load(); let revision = next.revision
        next.records = []; next.revision += 1
        expectError(.inconsistentJournal) { try store.save(next, expectedRevision: revision) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("operations.json")), before)
    }
    func testRevisionOverflowIsRejectedBeforeArithmetic() async throws {
        var snapshot = JournalSnapshot(); snapshot.revision = Int.max
        expectError(.inconsistentJournal) { try snapshot.validate() }
        let store = MemoryJournal()
        expectError(.revisionConflict) { try store.save(snapshot, expectedRevision: Int.max) }
    }
}
