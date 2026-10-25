import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class AtomicTests: XCTestCase {
    func validate(_ action: AtomicAction, f: Fixture, frame: FrameStamp, controls: [ObservedControl],
                  caps: InputCapabilities = .init()) throws {
        try AtomicActionRules.validateOrdinary(action, frame: frame, controls: controls, capabilities: caps,
                                              mode: .offline, now: f.now, maxAge: 5)
    }
    func testOrdinaryTapCannotBypassSubmissionJournal() async throws {
        let f = try Fixture(); let frame = f.stamp()
        for role in [ControlRole.sendMessage, .sendComment, .like, .unlike] {
            let control = f.control(role, stamp: frame)
            expectError(.unapprovedEffect) { try validate(.tap(control), f: f, frame: frame, controls: [control]) }
        }
    }
    func testNavigationAndInputAreDifferentActions() async throws {
        let f = try Fixture(); let frame = f.stamp(); let control = f.control(.textField, stamp: frame)
        try validate(.tap(control), f: f, frame: frame, controls: [control])
        expectError(.unavailableInput) { try validate(.inputASCII(control, text: "hello"), f: f, frame: frame, controls: [control]) }
        try validate(.inputASCII(control, text: "hello"), f: f, frame: frame, controls: [control],
                     caps: .init(keyboard: true, fieldAccess: .empty, focused: true))
    }
    func testUnicodeReturnAndTabCannotHideInsideTyping() async throws {
        let f = try Fixture(); let frame = f.stamp(); let control = f.control(.textField, stamp: frame)
        for text in ["你好", "hello\n", "hello\r", "hello\tworld", "hi👋"] {
            expectError(.unavailableInput) { try validate(.inputASCII(control, text: text), f: f, frame: frame, controls: [control], caps: .init(keyboard: true, fieldAccess: .empty, focused: true)) }
        }
    }
    func testForeignDraftCannotBeTypedIntoOrDeleted() async throws {
        let f = try Fixture(); let frame = f.stamp(); let control = f.control(.textField, stamp: frame)
        let caps = InputCapabilities(keyboard: true, fieldAccess: .foreignDraft, focused: true)
        expectError(.unavailableInput) { try validate(.inputASCII(control, text: "new"), f: f, frame: frame, controls: [control], caps: caps) }
        expectError(.unavailableInput) { try validate(.editingKey(control, key: .deleteBackward), f: f, frame: frame, controls: [control], caps: caps) }
    }
    func testClipboardPreparationRequiresHostForeground() async throws {
        let f = try Fixture(); let frame = f.stamp()
        expectError(.unavailableInput) { try validate(.prepareClipboard(text: "中文\n👋"), f: f, frame: frame, controls: [], caps: .init(clipboardPreparation: true)) }
        try validate(.prepareClipboard(text: "中文\n👋"), f: f, frame: frame, controls: [], caps: .init(hostForeground: true, clipboardPreparation: true))
    }
    func testPureMousePasteUsesVisibleMenuAsSeparateAction() async throws {
        let f = try Fixture(); let frame = f.stamp(); let field = f.control(.textField, stamp: frame, id: "field")
        let paste = f.control(.paste, stamp: frame, id: "paste")
        try validate(.longPress(field), f: f, frame: frame, controls: [field])
        let lease = ClipboardLease(text: "你好", preparedAt: f.now.addingTimeInterval(-1), expiresAt: f.now.addingTimeInterval(10))
        try validate(.tap(paste), f: f, frame: frame, controls: [paste], caps: .init(fieldAccess: .empty, focused: true, clipboard: lease))
        expectError(.unavailableInput) { try validate(.editingKey(field, key: .paste), f: f, frame: frame, controls: [field], caps: .init(fieldAccess: .empty, focused: true, clipboard: lease)) }
    }
    func testExpiredOrOverwrittenClipboardCannotBeUsed() async throws {
        let f = try Fixture(); let frame = f.stamp(); let paste = f.control(.paste, stamp: frame)
        for lease in [ClipboardLease(text: "你好", preparedAt: f.now.addingTimeInterval(-2), expiresAt: f.now),
                      ClipboardLease(text: "你好", preparedAt: f.now, expiresAt: f.now.addingTimeInterval(10), invalidated: true)] {
            expectError(.unavailableInput) { try validate(.tap(paste), f: f, frame: frame, controls: [paste], caps: .init(fieldAccess: .empty, focused: true, clipboard: lease)) }
        }
    }
    func testScrollCannotUseLikeOrSendAsAnchor() async throws {
        let f = try Fixture(); let frame = f.stamp(); let like = f.control(.like, stamp: frame)
        expectError(.invalidAction) { try validate(.scroll(like, ticks: -2), f: f, frame: frame, controls: [like]) }
        let list = f.control(.scrollRegion, stamp: frame)
        try validate(.scroll(list, ticks: -2), f: f, frame: frame, controls: [list])
        expectError(.invalidAction) { try validate(.scroll(list, ticks: -20), f: f, frame: frame, controls: [list]) }
    }
    func testControlFromOldFrameCannotBeReused() async throws {
        let f = try Fixture(); let frame = f.stamp(); let old = f.control(.navigation, stamp: f.stamp(-1))
        expectError(.invalidAction) { try validate(.tap(old), f: f, frame: frame, controls: [old]) }
    }
    func testInvalidAndNonfiniteRectanglesAreRejected() async throws {
        let f = try Fixture(); let frame = f.stamp()
        for rect in [UnitRect(x: .nan, y: 0, width: 0.1, height: 0.1), .init(x: 0.99, y: 0.5, width: 0.1, height: 0.1), .init(x: 0, y: 0, width: 0, height: 0.1)] {
            var control = f.control(.navigation, stamp: frame); control.rect = rect
            expectError(.invalidAction) { try validate(.tap(control), f: f, frame: frame, controls: [control]) }
        }
    }
    func testAtomicContractCannotDecodeAnActionArrayOrMacro() async throws {
        for json in ["[]", "{\"sendAndLike\":{}}", "{\"inputAndSend\":{}}", "{\"editingKey\":{\"key\":\"return\"}}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(AtomicAction.self, from: Data(json.utf8)))
        }
    }
    func testStaleFutureAndReferenceFramesFail() async throws {
        let f = try Fixture()
        for offset in [-6.0, 1.0] {
            let frame = f.stamp(offset)
            expectError { try validate(.prepareClipboard(text: "x"), f: f, frame: frame, controls: [], caps: .init(hostForeground: true, clipboardPreparation: true)) }
        }
        var frame = f.stamp(); frame.origin = .referenceImage
        expectError(.wrongProvenance) { try validate(.prepareClipboard(text: "x"), f: f, frame: frame, controls: [], caps: .init(hostForeground: true, clipboardPreparation: true)) }
    }
}
