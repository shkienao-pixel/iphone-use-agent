import Foundation
import Combine

/// Isolated, tools-only execution. Screen automation keeps its single owner.
/// Queue/session authority exists only in this process; disk records are data.
@MainActor final class BackgroundTaskCoordinator: ObservableObject {
    struct Origin { let conversationID: UUID; let messageID: UUID }
    private final class Entry {
        var record: PhoneTaskRecord
        var publishedRecord: PhoneTaskRecord?
        var persistenceFailed = false
        var token = UUID()
        var settings: AgentSettings
        var origin: Origin?
        var engine: AgentEngine?
        var wantsRun = true
        var recovery: TaskRecoveryMode?
        var observations = Set<AnyCancellable>()
        init(record: PhoneTaskRecord, settings: AgentSettings, origin: Origin?, recovery: TaskRecoveryMode? = nil) {
            self.record = record; self.settings = settings; self.origin = origin; self.recovery = recovery
        }
    }
    let maximumConcurrent: Int
    @Published private(set) var records: [PhoneTaskRecord] = []
    var persistRecord: ((PhoneTaskRecord) -> Bool)?
    var onRecord: ((PhoneTaskRecord, Origin?) -> Void)?
    private let makeEngine: (AgentSettings) -> AgentEngine
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var pumping = false
    init(maximumConcurrent: Int = 3, makeEngine: @escaping (AgentSettings) -> AgentEngine) {
        self.maximumConcurrent = min(3, max(1, maximumConcurrent)); self.makeEngine = makeEngine
    }
    var sessions: [UUID: UUID] {
        entries.compactMapValues { entry in
            [.completed, .stopped, .preview].contains(entry.record.outcome) ? nil : entry.token
        }
    }
    /// Cancellation may have set running=false while an SDK call is still
    /// settling. Maintenance must cover that window as well as queued workers.
    var hasUnsettledExecution: Bool {
        entries.values.contains { $0.wantsRun || $0.engine?.executionSettled == false }
    }
    /// Includes volatile paused checkpoints after a failed write. These records
    /// are only for an explicit durable retry, never proof of a committed UI state.
    var checkpointRecords: [PhoneTaskRecord] { order.compactMap { entries[$0]?.record } }
    /// The host calls this only immediately after its successful batch save.
    /// Match full immutable snapshots before acknowledging any entry. This
    /// updates committed projections, never tokens, queued work or execution.
    @discardableResult func acknowledgeSavedCheckpoints(_ persisted: [PhoneTaskRecord]) -> Bool {
        guard Set(persisted.map(\.id)).count == persisted.count else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var matched: [(entry: Entry, record: PhoneTaskRecord, identity: Data)] = []
        do {
            for record in persisted {
                guard let entry = entries[record.id] else { continue }
                let identity = try encoder.encode(record)
                guard identity == (try encoder.encode(entry.record)) else { return false }
                matched.append((entry, record, identity))
            }
        } catch { return false }
        guard !matched.isEmpty else { return true }
        for item in matched {
            item.entry.persistenceFailed = false; item.entry.publishedRecord = item.record
        }
        records = order.compactMap { entries[$0]?.publishedRecord }
        for item in matched {
            // A synchronous observer may have changed this task during the
            // projection update; do not deliver an obsolete host callback.
            guard entries[item.record.id] === item.entry,
                  (try? encoder.encode(item.entry.record)) == item.identity else { continue }
            onRecord?(item.record, item.entry.origin)
        }
        return true
    }
    func pauseAll() {
        for id in order where running(id) { try? pause(id) }
    }
    func contains(_ id: UUID) -> Bool { entries[id] != nil }
    func record(_ id: UUID) -> PhoneTaskRecord? { entries[id]?.record }
    func running(_ id: UUID) -> Bool { entries[id]?.engine?.running == true || entries[id]?.wantsRun == true }
    func busy(_ id: UUID) -> Bool { entries[id]?.engine?.releasing == true }
    func token(_ id: UUID) -> UUID? { sessions[id] }

