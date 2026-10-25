import Foundation
import SelaMemoryCore

@MainActor private final class Configuration {
    var settings = AgentSettings()
    var key = "offline-fixture-key"
    var requests = 0
}

@main struct IntegrationChecks {
    @MainActor static func main() async throws {
        let live = CommandLine.arguments.contains("--live")
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SELA_MEMORY_CHECK_ROOT"]!)
        let configuration = Configuration()
        if live {
            guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else { throw AgentError.message("No existing key available") }
            configuration.key = key
            configuration.settings.model = ProcessInfo.processInfo.environment["SELA_MEMORY_CHECK_MODEL"] ?? "gpt-6.1-sol"
        }
        let service = SelaMemoryService(root: root, configuration: { configuration.settings }, credential: { _ in configuration.key }) { input, settings, key in
            configuration.requests += 1
            var client = SelaMemoryModelClient(settings: settings, apiKey: key)
            if !live {
                client.transport = { request in
                    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    guard (body["tools"] as? [[String: Any]])?.isEmpty == true, body["store"] as? Bool == false else { throw AgentError.message("Unexpected tools or storage") }
                    let input = body["input"] as! [[String: String]]
                    let batch = try JSONDecoder().decode(LearningBatch.self, from: Data(input[0]["content"]!.utf8))
                    let schema = (body["text"] as! [String: Any])["format"] as! [String: Any]
                    let properties = (schema["schema"] as! [String: Any])["properties"] as! [String: Any]
                    let items = (properties["memories"] as! [String: Any])["items"] as! [String: Any]
                    let fields = items["properties"] as! [String: Any]
                    let scopes = (fields["scope"] as! [String: Any])["enum"] as! [String]
                    guard scopes == ["personal", "conversation"] else { throw AgentError.message("Unbound Work/topic scopes were offered to the model") }
                    let source = batch.messages.last { $0.role == .user }!
                    let result: [String: Any] = ["summary": ["text": "用户提供称呼和沟通偏好", "importantFacts": ["称呼记忆测试员"], "openQuestions": []],
                        "memories": [
                            ["key": "profile.preferred_name", "text": "用户希望被称呼为记忆测试员", "kind": "preference", "scope": "personal", "certainty": "stated", "evidence": [["messageID": source.id.uuidString, "quote": source.text]]],
                            ["key": "communication.response_length", "text": "回答尽量简短", "kind": "preference", "scope": "personal", "certainty": "stated", "evidence": [["messageID": source.id.uuidString, "quote": source.text]]]
                        ]]
                    let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                    let envelope: [String: Any] = ["status": "completed", "model": "offline", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]]
                    return (try JSONSerialization.data(withJSONObject: envelope), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }
            return try await client.extract(input)
        }
        await service.reload()
        guard service.documents.count == 5 else { throw AgentError.message("Foundation files were not initialized") }
        let conversationID = UUID()
        let source = AssistantMessage(role: "user", text: "我叫记忆测试员，回答尽量简短。")
        let messages = [source, AssistantMessage(role: "assistant", text: "好的，记忆测试员。")]
        let prepared = await service.prepare(question: source.text, conversationID: conversationID, settings: configuration.settings)
        guard prepared.identity.contains("Sela") else { throw AgentError.message("Identity missing") }
        service.completedTurn(conversationID: conversationID, messages: messages, settings: configuration.settings, apiKey: configuration.key)
        service.flushConversation(conversationID)
        for _ in 0..<900 {
            if let workspace = service.workspace, (try await workspace.memories()).count >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await service.reload()
        guard service.learned.count >= 2 else { throw AgentError.message("Automatic memory extraction did not commit: " + service.error) }
        let next = await service.prepare(question: "你记得我希望怎么称呼、回答应当怎样吗？", settings: configuration.settings)
        guard next.reference.contains("记忆测试员"), next.reference.contains("简短") || next.reference.contains("简洁") else { throw AgentError.message("New conversation did not recall learned facts") }
        print("PASS: native service → model request → validated learning → new-conversation recall")
        if live {
            let reply = try await ConnectedConversationClient(settings: configuration.settings, apiKey: configuration.key)
                .answer(question: "按我之前的要求，应该怎么称呼我？回答有什么偏好？", history: [], memoryContext: next.reference, assistantIdentity: next.identity)
            guard reply.text.contains("记忆测试员"), reply.text.contains("简短") || reply.text.contains("简洁") else { throw AgentError.message("Live answer did not apply recalled memory") }
            print("PASS: real configured model used the recalled name and response preference")
        }
        let lastCount = configuration.requests
        configuration.key = "rotated-fixture-key"
        service.completedTurn(conversationID: UUID(), messages: messages, settings: configuration.settings, apiKey: "old-fixture-key")
        try await Task.sleep(nanoseconds: 100_000_000)
        guard configuration.requests == lastCount else { throw AgentError.message("Stale credential launched a learning request") }
        let workspace = service.workspace!
        let memory = service.learned.first!
        let beforeForgetGeneration = service.recallGeneration
        try await service.forget(memory)
        guard beforeForgetGeneration != service.recallGeneration else { throw AgentError.message("Forgetting did not invalidate in-flight recall") }
        let afterForget = await service.prepare(question: "刚才的偏好", conversationID: conversationID, messages: messages, settings: configuration.settings)
        guard afterForget.excludedMessageIDs.contains(source.id), try await workspace.memories().isEmpty else { throw AgentError.message("Forgotten source remained in model history") }
        await service.setAutomaticLearning(false, settings: configuration.settings)
        let reloaded = try MemoryWorkspace(root: root)
        guard try await reloaded.learningPreferences().learnFromConversations == false else { throw AgentError.message("Learning preference did not persist") }
        let beforeClearGeneration = service.recallGeneration
        try await service.clearPersonalMemory()
        guard beforeClearGeneration != service.recallGeneration else { throw AgentError.message("Clearing did not invalidate in-flight recall") }
        print("PASS: credential change, forgetting, preference persistence, and clear-all")
        if !live {
            let failed = SelaMemoryService(root: root.appendingPathComponent("failure-observation"), configuration: { configuration.settings }, credential: { _ in configuration.key }) { _, _, _ in
                throw AgentError.message("Offline learning failure must be visible")
            }
            let failedID = UUID()
            _ = await failed.prepare(question: source.text, conversationID: failedID, settings: configuration.settings)
            failed.completedTurn(conversationID: failedID, messages: messages, settings: configuration.settings, apiKey: configuration.key)
            failed.flushConversation(failedID)
            for _ in 0..<100 {
                if !failed.error.isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard failed.error == "Offline learning failure must be visible" else { throw AgentError.message("Learning failure was silently discarded") }
            print("PASS: short-conversation learning failures reach the native memory UI")
            try await checkAutomaticScopeAdmission(root: root, configuration: configuration)
            try await checkUnavailableExclusions(root: root, configuration: configuration)
        }
        print(live ? "LIVE MEMORY INTEGRATION PASSED" : "OFFLINE MEMORY INTEGRATION PASSED")
    }

    @MainActor private static func checkAutomaticScopeAdmission(root: URL, configuration: Configuration) async throws {
        let service = SelaMemoryService(root: root.appendingPathComponent("scope-admission"), configuration: { configuration.settings }, credential: { _ in configuration.key }) { input, settings, key in
            var client = SelaMemoryModelClient(settings: settings, apiKey: key)
            client.transport = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let inputs = body["input"] as! [[String: String]]
                let batch = try JSONDecoder().decode(LearningBatch.self, from: Data(inputs[0]["content"]!.utf8))
                let source = batch.messages.last { $0.role == .user }!
                // Deliberately propose both as personal: the host must scope the
                // one-off value from actual source, even with a shortened quote.
                let result: [String: Any] = ["summary": ["text": "机票预算及会议默认时长", "importantFacts": [], "openQuestions": []],
                    "memories": [
                        ["key": "travel.budget", "text": "机票预算1500元", "kind": "preference", "scope": "personal", "certainty": "stated", "evidence": [["messageID": source.id.uuidString, "quote": "预算1500元"]]],
                        ["key": "meeting.default_duration", "text": "项目会议默认半小时", "kind": "preference", "scope": "personal", "certainty": "stated", "evidence": [["messageID": source.id.uuidString, "quote": "以后项目会议默认半小时"]]]
                    ]]
                let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                let envelope: [String: Any] = ["status": "completed", "model": "offline", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]]
                return (try JSONSerialization.data(withJSONObject: envelope), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return try await client.extract(input)
        }
        let conversationID = UUID()
        let source = AssistantMessage(role: "user", text: "这次机票预算1500元。以后项目会议默认半小时。")
        let messages = [source, AssistantMessage(role: "assistant", text: "收到。")]
        _ = await service.prepare(question: source.text, conversationID: conversationID, settings: configuration.settings)
        service.completedTurn(conversationID: conversationID, messages: messages, settings: configuration.settings, apiKey: configuration.key)
        service.flushConversation(conversationID)
        for _ in 0..<100 {
            if let workspace = service.workspace, (try await workspace.memories()).count == 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await service.reload()
        guard let budget = service.learned.first(where: { $0.key == "travel.budget" }),
              let duration = service.learned.first(where: { $0.key == "meeting.default_duration" }),
              budget.scope == .conversation(conversationID), budget.text == "机票预算1500元", duration.scope == .personal else {
            throw AgentError.message("Service admitted temporary parameters as personal memory: " + service.error)
        }
        let original = try await service.workspace!.conversation(conversationID)
        guard original.messages.first?.text == source.text else { throw AgentError.message("Scope admission changed source text") }
        let same = await service.prepare(question: "这次机票预算是多少？", conversationID: conversationID, messages: messages, settings: configuration.settings)
        guard same.reference.contains("1500") else { throw AgentError.message("Conversation-scoped value was discarded") }
        let next = await service.prepare(question: "机票预算是多少，项目会议默认多久？", settings: configuration.settings)
        guard !next.reference.contains("1500"), next.reference.contains("半小时") else {
            throw AgentError.message("Service leaked a one-off budget or lost the explicit future default")
        }
        print("PASS: automatic service extraction scopes one-off parameters while preserving explicit future defaults")
    }

    @MainActor private static func checkUnavailableExclusions(root: URL, configuration: Configuration) async throws {
        for primeCache in [true, false] {
            let fixtureRoot = root.appendingPathComponent(primeCache ? "exclusions-cached" : "exclusions-uncached")
            let service = SelaMemoryService(root: fixtureRoot, configuration: { configuration.settings }, credential: { _ in configuration.key }) { _, _, _ in
                throw AgentError.message("Exclusion checks must not call a model")
            }
            await service.reload()
            let workspace = service.workspace!
            let id = try await workspace.createConversation(.init(title: "忘记后读取失败", recipient: SelaMemoryService.recipient(configuration.settings)))
            let source = AssistantMessage(role: "user", text: "忘记前的专用资料")
            try await workspace.appendMessage(.init(id: source.id, role: .user, text: source.text, date: source.createdAt), to: id)
            let fact = RememberedFact(key: "profile.test_fact", text: source.text, recipient: SelaMemoryService.recipient(configuration.settings), evidence: [.init(messageID: source.id, quote: source.text)])
            try await workspace.remember(fact)
            await service.reload()
            try await service.forget(fact)
            if primeCache {
                guard try await service.recallExclusions().contains(source.id) else { throw AgentError.message("Forgotten source was not excluded before read failure") }
            }
            let archive = fixtureRoot.appendingPathComponent("state.json")
            let original = try Data(contentsOf: archive), corrupt = Data("{invalid-test-archive".utf8)
            defer { try? original.write(to: archive, options: .atomic) }
            try corrupt.write(to: archive, options: .atomic)
            let prepared = await service.prepare(question: "我的资料是什么？", conversationID: id, messages: [source], settings: configuration.settings)
            guard !service.error.isEmpty, !prepared.canUseConversationHistory, !prepared.reference.contains(source.text), try Data(contentsOf: archive) == corrupt else {
                throw AgentError.message("Unreadable exclusions were hidden or damaged archive was overwritten")
            }
            if primeCache {
                guard prepared.excludedMessageIDs.contains(source.id) else { throw AgentError.message("Read failure lost a known forgotten-source exclusion") }
            }
            try original.write(to: archive, options: .atomic)
            guard try await service.recallExclusions(in: id).contains(source.id) else { throw AgentError.message("Recovery lost the persisted forgotten-source marker") }
        }
        let corruptRoot = root.appendingPathComponent("exclusions-init-corrupt")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        try Data("{invalid-test-archive".utf8).write(to: corruptRoot.appendingPathComponent("state.json"))
        let unavailable = SelaMemoryService(root: corruptRoot, configuration: { configuration.settings }, credential: { _ in configuration.key }) { _, _, _ in
            throw AgentError.message("Unavailable workspace must not call a model")
        }
        let initial = await unavailable.prepare(question: "旧资料", settings: configuration.settings)
        guard !initial.canUseConversationHistory, !unavailable.error.isEmpty else { throw AgentError.message("Corrupt-at-start workspace reopened conversation history") }
        print("PASS: exclusion read failures retain known forgotten sources and close history when state is unknown")
    }
}
