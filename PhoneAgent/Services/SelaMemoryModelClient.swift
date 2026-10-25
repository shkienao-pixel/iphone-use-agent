import Foundation
import SelaMemoryCore

/// Uses the same configured model as chat, without search or phone tools.
struct SelaMemoryModelClient {
    let settings: AgentSettings
    let apiKey: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = ConnectedConversationClient.load

    func request(_ input: ConversationLearningRequest) throws -> URLRequest {
        guard PrivacyConsent.allowed(settings), settings.useMemories == true, !apiKey.isEmpty else {
            throw AgentError.message("记忆学习需要当前模型授权和本机记忆开关。")
        }
        let openAI = ConnectedConversationClient.supports(settings)
        let endpoint = openAI ? URL(string: "https://api.openai.com/v1/responses")! : try ModelEndpointPolicy.url(settings.endpoint)
        let instructions = input.instructions + "\nJSON 输出结构：\n" + input.responseShape
        let limit = max(4096, min(8192, settings.responseTokenLimit))
        var body: [String: Any] = ["model": settings.model, "stream": false]
        if openAI {
            body["instructions"] = instructions
            body["input"] = [["role": "user", "content": input.inputJSON]]
            body["store"] = false
            body["tools"] = []; body["tool_choice"] = "none"
            body["max_output_tokens"] = limit
            body["text"] = ["format": ["type": "json_schema", "name": "sela_memory", "strict": true, "schema": Self.schema(scopes: input.allowedScopes)]]
            if settings.model.hasPrefix("gpt-6") { body["reasoning"] = ["effort": "low"] }
        } else {
            body["messages"] = [["role": "system", "content": instructions], ["role": "user", "content": input.inputJSON]]
            body[settings.legacyTokenLimit ? "max_tokens" : "max_completion_tokens"] = limit
            if settings.jsonMode { body["response_format"] = ["type": "json_object"] }
        }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 75
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func extract(_ input: ConversationLearningRequest) async throws -> Data {
        var request = try request(input)
        let planID = settings.usesChatGPTPlan ? ChatGPTPlanStore.selected()?.id : nil
        if settings.usesChatGPTPlan {
            guard let id = planID, request.url?.absoluteString == ChatGPTPlanProtocol.endpoint,
                  let body = request.httpBody,
                  let legacy = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw ChatGPTPlanError.message("ChatGPT 记忆请求无效") }
            let profile = try await ChatGPTPlanTokens.shared.valid(id)
            try Task.checkCancellation()
            request.setValue("Bearer " + (profile.accessToken ?? ""), forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ChatGPTPlanResponses.body(from: legacy))
        }
        var (bytes, response) = try await transport(request)
        try Task.checkCancellation()
        if settings.usesChatGPTPlan {
            guard let id = planID, ChatGPTPlanStore.active(id), response.url == request.url else { throw CancellationError() }
            guard (200...299).contains(response.statusCode) else { throw ChatGPTPlanResponses.failure(code: nil, status: response.statusCode) }
            bytes = try ChatGPTPlanResponses.completion(from: bytes)
        }
        guard response.url == request.url, (200...299).contains(response.statusCode), bytes.count <= 1_048_576 else {
            throw AgentError.message("记忆整理暂未完成，请稍后继续聊天。")
        }
        let text: String
        if ConnectedConversationClient.supports(settings) { text = try ConnectedConversationClient.decode(bytes).text }
        else {
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let choice = (root["choices"] as? [[String: Any]])?.first,
                  choice["finish_reason"] as? String != "length",
                  let message = choice["message"] as? [String: Any], message["refusal"] == nil || message["refusal"] is NSNull,
                  let content = message["content"] as? String, !content.isEmpty else {
                throw AgentError.message("记忆整理没有返回完整结果。")
            }
            text = content
        }
        guard text.utf8.count <= 100_000 else { throw AgentError.message("记忆整理结果过大。") }
        return Data(text.utf8)
    }
    static var schema: [String: Any] {
        schema(scopes: ["personal", "conversation", "work", "topic"])
    }
    static func schema(scopes: [String]) -> [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let evidence: [String: Any] = ["type": "object", "additionalProperties": false,
            "properties": ["messageID": string, "quote": string], "required": ["messageID", "quote"]]
        let fact: [String: Any] = ["type": "object", "additionalProperties": false,
            "properties": ["key": string, "text": string,
                "kind": ["type": "string", "enum": ["preference", "fact", "decision", "episode"]],
                "scope": ["type": "string", "enum": scopes],
                "certainty": ["type": "string", "enum": ["stated", "inferred"]],
                "evidence": ["type": "array", "items": evidence]],
            "required": ["key", "text", "kind", "scope", "certainty", "evidence"]]
        let summary: [String: Any] = ["type": "object", "additionalProperties": false,
            "properties": ["text": string, "importantFacts": strings, "openQuestions": strings],
            "required": ["text", "importantFacts", "openQuestions"]]
        return ["type": "object", "additionalProperties": false,
            "properties": ["summary": summary, "memories": ["type": "array", "items": fact]], "required": ["summary", "memories"]]
    }
}
