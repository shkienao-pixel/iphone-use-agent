#if DEBUG
import Foundation

/// Opt-in synthetic evaluation. Calls the configured classifier only; never
/// installs handlers, creates tasks, accesses personal memory or invokes tools.
@MainActor enum IntentEvaluationRunner {
    private struct Corpus: Decodable { let schemaVersion: Int; let cases: [Case] }
    private struct Case: Decodable {
        struct Turn: Decodable { let role: String; let text: String; var missingInformation: [String]? }
        let id: String
        let question: String
        let expectedModes: [String]
        let history: [Turn]
        let expired: Bool
        let includeMemory: Bool
        var expectedRelation: String?
        var requireRootReference: Bool?
    }
    private static var running = false

    static func run(model: PhoneAgentViewModel, destination: URL) async throws {
        guard !running else { throw AgentError.message("意图评测已在运行") }
        guard model.consentReady, let url = Bundle.main.url(forResource: "evaluation-cases", withExtension: "json", subdirectory: "Skills/sela-intent/references") else {
            throw AgentError.message("意图评测需要已有模型授权与完整的合成测试资料")
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        guard corpus.schemaVersion == 1, corpus.cases.count <= 50 else { throw AgentError.message("意图评测资料格式无效") }
        running = true; defer { running = false }
        let settings = model.settings, key = SettingsStore.apiKey(for: settings.endpoint)
        let connection = SelaMemoryService.recipient(settings)
        var results: [[String: Any]] = []
        var correct = 0, falseActions = 0, unnecessaryClarifications = 0, decisions = 0, consecutiveErrors = 0
        var modelRejections = 0, groundingFailures = 0
        var proposedCount = 0, proposedCorrect = 0, proposedFalseActions = 0, hostOverrides = 0
        var stoppedReason: String?
        func action(_ mode: ConversationRoute.Mode) -> Bool {
            [.task, .supplement, .resume, .pause, .stop, .flightQuery, .paotuiQuery].contains(mode)
        }
        func recordProposal(_ proposed: ConversationRoute.Mode, for item: Case, result: inout [String: Any]) {
            proposedCount += 1
            if item.expectedModes.contains(proposed.rawValue) { proposedCorrect += 1 }
            if action(proposed), item.expectedModes.allSatisfy({ ["chat", "clarify"].contains($0) }) { proposedFalseActions += 1 }
            result["proposedMode"] = proposed.rawValue
        }
        func save(complete: Bool) throws {
            let evaluated = decisions + modelRejections
            let report: [String: Any] = ["schemaVersion": 1, "complete": complete,
                "model": settings.model, "caseCount": corpus.cases.count, "completedCount": results.count,
                "correctCount": correct, "validDecisionCount": decisions, "errorCount": results.count - decisions,
                "evaluatedDecisionCount": evaluated, "transportErrorCount": results.count - evaluated,
                "falseActionCount": falseActions, "hostOverrideCount": hostOverrides,
                "modelRejectionCount": modelRejections, "groundingFailureCount": groundingFailures,
                "unnecessaryClarificationCount": unnecessaryClarifications,
                "accuracy": evaluated == 0 ? NSNull() as Any : Double(correct) / Double(evaluated),
                "pipelineSuccessRate": results.isEmpty ? NSNull() as Any : Double(correct) / Double(results.count),
                "decisionCoverage": results.isEmpty ? NSNull() as Any : Double(decisions) / Double(results.count),
                "proposedModelModeAccuracy": proposedCount == 0 ? NSNull() as Any : Double(proposedCorrect) / Double(proposedCount),
                "proposedFalseActionCount": proposedFalseActions,
                "stoppedReason": stoppedReason as Any? ?? NSNull(),
                "scope": "Live classifier with synthetic inputs only; no personal memory, phone actions, account tools or execution handlers.",
                "results": results]
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: destination, options: [.atomic, .completeFileProtection])
        }
        for item in corpus.cases {
            try Task.checkCancellation()
            guard model.consentReady, SelaMemoryService.recipient(model.settings) == connection,
                  model.settings.model == settings.model, SettingsStore.apiKey(for: settings.endpoint) == key else {
                stoppedReason = "模型授权或连接已改变"; try save(complete: false)
                throw AgentError.message("模型授权或连接已改变，意图评测已停止")
            }
            let now = Date(), origin = now.addingTimeInterval(item.expired ? -259_200 : -60)
            var history: [AssistantMessage] = []
            for turn in item.history {
                var message = AssistantMessage(role: turn.role, text: turn.text)
                message.createdAt = origin
                if let missing = turn.missingInformation, let user = history.last(where: { $0.role == "user" }) {
                    let route = ConversationRoute(mode: .clarify, request: "", message: turn.text, missingInformation: missing, relation: .independent)
                    message.intent = ConversationWorkingMemory.record(route: route, user: user, replyID: message.id, history: history, now: origin)
                }
                history.append(message)
            }
            let memory = item.includeMemory ? "{\"manualMemories\":[{\"id\":\"ACACACAC-0000-4000-8000-000000000001\",\"content\":\"项目会议放工作日历\"}]}" : ""
            let input = try ConversationRoutingInput(question: item.question, history: history, taskContext: "{}", memoryContext: memory, now: now)
            let started = ProcessInfo.processInfo.systemUptime
            var result: [String: Any] = ["id": item.id, "expectedModes": item.expectedModes]
            do {
                let route = try await UnifiedConversationRouter(settings: settings, apiKey: key).route(input: input)
                decisions += 1; consecutiveErrors = 0
                let relationMatched = item.expectedRelation == nil || route.relation?.rawValue == item.expectedRelation
                let rootMatched = item.requireRootReference != true || history.first(where: { $0.role == "user" }).map { route.relatedMessageIDs?.contains($0.id) == true } == true
                let matched = item.expectedModes.contains(route.mode.rawValue) && relationMatched && rootMatched
                if !rootMatched { groundingFailures += 1 }
                if matched { correct += 1 }
                if !matched, action(route.mode), item.expectedModes.allSatisfy({ ["chat", "clarify"].contains($0) }) { falseActions += 1 }
                if route.mode == .clarify, !item.expectedModes.contains("clarify") { unnecessaryClarifications += 1 }
                result["actualMode"] = route.mode.rawValue; result["matched"] = matched
                result["relationMatched"] = relationMatched; result["rootReferenceMatched"] = rootMatched
                result["decisionSource"] = route.decisionSource ?? "local"
                result["groundedSourceCount"] = route.relatedMessageIDs?.count ?? 0
                if let proposed = route.proposedMode {
                    recordProposal(proposed, for: item, result: &result)
                    if proposed != route.mode { hostOverrides += 1 }
                }
            } catch {
                if let rejected = error as? ConversationRoutingRejection {
                    modelRejections += 1; consecutiveErrors = 0
                    result["rejection"] = rejected.reason.rawValue
                    if let proposed = rejected.proposedMode { recordProposal(proposed, for: item, result: &result) }
                } else { consecutiveErrors += 1 }
                result["matched"] = false; result["error"] = error.localizedDescription
            }
            result["milliseconds"] = Int(max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000))
            results.append(result); try save(complete: false)
            if consecutiveErrors >= 3 {
                stoppedReason = "连续三次无法完成分类，已停止本轮评测"; try save(complete: false); return
            }
        }
        try save(complete: true)
    }
}
#endif
