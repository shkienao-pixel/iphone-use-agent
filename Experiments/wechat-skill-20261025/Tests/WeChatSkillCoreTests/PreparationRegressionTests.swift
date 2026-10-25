import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class PreparationRegressionTests: XCTestCase {
    func testFocusBooleanAloneCannotAuthorizeTypingIntoAnyField() async throws {
        let f = try Fixture(); let frame = f.stamp(); let field = f.control(.textField, stamp: frame, id: "different-field")
        expectError(.unavailableInput) {
            try AtomicActionRules.validateOrdinary(.inputASCII(field, text: "hello"), frame: frame, controls: [field],
                capabilities: .init(keyboard: true, fieldAccess: .empty, focused: true), mode: .offline, now: f.now, maxAge: 5)
        }
    }

    func testPasteMenuMustBelongToObservedFocusedField() async throws {
        let f = try Fixture(); let frame = f.stamp(); let paste = f.control(.paste, stamp: frame)
        let lease = ClipboardLease(text: "hello", preparedAt: f.now, expiresAt: f.now.addingTimeInterval(10))
        expectError(.unavailableInput) {
            try AtomicActionRules.validateOrdinary(.tap(paste), frame: frame, controls: [paste],
                capabilities: .init(fieldAccess: .empty, focused: true, clipboard: lease), mode: .offline, now: f.now, maxAge: 5)
        }
    }

    func testWhitespaceSuffixCanBePreparedWithoutUsingReturn() async throws {
        let f = try Fixture()
        for suffix in [" ", "\n", "\n\n"] {
            try AtomicActionRules.validateOrdinary(.prepareClipboard(text: suffix), frame: f.stamp(), controls: [],
                capabilities: .init(hostForeground: true, clipboardPreparation: true), mode: .offline, now: f.now, maxAge: 5)
        }
    }

    func testWhitespaceOnlyLeasePreservesOriginalTrailingCharacters() async throws {
        let f = try Fixture()
        let lease = ClipboardLease(text: "\n", preparedAt: f.now, expiresAt: f.now.addingTimeInterval(10))
        XCTAssertTrue(lease.usable(at: f.now))
    }
}
