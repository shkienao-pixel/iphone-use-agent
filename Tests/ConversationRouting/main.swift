import Foundation

@main struct ConversationRoutingChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func rejects(_ label: String, operation: () async throws -> Void) async {
            do { try await operation(); expect(false, label) } catch { expect(true, label) }
        }
        func wire(_ connected: Bool) throws -> (guide: String, turns: [[String: Any]], body: [String: Any]) {
            let body = try JSONSerialization.jsonObject(with: RoutingWireProbe.requests.last!.httpBody!) as! [String: Any]
            if connected { return (body["instructions"] as! String, body["input"] as! [[String: Any]], body) }
            let messages = body["messages"] as! [[String: Any]]
            return (messages[0]["content"] as! String, Array(messages.dropFirst()), body)
        }
        func settleGate() async throws {
            for _ in 0..<2000 {
                if RoutingWireProbe.pending != nil { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw AgentError.message("Offline routing response did not reach its gate")
        }
        defer { PrivacyConsent.revoke() }
        for connected in [false, true] {
            let label = connected ? "Responses" : "Custom"
            var settings = AgentSettings()
            settings.endpoint = connected ? "https://api.openai.com/v1/chat/completions" : "https://routing.invalid/v1/chat/completions"
            settings.maxResponseTokens = 6144; settings.jsonMode = true
            PrivacyConsent.grant(settings)
            let router = UnifiedConversationRouter(settings: settings, apiKey: "offline-unused")
            RoutingWireProbe.reset()
            let control = try await router.route(question: "你好", history: [], taskContext: "{}")
            expect(control.mode == .chat, label + ": ordinary short question remains routable")
            var payload = try wire(connected)
            expect(payload.guide.contains("You route the LATEST USER MESSAGE"), label + ": routing guide occupies the system/instructions field")
            expect(payload.guide.contains("Automatic execution:") && payload.guide.contains("Start immediately"), label + ": normal task routing sends automatic execution policy")
            var reviewSettings = settings
            reviewSettings.confirmEachStep = true
            _ = try await UnifiedConversationRouter(settings: reviewSettings, apiKey: "offline-unused").route(question: "查看测试事项", history: [], taskContext: "{}")
            let reviewPayload = try wire(connected)
            expect(reviewPayload.guide.contains("Review mode:") && !reviewPayload.guide.contains("Automatic execution:"), label + ": explicit review mode replaces the automatic policy")
            _ = try await router.route(question: "你好", history: [], taskContext: "{}")
            payload = try wire(connected)
            expect(payload.turns.last?["role"] as? String == "user" && payload.turns.last?["content"] as? String == "你好",
                   label + ": latest user turn contains exactly the current human question")
            expect(payload.guide.contains("记忆与意图") && payload.guide.contains("先规划一下"), label + ": every request loads the bundled intent skill")
            expect(payload.guide.contains("Health queries also require screen") && !payload.guide.contains("authorized health/"),
                   label + ": foreground authorization constraints match the background capability policy")
            let outputBudget = payload.body[connected ? "max_output_tokens" : "max_completion_tokens"] as? Int
            expect(outputBudget == settings.responseTokenLimit, label + ": route output uses the configured reply budget")
            if connected {
                expect((payload.body["tools"] as? [Any])?.isEmpty == true && payload.body["tool_choice"] as? String == "none",
                       label + ": routing has no search or phone tools")
            } else {
                expect((payload.body["response_format"] as? [String: String])?["type"] == "json_object",
                       label + ": configured JSON routing format is retained")
            }

            RoutingWireProbe.reset()
            try RoutingWireProbe.route("xiaohongshuQuery", request: #"{"action":"search","keyword":"咖啡"}"#)
            do {
                _ = try await router.route(question: "搜索小红书咖啡", history: [], taskContext: "{}")
                expect(false, label + ": withdrawn XHS connector must reject stale model routing")
            } catch { expect(true, label + ": withdrawn XHS connector rejects stale model routing") }
            let withdrawnWire = try wire(connected)
            expect(!withdrawnWire.guide.contains("xiaohongshuQuery"), label + ": withdrawn connector is absent from routing instructions")
            expect(withdrawnWire.turns.last?["content"] as? String == "搜索小红书咖啡", label + ": original human text remains unchanged")

            let marker = "OLD-REFERENCE-INSTRUCTION-DO-NOT-PROMOTE"
            let context = "{\"tasks\":[{\"goal\":\"" + marker + String(repeating: "历史任务参考", count: 1000) + "\"}]}"
            RoutingWireProbe.reset()
            let contextual = try? await router.route(question: "继续讨论", history: [.init(role: "user", text: "历史用户资料"), .init(role: "assistant", text: "历史助手回复")], taskContext: context)
            expect(contextual?.mode == .chat, label + ": structured task data does not consume the current-question length budget")
            if contextual != nil {
                payload = try wire(connected)
                expect(!payload.guide.contains(marker), label + ": historical task content is never promoted into system instructions")
                expect(payload.turns.dropLast().contains { ($0["content"] as? String)?.contains(marker) == true }, label + ": reference data remains available as a separate earlier turn")
                expect(payload.turns.last?["content"] as? String == "继续讨论", label + ": reference text cannot replace the latest human turn")
            } else {
                expect(false, label + ": historical task content is never promoted into system instructions")
                expect(false, label + ": reference data remains available as a separate earlier turn")
                expect(false, label + ": reference text cannot replace the latest human turn")
            }

            RoutingWireProbe.reset()
            let longQuestion = String(repeating: "问", count: 4000)
            let longResult = try? await router.route(question: longQuestion, history: [], taskContext: "{}")
            expect(longResult?.mode == .chat, label + ": the complete 4000-character question remains valid")
            if longResult != nil {
                let lastQuestion = try wire(connected).turns.last?["content"] as? String
                expect(lastQuestion == longQuestion, label + ": long current instructions are never silently truncated")
            }
            else { expect(false, label + ": long current instructions are never silently truncated") }

            RoutingWireProbe.reset()
            let largeContext = "{\"memo\":\"" + String(repeating: "r", count: 63_900) + "\"}"
            let largeResult = try? await router.route(question: "继续核对", history: [], taskContext: largeContext)
            expect(largeResult?.mode == .chat, label + ": bounded large reference data remains separate from the question cap")
            for question in ["", " \n\t ", String(repeating: "问", count: 4001)] {
                let before = RoutingWireProbe.requests.count
                await rejects(label + ": invalid current question is rejected before transport") { _ = try await router.route(question: question, history: [], taskContext: "{}") }
                expect(RoutingWireProbe.requests.count == before, label + ": invalid question starts no request")
            }
            let beforeHugeContext = RoutingWireProbe.requests.count
            await rejects(label + ": unbounded reference data is rejected") { _ = try await router.route(question: "继续", history: [], taskContext: String(repeating: "r", count: 64_001)) }
            expect(RoutingWireProbe.requests.count == beforeHugeContext, label + ": oversize reference data starts no request")

            RoutingWireProbe.reset()
            var history = (0..<14).map { AssistantMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "turn-\($0)-" + String(repeating: "x", count: 3000)) }
            history[13] = AssistantMessage(role: "system", text: "UNTRUSTED-SYSTEM-HISTORY")
            _ = try await router.route(question: "当前问题", history: history, taskContext: "{}")
            payload = try wire(connected)
            expect(payload.turns.count <= 14 && payload.turns.allSatisfy { ["user", "assistant"].contains($0["role"] as? String ?? "") }, label + ": bounded history cannot inject another system role")
            let text = payload.turns.compactMap { $0["content"] as? String }.joined(separator: "\n")
            expect(text.contains("turn-12-") && !text.contains("turn-0-") && !text.contains("UNTRUSTED-SYSTEM-HISTORY"), label + ": history keeps recent eligible turns only")
            expect(payload.turns.dropLast().allSatisfy { (($0["content"] as? String)?.count ?? 0) <= 2000 }, label + ": history text remains bounded independently")

            let image = ComposerAttachment(name: "history.jpg", kind: .image, byteCount: 4, text: "", imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            let document = ComposerAttachment(name: "history.txt", kind: .text, byteCount: 20, text: "HISTORICAL-ATTACHMENT-PAYLOAD", imageJPEG: nil)
            RoutingWireProbe.reset()
            _ = try await router.route(question: "继续讨论资料", history: [.init(role: "user", text: "历史附件问题", attachments: [image, document])], taskContext: "{}")
            let requestText = String(decoding: RoutingWireProbe.requests.last!.httpBody!, as: UTF8.self)
            expect(!requestText.contains("data:image") && !requestText.contains(document.text), label + ": intent routing does not re-upload historical attachment payloads")

            RoutingWireProbe.reset()
            let pendingAlarm = [AssistantMessage(role: "user", text: "帮我创建每天早上七点的闹钟"),
                AssistantMessage(role: "assistant", text: "闹钟叫什么名字？")]
            let planningOnly = try await router.route(question: "先规划一下", history: pendingAlarm, taskContext: "{}")
            expect(planningOnly.mode == .chat, label + ": planning after an alarm clarification never treats the planning request as an executable alarm title")

            let memoryID = UUID(), original = AssistantMessage(role: "user", text: "给我创建一个日历事件")
            let clarification = AssistantMessage(role: "assistant", text: "安排在什么时候？", intent:
                .init(mode: .clarify, module: "clarification", missingInformation: ["开始时间"]))
            let recalled = "{\"relevantMemories\":[{\"id\":\"" + memoryID.uuidString + "\",\"text\":\"MEMORY-REFERENCE-MARKER\"}]}"
            let grounded = try ConversationRoutingInput(question: "明天九点", history: [original, clarification], taskContext: "{}", memoryContext: recalled)
            RoutingWireProbe.reset()
            RoutingWireProbe.content = String(decoding: try JSONSerialization.data(withJSONObject: [
                "mode": "task", "request": "MODEL-RECONSTRUCTION-MUST-NOT-EXECUTE", "message": "开始处理", "taskID": NSNull(),
                "relatedMessageIDs": [original.id.uuidString], "memorySourceIDs": [memoryID.uuidString], "missingInformation": []
            ]), as: UTF8.self)
            let groundedRoute = try await router.route(input: grounded)
            payload = try wire(connected)
            expect(groundedRoute.request == "明天九点" && groundedRoute.executionReference.contains(original.text), label + ": a slot answer keeps the latest goal and carries verbatim current-chat grounding separately")
            expect(!groundedRoute.executionReference.contains("MODEL-RECONSTRUCTION"), label + ": model-rewritten instructions never enter execution reference")
            expect(groundedRoute.record.module == "task-executor" && groundedRoute.record.memorySourceIDs == [memoryID], label + ": interpretation records the actual module and validated memory source")
            expect(groundedRoute.relation == .answer && groundedRoute.pendingIntentID == clarification.id, label + ": the real router binds a short answer to its current clarification ledger")
            expect(!payload.guide.contains("MEMORY-REFERENCE-MARKER") && payload.turns.contains { ($0["content"] as? String)?.contains(recalled) == true }, label + ": recalled memory reaches routing as separate data, never system instructions")
            expect(payload.turns.contains { ($0["content"] as? String)?.contains("开始时间") == true && ($0["content"] as? String)?.contains(clarification.id.uuidString) == true }, label + ": working state carries the real pending question and message identities")

            RoutingWireProbe.reset(); try RoutingWireProbe.route("task", request: "MISROUTED-PLAN", message: "开始处理")
            let planningGuard = try await router.route(question: "先规划一下，不要执行", history: [original, clarification], taskContext: "{}")
            expect(planningGuard.mode == .chat && planningGuard.decisionSource == "explicitDiscussion" && planningGuard.proposedMode == .task,
                   label + ": explicit discussion blocks a model's mistaken action while retaining proposal diagnostics")
            RoutingWireProbe.reset(); try RoutingWireProbe.route("task", request: "NORMAL-REQUEST", message: "开始处理")
            let namedPayload = try await router.route(question: "帮我设置明天七点的单次闹钟，名称叫“不要执行”", history: [], taskContext: "{}")
            expect(namedPayload.mode == .task, label + ": a quoted name is data and does not revoke the actual task instruction")
            RoutingWireProbe.reset(); try RoutingWireProbe.route("flightQuery", request: "明天上海到北京，1人，查价")
            let readOnlyQuery = try await router.route(question: "查明天上海到北京的机票，不要下单", history: [], taskContext: "{}")
            expect(readOnlyQuery.mode == .flightQuery, label + ": a read-only limit does not turn an authorized query into generic chat")

            var datedOriginal = original; datedOriginal.text = "给我创建明天的日历事件"
            let staleInput = try ConversationRoutingInput(question: "半小时", history: [datedOriginal, clarification], taskContext: "{}", now: Date().addingTimeInterval(259_200))
            RoutingWireProbe.reset(); try RoutingWireProbe.route("task", request: "INCOMPLETE-OLD-REQUEST", message: "开始处理")
            let expired = try await router.route(input: staleInput)
            expect(expired.mode == .clarify && expired.decisionSource == "expiredPending" && expired.executionReference.isEmpty,
                   label + ": an expired pending request cannot become an action even when the model selects task")
            RoutingWireProbe.reset(); try RoutingWireProbe.route("task", request: "x", message: "开始处理")
            let freshDateInput = try ConversationRoutingInput(question: "改成明天下午三点，半小时", history: [datedOriginal, clarification], taskContext: "{}", now: Date().addingTimeInterval(259_200))
            let refreshed = try await router.route(input: freshDateInput)
            expect(refreshed.mode == .task && refreshed.relation == .answer && refreshed.executionReference.contains(datedOriginal.text),
                   label + ": a new explicit date refreshes an expired pending request while preserving its original goal")
            RoutingWireProbe.reset(); try RoutingWireProbe.route("task", request: "x", message: "开始处理")
            let orphan = try await router.route(question: "半小时", history: [], taskContext: "{}")
            expect(orphan.mode == .clarify && orphan.decisionSource == "missingPending", label + ": a parameter without its source cannot become a standalone task")
            RoutingWireProbe.reset(); try RoutingWireProbe.route("stop", message: "停止任务")
            let beforePendingCancellation = RoutingWireProbe.requests.count
            let cancelledPending = try await router.route(question: "不用了", history: [original, clarification], taskContext: "{}")
            expect(cancelledPending.mode == .clarify && !cancelledPending.controlsTask && cancelledPending.decisionSource == "cancelPending" && RoutingWireProbe.requests.count == beforePendingCancellation,
                   label + ": cancelling a pending question cannot stop an unrelated running task or require another model call")
            RoutingWireProbe.reset()
            RoutingWireProbe.content = String(decoding: try JSONSerialization.data(withJSONObject: [
                "mode": "task", "request": "x", "message": "开始处理", "taskID": NSNull(),
                "relation": "answer", "pendingIntentID": UUID().uuidString
            ]), as: UTF8.self)
            await rejects(label + ": a reply cannot bind a different pending request") { _ = try await router.route(input: grounded) }

            let embeddedID = UUID()
            let embeddedMemory = "{\"relevantMemories\":[{\"id\":\"" + memoryID.uuidString + "\",\"text\":\"quoted source " + embeddedID.uuidString + "\"}]}"
            RoutingWireProbe.reset()
            RoutingWireProbe.content = String(decoding: try JSONSerialization.data(withJSONObject: [
                "mode": "task", "request": "x", "message": "开始处理", "taskID": NSNull(), "memorySourceIDs": [embeddedID.uuidString]
            ]), as: UTF8.self)
            await rejects(label + ": a UUID embedded in a memory quote cannot impersonate an owned source") {
                _ = try await router.route(question: "本轮要求", history: [], taskContext: "{}", memoryContext: embeddedMemory)
            }
            RoutingWireProbe.reset()
            RoutingWireProbe.content = String(decoding: try JSONSerialization.data(withJSONObject: [
                "mode": "chat", "request": "", "message": "", "taskID": NSNull(), "memorySourceIDs": [embeddedID.uuidString]
            ]), as: UTF8.self)
            let repairedChat = try await router.route(question: "解释这个概念", history: [], taskContext: "{}", memoryContext: embeddedMemory)
            expect(repairedChat.mode == .chat && repairedChat.memorySourceIDs?.isEmpty == true && repairedChat.decisionSource == "filteredReferences",
                   label + ": an unusable citation is removed from non-executing chat without breaking the conversation")

            let currentDocument = ComposerAttachment(name: "本轮.txt", kind: .text, byteCount: 20, text: "CURRENT-ATTACHMENT-REFERENCE", imageJPEG: nil)
            let multimedia = try ConversationRoutingInput(question: "参考这张图和文件，先规划一下", history: [], taskContext: "{}", memoryContext: recalled, attachments: [image, currentDocument])
            RoutingWireProbe.reset()
            let mediaRoute = try await router.route(input: multimedia)
            payload = try wire(connected)
            let parts = payload.turns.last?["content"] as? [[String: Any]] ?? []
            let wireBody = String(decoding: RoutingWireProbe.requests.last!.httpBody!, as: UTF8.self)
            expect(mediaRoute.mode == .chat && parts.first?["text"] as? String == multimedia.question, label + ": multimedia passes through the same intent classifier with the exact user question")
            expect(parts.contains { $0["type"] as? String == (connected ? "input_image" : "image_url") } && wireBody.contains(currentDocument.text), label + ": only this turn's actual pixels and document text reach the selected model protocol")

            RoutingWireProbe.reset(); try RoutingWireProbe.route("task", request: "NEW-MODEL-TEXT", message: "开始处理")
            let attachedTask = try await router.route(input: multimedia)
            expect(attachedTask.attachments == [image, currentDocument], label + ": a new task binds the original supplied attachment objects")
            let encodedRoute = try JSONEncoder().encode(attachedTask)
            let decodedRoute = try JSONDecoder().decode(ConversationRoute.self, from: encodedRoute)
            expect(decodedRoute.attachments.isEmpty && decodedRoute.executionReference.isEmpty, label + ": persisted/model route JSON cannot restore attachment or execution authority")

            RoutingWireProbe.reset()
            RoutingWireProbe.content = "{\"mode\":\"task\",\"request\":\"MODEL-TEXT\",\"message\":\"开始处理\",\"execution\":\"native\"}"
            var nativeSettings = settings; nativeSettings.systemToolsEnabled = true
            let nativeTask = try await UnifiedConversationRouter(settings: nativeSettings, apiKey: "offline-unused").route(
                question: "查询我的日历", history: [], taskContext: "{}")
            expect(nativeTask.execution == .native && nativeTask.request == "查询我的日历", label + ": a native hint retains the exact human request for independent execution")
            nativeSettings.systemToolsEnabled = false
            let unavailableNative = try await UnifiedConversationRouter(settings: nativeSettings, apiKey: "offline-unused").route(
                question: "查询我的日历", history: [], taskContext: "{}")
            expect(unavailableNative.execution == .screen, label + ": a model hint cannot enable disabled native tools")
            if connected {
                let format = (try wire(connected).body["text"] as? [String: Any])?["format"] as? [String: Any]
                let schema = format?["schema"] as? [String: Any]
                expect((schema?["required"] as? [String])?.contains("execution") == true,
                       label + ": the strict route schema declares the execution-lane hint")
            }

            let observation = try ConversationRoutingInput(question: "看看画面", history: [], taskContext: "{}", memoryContext: recalled,
                visuals: [.init(jpeg: image.imageJPEG!, capturedAt: Date(), source: "相机观察")])
            RoutingWireProbe.reset(); _ = try await router.route(input: observation)
            expect(String(decoding: RoutingWireProbe.requests.last!.httpBody!, as: UTF8.self).contains("相机观察"), label + ": camera observations also pass through memory-aware intent routing")

            for key in ["relatedMessageIDs", "memorySourceIDs"] {
                RoutingWireProbe.reset()
                RoutingWireProbe.content = String(decoding: try JSONSerialization.data(withJSONObject: [
                    "mode": "task", "request": "x", "message": "开始处理", "taskID": NSNull(), key: [UUID().uuidString]
                ]), as: UTF8.self)
                await rejects(label + ": invented " + key + " is rejected before dispatch") { _ = try await router.route(input: grounded) }
            }
            RoutingWireProbe.reset()
            let memoryRequests = RoutingWireProbe.requests.count
            await rejects(label + ": oversized recalled memory is rejected independently of the latest question") {
                _ = try await router.route(question: "当前问题", history: [], taskContext: "{}", memoryContext: String(repeating: "x", count: 40_001))
            }
            expect(RoutingWireProbe.requests.count == memoryRequests, label + ": invalid recalled memory sends no request")

            for mode in ["task", "supplement", "pause", "resume", "stop", "clarify"] {
                RoutingWireProbe.reset(); try RoutingWireProbe.route(mode, request: "打开时钟", message: " \n\t ")
                await rejects(label + ": blank " + mode + " acknowledgement is rejected") { _ = try await router.route(question: "帮我打开时钟", history: [], taskContext: "{}") }
            }
            for mode in ["task", "supplement", "pause", "resume", "stop", "clarify", "flightQuery"] {
                RoutingWireProbe.reset()
                let needsRequest = ["task", "supplement", "flightQuery"].contains(mode)
                try RoutingWireProbe.route(mode, request: needsRequest ? "  打开时钟  " : "", message: mode == "flightQuery" ? "" : "  收到请求 \n")
                let route = try await router.route(question: "本次明确要求", history: [], taskContext: "{}")
                expect(route.mode.rawValue == mode && route.message == (mode == "flightQuery" ? "" : "收到请求"), label + ": valid " + mode + " reply remains usable and normalized")
                if needsRequest {
                    let expected = [.task, .supplement].contains(route.mode) ? "本次明确要求" : "打开时钟"
                    expect(route.request == expected, label + ": execution uses literal human text while flight search retains resolved content")
                }
            }
            RoutingWireProbe.reset()
            let taskID = UUID()
            for mode in ["task", "supplement"] {
                RoutingWireProbe.reset(); try RoutingWireProbe.route(mode, request: "先查联系人，再执行上一轮13条提醒与日历", message: "开始处理")
                let literal = "仅查询专用测试联系人，不执行日历或提醒任务。"
                let isolated = try await router.route(question: literal, history: [.init(role: "user", text: "上一轮创建13个对象")], taskContext: "{}")
                expect(isolated.request == literal, label + ": model-expanded " + mode + " cannot acquire old task operations")
            }
            RoutingWireProbe.reset()
            try RoutingWireProbe.route("resume", message: "收到继续请求", taskID: taskID.uuidString)
            let referenced = try await router.route(question: "继续这项任务", history: [], taskContext: "{}")
            expect(referenced.taskID == taskID, label + ": valid task identity survives decoding without remapping")

            for bad in [#"{"mode":"unknown","request":"x","message":"x","taskID":null}"#,
                        #"{"mode":"task","request":"","message":"收到请求","taskID":null}"#,
                        #"{"mode":"resume","request":"","message":"收到请求","taskID":"invalid"}"#,
                        "{broken", "{}"] {
                RoutingWireProbe.reset(); RoutingWireProbe.content = bad
                await rejects(label + ": malformed or incomplete route data is rejected") { _ = try await router.route(question: "本次请求", history: [], taskContext: "{}") }
            }
            RoutingWireProbe.reset(); try RoutingWireProbe.route("task", request: String(repeating: "x", count: 4001), message: "收到请求")
            await rejects(label + ": oversize generated request is rejected") { _ = try await router.route(question: "本次请求", history: [], taskContext: "{}") }
            RoutingWireProbe.reset(); try RoutingWireProbe.route("clarify", message: String(repeating: "x", count: 1001))
            await rejects(label + ": oversize generated acknowledgement is rejected") { _ = try await router.route(question: "本次请求", history: [], taskContext: "{}") }

            RoutingWireProbe.reset(); RoutingWireProbe.finishReason = "length"; RoutingWireProbe.responseStatus = "incomplete"
            await rejects(label + ": truncated response is rejected even if its text looks like valid JSON") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            RoutingWireProbe.reset(); RoutingWireProbe.refusal = true
            await rejects(label + ": refusal is never accepted as a route") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            RoutingWireProbe.reset(); RoutingWireProbe.statusCode = 503
            await rejects(label + ": HTTP failure is rejected") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            for (status, code, expected) in [(429, "insufficient_quota", "余额或用量额度不足"), (429, "rate_limit_exceeded", "限速"), (401, "invalid_api_key", "身份验证"), (400, "invalid_json_schema", "结构化回复格式")] {
                RoutingWireProbe.reset(); RoutingWireProbe.statusCode = status
                RoutingWireProbe.rawPayload = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "PRIVATE-PROVIDER-ERROR-MUST-NOT-LEAK"]])
                do {
                    _ = try await router.route(question: "请你给我创建一个明天早上9:10的铃。", history: [], taskContext: "{}")
                    expect(false, label + ": HTTP error cannot produce a task route")
                } catch {
                    expect(error.localizedDescription.contains("HTTP \(status)") && error.localizedDescription.contains(expected), label + ": routing explains the concrete HTTP failure class")
                    expect(!error.localizedDescription.contains("PRIVATE-PROVIDER"), label + ": routing never echoes raw provider errors")
                }
            }
            RoutingWireProbe.reset(); RoutingWireProbe.responseURL = URL(string: "https://different.invalid/response")!
            await rejects(label + ": response from another origin is rejected") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            RoutingWireProbe.reset(); RoutingWireProbe.rawPayload = Data("{truncated envelope".utf8)
            await rejects(label + ": malformed provider envelope is rejected") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            RoutingWireProbe.reset(); RoutingWireProbe.content = ""
            await rejects(label + ": empty provider output is rejected") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            RoutingWireProbe.reset(); RoutingWireProbe.transportError = URLError(.timedOut)
            let beforeTimeout = RoutingWireProbe.requests.count
            await rejects(label + ": transport timeout remains a failure") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            expect(RoutingWireProbe.requests.count == beforeTimeout + 1, label + ": timeout never automatically resends the request")

            RoutingWireProbe.reset(); PrivacyConsent.revoke()
            let beforeConsent = RoutingWireProbe.requests.count
            await rejects(label + ": revoked consent blocks routing") { _ = try await router.route(question: "继续", history: [], taskContext: "{}") }
            expect(RoutingWireProbe.requests.count == beforeConsent, label + ": revoked consent starts no transport")
            PrivacyConsent.grant(settings)

            RoutingWireProbe.reset(); RoutingWireProbe.gateNext = true
            let delayed = Task { () -> Bool in
                do { _ = try await router.route(question: "随后取消", history: [], taskContext: "{}"); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            try await settleGate(); delayed.cancel(); RoutingWireProbe.resume()
            let delayedCancelled = await delayed.value
            expect(delayedCancelled, label + ": late uncooperative response remains cancelled")
            RoutingWireProbe.reset()
            let beforeCancelled = RoutingWireProbe.requests.count
            let cancelled = Task { () -> Bool in
                do { _ = try await router.route(question: "取消前不得请求", history: [], taskContext: "{}"); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            cancelled.cancel(); let cancelledAtEntry = await cancelled.value
            expect(cancelledAtEntry && RoutingWireProbe.requests.count == beforeCancelled, label + ": cancellation before entry starts no request")

            if !connected {
                var legacy = settings; legacy.legacyTokenLimit = true; legacy.jsonMode = false
                PrivacyConsent.grant(legacy); RoutingWireProbe.reset()
                _ = try await UnifiedConversationRouter(settings: legacy, apiKey: "offline-unused").route(question: "你好", history: [], taskContext: "{}")
                payload = try wire(false)
                expect(payload.body["max_tokens"] as? Int == legacy.responseTokenLimit && payload.body["max_completion_tokens"] == nil,
                       "Custom: legacy token-limit configuration is respected")
                expect(payload.body["response_format"] == nil, "Custom: JSON-format opt-out is respected")

                PrivacyConsent.grant(settings); RoutingWireProbe.reset(); RoutingWireProbe.content = "普通自然语言回答"
                let answer = try await VisionClient(settings: settings, apiKey: "offline-unused").answer(question: "看看附件", frame: nil, history: [], attachments: [image, document])
                payload = try wire(false)
                let normalBody = String(decoding: RoutingWireProbe.requests.last!.httpBody!, as: UTF8.self)
                expect(answer == "普通自然语言回答" && !payload.guide.contains("You route the LATEST USER MESSAGE"), "Ordinary answers keep their natural-language instructions")
                expect(normalBody.contains("data:image") && normalBody.contains(document.text), "Ordinary answers retain explicitly supplied attachment payloads")
                expect(payload.body["response_format"] == nil, "Routing JSON configuration does not leak into ordinary answers")
            }
        }
        for (endpoint, finalURL, official, path, port, query) in [
            ("HTTPS://ROUTING.INVALID/v1/chat/completions", "https://routing.invalid/v1/chat/completions", false, "/v1/chat/completions", nil as Int?, nil as String?),
            ("HTTPS://API.OPENAI.COM/v1/chat/completions", "https://api.openai.com/v1/responses", true, "/v1/responses", nil, nil),
            ("https://api.openai.com:8443/v1/chat/completions", "https://api.openai.com:8443/v1/chat/completions", false, "/v1/chat/completions", 8443, nil),
            ("https://api.openai.com/v1/chat/completions?fixture=1", "https://api.openai.com/v1/chat/completions?fixture=1", false, "/v1/chat/completions", nil, "fixture=1")
        ] {
            var settings = AgentSettings(); settings.endpoint = endpoint
            PrivacyConsent.grant(settings); RoutingWireProbe.reset(); RoutingWireProbe.responseURL = URL(string: finalURL)!
            expect(ConnectedConversationClient.supports(settings) == official, "Endpoint family honors case, port and query: " + endpoint)
            let result = try? await UnifiedConversationRouter(settings: settings, apiKey: "offline-unused").route(question: "你好", history: [], taskContext: "{}")
            expect(result?.mode == .chat, "Valid endpoint variants remain routable: " + endpoint)
            let outgoing = RoutingWireProbe.requests.last?.url
            expect(outgoing?.path == path && outgoing?.port == port && outgoing?.query == query, "Configured origin, path and query are retained: " + endpoint)
        }
        let upperOrigin = URL(string: "HTTPS://ROUTING.INVALID/v1/chat/completions")!
        expect(ModelEndpointPolicy.permitsRedirect(from: upperOrigin, to: URL(string: "https://routing.invalid:443/redirect")!), "Scheme/host case and explicit default HTTPS port preserve origin identity")
        expect(!ModelEndpointPolicy.permitsRedirect(from: upperOrigin, to: URL(string: "https://routing.invalid:8443/redirect")!), "A different HTTPS port remains another origin")
        expect(!ModelEndpointPolicy.permitsRedirect(from: upperOrigin, to: URL(string: "http://routing.invalid/redirect")!), "HTTP downgrade remains blocked")
        let report: [String: Any] = ["checks": checks, "failures": failures,
            "scope": "Actual router and both clients; only HTTP load replaced. No model quality, device actions, account access or phone acceptance."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
