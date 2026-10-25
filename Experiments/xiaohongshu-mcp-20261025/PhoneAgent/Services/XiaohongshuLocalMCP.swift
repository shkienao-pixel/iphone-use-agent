import Foundation

/// In-process MCP host. Sela is its only client; no LAN/public listener, helper
/// process, downloaded executable or server credential is needed on iPhone.
@MainActor final class XiaohongshuLocalMCP {
    typealias Handler = @MainActor (XiaohongshuMCPClient.Tool, [String: Any]) async throws -> [String: Any]
    private let handler: Handler
    private var initialized = false
    private var awaitingInitialized = false
    private var running = false
    init(handler: @escaping Handler) { self.handler = handler }

    func call(_ tool: XiaohongshuMCPClient.Tool, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard !running else { throw AgentError.message("手机正在处理一个小红书请求，请稍后再试。") }
        running = true
        defer { running = false; initialized = false; awaitingInitialized = false }
        _ = try await handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        _ = try await handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let envelope = try await handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool.rawValue, "arguments": arguments]])
        guard let result = envelope?["result"] as? [String: Any] else { throw XHSReadError.invalidResponse }
        return result
    }

    func handle(_ request: [String: Any]) async throws -> [String: Any]? {
        try Task.checkCancellation()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { throw XHSReadError.invalidQuery }
        let params = request["params"] as? [String: Any] ?? [:]
        func reply(_ result: [String: Any]) throws -> [String: Any] {
            guard let id = request["id"], id is String || id is Int else { throw XHSReadError.invalidQuery }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        }
        if method == "initialize" {
            initialized = false; awaitingInitialized = true
            return try reply(["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]], "serverInfo": ["name": "Sela iPhone Xiaohongshu", "version": "1"]])
        }
        if method == "notifications/initialized" {
            guard awaitingInitialized, request["id"] == nil else { throw XHSReadError.invalidQuery }
            initialized = true; awaitingInitialized = false; return nil
        }
        guard initialized else { throw XHSReadError.invalidQuery }
        if method == "tools/list" {
            let tools = [XiaohongshuMCPClient.Tool.status, .search, .detail].map { tool -> [String: Any] in
                var properties: [String: Any] = [:], required: [String] = []
                if tool == .search { properties = ["keyword": ["type": "string", "maxLength": 120]]; required = ["keyword"] }
                if tool == .detail {
                    properties = ["feed_id": ["type": "string", "pattern": "^[0-9a-fA-F]{24}$"], "xsec_token": ["type": "string", "maxLength": 4096], "load_all_comments": ["type": "boolean"]]
                    required = ["feed_id", "xsec_token"]
                }
                return ["name": tool.rawValue, "description": "在本机网页会话中读取，已加载范围有限。", "inputSchema": ["type": "object", "properties": properties, "required": required]]
            }
            return try reply(["tools": tools])
        }
        guard method == "tools/call", let name = params["name"] as? String,
              let tool = XiaohongshuMCPClient.Tool(rawValue: name), tool != .qr,
              let args = params["arguments"] as? [String: Any], JSONSerialization.isValidJSONObject(args),
              try JSONSerialization.data(withJSONObject: args).count <= 8192 else { throw XHSReadError.invalidQuery }
        switch tool {
        case .status: guard args.isEmpty else { throw XHSReadError.invalidQuery }
        case .search:
            guard Set(args.keys).isSubset(of: ["keyword", "filters"]), let value = args["keyword"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 120 else { throw XHSReadError.invalidQuery }
            if let filters = args["filters"] as? [String: String] {
                guard filters == ["sort_by": "综合", "note_type": "不限"] else { throw XHSReadError.invalidQuery }
            } else if args["filters"] != nil { throw XHSReadError.invalidQuery }
        case .detail:
            guard Set(args.keys).isSubset(of: ["feed_id", "xsec_token", "load_all_comments", "limit", "click_more_replies", "reply_limit", "scroll_speed"]),
                  let id = args["feed_id"] as? String, id.range(of: "^[0-9a-fA-F]{24}$", options: .regularExpression) != nil,
                  let ref = args["xsec_token"] as? String, !ref.isEmpty, ref.count <= 4096 else { throw XHSReadError.invalidQuery }
            if let limit = args["limit"] { guard limit as? Int == 20 else { throw XHSReadError.invalidQuery } }
            if let limit = args["reply_limit"] { guard limit as? Int == 10 else { throw XHSReadError.invalidQuery } }
            if let speed = args["scroll_speed"] { guard speed as? String == "slow" else { throw XHSReadError.invalidQuery } }
            if args["load_all_comments"] != nil && !(args["load_all_comments"] is Bool) { throw XHSReadError.invalidQuery }
            if args["click_more_replies"] != nil && !(args["click_more_replies"] is Bool) { throw XHSReadError.invalidQuery }
        case .qr: throw XHSReadError.invalidQuery
        }
        let result = try await handler(tool, args)
        try Task.checkCancellation()
        return try reply(result)
    }
}
