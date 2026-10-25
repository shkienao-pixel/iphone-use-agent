import Foundation
import CryptoKit

enum XiaohongshuCollectionError: LocalizedError {
    case invalidTask, unavailable, conflictingTask, invalidObservation, invalidDocument, changedEvidence
    var errorDescription: String? {
        switch self {
        case .invalidTask: return "小红书采集参数无效；只支持当前已打开搜索结果的有界采集"
        case .unavailable: return "小红书采集存储不可用；原文件已保留，未覆盖"
        case .conflictingTask: return "采集任务 ID 已绑定不同条件，请使用原条件续作"
        case .invalidObservation: return "采集页面、屏幕共享或尺寸证据无效，已停止"
        case .invalidDocument: return "采集明细校验失败，不能据此生成统计"
        case .changedEvidence: return "补来源期间明细或待核验来源已变化；保留最新记录，没有覆盖或重按分享"
        }
    }
}

enum XiaohongshuCollectionField: String, Codable, CaseIterable {
    case title, body, author, likes, favorites, comments
}

struct XiaohongshuCollectionStops: Codable, Equatable {
    var maxPages = 20
    var maxNotes = 200
    var maxSeconds: Double = 120
    var maxRepeatedPages = 2
    func validate() throws {
        guard (1...200).contains(maxPages), (1...2000).contains(maxNotes),
              maxSeconds.isFinite, (1...7200).contains(maxSeconds),
              (1...10).contains(maxRepeatedPages) else { throw XiaohongshuCollectionError.invalidTask }
    }
}

struct XiaohongshuCollectionTask: Codable, Equatable, Identifiable {
    var id: String
    var keyword: String
    var range = "currentSearchResults"
    var profileID: String? = nil
    var sampleSize: Int
    var sort = "综合"
    var filters: [String] = []
    var fields: [XiaohongshuCollectionField] = [.title, .body, .author, .likes, .favorites, .comments]
    var stops = XiaohongshuCollectionStops()
    func validate() throws {
        try stops.validate()
        guard (8...96).contains(id.count), id.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        }), !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, keyword.count <= 120,
              ["currentSearchResults", "currentProfileNotes"].contains(range),
              range != "currentProfileNotes" || (profileID?.isEmpty == false && profileID!.count <= 96 && XiaohongshuPageAdapter.sortKey(sort) == "profile_order"),
              (1...stops.maxNotes).contains(sampleSize),
              ["general", "latest", "popular", "most_liked", "most_saved", "profile_order"].contains(XiaohongshuPageAdapter.sortKey(sort)),
              sort.count <= 40, filters.count <= 12,
              filters.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 80 }),
              Set(filters).count == filters.count, !fields.isEmpty,
              Set(fields).count == fields.count else { throw XiaohongshuCollectionError.invalidTask }
    }
}

enum XiaohongshuClipboardError: LocalizedError {
    case unsupported, foregroundRequired, unchanged, changedAgain, invalidLink
    var errorDescription: String? {
        switch self {
        case .unsupported: return "当前驱动没有接入受控分享与本机剪贴板，来源待补全"
        case .foregroundRequired: return "链接已复制；请回到本 App 前台读取这一次实际复制的来源"
        case .unchanged: return "复制后剪贴板没有实际变化，来源仍待核验；不会重复点击复制"
        case .changedAgain: return "复制后剪贴板又发生变化，不能把后来的内容绑定到该笔记"
        case .invalidLink: return "复制来源不是唯一、受信任的平台笔记链接，未计入唯一样本"
        }
    }
}
enum XiaohongshuScopeError: LocalizedError {
    case selectionMismatch
    var errorDescription: String? { "实际筛选面板中的已选排序/筛选与任务不一致；已回到结果，没有修改选项或开始采集" }
}

struct XiaohongshuClipboardSnapshot: Codable, Equatable {
    var changeCount: Int
    var text: String?
    var readAt: Date
}

struct XiaohongshuResolvedLink: Codable, Equatable {
    /// Includes the original URL and EVERY redirect, with the final URL last.
    var redirectChain: [String]
    var finalURL: String
}

struct XiaohongshuObservedPageEvidence: Codable, Equatable {
    var snapshot: PhoneUISnapshot
    var shareID: String
    var width: Int
    var height: Int
    var screenshotSHA256: String?
    var confirmedAt: Date? = nil
}

struct XiaohongshuSourceCapture: Codable, Equatable {
    var note: XiaohongshuObservedPageEvidence
    var sharePanel: XiaohongshuObservedPageEvidence
    var afterCopy: XiaohongshuObservedPageEvidence
    var restoredNote: XiaohongshuObservedPageEvidence
    var shareElementID: String
    var copyElementID: String
    var baselineChangeCount: Int
    var copiedChangeCount: Int
    var copiedAt: Date
    func validate() throws {
        let pages = [note, sharePanel, afterCopy, restoredNote]
        guard baselineChangeCount >= 0, copiedChangeCount > baselineChangeCount,
              copiedAt.timeIntervalSince1970.isFinite,
              pages.allSatisfy({ page in
                  page.shareID == note.shareID && page.snapshot.deviceKey == note.snapshot.deviceKey &&
                  page.width == note.width && page.height == note.height && page.width > 0 && page.height > 0 &&
                  !page.snapshot.blockingOverlay && page.snapshot.elements.allSatisfy({ $0.rect.valid }) &&
                  (page.screenshotSHA256 == nil || page.screenshotSHA256?.count == 64)
              }),
              XiaohongshuPageAdapter.identity(in: note.snapshot, noteOpenedFromResults: true)?.scene == "xiaohongshu.note",
              XiaohongshuPageAdapter.identity(in: sharePanel.snapshot)?.scene == "xiaohongshu.share",
              XiaohongshuPageAdapter.identity(in: restoredNote.snapshot, noteOpenedFromResults: true)?.scene == "xiaohongshu.note",
              XiaohongshuPageAdapter.shareControl(in: note.snapshot)?.id == shareElementID,
              note.snapshot.element(id: shareElementID)?.source != "local_visual" || note.screenshotSHA256?.count == 64,
              XiaohongshuPageAdapter.copyLinkControl(in: sharePanel.snapshot)?.id == copyElementID,
              (note.confirmedAt ?? note.snapshot.capturedAt) < (sharePanel.confirmedAt ?? sharePanel.snapshot.capturedAt),
              (sharePanel.confirmedAt ?? sharePanel.snapshot.capturedAt) < (afterCopy.confirmedAt ?? afterCopy.snapshot.capturedAt),
              (restoredNote.confirmedAt ?? restoredNote.snapshot.capturedAt) >= (afterCopy.confirmedAt ?? afterCopy.snapshot.capturedAt),
              copiedAt >= (afterCopy.confirmedAt ?? afterCopy.snapshot.capturedAt),
              XiaohongshuPageAdapter.sameNoteText(note.snapshot, restoredNote.snapshot) else {
            throw XiaohongshuCollectionError.invalidDocument
        }
    }
}

