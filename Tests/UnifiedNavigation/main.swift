import Foundation

@main struct UnifiedNavigationRegressions {
    @MainActor static func main() throws {
        var checks = 0, failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sela-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func fixture(_ name: String) -> (NavigationModel, NavigationHarness, URL) {
            let url = folder.appendingPathComponent(name + ".json")
            let model = NavigationModel(AssistantConversation(store: AssistantConversationStore(url: url)))
            return (model, NavigationHarness(model), url)
        }
        let text = ComposerAttachment(name: "未发出的原文.txt", kind: .text, byteCount: 24, text: "保留原文\n不自行重写", imageJPEG: nil)
        let image = ComposerAttachment(name: "未发出的图.jpg", kind: .image, byteCount: 4, text: "", imageJPEG: Data([0xFF,0xD8,0xFF,0xD9]))
        let materials = [text, image]

        for entry in ["new-task", "new-conversation"] {
            let (model, nav, url) = fixture(entry)
            let chat = model.conversation, origin = chat.currentConversationID
            chat.draft = "旧对话独立草稿\n保留我的换行"
            chat.retainDraftAttachments(materials, conversationID: origin)
            model.legacyAttachments = materials
            let oldGoal = model.goal, oldPlan = model.taskPlan, queue = model.queueIDs, task = model.engine.id
            model.engine.running = true
            if entry == "new-task" { nav.pressNewTask() } else { nav.pressNewConversation() }
            let fresh = chat.currentConversationID
            expect(fresh != origin, entry + " creates a separate conversation ID")
            expect(nav.selectedDestination == .assistant && !nav.sidebarOpen, entry + " opens the unified conversation and closes sidebar")
            expect(chat.messages.isEmpty && chat.draft.isEmpty && chat.retryAttachments.isEmpty, entry + " opens an actually blank composer")
            expect(chat.focusedTaskID == nil, entry + " inherits no execution authority or task focus")
            expect(model.goal == oldGoal && model.taskPlan == oldPlan && model.legacyAttachments == materials, entry + " preserves legacy task draft and materials")
            expect(model.queueIDs == queue && model.engine.id == task, entry + " preserves execution identity and queue")
            expect(model.pauseCalls == 1 && model.engine.paused && !model.engine.running, entry + " retains the original safe navigation pause")
            let old = chat.conversations.first { $0.id == origin }
            expect(old?.draft == "旧对话独立草稿\n保留我的换行" && old?.draftAttachments == materials, entry + " archives exact old draft and attachment bytes")
            expect(AssistantConversationStore(url: url).records.first { $0.id == origin }?.draftAttachments == materials, entry + " persists old materials rather than only caching them in a view")
            nav.pressNewTask(); let next = chat.currentConversationID
            nav.pressNewConversation()
            expect(next != fresh && chat.currentConversationID != next, entry + " both entries keep creating independent conversations even on the same page")
            expect(model.pauseCalls == 1 && model.queueIDs == queue, entry + " repeated fresh conversations neither restart nor repeatedly pause the existing task")
            nav.openChat(origin)
            expect(chat.currentConversationID == origin && chat.retryAttachments == materials && chat.draft == old?.draft, entry + " restores original draft and attachments on reopen")
            let restarted = AssistantConversation(store: AssistantConversationStore(url: url))
            expect(restarted.currentConversationID == origin && restarted.retryAttachments == materials && restarted.draft == old?.draft, entry + " survives service reconstruction from the real archive")
        }

        let (legacyDraftModel, legacyDraftNav, legacyDraftURL) = fixture("legacy-task-draft")
        legacyDraftNav.attachmentDraft.items = materials
        let legacyTaskText = legacyDraftModel.goal
        legacyDraftNav.pressNewTask()
        let archivedLegacy = legacyDraftModel.conversation.conversations.first { $0.draft == legacyTaskText && $0.messages.isEmpty }
        expect(archivedLegacy?.draftAttachments == materials, "Old task composer text and materials are reachable as a separate legacy-input history draft")
        expect(archivedLegacy?.messages.isEmpty == true && legacyDraftModel.goal == legacyTaskText, "Legacy draft preservation creates no sent turn and does not clear the original field")
        let migratedCount = legacyDraftModel.conversation.conversations.count
        legacyDraftNav.pressNewConversation()
        expect(legacyDraftModel.conversation.conversations.count == migratedCount, "Identical legacy source is not repeatedly archived when opening new chats")
        let migratedRestart = AssistantConversation(store: AssistantConversationStore(url: legacyDraftURL))
        expect(migratedRestart.openConversation(archivedLegacy!.id) && migratedRestart.draft == legacyTaskText && migratedRestart.retryAttachments == materials, "Migrated legacy draft is recoverable through the real conversation archive")
        let currentMigrationID = migratedRestart.currentConversationID
        expect(migratedRestart.preserveLegacyInput("", attachments: [image]) && migratedRestart.currentConversationID == currentMigrationID, "Archiving an attachment-only legacy draft does not navigate or activate it")
        expect(migratedRestart.conversations.contains { $0.draft.isEmpty && $0.draftAttachments == [image] }, "Attachment-only legacy input remains reopenable")
        let beforeRejectedMigration = migratedRestart.conversations
        expect(!migratedRestart.preserveLegacyInput(String(repeating: "长", count: 4001), attachments: []) && migratedRestart.conversations == beforeRejectedMigration,
               "Oversized legacy draft is explicitly rejected without truncation or deleting prior history")

        for source in ["completed-history", "queued", "current-engine", "effective-goal"] {
            let (model, nav, _) = fixture("submitted-" + source)
            model.goal = "每天 9:20，名称 work"
            var completed = PhoneTaskRecord(title: "Clock", goal: model.goal, summary: "真实任务回执", outcome: .completed)
            completed.attachments = materials
            nav.attachmentDraft.items = materials
            if source == "completed-history" { model.history.records = [completed] }
            if source == "queued" { model.taskQueue.items = [.init(record: completed)] }
            if source == "current-engine" { model.engine.currentRecord = completed }
            if source == "effective-goal" {
                completed.goal = "旧原要求"
                completed.effectiveGoalOverride = model.goal
                model.history.records = [completed]
            }
            nav.pressNewTask()
            expect(model.conversation.conversations.isEmpty && model.goal == "每天 9:20，名称 work",
                   source + " retaining agent.currentGoal does not fabricate an unsent draft")
        }
        let (pendingModel, pendingNav, _) = fixture("pending-request")
        pendingModel.pendingConversationTask = .init(goal: pendingModel.goal)
        pendingNav.pressNewConversation()
        expect(pendingModel.conversation.conversations.isEmpty, "Already handed-off pending request is not recopied as a legacy draft")
        let archivedGoal = "已经提交的原生长任务"
        var submittedUser = AssistantMessage(role: "user", text: archivedGoal)
        submittedUser.attachments = materials
        var submittedReply = AssistantMessage(role: "assistant", text: "已完成的真实任务")
        submittedReply.taskID = UUID()
        let submittedMessages = [submittedUser, submittedReply]
        expect(ConversationTaskScope.containsSubmittedInput(archivedGoal, attachments: materials, in: submittedMessages),
               "The original user input and linked task prove submission after bounded task-history eviction")
        expect(!ConversationTaskScope.containsSubmittedInput(archivedGoal, attachments: [], in: submittedMessages),
               "Different materials remain a distinct legacy input")
        expect(!ConversationTaskScope.containsSubmittedInput(archivedGoal, attachments: materials,
               in: [submittedUser, .init(role: "assistant", text: "尚未提交"), .init(role: "user", text: "另一项请求"), submittedReply]),
               "A different later user request cannot lend its task link to an earlier input")
        expect(!ConversationTaskScope.containsSubmittedInput(archivedGoal, attachments: materials,
               in: [submittedUser, .init(role: "assistant", text: "只有文字，没有任务身份")]),
               "An unlinked answer does not prove execution submission")
        let submittedURL = folder.appendingPathComponent("evicted-submitted.json"), submittedID = UUID()
        let submittedStore = AssistantConversationStore(url: submittedURL)
        try submittedStore.upsert(.init(id: submittedID, title: "真实归档任务", messages: submittedMessages,
            createdAt: Date(), updatedAt: Date(), recipient: "", draft: "", draftAttachments: []), currentConversationID: submittedID)
        let archivedModel = NavigationModel(AssistantConversation(store: AssistantConversationStore(url: submittedURL)))
        archivedModel.goal = archivedGoal
        let archivedNav = NavigationHarness(archivedModel)
        archivedNav.attachmentDraft.items = materials
        expect(archivedModel.history.records.isEmpty && archivedModel.taskQueue.items.isEmpty && archivedModel.engine.currentRecord == nil,
               "Eviction regression uses only the saved conversation; no live or queued task record supplies the match")
        archivedNav.pressNewConversation()
        expect(!archivedModel.conversation.conversations.contains { $0.messages.isEmpty && $0.draft == archivedGoal },
               "Opening after archive reconstruction does not resurrect an evicted submitted task as a draft")
        expect(archivedModel.goal == archivedGoal && archivedModel.conversation.conversations.first { $0.id == submittedID }?.messages == submittedMessages,
               "Submission deduplication retains the original legacy field, messages and exact attachments")
        let (differentModel, differentNav, _) = fixture("new-materials")
        let finished = PhoneTaskRecord(title: "过去任务", goal: differentModel.goal, summary: "已完成", outcome: .completed)
        differentModel.history.records = [finished]
        differentNav.attachmentDraft.items = [image]
        differentNav.pressNewTask()
        expect(differentModel.conversation.conversations.first?.draftAttachments == [image], "Same goal with newly selected materials is retained as distinct legacy input")
        expect(differentModel.conversation.conversations.first?.title.hasPrefix("遗留输入 · ") == true,
               "Unknown provenance is labelled legacy input, never asserted to be an unsent or completed task")

        let (noticeModel, noticeNav, _) = fixture("notice-ownership")
        noticeModel.notice = "航班信息已复制，请在携程核对并选票"
        noticeModel.conversation.draft = "旧会话草稿"
        noticeModel.conversation.cancel()
        let noticeOrigin = noticeModel.conversation.currentConversationID
        noticeNav.pressNewTask()
        expect(noticeModel.notice.isEmpty, "New-task entry clears the old conversation's copied-flight notice")
        noticeModel.notice = "旧会话查询失败"
        noticeNav.pressNewConversation()
        expect(noticeModel.notice.isEmpty, "New-conversation entry clears an old error notice on the same destination")
        noticeModel.notice = "新会话的临时提示"
        noticeNav.openChat(noticeOrigin)
        expect(noticeModel.notice.isEmpty && noticeModel.conversation.draft == "旧会话草稿", "Opening an existing conversation clears the previous chat notice without altering its draft")
        noticeModel.notice = "旧交接提示"
        var noticeRecord = PhoneTaskRecord(title: "重用", goal: "查看计算器", summary: "原任务回执")
        expect(noticeModel.reuseTaskInNewConversation(noticeRecord) && noticeModel.notice.isEmpty, "Successful reuse clears the old conversation notice")
        noticeModel.engine.running = true
        noticeModel.engineError = "原执行器错误证据"
        noticeModel.pauseNotice = "已按原导航安全规则暂停任务"
        noticeModel.notice = "另一个对话的旧提示"
        noticeNav.selectedDestination = .tasks
        noticeNav.pressNewConversation()
        expect(noticeModel.notice == "已按原导航安全规则暂停任务" && noticeModel.engine.paused, "New navigation retains the fresh safety-pause notice after clearing the stale conversation notice")
        expect(noticeModel.engineError == "原执行器错误证据", "Conversation notice cleanup never clears executor errors")
        noticeRecord.goal = "updated"

        let (onlyModel, onlyNav, onlyURL) = fixture("attachment-only")
        let only = onlyModel.conversation, onlyID = only.currentConversationID
        only.retainDraftAttachments(materials, conversationID: onlyID)
        expect(only.conversations.first { $0.id == onlyID }?.draft.isEmpty == true && only.conversations.first { $0.id == onlyID }?.draftAttachments == materials,
               "Attachment-only drafts become reopenable conversation records")
        onlyNav.pressNewConversation()
        expect(only.openConversation(onlyID) && only.draft.isEmpty && only.retryAttachments == materials, "Attachment-only conversation restores without invented text")
        let onlyRestart = AssistantConversation(store: AssistantConversationStore(url: onlyURL))
        expect(onlyRestart.retryAttachments == materials, "Attachment-only material survives archive reconstruction")
        let beforeInvalid = try Data(contentsOf: onlyURL)
        only.retainDraftAttachments([text,text], conversationID: onlyID)
        expect(only.retryAttachments == materials && (try? Data(contentsOf: onlyURL)) == beforeInvalid, "Invalid draft materials preserve both selection and archive bytes")
        only.retainDraftAttachments([], conversationID: UUID())
        expect(only.retryAttachments == materials, "Stale view identity cannot delete current materials")
        only.retainDraftAttachments([], conversationID: onlyID)
        expect(only.retryAttachments.isEmpty && !AssistantConversationStore(url: onlyURL).records.contains { $0.id == onlyID }, "Explicitly removing the only materials removes just that empty draft")

        let (legacyModel, _, legacyURL) = fixture("old-archive")
        legacyModel.conversation.draft = "旧版文字草稿"
        legacyModel.conversation.cancel()
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
        var records = document["records"] as! [[String: Any]]
        for index in records.indices { records[index].removeValue(forKey: "draftAttachments") }
        document["records"] = records
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: legacyURL)
        let legacyBytes = try Data(contentsOf: legacyURL)
        let legacy = AssistantConversation(store: AssistantConversationStore(url: legacyURL))
        expect(legacy.storageError.isEmpty && legacy.draft == "旧版文字草稿" && legacy.retryAttachments.isEmpty, "Old JSON without optional draftAttachments decodes unchanged")
        expect((try? Data(contentsOf: legacyURL)) == legacyBytes, "Reading old JSON performs no archive migration rewrite")

