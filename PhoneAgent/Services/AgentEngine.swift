import Foundation
import Combine
import UIKit

/// Host-generated evidence from a local workflow. Only a real observation made
/// after its final input can replace another settling wait in the outer loop.
struct PhoneHarnessReceipt {
    let summary: String
    let verifiedFrame: ScreenFrame?
    let lastInputCompletedAt: Date?
}

@MainActor
protocol PhoneHarnessDriving: AnyObject {
    func reset()
    func context(for frame: ScreenFrame) async throws -> String
    func didExecute(_ action: AgentAction, frame: ScreenFrame) async
    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt
}

extension PhoneHarnessDriving { func reset() {} }

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

@MainActor
final class AgentEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var phase: AgentPhase = .idle
    @Published private(set) var releasing = false
    @Published private(set) var currentRecord: PhoneTaskRecord?
    var onRecord: ((PhoneTaskRecord) -> Void)?
    var memoryContext: ((String) async -> String)?
    var systemTool: ((UUID, SystemToolRequest) async throws -> String)?
    var phoneHarness: PhoneHarnessDriving?
    private var savedGoal = ""
    private var savedSettings: AgentSettings?
    private var releaseTask: Task<Void, Never>?
    private var previousIdentity: String?
    private var previousExecutionFrame: ScreenFrame?
    private var repeatedActions = 0
    private func resetActionRepetition() {
        previousIdentity = nil; previousExecutionFrame = nil; repeatedActions = 0
    }
    var canResume: Bool { savedSettings != nil && [.paused, .needsUser, .failed].contains(phase) && !releasing }
    var executionSettled: Bool { !running && !releasing && loop == nil }
    var currentSettings: AgentSettings? { savedSettings }
    var hasCurrentTask: Bool { savedSettings != nil && currentRecord != nil }
    private func transition(_ phase: AgentPhase, _ message: String) {
        self.phase = phase; state = message; publishRecord()
    }
    private func publishRecord() {
        guard var record = currentRecord else { return }
        record.updatedAt = Date(); record.outcome = phase.outcome; record.summary = state; record.logs = logs
        currentRecord = record; onRecord?(record)
    }
    func renameCurrent(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        currentRecord?.title = String(title.prefix(80)); publishRecord()
    }
    func discardCurrent() {
        guard !running, !releasing else { return }
        currentRecord = nil; savedSettings = nil; logs = []; phase = .idle; state = "准备开始"; error = ""
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

    init(capture: CaptureService, executor: MouseExecutor) { self.capture = capture; self.executor = executor }
    func log(_ title: String, _ detail: String, step: Int? = nil) {
        logs.append(AgentLogEntry(step: step ?? currentStep, title: title, detail: detail))
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
        publishRecord()
    }
    func clearLogs() { if !running { logs = []; publishRecord() } }
    func approve() { approved = true }
    private func cancelAndRelease() {
        phoneHarness?.reset()
        session = UUID(); let previous = loop; previous?.cancel(); loop = nil
        resetActionRepetition()
        running = false; pendingAction = nil; executingAction = nil
        guard releaseTask == nil else { return }
        releasing = true
        releaseTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.executor.ble.release(); self.executor.invalidatePosition()
            self.releasing = false; self.releaseTask = nil
        }
    }
    func pause() {
        guard running else { return }
        cancelAndRelease(); taskIndicator = .idle
        transition(.paused, "已暂停。继续时先核对最新画面。")
        log("暂停", "已取消旧计划并释放输入；上一步可能已部分执行，恢复后先核对结果。")
    }
    func handoff() {
        guard hasCurrentTask else { return }
        cancelAndRelease(); taskIndicator = .idle; error = ""
        transition(.needsUser, "已交给你操作。处理好后，可以说“继续”。")
        log("你已接管", "保留任务和进度，取消旧计划并释放输入。继续时重新检查当前画面。")
    }
    func amendTask(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasCurrentTask, var record = currentRecord else { throw AgentError.message("没有可补充的当前任务，请先开始任务") }
        guard !text.isEmpty, text.count <= 4000 else { throw AgentError.message("补充要求需为 1–4000 字") }
        guard (record.amendments ?? []).count < 20 else { throw AgentError.message("当前任务已收到 20 次补充，请整理需求后创建新任务") }
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
    func start(task: String, settings: AgentSettings, subtasks: [String] = []) {
        guard !running, !releasing else { return }
        let goal = task.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !goal.isEmpty, goal.count <= 12000 else { throw AgentError.message("请输入 1–12000 字的任务") }
            guard subtasks.count <= 12, subtasks.allSatisfy({ !$0.isEmpty && $0.count <= 240 }) else { throw AgentError.message("子任务清单格式无效") }
            try checkReady(settings)
        } catch { self.error = error.localizedDescription; return }
        if currentRecord != nil, savedSettings != nil {
            transition(.stopped, "已切换到新任务")
        }
        savedGoal = goal; savedSettings = settings
        error = ""; pendingAction = nil; executingAction = nil; logs = []; currentStep = 0
        resetActionRepetition()
        currentRecord = PhoneTaskRecord(title: String(goal.prefix(36)), goal: goal, subtasks: subtasks.isEmpty ? nil : subtasks.map { TaskSubtask(goal: $0) })
        launch(goal: goal, settings: settings, resumed: false)
    }
    // Queue restores preserve the same task ID, amendments, receipts and completed
    // subtasks. Pending actions are deliberately not part of the checkpoint.
    func restoreQueued(record: PhoneTaskRecord, settings: AgentSettings, step: Int, previouslyStarted: Bool) throws {
        guard executionSettled else { throw AgentError.message("正在结束上一次执行，请稍后再试") }
        guard !record.effectiveGoal.isEmpty, record.effectiveGoal.count <= 12000,
              (0...100).contains(step), step < settings.maxSteps,
              ![TaskOutcome.completed, .stopped, .preview].contains(record.outcome) else {
            throw AgentError.message("此队列任务不能继续，请核对结果或创建新任务")
        }
        try checkReady(settings)
        savedGoal = record.effectiveGoal; savedSettings = settings
        currentRecord = record; logs = record.logs; currentStep = step
        resetActionRepetition(); approved = false
        if previouslyStarted { log("从队列继续", "保留任务 ID 和已确认子任务；上一步可能已部分执行，先核对当前状态，不重放旧动作。") }
        launch(goal: savedGoal, settings: settings, resumed: previouslyStarted)
        guard running else { throw AgentError.message("队列记录未能保存，执行没有启动") }
    }
    func configurePausedTask(settings: AgentSettings) {
        guard canResume else { return }
        savedSettings = settings
    }
    func resume(settings: AgentSettings? = nil, delay: Double? = nil) {
        guard canResume, let previousSettings = savedSettings else { return }
        let savedSettings = settings ?? previousSettings
        do {
            try checkReady(savedSettings)
            guard currentStep < savedSettings.maxSteps else { throw AgentError.message("已达到行动步数上限，请检查任务结果后创建新任务") }
        } catch { self.error = error.localizedDescription; return }
        self.savedSettings = savedSettings
        log("恢复任务", "上一次操作可能已部分执行；先检查当前页面、字段与发送结果，不重放旧动作。")
        launch(goal: savedGoal, settings: savedSettings, resumed: true, resumeDelay: delay)
    }
    private func launch(goal: String, settings: AgentSettings, resumed: Bool, resumeDelay: Double? = nil) {
        phoneHarness?.reset()
        resetActionRepetition()
        executor.invalidatePosition(); error = ""; pendingAction = nil; executingAction = nil
        let token = UUID(); session = token
        running = true; taskIndicator = .running; transition(.preparing, resumed ? "正在恢复任务" : "正在准备任务")
        guard running else { return } // Record persistence may synchronously pause a queue.
        var runSettings = settings
        if resumed { runSettings.startDelay = min(30, max(2, resumeDelay ?? min(3, settings.startDelay))) }
        let firstStep = currentStep + 1
        let client = VisionClient(settings: settings, apiKey: SettingsStore.apiKey(for: settings.endpoint))
        loop = Task { [weak self] in
            if runSettings.toolsOnly == true { await self?.runTools(goal: goal, settings: runSettings, client: client, token: token, firstStep: firstStep) }
            else { await self?.run(goal: goal, settings: runSettings, client: client, token: token, firstStep: firstStep) }
        }
    }
    private func stillCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == session && running else { throw CancellationError() }
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
        let began = Date()
        let deadline = began.addingTimeInterval(6)
        var recoveryAttempted = false
        while Date() < deadline {
            try stillCurrent(token)
            guard capture.running else { throw AgentError.message("屏幕共享已停止") }
            if capture.frame?.fullDisplay == false { throw AgentError.message("屏幕共享已切换为单个应用，请重新共享整屏") }
            if let frame = recentFrame(after: after) { return frame }
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
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try stillCurrent(token)
        throw AgentError.message("等待 6 秒仍未收到可用的整屏画面，请检查屏幕共享后继续")
    }
    private func validatedFrame(for observation: ScreenFrame, token: UUID, allowPointerWake: Bool,
                                after: Date? = nil, waitingMessage: String) async throws -> ScreenFrame? {
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
        if waiting { log("画面已恢复", "已核对最新画面与模型所见画面，继续当前步骤") }
        return latest
    }
    private func planningGoal(_ goal: String) -> String {
        guard let subtasks = currentRecord?.subtasks, !subtasks.isEmpty else { return goal }
        let list = subtasks.map { "ID=\($0.id.uuidString) · \($0.completed ? "已确认完成" : "待完成") · \($0.goal)" }.joined(separator: "\n")
        return goal + "\n\n子任务账本：\n" + list + "\n按顺序完成尚未完成项目；已有完成记录不得重做。核对一项成功后，返回 complete_subtask，text 为该项 ID，reason 描述可验证的结果；App 会让用户确认。全部项目确认后才可 finish。"
    }
    private func finishAllowed() throws {
        guard currentRecord?.subtasks?.contains(where: { !$0.completed }) != true else { throw AgentError.message("仍有未确认完成的子任务，请核对结果后继续") }
    }
    private func completeSubtask(_ action: AgentAction, token: UUID) async throws {
        guard let id = UUID(uuidString: action.text ?? ""), var record = currentRecord,
              let index = record.subtasks?.firstIndex(where: { !$0.completed }), record.subtasks?[index].id == id else { throw AgentError.message("子任务 ID 或顺序无效，没有更改账本") }
        pendingAction = action; approved = false; transition(.awaitingApproval, "请确认子任务已完成：" + (record.subtasks?[index].goal ?? ""))
        while !approved { try await Task.sleep(nanoseconds: 150_000_000); try stillCurrent(token) }
        try stillCurrent(token); pendingAction = nil
        guard let latest = currentRecord else { throw CancellationError() }; record = latest
        record.subtasks?[index].completed = true; record.subtasks?[index].evidence = action.reason
        currentRecord = record; log("子任务确认完成", action.reason)
    }
    private func observeAction(goal: String, settings: AgentSettings, client: VisionClient, token: UUID,
                               step: Int, after: Date, remainingRecoveries: inout Int,
                               responseLimit: inout Int) async throws -> (ScreenFrame, AgentAction) {
        var after = after
        var retried = false
        while true {
            try stillCurrent(token)
            let captureStarted = Date()
            let frame = try await freshFrame(after: after, token: token, allowPointerWake: !settings.previewOnly)
            log("取屏耗时", String(format: "%.2f 秒", Date().timeIntervalSince(captureStarted)))
            if !settings.previewOnly { _ = try executor.validateCalibration(frame: frame) }
            transition(.observing, retried ? "第 \(step) 步：重新观察并生成完整动作" : "第 \(step) 步：正在观察")
            do {
                let context = settings.useMemories == true ? await memoryContext?(goal) ?? "" : ""
                let localStarted = Date()
                let harnessContext = try await phoneHarness?.context(for: frame) ?? ""
                try stillCurrent(token)
                if phoneHarness != nil { log("本地布局耗时", String(format: "%.2f 秒", Date().timeIntervalSince(localStarted))) }
                let modelStarted = Date()
                let action = try await client.nextAction(task: planningGoal(goal), jpeg: frame.jpeg, width: frame.width, height: frame.height,
                    history: logs, keyboardAvailable: executor.ble.keyboardReady,
                    mappedHomeAvailable: settings.homeButtonIsMapped(to: executor.ble.selectedID),
                    tokenLimit: responseLimit, formatRetry: retried, memoryContext: context, harnessContext: harnessContext)
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
    private func executeTool(_ action: AgentAction, settings: AgentSettings, token: UUID) async throws {
        guard settings.systemToolsEnabled == true, let systemTool, let id = currentRecord?.id else { throw AgentError.message("系统工具未启用") }
        let request = try SystemToolRequest.decode(action.text)
        transition(.awaitingApproval, "请回到 Phone Agent 确认：" + request.operation.label)
        let result = try await systemTool(id, request)
        try stillCurrent(token); log("工具回执", result); transition(.observing, "工具已完成，正在核对后续任务")
    }
    private func runTools(goal: String, settings: AgentSettings, client: VisionClient, token: UUID, firstStep: Int) async {
        do {
            var recoveries = 3
            var limit = settings.responseTokenLimit
            for step in firstStep...max(firstStep, min(100, settings.maxSteps)) {
                try stillCurrent(token); currentStep = step; transition(.observing, "第 \(step) 步：规划系统工具")
                let context = settings.useMemories == true ? await memoryContext?(goal) ?? "" : ""
                try stillCurrent(token)
                let action: AgentAction
                do { action = try await client.nextAction(task: planningGoal(goal), jpeg: Data(), width: 0, height: 0, history: logs, keyboardAvailable: false, mappedHomeAvailable: false, tokenLimit: limit, memoryContext: context) }
                catch let issue as ModelResponseIssue {
                    try stillCurrent(token); guard recoveries > 0 else { throw issue }; recoveries -= 1
                    if issue.kind == .length { limit = min(16384, limit * 2) }
                    log("回复未执行", issue.diagnostic); continue
                }
                try stillCurrent(token); log(action.label, action.reason); try stillCurrent(token)
                switch action.kind {
                case .finish: try finishAllowed(); running = false; taskIndicator = .completed; transition(.completed, action.reason); savedSettings = nil
                case .complete_subtask:
                    if settings.previewOnly { pendingAction = action; running = false; transition(.preview, action.reason); savedSettings = nil }
                    else { try await completeSubtask(action, token: token) }
                case .ask_user: pendingAction = action; running = false; taskIndicator = .idle; transition(.needsUser, action.reason)
                case .system_tool:
                    if settings.previewOnly { pendingAction = action; running = false; transition(.preview, action.reason); savedSettings = nil }
                    else { executingAction = action; try await executeTool(action, settings: settings, token: token); executingAction = nil }
                case .wait: try await Task.sleep(nanoseconds: UInt64(max(0.4, min(10, action.seconds ?? 1)) * 1_000_000_000))
                default: throw AgentError.message("当前为仅系统工具模式，不能执行鼠标动作。请在设置中切换模式")
                }
                if !running { break }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            if running && token == session { running = false; taskIndicator = .failed; transition(.failed, "已达到工具任务的步数上限") }
        } catch is CancellationError {}
        catch let decision as ToolDecisionError { if token == session { executingAction = nil; running = false; error = ""; taskIndicator = .idle; transition(.paused, decision.localizedDescription) } }
        catch { if token == session { self.error = error.localizedDescription; executingAction = nil; running = false; taskIndicator = .failed; transition(.failed, error.localizedDescription); log("工具任务中断", error.localizedDescription) } }
        if token == session { loop = nil; publishRecord() }
    }
    private func run(goal: String, settings: AgentSettings, client: VisionClient, token: UUID, firstStep: Int) async {
        do {
            for n in stride(from: Int(settings.startDelay.rounded()), through: 1, by: -1) {
                transition(.preparing, "\(n) 秒后开始，请切换到目标 App")
                try await Task.sleep(nanoseconds: 1_000_000_000); try stillCurrent(token)
            }
            var after = Date()
            var remainingRecoveries = 3
            var responseLimit = settings.responseTokenLimit
            for step in firstStep...max(firstStep, min(100, settings.maxSteps)) {
                try stillCurrent(token); currentStep = step; transition(.observing, "读取最新画面")
                let (frame, action) = try await observeAction(goal: goal, settings: settings, client: client, token: token,
                    step: step, after: after, remainingRecoveries: &remainingRecoveries, responseLimit: &responseLimit)
                try stillCurrent(token)
                guard var executionFrame = try await validatedFrame(for: frame, token: token, allowPointerWake: !settings.previewOnly,
                    waitingMessage: "模型已返回，等待最新屏幕画面") else {
                    after = Date(); continue
                }
                let identity = "\(action.kind.rawValue)|\(action.x ?? -1)|\(action.y ?? -1)|\(action.x2 ?? -1)|\(action.y2 ?? -1)|\(action.text ?? "")|\(action.amount ?? 0)"
                log(action.label, action.reason); try stillCurrent(token)
                if action.kind == .finish { try finishAllowed(); running = false; taskIndicator = .completed; transition(.completed, action.reason); savedSettings = nil; break }
                if action.kind == .ask_user {
                    pendingAction = action; running = false; taskIndicator = .idle; transition(.needsUser, action.reason); break
                }
                if settings.previewOnly {
                    pendingAction = action; running = false; taskIndicator = .idle; transition(.preview, "已生成计划：\(action.reason)"); savedSettings = nil; break
                }
                if action.kind == .complete_subtask { try await completeSubtask(action, token: token); after = Date(); continue }
                if action.kind == .press_key, action.text?.lowercased() == "home",
                   !settings.homeButtonIsMapped(to: executor.ble.selectedID) {
                    log("改用辅助触控菜单", "中键主屏幕映射尚未确认；请点击当前可见辅助触控按钮，观察菜单，再点击主屏幕。")
                    transition(.observing, "重新观察返回桌面的入口"); after = Date(); continue
                }
                if settings.confirmEachStep && action.kind != .system_tool {
                    pendingAction = action; approved = false; transition(.awaitingApproval, "等待确认：\(action.label)")
                    while !approved { try await Task.sleep(nanoseconds: 150_000_000); try stillCurrent(token) }
                    pendingAction = nil
                    guard let latest = try await validatedFrame(for: frame, token: token, allowPointerWake: !settings.previewOnly, after: Date(),
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
                        try stillCurrent(token); log("手机工具回执", receipt.summary)
                        verifiedInputBoundary = reusableInputBoundary(receipt, from: executionFrame)
                        log("手机工具耗时", String(format: "%.2f 秒", Date().timeIntervalSince(toolStarted)))
                    } catch let issue as PhoneHarnessFallback {
                        try stillCurrent(token); log("本地布局需重新观察", issue.message)
                        executingAction = nil; after = Date(); continue
                    }
                } else {
                    let inputStarted = Date()
                    try await executor.execute(action, frame: executionFrame,
                        mappedHomeAvailable: settings.homeButtonIsMapped(to: executor.ble.selectedID))
                    try stillCurrent(token)
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
                try await Task.sleep(nanoseconds: UInt64(max(0.4, min(5, settings.stepInterval)) * 1_000_000_000))
            }
            if running && token == session { running = false; taskIndicator = .failed; transition(.failed, "已到达最大步数，请检查当前结果") }
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
        if token == session { loop = nil; publishRecord() }
    }
    // Ignore small cursor/animation changes, but discard plans after a large scene change.
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