struct XiaohongshuSourceAttempt: Codable, Equatable, Identifiable {
    enum Stage: String, Codable { case openingShare, copyPending, copiedAwaitingRead, completed, uncertain }
    var id: UUID
    var note: XiaohongshuObservedPageEvidence
    var stage: Stage
    var updatedAt: Date
    var detail: String
    var capture: XiaohongshuSourceCapture? = nil
}

struct XiaohongshuScopeCapture: Codable, Equatable {
    var resultsBefore: XiaohongshuObservedPageEvidence
    var filterPanel: XiaohongshuObservedPageEvidence
    var resultsAfter: XiaohongshuObservedPageEvidence
    var selections: [XiaohongshuSelectionEvidence]
    var filterElementID: String
    var closeElementID: String
    func validate(task: XiaohongshuCollectionTask) throws {
        let before = resultsBefore, panel = filterPanel, after = resultsAfter
        guard [panel, after].allSatisfy({ $0.shareID == before.shareID && $0.snapshot.deviceKey == before.snapshot.deviceKey && $0.width == before.width && $0.height == before.height && !$0.snapshot.blockingOverlay }),
              XiaohongshuPageAdapter.identity(in: before.snapshot)?.scene == "xiaohongshu.results",
              XiaohongshuPageAdapter.identity(in: panel.snapshot)?.scene == "xiaohongshu.filters",
              XiaohongshuPageAdapter.identity(in: after.snapshot)?.scene == "xiaohongshu.results",
              XiaohongshuPageAdapter.filterControl(in: before.snapshot)?.id == filterElementID,
              XiaohongshuPageAdapter.closeFilterControl(in: panel.snapshot)?.id == closeElementID,
              (before.confirmedAt ?? before.snapshot.capturedAt) < (panel.confirmedAt ?? panel.snapshot.capturedAt),
              (panel.confirmedAt ?? panel.snapshot.capturedAt) < (after.confirmedAt ?? after.snapshot.capturedAt),
              XiaohongshuPageAdapter.selected(task.sort, snapshot: panel.snapshot, evidence: selections,
                screenshotSHA256: panel.screenshotSHA256, requiredRole: "sort") != nil,
              task.filters.allSatisfy({ XiaohongshuPageAdapter.selected($0, snapshot: panel.snapshot, evidence: selections,
                screenshotSHA256: panel.screenshotSHA256, requiredRole: "filter") != nil }) else {
            throw XiaohongshuCollectionError.invalidObservation
        }
        for page in [before, after] {
            let query = page.snapshot.elements.filter { $0.source == "ocr" && $0.rect.centerY < 0.18 && PhonePageAdapters.normalized($0.label) == PhonePageAdapters.normalized(task.keyword) }
            guard query.count == 1 else { throw XiaohongshuCollectionError.invalidObservation }
        }
    }
}

/// Displayed abbreviated counts are intervals, never fabricated precise values.
/// `1万+` has no known upper bound; missing values remain unknown.
struct XiaohongshuObservedCount: Codable, Equatable {
    enum Kind: String, Codable { case unknown, exact, lowerBound, interval }
    var kind: Kind
    var minimum: Int64?
    var maximum: Int64?
    var raw: String?
    static var unknown: Self { Self(kind: .unknown, minimum: nil, maximum: nil, raw: nil) }
    static func parse(_ raw: String) -> Self {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ",", with: "")
        guard let expression = try? NSRegularExpression(pattern: "^([0-9]+(?:\\.[0-9]+)?)(万|亿|w|k)?(\\+)?$"),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let numberRange = Range(match.range(at: 1), in: value),
              let number = Double(value[numberRange]), number.isFinite else {
            return Self(kind: .unknown, minimum: nil, maximum: nil, raw: raw)
        }
        let suffix = Range(match.range(at: 2), in: value).map { String(value[$0]) } ?? ""
        let factor: Double = ["万": 10000, "w": 10000, "亿": 100000000, "k": 1000][suffix] ?? 1
        let amount = number * factor
        guard amount >= 0, amount < 1e15 else { return Self(kind: .unknown, minimum: nil, maximum: nil, raw: raw) }
        if match.range(at: 3).location != NSNotFound {
            return Self(kind: .lowerBound, minimum: Int64(floor(amount)), maximum: nil, raw: raw)
        }
        if suffix.isEmpty {
            guard !value.contains(".") else { return Self(kind: .unknown, minimum: nil, maximum: nil, raw: raw) }
            return Self(kind: .exact, minimum: Int64(amount), maximum: Int64(amount), raw: raw)
        }
        let digits = String(value[numberRange]).split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        let resolution = factor / pow(10, Double(digits))
        // Cover both rounded and truncated display conventions; the UI does not
        // tell us which convention produced its abbreviated value.
        return Self(kind: .interval, minimum: Int64(max(0, floor(amount - resolution / 2))),
                    maximum: Int64(ceil(amount + resolution) - 1), raw: raw)
    }
    func validate() throws {
        guard minimum.map({ $0 >= 0 }) ?? true, maximum.map({ $0 >= 0 }) ?? true else { throw XiaohongshuCollectionError.invalidDocument }
        if let raw {
            guard Self.parse(raw) == self else { throw XiaohongshuCollectionError.invalidDocument }
        } else if self != .unknown { throw XiaohongshuCollectionError.invalidDocument }
        switch kind {
        case .unknown: guard minimum == nil && maximum == nil else { throw XiaohongshuCollectionError.invalidDocument }
        case .exact: guard let minimum, minimum == maximum else { throw XiaohongshuCollectionError.invalidDocument }
        case .lowerBound: guard minimum != nil && maximum == nil else { throw XiaohongshuCollectionError.invalidDocument }
        case .interval: guard let minimum, let maximum, minimum <= maximum else { throw XiaohongshuCollectionError.invalidDocument }
        }
    }
}

