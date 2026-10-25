import Foundation

@MainActor final class UIApplication {
    enum State { case active, inactive }
    static let shared = UIApplication()
    var applicationState = State.active
}
struct RecoveryChatMessage: Equatable { var id = UUID(); var taskID: UUID? }
@MainActor final class RecoveryConversation { var messages: [RecoveryChatMessage] = []; var loading = false }
@MainActor final class RecoverySpeech { var usingAudio = false }
@MainActor final class RecoveryTools {
    var pending: Bool?
    var unresolved = Set<UUID>()
    var unreadable = false
    func hasUnresolvedWrite(taskID: UUID) -> Bool { unreadable || unresolved.contains(taskID) }
}
@MainActor final class RecoveryExecutorState { var calibrationInProgress = false }

@MainActor final class PhoneAgentViewModel {
    let engine: AgentEngine
    let history: TaskHistoryStore
    let taskQueue: TaskQueueStore
    let conversation = RecoveryConversation(), speech = RecoverySpeech(), executor = RecoveryExecutorState(), tools = RecoveryTools()
    var settings = AgentSettings(), notice = "", showPreparation = false
    var recordingAudioOwner: UUID?, pendingConversationTask: UUID?, voiceMode: String?, unifiedFocusedTaskID: UUID?
    var preparingAutomatically = false, queueRunning = false, queueSwitching = false, voicePending = false
    var calibrating = false, manualBusy = false, pendingConsentStart = false, manualContinuationRequired = false
    var modelReady = true, preparationReady = true
    var consentReady: Bool { PrivacyConsent.allowed(settings) }
    private var queueActiveID: UUID?
    var activeQueueForChecks: UUID? { queueActiveID }
    init(directory: URL) {
        engine = AgentEngine(capture: CaptureService(), executor: MouseExecutor())
        history = TaskHistoryStore(url: directory.appendingPathComponent("history.json"))
        taskQueue = TaskQueueStore(url: directory.appendingPathComponent("queue.json"))
        engine.systemTool = { _, _ in "offline receipt" }
        engine.onRecord = { [weak self] record in self?.history.upsert(record) }
        settings.toolsOnly = true; settings.systemToolsEnabled = true; settings.startDelay = 0
        settings.continuousExecution = true; settings.confirmEachStep = false
    }
    lazy var backgroundTasks: BackgroundTaskCoordinator = {
        let pool = BackgroundTaskCoordinator { config in
            let worker = AgentEngine(capture: CaptureService(), executor: MouseExecutor(), ownsScreenInput: false)
            worker.systemTool = { _, _ in "offline native recovery receipt" }; return worker
        }
        pool.onRecord = { [weak self] record, _ in self?.history.upsert(record) }
        return pool
    }()
    func resumeScreenQueueTask(_ id: UUID) -> Bool {
        do { try taskQueue.update(id) { $0.state = .waiting }; return true } catch { return false }
    }
    // EXACT_RECOVERY_MEMBERS
}
