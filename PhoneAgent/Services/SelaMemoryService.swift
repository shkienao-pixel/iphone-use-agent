import Foundation
import Combine
import CryptoKit
import SelaMemoryCore

struct PreparedAssistantMemory {
    var identity = ""
    var reference = ""
    var excludedMessageIDs: Set<UUID> = []
    var recallRevision: String? = nil
    var canUseConversationHistory = true
    static func unavailable(excluded: Set<UUID> = []) -> Self {
        .init(reference: "{\"availability\":\"unavailable\",\"notices\":[\"本轮记忆或来源排除状态不可读取，不能据此断言用户从未提供过资料；不要从旧摘要恢复被忘记的内容。\"]}",
              excludedMessageIDs: excluded, canUseConversationHistory: false)
    }
}

@MainActor
final class SelaMemoryService: ObservableObject {
    @Published private(set) var documents: [DocumentSnapshot] = []
    @Published private(set) var learned: [RememberedFact] = []
    @Published private(set) var automaticLearning = true
    @Published private(set) var error = ""
    let workspace: MemoryWorkspace?
    private var learner: ConversationMemoryLearner?
    private var connection = ""
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var clearing = false
    private(set) var recallGeneration = UUID()
    private var knownExclusions: Set<UUID> = []
    private var recallMutations = 0
    private let configuration: () -> AgentSettings
    private let credential: (String) -> String
    private let derive: (ConversationLearningRequest, AgentSettings, String) async throws -> Data

