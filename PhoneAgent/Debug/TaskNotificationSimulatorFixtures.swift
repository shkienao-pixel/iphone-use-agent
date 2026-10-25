#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit

/// Fixed, opt-in OS-notification fixtures. They never run the business engine.
@MainActor enum TaskNotificationSimulatorFixtures {
    private static let firstID = UUID(uuidString: "00000000-0000-4000-8000-202610250101")!
    private static let secondID = UUID(uuidString: "00000000-0000-4000-8000-202610250102")!
    private static var session = UUID()
    private static var record: PhoneTaskRecord?
    private static var lastPhase = ""
    private static var pending: Task<Void, Never>?

    static func apply(_ value: String?, model: PhoneAgentViewModel) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--sela-notification-fixtures"),
              UIApplication.shared.applicationState == .active, !model.engine.hasCurrentTask else {
            throw AgentError.message("通知展示用例仅允许在专用模拟器的空闲测试会话运行")
        }
        if value == "repeat_last", let record {
            for _ in 0..<8 { observe(record, phase: lastPhase, model: model) }
            await model.taskNotifications.flush(); return
        }
        guard let value, ["foreground", "prepare_B", "background_A", "background_B", "delayed_foreground"].contains(value) else {
            throw AgentError.message("未知通知展示用例")
        }
        pending?.cancel(); session = UUID()
        let second = value == "background_B" || value == "prepare_B"
        let name = second ? "海棠通知 B" : "海棠通知 A"
        record = PhoneTaskRecord(id: second ? secondID : firstID, title: name,
            goal: name + "：仅核验系统通知及任务跳转；未执行业务任务。")
        model.history.upsert(record!)
        observe(record!, phase: "preparing", model: model)
        await model.taskNotifications.flush()
        if value == "prepare_B" { return }
        if value == "foreground" {
            finish(model: model)
            await model.taskNotifications.flush(); return
        }
        if value == "delayed_foreground" {
            finish(model: model)
            let event = TaskNotificationEvent(id: UUID(), taskID: record!.id, executionID: session,
                kind: .completed, taskTitle: name + " · 前台横幅抑制用例")
            await model.taskNotifications.schedulePresentationFixture(event, delay: 5)
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "SelaNotificationFixture", expirationHandler: nil)
        pending = Task { @MainActor in
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            do {
                try await Task.sleep(for: .seconds(3))
                try Task.checkCancellation()
                finish(model: model)
                await model.taskNotifications.flush()
            } catch { }
        }
    }
    private static func observe(_ record: PhoneTaskRecord, phase: String, model: PhoneAgentViewModel) {
        lastPhase = phase
        model.taskNotifications.observe(taskID: record.id, title: record.title, sessionID: session, phase: phase, releasing: false)
    }
    private static func finish(model: PhoneAgentViewModel) {
        guard var current = record else { return }
        current.outcome = .completed; current.summary = current.title + " · 通知展示夹具已结算，未执行模型任务。"
        record = current; model.history.upsert(current)
        for _ in 0..<8 { observe(current, phase: "completed", model: model) }
    }
}
#endif
