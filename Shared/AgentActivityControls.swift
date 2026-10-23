import Foundation
import AppIntents
import ActivityKit

enum ActivityTaskControl: String { case pause, stop }

// Installed only by the live app model. Nothing restores this handler, an
// execution session or an engine from an activity / persisted queue record.
@MainActor
enum AgentActivityControls {
    static var handler: ((UUID, UUID, ActivityTaskControl) async -> Void)?

    static func run(taskID: String, sessionID: String, control: ActivityTaskControl) async {
        guard let task = UUID(uuidString: taskID), let session = UUID(uuidString: sessionID) else { return }
        if let handler { await handler(task, session, control); return }
        // A cold process with no engine cannot stop a previously running task.
        // Retire only the matching stale activity; never create or resume work.
        for activity in Activity<AgentActivityAttributes>.activities
            where activity.attributes.taskID == task && activity.content.state.controlSessionID == session {
            var state = activity.content.state
            state.status = "任务状态已失效，请回到 App 核对"
            state.updatedAt = Date(); state.controlSessionID = nil
            state.canPause = false; state.canStop = false
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(30)))
        }
    }
}

struct PauseActivityPhoneTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暂停实时活动中的手机任务"
    static let description = IntentDescription("暂停此卡片对应的当前执行，取消计划并释放输入。")
    static let supportedModes: IntentModes = [.background]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let isDiscoverable = false
    @Parameter(title: "任务标识") var taskID: String
    @Parameter(title: "执行标识") var sessionID: String
    init() {}
    init(taskID: UUID, sessionID: UUID) { self.taskID = taskID.uuidString; self.sessionID = sessionID.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        await AgentActivityControls.run(taskID: taskID, sessionID: sessionID, control: .pause)
        return .result()
    }
}

struct StopActivityPhoneTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "停止实时活动中的手机任务"
    static let description = IntentDescription("结束此卡片对应的任务并暂停队列，等待项保留。")
    static let supportedModes: IntentModes = [.background]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let isDiscoverable = false
    @Parameter(title: "任务标识") var taskID: String
    @Parameter(title: "执行标识") var sessionID: String
    init() {}
    init(taskID: UUID, sessionID: UUID) { self.taskID = taskID.uuidString; self.sessionID = sessionID.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        await AgentActivityControls.run(taskID: taskID, sessionID: sessionID, control: .stop)
        return .result()
    }
}
