import Foundation
import Combine

@MainActor final class UIApplication {
    enum State { case active, inactive }
    static let shared = UIApplication()
    var applicationState = State.active
}
extension ModelEndpointPolicy { static func acceptsModelConnection(_ settings: AgentSettings) -> Bool { URL(string: settings.endpoint) != nil } }
@MainActor final class QueueStopper { func cancel() {}; func stop() {} }
@MainActor final class QueueConversation { func cancelScreenBoundRequest() {} }
@MainActor final class QueueTools {
    var unresolved = Set<UUID>()
    func hasUnresolvedWrite(taskID: UUID) -> Bool { unresolved.contains(taskID) }
}
@MainActor final class PhoneAgentViewModel {
    let engine = AgentEngine(capture: CaptureService(), executor: MouseExecutor())
    let taskQueue: TaskQueueStore, history: TaskHistoryStore
    let speech = QueueStopper(), liveCamera = QueueStopper(), camera = QueueStopper(), conversation = QueueConversation(), tools = QueueTools()
    var settings = AgentSettings(), goal = "", notice = "", taskPlan: [String] = [], taskPlanOriginal = "", taskPlanDraftGoal: String?
    var queueRunning = false, queueSwitching = false, queueStatus = "队列未运行"
    private var queueActiveID: UUID?, queueGlobalResumeID: UUID?
    private var queueGeneration = UUID(), queueUsesStrictOrder = false, handlingQueueFailure = false
    private var queueOperation: Task<Void,Never>?, queueAdvance: Task<Void,Never>?
    var preparingAutomatically = false, voicePending = false, calibrating = false, manualBusy = false
    var recordingAudioOwner: UUID?, voiceMode: String?
    let executor = QueueExecutorState()
    init(directory: URL) {
        taskQueue = TaskQueueStore(url: directory.appendingPathComponent("queue.json"))
        history = TaskHistoryStore(url: directory.appendingPathComponent("history.json"))
        settings.startDelay = 0; settings.stepInterval = 0.4; settings.toolsOnly = false; settings.confirmEachStep = false
        engine.onRecord = { [weak self] record in
            guard let self else { return }
            self.history.upsert(record); self.recordQueueProgress(record)
        }
    }
    func task(_ name: String, toolsOnly: Bool = false, state: QueueTaskState = .waiting) -> QueuedPhoneTask {
        var config = settings; config.toolsOnly = toolsOnly
        var record = PhoneTaskRecord(title: name, goal: name, outcome: .paused, summary: "waiting")
        record.executionLane = toolsOnly ? "native" : "screen"
        return QueuedPhoneTask(record: record, settings: config, state: state)
    }
    var activeID: UUID? { queueActiveID }
}
@MainActor final class QueueExecutorState { var calibrationInProgress = false }
