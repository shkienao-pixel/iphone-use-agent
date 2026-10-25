import Foundation

public enum ReferencePageKind: String, Codable, Sendable {
    case searchResults, contactProfile, chat, personalTimeline, momentDetail, chats, discover, unknown
}
public struct ReferenceText: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var rect: UnitRect
    public var confidence: Float
    public var source: ControlSource
    public init(id: String, text: String, rect: UnitRect, confidence: Float, source: ControlSource) {
        self.id = id; self.text = text; self.rect = rect; self.confidence = confidence; self.source = source
    }
}
public enum ReferenceShapeKind: String, Codable, Sendable { case rectangle, contour }
public struct ReferenceShape: Codable, Equatable, Sendable {
    public var id: String
    public var kind: ReferenceShapeKind
    public var rect: UnitRect
    public var source: ControlSource
    public init(id: String, kind: ReferenceShapeKind, rect: UnitRect, source: ControlSource) {
        self.id = id; self.kind = kind; self.rect = rect; self.source = source
    }
}
public struct ReferenceUIFrame: Sendable {
    public var origin: EvidenceOrigin
    public var width: Int
    public var height: Int
    public var imageSHA256: String?
    public var texts: [ReferenceText]
    public var shapes: [ReferenceShape]
    public init(origin: EvidenceOrigin, width: Int, height: Int, imageSHA256: String? = nil,
                texts: [ReferenceText], shapes: [ReferenceShape] = []) {
        self.origin = origin; self.width = width; self.height = height; self.imageSHA256 = imageSHA256
        self.texts = texts; self.shapes = shapes
    }
}
public struct ReferenceUIAnchor: Codable, Equatable, Sendable {
    public var role: String
    public var sourceIDs: [String]
    public var rect: UnitRect
}
public struct ReferencePageEvidence: Codable, Equatable, Sendable {
    public var origin: EvidenceOrigin
    public var page: ReferencePageKind
    public var anchors: [ReferenceUIAnchor]
    public var contactCandidates: [ContactCandidate]
    public var accountReadback: String?
    public var queryReadback: String?
    public var gaps: [String]
}

