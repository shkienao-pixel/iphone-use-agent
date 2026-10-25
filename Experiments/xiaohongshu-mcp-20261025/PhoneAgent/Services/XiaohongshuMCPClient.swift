import Foundation

/// Fixed tool allowlist for the reviewed xpzouying MCP contract. Server tool
/// discovery never expands what Sela can call, even when the server has writes.
struct XiaohongshuMCPClient {
    enum Tool: String { case status = "check_login_status", qr = "get_login_qrcode", search = "search_feeds", detail = "get_feed_detail" }
    let endpoint: URL
    let token: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = Self.load
    static func endpoint(_ raw: String) throws -> URL {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path == "/mcp" || c.path == "/mcp/", let url = c.url else {
            throw AgentError.message("请填写你自己的 HTTPS MCP 地址，路径应为 /mcp。")
        }
        return url
    }
    func call(_ tool: Tool, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        _ = try Self.endpoint(endpoint.absoluteString)
        guard !token.isEmpty, token.utf8.count <= 4096, token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw XHSReadError.disconnected }
        var sessionID: String?, version = "2025-03-26"
        func rpc(_ method: String, id: Int?, params: [String: Any]?) async throws -> [String: Any] {
            try Task.checkCancellation()
            var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
            if let id { body["id"] = id }; if let params { body["params"] = params }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
            request.httpMethod = "POST"; request.httpShouldHandleCookies = false
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let result: (Data, HTTPURLResponse)
            do { result = try await transport(request) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); throw AgentError.message("小红书 MCP 连接未完成，请检查主机是否运行及网络连接。") }
            try Task.checkCancellation()
            let (data, response) = result
            guard response.url == endpoint, (200...299).contains(response.statusCode), data.count <= 2_097_152 else {
                throw AgentError.message("小红书 MCP 连接返回 HTTP \(response.statusCode)，请检查服务地址和连接凭据。")
            }
            if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
                guard value.utf8.count <= 2048, !value.isEmpty, value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw XHSReadError.invalidResponse }
                sessionID = value
            }
            if id == nil { return [:] }
            let object = try Self.decode(data)
            guard (object["id"] as? Int) == id, object["error"] == nil, let reply = object["result"] as? [String: Any] else { throw XHSReadError.invalidResponse }
            return reply
        }
        let hello = try await rpc("initialize", id: 1, params: ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "Sela", "version": "1.0"]])
        guard let negotiated = hello["protocolVersion"] as? String, ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(negotiated) else { throw XHSReadError.invalidResponse }
        version = negotiated
        _ = try await rpc("notifications/initialized", id: nil, params: nil)
        let result = try await rpc("tools/call", id: 2, params: ["name": tool.rawValue, "arguments": arguments])
        guard result["isError"] as? Bool != true else { throw XHSReadError.invalidResponse }
        // Do not echo arbitrary server errors or an accidentally returned key.
        let bytes = try JSONSerialization.data(withJSONObject: result)
        guard !String(decoding: bytes, as: UTF8.self).contains(token) else { throw XHSReadError.invalidResponse }
        return result
    }
    static func text(_ result: [String: Any]) -> String {
        (result["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func object(_ result: [String: Any]) throws -> [String: Any] {
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        guard let bytes = text(result).data(using: .utf8), let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw XHSReadError.invalidResponse }
        return object
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return value }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for event in text.components(separatedBy: "\n\n") {
            let raw = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if let bytes = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], value["id"] != nil { return value }
        }
        throw XHSReadError.invalidResponse
    }
    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 100
        let session = URLSession(configuration: config, delegate: XHSNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw XHSReadError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw XHSReadError.invalidResponse }
            data.append(byte)
            if byte == 10, (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream"), (try? decode(data)) != nil { break }
        }
        return (data, http)
    }
}
private final class XHSNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
