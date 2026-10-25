import Foundation
import XCTest
@testable import WeChatSkillCore

private enum StorageFault: Error { case injected }
@MainActor private final class FaultJournal: JournalStorage {
    let backing = MemoryJournal()
    var writes = 0
    var failOnWrite: Int?
    var failAfterSaving = false
    func load() throws -> JournalSnapshot { try backing.load() }
    func save(_ next: JournalSnapshot, expectedRevision: Int) throws {
        writes += 1
        if failOnWrite == writes {
            if failAfterSaving { try backing.save(next, expectedRevision: expectedRevision) }
            throw StorageFault.injected
        }
        try backing.save(next, expectedRevision: expectedRevision)
    }
}

@MainActor final class JournalTests: XCTestCase {
    func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-skill-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    func testAtomicFileRoundTripKeepsExactTextAndPendingState() async throws {
        let f = try Fixture(); _ = try f.dispatch(.message(f.message)); let snapshot = try f.store.load()
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try FileJournal(directory: dir)
        // Commit one valid snapshot revision at a time; no revision jump.
        var first = snapshot; first.revision = 1
        try file.save(first, expectedRevision: 0)
        let restored = try FileJournal(directory: dir).load()
        XCTAssertEqual(restored.records[0].status, .pending)
        XCTAssertTrue(exact(restored.records[0].effect.text!, f.message))
        XCTAssertNotNil(restored.records[0].dispatchedAt)
        let permissions = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("operations.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testStaleWriterCannotOverwriteNewRecord() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try FileJournal(directory: dir), b = try FileJournal(directory: dir)
        var first = try a.load(), stale = try b.load(); first.revision = 1; stale.revision = 1
        try a.save(first, expectedRevision: 0)
        expectError(.revisionConflict) { try b.save(stale, expectedRevision: 0) }
        XCTAssertEqual(try b.load().revision, 1)
    }
    func testCorruptFileIsPreservedRatherThanOverwritten() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try FileJournal(directory: dir); let url = dir.appendingPathComponent("operations.json")
        let corrupt = Data("{broken json".utf8); try corrupt.write(to: url)
        XCTAssertThrowsError(try file.load())
        var next = JournalSnapshot(); next.revision = 1
        XCTAssertThrowsError(try file.save(next, expectedRevision: 0))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    func testDuplicateTaskEffectInArchiveIsRejected() async throws {
        let f = try Fixture(); _ = try f.reserve(.message(f.message)); var snapshot = try f.store.load()
        var duplicate = snapshot.records[0]; duplicate.id = UUID(); snapshot.records.append(duplicate)
        expectError(.inconsistentJournal) { try snapshot.validate() }
    }
    func testInconsistentVerifiedArchiveIsRejected() async throws {
        let f = try Fixture(); _ = try f.reserve(.message(f.message)); var snapshot = try f.store.load()
        snapshot.records[0].status = .verified
        expectError(.inconsistentJournal) { try snapshot.validate() }
    }
    func testReservationWriteFailureReleasesNoTicket() async throws {
        let f = try Fixture(); let store = FaultJournal(); store.failOnWrite = 1
        let coordinator = try SubmissionCoordinator(storage: store, mode: .offline)
        try coordinator.bindContact(f.contact, task: f.task, now: f.now)
        XCTAssertThrowsError(try coordinator.reserve(task: f.task, effect: .message(f.message), observation: f.scene(), controlID: "submit", now: f.now))
        XCTAssertTrue(try store.load().records.isEmpty)
    }
    func testWriteSavedButThrewCannotCauseAutomaticReplay() async throws {
        let f = try Fixture(); let store = FaultJournal(); store.failOnWrite = 1; store.failAfterSaving = true
        let coordinator = try SubmissionCoordinator(storage: store, mode: .offline)
        try coordinator.bindContact(f.contact, task: f.task, now: f.now)
        XCTAssertThrowsError(try coordinator.reserve(task: f.task, effect: .message(f.message), observation: f.scene(), controlID: "submit", now: f.now))
        XCTAssertEqual(try store.load().records.count, 1)
        expectError(.duplicateOperation) { _ = try coordinator.reserve(task: f.task, effect: .message(f.message), observation: f.scene(), controlID: "submit", now: f.now) }
    }
    func testDispatchWriteFailureInvalidatesPermitBeforeReturningTap() async throws {
        let f = try Fixture(); let store = FaultJournal(); store.failOnWrite = 2
        let coordinator = try SubmissionCoordinator(storage: store, mode: .offline)
        try coordinator.bindContact(f.contact, task: f.task, now: f.now)
        let before = f.scene()
        guard case .dispatch(let ticket) = try coordinator.reserve(task: f.task, effect: .message(f.message), observation: before, controlID: "submit", now: f.now) else { return XCTFail() }
        XCTAssertThrowsError(try coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.01)))
        expectError(.invalidTransition) { _ = try coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.02)) }
        XCTAssertNil(try store.load().records[0].dispatchedAt)
    }
    func testRehydratedArchiveDoesNotAuthorizeAnyLiveAction() async throws {
        let f = try Fixture(); _ = try f.dispatch(.message(f.message))
        let coordinator = try SubmissionCoordinator(storage: f.store, mode: .offline)
        let after = f.after(.message(f.message), items: [.init(id: "new", text: f.message, author: .myself)])
        expectError(.wrongContact) { _ = try coordinator.verify(operationID: try f.store.load().records[0].id, after: after, now: f.now.addingTimeInterval(0.3)) }
    }
    func testCancellationBeforeReservationProducesNoRecord() async throws {
        let f = try Fixture()
        let work = Task { @MainActor in
            await Task.yield()
            return try f.reserve(.message(f.message))
        }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled work must stop") }
        catch is CancellationError { }
        XCTAssertTrue(try f.store.load().records.isEmpty)
    }
}
