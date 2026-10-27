import Foundation

@main struct ConversationTaskOwnershipChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures: [String] = [], serial = 0
        let folder = URL(fileURLWithPath: CommandLine.arguments[2])
        func expect(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append(label); print("FAIL: " + label) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<4000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw CocoaError(.fileReadUnknown)
        }
        func make() -> PhoneAgentViewModel {
            serial += 1; PrivacyConsent.approved = true
            let vm = PhoneAgentViewModel(url: folder.appendingPathComponent("chat-\(serial).json"))
            vm.installCallbacks(); vm.conversation.unifiedRoute = { _ in .init(mode: .clarify, request: "", message: "离线任务消息") }
            return vm
        }
        func message(_ vm: PhoneAgentViewModel, text: String = "离线任务") async throws -> UUID {
            vm.conversation.draft = text
            guard vm.conversation.send(settings: .init(), apiKey: "offline-unused", memories: MemoryStore()) else { throw CocoaError(.fileReadUnknown) }
            try await wait { !vm.conversation.loading }
            return vm.conversation.messages.last!.id
        }
        func taskIDs(_ vm: PhoneAgentViewModel, recentOnly: Bool = false) throws -> Set<String> {
            let history = recentOnly ? Array(vm.conversation.messages.suffix(12)) : vm.conversation.messages
            let context = vm.unifiedTaskContext(history: history)
            let object = try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any]
            return Set((object["tasks"] as? [[String: String]] ?? []).compactMap { $0["id"] })
        }
        func linked(_ vm: PhoneAgentViewModel, chat: UUID, message: UUID) -> UUID? {
            vm.conversation.conversations.first { $0.id == chat }?.messages.first { $0.id == message }?.taskID
        }
        func ended(_ vm: PhoneAgentViewModel) {
            vm.engine.running = false; vm.engine.hasCurrentTask = false
            vm.engine.currentRecord?.outcome = .completed
            if let record = vm.engine.currentRecord { vm.engine.onRecord?(record) }
        }
        PrivacyConsent.approved = false
        expect(!PrivacyConsent.allowed(.init()), "Synthetic consent boundary actually follows a denied authorization")
        PrivacyConsent.approved = true
        expect(PrivacyConsent.allowed(.init()), "Synthetic consent boundary actually follows an approved authorization")
        // The production VM hook receives the full pre-await send snapshot,
        // even when the relevant flight result lies outside recent wire turns.
        let focusURL = folder.appendingPathComponent("flight-context-snapshot.json")
        let focusQuery = "2026-10-26 北京到深圳 1名成人经济舱"
        let focusOffers = (1...30).map { index in CtripFlightOffer(id: "same-legacy-id", title: "MU\(6000 + index)", details: "原始完整卡片\(index)", price: "900元", bookingURL: nil, query: focusQuery, queriedAt: Date()) }
        let focusHistory = [AssistantMessage(role: "user", text: focusQuery),
            AssistantMessage(role: "assistant", text: "三十个已保存候选", flightOffers: focusOffers, flightQuery: focusQuery)] +
            (0..<14).map { AssistantMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "穿插的普通聊天\($0)") }
        let focusRecord = AssistantConversationRecord(id: UUID(), title: "完整候选快照", messages: focusHistory,
            createdAt: Date(), updatedAt: Date(), recipient: "https://model.invalid/chat/completions|Offline fixture", draft: "")
        let focusStore = AssistantConversationStore(url: focusURL); try focusStore.save([focusRecord], currentConversationID: focusRecord.id)
        let focusVM = PhoneAgentViewModel(url: focusURL); focusVM.installCallbacks()
        let snapshotHook = focusVM.conversation.routingTaskContextInConversation!
        var hookCalls = 0, lateHookCalls = 0, seenQuestion = "", seenHistory: [AssistantMessage] = [], routedFocus: [ConversationRoutingInput] = []
        focusVM.conversation.routingTaskContextInConversation = { question, history, origin in
            hookCalls += 1; seenQuestion = question; seenHistory = history
            return snapshotHook(question, history, origin)
        }
        focusVM.conversation.unifiedRoute = { input in routedFocus.append(input); return .init(mode: .clarify, request: "", message: "请核对后再决定。") }
        var focusSettings = AgentSettings(); focusSettings.useMemories = true
        let focusMemories = MemoryStore(); focusMemories.reference = "SAME-SNAPSHOT-MEMORY"
        let focusAttachment = ComposerAttachment(name: "资料.txt", kind: .text, byteCount: 8, text: "本轮资料", imageJPEG: nil)
        let focusControl = ConversationControlContext(taskID: nil, engineSessionID: UUID(), preparationID: UUID(), voiceID: UUID(), queueID: UUID(), interactionID: UUID())
        focusVM.conversation.taskControlContext = { focusControl }
        focusVM.conversation.selectFrame(ScreenFrame())
        focusVM.conversation.draft = "第27个航班的行李呢？"
        expect(focusVM.conversation.send(settings: focusSettings, apiKey: "offline-unused", memories: focusMemories, attachments: [focusAttachment]),
               "Thirty-candidate follow-up enters the actual typed send path")
        expect(hookCalls == 1 && seenQuestion == "第27个航班的行李呢？" && seenHistory == focusHistory &&
               CtripFlightSearchContext.latest(in: seenHistory)?.offers.count == 30,
               "The current question and complete ordered history are captured synchronously before any await")
        focusVM.conversation.routingTaskContextInConversation = { _, _, _ in lateHookCalls += 1; return "{\"wrongLaterConversation\":true}" }
        try await wait { !focusVM.conversation.loading }
        let focusObject = try JSONSerialization.jsonObject(with: Data(routedFocus[0].taskContext.utf8)) as! [String: Any]
        let focusRows = focusObject["flightOffers"] as! [[String: Any]]
        expect(lateHookCalls == 0 && routedFocus.count == 1 && focusRows.contains { $0["position"] as? Int == 27 && $0["flightNumbers"] as? [String] == ["MU6027"] } &&
               routedFocus[0].history.allSatisfy { $0.flightOffers == nil },
               "Routing keeps the original focused snapshot even after callback replacement and recent-history truncation")
        expect(routedFocus[0].memoryContext == focusMemories.reference && routedFocus[0].attachments == [focusAttachment] &&
               routedFocus[0].visuals.count == 1 && routedFocus[0].controlContext == focusControl && routedFocus[0].configuration?.model == focusSettings.model,
               "Focused context keeps the same input memory, selected media, control and configuration snapshots")
        focusVM.conversation.routingTaskContextInConversation = { question, history, origin in hookCalls += 1; return snapshotHook(question, history, origin) }
        focusVM.conversation.draft = "最后一个呢？"
        _ = focusVM.conversation.send(settings: focusSettings, apiKey: "offline-unused", memories: focusMemories)
        let beforeSwitchCalls = hookCalls; focusVM.conversation.newConversation()
        try await Task.sleep(for: .milliseconds(20))
        expect(hookCalls == beforeSwitchCalls && routedFocus.count == 1 && focusVM.conversation.messages.isEmpty,
               "Switching conversation before the asynchronous route neither re-reads a new context nor routes the old send")

        let vm = make(), a = vm.conversation.currentConversationID
        let m = try await message(vm), reserved = UUID()
        expect(vm.submitForChecks(id: reserved, conversationID: a, messageID: m, text: "A的任务", reference: "A的已核对原文"), "Immediate same-chat submission still starts")
        let actual = vm.engine.currentRecord!.id
        expect(actual == reserved, "Start passes the reserved submission UUID into the engine")
        expect(vm.engine.currentRecord?.goal == "A的任务" && vm.engine.currentRecord?.conversationReference == "A的已核对原文", "The actual start controller hands conversation grounding to the executor separately from the original task")
        expect(linked(vm, chat: a, message: m) == actual && vm.unifiedFocusedTaskID == actual, "Own chat message and focus use the created task identity")
        expect(!vm.pendingForChecks, "Successful record publication consumes only its submission")
        expect(vm.conversation.messages.last?.text == "任务已启动。" && vm.conversation.messages.first?.text == "离线任务", "Only the exact engine record replaces the assistant acknowledgement; the human text stays unchanged")
        vm.unifiedFocusedTaskID = UUID(); vm.unifiedFocusedTaskID = nil
        expect(vm.unifiedFocusedTaskID == actual, "Clearing a manual selection falls back to this chat's own linked task")
        ended(vm); vm.conversation.newConversation()
        expect(try taskIDs(vm).isEmpty, "New conversation excludes the old completed engine record")
        vm.engine.currentRecord = nil
        let emptyThreadIDs = try taskIDs(vm)
        expect(vm.unifiedFocusedTaskID == nil && emptyThreadIDs.isEmpty, "No global focus survives an empty new conversation")
        expect(vm.conversation.openConversation(a), "Opening the original conversation remains usable")
        expect(try taskIDs(vm).contains(actual.uuidString), "Explicitly linked ended task stays available in its own chat")
        for _ in 0..<8 { _ = try await message(vm, text: "只讨论其他信息") }
        expect(try taskIDs(vm).contains(actual.uuidString), "The complete submitted conversation retains its own task beyond the 12-message routing window")
        let originalMessages = vm.conversation.messages
        vm.conversation.newConversation(); let b = vm.conversation.currentConversationID, bm = try await message(vm)
        _ = vm.submitForChecks(id: UUID(), conversationID: b, messageID: bm, text: "B的任务")
        ended(vm); vm.engine.currentRecord = nil
        _ = vm.conversation.openConversation(a)
        expect(try taskIDs(vm) == [actual.uuidString], "Opening A after B excludes B's unrelated completed focus")
        expect(vm.conversation.messages == originalMessages, "Switching task focus does not rewrite A's messages")
        let restarted = PhoneAgentViewModel(url: folder.appendingPathComponent("chat-1.json"))
        restarted.history.records = vm.history.records; restarted.installCallbacks()
        let restartedIDs = try taskIDs(restarted)
        expect(restarted.unifiedFocusedTaskID == actual && restartedIDs.contains(actual.uuidString), "Stored message links recover own-chat focus without restoring execution authority")
        expect(!restarted.engine.running && !restarted.pendingForChecks, "Restart restores no live submission or running task")

        let selected = make(), selectedChat = selected.conversation.currentConversationID
        _ = try await message(selected)
        let selectedRecord = PhoneTaskRecord(title: "界面选中的历史任务", goal: "selected", summary: "completed", outcome: .completed)
        selected.history.records = [selectedRecord]; selected.unifiedFocusedTaskID = selectedRecord.id
        expect(try taskIDs(selected).contains(selectedRecord.id.uuidString), "Existing task-page focus selection remains usable in the current conversation")
        selected.conversation.newConversation()
        let selectedNewIDs = try taskIDs(selected)
        expect(selected.unifiedFocusedTaskID == nil && selectedNewIDs.isEmpty, "A manually selected task does not leak into a new conversation")
        selected.unifiedFocusedTaskID = selectedRecord.id; selected.conversation.clear()
        let selectedClearedIDs = try taskIDs(selected)
        expect(selected.unifiedFocusedTaskID == nil && selectedClearedIDs.isEmpty, "Clearing the current conversation also clears explicit task focus")
        selected.unifiedFocusedTaskID = selectedRecord.id
        _ = selected.conversation.openConversation(selectedChat)
        let selectedOpenedIDs = try taskIDs(selected)
        expect(selected.unifiedFocusedTaskID == nil && selectedOpenedIDs.isEmpty, "Opening an unrelated stored conversation clears explicit task focus")
        selected.unifiedFocusedTaskID = selectedRecord.id
        let newerTaskMessage = try await message(selected)
        _ = selected.submitForChecks(id: UUID(), conversationID: selectedChat, messageID: newerTaskMessage, text: "从旧任务页发起的新任务")
        expect(selected.unifiedFocusedTaskID == selected.engine.currentRecord?.id, "A newly linked task supersedes the older task-page selection")

        let delayed = make(), oldChat = delayed.conversation.currentConversationID, oldMessage = try await message(delayed)
        let delayedID = UUID(); delayed.preparationReady = false
        expect(!delayed.submitForChecks(id: delayedID, conversationID: oldChat, messageID: oldMessage, text: "等待准备的任务") && delayed.preparingAutomatically, "Delayed task stays reserved while preparation runs")
        expect(delayed.conversation.messages.last?.text.contains("任务尚未开始") == true, "Preparation wait explicitly states execution has not started")
        delayed.conversation.newConversation(); let newChat = delayed.conversation.currentConversationID
        delayed.conversation.draft = "新对话尚未发送的草稿"
        delayed.preparationReady = true; delayed.step = .ready
        try await wait { !delayed.preparingAutomatically }
        let delayedActual = delayed.engine.currentRecord!.id
        expect(delayed.engine.starts == [delayedID], "Preparation launches exactly the reserved task once")
        expect(linked(delayed, chat: oldChat, message: oldMessage) == delayedActual, "Delayed publication links the original stored conversation/message")
        expect(delayed.conversation.conversations.first(where: { $0.id == oldChat })?.messages.first(where: { $0.id == oldMessage })?.text == "任务已启动。", "Late start acknowledgement is written to the original offscreen chat")
        expect(delayed.conversation.currentConversationID == newChat && delayed.conversation.draft == "新对话尚未发送的草稿" && delayed.conversation.messages.isEmpty, "Historical linkage preserves current chat, draft and messages")
        expect(delayed.unifiedFocusedTaskID == nil, "Delayed record cannot focus the replacement conversation")
        expect(try taskIDs(delayed).isEmpty, "An unlinked replacement conversation cannot import another conversation's active task")
        ended(delayed)
        expect(try taskIDs(delayed).isEmpty, "Ended delayed task is no longer imported into the unlinked replacement chat")
        _ = delayed.conversation.openConversation(oldChat)
        expect(delayed.conversation.messages.last?.taskID == delayedActual, "Opening the original chat shows its delayed task link")

        let newerSelection = make(), newerSelectionChat = newerSelection.conversation.currentConversationID, newerSelectionMessage = try await message(newerSelection)
        newerSelection.preparationReady = false
        _ = newerSelection.submitForChecks(id: UUID(), conversationID: newerSelectionChat, messageID: newerSelectionMessage, text: "同对话的旧请求")
        let chosenLater = UUID(); newerSelection.unifiedFocusedTaskID = chosenLater
        newerSelection.preparationReady = true; newerSelection.step = .ready
        try await wait { !newerSelection.preparingAutomatically }
        expect(newerSelection.unifiedFocusedTaskID == chosenLater, "A delayed link cannot take focus from a later explicit same-chat selection")
        let otherSelection = make(), otherSelectionChat = otherSelection.conversation.currentConversationID, otherSelectionMessage = try await message(otherSelection)
        otherSelection.preparationReady = false
        _ = otherSelection.submitForChecks(id: UUID(), conversationID: otherSelectionChat, messageID: otherSelectionMessage, text: "其他对话的旧请求")
        otherSelection.conversation.newConversation(); let otherChosen = UUID(); otherSelection.unifiedFocusedTaskID = otherChosen
        otherSelection.preparationReady = true; otherSelection.step = .ready
        try await wait { !otherSelection.preparingAutomatically }
        expect(otherSelection.unifiedFocusedTaskID == otherChosen, "An old-chat callback preserves the replacement chat's explicit focus")

        let loading = make(), loadingChat = loading.conversation.currentConversationID, loadingMessage = try await message(loading)
        loading.preparationReady = false
        _ = loading.submitForChecks(id: UUID(), conversationID: loadingChat, messageID: loadingMessage, text: "旧对话的延迟任务")
        loading.conversation.newConversation(); loading.conversation.unifiedRoute = nil
        loading.conversation.draft = "新对话正在等待回答"
        let modelIndex = OfflineModel.shared.requests.count
        _ = loading.conversation.send(settings: .init(), apiKey: "offline-unused", memories: MemoryStore())
        try await wait { OfflineModel.shared.requests.count > modelIndex }
        let waitingID = loading.conversation.messages.last?.id
        loading.preparationReady = true; loading.step = .ready
        try await wait { !loading.preparingAutomatically }
        expect(loading.conversation.loading && loading.conversation.messages.last?.id == waitingID, "Updating an old chat link does not cancel a live request in the new chat")
        OfflineModel.shared.complete(modelIndex, answer: "只回答新对话的问题")
        try await wait { !loading.conversation.loading }
        expect(loading.conversation.messages.last?.text == "只回答新对话的问题", "Current request still completes after a historical link update")
        expect(linked(loading, chat: loadingChat, message: loadingMessage) == loading.engine.currentRecord?.id, "Old task and new answer keep separate message ownership")

        let sameGoal = make(), sameChat = sameGoal.conversation.currentConversationID, sameMessage = try await message(sameGoal)
        let ownID = UUID(); sameGoal.preparationReady = false
        _ = sameGoal.submitForChecks(id: ownID, conversationID: sameChat, messageID: sameMessage, text: "相同的任务文字")
        let foreign = PhoneTaskRecord(title: "别的执行", goal: "相同的任务文字", summary: "same text")
        sameGoal.engine.onRecord?(foreign)
        expect(sameGoal.pendingForChecks && linked(sameGoal, chat: sameChat, message: sameMessage) == nil, "Same goal text from another UUID cannot consume or link a pending submission")
        sameGoal.preparationReady = true; sameGoal.step = .ready
        try await wait { !sameGoal.preparingAutomatically }
        expect(linked(sameGoal, chat: sameChat, message: sameMessage) == ownID, "Only the reserved task UUID can finish the original link")

        let lateRecord = make(), lateRecordChat = lateRecord.conversation.currentConversationID, lateRecordMessage = try await message(lateRecord), lateRecordID = UUID()
        lateRecord.engine.publishesRecords = false
        expect(lateRecord.submitForChecks(id: lateRecordID, conversationID: lateRecordChat, messageID: lateRecordMessage, text: "等待真正启动回执") && lateRecord.pendingForChecks,
               "An accepted executor start retains its origin until the actual record callback")
        lateRecord.conversation.newConversation(); lateRecord.conversation.draft = "新会话草稿"
        lateRecord.engine.onRecord?(PhoneTaskRecord(title: "无关回执", goal: "等待真正启动回执", summary: "foreign"))
        expect(lateRecord.pendingForChecks && linked(lateRecord, chat: lateRecordChat, message: lateRecordMessage) == nil,
               "A late unrelated record cannot claim a live handoff even when its goal text matches")
        lateRecord.engine.onRecord?(lateRecord.engine.currentRecord!)
        expect(!lateRecord.pendingForChecks && linked(lateRecord, chat: lateRecordChat, message: lateRecordMessage) == lateRecordID &&
               lateRecord.conversation.conversations.first(where: { $0.id == lateRecordChat })?.messages.first(where: { $0.id == lateRecordMessage })?.text == "任务已启动。",
               "A late matching record alone confirms started and links the original message")
        expect(lateRecord.conversation.messages.isEmpty && lateRecord.conversation.draft == "新会话草稿",
               "Late record confirmation leaves the replacement conversation and draft untouched")
        for action in ["pause", "stop"] {
            let awaitingRecord = make(), chat = awaitingRecord.conversation.currentConversationID, msg = try await message(awaitingRecord)
            awaitingRecord.engine.publishesRecords = false
            _ = awaitingRecord.submitForChecks(id: UUID(), conversationID: chat, messageID: msg, text: "执行器已接收但还没有回执")
            let matchingRecord = awaitingRecord.engine.currentRecord!
            if action == "pause" { _ = awaitingRecord.pauseTask() } else { awaitingRecord.stop() }
            let reported = awaitingRecord.conversation.messages.first(where: { $0.id == msg })?.text ?? ""
            expect(reported.contains("尚未收到启动回执") && !reported.contains("任务未启动") && !awaitingRecord.pendingForChecks,
                   "\(action) before a delayed record distinguishes unconfirmed receipt from a claim that execution never started")
            awaitingRecord.engine.onRecord?(matchingRecord)
            expect(awaitingRecord.conversation.messages.first(where: { $0.id == msg })?.text == reported && linked(awaitingRecord, chat: chat, message: msg) == nil,
                   "\(action) invalidates the canceled pending handoff so a late record cannot overwrite its receipt")
        }

        for cancellation in ["cancel preparation", "pause", "stop", "decline"] {
            let canceled = make(), chat = canceled.conversation.currentConversationID, msg = try await message(canceled)
            canceled.preparationReady = false
            _ = canceled.submitForChecks(id: UUID(), conversationID: chat, messageID: msg, text: "取消后不应关联")
            switch cancellation {
            case "cancel preparation": canceled.cancelAutomaticPreparation()
            case "pause": _ = canceled.pauseTask()
            case "stop": canceled.stop()
            default: canceled.declineConsent()
            }
            expect(!canceled.pendingForChecks && !canceled.preparingAutomatically, "\(cancellation) releases pending conversation ownership")
            expect(canceled.conversation.messages.first(where: { $0.id == msg })?.text.contains("任务未启动") == true, "\(cancellation) explains the canceled handoff on the originating assistant message")
            canceled.preparationReady = true; canceled.step = .ready
            expect(canceled.startAgent(), "Independent manual task can start after \(cancellation)")
            expect(linked(canceled, chat: chat, message: msg) == nil, "A later same-text task cannot inherit the canceled request after \(cancellation)")
        }
        for failure in ["model step", "changed draft", "engine preflight"] {
            let failed = make(), chat = failed.conversation.currentConversationID, msg = try await message(failed)
            if failure == "engine preflight" { failed.engine.acceptsStart = false }
            else { failed.preparationReady = false; failed.step = failure == "model step" ? .model : .screen }
            _ = failed.submitForChecks(id: UUID(), conversationID: chat, messageID: msg, text: "失败的请求")
            if failure == "changed draft" { failed.goal = "更新后的任务草稿" }
            try await wait { !failed.preparingAutomatically }
            expect(!failed.pendingForChecks && failed.engine.starts.isEmpty, "\(failure) leaves no stale request capable of claiming another task")
            expect(failed.conversation.messages.first(where: { $0.id == msg })?.text.contains("任务未启动") == true, "\(failure) cannot leave an unexplained execution promise")
        }

        let consent = make(), consentChat = consent.conversation.currentConversationID, consentMessage = try await message(consent), consentID = UUID()
        PrivacyConsent.approved = false
        _ = consent.submitForChecks(id: consentID, conversationID: consentChat, messageID: consentMessage, text: "等授权再开始")
        expect(consent.consentPendingForChecks && consent.pendingForChecks && consent.engine.starts.isEmpty, "Consent wait retains origin without starting a task")
        expect(consent.conversation.messages.last?.text.contains("等待已有的数据使用授权") == true && consent.conversation.messages.last?.taskID == nil, "Existing consent is a waiting handoff, never an already-started task card")
        consent.conversation.newConversation(); consent.acceptConsent()
        expect(consent.engine.starts == [consentID] && linked(consent, chat: consentChat, message: consentMessage) == consentID, "Explicit consent resumes the exact original task and chat link")
        for mode in ["pause", "stop", "decline", "new consent dialog"] {
            let canceled = make(), chat = canceled.conversation.currentConversationID, msg = try await message(canceled)
            PrivacyConsent.approved = false
            _ = canceled.submitForChecks(id: UUID(), conversationID: chat, messageID: msg, text: "等待授权后取消")
            switch mode {
            case "pause": _ = canceled.pauseTask()
            case "stop": canceled.stop()
            case "decline": canceled.declineConsent()
            default: canceled.requestConsent()
            }
            canceled.acceptConsent()
            expect(!canceled.pendingForChecks && !canceled.consentPendingForChecks && canceled.engine.starts.isEmpty, "\(mode) prevents later consent from restarting a canceled request")
            expect(canceled.conversation.messages.first(where: { $0.id == msg })?.text.contains("任务未启动") == true, "\(mode) leaves an explicit not-started result")
        }

        let timeout = make(), timeoutChat = timeout.conversation.currentConversationID, timeoutMessage = try await message(timeout)
        timeout.preparationReady = false
        _ = timeout.submitForChecks(id: UUID(), conversationID: timeoutChat, messageID: timeoutMessage, text: "等待准备超时")
        timeout.conversation.newConversation(); let timeoutReplacement = timeout.conversation.currentConversationID
        timeout.conversation.draft = "当前草稿不能被旧交接污染"
        timeout.cancelAutomaticPreparation(message: "准备超时，已停止等待")
        expect(timeout.engine.starts.isEmpty && !timeout.pendingForChecks, "Timeout cancellation drops only the waiting origin without starting or replaying work")
        expect(timeout.conversation.conversations.first(where: { $0.id == timeoutChat })?.messages.first(where: { $0.id == timeoutMessage })?.text.contains("准备超时") == true, "Timeout reason is saved in the offscreen originating chat")
        expect(timeout.conversation.currentConversationID == timeoutReplacement && timeout.conversation.messages.isEmpty && timeout.conversation.draft == "当前草稿不能被旧交接污染", "Late canceled handoff preserves the new chat and draft")

        let gated = make(), gatedChat = gated.conversation.currentConversationID, gatedMessage = try await message(gated)
        gated.preparationReady = false; gated.step = .assistiveTouch; AccessibilitySettings.gateNext = true
        _ = gated.submitForChecks(id: UUID(), conversationID: gatedChat, messageID: gatedMessage, text: "旧准备")
        try await wait { AccessibilitySettings.pending != nil }
        let oldPreparation = gated.automaticPreparation
        gated.cancelAutomaticPreparation(); gated.step = .screen
        let newerID = UUID()
        _ = gated.submitForChecks(id: newerID, conversationID: gatedChat, messageID: gatedMessage, text: "新准备")
        AccessibilitySettings.resume(); await oldPreparation?.value
        expect(gated.preparingAutomatically && gated.pendingForChecks, "Late old preparation cleanup cannot release a replacement submission")
        gated.preparationReady = true; gated.step = .ready
        try await wait { !gated.preparingAutomatically }
        expect(gated.engine.starts == [newerID], "Replacement preparation retains its own task identity")

        let cleared = make(), clearedChat = cleared.conversation.currentConversationID, clearedMessage = try await message(cleared)
        cleared.preparationReady = false
        _ = cleared.submitForChecks(id: UUID(), conversationID: clearedChat, messageID: clearedMessage, text: "旧消息被清除")
        cleared.conversation.clear(); cleared.conversation.newConversation()
        cleared.preparationReady = true; cleared.step = .ready
        try await wait { !cleared.preparingAutomatically }
        expect(!cleared.conversation.conversations.contains { $0.id == clearedChat }, "Delayed record never recreates a cleared original conversation")
        expect(cleared.conversation.messages.isEmpty && cleared.unifiedFocusedTaskID == nil, "Missing original message cannot redirect linkage to the current chat")
        let conflict = make(), conflictMessage = try await message(conflict), first = UUID()
        conflict.conversation.linkTask(first, to: conflictMessage)
        conflict.conversation.linkTask(UUID(), to: conflictMessage)
        expect(conflict.conversation.messages.last?.taskID == first, "A message already linked to another task cannot be silently rebound")

        let blocked = make(), blockedChat = blocked.conversation.currentConversationID, blockedMessage = try await message(blocked)
        let blockedPath = folder.appendingPathComponent("chat-\(serial).json"), preservedPath = folder.appendingPathComponent("preserved-\(serial).json")
        blocked.preparationReady = false
        _ = blocked.submitForChecks(id: UUID(), conversationID: blockedChat, messageID: blockedMessage, text: "保存链接失败")
        blocked.conversation.newConversation(); blocked.conversation.draft = "不能被覆盖的新草稿"
        let originalBytes = try Data(contentsOf: blockedPath)
        try FileManager.default.moveItem(at: blockedPath, to: preservedPath)
        try FileManager.default.createDirectory(at: blockedPath, withIntermediateDirectories: false)
        blocked.preparationReady = true; blocked.step = .ready
        try await wait { !blocked.preparingAutomatically }
        expect(!blocked.conversation.storageError.isEmpty && linked(blocked, chat: blockedChat, message: blockedMessage) == nil, "Failed historical-link storage remains an error without committing a memory-only success")
        let preservedAfterFailure = try Data(contentsOf: preservedPath)
        expect(blocked.conversation.draft == "不能被覆盖的新草稿" && preservedAfterFailure == originalBytes, "Historical-link failure preserves current draft and previous durable bytes")
        try FileManager.default.removeItem(at: blockedPath)
        try FileManager.default.moveItem(at: preservedPath, to: blockedPath)
        expect(AccessibilitySettings.pending == nil && OfflineModel.shared.requests.allSatisfy { $0.continuation == nil }, "No synthetic settings/model gates remain unresolved")
        let report: [String: Any] = ["checks": checks, "failures": failures,
            "scope": "Actual conversation/store and complete extracted focus/context/onRecord/start/preparation/consent/cancel/stop/pause methods; synthetic engine, readiness, UI, capture, BLE and audio. No network/model/phone acceptance."]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(String(decoding: bytes, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