struct XiaohongshuSource: Codable, Equatable {
    var noteID: String
    var url: String
    var evidenceElementID: String
    var observedText: String
    var shareCapture: XiaohongshuSourceCapture? = nil
    var clipboard: XiaohongshuClipboardSnapshot? = nil
    var resolvedLink: XiaohongshuResolvedLink? = nil
    /// Only a platform note URL actually present in this observation establishes
    /// identity. Titles, body hashes, author IDs and short links do not.
    static func extract(from element: PhoneUIElement) -> Self? {
        guard element.source == "ocr", element.rect.valid,
              let expression = try? NSRegularExpression(pattern: "https://(?:www\\.)?xiaohongshu\\.com/(?:explore|discovery/item)/([a-fA-F0-9]{24})(?=$|[?\\s<>，。])(?:[?][^\\s<>]*)?"),
              let match = expression.firstMatch(in: element.label, range: NSRange(element.label.startIndex..., in: element.label)),
              let urlRange = Range(match.range(at: 0), in: element.label),
              let idRange = Range(match.range(at: 1), in: element.label) else { return nil }
        let observedURL = String(element.label[urlRange])
        guard let components = URLComponents(string: observedURL), components.scheme == "https",
              ["xiaohongshu.com", "www.xiaohongshu.com"].contains(components.host ?? ""),
              components.user == nil, components.password == nil, components.port == nil else { return nil }
        return Self(noteID: String(element.label[idRange]).lowercased(), url: observedURL,
                    evidenceElementID: element.id, observedText: element.label)
    }
    func validate(in elements: [PhoneUIElement]) throws {
        if let shareCapture, let clipboard {
            try shareCapture.validate()
            guard evidenceElementID == shareCapture.copyElementID,
                  clipboard.changeCount == shareCapture.copiedChangeCount,
                  clipboard.readAt >= shareCapture.copiedAt,
                  clipboard.text == observedText,
                  let copiedURL = Self.copiedURL(in: observedText),
                  let final = resolvedLink?.finalURL ?? (Self.directURL(copiedURL.absoluteString) == nil ? nil : copiedURL.absoluteString),
                  let direct = Self.directURL(final), direct.noteID == noteID, direct.url == url else {
                throw XiaohongshuCollectionError.invalidDocument
            }
            if let resolvedLink { try Self.validateResolution(resolvedLink, original: copiedURL) }
            return
        }
        guard shareCapture == nil && clipboard == nil && resolvedLink == nil else { throw XiaohongshuCollectionError.invalidDocument }
        guard let element = elements.first(where: { $0.id == evidenceElementID }),
              Self.extract(from: element) == self else { throw XiaohongshuCollectionError.invalidDocument }
    }
    static func permittedURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(),
              ["xiaohongshu.com", "www.xiaohongshu.com", "xhslink.com", "www.xhslink.com", "xhslink.cn"].contains(host) else { return false }
        return components.scheme == "https" || (components.scheme == "http" && ["xhslink.com", "www.xhslink.com"].contains(host))
    }
    static func directURL(_ raw: String) -> (noteID: String, url: String)? {
        guard let url = URL(string: raw), permittedURL(url), url.scheme == "https",
              ["xiaohongshu.com", "www.xiaohongshu.com"].contains(url.host?.lowercased() ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expression = try? NSRegularExpression(pattern: "^/(?:explore|discovery/item)/([a-fA-F0-9]{24})/?$"),
              let match = expression.firstMatch(in: components.path, range: NSRange(components.path.startIndex..., in: components.path)),
              let range = Range(match.range(at: 1), in: components.path) else { return nil }
        return (String(components.path[range]).lowercased(), raw)
    }
    static func copiedURL(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+") else { return nil }
        let urls = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ")],;"))
        }
        guard Set(urls).count == 1, let raw = urls.first, let url = URL(string: raw), permittedURL(url) else { return nil }
        return url
    }
    static func validateResolution(_ result: XiaohongshuResolvedLink, original: URL) throws {
        guard (1...6).contains(result.redirectChain.count), result.redirectChain.first == original.absoluteString,
              result.redirectChain.last == result.finalURL, Self.directURL(result.finalURL) != nil,
              result.redirectChain.allSatisfy({ URL(string: $0).map(permittedURL) == true }) else {
            throw XiaohongshuClipboardError.invalidLink
        }
    }
}

