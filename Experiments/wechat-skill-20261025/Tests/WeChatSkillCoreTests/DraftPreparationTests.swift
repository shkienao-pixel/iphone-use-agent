import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class PreparationFixture {
    let f: Fixture
    let task: SkillTask
    let scope: DraftScope
    let preparation: DraftPreparation
    let fieldBindingID = UUID()
    init(text: String = "hello", purpose: DraftPurpose = .message, submit: Bool = false,
         storage: (any DraftCheckpointStorage)? = nil) throws {
        let goal: TaskGoal = purpose == .momentComment
            ? .moment(clues: .init(bodyExcerpt: "正式介绍"), like: false, comment: text, submit: submit)
            : (purpose == .contactSearch ? .findContact : .message(text: text, submit: submit))
        f = try Fixture(goal: goal); task = f.task
        scope = .init(taskID: task.id, purpose: purpose, device: "fixture-phone", stream: f.stream,
            account: purpose == .contactSearch ? nil : f.contact.account,
            contactProofID: purpose == .contactSearch ? nil : f.contact.proofID,
            momentBindingID: purpose == .momentComment ? f.moment?.id : nil)
        preparation = try DraftPreparation(task: task, scope: scope, mode: .offline,
            checkpointStorage: storage, contact: purpose == .contactSearch ? nil : f.contact,
            moment: purpose == .momentComment ? f.moment : nil, now: f.now)
    }
    func observation(_ text: String = "", offset: Double = 0, focused: Bool = true,
                     ownership: FieldAccess? = nil, selection: DraftSelection = .caretAtEnd,
                     paste: Bool = false) -> DraftObservation {
        let frame = f.stamp(offset); let field = f.control(.textField, stamp: frame, id: "field")
        var controls = [field]
        if paste {
            var menu = f.control(.paste, stamp: frame, id: "paste"); menu.ownerFieldID = field.id; controls.append(menu)
        }
        return .init(frame: frame, scope: scope, fieldBindingID: fieldBindingID, field: field, controls: controls,
            text: text, complete: true, ownership: ownership ?? (text.isEmpty ? .empty : .taskOwned),
            focused: focused, fieldKind: DraftFieldKind(rawValue: scope.purpose.rawValue)!, selection: selection, composing: false)
    }
    func lease(_ text: String) -> ClipboardLease {
        .init(text: text, preparedAt: f.now, expiresAt: f.now.addingTimeInterval(10))
    }
    func next(_ observation: DraftObservation, keyboard: Bool = true, clipboard: ClipboardLease? = nil) throws -> PreparationDecision {
        try preparation.next(observation, keyboardAvailable: keyboard, clipboard: clipboard, now: observation.frame.confirmedAt.addingTimeInterval(0.01))
    }
    func action(_ observation: DraftObservation, keyboard: Bool = true, clipboard: ClipboardLease? = nil) throws -> AtomicAction {
        guard case .action(let ticket) = try next(observation, keyboard: keyboard, clipboard: clipboard) else { throw SkillError.invalidTransition }
        return try preparation.take(ticket, current: observation, keyboardAvailable: keyboard, clipboard: clipboard,
                                    now: observation.frame.confirmedAt.addingTimeInterval(0.02))
    }
}

