import Foundation
import Testing
@testable import SelaMemoryCore

private struct LearningFixture: Sendable {
    let root: URL
    let workspace: MemoryWorkspace
    let conversationID: UUID
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sela-auto-learning-" + UUID().uuidString)
        workspace = try MemoryWorkspace(root: root)
        conversationID = try await workspace.createConversation(MemoryConversation(title: "日常聊天", recipient: "provider-a"))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func turn(_ text: String) async throws {
        try await workspace.appendMessage(MemoryMessage(role: .user, text: text), to: conversationID)
        try await workspace.appendMessage(MemoryMessage(role: .assistant, text: "知道了。"), to: conversationID)
    }
}

private actor LearningProbe {
    private(set) var count = 0
    private(set) var knownKeys: [[String]] = []
    let certainty: String
    let scope: String
    init(certainty: String = "stated", scope: String = "personal") { self.certainty = certainty; self.scope = scope }
    func reply(_ request: ConversationLearningRequest) throws -> Data {
        count += 1
        let batch = try JSONDecoder().decode(LearningBatch.self, from: Data(request.inputJSON.utf8))
        knownKeys.append(batch.knownMemories.map(\.key))
        return try Self.bytes(batch: batch, certainty: certainty, scope: scope)
    }
    static func bytes(batch: LearningBatch, certainty: String = "stated", scope: String = "personal") throws -> Data {
        let user = batch.messages.last { $0.role == .user }!
        let value = user.text.contains("详细") ? "回答详细一些" : "回答简短一些"
        let object: [String: Any] = ["summary": ["text": "讨论交流偏好", "importantFacts": [value], "openQuestions": []],
            "memories": [["key": "communication.response_length", "text": value, "kind": "preference", "scope": scope,
                "certainty": certainty, "evidence": [["messageID": user.id.uuidString, "quote": user.text]]]]]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private func settle(_ predicate: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw MemoryError.invalid("自动学习没有在测试时限内完成。")
}

@Suite(.serialized) struct AutomaticLearningTests {
    @Test func learningScopesRequireActualHostBindings() throws {
        let cases: [(UUID?, String?, [String])] = [
            (nil, nil, ["personal", "conversation"]),
            (UUID(), nil, ["personal", "conversation", "work"]),
            (nil, "机票", ["personal", "conversation", "topic"]),
            (UUID(), "机票", ["personal", "conversation", "work", "topic"])
        ]
        for (workID, topic, expected) in cases {
            let batch = LearningBatch(conversationID: UUID(), recipient: "provider-a", expectedRevision: 1,
                previousSummary: nil, messages: [], coveredMessageIDs: [], knownMemories: [], workID: workID, topic: topic)
            let request = try ConversationLearningRequest(batch: batch)
            #expect(request.allowedScopes == expected)
        }
    }
    @Test func ordinaryConversationLearnsWithoutRememberCommand() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let probe = LearningProbe()
        let learner = ConversationMemoryLearner(workspace: f.workspace, delayNanoseconds: 0) { try await probe.reply($0) }
        for text in ["今天想聊一下阅读", "我最近在看一本书"] {
            try await f.turn(text); await learner.noteCompletedTurn(conversationID: f.conversationID)
        }
        #expect(await probe.count == 0)
        try await f.turn("我喜欢回答简短一点")
        await learner.noteCompletedTurn(conversationID: f.conversationID)
        try await settle { await learner.state(for: f.conversationID) == .saved }
        #expect(await probe.count == 1)
        let memories = try await f.workspace.memories()
        #expect(memories.count == 1 && memories[0].text == "回答简短一些")
        let context = try await f.workspace.context(ContextRequest(question: "解释一下黑洞", recipient: "provider-a"))
        #expect(context.relevantMemories.first?.text == "回答简短一些")
    }

    @Test func explicitFuturePreferenceRunsImmediately() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let probe = LearningProbe()
        let learner = ConversationMemoryLearner(workspace: f.workspace, minimumUserMessages: 99, delayNanoseconds: 30_000_000_000) { try await probe.reply($0) }
        try await f.turn("以后回答简短一点")
        await learner.noteCompletedTurn(conversationID: f.conversationID)
        try await settle { await learner.state(for: f.conversationID) == .saved }
        #expect(await probe.count == 1)
    }

    @Test func correctionSeesKnownKeysAndReplacesPreviousValue() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let probe = LearningProbe()
        let learner = ConversationMemoryLearner(workspace: f.workspace) { try await probe.reply($0) }
        try await f.turn("我喜欢简短一点")
        await learner.flush(conversationID: f.conversationID)
        try await f.turn("改成回答详细一点")
        await learner.flush(conversationID: f.conversationID)
        #expect(await probe.knownKeys.last == ["communication.response_length"])
        let memories = try await f.workspace.memories()
        #expect(memories.count == 1 && memories[0].text == "回答详细一些")
        #expect(try await f.workspace.memories(includeInactive: true).contains { $0.status == .superseded })
    }

    @Test func repeatedPreferenceMergesEvidenceInsteadOfDuplicating() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let probe = LearningProbe()
        let learner = ConversationMemoryLearner(workspace: f.workspace) { try await probe.reply($0) }
        try await f.turn("我喜欢简短一点"); await learner.flush(conversationID: f.conversationID)
        try await f.turn("还是简短一点"); await learner.flush(conversationID: f.conversationID)
        let memories = try await f.workspace.memories(includeInactive: true)
        #expect(memories.count == 1 && memories[0].evidence.count == 2)
    }

    @Test func inferredInformationStaysCandidateEvenWithAutomaticLearning() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let probe = LearningProbe(certainty: "inferred")
        let learner = ConversationMemoryLearner(workspace: f.workspace) { try await probe.reply($0) }
        try await f.turn("聊聊天"); await learner.flush(conversationID: f.conversationID)
        #expect(try await f.workspace.memories().isEmpty)
        #expect(try await f.workspace.memories(includeInactive: true).first?.status == .candidate)
    }

    @Test func temporaryConditionUsesConversationScope() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let probe = LearningProbe(scope: "conversation")
        let learner = ConversationMemoryLearner(workspace: f.workspace) { try await probe.reply($0) }
        try await f.turn("这次回答简短一些"); await learner.flush(conversationID: f.conversationID)
        #expect(try await f.workspace.memories().first?.scope == .conversation(f.conversationID))
        let context = try await f.workspace.context(ContextRequest(question: "我的偏好", recipient: "provider-a"))
        #expect(context.relevantMemories.isEmpty)
    }

    @Test func boundWorkScopeCannotChangeTaskState() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let work = MemoryWork(title: "查资料", recipient: "provider-a", conversationID: f.conversationID, originalGoal: "查询资料", steps: [WorkStep(goal: "查询")])
        try await f.workspace.createWork(work)
        let probe = LearningProbe(scope: "work")
        let learner = ConversationMemoryLearner(workspace: f.workspace) { try await probe.reply($0) }
        try await f.turn("这个任务的说明简短些"); await learner.flush(conversationID: f.conversationID, workID: work.id)
        #expect(try await f.workspace.memories().first?.scope == .work(work.id))
        #expect(try await f.workspace.work(work.id).status == .pending)
        #expect(try await f.workspace.work(work.id).receipts.isEmpty)
    }

    @Test func disablingLearningDuringRequestBlocksItsCommit() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let learner = ConversationMemoryLearner(workspace: f.workspace) { request in
            try await f.workspace.setLearningPreferences(LearningPreferences(learnFromConversations: false))
            let batch = try JSONDecoder().decode(LearningBatch.self, from: Data(request.inputJSON.utf8))
            return try LearningProbe.bytes(batch: batch)
        }
        try await f.turn("我喜欢简短些"); await learner.flush(conversationID: f.conversationID)
        #expect(try await f.workspace.memories().isEmpty)
        #expect(try await f.workspace.conversation(f.conversationID).summary == nil)
        let reloaded = try MemoryWorkspace(root: f.root)
        #expect(try await reloaded.learningPreferences().learnFromConversations == false)
    }

    @Test func memorySwitchBlocksLearningAndPersonalContextAcrossRestart() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        try await f.workspace.setLearningPreferences(LearningPreferences(useMemories: false))
        let probe = LearningProbe()
        let learner = ConversationMemoryLearner(workspace: f.workspace) { try await probe.reply($0) }
        try await f.turn("记住回答简短些"); await learner.noteCompletedTurn(conversationID: f.conversationID)
        #expect(await learner.state(for: f.conversationID) == .disabled)
        #expect(await probe.count == 0)
        let reloaded = try MemoryWorkspace(root: f.root)
        let context = try await reloaded.context(ContextRequest(question: "我的偏好", recipient: "provider-a"))
        #expect(context.foundationReferences.isEmpty && context.relatedHistory.isEmpty)
    }

    @Test func coalescedTurnsUseOneCallForLatestConversation() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let probe = LearningProbe()
        let learner = ConversationMemoryLearner(workspace: f.workspace, minimumUserMessages: 1, delayNanoseconds: 30_000_000_000) { try await probe.reply($0) }
        for text in ["我喜欢简短些", "聊一点别的", "最近喜欢详细说明"] {
            try await f.turn(text); await learner.noteCompletedTurn(conversationID: f.conversationID)
        }
        #expect(await probe.count == 0)
        await learner.flush(conversationID: f.conversationID)
        #expect(await probe.count == 1)
        #expect(try await f.workspace.memories().first?.text == "回答详细一些")
    }

    @Test func lateResultCannotOverwriteNewMessages() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let learner = ConversationMemoryLearner(workspace: f.workspace) { request in
            let batch = try JSONDecoder().decode(LearningBatch.self, from: Data(request.inputJSON.utf8))
            try await f.workspace.appendMessage(MemoryMessage(role: .user, text: "新的补充"), to: f.conversationID)
            return try LearningProbe.bytes(batch: batch)
        }
        try await f.turn("回答简短些"); await learner.flush(conversationID: f.conversationID)
        #expect(await learner.state(for: f.conversationID) == .superseded)
        #expect(try await f.workspace.memories().isEmpty)
    }

    @Test func malformedReplyDoesNotCreatePartialSummaryOrFacts() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let learner = ConversationMemoryLearner(workspace: f.workspace) { _ in Data("not json".utf8) }
        try await f.turn("记住回答简短些"); await learner.flush(conversationID: f.conversationID)
        #expect(try await f.workspace.memories().isEmpty)
        #expect(try await f.workspace.conversation(f.conversationID).summary == nil)
        if case .failed = await learner.state(for: f.conversationID) {} else { Issue.record("错误没有被记录") }
    }

    @Test func learningDoesNotWriteFoundationDocuments() async throws {
        let f = try await LearningFixture(); defer { f.clean() }
        let before = try await f.workspace.documents(), probe = LearningProbe()
        let learner = ConversationMemoryLearner(workspace: f.workspace) { try await probe.reply($0) }
        try await f.turn("以后回答简短一些"); await learner.flush(conversationID: f.conversationID)
        #expect(try await f.workspace.documents() == before)
    }
}
