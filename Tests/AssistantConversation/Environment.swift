import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Offline doubles for the app's image/model boundary. The real service under
// test is compiled unchanged; this client can only resume local continuations.
struct AgentSettings {
    var endpoint = "https://model.invalid/chat/completions"
    var model = "offline-fixture"
    var providerName = "Offline fixture"
    var useMemories: Bool? = false
}
enum PrivacyConsent {
    static var permitted = true
    static func allowed(_ settings: AgentSettings) -> Bool { permitted }
    static func recipient(_ settings: AgentSettings) -> String { settings.providerName }
}
struct ScreenFrame { var capturedAt = Date(); var jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]) }
struct CameraObservationFrame { var jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]); var capturedAt = Date(); var capturedUptime: TimeInterval = 0 }
struct AgentLogEntry { var title: String; var detail: String }
enum TaskOutcome { case completed, interrupted
    var label: String { self == .completed ? "已完成" : "执行中断" }
}
struct PhoneTaskRecord {
    var id = UUID()
    var title: String
    var goal: String
    var summary: String
    var updatedAt = Date()
    var outcome: TaskOutcome = .interrupted
    var logs: [AgentLogEntry] = []
    var conversationReference: String? = nil
    var effectiveGoal: String { goal }
}
@MainActor final class MemoryStore {
    var calls = 0
    var reference = "offline-approved-memory"
    var excludedMessageIDs: Set<UUID> = []
    var recallRevision = "offline-memory-revision"
    var canUseConversationHistory = true
    var beforePrepare: (() async -> Void)?
    func context(for query: String) async -> String { calls += 1; return reference }
    func prepareConversation(id: UUID, messages: [AssistantMessage], question: String, settings: AgentSettings) async -> PreparedAssistantMemory {
        await beforePrepare?()
        return PreparedAssistantMemory(reference: settings.useMemories == true ? await context(for: question) : "", excludedMessageIDs: excludedMessageIDs,
            recallRevision: settings.useMemories == true ? recallRevision : nil, canUseConversationHistory: canUseConversationHistory)
    }
    func learnConversation(id: UUID, messages: [AssistantMessage], settings: AgentSettings, apiKey: String) {}
    func flushConversation(id: UUID) {}
}
struct PreparedAssistantMemory { var identity = ""; var reference = ""; var excludedMessageIDs: Set<UUID> = []; var recallRevision: String? = nil; var canUseConversationHistory = true }
@MainActor final class OfflineModel {
    struct Request {
        var question: String
        var history: [AssistantMessage]
        var context: String
        var frameCount: Int
        var hasFrame: Bool
        var attachments: [ComposerAttachment]
        var continuation: CheckedContinuation<String, Error>?
    }
    static let shared = OfflineModel()
    var requests: [Request] = []
    func answer(question: String, history: [AssistantMessage], context: String, frames: Int, hasFrame: Bool, attachments: [ComposerAttachment] = []) async throws -> String {
        // Intentionally ignores cancellation until resumed, exercising the real
        // service's post-response cancellation and conversation-ID guards.
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(question: question, history: history, context: context, frameCount: frames, hasFrame: hasFrame, attachments: attachments, continuation: continuation))
        }
    }
    func complete(_ index: Int, answer: String) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil; continuation?.resume(returning: answer)
    }
    func fail(_ index: Int) {
        let continuation = requests[index].continuation
        requests[index].continuation = nil; continuation?.resume(throwing: CocoaError(.fileReadUnknown))
    }
}
@MainActor struct VisionClient {
    var settings: AgentSettings
    var apiKey: String
    func answer(question: String, frame: ScreenFrame?, history: [AssistantMessage], memoryContext: String,
                sequence: [CameraObservationFrame], attachments: [ComposerAttachment] = [], assistantIdentity: String = "") async throws -> String {
        try await OfflineModel.shared.answer(question: question, history: history, context: memoryContext, frames: sequence.count, hasFrame: frame != nil, attachments: attachments)
    }
}

struct ConnectedConversationClient {
    let settings: AgentSettings
    let apiKey: String
    static func supports(_ settings: AgentSettings) -> Bool { false }
    func answer(question: String, history: [AssistantMessage], memoryContext: String, assistantIdentity: String = "") async throws -> ConnectedConversationReply { fatalError("Offline legacy route must not call network") }
}
struct ConnectedConversationReply { let text: String; let model: String; let searched: Bool }
