import Foundation

/// Request contract from the official @meituan-travel/ht-ai package.
struct MeituanTravelClient {
    static let endpoint = URL(string: "https://mcp-open-cater.meituan.com/v1/api/voyage/openapi/query")!
    let token: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = MeituanMCPClient.load
    func request(query: String) throws -> URLRequest {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 4096, !token.isEmpty, token.utf8.count <= 8192,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw AgentError.message("请检查美团旅行凭据和查询文字") }
        var request = URLRequest(url: Self.endpoint); request.httpMethod = "POST"; request.timeoutInterval = 125
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The explicit question carries cities and dates; the city is only the official service's required fallback.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["city": "北京", "query": query, "originQuery": query, "channel": "meituan-developer"])
        return request
    }
    func query(_ query: String) async throws -> String {
        let (data, response) = try await transport(request(query: query)); try Task.checkCancellation()
        guard response.url == Self.endpoint, (200...299).contains(response.statusCode), data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], (object["code"] as? Int) == 0,
              let text = object["data"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains(token) else { throw AgentError.message("美团旅行查询未完成，请检查授权或稍后重试") }
        return String(text.prefix(12000))
    }
}
