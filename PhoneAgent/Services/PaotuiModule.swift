import Foundation
import Combine

/// One process boundary for chat preparation. Correlation belongs to the host;
/// business authority remains inside the live store-owned Session.
@MainActor final class PaotuiModule: ObservableObject {
    enum Input {
        case text(question: String, history: [AssistantMessage])
        case card(PaotuiChatCard, PaotuiChatSelection)
    }
    private let store: MeituanPaotuiStore
    private let conversation: MeituanPaotuiConversation
    private var observation: AnyCancellable?
    private var requests: [UUID: UUID] = [:]
    private var toolRequests: [UUID: UUID] = [:]
    var diagnosticsSnapshot: PaotuiDiagnosticsSnapshot { store.diagnosticsSnapshot }

    init(store: MeituanPaotuiStore, conversation: MeituanPaotuiConversation) {
        self.store = store; self.conversation = conversation
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func summary(for conversationID: UUID) -> PaotuiSessionSummary? {
        guard let session = store.existingSession(for: conversationID),
              (try? store.validateSession(session)) != nil else { return nil }
        return PaotuiSessionSummary(session: session, locations: store.locations(for: session.ticket),
            unresolved: store.hasUnresolvedSubmission, canCreateOrder: { store.canSubmit($0, for: session.ticket) })
    }
    var savedPreparations: [PaotuiSavedPreparationSummary] { store.savedPreparations }
    var preparationRecoveryIssue: String? { store.preparationRecoveryIssue }
    func restorePreparation(for conversationID: UUID) throws { _ = try store.restorePreparation(for: conversationID) }
    func discardSavedPreparation(for conversationID: UUID) throws { try store.discardSavedPreparation(for: conversationID) }

    func presentation(for card: PaotuiChatCard, conversationID: UUID) -> PaotuiCardPresentation {
        conversation.presentation(for: card, conversationID: conversationID)
    }

    func handle(_ input: Input, context: PaotuiHostContext,
                routingInput: ConversationRoutingInput? = nil,
                interpret: ((ConversationRoutingInput, String) async throws -> String)? = nil) async throws -> PaotuiChatReply {
        try Task.checkCancellation()
        let command: PaotuiDiagnosticCommand
        switch input { case .text: command = .hostText; case .card: command = .hostCard }
        let diagnosticSpan = store.diagnostics.start(command: command, phase: .host, context: .init(conversationID: context.conversationID))
        var diagnosticResult: PaotuiDiagnosticResult = .failed
        defer { if let diagnosticSpan { store.diagnostics.finish(diagnosticSpan, result: diagnosticResult) } }
        if case .text(let question, _) = input, let routingInput {
            guard routingInput.conversationID == nil || routingInput.conversationID == context.conversationID,
                  routingInput.question == question.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw PaotuiSession.SessionError.stale
            }
        }
        try store.retainHostRequest(for: context.conversationID, requestID: context.requestID)
        defer { store.releaseHostRequest(for: context.conversationID, requestID: context.requestID) }
        requests[context.conversationID] = context.requestID
        defer {
            if requests[context.conversationID] == context.requestID { requests.removeValue(forKey: context.conversationID) }
        }
        let reply: PaotuiChatReply
        switch input {
        case .text(let question, let history):
            reply = try await conversation.respond(question: question, history: routingInput?.history ?? history,
                conversationID: context.conversationID, routingInput: routingInput, hostContext: context, interpret: interpret)
        case .card(let card, let selection):
            guard presentation(for: card, conversationID: context.conversationID).allows(selection.action) else {
                throw AgentError.message("这张卡片的操作已失效，请在当前对话继续或重新询价")
            }
            reply = try await conversation.select(card, selection, conversationID: context.conversationID)
        }
        try Task.checkCancellation()
        guard requests[context.conversationID] == context.requestID else { throw CancellationError() }
        diagnosticResult = .succeeded
        return reply
    }

    func lifecycle(_ event: PaotuiLifecycleEvent) {
        switch event {
        case .cleared(let conversationID):
            requests.removeValue(forKey: conversationID)
            conversation.clearPreparation(conversationID: conversationID)
        }
    }
    func clearPreparation(conversationID: UUID) { lifecycle(.cleared(conversationID)) }

    func query(_ query: String, context: PaotuiToolContext) async throws -> String {
        try Task.checkCancellation()
        let span = store.diagnostics.start(command: .toolQuery, phase: .host, context: .init(taskID: context.taskID, invocationID: context.invocationID))
        var resultClassification: PaotuiDiagnosticResult = .failed
        defer { if let span { store.diagnostics.finish(span, result: resultClassification) } }
        _ = try PaotuiToolQuery.decode(query)
        toolRequests[context.taskID] = context.invocationID
        defer {
            if toolRequests[context.taskID] == context.invocationID { toolRequests.removeValue(forKey: context.taskID) }
        }
        let result = try await store.tool(query, taskID: context.taskID)
        try Task.checkCancellation()
        guard toolRequests[context.taskID] == context.invocationID else { throw CancellationError() }
        resultClassification = .succeeded
        return result
    }
}
