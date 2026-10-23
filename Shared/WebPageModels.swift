import Foundation

struct WebPageExcerpt: Codable, Equatable {
    let url: URL
    let text: String
    let start: Int
    let totalCharacters: Int
    let retrievedAt: Date
    func validate() throws {
        guard (1...120000).contains(totalCharacters), start >= 0, start <= totalCharacters,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 12000,
              start + text.count <= totalCharacters, retrievedAt.timeIntervalSince1970.isFinite,
              WebPageDocument.canonicalURL(url) != nil else { throw AgentError.message("网页正文片段或来源信息无效，未用于回答") }
    }
    var label: String { "Tavily 正文第 \(start + 1)–\(start + text.count) 字 / 提取结果共 \(totalCharacters) 字 · 接收时间 \(ISO8601DateFormatter().string(from: retrievedAt))（不是网页发布时间）" }
}
struct WebPageDocument {
    let url: URL
    let text: String
    let retrievedAt: Date
    func excerpt(start: Int, length: Int) throws -> WebPageExcerpt {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 120000,
              start >= 0, start < text.count, (1...12000).contains(length), length <= text.count - start else { throw AgentError.message("请选择正文中连续的 1–12000 字，不能超出提取结果") }
        let value = WebPageExcerpt(url: url, text: String(text.dropFirst(start).prefix(length)), start: start, totalCharacters: text.count, retrievedAt: retrievedAt)
        try value.validate(); return value
    }
    static func canonicalURL(_ url: URL) -> String? {
        guard WebSearchBatch.sourceURL(url.absoluteString) != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        parts.fragment = nil; parts.host = parts.host?.lowercased(); parts.scheme = parts.scheme?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.url?.absoluteString
    }
}
extension WebSearchBatch {
    func validatePageEvidence() throws {
        for source in sources {
            if let excerpt = source.pageExcerpt {
                try excerpt.validate()
                guard WebPageDocument.canonicalURL(excerpt.url) == WebPageDocument.canonicalURL(source.url) else { throw AgentError.message("正文来源与检索链接不匹配") }
            }
        }
    }
    func usingPage(sourceID: Int, excerpt: WebPageExcerpt?) throws -> Self {
        try validateResearchEvidence(); try validatePageEvidence()
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { throw AgentError.message("检索来源已变化，请重新选择") }
        if let excerpt {
            try excerpt.validate()
            guard WebPageDocument.canonicalURL(excerpt.url) == WebPageDocument.canonicalURL(sources[index].url) else { throw AgentError.message("正文来源与已确认链接不匹配") }
        }
        var changed = sources; changed[index].pageExcerpt = excerpt
        let value = Self(query: query, provider: provider, freshness: freshness, retrievedAt: retrievedAt, sources: changed, omitted: omitted, plan: plan, completedQueries: completedQueries, researchTrail: researchTrail, researchStop: researchStop)
        guard value.referenceText.count <= 40000 else { throw AgentError.message("当前模型材料超过 40000 字，请减少所选正文长度；未截断或替换已有材料") }
        return value
    }
}
