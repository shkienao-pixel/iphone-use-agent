import Foundation

struct ReferenceRecord: Equatable {
    struct Log: Equatable { var title: String; var detail: String }
    enum Outcome: String { case paused, completed }
    var id = UUID(), effectiveGoal = "offline task", summary = "offline summary"
    var logs: [Log] = []
    var outcome: Outcome = .paused
    var executionLane: String? = nil
}
@MainActor final class ReferenceHistory { var records: [ReferenceRecord] = [] }
@MainActor final class ReferenceEngine {
    var currentRecord: ReferenceRecord?
    var hasCurrentTask = false
}
@MainActor final class ReferenceBackgroundTasks {
    var records: [ReferenceRecord] = []
    var activeIDs = Set<UUID>()
    func token(_ id: UUID) -> UUID? { activeIDs.contains(id) ? id : nil }
}
@MainActor final class ReferenceConversation {
    let currentConversationID = UUID()
    var focusedTaskID: UUID?
}
@MainActor final class PhoneAgentViewModel {
    let history = ReferenceHistory(), engine = ReferenceEngine()
    let backgroundTasks = ReferenceBackgroundTasks()
    let conversation = ReferenceConversation()
    var pendingConversationTask: ConversationTaskSubmission?
    var unifiedFocusedTaskID: UUID?
    // EXACT_PRODUCTION_CONTEXT
}
