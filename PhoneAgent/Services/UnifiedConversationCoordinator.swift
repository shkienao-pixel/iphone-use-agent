import Foundation
import UIKit

@MainActor extension PhoneAgentViewModel {
    func unifiedTaskContext(history messages: [AssistantMessage], question: String? = nil) -> String {
        // Recent verbatim turns stay separate from task records. Only task IDs
        // already linked to this thread, its focused task, and the active task
        // are eligible. A different thread's old goals never become instructions.
        let active = engine.hasCurrentTask ? engine.currentRecord : nil
        let background = backgroundTasks.records.filter { backgroundTasks.token($0.id) != nil }
        let activeIDs = Set(background.map(\.id) + [active?.id].compactMap { $0 })
        let ids = Set(messages.compactMap(\.taskID) + [unifiedFocusedTaskID].compactMap { $0 }).union(activeIDs)
        var records = history.records.filter { ids.contains($0.id) && !activeIDs.contains($0.id) }
        records = Array(records.prefix(3))
        records.insert(contentsOf: background, at: 0)
        if let active { records.insert(active, at: 0) }
        // Every active/queued task retains its real ID. Compact rows leave room
        // for travel references without dropping a worker from intent routing.
        let compact = records.count > 3
        let data = records.map { record -> [String: String] in
            let receipts = record.logs.last(where: { $0.title == "工具回执" })?.detail ?? ""
            return ["id": record.id.uuidString, "goal": ConversationReferenceText.excerpt(record.effectiveGoal, characters: compact ? 160 : 1000, jsonCharacters: compact ? 240 : 1600), "status": record.outcome.rawValue,
                    "summary": ConversationReferenceText.excerpt(record.summary, characters: compact ? 120 : 1000, jsonCharacters: compact ? 180 : 1600), "verifiedToolReceipts": ConversationReferenceText.excerpt(receipts, characters: compact ? 180 : 1800, jsonCharacters: compact ? 260 : 2600),
                    "active": String(activeIDs.contains(record.id)), "execution": record.executionLane ?? "screen",
                    "detailsOmitted": String(compact)]
        }
        let search = CtripFlightSearchContext.latest(in: messages)
        let positions = search?.referencePositions(question: question) ?? []
        let offers = search.map { search in positions.map { search.offers[$0 - 1] } } ?? []
        let expanded = offers.count > 6
        let crowded = offers.count > 12
        // Keep existing budgets through twelve cards. For thirteen to twenty-four,
        // fields total at most 56,640 JSON characters, leaving room for IDs,
        // flight numbers and structure below the independent 64,000 cap. The
        // complete search query stays shared above the shorter per-card excerpts.
        var payload: [String: Any] = ["tasks": data,
            "paotuiConversationActive": messages.last(where: { $0.role == "assistant" })?.paotuiCard != nil,
            "flightSearch": search.map { ["query": ConversationReferenceText.excerpt($0.query, characters: 4000, jsonCharacters: 4200),
                "queriedAt": ISO8601DateFormatter().string(from: $0.queriedAt), "resultCount": $0.offers.count,
                "referenceCount": offers.count, "referencesOmitted": offers.count < $0.offers.count,
                "omittedReferenceCount": $0.offers.count - offers.count] as [String: Any] } ?? NSNull(),
            "flightOffers": offers.enumerated().map { index, offer -> [String: Any] in
            var flightNumbers: [String] = [], remaining = offer.title[...]
            while flightNumbers.count < 4, let match = remaining.range(of: #"\b[A-Z0-9]{2}\d{3,4}\b"#, options: .regularExpression) {
                flightNumbers.append(String(remaining[match])); remaining = remaining[match.upperBound...]
            }
            return ["position": positions[index], "sourceKind": offer.isSchedule ? "schedule_reference" : "quoted_fare", "title": ConversationReferenceText.excerpt(offer.title, characters: crowded ? 160 : expanded ? 200 : 400, jsonCharacters: crowded ? 320 : expanded ? 400 : 800), "flightNumbers": flightNumbers,
             "query": ConversationReferenceText.excerpt(offer.query, characters: crowded ? 120 : expanded ? 500 : 4000, jsonCharacters: crowded ? 240 : expanded ? 800 : 4200),
             "details": ConversationReferenceText.excerpt(offer.details, characters: expanded ? 600 : 1000, jsonCharacters: crowded ? 900 : expanded ? 1000 : 1600),
             "queriedAt": String(ISO8601DateFormatter().string(from: offer.queriedAt).prefix(40))]
        }]
        func encoded() -> String? {
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
        guard var text = encoded() else { return "{}" }
        if text.count > 64_000 || text.utf8.count > 250_000 || (compact && text.utf8.count > 64_000) {
            func limited(_ value: String, bytes limit: Int) -> String {
                var count = min(value.count, limit / 4)
                while count > 0 {
                    let candidate = ConversationReferenceText.excerpt(value, characters: count, jsonCharacters: limit)
                    if let bytes = try? JSONSerialization.data(withJSONObject: candidate, options: [.fragmentsAllowed]), bytes.count <= limit { return candidate }
                    count /= 2
                }
                return ""
            }
            // Compact reference copies only. Original goals, messages, task
            // records and card contents remain intact in their owning stores.
            payload["tasks"] = records.map { record in
                ["id": record.id.uuidString, "goal": limited(record.effectiveGoal, bytes: 180),
                 "status": record.outcome.rawValue, "active": String(activeIDs.contains(record.id)),
                 "execution": record.executionLane ?? "screen", "detailsOmitted": "true"]
            }
            if let rows = payload["flightOffers"] as? [[String: Any]] {
                payload["flightOffers"] = rows.map { row in
                    var short = row
                    for key in ["title", "query", "details"] {
                        if let value = row[key] as? String { short[key] = limited(value, bytes: key == "details" ? 600 : 220) }
                    }
                    short["detailsOmitted"] = true; return short
                }
            }
            // Keep the shared search constraints intact. Card excerpts may
            // shrink, but dates, passengers and ending constraints must not.
            payload["contextDetailsOmitted"] = true
            payload["taskDetailsOmittedCount"] = records.count
            payload["flightDetailsOmittedCount"] = offers.count
            text = encoded() ?? "{}"
        }
        return text
    }
    /// Reuse is an editable new conversation, never authority to replay a record.
    @discardableResult
    func reuseTaskInNewConversation(_ record: PhoneTaskRecord) -> Bool {
        let text = record.effectiveGoal
        let attachments = record.attachments ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4000 else {
            notice = "原任务内容超过对话输入范围，请在任务详情选择要重新处理的要求。"
            return false
        }
        do { try ComposerAttachmentPolicy.validate(attachments) }
        catch { notice = error.localizedDescription; return false }
        conversation.newConversation()
        conversation.draft = text
        conversation.retainDraftAttachments(attachments, conversationID: conversation.currentConversationID)
        notice = ""
        return true
    }
    func handleConversationAction(_ route: ConversationRoute, messageID: UUID) {
        let origin = route.originConversationID ?? conversation.currentConversationID
        if route.controlsTask, let target = route.taskID, backgroundTasks.token(target) != nil {
            guard let token = route.backgroundControlToken, token == backgroundTasks.token(target) else {
                notice = "这项后台任务状态已改变，请核对后重新发送"; return
            }
            if [.resume, .supplement].contains(route.mode), tools.hasUnresolvedWrite(taskID: target) {
                notice = "这项后台任务有未核验的写入，请先核对实际结果后再继续"; return
            }
            do {
                switch route.mode {
                case .pause: try backgroundTasks.pause(target, expected: token)
                case .stop: try backgroundTasks.stop(target, expected: token)
                case .resume: try backgroundTasks.resume(target, settings: settings, expected: token)
                case .supplement: try backgroundTasks.supplement(target, text: route.request, reference: route.executionReference, settings: settings, expected: token)
                default: return
                }
                conversation.linkTask(target, to: messageID, in: origin); notice = ""
            } catch { notice = error.localizedDescription }
            return
        }
        if route.controlsTask {
            guard route.backgroundControlToken == nil, let context = route.controlContext, context == conversationControlContext else {
                notice = "任务状态已改变，请核对当前任务后重新发送"; return
            }
        }
        switch route.mode {
        case .task:
            if route.execution == .native || (route.execution == nil && settings.toolsOnly == true) {
                guard modelReady, consentReady else {
                    notice = "请先核对模型配置与数据授权，后台任务尚未启动"
                    conversation.reportTaskHandoff(text: notice, to: messageID, in: origin); return
                }
                do {
                    let id = try backgroundTasks.submit(goal: route.request, settings: settings, attachments: route.attachments,
                        reference: route.executionReference, origin: .init(conversationID: origin, messageID: messageID))
                    conversation.linkTask(id, to: messageID, in: origin)
                    conversation.reportTaskHandoff(text: "已创建独立后台任务，可在等待时继续对话或新建任务。", to: messageID, in: origin, onlyIfUnlinked: false)
                    notice = ""
                } catch {
                    notice = error.localizedDescription
                    conversation.reportTaskHandoff(text: "后台任务未启动：" + notice, to: messageID, in: origin)
                }
                return
            }
            guard !route.request.isEmpty, pendingConversationTask == nil, !preparingAutomatically, !queueSwitching, !manualBusy, !calibrating, !engine.releasing else {
                notice = route.request.isEmpty ? "任务内容为空，请补充具体要求" :
                    pendingConversationTask != nil ? "上一条执行请求仍在等待启动回执，请先处理该请求" : "设备正在切换或处理其他操作，请稍后重试"
                conversation.reportTaskHandoff(text: "任务未启动：" + notice, to: messageID, in: origin)
                return
            }
            if engine.hasCurrentTask || queueRunning || !screenQueueWaiting.isEmpty || !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let id = queueConversationScreenTask(route) {
                    let linked = conversation.linkTask(id, to: messageID, in: origin)
                    conversation.reportTaskHandoff(text: linked ? "已加入任务队列，尚未开始执行。" : "已加入任务队列，任务卡暂未关联，请在队列查看；尚未开始执行。",
                        to: messageID, in: origin, onlyIfUnlinked: false)
                } else {
                    conversation.reportTaskHandoff(text: "任务未启动，也未加入队列：" + (notice.isEmpty ? "队列没有接收这次请求，请检查后重新发送。" : notice),
                        to: messageID, in: origin)
                }
            } else {
                goal = route.request
                let submission = ConversationTaskSubmission(conversationID: origin, messageID: messageID, goal: route.request, reference: route.executionReference)
                pendingConversationTask = submission
                let started = startAgent(attachments: route.attachments, conversationTask: submission)
                if started {
                    conversation.reportTaskHandoff(text: "已交给执行器，正在等待任务启动回执。", to: messageID, in: origin)
                } else if preparingAutomatically, pendingConversationTask == submission {
                    conversation.reportTaskHandoff(text: "正在准备设备，任务尚未开始执行。", to: messageID, in: origin)
                } else if showPrivacyConsent, pendingConversationTask == submission, !consentReady {
                    conversation.reportTaskHandoff(text: "正在等待已有的数据使用授权，任务尚未启动。", to: messageID, in: origin)
                } else {
                    conversation.reportTaskHandoff(text: "任务未启动：" + (notice.isEmpty ? "执行器没有接收这次请求，请检查准备状态后重新发送。" : notice),
                        to: messageID, in: origin)
                }
            }
        case .supplement:
            guard route.taskID == nil || route.taskID == engine.currentRecord?.id else { notice = "请指定当前要补充的任务"; return }
            guard engine.hasCurrentTask else { notice = "原任务已结束，请说明要新执行什么"; return }
            guard engine.appendConversationReference(route.executionReference) else { notice = "任务引用资料过长，请重新说明补充要求"; return }
            let previous = engine.currentRecord?.amendments?.count ?? 0
            _ = supplementTask(route.request)
            guard (engine.currentRecord?.amendments?.count ?? 0) > previous else { return }
            if let id = engine.currentRecord?.id { conversation.linkTask(id, to: messageID, in: origin) }
            let context = conversationControlContext
            Task {
                _ = await resumeVoiceTask(expectedContext: context)
            }
        case .resume:
            if let target = route.taskID, recoverableTask(target)?.executionLane == "native" {
                if continueTask(target) { conversation.linkTask(target, to: messageID, in: origin) }
                return
            }
            if let target = route.taskID, target != engine.currentRecord?.id || !engine.hasCurrentTask {
                if let queued = taskQueue.items.first(where: { $0.id == target }) {
                    guard queued.resumable else { notice = "这项任务没有可继续的进度"; return }
                    if resumeScreenQueueTask(target) { conversation.linkTask(target, to: messageID, in: origin) }; return
                }
                let referenced = engine.currentRecord?.id == target || unifiedFocusedTaskID == target ||
                    conversation.messages.contains { $0.taskID == target }
                guard referenced, recoverableTask(target) != nil else { notice = "这项任务没有可继续的进度"; return }
                // Use the same guarded recovery as the history card. It keeps
                // task identity, progress and uncertain-write checks, and
                // refuses replacing a different active execution.
                if continueTask(target) { conversation.linkTask(target, to: messageID, in: origin) }
                return
            }
            guard engine.hasCurrentTask else { notice = "当前没有可继续的任务，请说明新任务"; return }
            if let id = engine.currentRecord?.id { conversation.linkTask(id, to: messageID, in: origin) }
            let context = conversationControlContext
            Task {
                _ = await resumeVoiceTask(expectedContext: context)
            }
        case .pause:
            guard route.taskID == nil || (engine.hasCurrentTask && route.taskID == engine.currentRecord?.id) else { notice = "要暂停的不是当前任务"; return }
            if let id = engine.currentRecord?.id { conversation.linkTask(id, to: messageID, in: origin) }
            _ = pauseTask()
        case .stop:
            guard route.taskID == nil || (engine.hasCurrentTask && route.taskID == engine.currentRecord?.id) else { notice = "这项任务不是当前执行的任务，未停止其他任务"; return }
            if let id = engine.currentRecord?.id { conversation.linkTask(id, to: messageID, in: origin) }
            stop()
        default: break
        }
    }
    /// A late route owns its own queue record. It must neither overwrite the
    /// user's new draft nor borrow a different draft's structured subtask plan.
    func queueConversationScreenTask(_ route: ConversationRoute) -> UUID? {
        let record = PhoneTaskRecord(title: String(route.request.prefix(36)), goal: route.request,
            outcome: .paused, summary: "已加入队列，尚未执行",
            attachments: route.attachments.isEmpty ? nil : route.attachments,
            conversationReference: route.executionReference.isEmpty ? nil : route.executionReference)
        do {
            try taskQueue.append(QueuedPhoneTask(record: record, settings: settings))
            notice = "已加入队列。点“运行队列”后依次执行。"; return record.id
        } catch { notice = error.localizedDescription; return nil }
    }
    /// Resolve legacy calls only from a current chat link or the explicitly focused task.
    func bookFlight(_ offer: CtripFlightOffer) {
        if let message = conversation.messages.last(where: { flightHandoffOffers(for: $0).contains(offer) }) {
            bookFlight(offer, origin: CtripFlightHandoffOrigin(conversationID: conversation.currentConversationID, messageID: message.id))
        } else if let taskID = unifiedFocusedTaskID, flightHandoffTaskOffers(taskID).contains(offer) {
            bookFlight(offer, taskID: taskID, conversationID: conversation.currentConversationID,
                       isVisible: { [weak self] in self?.unifiedFocusedTaskID == taskID })
        } else { notice = "所选航班已变化，请重新选择" }
    }
    func bookFlight(_ offer: CtripFlightOffer, origin: CtripFlightHandoffOrigin,
                    isVisible: @escaping @MainActor () -> Bool = { true }) {
        startFlightHandoff(offer, origin: origin, isVisible: isVisible)
    }
    func bookFlight(_ offer: CtripFlightOffer, taskID: UUID, conversationID: UUID, isVisible: @escaping @MainActor () -> Bool) {
        startFlightHandoff(offer, origin: CtripFlightHandoffOrigin(conversationID: conversationID, taskID: taskID), isVisible: isVisible)
    }
    private func startFlightHandoff(_ offer: CtripFlightOffer, origin: CtripFlightHandoffOrigin, isVisible: @escaping @MainActor () -> Bool) {
        guard isVisible(), let snapshot = flightHandoffSnapshot(offer, origin: origin) else {
            CtripFlightHandoffCoordinator.shared.reject(origin: origin, offer: offer)
            if isVisible(), conversation.currentConversationID == origin.conversationID { notice = "所选航班已变化，请重新选择" }
            return
        }
        let operations = CtripFlightUIKitHandoffOperations(model: self, isVisible: isVisible)
        Task { _ = await CtripFlightHandoffCoordinator.shared.perform(snapshot, operations: operations) }
    }
    fileprivate func flightHandoffSnapshot(_ offer: CtripFlightOffer, origin: CtripFlightHandoffOrigin) -> CtripFlightHandoffSnapshot? {
        guard conversation.currentConversationID == origin.conversationID else { return nil }
        if let taskID = origin.taskID {
            return CtripFlightHandoffSnapshot.captureTask(offer, origin: origin, currentConversationID: conversation.currentConversationID,
                                                         taskID: taskID, offers: flightHandoffTaskOffers(taskID))
        }
        guard let message = conversation.messages.first(where: { $0.id == origin.messageID }) else { return nil }
        return CtripFlightHandoffSnapshot.capture(offer, origin: origin, currentConversationID: conversation.currentConversationID,
                                                 message: message, offers: flightHandoffOffers(for: message))
    }
    fileprivate func flightHandoffOffers(for message: AssistantMessage) -> [CtripFlightOffer] {
        var offers = conversation.flightOffers(for: message)
        if let taskID = message.taskID { offers += flightHandoffTaskOffers(taskID) }
        return offers
    }
    private func flightHandoffTaskOffers(_ taskID: UUID) -> [CtripFlightOffer] {
        // Only the explicitly supplied/focused task is read; never search other
        // history records for a matching fare or inherit permission to run them.
        guard let record = (engine.currentRecord?.id == taskID ? engine.currentRecord : nil) ??
                history.records.first(where: { $0.id == taskID }) ?? taskQueue.items.first(where: { $0.id == taskID })?.record else { return [] }
        return record.logs.filter { $0.title == "工具回执" && $0.detail.hasPrefix("来源：携程") }
            .flatMap { CtripFlightParser.offers($0.detail, query: record.goal, at: record.updatedAt) }
    }
}