    @discardableResult func submit(goal: String, settings: AgentSettings, attachments: [ComposerAttachment], reference: String, origin: Origin) throws -> UUID {
        guard settings.systemToolsEnabled == true else { throw AgentError.message("请先启用原生系统工具，再执行无需屏幕的任务") }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= 12000, reference.utf8.count <= 64_000 else { throw AgentError.message("任务要求或引用资料无效") }
        try ComposerAttachmentPolicy.validate(attachments)
        guard sessions.count < 20 else { throw AgentError.message("后台任务过多，请先完成或停止部分任务") }
        var record = PhoneTaskRecord(title: String(goal.prefix(36)), goal: goal,
            summary: "等待后台执行名额", attachments: attachments.isEmpty ? nil : attachments,
            conversationReference: reference.isEmpty ? nil : reference)
        record.executionLane = "native"
        var native = settings; native.toolsOnly = true
        let entry = Entry(record: record, settings: native, origin: origin)
        entries[record.id] = entry; order.append(record.id)
        guard publish(entry) else { throw checkpointSaveError }
        pump()
        return record.id
    }
    @discardableResult func recover(_ record: PhoneTaskRecord, settings: AgentSettings, mode: TaskRecoveryMode) throws -> Bool {
        guard record.executionLane == "native", settings.systemToolsEnabled == true else { return false }
        guard token(record.id) != nil || sessions.count < 20 else { throw AgentError.message("后台任务过多，请先完成或停止部分任务") }
        guard !busy(record.id), !running(record.id) else { throw AgentError.message("这项后台任务仍在执行或结束中") }
        var native = settings; native.toolsOnly = true
        let previousEntry = entries[record.id]
        let oldOrigin = previousEntry?.origin
        let entry = Entry(record: record, settings: native, origin: oldOrigin, recovery: mode)
        entry.publishedRecord = previousEntry?.publishedRecord
        entry.record.outcome = .running; entry.record.summary = "等待后台恢复名额"
        // Preserve the recoverable checkpoint outcome until the engine accepts it.
        entry.recovery = mode; entries[record.id] = entry
        if !order.contains(record.id) { order.append(record.id) }
        guard publish(entry) else { return false }
        pump(recoveryRecord: record); return true
    }
    func pause(_ id: UUID, expected: UUID? = nil) throws {
        let entry = try checked(id, expected)
        entry.token = UUID(); entry.wantsRun = false
        if entry.engine?.running == true { entry.engine?.pause() }
        else {
            entry.record.outcome = .paused; entry.record.summary = "后台任务已暂停"
            guard publish(entry) else { return }
        }
        guard !entry.persistenceFailed else { return }
        pump()
    }
    func stop(_ id: UUID, expected: UUID? = nil) throws {
        let entry = try checked(id, expected)
        entry.token = UUID(); entry.wantsRun = false
        if let engine = entry.engine { engine.stop() }
        else {
            entry.record.outcome = .stopped; entry.record.summary = "后台任务已停止"
            guard publish(entry) else { return }
        }
        guard !entry.persistenceFailed else { return }
        pump()
    }
    func resume(_ id: UUID, settings: AgentSettings? = nil, expected: UUID? = nil) throws {
        let entry = try checked(id, expected)
        guard !busy(id), !running(id), [.paused, .needsUser, .failed].contains(entry.record.outcome) else {
            throw AgentError.message("这项后台任务暂时不能继续，请核对其状态")
        }
        if var settings {
            guard settings.systemToolsEnabled == true else { throw AgentError.message("请先启用原生系统工具") }
            settings.toolsOnly = true; entry.settings = settings
        }
        entry.token = UUID(); entry.wantsRun = true
        entry.record.outcome = .running; entry.record.summary = "等待后台恢复名额"
        guard publish(entry) else { throw checkpointSaveError }
        pump()
    }
    func supplement(_ id: UUID, text: String, reference: String, settings: AgentSettings? = nil, expected: UUID? = nil) throws {
        let entry = try checked(id, expected)
        guard let engine = entry.engine else { throw AgentError.message("这项后台任务尚未启动，请先暂停或重新提交完整要求") }
        if var settings {
            guard settings.systemToolsEnabled == true else { throw AgentError.message("请先启用原生系统工具") }
            settings.toolsOnly = true; entry.settings = settings
        }
        guard engine.appendConversationReference(reference) else { throw AgentError.message("任务引用资料过长") }
        guard !entry.persistenceFailed else { throw checkpointSaveError }
        try engine.amendTask(text)
        guard !entry.persistenceFailed else { throw checkpointSaveError }
        entry.token = UUID(); entry.wantsRun = true
        // Cancellation cleanup must settle before this same worker resumes.
        schedulePump()
    }
    private func checked(_ id: UUID, _ expected: UUID?) throws -> Entry {
        guard let entry = entries[id], let current = token(id), expected == nil || expected == current else {
            throw AgentError.message("这项后台任务状态已改变，请核对后重新发送")
        }
        return entry
    }
    private var checkpointSaveError: AgentError {
        AgentError.message("后台任务记录未能保存，已暂停。请先重试保存记录，再明确继续任务。")
    }
    private func retainPersistenceFailure(_ entry: Entry, record: PhoneTaskRecord? = nil) {
        let alreadyFailing = entry.persistenceFailed
        if let record { entry.record = record }
        entry.record.executionLane = "native"
        entry.record.outcome = .paused
        entry.record.summary = checkpointSaveError.localizedDescription
        entry.persistenceFailed = true; entry.wantsRun = false; entry.token = UUID()
        // Cancellation is synchronous and is never held behind a failing disk.
        // Avoid re-entering pause when its own checkpoint callback also fails.
        if !alreadyFailing, entry.engine?.running == true { entry.engine?.pause() }
    }
    @discardableResult private func publish(_ entry: Entry, alreadyCommitted: Bool = false) -> Bool {
        entry.record.executionLane = "native"
        guard alreadyCommitted || (persistRecord?(entry.record) ?? true) else {
            retainPersistenceFailure(entry); return false
        }
        entry.persistenceFailed = false; entry.publishedRecord = entry.record
        // A different entry's successful update must not leak a volatile failed
        // checkpoint into this committed projection.
        records = order.compactMap { entries[$0]?.publishedRecord }
        onRecord?(entry.record, entry.origin)
        return true
    }
    private func schedulePump() {
        Task { [weak self] in await Task.yield(); self?.pump() }
    }
    private func pump(recoveryRecord: PhoneTaskRecord? = nil) {
        guard !pumping else { return }; pumping = true; defer { pumping = false }
        var slots = entries.values.filter { $0.engine.map { !$0.executionSettled } ?? false }.count
        for id in order {
            guard slots < maximumConcurrent, let entry = entries[id], entry.wantsRun,
                  entry.engine?.executionSettled != false else { continue }
            entry.wantsRun = false
            if entry.engine == nil {
                let engine = makeEngine(entry.settings); entry.engine = engine
                let engineCommit = engine.persistRecord
                if engineCommit != nil || persistRecord != nil {
                    engine.persistRecord = { [weak self, weak entry] record in
                        guard let self, let entry, self.entries[id] === entry else { return false }
                        var native = record; native.executionLane = "native"
                        return engineCommit?(native) ?? self.persistRecord?(native) ?? false
                    }
                }
                let existingFailure = engine.onPersistenceFailure
                engine.onPersistenceFailure = { [weak self, weak entry] record in
                    guard let self, let entry, self.entries[id] === entry else { return }
                    self.retainPersistenceFailure(entry, record: record)
                    existingFailure?(record)
                }
                engine.onRecord = { [weak self, weak entry, weak engine] record in
                    guard let self, let entry, self.entries[id] === entry else { return }
                    entry.record = record
                    guard self.publish(entry, alreadyCommitted: engine?.persistRecord != nil) else { return }
                    self.schedulePump()
                }
                engine.$releasing.removeDuplicates().sink { [weak self] _ in self?.schedulePump() }.store(in: &entry.observations)
            }
            guard let engine = entry.engine else { continue }
            if let mode = entry.recovery {
                var checkpoint = recoveryRecord?.id == id ? recoveryRecord! : entry.record
                if checkpoint.outcome == .running { checkpoint.outcome = .interrupted }
                do { try engine.recover(record: checkpoint, settings: entry.settings, mode: mode) }
                catch {
                    entry.record.outcome = .failed; entry.record.summary = error.localizedDescription
                    guard publish(entry) else { entry.recovery = nil; return }
                }
                entry.recovery = nil
            } else if engine.currentRecord == nil {
                engine.start(task: entry.record.goal, settings: entry.settings, attachments: entry.record.attachments ?? [],
                    taskID: id, conversationReference: entry.record.conversationReference ?? "")
            } else { engine.resume(settings: entry.settings) }
            if entry.persistenceFailed { return }
            if engine.running { slots += 1 }
            else if engine.currentRecord == nil {
                entry.record.outcome = .failed; entry.record.summary = engine.error.isEmpty ? "后台执行器未启动" : engine.error
                guard publish(entry) else { return }
            }
        }
        // Completed workers retain no input authority. Keep a bounded card cache.
        if order.count > 50 {
            for id in order where order.count > 50 {
                if let entry = entries[id], token(id) == nil, entry.engine?.executionSettled != false {
                    entries.removeValue(forKey: id); order.removeAll { $0 == id }
                }
            }
        }
    }
}
