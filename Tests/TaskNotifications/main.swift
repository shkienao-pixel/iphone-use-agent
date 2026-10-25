import Foundation

@main struct NotificationChecks {
    static var count = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) {
        do { guard try value() else { fatalError(label) }; count += 1 }
        catch { fatalError(label + ": " + error.localizedDescription) }
    }
    static func main() throws {
        let a = UUID(), b = UUID(), run = UUID()
        var policy = TaskNotificationPolicy()
        func observe(_ task: UUID? = a, _ phase: String, release: Bool = false, foreground: Bool = false,
                     enabled: Bool = true, session: UUID = run, title: String = "海棠通知\n不应显示的第二行") -> TaskNotificationPolicy.Decision {
            policy.observe(taskID: task, sessionID: session, phase: phase, title: title,
                releasing: release, foreground: foreground, enabled: enabled)
        }
        expect(observe(a, "completed").event == nil, "Opening a saved completed record must never alert")
        expect(observe(a, "preparing").clearTaskID == a, "New attempt clears its own older prompts")
        expect(observe(a, "acting").event == nil, "Normal step changes do not notify")
        let approval = observe(a, "awaitingApproval").event!
        expect(approval.taskID == a && approval.executionID == run, "Task and attempt remain bound")
        expect(approval.taskTitle == "海棠通知", "Only first title line enters notification")
        for _ in 0..<8 {
            expect(observe(a, "awaitingApproval", session: UUID(), title: "改过标题").event == nil,
                "Repeated publications, changed titles and cancellation tokens cannot duplicate the same alert")
        }
        expect(observe(a, "acting").clearTaskID == a, "Continuing clears the superseded approval notice")
        let nextApproval = observe(a, "awaitingApproval").event!
        expect(nextApproval.id != approval.id, "A later distinct approval step can notify again")
        expect(observe(a, "failed", release: true).event == nil, "Release must settle before claiming a final state")
        let failure = observe(a, "failed", session: UUID()).event!
        expect(failure.kind == .failed && failure.executionID == run, "Release rotates control token without inventing a new attempt")
        expect(observe(a, "failed").event == nil, "The settled failure notifies once")
        _ = observe(a, "preparing", session: UUID())
        expect(observe(a, "completed", foreground: true).event == nil, "Foreground result is already visible")
        expect(observe(a, "completed", foreground: false).event == nil, "Leaving App does not replay a seen result")
        _ = observe(a, "preparing", session: UUID())
        expect(observe(a, "needsUser", enabled: false).event == nil, "Opt-out blocks notification")
        expect(observe(a, "needsUser", enabled: true).event == nil, "Enabling does not replay an old result")
        _ = observe(b, "preparing", session: UUID())
        expect(observe(a, "completed").event == nil, "Late old-task state cannot notify or acquire ownership")
        let needsUser = observe(b, "needsUser").event!
        expect(needsUser.taskID == b, "New task retains its identity")
        expect(observe(nil, "idle").clearTaskID == b, "Discarding a waiting task clears its prompt")
        for phase in ["paused", "stopped", "idle", "preview", "unknown"] {
            _ = observe(a, "preparing", session: UUID())
            expect(observe(a, phase).event == nil, "Manual/unknown state is not a completion notification")
        }
        let info = approval.userInfo
        expect(TaskNotificationEvent.taskID(identifier: approval.identifier, category: TaskNotificationEvent.category, userInfo: info) == a,
            "Exact notification route resolves its own task")
        expect(TaskNotificationEvent.taskID(identifier: approval.identifier, category: "other", userInfo: info) == nil, "Reject another category")
        expect(TaskNotificationEvent.taskID(identifier: nextApproval.identifier, category: TaskNotificationEvent.category, userInfo: info) == nil, "Reject changed event identifier")
        for (key, value) in [("schema", "2"), ("taskID", b.uuidString), ("eventID", "bad"), ("kind", "run")] {
            var modified = info; modified[key] = value
            expect(TaskNotificationEvent.taskID(identifier: approval.identifier, category: TaskNotificationEvent.category, userInfo: modified) == nil, "Reject mismatched routing data")
        }
        var extra = info; extra["execute"] = "true"
        expect(TaskNotificationEvent.taskID(identifier: approval.identifier, category: TaskNotificationEvent.category, userInfo: extra) == nil,
            "A notification cannot smuggle execution instructions")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sela-notification-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("journal.json")
        let journal = TaskNotificationJournal(url: file)
        expect(try journal.reserve(approval), "Reserve before submitting")
        expect(try !journal.reserve(approval), "Unknown prior submission cannot be repeated")
        expect(try !TaskNotificationJournal(url: file).reserve(approval), "Reservation survives process restart")
        let bytes = try Data(contentsOf: file)
        expect(!String(decoding: bytes, as: UTF8.self).contains("海棠"), "Journal never stores title, task text or response contents")
        for (name, data) in [("corrupt", Data("{broken".utf8)), ("future", Data("{\"version\":2,\"entries\":[]}".utf8))] {
            let target = folder.appendingPathComponent(name + ".json"); try data.write(to: target)
            let broken = TaskNotificationJournal(url: target)
            expect(!broken.error.isEmpty, "Unreadable/future journal exposes an actionable error")
            do { _ = try broken.reserve(approval); fatalError("Unreadable journal accepted a write") } catch { count += 1 }
            expect(try Data(contentsOf: target) == data, "Original journal must remain unchanged")
        }
        let capacity = folder.appendingPathComponent("capacity.json")
        let ids = (0..<512).map { _ in UUID() }
        let entries = ids.map { ["id": $0.uuidString, "taskID": a.uuidString, "executionID": run.uuidString, "kind": "completed"] }
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries]).write(to: capacity)
        let bounded = TaskNotificationJournal(url: capacity)
        expect(try bounded.reserve(approval), "A full valid journal accepts a new event")
        expect(bounded.totalReservations == 512, "Retention stays bounded")
        expect(TaskNotificationJournal(url: capacity).totalReservations == 512, "Bounded journal remains valid after restart")
        print("PASS: \(count) notification phase, ownership, opt-out, routing, durable reservation and bounded-retention checks")
    }
}