struct CtripFlightHandoffOrigin: Equatable, Sendable {
    let conversationID: UUID
    let messageID: UUID?
    let taskID: UUID?
    init(conversationID: UUID, messageID: UUID) {
        self.conversationID = conversationID; self.messageID = messageID; taskID = nil
    }
    init(conversationID: UUID, taskID: UUID) {
        self.conversationID = conversationID; messageID = nil; self.taskID = taskID
    }
}

struct CtripFlightHandoffSnapshot: Equatable, Sendable {
    let origin: CtripFlightHandoffOrigin
    let offer: CtripFlightOffer
    let clipboardText: String
    var specificURL: URL? { offer.flightSpecificBookingURL }

    static func capture(_ offer: CtripFlightOffer, origin: CtripFlightHandoffOrigin,
                        currentConversationID: UUID, message: AssistantMessage?, offers: [CtripFlightOffer]) -> Self? {
        guard currentConversationID == origin.conversationID, origin.messageID != nil, origin.taskID == nil, message?.id == origin.messageID,
              let selected = offers.first(where: { $0 == offer }) else { return nil }
        return Self(origin: origin, offer: selected, clipboardText: selected.bookingSummary)
    }
    static func captureTask(_ offer: CtripFlightOffer, origin: CtripFlightHandoffOrigin,
                            currentConversationID: UUID, taskID: UUID, offers: [CtripFlightOffer]) -> Self? {
        guard currentConversationID == origin.conversationID, origin.messageID == nil, origin.taskID == taskID,
              let selected = offers.first(where: { $0 == offer }) else { return nil }
        return Self(origin: origin, offer: selected, clipboardText: selected.bookingSummary)
    }
}

