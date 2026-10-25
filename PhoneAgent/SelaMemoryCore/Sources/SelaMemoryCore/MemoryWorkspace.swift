import Foundation

public actor MemoryWorkspace {
    let disk: DiskStore
    public nonisolated let root: URL
    public init(root: URL) throws { let disk = try DiskStore(root: root); self.disk = disk; self.root = disk.root }

    public func documents() throws -> [DocumentSnapshot] {
        try disk.lock { try FoundationDocument.allCases.map { try disk.document($0) } }
    }
    /// Only an explicit owner edit uses this API. Automatic learning cannot write foundation files.
    public func editDocument(_ kind: FoundationDocument, text: String, expectedRevision: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else {
            throw MemoryError.invalid("资料不能为空，或超过了文件容量上限。")
        }
        try disk.lock {
            guard try disk.document(kind).revision == expectedRevision else { throw MemoryError.stale }
            try disk.atomic(Data(text.utf8), to: disk.child(kind.rawValue))
        }
    }
    public func completeBootstrap() throws { try disk.transaction { $0.bootstrapComplete = true } }
    public func bootstrapComplete() throws -> Bool { try disk.snapshot().bootstrapComplete }
    public func learningPreferences() throws -> LearningPreferences { try disk.snapshot().learningPreferences ?? LearningPreferences() }
    public func setLearningPreferences(_ preferences: LearningPreferences) throws {
        try disk.transaction { $0.learningPreferences = preferences }
    }

    @discardableResult public func createConversation(_ conversation: MemoryConversation) throws -> UUID {
        guard !conversation.title.isEmpty, !conversation.recipient.isEmpty, conversation.messages.isEmpty,
              conversation.summary == nil, conversation.revision == 0 else { throw MemoryError.invalid("新对话参数无效。") }
        return try disk.transaction { state in
            guard !state.conversations.contains(where: { $0.id == conversation.id }) else { throw MemoryError.invalid("对话 ID 已存在。") }
            state.conversations.append(conversation); return conversation.id
        }
    }
    public func conversations() throws -> [MemoryConversation] {
        try disk.snapshot().conversations.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func conversation(_ id: UUID) throws -> MemoryConversation {
        guard let record = try disk.snapshot().conversations.first(where: { $0.id == id }) else { throw MemoryError.missing("对话") }
        return record
    }
    public func appendMessage(_ message: MemoryMessage, to id: UUID) throws {
        guard !message.text.isEmpty, message.text.utf8.count <= 250_000, !message.excludedFromRecall else { throw MemoryError.invalid("消息内容无效。") }
        try disk.transaction { state in
            guard let index = state.conversations.firstIndex(where: { $0.id == id }) else { throw MemoryError.missing("对话") }
            if let existing = state.conversations.flatMap(\.messages).first(where: { $0.id == message.id }) {
                guard state.conversations[index].messages.contains(existing), existing == message else { throw MemoryError.invalid("消息 ID 冲突。") }
                return
            }
            state.conversations[index].messages.append(message)
            state.conversations[index].revision += 1; state.conversations[index].updatedAt = message.date
        }
    }
    public func saveSummary(_ summary: ConversationSummary, conversationID: UUID, expectedRevision: Int) throws {
        try disk.transaction { state in try Self.applySummary(summary, id: conversationID, revision: expectedRevision, state: &state) }
    }
    static func applySummary(_ summary: ConversationSummary, id: UUID, revision: Int, state: inout Archive) throws {
        guard let index = state.conversations.firstIndex(where: { $0.id == id }) else { throw MemoryError.missing("对话") }
        let record = state.conversations[index]
        guard record.revision == revision else { throw MemoryError.stale }
        let eligible = record.messages.filter { !$0.excludedFromRecall }
        let count = summary.coveredMessageIDs.count
        guard count > 0, count <= eligible.count, !summary.text.isEmpty,
              summary.text.count <= 6000, summary.importantFacts.joined().count <= 6000,
              summary.openQuestions.joined().count <= 3000,
              summary.coveredMessageIDs == eligible.prefix(count).map(\.id),
              count >= (record.summary?.coveredMessageIDs.count ?? 0) else { throw MemoryError.invalid("摘要来源或覆盖范围无效。") }
        state.conversations[index].summary = summary
        state.conversations[index].revision += 1
    }

    public func remember(_ fact: RememberedFact) throws {
        try disk.transaction { state in try Self.applyFact(fact, state: &state) }
    }
    static func applyFact(_ fact: RememberedFact, state: inout Archive) throws {
        guard !fact.key.isEmpty, fact.key.count <= 160, !fact.text.isEmpty, fact.text.count <= 4000,
              !fact.recipient.isEmpty, !fact.evidence.isEmpty, fact.evidence.count <= 8,
              [.active, .candidate].contains(fact.status), !state.memories.contains(where: { $0.id == fact.id }) else {
            throw MemoryError.invalid("记忆内容、来源或 ID 无效。")
        }
        for evidence in fact.evidence {
            guard let source = state.conversations.first(where: { $0.messages.contains(where: { $0.id == evidence.messageID }) }),
                  source.recipient == fact.recipient,
                  let message = source.messages.first(where: { $0.id == evidence.messageID }),
                  !message.excludedFromRecall, !evidence.quote.isEmpty, message.text.contains(evidence.quote) else {
                throw MemoryError.invalid("记忆缺少真实来源，或来源不属于当前接收方。")
            }
            if fact.status == .active, message.role != .user { throw MemoryError.invalid("助手回复和工具文字不能自动成为用户事实。") }
            switch fact.scope {
            case .personal: break
            case .topic(let topic): guard !topic.isEmpty, source.topic == topic else { throw MemoryError.invalid("话题范围不匹配。") }
            case .conversation(let id): guard source.id == id else { throw MemoryError.invalid("对话范围不匹配。") }
            case .work(let id):
                guard state.works.contains(where: { $0.id == id && $0.recipient == fact.recipient && $0.conversationID == source.id }) else {
                    throw MemoryError.invalid("任务范围不匹配。")
                }
            }
        }
        if fact.status == .active {
            if let index = state.memories.firstIndex(where: { $0.key == fact.key && $0.scope == fact.scope &&
                $0.recipient == fact.recipient && $0.status == .active && $0.text == fact.text && $0.kind == fact.kind &&
                $0.expiresAt == fact.expiresAt && ($0.pinned == true) == (fact.pinned == true) }) {
                guard state.memories[index].updatedAt <= fact.updatedAt else { throw MemoryError.stale }
                let merged = state.memories[index].evidence + fact.evidence.filter { !state.memories[index].evidence.contains($0) }
                state.memories[index].evidence = Array(merged.suffix(8))
                state.memories[index].updatedAt = fact.updatedAt
                return
            }
            for index in state.memories.indices where state.memories[index].key == fact.key &&
                state.memories[index].scope == fact.scope && state.memories[index].recipient == fact.recipient && state.memories[index].status == .active {
                guard state.memories[index].updatedAt <= fact.updatedAt else { throw MemoryError.stale }
                state.memories[index].status = .superseded
            }
        }
        state.memories.append(fact)
    }
    public func memories(includeInactive: Bool = false) throws -> [RememberedFact] {
        try disk.snapshot().memories.filter { includeInactive || $0.status == .active }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func approveCandidate(_ id: UUID) throws {
        try disk.transaction { state in
            guard let index = state.memories.firstIndex(where: { $0.id == id && $0.status == .candidate }) else { throw MemoryError.missing("候选记忆") }
            var candidate = state.memories.remove(at: index)
            candidate.status = .active
            try Self.applyFact(candidate, state: &state)
        }
    }
    /// Forget sourced facts and derived summaries together. Original messages remain visible in history,
    /// but are excluded from automatic model context and subsequent learning.
    public func forgetMemory(_ id: UUID) throws {
        try disk.transaction { state in
            guard let fact = state.memories.first(where: { $0.id == id }) else { throw MemoryError.missing("记忆") }
            if fact.status == .forgotten { return }
            let family = state.memories.filter { $0.recipient == fact.recipient && $0.scope == fact.scope && $0.key == fact.key }
            let sources = Set(family.flatMap(\.evidence).map(\.messageID))
            Self.eraseDerived(sources: sources, state: &state)
        }
    }
    static func eraseDerived(sources: Set<UUID>, state: inout Archive) {
        for index in state.memories.indices where !sources.isDisjoint(with: state.memories[index].evidence.map(\.messageID)) {
            state.memories[index].status = .forgotten; state.memories[index].text = ""
            state.memories[index].key = ""; state.memories[index].evidence = []
        }
        for index in state.conversations.indices {
            let affected = state.conversations[index].messages.indices.filter { sources.contains(state.conversations[index].messages[$0].id) }
            guard !affected.isEmpty else { continue }
            for message in affected { state.conversations[index].messages[message].excludedFromRecall = true }
            state.conversations[index].summary = nil; state.conversations[index].revision += 1
        }
    }
    public func deleteConversation(_ id: UUID) throws {
        try disk.transaction { state in
            guard let conversation = state.conversations.first(where: { $0.id == id }) else { return }
            Self.eraseDerived(sources: Set(conversation.messages.map(\.id)), state: &state)
            state.conversations.removeAll { $0.id == id }
            for index in state.works.indices where state.works[index].conversationID == id { state.works[index].conversationID = nil }
        }
    }

    public func clearLearnedMemories() throws {
        try disk.transaction { state in
            Self.eraseDerived(sources: Set(state.conversations.flatMap(\.messages).map(\.id)), state: &state)
        }
    }

    public func createWork(_ work: MemoryWork) throws {
        guard !work.title.isEmpty, !work.recipient.isEmpty, !work.originalGoal.isEmpty, !work.steps.isEmpty,
              Set(work.steps.map(\.id)).count == work.steps.count, work.steps.allSatisfy({ !$0.goal.isEmpty && $0.state == .pending }),
              work.receipts.isEmpty, work.amendments.isEmpty, work.artifacts.isEmpty,
              work.status == .pending, work.revision == 0 else { throw MemoryError.invalid("新任务参数无效。") }
        try disk.transaction { state in
            guard !state.works.contains(where: { $0.id == work.id }) else { throw MemoryError.invalid("任务 ID 已存在。") }
            if let id = work.conversationID {
                guard state.conversations.contains(where: { $0.id == id && $0.recipient == work.recipient }) else { throw MemoryError.invalid("关联对话不属于当前接收方。") }
            }
            state.works.append(work)
        }
    }
    public func works() throws -> [MemoryWork] { try disk.snapshot().works.sorted { $0.updatedAt > $1.updatedAt } }
    public func work(_ id: UUID) throws -> MemoryWork {
        guard let record = try disk.snapshot().works.first(where: { $0.id == id }) else { throw MemoryError.missing("任务") }
        return record
    }
    public func amendWork(_ id: UUID, text: String, expectedRevision: Int, now: Date = Date()) throws {
        guard !text.isEmpty else { throw MemoryError.invalid("补充要求不能为空。") }
        try updateWork(id, revision: expectedRevision, now: now) { work in
            guard ![.completed, .stopped].contains(work.status) else { throw MemoryError.invalid("原任务已结束，请创建新任务。") }
            work.amendments.append(text)
        }
    }
    public func recordReceipt(_ receipt: WorkReceipt, workID: UUID, expectedRevision: Int) throws {
        try updateWork(workID, revision: expectedRevision, now: receipt.date) { work in
            if let existing = work.receipts.first(where: { $0.id == receipt.id }) {
                guard existing == receipt else { throw MemoryError.invalid("回执 ID 冲突。") }; return
            }
            guard ![.completed, .stopped].contains(work.status), !receipt.detail.isEmpty,
                  let index = work.steps.firstIndex(where: { $0.id == receipt.stepID }),
                  work.receipts.filter({ $0.actionID == receipt.actionID }).allSatisfy({ $0.stepID == receipt.stepID }) else {
                throw MemoryError.invalid("回执与任务或步骤不匹配。")
            }
            work.receipts.append(receipt)
            let unresolved = Set(work.unresolvedActions)
            let unknown = work.receipts.contains { $0.stepID == receipt.stepID && unresolved.contains($0.actionID) }
            work.steps[index].state = unknown ? .unknown : receipt.outcome == .verifiedSuccess ? .verified : receipt.outcome == .verifiedFailure ? .failed : .unknown
        }
    }
    public func setWorkStatus(_ status: WorkStatus, workID: UUID, expectedRevision: Int, now: Date = Date()) throws {
        try updateWork(workID, revision: expectedRevision, now: now) { work in
            guard ![.completed, .stopped].contains(work.status) || status == work.status else { throw MemoryError.invalid("已结束任务不能自动恢复。") }
            if status == .completed {
                guard work.steps.allSatisfy({ $0.state == .verified }), work.unresolvedActions.isEmpty else {
                    throw MemoryError.invalid("仍有未完成步骤或未知结果，不能标记完成。")
                }
            }
            work.status = status
        }
    }
    public func addArtifact(_ reference: String, workID: UUID, expectedRevision: Int) throws {
        guard !reference.isEmpty else { throw MemoryError.invalid("产物引用不能为空。") }
        try updateWork(workID, revision: expectedRevision, now: Date()) { work in
            if !work.artifacts.contains(reference) { work.artifacts.append(reference) }
        }
    }
    private func updateWork(_ id: UUID, revision: Int, now: Date, update: (inout MemoryWork) throws -> Void) throws {
        try disk.transaction { state in
            guard let index = state.works.firstIndex(where: { $0.id == id }) else { throw MemoryError.missing("任务") }
            guard state.works[index].revision == revision else { throw MemoryError.stale }
            try update(&state.works[index]); state.works[index].revision += 1; state.works[index].updatedAt = now
        }
    }
}
