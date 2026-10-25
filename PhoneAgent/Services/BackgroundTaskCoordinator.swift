import Foundation
import Combine

/// Isolated, tools-only execution. Screen automation keeps its single owner.
/// Queue/session authority exists only in this process; disk records are data.
@MainActor final class BackgroundTaskCoordinator: ObservableObject {
    struct Origin { let conversationID: UUID; let messageID: UUID }
    private final class Entry {
        var record: PhoneTaskRecord
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
        entries[record.id] = entry; order.append(record.id); publish(entry); pump()
        return record.id
    }
    @discardableResult func recover(_ record: PhoneTaskRecord, settings: AgentSettings, mode: TaskRecoveryMode) throws -> Bool {
        guard record.executionLane == "native", settings.systemToolsEnabled == true else { return false }
        guard token(record.id) != nil || sessions.count < 20 else { throw AgentError.message("后台任务过多，请先完成或停止部分任务") }
        guard !busy(record.id), !running(record.id) else { throw AgentError.message("这项后台任务仍在执行或结束中") }
        var native = settings; native.toolsOnly = true
        let oldOrigin = entries[record.id]?.origin
        let entry = Entry(record: record, settings: native, origin: oldOrigin, recovery: mode)
        entry.record.outcome = .running; entry.record.summary = "等待后台恢复名额"
        // Preserve the recoverable checkpoint outcome until the engine accepts it.
        entry.recovery = mode; entries[record.id] = entry
        if !order.contains(record.id) { order.append(record.id) }
        publish(entry); pump(recoveryRecord: record); return true
    }
    func pause(_ id: UUID, expected: UUID? = nil) throws {
        let entry = try checked(id, expected)
        entry.token = UUID(); entry.wantsRun = false
        if entry.engine?.running == true { entry.engine?.pause() }
        else { entry.record.outcome = .paused; entry.record.summary = "后台任务已暂停"; publish(entry) }
        pump()
    }
    func stop(_ id: UUID, expected: UUID? = nil) throws {
        let entry = try checked(id, expected)
        entry.token = UUID(); entry.wantsRun = false
        if let engine = entry.engine { engine.stop() }
        else { entry.record.outcome = .stopped; entry.record.summary = "后台任务已停止"; publish(entry) }
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
        if entry.engine == nil { entry.record.outcome = .running }
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
        try engine.amendTask(text); entry.token = UUID(); entry.wantsRun = true
        // Cancellation cleanup must settle before this same worker resumes.
        schedulePump()
    }
    private func checked(_ id: UUID, _ expected: UUID?) throws -> Entry {
        guard let entry = entries[id], let current = token(id), expected == nil || expected == current else {
            throw AgentError.message("这项后台任务状态已改变，请核对后重新发送")
        }
        return entry
    }
    private func publish(_ entry: Entry) {
        entry.record.executionLane = "native"
        records = order.compactMap { entries[$0]?.record }
        onRecord?(entry.record, entry.origin)
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
                engine.onRecord = { [weak self, weak entry] record in
                    guard let self, let entry, self.entries[id] === entry else { return }
                    entry.record = record; self.publish(entry); self.schedulePump()
                }
                engine.$releasing.removeDuplicates().sink { [weak self] _ in self?.schedulePump() }.store(in: &entry.observations)
            }
            guard let engine = entry.engine else { continue }
            if let mode = entry.recovery {
                var checkpoint = recoveryRecord?.id == id ? recoveryRecord! : entry.record
                if checkpoint.outcome == .running { checkpoint.outcome = .interrupted }
                do { try engine.recover(record: checkpoint, settings: entry.settings, mode: mode) }
                catch { entry.record.outcome = .failed; entry.record.summary = error.localizedDescription; publish(entry) }
                entry.recovery = nil
            } else if engine.currentRecord == nil {
                engine.start(task: entry.record.goal, settings: entry.settings, attachments: entry.record.attachments ?? [],
                    taskID: id, conversationReference: entry.record.conversationReference ?? "")
            } else { engine.resume(settings: entry.settings) }
            if engine.running { slots += 1 }
            else if engine.currentRecord == nil {
                entry.record.outcome = .failed; entry.record.summary = engine.error.isEmpty ? "后台执行器未启动" : engine.error; publish(entry)
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