enum CtripFlightHandoffStage: String, Sendable { case snapshot, clipboard, specificEntry, generalEntry, finished }
enum CtripFlightClipboardResult: String, Sendable { case notAttempted, prepared, failed }
/// Accepted means only that the OS accepted the app entry. It proves no prefill or order.
enum CtripFlightEntryResult: String, Sendable { case notAttempted, accepted, unavailable, failed }
enum CtripFlightHandoffOutcome: String, Sendable {
    case preparing, clipboardPrepared, specificAccepted, generalAccepted, unavailable, failed, busy, originChanged
}

struct CtripFlightHandoffReceipt: Equatable, Sendable {
    let origin: CtripFlightHandoffOrigin
    let isSchedule: Bool
    var stage = CtripFlightHandoffStage.snapshot
    var clipboard = CtripFlightClipboardResult.notAttempted
    var specificEntry = CtripFlightEntryResult.notAttempted
    var generalEntry = CtripFlightEntryResult.notAttempted
    var outcome = CtripFlightHandoffOutcome.preparing

    init(snapshot: CtripFlightHandoffSnapshot) {
        origin = snapshot.origin; isSchedule = snapshot.offer.isSchedule
    }
    init(origin: CtripFlightHandoffOrigin, offer: CtripFlightOffer) {
        self.origin = origin; isSchedule = offer.isSchedule
    }
    var notice: String? {
        let subject = isSchedule ? "参考时刻" : "航班信息"
        switch outcome {
        case .specificAccepted, .generalAccepted:
            return isSchedule ? "参考时刻已复制，请在携程查价并核对航班" : "航班信息已复制，请在携程核对并选票"
        case .unavailable: return subject + "已复制，请安装携程旅行 App 后继续选票"
        case .failed:
            return clipboard == .prepared ? subject + "已复制，暂时无法打开携程，请稍后重试" : "未能准备航班信息剪贴板，请重试"
        case .busy: return "正在准备携程交接，请稍候"
        case .preparing, .clipboardPrepared, .originChanged: return nil
        }
    }
}

