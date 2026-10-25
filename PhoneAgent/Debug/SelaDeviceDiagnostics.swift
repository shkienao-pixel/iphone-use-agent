#if DEBUG
import Foundation
import UIKit
import EventKit
import ActivityKit

/// Cable-only, opt-in developer session. No HTTP listener or credentials in output.
@MainActor enum SelaDeviceDiagnostics {
    struct Command: Decodable {
        let id: String
        let session: String
        let operation: String
        var value: String?
        var x: Double?
        var y: Double?
        let expiresAt: Double
    }
    static var probeSettings: AgentSettings?
    static var travelChecks: [String: String] = [:]
    static var flightAttempts = 0
    static var flightRealtimeUnavailable = false
    static var notificationChecks: [String: Any] = [:]
    static func run(model: PhoneAgentViewModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--sela-device-debug"), arguments.indices.contains(index + 1),
              UUID(uuidString: arguments[index + 1]) != nil else { return }
        let session = arguments[index + 1]
        let root = URL.documentsDirectory.appendingPathComponent("SelaDeviceDebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("command.json")
        var lastID = "", lastError = "", lastOperation = ""
        while !Task.isCancelled {
            do {
                if FileManager.default.fileExists(atPath: input.path) {
                    guard (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4096 else { throw AgentError.message("调试指令过大") }
                    let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: input))
                    try FileManager.default.removeItem(at: input)
                    guard command.session == session, command.id != lastID,
                          Date().timeIntervalSince1970 < command.expiresAt,
                          command.expiresAt - Date().timeIntervalSince1970 <= 15 else { throw AgentError.message("调试指令过期或会话不匹配") }
                    lastID = command.id; lastOperation = command.operation; lastError = ""
                    switch command.operation {
                    case "intent_evaluate":
                        Task {
                            try? await IntentEvaluationRunner.run(model: model,
                                destination: root.appendingPathComponent("intent-evaluation.json"))
                        }
                    #if targetEnvironment(simulator)
                    case "notification_fixture":
                        try await TaskNotificationSimulatorFixtures.apply(command.value, model: model)
                    case "notification_status":
                        notificationChecks = await model.taskNotifications.diagnostics()
                    case "activity_fixture":
                        try await TaskActivitySimulatorFixtures.apply(command.value, model: model)
                    #endif
                    case "navigate":
                        let destination: WorkspaceDestination
                        switch command.value {
                        case "calendar": destination = .nativeAppConnection(.calendar)
                        case "reminders": destination = .nativeAppConnection(.reminders)
                        case "contacts": destination = .nativeAppConnection(.contacts)
                        case "photos": destination = .nativeAppConnection(.photos)
                        case "music": destination = .nativeAppConnection(.music)
                        case "health": destination = .nativeAppConnection(.health)
                        case "location": destination = .nativeAppConnection(.location)
                        case "notes": destination = .nativeAppConnection(.notes)
                        case "feishu": destination = .appConnection(.feishu)
                        case "wecom": destination = .appConnection(.wecom)
                        case "ctrip": destination = .appConnection(.ctrip)
                        case "meituan": destination = .appConnection(.meituan)
                        case "assistant": destination = .assistant
                        case "device": destination = .device
                        default: destination = .tasks
                        }
                        model.deviceDebugDestination = destination
                    case "request_permission":
                        guard let value = command.value, let app = NativeAppConnection(rawValue: value) else { throw AgentError.message("无效授权类型") }
                        Task { await NativeConnectionsStore.shared.request(app) }
                    case "prepare": model.prepareAutomatically()
                    case "tap", "long_press":
                        guard (!model.engine.running || (model.engine.phase == .awaitingApproval && model.tools.pending != nil)),
                              !model.manualBusy, !model.voicePending,
                              model.ble.ready, model.calibrationReady,
                              let x = command.x, let y = command.y, (0...1).contains(x), (0...1).contains(y) else { throw AgentError.message("手动调试点击未就绪") }
                        try await model.executor.locate(x: x, y: y)
                        if command.operation == "long_press" {
                            let connection = model.ble.pointerConnectionGeneration
                            do {
                                try await model.ble.send(.report, buttons: 1)
                                for _ in 0..<4 {
                                    try await Task.sleep(for: .milliseconds(300))
                                    try await model.ble.send(.report, buttons: 1)
                                }
                                try await model.ble.send(.release)
                            } catch { await model.ble.release(expectedConnection: connection); throw error }
                        } else { try await model.executor.click() }
                    case "automatic_execution":
                        model.settings.confirmEachStep = false
                    case "memory_test_isolate":
                        // Session-only isolation: verify learned recall without
                        // the separate legacy cross-chat excerpt retriever.
                        model.conversation.sharedContextEnabled = false
                    case "memory_test_restore":
                        model.conversation.sharedContextEnabled = true
                    case "configure_travel":
                        model.settings.liveTaskStatus = true
                        CtripStore.connectionMode = .legacy
                        CtripStore.enabled = CtripStore.hasCredential
                        let source = URL.documentsDirectory.appendingPathComponent("meituan-config.once.json")
                        if FileManager.default.fileExists(atPath: source.path) {
                            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                            guard attributes[.type] as? FileAttributeType == .typeRegular,
                                  (attributes[.size] as? NSNumber)?.intValue ?? 20000 <= 16384 else { throw AgentError.message("旅行配置文件无效") }
                            let data = try Data(contentsOf: source)
                            try FileManager.default.removeItem(at: source)
                            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String], let token = object["token"] else { throw AgentError.message("旅行配置无效") }
                            try MeituanConnectionStore.save(endpoint: MeituanTravelClient.endpoint.absoluteString, token: token)
                        }
                        Task {
                            do {
                                let text = try await CtripClient(apiKey: CtripStore.apiKey()).query(query: "查询上海一日游景点，仅查询，不预订不下单。")
                                travelChecks["ctrip"] = "ok:" + String(text.count)
                            } catch { travelChecks["ctrip"] = "failed" }
                        }
                        Task {
                            do {
                                let text = try await MeituanTravelClient(token: MeituanConnectionStore.credential).query("查询上海一日游景点，仅查询，不预订不下单。")
                                MeituanConnectionStore.verified(tools: ["旅行查询"])
                                travelChecks["meituan"] = "ok:" + String(text.count)
                            } catch { travelChecks["meituan"] = "failed" }
                        }
                    case "tools_task_mode":
                        probeSettings = model.settings
                        model.settings.confirmEachStep = false
                        model.settings.toolsOnly = true; model.settings.systemToolsEnabled = true
                    case "auto_tool_probe":
                        probeSettings = model.settings
                        model.settings.confirmEachStep = false
                        model.settings.toolsOnly = true; model.settings.systemToolsEnabled = true
                        model.goal = "请直接调用 ctrip_query 查询上海一日游景点，收到真实结果后结束。仅查询，不预订，不创建订单。用户已要求自动执行，不需要再次确认。"
                        model.startAgent()
                    case "live_probe":
                        probeSettings = model.settings
                        model.settings.toolsOnly = true; model.settings.systemToolsEnabled = true
                        model.goal = "查询今天的日历安排，读取前先等待我确认；不要调用其他工具。"
                        model.startAgent()
                    case "live_probe_end":
                        model.stop()
                        if let saved = probeSettings { model.settings = saved; probeSettings = nil }
                    case "chat_send", "chat_followup":
                        if command.operation == "chat_send" { model.conversation.newConversation() }
                        model.conversation.draft = String((command.value ?? "今天有什么 AI 大事发生？请联网核实并附来源链接。").prefix(4000))
                        _ = model.conversation.send(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint), memories: model.memories)
                    case "draft": model.goal = String((command.value ?? "").prefix(2000))
                    case "start": model.startAgent()
                    case "stop": model.stop()
                    case "stop_alarm_card_fixture_a09":
                        guard model.engine.executionSettled, !model.conversation.loading, model.tools.pending == nil else {
                            model.notice = "仍有任务或工具操作，未停止测试闹钟"; break
                        }
                        do { model.notice = try model.tools.stopAlarmCardFixtureA09() }
                        catch { model.notice = error.localizedDescription }
                    case "check_model":
                        Task {
                            do {
                                try await VisionClient(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint)).checkConnection()
                                model.notice = "模型网络连接正常"
                            } catch { model.notice = "模型连接检查：" + error.localizedDescription }
                        }
                    case "check_conversation_route":
                        // Classify the supplied text with the existing phone
                        // credential, without sending a chat or executing it.
                        let question = command.value ?? "你好"
                        Task {
                            do {
                                let route = try await UnifiedConversationRouter(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint))
                                    .route(question: question, history: model.conversation.messages,
                                           taskContext: model.unifiedTaskContext(history: model.conversation.messages))
                                travelChecks["conversation_route"] = "ok:" + route.mode.rawValue
                            } catch { travelChecks["conversation_route"] = "failed:" + error.localizedDescription }
                        }
                    case "check_plan_inference":
                        Task {
                            do {
                                let matched = try await VisionClient(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint)).checkPlanInference()
                                model.notice = matched ? "ChatGPT 计划最小推理已完成，固定文本匹配" : "ChatGPT 计划最小推理已完成，固定文本未匹配"
                            } catch { model.notice = "ChatGPT 计划最小推理：" + error.localizedDescription }
                        }
                    case "check_bridge": await ExternalConnectionsCoordinator.shared.checkBridge(); await ExternalConnectionsCoordinator.shared.refreshAll()
                    default: throw AgentError.message("未知调试操作")
                    }
                }
            } catch { lastError = error.localizedDescription }
            NativeConnectionsStore.shared.refresh()
            let permissions = Dictionary(uniqueKeysWithValues: NativeAppConnection.allCases.map { ($0.rawValue, NativeConnectionsStore.shared.state($0).title) })
            let chatGPTProfile = model.settings.usesChatGPTPlan ? ChatGPTPlanStore.selected() : nil
            let state: [String: Any] = ["session": session, "command": lastID, "operation": lastOperation, "error": lastError,
                "active": UIApplication.shared.applicationState == .active,
                "permissions": permissions, "eventKit": NativeEventAccess.shared.diagnostics,
                "calendar_raw": EKEventStore.authorizationStatus(for: .event).rawValue,
                "reminders_raw": EKEventStore.authorizationStatus(for: .reminder).rawValue,
                "permission_message": NativeConnectionsStore.shared.message,
                "model_ready": model.modelReady, "consent_ready": model.consentReady,
                "model_authentication": model.settings.modelAuthentication ?? "api_key",
                "chatgpt_plan_authorized": chatGPTProfile?.sharing == true,
                "chatgpt_access_expires_at": chatGPTProfile?.expiresAt?.timeIntervalSince1970 ?? 0,
                "chatgpt_model_count": model.settings.usesChatGPTPlan ? ChatGPTPlanAuthorization.shared.models.count : 0,
                "chatgpt_last_http_failure": ChatGPTPlanDiagnostics.snapshot(),
                "chatgpt_protocol_diagnostics": ChatGPTPlanDiagnostics.transportSnapshot(),
                "ble_ready": model.ble.ready, "calibration_ready": model.calibrationReady,
                "assistive_touch_ready": model.assistiveTouchReady,
                "capture_running": model.capture.running, "preparation_ready": model.preparationReady,
                "phase": model.engine.phase.rawValue, "step": model.engine.currentStep,
                "engine_error": model.engine.error, "notice": model.notice, "preparation_status": model.automaticPreparationStatus, "bridge_available": ExternalConnectionsCoordinator.shared.bridgeAvailable,
                "bridge_paired": ExternalConnectionsCoordinator.shared.paired,
                "confirm_each_step": model.settings.confirmEachStep,
                "tools_only": model.settings.toolsOnly == true,
                "continuous_execution": model.settings.runsContinuously,
                "current_task_id": model.engine.currentRecord?.id.uuidString ?? "",
                "engine_releasing": model.engine.releasing,
                "execution_settled": model.engine.executionSettled,
                "health_authorization_pending": NativeConnectionsStore.shared.healthAuthorizationPending,
                "tool_preview": model.tools.pending?.request.preview ?? "",
                "chat_route": model.conversation.lastRoute?.mode.rawValue ?? "",
                "chat_flight_cards": model.conversation.messages.last?.flightOffers?.count ?? 0,
                "chat_task_cards": model.conversation.messages.compactMap(\.taskID).count,
                "chat_message_count": model.conversation.messages.count,
                "chat_shared_context": model.conversation.sharedContextEnabled,
                "memory_learning": model.memories.intelligence.automaticLearning,
                "memory_count": model.memories.intelligence.learned.count,
                "memory_error": model.memories.intelligence.error,
                "flight_query_attempts": flightAttempts,
                "flight_realtime_unavailable": flightRealtimeUnavailable,
                "chat_loading": model.conversation.loading, "chat_error": model.conversation.error,
                "chat_response_model": model.conversation.messages.last(where: { $0.role == "assistant" })?.responseModel ?? "",
                "chat_used_web": model.conversation.messages.last(where: { $0.role == "assistant" })?.usedWebSearch ?? false,
                "chat_answer_length": model.conversation.messages.last(where: { $0.role == "assistant" })?.text.count ?? 0,
                "tool_pending": model.tools.pending?.request.operation.rawValue ?? "",
                "live_activity_enabled": model.settings.liveTaskStatus != false,
                "live_activity_authorized": ActivityAuthorizationInfo().areActivitiesEnabled,
                "live_activity_count": Activity<AgentActivityAttributes>.activities.count,
                "live_activity_states": Activity<AgentActivityAttributes>.activities.map { item in
                    ["taskID": item.attributes.taskID.uuidString, "phase": item.content.state.phase ?? "",
                     "status": item.content.state.status, "activityState": String(describing: item.activityState),
                     "taskTitle": item.content.state.taskTitle ?? "", "canPause": item.content.state.canPause == true,
                     "canStop": item.content.state.canStop == true, "completed": item.content.state.completed == true] as [String: Any]
                },
                "live_activity_title": Activity<AgentActivityAttributes>.activities.first?.content.state.taskTitle ?? "",
                "live_activity_error": model.taskActivity.error,
                "notification_enabled": model.taskNotifications.enabled,
                "notification_authorization": model.taskNotifications.authorization,
                "notification_error": model.taskNotifications.error,
                "notification_checks": notificationChecks,
                "travel_checks": travelChecks, "meituan_connected": MeituanConnectionStore.verified,
                "paotui_configured": MeituanPaotuiStore.shared.configured,
                "paotui_ready": MeituanPaotuiStore.shared.ready,
                "paotui_address_count": MeituanPaotuiStore.shared.addresses.count,
                "paotui_quotes": MeituanPaotuiStore.shared.quotes.map { ["service": $0.serviceTitle, "fee": $0.fee, "distance": $0.distance, "estimate": $0.estimate] as [String: Any] },
                "paotui_order_created": MeituanPaotuiStore.shared.lastOrderID != nil,
                "paotui_unresolved_order": MeituanPaotuiStore.shared.hasUnresolvedSubmission,
                "ctrip_enabled": CtripStore.enabled, "ctrip_credential": CtripStore.hasCredential,
                "date": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtection])
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
    }
}
#endif
