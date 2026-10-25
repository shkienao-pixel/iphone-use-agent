import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class MomentTests: XCTestCase {
    let clues = MomentClues(dateLabel: "29 Sep", bodyExcerpt: "正式介绍")
    func fixture(like: Bool = true, comment: String? = "越做越好👏") throws -> Fixture {
        try Fixture(goal: .moment(clues: clues, like: like, comment: comment, submit: true))
    }
    func testAlreadyLikedProducesNoTicketAndNoClick() async throws {
        let f = try fixture(); var before = f.scene(effect: .like); before.like = .likedBySelf; before.controls = []
        guard case .alreadySatisfied = try f.coordinator.reserve(task: f.task, effect: .like, observation: before, now: f.now) else { return XCTFail() }
        let record = try f.store.load().records[0]
        XCTAssertEqual(record.status, .alreadySatisfied); XCTAssertNil(record.dispatchedAt); XCTAssertNil(record.control)
    }
    func testUnknownLikeStateNeverToggles() async throws {
        let f = try fixture(); var before = f.scene(effect: .like); before.like = .unknown
        expectError(.invalidObservation) { _ = try f.reserve(.like, before: before) }
    }
    func testUnlikeControlIsNeverUsedForLikeTask() async throws {
        let f = try fixture(); var before = f.scene(effect: .like); before.controls[1].role = .unlike
        expectError(.invalidAction) { _ = try f.reserve(.like, before: before) }
    }
    func testLikeHasItsOwnResult() async throws {
        let f = try fixture(); let ticket = try f.dispatch(.like)
        var after = f.after(.like, items: [], empty: true); after.like = .likedBySelf
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .verified)
        XCTAssertEqual(try f.store.load().records.count, 1)
        XCTAssertEqual(try f.store.load().records[0].effect, .like)
    }
    func testLikePendingCannotStartCommentInCombinedTask() async throws {
        let f = try fixture(); _ = try f.dispatch(.like)
        expectError(.invalidTransition) { _ = try f.reserve(.comment("越做越好👏")) }
    }
    func testLikeAndCommentRemainSeparateThroughPartialRecovery() async throws {
        let f = try fixture(); var liked = f.scene(effect: .like); liked.like = .likedBySelf
        _ = try f.coordinator.reserve(task: f.task, effect: .like, observation: liked, now: f.now)
        let effect = Effect.comment("越做越好👏"); let ticket = try f.dispatch(effect)
        _ = try f.coordinator.verify(operationID: ticket.operationID, after: f.after(effect, items: [], empty: true), now: f.now.addingTimeInterval(0.3))
        let records = try f.store.load().records
        XCTAssertEqual(records.map(\.status), [.alreadySatisfied, .uncertain])
        expectError(.duplicateOperation) { _ = try f.reserve(.like, before: liked) }
        expectError(.duplicateOperation) { _ = try f.reserve(effect) }
    }
    func testCommentOnlyDoesNotRequireOrCreateLike() async throws {
        let f = try fixture(like: false); let effect = Effect.comment("越做越好👏")
        let ticket = try f.dispatch(effect)
        let after = f.after(effect, items: [.init(id: "new-comment", text: "越做越好👏", author: .myself)])
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .verified)
        XCTAssertEqual(try f.store.load().records.map(\.effect), [effect])
    }
    func testReplyToPersonCannotMasqueradeAsTopLevelComment() async throws {
        let f = try fixture(like: false); let effect = Effect.comment("越做越好👏"); var before = f.scene(effect: effect)
        before.draft?.kind = .reply; before.draft?.replyTarget = "Bob"
        expectError(.wrongDraft) { _ = try f.reserve(effect, before: before) }
    }
    func testWrongPostBindingCannotSubmit() async throws {
        let f = try fixture(like: false); let effect = Effect.comment("越做越好👏"); var before = f.scene(effect: effect)
        before.momentBindingID = UUID()
        expectError(.wrongMoment) { _ = try f.reserve(effect, before: before) }
    }
    func testPostCountChangeCannotProveComment() async throws {
        let f = try fixture(like: false); let effect = Effect.comment("越做越好👏"); let ticket = try f.dispatch(effect)
        let after = f.after(effect, items: [.init(id: "other-comment", text: "别人评论", author: .other)])
        XCTAssertEqual(try f.coordinator.verify(operationID: ticket.operationID, after: after, now: f.now.addingTimeInterval(0.3)), .uncertain("unique_new_self_item_missing"))
    }
    func testProfileBindingChangeInvalidatesOutstandingPermit() async throws {
        let f = try fixture(like: false); let effect = Effect.comment("越做越好👏"); let before = f.scene(effect: effect)
        let ticket = try f.reserve(effect, before: before)
        try f.coordinator.bindContact(f.contact, task: f.task, now: f.now)
        expectError(.invalidTransition) { _ = try f.coordinator.take(ticket, current: before, now: f.now.addingTimeInterval(0.01)) }
    }
    func testFriendsFeedStillRequiresAuthorAccountBinding() async throws {
        let f = try fixture(); var task = f.task; task.route = .friendsFeed
        let coordinator = try SubmissionCoordinator(storage: MemoryJournal(), mode: .offline)
        try coordinator.bindContact(f.contact, task: task, now: f.now)
        var unknown = f.candidate(); unknown.ownerAccount = nil
        expectError(.ambiguousTarget) { _ = try coordinator.bindMoment(candidates: [unknown], task: task, frame: f.stamp(), now: f.now) }
    }
}