@MainActor protocol CtripFlightHandoffOperations: AnyObject {
    func originIsCurrent(_ snapshot: CtripFlightHandoffSnapshot) -> Bool
    func prepareClipboard(_ text: String) -> Bool
    func canOpenGeneralEntry() -> Bool
    func openSpecificEntry(_ url: URL) async -> Bool
    func openGeneralEntry() async -> Bool
    func publish(_ receipt: CtripFlightHandoffReceipt, for snapshot: CtripFlightHandoffSnapshot)
}

@MainActor final class CtripFlightHandoffCoordinator {
    static let shared = CtripFlightHandoffCoordinator()
    private(set) var isRunning = false
    private(set) var lastReceipt: CtripFlightHandoffReceipt?

    func reject(origin: CtripFlightHandoffOrigin, offer: CtripFlightOffer) {
        var receipt = CtripFlightHandoffReceipt(origin: origin, offer: offer)
        receipt.stage = .finished; receipt.outcome = .originChanged
        lastReceipt = receipt
    }
    private func finish(_ result: CtripFlightHandoffReceipt, snapshot: CtripFlightHandoffSnapshot,
                        operations: any CtripFlightHandoffOperations) -> CtripFlightHandoffReceipt {
        var receipt = result
        receipt.stage = .finished
        if !operations.originIsCurrent(snapshot) { receipt.outcome = .originChanged }
        lastReceipt = receipt
        if receipt.outcome != .originChanged { operations.publish(receipt, for: snapshot) }
        return receipt
    }
    func perform(_ snapshot: CtripFlightHandoffSnapshot, operations: any CtripFlightHandoffOperations) async -> CtripFlightHandoffReceipt {
        var receipt = CtripFlightHandoffReceipt(snapshot: snapshot)
        guard operations.originIsCurrent(snapshot) else {
            receipt.outcome = .originChanged
            return finish(receipt, snapshot: snapshot, operations: operations)
        }
        guard !isRunning else {
            receipt.outcome = .busy
            return finish(receipt, snapshot: snapshot, operations: operations)
        }
        isRunning = true
        defer { isRunning = false }
        lastReceipt = receipt
        receipt.stage = .clipboard
        guard operations.prepareClipboard(snapshot.clipboardText) else {
            receipt.clipboard = .failed; receipt.outcome = .failed
            return finish(receipt, snapshot: snapshot, operations: operations)
        }
        receipt.clipboard = .prepared; receipt.outcome = .clipboardPrepared
        lastReceipt = receipt
        guard operations.originIsCurrent(snapshot) else {
            receipt.outcome = .originChanged
            return finish(receipt, snapshot: snapshot, operations: operations)
        }
        if let url = snapshot.specificURL {
            receipt.stage = .specificEntry; lastReceipt = receipt
            let accepted = await operations.openSpecificEntry(url)
            receipt.specificEntry = accepted ? .accepted : .failed
            lastReceipt = receipt
            guard operations.originIsCurrent(snapshot) else {
                receipt.outcome = .originChanged
                return finish(receipt, snapshot: snapshot, operations: operations)
            }
            if accepted {
                receipt.outcome = .specificAccepted
                return finish(receipt, snapshot: snapshot, operations: operations)
            }
        }
        receipt.stage = .generalEntry; lastReceipt = receipt
        guard operations.canOpenGeneralEntry() else {
            receipt.generalEntry = .unavailable; receipt.outcome = .unavailable
            return finish(receipt, snapshot: snapshot, operations: operations)
        }
        guard operations.originIsCurrent(snapshot) else {
            receipt.outcome = .originChanged
            return finish(receipt, snapshot: snapshot, operations: operations)
        }
        let accepted = await operations.openGeneralEntry()
        receipt.generalEntry = accepted ? .accepted : .failed
        receipt.outcome = accepted ? .generalAccepted : .failed
        return finish(receipt, snapshot: snapshot, operations: operations)
    }
}

@MainActor private final class CtripFlightUIKitHandoffOperations: CtripFlightHandoffOperations {
    private weak var model: PhoneAgentViewModel?
    private let generalURL = URL(string: "ctrip://wireless/flight_inquire")!
    private let isVisible: @MainActor () -> Bool
    init(model: PhoneAgentViewModel, isVisible: @escaping @MainActor () -> Bool) { self.model = model; self.isVisible = isVisible }
    func originIsCurrent(_ snapshot: CtripFlightHandoffSnapshot) -> Bool {
        isVisible() && model?.flightHandoffSnapshot(snapshot.offer, origin: snapshot.origin) == snapshot
    }
    func prepareClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        UIPasteboard.general.string = text
        return UIPasteboard.general.string == text
    }
    func canOpenGeneralEntry() -> Bool { UIApplication.shared.canOpenURL(generalURL) }
    func openSpecificEntry(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
    }
    func openGeneralEntry() async -> Bool { await UIApplication.shared.open(generalURL) }
    func publish(_ receipt: CtripFlightHandoffReceipt, for snapshot: CtripFlightHandoffSnapshot) {
        guard originIsCurrent(snapshot), let notice = receipt.notice else { return }
        model?.notice = notice
    }
}
