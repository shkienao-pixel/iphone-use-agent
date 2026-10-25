#if DEBUG && targetEnvironment(simulator)
import Foundation
import ActivityKit
import UIKit

/// Opt-in presentation fixtures. They never start the engine or invoke a model/tool.
@MainActor enum TaskActivitySimulatorFixtures {
    private static let firstID = UUID(uuidString: "00000000-0000-4000-8000-202610250001")!
    private static let secondID = UUID(uuidString: "00000000-0000-4000-8000-202610250002")!
    private static let session = UUID()
    private static var record: PhoneTaskRecord?

    static func apply(_ value: String?, model: PhoneAgentViewModel) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--sela-activity-fixtures"),
              UIApplication.shared.applicationState == .active, !model.engine.hasCurrentTask else {
            throw AgentError.message("实时活动展示用例仅允许在专用模拟器的空闲测试会话运行")
        }
        if value == "hide" {
            model.taskActivity.update(record: nil, phase: .idle, step: 0, action: nil, enabled: false,
                sessionID: session, releasing: false, canPause: false, canStop: false)
            await model.taskActivity.flush()
            for old in Activity<AgentActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let phase = value == "second" ? AgentPhase.preparing : value.flatMap(AgentPhase.init(rawValue:))
        guard let phase, ![.idle, .preview].contains(phase) else { throw AgentError.message("未知实时活动展示状态") }
        if record == nil || value == "second" {
            let second = value == "second"
            record = PhoneTaskRecord(id: second ? secondID : firstID,
                title: second ? "海棠展示 B" : "海棠展示 A", goal: "仅供实时活动展示核验；未执行业务任务。")
        }
        record!.outcome = phase.outcome
        record!.summary = "模拟器展示状态：" + phase.rawValue
        model.history.upsert(record!)
        model.taskActivity.update(record: record, phase: phase, step: phase == .preparing ? 0 : 3,
            action: "正在核对展示状态", enabled: true, sessionID: session,
            releasing: false, canPause: false, canStop: false)
        await model.taskActivity.flush()
    }
}
#endif
