import Foundation
import Combine

private enum OfflineStage { case systemTool }
private final class OfflineMetrics {
    @MainActor func measureAsync<T>(_ stage: OfflineStage, label: String, operation: () async throws -> T) async rethrows -> T { try await operation() }
}
@MainActor final class ProductionToolsLoop {
    enum Phase: String { case idle, observing, acting, awaitingApproval, completed, needsUser, preview, paused, failed }
    enum Indicator { case idle, completed, failed }
    struct Record { var id = UUID(); var goal = ""; var effectiveGoal: String { goal }; var attachments: [ComposerAttachment] = []; var conversationReference: String?; var nativeResults: [NativeTaskResult]?; var completionEvidence: TaskCompletionEvidence? }
    var running = false, currentStep = 0
    var state = "", error = "", ledgerProgress = 0
    var phase = Phase.idle, taskIndicator = Indicator.idle
    @Published var currentRecord: Record? = Record()
    var pendingAction: AgentAction?, executingAction: AgentAction?
    var savedSettings: AgentSettings?
    var savedGoal = ""
    var completedToolReceipts: ((UUID) -> [String])?
    var persistenceBlocked = false
    var logs: [AgentLogEntry] = []
    var memoryContext: ((String, AgentSettings) async -> String)?
    var systemTool: ((UUID, SystemToolRequest) async throws -> String)?
    private var runMetrics: OfflineMetrics?
    private var session = UUID()
    private var loop: Task<Void, Never>?
    private var attemptSteps: Int { currentStep }
    private var taskContext: String { "" }
    func start(goal: String, settings: AgentSettings, client: VisionClient) async { running = true; savedGoal = goal; currentRecord?.goal = goal; currentRecord?.completionEvidence = TaskCompletionEvidence(goal: goal); await runTools(goal: goal, settings: settings, client: client, token: session) }
    private func planningGoal(_ goal: String) -> String { goal + (ledgerProgress == 0 ? "" : "\n已确认子任务：\(ledgerProgress)") }
    private func stillCurrent(_ token: UUID) throws { if token != session { throw CancellationError() } }
    @discardableResult private func transition(_ phase: Phase, _ state: String) -> Bool { self.phase = phase; self.state = state; return true }
    private func log(_ title: String, _ detail: String) { logs.append(AgentLogEntry(step: currentStep, title: title, detail: detail)) }
    private func finishAllowed() throws {}
    // This native read-only fixture has no screen checkpoint pilot. The real
    // finish method still calls its lifecycle boundary before completion policy.
    private func diagnoseCheckpoint() {}
    private func completeSubtask(_ action: AgentAction, token: UUID, requiresConfirmation: Bool) async throws { try stillCurrent(token); ledgerProgress += 1 }
    private func measuredWait(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
    private func finishRunMetrics(_ metrics: OfflineMetrics?) {}
    private func publishRecord() {}
    private func pauseAtStepLimit(_ settings: AgentSettings) { running = false; phase = .paused; state = "Existing user-configured budget" }
