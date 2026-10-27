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
        let legacyQueueText = ConversationQueuePresentation.legacyAcknowledgement
        let linkedID = UUID()
        var linkedMessage = AssistantMessage(role: "assistant", text: legacyQueueText, taskID: linkedID)
        expect(ConversationQueuePresentation.messageText(linkedMessage.text, taskLinked: linkedMessage.taskID != nil) == "已加入任务队列。", "A linked legacy queue notice remains true as the task advances")
        expect(linkedMessage.text == legacyQueueText, "Display correction does not rewrite historical message content")
        linkedMessage.taskID = nil
        expect(ConversationQueuePresentation.messageText(linkedMessage.text, taskLinked: false) == legacyQueueText, "Unlinked historical acknowledgement is not rewritten")
        expect(ConversationQueuePresentation.messageText("其他回复", taskLinked: true) == "其他回复", "An unrelated linked reply is unchanged")
        expect(ConversationQueuePresentation.statusLabel(outcome: "paused", queueState: "waiting", queueStarted: false, isCurrent: false) == "等待执行", "Never-started queued task is waiting, not paused")
        expect(ConversationQueuePresentation.statusLabel(outcome: "paused", queueState: "suspended", queueStarted: false, isCurrent: false) == "等待你确认", "Restart suspension is reported as requiring confirmation")
        expect(ConversationQueuePresentation.statusLabel(outcome: "running", queueState: "waiting", queueStarted: true, isCurrent: true) == "进行中", "Current execution outranks stale queue state")
        for (terminal, label) in [("completed", "已完成"), ("failed", "执行中断"), ("stopped", "已停止")] {
            expect(ConversationQueuePresentation.statusLabel(outcome: terminal, queueState: "waiting", queueStarted: false, isCurrent: false) == label, "Terminal history outranks a stale queued state: " + terminal)
        }
        expect(ConversationQueuePresentation.statusLabel(outcome: nil, queueState: nil, queueStarted: false, isCurrent: false) == nil, "Missing task record remains unknown")
        expect(ConversationQueuePresentation.statusLabel(outcome: nil, queueState: "future", queueStarted: false, isCurrent: false) == nil, "Unknown future state is not invented")

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
        var terminalChangeBeforeHandoff = false
        handoff.onProcessingChange = {
            if handoff.activityRequests.isEmpty && handledReply == nil { terminalChangeBeforeHandoff = true }
        }
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
        expect(!terminalChangeBeforeHandoff, "The background runtime remains owned until synchronous native task handoff is established")
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

        // Exercise the real service's presentation boundary independently of
        // SwiftUI callback ordering. Cleanup only follows a successful release.
        let presented = conversation("presentation-screen-bound"), ownerA = UUID(), ownerB = UUID()
        expect(!presented.ownsPresentation(ownerA) && !presented.releasePresentation(ownerA), "An unclaimed presentation cannot release another view's services")
        expect(!presented.claimPresentation(ownerA) && presented.ownsPresentation(ownerA), "The first presentation claim does not replace an existing view")
        expect(!presented.claimPresentation(ownerA), "A repeated claim by the same presentation does not request media cleanup")
        let presentedOrigin = presented.currentConversationID
        presented.newConversation()
        expect(presented.currentConversationID != presentedOrigin && presented.ownsPresentation(ownerA), "The same view keeps presentation ownership when it opens a new conversation")
        expect(presented.claimPresentation(ownerB) && presented.ownsPresentation(ownerB) && !presented.ownsPresentation(ownerA), "A replacement presentation reports the displaced owner for media cleanup")
        var presentedRoute: CheckedContinuation<ConversationRoute, Never>?, presentedQueryCalls = 0
        presented.unifiedRoute = { _ in await withCheckedContinuation { presentedRoute = $0 } }
        presented.flightQuery = { _ in presentedQueryCalls += 1; return "不可开始" }
        presented.draft = "新页面当前画面的问题"; presented.selectFrame(ScreenFrame())
        expect(presented.send(settings: settings, apiKey: "", memories: memories), "The replacement presentation starts a real screen-bound request")
        try await settle { presentedRoute != nil }
        let presentedMessageID = presented.messages.last?.id
        let oldReleased = presented.releasePresentation(ownerA)
        if oldReleased { presented.cancelScreenBoundRequest() }
        expect(!oldReleased && presented.ownsPresentation(ownerB) && presented.loading && presented.messages.last?.id == presentedMessageID && presented.processingConversationIDs == [presented.currentConversationID], "A late outgoing view cannot release its successor or cancel the successor's pending turn")
        let currentReleased = presented.releasePresentation(ownerB)
        if currentReleased { presented.cancelScreenBoundRequest() }
        expect(currentReleased && !presented.ownsPresentation(ownerB) && !presented.loading && presented.messages.isEmpty && presented.draft == "新页面当前画面的问题", "The actual owner can leave and restore a screen-bound question for retry")
        expect(!presented.releasePresentation(ownerB), "A released owner cannot clean up a later presentation a second time")
        presentedRoute!.resume(returning: .init(mode: .flightQuery, request: "不应执行的旧画面查询", message: ""))
        await drain()
        expect(presentedQueryCalls == 0 && presented.processingConversationIDs.isEmpty, "Owner-authorized screen cleanup rejects a late provider operation")

        let presentedText = conversation("presentation-background-text"), textOwner = UUID(), presentedTextStart = model.requests.count
        presentedText.claimPresentation(textOwner)
        presentedText.draft = "离开当前页面仍继续的文本问题"
        expect(presentedText.send(settings: settings, apiKey: "", memories: memories), "Presentation cleanup fixture starts a real text-only request")
        try await settle { model.requests.count == presentedTextStart + 1 }
        let textReleased = presentedText.releasePresentation(textOwner)
        if textReleased { presentedText.cancelScreenBoundRequest() }
        expect(textReleased && presentedText.loading && presentedText.messages.last?.text == "离开当前页面仍继续的文本问题", "A valid presentation exit preserves the existing background text request")
        model.complete(presentedTextStart, answer: "离开页面后的文本回答")
        try await settle { !presentedText.loading }
        expect(presentedText.messages.last?.text == "离开页面后的文本回答", "A released presentation's background answer still reaches its originating conversation")
        presentedText.claimPresentation(textOwner)
        let reopenedPresentedText = conversation("presentation-background-text")
        expect(!reopenedPresentedText.ownsPresentation(textOwner) && reopenedPresentedText.messages.last?.text == "离开页面后的文本回答", "Presentation ownership is process-local and is never restored from the conversation archive")

        // Real SwiftUI navigation can briefly mount B after the surviving C.
        // When B leaves, C must regain its existing composer and send authority.
        let surviving = conversation("presentation-transient-fallback"), survivor = UUID(), transient = UUID()
        surviving.claimPresentation(survivor)
        surviving.claimPresentation(survivor)
        expect(surviving.claimPresentation(transient) && !surviving.ownsPresentation(survivor), "A transient presenter temporarily owns the shared view boundary")
        let transientReleased = surviving.releasePresentation(transient)
        if transientReleased { surviving.cancelScreenBoundRequest() }
        expect(!transientReleased && surviving.ownsPresentation(survivor), "A transient exit restores the still-present composer without shared cleanup")
        let survivingStart = model.requests.count
        surviving.draft = "导航返回后由原页面发送的文本"
        let survivorSent = surviving.ownsPresentation(survivor) && surviving.send(settings: settings, apiKey: "", memories: memories)
        expect(survivorSent, "The restored presenter passes the actual send ownership gate and submits its retained draft")
        try await settle { model.requests.count == survivingStart + 1 }
        surviving.claimPresentation(transient)
        let pendingTransientReleased = surviving.releasePresentation(transient)
        if pendingTransientReleased { surviving.cancelScreenBoundRequest() }
        expect(!pendingTransientReleased && surviving.ownsPresentation(survivor) && surviving.loading && surviving.messages.last?.text == "导航返回后由原页面发送的文本", "A second transient exit cannot cancel the surviving presenter's real pending turn")
        model.complete(survivingStart, answer: "原页面本轮回答")
        try await settle { !surviving.loading }
        expect(surviving.messages.map(\.text) == ["导航返回后由原页面发送的文本", "原页面本轮回答"], "The resumed composer receives only its own completed user turn and answer")
        expect(surviving.releasePresentation(survivor) && !surviving.ownsPresentation(survivor), "One final release cleans up a repeatedly claimed presenter without leaving duplicate registrations")
        expect(!surviving.releasePresentation(survivor), "A repeated final release cannot clean up another presentation")

        let removed = conversation("presentation-remove-hidden-owner"), removedOld = UUID(), visible = UUID(), overlay = UUID()
        removed.claimPresentation(removedOld); removed.claimPresentation(visible); removed.claimPresentation(overlay)
        expect(!removed.releasePresentation(removedOld) && removed.ownsPresentation(overlay), "An older hidden presenter unregisters without disturbing the current one")
        expect(!removed.releasePresentation(overlay) && removed.ownsPresentation(visible), "A transient presenter falls back to the remaining visible view")
        expect(removed.releasePresentation(visible) && !removed.ownsPresentation(removedOld), "The last live release cleans up and never resurrects an older view that already disappeared")
        expect(!removed.releasePresentation(removedOld), "The removed older owner cannot later acquire cleanup authority")

        // Revoking access cancels every real request, including routers that
        // ignore cancellation until their local continuations are resumed.
        let cancelledAll = conversation("cancel-all-late-routes"), cancelledAllStart = model.requests.count
        let cancelledAllA = cancelledAll.currentConversationID
        let cancelledQuestionA = "撤销授权前等待路由的 A 原问题"
        let cancelledQuestionB = "撤销授权前等待路由的 B 原问题"
        var cancelledRoutes: [String: CheckedContinuation<ConversationRoute, Never>] = [:]
        var returnedCancelledRoutes: Set<String> = []
        cancelledAll.unifiedRoute = { input in
            let route = await withCheckedContinuation { cancelledRoutes[input.question] = $0 }
            returnedCancelledRoutes.insert(input.question)
            return route
        }
        cancelledAll.draft = cancelledQuestionA
        expect(cancelledAll.send(settings: settings, apiKey: "", memories: memories), "Cancel-all fixture starts its first production conversation request")
        try await settle { cancelledRoutes[cancelledQuestionA] != nil }
        cancelledAll.newConversation(); let cancelledAllB = cancelledAll.currentConversationID
        cancelledAll.draft = cancelledQuestionB
        expect(cancelledAll.send(settings: settings, apiKey: "", memories: memories), "Cancel-all fixture starts a second production request while the first router waits")
        try await settle { cancelledRoutes[cancelledQuestionB] != nil }
        expect(cancelledAll.processingConversationIDs == [cancelledAllA, cancelledAllB] && model.requests.count == cancelledAllStart, "Both conversations are waiting in the router before any ordinary answer is requested")

        cancelledAll.cancelAllRequests()
        expect(cancelledAll.currentConversationID == cancelledAllB && !cancelledAll.loading && cancelledAll.messages.isEmpty && cancelledAll.draft == cancelledQuestionB, "Cancel-all synchronously restores the active question without a phantom turn or navigation")
        expect(cancelledAll.processingConversationIDs == [cancelledAllA] && cancelledAll.backgroundRequestCount == 1 && cancelledAll.conversations.first(where: { $0.id == cancelledAllA })?.messages.map(\.text) == [cancelledQuestionA], "Cancel-all retains the cancelled background handle until its own failure handler can restore its question")

        cancelledRoutes.removeValue(forKey: cancelledQuestionB)!.resume(returning: .init(mode: .chat, request: "", message: ""))
        try await settle { returnedCancelledRoutes.contains(cancelledQuestionB) }
        await drain()
        expect(cancelledAll.currentConversationID == cancelledAllB && cancelledAll.messages.isEmpty && cancelledAll.draft == cancelledQuestionB && cancelledAll.processingConversationIDs == [cancelledAllA] && model.requests.count == cancelledAllStart, "The active conversation's late chat route cannot restart an answer or consume its restored question")

        cancelledRoutes.removeValue(forKey: cancelledQuestionA)!.resume(returning: .init(mode: .chat, request: "", message: ""))
        try await settle { returnedCancelledRoutes.count == 2 }
        await drain()
        expect(model.requests.count == cancelledAllStart, "Neither cancelled late chat route starts an ordinary model answer")
        // Release an unexpected boundary request after recording its failure so
        // a regression reports assertions instead of leaking a continuation.
        if model.requests.count > cancelledAllStart {
            for index in cancelledAllStart..<model.requests.count { model.complete(index, answer: "不得采用的取消后回答") }
        }
        try await settle { cancelledAll.processingConversationIDs.isEmpty }
        expect(cancelledAll.currentConversationID == cancelledAllB && !cancelledAll.loading && cancelledAll.messages.isEmpty && cancelledAll.draft == cancelledQuestionB, "Both late returns leave the current conversation and its exact draft untouched")
        expect(cancelledAll.conversations.first(where: { $0.id == cancelledAllA })?.draft == cancelledQuestionA && cancelledAll.conversations.first(where: { $0.id == cancelledAllA })?.messages.isEmpty == true, "The background cancellation handler restores only its own exact draft and removes its pending user turn")
        let cancelledAllArchive = AssistantConversationStore(url: folder.appendingPathComponent("cancel-all-late-routes.json"))
        expect(cancelledAllArchive.error.isEmpty && cancelledAllArchive.currentConversationID == cancelledAllB && cancelledAllArchive.records.first(where: { $0.id == cancelledAllA })?.draft == cancelledQuestionA && cancelledAllArchive.records.first(where: { $0.id == cancelledAllB })?.draft == cancelledQuestionB && cancelledAllArchive.records.allSatisfy({ $0.messages.isEmpty }), "The real archive retains both cancelled drafts, no phantom messages and the unchanged current conversation")

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

        // The persisted event acknowledgement must not mislead the next model
        // or archived-chat recall after its linked task has changed state.
        let queuePath = folder.appendingPathComponent("queue-legacy-context.json")
        let queueStore = AssistantConversationStore(url: queuePath), queueOrigin = UUID(), queueOther = UUID(), queueOtherUnlinked = UUID(), queueTime = Date()
        let queueLegacy = ConversationQueuePresentation.legacyAcknowledgement
        let sourceMessages = [AssistantMessage(role: "user", text: "微信朋友圈任务"),
            AssistantMessage(role: "assistant", text: queueLegacy, taskID: UUID())]
        let originalCurrentMessages = [AssistantMessage(role: "user", text: "微信朋友圈任务"),
            AssistantMessage(role: "assistant", text: queueLegacy, taskID: UUID()),
            AssistantMessage(role: "assistant", text: queueLegacy),
            AssistantMessage(role: "user", text: queueLegacy, taskID: UUID())]
        let queueRecipient = settings.endpoint + "|" + PrivacyConsent.recipient(settings)
        let queueCurrent = AssistantConversationRecord(id: queueOrigin, title: "微信朋友圈任务", messages: originalCurrentMessages,
            createdAt: queueTime, updatedAt: queueTime, recipient: queueRecipient, draft: "", contextReferences: [])
        let queueSource = AssistantConversationRecord(id: queueOther, title: "微信朋友圈任务", messages: sourceMessages,
            createdAt: queueTime, updatedAt: queueTime, recipient: queueRecipient, draft: "", contextReferences: [])
        let queueUnlinkedSource = AssistantConversationRecord(id: queueOtherUnlinked, title: "微信朋友圈任务另一条",
            messages: [AssistantMessage(role: "user", text: "微信朋友圈任务另一条"), AssistantMessage(role: "assistant", text: queueLegacy)],
            createdAt: queueTime, updatedAt: queueTime, recipient: queueRecipient, draft: "", contextReferences: [])
        try queueStore.save([queueCurrent, queueSource, queueUnlinkedSource], currentConversationID: queueOrigin)
        let queueChat = AssistantConversation(store: queueStore), queueMemory = MemoryStore(), queueStart = model.requests.count
        let crossHit = queueChat.searchConversationContext("微信朋友圈任务", originatingConversationID: queueOrigin, recipientKey: queueRecipient)
        expect(crossHit.contains { $0.sourceID == queueOther && $0.excerpt.contains("已加入任务队列。") && !$0.excerpt.contains(queueLegacy) }, "Cross-chat retrieval converts the linked legacy acknowledgement")
        expect(crossHit.contains { $0.sourceID == queueOtherUnlinked && $0.excerpt.contains(queueLegacy) }, "Cross-chat retrieval keeps unlinked assistant text intact")
        var queueRoutingInput: ConversationRoutingInput?
        queueChat.unifiedRoute = { input in queueRoutingInput = input; return .init(mode: .chat, request: "", message: "") }
        queueChat.draft = "这个任务现在怎样"
        expect(queueChat.send(settings: settings, apiKey: "", memories: queueMemory), "Queue history fixture sends")
        try await settle { model.requests.count == queueStart + 1 }
        let expectedHistory = ["微信朋友圈任务", "已加入任务队列。", queueLegacy, queueLegacy]
        expect(queueRoutingInput?.history.map(\.text) == expectedHistory && model.requests[queueStart].history.map(\.text) == expectedHistory, "Router and model get a corrected copy while unlinked and user text stay intact")
        expect(queueChat.messages.prefix(4).map(\.text) == originalCurrentMessages.map(\.text), "Current chat retains its original stored text")
        model.complete(queueStart, answer: "请查看当前任务状态")
        try await settle { !queueChat.loading }
        let queueReload = AssistantConversationStore(url: queuePath)
        expect(queueReload.records.first(where: { $0.id == queueOrigin })?.messages.prefix(4).map(\.text) == originalCurrentMessages.map(\.text), "Current archive retains original messages after sending")
        expect(queueReload.records.first(where: { $0.id == queueOther })?.messages == sourceMessages, "Cross-chat archive remains unchanged")

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

        var transientAttempts = 0
        let recovered: String = try await AssistantConversation.retryReadOnly(settings: settings) {
            transientAttempts += 1
            if transientAttempts == 1 { throw URLError(.networkConnectionLost) }
            return "网络恢复后的回答"
        }
        expect(recovered == "网络恢复后的回答" && transientAttempts == 2, "Read-only interpretation/answer retries a transient disconnect once")
        var exhaustedAttempts = 0
        do {
            let _: String = try await AssistantConversation.retryReadOnly(settings: settings) {
                exhaustedAttempts += 1; throw URLError(.timedOut)
            }
            expect(false, "Repeated network failure must propagate")
        } catch {
            expect(exhaustedAttempts == 2, "Repeated transient failure uses a bounded two-attempt budget")
        }
        var permanentAttempts = 0
        do {
            let _: String = try await AssistantConversation.retryReadOnly(settings: settings) {
                permanentAttempts += 1; throw URLError(.serverCertificateUntrusted)
            }
        } catch { expect(permanentAttempts == 1, "Certificate/authentication failures cannot enter network recovery") }
        var deniedAttempts = 0
        PrivacyConsent.permitted = false
        do {
            let _: String = try await AssistantConversation.retryReadOnly(settings: settings) {
                deniedAttempts += 1; return "不得请求"
            }
        } catch { expect(deniedAttempts == 0, "Read-only recovery checks current consent before every request") }
        PrivacyConsent.permitted = true

        let expiring = conversation("background-expiration"), expirationStart = model.requests.count
        expiring.draft = "后台待查询的原问题 A"
        let expiringA = expiring.currentConversationID
        _ = expiring.send(settings: settings, apiKey: "", memories: memories)
        try await settle { model.requests.count == expirationStart + 1 }
        let activityA = expiring.activityRequests.first!
        expect(activityA.id == expiringA && activityA.title == "后台待查询的原问题 A", "Island metadata is bound to the submitted user request and its generation")
        expiring.newConversation(); let expiringB = expiring.currentConversationID
        expiring.draft = "独立查询 B"
        _ = expiring.send(settings: settings, apiKey: "", memories: memories)
        try await settle { model.requests.count == expirationStart + 2 }
        expiring.expireBackgroundRequests([expiringA], expectedTokens: [expiringA: UUID()])
        expect(expiring.processingConversationIDs == [expiringA, expiringB], "Stale OS expiration cannot cancel a replacement request generation")
        expiring.expireBackgroundRequests([expiringA], expectedTokens: [expiringA: activityA.token])
        expect(expiring.processingConversationIDs == [expiringB] && expiring.loading,
            "Expiration synchronously settles only its matching request while another conversation keeps working")
        expect(expiring.conversations.first(where: { $0.id == expiringA })?.draft == "后台待查询的原问题 A",
            "OS expiration restores the originating conversation's exact query")
        model.complete(expirationStart, answer: "过期后迟到的结果不得覆盖")
        model.complete(expirationStart + 1, answer: "独立查询 B 的结果")
        try await settle { expiring.processingConversationIDs.isEmpty }
        expect(expiring.currentConversationID == expiringB && expiring.messages.last?.text == "独立查询 B 的结果" &&
            expiring.conversations.first(where: { $0.id == expiringA })?.messages.isEmpty == true,
            "Late expired results cannot restart work or overwrite the surviving conversation")

        let report: [String: Any] = ["checks": checks, "failures": failures, "mode": "offline continuations only; no model/network/device access"]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
