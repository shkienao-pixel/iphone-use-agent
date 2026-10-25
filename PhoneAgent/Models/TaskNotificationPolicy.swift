import Foundation

enum TaskNotificationKind: String, Codable, CaseIterable {
    case completed, failed, needsUser, awaitingApproval
    var title: String {
        switch self {
        case .completed: return "任务已完成"
        case .failed: return "任务执行中断"
        case .needsUser: return "任务需要你处理"
        case .awaitingApproval: return "任务等待你确认"
        }
    }
}

struct TaskNotificationEvent: Equatable {
    let id: UUID
    let taskID: UUID
    let executionID: UUID
    let kind: TaskNotificationKind
    let taskTitle: String
    static let category = "sela.task.v1"
    static let prefix = "sela.task."
    var identifier: String { Self.prefix + taskID.uuidString + "." + id.uuidString }
    var userInfo: [String: String] {
        ["schema": "1", "taskID": taskID.uuidString, "eventID": id.uuidString, "kind": kind.rawValue]
    }
    static func taskID(identifier: String, category: String, userInfo: [AnyHashable: Any]) -> UUID? {
        guard category == Self.category, userInfo.count == 4, userInfo["schema"] as? String == "1",
              let rawTask = userInfo["taskID"] as? String, let task = UUID(uuidString: rawTask),
              let rawEvent = userInfo["eventID"] as? String, let event = UUID(uuidString: rawEvent),
              let rawKind = userInfo["kind"] as? String, TaskNotificationKind(rawValue: rawKind) != nil,
              identifier == prefix + task.uuidString + "." + event.uuidString else { return nil }
        return task
    }
}

/// Phase edges are independent of mutable titles and cancellation control tokens.
/// Only an observed preparation establishes a live execution; archives cannot notify.
struct TaskNotificationPolicy {
    struct Decision {
        var event: TaskNotificationEvent?
        var clearTaskID: UUID?
        var invalidated = false
    }
    private var taskID: UUID?
    private var executionID: UUID?
    private var phase = ""
    private var pending: TaskNotificationEvent?
    private var consumed = false
    private var wasReleasing = false

    mutating func observe(taskID: UUID?, sessionID: UUID, phase: String, title: String,
                          releasing: Bool, foreground: Bool, enabled: Bool) -> Decision {
        guard let taskID else {
            let old = self.taskID
            let clear = pending != nil ? old : nil
            self = TaskNotificationPolicy()
            return Decision(clearTaskID: clear, invalidated: old != nil)
        }
        let newExecution = phase == "preparing" && (self.taskID != taskID || executionID != sessionID)
        guard newExecution || self.taskID == taskID else { return Decision() }
        let changed = newExecution || self.phase != phase
        let settled = wasReleasing && !releasing
        let previousPending = pending != nil
        if newExecution { self.taskID = taskID; executionID = sessionID }
        guard let executionID else { return Decision() }
        if changed {
            self.phase = phase; consumed = false
            pending = TaskNotificationKind(rawValue: phase).map {
                TaskNotificationEvent(id: UUID(), taskID: taskID, executionID: executionID, kind: $0,
                    taskTitle: String(title.components(separatedBy: .newlines).first?.prefix(80) ?? ""))
            }
        }
        wasReleasing = releasing
        var decision = Decision(clearTaskID: changed && (newExecution || previousPending || pending != nil) ? taskID : nil,
                                invalidated: changed || releasing)
        guard (changed || settled), let pending, !consumed, !releasing else { return decision }
        consumed = true
        // Enabling the setting or switching to background must not replay an old phase.
        if enabled && !foreground { decision.event = pending }
        return decision
    }
}

final class TaskNotificationJournal {
    struct Entry: Codable {
        let id: UUID
        let taskID: UUID
        let executionID: UUID
        let kind: TaskNotificationKind
    }
    private struct Document: Codable { var version = 1; var entries: [Entry] }
    private let url: URL
    private var entries: [Entry] = []
    private var readable = true
    private(set) var error = ""
    private(set) var totalReservations = 0
    init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 262_144 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url)
            guard data.count <= 262_144 else { throw CocoaError(.fileReadTooLarge) }
            let value = try JSONDecoder().decode(Document.self, from: data)
            guard value.version == 1, value.entries.count <= 512,
                  Set(value.entries.map(\.id)).count == value.entries.count else { throw CocoaError(.fileReadCorruptFile) }
            entries = value.entries; totalReservations = entries.count
        } catch {
            readable = false
            self.error = "通知记录暂时无法读取，原文件已保留；任务仍可在 App 中查看。"
        }
    }
    /// Reserve before submitting to the OS. An unknown submission is never retried.
    func reserve(_ event: TaskNotificationEvent) throws -> Bool {
        guard readable else { throw NSError(domain: "SelaTaskNotification", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        guard !entries.contains(where: { $0.id == event.id }) else { return false }
        let updated = Array((entries + [Entry(id: event.id, taskID: event.taskID, executionID: event.executionID, kind: event.kind)]).suffix(512))
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = folder; try excluded.setResourceValues(values)
            let bytes = try JSONEncoder().encode(Document(entries: updated))
            #if os(iOS)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try bytes.write(to: url, options: .atomic)
            #endif
            entries = updated; totalReservations = entries.count; error = ""
            return true
        } catch {
            self.error = "通知记录未能保存，本次提醒未提交；任务结果仍保留在 App 中。"
            throw NSError(domain: "SelaTaskNotification", code: 2, userInfo: [NSLocalizedDescriptionKey: self.error])
        }
    }
}
