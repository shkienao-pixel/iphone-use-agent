import Foundation
import Combine

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct AgentSettings {
    var endpoint = "https://offline.invalid", model = "offline-model"
    var startDelay = 0.0
    var useMemories: Bool? = false
    var toolsOnly: Bool? = nil
    var systemToolsEnabled: Bool? = true
}
enum SettingsStore { static func apiKey(for endpoint: String) -> String { "offline-unused" } }
enum PrivacyConsent { static func recipient(_ settings: AgentSettings) -> String { "offline-recipient" } }
struct Record {
    struct Log { var title: String; var detail: String }
    enum Outcome: String { case running, paused, failed, completed, stopped, needsUser }
    var id = UUID(), effectiveGoal = "offline task", summary = "paused"
    var executionLane: String? = nil
    var logs: [Log] = [], outcome: Outcome = .paused, amendments: [String]? = nil
}
@MainActor final class Engine {
    var currentRecord: Record?
    var hasCurrentTask = false, releasing = false, canResume = true, running = false
    var activityControlSessionID = UUID(), error = ""
    var resumedIDs: [UUID] = []
    func replace(_ record: Record?, active: Bool = true) {
        currentRecord = record; hasCurrentTask = active && record != nil
        activityControlSessionID = UUID(); running = false; canResume = hasCurrentTask
    }
    func resume(settings: AgentSettings, delay: Double) {
        if let id = currentRecord?.id { resumedIDs.append(id) }
        running = true; canResume = false; activityControlSessionID = UUID()
    }
    func appendConversationReference(_ reference: String) -> Bool { true }
}
@MainActor final class History { var records: [Record] = [] }
@MainActor final class Queue {
    struct Item { var id = UUID(); var resumable = true }
    var items: [Item] = []
    var pendingCount: Int { items.filter(\.resumable).count }
}
@MainActor final class Conversation {
    let currentConversationID = UUID()
    var messages: [AssistantMessage] = []
    var unifiedRoute: ((ConversationRoutingInput) async throws -> ConversationRoute)?
    var links: [UUID] = [], cancellations = 0
    var handoffs: [UUID: String] = [:], linkedMessages: [UUID: UUID] = [:]
    @discardableResult func linkTask(_ id: UUID, to messageID: UUID, in conversationID: UUID? = nil) -> Bool {
        links.append(id); linkedMessages[messageID] = id; return true
    }
    @discardableResult func reportTaskHandoff(text: String, to messageID: UUID, in conversationID: UUID? = nil, onlyIfUnlinked: Bool = true) -> Bool {
        guard !onlyIfUnlinked || linkedMessages[messageID] == nil else { return false }
        handoffs[messageID] = text; return true
    }
    func cancel() { cancellations += 1 }
    func cancelScreenBoundRequest() { cancellations += 1 }
}
@MainActor final class ToolsProbe { func hasUnresolvedWrite(taskID: UUID) -> Bool { false } }
@MainActor final class Speech { var cancellations = 0; func cancel() { cancellations += 1 } }
@MainActor final class RecallMemory { var recallRevision = "offline-memory-revision" }
@MainActor enum ControlRouteProbe {
    static var context = ""
    static var pending: CheckedContinuation<ConversationRoute, Never>?
}
@MainActor struct UnifiedConversationRouter {
    let settings: AgentSettings, apiKey: String
    func route(input: ConversationRoutingInput) async throws -> ConversationRoute {
        ControlRouteProbe.context = input.taskContext
        return await withCheckedContinuation { ControlRouteProbe.pending = $0 }
    }
}
@MainActor final class BackgroundProbe {
    struct Origin { let conversationID: UUID; let messageID: UUID }
    var records: [Record] = []
    var sessions: [UUID: UUID] = [:]
    var actions: [(String, UUID)] = []
    var origins: [UUID: Origin] = [:]
    func token(_ id: UUID) -> UUID? { sessions[id] }
    func contains(_ id: UUID) -> Bool { records.contains { $0.id == id } }
    func submit(goal: String, settings: AgentSettings, attachments: [ComposerAttachment], reference: String, origin: Origin) throws -> UUID {
        guard settings.systemToolsEnabled == true else { throw AgentError.message("tools disabled") }
        let record = Record(effectiveGoal: goal, summary: reference, executionLane: "native", outcome: .running)
        records.append(record); sessions[record.id] = UUID(); origins[record.id] = origin; actions.append(("submit", record.id)); return record.id
    }
    func apply(_ mode: String, _ id: UUID, _ expected: UUID?) throws {
        guard let token = sessions[id], expected == nil || expected == token else { throw AgentError.message("stale worker") }
        actions.append((mode, id)); sessions[id] = mode == "stop" ? nil : UUID()
    }
    func pause(_ id: UUID, expected: UUID?) throws { try apply("pause", id, expected) }
    func stop(_ id: UUID, expected: UUID?) throws { try apply("stop", id, expected) }
    func resume(_ id: UUID, settings: AgentSettings? = nil, expected: UUID?) throws { try apply("resume", id, expected) }
    func supplement(_ id: UUID, text: String, reference: String, settings: AgentSettings? = nil, expected: UUID?) throws { try apply("supplement", id, expected) }
}
@MainActor final class PhoneAgentViewModel {
    let tools = ToolsProbe()
    let backgroundTasks = BackgroundProbe()
    var modelReady = true
    let memories = RecallMemory()
    var settings = AgentSettings(), consentReady = true
    let engine = Engine(), history = History(), taskQueue = Queue(), conversation = Conversation(), speech = Speech()
    var unifiedFocusedTaskID: UUID?
    var pendingConversationTask: ConversationTaskSubmission?
    var preparingAutomatically = false, queueSwitching = false, voicePending = false
    var showPrivacyConsent = false, enqueueAllowed = true, startAllowed = true
    var prepareOnStart = false, requireConsentOnStart = false
    var manualContinuationRequired = false, preparationReady = true, showPreparation = false
    var automaticPreparationGeneration = UUID(), voiceGeneration = UUID(), queueGeneration = UUID()
    private var conversationInteractionID = UUID()
    var voiceRequestID = UUID(), voiceMode: String?
    var notice = "", goal = ""
    var actions: [(String, UUID?)] = [], halts = 0
    var historicalRecoveryAllowed = true
    var effectCount: Int { actions.count + engine.resumedIDs.count + halts + speech.cancellations + conversation.cancellations }
    func enqueueDraft(priority: Bool, attachments: [ComposerAttachment] = [], conversationReference: String = "") -> Bool {
        guard enqueueAllowed else { notice = "offline queue full"; return false }
        taskQueue.items.append(.init()); actions.append(("enqueue", nil)); return true
    }
    func queueConversationScreenTask(_ route: ConversationRoute) -> UUID? {
        guard enqueueDraft(priority: false, attachments: route.attachments, conversationReference: route.executionReference) else { return nil }
        return taskQueue.items.last?.id
    }
    func startAgent(attachments: [ComposerAttachment] = [], conversationTask: ConversationTaskSubmission? = nil) -> Bool {
        if prepareOnStart { preparingAutomatically = true; return false }
        if requireConsentOnStart { consentReady = false; showPrivacyConsent = true; return false }
        guard startAllowed else { if !showPrivacyConsent && !preparingAutomatically { notice = "offline model unavailable" }; return false }
        actions.append(("new", nil)); return true
    }
    func supplementTask(_ request: String) -> String {
        actions.append(("supplement", engine.currentRecord?.id)); haltQueue("offline supplement")
        let amendments = (engine.currentRecord?.amendments ?? []) + [request]
        engine.currentRecord?.amendments = amendments
        engine.activityControlSessionID = UUID()
        return "offline supplemented"
    }
    func pauseTask() -> String { actions.append(("pause", engine.currentRecord?.id)); return "offline paused" }
    func stop() { actions.append(("stop", engine.currentRecord?.id)) }
    func runTaskQueue(first id: UUID) { actions.append(("queue", id)) }
    func resumeScreenQueueTask(_ id: UUID) -> Bool { actions.append(("queue", id)); return true }
    var queueRunning = false
    var screenQueueWaiting: [Queue.Item] { taskQueue.items.filter(\.resumable) }
    func recoverableTask(_ id: UUID) -> Record? {
        let record = engine.currentRecord?.id == id ? engine.currentRecord : history.records.first { $0.id == id }
        return record?.outcome == .completed ? nil : record
    }
    func continueTask(_ id: UUID) -> Bool {
        if recoverableTask(id)?.executionLane == "native" { actions.append(("nativeRecovery", id)); return true }
        guard historicalRecoveryAllowed, !engine.hasCurrentTask || engine.currentRecord?.id == id else { return false }
        actions.append(("history", id)); return true
    }
    private func haltQueue(_ reason: String) { halts += 1; queueGeneration = UUID() }
    func setPendingConsent(_ value: Bool) { pendingConsentStart = value }
    // EXACT_PRODUCTION_MEMBERS
}
