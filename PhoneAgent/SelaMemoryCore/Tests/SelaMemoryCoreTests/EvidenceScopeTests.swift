import Foundation
import Testing
@testable import SelaMemoryCore

@Suite struct EvidenceScopeTests {
    private func admitted(source text: String, quote: String? = nil, key: String, factText: String) async throws -> (RememberedFact, Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sela-scope-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try MemoryWorkspace(root: root)
        let conversation = try await workspace.createConversation(MemoryConversation(title: "来源范围测试", recipient: "provider-a"))
        let message = MemoryMessage(role: .user, text: text)
        try await workspace.appendMessage(message, to: conversation)
        let batch = try await workspace.learningBatch(conversationID: conversation)!
        let fact = RememberedFact(key: key, text: factText, scope: .personal, kind: .preference,
            recipient: "provider-a", evidence: [Evidence(messageID: message.id, quote: quote ?? text)])
        try await workspace.applyLearning(.init(summary: .init(text: "记录用户提供的参数", coveredMessageIDs: batch.coveredMessageIDs), memories: [fact]),
            batch: batch, policy: .automatic)
        let saved = try await workspace.memories().first!
        let context = try await workspace.context(.init(question: factText, recipient: "provider-a", includeOtherConversations: false))
        return (saved, context.relevantMemories.contains { $0.id == saved.id })
    }

    @Test func oneOffBudgetCannotBecomePersonalEvenWhenModelProposesIt() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次机票预算1500元", key: "travel.budget", factText: "机票预算1500元")
        if case .conversation = fact.scope {} else { Issue.record("Explicit one-off budget escaped its conversation") }
        #expect(!crossConversation && fact.text == "机票预算1500元")
    }

    @Test func unrelatedFutureCommunicationClauseDoesNotUpgradeTemporaryBudget() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次机票预算1500元，以后回答简短一点", key: "travel.budget", factText: "机票预算1500元")
        if case .conversation = fact.scope {} else { Issue.record("Unrelated durable instruction upgraded a one-off budget") }
        #expect(!crossConversation)
    }

    @Test func shortenedQuoteCannotRemoveTemporaryQualifier() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次机票预算1500元", quote: "预算1500元", key: "travel.budget", factText: "机票预算1500元")
        if case .conversation = fact.scope {} else { Issue.record("A shortened quote discarded its source qualifier") }
        #expect(!crossConversation)
    }

    @Test func commaAfterStandaloneTemporaryQualifierDoesNotPromoteBudget() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次，机票预算1500元", quote: "机票预算1500元", key: "travel.budget", factText: "机票预算1500元")
        if case .conversation = fact.scope {} else { Issue.record("A comma detached the temporary qualifier") }
        #expect(!crossConversation)
    }

    @Test func futureBudgetWithAnotherValueDoesNotUpgradeOneOffBudget() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次机票预算1500元，以后机票预算默认2000元", key: "travel.budget", factText: "机票预算1500元")
        if case .conversation = fact.scope {} else { Issue.record("Another budget value upgraded the temporary parameter") }
        #expect(!crossConversation)
    }

    @Test func futureDefaultIsNotDowngradedByAnotherOneOffBudget() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次机票预算1500元，以后机票预算默认2000元", key: "travel.budget", factText: "机票预算默认2000元")
        #expect(fact.scope == .personal && crossConversation)
    }

    @Test func relativeMeetingTimeRemainsConversationScoped() async throws {
        let (fact, crossConversation) = try await admitted(source: "明天下午三点开项目复盘会", key: "meeting.start_time", factText: "项目会议时间是明天下午三点")
        if case .conversation = fact.scope {} else { Issue.record("Single meeting time became a personal default") }
        #expect(!crossConversation)
    }

    @Test func absoluteMeetingDateRemainsConversationScoped() async throws {
        let (fact, crossConversation) = try await admitted(source: "2026年10月26日下午三点开项目复盘会", key: "meeting.start_time", factText: "项目会议时间是2026年10月26日下午三点")
        if case .conversation = fact.scope {} else { Issue.record("An explicit meeting date became a personal default") }
        #expect(!crossConversation)
    }

    @Test func datedDefaultIsStillForThatMeeting() async throws {
        let (fact, crossConversation) = try await admitted(source: "明天会议默认半小时", key: "meeting.default_duration", factText: "会议默认半小时")
        if case .conversation = fact.scope {} else { Issue.record("A default for tomorrow's meeting became a personal default") }
        #expect(!crossConversation)
    }

    @Test func datedBudgetRemainsConversationScoped() async throws {
        let (fact, crossConversation) = try await admitted(source: "明天机票预算1500元", key: "travel.budget", factText: "机票预算1500元")
        if case .conversation = fact.scope {} else { Issue.record("A dated budget became a personal default") }
        #expect(!crossConversation)
    }

    @Test func explicitDefaultStartingTodayRemainsPersonal() async throws {
        let (fact, crossConversation) = try await admitted(source: "从今天开始项目会议默认半小时", key: "meeting.default_duration", factText: "项目会议默认半小时")
        #expect(fact.scope == .personal && crossConversation)
    }

    @Test func oneOrderQuantityRemainsConversationScoped() async throws {
        let (fact, crossConversation) = try await admitted(source: "这单鸡肉饭买两份", key: "goods.quantity", factText: "鸡肉饭数量为两份")
        if case .conversation = fact.scope {} else { Issue.record("Single-order quantity became a personal default") }
        #expect(!crossConversation)
    }

    @Test func thisTimeIntroductionDoesNotDowngradeIdentity() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次我告诉你，我叫张三", key: "profile.preferred_name", factText: "用户希望被称呼张三")
        #expect(fact.scope == .personal && crossConversation)
    }

    @Test func explicitFutureParameterDefaultRemainsPersonal() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次我告诉你，以后项目会议默认半小时", key: "meeting.default_duration", factText: "项目会议默认持续半小时")
        #expect(fact.scope == .personal && crossConversation)
    }

    @Test func explicitFutureBudgetDefaultRemainsPersonal() async throws {
        let (fact, crossConversation) = try await admitted(source: "以后每次出差的机票预算默认2000元", key: "travel.budget", factText: "出差机票预算默认2000元")
        #expect(fact.scope == .personal && crossConversation)
    }

    @Test func thisRequestDefaultIsStillTemporary() async throws {
        let (fact, crossConversation) = try await admitted(source: "这次默认使用工作日历", key: "calendar.default", factText: "使用工作日历")
        if case .conversation = fact.scope {} else { Issue.record("A one-request default became a personal default") }
        #expect(!crossConversation)
    }

    @Test func ownerRememberRetainsExplicitlySelectedScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sela-manual-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try MemoryWorkspace(root: root)
        let id = try await workspace.createConversation(.init(title: "手工范围", recipient: "provider-a"))
        let source = MemoryMessage(role: .user, text: "这次预算1500元")
        try await workspace.appendMessage(source, to: id)
        let fact = RememberedFact(key: "travel.budget", text: source.text, scope: .personal, kind: .fact,
            recipient: "provider-a", evidence: [.init(messageID: source.id, quote: source.text)])
        try await workspace.remember(fact)
        #expect(try await workspace.memories().first?.scope == .personal)
    }
}
