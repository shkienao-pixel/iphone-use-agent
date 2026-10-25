import Foundation
import Testing
@testable import SelaMemoryCore

private struct Fixture {
    let root: URL
    let workspace: MemoryWorkspace
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sela-memory-test-" + UUID().uuidString)
        workspace = try MemoryWorkspace(root: root)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func conversation(recipient: String = "provider-a", topic: String? = nil) async throws -> UUID {
        try await workspace.createConversation(MemoryConversation(title: "旅行计划", recipient: recipient, topic: topic))
    }
    func message(_ text: String, conversation: UUID, role: MessageRole = .user) async throws -> MemoryMessage {
        let message = MemoryMessage(role: role, text: text)
        try await workspace.appendMessage(message, to: conversation); return message
    }
    func fact(_ text: String, source: MemoryMessage, key: String = "preference", scope: MemoryScope = .personal,
              recipient: String = "provider-a", now: Date = Date(), expiresAt: Date? = nil) -> RememberedFact {
        RememberedFact(key: key, text: text, scope: scope, kind: .preference, recipient: recipient,
            evidence: [Evidence(messageID: source.id, quote: source.text)], expiresAt: expiresAt, now: now)
    }
}

@Suite(.serialized) struct MemoryTests {
    @Test func translatedFactsRecallByVerifiedSourceWithoutOtherConversationExcerpts() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("The name of my travel software project is Maple Grove.", conversation: id)
        let fact = f.fact("用户的旅行软件项目名为 Maple Grove。", source: source, key: "项目.名称")
        try await f.workspace.remember(fact)
        let unrelated = try await f.message("My favorite drink is green tea.", conversation: id)
        let drink = f.fact("用户偏爱绿茶。", source: unrelated, key: "taste.drink")
        try await f.workspace.remember(drink)
        let question = "What is the name of my travel software project?"
        let context = try await f.workspace.context(ContextRequest(question: question, recipient: "provider-a", includeOtherConversations: false))
        #expect(context.relevantMemories.contains { $0.id == fact.id })
        #expect(!context.relevantMemories.contains { $0.id == drink.id })
        #expect(context.relatedHistory.isEmpty)
        #expect(LocalRecall.score(question, unrelated.text) == 0)
    }
    @Test func seedsEditableFoundationFilesWithoutInventingUser() async throws {
        let f = try Fixture(); defer { f.clean() }
        let documents = try await f.workspace.documents()
        #expect(documents.count == 5)
        #expect(documents.first { $0.kind == .identity }!.text.contains("Sela"))
        #expect(documents.first { $0.kind == .user }!.text.contains("尚未填写"))
        let identity = documents.first { $0.kind == .identity }!
        try await f.workspace.editDocument(.identity, text: "我是 Sela，用户的伙伴。", expectedRevision: identity.revision)
        let reloaded = try MemoryWorkspace(root: f.root)
        #expect(try await reloaded.documents().first { $0.kind == .identity }!.text == "我是 Sela，用户的伙伴。")
        let context = try await reloaded.context(ContextRequest(question: "你是谁", recipient: "provider-a"))
        #expect(context.personaInstructions.contains("用户的伙伴"))
        #expect(context.foundationReferences.count == 3)
        #expect(context.relevantMemories.isEmpty)
    }

    @Test func documentRevisionProtectsConcurrentEdits() async throws {
        let f = try Fixture(); defer { f.clean() }
        let document = try await f.workspace.documents().first { $0.kind == .user }!
        try await f.workspace.editDocument(.user, text: "称呼：小禾", expectedRevision: document.revision)
        await #expect(throws: MemoryError.self) {
            try await f.workspace.editDocument(.user, text: "过期版本", expectedRevision: document.revision)
        }
        #expect(try await f.workspace.documents().first { $0.kind == .user }!.text == "称呼：小禾")
    }

    @Test func bootstrapCompletionPersistsButDoesNotDeleteOwnerDocument() async throws {
        let f = try Fixture(); defer { f.clean() }
        try await f.workspace.completeBootstrap()
        let reloaded = try MemoryWorkspace(root: f.root)
        #expect(try await reloaded.bootstrapComplete())
        let context = try await reloaded.context(ContextRequest(question: "你好", recipient: "provider-a"))
        #expect(!context.foundationReferences.contains { $0.kind == .bootstrap })
        #expect(try await reloaded.documents().count == 5)
    }

    @Test func memoryOffExcludesPersonalizationButKeepsCurrentConversation() async throws {
        let f = try Fixture(); defer { f.clean() }
        let user = try await f.workspace.documents().first { $0.kind == .user }!
        try await f.workspace.editDocument(.user, text: "专属资料ABC", expectedRevision: user.revision)
        let id = try await f.conversation()
        let source = try await f.message("我优先直飞", conversation: id)
        try await f.workspace.remember(f.fact("直飞偏好", source: source))
        let context = try await f.workspace.context(ContextRequest(question: "直飞", recipient: "provider-a", conversationID: id, memoryEnabled: false))
        #expect(context.foundationReferences.isEmpty && context.relevantMemories.isEmpty && context.relatedHistory.isEmpty)
        #expect(context.recentMessages.count == 1)
        #expect(!(try context.referenceJSON()).contains("专属资料ABC"))
    }

    @Test func archiveKeepsMoreThanOneHundredMessagesAndFindsEarlierFacts() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        _ = try await f.message("最初确定的暗号是北极星739", conversation: id)
        for index in 0..<140 { _ = try await f.message("第\(index)条普通内容" + String(repeating: "继续讨论。", count: 25), conversation: id) }
        let reloaded = try MemoryWorkspace(root: f.root)
        #expect(try await reloaded.conversation(id).messages.count == 141)
        let context = try await reloaded.context(ContextRequest(question: "最初的暗号北极星739是什么", recipient: "provider-a", conversationID: id))
        #expect(context.needsSummary)
        #expect(context.relatedHistory.contains { $0.excerpt.contains("北极星739") })
        #expect(try context.characterCount() <= 32_000)
    }

    @Test func summaryCoversExactPrefixAndPreservesOpenQuestions() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let first = try await f.message("这次预算1500元", conversation: id)
        _ = try await f.message("出发时间还没确定", conversation: id)
        let summary = ConversationSummary(text: "准备旅行", coveredMessageIDs: [first.id], importantFacts: ["这次预算1500元"], openQuestions: ["出发时间未确定"])
        let record = try await f.workspace.conversation(id)
        try await f.workspace.saveSummary(summary, conversationID: id, expectedRevision: record.revision)
        let context = try await f.workspace.context(ContextRequest(question: "接着聊", recipient: "provider-a", conversationID: id))
        #expect(context.summary?.importantFacts == ["这次预算1500元"])
        #expect(context.summary?.openQuestions == ["出发时间未确定"])
        let before = try Data(contentsOf: f.root.appendingPathComponent("state.json"))
        await #expect(throws: MemoryError.self) {
            try await f.workspace.saveSummary(summary, conversationID: id, expectedRevision: record.revision)
        }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("state.json")) == before)
    }

    @Test func summaryRejectsMadeUpOrOutOfOrderCoverage() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        _ = try await f.message("第一条", conversation: id)
        let second = try await f.message("第二条", conversation: id)
        await #expect(throws: MemoryError.self) {
            try await f.workspace.saveSummary(ConversationSummary(text: "跳过了第一条", coveredMessageIDs: [second.id]), conversationID: id, expectedRevision: 2)
        }
        #expect(try await f.workspace.conversation(id).summary == nil)
    }

    @Test func assistantCannotBecomeAnActiveUserFact() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("我猜你喜欢喝咖啡", conversation: id, role: .assistant)
        await #expect(throws: MemoryError.self) { try await f.workspace.remember(f.fact("用户喜欢咖啡", source: source)) }
        #expect(try await f.workspace.memories().isEmpty)
    }

    @Test func temporaryBudgetStaysInItsConversation() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try await f.conversation()
        let source = try await f.message("这次预算1500元", conversation: first)
        try await f.workspace.remember(f.fact("这次预算1500元", source: source, scope: .conversation(first)))
        let other = try await f.conversation()
        let own = try await f.workspace.context(ContextRequest(question: "预算", recipient: "provider-a", conversationID: first))
        let fresh = try await f.workspace.context(ContextRequest(question: "预算", recipient: "provider-a", conversationID: other))
        #expect(own.relevantMemories.count == 1)
        #expect(fresh.relevantMemories.isEmpty)
        #expect(fresh.relatedHistory.contains { $0.sourceID == first })
    }

    @Test func recipientBoundaryAppliesToAllHistoryAndCurrentIdentifiers() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("我只坐直飞", conversation: id)
        try await f.workspace.remember(f.fact("直飞偏好", source: source))
        let context = try await f.workspace.context(ContextRequest(question: "直飞", recipient: "provider-b"))
        #expect(context.relevantMemories.isEmpty && context.relatedHistory.isEmpty)
        await #expect(throws: MemoryError.self) { _ = try await f.workspace.context(ContextRequest(question: "继续", recipient: "provider-b", conversationID: id)) }
        await #expect(throws: MemoryError.self) { try await f.workspace.remember(f.fact("直飞偏好", source: source, recipient: "provider-b")) }
    }

    @Test func newerFactReplacesOldFactAndExpiredFactsAreNotRetrieved() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try await f.message("我喜欢靠窗", conversation: id)
        try await f.workspace.remember(f.fact("我喜欢靠窗", source: old, now: now))
        let newer = try await f.message("我改成喜欢过道", conversation: id)
        try await f.workspace.remember(f.fact("我喜欢过道", source: newer, now: now.addingTimeInterval(1)))
        let active = try await f.workspace.memories()
        #expect(active.count == 1 && active[0].text.contains("过道"))
        await #expect(throws: MemoryError.self) { try await f.workspace.remember(f.fact("旧版本再次写入", source: old, now: now)) }
        try await f.workspace.remember(f.fact("临时过道安排", source: newer, key: "expired", now: now, expiresAt: now))
        let context = try await f.workspace.context(ContextRequest(question: "我的偏好", recipient: "provider-a", now: now.addingTimeInterval(2)))
        #expect(!context.relevantMemories.contains { $0.key == "expired" || $0.text.contains("靠窗") })
    }

    @Test func forgettingInvalidatesDerivedFactsSummariesAndAutomaticRecall() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("我的专属暗号是海星882", conversation: id)
        let fact = f.fact("专属暗号海星882", source: source)
        try await f.workspace.remember(fact)
        try await f.workspace.saveSummary(ConversationSummary(text: "暗号海星882", coveredMessageIDs: [source.id]), conversationID: id, expectedRevision: 1)
        try await f.workspace.forgetMemory(fact.id)
        let context = try await f.workspace.context(ContextRequest(question: "专属暗号", recipient: "provider-a", conversationID: id))
        #expect(context.summary == nil && context.relevantMemories.isEmpty && context.recentMessages.isEmpty && context.relatedHistory.isEmpty)
        #expect(!(try context.referenceJSON()).contains("海星882"))
        #expect(try await f.workspace.conversation(id).messages[0].text.contains("海星882"))
        #expect(try await f.workspace.learningBatch(conversationID: id) == nil)
        _ = try await f.message("重新开始讨论旅行", conversation: id)
        let batch = try await f.workspace.learningBatch(conversationID: id)!
        try await f.workspace.applyLearning(LearningOutput(summary: ConversationSummary(text: "讨论旅行", coveredMessageIDs: batch.coveredMessageIDs)), batch: batch)
        #expect(try await f.workspace.conversation(id).summary?.text == "讨论旅行")
    }

    @Test func deletingConversationRemovesItsDerivedMemoryAndUnlinksWork() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("只坐直飞", conversation: id)
        try await f.workspace.remember(f.fact("直飞偏好", source: source))
        let work = MemoryWork(title: "查航班", recipient: "provider-a", conversationID: id, originalGoal: "查询航班", steps: [WorkStep(goal: "查询")])
        try await f.workspace.createWork(work)
        try await f.workspace.deleteConversation(id)
        #expect(try await f.workspace.conversations().isEmpty)
        #expect(try await f.workspace.memories().isEmpty)
        #expect(try await f.workspace.work(work.id).conversationID == nil)
    }

    @Test func workUnknownResultCannotBeCompletedOrSilentlyReplayed() async throws {
        let f = try Fixture(); defer { f.clean() }
        let step = WorkStep(goal: "提交查询"), action = UUID()
        let work = MemoryWork(title: "查询", recipient: "provider-a", originalGoal: "只查询不预订", steps: [step])
        try await f.workspace.createWork(work)
        try await f.workspace.recordReceipt(WorkReceipt(actionID: action, stepID: step.id, outcome: .unknown, detail: "等待核验"), workID: work.id, expectedRevision: 0)
        await #expect(throws: MemoryError.self) { try await f.workspace.setWorkStatus(.completed, workID: work.id, expectedRevision: 1) }
        let paused = try await f.workspace.work(work.id)
        #expect(paused.steps[0].state == .unknown && paused.unresolvedActions == [action])
        try await f.workspace.recordReceipt(WorkReceipt(actionID: action, stepID: step.id, outcome: .verifiedSuccess, detail: "工具核验已完成查询"), workID: work.id, expectedRevision: 1)
        try await f.workspace.setWorkStatus(.completed, workID: work.id, expectedRevision: 2)
        let reloaded = try MemoryWorkspace(root: f.root)
        #expect(try await reloaded.work(work.id).status == .completed)
        await #expect(throws: MemoryError.self) { try await reloaded.setWorkStatus(.running, workID: work.id, expectedRevision: 3) }
    }

    @Test func workKeepsOriginalGoalAmendmentsAndMoreThanOneHundredSteps() async throws {
        let f = try Fixture(); defer { f.clean() }
        let work = MemoryWork(title: "长任务", recipient: "provider-a", originalGoal: "原始目标不可丢失", steps: (0..<2000).map { WorkStep(goal: "第\($0)项") })
        try await f.workspace.createWork(work)
        try await f.workspace.amendWork(work.id, text: "新的明确要求", expectedRevision: 0)
        try await f.workspace.setWorkStatus(.paused, workID: work.id, expectedRevision: 1)
        let reloaded = try MemoryWorkspace(root: f.root)
        #expect(try await reloaded.work(work.id).steps.count == 2000)
        #expect(try await reloaded.work(work.id).originalGoal == "原始目标不可丢失")
        #expect(try await reloaded.work(work.id).amendments == ["新的明确要求"])
        #expect(try await reloaded.work(work.id).status == .paused)
        await #expect(throws: MemoryError.self) { try await reloaded.amendWork(work.id, text: "过期补充", expectedRevision: 0) }
    }

    @Test func workContextCannotMixAnotherConversationOrTruncateMandatoryGoal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try await f.conversation(), other = try await f.conversation()
        let work = MemoryWork(title: "任务", recipient: "provider-a", conversationID: first,
            originalGoal: String(repeating: "重要原始要求", count: 2000), steps: [WorkStep(goal: "执行")])
        try await f.workspace.createWork(work)
        await #expect(throws: MemoryError.self) { _ = try await f.workspace.context(ContextRequest(question: "继续", recipient: "provider-a", conversationID: other, workID: work.id, mode: .work)) }
        await #expect(throws: MemoryError.self) { _ = try await f.workspace.context(ContextRequest(question: "继续", recipient: "provider-a", workID: work.id, mode: .work, maximumCharacters: 4096)) }
        let context = try await f.workspace.context(ContextRequest(question: "进度", recipient: "provider-a", workID: work.id, mode: .work))
        #expect(context.work?.originalGoal == work.originalGoal)
    }

    @Test func lateLearningCannotUpdateNewerConversationAndRollsBackAllFacts() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("我喜欢直飞", conversation: id)
        await #expect(throws: MemoryError.self) {
            try await f.workspace.refreshConversation(id, policy: .automatic) { batch in
                try await f.workspace.appendMessage(MemoryMessage(role: .user, text: "补充的新要求"), to: id)
                return LearningOutput(summary: ConversationSummary(text: "过期摘要", coveredMessageIDs: batch.coveredMessageIDs), memories: [f.fact("直飞偏好", source: source)])
            }
        }
        #expect(try await f.workspace.memories().isEmpty)
        #expect(try await f.workspace.conversation(id).summary == nil)
    }

    @Test func learningValidatesEvidenceAndNeverEditsFoundationFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("我喜欢直飞", conversation: id)
        let documents = try await f.workspace.documents()
        let batch = try await f.workspace.learningBatch(conversationID: id)!
        var invalid = f.fact("编造偏好", source: source); invalid.evidence[0].quote = "不存在的原话"
        await #expect(throws: MemoryError.self) {
            try await f.workspace.applyLearning(LearningOutput(summary: ConversationSummary(text: "摘要", coveredMessageIDs: batch.coveredMessageIDs), memories: [invalid]), batch: batch, policy: .automatic)
        }
        #expect(try await f.workspace.conversation(id).summary == nil)
        try await f.workspace.applyLearning(LearningOutput(summary: ConversationSummary(text: "用户偏好直飞", coveredMessageIDs: batch.coveredMessageIDs), memories: [f.fact("直飞偏好", source: source)]), batch: batch)
        #expect(try await f.workspace.memories().isEmpty)
        let candidate = try await f.workspace.memories(includeInactive: true).first!
        #expect(candidate.status == .candidate)
        try await f.workspace.approveCandidate(candidate.id)
        #expect(try await f.workspace.memories().count == 1)
        #expect(try await f.workspace.documents() == documents)
    }

    @Test func cancelledOrFailedDerivationDoesNotMutateMemory() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        _ = try await f.message("聊聊天", conversation: id)
        let before = try Data(contentsOf: f.root.appendingPathComponent("state.json"))
        await #expect(throws: CancellationError.self) {
            try await f.workspace.refreshConversation(id) { _ in throw CancellationError() }
        }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("state.json")) == before)
    }

    @Test func separateStoreInstancesDoNotLoseConcurrentWrites() async throws {
        let f = try Fixture(); defer { f.clean() }
        let second = try MemoryWorkspace(root: f.root), id = try await f.conversation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                let workspace = index.isMultiple(of: 2) ? f.workspace : second
                group.addTask { try await workspace.appendMessage(MemoryMessage(role: .user, text: "消息\(index)"), to: id) }
            }
            try await group.waitForAll()
        }
        #expect(try await f.workspace.conversation(id).messages.count == 30)
    }

    @Test func corruptOrFutureArchiveIsPreserved() async throws {
        let f = try Fixture(); defer { f.clean() }
        let path = f.root.appendingPathComponent("state.json")
        for bytes in [Data("{broken".utf8), Data("{\"schemaVersion\":99,\"revision\":0,\"bootstrapComplete\":false,\"conversations\":[],\"memories\":[],\"works\":[]}".utf8)] {
            try bytes.write(to: path)
            #expect(throws: MemoryError.self) { _ = try MemoryWorkspace(root: f.root) }
            #expect(try Data(contentsOf: path) == bytes)
        }
    }

    @Test func symlinkedDocumentCannotReadOrOverwriteOutsideWorkspace() async throws {
        let f = try Fixture(); defer { f.clean() }
        let outside = f.root.deletingLastPathComponent().appendingPathComponent("sela-outside-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("保留原文件".utf8).write(to: outside)
        let document = f.root.appendingPathComponent("USER.md")
        try FileManager.default.removeItem(at: document)
        try FileManager.default.createSymbolicLink(at: document, withDestinationURL: outside)
        await #expect(throws: MemoryError.self) { _ = try await f.workspace.documents() }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "保留原文件")
    }

    @Test func yesterdayRecallUsesMessageTimeAndShanghaiMidnight() async throws {
        let f = try Fixture(); defer { f.clean() }
        let now = ISO8601DateFormatter().date(from: "2026-10-25T00:30:00+08:00")!
        let id = try await f.conversation()
        try await f.workspace.appendMessage(MemoryMessage(role: .user, text: "昨天确认了去海边", date: now.addingTimeInterval(-3600)), to: id)
        try await f.workspace.appendMessage(MemoryMessage(role: .user, text: "今天新增了咖啡安排", date: now.addingTimeInterval(-300)), to: id)
        let context = try await f.workspace.context(ContextRequest(question: "昨天聊了什么", recipient: "provider-a", now: now, timeZoneIdentifier: "Asia/Shanghai"))
        #expect(context.relatedHistory.count == 1)
        #expect(context.relatedHistory[0].excerpt.contains("海边"))
        #expect(!context.relatedHistory[0].excerpt.contains("咖啡"))
        #expect(context.relatedHistory[0].updatedAt == now.addingTimeInterval(-3600))
    }

    @Test func ownerPinnedPreferenceIsIncludedForUnrelatedQuestions() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("以后回答简短一点", conversation: id)
        var fact = f.fact("回答简短", source: source); fact.pinned = true
        try await f.workspace.remember(fact)
        let context = try await f.workspace.context(ContextRequest(question: "解释一下黑洞", recipient: "provider-a"))
        #expect(context.relevantMemories.contains { $0.id == fact.id })
    }

    @Test func automaticLearningCannotForgeFutureTimeOrPinItself() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("我喜欢直飞", conversation: id)
        let batch = try await f.workspace.learningBatch(conversationID: id)!
        var fact = f.fact("直飞偏好", source: source, now: Date.distantFuture); fact.pinned = true
        try await f.workspace.applyLearning(LearningOutput(summary: ConversationSummary(text: "出行偏好", coveredMessageIDs: batch.coveredMessageIDs), memories: [fact]), batch: batch, policy: .automatic)
        let saved = try await f.workspace.memories().first!
        #expect(saved.updatedAt == source.date)
        #expect(saved.pinned == false)
    }

    @Test func optionalPinnedFieldIsBackwardCompatible() async throws {
        let f = try Fixture(); defer { f.clean() }
        let id = try await f.conversation()
        let source = try await f.message("喜欢直飞", conversation: id)
        try await f.workspace.remember(f.fact("喜欢直飞", source: source))
        let path = f.root.appendingPathComponent("state.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        var memories = object["memories"] as! [[String: Any]]; memories[0].removeValue(forKey: "pinned"); object["memories"] = memories
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        let reloaded = try MemoryWorkspace(root: f.root)
        #expect(try await reloaded.memories().count == 1)
    }
}
