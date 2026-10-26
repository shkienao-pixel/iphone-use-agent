import Foundation
import Combine
import UIKit

/// Host-generated evidence from a local workflow. Only a real observation made
/// after its final input can replace another settling wait in the outer loop.
struct PhoneHarnessReceipt {
    let summary: String
    let verifiedFrame: ScreenFrame?
    let lastInputCompletedAt: Date?
    var requiresUserReview = false
}

@MainActor
protocol PhoneHarnessDriving: AnyObject {
    var metrics: RunMetricsRecorder? { get set }
    var hasPendingReview: Bool { get }
    var taskScopeID: UUID? { get set }
    func reset()
    func context(for frame: ScreenFrame) async throws -> String
    func didExecute(_ action: AgentAction, frame: ScreenFrame) async
    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt
}

extension PhoneHarnessDriving {
    func reset() {}
    var metrics: RunMetricsRecorder? { get { nil } set {} }
    var hasPendingReview: Bool { false }
    var taskScopeID: UUID? { get { nil } set {} }
}

struct PhoneHarnessFallback: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AgentPhase: String {
    case idle, preparing, observing, acting, awaitingApproval, paused, needsUser, completed, failed, stopped, preview
    var outcome: TaskOutcome {
        switch self {
        case .paused: return .paused
        case .needsUser: return .needsUser
        case .completed: return .completed
        case .failed: return .failed
        case .stopped, .idle: return .stopped
        case .preview: return .preview
        default: return .running
        }
    }
}

enum TaskRecoveryMode { case retry, continueTask }

