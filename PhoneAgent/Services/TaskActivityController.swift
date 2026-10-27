import Foundation
import Combine
import ActivityKit
import UIKit

@MainActor
final class TaskActivityController: ObservableObject {
    @Published private(set) var error = ""
    @Published private(set) var activitiesAvailable = ActivityAuthorizationInfo().areActivitiesEnabled
    @Published private(set) var hasTaskPresentation = false
    @Published private(set) var previewing = false
    @Published private(set) var previewMessage = ""
    private var previewActivity: Activity<AgentActivityAttributes>?
    private var previewToken: UUID?
    private var previewExpiry: Task<Void, Never>?
    private var activity: Activity<AgentActivityAttributes>?
    private var queue: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private struct TerminalKey: Equatable { let taskID: UUID; let sessionID: UUID; let phase: AgentPhase }
    private var terminalKey: TerminalKey?
    private var pendingTerminalKey: TerminalKey?
    private var lastLiveTaskID: UUID?
    private var lastLiveSessionID: UUID?
    private var presentationRevision = UUID()
    private var terminalToken: UUID?
    private var terminalDeadline: Date?
    private var terminalExpiry: Task<Void, Never>?
    private var terminalAssertion: UIBackgroundTaskIdentifier = .invalid
    private let terminalDisplayNanoseconds: UInt64
    private let defaults: UserDefaults
    private let endActivity: (Activity<AgentActivityAttributes>, ActivityContent<AgentActivityAttributes.ContentState>?, ActivityUIDismissalPolicy) async -> Void
    var onFirstUseGuide: (() -> Void)?
    init(defaults: UserDefaults = .standard, terminalDisplayNanoseconds: UInt64 = 10_000_000_000,
         endActivity: @escaping (Activity<AgentActivityAttributes>, ActivityContent<AgentActivityAttributes.ContentState>?, ActivityUIDismissalPolicy) async -> Void = { activity, content, policy in
             await activity.end(content, dismissalPolicy: policy)
         }) {
        self.defaults = defaults; self.terminalDisplayNanoseconds = terminalDisplayNanoseconds; self.endActivity = endActivity
        // A previous process cannot still own our engine. Do not leave a stale
        // activity implying that an interrupted task continues after relaunch.
        let oldActivities = Activity<AgentActivityAttributes>.activities
        queue = Task { for old in oldActivities { await old.end(nil, dismissalPolicy: .immediate) } }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                self?.refreshLiveness()
            }
        }
    }
    deinit {
        heartbeat?.cancel(); previewExpiry?.cancel(); terminalExpiry?.cancel()
        let assertion = terminalAssertion
        if assertion != .invalid { Task { @MainActor in UIApplication.shared.endBackgroundTask(assertion) } }
    }
    func refreshAvailability() { activitiesAvailable = ActivityAuthorizationInfo().areActivitiesEnabled }
    func applicationBecameActive() {
        refreshAvailability()
        if previewToken != nil { stopPreview(message: "预览已结束。首次使用时，请在锁屏或通知中心的 Sela 卡片中点“允许”。") }
        if let token = terminalToken, let terminalDeadline, terminalDeadline <= Date() { finishTerminal(token: token) }
    }
    /// A display-only, user-started activity. It cannot start an engine, send a
    /// network request, enter task history, or grant activity task controls.
    @discardableResult func startPreview(phase: String = "observing") async -> Bool {
        refreshAvailability()
        guard Self.previewPhases.contains(phase) else { return false }
        guard UIApplication.shared.applicationState == .active, activitiesAvailable else {
            previewMessage = "系统已关闭实时活动，请到系统设置中检查 Sela 的实时活动开关。"; return false
        }
        guard !hasTaskPresentation, !previewing else {
            previewMessage = "当前已有任务状态或角色预览，请先查看现有状态。"; return false
        }
        let token = UUID(); previewToken = token; previewing = true
        previewMessage = "正在创建角色预览。"
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, self.previewToken == token else { return }
            guard !self.hasTaskPresentation, UIApplication.shared.applicationState == .active else {
                self.stopPreview(message: "预览尚未开始，请在 Sela 前台且没有任务时重试。"); return
            }
            let state = self.previewState(phase: phase)
            do {
                self.previewActivity = try Activity.request(attributes: AgentActivityAttributes(taskID: token),
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(60), relevanceScore: 100), pushType: nil)
                self.defaults.set(true, forKey: "sela.activity.firstUseGuideShown.v1")
                self.previewMessage = "预览已创建。返回桌面查看头像；首次没有显示时，锁屏或下拉通知中心，在 Sela 卡片中点“允许”。返回 Sela 会结束预览。"
                self.previewExpiry = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    guard self?.previewToken == token else { return }
                    self?.stopPreview(message: "预览已结束。可以再次预览，或开始实际任务查看角色状态。")
                }
            } catch {
                self.previewToken = nil; self.previewing = false
                self.previewMessage = "角色预览暂时无法创建，请检查系统实时活动开关后重试。"
            }
        }
        await queue?.value
        return previewToken == token && previewActivity != nil
    }
    private static let previewPhases: Set<String> = ["observing", "acting", "needsUser", "paused", "completed", "stale", "failed"]
    private func previewState(phase: String) -> AgentActivityAttributes.ContentState {
        .init(status: "仅为角色预览，未执行任务", step: 0, updatedAt: Date(),
            canPause: false, canStop: false, completed: phase == "completed", phase: phase,
            taskTitle: "Sela 角色预览", isPreview: true)
    }
    func updatePreview(phase: String) {
        guard Self.previewPhases.contains(phase), let token = previewToken else { return }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, self.previewToken == token, let preview = self.previewActivity else { return }
            await preview.update(ActivityContent(state: self.previewState(phase: phase),
                staleDate: Date().addingTimeInterval(60), relevanceScore: 100))
        }
    }
    func stopPreview(message: String = "预览已结束。") {
        previewToken = nil; previewing = false; previewExpiry?.cancel(); previewExpiry = nil
        let previousPreview = previewActivity; previewActivity = nil; previewMessage = message
        guard let previousPreview else { return }
        let previous = queue
        queue = Task {
            await previous?.value
            await previousPreview.end(nil, dismissalPolicy: .immediate)
        }
    }
    private func refreshLiveness() {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, let activity = self.activity else { return }
            var state = activity.content.state
            state.updatedAt = Date()
            // The heartbeat confirms this process is still observing its live
            // work; suspension still makes the island stale after one minute.
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60), relevanceScore: 100))
        }
    }
    func represents(_ taskID: UUID) -> Bool { activity?.attributes.taskID == taskID }
    func flush() async { await queue?.value }
    func update(record: PhoneTaskRecord?, phase: AgentPhase, step: Int, action: String?, enabled: Bool, sessionID: UUID, releasing: Bool, canPause: Bool, canStop: Bool) {
        let final = [.completed, .failed, .stopped, .idle, .preview].contains(phase)
        let keepTerminal = [.completed, .failed, .stopped].contains(phase) && !releasing
        if enabled, let record, !final || releasing { lastLiveTaskID = record.id; lastLiveSessionID = sessionID }
        if enabled, keepTerminal, let record,
           lastLiveTaskID != record.id || lastLiveSessionID != sessionID { return }
        if enabled, record == nil, terminalToken != nil || pendingTerminalKey != nil { return }
        let revision = UUID(); presentationRevision = revision
        if !enabled { error = "" }
        if !enabled || !final || releasing { cancelTerminalPresentation() }
        if enabled, keepTerminal, let record { pendingTerminalKey = .init(taskID: record.id, sessionID: sessionID, phase: phase) }
        hasTaskPresentation = enabled && record != nil && (!final || releasing || keepTerminal)
        if !enabled || hasTaskPresentation {
            if previewToken != nil { stopPreview(message: hasTaskPresentation ? "预览已结束，正在显示实际任务状态。" : "实时活动显示已关闭。") }
        }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.apply(record: record, phase: phase, step: step, action: action, enabled: enabled,
                             sessionID: sessionID, releasing: releasing, canPause: canPause, canStop: canStop, revision: revision)
        }
    }
    private func apply(record: PhoneTaskRecord?, phase: AgentPhase, step: Int, action: String?, enabled: Bool, sessionID: UUID, releasing: Bool, canPause: Bool, canStop: Bool, revision: UUID) async {
        guard enabled, let record else {
            // A later foreground task may already have taken presentation
            // ownership while an earlier ActivityKit update was suspended.
            // Never end its only reusable activity after the app backgrounds.
            guard presentationRevision == revision else { return }
            cancelTerminalPresentation()
            hasTaskPresentation = false
            error = ""
            if let activity {
                await endActivity(activity, nil, .immediate)
                if self.activity === activity { self.activity = nil }
            }
            return
        }
        // Do not create a stale queued presentation after a newer close. A
        // queued initial state is still needed when a current terminal state
        // owns the presentation, so that completion can be shown accurately.
        if presentationRevision != revision && !hasTaskPresentation { return }
        let final = [.completed, .failed, .stopped, .idle, .preview].contains(phase)
        let isTerminal = [.completed, .failed, .stopped].contains(phase) && !releasing
        if isTerminal, lastLiveTaskID != record.id || lastLiveSessionID != sessionID { return }
        if !final || releasing { cancelTerminalPresentation() }
        // The user opted to display the task name. Never expose screenshots,
        // model reasoning or tool result contents on the lock screen.
        var status: String
        switch phase {
        case .preparing: status = "正在准备"
        case .observing: status = "正在观察与规划"
        case .acting: status = action ?? "正在执行"
        case .awaitingApproval: status = "请回到 App 确认"
        default: status = phase.outcome.label
        }
        if releasing { status = "\(phase.outcome.label)，正在结束操作与释放输入" }
        var state = AgentActivityAttributes.ContentState(status: String(status.prefix(80)), step: step, updatedAt: Date(),
            controlSessionID: final ? nil : sessionID, canPause: !final && canPause && !releasing, canStop: !final && canStop, completed: phase == .completed && !releasing, phase: phase.rawValue, taskTitle: String((record.title.components(separatedBy: .newlines).first ?? record.title).prefix(60)))
        state.displayTaskID = record.id
        if let activity, activity.attributes.taskID != record.id {
            if UIApplication.shared.applicationState == .active {
                await endActivity(activity, nil, .immediate)
                if self.activity === activity { self.activity = nil }
            } else {
                // ActivityKit cannot create a replacement while backgrounded.
                // Reuse the existing display, with an explicit current link and
                // no controls against its old immutable task identity.
                state.controlSessionID = nil; state.canPause = false; state.canStop = false
            }
        }
        // The character is the primary task surface. A higher relative score
        // keeps it ahead of other activities from this app when iOS can honor it.
        let keepTerminal = [.completed, .failed, .stopped].contains(phase) && !releasing
        let content = ActivityContent(state: state, staleDate: keepTerminal ? Date().addingTimeInterval(Double(terminalDisplayNanoseconds) / 1_000_000_000) : final && !releasing ? nil : Date().addingTimeInterval(60), relevanceScore: 100)
        if final && !releasing {
            if let activity {
                if keepTerminal {
                    await activity.update(content)
                    let key = TerminalKey(taskID: record.id, sessionID: sessionID, phase: phase)
                    // Display can be disabled, or a newer run can take over,
                    // while ActivityKit is suspended. Only the still-pending
                    // terminal state may recreate presentation ownership.
                    guard presentationRevision == revision else { return }
                    retainTerminal(activity, key: key)
                } else {
                    cancelTerminalPresentation()
                    await endActivity(activity, content, .after(Date().addingTimeInterval(300)))
                    if self.activity === activity { self.activity = nil }
                }
            } else {
                if presentationRevision == revision {
                    pendingTerminalKey = nil; hasTaskPresentation = false; error = ""
                }
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if presentationRevision == revision {
                hasTaskPresentation = false
                error = "系统未允许实时活动，请在系统设置中检查 Sela 权限"
            }
            return
        }
        if let activity {
            await activity.update(content)
            if presentationRevision == revision { hasTaskPresentation = true; error = "" }
        }
        else if !final && UIApplication.shared.applicationState == .active {
            do {
                activity = try Activity.request(attributes: AgentActivityAttributes(taskID: record.id), content: content, pushType: nil)
                if presentationRevision == revision { hasTaskPresentation = true; error = "" }
                if !defaults.bool(forKey: "sela.activity.firstUseGuideShown.v1") {
                    defaults.set(true, forKey: "sela.activity.firstUseGuideShown.v1"); onFirstUseGuide?()
                }
            }
            catch {
                if presentationRevision == revision {
                    hasTaskPresentation = false
                    self.error = "实时活动暂时无法开启（" + String((error as NSError).code) + "）；任务仍可在 App 内查看"
                }
            }
        } else if !final && presentationRevision == revision {
            // An end already handed to ActivityKit cannot be recalled. The
            // platform disallows a replacement until the app is foregrounded.
            // The host will send its current task snapshot on foreground return.
            hasTaskPresentation = false
            error = "实时活动暂不可显示，返回 Sela 后恢复"
        }
    }
    private func retainTerminal(_ activity: Activity<AgentActivityAttributes>, key: TerminalKey) {
        hasTaskPresentation = true
        guard terminalKey != key || terminalToken == nil else { return }
        cancelTerminalPresentation()
        let token = UUID(); terminalToken = token; terminalKey = key
        terminalDeadline = Date().addingTimeInterval(Double(terminalDisplayNanoseconds) / 1_000_000_000)
        // The execution already ended. This finite assertion only lets the
        // completion marker be seen briefly and then removes it reliably.
        terminalAssertion = UIApplication.shared.beginBackgroundTask(withName: "Sela terminal display cleanup") { [weak self] in
            guard let self, self.terminalToken == token else { return }
            self.endTerminalAssertion(); self.finishTerminal(token: token)
        }
        terminalExpiry = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: self.terminalDisplayNanoseconds) } catch { return }
            self.finishTerminal(token: token)
        }
    }
    private func finishTerminal(token: UUID) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, self.terminalToken == token, let activity = self.activity else { return }
            await self.endActivity(activity, activity.content, .after(Date().addingTimeInterval(300)))
            if self.activity === activity { self.activity = nil }
            if self.terminalToken == token {
                self.cancelTerminalPresentation(); self.hasTaskPresentation = false
            }
        }
    }
    private func cancelTerminalPresentation() {
        terminalToken = nil; terminalKey = nil; pendingTerminalKey = nil; terminalDeadline = nil
        terminalExpiry?.cancel(); terminalExpiry = nil; endTerminalAssertion()
    }
    private func endTerminalAssertion() {
        guard terminalAssertion != .invalid else { return }
        let previous = terminalAssertion; terminalAssertion = .invalid
        UIApplication.shared.endBackgroundTask(previous)
    }

}
