import Foundation
import SelaMemoryCore

@main struct PlanMemoryChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SELA_MEMORY_CHECK_ROOT"]!)
        var settings = AgentSettings()
        settings.usesChatGPTPlan = true
        settings.endpoint = ChatGPTPlanProtocol.endpoint
        settings.providerName = "ChatGPT 计划"
        var requestCount = 0
        var bearerChecks = 0
        var successfulExtractions = 0
        let initial = ChatGPTPlanProfile(id: UUID(), clientID: "fixture-client", issuer: "https://auth.openai.com",
            subject: "fixture-account", accessToken: "synthetic-access-initial", refreshToken: "synthetic-refresh",
            scopes: ["resource.invoke", "chatgpt.tokens.use.direct"], expiresAt: Date().addingTimeInterval(3600), authorizationID: UUID())

        for mode in ["same-account-refresh", "other-account", "revoked-scopes", "same-account-reauthorized"] {
            ChatGPTPlanStore.fixture = initial
            let directory = root.appendingPathComponent(mode)
            let service = SelaMemoryService(root: directory, configuration: { settings },
                credential: { _ in ChatGPTPlanStore.readinessToken() }) { input, options, binding in
                var client = SelaMemoryModelClient(settings: options, apiKey: binding)
                client.transport = { request in
                    requestCount += 1
                    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-initial" else {
                        throw AgentError.message("An identity marker replaced the actual OAuth bearer on the wire")
                    }
                    bearerChecks += 1
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    guard body["store"] as? Bool == false, body["stream"] as? Bool == true,
                          (body["tools"] as? [[String: Any]] ?? []).isEmpty else {
                        throw AgentError.message("Plan memory request violated storage/stream/tool contract")
                    }
                    let batch = try JSONDecoder().decode(LearningBatch.self, from: Data(input.inputJSON.utf8))
                    let user = batch.messages.last { $0.role == .user }!
                    let learned: [String: Any] = ["summary": ["text": "合成偏好", "importantFacts": [], "openQuestions": []],
                        "memories": [["key": "profile.preferred_name", "text": "用户希望称呼为记忆测试员", "kind": "preference",
                            "scope": "personal", "certainty": "stated", "evidence": [["messageID": user.id.uuidString, "quote": user.text]]]]]
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: learned), as: UTF8.self)
                    let response: [String: Any] = ["status": "completed", "model": "offline-plan",
                        "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]]
                    let event = try JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": response])
                    var replacement = initial
                    if mode == "same-account-refresh" { replacement.accessToken = "synthetic-access-refreshed" }
                    else if mode == "other-account" { replacement.id = UUID(); replacement.subject = "another-fixture-account" }
                    else if mode == "revoked-scopes" { replacement.scopes = ["openid"] }
                    else { replacement.authorizationID = UUID() }
                    ChatGPTPlanStore.fixture = replacement
                    return (Data("event: response.completed\ndata: ".utf8) + event + Data("\n\n".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let result = try await client.extract(input)
                successfulExtractions += 1
                return result
            }
            await service.reload()
            let id = UUID()
            let messages = [AssistantMessage(role: "user", text: "请记住，我希望被称呼为记忆测试员。"),
                            AssistantMessage(role: "assistant", text: "好的。")]
            let before = requestCount
            service.completedTurn(conversationID: id, messages: messages, settings: settings,
                apiKey: ChatGPTPlanStore.readinessToken())
            for _ in 0..<50 {
                if requestCount > before { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard requestCount == before + 1 else { throw AgentError.message("Expected exactly one local model transport invocation") }
            try await Task.sleep(nanoseconds: 300_000_000)
            if mode == "same-account-refresh", successfulExtractions != 1 {
                throw AgentError.message("Fixture extraction failed before the credential-rotation check: " + service.error)
            }
            let saved = try await service.workspace!.memories()
            if mode == "same-account-refresh" {
                guard saved.count == 1 else {
                    throw AgentError.message("Same-account token refresh discarded a successful memory extraction")
                }
                let next = await service.prepare(question: "应该怎么称呼我？", settings: settings)
                guard next.reference.contains("记忆测试员") else { throw AgentError.message("Committed refresh result was not recalled") }
                guard !ChatGPTPlanStore.readinessToken().contains("synthetic-access") else {
                    throw AgentError.message("Readiness/identity binding still exposes the transport token")
                }
            } else {
                guard saved.isEmpty else { throw AgentError.message("Old account or revoked grant committed a memory") }
            }
            await service.setAutomaticLearning(false, settings: settings)
            print("PASS: " + mode)
        }
        guard requestCount == 4 && bearerChecks == 4 && successfulExtractions == 3 else { throw AgentError.message("Unexpected request count, extraction or bearer contract") }
        var freshGrant = initial; freshGrant.authorizationID = UUID()
        ChatGPTPlanStore.fixture = freshGrant
        var lateRefresh = initial; lateRefresh.accessToken = "synthetic-late-refresh"
        do {
            try ChatGPTPlanStore.save(lateRefresh, expectedRefreshToken: initial.refreshToken, select: false)
            throw AgentError.message("Old refresh overwrote a newer authorization even with the same refresh token")
        } catch is CancellationError {}
        guard ChatGPTPlanStore.fixture?.authorizationID == freshGrant.authorizationID else { throw AgentError.message("New grant identity was lost") }
        print("PASS: old refresh cannot overwrite a reauthorized grant")
        ChatGPTPlanStore.fixture = initial
        var currentRefresh = initial; currentRefresh.accessToken = "synthetic-current-refresh"
        try ChatGPTPlanStore.save(currentRefresh, expectedRefreshToken: initial.refreshToken, select: false)
        guard ChatGPTPlanStore.fixture?.accessToken == currentRefresh.accessToken else { throw AgentError.message("A valid same-grant refresh did not persist") }
        print("PASS: same-grant refresh persists normally")
        print("PASS: plan memory rotation/account/permission/relogin (4 cases) and late-refresh persistence protection; no network, Keychain or account credentials")
    }
}
