import Foundation
import Combine
import UIKit
import Accessibility

@MainActor
final class PhoneAgentViewModel: ObservableObject {
    static let shared = PhoneAgentViewModel()
    var unifiedFocusedTaskID: UUID? {
        get { conversation.focusedTaskID ?? conversation.messages.last(where: { $0.taskID != nil })?.taskID }
        set { conversation.focusedTaskID = newValue }
    }
    var pendingConversationTask: ConversationTaskSubmission?
    @Published var goal = UserDefaults.standard.string(forKey: "agent.currentGoal") ?? "" {
        didSet {
            UserDefaults.standard.set(goal, forKey: "agent.currentGoal")
            if !taskPlan.isEmpty && taskPlanDraftGoal != goal { taskPlan = []; taskPlanDraftGoal = nil; taskPlanOriginal = "" }
        }
    }
    @Published var settings: AgentSettings { didSet {
        if preparingAutomatically && !(preparingSavedConfiguration && configurationSettingsOpen) {
            cancelAutomaticPreparation(message: "设置已更改，请重新一键准备")
        }
        SettingsStore.save(settings); capture.maxSide = settings.imageMaxSide; updateTaskActivity()
        let recipientChanged = oldValue.endpoint != settings.endpoint || oldValue.model != settings.model || PrivacyConsent.recipient(oldValue) != PrivacyConsent.recipient(settings)
        liveCamera.stop(clearResults: recipientChanged)
        if recipientChanged || oldValue.useMemories != settings.useMemories { backgroundTasks.pauseAll() }
        if recipientChanged {
            conversation.cancel(); conversation.selectFrame(nil)
            if manualBusy { manualContinuationRequired = true; manual?.cancel() }
        }
        if queueRunning { pauseQueue(); notice = "配置已更改，队列已暂停，请核对后继续" }
    } }
    @Published var taskPlan: [String] = []
    private(set) var taskPlanDraftGoal: String?
    private(set) var taskPlanOriginal = ""
    func useTaskPlan(_ items: [String], original: String) {
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = original.isEmpty ? list : "总任务与约束：\n" + original + "\n\n子任务：\n" + list
        taskPlanOriginal = original; taskPlanDraftGoal = combined; taskPlan = items; goal = combined
    }
    func removeTaskPlan() {
        guard !taskPlan.isEmpty else { return }
        let original = taskPlanOriginal
        let ownsDraft = goal == taskPlanDraftGoal
        taskPlan = []; taskPlanDraftGoal = nil; taskPlanOriginal = ""
        if ownsDraft { goal = original }
    }
    @Published var deviceDebugDestination: WorkspaceDestination?
    @Published var assistantInputActive = false
    @Published var workbenchHasDraft = false
    @Published var notice = ""
    @Published var showPrivacyConsent = false
    @Published var showPrivacyPolicy = false
    @Published var showPreparation = false
    @Published var showConfigurationSettings = false
    @Published private(set) var preparingAutomatically = false
    @Published private(set) var preparingSavedConfiguration = false
    @Published private(set) var configurationCompletionID: UUID?
    @Published private(set) var automaticPreparationStatus = ""
    @Published var automaticCalibrationRequested = false
    private var automaticPreparation: Task<Void, Never>?
    private var automaticPreparationGeneration = UUID()
    private var automaticPreparationConversationTaskID: UUID?
    private var awaitingAutomaticCalibration = false
    private var automaticPreparationOwnsCapture = false
    private var configurationSettingsOpen = false
    private var assistiveTouchVerification = AssistiveTouchSessionVerification()
    private var pendingConsentStart = false {
        didSet { if oldValue != pendingConsentStart { conversationInteractionID = UUID() } }
    }
    private var pendingConsentAttachments: [ComposerAttachment] = []
    private var pendingConsentConversationTask: ConversationTaskSubmission?
    let history = TaskHistoryStore()
    let taskQueue = TaskQueueStore()
    @Published private(set) var queueRunning = false
    @Published private(set) var queueSwitching = false
    @Published private(set) var queueStatus = "队列未运行"
    private var queueActiveID: UUID?
    private var queueGeneration = UUID()
    private var queueOperation: Task<Void, Never>?
    private var queueAdvance: Task<Void, Never>?
    private var handlingQueueFailure = false
    private var queueUsesStrictOrder = false
    private var queueGlobalResumeID: UUID?
    let memories = MemoryStore()
    let recordings = RecordingStore()
    @Published private(set) var recordingAudioOwner: UUID?
    func reserveRecordingAudio(_ id: UUID) -> Bool {
        guard recordingAudioOwner == nil, !engine.running, !engine.releasing, !queueRunning, !queueSwitching,
              !preparingAutomatically, !voicePending, voiceMode == nil, !manualBusy, !calibrating, !speech.usingAudio else { return false }
        recordingAudioOwner = id; conversation.cancel(); liveCamera.stop(); camera.stop(); return true
    }
    func releaseRecordingAudio(_ id: UUID) { if recordingAudioOwner == id { recordingAudioOwner = nil } }
    let tools = SystemTools()
    let taskResources = TaskResourceGate()
    lazy var backgroundTasks: BackgroundTaskCoordinator = {
        let pool = BackgroundTaskCoordinator { [weak self] config in
            guard let self else { fatalError("Task coordinator outlived its owner") }
            return self.makeBackgroundEngine(settings: config)
        }
        pool.persistRecord = { [weak self] record in
            guard let self else { return false }
            let saved = self.history.upsert(record)
            if !saved { self.notice = self.history.error }
            return saved
        }
        pool.onRecord = { [weak self] record, _ in
            guard let self else { return }
            self.conversation.retainTaskResult(record.nativeConversationSnapshot)
            self.objectWillChange.send()
        }
        return pool
    }()
    var toolReceiptMaintenanceContext: ToolReceiptMaintenanceContext {
        var protected = Set(history.records.filter { $0.outcome.retainsRecoveryCheckpoint }.map(\.id))
        protected.formUnion(taskQueue.items.filter(\.resumable).map(\.id))
        protected.formUnion(backgroundTasks.checkpointRecords.filter { $0.outcome.retainsRecoveryCheckpoint }.map(\.id))
        if let record = engine.currentRecord, record.outcome.retainsRecoveryCheckpoint { protected.insert(record.id) }
        return ToolReceiptMaintenanceContext(protectedTaskIDs: protected,
            executionInFlight: !engine.executionSettled || backgroundTasks.hasUnsettledExecution || queueRunning || queueSwitching || preparingAutomatically,
            taskStorageAvailable: history.error.isEmpty && taskQueue.error.isEmpty)
    }
    var toolReceiptMaintenanceBlockedReason: String? {
        tools.receiptMaintenanceBlockedReason(toolReceiptMaintenanceContext)
    }
    @discardableResult
    func cleanEndedTaskReceipts() throws -> ToolReceiptCleanupResult {
        try tools.clearReceipts(context: toolReceiptMaintenanceContext)
    }
    func retryTaskRecordPersistence() {
        guard engine.executionSettled, !backgroundTasks.hasUnsettledExecution,
              !queueRunning, !queueSwitching, !preparingAutomatically else {
            notice = "请先暂停正在执行的任务，再重试保存记录"; return
        }
        var checkpoints = Dictionary(uniqueKeysWithValues: backgroundTasks.checkpointRecords.map { ($0.id, $0) })
        if let current = engine.currentRecord { checkpoints[current.id] = current }
        let ordered = checkpoints.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        guard history.saveCheckpoints(ordered) else { notice = history.error; return }
        guard backgroundTasks.acknowledgeSavedCheckpoints(ordered) else {
            notice = "记录已保存，但当前任务检查点又有变化，请重新核对后重试保存"; return
        }
        if !taskQueue.error.isEmpty {
            do {
                try taskQueue.transaction { items in
                    for index in items.indices where items[index].state == .running {
                        items[index].state = .suspended
                        items[index].note = "记录已重新保存；请核对实际结果后手动继续"
                        if items[index].record.outcome == .running { items[index].record.outcome = .interrupted }
                    }
                }
            } catch {
                notice = "任务历史已保存，队列仍未能保存：" + error.localizedDescription
                return
            }
        }
        // Re-establish the original conversation handoff only after its task is
        // durable. This callback does not start or resume an execution session.
        if let current = engine.currentRecord { engine.onRecord?(current) }
        notice = history.error.isEmpty && taskQueue.error.isEmpty ? "任务记录已保存；请手动确认是否继续任务" : (history.error.isEmpty ? taskQueue.error : history.error)
    }
    let contentStore = PhoneContentStore.shared
    let camera = CameraService()
    let liveCamera = LiveCameraObserver()
    let taskActivity = TaskActivityController()
    let taskNotifications = TaskNotificationsController.shared
    var interactionBusy: Bool {
        preparingAutomatically || calibrating || recordingAudioOwner != nil || queueSwitching || engine.running || engine.releasing || manualBusy || voicePending
    }

