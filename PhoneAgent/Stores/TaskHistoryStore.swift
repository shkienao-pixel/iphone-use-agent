import Foundation
import Combine

enum TaskOutcome: String, Codable {
    case running, paused, needsUser, completed, failed, stopped, interrupted, preview
    var label: String {
        switch self {
        case .running: return "进行中"
        case .paused: return "已暂停"
        case .needsUser: return "需要你处理"
        case .completed: return "已完成"
        case .failed: return "执行中断"
        case .stopped: return "已停止"
        case .interrupted: return "上次未结束"
        case .preview: return "已生成计划"
        }
    }
}
struct TaskAmendment: Identifiable, Codable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}

struct TaskSubtask: Identifiable, Codable {
    var id = UUID()
    var goal: String
    var completed = false
    var evidence: String? = nil
}

struct PhoneTaskRecord: Identifiable, Codable {
    var id = UUID()
    var title: String
    var goal: String
    var createdAt = Date()
    var updatedAt = Date()
    var outcome: TaskOutcome = .running
    var summary = "正在准备"
    var logs: [AgentLogEntry] = []
    // Optional so existing task files remain readable.
    var amendments: [TaskAmendment]? = nil
    var subtasks: [TaskSubtask]? = nil
    var effectiveGoal: String {
        let additions = (amendments ?? []).enumerated().map { "\($0.offset + 1). \($0.element.text)" }
        guard !additions.isEmpty else { return goal }
        return goal + "\n\n用户后续补充（与前文冲突时，以较新的明确要求为准）：\n" + additions.joined(separator: "\n")
    }
}

@MainActor
final class TaskHistoryStore: ObservableObject {
    @Published private(set) var records: [PhoneTaskRecord] = []
    @Published private(set) var error = ""
    private let url: URL
    private var readable = true
    private struct Document: Codable { var version = 1; var records: [PhoneTaskRecord] }
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent", isDirectory: true).appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
            guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
            records = Array(document.records.prefix(50)).map { record in
                var value = record
                if [.running, .paused, .needsUser].contains(value.outcome) {
                    value.outcome = .interrupted
                    value.summary = "上次任务未结束。请检查手机当前状态，再决定是否重新执行。"
                }
                return value
            }
        } catch {
            readable = false
            self.error = "历史记录暂时无法读取，原文件已保留。你仍可执行新任务。"
        }
    }
    func upsert(_ record: PhoneTaskRecord) {
        guard readable else { return }
        records.removeAll { $0.id == record.id }; records.insert(record, at: 0)
        records = Array(records.prefix(50)); save()
    }
    func rename(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].title = String(title.prefix(80)); save()
    }
    func remove(_ id: UUID) { records.removeAll { $0.id == id }; save() }
    func clear() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            records = []; readable = true; error = ""
        } catch { self.error = "未能删除历史记录，请稍后重试。" }
    }
    private func save() {
        guard readable else { return }
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = folder; try excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(Document(records: records))
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            error = ""
        } catch { self.error = "历史记录保存失败，请检查设备剩余空间。" }
    }
}
