import Foundation
import XCTest
@testable import WeChatSkillCore

final class TargetTests: XCTestCase {
    func testMixedSearchOnlySelectsContacts() throws {
        let items = SearchSection.allFixtureSections.enumerated().map { index, section in
            ContactCandidate(rowID: "row-\(index)", section: section, name: "Alice")
        }
        XCTAssertEqual(try TargetMatcher.contact(.init(keyword: "ali"), candidates: items), .candidate("row-0"))
    }
    func testIdenticalContactNamesNeedSelection() throws {
        let items = ["a","b"].map { ContactCandidate(rowID: $0, section: .contacts, name: "Alice") }
        XCTAssertEqual(try TargetMatcher.contact(.init(keyword: "Alice"), candidates: items), .ambiguous(["a","b"]))
    }
    func testKnownAccountDoesNotBeatUnknownPlausibleCandidate() throws {
        let items = [ContactCandidate(rowID: "a", section: .contacts, name: "Alice", account: "Alice_ID"),
                     ContactCandidate(rowID: "b", section: .contacts, name: "Alice")]
        XCTAssertEqual(try TargetMatcher.contact(.init(keyword: "Alice", expectedAccount: "Alice_ID"), candidates: items), .ambiguous(["a","b"]))
    }
    func testWrongAccountCaseDoesNotMatch() throws {
        let items = [ContactCandidate(rowID: "a", section: .contacts, name: "Alice", account: "alice_id")]
        XCTAssertEqual(try TargetMatcher.contact(.init(keyword: "Alice", expectedAccount: "Alice_ID"), candidates: items), .noneInObservedResults)
    }
    func testNoVisibleMatchDoesNotClaimContactAbsent() throws {
        XCTAssertEqual(try TargetMatcher.contact(.init(keyword: "Alice"), candidates: []), .noneInObservedResults)
    }
    func testDuplicateRowsAreInvalid() {
        let item = ContactCandidate(rowID: "a", section: .contacts, name: "Alice")
        expectError(.invalidObservation) { _ = try TargetMatcher.contact(.init(keyword: "Alice"), candidates: [item,item]) }
    }
    func testMissingYearNeedsMoreEvidence() throws {
        let item = MomentCandidate(localID: "a", ownerAccount: "Alice_ID", dateLabel: "29 Sep", body: "hello", bodyComplete: true, isDetail: true)
        XCTAssertEqual(try TargetMatcher.moment(account: "Alice_ID", clues: .init(dateLabel: "29 Sep", explicitYear: 2026), candidates: [item]), .inspectDetails(["a"]))
    }
    func testOneMatchPlusTruncatedCandidateCannotSelectFirst() throws {
        let full = MomentCandidate(localID: "a", ownerAccount: "Alice_ID", body: "hello world", bodyComplete: true, isDetail: true)
        let short = MomentCandidate(localID: "b", ownerAccount: "Alice_ID", body: "hello…", bodyComplete: false, isDetail: false)
        XCTAssertEqual(try TargetMatcher.moment(account: "Alice_ID", clues: .init(bodyExcerpt: "world"), candidates: [full,short]), .inspectDetails(["a","b"]))
    }
    func testRepeatedFullPostsAreAmbiguous() throws {
        let items = ["a","b"].map { MomentCandidate(localID: $0, ownerAccount: "Alice_ID", body: "hello", bodyComplete: true, isDetail: true) }
        XCTAssertEqual(try TargetMatcher.moment(account: "Alice_ID", clues: .init(bodyExcerpt: "hello"), candidates: items), .ambiguous(["a","b"]))
    }
    func testWrongOwnerCannotSupplyDateOrBody() throws {
        let item = MomentCandidate(localID: "a", ownerAccount: "Bob_ID", dateLabel: "29 Sep", body: "hello", bodyComplete: true, isDetail: true)
        XCTAssertEqual(try TargetMatcher.moment(account: "Alice_ID", clues: .init(bodyExcerpt: "hello"), candidates: [item]), .noneInObservedRange)
    }
    func testUnknownOwnerNeedsDetail() throws {
        let item = MomentCandidate(localID: "a", ownerAccount: nil, body: "hello", bodyComplete: true, isDetail: true)
        XCTAssertEqual(try TargetMatcher.moment(account: "Alice_ID", clues: .init(bodyExcerpt: "hello"), candidates: [item]), .inspectDetails(["a"]))
    }
    func testMediaClueNotInferredFromText() throws {
        let item = MomentCandidate(localID: "a", ownerAccount: "Alice_ID", body: "hello", bodyComplete: true, isDetail: true)
        XCTAssertEqual(try TargetMatcher.moment(account: "Alice_ID", clues: .init(mediaDescription: "九宫格招聘图"), candidates: [item]), .inspectDetails(["a"]))
    }
    func testExactTextPreservesUnicodeEncodingAndWhitespace() {
        XCTAssertFalse(exact("é", "e\u{301}"))
        XCTAssertFalse(exact("hello\nworld", "hello world"))
        XCTAssertFalse(exact("hi👋", "hi"))
        XCTAssertTrue(exact("你好\n👋", "你好\n👋"))
    }
    func testExcerptDoesNotNormalizeUnicode() {
        let item = MomentCandidate(localID: "a", ownerAccount: "Alice_ID", body: "é", bodyComplete: true, isDetail: true)
        XCTAssertEqual(TargetMatcher.quality(item, account: "Alice_ID", clues: .init(bodyExcerpt: "e\u{301}")), .different)
    }
    func testInvalidCluesAndEmptyTaskAreRejected() {
        expectError(.invalidTask) { try MomentClues().validate() }
        expectError(.invalidTask) { try MomentClues(explicitYear: 2026, bodyExcerpt: "x").validate() }
        expectError(.invalidTask) { try ContactQuery(keyword: " ").validate() }
        expectError(.invalidTask) { try MomentClues(bodyExcerpt: "").validate() }
    }
}

private extension SearchSection {
    static let allFixtureSections: [SearchSection] = [.contacts, .groups, .chatHistory, .internet, .searchID]
}