    var consentReady: Bool { PrivacyConsent.allowed(settings) }
    var calibrationReady: Bool {
        guard let c = executor.calibration else { return false }
        guard c.usable && c.peripheralID == ble.selectedID else { return false }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) {
            let size = scene.screen.bounds.size
            guard abs(c.screenWidth - Double(size.width)) < 1, abs(c.screenHeight - Double(size.height)) < 1 else { return false }
        }
        return (try? executor.validateCalibration(frame: capture.frame?.fullDisplay == true ? capture.frame : nil)) != nil
    }
    var assistiveTouchObservedState: AssistiveTouchObservedState {
        .observed(reportedRunning: UIAccessibility.isAssistiveTouchRunning,
                  guidedAccessEnabled: UIAccessibility.isGuidedAccessEnabled)
    }
    private var assistiveTouchVerificationContext: AssistiveTouchVerificationContext {
        var calibration: Data?
        if ble.ready, calibrationReady, let value = executor.calibration {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            calibration = try? encoder.encode(value)
        }
        return .init(preparationID: preparingAutomatically ? automaticPreparationGeneration : nil,
            accessoryID: ble.selectedID, connectionID: ble.ready ? ble.pointerConnectionGeneration : nil,
            calibrationFingerprint: calibration, captureID: capture.running && capture.frame?.fullDisplay == true ? capture.frame?.captureID : nil,
            captureRunning: capture.running)
    }
    var assistiveTouchReady: Bool {
        switch assistiveTouchObservedState {
        case .enabled:
            UserDefaults.standard.set(true, forKey: "agent.assistiveTouchConfigured")
            return true
        case .disabled:
            UserDefaults.standard.set(false, forKey: "agent.assistiveTouchConfigured")
            return false
        case .unknown:
            // UIKit cannot reliably report the switch outside Guided Access.
            // Let live pointer/calibration/capture checks diagnose actual failures.
            return assistiveTouchObservedState.allowsStartup
        }
    }
    var assistiveTouchStatusText: String {
        if assistiveTouchReady {
            return assistiveTouchObservedState == .enabled ? "辅助触控已开启" : "直接使用已配置的辅助触控"
        }
        return assistiveTouchObservedState == .disabled ? "辅助触控未开启，请到系统设置开启" : "请核对本次辅助触控设置"
    }
    var needsAssistiveTouchConfirmation: Bool {
        settings.toolsOnly != true && !settings.previewOnly && assistiveTouchObservedState == .unknown && !assistiveTouchReady
    }
    var canConfirmAssistiveTouch: Bool {
        needsAssistiveTouchConfirmation && modelReady && consentReady && recordingAudioOwner == nil &&
        !queueRunning && !queueSwitching && !engine.running && !engine.releasing && !manualBusy &&
        !voicePending && !calibrating && !executor.calibrationInProgress
    }
    /// Called only by the explicit native confirmation dialog. No model/tool
    /// route can turn this into system-reported state or persistent permission.
    func confirmAssistiveTouchForCurrentPreparation() {
        guard canConfirmAssistiveTouch else {
            notice = assistiveTouchObservedState == .disabled ? "请先在系统设置开启辅助触控，再返回核对" : "请先完成模型授权并结束其他操作，再核对本次设置"
            return
        }
        if !preparingAutomatically { prepareAutomatically() }
        guard preparingAutomatically,
              assistiveTouchVerification.confirm(observation: assistiveTouchObservedState, context: assistiveTouchVerificationContext) else { return }
        automaticPreparationStatus = "已记录本次设置核对，继续检查配件、校准和整屏共享"
        notice = ""; objectWillChange.send()
    }
    var modelReady: Bool {
        guard ModelEndpointPolicy.acceptsModelConnection(settings) else { return false }
        return !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !SettingsStore.apiKey(for: settings.endpoint).isEmpty
    }
    var preparationReady: Bool {
        recordingAudioOwner == nil && modelReady && consentReady && (settings.toolsOnly == true ? settings.systemToolsEnabled == true : (capture.running && capture.frame?.fullDisplay == true &&
            (settings.previewOnly || (assistiveTouchReady && ble.ready && calibrationReady))))
    }
    var savedPreparationConfiguration: SavedPreparationConfiguration {
        let accessoryID = ble.selectedID ?? ble.rememberedPeripheralID
        let calibration = executor.calibration
        return SavedPreparationConfiguration(modelReady: modelReady, consentReady: consentReady,
            toolsOnly: settings.toolsOnly == true, systemToolsEnabled: settings.systemToolsEnabled == true,
            previewOnly: settings.previewOnly, accessoryConfigured: accessoryID != nil,
            calibrationConfigured: calibration?.usable == true && calibration?.peripheralID == accessoryID)
    }
    var configurationReady: Bool { savedPreparationConfiguration.configured }
    func configurationSettingsDismissed() { configurationSettingsOpen = false }
    func requestConsent() {
        if let pending = pendingConsentConversationTask {
            conversation.reportTaskHandoff(text: "任务未启动：已重新打开数据授权，请完成授权后重新发送原请求。", to: pending.messageID, in: pending.conversationID)
        }
        if let pending = pendingConsentConversationTask, pendingConversationTask?.taskID == pending.taskID { pendingConversationTask = nil }
        pendingConsentConversationTask = nil; pendingConsentStart = false; pendingConsentAttachments = []; showPrivacyConsent = true
    }
    func acceptConsent() {
        guard modelReady else {
            notice = "请先保存有效的模型配置"
            if let pending = pendingConsentConversationTask {
                conversation.reportTaskHandoff(text: "任务尚未启动：" + notice + "，再完成数据授权。", to: pending.messageID, in: pending.conversationID)
            }
            return
        }
        PrivacyConsent.grant(settings); showPrivacyConsent = false; objectWillChange.send()
        let shouldStart = pendingConsentStart; pendingConsentStart = false
        let attachments = pendingConsentAttachments; pendingConsentAttachments = []
        let submission = pendingConsentConversationTask; pendingConsentConversationTask = nil
        if shouldStart { startAgent(attachments: attachments, conversationTask: submission) }
    }
    func declineConsent() {
        if let pending = pendingConsentConversationTask ?? (preparingAutomatically ? pendingConversationTask : nil) {
            conversation.reportTaskHandoff(text: "任务未启动：未授权模型处理数据，本次执行请求已取消。", to: pending.messageID, in: pending.conversationID)
        }
        if let pending = pendingConsentConversationTask, pendingConversationTask?.taskID == pending.taskID { pendingConversationTask = nil }
        pendingConsentConversationTask = nil
        pendingConsentStart = false; pendingConsentAttachments = []; showPrivacyConsent = false
        if preparingAutomatically { cancelAutomaticPreparation(message: "未授权模型处理数据，准备已停止") }
    }
    func revokeConsent() {
        stop(); backgroundTasks.pauseAll(); capture.stop(); PrivacyConsent.revoke(); objectWillChange.send()
        notice = "已撤回 AI 数据授权并停止屏幕共享"
    }
    func resumeAgent() {
        guard !manualContinuationRequired else { notice = "请到记录与文件选择刚才的任务续作；不会继续另一个旧任务"; return }
        haltQueue("已改为手动继续当前任务")
        guard !preparingAutomatically, !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return }
        guard preparationReady else { showPreparation = true; notice = "准备完成后，请手动点继续任务"; return }
        notice = ""; engine.resume(settings: settings)
    }
    var taskRecoveryBusy: Bool {
        recordingAudioOwner != nil || preparingAutomatically || queueRunning || queueSwitching || voicePending || voiceMode != nil ||
        calibrating || manualBusy || executor.calibrationInProgress || !engine.executionSettled ||
        pendingConsentStart || pendingConversationTask != nil || conversation.loading || speech.usingAudio || tools.pending != nil
    }
    func recoverableTask(_ id: UUID) -> PhoneTaskRecord? {
        let historical = history.records.first(where: { $0.id == id })
        let queued = taskQueue.items.first(where: { $0.id == id })
        let selected: PhoneTaskRecord?
        if engine.currentRecord?.id == id {
            selected = engine.currentRecord
        } else if let native = backgroundTasks.record(id) {
            selected = native
        } else if let historical, let queued {
            let historyStep = historical.checkpointStep ?? max(0, historical.logs.map(\.step).max() ?? 0)
            let queueStep = max(queued.step, queued.record.checkpointStep ?? max(0, queued.record.logs.map(\.step).max() ?? 0))
            if queueStep > historyStep || (queueStep == historyStep && queued.record.updatedAt > historical.updatedAt) {
                var completeCheckpoint = queued.record
                completeCheckpoint.checkpointStep = queueStep
                selected = completeCheckpoint
            } else { selected = historical }
        } else if let queued {
            var completeCheckpoint = queued.record
            completeCheckpoint.checkpointStep = max(queued.step, completeCheckpoint.checkpointStep ?? max(0, completeCheckpoint.logs.map(\.step).max() ?? 0))
            selected = completeCheckpoint
        } else { selected = historical }
        guard let record = selected, [.failed, .stopped, .interrupted, .paused, .needsUser].contains(record.outcome) else { return nil }
        return record
    }
    @discardableResult
    func retryTask(_ id: UUID) -> Bool { recoverTask(id, mode: .retry) }
    @discardableResult
    func continueTask(_ id: UUID) -> Bool { recoverTask(id, mode: .continueTask) }
    private func recoverTask(_ id: UUID, mode: TaskRecoveryMode) -> Bool {
        guard let record = recoverableTask(id) else { notice = "所选任务已结束或不存在，未恢复其他任务"; return false }
        if record.executionLane == "native" {
            return recoverBackgroundTask(record, mode: mode)
        }
        if let queued = taskQueue.items.first(where: { $0.id == id }), queued.settings.toolsOnly != true, queued.record.executionLane != "native" {
            guard queued.resumable, history.error.isEmpty, taskQueue.error.isEmpty, !tools.hasUnresolvedWrite(taskID: id),
                  !(engine.currentRecord?.id == id && (engine.running || engine.releasing)) else {
                notice = "这项任务仍在执行、已终止或有待核验记录，请先到屏幕队列核对"; return false
            }
            do {
                var checkpoint = record
                if mode == .retry { checkpoint.attemptStartStep = max(queued.step, record.checkpointStep ?? 0) }
                try taskQueue.update(id) { $0.record = checkpoint; $0.step = max($0.step, checkpoint.checkpointStep ?? 0); $0.state = .waiting; $0.note = "已按原位置恢复排队" }
                if engine.currentRecord?.id == id { engine.discardCurrent(); queueActiveID = nil }
                return resumeScreenQueueTask(id)
            } catch { notice = error.localizedDescription; return false }
        }
        guard !taskRecoveryBusy else { notice = "已有任务、准备或输入正在进行，请结束后再恢复这项任务"; return false }
        guard UIApplication.shared.applicationState == .active else { notice = "请回到 Sela 后重试或继续所选任务"; return false }
        guard !manualContinuationRequired else { notice = "刚才的手机操作结果尚待核对，请先在记录与文件处理回执"; return false }
        guard !engine.hasCurrentTask || engine.currentRecord?.id == id else {
            notice = "另一个任务仍保留执行会话；请先完成或结束它，再恢复这项任务"; return false
        }
        guard history.error.isEmpty, taskQueue.error.isEmpty else { notice = "任务记录未能安全保存，请先处理存储问题后再恢复"; return false }
        guard !tools.hasUnresolvedWrite(taskID: id) else {
            notice = "这项任务有尚未核验的写入回执，请先核对实际结果；没有重试写入，也没有清除原回执"
            return false
        }
        guard modelReady, consentReady, preparationReady else {
            showPreparation = true
            notice = "请完成当前配置与设备准备，再点这项任务的重试或继续；准备结束不会自动执行"
            return false
        }
        history.upsert(record)
        guard history.error.isEmpty else { notice = "这项任务的记录暂时无法保存，未启动恢复"; return false }
        let oldQueueID = queueActiveID
        // This click authorizes only the selected task. It never runs the rest
        // of the queue or attaches an archived task to another conversation.
        queueActiveID = taskQueue.items.contains(where: { $0.id == id }) ? id : nil
        do {
            try engine.recover(record: record, settings: settings, mode: mode)
            notice = ""
            if conversation.messages.contains(where: { $0.taskID == id }) { unifiedFocusedTaskID = id }
            return engine.running
        } catch {
            queueActiveID = oldQueueID; notice = error.localizedDescription
            return false
        }
    }
    func removeTask(_ id: UUID) {
        guard !toolReceiptMaintenanceContext.executionInFlight else { return }
        if history.remove(id), engine.currentRecord?.id == id { engine.discardCurrent() }
    }
    func clearHistory() {
        guard !toolReceiptMaintenanceContext.executionInFlight else { return }
        history.clear()
        if history.error.isEmpty { engine.discardCurrent() }
    }
    @Published var manualBusy = false {
        didSet { if oldValue != manualBusy { conversationInteractionID = UUID() } }
    }
    @Published private(set) var manualScreenWorkflow = false
    @Published var calibrating = false {
        didSet { if oldValue != calibrating { conversationInteractionID = UUID() } }
    }
    @Published private(set) var voicePending = false
    @Published var voiceRequestID = UUID()
    @Published var voiceMode: VoiceInputMode?
    @Published var showAssistant = false
    var cancelCalibration: (() -> Void)?
    let ble = BLETransport()
    let capture = CaptureService()
    let executor: MouseExecutor
    let engine: AgentEngine
    let workflowServices: PhoneWorkflowWorkspace
    lazy var speech = VoiceController()
    lazy var conversation = AssistantConversation()
    lazy var pip = AgentPiPController(engine: engine, stopTask: { [weak self] in self?.stop() })
    private var observers = Set<AnyCancellable>()
    private var manual: Task<Void, Never>?
    private var manualContinuationRequired = false
    private var voicePreparation: Task<Void, Never>?
    private var voiceGeneration = UUID()
    private var conversationInteractionID = UUID()
    func pendingTaskForConversation(_ conversationID: UUID) -> ConversationTaskSubmission? {
        guard !engine.hasCurrentTask, let pending = pendingConversationTask, pending.conversationID == conversationID else { return nil }
        return pending
    }
    var conversationControlContext: ConversationControlContext {
        .init(taskID: engine.hasCurrentTask ? engine.currentRecord?.id : nil,
              engineSessionID: engine.activityControlSessionID,
              preparationID: automaticPreparationGeneration, voiceID: voiceGeneration,
              queueID: queueGeneration, interactionID: conversationInteractionID)
    }
    init() {
        #if DEBUG
        let importedModelNotice = DebugModelConfigImport.runIfRequested()
        let importedCtripNotice = DebugCtripConfigImport.runIfRequested()
        #endif
        let restoredSettings = SettingsStore.load()
        settings = restoredSettings
        #if DEBUG
        // Prepare a reviewable local draft; this never starts a task.
        let launchArguments = ProcessInfo.processInfo.arguments
        if let index = launchArguments.firstIndex(of: "--draft-goal"),
           launchArguments.indices.contains(index + 1) {
            let draft = launchArguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !draft.isEmpty, draft.count <= 1000 { goal = draft }
        }
        #endif
        SettingsStore.adoptLegacyCredential(for: restoredSettings.endpoint)
        executor = MouseExecutor(ble: ble)
        engine = AgentEngine(capture: capture, executor: executor)
        let contextCapture = capture, contextBLE = executor.ble
        let harness = PhoneHarnessRuntime(executor: executor, contextCurrent: {
            .init(frame: contextCapture.frame, running: contextCapture.running,
                selectedDeviceID: contextBLE.selectedID, accessoryReady: contextBLE.ready,
                connectionGeneration: contextBLE.pointerConnectionGeneration)
        })
        engine.phoneHarness = harness
        workflowServices = PhoneWorkflowWorkspace(capture: capture, executor: executor, harness: harness)
        let workflows = workflowServices
        harness.savedWorkflow = { [weak workflows] request, frame, next in
            guard let workflows else { throw AgentError.message("本地流程不可用") }
            return try await workflows.savedTool(request, initial: frame, next: next)
        }
        harness.savedWorkflowContext = { [weak workflows] in workflows?.advertisedPlans() ?? "{}" }
        harness.externalPendingReview = { [weak workflows] in workflows?.blocksGUI ?? true }
        workflows.model = { [weak self] prompt in
            guard let self, self.consentReady else { throw AgentError.message("请先授权当前模型处理已读取的文字") }
            let settings = self.settings
            let client = VisionClient(settings: settings, apiKey: SettingsStore.apiKey(for: settings.endpoint),
                                      metrics: self.engine.running ? self.engine.runMetrics : nil)
            let answer = try await client.answer(question: prompt, frame: nil, history: [], drafting: true)
            try Task.checkCancellation()
            guard self.consentReady, self.settings.endpoint == settings.endpoint, self.settings.model == settings.model else {
                throw AgentError.message("模型授权或接收方已改变，本批结果未采用")
            }
            return answer
        }
        #if DEBUG
        if let importedModelNotice { notice = importedModelNotice }
        if let importedCtripNotice { notice = importedCtripNotice }
        Task { await DebugCtripConfigImport.probeIfRequested() }
        #endif
        capture.maxSide = settings.imageMaxSide
        for publisher in [ble.objectWillChange, capture.objectWillChange, engine.objectWillChange, history.objectWillChange, taskQueue.objectWillChange, memories.objectWillChange, tools.objectWillChange, contentStore.objectWillChange, camera.objectWillChange, liveCamera.objectWillChange, taskActivity.objectWillChange, taskNotifications.objectWillChange, workflowServices.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        }
        engine.$taskIndicator.removeDuplicates().sink { [weak self] value in
            self?.ble.setTaskIndicator(value)
        }.store(in: &observers)
        conversation.taskContext = { [weak self] in guard let self else { return "{}" }; return self.unifiedTaskContext(history: self.conversation.messages) }
        conversation.routingTaskContext = { [weak self] question, history in
            guard let self else { return "{}" }
            return self.unifiedTaskContext(history: history, question: question)
        }
        conversation.taskControlContext = { [weak self] in self?.conversationControlContext }
        conversation.pendingTaskSubmission = { [weak self] in
            guard let self else { return nil }
            return self.pendingTaskForConversation(self.conversation.currentConversationID)
        }
        conversation.unifiedRoute = { [weak self] input in
            guard let self, self.consentReady else { throw AgentError.message("当前 AI 数据授权已失效") }
            let config = self.settings, credential = SettingsStore.apiKey(for: self.settings.endpoint)
            let submittedConfiguration = ConversationRoutingConfiguration(connection: config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + PrivacyConsent.recipient(config),
                model: config.model, useMemories: config.useMemories == true)
            guard (input.configuration == nil || input.configuration == submittedConfiguration),
                  input.memoryRevision == nil || input.memoryRevision == self.memories.recallRevision else {
                throw AgentError.message("模型或记忆设置已改变，请重新发送")
            }
            let controlContext = ConversationTaskScope.controlContext(input.controlContext,
                taskIDs: input.authorizedTaskIDs, pendingTaskID: input.pendingTask?.taskID)
            var result = try await UnifiedConversationRouter(settings: config, apiKey: credential).route(input: input)
            try Task.checkCancellation()
            guard self.consentReady, self.settings.endpoint == config.endpoint, self.settings.model == config.model,
                  PrivacyConsent.recipient(self.settings) == PrivacyConsent.recipient(config),
                  self.settings.useMemories == config.useMemories,
                  input.memoryRevision == nil || input.memoryRevision == self.memories.recallRevision else { throw AgentError.message("模型或记忆设置已改变，请重新发送") }
            if result.controlsTask {
                let activeTargets = Set(input.backgroundSessions.keys).union([controlContext?.taskID].compactMap { $0 })
                guard let target = ConversationTaskScope.controlTarget(result.taskID ?? input.selectedTaskID,
                    context: controlContext, taskIDs: input.authorizedTaskIDs, ambiguous: activeTargets.count > 1) else {
                    return ConversationRoute(mode: .clarify, request: "",
                        message: input.authorizedTaskIDs.isEmpty ? "这次对话没有关联可控制的任务，请说明新任务。" : "请说明要控制本对话的哪项任务。",
                        relation: .independent)
                }
                result.taskID = target
                result.authorizedTaskIDs = input.authorizedTaskIDs
                if let pending = input.pendingTask, pending.taskID == target {
                    guard [.pause, .stop].contains(result.mode), self.pendingTaskForConversation(pending.conversationID) == pending,
                          let controlContext,
                          ConversationTaskScope.controlContext(self.conversationControlContext, taskIDs: input.authorizedTaskIDs,
                              pendingTaskID: pending.taskID) == controlContext else { throw AgentError.message("等待中的任务状态已改变，请重新核对") }
                    result.pendingTask = pending; result.controlContext = controlContext
                    return result
                }
                // Bind only the selected worker's submitted session. A change
                // to another task cannot invalidate or redirect this command.
                if let target = result.taskID, let submitted = input.backgroundSessions[target] {
                    guard self.backgroundTasks.token(target) == submitted else { throw AgentError.message("这项后台任务状态已改变，请核对后重新发送") }
                    result.backgroundControlToken = submitted
                } else if result.mode == .resume, self.backgroundTasks.token(target) == nil,
                          self.recoverableTask(target)?.executionLane == "native" {
                    // The submitted session link/explicit task-page selection is
                    // sufficient for exact native recovery; never borrow a GUI lease.
                    return result
                } else {
                    guard result.taskID == nil || self.backgroundTasks.token(result.taskID!) == nil,
                          ConversationTaskScope.controlContext(self.conversationControlContext, taskIDs: input.authorizedTaskIDs) == controlContext else { throw AgentError.message("任务状态已改变，请核对当前任务后重新发送") }
                    result.controlContext = controlContext
                }
            }
            return result
        }
        conversation.backgroundTaskSessions = { [weak self] in self?.backgroundTasks.sessions ?? [:] }
        conversation.onActionInConversation = { [weak self] route, messageID, origin in
            var bound = route; bound.originConversationID = origin
            self?.handleConversationAction(bound, messageID: messageID)
        }
        conversation.paotuiQuery = { [weak self] input, conversationID in
            guard let self, self.consentReady else { throw AgentError.message("AI 数据授权已失效") }
            let settings = self.settings, key = SettingsStore.apiKey(for: settings.endpoint)
            let configuration = ConversationRoutingConfiguration(connection: settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + PrivacyConsent.recipient(settings),
                model: settings.model, useMemories: settings.useMemories == true)
            guard (input.configuration == nil || input.configuration == configuration),
                  input.memoryRevision == nil || input.memoryRevision == self.memories.recallRevision else { throw AgentError.message("模型或记忆设置已改变，请重新发送") }
            let reply = try await MeituanPaotuiConversation.shared.respond(question: input.question, history: input.history,
                conversationID: conversationID, settings: settings, apiKey: key, routingInput: input)
            try Task.checkCancellation()
            guard self.consentReady, self.settings.endpoint == settings.endpoint, self.settings.model == settings.model,
                  self.settings.useMemories == settings.useMemories,
                  PrivacyConsent.recipient(self.settings) == PrivacyConsent.recipient(settings),
                  input.memoryRevision == nil || input.memoryRevision == self.memories.recallRevision else { throw AgentError.message("模型或记忆设置已改变，请重新发送") }
            return reply
        }
        conversation.paotuiSelection = { [weak self] card, selection, conversationID in
            guard let self, self.consentReady, self.conversation.currentConversationID == conversationID else { throw AgentError.message("对话已改变，请重新核对") }
            return try await MeituanPaotuiConversation.shared.select(card, selection, conversationID: conversationID)
        }
        conversation.flightQuery = { [weak self] query in
            guard let self, self.consentReady else { throw AgentError.message("AI 数据授权已失效") }
            guard CtripStore.enabled, CtripStore.hasCredential else { throw AgentError.message("请先连接携程") }
            let credential = CtripStore.apiKey(), mode = CtripStore.connectionMode
            let result = try await CtripClient(apiKey: credential, apiEndpoint: mode.endpoint).queryFlights(query: query, canRetry: {
                self.consentReady && credential == CtripStore.apiKey() && CtripStore.enabled && mode == CtripStore.connectionMode
            })
            try Task.checkCancellation()
            guard self.consentReady, credential == CtripStore.apiKey(), CtripStore.enabled, mode == CtripStore.connectionMode else { throw AgentError.message("携程连接已改变，请重新查询") }
            #if DEBUG
            SelaDeviceDiagnostics.flightAttempts = result.attempts
            SelaDeviceDiagnostics.flightRealtimeUnavailable = result.realtimeUnavailable
            #endif
            return "来源：携程官方查询 · " + Date().formatted(date: .abbreviated, time: .shortened) + "\n\n" + result.displayText
        }
        engine.systemTool = { [weak self] taskID, request in
            guard let self, self.consentReady else { throw AgentError.message("AI 数据授权已失效") }
            let config = self.engine.currentSettings ?? self.settings
            return try await self.executeTaskTool(request, taskID: taskID, settings: config, background: false)
        }
        engine.memoryContext = { [weak self] query, settings in await self?.memories.context(for: query, settings: settings) ?? "" }
        engine.systemToolEvidence = { [weak self] taskID in
            guard let self, self.consentReady else { return "" }
            return self.tools.taskContentEvidence(taskID: taskID)
        }
        engine.$phase.removeDuplicates().sink { [weak self] phase in
            // Start while foreground, before the throttled updates or an App switch.
            if phase == .preparing { self?.updateTaskActivity(phase: phase) }
        }.store(in: &observers)
        engine.$currentRecord.combineLatest(engine.$phase, engine.$currentStep, engine.$releasing).throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true).sink { [weak self] _, _, _, _ in self?.updateTaskActivity() }.store(in: &observers)
        engine.$currentRecord.combineLatest(engine.$phase, engine.$releasing).sink { [weak self] record, phase, releasing in
            guard let self else { return }
            self.taskNotifications.observe(taskID: record?.id, title: record?.title ?? "",
                sessionID: self.engine.activityControlSessionID, phase: phase.rawValue, releasing: releasing)
        }.store(in: &observers)
        engine.persistRecord = { [weak self] record in
            guard let self else { return false }
            let saved = self.history.upsert(record)
            if !saved { self.notice = self.history.error }
            return saved
        }
        engine.executionPersistenceReady = { [weak self] in
            guard let self else { return false }
            return self.history.error.isEmpty && (self.queueActiveID == nil || self.taskQueue.error.isEmpty)
        }
        engine.completedToolReceipts = { [weak self] taskID in
            guard let self, self.consentReady else { return [] }
            return self.tools.completedTaskReceipts(taskID: taskID)
        }
        engine.onRecord = { [weak self] record in
            guard let self else { return }
            guard self.history.error.isEmpty else { self.notice = self.history.error; return }
            self.recordQueueProgress(record)
            if let pending = self.pendingConversationTask, pending.taskID == record.id {
                self.pendingConversationTask = nil
                if self.conversation.linkTask(record.id, to: pending.messageID, in: pending.conversationID) {
                    self.conversation.reportTaskHandoff(text: "任务已启动。", to: pending.messageID, in: pending.conversationID, onlyIfUnlinked: false)
                } else {
                    self.conversation.reportTaskHandoff(text: "任务已启动，但任务卡未能保存关联，请到任务记录查看。", to: pending.messageID, in: pending.conversationID, onlyIfUnlinked: false)
                }
            }
            self.conversation.retainTaskResult(record.nativeConversationSnapshot)
        }
        engine.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self, self.recordingAudioOwner == nil, self.settings.spokenFeedback == true, UIApplication.shared.applicationState == .active else { return }
            if phase == .completed { self.speech.speak("任务已完成。" + String(self.engine.state.prefix(140))) }
            else if phase == .needsUser { self.speech.speak("任务需要你处理。" + String(self.engine.state.prefix(140))) }
        }.store(in: &observers)
        speech.prepareAudio = { [weak self] in
            guard self?.recordingAudioOwner == nil else { throw AgentError.message("请先结束当前音频会话，再使用语音") }
            try await self?.pip.suspendForVoice()
            guard self?.recordingAudioOwner == nil else { throw AgentError.message("当前音频会话正在运行，请稍后重试") }
        }
        speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        conversation.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        for offset in stride(from: 0, to: history.records.count, by: 50) {
            let batch = Array(history.records[offset..<min(offset + 50, history.records.count)])
            conversation.retainTaskResults(batch.map(\.nativeConversationSnapshot))
        }
        Publishers.Merge(
            NotificationCenter.default.publisher(for: UIAccessibility.assistiveTouchStatusDidChangeNotification),
            NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification))
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.assistiveTouchVerification.invalidate(); self?.objectWillChange.send()
            }.store(in: &observers)
        capture.onStop = { [weak self] in
            self?.assistiveTouchVerification.invalidate()
            if self?.manualBusy == true { self?.manualContinuationRequired = true }
            self?.manual?.cancel()
            self?.contentStore.invalidatePreparations()
            self?.cancelVoicePreparation(message: "屏幕共享已停止，语音任务已取消")
            if self?.settings.toolsOnly != true { self?.engine.stop(reason: "屏幕共享已停止") }
        }
        AgentActivityControls.handler = { [weak self] taskID, sessionID, control in
            await self?.performActivityControl(taskID: taskID, sessionID: sessionID, control: control)
        }
    }
    private func updateTaskActivity(phase: AgentPhase? = nil) {
        taskActivity.update(record: engine.currentRecord, phase: phase ?? engine.phase, step: engine.currentStep, action: engine.executingAction?.label,
                            enabled: settings.liveTaskStatus != false, sessionID: engine.activityControlSessionID,
                            releasing: engine.releasing, canPause: engine.running, canStop: engine.hasCurrentTask)
    }
    private func performActivityControl(taskID: UUID, sessionID: UUID, control: ActivityTaskControl) async {
        // Validate before the first suspension. An archived card, old run of the
        // same queued task, completed task or disabled feature has no authority.
        guard settings.liveTaskStatus != false, engine.currentRecord?.id == taskID,
              engine.activityControlSessionID == sessionID, taskActivity.represents(taskID),
              engine.hasCurrentTask else {
            updateTaskActivity(); await taskActivity.flush(); return
        }
        switch control {
        case .pause:
            guard engine.running else { updateTaskActivity(); await taskActivity.flush(); return }
            _ = pauseTask()
            notice = "已从实时活动暂停，任务进度已保留"
        case .stop:
            guard ![AgentPhase.completed, .stopped, .idle, .preview].contains(engine.phase) else { return }
            stop(); notice = "已从实时活动停止"
        }
        // Cancellation is synchronous; release may wait for a submitted OS / BLE
        // operation. Show that distinction before waiting, and bound this intent.
        let settledSession = engine.activityControlSessionID
        updateTaskActivity(); await taskActivity.flush()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while engine.releasing && ProcessInfo.processInfo.systemUptime < deadline {
            guard engine.currentRecord?.id == taskID, engine.activityControlSessionID == settledSession else { return }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
        guard engine.currentRecord?.id == taskID, engine.activityControlSessionID == settledSession else { return }
        updateTaskActivity(); await taskActivity.flush()
    }
    var automaticPreparationSnapshot: AutomaticPreparationSnapshot {
        AutomaticPreparationSnapshot(modelReady: modelReady, consentReady: consentReady,
            toolsOnly: settings.toolsOnly == true, systemToolsEnabled: settings.systemToolsEnabled == true,
            previewOnly: settings.previewOnly, assistiveTouchReady: assistiveTouchReady,
            deviceReady: ble.ready, calibrationReady: calibrationReady,
            fullScreenReady: capture.running && capture.frame?.fullDisplay == true)
    }
    func openAccessorySettings() {
        Task { @MainActor in
            do { try await AccessibilitySettings.openSettings(for: .assistiveTouchDevices) }
            catch { notice = "请打开 iPhone 设置 → 辅助功能 → 触控 → 辅助触控 → 设备，配对 AgentMouse" }
        }
    }
    func prepareAutomatically(startWhenReady: Bool = false, attachments: [ComposerAttachment] = [], configurationOnly: Bool = false, conversationTask: ConversationTaskSubmission? = nil) {
        guard !interactionBusy, !executor.calibrationInProgress, !queueRunning else {
            if let pending = conversationTask {
                conversation.reportTaskHandoff(text: "任务未启动：设备正在处理其他操作，无法开始准备。", to: pending.messageID, in: pending.conversationID)
            }
            return
        }
        if let conversationTask {
            guard startWhenReady, pendingConversationTask == conversationTask, goal == conversationTask.goal else {
                notice = "任务请求或草稿已改变，请重新发送"
                conversation.reportTaskHandoff(text: "任务未启动：" + notice, to: conversationTask.messageID, in: conversationTask.conversationID)
                return
            }
        }
        speech.cancel(); liveCamera.stop(); camera.stop(); conversation.cancelScreenBoundRequest()
        preparingAutomatically = true; automaticPreparationStatus = "正在检查设备与已保存配置"
        if let pending = conversationTask {
            conversation.reportTaskHandoff(text: "正在准备设备，任务尚未开始执行。", to: pending.messageID, in: pending.conversationID)
        }
        // Home configuration never starts a task or treats saved setup as a
        // live screen/control session. Execution retains its separate checks.
        preparingSavedConfiguration = configurationOnly && !startWhenReady
        let savedConfigurationOnly = preparingSavedConfiguration
        automaticPreparationOwnsCapture = false
        let token = UUID(); automaticPreparationGeneration = token
        automaticPreparationConversationTaskID = conversationTask?.taskID
        let submittedGoal = goal, submittedPlan = taskPlan
        automaticPreparation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.automaticPreparationGeneration == token {
                    if let conversationTask, self.pendingConversationTask?.taskID == conversationTask.taskID {
                        if !self.engine.running || self.engine.currentRecord?.id != conversationTask.taskID {
                            let reason = self.automaticPreparationStatus.isEmpty ? "准备已结束，请核对设备状态后重新发送。" : self.automaticPreparationStatus
                            self.conversation.reportTaskHandoff(text: "任务未启动：" + reason, to: conversationTask.messageID, in: conversationTask.conversationID)
                            self.pendingConversationTask = nil
                        }
                    }
                    self.automaticPreparationConversationTaskID = nil
                    self.preparingAutomatically = false; self.automaticPreparation = nil
                    self.preparingSavedConfiguration = false; self.configurationSettingsOpen = false
                    self.showConfigurationSettings = false
                    self.automaticCalibrationRequested = false
                    if self.automaticPreparationOwnsCapture {
                        self.automaticPreparationOwnsCapture = false; self.capture.stop()
                    }
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 240
            var requestedConsent = false, openedAssistiveTouch = false, requestedDevice = false
            var openedPairing = false, requestedScreen = self.capture.running || self.capture.waitingForPicker
            var correctedScreenSelection = false
            var requestedConfigurationSettings: Set<AutomaticPreparationStep> = []
            var deviceStartedAt: Double?
            while !Task.isCancelled, self.automaticPreparationGeneration == token {
                if let conversationTask, self.pendingConversationTask != conversationTask { return }
                if startWhenReady && self.goal != submittedGoal {
                    self.automaticPreparationStatus = "任务草稿已更改，请重新开始"; return
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    self.cancelAutomaticPreparation(message: "准备超时，已停止等待。完成系统设置后可再次一键准备")
                    return
                }
                // Settings and system sharing may temporarily take the app away.
                guard UIApplication.shared.applicationState == .active else {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    continue
                }
                if self.configurationSettingsOpen {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    continue
                }
                if self.awaitingAutomaticCalibration || self.calibrating || self.executor.calibrationInProgress {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    continue
                }
                if savedConfigurationOnly && self.configurationReady {
                    self.automaticPreparationStatus = "配置完成"
                    self.configurationCompletionID = UUID()
                    return
                }
                switch self.automaticPreparationSnapshot.nextStep {
                case .model:
                    self.automaticPreparationStatus = "请先填写并保存模型接口、模型名称和 API Key；之后会自动复用"
                    if savedConfigurationOnly {
                        guard requestedConfigurationSettings.insert(.model).inserted else { return }
                        self.configurationSettingsOpen = true; self.showConfigurationSettings = true
                        break
                    }
                    self.showPreparation = true; return
                case .consent:
                    self.automaticPreparationStatus = "请确认当前模型的数据使用授权"
                    if !requestedConsent { requestedConsent = true; self.requestConsent() }
                case .systemTools:
                    self.automaticPreparationStatus = "请在设置中启用系统工具"
                    if savedConfigurationOnly {
                        guard requestedConfigurationSettings.insert(.systemTools).inserted else { return }
                        self.configurationSettingsOpen = true; self.showConfigurationSettings = true
                        break
                    }
                    self.showPreparation = true; return
                case .assistiveTouch:
                    self.automaticPreparationStatus = self.assistiveTouchObservedState == .disabled
                        ? "请在系统设置开启辅助触控，返回后继续准备"
                        : "请核对辅助触控已开启，返回使用准备或设备页确认本次设置"
                    if self.assistiveTouchObservedState == .unknown { self.showPreparation = true }
                    if !openedAssistiveTouch {
                        openedAssistiveTouch = true
                        do { try await AccessibilitySettings.openSettings(for: .assistiveTouch) }
                        catch {
                            self.automaticPreparationStatus = "请在 iPhone 设置 → 辅助功能 → 触控中开启辅助触控"
                            return
                        }
                    }
                case .device:
                    if deviceStartedAt == nil { deviceStartedAt = ProcessInfo.processInfo.systemUptime }
                    if self.ble.bluetoothNeedsPermission {
                        self.automaticPreparationStatus = "请在系统设置中允许蓝牙访问，再次一键准备"
                        if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                        return
                    }
                    if self.ble.bluetoothPoweredOff {
                        self.automaticPreparationStatus = "请开启 iPhone 蓝牙，再次一键准备"; return
                    }
                    if !self.ble.bluetoothPoweredOn {
                        self.automaticPreparationStatus = "正在等待系统蓝牙就绪"
                        break
                    }
                    self.automaticPreparationStatus = "正在自动查找并连接 AgentMouse"
                    if !requestedDevice { requestedDevice = true; self.ble.scan() }
                    if !self.ble.connected, !self.ble.scanning, self.ble.devices.count > 1 {
                        self.automaticPreparationStatus = "发现多个配件，请在设备页选择你的 AgentMouse，再次一键准备"
                        return
                    }
                    if !self.ble.connected, !self.ble.scanning, !self.ble.error.isEmpty,
                       ProcessInfo.processInfo.systemUptime - (deviceStartedAt ?? 0) > 15 {
                        if !self.ble.hasSavedAccessory, self.ble.devices.isEmpty, !openedPairing {
                            openedPairing = true
                            self.automaticPreparationStatus = "首次使用请在系统中配对 AgentMouse，返回后自动连接"
                            do { try await AccessibilitySettings.openSettings(for: .assistiveTouchDevices) }
                            catch { return }
                            requestedDevice = false; deviceStartedAt = nil
                        } else {
                            self.automaticPreparationStatus = self.ble.devices.count > 1
                                ? "发现多个配件，请在设备页选择你的 AgentMouse，再次一键准备"
                                : "配件尚未就绪：" + self.ble.error
                            return
                        }
                    }
                    if let deviceStartedAt, ProcessInfo.processInfo.systemUptime - deviceStartedAt > 45 {
                        self.automaticPreparationStatus = "配件未就绪：" + (self.ble.error.isEmpty ? self.ble.state : self.ble.error)
                        return
                    }
                case .calibration:
                    self.automaticPreparationStatus = "正在为当前配件准备自动校准，请保持竖屏并勿触碰屏幕"
                    if !self.ble.bufferedMotionReady {
                        self.automaticPreparationStatus = "配件固件不支持精细校准，请先升级固件"; return
                    }
                    if !self.awaitingAutomaticCalibration {
                        self.awaitingAutomaticCalibration = true; self.automaticCalibrationRequested = true
                    }
                case .screen:
                    self.automaticPreparationStatus = "请在系统窗口确认整屏共享；共享保持期间会自动复用"
                    if self.capture.running, self.capture.frame?.fullDisplay == false {
                        guard !correctedScreenSelection else {
                            self.automaticPreparationStatus = "选择的仍是单个应用，请再次准备并在系统窗口选择整屏"
                            return
                        }
                        correctedScreenSelection = true; self.capture.stop(); requestedScreen = false
                    }
                    if !requestedScreen, !self.capture.running {
                        requestedScreen = true; self.automaticPreparationOwnsCapture = true; self.capture.start()
                    } else if requestedScreen, !self.capture.running, !self.capture.waitingForPicker {
                        self.automaticPreparationStatus = self.capture.error.isEmpty ? "屏幕共享已取消，准备已停止" : self.capture.error
                        return
                    }
                case .ready:
                    guard !self.calibrating, !self.executor.calibrationInProgress else { break }
                    guard self.preparationReady else {
                        self.automaticPreparationStatus = "当前设备状态已变化，正在重新检查准备"
                        break
                    }
                    self.automaticPreparationStatus = "已准备就绪，已保存配置会自动复用"
                    self.automaticPreparationOwnsCapture = false
                    if startWhenReady {
                        // Only this live submission may start; it is never persisted.
                        self.engine.start(task: submittedGoal, settings: self.settings, subtasks: submittedPlan, attachments: attachments, taskID: conversationTask?.taskID ?? UUID(), conversationReference: conversationTask?.reference ?? "")
                        if self.engine.running {
                            self.taskPlan = []
                            if let pending = conversationTask {
                                self.conversation.reportTaskHandoff(text: "已交给执行器，正在等待任务启动回执。", to: pending.messageID, in: pending.conversationID)
                            }
                        } else { self.automaticPreparationStatus = "执行器没有接收本次请求，请检查准备状态后重新发送。" }
                    }
                    return
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
    }
    func automaticCalibrationFinished(success: Bool, error: String) {
        awaitingAutomaticCalibration = false
        guard preparingAutomatically else { return }
        if !success { cancelAutomaticPreparation(message: error.isEmpty ? "校准已取消，准备已停止" : "校准未通过：" + error) }
    }
    func cancelAutomaticPreparation(message: String = "已取消自动准备") {
        if let id = automaticPreparationConversationTaskID, let pending = pendingConversationTask, pending.taskID == id {
            conversation.reportTaskHandoff(text: "任务未启动：" + message, to: pending.messageID, in: pending.conversationID)
        }
        if let id = automaticPreparationConversationTaskID, pendingConversationTask?.taskID == id { pendingConversationTask = nil }
        automaticPreparationConversationTaskID = nil
        assistiveTouchVerification.invalidate()
        automaticPreparationGeneration = UUID(); automaticPreparation?.cancel(); automaticPreparation = nil
        preparingAutomatically = false; automaticCalibrationRequested = false; awaitingAutomaticCalibration = false
        preparingSavedConfiguration = false; configurationSettingsOpen = false; showConfigurationSettings = false
        automaticPreparationStatus = message
        if calibrating { cancelCalibration?() }
        if automaticPreparationOwnsCapture { automaticPreparationOwnsCapture = false; capture.stop() }
    }
    @discardableResult
    func startAgent(attachments: [ComposerAttachment] = [], conversationTask: ConversationTaskSubmission? = nil) -> Bool {
        defer {
            if let conversationTask, pendingConversationTask?.taskID == conversationTask.taskID,
               !preparingAutomatically, !pendingConsentStart,
               !engine.running || engine.currentRecord?.id != conversationTask.taskID {
                conversation.reportTaskHandoff(text: "任务未启动：" + (notice.isEmpty ? "执行器没有接收这次请求，请核对准备状态后重新发送。" : notice),
                    to: conversationTask.messageID, in: conversationTask.conversationID)
                pendingConversationTask = nil
            }
        }
        if let conversationTask {
            guard pendingConversationTask == conversationTask, goal == conversationTask.goal else { notice = "任务请求或草稿已改变，请重新发送"; return false }
        }
        do { try ComposerAttachmentPolicy.validate(attachments) }
        catch { notice = error.localizedDescription; return false }
        guard recordingAudioOwner == nil else { notice = "请先结束当前音频会话，再执行手机任务"; return false }
        guard !queueRunning, screenQueueWaiting.isEmpty else {
            notice = "屏幕任务队列仍有等待项，请打开队列按顺序开始"; return false
        }
        guard !engine.hasCurrentTask else {
            notice = "请先完成或结束当前任务，再开始新任务"
            return false
        }
        guard !preparingAutomatically, !queueSwitching, !voicePending, !calibrating, !manualBusy, !executor.calibrationInProgress else {
            notice = "正在准备、切换任务或处理其他操作，请稍后重新发送"
            return false
        }
        guard !engine.releasing else { notice = "正在释放上一任务的输入，请稍后重新发送"; return false }
        speech.cancel(); liveCamera.stop(); camera.stop(); conversation.cancelScreenBoundRequest(); notice = ""
        guard modelReady else { notice = "请先配置模型服务"; showPreparation = true; return false }
        guard consentReady else {
            pendingConsentStart = true; pendingConsentAttachments = attachments; pendingConsentConversationTask = conversationTask; showPrivacyConsent = true
            if let pending = conversationTask {
                conversation.reportTaskHandoff(text: "正在等待已有的数据使用授权，任务尚未启动。", to: pending.messageID, in: pending.conversationID)
            }
            return false
        }
        guard preparationReady else { prepareAutomatically(startWhenReady: true, attachments: attachments, conversationTask: conversationTask); return false }
        engine.start(task: goal, settings: settings, subtasks: taskPlan, attachments: attachments, taskID: conversationTask?.taskID ?? UUID(), conversationReference: conversationTask?.reference ?? "")
        if engine.running { taskPlan = [] }
        return engine.running
    }
    func requestVoiceTask(_ text: String) -> String {
        guard !preparingAutomatically else { return "正在准备设备与校准，请稍候或取消准备。" }
        guard recordingAudioOwner == nil else { return "请先结束当前音频会话，再开始任务。" }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return "请输入 1 至 4000 字的任务。" }
        if settings.toolsOnly != true, engine.hasCurrentTask || queueRunning || !screenQueueWaiting.isEmpty {
            let request = ConversationRoute(mode: .task, request: text, message: "", execution: .screen)
            if queueConversationScreenTask(request) != nil { return "已加入屏幕任务队列，点开始队列后按顺序执行。" }
            return notice.isEmpty ? "任务未加入队列，请稍后重试。" : notice
        }
        let route = VoiceTaskRequestRouter.route(
            hasCurrentTask: engine.hasCurrentTask,
            pendingTaskCount: taskQueue.pendingCount,
            queueRunning: queueRunning,
            engineRunning: engine.running,
            queueSwitching: queueSwitching,
            engineReleasing: engine.releasing,
            voicePending: voicePending,
            manualBusy: manualBusy,
            calibrating: calibrating || executor.calibrationInProgress
        )
        switch route {
        case .busy:
            return engine.hasCurrentTask ? "请先完成或结束当前任务，再开始新任务。" : "已有操作或校准正在进行，请稍后再发出新任务。"
        case .start:
            break
        }
        goal = text
        guard consentReady else {
            pendingConsentStart = false; showPrivacyConsent = true
            notice = "请先确认向当前 AI 服务发送画面与任务数据，再重新发出语音指令"
            return notice
        }
        guard !SettingsStore.apiKey().isEmpty else {
            notice = "请先在模型与设置中保存 API Key"
            return notice
        }
        liveCamera.stop(); camera.stop(); conversation.cancelScreenBoundRequest()
        if settings.toolsOnly == true {
            guard modelReady, settings.systemToolsEnabled == true else { notice = "请先配置模型并启用系统工具"; return notice }
            voiceRequestID = UUID(); engine.start(task: text, settings: settings)
            return engine.running ? "已开始自动执行系统工具任务" : engine.error
        }
        guard settings.previewOnly || executor.calibration?.usable == true else {
            notice = "请先在设备与校准中完成鼠标定位校准"
            return notice
        }
        goal = text; voiceRequestID = UUID(); voicePending = true
        notice = "已收到语音任务，正在准备画面和鼠标。出现系统共享窗口时，请选择整屏。"
        let token = UUID(); voiceGeneration = token
        // Only this live, cancellable request may start. It isn't restored on launch.
        var taskSettings = settings
        taskSettings.startDelay = max(5, taskSettings.startDelay)
        voicePreparation = Task { [weak self] in
            await self?.prepareVoiceTask(text, settings: taskSettings, token: token)
        }
        return "已收到任务，Sela 正在准备执行。如果出现共享窗口，请确认整屏共享。"
    }
    private func prepareVoiceTask(_ text: String, settings: AgentSettings, token: UUID) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var attemptedCapture = capture.running || capture.waitingForPicker
        var nextScan = 0.0
        while !Task.isCancelled, token == voiceGeneration, voicePending {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                cancelVoicePreparation(message: "准备超时，语音任务已取消。请检查屏幕共享和鼠标连接后重试。")
                return
            }
            if UIApplication.shared.applicationState == .active {
                if !settings.previewOnly, !ble.ready, ProcessInfo.processInfo.systemUptime >= nextScan {
                    ble.scan(); nextScan = ProcessInfo.processInfo.systemUptime + 10
                }
                if !attemptedCapture, !capture.running, !capture.waitingForPicker {
                    attemptedCapture = true; capture.start()
                }
                if attemptedCapture, !capture.error.isEmpty {
                    cancelVoicePreparation(message: "屏幕共享失败，语音任务已取消：\(capture.error)")
                    return
                }
                if let frame = capture.frame, !frame.fullDisplay {
                    cancelVoicePreparation(message: "语音任务已取消。请先选择整屏共享，再重新发出指令。")
                    return
                }
                if capture.running, let frame = capture.frame, frame.fullDisplay,
                   (0..<1.5).contains(Date().timeIntervalSince(frame.confirmedAt)), settings.previewOnly || ble.ready {
                    if !settings.previewOnly {
                        do { _ = try executor.validateCalibration(frame: frame) }
                        catch {
                            cancelVoicePreparation(message: "语音任务已取消：\(error.localizedDescription)")
                            return
                        }
                    }
                    voicePending = false; voicePreparation = nil
                    notice = ""; engine.start(task: text, settings: settings)
                    if !engine.running { notice = engine.error }
                    return
                }
            }
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
        }
    }
    private func cancelVoicePreparation(message: String? = nil) {
        let wasPending = voicePending
        voiceGeneration = UUID(); voicePreparation?.cancel(); voicePreparation = nil; voicePending = false
        if wasPending, let message { notice = message }
    }
    func stop() { stop(cancelConversation: true) }
    func stop(cancelConversation: Bool) {
        if let pending = pendingConversationTask ?? pendingConsentConversationTask {
            let handedToRunningExecutor = engine.running && engine.currentRecord?.id == pending.taskID
            conversation.reportTaskHandoff(text: handedToRunningExecutor ? "已请求停止执行；本次任务此前尚未收到启动回执。" : "任务未启动：已停止等待中的执行请求。", to: pending.messageID, in: pending.conversationID)
        }
        assistiveTouchVerification.invalidate()
        if preparingAutomatically { cancelAutomaticPreparation() }
        contentStore.invalidatePreparations()
        haltQueue("已停止队列，等待任务已保留")
        liveCamera.stop()
        camera.stop()
        speech.cancel()
        if cancelConversation { conversation.cancel() }
        voiceMode = nil
        pendingConsentStart = false; pendingConsentAttachments = []; pendingConsentConversationTask = nil; pendingConversationTask = nil
        cancelVoicePreparation(message: "语音任务已取消")
        if calibrating { cancelCalibration?() }
        // Keep ownership until the cancelled operation has released its input.
        manualContinuationRequired = false
        manual?.cancel()
        engine.stop()
    }
    @discardableResult
    func pauseTask(handoff: Bool = false) -> String {
        contentStore.invalidatePreparations()
        haltQueue(handoff ? "你已接管，队列已暂停" : "队列已暂停")
        let wasPreparing = voicePending || preparingAutomatically || pendingConsentStart
        if let pending = pendingConversationTask ?? pendingConsentConversationTask {
            let handedToRunningExecutor = engine.running && engine.currentRecord?.id == pending.taskID
            conversation.reportTaskHandoff(text: handedToRunningExecutor ? "已请求暂停执行；本次任务此前尚未收到启动回执。" : "任务未启动：已取消等待中的执行请求。", to: pending.messageID, in: pending.conversationID)
        }
        pendingConsentStart = false; pendingConsentAttachments = []; pendingConsentConversationTask = nil; pendingConversationTask = nil
        if preparingAutomatically { cancelAutomaticPreparation() }
        cancelVoicePreparation(message: "语音任务准备已取消")
        if manualBusy {
            manualContinuationRequired = true
            manual?.cancel()
            notice = "已请求暂停，正在保存批次并释放输入；可从已存任务继续"
            return notice
        }
        guard engine.hasCurrentTask else {
            notice = wasPreparing ? "已取消等待中的任务" : "当前没有执行中的任务"
            return notice
        }
        if handoff { engine.handoff() } else { engine.pause() }
        notice = handoff ? "已交给你操作，处理好后说“继续”" : "已暂停，任务进度已保留"
        return notice
    }
    @discardableResult
    func beginVoice(_ mode: VoiceInputMode) -> String {
        guard !preparingAutomatically else { return "请先完成或取消自动准备。" }
        guard recordingAudioOwner == nil else { return "请先结束当前音频会话，再使用语音。" }
        guard !queueSwitching, !calibrating, !manualBusy, !executor.calibrationInProgress else { notice = "请先结束任务切换、校准或手动操作"; return notice }
        if mode == .supplement {
            guard engine.hasCurrentTask else { notice = "当前没有可补充的任务"; return notice }
            _ = pauseTask()
        } else if engine.running || voicePending { _ = pauseTask() }
        speech.cancel(); liveCamera.stop(); camera.stop(); speech.onSilence = nil; conversation.cancel(); voiceMode = mode; voiceRequestID = UUID()
        return mode == .supplement ? "任务已暂停，请说补充要求。" : "请在 Sela 中说出内容。"
    }
    @discardableResult
    func supplementTask(_ text: String, attachments: [ComposerAttachment] = []) -> String {
        haltQueue("补充要求后，请手动继续任务")
        do { try engine.amendTask(text, attachments: attachments); notice = "已加入补充要求，说“继续”后执行" }
        catch { notice = error.localizedDescription }
        return notice
    }
    func resumeVoiceTask(expectedContext: ConversationControlContext? = nil) async -> String {
        guard !Task.isCancelled else { return "继续请求已取消。" }
        if let expectedContext, conversationControlContext != expectedContext { return "任务状态已改变，请核对后重新继续。" }
        guard !manualContinuationRequired else { return "刚才的流程已保存在记录与文件，请选择同一个任务续作；不会恢复另一个旧任务。" }
        haltQueue("已改为语音继续当前任务")
        guard engine.hasCurrentTask else { return "当前没有可继续的任务。" }
        let controlContext = conversationControlContext
        let deadline = Date().addingTimeInterval(5)
        while engine.releasing && Date() < deadline {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return "继续请求已取消。" }
            guard conversationControlContext == controlContext else { return "任务状态已改变，请核对后重新继续。" }
        }
        guard conversationControlContext == controlContext else { return "任务状态已改变，请核对后重新继续。" }
        guard !preparingAutomatically, !queueSwitching, !engine.releasing, !voicePending, !manualBusy, !calibrating else { return "正在释放输入或处理其他操作，请稍后继续。" }
        guard engine.canResume else { return engine.running ? "任务正在执行。" : "当前任务不能继续，请创建新任务。" }
        guard preparationReady else { showPreparation = true; notice = "请先恢复画面、模型或配件，再说“继续”"; return notice }
        guard !Task.isCancelled else { return "继续请求已取消。" }
        speech.cancel(); conversation.cancelScreenBoundRequest(); voiceMode = nil; notice = ""
        engine.resume(settings: settings, delay: max(5, settings.startDelay))
        voiceRequestID = UUID()
        return engine.running ? (settings.toolsOnly == true ? "正在继续自动执行系统工具任务。" : "正在继续任务，请切换回目标应用。") : engine.error
    }
    func handleVoiceCommand(_ command: VoiceCommand) async -> String {
        switch command {
        case .pause: return pauseTask()
        case .handoff: return pauseTask(handoff: true)
        case .stop: stop(); notice = "已停止任务"; return notice
        case .resume: return await resumeVoiceTask()
        case .supplement: return beginVoice(.supplement)
        }
    }
    func submitVoiceText(_ text: String, mode: VoiceInputMode) async -> String {
        guard !Task.isCancelled else { return "提交已取消。" }
        if let command = VoiceCommand.parse(text) { return await handleVoiceCommand(command) }
        switch mode {
        case .task: return requestVoiceTask(text)
        case .supplement: return supplementTask(text)
        case .question:
            showAssistant = true; conversation.draft = text
            return "已把问题放入对话，请确认后发送。"
        }
    }
    func manualAction(allowsBackgroundScreen: Bool = false, _ block: @escaping () async throws -> Void) {
        guard !preparingAutomatically, recordingAudioOwner == nil, !queueRunning, !queueSwitching, !engine.running, !engine.releasing,
              !preparingAutomatically, !manualBusy, !voicePending, !calibrating, !executor.calibrationInProgress else { return }
        guard !workflowServices.blocksGUI else { notice = "文件操作尚在进行或结果待核验，请先到记录与文件处理"; return }
        notice = ""; manualContinuationRequired = false; manualScreenWorkflow = allowsBackgroundScreen; manualBusy = true
        let inputConnection = ble.pointerConnectionGeneration
        manual = Task {
            do { try await block() }
            catch is CancellationError { }
            catch { notice = error.localizedDescription }
            await ble.release(expectedConnection: inputConnection); manualBusy = false; manualScreenWorkflow = false; manual = nil
        }
    }
    func saveKey(_ key: String) {
        do { try SettingsStore.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines)); notice = "模型配置已保存" }
        catch { notice = error.localizedDescription }
    }
}

