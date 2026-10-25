import Foundation

enum ChatGPTPlanDiagnostics {
    private static let lock = NSLock()
    private static var failure: [String: String] = [:]
    private static var transport: [String: String] = [:]
    static func record(_ data: Data, status: Int) {
        let safe = ChatGPTPlanResponses.safeHTTPFailure(data, status: status)
        lock.lock(); defer { lock.unlock() }; failure = safe
    }
    static func recordRequest(_ body: [String: Any]) {
        let items = body["input"] as? [[String: Any]] ?? []
        let safe = ["input_count": String(items.count),
            "assistant_count": String(items.filter { $0["role"] as? String == "assistant" }.count),
            "string_content_count": String(items.filter { $0["content"] is String }.count),
            "empty_content_count": String(items.filter { ($0["content"] as? String)?.isEmpty == true }.count)]
        lock.lock(); defer { lock.unlock() }; transport = safe
    }
    static func recordStream(_ data: Data) {
        let safe = ChatGPTPlanResponses.safeStreamShape(data)
        lock.lock(); defer { lock.unlock() }; transport.merge(safe) { _, new in new }
    }
    static func snapshot() -> [String: String] { lock.lock(); defer { lock.unlock() }; return failure }
    static func transportSnapshot() -> [String: String] { lock.lock(); defer { lock.unlock() }; return transport }
    static func recordParseViolation(_ code: String) { lock.lock(); defer { lock.unlock() }; transport["parse_violation"] = code }
}