        let (reuseModel, _, reuseURL) = fixture("reuse")
        let reuse = reuseModel.conversation, originalChat = reuse.currentConversationID
        reuse.draft = "当前还没发出的聊天内容"
        reuse.retainDraftAttachments([image], conversationID: originalChat)
        var record = PhoneTaskRecord(title: "原任务", goal: "打开计算器，只查看，不改设置。", summary: "上次回执")
        record.attachments = materials
        let queue = reuseModel.queueIDs, engineID = reuseModel.engine.id, legacyGoal = reuseModel.goal
        let requests = OfflineModel.shared.requests.count
        expect(reuseModel.reuseTaskInNewConversation(record), "Reuse stages an editable new conversation")
        expect(reuse.currentConversationID != originalChat && reuse.messages.isEmpty && reuse.focusedTaskID == nil, "Reuse inherits no record ID, receipt or execution focus")
        expect(reuse.draft == record.effectiveGoal && reuse.retryAttachments == materials, "Reuse copies exact requirements and materials without sending")
        expect(reuse.conversations.first { $0.id == originalChat }?.draft == "当前还没发出的聊天内容" && reuse.conversations.first { $0.id == originalChat }?.draftAttachments == [image], "Reuse preserves the previous conversation draft and materials")
        expect(reuseModel.goal == legacyGoal && reuseModel.engine.id == engineID && reuseModel.queueIDs == queue && reuseModel.pauseCalls == 0, "Reuse staging does not overwrite legacy draft, restart, pause or replace execution")
        expect(OfflineModel.shared.requests.count == requests, "Reuse dispatches no model request or phone action")
        let persistedReuse = AssistantConversation(store: AssistantConversationStore(url: reuseURL))
        expect(persistedReuse.draft == record.effectiveGoal && persistedReuse.retryAttachments == materials, "Staged reuse selection is actually saved")
        let stagedID = reuse.currentConversationID
        var tooLong = record; tooLong.goal = String(repeating: "长", count: 4001)
        expect(!reuseModel.reuseTaskInNewConversation(tooLong) && reuse.currentConversationID == stagedID && reuse.draft == record.effectiveGoal,
               "Out-of-range reuse is explicit and preserves the editable conversation without truncation")
        var invalid = record; invalid.attachments = [text,text]
        expect(!reuseModel.reuseTaskInNewConversation(invalid) && reuse.currentConversationID == stagedID && reuse.retryAttachments == materials,
               "Invalid reuse attachments never replace the current conversation")

