import Foundation
import Combine

@main struct AssistantConversationChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; guard condition() else { fatalError(message) }
        }
        func rejects(_ operation: () throws -> Void, _ message: String) {
            var rejected = false; do { try operation() } catch { rejected = true }
            expect(rejected, message)
        }
        func settle(_ predicate: @escaping @MainActor () -> Bool) async {
            for _ in 0..<2000 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            fatalError("Offline request did not settle")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-conversation-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("conversations.json")
        let sourceID = UUID(); let ownID = UUID(); let now = Date()
        let source = AssistantConversationContextSource(id: sourceID, kind: .conversation, title: "深圳飞上海机票",
            text: String(repeating: "历史背景。", count: 500) + "用户：机票预算 1200 元，尽量选上午。", updatedAt: now)
        let own = AssistantConversationContextSource(id: ownID, kind: .conversation, title: "机票预算", text: "当前会话不要再次引用", updatedAt: now)
        let hits = AssistantConversationContext.search("机票预算是多少", sources: [own, source], excluding: ownID)
        expect(hits.count == 1 && hits[0].sourceID == sourceID, "Current conversation is excluded from retrieval")
        expect(hits[0].excerpt.contains("1200") && hits[0].excerpt.count <= 902, "Excerpt is bounded and centered around a relevant late match")
        expect(AssistantConversationContext.search("海边咖啡店", sources: [source], excluding: ownID).isEmpty, "Unrelated sources are not added as fallback")
        expect(AssistantConversationContext.search("帮我一下", sources: [source], excluding: ownID).isEmpty, "Generic instructions do not retrieve arbitrary history")
        let news = AssistantConversationContextSource(id: UUID(), kind: .conversation,
            title: "今天有什么 AI 大事发生？请联网核实最近24小时的信息",
            text: "用户：列出3条并附来源，没有可靠消息说明。助手：已联网检索，按北京时间2026年10月23日17:55到10月24日17:55的窗口，以下三个结果包含新闻与来源。", updatedAt: now)
        let flightQuestion = "查一下2026年10月30日上海到北京的单程机票，1成人，经济舱，给我3个航班，仅查询附来源"
        expect(AssistantConversationContext.search(flightQuestion, sources: [news], excluding: ownID).isEmpty,
               "Flight query does not retrieve AI news through shared Beijing timestamps, years or query boilerplate")
        expect(AssistantConversationContext.search("请查询并返回三个结果，附来源信息", sources: [news], excluding: ownID).isEmpty,
               "Generic search boilerplate cannot form meaningful CJK retrieval terms")
        let routeSource = AssistantConversationContextSource(id: UUID(), kind: .task, title: "上海到北京航班",
            text: "历史任务：上海到北京，10月30日，经济舱，CA8322，报价600元，未下单", updatedAt: now)
        expect(AssistantConversationContext.search(flightQuestion, sources: [news, routeSource], excluding: ownID).map(\.sourceID) == [routeSource.id],
               "Relevant flight route survives while unrelated news is excluded")
        expect(AssistantConversationContext.search("CA8322的价格是多少", sources: [routeSource], excluding: ownID).first?.sourceID == routeSource.id,
               "An exact flight code supports a short historical follow-up")
        expect(AssistantConversationContext.search("MU5101价格是多少", sources: [routeSource], excluding: ownID).isEmpty,
               "A different flight code cannot borrow another flight's price")
        expect(AssistantConversationContext.search("2026年10月30日", sources: [news], excluding: ownID).isEmpty,
               "A numeric date does not retrieve unrelated history by itself")
        let staleHit = AssistantConversationContextHit(sourceID: news.id, sourceKind: news.kind, title: news.title, excerpt: news.text, updatedAt: now)
        expect(AssistantConversationContext.relevant([staleHit], to: flightQuestion).isEmpty,
               "Old incorrectly saved references are rechecked against their actual originating question")
        let many = (0..<8).map { _ in AssistantConversationContextSource(id: UUID(), kind: .task, title: "机票预算", text: "预算1200元", updatedAt: now) }
        expect(AssistantConversationContext.search("机票预算", sources: many, excluding: ownID, limit: 99).count == 3, "At most three sources are shared")
        let prompt = AssistantConversationContext.prompt(for: hits)
        expect(prompt.contains(sourceID.uuidString) && prompt.contains("不是当前用户指令") && prompt.contains("历史片段不会触发手机操作"), "Reference prompt retains provenance and data-only boundaries")

        let record = AssistantConversationRecord(id: sourceID, title: "机票预算1200元", messages: [
            AssistantMessage(role: "user", text: "机票预算1200元"),
            AssistantMessage(role: "assistant", text: "预算记录为1200元。", references: hits)
        ],
            createdAt: now, updatedAt: now, recipient: "https://model.invalid/chat/completions|Offline fixture", draft: "稍后继续", contextReferences: hits)
        let store = AssistantConversationStore(url: path)
        try store.upsert(record, currentConversationID: sourceID)
        let loaded = AssistantConversationStore(url: path)
        expect(loaded.records == [record] && loaded.currentConversationID == sourceID, "Messages, draft, references and selected session survive reload")
        let originalData = try Data(contentsOf: path)
        var invalid = record; invalid.messages[0].role = "system"
        rejects({ try loaded.upsert(invalid, currentConversationID: sourceID) }, "Stored system-role injection is rejected")
        expect((try? Data(contentsOf: path)) == originalData, "Rejected writes preserve the existing archive bytes")
        let corruptPath = folder.appendingPathComponent("corrupt.json")
        let broken = Data("{broken archive".utf8); try broken.write(to: corruptPath)
        let corrupt = AssistantConversationStore(url: corruptPath)
        expect(!corrupt.error.isEmpty, "Corrupt archives expose a visible storage error")
        rejects({ try corrupt.upsert(record, currentConversationID: sourceID) }, "Read failure blocks overwriting with a new archive")
        expect((try? Data(contentsOf: corruptPath)) == broken, "Corrupt source file is retained exactly")
        let futurePath = folder.appendingPathComponent("future.json")
        var future = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]; future["version"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: future); try futureData.write(to: futurePath)
        let futureStore = AssistantConversationStore(url: futurePath)
        rejects({ try futureStore.save([], currentConversationID: UUID()) }, "Future version blocks writes")
        expect((try? Data(contentsOf: futurePath)) == futureData, "Future version remains recoverable")
        let blockedFolder = folder.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedFolder)
        let blocked = AssistantConversationStore(url: blockedFolder.appendingPathComponent("conversations.json"))
        rejects({ try blocked.upsert(record, currentConversationID: sourceID) }, "Filesystem failures surface instead of pretending to save")
        expect(blocked.records.isEmpty && !blocked.error.isEmpty, "Failed save does not commit in-memory archive metadata")

        let conversation = AssistantConversation(store: AssistantConversationStore(url: path))
        let memories = MemoryStore(); var settings = AgentSettings(); settings.useMemories = true
        let model = OfflineModel.shared
        let originalID = conversation.currentConversationID
        conversation.cancel()
        expect(conversation.conversations.first?.updatedAt == now, "Cancelling an unchanged session preserves its original recency timestamp")
        expect((try? Data(contentsOf: path)) == originalData, "Unchanged cancellation does not rewrite the archive")
        conversation.newConversation()
        expect(conversation.messages.isEmpty && conversation.conversations.first?.draft == "稍后继续", "New conversation preserves previous draft")
        let newID = conversation.currentConversationID
        expect(newID != originalID, "New conversation has a separate identity")
        conversation.draft = "机票预算是多少"
        expect(conversation.send(settings: settings, apiKey: "", memories: memories), "Offline send starts")
        await settle { model.requests.count == 1 }
        expect(model.requests[0].history.isEmpty, "New chat history contains no previous conversation turns")
        expect(model.requests[0].context.contains("1200") && model.requests[0].context.contains("offline-approved-memory"), "Actual model input combines retrieved context with existing memories")
        expect(model.requests[0].context.contains(originalID.uuidString), "Actual model input identifies the originating conversation")
        model.complete(0, answer: "参考之前的机票对话，预算是1200元。")
        await settle { !conversation.loading }
        expect(conversation.messages.last?.references?.first?.sourceID == originalID, "Successful reply stores its actual source references")
        expect(AssistantConversationStore(url: path).records.count == 2, "Both chats persist after the reply")
        let timesBeforeOpening = Dictionary(uniqueKeysWithValues: conversation.conversations.map { ($0.id, $0.updatedAt) })
        expect(conversation.openConversation(originalID), "Stored original conversation can be opened")
        conversation.cancel()
        expect(conversation.openConversation(newID), "Newer conversation can be reopened")
        expect(Dictionary(uniqueKeysWithValues: conversation.conversations.map { ($0.id, $0.updatedAt) }) == timesBeforeOpening,
               "Opening and leaving unedited conversations preserves all recent-history ordering timestamps")
        conversation.newConversation()
        expect(conversation.openConversation(newID) && conversation.contextReferences.first?.sourceID == originalID, "Opening stored chat restores its reference disclosure")

        conversation.newConversation(); let cancelledID = conversation.currentConversationID
        conversation.draft = "取消这条机票问题"
        _ = conversation.send(settings: settings, apiKey: "", memories: memories)
        await settle { model.requests.count == 2 }
        conversation.cancel()
        conversation.newConversation(); let replacementID = conversation.currentConversationID
        expect(conversation.conversations.first(where: { $0.id == cancelledID })?.draft == "取消这条机票问题", "Explicit cancellation saves the pending user's draft before switching chats")
        conversation.draft = "新的外卖问题"
        _ = conversation.send(settings: settings, apiKey: "", memories: memories)
        await settle { model.requests.count == 3 }
        model.complete(1, answer: "STALE REPLY MUST NEVER APPEAR")
        for _ in 0..<20 { await Task.yield() }
        expect(conversation.currentConversationID == replacementID && conversation.loading && conversation.messages.count == 1, "Late cancelled response cannot update or stop a newer conversation")
        model.complete(2, answer: "新对话回答")
        await settle { !conversation.loading }
        expect(conversation.messages.last?.text == "新对话回答", "Current response still completes after an older cancellation")

        conversation.newConversation(); conversation.sharedContextEnabled = false; conversation.draft = "机票预算是多少"
        _ = conversation.send(settings: settings, apiKey: "", memories: memories)
        await settle { model.requests.count == 4 }
        expect(!model.requests[3].context.contains("历史引用 JSON") && conversation.contextReferences.isEmpty, "Context toggle prevents archived conversations from entering the model prompt")
        model.complete(3, answer: "未参考其他对话")
        await settle { !conversation.loading }

        conversation.newConversation(); conversation.sharedContextEnabled = true; conversation.draft = "火锅外卖地址在哪里"
        let task = PhoneTaskRecord(title: "火锅外卖", goal: "外卖送到深圳南山", summary: "地址已记录，未下单", logs: [AgentLogEntry(title: "查看地址", detail: "火锅外卖地址：深圳南山")])
        conversation.selectSequence([CameraObservationFrame(capturedUptime: 1), CameraObservationFrame(capturedUptime: 2)])
        _ = conversation.send(settings: settings, apiKey: "", memories: memories, observationContext: "历史相机描述", taskRecords: [task])
        await settle { model.requests.count == 5 }
        expect(model.requests[4].frameCount == 2 && model.requests[4].context.contains(task.id.uuidString), "Camera/video question uses the same referenced-context path")
        expect(model.requests[4].context.contains("执行中断") && model.requests[4].context.contains("不证明现在已完成操作"), "Task references preserve status and cannot establish new execution")
        model.fail(4)
        await settle { !conversation.loading }
        expect(conversation.messages.isEmpty && conversation.draft == "火锅外卖地址在哪里" && conversation.contextReferences.isEmpty, "Failed answer restores draft and does not leave false reference attribution")

        conversation.newConversation(); settings.endpoint = "https://different.invalid/chat/completions"
        conversation.draft = "机票预算是多少"
        _ = conversation.send(settings: settings, apiKey: "", memories: memories)
        await settle { model.requests.count == 6 }
        expect(!model.requests[5].context.contains("历史引用 JSON"), "Different recipient cannot retrieve another provider's chat history")
        model.complete(5, answer: "当前没有可参考的预算记录")
        await settle { !conversation.loading }
        let beforeProviderSwitch = conversation.currentConversationID
        settings.endpoint = "https://third.invalid/chat/completions"; conversation.draft = "继续讨论"
        conversation.selectSequence([CameraObservationFrame(capturedUptime: 10), CameraObservationFrame(capturedUptime: 11)])
        _ = conversation.send(settings: settings, apiKey: "", memories: memories)
        await settle { model.requests.count == 7 }
        expect(conversation.currentConversationID != beforeProviderSwitch && model.requests[6].history.isEmpty, "Recipient changes preserve the old session and isolate model history")
        expect(model.requests[6].frameCount == 2 && conversation.messages.first?.cameraFrames == 2,
               "Recipient switch preserves the explicitly attached camera sequence and message provenance")
        model.complete(6, answer: "新服务对话")
        await settle { !conversation.loading }
        expect(conversation.conversations.contains(where: { $0.id == beforeProviderSwitch }), "Recipient switch does not delete previous conversations")
        settings.endpoint = "https://fourth.invalid/chat/completions"; conversation.draft = "看看本次附图"
        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        conversation.selectFrame(ScreenFrame(capturedAt: captureDate))
        _ = conversation.send(settings: settings, apiKey: "", memories: memories)
        await settle { model.requests.count == 8 }
        expect(model.requests[7].hasFrame && model.requests[7].frameCount == 0 && conversation.messages.first?.screenDate == captureDate,
               "Recipient switch preserves the explicitly attached still frame and its capture date")
        model.complete(7, answer: "附图回答")
        await settle { !conversation.loading }
        conversation.clear()
        expect(conversation.messages.isEmpty && conversation.conversations.contains(where: { $0.id == originalID }), "Clearing selected chat preserves other archives")
        expect(memories.calls == 8, "Existing memories continue to run independently of cross-chat context toggle")

        let attachedText = ComposerAttachment(name: "用户资料.txt", kind: .text, byteCount: 24, text: "附件正文：只作参考资料。", imageJPEG: nil)
        let attachedImage = ComposerAttachment(name: "用户图片.jpg", kind: .image, byteCount: 4, text: "", imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let selected = [attachedText, attachedImage]
        conversation.newConversation(); conversation.draft = "总结文件并看看这张图片"
        let attachmentRequest = model.requests.count
        expect(conversation.send(settings: settings, apiKey: "", memories: memories, attachments: selected), "Explicit text and image attachments start a question")
        await settle { model.requests.count == attachmentRequest + 1 }
        expect(model.requests[attachmentRequest].attachments == selected && !model.requests[attachmentRequest].hasFrame,
               "Actual conversation service passes selected materials separately from captured phone frame")
        expect(conversation.messages.first?.attachments == selected, "Pending user message records exact attachment provenance")
        model.complete(attachmentRequest, answer: "已根据文件和图片回答")
        await settle { !conversation.loading }
        let attachedConversationID = conversation.currentConversationID
        expect(AssistantConversationStore(url: path).records.first(where: { $0.id == attachedConversationID })?.messages.first?.attachments == selected,
               "Successful chat persistence retains uploaded document and image snapshot")
        let attachmentArchive = AssistantConversationStore(url: path)
        var invalidAttachmentRecord = attachmentArchive.records.first(where: { $0.id == attachedConversationID })!
        invalidAttachmentRecord.messages[0].attachments = [attachedImage, attachedImage]
        let attachmentArchiveBytes = try Data(contentsOf: path)
        rejects({ try attachmentArchive.upsert(invalidAttachmentRecord, currentConversationID: attachedConversationID) },
                "Conversation archive validates attachment identities before writing")
        expect((try? Data(contentsOf: path)) == attachmentArchiveBytes, "Rejected message attachments preserve archive bytes")

        conversation.newConversation(); conversation.draft = "新的无附件问题"
        let plainRequest = model.requests.count
        expect(conversation.send(settings: settings, apiKey: "", memories: memories), "Attachment-free question starts after another chat")
        await settle { model.requests.count == plainRequest + 1 }
        expect(model.requests[plainRequest].attachments.isEmpty && conversation.messages.first?.attachments == nil,
               "New conversation cannot inherit earlier file or image payload")
        model.complete(plainRequest, answer: "没有收到本次附件")
        await settle { !conversation.loading }

        settings.endpoint = "https://attachment-recipient.invalid/chat/completions"
        conversation.draft = "新服务只看本次附件"
        let recipientRequest = model.requests.count
        expect(conversation.send(settings: settings, apiKey: "", memories: memories, attachments: selected), "Recipient switch accepts explicitly selected new material")
        await settle { model.requests.count == recipientRequest + 1 }
        expect(model.requests[recipientRequest].attachments == selected && model.requests[recipientRequest].history.isEmpty,
               "Recipient switch preserves current attachment selection while isolating prior history")
        model.fail(recipientRequest)
        await settle { !conversation.loading }
        expect(conversation.draft == "新服务只看本次附件" && conversation.messages.isEmpty,
               "Failed attachment response restores question without a false completed message")
        let beforeInvalid = model.requests.count
        expect(!conversation.send(settings: settings, apiKey: "", memories: memories, attachments: [attachedImage, attachedImage]),
               "Duplicate attachment IDs are rejected by conversation before dispatch")
        expect(!conversation.loading && model.requests.count == beforeInvalid && !conversation.error.isEmpty,
               "Invalid attachment selection neither calls the model nor starts a pending answer")

        conversation.newConversation()
        let cacheConversationID = conversation.currentConversationID
        conversation.retainDraftAttachments(selected, conversationID: cacheConversationID)
        expect(conversation.retryAttachments == selected, "Current idle conversation retains exact draft attachment selection for view reconstruction")
        conversation.retainDraftAttachments([attachedImage, attachedImage], conversationID: cacheConversationID)
        expect(conversation.retryAttachments == selected, "Invalid draft attachment cache update preserves the prior valid selection")
        conversation.retainDraftAttachments([], conversationID: cacheConversationID)
        expect(conversation.retryAttachments.isEmpty, "Removing draft attachments clears the service cache instead of reviving them on return")
        conversation.retainDraftAttachments(selected, conversationID: cacheConversationID)
        conversation.retainDraftAttachments([], conversationID: UUID())
        expect(conversation.retryAttachments == selected, "A stale view identity cannot clear the current attachment draft")

        conversation.draft = "发送期间保持本次附件快照"
        let retainedRequest = model.requests.count
        expect(conversation.send(settings: settings, apiKey: "", memories: memories, attachments: selected), "Cached attachment draft starts an explicit selected-material request")
        await settle { model.requests.count == retainedRequest + 1 }
        conversation.retainDraftAttachments([attachedText], conversationID: cacheConversationID)
        conversation.retainDraftAttachments([], conversationID: cacheConversationID)
        expect(conversation.loading && conversation.retryAttachments.isEmpty && conversation.messages.first?.attachments == selected && model.requests[retainedRequest].attachments == selected,
               "While sending, view cache callbacks cannot replace or delete the immutable submitted materials")
        conversation.cancel()
        expect(!conversation.loading && conversation.retryAttachments == selected && conversation.draft == "发送期间保持本次附件快照",
               "Cancelling restores the submitted attachment draft for the same conversation")
        conversation.retainDraftAttachments([], conversationID: cacheConversationID)
        conversation.cancel()
        expect(conversation.retryAttachments.isEmpty, "An idle cancellation cannot resurrect an explicitly removed retry selection")
        model.complete(retainedRequest, answer: "旧请求回复不得恢复附件")
        for _ in 0..<20 { await Task.yield() }
        expect(conversation.retryAttachments.isEmpty && conversation.messages.isEmpty, "Late cancelled model reply cannot repopulate deleted cached materials")

        conversation.retainDraftAttachments(selected, conversationID: cacheConversationID)
        conversation.newConversation()
        let replacementCacheID = conversation.currentConversationID
        expect(conversation.retryAttachments.isEmpty && replacementCacheID != cacheConversationID, "A new conversation starts with an empty attachment cache")
        conversation.retainDraftAttachments(selected, conversationID: cacheConversationID)
        expect(conversation.retryAttachments.isEmpty, "Old conversation view cannot insert its cached attachments into a new conversation")
        conversation.retainDraftAttachments([attachedText], conversationID: replacementCacheID)
        conversation.retainDraftAttachments([], conversationID: cacheConversationID)
        expect(conversation.retryAttachments == [attachedText], "Old conversation view cannot clear the new conversation's own draft")
        conversation.newConversation()
        var dispatched = 0
        var observedIdle = false
        conversation.unifiedRoute = { _ in ConversationRoute(mode: .task, request: "打开时钟", message: "正在打开时钟") }
        conversation.onAction = { _, messageID in
            dispatched += 1; observedIdle = !conversation.loading
            conversation.cancel()
            conversation.linkTask(sourceID, to: messageID)
        }
        conversation.draft = "帮我打开时钟"
        expect(conversation.send(settings: settings, apiKey: "", memories: memories), "Unified task request is accepted")
        await settle { dispatched == 1 }
        expect(observedIdle && conversation.messages.count == 2, "Task execution starts after the reply is committed and cannot cancel its own user turn")
        expect(conversation.messages.last?.taskID == sourceID, "A task remains linked to its originating message")
        var routeContinuation: CheckedContinuation<ConversationRoute, Never>?
        conversation.unifiedRoute = { _ in await withCheckedContinuation { routeContinuation = $0 } }
        conversation.draft = "这条随后取消"
        _ = conversation.send(settings: settings, apiKey: "", memories: memories)
        await settle { routeContinuation != nil }
        conversation.newConversation()
        routeContinuation?.resume(returning: .init(mode: .task, request: "不应执行", message: "不应出现"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(dispatched == 1 && conversation.messages.isEmpty, "A late routing result cannot launch a task in a replacement conversation")

        // A native provider/action does not receive cross-chat excerpts. Having
        // retrieved a candidate is not evidence that the response used it.
        let attributionPath = folder.appendingPathComponent("attribution.json")
        let attributionStore = AssistantConversationStore(url: attributionPath)
        try attributionStore.save([record], currentConversationID: record.id)
        let attribution = AssistantConversation(store: attributionStore)
        var attributionSettings = AgentSettings(); attributionSettings.useMemories = false
        let attributionMemories = MemoryStore()
        attribution.newConversation()
        var flightContinuation: CheckedContinuation<String, Never>?
        attribution.unifiedRoute = { input in .init(mode: .flightQuery, request: input.question, message: "查询航班") }
        attribution.flightQuery = { _ in await withCheckedContinuation { flightContinuation = $0 } }
        attribution.draft = "机票预算是多少"
        expect(attribution.send(settings: attributionSettings, apiKey: "", memories: attributionMemories), "Native flight query starts with a matching archived source available")
        await settle { flightContinuation != nil }
        expect(attribution.contextReferences.isEmpty, "Native flight query does not claim candidate references while loading")
        flightContinuation?.resume(returning: "仅返回当前查询说明，没有可售航班数据。")
        await settle { !attribution.loading }
        expect(attribution.messages.last?.references == nil && attribution.contextReferences.isEmpty,
               "Native flight response stores no cross-chat attribution that its provider never received")
        expect(attribution.messages.last?.flightOffers != nil && attribution.references(for: attribution.messages.last!).isEmpty,
               "A flight query without cards still retains enough route provenance to suppress old false reference disclosure")
        expect(attribution.messages.last?.flightQuery == "机票预算是多少",
               "A completed zero-offer query keeps its full provider request for the next follow-up")
        let restoredFlightQuery = AssistantConversation(store: AssistantConversationStore(url: attributionPath))
        expect(restoredFlightQuery.messages.last?.flightQuery == "机票预算是多少",
               "The provider query survives a real archive round-trip even when no flight cards exist")
        attribution.newConversation()
        attribution.unifiedRoute = { _ in .init(mode: .task, request: "查看机票预算", message: "正在查看机票预算") }
        attribution.onAction = { _, _ in }
        attribution.draft = "机票预算是多少"
        _ = attribution.send(settings: attributionSettings, apiKey: "", memories: attributionMemories)
        await settle { !attribution.loading }
        expect(attribution.messages.last?.references == nil && attribution.contextReferences.isEmpty,
               "Task dispatch acknowledgement also does not claim unused cross-chat excerpts")

        let legacyReply = AssistantMessage(role: "assistant", text: "旧查询答复", references: hits, flightOffers: [])
        let legacyRecord = AssistantConversationRecord(id: UUID(), title: "机票预算是多少", messages: [
            .init(role: "user", text: "机票预算是多少"), legacyReply
        ], createdAt: now, updatedAt: now, recipient: record.recipient, contextReferences: hits)
        let legacyPath = folder.appendingPathComponent("legacy-references.json")
        let legacyStore = AssistantConversationStore(url: legacyPath)
        try legacyStore.save([legacyRecord], currentConversationID: legacyRecord.id)
        let legacyBytes = try Data(contentsOf: legacyPath)
        let legacyConversation = AssistantConversation(store: legacyStore)
        expect(legacyConversation.references(for: legacyReply).isEmpty, "Previously persisted native query references are hidden even if lexically related")
        expect(legacyConversation.messages.last?.references == hits && (try? Data(contentsOf: legacyPath)) == legacyBytes,
               "Filtering old disclosure preserves original stored messages and archive bytes")
        legacyConversation.cancel()
        expect((try? Data(contentsOf: legacyPath)) == legacyBytes && legacyConversation.conversations.first?.updatedAt == now,
               "Idle cancellation after filtering legacy disclosure preserves original archive bytes and recency")
        var staleRecord = legacyRecord
        staleRecord.messages[1].flightOffers = nil
        staleRecord.messages[1].references = [staleHit] + hits
        try legacyStore.save([staleRecord], currentConversationID: staleRecord.id)
        let oldChat = AssistantConversation(store: legacyStore)
        expect(oldChat.references(for: oldChat.messages.last!).map(\.sourceID) == hits.map(\.sourceID),
               "Old ordinary chat keeps genuinely relevant sources and removes unrelated AI news")
        expect(oldChat.references(for: .init(role: "assistant", text: "foreign message", references: hits)).isEmpty,
               "A message outside the current conversation cannot display another turn's references")

        let legacyFlightDate = Date(timeIntervalSince1970: 1_790_000_000)
        let legacyFlightText = "### 航班一：CA8322（中国国际航空）\n- 出发时间：06:40\n- 到达时间：08:55\n- 经济舱参考价：600元（未含税费）"
        var legacyCardsRecord = legacyRecord
        legacyCardsRecord.messages = [.init(role: "user", text: "查明天上海到北京的机票"),
            .init(role: "assistant", text: legacyFlightText, createdAt: legacyFlightDate, flightOffers: [])]
        legacyCardsRecord.title = legacyCardsRecord.messages[0].text
        legacyCardsRecord.contextReferences = []
        try legacyStore.save([legacyCardsRecord], currentConversationID: legacyCardsRecord.id)
        let legacyCardBytes = try Data(contentsOf: legacyPath)
        let oldCards = AssistantConversation(store: legacyStore)
        let rebuiltCards = oldCards.flightOffers(for: oldCards.messages.last!)
        expect(rebuiltCards.count == 1 && rebuiltCards.first?.title.contains("CA8322") == true,
               "Legacy native provider reply with saved empty cards is reparsed for display")
        expect(rebuiltCards.first?.queriedAt == legacyFlightDate && rebuiltCards.first?.query == legacyCardsRecord.messages[0].text,
               "Legacy card rebuild uses the original reply date and preceding question rather than current time")
        expect(oldCards.messages.last?.flightOffers == [] && (try? Data(contentsOf: legacyPath)) == legacyCardBytes,
               "Rebuilding legacy card presentation does not mutate messages or rewrite the archive")
        var unprovenReply = oldCards.messages.last!
        unprovenReply.flightOffers = nil
        expect(oldCards.flightOffers(for: unprovenReply).isEmpty,
               "Ordinary model text without provider provenance never becomes flight cards")
        var existingOfferReply = oldCards.messages.last!
        let savedOffer = CtripFlightOffer(id: "saved-offer", title: "原有航班 CA8322", details: "", price: "600元", bookingURL: nil,
            query: "原始保存的航线、日期和人数", queriedAt: now)
        existingOfferReply.flightOffers = [savedOffer]
        let preferredQuery = oldCards.flightOffers(for: existingOfferReply)
        expect(preferredQuery.first?.query == savedOffer.query && preferredQuery.first?.queriedAt == legacyFlightDate,
               "Rebuild prefers the original saved provider query while retaining the original message date")
        existingOfferReply.text = "旧响应格式无法重新解析"
        expect(oldCards.flightOffers(for: existingOfferReply) == [savedOffer],
               "Unsupported old reply format preserves the original saved flight cards")
        var networkOfferReply = existingOfferReply
        networkOfferReply.text = "### 网络参考\n### 航班一：CA8322（网络来源）\n- 出发时间：06:40\n- 参考价：600元"
        expect(oldCards.flightOffers(for: networkOfferReply).isEmpty && oldCards.flightNarrative(for: networkOfferReply) == networkOfferReply.text,
               "Legacy fallback cannot revive a saved card explicitly attributed to external network references")
        existingOfferReply.role = "user"
        expect(oldCards.flightOffers(for: existingOfferReply).isEmpty,
               "User-authored text cannot create provider flight cards")
        oldCards.cancel()
        expect((try? Data(contentsOf: legacyPath)) == legacyCardBytes && oldCards.conversations.first?.updatedAt == now,
               "Displaying rebuilt cards does not alter archived history ordering on idle cancellation")

        let stableFlightMessage = oldCards.messages.last!
        let stableOffers = oldCards.flightOffers(for: stableFlightMessage)
        let stableNarrative = oldCards.flightNarrative(for: stableFlightMessage)
        let cachedBuilds = oldCards.flightPresentationBuildCount
        var publications = 0
        let observation = oldCards.objectWillChange.sink { publications += 1 }
        var samePresentation = true
        for _ in 0..<40 {
            samePresentation = samePresentation && oldCards.flightOffers(for: stableFlightMessage) == stableOffers &&
                oldCards.flightNarrative(for: stableFlightMessage) == stableNarrative
        }
        expect(samePresentation && oldCards.flightPresentationBuildCount == cachedBuilds,
               "Repeated card and narrative reads reuse the same derived parse instead of reparsing reply text")
        expect(stableNarrative == CtripFlightParser.narrative(stableFlightMessage.text, representedBy: stableOffers),
               "Cached narrative is derived from the same cards returned by the presentation helper")
        expect(publications == 0 && (try? Data(contentsOf: legacyPath)) == legacyCardBytes,
               "Cache reads and writes neither publish view changes nor write archive data")
        observation.cancel()

        var changedFlightMessage = stableFlightMessage
        changedFlightMessage.text = changedFlightMessage.text.replacingOccurrences(of: "600元", with: "900元")
        let changedOffers = oldCards.flightOffers(for: changedFlightMessage)
        expect(changedOffers.first?.price.contains("900") == true && oldCards.flightPresentationBuildCount == cachedBuilds + 1,
               "A changed reply with the same message identity invalidates its derived cache")
        let changedNarrative = oldCards.flightNarrative(for: changedFlightMessage)
        expect(changedNarrative == CtripFlightParser.narrative(changedFlightMessage.text, representedBy: changedOffers) &&
            oldCards.flightPresentationBuildCount == cachedBuilds + 1,
               "Narrative reuses the freshly invalidated card presentation rather than another parse")
        changedFlightMessage.flightOffers = [savedOffer]
        let savedQueryOffers = oldCards.flightOffers(for: changedFlightMessage)
        expect(savedQueryOffers.first?.query == savedOffer.query && oldCards.flightPresentationBuildCount == cachedBuilds + 2,
               "Changed saved cards and their provider query invalidate a cache entry sharing the same message ID")
        changedFlightMessage.createdAt = legacyFlightDate.addingTimeInterval(86_400)
        let changedDateOffers = oldCards.flightOffers(for: changedFlightMessage)
        expect(changedDateOffers.first?.queriedAt == changedFlightMessage.createdAt && oldCards.flightPresentationBuildCount == cachedBuilds + 3,
               "A changed original message date cannot reuse cards from an earlier query date")
        changedFlightMessage.flightOffers = nil
        let beforeOrdinary = oldCards.flightPresentationBuildCount
        expect(oldCards.flightOffers(for: changedFlightMessage).isEmpty && oldCards.flightNarrative(for: changedFlightMessage) == changedFlightMessage.text &&
            oldCards.flightPresentationBuildCount == beforeOrdinary,
               "Ordinary chat without provider provenance returns its original text without parsing or caching")

        var generatedMessages: [AssistantMessage] = []
        for _ in 0..<101 {
            var generated = stableFlightMessage; generated.id = UUID(); generated.flightOffers = [savedOffer]
            generatedMessages.append(generated)
            _ = oldCards.flightOffers(for: generated)
        }
        expect(oldCards.flightPresentationCacheCount == 100, "Derived presentation cache remains bounded after more than one hundred reply identities")
        let fullBuildCount = oldCards.flightPresentationBuildCount
        _ = oldCards.flightNarrative(for: generatedMessages.last!)
        expect(oldCards.flightPresentationBuildCount == fullBuildCount, "A retained recent cache entry serves narrative without reparsing")
        _ = oldCards.flightOffers(for: generatedMessages.first!)
        expect(oldCards.flightPresentationBuildCount == fullBuildCount + 1 && oldCards.flightPresentationCacheCount == 100,
               "Evicted presentation is rebuilt on demand while the cache stays bounded")
        oldCards.newConversation()
        expect(oldCards.flightPresentationCacheCount == 0, "Starting another conversation clears derived reply presentation data")
        expect(oldCards.openConversation(legacyCardsRecord.id) && oldCards.flightPresentationCacheCount == 0,
               "Reopening an archived conversation starts with a clean process-local presentation cache")
        let beforeReopenBuild = oldCards.flightPresentationBuildCount
        expect(oldCards.flightOffers(for: oldCards.messages.last!) == stableOffers && oldCards.flightPresentationBuildCount == beforeReopenBuild + 1,
               "Reopened history rebuilds its own original presentation without receiving another conversation's cache")
        expect(oldCards.messages == legacyCardsRecord.messages && oldCards.conversations.first?.updatedAt == now,
               "Cache lifecycle leaves original messages and historical ordering timestamps unchanged")
        oldCards.clear()
        expect(oldCards.flightPresentationCacheCount == 0, "Clearing a conversation also clears its derived presentation cache")
        let flightText = "### 方案一：CA1234\n- **价格**：400元，未含税\n- **出发时间**：2026-10-30 08:30\n### 预订方式\nhttps://flights.ctrip.com/"
        let offers = CtripFlightParser.offers(flightText, query: "上海到北京机票")
        expect(offers.count == 1 && offers[0].price.contains("未含税"), "Flight cards preserve the provider's tax qualification")
        expect(offers[0].bookingURL == nil && !offers[0].details.contains("预订方式"), "A generic search link is not promoted to a flight payment link")
        expect(CtripFlightParser.officialURL("https://ctrip.com.evil.invalid/order") == nil, "Booking links reject suffix lookalike hosts")
        expect(CtripFlightParser.officialURL("http://flights.ctrip.com/order") == nil, "Booking links require HTTPS")
        expect(CtripFlightParser.officialURL("https://flights.ctrip.com/order") != nil, "Official HTTPS booking links are accepted")
        let combined = CtripFlightOffer(id: "combined", title: "CA1234", details: "- **出发时间**：06:40　**到达时间**：08:55（飞行约2小时15分钟）\n- **出发机场**：浦东T2\n- **到达机场**：大兴", price: "600元，不含税", bookingURL: URL(string: "https://m.ctrip.com/html5/flight/sha-bjs-day-1.html"), query: "上海到北京", queriedAt: now)
        expect(combined.leg(departure: true).time == "06:40" && combined.leg(departure: false).time == "08:55", "Departure and arrival times on the same source line stay distinct")
        expect(combined.leg(departure: true).airport == "浦东T2" && combined.leg(departure: false).airport == "大兴", "Flight duration is never shown as an airport")
        expect(combined.flightSpecificBookingURL == nil, "An official search-day link is still not a flight-specific order link")
        // Retrying an answer is a read-only operation. It must not reroute the
        // original request into phone execution, trim history, or reuse a newly
        // selected frame in place of the original question's materials.
        let retrySettings = AgentSettings(), retryMemories = MemoryStore()
        func retryFixture(_ name: String, question: AssistantMessage = .init(role: "user", text: "解释这个问题"),
                          reply: AssistantMessage = .init(role: "assistant", text: "原回答"), prior: [AssistantMessage] = []) throws -> (AssistantConversation, URL) {
            let url = folder.appendingPathComponent("retry-" + name + ".json")
            let record = AssistantConversationRecord(id: UUID(), title: String((prior.first?.text ?? question.text).prefix(80)),
                messages: prior + [question, reply], createdAt: now, updatedAt: now,
                recipient: retrySettings.endpoint + "|" + retrySettings.providerName)
            let store = AssistantConversationStore(url: url)
            try store.save([record], currentConversationID: record.id)
            return (AssistantConversation(store: store), url)
        }
        let priorTurns: [AssistantMessage] = [.init(role: "user", text: "此前背景"), .init(role: "assistant", text: "此前说明")]
        let (regenerating, retryURL) = try retryFixture("chat", prior: priorTurns)
        let originalRetryMessages = regenerating.messages, originalReply = regenerating.messages.last!
        let originalRetryBytes = try Data(contentsOf: retryURL)
        regenerating.draft = "保持我还没发出的草稿"
        regenerating.retainDraftAttachments([attachedImage], conversationID: regenerating.currentConversationID)
        let unrelatedFrameDate = now.addingTimeInterval(500)
        regenerating.selectFrame(ScreenFrame(capturedAt: unrelatedFrameDate))
        var retryRouteCalls = 0, retryActionCalls = 0
        regenerating.unifiedRoute = { _ in retryRouteCalls += 1; return .init(mode: .task, request: "不得执行", message: "不得执行") }
        regenerating.onAction = { _, _ in retryActionCalls += 1 }
        expect(regenerating.canRetry(originalReply), "Latest ordinary answer is eligible for read-only regeneration")
        let retryRequest = model.requests.count
        expect(regenerating.retry(originalReply, settings: retrySettings, apiKey: "", memories: retryMemories), "Explicit retry starts the original question's answer channel")
        await settle { model.requests.count == retryRequest + 1 }
        expect(model.requests[retryRequest].question == originalRetryMessages[originalRetryMessages.count - 2].text && model.requests[retryRequest].history == priorTurns,
               "Retry sends the originating question and earlier history without recycling its old answer")
        expect(!model.requests[retryRequest].hasFrame && model.requests[retryRequest].frameCount == 0 && model.requests[retryRequest].attachments.isEmpty,
               "Retry never substitutes currently selected screen pixels or draft attachments for its original question")
        expect(model.requests[retryRequest].context.contains("不启动、重试或恢复手机任务"), "Regeneration context explicitly stays outside phone execution")
        expect(regenerating.messages == originalRetryMessages && (try? Data(contentsOf: retryURL)) == originalRetryBytes,
               "Pending regeneration preserves the complete old reply and archive bytes")
        expect(!regenerating.canRetry(originalReply) && !regenerating.retry(originalReply, settings: retrySettings, apiKey: "", memories: retryMemories),
               "Duplicate retry clicks cannot create concurrent requests")
        model.complete(retryRequest, answer: "重新生成的回答")
        await settle { !regenerating.loading }
        expect(Array(regenerating.messages.dropLast()) == originalRetryMessages && regenerating.messages.last?.text == "重新生成的回答",
               "Successful regeneration appends an alternative while preserving the original question, answer, and ordering")
        expect(regenerating.draft == "保持我还没发出的草稿" && regenerating.retryAttachments == [attachedImage] && regenerating.selectedFrame?.capturedAt == unrelatedFrameDate,
               "Regeneration preserves the independently edited draft and selected future materials")
        expect(retryRouteCalls == 0 && retryActionCalls == 0, "Retry never calls unified task routing or task action dispatch")
        let afterRetryMessages = regenerating.messages
        expect(!regenerating.canRetry(originalReply) && !regenerating.retry(originalReply, settings: retrySettings, apiKey: "", memories: retryMemories) && regenerating.messages == afterRetryMessages,
               "Retrying an older answer cannot truncate or reorder later conversation")
        let cancellationRequest = model.requests.count
        expect(regenerating.retry(regenerating.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories), "Latest alternative can itself be retried")
        await settle { model.requests.count == cancellationRequest + 1 }
        regenerating.cancel()
        model.complete(cancellationRequest, answer: "晚到的取消回复")
        for _ in 0..<25 { await Task.yield() }
        expect(regenerating.messages == afterRetryMessages && regenerating.draft == "保持我还没发出的草稿" && !regenerating.loading,
               "Cancellation and a late reply preserve all completed alternatives and the unsent draft")
        let switchingRequest = model.requests.count
        _ = regenerating.retry(regenerating.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { model.requests.count == switchingRequest + 1 }
        let previousRetryConversation = regenerating.currentConversationID
        regenerating.newConversation(); regenerating.unifiedRoute = nil
        regenerating.draft = "新会话的问题"
        _ = regenerating.send(settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { model.requests.count == switchingRequest + 2 }
        model.complete(switchingRequest, answer: "旧会话晚到的重试")
        for _ in 0..<25 { await Task.yield() }
        expect(regenerating.loading && regenerating.messages.count == 1 && regenerating.messages.first?.text == "新会话的问题",
               "Late retry cannot append into or stop another conversation's current request")
        model.complete(switchingRequest + 1, answer: "新会话回答")
        await settle { !regenerating.loading }
        expect(regenerating.conversations.first(where: { $0.id == previousRetryConversation })?.messages == afterRetryMessages,
               "Switching chats during regeneration preserves the original conversation and its alternatives")

        let (failedRetry, failedRetryURL) = try retryFixture("failure")
        let failedMessages = failedRetry.messages, failedBytes = try Data(contentsOf: failedRetryURL)
        failedRetry.draft = "新的独立草稿"
        let failureRequest = model.requests.count
        _ = failedRetry.retry(failedRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { model.requests.count == failureRequest + 1 }
        model.fail(failureRequest)
        await settle { !failedRetry.loading }
        expect(failedRetry.messages == failedMessages && failedRetry.draft == "新的独立草稿" && !failedRetry.error.isEmpty && (try? Data(contentsOf: failedRetryURL)) == failedBytes,
               "Network failure preserves the old answer, independent draft and archive without a phantom replacement")
        let emptyRetryRequest = model.requests.count
        _ = failedRetry.retry(failedRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { model.requests.count == emptyRetryRequest + 1 }
        model.complete(emptyRetryRequest, answer: "  \n")
        await settle { !failedRetry.loading }
        expect(failedRetry.messages == failedMessages && (try? Data(contentsOf: failedRetryURL)) == failedBytes, "An empty regeneration result cannot replace or delete the original answer")
        PrivacyConsent.permitted = false
        let deniedCount = model.requests.count
        expect(!failedRetry.retry(failedRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories) && model.requests.count == deniedCount,
               "Retry retains the current data consent gate before any provider request")
        PrivacyConsent.permitted = true
        let revocationRequest = model.requests.count
        _ = failedRetry.retry(failedRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { model.requests.count == revocationRequest + 1 }
        PrivacyConsent.permitted = false
        model.complete(revocationRequest, answer: "授权撤销后不应提交的答复")
        await settle { !failedRetry.loading }
        expect(failedRetry.messages == failedMessages && !failedRetry.error.isEmpty, "Consent revoked while awaiting a model prevents retry result commit")
        PrivacyConsent.permitted = true
        var otherRetryRecipient = retrySettings; otherRetryRecipient.endpoint = "https://other-recipient.invalid/chat/completions"
        let originalRetryConversation = failedRetry.currentConversationID
        expect(!failedRetry.retry(failedRetry.messages.last!, settings: otherRetryRecipient, apiKey: "", memories: retryMemories) && failedRetry.currentConversationID == originalRetryConversation && model.requests.count == revocationRequest + 1,
               "A changed provider cannot receive another recipient's original question or history through retry")
        var forgedRetryReply = failedRetry.messages.last!; forgedRetryReply.text = "不同的伪造回答"
        expect(!failedRetry.canRetry(forgedRetryReply) && !failedRetry.retry(forgedRetryReply, settings: retrySettings, apiKey: "", memories: retryMemories),
               "A stale or forged same-ID message cannot select different retry input")
        let (reboundRetry, _) = try retryFixture("task-rebound")
        let reboundReply = reboundRetry.messages.last!, reboundRequest = model.requests.count, reboundTaskID = UUID()
        _ = reboundRetry.retry(reboundReply, settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { model.requests.count == reboundRequest + 1 }
        expect(reboundRetry.linkTask(reboundTaskID, to: reboundReply.id), "Concurrent task ownership can bind the original reply during a read-only retry")
        model.complete(reboundRequest, answer: "不得覆盖新任务归属的回复")
        await settle { !reboundRetry.loading }
        expect(reboundRetry.messages.count == 2 && reboundRetry.messages.last?.taskID == reboundTaskID && !reboundRetry.canRetry(reboundRetry.messages.last!),
               "A reply rebound to an actual task while awaiting the provider cannot receive a stale regenerated answer")

        let originalAttachmentQuestion = AssistantMessage(role: "user", text: "看原问题的图片和文字附件", attachments: selected)
        let (attachmentRetry, _) = try retryFixture("attachments", question: originalAttachmentQuestion)
        attachmentRetry.retainDraftAttachments([attachedText], conversationID: attachmentRetry.currentConversationID)
        attachmentRetry.selectFrame(ScreenFrame())
        let attachmentRetryRequest = model.requests.count
        expect(attachmentRetry.retry(attachmentRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories), "Persisted original attachments remain eligible for regeneration")
        await settle { model.requests.count == attachmentRetryRequest + 1 }
        expect(model.requests[attachmentRetryRequest].attachments == selected && !model.requests[attachmentRetryRequest].hasFrame,
               "Retry reuses only the originating question's exact stored text/image attachments")
        model.complete(attachmentRetryRequest, answer: "原附件的新回答")
        await settle { !attachmentRetry.loading }
        var screenQuestion = AssistantMessage(role: "user", text: "看屏幕", screenDate: now)
        let (screenRetry, _) = try retryFixture("missing-screen", question: screenQuestion)
        expect(!screenRetry.canRetry(screenRetry.messages.last!), "An unavailable original screen frame cannot be silently replaced with new pixels")
        screenQuestion.screenDate = nil; screenQuestion.cameraFrames = 3
        let (cameraRetry, _) = try retryFixture("missing-camera", question: screenQuestion)
        expect(!cameraRetry.canRetry(cameraRetry.messages.last!), "A camera sequence without retained frames requires a new explicit question")
        var taskReceipt = AssistantMessage(role: "assistant", text: "已完成手机操作"); taskReceipt.taskID = UUID()
        let (taskRetry, _) = try retryFixture("task-receipt", reply: taskReceipt)
        expect(!taskRetry.canRetry(taskRetry.messages.last!) && !taskRetry.retry(taskRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories),
               "Actual task receipts are reserved for task recovery rather than fabricated answer regeneration")
        let (taskAcknowledgement, _) = try retryFixture("task-acknowledgement")
        taskAcknowledgement.newConversation()
        var acknowledgementActions = 0
        taskAcknowledgement.unifiedRoute = { _ in .init(mode: .task, request: "打开时钟", message: "正在处理手机任务") }
        taskAcknowledgement.onAction = { _, _ in acknowledgementActions += 1 }
        taskAcknowledgement.draft = "打开时钟"
        _ = taskAcknowledgement.send(settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { !taskAcknowledgement.loading }
        expect(acknowledgementActions == 1 && !taskAcknowledgement.canRetry(taskAcknowledgement.messages.last!),
               "Even an as-yet unlinked live task acknowledgement is excluded from answer retry")

        let flightRetryQuery = "查询2026年10月30日上海到北京CA8322经济舱，1人"
        let flightRetryReply = AssistantMessage(role: "assistant", text: "原航班查询答复", flightOffers: [], flightQuery: flightRetryQuery)
        let (flightRetry, _) = try retryFixture("flight", question: .init(role: "user", text: "有没有直飞的"), reply: flightRetryReply)
        var flightRetryQueries: [String] = []
        var flightRetryContinuation: CheckedContinuation<String, Never>?
        flightRetry.flightQuery = { query in flightRetryQueries.append(query); return await withCheckedContinuation { flightRetryContinuation = $0 } }
        flightRetry.unifiedRoute = { _ in retryRouteCalls += 1; return .init(mode: .task, request: "不得重新执行", message: "不得出现") }
        flightRetry.onAction = { _, _ in retryActionCalls += 1 }
        let beforeFlightRetryModelRequests = model.requests.count
        expect(flightRetry.retry(flightRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories), "Travel retry uses explicit provider provenance even for old empty-card results")
        await settle { flightRetryContinuation != nil }
        expect(flightRetryQueries.count == 1 && flightRetryQueries[0].hasPrefix(flightRetryQuery) && flightRetryQueries[0].contains("不创建订单") && model.requests.count == beforeFlightRetryModelRequests,
               "Travel retry refreshes the complete saved query once with a read-only limit and without a second intent/model dispatch")
        flightRetryContinuation?.resume(returning: legacyFlightText)
        await settle { !flightRetry.loading }
        expect(flightRetry.messages.count == 3 && flightRetry.messages[1] == flightRetryReply && flightRetry.messages.last?.flightQuery == flightRetryQuery && flightRetry.messages.last?.flightOffers?.first?.query == flightRetryQuery,
               "Refreshed travel cards append beside the preserved original answer and keep the complete query constraints")
        expect(flightRetry.messages.last?.references == nil && retryRouteCalls == 0 && retryActionCalls == 0,
               "Travel regeneration does not claim unused references or execute any phone task")
        flightRetry.flightQuery = nil
        expect(!flightRetry.canRetry(flightRetry.messages.last!), "A disabled travel connection cannot be retried through an unrelated model route")
        let manyRetryTurns = (0..<98).map { index in AssistantMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", text: "已保存\(index)") }
        let (fullRetry, fullRetryURL) = try retryFixture("full-history", prior: manyRetryTurns)
        let fullRetryBytes = try Data(contentsOf: fullRetryURL), fullRetryCount = model.requests.count
        expect(!fullRetry.canRetry(fullRetry.messages.last!) && !fullRetry.retry(fullRetry.messages.last!, settings: retrySettings, apiKey: "", memories: retryMemories) && fullRetry.messages.count == 100,
               "Retry at the history limit refuses instead of deleting earlier messages to make space")
        expect(model.requests.count == fullRetryCount && (try? Data(contentsOf: fullRetryURL)) == fullRetryBytes,
               "Rejected full-history retry neither calls a provider nor changes the original archive")
        let intentURL = folder.appendingPathComponent("memory-intent.json")
        let intentConversation = AssistantConversation(store: AssistantConversationStore(url: intentURL))
        var intentSettings = AgentSettings(); intentSettings.useMemories = true
        let intentMemories = MemoryStore()
        intentMemories.reference = "CURRENT-APPROVED-INTENT-MEMORY"
        intentConversation.taskContext = { "{\"tasks\":[],\"snapshot\":\"CURRENT-TASK-STATE\"}" }
        var routedInputs: [ConversationRoutingInput] = []
        intentConversation.unifiedRoute = { input in
            routedInputs.append(input)
            return .init(mode: .clarify, request: "", message: "安排在什么时候？", missingInformation: ["开始时间"])
        }
        intentConversation.draft = "帮我建一个日历事件"
        let beforeIntentAnswers = model.requests.count
        _ = intentConversation.send(settings: intentSettings, apiKey: "", memories: intentMemories)
        await settle { !intentConversation.loading }
        expect(routedInputs.count == 1 && routedInputs[0].memoryContext.contains(intentMemories.reference) && routedInputs[0].taskContext.contains("CURRENT-TASK-STATE"),
               "The actual send path prepares memory and one current task snapshot before intent routing")
        expect(model.requests.count == beforeIntentAnswers && intentConversation.messages.last?.intent?.missingInformation == ["开始时间"],
               "A clarification commits working memory without a second chat model or execution")
        let originalIntentMessage = intentConversation.messages.first!
        let reopenedIntent = AssistantConversation(store: AssistantConversationStore(url: intentURL))
        var capturedFollowup: ConversationRoutingInput?
        reopenedIntent.unifiedRoute = { input in
            capturedFollowup = input
            return .init(mode: .clarify, request: "", message: "还需要持续多久？", missingInformation: ["结束时间"])
        }
        reopenedIntent.draft = "明天九点"
        _ = reopenedIntent.send(settings: intentSettings, apiKey: "", memories: intentMemories)
        await settle { !reopenedIntent.loading }
        expect(capturedFollowup?.history.first?.id == originalIntentMessage.id && capturedFollowup?.history.last?.intent?.missingInformation == ["开始时间"],
               "Reopening the actual archive restores the preceding clarification and its real source identities")
        intentMemories.excludedMessageIDs = [originalIntentMessage.id]
        reopenedIntent.selectFrame(ScreenFrame())
        let selectedIntentAttachment = ComposerAttachment(name: "本轮资料.txt", kind: .text, byteCount: 12, text: "CURRENT-INTENT-ATTACHMENT", imageJPEG: nil)
        reopenedIntent.draft = "参考附件先规划一下"
        _ = reopenedIntent.send(settings: intentSettings, apiKey: "", memories: intentMemories, attachments: [selectedIntentAttachment])
        await settle { !reopenedIntent.loading }
        expect(capturedFollowup?.attachments == [selectedIntentAttachment] && capturedFollowup?.visuals.count == 1,
               "A frame and attachment take the same memory-first routing path as ordinary conversation and dictation")
        expect(capturedFollowup?.history.contains { $0.id == originalIntentMessage.id } == false,
               "Forgotten source turns are excluded from routing and working-state recovery")
        intentSettings.useMemories = false; reopenedIntent.selectFrame(nil)
        reopenedIntent.draft = "换个话题"
        _ = reopenedIntent.send(settings: intentSettings, apiKey: "", memories: intentMemories)
        await settle { !reopenedIntent.loading }
        expect(capturedFollowup?.memoryContext.isEmpty == true, "Disabling memory removes recalled material before routing, while current conversation remains available")

        func freshHandoff(_ name: String) -> AssistantConversation {
            let service = AssistantConversation(store: AssistantConversationStore(url: folder.appendingPathComponent("handoff-" + name + ".json")))
            service.unifiedRoute = { input in .init(mode: .task, request: input.question, message: "已创建闹钟，开始执行") }
            return service
        }
        let requestText = "请创建明天早上9:10的闹钟"
        for handlerPresent in [false, true] {
            let service = freshHandoff(handlerPresent ? "unreported" : "missing-handler")
            var observedAck = ""
            if handlerPresent { service.onAction = { _, _ in observedAck = service.messages.last?.text ?? "" } }
            service.draft = requestText
            expect(service.send(settings: retrySettings, apiKey: "", memories: retryMemories), "Task handoff request starts its semantic route")
            await settle { !service.loading }
            expect(service.messages.first?.text == requestText && service.draft == requestText, "Unaccepted handoff preserves the exact human message and retry draft")
            expect(service.messages.last?.text.contains("任务未启动") == true && service.messages.last?.taskID == nil && !service.error.isEmpty,
                   "Missing or unreported Void handler cannot leave a model execution promise")
            if handlerPresent { expect(observedAck == "正在交接执行请求", "Model action wording is replaced by a neutral host acknowledgement before dispatch") }
        }
        let queuedHandoff = freshHandoff("queue"), queuedHandoffID = UUID()
        queuedHandoff.onAction = { _, id in
            _ = queuedHandoff.linkTask(queuedHandoffID, to: id)
            queuedHandoff.reportTaskHandoff(text: "已加入任务队列，尚未开始执行。", to: id, onlyIfUnlinked: false)
        }
        queuedHandoff.draft = requestText
        _ = queuedHandoff.send(settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { !queuedHandoff.loading }
        expect(queuedHandoff.messages.last?.taskID == queuedHandoffID && queuedHandoff.messages.last?.text == "已加入任务队列，尚未开始执行。" && queuedHandoff.error.isEmpty,
               "Explicit queued handoff persists its real ID and waiting state")
        let delayedHandoff = freshHandoff("late-origin"), delayedOrigin = delayedHandoff.currentConversationID
        delayedHandoff.onAction = { _, id in delayedHandoff.reportTaskHandoff(text: "正在准备设备，任务尚未开始执行。", to: id) }
        delayedHandoff.draft = requestText
        _ = delayedHandoff.send(settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { !delayedHandoff.loading }
        let delayedAck = delayedHandoff.messages.last!.id, humanMessage = delayedHandoff.messages.first!.id
        expect(delayedHandoff.messages.last?.taskID == nil && delayedHandoff.error.isEmpty && delayedHandoff.draft.isEmpty,
               "Explicit preparation report satisfies the handoff without inventing a task link")
        expect(!delayedHandoff.reportTaskHandoff(text: "不得重写人类", to: humanMessage), "Handoff reports cannot rewrite human messages")
        let waitingText = delayedHandoff.messages.last?.text
        expect(!delayedHandoff.reportTaskHandoff(text: "   ", to: delayedAck) &&
               !delayedHandoff.reportTaskHandoff(text: String(repeating: "长", count: 4001), to: delayedAck) &&
               !delayedHandoff.reportTaskHandoff(text: "未知消息", to: UUID()) &&
               delayedHandoff.messages.last?.text == waitingText,
               "Invalid or foreign host reports cannot erase a valid waiting acknowledgement")
        delayedHandoff.newConversation(); let activeReplacement = delayedHandoff.currentConversationID
        delayedHandoff.draft = "另一会话正在编辑的草稿"
        let delayedRecord = UUID()
        expect(delayedHandoff.linkTask(delayedRecord, to: delayedAck, in: delayedOrigin), "Delayed actual record links the original archived acknowledgement")
        expect(delayedHandoff.reportTaskHandoff(text: "任务已启动。", to: delayedAck, in: delayedOrigin, onlyIfUnlinked: false), "Delayed host start report updates its offscreen origin")
        expect(!delayedHandoff.reportTaskHandoff(text: "不得降级已启动任务", to: delayedAck, in: delayedOrigin), "Unlinked-only report cannot downgrade a linked actual task")
        expect(delayedHandoff.currentConversationID == activeReplacement && delayedHandoff.messages.isEmpty && delayedHandoff.draft == "另一会话正在编辑的草稿" && delayedHandoff.error.isEmpty,
               "Late handoff result does not alter replacement chat, messages, draft or error")
        expect(delayedHandoff.conversations.first(where: { $0.id == delayedOrigin })?.messages.first(where: { $0.id == delayedAck })?.text == "任务已启动。",
               "Stored original conversation has the actual start result")
        expect(!delayedHandoff.reportTaskHandoff(text: "不得重写归档人类", to: humanMessage, in: delayedOrigin, onlyIfUnlinked: false) &&
               !delayedHandoff.reportTaskHandoff(text: "不能跨归属", to: delayedAck, in: UUID(), onlyIfUnlinked: false),
               "Archived reporting still rejects human text and a different conversation identity")
        let switchedDuringHandoff = freshHandoff("switch-in-handler"), switchedOrigin = switchedDuringHandoff.currentConversationID
        switchedDuringHandoff.onAction = { _, _ in switchedDuringHandoff.newConversation(); switchedDuringHandoff.draft = "新对话草稿" }
        switchedDuringHandoff.draft = requestText
        _ = switchedDuringHandoff.send(settings: retrySettings, apiKey: "", memories: retryMemories)
        await settle { !switchedDuringHandoff.loading }
        expect(switchedDuringHandoff.conversations.first(where: { $0.id == switchedOrigin })?.messages.last?.text.contains("任务未启动") == true && switchedDuringHandoff.draft == "新对话草稿" && switchedDuringHandoff.error.isEmpty,
               "A handler that navigates away without accepting updates only its originating acknowledgement")
        for (index, question) in [requestText, "请帮我打开时钟"].enumerated() {
            let service = freshHandoff("dishonest-chat-\(index)"); var executions = 0
            service.unifiedRoute = { _ in .init(mode: .chat, request: "", message: "") }
            service.onAction = { _, _ in executions += 1 }; service.draft = question
            let replyIndex = model.requests.count
            _ = service.send(settings: retrySettings, apiKey: "", memories: retryMemories)
            await settle { model.requests.count > replyIndex }
            model.complete(replyIndex, answer: index == 0 ? "好的，我已创建闹钟。" : "正在为你打开时钟。")
            await settle { !service.loading }
            expect(service.error.contains("尚未交接") && service.draft == question && service.messages.isEmpty && executions == 0,
                   "Chat action promise is rejected and retained as a request, never promoted into execution")
        }
        for (index, question) in ["请你帮我解释如何设置闹钟。", "把“创建一个闹钟”翻译成英文。", "帮我起草创建闹钟的操作说明。", "“请创建一个闹钟”是什么意思？"].enumerated() {
            let service = freshHandoff("non-action-\(index)")
            service.unifiedRoute = { _ in .init(mode: .chat, request: "", message: "") }; service.draft = question
            let replyIndex = model.requests.count
            _ = service.send(settings: retrySettings, apiKey: "", memories: retryMemories)
            await settle { model.requests.count > replyIndex }
            model.complete(replyIndex, answer: "已创建，是一个完成时表达。")
            await settle { !service.loading }
            expect(service.error.isEmpty && service.messages.last?.text == "已创建，是一个完成时表达。", "Explanation, draft and quoted language never acquire action authority or trigger the narrow honesty guard")
        }

        expect(intentConversation.messages.last?.intent?.pending?.originalMessageID == originalIntentMessage.id,
               "The actual send path stores a typed clarification ledger anchored to its user message")
        expect(intentConversation.messages.last?.intent?.diagnostics?.memoryMilliseconds ?? -1 >= 0,
               "Per-turn diagnostics measure memory time without storing its text")
        let invalidatedMemory = MemoryStore()
        let invalidated = AssistantConversation(store: AssistantConversationStore(url: folder.appendingPathComponent("revoked-recall.json")))
        var invalidationSettings = AgentSettings(); invalidationSettings.useMemories = true
        var delayedIntent: CheckedContinuation<ConversationRoute, Never>?
        var invalidatedActions = 0
        invalidated.unifiedRoute = { _ in await withCheckedContinuation { delayedIntent = $0 } }
        invalidated.onAction = { _, _ in invalidatedActions += 1 }
        invalidated.draft = "按我的日历偏好创建明天的复盘"
        _ = invalidated.send(settings: invalidationSettings, apiKey: "", memories: invalidatedMemory)
        await settle { delayedIntent != nil }
        invalidatedMemory.recallRevision = "forgotten-after-classification-started"
        delayedIntent!.resume(returning: .init(mode: .task, request: "x", message: "开始处理"))
        await settle { !invalidated.loading }
        expect(invalidatedActions == 0 && !invalidated.error.isEmpty && !invalidated.draft.isEmpty,
               "Forgetting or editing memory during routing blocks stale execution and preserves the human draft")
        invalidated.newConversation(); invalidated.unifiedRoute = { _ in .init(mode: .chat, request: "", message: "") }
        let privateAnswerIndex = model.requests.count
        invalidated.draft = "我以前有什么偏好？"
        _ = invalidated.send(settings: invalidationSettings, apiKey: "", memories: invalidatedMemory)
        await settle { model.requests.count > privateAnswerIndex }
        invalidatedMemory.recallRevision = "forgotten-during-answer"
        model.complete(privateAnswerIndex, answer: "OLD-RECALLED-FACT-MUST-NOT-DISPLAY")
        await settle { !invalidated.loading }
        expect(invalidated.messages.isEmpty && !invalidated.error.isEmpty && !invalidated.draft.isEmpty,
               "A forgotten memory cannot reappear in a late ordinary answer")
        print("Assistant conversation checks passed (\(checks) checks; offline continuations only)")
    }
}
