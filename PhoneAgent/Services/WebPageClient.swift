import Foundation

// The app calls the fixed extraction service, never the page URL itself.
struct WebPageClient {
    static let endpoint = URL(string: "https://api.tavily.com/extract")!
    let apiKey: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = WebSearchClient.load
    func request(url: URL) throws -> URLRequest {
        guard let value = WebPageDocument.canonicalURL(url) else { throw AgentError.message("请选择有效的 HTTP / HTTPS 来源链接") }
        guard !apiKey.isEmpty, apiKey.utf8.count <= 4096, apiKey.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) else { throw AgentError.message("请先保存有效的 Tavily Key；不会使用 Brave 或模型 Key") }
        var request = URLRequest(url: Self.endpoint); request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No query/chunks option: request the page text rather than reranked snippets.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["urls": [value], "extract_depth": "basic", "format": "text", "include_images": false, "include_favicon": false, "timeout": 20, "include_usage": false])
        return request
    }
    func read(url: URL) async throws -> WebPageDocument {
        try Task.checkCancellation(); let request = try request(url: url)
        let (data, response) = try await transport(request); try Task.checkCancellation()
        guard response.url == Self.endpoint else { throw AgentError.message("正文服务响应来自不匹配的接口，已丢弃") }
        guard (200...299).contains(response.statusCode) else { throw WebSearchClient.httpError(response.statusCode) }
        return try Self.decode(data, requestedURL: url, date: Date())
    }
    static func decode(_ data: Data, requestedURL: URL, date: Date) throws -> WebPageDocument {
        guard data.count <= 1_000_000, date.timeIntervalSince1970.isFinite, let requested = WebPageDocument.canonicalURL(requestedURL) else { throw AgentError.message("正文响应或链接超过范围，未保存") }
        struct Entry: Decodable { let url: String; let raw_content: String }
        struct Failure: Decodable { let url: String; let error: String? }
        struct Envelope: Decodable { let results: [Entry]; let failed_results: [Failure] }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data), value.results.count + value.failed_results.count == 1 else { throw AgentError.message("正文服务未返回完整的单链接结果，未替换已有材料") }
        if let failure = value.failed_results.first {
            guard let url = WebSearchBatch.sourceURL(failure.url), WebPageDocument.canonicalURL(url) == requested else { throw AgentError.message("正文服务返回了未确认的来源，已丢弃") }
            // Do not expose provider error bodies, URLs or credentials in errors.
            throw AgentError.message("服务未能提取该页正文；可直接打开来源核对，未绕过登录或访问限制")
        }
        guard let entry = value.results.first, let url = WebSearchBatch.sourceURL(entry.url), WebPageDocument.canonicalURL(url) == requested else { throw AgentError.message("返回正文与已确认的网页不匹配，已丢弃") }
        guard !entry.raw_content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.raw_content.count <= 120000 else { throw AgentError.message("正文为空或超过 120000 字，未截断保存") }
        return .init(url: requestedURL, text: entry.raw_content, retrievedAt: date)
    }
}