    init(root: URL? = nil, configuration: @escaping () -> AgentSettings = SettingsStore.load,
         credential: @escaping (String) -> String = { SettingsStore.apiKey(for: $0) },
         derive: @escaping (ConversationLearningRequest, AgentSettings, String) async throws -> Data = { request, settings, key in
             try await SelaMemoryModelClient(settings: settings, apiKey: key).extract(request)
         }) {
        self.configuration = configuration; self.credential = credential; self.derive = derive
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/Intelligence", isDirectory: true)
        do { workspace = try MemoryWorkspace(root: root) }
        catch { workspace = nil; self.error = error.localizedDescription }
        Task { [weak self] in await self?.reload() }
    }
    static func recipient(_ settings: AgentSettings) -> String {
        settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + PrivacyConsent.recipient(settings)
    }
    private func valid(_ settings: AgentSettings, key: String? = nil) -> Bool {
        let current = configuration()
        return !clearing && recallMutations == 0 && current.useMemories == true && PrivacyConsent.allowed(current) && PrivacyConsent.allowed(settings) &&
            Self.recipient(current) == Self.recipient(settings) && current.model == settings.model &&
            (key == nil || credential(settings.endpoint) == key)
    }
    func reload() async {
        guard let workspace else { return }
        do {
            documents = try await workspace.documents()
            learned = try await workspace.memories(includeInactive: true).filter { $0.status == .active || $0.status == .candidate }
            automaticLearning = try await workspace.learningPreferences().learnFromConversations
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    func setAutomaticLearning(_ enabled: Bool, settings: AgentSettings) async {
        guard let workspace else { return }
        automaticLearning = enabled
        if !enabled { await learner?.cancelAll() }
        do { try await workspace.setLearningPreferences(LearningPreferences(useMemories: settings.useMemories == true, learnFromConversations: enabled)) }
        catch { self.error = error.localizedDescription }
    }
    func settingsChanged(_ settings: AgentSettings) async {
        guard let workspace else { return }
        do {
            let previous = try await workspace.learningPreferences()
            if settings.useMemories != true || !PrivacyConsent.allowed(settings) { await learner?.cancelAll() }
            let updated = LearningPreferences(useMemories: settings.useMemories == true, learnFromConversations: previous.learnFromConversations)
            if previous != updated { try await workspace.setLearningPreferences(updated) }
        } catch { self.error = error.localizedDescription }
    }
    func save(_ document: DocumentSnapshot, text: String) async throws {
        guard let workspace else { throw AgentError.message(error) }
        recallMutations += 1
        defer { recallMutations -= 1; recallGeneration = UUID() }
        recallGeneration = UUID()
        try await workspace.editDocument(document.kind, text: text, expectedRevision: document.revision)
        await reload()
    }
    func forget(_ memory: RememberedFact) async throws {
        guard let workspace else { throw AgentError.message(error) }
        recallMutations += 1
        defer { recallMutations -= 1; recallGeneration = UUID() }
        recallGeneration = UUID()
        try await workspace.forgetMemory(memory.id); await reload()
    }
    func approve(_ memory: RememberedFact) async throws {
        guard let workspace else { throw AgentError.message(error) }
        recallMutations += 1
        defer { recallMutations -= 1; recallGeneration = UUID() }
        recallGeneration = UUID()
        try await workspace.approveCandidate(memory.id); await reload()
    }
    func excludedMessages(in conversationID: UUID) async -> Set<UUID> {
        (try? await recallExclusions(in: conversationID)) ?? knownExclusions
    }
    func recallExclusions(in conversationID: UUID? = nil) async throws -> Set<UUID> {
        guard let workspace else { throw AgentError.message("记忆来源排除状态暂不可读取") }
        guard recallMutations == 0 else { throw MemoryError.stale }
        let generation = recallGeneration
        let ids: Set<UUID>
        if let conversationID {
            do { ids = Set(try await workspace.conversation(conversationID).messages.filter(\.excludedFromRecall).map(\.id)) }
            catch MemoryError.missing(_) { return [] }
        } else {
            ids = Set(try await workspace.conversations().flatMap(\.messages).filter(\.excludedFromRecall).map(\.id))
        }
        guard generation == recallGeneration else { throw MemoryError.stale }
        knownExclusions.formUnion(ids)
        return ids.union(knownExclusions)
    }
    func clearPersonalMemory() async throws {
        guard let workspace else { throw AgentError.message(error) }
        guard !clearing else { throw AgentError.message("正在清空记忆。") }
        clearing = true; defer { clearing = false }
        recallMutations += 1
        defer { recallMutations -= 1; recallGeneration = UUID() }
        recallGeneration = UUID()
        let pending = Array(jobs.values)
        for job in pending { job.cancel() }; jobs.removeAll()
        await learner?.cancelAll()
        for job in pending { await job.value }
        try await workspace.clearLearnedMemories()
        for document in try await workspace.documents() where [.user, .memory].contains(document.kind) {
            try await workspace.editDocument(document.kind, text: document.kind.starter, expectedRevision: document.revision)
        }
        await reload()
    }
    func exportText() async throws -> Data {
        guard let workspace else { throw AgentError.message(error) }
        struct Export: Encodable { let documents: [DocumentSnapshot]; let memories: [RememberedFact] }
        return try JSONEncoder().encode(Export(documents: try await workspace.documents(),
            memories: try await workspace.memories(includeInactive: true).filter { $0.status == .active || $0.status == .candidate }))
    }
    private func synchronize(_ id: UUID, messages: [AssistantMessage], settings: AgentSettings) async throws {
        guard let workspace else { throw AgentError.message(error) }
        let boundary = Self.recipient(settings)
        var existing = try await workspace.conversations().first { $0.id == id }
        if let existing, existing.recipient != boundary { throw AgentError.message("对话的模型接收方已改变。") }
        if messages.isEmpty, existing?.messages.isEmpty == false {
            recallGeneration = UUID()
            try await workspace.deleteConversation(id); existing = nil
        }
        if existing == nil {
            try await workspace.createConversation(MemoryConversation(id: id,
                title: String((messages.first { $0.role == "user" }?.text ?? "新对话").prefix(80)), recipient: boundary))
        }
        let known = Dictionary(uniqueKeysWithValues: (existing?.messages ?? []).map { ($0.id, $0) })
        for message in messages where ["user", "assistant"].contains(message.role) {
            try Task.checkCancellation()
            if let saved = known[message.id] {
                guard saved.text == message.text, saved.role.rawValue == message.role else { throw AgentError.message("对话原文已改变，请重新核对记录。") }
                continue
            }
            try await workspace.appendMessage(MemoryMessage(id: message.id, role: message.role == "user" ? .user : .assistant,
                text: message.text, date: message.createdAt), to: id)
        }
    }
    func prepare(question: String, conversationID: UUID? = nil, messages: [AssistantMessage] = [], settings: AgentSettings) async -> PreparedAssistantMemory {
        guard let workspace else { return .unavailable(excluded: knownExclusions) }
        guard valid(settings) else {
            if let excluded = try? await recallExclusions() { return PreparedAssistantMemory(excludedMessageIDs: excluded) }
            return .unavailable(excluded: knownExclusions)
        }
        do {
            await settingsChanged(settings)
            let generation = recallGeneration
            if let conversationID { try await synchronize(conversationID, messages: messages, settings: settings) }
            var context = try await workspace.context(ContextRequest(question: question, recipient: Self.recipient(settings),
                conversationID: conversationID, maximumCharacters: 28_000, includeOtherConversations: false))
            // Existing chat clients carry these exact recent turns (including attachments).
            // Cross-chat references continue through the app's relevance-checked disclosure path.
            let recent = Set(messages.suffix(12).map(\.id))
            context.recentMessages.removeAll { recent.contains($0.id) }
            context.relatedHistory.removeAll { $0.kind != "earlierMessage" }
            let excluded = try await recallExclusions()
            guard valid(settings), generation == recallGeneration else { return PreparedAssistantMemory(excludedMessageIDs: excluded) }
            return PreparedAssistantMemory(identity: context.personaInstructions, reference: try context.referenceJSON(),
                excludedMessageIDs: excluded)
        } catch {
            self.error = error.localizedDescription
            if let excluded = try? await recallExclusions() { return PreparedAssistantMemory(excludedMessageIDs: excluded) }
            return .unavailable(excluded: knownExclusions)
        }
    }
    func completedTurn(conversationID: UUID, messages: [AssistantMessage], settings: AgentSettings, apiKey: String) {
        guard valid(settings, key: apiKey), workspace != nil else { return }
        jobs[conversationID]?.cancel()
        jobs[conversationID] = Task { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            do {
                await self.settingsChanged(settings)
                guard try await workspace.learningPreferences().allowsLearning else { return }
                try await self.synchronize(conversationID, messages: messages, settings: settings)
                try Task.checkCancellation()
                let digest = SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
                let connection = Self.recipient(settings) + "|" + settings.model + "|" + digest
                if self.connection != connection {
                    await self.learner?.cancelAll()
                    self.connection = connection
                    self.learner = ConversationMemoryLearner(workspace: workspace) { [weak self] input in
                        guard let self else { throw CancellationError() }
                        return try await self.extract(input, settings: settings, key: apiKey)
                    }
                }
                await self.learner?.noteCompletedTurn(conversationID: conversationID)
                // Refresh the visible memory list after the coalesced request settles.
                for _ in 0..<90 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try Task.checkCancellation()
                    let state = await self.learner?.state(for: conversationID)
                    if case .failed(let message) = state {
                        guard self.valid(settings, key: apiKey) else { return }
                        throw AgentError.message(message)
                    }
                    if state != .scheduled && state != .learning { break }
                }
                await self.reload()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func flushConversation(_ id: UUID) {
        let pending = jobs[id]
        Task { [weak self] in
            await pending?.value
            guard let self, self.valid(self.configuration()), self.automaticLearning else { return }
            await self.learner?.flush(conversationID: id)
            await self.reload()
            if case .failed(let message) = await self.learner?.state(for: id) { self.error = message }
        }
    }
    private func extract(_ input: ConversationLearningRequest, settings: AgentSettings, key: String) async throws -> Data {
        guard valid(settings, key: key), automaticLearning else { throw CancellationError() }
        let bytes = try await derive(input, settings, key)
        try Task.checkCancellation()
        guard valid(settings, key: key), automaticLearning else { throw CancellationError() }
        return bytes
    }
}
