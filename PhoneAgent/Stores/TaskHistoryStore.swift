import Foundation
import Combine

enum TaskOutcome: String, Codable {
    case running, paused, needsUser, completed, failed, stopped, interrupted, preview
    /// The existing recovery contract includes stopped/failed tasks. Display
    /// retention must never discard their exact checkpoints without an explicit
    /// user deletion; loading a checkpoint still grants no execution authority.
    var retainsRecoveryCheckpoint: Bool {
        switch self {
        case .completed, .preview: return false
        default: return true
        }
    }
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
    // Actual completed native results for conversation cards; absent in old records.
    var nativeResults: [NativeTaskResult]? = nil
    /// Optional for backward-compatible version-one archives. A model's finish
    /// proposal is distinct from independently checked task completion.
    var completionEvidence: TaskCompletionEvidence? = nil
    var nativeConversationSnapshot: NativeTaskSnapshot? {
        NativeTaskSnapshot(taskID: id, title: title, summary: summary, outcome: outcome.rawValue,
                           updatedAt: updatedAt, results: nativeResults ?? [])
    }
    // Optional so existing task files remain readable.
    var amendments: [TaskAmendment]? = nil
    var subtasks: [TaskSubtask]? = nil
    // Optional so existing history and queue documents remain readable.
    var contextMemory: TaskContextMemory? = nil
    var attachments: [ComposerAttachment]? = nil
    /// Same-conversation source excerpts selected during intent resolution.
    /// Reference data only; goal/amendments and verified receipts keep authority.
    var conversationReference: String? = nil
    /// Scheduling provenance only; never restores an execution session or tool authority.
    var executionLane: String? = nil
    // Optional checkpoints preserve an interrupted attempt's exact action
    // budget without restoring any process-local execution authority.
    var checkpointStep: Int? = nil
    var attemptStartStep: Int? = nil
    var validConversationReference: Bool { (conversationReference?.utf8.count ?? 0) <= 64_000 }
    var effectiveGoal: String {
        let additions = (amendments ?? []).enumerated().map { "\($0.offset + 1). \($0.element.text)" }
        guard !additions.isEmpty else { return goal }
        return goal + "\n\n用户后续补充（与前文冲突时，以较新的明确要求为准）：\n" + additions.joined(separator: "\n")
    }
}

/// One repository policy for both legacy archive loading and new commits.
/// Recoverable checkpoints are durable working state, independent of the
/// bounded completed/preview history shown beside them.
enum TaskHistoryRetentionPolicy {
    static let maximumFinishedRecords = 50
    static func retained(_ records: [PhoneTaskRecord]) -> [PhoneTaskRecord] {
        var finished = 0
        return records.filter { record in
            if record.outcome.retainsRecoveryCheckpoint { return true }
            finished += 1
            return finished <= maximumFinishedRecords
        }
    }
}

/// A local snapshot, with retention limits kept beside the actual saved record.
/// Exporting does not consult a model or restore any execution authority.
enum TaskRecordExport {
    struct Coverage: Codable {
        let scope: String
        let fullHistoricalTranscriptGuaranteed: Bool
        let rawLogCount: Int
        let firstRawLogStep: Int?
        let lastRawLogStep: Int?
        let compactedSourceEntryCount: Int
        let retainedCompactedEntryCount: Int
        let truncatedCompactedCharacters: Int
        let notIncluded: [String]
    }
    struct Document: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let dateEncoding: String
        let coverage: Coverage
        let record: PhoneTaskRecord
    }
    static func data(record: PhoneTaskRecord, exportedAt: Date = Date()) throws -> Data {
        let coverage = Coverage(scope: "retained_task_snapshot", fullHistoricalTranscriptGuaranteed: false,
            rawLogCount: record.logs.count, firstRawLogStep: record.logs.map(\.step).min(),
            lastRawLogStep: record.logs.map(\.step).max(),
            compactedSourceEntryCount: record.contextMemory?.compactedEntryCount ?? 0,
            retainedCompactedEntryCount: record.contextMemory?.retainedEntryCount ?? 0,
            truncatedCompactedCharacters: record.contextMemory?.truncatedCharacterCount ?? 0,
            notIncluded: ["已压缩或被覆盖日志的完整原文", "附件及保存产物的原文件", "独立系统核验结果",
                          "单独保存的工具提交回执账本与运行计时文件"])
        let document = Document(schemaVersion: 1, exportedAt: exportedAt,
            dateEncoding: "seconds_since_2001-01-01T00:00:00Z", coverage: coverage, record: record)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
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
            guard (try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
            guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
            for record in document.records {
                try ComposerAttachmentPolicy.validate(record.attachments ?? [])
                guard record.validConversationReference else { throw CocoaError(.fileReadCorruptFile) }
            }
            records = TaskHistoryRetentionPolicy.retained(document.records).map { record in
                var value = record
                if [.running, .paused, .needsUser].contains(value.outcome) {
                    value.outcome = .interrupted
                    value.summary = "上次任务未结束。请检查手机当前状态，再决定是否重新执行。"
                }
                return value
            }
        } catch {
            readable = false
            self.error = "历史记录暂时无法读取，原文件已保留。请先导出并处理存储问题，再执行任务。"
        }
    }
    /// Success means the exact checkpoint has reached durable storage. Callers
    /// must pause before further side effects when this returns false.
    @discardableResult
    func upsert(_ record: PhoneTaskRecord) -> Bool {
        saveCheckpoints([record])
    }
    /// Explicitly retry current checkpoints in one durable transaction. This
    /// only saves data; it never grants execution authority or resumes engines.
    /// An empty batch retries the last readable repository snapshot.
    @discardableResult
    func saveCheckpoints(_ updates: [PhoneTaskRecord]) -> Bool {
        guard readable else { return false }
        do {
            guard Set(updates.map(\.id)).count == updates.count else { throw CocoaError(.fileReadCorruptFile) }
            for record in updates {
                try ComposerAttachmentPolicy.validate(record.attachments ?? [])
                guard record.validConversationReference else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        catch { self.error = error.localizedDescription; return false }
        let identities = Set(updates.map(\.id))
        let updated = updates + records.filter { !identities.contains($0.id) }
        return commit(TaskHistoryRetentionPolicy.retained(updated))
    }
    @discardableResult
    func rename(_ id: UUID, title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard readable, !title.isEmpty, let index = records.firstIndex(where: { $0.id == id }) else { return false }
        var updated = records
        updated[index].title = String(title.prefix(80))
        return commit(updated)
    }
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard readable else { return false }
        return commit(records.filter { $0.id != id })
    }
    func clear() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            records = []; readable = true; error = ""
        } catch { self.error = "未能删除历史记录，请稍后重试。" }
    }
    /// No published record changes before the atomic checkpoint commit. A
    /// failed write leaves both the previous in-memory snapshot and file intact.
    private func commit(_ updated: [PhoneTaskRecord]) -> Bool {
        guard readable else { return false }
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = folder; try excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(Document(records: updated))
            guard data.count <= 64_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            records = updated; error = ""
            return true
        } catch {
            self.error = "历史记录保存失败，未发布新的检查点。请检查设备剩余空间后重试。"
            return false
        }
    }
}