struct XiaohongshuNoteObservation: Codable, Equatable, Identifiable {
    var id: String { source.noteID }
    var source: XiaohongshuSource
    var observedAt: Date
    var pageScene: String
    var pageEvidence: [String]
    var elements: [PhoneUIElement]
    var matchedKeywords: [String]
    var title: String?
    var body: String?
    var author: String?
    var likes: XiaohongshuObservedCount
    var favorites: XiaohongshuObservedCount
    var comments: XiaohongshuObservedCount
    var unreadMedia: [String] = ["图片内容未读取", "视频与音频未读取", "评论正文未读取"]
    var textCoverage = "visible_ocr_fragments_only"
    var contentConclusionAllowed = false
    /// Missing on Build 73 archives; their original OCR evidence is retained.
    var pageAdapterVersion: Int? = nil
    var analysisText: String {
        [title, body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var visibleTextSHA256: String {
        SHA256.hash(data: Data(analysisText.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        try source.validate(in: elements)
        try likes.validate(); try favorites.validate(); try comments.validate()
        let snapshot = PhoneUISnapshot(deviceKey: "stored-evidence", scene: pageScene, elements: elements, capturedAt: observedAt)
        guard pageScene == "xiaohongshu.note", !pageEvidence.isEmpty else {
            throw XiaohongshuCollectionError.invalidDocument
        }
        let identity = XiaohongshuPageAdapter.identity(in: snapshot, noteOpenedFromResults: source.shareCapture != nil)
        guard identity?.scene == pageScene,
              pageAdapterVersion != 2 || identity?.evidence == pageEvidence,
              source.shareCapture == nil || source.shareCapture?.note.snapshot.elements == elements,
              pageEvidence.allSatisfy({ id in elements.contains(where: { $0.id == id }) }),
              observedAt.timeIntervalSince1970.isFinite, !contentConclusionAllowed,
              textCoverage == "visible_ocr_fragments_only", !unreadMedia.isEmpty,
              title.map({ $0 == XiaohongshuNoteEvidence.labelled(XiaohongshuNoteEvidence.titlePrefixes, elements: elements) }) ?? true,
              author.map({ $0 == XiaohongshuNoteEvidence.labelled(XiaohongshuNoteEvidence.authorPrefixes, elements: elements) }) ?? true,
              body.map({ $0 == XiaohongshuNoteEvidence.body(elements: elements) }) ?? true,
              likes.kind == .unknown || likes == XiaohongshuNoteEvidence.count(XiaohongshuNoteEvidence.likeLabels, elements: elements),
              favorites.kind == .unknown || favorites == XiaohongshuNoteEvidence.count(XiaohongshuNoteEvidence.favoriteLabels, elements: elements),
              comments.kind == .unknown || comments == XiaohongshuNoteEvidence.count(XiaohongshuNoteEvidence.commentLabels, elements: elements),
              matchedKeywords.allSatisfy({ keyword in elements.contains { $0.label.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }),
              elements.count <= 4000, Set(elements.map(\.id)).count == elements.count,
              elements.allSatisfy({ $0.rect.valid }) else { throw XiaohongshuCollectionError.invalidDocument }
    }
}

enum XiaohongshuNoteEvidence {
    static let titlePrefixes = ["标题：", "标题:", "Title: ", "Title:", "title: "]
    static let authorPrefixes = ["作者：", "作者:", "Author: ", "Author:", "author: "]
    static let likeLabels = ["点赞", "赞", "Like", "Likes", "likes", "like"]
    static let favoriteLabels = ["收藏", "Save", "Saves", "Saved", "save", "saves", "saved", "Favorites", "favorites"]
    static let commentLabels = ["评论", "Comments", "comments", "Comment", "comment"]
    static func labelled(_ prefixes: [String], elements: [PhoneUIElement]) -> String? {
        let matches = elements.compactMap { element -> String? in
            guard element.source == "ocr" else { return nil }
            for prefix in prefixes where element.label.hasPrefix(prefix) {
                let value = String(element.label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return nil
        }
        return matches.count == 1 ? matches[0] : nil
    }
    static func body(elements: [PhoneUIElement]) -> String? {
        if let explicit = labelled(["正文：", "正文:", "Body: ", "Body:", "body: "], elements: elements) { return explicit }
        let fragments = elements.filter { element in
            element.source == "ocr" && (0.28...0.78).contains(element.rect.centerY) &&
                XiaohongshuSource.extract(from: element) == nil &&
                !(likeLabels + favoriteLabels + commentLabels).contains(element.label) &&
                XiaohongshuObservedCount.parse(element.label).kind == .unknown
        }.sorted { $0.rect.y == $1.rect.y ? $0.rect.x < $1.rect.x : $0.rect.y < $1.rect.y }
        return fragments.isEmpty ? nil : fragments.map(\.label).joined(separator: "\n")
    }
    static func count(_ labels: [String], elements: [PhoneUIElement]) -> XiaohongshuObservedCount {
        if let explicit = labelled(labels.flatMap { [$0 + "：", $0 + ": ", $0 + ":"] }, elements: elements) { return .parse(explicit) }
        var values: [XiaohongshuObservedCount] = []
        for anchor in elements where labels.contains(anchor.label) && anchor.source == "ocr" {
            let neighbors = elements.filter { element in
                element.id != anchor.id && element.source == "ocr" &&
                abs(element.rect.centerY - anchor.rect.centerY) < 0.03 &&
                abs(element.rect.centerX - anchor.rect.centerX) < 0.12 &&
                XiaohongshuObservedCount.parse(element.label).kind != .unknown
            }
            if neighbors.count == 1 { values.append(.parse(neighbors[0].label)) }
        }
        return values.count == 1 ? values[0] : .unknown
    }
}

struct XiaohongshuAnalysisInput: Codable, Equatable {
    var noteID: String
    var visibleTextSHA256: String
    var partIndex: Int
    var partCount: Int
    var excerpt: String
    var key: String { noteID + ":" + visibleTextSHA256 + ":" + String(partIndex) }
}

struct XiaohongshuFragmentTopic: Codable, Equatable {
    var noteID: String
    var quote: String
    /// An extractive phrase actually contained in `quote`, not free-form claims.
    var topic: String
}

struct XiaohongshuAnalysisSegment: Codable, Equatable, Identifiable {
    var id: UUID
    var createdAt: Date
    var kind = "visible_fragment_topics"
    var scope = "visible_ocr_fragments_only"
    var inputs: [XiaohongshuAnalysisInput]
    var items: [XiaohongshuFragmentTopic]
    var excluded = ["unread_images", "unread_video_audio", "unread_comments", "unread_note_text"]
    func validate(notes: [XiaohongshuNoteObservation]) throws {
        guard kind == "visible_fragment_topics", scope == "visible_ocr_fragments_only",
              !inputs.isEmpty, inputs.count <= 50, Set(inputs.map(\.key)).count == inputs.count,
              items.count <= 100, !excluded.isEmpty, createdAt.timeIntervalSince1970.isFinite else {
            throw XiaohongshuCollectionError.invalidDocument
        }
        var texts: [String: [String]] = [:]
        for input in inputs {
            guard let note = notes.first(where: { $0.id == input.noteID && $0.visibleTextSHA256 == input.visibleTextSHA256 }),
                  !note.analysisText.isEmpty, input.partIndex >= 0, input.partCount > 0,
                  input.partIndex < input.partCount, !input.excerpt.isEmpty,
                  note.analysisText.contains(input.excerpt) else { throw XiaohongshuCollectionError.invalidDocument }
            let characters = Array(note.analysisText)
            let expectedParts = (characters.count + 999) / 1000
            guard input.partCount == expectedParts,
                  input.excerpt == String(characters[(input.partIndex * 1000)..<min(characters.count, (input.partIndex + 1) * 1000)]) else {
                throw XiaohongshuCollectionError.invalidDocument
            }
            texts[input.noteID, default: []].append(input.excerpt)
        }
        for item in items {
            guard let fragments = texts[item.noteID], !item.quote.isEmpty, item.quote.count <= 500,
                  fragments.contains(where: { $0.contains(item.quote) }),
                  (2...40).contains(item.topic.count), item.quote.contains(item.topic) else {
                throw XiaohongshuCollectionError.invalidDocument
            }
        }
    }
}

struct XiaohongshuPendingObservation: Codable, Equatable, Identifiable {
    var id: UUID
    var observedAt: Date
    var reason: String
    var elements: [PhoneUIElement]
    var pageScene: String
    var sourceCapture: XiaohongshuSourceCapture? = nil
}

struct XiaohongshuCollectionPage: Codable, Equatable {
    var number: Int
    var observedAt: Date
    /// Navigation/overlap signature only. This is NEVER a note ID.
    var viewport: String
    var elementCount: Int
    var scopeEvidence: [String]
    var elements: [PhoneUIElement]
    var selectionEvidence: [XiaohongshuSelectionEvidence] = []
    var screenshotSHA256: String? = nil
    var scopeVersion = 2
    var scopeCapture: XiaohongshuScopeCapture? = nil
}

struct XiaohongshuCollectionCheckpoint: Codable, Equatable {
    var deviceKey: String
    var shareID: String
    var width: Int
    var height: Int
    var visitedCandidateKeys: [String] = []
    var viewport = ""
    var repeatedPages = 0
    var attemptedNotes = 0
    var readCount = 0
    var scrollCount = 0
    var noteOpenCount = 0
    var pageStartUniqueCount = 0
    var pageRepeatedViewport = false
    var scopeCapture: XiaohongshuScopeCapture? = nil
    var elapsedSeconds: Double = 0
}

struct XiaohongshuCollectionEvent: Codable, Equatable {
    var at: Date
    var kind: String
    var detail: String
}

struct XiaohongshuCountStatistics: Codable, Equatable {
    var exact = 0
    var intervals = 0
    var lowerBounds = 0
    var missing = 0
    /// Sums cover observed values only. Missing values are not counted as zero.
    var observedMinimum: Int64?
    var observedMaximum: Int64?
    var exactTotal: Int64?
    var distribution: [String: Int] = [:]
    var distributionDenominator = 0
    var missingFraction: Double?
    static func calculate(_ values: [XiaohongshuObservedCount]) -> Self {
        var result = Self()
        var low: Int64 = 0, high: Int64 = 0
        var hasObserved = false, unbounded = false
        for value in values {
            switch value.kind {
            case .unknown: result.missing += 1
            case .exact: result.exact += 1
            case .interval: result.intervals += 1
            case .lowerBound: result.lowerBounds += 1
            }
            if let minimum = value.minimum { low += minimum; hasObserved = true }
            if let maximum = value.maximum { high += maximum }
            else if value.kind != .unknown { unbounded = true }
            let bucket: String
            if value.kind == .unknown { bucket = "missing" }
            else if let minimum = value.minimum {
                if minimum >= 10000 { bucket = "10000+" }
                else if let maximum = value.maximum {
                    if minimum == 0 && maximum == 0 { bucket = "0" }
                    else if minimum >= 1 && maximum <= 99 { bucket = "1-99" }
                    else if minimum >= 100 && maximum <= 999 { bucket = "100-999" }
                    else if minimum >= 1000 && maximum <= 9999 { bucket = "1000-9999" }
                    else { bucket = "cross_bucket_range" }
                } else { bucket = "cross_bucket_range" }
            } else { bucket = "missing" }
            result.distribution[bucket, default: 0] += 1
        }
        result.observedMinimum = hasObserved ? low : nil
        result.observedMaximum = hasObserved && !unbounded ? high : nil
        result.exactTotal = !values.isEmpty && result.exact == values.count ? low : nil
        result.distributionDenominator = values.count
        result.missingFraction = values.isEmpty ? nil : Double(result.missing) / Double(values.count)
        return result
    }
}

struct XiaohongshuCollectionStatistics: Codable, Equatable {
    var uniqueSamples: Int
    var pendingObservations: Int
    var duplicateObservations: Int
    var pagesRead: Int
    var requestedSamples: Int
    var sampleShortfall: Int
    var requestedRange: String
    var scope = "当前已核验关键词/主页身份与选中排序/筛选的可见样本；不能外推全站总体"
    var conditionEvidence = "selected_state_evidence_required"
    var startedAt: Date
    var lastCollectedAt: Date?
    var missingFields: [String: Int]
    var likes: XiaohongshuCountStatistics
    var favorites: XiaohongshuCountStatistics
    var comments: XiaohongshuCountStatistics
    var unreadMediaNotes: Int
    var keywordHitSamples: Int
    var keywordHitFraction: Double?
}

private struct HistoricalScopeValidationContext {
    private struct Entry: Equatable {
        var task: XiaohongshuCollectionTask
        var scope: XiaohongshuScopeCapture
    }
    private var lastSuccess: Entry?
    init() {}
    mutating func validate(_ scope: XiaohongshuScopeCapture, task: XiaohongshuCollectionTask) throws {
        let entry = Entry(task: task, scope: scope)
        if lastSuccess == entry { return }
        try scope.validate(task: task)
        lastSuccess = entry
    }
}

struct XiaohongshuCollectionRun: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case running, sampleReached, boundedStop, paused, cancelled, failed }
    var id: String { task.id }
    var version = 1
    var task: XiaohongshuCollectionTask
    var startedAt: Date
    var updatedAt: Date
    var status: Status = .running
    var stopReason = ""
    var notes: [XiaohongshuNoteObservation] = []
    var noteRevisions: [XiaohongshuNoteObservation] = []
    var analysisSegments: [XiaohongshuAnalysisSegment] = []
    var sourceAttempts: [XiaohongshuSourceAttempt] = []
    var pending: [XiaohongshuPendingObservation] = []
    var pages: [XiaohongshuCollectionPage] = []
    var duplicateObservations = 0
    var events: [XiaohongshuCollectionEvent] = []
    var checkpoint: XiaohongshuCollectionCheckpoint?
    var readingBudgetReceipt: String {
        let budget = String(format: "%.0f", task.stops.maxSeconds)
        guard let seconds = checkpoint?.elapsedSeconds, seconds.isFinite, seconds >= 0 else {
            return "运行预算 \(budget) 秒；累计运行及剩余时间未建立，不能据此声称读满指定时长。"
        }
        let elapsed = String(format: "%.1f", seconds)
        let remaining = String(format: "%.1f", max(0, task.stops.maxSeconds - seconds))
        return "运行预算 \(budget) 秒，累计运行 \(elapsed) 秒，剩余 \(remaining) 秒；含加载和网络等待，不含暂停间隔，不等同有效阅读时长。"
    }
    /// Recompute from the ID-deduplicated evidence; cached/model totals are never
    /// accepted as authority. Analysis can consume this export independently.
    func statistics() throws -> XiaohongshuCollectionStatistics {
        try validate()
        var missing: [String: Int] = [:]
        for field in task.fields {
            missing[field.rawValue] = notes.filter { note in
                switch field {
                case .title: return note.title == nil
                case .body: return note.body == nil
                case .author: return note.author == nil
                case .likes: return note.likes.kind == .unknown
                case .favorites: return note.favorites.kind == .unknown
                case .comments: return note.comments.kind == .unknown
                }
            }.count
        }
        var result = XiaohongshuCollectionStatistics(uniqueSamples: notes.count, pendingObservations: pending.count,
            duplicateObservations: duplicateObservations, pagesRead: pages.count, requestedSamples: task.sampleSize,
            sampleShortfall: max(0, task.sampleSize - notes.count), requestedRange: task.range,
            startedAt: startedAt, lastCollectedAt: (notes.map(\.observedAt) + pending.map(\.observedAt)).max(), missingFields: missing,
            likes: .calculate(notes.map(\.likes)), favorites: .calculate(notes.map(\.favorites)),
            comments: .calculate(notes.map(\.comments)), unreadMediaNotes: notes.filter { !$0.unreadMedia.isEmpty }.count,
            keywordHitSamples: notes.filter { $0.matchedKeywords.contains(task.keyword) }.count,
            keywordHitFraction: notes.isEmpty ? nil : Double(notes.filter { $0.matchedKeywords.contains(task.keyword) }.count) / Double(notes.count))
        if pages.isEmpty {
            result.scope = "尚未取得当前任务范围的选中态证明；只报告已保存明细，不追认范围完成"
            result.conditionEvidence = "not_verified_no_pages"
        } else if pages.contains(where: { $0.scopeVersion < 2 }) {
            result.scope = "包含旧版未证明排序/筛选选中态的可见样本；原始范围证据保留，不能追认严格范围或外推全站总体"
            result.conditionEvidence = "legacy_visible_labels_only_included; selected_state_not_retroactively_verified"
        } else if pages.allSatisfy({ $0.scopeVersion == 3 }) {
            result.scope = "当前已核验关键词、All 分类红下划线与原生 Latest 对比选中态的可见笔记样本；排除 AI 回答区，不能外推全站总体"
            result.conditionEvidence = "native_all_category_and_latest_sort_verified_from_current_pixels"
        } else if pages.contains(where: { page in
            guard page.scopeVersion == 2 else { return false }
            let snapshot = PhoneUISnapshot(deviceKey: "stored-page", scene: "xiaohongshu.results", elements: page.elements, capturedAt: page.observedAt)
            return XiaohongshuPageAdapter.nativeLatestLayout(in: snapshot) != nil
        }) {
            result.scope = "保留旧版排序/筛选选中证据；出现 All/Top/Latest 文字不追认新版原生 All/Latest 像素范围，不能外推全站总体"
            result.conditionEvidence = "legacy_sort_filter_scope_only; native_all_latest_not_retroactively_verified"
        } else { result.conditionEvidence = "selected_state_verified_from_observed_controls" }
        return result
    }
    func validate() throws {
        try validatePersistedAnalysisState(reusingImmutableEvidence: false)
    }

    /// Only the same-file value wrapper calls this after copying its own raw
    /// fields unchanged. No Boolean or evidence witness is exposed to callers.
    fileprivate func validateAfterAppendingAnalysis() throws {
        try validatePersistedAnalysisState(reusingImmutableEvidence: true)
    }

    private func validatePersistedAnalysisState(reusingImmutableEvidence: Bool) throws {
        try task.validate()
        guard version == 1, notes.count <= task.stops.maxNotes, pending.count <= task.stops.maxNotes,
              Set(notes.map(\.id)).count == notes.count, noteRevisions.count <= task.stops.maxNotes,
              analysisSegments.count <= 5000, Set(analysisSegments.map(\.id)).count == analysisSegments.count,
              sourceAttempts.count <= task.stops.maxNotes,
              Set(sourceAttempts.map(\.id)).count == sourceAttempts.count,
              duplicateObservations >= 0,
              startedAt.timeIntervalSince1970.isFinite, updatedAt >= startedAt,
              pages.count <= task.stops.maxPages, events.count <= 5000 else { throw XiaohongshuCollectionError.invalidDocument }
        if !reusingImmutableEvidence {
            for note in notes { try note.validate() }
            for note in noteRevisions { try note.validate() }
        }
        if reusingImmutableEvidence {
            guard let segment = analysisSegments.last else { throw XiaohongshuCollectionError.invalidDocument }
            try segment.validate(notes: notes + noteRevisions)
        } else {
            for segment in analysisSegments { try segment.validate(notes: notes + noteRevisions) }
        }
        if !reusingImmutableEvidence {
            for (attemptIndex, attempt) in sourceAttempts.enumerated() {
                guard attempt.updatedAt.timeIntervalSince1970.isFinite, !attempt.detail.isEmpty,
                      !attempt.note.snapshot.blockingOverlay,
                      XiaohongshuPageAdapter.identity(in: attempt.note.snapshot, noteOpenedFromResults: true)?.scene == "xiaohongshu.note" else {
                    throw XiaohongshuCollectionError.invalidDocument
                }
                if let capture = attempt.capture {
                    let alreadyValidated = notes.indices.contains(attemptIndex) &&
                        notes[attemptIndex].source.shareCapture == capture
                    if !alreadyValidated { try capture.validate() }
                }
            }
            for value in pending {
                guard value.observedAt.timeIntervalSince1970.isFinite, !value.reason.isEmpty,
                      value.pageScene == "xiaohongshu.note", value.elements.count <= 4000,
                      value.elements.allSatisfy({ $0.rect.valid }),
                      Set(value.elements.map(\.id)).count == value.elements.count else {
                    throw XiaohongshuCollectionError.invalidDocument
                }
                if let capture = value.sourceCapture {
                    try capture.validate()
                    guard capture.note.snapshot.elements == value.elements else { throw XiaohongshuCollectionError.invalidDocument }
                }
            }
        }
        guard Set(pending.map(\.id)).count == pending.count else { throw XiaohongshuCollectionError.invalidDocument }
        if !reusingImmutableEvidence {
            var historicalScope = HistoricalScopeValidationContext()
            for (index, page) in pages.enumerated() {
                let snapshot = PhoneUISnapshot(deviceKey: "stored-page", scene: "xiaohongshu.results", elements: page.elements, capturedAt: page.observedAt)
                let expectedScene = task.range == "currentProfileNotes" ? "xiaohongshu.profile" : "xiaohongshu.results"
                let sortLabel = task.range == "currentProfileNotes" ? "笔记" : task.sort
                let selected = XiaohongshuPageAdapter.selected(sortLabel, snapshot: snapshot,
                    evidence: page.selectionEvidence, screenshotSHA256: page.screenshotSHA256,
                    requiredRole: task.range == "currentProfileNotes" ? nil : "sort") ??
                    (task.range == "currentProfileNotes" ? XiaohongshuPageAdapter.selected("notes", snapshot: snapshot,
                        evidence: page.selectionEvidence, screenshotSHA256: page.screenshotSHA256) : nil)
                let capturedScopeValid = page.scopeCapture.map { (try? historicalScope.validate($0, task: task)) != nil } == true
                let nativeScopeValid = page.scopeVersion == 3 && task.range == "currentSearchResults" &&
                    XiaohongshuPageAdapter.sortKey(task.sort) == "latest" && task.filters.isEmpty &&
                    XiaohongshuPageAdapter.nativeLatestScopeEvidence(snapshot: snapshot, evidence: page.selectionEvidence,
                        screenshotSHA256: page.screenshotSHA256) != nil
                let carriesNativeProof = (page.selectionEvidence + (page.scopeCapture?.selections ?? [])).contains {
                    $0.method == .neutralTextAndRedUnderline || $0.method == .nativeLatestContrastChip
                }
                guard XiaohongshuPageAdapter.identity(in: snapshot)?.scene == expectedScene,
                      !carriesNativeProof || page.scopeVersion == 3,
                      [1, 2, 3].contains(page.scopeVersion), page.scopeVersion != 3 || nativeScopeValid,
                      page.scopeVersion == 1 || selected != nil || capturedScopeValid,
                      page.scopeVersion == 1 || capturedScopeValid || task.filters.allSatisfy({ XiaohongshuPageAdapter.selected($0, snapshot: snapshot, evidence: page.selectionEvidence, screenshotSHA256: page.screenshotSHA256) != nil }),
                      page.number == index + 1, page.elements.allSatisfy({ $0.rect.valid }),
                      Set(page.elements.map(\.id)).count == page.elements.count,
                      page.scopeEvidence.allSatisfy({ id in page.elements.contains { $0.id == id } }),
                      !page.scopeEvidence.isEmpty, page.elementCount == page.elements.count,
                      page.elements.count <= 4000, page.observedAt.timeIntervalSince1970.isFinite else {
                    throw XiaohongshuCollectionError.invalidDocument
                }
            }
            if let checkpoint {
                if let scope = checkpoint.scopeCapture { try historicalScope.validate(scope, task: task) }
                guard !checkpoint.deviceKey.isEmpty, !checkpoint.shareID.isEmpty,
                      checkpoint.width > 0, checkpoint.height > 0,
                      checkpoint.elapsedSeconds.isFinite, checkpoint.elapsedSeconds >= 0,
                      checkpoint.readCount >= 0, checkpoint.scrollCount >= 0,
                      checkpoint.noteOpenCount >= 0, checkpoint.attemptedNotes >= 0,
                      checkpoint.visitedCandidateKeys.count <= 4000 else { throw XiaohongshuCollectionError.invalidDocument }
            }
        }
    }
}

extension XiaohongshuCollectionRun {
    private enum CodingKeys: String, CodingKey {
        case version, task, startedAt, updatedAt, status, stopReason, notes, noteRevisions, analysisSegments
        case sourceAttempts, pending, pages, duplicateObservations, events, checkpoint
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        version = try value.decodeIfPresent(Int.self, forKey: .version) ?? 1
        task = try value.decode(XiaohongshuCollectionTask.self, forKey: .task)
        startedAt = try value.decode(Date.self, forKey: .startedAt)
        updatedAt = try value.decode(Date.self, forKey: .updatedAt)
        status = try value.decodeIfPresent(Status.self, forKey: .status) ?? .paused
        stopReason = try value.decodeIfPresent(String.self, forKey: .stopReason) ?? "legacy_archive"
        notes = try value.decodeIfPresent([XiaohongshuNoteObservation].self, forKey: .notes) ?? []
        noteRevisions = try value.decodeIfPresent([XiaohongshuNoteObservation].self, forKey: .noteRevisions) ?? []
        analysisSegments = try value.decodeIfPresent([XiaohongshuAnalysisSegment].self, forKey: .analysisSegments) ?? []
        sourceAttempts = try value.decodeIfPresent([XiaohongshuSourceAttempt].self, forKey: .sourceAttempts) ?? []
        pending = try value.decodeIfPresent([XiaohongshuPendingObservation].self, forKey: .pending) ?? []
        pages = try value.decodeIfPresent([XiaohongshuCollectionPage].self, forKey: .pages) ?? []
        duplicateObservations = try value.decodeIfPresent(Int.self, forKey: .duplicateObservations) ?? 0
        events = try value.decodeIfPresent([XiaohongshuCollectionEvent].self, forKey: .events) ?? []
        checkpoint = try value.decodeIfPresent(XiaohongshuCollectionCheckpoint.self, forKey: .checkpoint)
    }
}

extension XiaohongshuCollectionPage {
    private enum CodingKeys: String, CodingKey {
        case number, observedAt, viewport, elementCount, scopeEvidence, elements, selectionEvidence, screenshotSHA256, scopeVersion, scopeCapture
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        number = try value.decode(Int.self, forKey: .number)
        observedAt = try value.decode(Date.self, forKey: .observedAt)
        viewport = try value.decode(String.self, forKey: .viewport)
        elementCount = try value.decode(Int.self, forKey: .elementCount)
        scopeEvidence = try value.decode([String].self, forKey: .scopeEvidence)
        elements = try value.decode([PhoneUIElement].self, forKey: .elements)
        selectionEvidence = try value.decodeIfPresent([XiaohongshuSelectionEvidence].self, forKey: .selectionEvidence) ?? []
        screenshotSHA256 = try value.decodeIfPresent(String.self, forKey: .screenshotSHA256)
        scopeVersion = try value.decodeIfPresent(Int.self, forKey: .scopeVersion) ?? 1
        scopeCapture = try value.decodeIfPresent(XiaohongshuScopeCapture.self, forKey: .scopeCapture)
    }
}


/// Stored-value validation only, never fresh UI/input/scope authority. This is
/// deliberately not Codable: every externally supplied Run enters through the
/// full validator, including values decoded by the Store's original Document.
struct ValidatedXiaohongshuCollectionRun {
    private let storedValue: XiaohongshuCollectionRun
    var value: XiaohongshuCollectionRun { storedValue }

    init(validating value: XiaohongshuCollectionRun) throws {
        try value.validate()
        storedValue = value
    }

    private init(knownValid value: XiaohongshuCollectionRun) {
        storedValue = value
    }

    func appendingAnalysis(_ segment: XiaohongshuAnalysisSegment, updatedAt: Date) throws -> Self {
        var next = storedValue
        next.analysisSegments.append(segment)
        next.updatedAt = updatedAt
        try next.validateAfterAppendingAnalysis()
        return Self(knownValid: next)
    }
}