@MainActor
final class AgentEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var phase: AgentPhase = .idle
    @Published private(set) var releasing = false
    @Published private(set) var currentRecord: PhoneTaskRecord?
    var onRecord: ((PhoneTaskRecord) -> Void)?
    var memoryContext: ((String, AgentSettings) async -> String)?
    var systemTool: ((UUID, SystemToolRequest) async throws -> String)?
    var systemToolEvidence: ((UUID) -> String)?
    /// Actual completed host receipts only; pending writes and model logs are excluded.
    var completedToolReceipts: ((UUID) -> [String])?
    /// The host checks all durable stores before another execution step.
    var executionPersistenceReady: (() -> Bool)?
    /// Durable commit happens before publishing a terminal success to UI/voice.
    var persistRecord: ((PhoneTaskRecord) -> Bool)?
    /// Volatile checkpoint notification; never a committed history projection.
    var onPersistenceFailure: ((PhoneTaskRecord) -> Void)?
    var phoneHarness: PhoneHarnessDriving?
    private(set) var runMetrics: RunMetricsRecorder?
    // Benchmark callers must explicitly attest starting conditions. Ordinary
    // interactive tasks retain unknown defaults and cannot yield speedup claims.
    var initialRunConditions = RunInitialConditions()
    #if os(iOS)
    var metricsDirectory: URL? = RunMetricsRecorder.defaultDirectory
    #else
    var metricsDirectory: URL? = nil // Offline suites never pollute an installed app's metrics.
    #endif
    private func makeRunMetrics(settings: AgentSettings, taskID: UUID) -> RunMetricsRecorder {
        let conditions = initialRunConditions
        initialRunConditions = RunInitialConditions()
        func version(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown" }
        #if targetEnvironment(simulator)
        let kind = RunExecutionKind.simulator
        #elseif os(iOS)
        let kind = RunExecutionKind.deviceGUI
        #else
        let kind = RunExecutionKind.offlineReplay
        #endif
        #if os(iOS)
        let deviceIdentity = UIDevice.current.model + "|" + (UIDevice.current.identifierForVendor?.uuidString ?? "unknown")
        #else
        let deviceIdentity = "offline-host"
        #endif
        return RunMetricsRecorder(taskID: taskID, versions: RunVersionIdentity(
            appVersion: version("CFBundleShortVersionString"), appBuild: version("CFBundleVersion"),
            sourceRevision: version("PhoneAgentSourceRevision"), harnessVersion: version("PhoneAgentHarnessVersion"),
            firmwareVersion: version("PhoneAgentFirmwareVersion"), model: settings.model,
            endpointHost: URLComponents(string: settings.endpoint)?.host ?? "unknown",
            device: deviceIdentity,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, executionKind: kind),
            conditions: conditions, directory: metricsDirectory)
    }
    private func finishRunMetrics(_ metrics: RunMetricsRecorder?) {
        switch phase {
        case .completed:
            metrics?.finish(.completed, evidence: "The model declared completion from observations/tool receipts; independent task correctness and side-effect counts remain unverified.")
        case .failed: metrics?.finish(.failed, evidence: "Execution failed. Task outcome and any partially applied side effects require review.")
        case .paused, .needsUser: metrics?.finish(.partial, evidence: "Execution requires user review; previously applied actions may be partial.")
        case .stopped: metrics?.finish(.cancelled, evidence: "Execution was stopped; inspect current state before resuming.")
        default: metrics?.finish(.unknown, evidence: "No verified terminal task result was established.")
        }
    }
    private var savedGoal = ""
    private var savedSettings: AgentSettings?
    private var releaseTask: Task<Void, Never>?
    private var previousIdentity: String?
    private var previousExecutionFrame: ScreenFrame?
    private var repeatedActions = 0
    private var attemptStartStep = 0
    private var attemptSteps: Int { max(0, currentStep - attemptStartStep) }
    private func resetActionRepetition() {
        previousIdentity = nil; previousExecutionFrame = nil; repeatedActions = 0
    }
    var canResume: Bool { savedSettings != nil && [.paused, .needsUser, .failed].contains(phase) && !releasing }
    var executionSettled: Bool { !running && !releasing && loop == nil }
    var currentSettings: AgentSettings? { savedSettings }
    var hasCurrentTask: Bool { savedSettings != nil && currentRecord != nil }
    private var recordPublication = UUID()
    private var persistenceBlocked = false
    @discardableResult private func transition(_ phase: AgentPhase, _ message: String) -> Bool {
        commitRecord(phase: phase, message: message, publishPhase: true)
    }
    private func publishRecord() { _ = commitRecord(phase: phase, message: state, publishPhase: false) }
    @discardableResult private func commitRecord(phase nextPhase: AgentPhase, message: String, publishPhase: Bool) -> Bool {
        let publication = UUID(), originSession = session
        recordPublication = publication
        guard var record = currentRecord else {
            if publishPhase { phase = nextPhase; state = message }; return true
        }
        record.updatedAt = Date(); record.outcome = nextPhase.outcome; record.summary = message; record.logs = logs
        record.checkpointStep = currentStep; record.attemptStartStep = attemptStartStep
        if persistenceBlocked {
            // End-of-loop bookkeeping must not automatically retry a failed
            // commit. Explicit launch/recovery reopens the durable boundary.
            if nextPhase == .stopped { phase = .stopped; state = message; currentRecord = record }
            return false
        }
        let committed = persistRecord?(record) ?? true
        // A synchronous store subscriber may Stop/Pause while committing.
        // Never let the old terminal candidate overwrite that newer session.
        guard publication == recordPublication, originSession == session else { return false }
        guard committed else {
            persistenceBlocked = true
            let explanation = PersistencePaused().localizedDescription
            record.outcome = .paused; record.summary = explanation
            running = false; taskIndicator = .idle; error = explanation
            phase = .paused; state = explanation; currentRecord = record
            onPersistenceFailure?(record)
            return false
        }
        if publishPhase { phase = nextPhase; state = message }
        currentRecord = record; onRecord?(record)
        return publication == recordPublication && originSession == session && phase == nextPhase
    }
    func renameCurrent(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        currentRecord?.title = String(title.prefix(80)); publishRecord()
    }
    func appendConversationReference(_ reference: String) -> Bool {
        guard !reference.isEmpty else { return true }
        guard var record = currentRecord else { return false }
        let existing = record.conversationReference ?? ""
        if existing.contains(reference) { return true }
        let combined = [existing, reference].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard combined.utf8.count <= 64_000 else { error = "任务引用资料过长，请重新说明补充要求"; return false }
        record.conversationReference = combined; currentRecord = record; publishRecord()
        return true
    }
    func discardCurrent() {
        guard !running, !releasing else { return }
        currentRecord = nil; savedSettings = nil; logs = []; phase = .idle; state = "准备开始"; error = ""
        currentStep = 0; attemptStartStep = 0
    }
    @Published private(set) var taskIndicator: MouseProtocol.TaskIndicator = .idle
    @Published private(set) var state = "准备开始"
    @Published private(set) var logs: [AgentLogEntry] = []
    @Published private(set) var pendingAction: AgentAction?
    @Published private(set) var executingAction: AgentAction?
    @Published private(set) var error = ""
    @Published private(set) var currentStep = 0
    private var loop: Task<Void, Never>?
    private var session = UUID()
    var activityControlSessionID: UUID { session }
    private var approved = false
    let capture: CaptureService
    let executor: MouseExecutor

    private let ownsScreenInput: Bool
    init(capture: CaptureService, executor: MouseExecutor, ownsScreenInput: Bool = true) {
        self.capture = capture; self.executor = executor; self.ownsScreenInput = ownsScreenInput
    }
    // Keep a bounded historical checkpoint before diagnostic/raw rows roll out.
    // The current goal and confirmed subtask ledger are always supplied separately.
    private func compactTaskContext() {
        guard var record = currentRecord else { return }
        var memory = record.contextMemory ?? TaskContextMemory()
        memory.compact(history: logs)
        record.contextMemory = memory.isEmpty ? nil : memory
        currentRecord = record
    }
    private var taskContext: String {
        let archived = currentRecord?.contextMemory?.prompt ?? ""
        let evidence = currentRecord.map { systemToolEvidence?($0.id) ?? "" } ?? ""
        return [currentRecord?.conversationReference ?? "", archived, evidence].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    func log(_ title: String, _ detail: String, step: Int? = nil) {
        logs.append(AgentLogEntry(step: step ?? currentStep, title: title, detail: detail))
        compactTaskContext()
        if logs.count > 150 {
            var memory = currentRecord?.contextMemory ?? TaskContextMemory()
            memory.absorb(Array(logs.prefix(logs.count - 150)))
            currentRecord?.contextMemory = memory.isEmpty ? nil : memory
            logs.removeFirst(logs.count - 150)
        }
        publishRecord()
    }
    func clearLogs() {
        if !running {
            // Clearing the visible timeline must not erase long-task progress.
            var memory = currentRecord?.contextMemory ?? TaskContextMemory()
            memory.absorb(logs)
            currentRecord?.contextMemory = memory.isEmpty ? nil : memory
            logs = []; publishRecord()
        }
    }
    func approve() { approved = true }
    private func cancelAndRelease() {
        if ownsScreenInput { phoneHarness?.reset() }
        let cancelledMetrics = runMetrics
        session = UUID(); let previous = loop; previous?.cancel(); loop = nil
        resetActionRepetition()
        running = false; pendingAction = nil; executingAction = nil
        guard releaseTask == nil else { return }
        releasing = true
        releaseTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if self.ownsScreenInput { await self.executor.ble.release(); self.executor.invalidatePosition() }
            cancelledMetrics?.finish(.cancelled, evidence: "Execution cancelled and input released. Partial side effects are not automatically retried.")
            self.releasing = false; self.releaseTask = nil
        }
    }
    func pause() {
        guard running else { return }
        cancelAndRelease(); taskIndicator = .idle
        transition(.paused, ownsScreenInput ? "已暂停。继续时先核对最新画面。" : "后台任务已暂停，保留进度与已确认工具回执。")
        log("暂停", ownsScreenInput ? "已取消旧计划并释放输入；上一步可能已部分执行，恢复后先核对结果。" : "已取消本任务的规划与工具等待；上一步可能已部分执行，继续前先核对工具回执。")
    }
    func handoff(reason: String? = nil) {
        guard hasCurrentTask else { return }
        cancelAndRelease(); taskIndicator = .idle; error = ""
        transition(.needsUser, reason ?? "已交给你操作。处理好后，可以说“继续”。")
        log("你已接管", ownsScreenInput ? "保留任务和进度，取消旧计划并释放输入。继续时重新检查当前画面。" : "保留后台任务和工具回执，等待你处理权限、确认或服务问题后明确继续。")
    }
    func amendTask(_ text: String, attachments: [ComposerAttachment] = []) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasCurrentTask, var record = currentRecord else { throw AgentError.message("没有可补充的当前任务，请先开始任务") }
        guard !text.isEmpty, text.count <= 4000 else { throw AgentError.message("补充要求需为 1–4000 字") }
        guard (record.amendments ?? []).count < 20 else { throw AgentError.message("当前任务已收到 20 次补充，请整理需求后创建新任务") }
        let combinedAttachments = (record.attachments ?? []) + attachments
        try ComposerAttachmentPolicy.validate(combinedAttachments)
        record.attachments = combinedAttachments.isEmpty ? nil : combinedAttachments
        record.amendments = (record.amendments ?? []) + [TaskAmendment(text: text)]
        guard record.effectiveGoal.count <= 12000 else { throw AgentError.message("当前任务与补充内容过长，请整理需求后创建新任务") }
        cancelAndRelease(); taskIndicator = .idle; error = ""
        currentRecord = record; savedGoal = record.effectiveGoal
        resetActionRepetition()
        transition(.paused, "已加入补充要求。说“继续”后按新要求执行。")
        log("补充要求", text)
    }
    func stop(reason: String = "已停止") {
        let preserveCompletion = phase == .completed && !running
        let active = running || canResume
        cancelAndRelease()
        if preserveCompletion { return }
        if reason == "已停止" { error = ""; taskIndicator = .idle; transition(.stopped, reason); savedSettings = nil }
        else if active {
            error = reason; taskIndicator = .failed; transition(.failed, reason)
        }
    }
    private func checkReady(_ settings: AgentSettings) throws {
        guard executionPersistenceReady?() != false else { throw PersistencePaused() }
        guard ownsScreenInput || settings.toolsOnly == true else { throw AgentError.message("后台任务只允许原生工具，不能操作手机屏幕") }
        guard settings.validStepConfiguration else { throw AgentError.message("行动步数配置无效，请在设置中重新选择") }
        guard phoneHarness?.hasPendingReview != true else {
            throw AgentError.message("存在待核验的手机操作，请先在设备页核对结果并处理回执，再启动或恢复任务")
        }
        guard PrivacyConsent.allowed(settings) else { throw AgentError.message("请先确认向当前 AI 服务发送画面与任务数据") }
        _ = try ModelEndpointPolicy.url(settings.endpoint)
        if settings.toolsOnly == true {
            guard settings.systemToolsEnabled == true, systemTool != nil else { throw AgentError.message("请先启用系统工具") }
        } else {
        guard capture.running, capture.frame?.fullDisplay == true else { throw AgentError.message("请先通过系统选择器开启整屏共享") }
        if !settings.previewOnly {
            _ = try executor.validateCalibration(frame: capture.frame)
            guard executor.ble.ready else { throw AgentError.message("请先连接蓝牙鼠标") }
        }
        }
        guard !SettingsStore.apiKey(for: settings.endpoint).isEmpty else { throw AgentError.message("请在设置中保存 API Key") }
    }
    func start(task: String, settings: AgentSettings, subtasks: [String] = [], attachments: [ComposerAttachment] = [], taskID: UUID = UUID(), conversationReference: String = "") {
        guard !running, !releasing else { return }
        let goal = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let attempt = makeRunMetrics(settings: settings, taskID: taskID)
        let preflight = attempt.begin(.preparation, label: "validate task, consent, capture, calibration and model configuration")
        do {
            guard !goal.isEmpty, goal.count <= 12000 else { throw AgentError.message("请输入 1–12000 字的任务") }
            guard subtasks.count <= 12, subtasks.allSatisfy({ !$0.isEmpty && $0.count <= 240 }) else { throw AgentError.message("子任务清单格式无效") }
            try ComposerAttachmentPolicy.validate(attachments)
            guard conversationReference.utf8.count <= 64_000 else { throw AgentError.message("任务引用资料过长，请重新说明任务") }
            try checkReady(settings)
        } catch {
            attempt.end(preflight, outcome: .failed); attempt.finish(.failed, evidence: "Preflight rejected execution; no task action was dispatched.")
            self.error = error.localizedDescription; return
        }
        attempt.end(preflight)
        if currentRecord != nil, savedSettings != nil {
            transition(.stopped, "已切换到新任务")
        }
        savedGoal = goal; savedSettings = settings
        error = ""; pendingAction = nil; executingAction = nil; logs = []; currentStep = 0; attemptStartStep = 0
        resetActionRepetition()
        currentRecord = PhoneTaskRecord(id: attempt.snapshot.taskID, title: String(goal.prefix(36)), goal: goal, subtasks: subtasks.isEmpty ? nil : subtasks.map { TaskSubtask(goal: $0) }, attachments: attachments.isEmpty ? nil : attachments,
            conversationReference: conversationReference.isEmpty ? nil : conversationReference)
        currentRecord?.completionEvidence = TaskCompletionEvidence(goal: goal)
        launch(goal: goal, settings: settings, resumed: false, metrics: attempt)
    }
    // Queue restores preserve the same task ID, amendments, receipts and completed
    // subtasks. Pending actions are deliberately not part of the checkpoint.
    func restoreQueued(record: PhoneTaskRecord, settings: AgentSettings, step: Int, previouslyStarted: Bool) throws {
        try ComposerAttachmentPolicy.validate(record.attachments ?? [])
        guard executionSettled else { throw AgentError.message("正在结束上一次执行，请稍后再试") }
        guard record.validConversationReference, !record.effectiveGoal.isEmpty, record.effectiveGoal.count <= 12000,
              step >= 0, step < Int.max, (record.attemptStartStep ?? 0) >= 0, (record.attemptStartStep ?? 0) <= step,
              settings.allowsNextStep(after: step - (record.attemptStartStep ?? 0)),
              ![TaskOutcome.completed, .stopped, .preview].contains(record.outcome) else {
            throw AgentError.message("此队列任务不能继续，请核对结果或创建新任务")
        }
        let attempt = makeRunMetrics(settings: settings, taskID: record.id)
        do { try attempt.measure(.preparation, label: "queued task readiness") { try checkReady(settings) } }
        catch { attempt.finish(.failed, evidence: "Queued attempt failed readiness; no task action was dispatched."); throw error }
        savedGoal = record.effectiveGoal; savedSettings = settings
        currentRecord = record; logs = record.logs; currentStep = step; attemptStartStep = record.attemptStartStep ?? 0
        resetActionRepetition(); approved = false
        if previouslyStarted { log("从队列继续", "保留任务 ID 和已确认子任务；上一步可能已部分执行，先核对当前状态，不重放旧动作。") }
        launch(goal: savedGoal, settings: settings, resumed: previouslyStarted, metrics: attempt)
        guard running else { throw AgentError.message("队列记录未能保存，执行没有启动") }
    }
    /// Explicit recovery of one selected task. A stopped task never regains
    /// authority merely because it was loaded from disk or remains on screen.
    func recover(record: PhoneTaskRecord, settings: AgentSettings, mode: TaskRecoveryMode) throws {
        guard executionSettled else { throw AgentError.message("正在结束上一次执行，请稍后再试") }
        guard !hasCurrentTask || currentRecord?.id == record.id else {
            throw AgentError.message("另一个任务仍保留执行会话，请先完成或结束它，再恢复所选任务")
        }
        guard record.validConversationReference, [.failed, .stopped, .interrupted, .paused, .needsUser].contains(record.outcome),
              !record.effectiveGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.effectiveGoal.count <= 12000, (record.amendments ?? []).count <= 20,
              (record.subtasks ?? []).count <= 12,
              Set((record.subtasks ?? []).map(\.id)).count == (record.subtasks ?? []).count,
              (record.subtasks ?? []).allSatisfy({ !$0.goal.isEmpty && $0.goal.count <= 240 }) else {
            throw AgentError.message("这项任务无法恢复，请核对记录后创建新任务")
        }
        let step = record.checkpointStep ?? max(0, record.logs.map(\.step).max() ?? 0)
        let base = mode == .retry ? step : record.attemptStartStep ?? 0
        guard step >= 0, step < Int.max, base >= 0, base <= step else { throw AgentError.message("任务步骤记录无效，未恢复执行") }
        guard settings.allowsNextStep(after: step - base) else {
            throw AgentError.message("原尝试已达到行动上限；提高上限后继续，或点重试重新规划一次")
        }
        try ComposerAttachmentPolicy.validate(record.attachments ?? [])
        let attempt = makeRunMetrics(settings: settings, taskID: record.id)
        do { try attempt.measure(.preparation, label: "explicit selected-task recovery readiness") { try checkReady(settings) } }
        catch { attempt.finish(.failed, evidence: "Selected-task recovery failed readiness; no action was dispatched."); throw error }
        savedGoal = record.effectiveGoal; savedSettings = settings
        currentRecord = record; logs = record.logs; currentStep = step; attemptStartStep = base
        resetActionRepetition(); approved = false; pendingAction = nil; executingAction = nil
        phase = .paused
        log(mode == .retry ? "重试任务" : "继续历史任务", mode == .retry
            ? "开始新的尝试并从头重新规划，本次行动预算重新计数。保留原任务 ID、已确认子任务和工具回执；不得重复已确认的发送、创建或下单。未知结果先核验，不重放旧动作。"
            : "保留原任务 ID、累计步骤、原尝试预算、已确认子任务与工具回执。先核对最新页面和已发生的操作，未知结果先处理，不重放旧动作。")
        launch(goal: savedGoal, settings: settings, resumed: true, metrics: attempt)
        guard running else { throw AgentError.message("任务记录未能保存，恢复没有启动") }
    }
    func configurePausedTask(settings: AgentSettings) {
        guard canResume else { return }
        savedSettings = settings
    }
    func resume(settings: AgentSettings? = nil, delay: Double? = nil) {
        guard canResume, let previousSettings = savedSettings else { return }
        let savedSettings = settings ?? previousSettings
        let attempt = makeRunMetrics(settings: savedSettings, taskID: currentRecord?.id ?? UUID())
        let preflight = attempt.begin(.preparation, label: "resume readiness and remaining action budget")
        do {
            try checkReady(savedSettings)
            guard currentStep < Int.max, savedSettings.allowsNextStep(after: attemptSteps) else { throw AgentError.message("已达到设置的行动上限，请开启长任务模式或提高上限后继续") }
        } catch {
            attempt.end(preflight, outcome: .failed); attempt.finish(.failed, evidence: "Resume failed readiness; inspect current state before another attempt.")
            self.error = error.localizedDescription; return
        }
        attempt.end(preflight)
        self.savedSettings = savedSettings
        log("恢复任务", "上一次操作可能已部分执行；先检查当前页面、字段与发送结果，不重放旧动作。")
        launch(goal: savedGoal, settings: savedSettings, resumed: true, resumeDelay: delay, metrics: attempt)
    }
    private func launch(goal: String, settings: AgentSettings, resumed: Bool, resumeDelay: Double? = nil, metrics: RunMetricsRecorder? = nil) {
        persistenceBlocked = false
        // Import old task-bound host receipts before the first new operation.
        // Later request/result validation cannot erase this recovered proof.
        currentRecord?.completionEvidence = completionEvidence()
        runMetrics = metrics ?? makeRunMetrics(settings: settings, taskID: currentRecord?.id ?? UUID())
        phoneHarness?.metrics = runMetrics
        phoneHarness?.taskScopeID = currentRecord?.id
        if ownsScreenInput { phoneHarness?.reset() }
        resetActionRepetition()
        if ownsScreenInput { executor.invalidatePosition() }; error = ""; pendingAction = nil; executingAction = nil
        let token = UUID(); session = token
        running = true; taskIndicator = .running; transition(.preparing, resumed ? "正在恢复任务" : "正在准备任务")
        guard running else { return } // Record persistence may synchronously pause a queue.
        var runSettings = settings
        if resumed { runSettings.startDelay = min(30, max(2, resumeDelay ?? min(3, settings.startDelay))) }
        let client = VisionClient(settings: settings, apiKey: SettingsStore.apiKey(for: settings.endpoint), metrics: runMetrics)
        loop = Task { [weak self] in
            if runSettings.toolsOnly == true { await self?.runTools(goal: goal, settings: runSettings, client: client, token: token) }
            else { await self?.run(goal: goal, settings: runSettings, client: client, token: token) }
        }
    }
    private func measuredWait(nanoseconds: UInt64) async throws {
        if let metrics = runMetrics {
            try await metrics.measureAsync(.wait, label: "poll, settle or await human confirmation") {
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        } else { try await Task.sleep(nanoseconds: nanoseconds) }
    }
    private func awaitApproval(token: UUID) async throws {
        let timer = runMetrics?.begin(.wait, label: "await human confirmation")
        var completed = false
        defer {
            if let timer { runMetrics?.end(timer, outcome: Task.isCancelled ? .cancelled : (completed ? .completed : .failed)) }
        }
        // One span for the complete human wait, rather than seven spans per second.
        while !approved {
            try await Task.sleep(nanoseconds: 150_000_000)
            try stillCurrent(token)
        }
        completed = true
    }
    private func awaitFrameEvent(after: Date, timeout: Double) async throws {
        if let metrics = runMetrics {
            _ = try await metrics.measureAsync(.wait, label: "await system frame event, bounded by configured interval") {
                try await capture.waitForFrame(after: after, timeout: timeout)
            }
        } else { _ = try await capture.waitForFrame(after: after, timeout: timeout) }
    }
    private func stillCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == session && running else { throw CancellationError() }
        guard executionPersistenceReady?() != false else { throw PersistencePaused() }
    }
    private struct PersistencePaused: LocalizedError {
        var errorDescription: String? { "任务记录暂时无法安全保存，已暂停后续执行；已发生的操作与回执保留，请处理存储问题后继续。" }
    }
    private func completionEvidence(includeReceipts: Bool = true) -> TaskCompletionEvidence {
        guard let record = currentRecord else { return TaskCompletionEvidence(goal: savedGoal) }
        return TaskCompletionEvidence.restore(goal: record.effectiveGoal, persisted: record.completionEvidence,
            legacyResults: record.nativeResults ?? [], receipts: includeReceipts ? completedToolReceipts?(record.id) ?? [] : [])
    }
    private func recordObservation(_ frame: ScreenFrame) {
        var evidence = completionEvidence(); evidence.observe(confirmedAt: frame.confirmedAt)
        currentRecord?.completionEvidence = evidence
    }
    private func recordInput(completedAt: Date) {
        var evidence = completionEvidence(); evidence.input(completedAt: completedAt)
        currentRecord?.completionEvidence = evidence
    }
    private func finish(_ action: AgentAction, settings: AgentSettings) throws {
        if settings.previewOnly {
            pendingAction = action; running = false; taskIndicator = .idle
            transition(.preview, "仅生成结束建议，未执行或核验任务。"); savedSettings = nil; return
        }
        try finishAllowed()
        let evidence = completionEvidence(); currentRecord?.completionEvidence = evidence
        switch TaskCompletionPolicy.decide(goal: currentRecord?.effectiveGoal ?? savedGoal,
            toolsOnly: settings.toolsOnly == true, evidence: evidence) {
        case .needsUser(let explanation):
            running = false; taskIndicator = .idle; pendingAction = nil
            log("模型结束声明（尚未核验）", action.completionSummary)
            transition(.needsUser, explanation)
        case .tools:
            running = false
            if transition(.completed, "已取得匹配的实际工具回执。\n" + action.completionSummary), phase == .completed {
                taskIndicator = .completed; savedSettings = nil
            }
        case .observed:
            running = false
            let scope = evidence.inputs == 0 ? "已观察当前画面；以下为基于画面的模型结果：" : "已执行并观察后续画面；以下业务结果为模型判断，尚未独立核验："
            if transition(.completed, scope + "\n" + action.completionSummary), phase == .completed {
                taskIndicator = .completed; savedSettings = nil
            }
        }
    }
    private func recentFrame(after: Date) -> ScreenFrame? {
        guard let frame = capture.frame, frame.fullDisplay, frame.confirmedAt > after else { return nil }
        let age = Date().timeIntervalSince(frame.confirmedAt)
        return (0..<1.5).contains(age) ? frame : nil
    }
    private func reusableInputBoundary(_ receipt: PhoneHarnessReceipt, from source: ScreenFrame) -> Date? {
        guard capture.running, let after = receipt.lastInputCompletedAt,
              after.timeIntervalSinceReferenceDate.isFinite, after <= Date(),
              let verified = receipt.verifiedFrame, verified.fullDisplay,
              verified.captureID != nil, verified.captureID == source.captureID,
              verified.sourceWidth == source.sourceWidth, verified.sourceHeight == source.sourceHeight,
              verified.width == source.width, verified.height == source.height,
              verified.confirmedAt > after,
              (0..<1.5).contains(Date().timeIntervalSince(verified.confirmedAt)),
              let current = recentFrame(after: after),
              current.captureID == verified.captureID,
              current.sourceWidth == verified.sourceWidth, current.sourceHeight == verified.sourceHeight,
              current.width == verified.width, current.height == verified.height,
              current.confirmedAt >= verified.confirmedAt else { return nil }
        return after
    }
    private func freshFrame(after: Date, token: UUID, allowPointerWake: Bool) async throws -> ScreenFrame {
        let timer = runMetrics?.begin(.capture, label: "wait for a fresh system-confirmed screen frame")
        var timerResult = RunStageOutcome.failed
        defer { if let timer { runMetrics?.end(timer, outcome: Task.isCancelled ? .cancelled : timerResult) } }
        let began = Date()
        let deadline = began.addingTimeInterval(6)
        var recoveryAttempted = false
        while Date() < deadline {
            try stillCurrent(token)
            guard capture.running else { throw AgentError.message("屏幕共享已停止") }
            if capture.frame?.fullDisplay == false { throw AgentError.message("屏幕共享已切换为单个应用，请重新共享整屏") }
            if let frame = recentFrame(after: after) {
                runMetrics?.recordCapture(RunCaptureIdentity(captureID: frame.captureID, width: frame.width, height: frame.height,
                    sourceWidth: frame.sourceWidth, sourceHeight: frame.sourceHeight))
                timerResult = .completed; return frame
            }
            if !recoveryAttempted, Date().timeIntervalSince(began) >= 0.3 {
                if allowPointerWake {
                    if let frame = capture.frame, frame.fullDisplay, executor.ble.ready {
                        _ = try executor.validateCalibration(frame: frame)
                        recoveryAttempted = true
                        log("唤醒最新画面", "仅轻移指针，不发送点击或按键；仍等待系统确认的新画面")
                        try stillCurrent(token)
                        // Move in both directions so a pointer at an edge can
                        // still change the display. moveUnits invalidates the
                        // position cache; the next target will home again.
                        try await executor.moveUnits(x: 3, y: 0, buttons: 0)
                        try stillCurrent(token)
                        guard Date() < deadline else { break }
                        if capture.running, let current = capture.frame, current.fullDisplay,
                           current.captureID == frame.captureID {
                            _ = try executor.validateCalibration(frame: current)
                            try await executor.moveUnits(x: -3, y: 0, buttons: 0)
                            try stillCurrent(token)
                            guard Date() < deadline else { break }
                        }
                    }
                } else {
                    recoveryAttempted = true
                    // Preview may refresh capture, but must never send input.
                    _ = capture.requestFreshFrame()
                }
            }
            try await awaitFrameEvent(after: after, timeout: 0.15)
        }
        try stillCurrent(token)
        throw AgentError.message("等待 6 秒仍未收到可用的整屏画面，请检查屏幕共享后继续")
    }
    private func validatedFrame(for observation: ScreenFrame, token: UUID, allowPointerWake: Bool, action: AgentAction? = nil,
                                after: Date? = nil, waitingMessage: String) async throws -> ScreenFrame? {
        let timer = runMetrics?.begin(.verification, label: "validate observation sharing identity, dimensions and scene")
        var verificationPassed = false
        defer { if let timer { runMetrics?.end(timer, outcome: Task.isCancelled ? .cancelled : (verificationPassed ? .completed : .failed)) } }
        try stillCurrent(token)
        let after = after ?? observation.confirmedAt
        let waiting = recentFrame(after: after) == nil
        if waiting {
            transition(.observing, waitingMessage)
            let detail = capture.frame.map { "距系统确认画面 \(String(format: "%.1f", Date().timeIntervalSince($0.confirmedAt))) 秒" }
                ?? "当前没有可用画面"
            log("等待最新画面", detail + "；最多等待 6 秒，不发送点击或按键" + (allowPointerWake ? "，必要时仅轻移指针" : ""))
        }
        let latest = try await freshFrame(after: after, token: token, allowPointerWake: allowPointerWake)
        try stillCurrent(token)
        guard observation.captureID == latest.captureID,
              observation.sourceWidth == latest.sourceWidth, observation.sourceHeight == latest.sourceHeight,
              observation.width == latest.width, observation.height == latest.height else {
            log("共享或画面尺寸已改变", "丢弃旧动作，使用当前整屏重新观察")
            return nil
        }
        guard imageDifference(observation.image, latest.image) <= 0.18 else {
            log("画面已改变", "丢弃旧动作，重新观察")
            return nil
        }
        if localImageChanged(observation.image, latest.image, action: action) {
            log("局部画面已改变", "目标区域或局部弹窗发生变化，丢弃旧动作并重新观察")
            return nil
        }
        if waiting { log("画面已恢复", "已核对最新画面与模型所见画面，继续当前步骤") }
        verificationPassed = true
        return latest
    }
    private func planningGoal(_ goal: String) -> String {
        guard let subtasks = currentRecord?.subtasks, !subtasks.isEmpty else { return goal }
        let list = subtasks.map { "ID=\($0.id.uuidString) · \($0.completed ? "已确认完成" : "待完成") · \($0.goal)" + ($0.completed ? " · 完成依据：" + ($0.evidence ?? "未记录细节") : "") }.joined(separator: "\n")
        return goal + "\n\n子任务账本：\n" + list + "\n按顺序完成尚未完成项目；已有完成记录不得重做。核对一项成功后，返回 complete_subtask，text 为该项 ID，reason 描述可验证的结果；按本次确认模式记录完成依据。全部项目完成后才可 finish。"
    }
    private func finishAllowed() throws {
        guard currentRecord?.subtasks?.contains(where: { !$0.completed }) != true else { throw AgentError.message("仍有未确认完成的子任务，请核对结果后继续") }
    }
    private func completeSubtask(_ action: AgentAction, token: UUID, requiresConfirmation: Bool) async throws {
        guard let id = UUID(uuidString: action.text ?? ""), var record = currentRecord,
              let index = record.subtasks?.firstIndex(where: { !$0.completed }), record.subtasks?[index].id == id else { throw AgentError.message("子任务 ID 或顺序无效，没有更改账本") }
        if requiresConfirmation {
        pendingAction = action; approved = false; transition(.awaitingApproval, "请确认子任务已完成：" + (record.subtasks?[index].goal ?? ""))
        try await awaitApproval(token: token)
        try stillCurrent(token); pendingAction = nil
        } else {
            var available = completionEvidence()
            available.tools.removeAll { available.subtaskReceiptIDs.contains($0.receiptID) }
            if available.observations <= available.subtaskObservationBoundary { available.observations = 0; available.postInputObservations = 0 }
            let subtaskGoal = record.subtasks?[index].goal ?? ""
            available.goalSHA256 = TaskCompletionEvidence.digest(subtaskGoal)
            if case .needsUser(let explanation) = TaskCompletionPolicy.decide(goal: subtaskGoal,
                toolsOnly: savedSettings?.toolsOnly == true, evidence: available) {
                running = false; taskIndicator = .idle; pendingAction = nil
                transition(.needsUser, "子任务尚待核验：" + explanation); return
            }
        }
        try stillCurrent(token)
        guard let latest = currentRecord else { throw CancellationError() }; record = latest
        var evidence = completionEvidence()
        evidence.subtaskReceiptIDs = Array(Set(evidence.subtaskReceiptIDs + evidence.tools.map(\.receiptID)))
        evidence.subtaskObservationBoundary = evidence.observations
        record.completionEvidence = evidence
        record.subtasks?[index].completed = true
        record.subtasks?[index].evidence = requiresConfirmation ? "用户已确认完成；模型说明：" + action.reason
            : "宿主已有实际工具或画面依据；模型说明：" + action.reason
        currentRecord = record; log("子任务完成", action.reason)
    }
    private func observeAction(goal: String, settings: AgentSettings, client: VisionClient, token: UUID,
                               step: Int, after: Date, remainingRecoveries: inout Int,
                               responseLimit: inout Int) async throws -> (ScreenFrame, AgentAction) {
        var after = after
        var retried = false
        while true {
            try stillCurrent(token)
            transition(.observing, "正在观察并规划当前步骤")
            let captureStarted = Date()
            let frame = try await freshFrame(after: after, token: token, allowPointerWake: !settings.previewOnly)
            if !settings.previewOnly { recordObservation(frame) }
            log("取屏耗时", String(format: "%.2f 秒", Date().timeIntervalSince(captureStarted)))
            if !settings.previewOnly { _ = try executor.validateCalibration(frame: frame) }
            do {
                let recallQuestion = goal + "\n" + (currentRecord?.conversationReference ?? "")
                let context = settings.useMemories == true ? await memoryContext?(recallQuestion, settings) ?? "" : ""
                let localStarted = Date()
                var harnessContext = ""
                do {
                    if let metrics = runMetrics {
                        harnessContext = try await metrics.measureAsync(.harness, label: "build local page context") {
                            try await phoneHarness?.context(for: frame) ?? ""
                        }
                    } else { harnessContext = try await phoneHarness?.context(for: frame) ?? "" }
                } catch let issue as WorkflowLeaseFailure {
                    let pixels: Set<WorkflowLeaseFailure.Predicate> = [.currentPixelsMatch, .currentImageObjectMatches, .currentCGImageObjectMatches, .currentJPEGMatches]
                    guard !issue.predicates.isEmpty, issue.predicates.allSatisfy({ pixels.contains($0) }),
                          capture.running, let current = capture.frame,
                          current.fullDisplay, current.captureID != nil, current.captureID == frame.captureID,
                          current.width == frame.width, current.height == frame.height,
                          current.sourceWidth == frame.sourceWidth, current.sourceHeight == frame.sourceHeight,
                          current.capturedAt > frame.capturedAt, current.confirmedAt >= current.capturedAt,
                          Date().timeIntervalSince(current.confirmedAt) >= 0,
                          Date().timeIntervalSince(current.confirmedAt) < 1.5 else { throw issue }
                    // Discard every OCR ID. The model sees this actual frame, and
                    // the ordinary pre-action validation still checks newer pixels.
                    harnessContext = "Local OCR changed during recognition and was discarded. Use only the attached current screenshot and visual coordinates; no OCR element IDs are available."
                    log("改用当前截图", "识别期间局部动画更新，已丢弃文字元素；动作仍需通过最新画面核验")
                }
                try stillCurrent(token)
                if phoneHarness != nil { log("本地布局耗时", String(format: "%.2f 秒", Date().timeIntervalSince(localStarted))) }
                let modelStarted = Date()
                let action = try await client.nextAction(task: planningGoal(goal), jpeg: frame.jpeg, width: frame.width, height: frame.height,
                    history: logs, keyboardAvailable: executor.ble.keyboardReady,
                    mappedHomeAvailable: settings.homeButtonIsMapped(to: executor.ble.selectedID),
                    tokenLimit: responseLimit, formatRetry: retried, memoryContext: context, harnessContext: harnessContext, taskContext: taskContext, attachments: currentRecord?.attachments ?? [], skillReference: currentRecord?.conversationReference ?? "")
                try stillCurrent(token)
                log("模型耗时", String(format: "%.2f 秒", Date().timeIntervalSince(modelStarted)))
                return (frame, action)
            } catch let issue as ModelResponseIssue {
                try stillCurrent(token)
                log("模型回复诊断", issue.diagnostic)
                guard !retried && remainingRecoveries > 0 else { throw issue }
                remainingRecoveries -= 1; retried = true
                if issue.kind == .length { responseLimit = min(16384, responseLimit * 2) }
                log("重新观察", "错误回复未执行；读取新画面后重试一次，回复上限 \(responseLimit) Token")
                transition(.observing, "回复不完整或格式无效，正在重新观察")
                // No action has reached the executor. Do not continue a partial JSON,
                // reuse its screenshot or retry transport/HTTP/refusal failures.
                after = Date()
            }
        }
    }
    @discardableResult private func executeTool(_ action: AgentAction, settings: AgentSettings, token: UUID) async throws -> String {
        guard settings.systemToolsEnabled == true, let systemTool, let id = currentRecord?.id else { throw AgentError.message("系统工具未启用") }
        let request = try SystemToolRequest.decode(action.text)
        transition(settings.confirmEachStep ? .awaitingApproval : .acting,
                   (settings.confirmEachStep ? "请回到 Sela 确认：" : "正在执行：") + request.operation.label)
        let result: String
        if let metrics = runMetrics {
            result = try await metrics.measureAsync(.systemTool, label: "system tool including user approval") { try await systemTool(id, request) }
        } else { result = try await systemTool(id, request) }
        // A real completed return may race Stop; preserve its evidence for this
        // same task before checking the cancelled execution session.
        if currentRecord?.id == id {
            var evidence = completionEvidence(includeReceipts: false)
            // This invocation has an actual request/result pair. A contradictory
            // response must not be re-imported later as a title-only legacy card.
            evidence.allowsReceiptRecovery = false
            if let proof = TaskCompletionEvidence.successfulTool(operation: request.operation.rawValue,
                result: result, title: request.title, start: request.start, end: request.end, query: request.query,
                artifactReference: request.artifact_ref, content: request.content, eventID: id.uuidString + ":" + String(currentStep)) { evidence.add(proof) }
            currentRecord?.completionEvidence = evidence
        }
        try stillCurrent(token)
        if let card = NativeTaskResult.completed(operation: request.operation.rawValue, result: result,
                                                 title: request.title, start: request.start,
                                                 eventID: id.uuidString + ":" + String(currentStep)) {
            currentRecord?.nativeResults = NativeTaskResult.retained(currentRecord?.nativeResults ?? [], adding: card)
        }
        log("工具回执", result); transition(.observing, "工具已完成，正在核对后续任务")
        return result
    }
    private func pauseAtStepLimit(_ settings: AgentSettings) {
        running = false; taskIndicator = .idle
        transition(.paused, settings.runsContinuously
            ? "步骤计数已达到系统可表示的范围，请核对结果后开始新任务"
            : "已到达最大步数（\(settings.maxSteps) 步）。开启长任务模式或提高上限后可继续。")
    }
    private func runTools(goal: String, settings: AgentSettings, client: VisionClient, token: UUID) async {
        do {
            var recoveries = 3
            var limit = settings.responseTokenLimit
            var formatRetry = false
            var readProgress = NativeReadProgress()
            while currentStep < Int.max && settings.allowsNextStep(after: attemptSteps) {
                let step = currentStep + 1
                try stillCurrent(token); currentStep = step; transition(.observing, "第 \(step) 步：规划系统工具")
                let recallQuestion = goal + "\n" + (currentRecord?.conversationReference ?? "")
                let context = settings.useMemories == true ? await memoryContext?(recallQuestion, settings) ?? "" : ""
                try stillCurrent(token)
                let action: AgentAction
                do {
                    action = try await NativePlanningRecovery.nextAction(
                        stillCurrent: { try self.stillCurrent(token) },
                        request: { try await client.nextAction(task: self.planningGoal(goal), jpeg: Data(), width: 0, height: 0, history: self.logs, keyboardAvailable: false, mappedHomeAvailable: false, tokenLimit: limit, formatRetry: formatRetry, memoryContext: context, taskContext: self.taskContext, attachments: self.currentRecord?.attachments ?? [], skillReference: self.currentRecord?.conversationReference ?? "", nativeExecutionContext: readProgress.context(for: self.planningGoal(goal))) },
                        wait: { try await self.measuredWait(nanoseconds: $0) },
                        onRetry: { attempt, interval in
                            let text = "\(interval / 1_000_000_000) 秒后自动继续（\(attempt)/\(NativePlanningRecovery.delays.count)），已完成结果保留，可随时停止"
                            self.log("等待模型连接", text)
                            self.transition(.observing, text)
                        })
                }
                catch let issue as ModelResponseIssue {
                    try stillCurrent(token); guard recoveries > 0 else { throw issue }; recoveries -= 1
                    if issue.kind == .length { limit = min(16384, limit * 2) }
                    formatRetry = true
                    log("回复未执行", issue.diagnostic); continue
                }
                formatRetry = false
                try stillCurrent(token); log(action.label, action.reason); try stillCurrent(token)
                switch action.kind {
                case .finish: try finish(action, settings: settings)
                case .complete_subtask:
                    if settings.previewOnly { pendingAction = action; running = false; transition(.preview, action.reason); savedSettings = nil }
                    else { readProgress.reset(); try await completeSubtask(action, token: token, requiresConfirmation: settings.confirmEachStep) }
                case .ask_user: pendingAction = action; running = false; taskIndicator = .idle; transition(.needsUser, action.reason)
                case .system_tool:
                    if settings.previewOnly { pendingAction = action; running = false; transition(.preview, action.reason); savedSettings = nil }
                    else {
                        let request = try SystemToolRequest.decode(action.text)
                        switch readProgress.beforeDispatch(request, goal: planningGoal(goal)) {
                        case .correctWithReceipt:
                            log("重复只读规划已拦截", "本轮相同alarm_list已成功返回，没有再次派发SDK；已把真实回执和完成条件反馈给下一步。")
                            continue
                        case .pauseRepeatedPlan:
                            running = false; taskIndicator = .idle
                            log("重复只读规划已暂停", "已收到同条件真实回执并做过一次规划纠偏；没有再次调用SDK，也没有自动完成其它子任务。")
                            transition(.needsUser, "本次只读结果已返回，但规划仍要求重复读取，已暂停以避免循环。请核对已有回执或明确新的查询条件。")
                        case .execute:
                            executingAction = action
                            let result = try await executeTool(action, settings: settings, token: token)
                            readProgress.succeeded(request, result: result, goal: planningGoal(goal), step: step)
                            executingAction = nil
                        }
                    }
                case .wait:
                    readProgress.reset()
                    try await measuredWait(nanoseconds: UInt64(max(0.4, min(10, action.seconds ?? 1)) * 1_000_000_000))
                default: throw AgentError.message("当前为仅系统工具模式，不能执行鼠标动作。请在设置中切换模式")
                }
                if !running { break }
                try await measuredWait(nanoseconds: 400_000_000)
            }
            if running && token == session { pauseAtStepLimit(settings) }
        } catch is CancellationError {}
        catch let issue as PersistencePaused { if token == session { executingAction = nil; running = false; taskIndicator = .idle; transition(.paused, issue.localizedDescription) } }
        catch let decision as ToolDecisionError { if token == session { executingAction = nil; running = false; error = ""; taskIndicator = .idle; transition(.paused, decision.localizedDescription) } }
        catch { if token == session { self.error = error.localizedDescription; executingAction = nil; running = false; taskIndicator = .failed; transition(.failed, error.localizedDescription); log("工具任务中断", error.localizedDescription) } }
        if token == session { finishRunMetrics(runMetrics); loop = nil; if !persistenceBlocked { publishRecord() } }
    }
    private func run(goal: String, settings: AgentSettings, client: VisionClient, token: UUID) async {
        do {
            let preparationTimer = runMetrics?.begin(.preparation, label: "foreground startup countdown")
            defer { if let preparationTimer { runMetrics?.end(preparationTimer, outcome: Task.isCancelled ? .cancelled : .completed) } }
            for n in stride(from: Int(settings.startDelay.rounded()), through: 1, by: -1) {
                transition(.preparing, "\(n) 秒后开始，请切换到目标 App")
                try await measuredWait(nanoseconds: 1_000_000_000); try stillCurrent(token)
            }
            if let preparationTimer { runMetrics?.end(preparationTimer) }
            var after = Date()
            var remainingRecoveries = 3
            var consecutiveFrameRejections = 0
            var responseLimit = settings.responseTokenLimit
            while currentStep < Int.max && settings.allowsNextStep(after: attemptSteps) {
                let step = currentStep + 1
                if phoneHarness?.hasPendingReview == true {
                    running = false; taskIndicator = .idle
                    transition(.needsUser, "存在待核验操作，已暂停自动执行。请到设备页先核对实际结果。")
                    break
                }
                try stillCurrent(token); currentStep = step; transition(.observing, "读取最新画面")
                let (frame, action) = try await observeAction(goal: goal, settings: settings, client: client, token: token,
                    step: step, after: after, remainingRecoveries: &remainingRecoveries, responseLimit: &responseLimit)
                try stillCurrent(token)
                guard var executionFrame = try await validatedFrame(for: frame, token: token, allowPointerWake: !settings.previewOnly, action: action,
                    waitingMessage: "模型已返回，等待最新屏幕画面") else {
                    consecutiveFrameRejections += 1
                    guard consecutiveFrameRejections <= 3 else { throw AgentError.message("连续四次画面变化，未执行旧动作。请切到目标 App 后继续任务") }
                    after = Date(); continue
                }
                consecutiveFrameRejections = 0
                let identity = "\(action.kind.rawValue)|\(action.x ?? -1)|\(action.y ?? -1)|\(action.x2 ?? -1)|\(action.y2 ?? -1)|\(action.text ?? "")|\(action.amount ?? 0)"
                log(action.label, action.reason); try stillCurrent(token)
                if action.kind == .finish { try finish(action, settings: settings); break }
                if action.kind == .ask_user {
                    pendingAction = action; running = false; taskIndicator = .idle; transition(.needsUser, action.reason); break
                }
                if settings.previewOnly {
                    pendingAction = action; running = false; taskIndicator = .idle; transition(.preview, "已生成计划：\(action.reason)"); savedSettings = nil; break
                }
                if action.kind == .complete_subtask { try await completeSubtask(action, token: token, requiresConfirmation: settings.confirmEachStep); after = Date(); continue }
                if action.kind == .press_key, action.text?.lowercased() == "home",
                   !settings.homeButtonIsMapped(to: executor.ble.selectedID) {
                    log("改用辅助触控菜单", "中键主屏幕映射尚未确认；请点击当前可见辅助触控按钮，观察菜单，再点击主屏幕。")
                    transition(.observing, "重新观察返回桌面的入口"); after = Date(); continue
                }
                if settings.confirmEachStep && action.kind != .system_tool {
                    pendingAction = action; approved = false; transition(.awaitingApproval, "等待确认：\(action.label)")
                    try await awaitApproval(token: token)
                    pendingAction = nil
                    guard let latest = try await validatedFrame(for: frame, token: token, allowPointerWake: !settings.previewOnly, action: action, after: Date(),
                        waitingMessage: "已确认，正在核对最新屏幕画面") else {
                        after = Date(); continue
                    }
                    executionFrame = latest
                }
                try stillCurrent(token)
                let unchangedScene = previousExecutionFrame.map { previous in
                    previous.captureID == executionFrame.captureID &&
                    previous.sourceWidth == executionFrame.sourceWidth && previous.sourceHeight == executionFrame.sourceHeight &&
                    previous.width == executionFrame.width && previous.height == executionFrame.height &&
                    imageDifference(previous.image, executionFrame.image) <= 0.02
                } ?? false
                // Reusing a Back button across different pages is progress.
                // Small cursor/status changes alone must not defeat the guard.
                repeatedActions = previousIdentity == identity && unchangedScene ? repeatedActions + 1 : 0
                guard repeatedActions < 3 else { throw AgentError.message("模型在画面没有实质变化时连续重复同一动作，请检查定位或更换任务描述") }
                previousIdentity = identity; previousExecutionFrame = executionFrame
                executingAction = action; transition(.acting, "第 \(step) 步：\(action.label)")
                var verifiedInputBoundary: Date?
                // The action refers to the observation image; dimensions were checked above.
                if action.kind == .system_tool { try await executeTool(action, settings: settings, token: token) }
                else if action.kind == .phone_tool {
                    guard let phoneHarness else { throw AgentError.message("手机布局工具未接入") }
                    do {
                        let toolStarted = Date()
                        let toolTimer = runMetrics?.begin(.harness, label: "execute local semantic workflow")
                        var toolResult = RunStageOutcome.failed
                        defer { if let toolTimer { runMetrics?.end(toolTimer, outcome: Task.isCancelled ? .cancelled : toolResult) } }
                        let receipt = try await phoneHarness.execute(PhoneHarnessRequest.decode(action.text), frame: executionFrame,
                            mappedHome: settings.homeButtonIsMapped(to: executor.ble.selectedID), nextFrame: { [weak self] after in
                                guard let self else { throw CancellationError() }
                                try self.stillCurrent(token)
                                let fresh = try await self.freshFrame(after: after, token: token, allowPointerWake: true)
                                try self.stillCurrent(token)
                                guard fresh.captureID == executionFrame.captureID,
                                      fresh.sourceWidth == executionFrame.sourceWidth, fresh.sourceHeight == executionFrame.sourceHeight else {
                                    throw AgentError.message("手机工具执行期间共享或屏幕尺寸已改变，已停止")
                                }
                                return fresh
                            })
                        toolResult = .completed
                        try stillCurrent(token); log("手机工具回执", receipt.summary)
                        if receipt.requiresUserReview || phoneHarness.hasPendingReview {
                            toolResult = .failed
                            pendingAction = action; executingAction = nil
                            running = false; taskIndicator = .idle
                            transition(.needsUser, "本地流程结果待核验。请先检查手机实际结果，并到设备页处理回执。")
                            break
                        }
                        if let at = receipt.lastInputCompletedAt { recordInput(completedAt: at) }
                        if let verified = receipt.verifiedFrame { recordObservation(verified) }
                        verifiedInputBoundary = reusableInputBoundary(receipt, from: executionFrame)
                        log("手机工具耗时", String(format: "%.2f 秒", Date().timeIntervalSince(toolStarted)))
                    } catch let issue as PhoneHarnessFallback {
                        try stillCurrent(token); log("本地布局需重新观察", issue.message)
                        executingAction = nil; after = Date(); continue
                    }
                } else {
                    let inputStarted = Date()
                    let category: RunTimingCategory = action.kind == .wait ? .wait : .input
                    if let metrics = runMetrics {
                        try await metrics.measureAsync(category, label: "execute ordinary " + action.kind.rawValue) {
                            try await executor.execute(action, frame: executionFrame,
                                mappedHomeAvailable: settings.homeButtonIsMapped(to: executor.ble.selectedID))
                        }
                    } else {
                        try await executor.execute(action, frame: executionFrame,
                            mappedHomeAvailable: settings.homeButtonIsMapped(to: executor.ble.selectedID))
                    }
                    try stillCurrent(token)
                    if action.kind != .wait { recordInput(completedAt: Date()) }
                    log("输入执行耗时", String(format: "%.2f 秒", Date().timeIntervalSince(inputStarted)))
                    await phoneHarness?.didExecute(action, frame: executionFrame)
                }
                try stillCurrent(token); executingAction = nil
                if let verifiedInputBoundary {
                    // The local workflow has already observed the result of its
                    // last input. Preserve that watermark so its real final
                    // frame remains eligible for the next model observation.
                    // Model-return validation still independently checks a new
                    // current frame before any subsequent action is dispatched.
                    after = verifiedInputBoundary
                    log("复用已核对画面", "本地工具已核对最后输入后的真实画面，直接进入下一轮观察")
                    continue
                }
                // Frames delivered during the settling interval remain usable.
                // They must still be newer than the actual completed input.
                after = Date()
                // A real new frame can begin the next observation early. This
                // does not certify that a target page or business result is ready.
                try await awaitFrameEvent(after: after, timeout: max(0.4, min(5, settings.stepInterval)))
            }
            if running && token == session { pauseAtStepLimit(settings) }
        } catch let issue as PersistencePaused {
            if token == session { executingAction = nil; running = false; taskIndicator = .idle; transition(.paused, issue.localizedDescription) }
        } catch let decision as ToolDecisionError {
            if token == session { executingAction = nil; running = false; error = ""; taskIndicator = .idle; transition(.paused, decision.localizedDescription) }
        } catch is CancellationError {
            // A new session or Stop owns the visible state.
        } catch {
            if token == session {
                self.error = error.localizedDescription; executingAction = nil; running = false; taskIndicator = .failed; transition(.failed, "执行中断：\(error.localizedDescription)")
                log("停止", error.localizedDescription)
            }
        }
        if token == session && !settings.previewOnly {
            releasing = true
            await executor.ble.release()
            if token == session { releasing = false }
        }
        if token == session { finishRunMetrics(runMetrics); loop = nil; if !persistenceBlocked { publishRecord() } }
    }
    private func localImageChanged(_ before: UIImage, _ after: UIImage, action: AgentAction?) -> Bool {
        let width = 96, height = 192
        func raster(_ image: UIImage) -> [UInt8]? {
            guard let cg = image.cgImage else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                // Match normalized top-left coordinates used by model actions.
                context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            return success ? pixels : nil
        }
        guard let a = raster(before), let b = raster(after) else { return true }
        return FrameChangeAnalysis.compare(a, b, width: width, height: height,
            targetX: action?.x, targetY: action?.y).requiresReobservation
    }
    // This global average alone is not a target-identity or local-popup check.
    private func imageDifference(_ a: UIImage, _ b: UIImage) -> Double {
        func pixels(_ image: UIImage) -> [UInt8]? {
            guard let cg = image.cgImage else { return nil }
            var bytes = [UInt8](repeating: 0, count: 24 * 48 * 4)
            let rendered = bytes.withUnsafeMutableBytes { ptr -> Bool in
                guard let context = CGContext(data: ptr.baseAddress, width: 24, height: 48, bitsPerComponent: 8,
                    bytesPerRow: 24 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: 24, height: 48)); return true
            }
            return rendered ? bytes : nil
        }
        guard let x = pixels(a), let y = pixels(b) else { return 1 }
        var total = 0.0
        for i in stride(from: 0, to: x.count, by: 4) {
            total += abs(Double(x[i]) - Double(y[i])) + abs(Double(x[i+1]) - Double(y[i+1])) + abs(Double(x[i+2]) - Double(y[i+2]))
        }
        return total / Double(24 * 48 * 3 * 255)
    }
}