/// The plan route supports Responses/SSE, not Chat Completions. Keep the
/// existing prompt/action validators and adapt only the wire envelope.
enum ChatGPTPlanResponses {
    /// Provider messages can echo request data or credentials. Retain only
    /// recognized protocol identifiers; never retain the message or raw body.
    static func safeHTTPFailure(_ data: Data, status: Int) -> [String: String] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"] as? [String: Any] ?? [:]
        let codes: Set<String> = ["invalid_request_error", "unsupported_parameter", "unsupported_value", "invalid_value", "missing_required_parameter", "missing_required_argument", "model_not_found", "context_length_exceeded", "subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible", "subscription_sharing_usage_unavailable", "invalid_grant", "invalid_client", "invalid_scope"]
        let params: Set<String> = ["model", "instructions", "input", "text", "text.format", "text.format.type", "reasoning", "reasoning.effort", "store", "stream", "tools", "tool_choice"]
        let code = error["code"] as? String ?? error["type"] as? String ?? ""
        let param = error["param"] as? String ?? ""
        var safeParam = params.contains(param) ? param : "unknown"
        if param.range(of: #"^input\[\d{1,3}\](\.content(\[\d{1,3}\])?(\.type)?)?$"#, options: .regularExpression) != nil { safeParam = "input.content" }
        let message = (error["message"] as? String ?? "").lowercased()
        let reason: String
        if message.contains("json_object") && (message.contains("not supported") || message.contains("unsupported")) { reason = "unsupported_json_object" }
        else if message.contains("instructions") && (message.contains("required") || message.contains("must be provided")) { reason = "required_instructions" }
        else { reason = "unknown" }
        let vocabulary: Set<String> = ["input", "item", "items", "field", "fields", "type", "content", "role", "roles", "message", "messages", "user", "assistant", "developer", "system", "output_text", "input_text", "text", "format", "json_object", "json_schema", "invalid", "unsupported", "missing", "required", "expected", "received", "must", "be", "is", "are", "a", "an", "the", "to", "of", "and", "or", "not", "provided", "empty", "array", "string", "object", "list", "allowed", "only", "with", "cannot", "can", "have", "include", "using", "supported", "as", "was", "should", "at", "any", "when", "each", "element", "contains", "for", "instructions", "store", "stream", "reasoning", "effort", "image", "file", "refusal", "function_call", "function_call_output", "id", "previous_response_id"]
        let words = message.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "_")).inverted).filter { !$0.isEmpty }
        let protocolWords = words.prefix(64).map { vocabulary.contains($0) ? $0 : "…" }.joined(separator: " ")
        return ["status": String(status), "code": codes.contains(code) ? code : "unknown", "parameter": safeParam, "reason": reason, "protocol_words": protocolWords]
    }

    static func safeStreamShape(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return ["stream_utf8": "false"] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let known: Set<String> = ["response.created", "response.in_progress", "response.output_item.added", "response.content_part.added", "response.output_text.delta", "response.output_text.done", "response.content_part.done", "response.output_item.done", "response.completed", "response.failed", "response.incomplete", "error", "response.reasoning_summary_part.added", "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done", "response.reasoning_summary_part.done"]
        var types = Set<String>(), frames = 0
        var result = ["stream_bytes": String(data.count), "final_blank_frame": String(normalized.hasSuffix("\n\n"))]
        let tail = normalized.components(separatedBy: "\n\n").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result["stream_tail"] = tail.isEmpty ? "blank" : (tail == "data: [DONE]" ? "done_marker" : "unterminated_frame")
        for frame in normalized.components(separatedBy: "\n\n") {
            let payload = frame.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            guard !payload.isEmpty else { continue }; frames += 1
            guard let item = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            let type = item["type"] as? String ?? ""
            if known.contains(type) { types.insert(type) }
            if ["response.failed", "error"].contains(type) {
                let nested = (item["response"] as? [String: Any])?["error"] ?? item["error"]
                if let error = nested as? [String: Any], let encoded = try? JSONSerialization.data(withJSONObject: ["error": error]) {
                    for (key, value) in safeHTTPFailure(encoded, status: 200) { result["stream_" + key] = value }
                }
            }
        }
        result["event_types"] = types.sorted().joined(separator: ","); result["data_frames"] = String(frames)
        return result
    }

    static func body(from legacy: [String: Any]) throws -> [String: Any] {
        guard let model = legacy["model"] as? String, !model.isEmpty,
              let messages = legacy["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw ChatGPTPlanError.message("ChatGPT 请求缺少模型或上下文")
        }
        var instructions: [String] = [], input: [[String: Any]] = []
        for message in messages {
            guard let role = message["role"] as? String, ["system", "developer", "user", "assistant"].contains(role) else {
                throw ChatGPTPlanError.message("ChatGPT 请求的消息角色不受支持")
            }
            if role == "system" || role == "developer" {
                guard let text = message["content"] as? String else { throw ChatGPTPlanError.message("ChatGPT 指令必须为文字") }
                instructions.append(text); continue
            }
            if let text = message["content"] as? String { input.append(["role": role, "content": text]); continue }
            guard let content = message["content"] as? [[String: Any]] else { throw ChatGPTPlanError.message("ChatGPT 消息内容无效") }
            var converted: [[String: Any]] = []
            for part in content {
                switch part["type"] as? String {
                case "text":
                    guard let text = part["text"] as? String else { throw ChatGPTPlanError.message("ChatGPT 文字内容无效") }
                    converted.append(["type": "input_text", "text": text])
                case "image_url":
                    guard let image = part["image_url"] as? [String: Any], let url = image["url"] as? String else { throw ChatGPTPlanError.message("ChatGPT 图片内容无效") }
                    converted.append(["type": "input_image", "image_url": url, "detail": image["detail"] as? String ?? "auto"])
                default: throw ChatGPTPlanError.message("此内容类型暂不支持 ChatGPT 计划连接")
                }
            }
            input.append(["role": role, "content": converted])
        }
        var result: [String: Any] = ["model": model, "input": input, "store": false, "stream": true]
        if !instructions.isEmpty { result["instructions"] = instructions.joined(separator: "\n\n") }
        if let effort = legacy["reasoning_effort"] as? String { result["reasoning"] = ["effort": effort] }
        if let format = legacy["response_format"] as? [String: Any] {
            if format["type"] as? String == "json_schema", let schema = format["json_schema"] as? [String: Any] {
                var value = schema; value["type"] = "json_schema"; result["text"] = ["format": value]
            } else if format["type"] as? String == "json_object" {
                result["text"] = ["format": ["type": "json_object"]]
                // This route validates JSON guidance in input, separately from
                // top-level instructions. Preserve every original user item.
                input.insert(["role": "developer", "content": "Return exactly one JSON object, without Markdown. Follow the required JSON schema and the user's request."], at: 0)
                result["input"] = input
            }
        }
        // Deliberate allowlist: token caps, temperature, previous_response_id,
        // hosted tools and other unsupported legacy fields cannot leak through.
        return result
    }

    static func failure(code: String?, status: Int? = nil) -> ChatGPTPlanError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .message("ChatGPT 计划或此应用的用量限制已达到。请在 ChatGPT 设置 → 用量核对，恢复后可继续原任务。")
        case "subscription_sharing_user_not_eligible": return .message("当前 ChatGPT 账户或工作区暂不支持向此应用提供计划用量。请核对账户与授权。")
        case "subscription_sharing_usage_unavailable": return .message("暂时无法核对 ChatGPT 计划用量，本步骤未执行。请稍后继续。")
        default:
            if status == 401 { return .message("ChatGPT 登录授权已失效，请重新登录后继续原任务。") }
            if status == 403 { return .message("ChatGPT 计划请求未获准，请核对账户授权和所在区域。") }
            if status == 429 { return .message("ChatGPT 计划请求受用量限制或临时限速，请在 ChatGPT 设置 → 用量核对。") }
            return .message("ChatGPT 计划请求未完成，未采用回复，也未执行动作。" + (status.map { "（HTTP \($0)）" } ?? ""))
        }
    }

    static func completion(from stream: Data) throws -> Data {
        func reject(_ code: String) -> ChatGPTPlanError {
            ChatGPTPlanDiagnostics.recordParseViolation(code)
            return .message("ChatGPT 回复完整性校验未通过（" + code + "），未执行动作。")
        }
        guard stream.count <= 2_000_000, let text = String(data: stream, encoding: .utf8) else { throw reject("size_or_encoding") }
        let frames = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        guard frames.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else { throw reject("unterminated_frame") }
        var completed: [String: Any]?
        var responseID: String?
        var finishedOutput: [Int: [String: Any]] = [:]
        for frame in frames.dropLast() {
            let payload = frame.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if payload.isEmpty { continue }
            if payload == "[DONE]" { guard completed != nil else { throw reject("done_before_completed") }; continue }
            guard let data = payload.data(using: .utf8), let item = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = item["type"] as? String else { throw reject("event_envelope") }
            if let response = item["response"] as? [String: Any], let id = response["id"] as? String {
                guard responseID == nil || responseID == id else { throw reject("response_id_mismatch") }
                responseID = id
            }
            switch type {
            case "response.output_item.done":
                guard completed == nil, let index = item["output_index"] as? Int, (0..<128).contains(index),
                      finishedOutput[index] == nil, let value = item["item"] as? [String: Any] else { throw reject("output_item_done_shape") }
                finishedOutput[index] = value
            case "response.failed", "error":
                let response = item["response"] as? [String: Any]
                let error = (response?["error"] ?? item["error"]) as? [String: Any]
                throw failure(code: error?["code"] as? String ?? item["code"] as? String)
            case "response.incomplete": throw ChatGPTPlanError.message("ChatGPT 回复未完成，动作已丢弃。请减少单次内容后继续。")
            case "response.completed":
                guard completed == nil else { throw reject("duplicate_completed") }
                guard let response = item["response"] as? [String: Any] else { throw reject("terminal_response_missing") }
                guard response["status"] as? String == "completed" else { throw reject("terminal_status") }
                completed = response
            default:
                guard completed == nil else { throw reject("event_after_completed") }
            }
        }
        guard let completed else { throw reject("completed_missing") }
        guard let terminalOutput = completed["output"] as? [[String: Any]] else { throw reject("output_missing") }
        // Some plan streams leave output empty on the final response object.
        // Use full closed items, never deltas, only after response.completed.
        let output = terminalOutput.isEmpty ? finishedOutput.keys.sorted().compactMap { finishedOutput[$0] } : terminalOutput
        var textParts: [String] = []
        for item in output where item["type"] as? String == "message" {
            if let status = item["status"] as? String, status != "completed" { throw reject("output_message_not_completed") }
            guard item["role"] as? String == "assistant" else { throw reject("output_role") }
            guard let content = item["content"] as? [[String: Any]] else { throw reject("output_content_missing") }
            for part in content {
                if part["type"] as? String == "refusal" { throw ChatGPTPlanError.message("ChatGPT 未提供可执行回复。") }
                guard part["type"] as? String == "output_text", let value = part["text"] as? String else { throw reject("output_text_shape") }
                textParts.append(value)
            }
        }
        guard !textParts.isEmpty else { throw reject("assistant_text_missing") }
        var wrapped: [String: Any] = ["choices": [["message": ["content": textParts.joined()], "finish_reason": "stop"]]]
        if let usage = completed["usage"] as? [String: Any] {
            var value: [String: Any] = [:]
            if let count = usage["output_tokens"] as? Int { value["completion_tokens"] = count }
            if let details = usage["output_tokens_details"] as? [String: Any], let count = details["reasoning_tokens"] as? Int { value["completion_tokens_details"] = ["reasoning_tokens": count] }
            wrapped["usage"] = value
        }
        return try JSONSerialization.data(withJSONObject: wrapped)
    }
}