        let originURL = folder.appendingPathComponent("late-origin.json"), originID = UUID(), messageID = UUID(), taskID = UUID()
        var ack = AssistantMessage(id: messageID, role: "assistant", text: "正在准备设备，任务尚未开始执行。")
        let originRecord = AssistantConversationRecord(id: originID, title: "原任务请求", messages: [AssistantMessage(role: "user", text: "打开时钟"),ack], createdAt: Date(), updatedAt: Date(), recipient: "", draft: "原会话草稿", draftAttachments: materials)
        let originStore = AssistantConversationStore(url: originURL)
        try originStore.upsert(originRecord, currentConversationID: originID)
        let originModel = NavigationModel(AssistantConversation(store: AssistantConversationStore(url: originURL))), originNav = NavigationHarness(originModel)
        originNav.pressNewTask(); let replacement = originModel.conversation.currentConversationID
        expect(originModel.conversation.linkTask(taskID,to:messageID,in:originID), "Late record links to the actual originating assistant message")
        expect(originModel.conversation.reportTaskHandoff(text:"任务已启动。",to:messageID,in:originID,onlyIfUnlinked:false), "Late handoff report updates its original archived conversation")
        expect(originModel.conversation.currentConversationID == replacement && originModel.conversation.messages.isEmpty && originModel.conversation.focusedTaskID == nil, "Late task callback cannot claim the new empty conversation")
        let savedOrigin = AssistantConversationStore(url: originURL).records.first { $0.id == originID }
        expect(savedOrigin?.messages.last?.taskID == taskID && savedOrigin?.messages.first?.text == "打开时钟" && savedOrigin?.draftAttachments == materials, "Original task identity, human text and draft materials remain owned by origin")
        ack.text = "unused"

        let report: [String: Any] = ["checks":checks,"failures":failures,"limits":"Real extracted ContentView navigation and reuse methods plus real conversation/store; engine and platform boundaries synthetic. No device, simulator, model or network."]
        let bytes = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count > 1 { try bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        print(String(data:bytes,encoding:.utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
