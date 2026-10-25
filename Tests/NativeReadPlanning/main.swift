import Foundation

@main struct NativeReadPlanningChecks {
    struct Fixture: Decodable { let record: Record }
    struct Record: Decodable { let goal: String; let logs: [AgentLogEntry] }
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !value() { fatalError("FAIL: " + message) }
        }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/alarm-read-loop.json")
        let original = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(Fixture.self, from: original)
        let receipts = fixture.record.logs.filter { $0.title == "工具回执" }
        expect(receipts.count == 10 && receipts.last?.step == 10, "The real stopped task has exactly ten completed SDK receipts, not eleven")
        let raw = receipts[0].detail, goal = fixture.record.goal
        expect(receipts.allSatisfy { $0.detail == raw }, "All ten original completed reads returned the same actual SDK data")
        let request = SystemToolRequest(operation: .alarm_list)
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let summary = NativeReadProgress.alarmSummary(raw, timeZone: shanghai)
        expect(summary.contains("870AC655-5D25-48DA-974C-C4E4FA94AB5C") && summary.contains("状态scheduled（已安排）"), "The host-readable result is grounded in the actual SDK ID and scheduled enum")
        expect(summary.contains("814669800") && summary.contains("2001-01-01 UTC") && summary.contains("2026-10-26T01:10:00Z") && summary.contains("2026-10-26 09:10:00 +08:00"), "The SDK numeric reference-date value is decoded explicitly into the correct instant and requested local time")
        expect(!summary.contains("已响铃") && !summary.contains("标题："), "A scheduled read neither proves sound nor invents an absent title")
        var progress = NativeReadProgress()
        switch progress.beforeDispatch(request, goal: goal) { case .execute: expect(true, "first read"); default: expect(false, "A new run must execute its first actual read") }
        progress.succeeded(request, result: raw, goal: goal, step: 10, at: receipts.last!.date)
        let context = progress.context(for: goal, timeZone: shanghai)
        expect(context.contains("实际成功返回") && context.contains("第10步") && context.contains("不随每轮规划"), "Current-run evidence distinguishes one fresh read from repeating a new read on every model turn")
        switch progress.beforeDispatch(request, goal: goal) { case .correctWithReceipt: expect(true, "same read correction"); default: expect(false, "An adjacent identical read is corrected before SDK dispatch") }
        expect(progress.context(for: goal).contains("没有再次调用SDK"), "The correction never represents a blocked duplicate as a new SDK result")
        switch progress.beforeDispatch(request, goal: goal) { case .pauseRepeatedPlan: expect(true, "same read local pause"); default: expect(false, "Persistent identical-read planning pauses locally rather than auto-finishing the task") }
        progress.reset()
        switch progress.beforeDispatch(request, goal: goal) { case .execute: expect(true, "reset permits read"); default: expect(false, "A wait or intervening condition boundary allows a genuine new read") }
        progress.succeeded(request, result: raw, goal: goal, step: 1)
        switch progress.beforeDispatch(request, goal: goal + "核对另一个目标") { case .execute: expect(true, "changed goal permits read"); default: expect(false, "Changed actual task criteria do not reuse an earlier read") }
        let empty = NativeReadProgress.alarmSummary("[]\n本 App 闹钟总数：30，返回前 20 项", timeZone: shanghai)
        expect(empty.contains("不把前20项当全部") && empty.contains("不推断目标已删除"), "Empty or truncated lists retain coverage uncertainty")
        let malformed = NativeReadProgress.alarmSummary("权限不足，未执行查询", timeZone: shanghai)
        expect(malformed.contains("不能猜测日期、数量或状态"), "An unreadable receipt cannot fabricate a decoded success result")
        let notScheduled = NativeReadProgress.alarmSummary(raw.replacingOccurrences(of: "scheduled", with: "alerting"), timeZone: shanghai)
        expect(!notScheduled.contains("状态scheduled（已安排）"), "An SDK alerting state is not relabeled scheduled")
        let booleanDate = NativeReadProgress.alarmSummary(raw.replacingOccurrences(of: "814669800", with: "true"), timeZone: shanghai)
        expect(booleanDate.contains("fixed计划日期待核实"), "A malformed boolean numeric field is never converted into a date")

        var settings = AgentSettings(); settings.endpoint = "https://native-read.invalid/v1/chat/completions"
        settings.modelAuthentication = nil; settings.toolsOnly = true; settings.systemToolsEnabled = true
        settings.continuousExecution = true; settings.startDelay = 0; settings.useMemories = false
        PrivacyConsent.grant(settings); defer { PrivacyConsent.revoke() }
        let client = VisionClient(settings: settings, apiKey: "offline-unused-not-a-secret")
        func action(_ kind: String, text: String? = nil, seconds: Double? = nil) throws -> String {
            let object: [String: Any] = ["kind": kind, "text": text.map { $0 as Any } ?? NSNull(), "reason": "Offline scripted response only",
                "x": NSNull(), "y": NSNull(), "x2": NSNull(), "y2": NSNull(), "amount": NSNull(), "seconds": seconds.map { $0 as Any } ?? NSNull()]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let readAction = try action("system_tool", text: String(decoding: JSONEncoder().encode(request), as: UTF8.self))
        let report = "本次只读回执确认ID 870AC655-5D25-48DA-974C-C4E4FA94AB5C为scheduled，2026-10-26 09:10 Asia/Shanghai。只证明已安排，不证明响铃；未创建、修改或取消闹钟。"
        let finishAction = try action("finish", text: report)
        RoutingWireProbe.reset(); RoutingWireProbe.content = finishAction
        var actualProgress = NativeReadProgress(); actualProgress.succeeded(request, result: raw, goal: goal, step: 10, at: receipts.last!.date)
        _ = try await client.nextAction(task: goal, jpeg: Data(), width: 0, height: 0, history: fixture.record.logs.filter { $0.step <= 10 }, keyboardAvailable: false, mappedHomeAvailable: false,
            nativeExecutionContext: actualProgress.context(for: goal, timeZone: shanghai))
        let capturedBody = try JSONSerialization.jsonObject(with: RoutingWireProbe.requests.last!.httpBody!) as! [String: Any]
        let messages = capturedBody["messages"] as! [[String: Any]], system = messages[0]["content"] as! String
        let parts = messages[1]["content"] as! [[String: Any]], prompt = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        expect(messages.count == 2 && prompt.components(separatedBy: raw).count == 11, "The actual production request body retains all ten real receipts even though it has only two message envelopes")
        expect(system.contains("Native tools-only execution") && system.contains("successful SDK receipt is sufficient evidence"), "The native-only completion contract explicitly accepts genuine SDK receipts")
        expect(!system.contains("Offline phone skill boundary") && !system.contains("Offline support boundary") && !system.contains("Coordinates x,y,x2,y2") && !system.contains("BLE HID mouse"), "GUI and Apple UI guides are absent from the actual native-only system request")
        expect(prompt.contains("2026-10-26 09:10:00 +08:00") && prompt.contains("没有截图") && !prompt.contains("根据当前画面决定下一步"), "The native instruction uses current-run decoded tool evidence, not an impossible screenshot completion gate")
        let converted = try ChatGPTPlanResponses.body(from: capturedBody)
        let convertedData = try JSONSerialization.data(withJSONObject: converted)
        let convertedText = String(decoding: convertedData, as: UTF8.self)
        expect(convertedText.contains("814669800") && convertedText.contains("2026-10-26") && convertedText.contains("Native tools-only execution"), "The production ChatGPT Responses conversion preserves the corrected native evidence and guide")

        var runReports: [[String: Any]] = []
        func run(_ name: String, script: [String], expectedSDK: Int, expectedPhase: ProductionToolsLoop.Phase) async throws {
            RoutingWireProbe.reset(); RoutingWireProbe.scripts = script
            let engine = ProductionToolsLoop(); var calls: [String] = []
            engine.systemTool = { _, tool in calls.append(tool.operation.rawValue); return tool.operation == .alarm_list ? raw : "Offline synthetic write boundary; no SDK executed" }
            await engine.start(goal: goal, settings: settings, client: client)
            expect(calls.filter { $0 == "alarm_list" }.count == expectedSDK && engine.phase == expectedPhase, name + ": exact production loop honors SDK-read count and resulting phase")
            expect(engine.logs.filter { $0.title == "工具回执" }.count == calls.count, name + ": blocked plans never create fictitious SDK receipt log entries")
            runReports.append(["name": name, "substitutedSDKReadCount": calls.filter { $0 == "alarm_list" }.count, "phase": engine.phase.rawValue, "planningRequests": RoutingWireProbe.requests.count])
        }
        try await run("successful read then model finishes", script: [readAction, finishAction], expectedSDK: 1, expectedPhase: .completed)
        try await run("duplicate corrected then model finishes", script: [readAction, readAction, finishAction], expectedSDK: 1, expectedPhase: .completed)
        try await run("persistent duplicate pauses locally", script: [readAction, readAction, readAction], expectedSDK: 1, expectedPhase: .needsUser)
        let wait = try action("wait", seconds: 0.4)
        try await run("intervening wait invalidates adjacency", script: [readAction, wait, readAction, finishAction], expectedSDK: 2, expectedPhase: .completed)
        let write = SystemToolRequest(operation: .alarm_create, title: "Offline synthetic only", start: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))
        let writeAction = try action("system_tool", text: String(decoding: JSONEncoder().encode(write), as: UTF8.self))
        try await run("intervening synthetic write invalidates adjacency", script: [readAction, writeAction, readAction, finishAction], expectedSDK: 2, expectedPhase: .completed)
        try await run("subtask boundary invalidates adjacency", script: [readAction, try action("complete_subtask", text: UUID().uuidString), readAction, finishAction], expectedSDK: 2, expectedPhase: .completed)
        try await run("new task always gets actual first read", script: [readAction, finishAction], expectedSDK: 1, expectedPhase: .completed)
        expect(settings.runsContinuously && settings.allowsNextStep(after: 20_000), "No new task-wide step limit or cutoff was introduced")
        let unchanged = try Data(contentsOf: fixtureURL)
        expect(unchanged == original, "The actual stopped-task receipt fixture remains unchanged")
        let output: [String: Any] = ["checks": checks, "scope": "Offline exact production nextAction HTTP-body capture and native runTools/executeTool extraction; HTTP and SDK boundaries substituted, no network, model or device calls", "actualCompletedReceiptCount": receipts.count, "capturedMessageEnvelopes": messages.count, "runs": runReports]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: \(checks) native read planning checks; actual HTTP body and production native loop, no device/network")
    }
}
