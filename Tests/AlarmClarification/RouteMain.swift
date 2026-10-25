import Foundation

@main enum AlarmClarificationRouteChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures: [String] = []
        func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures.append(label); print("FAIL: " + label) } }
        let original = "帮我在时钟里设一个闹钟，先问我几点响、是否重复，以及闹钟名称。"
        let history = [AssistantMessage(role: "user", text: original), AssistantMessage(role: "assistant", text: "几点响？是否重复？闹钟名称叫什么？")]
        for connected in [false, true] {
            var settings = AgentSettings(); settings.toolsOnly = false
            settings.endpoint = connected ? "https://api.openai.com/v1/chat/completions" : "https://routing.invalid/v1/chat/completions"
            settings.maxResponseTokens = 6144; settings.jsonMode = true
            PrivacyConsent.grant(settings)
            let router = UnifiedConversationRouter(settings: settings, apiKey: "offline-unused")
            RoutingWireProbe.reset()
            let initialRequests = RoutingWireProbe.requests.count
            let answer = "每天9:20的 就叫work"
            let complete = try await router.route(question: answer, history: history, taskContext: "{}")
            check(complete.mode == .task && complete.request.contains(original) && complete.request.contains(answer), "Complete answer becomes one bound task")
            check(RoutingWireProbe.requests.count == initialRequests, "Complete typed clarification never falls back to an actionless chat reply")
            check(!complete.request.contains(history.last!.text), "Host never executes assistant clarification wording")
            let partial = try await router.route(question: "每天9:20", history: history, taskContext: "{}")
            check(partial.mode == .clarify && partial.message.contains("名称") && !partial.message.contains("时间；"), "Only a missing title is clarified, with no execution claim")
            let ambiguous = try await router.route(question: "每天9点或者10点，就叫work", history: history, taskContext: "{}")
            check(ambiguous.mode == .clarify, "Two times cannot auto-submit a task")
            let cancelled = try await router.route(question: "每天9:20，就叫work，取消吧", history: history, taskContext: "{}")
            check(cancelled.mode == .clarify && cancelled.request.isEmpty && cancelled.message.contains("取消"), "Trailing cancellation never dispatches")
            check(RoutingWireProbe.requests.count == initialRequests, "Clarification and cancellation stay local")
            var nativeOnly = settings; nativeOnly.toolsOnly = true
            let unsupported = try await UnifiedConversationRouter(settings: nativeOnly, apiKey: "offline-unused").route(question: answer, history: history, taskContext: "{}")
            check(unsupported.mode == .clarify && unsupported.message.contains("不能修改") && unsupported.message.contains("尚未"), "Native-only capability cannot pretend to set Clock recurring alarms")
            PrivacyConsent.revoke()
            do { _ = try await router.route(question: answer, history: history, taskContext: "{}"); check(false, "Revoked consent blocks dispatch intent") }
            catch { check(true, "Revoked consent blocks dispatch intent") }
            PrivacyConsent.grant(settings)
            RoutingWireProbe.reset()
            let beforeOrdinary = RoutingWireProbe.requests.count
            let ordinary = try await router.route(question: "你好", history: [], taskContext: "{}")
            check(ordinary.mode == .chat && RoutingWireProbe.requests.count == beforeOrdinary + 1, "Ordinary input still uses semantic routing once")
        }
        PrivacyConsent.revoke()
        let report: [String: Any] = ["checks": checks, "failures": failures,
            "scope": "Actual pinned UnifiedConversationRouter and production clients, HTTP replaced by existing offline wire harness; no model or device request."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        if !failures.isEmpty { exit(1) }
    }
}
