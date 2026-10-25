import Foundation

@main struct ConversationLifecycleRegressions {
    @MainActor static func main() async throws {
        var checks = 0
        var failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func settle(_ predicate: () -> Bool) async throws {
            for _ in 0..<2000 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw NSError(domain: "OfflineLifecycleFixture", code: 1)
        }
        func drain() async {
            for _ in 0..<30 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sela-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = AgentSettings(), memories = MemoryStore(), model = OfflineModel.shared
        func conversation(_ name: String) -> AssistantConversation {
            AssistantConversation(store: AssistantConversationStore(url: folder.appendingPathComponent(name + ".json")))
        }

        let flight = conversation("late-flight-route")
        var pendingFlight: CheckedContinuation<ConversationRoute, Never>?
        var flightCalls = 0
        flight.unifiedRoute = { _ in await withCheckedContinuation { pendingFlight = $0 } }
        flight.flightQuery = { _ in flightCalls += 1; return "offline response" }
        flight.draft = "上海到北京机票"
        expect(flight.send(settings: settings, apiKey: "", memories: memories), "Flight-routing fixture starts")
        try await settle { pendingFlight != nil }
        let flightOrigin = flight.currentConversationID
        flight.newConversation()
        pendingFlight!.resume(returning: .init(mode: .flightQuery, request: "上海到北京机票", message: "查询中"))
        await drain()
        expect(flightCalls == 1, "Navigating to a new task preserves the pending cloud flight route")
        expect(flight.messages.isEmpty && !flight.loading, "Background flight route cannot update the replacement chat")
        expect(flight.conversations.first(where: { $0.id == flightOrigin })?.messages.last?.text == "offline response", "Background query saves its result only to its original conversation")

        let chat = conversation("late-chat-route")
        var pendingChat: CheckedContinuation<ConversationRoute, Never>?
        chat.unifiedRoute = { _ in await withCheckedContinuation { pendingChat = $0 } }
        chat.draft = "稍后取消的问题"
        let oldModelCount = model.requests.count
        expect(chat.send(settings: settings, apiKey: "", memories: memories), "Chat-routing fixture starts")
        try await settle { pendingChat != nil }
        chat.cancel()
        pendingChat!.resume(returning: .init(mode: .chat, request: "", message: ""))
        await drain()
        expect(model.requests.count == oldModelCount, "Cancelled late chat route never starts another model request")
        if model.requests.count > oldModelCount {
            model.complete(oldModelCount, answer: "Cancelled old response")
            await drain()
        }
        expect(chat.messages.isEmpty && chat.draft == "稍后取消的问题", "Late cancelled route preserves the restored question")

        let interrupted = conversation("upstream-cancellation")
        var routeReturned = false
        interrupted.unifiedRoute = { _ in routeReturned = true; throw CancellationError() }
        interrupted.draft = "请求意外取消时保留这个问题"
        expect(interrupted.send(settings: settings, apiKey: "", memories: memories), "Upstream-cancellation fixture starts")
        try await settle { routeReturned }
        await drain()
        expect(!interrupted.loading, "Upstream cancellation clears the loading indicator")
        expect(interrupted.draft == "请求意外取消时保留这个问题" && interrupted.messages.isEmpty,
               "Upstream cancellation restores a retryable question without a phantom turn")
        expect(!interrupted.error.isEmpty, "Upstream cancellation has a visible interruption result")
        interrupted.cancel()

        let editing = conversation("preserve-new-draft")
        editing.draft = "先发送的旧问题"
        let editIndex = model.requests.count
        expect(editing.send(settings: settings, apiKey: "", memories: memories), "Network-failure fixture starts")
        try await settle { model.requests.count == editIndex + 1 }
        editing.draft = "等待期间新输入的问题"
        model.fail(editIndex)
        try await settle { !editing.loading }
        expect(editing.draft == "等待期间新输入的问题", "Request failure preserves the newer unsent draft")
        expect(!editing.error.isEmpty && editing.messages.isEmpty, "Network failure removes only its own pending turn")

        let parallel = conversation("parallel-reverse-results")
        let parallelA = parallel.currentConversationID, parallelStart = model.requests.count
        parallel.draft = "独立查询 A"
        expect(parallel.send(settings: settings, apiKey: "", memories: memories), "First parallel query starts")
        try await settle { model.requests.count == parallelStart + 1 }
        parallel.draft = "A 内尚未发送的补充"
        expect(!parallel.send(settings: settings, apiKey: "", memories: memories), "A pending turn cannot accept a second same-conversation submission")
        parallel.newConversation(); let parallelB = parallel.currentConversationID
        expect(!parallel.loading && parallel.backgroundRequestCount == 1, "New task is immediately writable while the first cloud request waits")
        parallel.draft = "独立查询 B"
        expect(parallel.send(settings: settings, apiKey: "", memories: memories), "A second conversation submits while the first is pending")
        try await settle { model.requests.count == parallelStart + 2 }
        expect(parallel.openConversation(parallelA) && parallel.loading && parallel.draft == "A 内尚未发送的补充", "Reopening a busy conversation restores its own request and unsent input")
        parallel.cancelScreenBoundRequest()
        expect(parallel.loading && parallel.processingConversationIDs.count == 2, "Screen navigation preserves both text-only requests")
        parallel.newConversation(); let parallelC = parallel.currentConversationID
        let unsentAttachment = ComposerAttachment(name: "新草稿.txt", kind: .text, byteCount: 12, text: "仅属于 C", imageJPEG: nil)
        parallel.draft = "C 正在编辑的输入"
        parallel.retainDraftAttachments([unsentAttachment], conversationID: parallelC)
        model.complete(parallelStart + 1, answer: "B 先返回的结果")
        try await settle { parallel.processingConversationIDs.count == 1 }
        model.complete(parallelStart, answer: "A 后返回的结果")
        try await settle { parallel.processingConversationIDs.isEmpty }
        expect(parallel.currentConversationID == parallelC && parallel.messages.isEmpty && !parallel.loading && parallel.draft == "C 正在编辑的输入" && parallel.retryAttachments == [unsentAttachment], "Reverse-order background completions preserve the active page, draft and selected material")
        expect(parallel.conversations.first(where: { $0.id == parallelA })?.messages.last?.text == "A 后返回的结果" && parallel.conversations.first(where: { $0.id == parallelB })?.messages.last?.text == "B 先返回的结果", "Both reverse-order results merge into their own archived conversations")
        expect(parallel.openConversation(parallelB) && parallel.messages.last?.text == "B 先返回的结果" && !parallel.loading, "Completed background result is available when its conversation is reopened")
        expect(parallel.openConversation(parallelA) && parallel.messages.last?.text == "A 后返回的结果" && parallel.draft == "A 内尚未发送的补充", "First query preserves its own newer unsent follow-up after completion")

        let independentCancel = conversation("independent-cancellation"), cancelStart = model.requests.count
        let cancelledOrigin = independentCancel.currentConversationID
        independentCancel.draft = "只取消 A"
        _ = independentCancel.send(settings: settings, apiKey: "", memories: memories)
        try await settle { model.requests.count == cancelStart + 1 }
        independentCancel.newConversation(); let retainedOrigin = independentCancel.currentConversationID
        independentCancel.draft = "B 应继续"
        _ = independentCancel.send(settings: settings, apiKey: "", memories: memories)
        try await settle { model.requests.count == cancelStart + 2 }
        _ = independentCancel.openConversation(cancelledOrigin); independentCancel.cancel()
        expect(independentCancel.processingConversationIDs == [retainedOrigin], "Explicit cancellation terminates only the selected conversation's handle")
        model.complete(cancelStart, answer: "被取消 A 的迟到结果")
        model.complete(cancelStart + 1, answer: "B 独立完成")
        try await settle { independentCancel.processingConversationIDs.isEmpty }
        expect(independentCancel.messages.isEmpty && independentCancel.draft == "只取消 A", "Cancelled request cannot repopulate its own restored draft")
        expect(independentCancel.conversations.first(where: { $0.id == retainedOrigin })?.messages.last?.text == "B 独立完成", "Cancelling A does not stop B or redirect its result")

        let actualTask = UUID(), backgroundSession = UUID(), handoffSeedID = UUID()
        let handoffStore = AssistantConversationStore(url: folder.appendingPathComponent("offscreen-native-handoff.json"))
        try handoffStore.upsert(.init(id: handoffSeedID, title: "本对话原生任务", messages: [
            .init(role: "assistant", text: "本对话已关联的原生任务", taskID: actualTask)
        ], createdAt: Date(), updatedAt: Date(), recipient: "", draft: ""), currentConversationID: handoffSeedID)
        let handoff = AssistantConversation(store: handoffStore), handoffOrigin = handoff.currentConversationID
        var nativeRoute: CheckedContinuation<ConversationRoute, Never>?, handledOrigin: UUID?, handledReply: UUID?
        var capturedSessions: [UUID: UUID] = [:]
        handoff.backgroundTaskSessions = { [actualTask: backgroundSession] }
        handoff.unifiedRoute = { input in capturedSessions = input.backgroundSessions; return await withCheckedContinuation { nativeRoute = $0 } }
        handoff.onActionInConversation = { _, replyID, origin in
            handledOrigin = origin; handledReply = replyID
            _ = handoff.linkTask(actualTask, to: replyID, in: origin)
            _ = handoff.reportTaskHandoff(text: "原生后台任务已接收", to: replyID, in: origin, onlyIfUnlinked: false)
        }
        handoff.draft = "创建一个原生任务"
        _ = handoff.send(settings: settings, apiKey: "", memories: memories)
        try await settle { nativeRoute != nil }
        handoff.newConversation(); let handoffReplacement = handoff.currentConversationID
        handoff.draft = "另一个独立任务的输入"
        nativeRoute!.resume(returning: .init(mode: .task, request: "创建一个原生任务", message: "已交接"))
        try await settle { handoff.processingConversationIDs.isEmpty }
        expect(capturedSessions == [actualTask: backgroundSession], "Intent routing receives the submitted native worker session snapshot")
        expect(handledOrigin == handoffOrigin && handledReply != nil, "Offscreen native handoff carries its real originating conversation and reply")
        expect(handoff.currentConversationID == handoffReplacement && handoff.messages.isEmpty && handoff.draft == "另一个独立任务的输入", "Offscreen task acceptance cannot overwrite the new page")
        expect(handoff.conversations.first(where: { $0.id == handoffOrigin })?.messages.last?.taskID == actualTask && handoff.conversations.first(where: { $0.id == handoffOrigin })?.messages.last?.text == "原生后台任务已接收", "Native acceptance and task binding update the source acknowledgement")

        let camera = conversation("screen-bound-cancellation"), cameraOrigin = camera.currentConversationID
        var cameraRoute: CheckedContinuation<ConversationRoute, Never>?, cameraQueryCalls = 0
        camera.unifiedRoute = { _ in await withCheckedContinuation { cameraRoute = $0 } }
        camera.flightQuery = { _ in cameraQueryCalls += 1; return "不可开始" }
        camera.draft = "结合当前画面查机票"; camera.selectFrame(ScreenFrame())
        _ = camera.send(settings: settings, apiKey: "", memories: memories)
        try await settle { cameraRoute != nil }
        camera.newConversation()
        cameraRoute!.resume(returning: .init(mode: .flightQuery, request: "屏幕机票", message: ""))
        await drain()
        expect(cameraQueryCalls == 0 && camera.processingConversationIDs.isEmpty && camera.messages.isEmpty, "Screen-bound observation cancels on navigation and cannot start a late provider operation")
        expect(camera.conversations.first(where: { $0.id == cameraOrigin })?.draft == "结合当前画面查机票", "Screen-bound cancellation preserves its original question for an explicit retry")

        let bounded = conversation("bounded-parallelism"), boundedStart = model.requests.count
        for i in 0..<AssistantConversation.maximumParallelConversations {
            bounded.draft = "等待查询 \(i)"
            expect(bounded.send(settings: settings, apiKey: "", memories: memories), "Each available parallel conversation slot accepts a request")
            try await settle { model.requests.count == boundedStart + i + 1 }
            bounded.newConversation()
        }
        bounded.draft = "达到上限后应保留的输入"
        expect(!bounded.send(settings: settings, apiKey: "", memories: memories) && bounded.draft == "达到上限后应保留的输入" && !bounded.error.isEmpty, "Parallel limit rejects excess work without discarding the input")
        for i in 0..<AssistantConversation.maximumParallelConversations { model.complete(boundedStart + i, answer: "完成 \(i)") }
        try await settle { bounded.processingConversationIDs.isEmpty }
        expect(bounded.conversations.filter { $0.messages.last?.role == "assistant" }.count == AssistantConversation.maximumParallelConversations, "Every admitted parallel result remains archived after the limit is reached")

        let memoryBound = conversation("memory-bound-origin"), guardedMemory = MemoryStore()
        var memoryWait: CheckedContinuation<Void, Never>?
        guardedMemory.beforePrepare = { await withCheckedContinuation { memoryWait = $0 } }
        memoryBound.draft = "等待记忆准备的原问题"
        let memoryBoundOrigin = memoryBound.currentConversationID, memoryBoundStart = model.requests.count
        _ = memoryBound.send(settings: settings, apiKey: "", memories: guardedMemory)
        try await settle { memoryWait != nil }
        memoryBound.newConversation(); let memoryReplacement = memoryBound.currentConversationID
        memoryBound.draft = "记忆等待期间的新输入"
        memoryWait!.resume()
        try await settle { model.requests.count == memoryBoundStart + 1 }
        expect(model.requests[memoryBoundStart].question == "等待记忆准备的原问题", "Memory preparation resumes the submitted question after navigation")
        model.complete(memoryBoundStart, answer: "记忆等待后的原会话结果")
        try await settle { memoryBound.processingConversationIDs.isEmpty }
        expect(memoryBound.currentConversationID == memoryReplacement && memoryBound.draft == "记忆等待期间的新输入" && memoryBound.conversations.first(where: { $0.id == memoryBoundOrigin })?.messages.last?.text == "记忆等待后的原会话结果", "Memory-first asynchronous preparation retains request ownership")

        let recallPath = folder.appendingPathComponent("recall-exclusion.json"), recallStore = AssistantConversationStore(url: recallPath)
        let recallOrigin = UUID(), forgottenSourceID = UUID(), forgottenTaskID = UUID(), recallTime = Date()
        let forgottenUser = AssistantMessage(role: "user", text: "机票预算 PRIVATE_540 元")
        let sourceUser = AssistantMessage(role: "user", text: "机票预算 CROSS_SECRET_680 元")
        let forgottenReceipt = AssistantMessage(role: "assistant", text: "预算 PRIVATE_540 已理解", taskID: forgottenTaskID)
        let currentRecall = AssistantConversationRecord(id: recallOrigin, title: "机票预算", messages: [forgottenUser, forgottenReceipt,
            AssistantMessage(role: "assistant", text: "备用说明 PRIVATE_540"), AssistantMessage(role: "user", text: "保留的非敏感话题"),
            AssistantMessage(role: "assistant", text: "保留的正常回答")], createdAt: recallTime, updatedAt: recallTime,
            recipient: settings.endpoint + "|" + PrivacyConsent.recipient(settings), draft: "", contextReferences: [])
        let excludedSource = AssistantConversationRecord(id: forgottenSourceID, title: "机票预算 CROSS_SECRET_680", messages: [sourceUser,
            AssistantMessage(role: "assistant", text: "历史预算 CROSS_SECRET_680")], createdAt: recallTime, updatedAt: recallTime,
            recipient: settings.endpoint + "|" + PrivacyConsent.recipient(settings), draft: "", contextReferences: [])
        try recallStore.save([currentRecall, excludedSource], currentConversationID: recallOrigin)
        let recall = AssistantConversation(store: recallStore), recallMemory = MemoryStore(), recallStart = model.requests.count
        recallMemory.excludedMessageIDs = [forgottenUser.id, sourceUser.id]
        var recallInput: ConversationRoutingInput?
        recall.taskContext = { "{\"tasks\":[{\"id\":\"" + forgottenTaskID.uuidString + "\",\"goal\":\"TASK_SECRET_540\"}]}" }
        recall.unifiedRoute = { input in recallInput = input; return .init(mode: .chat, request: "", message: "") }
        recall.draft = "机票预算是多少"
        let historicalTask = PhoneTaskRecord(id: forgottenTaskID, title: "机票预算 TASK_SECRET_540", goal: "机票预算 TASK_SECRET_540", summary: "未下单")
        expect(recall.send(settings: settings, apiKey: "", memories: recallMemory, taskRecords: [historicalTask]), "Fresh question can proceed after a historical memory source is excluded")
        try await settle { model.requests.count == recallStart + 1 }
        expect(recallInput?.history.map(\.text) == ["保留的非敏感话题", "保留的正常回答"] && model.requests[recallStart].history.map(\.text) == ["保留的非敏感话题", "保留的正常回答"], "Excluded source removes its task acknowledgement and alternative answers from router and model history")
        expect(!(recallInput?.taskContext.contains("TASK_SECRET_540") ?? true) && !model.requests[recallStart].context.contains("SECRET") && !model.requests[recallStart].context.contains("PRIVATE_540"), "Excluded source cannot re-enter through automatic task or cross-conversation references")
        model.complete(recallStart, answer: "请提供当前预算")
        try await settle { !recall.loading }
        recallMemory.canUseConversationHistory = false
        recall.draft = "只回答当前的新问题"
        _ = recall.send(settings: settings, apiKey: "", memories: recallMemory, taskRecords: [historicalTask])
        try await settle { model.requests.count == recallStart + 2 }
        let unavailablePayload = (try? JSONSerialization.jsonObject(with: Data((recallInput?.taskContext ?? "").utf8))) as? [String: Any]
        let unavailableTaskRows = unavailablePayload?["tasks"] as? [[String: Any]] ?? []
        expect(recallInput?.history.isEmpty == true && unavailablePayload != nil && unavailableTaskRows.isEmpty && model.requests[recallStart + 1].history.isEmpty && !model.requests[recallStart + 1].context.contains("SECRET"), "Unavailable exclusion state fails closed for histories, archived references and task snapshots while allowing fresh input")
        model.complete(recallStart + 1, answer: "当前问题的回答")
        try await settle { !recall.loading }
        let answerBeforeUnavailableRetry = recall.messages.last!
        expect(recall.retry(answerBeforeUnavailableRetry, settings: settings, apiKey: "", memories: recallMemory, taskRecords: [historicalTask]), "Retry validates memory state before replaying an archived question")
        try await settle { !recall.loading }
        expect(model.requests.count == recallStart + 2 && recall.messages.last == answerBeforeUnavailableRetry && !recall.error.isEmpty, "Unavailable exclusion state rejects archived-question replay without losing the original answer")
        recallMemory.canUseConversationHistory = true
        recallMemory.excludedMessageIDs.insert(recall.messages.dropLast().last(where: { $0.role == "user" })!.id)
        expect(recall.retry(answerBeforeUnavailableRetry, settings: settings, apiKey: "", memories: recallMemory), "Retry checks whether its own archived question was revoked")
        try await settle { !recall.loading }
        expect(model.requests.count == recallStart + 2 && recall.messages.last == answerBeforeUnavailableRetry, "A revoked original question is never silently resent by answer retry")

        let durableFolder = folder.appendingPathComponent("recoverable-disk-failure")
        let durablePath = durableFolder.appendingPathComponent("conversations.json")
        let durable = AssistantConversation(store: AssistantConversationStore(url: durablePath)), durableStart = model.requests.count
        let durableA = durable.currentConversationID
        durable.draft = "写盘失败时也保留 A"
        _ = durable.send(settings: settings, apiKey: "", memories: memories)
        try await settle { model.requests.count == durableStart + 1 }
        durable.newConversation(); let durableB = durable.currentConversationID
        durable.draft = "写盘失败时也保留 B"
        _ = durable.send(settings: settings, apiKey: "", memories: memories)
        try await settle { model.requests.count == durableStart + 2 }
        durable.newConversation(); durable.draft = "当前页面的草稿 C"
        try FileManager.default.removeItem(at: durableFolder)
        try Data([0]).write(to: durableFolder)
        model.complete(durableStart, answer: "离屏 A 完成但写盘失败")
        try await settle { durable.processingConversationIDs.count == 1 }
        model.complete(durableStart + 1, answer: "离屏 B 完成但写盘失败")
        try await settle { durable.processingConversationIDs.isEmpty }
        expect(!durable.storageError.isEmpty && durable.conversations.first(where: { $0.id == durableA })?.messages.last?.text == "离屏 A 完成但写盘失败" && durable.conversations.first(where: { $0.id == durableB })?.messages.last?.text == "离屏 B 完成但写盘失败", "Disk failure retains both completed background results in memory")
        try FileManager.default.removeItem(at: durableFolder)
        durable.cancel()
        let recoveredRecords = AssistantConversationStore(url: durablePath).records
        expect(durable.storageError.isEmpty && recoveredRecords.first(where: { $0.id == durableA })?.messages.last?.text == "离屏 A 完成但写盘失败" && recoveredRecords.first(where: { $0.id == durableB })?.messages.last?.text == "离屏 B 完成但写盘失败" && durable.draft == "当前页面的草稿 C", "A later successful save merges unsaved background results with the active draft")

        let validation = conversation("preserve-attachments")
        let attachment = ComposerAttachment(name: "资料.txt", kind: .text, byteCount: 12, text: "离线资料", imageJPEG: nil)
        validation.retainDraftAttachments([attachment], conversationID: validation.currentConversationID)
        expect(!validation.send(settings: settings, apiKey: "", memories: memories), "Empty question is rejected before dispatch")
        expect(validation.retryAttachments == [attachment], "Rejected empty question preserves selected draft attachments")
        validation.retainDraftAttachments([attachment], conversationID: validation.currentConversationID)
        validation.draft = "重复附件应拒绝但不能丢失原稿"
        expect(!validation.send(settings: settings, apiKey: "", memories: memories, attachments: [attachment, attachment]), "Invalid duplicate attachments are rejected")
        expect(validation.retryAttachments == [attachment], "Rejected attachment validation preserves the prior valid selection")
        expect(!validation.loading && validation.messages.isEmpty, "Rejected send never starts or persists a request")

        let report: [String: Any] = ["checks": checks, "failures": failures, "mode": "offline continuations only; no model/network/device access"]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
