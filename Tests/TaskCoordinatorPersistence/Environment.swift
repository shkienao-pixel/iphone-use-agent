import Foundation
import Combine

// The coordinator, repository, record/native-result models and receipt
// maintenance policy compile unchanged. This deterministic worker is only the
// execution boundary; it never runs a model, SDK, phone or Bluetooth operation.
struct AgentSettings { var systemToolsEnabled: Bool? = true; var toolsOnly: Bool? = true }
enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum TaskRecoveryMode { case retry, continueTask }
struct AgentLogEntry: Identifiable, Codable {
    var id = UUID(); var date = Date(); var step: Int; var title: String; var detail: String
}
struct TaskContextMemory: Codable {
    var compactedEntryCount = 0; var retainedEntryCount = 0; var truncatedCharacterCount = 0
}
@MainActor final class AgentEngine {
    var persistRecord: ((PhoneTaskRecord) -> Bool)?
    var onRecord: ((PhoneTaskRecord) -> Void)?
    var onPersistenceFailure: ((PhoneTaskRecord) -> Void)?
    var running = false
    @Published var releasing = false
    var currentRecord: PhoneTaskRecord?
    var error = ""
    var starts = 0, resumes = 0, recoveries = 0, pauses = 0, stops = 0, dispatches = 0
    var holdCancellation = false
    var executionSettled: Bool { !running && !releasing }
    @discardableResult func emit(_ record: PhoneTaskRecord) -> Bool {
        var candidate = record; candidate.updatedAt = Date()
        if let persistRecord, !persistRecord(candidate) {
            candidate.outcome = .paused; candidate.summary = "synthetic worker write failure"
            running = false; currentRecord = candidate; onPersistenceFailure?(candidate)
            return false
        }
        currentRecord = candidate; onRecord?(candidate); return true
    }
    func start(task: String, settings: AgentSettings, attachments: [ComposerAttachment], taskID: UUID, conversationReference: String) {
        starts += 1; running = true
        let record = PhoneTaskRecord(id: taskID, title: String(task.prefix(36)), goal: task,
            summary: "worker started", attachments: attachments.isEmpty ? nil : attachments,
            conversationReference: conversationReference.isEmpty ? nil : conversationReference)
        if emit(record), running { dispatches += 1 }
    }
    func recover(record: PhoneTaskRecord, settings: AgentSettings, mode: TaskRecoveryMode) throws {
        recoveries += 1; running = true
        var candidate = record; candidate.outcome = .running; candidate.summary = "worker recovered"
        if emit(candidate), running { dispatches += 1 }
    }
    func resume(settings: AgentSettings) {
        guard var candidate = currentRecord else { return }
        resumes += 1; running = true; candidate.outcome = .running; candidate.summary = "worker resumed"
        if emit(candidate), running { dispatches += 1 }
    }
    func pause() {
        guard var candidate = currentRecord, running else { return }
        pauses += 1; running = false; releasing = holdCancellation
        candidate.outcome = .paused; candidate.summary = "worker paused"; emit(candidate)
    }
    func stop() {
        guard var candidate = currentRecord else { return }
        stops += 1; running = false; releasing = holdCancellation
        candidate.outcome = .stopped; candidate.summary = "worker stopped"; emit(candidate)
    }
    func complete() {
        guard var candidate = currentRecord else { return }
        running = false; candidate.outcome = .completed; candidate.summary = "worker completed"; emit(candidate)
    }
    func appendConversationReference(_ reference: String) -> Bool {
        guard var candidate = currentRecord else { return false }
        candidate.conversationReference = [candidate.conversationReference ?? "", reference].filter { !$0.isEmpty }.joined(separator: "\n")
        emit(candidate); return true
    }
    func amendTask(_ text: String) throws {
        guard var candidate = currentRecord else { throw AgentError.message("no worker checkpoint") }
        running = false; releasing = holdCancellation
        candidate.amendments = (candidate.amendments ?? []) + [TaskAmendment(text: text)]
        candidate.outcome = .paused; emit(candidate)
    }
}
