import Foundation

@main struct UnderstandingChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1; precondition(value(), label)
        }
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let fact = UUID(), manual = UUID(), historyID = UUID(), injected = UUID()
        let semantic = String(decoding: try JSONSerialization.data(withJSONObject: [
            "relevantMemories": [["id": fact.uuidString, "text": "quoted ID: " + injected.uuidString,
                                   "evidence": [["messageID": injected.uuidString]]]],
            "relatedHistory": [["sourceID": historyID.uuidString]],
            "recentMessages": [["id": injected.uuidString]], "untrusted": ["id": injected.uuidString]
        ]), as: UTF8.self)
        let manualJSON = "[{\"id\":\"" + manual.uuidString + "\",\"content\":\"" + injected.uuidString + "\"}]"
        let packed = ConversationMemorySources.envelope(semantic: semantic, manual: manualJSON)
        expect(ConversationMemorySources.ids(in: packed) == [fact, manual, historyID], "Only explicit owned source fields grant reference IDs")
        expect(!ConversationMemorySources.ids(in: semantic).contains(injected), "A quoted UUID or evidence-message UUID is not a recalled fact ID")
        expect(ConversationMemorySources.ids(in: "not JSON").isEmpty, "Malformed references cannot grant source identity")
        expect(ConversationMemorySources.envelope(semantic: "", manual: "").isEmpty, "Empty recall remains empty")

        var user = AssistantMessage(role: "user", text: "帮我在工作日历安排明天下午三点的项目复盘")
        user.createdAt = now.addingTimeInterval(-60)
        var reply = AssistantMessage(role: "assistant", text: "持续多久？")
        reply.createdAt = now
        reply.intent = ConversationWorkingMemory.record(route: .init(mode: .clarify, request: "", message: reply.text,
            missingInformation: ["持续时长"], relation: .independent), user: user, replyID: reply.id, history: [], now: now)
        var history = [user, reply]
        expect(ConversationWorkingMemory.pending(in: history)?.originalMessageID == user.id, "A clarification ledger binds the actual original user source")
        let decoded = try JSONDecoder().decode([AssistantMessage].self, from: JSONEncoder().encode(history))
        expect(ConversationWorkingMemory.pending(in: decoded)?.id == reply.id, "The pending request survives a real Codable archive round-trip")
        let expanded = ConversationWorkingMemory.recallQuery(question: "半小时", history: history)
        expect(expanded.contains("项目复盘") && expanded.hasPrefix("半小时"), "Short answers retrieve domain-specific preferences using the original request")
        expect(ConversationWorkingMemory.recallQuery(question: "帮我查北京天气", history: history) == "帮我查北京天气", "An explicit unrelated request does not inherit the pending recall query")
        expect(ConversationWorkingMemory.recallQuery(question: "先规划一下", history: history) == "先规划一下", "Discussion-only input remains the primary recall query")

        for index in 0..<8 {
            var answer = AssistantMessage(role: "user", text: "补充值\(index)")
            answer.createdAt = now.addingTimeInterval(Double(index + 1))
            let pending = ConversationWorkingMemory.pending(in: history)!
            var question = AssistantMessage(role: "assistant", text: "还需要补充字段\(index)？")
            question.createdAt = answer.createdAt
            let route = ConversationRoute(mode: .clarify, request: "", message: question.text,
                missingInformation: ["字段\(index)"], relation: .answer, pendingIntentID: pending.id)
            question.intent = ConversationWorkingMemory.record(route: route, user: answer, replyID: question.id,
                history: history, now: answer.createdAt)
            history += [answer, question]
        }
        let longInput = try ConversationRoutingInput(question: "半小时", history: history, taskContext: "{}", memoryContext: packed, now: now)
        expect(longInput.history.contains { $0.id == user.id }, "The original request stays pinned beyond the recent-message window")
        expect(longInput.pendingIntent?.sourceMessageIDs.count == 9, "Every supplied answer remains bound to the same original request")
        expect(longInput.turns.contains { $0["content"]?.contains("originalUserRequest") == true && $0["content"]?.contains(user.text) == true }, "The model sees the pending original request as separately labelled data")
        let reference = try longInput.executionReference(messageIDs: longInput.pendingIntent!.sourceMessageIDs)
        expect(reference.contains(user.text) && reference.contains("补充值0") && reference.contains("补充值7"), "Execution receives all original slot sources without reconstruction")
        expect(longInput.history.contains { $0.id == reply.id }, "The first clarification question stays pinned with the answers that depend on it")
        expect(reference.contains(reply.text) == false, "User authority sources remain separate from assistant question references")
        let completeReference = try longInput.executionReference(messageIDs: longInput.pendingIntent!.sourceMessageIDs + (longInput.pendingIntent!.clarificationMessageIDs ?? []))
        expect(completeReference.contains(reply.text) && completeReference.contains("question_or_content_only_not_execution_authority"),
               "Execution carries the actual clarification questions as labelled reference data")
        var choiceUser = AssistantMessage(role: "user", text: "帮我安排明天的复盘，时间让我选")
        choiceUser.createdAt = now
        var choiceQuestion = AssistantMessage(role: "assistant", text: "选择哪个开始时间？1. 下午三点；2. 下午四点。")
        choiceQuestion.intent = ConversationWorkingMemory.record(route: .init(mode: .clarify, request: "", message: choiceQuestion.text,
            missingInformation: ["开始时间"], relation: .independent), user: choiceUser, replyID: choiceQuestion.id, history: [], now: now)
        var choiceHistory = [choiceUser, choiceQuestion]
        for index in 0..<8 {
            var answer = AssistantMessage(role: "user", text: index == 0 ? "第二个" : "参数\(index)")
            answer.createdAt = now
            let prior = ConversationWorkingMemory.pending(in: choiceHistory)!
            var question = AssistantMessage(role: "assistant", text: "请再补充字段\(index)")
            question.intent = ConversationWorkingMemory.record(route: .init(mode: .clarify, request: "", message: question.text,
                missingInformation: ["字段\(index)"], relation: .answer, pendingIntentID: prior.id), user: answer,
                replyID: question.id, history: choiceHistory, now: now)
            choiceHistory += [answer, question]
        }
        let choiceInput = try ConversationRoutingInput(question: "半小时", history: choiceHistory, taskContext: "{}", now: now)
        expect(choiceInput.history.contains { $0.id == choiceQuestion.id }, "An ordinal keeps the original options after they leave the recent window")
        expect(!choiceInput.pendingIntent!.sourceMessageIDs.contains(choiceQuestion.id), "Assistant options do not become user authorization sources")
        let choiceReference = try choiceInput.executionReference(messageIDs: choiceInput.pendingIntent!.sourceMessageIDs + (choiceInput.pendingIntent!.clarificationMessageIDs ?? []))
        expect(choiceReference.contains("下午四点") && choiceReference.contains("第二个"), "Execution can resolve the ordinal against its actual option question")
        expect(ConversationWorkingMemory.pending(in: history.filter { $0.id != user.id }) == nil, "Forgetting the root source invalidates pending authority")
        let otherThread = Array(history.suffix(4))
        expect(ConversationWorkingMemory.pending(in: otherThread) == nil, "A copied pending record cannot bind another thread without its actual sources")
        let stale = try ConversationRoutingInput(question: "半小时", history: history, taskContext: "{}", now: now.addingTimeInterval(259_200))
        expect(stale.pendingIntent?.expired(at: stale.referenceTime) == true && stale.turns.contains { $0["content"]?.contains("\"requiresRestatement\":true") == true }, "Old pending requests disclose expiry instead of silently moving relative dates")
        expect(ConversationWorkingMemory.expiry(for: "帮我写一篇文章", at: now, timeZone: "Asia/Shanghai") == nil, "Non-temporal drafting is not expired by an arbitrary time-to-live")
        let tomorrowExpiry = ConversationWorkingMemory.expiry(for: "帮我安排明天的会议", at: now, timeZone: "Asia/Shanghai")!
        expect(tomorrowExpiry > now.addingTimeInterval(86_400) && tomorrowExpiry <= now.addingTimeInterval(172_800), "Relative day expiry uses the original timezone/day boundary, not time since last message")
        let thirdDay = ConversationWorkingMemory.expiry(for: "大后天开会", at: now, timeZone: "Asia/Shanghai")!
        expect(thirdDay.timeIntervalSince(tomorrowExpiry) == 172_800, "Overlapping day words retain the longest date term")
        expect(ConversationWorkingMemory.refreshesDate("改成明天下午三点，半小时", at: now), "An explicit fresh date can update the same pending request without repeating its title")
        expect(!ConversationWorkingMemory.refreshesDate("就叫明天", at: now), "An event name cannot refresh an expired execution date")
        let switched = history + [AssistantMessage(role: "user", text: "换个话题"), AssistantMessage(role: "assistant", text: "我们聊周末", intent: .init(mode: .chat, module: "conversation"))]
        expect(ConversationWorkingMemory.pending(in: switched) == nil, "A new topic clears the pending interpretation")
        let completed = history + [AssistantMessage(role: "assistant", text: "实际任务回执", taskID: UUID(), intent: .init(mode: .task, module: "task-executor"))]
        expect(ConversationWorkingMemory.pending(in: completed) == nil, "A handed-off task is not resurrected as a pending clarification")
        let twelve = (0..<12).map { AssistantMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "近期消息\($0)") }
        let window = try ConversationRoutingInput(question: "当前问题", history: twelve, taskContext: "{}")
        expect(window.history.map(\.id) == twelve.map(\.id), "The router keeps the same twelve recent messages excluded from the memory envelope")
        let nativeSession = UUID(), taskID = UUID()
        let privateSessions = try ConversationRoutingInput(question: "暂停任务", history: [], taskContext: "{}", backgroundSessions: [taskID: nativeSession])
        let privateWire = try JSONSerialization.data(withJSONObject: privateSessions.wireTurns(responses: false))
        expect(!String(decoding: privateWire, as: UTF8.self).contains(nativeSession.uuidString), "Background execution authority tokens are never sent to the model")
        var privateRoute = ConversationRoute(mode: .task, request: "创建日程", message: "开始处理", execution: .native)
        privateRoute.backgroundControlToken = nativeSession; privateRoute.originConversationID = UUID()
        let restoredRoute = try JSONDecoder().decode(ConversationRoute.self, from: JSONEncoder().encode(privateRoute))
        expect(restoredRoute.execution == .native && restoredRoute.backgroundControlToken == nil && restoredRoute.originConversationID == nil,
               "An execution hint may persist while process-local authority and handoff ownership cannot be restored")
        let sentAt = ISO8601DateFormatter().date(from: "2026-10-25T15:59:59Z")!
        let midnightInput = try ConversationRoutingInput(question: "明天下午三点创建项目复盘", history: [], taskContext: "{}", now: sentAt, timeZoneIdentifier: "Asia/Shanghai")
        let timestamped = try midnightInput.executionReference(messageIDs: [])
        let payload = try JSONSerialization.jsonObject(with: Data(timestamped[timestamped.firstIndex(of: "{")!...].utf8)) as! [String: Any]
        let latest = payload["latestUserMessage"] as! [String: String]
        expect(latest["createdAt"] == "2026-10-25T15:59:59Z" && latest["timeZone"] == "Asia/Shanghai",
               "Even a standalone task carries the original send timestamp and timezone into execution across midnight")
        let historicReference = try longInput.executionReference(messageIDs: [user.id])
        let historicPayload = try JSONSerialization.jsonObject(with: Data(historicReference[historicReference.firstIndex(of: "{")!...].utf8)) as! [String: Any]
        expect((historicPayload["relatedMessages"] as? [[String: String]])?.first?["createdAt"] == ISO8601DateFormatter().string(from: user.createdAt),
               "Clarification references retain the original message's own timestamp")

        let discussion = ["先规划一下", "先别执行，给我看看方案", "帮我写一段闹钟示例，不要执行", "只讨论一下怎么设置日历", "暂时解释一下这个操作"]
        for text in discussion { expect(ConversationTurnSignal.discussionOnly(text), "Explicit discussion boundary: " + text) }
        let actions = ["帮我设置明天七点的闹钟", "给闹钟取名‘不要执行’并设置明天七点", "就叫不要执行，并设置明天七点",
            "请复制文字：\"不要执行\"", "帮我查机票，不要下单", "不要创建重复事件，先查是否已经存在", "先规划一下，然后直接执行", "先规划一下，之后直接做"]
        for text in actions { expect(!ConversationTurnSignal.discussionOnly(text), "Quoted payloads and bounded read requests retain semantic routing: " + text) }
        for value in ["半小时", "明天下午三点", "第二个", "改成明天", "不重复"] { expect(ConversationTurnSignal.slotLike(value), "Recognized retrieval follow-up: " + value) }
        for value in ["帮我创建另一个任务", "换个话题", "怎么设置", "谢谢", "我饿了"] { expect(!ConversationTurnSignal.slotLike(value), "An unrelated turn is not a slot-only retrieval hint: " + value) }
        for value in ["半小时", "明天下午三点，半小时", "改成明天下午三点", "第二个"] { expect(ConversationTurnSignal.parameterOnly(value), "Strong parameter-only fragment: " + value) }
        for value in ["明天下午去打球", "明天帮我订机票", "第二个任务帮我重新写", "工作日去开会"] { expect(!ConversationTurnSignal.parameterOnly(value), "A new goal is never bound using only a temporal prefix: " + value) }
        expect(ConversationTurnSignal.cancelsPending("不用了") && !ConversationTurnSignal.cancelsPending("停止当前正在运行的任务"), "Pending cancellation and active execution control retain distinct targets")
        expect(!ConversationTurnSignal.cancelsPending("不用了，改成帮我查机票") && !ConversationTurnSignal.cancelsPending("解释一下“不用了”"), "Compound instructions and quoted cancellation remain semantic inputs")
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let cases = corpus["cases"] as! [[String: Any]]
        expect(cases.count == 31 && Set(cases.compactMap { $0["id"] as? String }).count == cases.count, "The shared live-evaluation corpus contains thirty-one uniquely named scenarios")
        let allowed = Set(["chat", "task", "clarify", "supplement", "resume", "pause", "stop", "flightQuery", "paotuiQuery"])
        expect(cases.allSatisfy { !($0["question"] as? String ?? "").isEmpty && !($0["expectedModes"] as? [String] ?? []).isEmpty && Set($0["expectedModes"] as? [String] ?? []).isSubset(of: allowed) }, "Live-evaluation cases use the actual registered mode contract")
        print("Validated 31 synthetic evaluation cases; real-model classification scoring was not run.")
        print("Understanding checks passed (\(checks) checks; real shared policy/state, no model or account access)")
    }
}