/// Appearance study only. It rejects live input and produces neither controls,
/// ContactBinding, FrameStamp nor AtomicAction. Reference coordinates cannot be
/// promoted to current device evidence by this API.
public enum ReferenceUIAnalyzer {
    public static func analyze(_ frame: ReferenceUIFrame) throws -> ReferencePageEvidence {
        guard frame.origin != .liveDevice else { throw SkillError.wrongProvenance }
        guard frame.width > 0, frame.height > 0,
              Set(frame.texts.map(\.id) + frame.shapes.map(\.id)).count == frame.texts.count + frame.shapes.count,
              frame.texts.allSatisfy({ nonblank($0.id) && nonblank($0.text) && $0.rect.valid && $0.confidence.isFinite && (0...1).contains($0.confidence) &&
                  $0.source == (frame.origin == .fixture ? .fixture : .ocr) }),
              frame.shapes.allSatisfy({ nonblank($0.id) && $0.rect.valid && $0.source == (frame.origin == .fixture ? .fixture : .localPixels) })
        else { throw SkillError.invalidObservation }
        if frame.origin == .referenceImage {
            guard let hash = frame.imageSHA256, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw SkillError.invalidObservation }
        }
        let texts = frame.texts.filter { $0.confidence >= 0.5 }
        func normalized(_ value: String) -> String { value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func label(_ row: ReferenceText, _ aliases: [String], decorated: Bool = false) -> Bool {
            let value = normalized(row.text)
            return aliases.contains { alias in
                if value == alias { return true }
                guard decorated, value.hasSuffix(alias) else { return false }
                let prefix = value.dropLast(alias.count).trimmingCharacters(in: .whitespaces)
                return !prefix.isEmpty && prefix.count <= 3 && prefix.allSatisfy { "0oqdc•◦○◉□♧☏☎".contains($0) }
            }
        }
        func find(_ aliases: [String], decorated: Bool = false, region: (UnitRect) -> Bool = { _ in true }) -> [ReferenceText] {
            texts.filter { region($0.rect) && label($0, aliases, decorated: decorated) }
        }
        func one(_ rows: [ReferenceText]) -> ReferenceText? { rows.count == 1 ? rows[0] : nil }
        func anchor(_ role: String, _ row: ReferenceText) -> ReferenceUIAnchor { .init(role: role, sourceIDs: [row.id], rect: row.rect) }
        func shapeAnchor(_ role: String, _ shape: ReferenceShape) -> ReferenceUIAnchor { .init(role: role, sourceIDs: [shape.id], rect: shape.rect) }
        func centerX(_ rect: UnitRect) -> Double { rect.x + rect.width / 2 }
        func centerY(_ rect: UnitRect) -> Double { rect.y + rect.height / 2 }
        func heading(_ rect: UnitRect) -> Bool { (0.055...0.105).contains(rect.y) && (0.25...0.78).contains(centerX(rect)) }
        var matches: [ReferencePageEvidence] = []
        func add(_ page: ReferencePageKind, _ anchors: [ReferenceUIAnchor], candidates: [ContactCandidate] = [],
                 account: String? = nil, query: String? = nil, gaps: [String] = []) {
            matches.append(.init(origin: frame.origin, page: page, anchors: anchors, contactCandidates: candidates,
                                 accountReadback: account, queryReadback: query, gaps: gaps))
        }

        let tabs = [["chats", "微信"], ["contacts", "通讯录"], ["discover", "发现"], ["me", "我"]].compactMap {
            one(find($0, region: { $0.y > 0.90 }))
        }
        if tabs.count == 4 {
            let titles = texts.filter { row in
                heading(row.rect) && normalized(row.text).range(of: "^(weixin|wechat|chats|微信)( ?\\([0-9]+\\))?$", options: .regularExpression) != nil
            }
            if let title = one(titles) { add(.chats, [anchor("chatsHeading", title)] + tabs.map { anchor("bottomTab", $0) }) }
            if let title = one(find(["discover", "发现"], region: heading)),
               let moments = one(find(["moments", "朋友圈"], region: { (0.11...0.25).contains($0.y) })),
               let another = find(["channels", "视频号", "scan", "扫一扫", "mini programs", "小程序"], region: { $0.y > moments.rect.y + 0.03 && $0.y < 0.85 }).first {
                add(.discover, [anchor("discoverHeading",title), anchor("momentsEntry",moments),anchor("otherDiscoverEntry",another)] + tabs.map { anchor("bottomTab",$0) })
            }
        }

        if let contacts = one(find(["contacts", "联系人"], region: { (0.12...0.45).contains($0.y) && $0.x < 0.12 })),
           let groups = one(find(["group chats", "群聊"], region: { $0.y > contacts.rect.y + 0.03 && $0.y < 0.65 })),
           let history = one(find(["chat history", "聊天记录"], region: { $0.y > groups.rect.y + 0.03 && $0.y < 0.85 })),
           let query = one(texts.filter { $0.rect.y > 0.055 && $0.rect.y < contacts.rect.y - 0.015 && $0.rect.x > 0.10 && $0.rect.x < 0.70 && $0.rect.width > 0.035 }) {
            let rows = texts.filter { $0.rect.y >= contacts.rect.y + contacts.rect.height &&
                $0.rect.y + $0.rect.height < groups.rect.y && $0.rect.x > 0.12 }
            let candidates = rows.map { ContactCandidate(rowID: $0.id, section: .contacts, name: $0.text) }
            add(.searchResults, [anchor("contactsSection",contacts),anchor("groupsSection",groups),anchor("historySection",history),anchor("searchQuery",query)],
                candidates: candidates, query: query.text, gaps: ["contact_rows_are_candidates_not_identity"])
        }

        var momentsAnchors = find(["moments", "朋友圈"], region: { (0.22...0.75).contains($0.y) }).map { anchor("profileMoments",$0) }
        for upper in find(["mome", "momen"], region: { (0.22...0.75).contains($0.y) && $0.x < 0.2 }) {
            let lowers = find(normalized(upper.text) == "mome" ? ["nts"] : ["ts"], region: {
                abs($0.x - upper.rect.x) < 0.015 && $0.y >= upper.rect.y + upper.rect.height && $0.y - upper.rect.y < 0.04
            })
            if let lower = one(lowers) {
                momentsAnchors.append(.init(role: "profileMoments", sourceIDs: [upper.id,lower.id],
                    rect: .init(x: min(upper.rect.x,lower.rect.x), y: upper.rect.y,
                                width: max(upper.rect.x+upper.rect.width,lower.rect.x+lower.rect.width)-min(upper.rect.x,lower.rect.x),
                                height: lower.rect.y+lower.rect.height-upper.rect.y)))
            }
        }
        let accountRows = texts.filter { row in
            guard (0.12...0.4).contains(row.rect.y), let colon = row.text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
            return ["weixin id","wechat id","微信号"].contains(normalized(String(row.text[..<colon])))
        }
        if let accountRow = one(accountRows), let colon = accountRow.text.firstIndex(where: { $0 == ":" || $0 == "：" }),
           momentsAnchors.count == 1,
           let messages = one(find(["messages", "message", "发消息"], decorated: true, region: { (0.35...0.85).contains($0.y) && (0.3...0.75).contains(centerX($0)) })),
           let call = one(find(["voice or video call", "音视频通话", "语音或视频通话"], decorated: true, region: { $0.y > messages.rect.y + 0.025 && $0.y < 0.95 })) {
            var value = String(accountRow.text[accountRow.text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var sources = [accountRow.id]
            if value.isEmpty {
                let values = texts.filter { abs(centerY($0.rect) - centerY(accountRow.rect)) < 0.008 &&
                    $0.rect.x >= accountRow.rect.x + accountRow.rect.width - 0.005 && $0.id != accountRow.id }
                if let actual = one(values) { value = actual.text; sources.append(actual.id) }
            }
            let moments = momentsAnchors[0]
            if nonblank(value), accountRow.rect.y + accountRow.rect.height < moments.rect.y,
               moments.rect.y + moments.rect.height < messages.rect.y {
                add(.contactProfile, [.init(role:"accountField",sourceIDs:sources,rect:accountRow.rect),moments,
                    anchor("messagesEntry",messages),anchor("callEntry",call)], account: value,
                    gaps: ["reference_profile_is_not_live_identity_or_navigation_proof"])
            }
        }

        let details = one(find(["details", "详情"], region: heading))
        if let details, let comment = one(find(["comment:", "comment", "评论", "评论:"], region: { $0.y > 0.87 && $0.x < 0.4 })),
           texts.filter({ $0.rect.y > 0.18 && $0.rect.y < 0.87 && $0.rect.width > 0.3 }).count >= 3 {
            add(.momentDetail, [anchor("detailsHeading",details),anchor("commentComposer",comment)], gaps: ["author_post_identity_and_submit_state_unverified"])
        }

        if tabs.count != 4 && details == nil, let title = one(texts.filter({ heading($0.rect) })),
           let back = frame.shapes.first(where: { $0.kind == .contour && $0.rect.x < 0.1 && (0.06...0.12).contains($0.rect.y) &&
               (0.005...0.05).contains($0.rect.width) && (0.006...0.035).contains($0.rect.height) }) {
            let circles = frame.shapes.filter { shape in
                let r=shape.rect, ratio=r.width*Double(frame.width)/(r.height*Double(frame.height))
                return shape.kind == .contour && (0.89...0.96).contains(r.y) && (0.04...0.08).contains(r.width) && (0.8...1.2).contains(ratio)
            }
            if let left = circles.first(where: { centerX($0.rect) < 0.12 }),
               let middle = circles.first(where: { (0.80...0.90).contains(centerX($0.rect)) }),
               let right = circles.first(where: { centerX($0.rect) > 0.91 }) {
                add(.chat, [anchor("chatTitle",title),shapeAnchor("backOutline",back),shapeAnchor("leftComposerOutline",left),
                            shapeAnchor("middleComposerOutline",middle),shapeAnchor("rightComposerOutline",right)],
                    gaps: ["outline_roles_are_appearance_only_not_focus_or_send_proof"])
            }
        }

        let dates = texts.filter { row in
            row.rect.x < 0.20 && (0.4...0.90).contains(row.rect.y) && normalized(row.text).range(of:
                "^[0-9]{1,2} ?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)$", options: .regularExpression) != nil
        }
        if details == nil, tabs.count != 4, let date = dates.first {
            let avatars = frame.shapes.filter { shape in
                let r=shape.rect, ratio=r.width*Double(frame.width)/(r.height*Double(frame.height))
                return r.x > 0.65 && (0.25...0.52).contains(r.y) && r.width > 0.10 && r.width < 0.25 &&
                    (0.85...1.2).contains(ratio) && r.y+r.height < date.rect.y
            }
            if let avatar = avatars.first, let name = texts.first(where: {
                $0.rect.x > 0.25 && $0.rect.x+$0.rect.width <= avatar.rect.x+0.02 &&
                abs(centerY($0.rect)-centerY(avatar.rect)) < avatar.rect.height/2 && $0.rect.width > 0.15
            }) {
                add(.personalTimeline,[shapeAnchor("coverAvatarOutline",avatar),anchor("profileName",name),anchor("postDateLabel",date)],
                    gaps:["date_has_no_year_owner_and_post_details_unverified"])
            }
        }
        if matches.count == 1 { return matches[0] }
        return .init(origin: frame.origin, page: .unknown, anchors: [], contactCandidates: [], accountReadback: nil,
                     queryReadback: nil, gaps: [matches.isEmpty ? "insufficient_ui_anchors" : "conflicting_page_structures"])
    }
}