extension PhoneAgentViewModel {
    private func queuedSnapshot() -> QueuedPhoneTask? {
        guard engine.hasCurrentTask, let record = engine.currentRecord, let settings = engine.currentSettings else { return nil }
        return QueuedPhoneTask(record: record, settings: settings, step: engine.currentStep, started: true,
                               state: engine.running ? .running : .suspended)
    }
    @discardableResult
    func enqueueDraft(priority: Bool = false, attachments: [ComposerAttachment] = [], conversationReference: String = "") -> Bool {
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return false }
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12000 else { notice = "任务内容需为 1–12000 字"; return false }
        let item = QueuedPhoneTask(record: PhoneTaskRecord(title: String(text.prefix(36)), goal: text,
                    outcome: .paused, summary: "已加入队列，尚未执行",
                    subtasks: taskPlan.isEmpty ? nil : taskPlan.map { TaskSubtask(goal: $0) }, attachments: attachments.isEmpty ? nil : attachments,
                    conversationReference: conversationReference.isEmpty ? nil : conversationReference), settings: settings)
        do {
            try taskQueue.append(item)
            goal = ""; taskPlan = []; taskPlanOriginal = ""; taskPlanDraftGoal = nil
            notice = priority ? "已加入优先任务，正在保存原任务进度" : "已加入队列。点“运行队列”后依次执行。"
            if priority { runTaskQueue(first: item.id) }
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    // This authority is process-local. It is never restored from queue.json.
    private func haltQueue(_ reason: String) {
        queueRunning = false; queueSwitching = false; queueGeneration = UUID()
        queueOperation?.cancel(); queueOperation = nil
        queueAdvance?.cancel(); queueAdvance = nil
        queueStatus = reason
    }
    func pauseQueue() {
        haltQueue("队列已暂停，进度已保留")
        engine.pause()
    }
    private func waitForQueueSettlement(_ token: UUID) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !engine.executionSettled {
            try Task.checkCancellation()
            guard token == queueGeneration else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AgentError.message("上一次执行尚未结束；队列已暂停，请稍后再试") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        guard token == queueGeneration else { throw CancellationError() }
    }
    func runTaskQueue(first selected: UUID? = nil) {
        guard !preparingAutomatically else { return }
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !executor.calibrationInProgress else { return }
        queueUsesStrictOrder = false
        haltQueue("正在准备队列")
        let current = queuedSnapshot()
        do {
            try taskQueue.transaction { items in
                if let current {
                    if let index = items.firstIndex(where: { $0.id == current.id }) { items[index] = current }
                    else { items.insert(current, at: 0) }
                }
                if let selected {
                    guard let index = items.firstIndex(where: { $0.id == selected }), items[index].resumable else {
                        throw AgentError.message("这项任务已结束，不能继续")
                    }
                    var item = items.remove(at: index)
                    item.state = current?.id == selected && engine.running ? .running : .waiting
                    item.note = "你已选择优先执行"; items.insert(item, at: 0)
                    if let current, current.id != selected, let old = items.firstIndex(where: { $0.id == current.id }) {
                        let interrupted = items.remove(at: old); items.insert(interrupted, at: 1)
                    }
                } else if let current, let index = items.firstIndex(where: { $0.id == current.id }) {
                    var item = items.remove(at: index); item.state = engine.running ? .running : .waiting
                    items.insert(item, at: 0)
                } else if let index = items.firstIndex(where: { $0.resumable }) {
                    // One explicit Run resumes the next item, not every interrupted item.
                    items[index].state = .waiting
                }
            }
        } catch { notice = error.localizedDescription; queueStatus = "队列未启动"; return }
        queueRunning = true; queueActiveID = current?.id; notice = ""
        if let current, engine.running, selected == nil || selected == current.id {
            queueStatus = "当前任务完成后继续下一项"; return
        }
        let token = queueGeneration; queueSwitching = true
        if engine.running { engine.pause() }
        queueOperation = Task { [weak self] in
            guard let self else { return }
            defer { if self.queueGeneration == token { self.queueSwitching = false; self.queueOperation = nil } }
            do {
                try await self.waitForQueueSettlement(token)
                if let current, selected != nil, selected != current.id {
                    try self.taskQueue.update(current.id) { item in
                        // Failures and user-required steps need a separate explicit review.
                        item.state = [.running, .paused].contains(current.record.outcome) ? .waiting : .suspended
                        item.note = "优先任务结束后从新画面继续；上一步可能已部分执行。"
                    }
                }
                let target = selected ?? current?.id
                if let target { try self.taskQueue.update(target) { $0.state = .waiting } }
                self.engine.discardCurrent(); self.queueActiveID = nil
                try self.launchNextQueued(token)
            } catch is CancellationError { }
            catch { self.haltQueue(error.localizedDescription); self.notice = error.localizedDescription }
        }
    }
    private func launchNextQueued(_ token: UUID) throws {
        guard recordingAudioOwner == nil else { throw AgentError.message("请先结束当前音频会话，再运行队列") }
        guard token == queueGeneration, queueRunning else { throw CancellationError() }
        guard UIApplication.shared.applicationState == .active else { throw AgentError.message("请回到 Sela 点“运行队列”；后台不自动开启下一项") }
        guard history.error.isEmpty, taskQueue.error.isEmpty else { throw AgentError.message("任务记录未能保存，队列已暂停，请先处理存储问题") }
        if queueUsesStrictOrder {
            for pending in taskQueue.items where pending.resumable && isScreenQueueItem(pending) { _ = try reconcileScreenQueueHistory(pending.id) }
        }
        guard let item = taskQueue.items.first(where: { $0.resumable && (!queueUsesStrictOrder || isScreenQueueItem($0)) }) else {
            haltQueue("队列已完成"); return
        }
        guard item.state == .waiting else { throw AgentError.message(item.state == .paused ? "队首任务已暂停；请先点这项的开始，后续任务不会越过它执行" : "下一项需要你核对，点它的开始后再运行") }
        guard !tools.hasUnresolvedWrite(taskID: item.id) else { throw AgentError.message("队首任务有尚未核验的写入，请先核对实际结果") }
        var config = item.settings
        config.confirmEachStep = settings.confirmEachStep
        config.useMemories = config.useMemories == true && settings.useMemories == true
        guard config.endpoint == settings.endpoint, config.model == settings.model,
              PrivacyConsent.recipient(config) == PrivacyConsent.recipient(settings) else {
            throw AgentError.message("模型配置已经改变；在队列中核对并选择“使用当前配置”后再继续")
        }
        guard ModelEndpointPolicy.acceptsModelConnection(config),
              !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              PrivacyConsent.allowed(config), !SettingsStore.apiKey(for: config.endpoint).isEmpty else {
            throw AgentError.message("请先保存模型密钥并确认当前 AI 数据授权，再运行队列")
        }
        if config.systemToolsEnabled == true && settings.systemToolsEnabled != true {
            throw AgentError.message("系统工具已关闭；请核对队列任务的配置")
        }
        // Persist the reservation before any model request or input is started.
        try taskQueue.update(item.id) { $0.state = .running; $0.note = "正在执行"; $0.started = true; $0.settings = config }
        queueActiveID = item.id
        do {
            speech.cancel(); liveCamera.stop(); camera.stop(); conversation.cancelScreenBoundRequest(); voiceMode = nil
            try engine.restoreQueued(record: item.record, settings: config, step: item.step, previouslyStarted: item.started)
            queueStatus = "正在执行：" + item.record.title
        } catch {
            try? taskQueue.update(item.id) { $0.state = .suspended; $0.note = String(error.localizedDescription.prefix(1000)) }
            queueActiveID = nil; throw error
        }
    }
    private func recordQueueProgress(_ record: PhoneTaskRecord) {
        guard queueActiveID == record.id, !handlingQueueFailure else { return }
        do {
            try taskQueue.update(record.id) { item in
                item.record = record; item.step = engine.currentStep; item.started = true
                if let settings = engine.currentSettings { item.settings = settings }
                item.note = String(record.summary.prefix(1000))
                switch record.outcome {
                case .running: item.state = .running
                case .completed: item.state = .completed
                case .stopped: item.state = .stopped
                case .preview: item.state = .preview
                default: item.state = item.state == .paused ? .paused : (queueGlobalResumeID == record.id && record.outcome == .paused ? .waiting : .suspended)
                }
            }
        } catch {
            handlingQueueFailure = true
            haltQueue("队列记录保存失败，已暂停执行")
            if engine.running { engine.pause() }
            notice = taskQueue.error.isEmpty ? error.localizedDescription : taskQueue.error
            handlingQueueFailure = false; return
        }
        if !history.error.isEmpty {
            handlingQueueFailure = true; haltQueue("任务历史保存失败，队列已暂停")
            if engine.running { engine.pause() }
            notice = history.error; handlingQueueFailure = false; return
        }
        if record.outcome == .completed, queueRunning, !queueSwitching {
            scheduleQueueAdvance(after: record.id)
        } else if record.outcome != .running, record.outcome != .completed, !queueSwitching {
            haltQueue("当前任务" + record.outcome.label + "，队列等待你确认")
        }
    }
    private func scheduleQueueAdvance(after id: UUID) {
        guard queueAdvance == nil else { return }
        let token = queueGeneration
        queueSwitching = true
        queueAdvance = Task { [weak self] in
            guard let self else { return }
            defer { if self.queueGeneration == token { self.queueAdvance = nil; self.queueSwitching = false } }
            do {
                try await self.waitForQueueSettlement(token)
                guard self.queueActiveID == id, self.engine.currentRecord?.id == id else { throw AgentError.message("屏幕任务已改变，队列已暂停") }
                self.queueActiveID = nil; self.engine.discardCurrent()
                try self.launchNextQueued(token)
            } catch is CancellationError { }
            catch { self.haltQueue(error.localizedDescription); self.notice = error.localizedDescription }
        }
    }
    private func isScreenQueueItem(_ item: QueuedPhoneTask) -> Bool {
        item.settings.toolsOnly != true && item.record.executionLane != "native"
    }
    var screenQueueCurrent: QueuedPhoneTask? {
        if let record = engine.currentRecord, engine.running || engine.releasing || engine.hasCurrentTask {
            let stored = taskQueue.items.first { $0.id == record.id }
            let config = engine.currentSettings ?? stored?.settings ?? settings
            guard config.toolsOnly != true, record.executionLane != "native" else { return nil }
            var item = stored ?? QueuedPhoneTask(record: record, settings: config, state: engine.running ? .running : .suspended)
            item.record = record; item.settings = config; item.step = engine.currentStep; item.started = true
            if engine.running { item.state = .running }
            else if record.outcome == .completed { item.state = .completed }
            else if record.outcome == .stopped { item.state = .stopped }
            else if record.outcome == .preview { item.state = .preview }
            else if item.state != .paused && item.state != .waiting { item.state = .suspended }
            return item
        }
        if let id = queueActiveID, let item = taskQueue.items.first(where: { $0.id == id && $0.state == .running }), isScreenQueueItem(item) { return item }
        return nil
    }
    var screenQueueWaiting: [QueuedPhoneTask] {
        let current = screenQueueCurrent?.id
        return taskQueue.items.filter { $0.id != current && $0.resumable && isScreenQueueItem($0) }
    }
    var screenQueueCount: Int { screenQueueWaiting.count + (screenQueueCurrent?.resumable == true ? 1 : 0) }
    var screenQueueBusy: Bool { queueSwitching }
    @discardableResult
    private func reconcileScreenQueueHistory(_ id: UUID) throws -> Bool {
        guard let record = history.records.first(where: { $0.id == id }), [.completed, .stopped, .preview].contains(record.outcome),
              let queued = taskQueue.items.first(where: { $0.id == id }), queued.resumable, isScreenQueueItem(queued) else { return false }
        try taskQueue.update(id) { item in
            item.record = record; item.step = max(item.step, record.checkpointStep ?? 0)
            item.state = record.outcome == .completed ? .completed : record.outcome == .preview ? .preview : .stopped
            item.note = "已按任务历史核对结束状态，不会重新执行"
        }
        return true
    }
    @discardableResult
    private func preserveScreenQueueCurrent() throws -> QueuedPhoneTask? {
        guard let current = screenQueueCurrent else { return nil }
        try taskQueue.transaction { items in
            if let index = items.firstIndex(where: { $0.id == current.id }) { items[index] = current }
            else { items.insert(current, at: 0) }
        }
        queueActiveID = current.id
        return current
    }
    @discardableResult
    func startScreenQueue() -> Bool {
        guard !preparingAutomatically, !queueSwitching, !voicePending, !calibrating, !manualBusy,
              !executor.calibrationInProgress, recordingAudioOwner == nil else { notice = "正在处理设备或输入，请稍后开始队列"; return false }
        guard history.error.isEmpty, taskQueue.error.isEmpty else { notice = "任务记录未能保存，请先处理存储问题"; return false }
        if queueRunning { return true }
        guard !(engine.running || engine.hasCurrentTask || engine.releasing) || screenQueueCurrent != nil else {
            notice = "主执行器仍在处理无屏幕任务，请等它结束后再开始屏幕队列"; return false
        }
        let current: QueuedPhoneTask?
        do {
            for item in taskQueue.items where item.resumable && isScreenQueueItem(item) { _ = try reconcileScreenQueueHistory(item.id) }
            // Starting the queue explicitly authorizes untouched waiting work
            // after restart, while individual holds and reviewed failures stay.
            try taskQueue.transaction { items in
                for index in items.indices where isScreenQueueItem(items[index]) && !items[index].started && items[index].state == .suspended && [.paused, .interrupted, .running].contains(items[index].record.outcome) {
                    items[index].state = .waiting; items[index].note = "你已开始队列，将按保存顺序首次执行"
                }
            }
            current = try preserveScreenQueueCurrent()
        }
        catch { notice = error.localizedDescription; return false }
        guard let first = taskQueue.items.first(where: { $0.resumable && isScreenQueueItem($0) }) else { notice = "没有等待执行的屏幕任务"; return false }
        if current?.id != first.id, engine.running { notice = "当前执行项之前仍有等待记录，请先核对队列"; return false }
        guard first.state == .waiting || (first.id == current?.id && engine.running) else {
            notice = first.state == .paused ? "队首任务已暂停，请先点这项的开始；不会越过它执行" : "队首任务需要你核对，请先点这项的开始"; return false
        }
        haltQueue("正在按顺序准备队列"); queueUsesStrictOrder = true; queueRunning = true; queueGlobalResumeID = nil
        notice = ""
        if let current, engine.running {
            queueActiveID = current.id; queueStatus = "当前任务完成后按排队顺序继续"; return true
        }
        let token = queueGeneration, previousID = engine.currentRecord?.id
        queueSwitching = true
        queueOperation = Task { [weak self] in
            guard let self else { return }
            defer { if self.queueGeneration == token { self.queueSwitching = false; self.queueOperation = nil } }
            do {
                try await self.waitForQueueSettlement(token)
                guard self.engine.currentRecord?.id == previousID else { throw AgentError.message("屏幕任务已改变，队列已暂停") }
                self.engine.discardCurrent(); self.queueActiveID = nil
                try self.launchNextQueued(token)
            } catch is CancellationError { }
            catch { self.haltQueue(error.localizedDescription); self.notice = error.localizedDescription }
        }
        return true
    }
    func pauseScreenQueue() {
        let current: QueuedPhoneTask?
        do { current = try preserveScreenQueueCurrent() }
        catch { haltQueue("队列保存失败，已暂停"); engine.pause(); notice = error.localizedDescription; return }
        queueGlobalResumeID = current?.id
        if let current, current.resumable, current.state != .paused {
            do { try taskQueue.update(current.id) { $0.state = .waiting; $0.note = "队列已暂停，点开始队列后保留顺序继续" } }
            catch { notice = error.localizedDescription }
        }
        haltQueue("队列已暂停，原顺序与进度已保留")
        if current != nil { engine.pause() }
    }
    @discardableResult
    func pauseScreenQueueTask(_ id: UUID) -> Bool {
        do {
            if let current = screenQueueCurrent, current.id == id {
                guard current.resumable else { throw AgentError.message("这项任务已结束，未改变队列") }
                queueGlobalResumeID = nil; haltQueue("当前任务已暂停，队列保持原顺序")
                defer { engine.pause() }
                _ = try preserveScreenQueueCurrent()
                try taskQueue.update(id) { $0.state = .paused; $0.note = "你已暂停这项任务；队列不会越过它执行" }
            } else {
                guard let item = taskQueue.items.first(where: { $0.id == id }), item.resumable, isScreenQueueItem(item) else { throw AgentError.message("这项屏幕任务已结束或不存在") }
                try taskQueue.update(id) { $0.state = .paused; $0.note = "你已暂停这项任务；到达队首时等待你恢复" }
            }
            notice = ""; return true
        } catch { screenQueueMutationFailed(error); return false }
    }
    @discardableResult
    func resumeScreenQueueTask(_ id: UUID) -> Bool {
        do {
            if try reconcileScreenQueueHistory(id) { notice = "这项任务已有结束回执，不会重新执行"; return false }
            if screenQueueCurrent?.id == id { _ = try preserveScreenQueueCurrent() }
            guard let item = taskQueue.items.first(where: { $0.id == id }), item.resumable, isScreenQueueItem(item), item.state != .running else { throw AgentError.message("这项任务正在执行、已结束或不存在") }
            guard !tools.hasUnresolvedWrite(taskID: id) else { throw AgentError.message("这项任务有未核验的写入，请先核对实际结果") }
            try taskQueue.update(id) { $0.state = .waiting; $0.note = "已恢复原位置排队；不会置顶或抢占当前任务" }
            notice = queueRunning ? "已按原位置恢复排队" : "已恢复排队，点开始队列后按顺序执行"
            return true
        } catch { screenQueueMutationFailed(error); return false }
    }
    @discardableResult
    func stopScreenQueueTask(_ id: UUID) -> Bool {
        do {
            if let current = screenQueueCurrent, current.id == id {
                guard current.resumable else { throw AgentError.message("这项任务已结束，未改变队列") }
                queueGlobalResumeID = nil; haltQueue("当前任务已终止，其他任务保留，点开始队列后继续")
                defer { engine.stop() }
                _ = try preserveScreenQueueCurrent()
                notice = ""; return true
            }
            guard let item = taskQueue.items.first(where: { $0.id == id }), item.resumable, isScreenQueueItem(item) else { throw AgentError.message("这项屏幕任务已结束或不存在") }
            var record = item.record; record.outcome = .stopped; record.summary = item.started ? "你已终止这项排队任务，已有操作不会撤销" : "你已终止这项排队任务，尚未执行"
            record.updatedAt = Date()
            try taskQueue.update(id) { $0.record = record; $0.state = .stopped; $0.note = record.summary }
            history.upsert(record); guard history.error.isEmpty else { throw AgentError.message(history.error) }
            notice = ""; return true
        } catch { screenQueueMutationFailed(error); return false }
    }
    @discardableResult
    func removeScreenQueueTask(_ id: UUID) -> Bool {
        guard screenQueueCurrent?.id != id else { notice = "请先终止正在执行或保留会话的任务，再删除它"; return false }
        do {
            guard let item = taskQueue.items.first(where: { $0.id == id }), isScreenQueueItem(item), item.state != .running else { throw AgentError.message("这项任务正在执行或已不存在") }
            var record = item.record
            if item.resumable { record.outcome = .stopped; record.summary = item.started ? "已从队列删除，已有操作和回执保留" : "已从队列删除，尚未执行"; record.updatedAt = Date() }
            try taskQueue.remove(id)
            history.upsert(record); guard history.error.isEmpty else { throw AgentError.message(history.error) }
            notice = ""; return true
        } catch { screenQueueMutationFailed(error); return false }
    }
    @discardableResult
    func reorderScreenQueueTasks(_ orderedIDs: [UUID]) -> Bool {
        do { try taskQueue.reorder(orderedIDs, excluding: screenQueueCurrent?.id, screenOnly: true); notice = "排队顺序已保存，当前任务不受影响"; return true }
        catch { screenQueueMutationFailed(error); return false }
    }
    private func screenQueueMutationFailed(_ error: Error) {
        if !taskQueue.error.isEmpty || !history.error.isEmpty { haltQueue("队列变更未能保存，已停止自动执行后续任务") }
        notice = error.localizedDescription
    }
    func useCurrentQueueConfiguration(_ id: UUID) {
        guard !queueRunning, !queueSwitching, !engine.running, !engine.releasing else { return }
        do {
            try taskQueue.update(id) { $0.settings = settings; $0.note = "已改为当前配置，请核对执行模式后继续" }
            if id == engine.currentRecord?.id, engine.canResume { engine.configurePausedTask(settings: settings) }
        }
        catch { notice = error.localizedDescription }
    }
    func moveQueuedTask(_ id: UUID, by offset: Int) {
        var ids = screenQueueWaiting.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset); _ = reorderScreenQueueTasks(ids)
    }
    func removeQueuedTask(_ id: UUID) { _ = removeScreenQueueTask(id) }
    @discardableResult
    func requestQueuedVoiceTask(_ text: String, priority: Bool) -> String {
        "任务列表功能已移除，请直接开始任务。"
    }
    func clearTaskQueue() {
        guard !queueRunning, !queueSwitching, !engine.running, !engine.releasing else { return }
        do { try taskQueue.clear(); queueActiveID = nil; notice = "队列已清除，已执行的实际操作不会撤销" }
        catch { notice = error.localizedDescription }
    }
}