@MainActor final class DraftPreparationTests: XCTestCase {
    func testFocusAndTypingRequireDifferentObservedActions() async throws {
        let p = try PreparationFixture()
        guard case .tap(let field) = try p.action(p.observation(focused: false)) else { return XCTFail() }
        XCTAssertEqual(field.role, .textField)
        guard case .inputASCII(_, let text) = try p.action(p.observation(offset: 0.2)) else { return XCTFail() }
        XCTAssertEqual(text, "hello")
    }
    func testUnchangedAfterTypingDoesNotIssueSecondInput() async throws {
        let p = try PreparationFixture(); _ = try p.action(p.observation())
        XCTAssertEqual(try p.next(p.observation(offset: 0.2)), .hold(.inputResultUncertain))
        let readback = p.observation("hello", offset: 0.4)
        XCTAssertEqual(try p.next(readback), .verified(text: "hello", frameID: readback.frame.id))
    }
    func testPartialASCIIReadbackAppendsOnlyMissingSuffix() async throws {
        let p = try PreparationFixture(); _ = try p.action(p.observation())
        guard case .inputASCII(_, let text) = try p.action(p.observation("he", offset: 0.2)) else { return XCTFail() }
        XCTAssertEqual(text, "llo")
    }
    func testPartialChineseRequiresSuffixClipboardNotOriginalFullText() async throws {
        let p = try PreparationFixture(text: "你好世界")
        XCTAssertEqual(try p.next(p.observation("你好"), keyboard: false, clipboard: p.lease("你好世界")), .needsClipboardPreparation("世界"))
    }
    func testPureMouseMenuOpeningAndPastingAreSeparate() async throws {
        let p = try PreparationFixture(text: "你好👋"); let lease = p.lease("你好👋")
        guard case .longPress = try p.action(p.observation(), keyboard: false, clipboard: lease) else { return XCTFail() }
        guard case .tap(let menu) = try p.action(p.observation(offset: 0.2, paste: true), keyboard: false, clipboard: lease) else { return XCTFail() }
        XCTAssertEqual(menu.role, .paste); XCTAssertEqual(menu.ownerFieldID, "field")
        let readback = p.observation("你好👋", offset: 0.4)
        XCTAssertEqual(try p.next(readback, keyboard: false), .verified(text: "你好👋", frameID: readback.frame.id))
    }
    func testMenuThatNeverAppearsDoesNotTriggerBlindLongPress() async throws {
        let p = try PreparationFixture(text: "你好"); let lease = p.lease("你好")
        _ = try p.action(p.observation(), keyboard: false, clipboard: lease)
        XCTAssertEqual(try p.next(p.observation(offset: 0.2), keyboard: false, clipboard: lease), .hold(.pasteMenuUnconfirmed))
    }
    func testForeignPrefixIsPreservedRatherThanAdopted() async throws {
        let p = try PreparationFixture()
        XCTAssertEqual(try p.next(p.observation("he", ownership: .foreignDraft)), .hold(.foreignDraft))
    }
    func testExactlyAuthorizedForeignTextCanBeReadWithoutEditing() async throws {
        let p = try PreparationFixture(); let observation = p.observation("hello", ownership: .foreignDraft)
        XCTAssertEqual(try p.next(observation), .verified(text: "hello", frameID: observation.frame.id))
    }
    func testUnknownOwnershipCannotAuthorizeAppending() async throws {
        let p = try PreparationFixture()
        XCTAssertEqual(try p.next(p.observation("he", ownership: .unknown)), .hold(.unknownOwnership))
    }
    func testIncompleteReadbackCannotBecomeVerified() async throws {
        let p = try PreparationFixture(); var observation = p.observation("hello"); observation.complete = false
        XCTAssertEqual(try p.next(observation), .hold(.unreadableText))
    }
    func testMarkedInputTextIsNotCommittedText() async throws {
        let p = try PreparationFixture(); var observation = p.observation("hello"); observation.composing = true
        XCTAssertEqual(try p.next(observation), .hold(.inputMethodComposing))
    }
    func testUnknownCompositionStateCannotDefaultToCommittedText() async throws {
        let p = try PreparationFixture(); var observation = p.observation("hello"); observation.composing = nil
        XCTAssertEqual(try p.next(observation), .hold(.inputMethodComposing))
    }
    func testUnknownObservedFieldKindCannotBeInferredFromTask() async throws {
        let p = try PreparationFixture(); var observation = p.observation("hello"); observation.fieldKind = .unknown
        expectError(.wrongDraft) { _ = try p.next(observation) }
    }
    func testReplyFieldIsRejectedEvenWithoutReadableReplyName() async throws {
        let p = try PreparationFixture(text: "越做越好👏", purpose: .momentComment)
        var observation = p.observation(); observation.fieldKind = .reply; observation.replyTarget = nil
        expectError(.wrongDraft) { _ = try p.next(observation) }
    }
    func testPreparationVerificationNeverGrantsSubmissionAuthorization() async throws {
        let p = try PreparationFixture(); let readback = p.observation("hello")
        XCTAssertEqual(try p.next(readback), .verified(text: "hello", frameID: readback.frame.id))
        expectError(.unapprovedEffect) { _ = try p.f.reserve(.message("hello")) }
        XCTAssertTrue(try p.f.store.load().records.isEmpty)
    }
    func testTopLevelCommentPreparationRejectsReplyTarget() async throws {
        let p = try PreparationFixture(text: "越做越好👏", purpose: .momentComment)
        var observation = p.observation(); observation.replyTarget = "Bob"
        expectError(.wrongDraft) { _ = try p.next(observation) }
    }
    func testSearchPreparesKeywordWithoutClaimingContactIdentity() async throws {
        let p = try PreparationFixture(purpose: .contactSearch)
        guard case .inputASCII(_, let text) = try p.action(p.observation()) else { return XCTFail() }
        XCTAssertEqual(text, p.task.contact.keyword); XCTAssertNil(p.scope.account)
    }
    func testWrongAccountAndWrongComposerCannotReusePreparation() async throws {
        let p = try PreparationFixture(); var wrong = p.observation(); wrong.scope.account = "Bob_ID"
        expectError(.wrongContact) { _ = try p.next(wrong) }
        _ = try p.next(p.observation())
        var other = p.observation(offset: 0.2); other.fieldBindingID = UUID()
        expectError(.wrongDraft) { _ = try p.next(other) }
    }
    func testProposalIsIdempotentButTicketIsSingleUse() async throws {
        let p = try PreparationFixture(); let observation = p.observation()
        let first = try p.next(observation); XCTAssertEqual(try p.next(observation), first)
        guard case .action(let ticket) = first else { return XCTFail() }
        _ = try p.preparation.take(ticket, current: observation, keyboardAvailable: true, now: p.f.now.addingTimeInterval(0.02))
        expectError(.invalidTransition) { _ = try p.preparation.take(ticket, current: observation, keyboardAvailable: true, now: p.f.now.addingTimeInterval(0.03)) }
    }
    func testClipboardChangeBeforeTakeInvalidatesPasteProposal() async throws {
        let p = try PreparationFixture(text: "你好"); let observation = p.observation(paste: true)
        guard case .action(let ticket) = try p.next(observation, keyboard: false, clipboard: p.lease("你好")) else { return XCTFail() }
        expectError(.unavailableInput) {
            _ = try p.preparation.take(ticket, current: observation, keyboardAvailable: false, clipboard: p.lease("其他内容"), now: p.f.now.addingTimeInterval(0.02))
        }
        expectError(.invalidTransition) {
            _ = try p.preparation.take(ticket, current: observation, keyboardAvailable: false, clipboard: p.lease("你好"), now: p.f.now.addingTimeInterval(0.03))
        }
    }
    func testTrailingNewlineUsesClipboardNotReturnKey() async throws {
        let p = try PreparationFixture(text: "hello\n")
        XCTAssertEqual(try p.next(p.observation("hello"), keyboard: true), .needsClipboardPreparation("\n"))
        guard case .editingKey(_, .paste) = try p.action(p.observation("hello", offset: 0.2), clipboard: p.lease("\n")) else { return XCTFail() }
    }
    func testUnknownCaretMustBeObservedOrSelectedBeforeAppending() async throws {
        let p = try PreparationFixture()
        XCTAssertEqual(try p.next(p.observation("he", selection: .unknown), keyboard: false), .hold(.caretOrSelectionRequired))
    }
    func testCorrectingOwnedDraftUsesSelectAllAndSeparateReadback() async throws {
        let p = try PreparationFixture()
        guard case .editingKey(_, .selectAll) = try p.action(p.observation("wrong")) else { return XCTFail() }
        guard case .inputASCII(_, let text) = try p.action(p.observation("wrong", offset: 0.2, selection: .allText)) else { return XCTFail() }
        XCTAssertEqual(text, "hello")
    }
    func testMissingSelectionFeedbackDoesNotTypeOverUnknownRange() async throws {
        let p = try PreparationFixture(); _ = try p.action(p.observation("wrong"))
        XCTAssertEqual(try p.next(p.observation("wrong", offset: 0.2)), .hold(.selectionUnconfirmed))
    }
    func testLongASCIIDraftIsChunkedWithoutOverallStepLimit() async throws {
        let wanted = String(repeating: "a", count: 1002); let p = try PreparationFixture(text: wanted)
        guard case .inputASCII(_, let first) = try p.action(p.observation()) else { return XCTFail() }
        XCTAssertEqual(first.count, 500)
        guard case .inputASCII(_, let second) = try p.action(p.observation(String(repeating: "a", count: 500), offset: 0.2)) else { return XCTFail() }
        XCTAssertEqual(second.count, 500)
        guard case .inputASCII(_, let final) = try p.action(p.observation(String(repeating: "a", count: 1000), offset: 0.4)) else { return XCTFail() }
        XCTAssertEqual(final, "aa")
    }
    func testPauseAndCancellationInvalidatePreparationTickets() async throws {
        let p = try PreparationFixture(); let observation = p.observation()
        guard case .action(let ticket) = try p.next(observation) else { return XCTFail() }
        let work = Task { @MainActor in
            await Task.yield()
            return try p.preparation.take(ticket, current: observation, keyboardAvailable: true, now: p.f.now.addingTimeInterval(0.02))
        }
        work.cancel()
        do { _ = try await work.value; XCTFail() } catch is CancellationError { }
        expectError(.invalidTransition) { _ = try p.next(p.observation(offset: 0.2)) }
    }
}
