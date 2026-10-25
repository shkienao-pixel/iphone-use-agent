import Foundation
import XCTest
@testable import WeChatSkillCore

final class ReferenceUITests: XCTestCase {
    func text(_ id: String, _ value: String, _ x: Double, _ y: Double, width: Double = 0.25) -> ReferenceText {
        .init(id:id,text:value,rect:.init(x:x,y:y,width:width,height:0.015),confidence:0.95,source:.fixture)
    }
    func frame(_ rows: [ReferenceText], shapes: [ReferenceShape] = []) -> ReferenceUIFrame {
        .init(origin:.fixture,width:1280,height:2781,texts:rows,shapes:shapes)
    }
    var tabs: [ReferenceText] {
        [text("chats","Chats",0.08,0.95,width:0.08),text("contacts","Contacts",0.32,0.95,width:0.11),
         text("discover","Discover",0.57,0.95,width:0.12),text("me","Me",0.85,0.95,width:0.05)]
    }
    var profile: [ReferenceText] {
        [text("account","Weixin ID: Alice_ID",0.21,0.19,width:0.4),text("mome","Mome",0.03,0.37,width:0.10),
         text("nts","nts",0.03,0.39,width:0.06),text("message","D Messages",0.38,0.47,width:0.25),
         text("call","C Voice or Video Call",0.30,0.53,width:0.40)]
    }
    func testSearchResultsOnlyExtractRowsBetweenContactAndGroupHeaders() throws {
        let rows = [text("query","fram",0.18,0.08),text("contacts","Contacts",0.03,0.15),
            text("person","Alice",0.16,0.21),text("groups","Group Chats",0.03,0.30),
            text("group","Alice group",0.16,0.35),text("history","Chat History",0.03,0.45),text("chat","Alice",0.16,0.50)]
        let result = try ReferenceUIAnalyzer.analyze(frame(rows))
        XCTAssertEqual(result.page,.searchResults); XCTAssertEqual(result.queryReadback,"fram")
        XCTAssertEqual(result.contactCandidates.map(\.rowID),["person"])
    }
    func testWrappedMomentsAndDecoratedButtonsPreserveAccountSpelling() throws {
        let result = try ReferenceUIAnalyzer.analyze(frame(profile))
        XCTAssertEqual(result.page,.contactProfile); XCTAssertEqual(result.accountReadback,"Alice_ID")
        XCTAssertEqual(result.anchors.first(where: { $0.role == "profileMoments" })?.sourceIDs,["mome","nts"])
    }
    func testDuplicateAccountFieldsDoNotSelectAProfileIdentity() throws {
        let result = try ReferenceUIAnalyzer.analyze(frame(profile+[text("other","Weixin ID: Bob_ID",0.21,0.23,width:0.4)]))
        XCTAssertEqual(result.page,.unknown); XCTAssertNil(result.accountReadback)
    }
    func testSplitAccountLabelAndSameLineValueAreNotAutocorrected() throws {
        var rows = profile; rows[0] = text("account","Weixin ID:",0.21,0.19,width:0.18)
        rows.append(text("account-value","aLice_1D",0.40,0.19,width:0.18))
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(rows)).accountReadback,"aLice_1D")
    }
    func testWeixinUnreadCountWithFourTabsIsChatList() throws {
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(tabs+[text("title","Weixin (34)",0.39,0.075,width:0.22)])).page,.chats)
    }
    func testDiscoverNeedsRealTopHeadingEntryAndBottomTabs() throws {
        let rows = tabs+[text("title","Discover",0.42,0.075,width:0.17),text("moments","Moments",0.13,0.13,width:0.17),text("channels","Channels",0.13,0.20)]
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(rows)).page,.discover)
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(Array(rows.dropFirst(4)))).page,.unknown)
    }
    func testMomentDetailRequiresBottomComposerAndActualBodyRegion() throws {
        let rows = [text("details","Details",0.43,0.075,width:0.14),text("comment","Comment:",0.04,0.93,width:0.16),
            text("body1","first actual paragraph",0.14,0.25,width:0.7),text("body2","second actual paragraph",0.14,0.35,width:0.7),
            text("body3","third actual paragraph",0.14,0.45,width:0.7)]
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(rows)).page,.momentDetail)
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame([rows[0],rows[1]])).page,.unknown)
    }
    func testAChatTitleAloneCannotIdentifyAnEmptyComposer() throws {
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame([text("title","Alice",0.35,0.075)])).page,.unknown)
    }
    func testEmptyComposerNeedsIndependentGraphicalOutlines() throws {
        let shapes = [ReferenceShape(id:"back",kind:.contour,rect:.init(x:0.03,y:0.075,width:0.02,height:0.015),source:.fixture)] +
            [0.025,0.825,0.915].enumerated().map { index,x in
                ReferenceShape(id:"circle-\(index)",kind:.contour,rect:.init(x:x,y:0.921,width:0.059,height:0.0276),source:.fixture)
            }
        let rows = [text("title","Alice",0.35,0.075),text("first-message-time","9/28 11:37 pm",0.37,0.116,width:0.25)]
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(rows,shapes:shapes)).page,.chat)
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(rows,shapes:Array(shapes.dropLast()))).page,.unknown)
    }
    func testReferenceImagesRequireHashAndNeverBecomeLiveEvidence() throws {
        var input = frame(profile); input.origin = .referenceImage
        expectError(.invalidObservation) { _ = try ReferenceUIAnalyzer.analyze(input) }
        input.imageSHA256 = String(repeating:"a",count:64)
        for i in input.texts.indices { input.texts[i].source = .ocr }
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(input).origin,.referenceImage)
        input.origin = .liveDevice
        expectError(.wrongProvenance) { _ = try ReferenceUIAnalyzer.analyze(input) }
    }
    func testModelAuthoredLabelsAndInvalidCoordinatesAreRejected() {
        var input = frame(profile); input.texts[0].source = .modelGuess
        expectError(.invalidObservation) { _ = try ReferenceUIAnalyzer.analyze(input) }
        input = frame(profile); input.texts[0].rect.x = .nan
        expectError(.invalidObservation) { _ = try ReferenceUIAnalyzer.analyze(input) }
    }
    func testBodyCopyOfSectionNamesCannotPretendToBeSearchHeaders() throws {
        let rows = [text("query","fram",0.18,0.08),text("contacts","Contacts",0.03,0.61),
            text("groups","Group Chats",0.03,0.68),text("history","Chat History",0.03,0.75)]
        XCTAssertEqual(try ReferenceUIAnalyzer.analyze(frame(rows)).page,.unknown)
    }
}
