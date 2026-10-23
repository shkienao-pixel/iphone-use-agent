import Foundation
import Combine
import UIKit

@MainActor
final class PhoneAgentViewModel: ObservableObject {
    static let shared = PhoneAgentViewModel()
    @Published var goal = UserDefaults.standard.string(forKey: "agent.currentGoal") ?? "" {
        didSet {
            UserDefaults.standard.set(goal, forKey: "agent.currentGoal")
            if !taskPlan.isEmpty && taskPlanDraftGoal != goal { taskPlan = []; taskPlanDraftGoal = nil; taskPlanOriginal = "" }
        }
    }
    @Published var settings: AgentSettings { didSet {
        SettingsStore.save(settings); capture.maxSide = settings.imageMaxSide; updateTaskActivity()
        let recipientChanged = oldValue.endpoint != settings.endpoint || oldValue.model != settings.model || PrivacyConsent.recipient(oldValue) != PrivacyConsent.recipient(settings)
        liveCamera.stop(clearResults: recipientChanged)
        if recipientChanged { conversation.cancel(); conversation.selectFrame(nil) }
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
    @Published var workbenchHasDraft = false
    @Published var notice = ""
    @Published var showPrivacyConsent = false
    @Published var showPrivacyPolicy = false
    @Published var showPreparation = false
    private var pendingConsentStart = false
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
    let memories = MemoryStore()
    let recordings = RecordingStore()
    @Published private(set) var recordingAudioOwner: UUID?
    func reserveRecordingAudio(_ id: UUID) -> Bool {
        guard recordingAudioOwner == nil, !engine.running, !engine.releasing, !queueRunning, !queueSwitching,
              !voicePending, voiceMode == nil, !manualBusy, !calibrating, !speech.usingAudio else { return false }
        recordingAudioOwner = id; conversation.cancel(); liveCamera.stop(); camera.stop(); return true
    }
    func releaseRecordingAudio(_ id: UUID) { if recordingAudioOwner == id { recordingAudioOwner = nil } }
    let tools = SystemTools()
    let camera = CameraService()
    let liveCamera = LiveCameraObserver()
    let taskActivity = TaskActivityController()
    var interactionBusy: Bool {
        recordingAudioOwner != nil || queueSwitching || engine.running || engine.releasing || manualBusy || voicePending
    }

    var consentReady: Bool { PrivacyConsent.allowed(settings) }
    var calibrationReady: Bool {
        guard let c = executor.calibration else { return false }
        return c.usable && c.peripheralID == ble.selectedID
    }
    var modelReady: Bool {
        guard let endpoint = try? ModelEndpointPolicy.url(settings.endpoint), endpoint.path.hasSuffix("/chat/completions") else { return false }
        return !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !SettingsStore.apiKey(for: settings.endpoint).isEmpty
    }
    var preparationReady: Bool {
        recordingAudioOwner == nil && modelReady && consentReady && (settings.toolsOnly == true ? settings.systemToolsEnabled == true : (capture.running && capture.frame?.fullDisplay == true &&
            (settings.previewOnly || (ble.ready && calibrationReady))))
    }
    func requestConsent() { pendingConsentStart = false; showPrivacyConsent = true }
    func acceptConsent() {
        guard modelReady else { notice = "请先保存有效的模型配置"; return }
        PrivacyConsent.grant(settings); showPrivacyConsent = false; objectWillChange.send()
        let shouldStart = pendingConsentStart; pendingConsentStart = false
        if shouldStart { startAgent() }
    }
    func declineConsent() { pendingConsentStart = false; showPrivacyConsent = false }
    func revokeConsent() {
        stop(); capture.stop(); PrivacyConsent.revoke(); objectWillChange.send()
        notice = "已撤回 AI 数据授权并停止屏幕共享"
    }
    func resumeAgent() {
        haltQueue("已改为手动继续当前任务")
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return }
        guard preparationReady else { showPreparation = true; notice = "准备完成后，请手动点继续任务"; return }
        notice = ""; engine.resume(settings: settings)
    }
    func removeTask(_ id: UUID) {
        guard !engine.running, !engine.releasing else { return }
        guard !taskQueue.items.contains(where: { $0.id == id }) else { notice = "请先从队列移除此任务，再删除历史"; return }
        if engine.currentRecord?.id == id { engine.discardCurrent() }
        history.remove(id)
    }
    func clearHistory() {
        guard !engine.running, !engine.releasing else { return }
        guard taskQueue.items.isEmpty else { notice = "请先清除任务队列，再清除历史"; return }
        engine.discardCurrent(); history.clear()
    }
    @Published var manualBusy = false
    @Published var calibrating = false
    @Published private(set) var voicePending = false
    @Published var voiceRequestID = UUID()
    @Published var voiceMode: VoiceInputMode?
    @Published var showAssistant = false
    var cancelCalibration: (() -> Void)?
    let ble = BLETransport()
    let capture = CaptureService()
    let executor: MouseExecutor
    let engine: AgentEngine
    lazy var speech = VoiceController()
    lazy var conversation = AssistantConversation()
    lazy var pip = AgentPiPController(engine: engine, stopTask: { [weak self] in self?.stop() })
    private var observers = Set<AnyCancellable>()
    private var manual: Task<Void, Never>?
    private var voicePreparation: Task<Void, Never>?
    private var voiceGeneration = UUID()
    init() {
        #if DEBUG
        let importedModelNotice = DebugModelConfigImport.runIfRequested()
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
        engine.phoneHarness = PhoneHarnessRuntime(executor: executor)
        #if DEBUG
        if let importedModelNotice { notice = importedModelNotice }
        #endif
        capture.maxSide = settings.imageMaxSide
        for publisher in [ble.objectWillChange, capture.objectWillChange, engine.objectWillChange, history.objectWillChange, taskQueue.objectWillChange, memories.objectWillChange, tools.objectWillChange, camera.objectWillChange, liveCamera.objectWillChange, taskActivity.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        }
        engine.$taskIndicator.removeDuplicates().sink { [weak self] value in
            self?.ble.setTaskIndicator(value)
        }.store(in: &observers)
        engine.systemTool = { [weak self] taskID, request in
            guard let self, self.consentReady else { throw AgentError.message("AI 数据授权已失效") }
            return try await self.tools.execute(request, taskID: taskID)
        }
        engine.memoryContext = { [weak self] query in await self?.memories.context(for: query) ?? "" }
        engine.$currentRecord.combineLatest(engine.$phase, engine.$currentStep, engine.$releasing).throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true).sink { [weak self] _, _, _, _ in self?.updateTaskActivity() }.store(in: &observers)
        engine.onRecord = { [weak self] record in
            self?.history.upsert(record); self?.recordQueueProgress(record)
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
        capture.onStop = { [weak self] in
            self?.cancelVoicePreparation(message: "屏幕共享已停止，语音任务已取消")
            if self?.settings.toolsOnly != true { self?.engine.stop(reason: "屏幕共享已停止") }
        }
        AgentActivityControls.handler = { [weak self] taskID, sessionID, control in
            await self?.performActivityControl(taskID: taskID, sessionID: sessionID, control: control)
        }
    }
    private func updateTaskActivity() {
        taskActivity.update(record: engine.currentRecord, phase: engine.phase, step: engine.currentStep, action: engine.executingAction?.label,
                            enabled: settings.liveTaskStatus == true, sessionID: engine.activityControlSessionID,
                            releasing: engine.releasing, canPause: engine.running, canStop: engine.hasCurrentTask)
    }
    private func performActivityControl(taskID: UUID, sessionID: UUID, control: ActivityTaskControl) async {
        // Validate before the first suspension. An archived card, old run of the
        // same queued task, completed task or disabled feature has no authority.
        guard settings.liveTaskStatus == true, engine.currentRecord?.id == taskID,
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
            stop(); notice = "已从实时活动停止，队列等待项已保留"
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
    func startAgent() {
        guard recordingAudioOwner == nil else { notice = "请先结束当前音频会话，再执行手机任务"; return }
        if engine.hasCurrentTask || queueRunning || taskQueue.pendingCount > 0 { enqueueDraft(); return }
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !executor.calibrationInProgress else { return }
        guard !engine.releasing else { return }
        speech.cancel(); liveCamera.stop(); camera.stop(); conversation.cancel(); notice = ""
        guard modelReady else { notice = "请先配置模型服务"; showPreparation = true; return }
        guard consentReady else { pendingConsentStart = true; showPrivacyConsent = true; return }
        guard preparationReady else { showPreparation = true; return }
        engine.start(task: goal, settings: settings, subtasks: taskPlan)
        if engine.running { taskPlan = [] }
    }
    func requestVoiceTask(_ text: String) -> String {
        guard recordingAudioOwner == nil else { return "请先结束当前音频会话，再开始任务。" }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return "请输入 1 至 4000 字的任务。" }
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
        case .queue:
            return requestQueuedVoiceTask(text, priority: false)
        case .busy:
            return "已有操作或校准正在进行，请稍后再发出新任务。"
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
        liveCamera.stop(); camera.stop(); conversation.cancel()
        if settings.toolsOnly == true {
            guard modelReady, settings.systemToolsEnabled == true else { notice = "请先配置模型并启用系统工具"; return notice }
            voiceRequestID = UUID(); engine.start(task: text, settings: settings)
            return engine.running ? "已开始系统工具任务，请在 App 内确认每项操作" : engine.error
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
        return "已收到任务，Phone Agent 正在准备执行。如果出现共享窗口，请确认整屏共享。"
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
    func stop() {
        haltQueue("已停止队列，等待任务已保留")
        liveCamera.stop()
        camera.stop()
        speech.cancel(); conversation.cancel(); voiceMode = nil
        pendingConsentStart = false
        cancelVoicePreparation(message: "语音任务已取消")
        if calibrating { cancelCalibration?() }
        manual?.cancel(); manual = nil; manualBusy = false
        engine.stop()
    }
    @discardableResult
    func pauseTask(handoff: Bool = false) -> String {
        haltQueue(handoff ? "你已接管，队列已暂停" : "队列已暂停")
        let wasPreparing = voicePending
        cancelVoicePreparation(message: "语音任务准备已取消")
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
        guard recordingAudioOwner == nil else { return "请先结束当前音频会话，再使用语音。" }
        guard !queueSwitching, !calibrating, !manualBusy, !executor.calibrationInProgress else { notice = "请先结束任务切换、校准或手动操作"; return notice }
        if mode == .supplement {
            guard engine.hasCurrentTask else { notice = "当前没有可补充的任务"; return notice }
            _ = pauseTask()
        } else if engine.running || voicePending { _ = pauseTask() }
        speech.cancel(); liveCamera.stop(); camera.stop(); speech.onSilence = nil; conversation.cancel(); voiceMode = mode; voiceRequestID = UUID()
        return mode == .supplement ? "任务已暂停，请说补充要求。" : "请在 Phone Agent 中说出内容。"
    }
    @discardableResult
    func supplementTask(_ text: String) -> String {
        haltQueue("补充要求后，请手动继续任务或队列")
        do { try engine.amendTask(text); notice = "已加入补充要求，说“继续”后执行" }
        catch { notice = error.localizedDescription }
        return notice
    }
    func resumeVoiceTask() async -> String {
        guard !Task.isCancelled else { return "继续请求已取消。" }
        haltQueue("已改为语音继续当前任务")
        guard engine.hasCurrentTask else { return "当前没有可继续的任务。" }
        let deadline = Date().addingTimeInterval(5)
        while engine.releasing && Date() < deadline {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return "继续请求已取消。" }
        }
        guard !queueSwitching, !engine.releasing, !voicePending, !manualBusy, !calibrating else { return "正在释放输入或处理其他操作，请稍后继续。" }
        guard engine.canResume else { return engine.running ? "任务正在执行。" : "当前任务不能继续，请创建新任务。" }
        guard preparationReady else { showPreparation = true; notice = "请先恢复画面、模型或配件，再说“继续”"; return notice }
        guard !Task.isCancelled else { return "继续请求已取消。" }
        speech.cancel(); conversation.cancel(); voiceMode = nil; notice = ""
        engine.resume(settings: settings, delay: max(5, settings.startDelay))
        voiceRequestID = UUID()
        return engine.running ? (settings.toolsOnly == true ? "正在继续系统工具任务，请在 App 中确认操作。" : "正在继续任务，请切换回目标应用。") : engine.error
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
    func manualAction(_ block: @escaping () async throws -> Void) {
        guard !queueSwitching, !engine.running, !manualBusy, !voicePending, !calibrating, !executor.calibrationInProgress else { return }
        notice = ""; manualBusy = true
        manual = Task {
            do { try await block() }
            catch is CancellationError { }
            catch { notice = error.localizedDescription }
            await ble.release(); manualBusy = false
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
    func enqueueDraft(priority: Bool = false) {
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return }
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12000 else { notice = "任务内容需为 1–12000 字"; return }
        let item = QueuedPhoneTask(record: PhoneTaskRecord(title: String(text.prefix(36)), goal: text,
                    outcome: .paused, summary: "已加入队列，尚未执行",
                    subtasks: taskPlan.isEmpty ? nil : taskPlan.map { TaskSubtask(goal: $0) }), settings: settings)
        do {
            try taskQueue.append(item)
            goal = ""; taskPlan = []; taskPlanOriginal = ""; taskPlanDraftGoal = nil
            notice = priority ? "已加入优先任务，正在保存原任务进度" : "已加入队列。点“运行队列”后依次执行。"
            if priority { runTaskQueue(first: item.id) }
        } catch { notice = error.localizedDescription }
    }
    // This authority is process-local. It is never restored from queue.json.
    private func haltQueue(_ reason: String) {
        queueRunning = false; queueGeneration = UUID()
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
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !executor.calibrationInProgress else { return }
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
            defer { self.queueSwitching = false; self.queueOperation = nil }
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
        guard UIApplication.shared.applicationState == .active else { throw AgentError.message("请回到 Phone Agent 点“运行队列”；后台不自动开启下一项") }
        guard let item = taskQueue.items.first(where: { $0.resumable }) else {
            haltQueue("队列已完成"); return
        }
        guard item.state == .waiting else { throw AgentError.message("下一项需要你核对，点它的“继续这项”后再运行") }
        var config = item.settings
        config.useMemories = config.useMemories == true && settings.useMemories == true
        guard config.endpoint == settings.endpoint, config.model == settings.model,
              PrivacyConsent.recipient(config) == PrivacyConsent.recipient(settings) else {
            throw AgentError.message("模型配置已经改变；在队列中核对并选择“使用当前配置”后再继续")
        }
        guard let endpoint = try? ModelEndpointPolicy.url(config.endpoint), endpoint.path.hasSuffix("/chat/completions"),
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
            speech.cancel(); liveCamera.stop(); camera.stop(); conversation.cancel(); voiceMode = nil
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
                default: item.state = .suspended
                }
            }
        } catch {
            handlingQueueFailure = true
            haltQueue("队列记录保存失败，已暂停执行")
            if engine.running { engine.pause() }
            notice = taskQueue.error.isEmpty ? error.localizedDescription : taskQueue.error
            handlingQueueFailure = false; return
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
        queueAdvance = Task { [weak self] in
            guard let self else { return }
            defer { self.queueAdvance = nil }
            do {
                try await self.waitForQueueSettlement(token)
                guard self.queueActiveID == id, self.engine.currentRecord?.id == id else { throw CancellationError() }
                self.queueActiveID = nil; self.engine.discardCurrent()
                try self.launchNextQueued(token)
            } catch is CancellationError { }
            catch { self.haltQueue(error.localizedDescription); self.notice = error.localizedDescription }
        }
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
        guard !queueRunning, !queueSwitching else { return }
        do { try taskQueue.move(id, by: offset) } catch { notice = error.localizedDescription }
    }
    func removeQueuedTask(_ id: UUID) {
        guard !queueRunning, !queueSwitching, !engine.releasing else { return }
        guard id != engine.currentRecord?.id || !engine.hasCurrentTask else { notice = "请先结束当前任务，再移除它的队列记录"; return }
        do { try taskQueue.remove(id) } catch { notice = error.localizedDescription }
    }
    @discardableResult
    func requestQueuedVoiceTask(_ text: String, priority: Bool) -> String {
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return "请等待任务切换、校准或输入释放结束，再加入任务。" }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return "请输入 1–4000 字的任务。" }
        goal = text; enqueueDraft(priority: priority); voiceRequestID = UUID()
        return notice
    }
    func clearTaskQueue() {
        guard !queueRunning, !queueSwitching, !engine.running, !engine.releasing else { return }
        do { try taskQueue.clear(); queueActiveID = nil; notice = "队列已清除，已执行的实际操作不会撤销" }
        catch { notice = error.localizedDescription }
    }
}
