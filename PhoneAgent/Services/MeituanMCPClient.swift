import Foundation

struct MeituanMCPClient {
    let endpoint: URL
    let token: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = Self.load

    static func validatedEndpoint(_ value: String) throws -> URL {
        guard let c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", let host = c.host?.lowercased(), c.user == nil, c.password == nil, c.fragment == nil,
              ["meituan.com", "meituan.net", "dianping.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              c.port == nil || c.port == 443, let url = c.url else {
            throw AgentError.message("请填写美团官方提供的 HTTPS MCP 地址")
        }
        return url
    }

    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: MCPNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.message("美团服务未返回有效响应") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AgentError.message("美团响应过大，请稍后重试") }
            data.append(byte)
            // Streamable HTTP may keep the SSE stream open after its RPC result.
            if byte == 10, let text = String(data: data, encoding: .utf8), (text.hasSuffix("\n\n") || text.hasSuffix("\r\n\r\n")),
               (try? decode(data)) != nil { break }
        }
        return (data, http)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let text = (String(data: data, encoding: .utf8) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        for block in text.components(separatedBy: "\n\n") {
            let json = block.components(separatedBy: .newlines).filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], object["id"] != nil,
               object["result"] != nil || object["error"] != nil { return object }
        }
        throw AgentError.message("美团未返回有效的 MCP 响应")
    }

    func checkConnection() async throws -> [String] {
        _ = try Self.validatedEndpoint(endpoint.absoluteString)
        guard !token.contains("\n"), token.utf8.count <= 8192 else { throw AgentError.message("授权凭据格式不正确") }
        var sessionID: String?
        var protocolVersion = "2025-03-26"
        func rpc(_ method: String, id: Int?, params: [String: Any]?) async throws -> [String: Any] {
            var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
            if let id { body["id"] = id }; if let params { body["params"] = params }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
            request.httpMethod = "POST"; request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard response.url == endpoint, (200...299).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 { throw AgentError.message("美团授权未通过，请重新获取接入地址或授权凭据") }
                throw AgentError.message("美团 MCP 连接未完成，请核对地址和服务状态")
            }
            guard data.count <= 1_048_576 else { throw AgentError.message("美团响应过大") }
            if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
                guard !value.isEmpty, value.utf8.count <= 4096, value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
                    throw AgentError.message("美团返回的会话信息无效")
                }
                sessionID = value
            }
            if id == nil { return [:] }
            let object = try Self.decode(data)
            guard object["error"] == nil, (object["id"] as? Int) == id,
                  let result = object["result"] as? [String: Any] else { throw AgentError.message("美团未确认 MCP 请求，请检查服务权限") }
            return result
        }
        let initialized = try await rpc("initialize", id: 1, params: ["protocolVersion": protocolVersion, "capabilities": [:], "clientInfo": ["name": "Sela", "version": "1.0"]])
        guard let version = initialized["protocolVersion"] as? String, ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else {
            throw AgentError.message("美团 MCP 协议版本暂不兼容")
        }
        protocolVersion = version
        _ = try await rpc("notifications/initialized", id: nil, params: nil)
        let result = try await rpc("tools/list", id: 2, params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else { throw AgentError.message("美团未返回已开放的能力列表") }
        return tools.prefix(100).compactMap { tool in
            guard let name = tool["name"] as? String, !name.isEmpty, name.count <= 200,
                  token.isEmpty || !name.contains(token) else { return nil }
            return name
        }
    }
}

private final class MCPNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
