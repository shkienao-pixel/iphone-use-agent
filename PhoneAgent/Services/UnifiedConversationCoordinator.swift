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
    func bookFlight(_ offer: CtripFlightOffer) {
        // App-only handoff. Never fall back to Safari or launch an agent.
        let appURL = URL(string: "ctrip://wireless/flight_inquire")!
        Task {
            if let link = offer.flightSpecificBookingURL,
               await UIApplication.shared.open(link, options: [.universalLinksOnly: true]) { return }
            guard UIApplication.shared.canOpenURL(appURL) else {
                notice = "请先安装携程旅行 App，再点订票"; return
            }
            // The fallback deliberately carries the selection as copyable text;
            // opening the app is never reported as an order/payment handoff.
            UIPasteboard.general.string = offer.bookingSummary
            if await UIApplication.shared.open(appURL) {
                notice = offer.isSchedule ? "已复制 " + offer.cardTitle + " 的参考时刻，请在携程查价并核对航班。" :
                    "已复制 " + offer.cardTitle + " 的航班信息。请在携程核对并选票；尚未创建订单。"
            } else { notice = "暂时无法打开携程 App，请稍后重试" }
        }
    }
}
