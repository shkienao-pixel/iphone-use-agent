import Foundation
import UIKit

@MainActor extension PhoneAgentViewModel {
    func makeBackgroundEngine(settings: AgentSettings) -> AgentEngine {
        let worker = AgentEngine(capture: capture, executor: executor, ownsScreenInput: false)
        worker.memoryContext = { [weak self] query, config in
            await self?.memories.context(for: query, settings: config) ?? ""
        }
        worker.systemToolEvidence = { [weak self] id in self?.tools.taskContentEvidence(taskID: id) ?? "" }
        worker.systemTool = { [weak self, weak worker] id, request in
            guard let self else { throw CancellationError() }
            do {
                try BackgroundToolPolicy.validate(request)
                return try await self.executeTaskTool(request, taskID: id, settings: worker?.currentSettings ?? settings, background: true)
            } catch {
                if !Task.isCancelled {
                    // Keep the same task/receipts for explicit continuation.
                    worker?.handoff(reason: error.localizedDescription)
                }
                throw error
            }
        }
        return worker
    }
    func executeTaskTool(_ request: SystemToolRequest, taskID: UUID, settings config: AgentSettings, background: Bool) async throws -> String {
        let resources = TaskResourceGate.resources(for: request.operation, confirmation: config.confirmEachStep)
        return try await taskResources.withResources(resources) {
            guard self.history.error.isEmpty, self.consentReady, PrivacyConsent.allowed(config), config.endpoint == self.settings.endpoint,
                  config.model == self.settings.model, config.useMemories == self.settings.useMemories,
                  PrivacyConsent.recipient(config) == PrivacyConsent.recipient(self.settings),
                  self.settings.systemToolsEnabled == true else { throw AgentError.message("模型、系统工具或数据授权已改变，请核对后继续任务") }
            if background { try BackgroundToolPolicy.validate(request) }
            return try await self.tools.execute(request, taskID: taskID, requiresConfirmation: config.confirmEachStep,
                                                allowsPermissionPrompt: !background)
        }
    }
    @discardableResult func recoverBackgroundTask(_ record: PhoneTaskRecord, mode: TaskRecoveryMode) -> Bool {
        guard UIApplication.shared.applicationState == .active, modelReady, consentReady, settings.systemToolsEnabled == true else {
            notice = "请回到 Sela 并核对模型、原生工具与数据授权后，再恢复这项后台任务"; return false
        }
        guard history.error.isEmpty, !tools.hasUnresolvedWrite(taskID: record.id) else {
            notice = "这项后台任务有未核验的写入或存储问题，请先核对实际结果"; return false
        }
        do { let accepted = try backgroundTasks.recover(record, settings: settings, mode: mode); notice = ""; return accepted }
        catch { notice = error.localizedDescription; return false }
    }
    func taskRecoveryBusy(_ id: UUID) -> Bool {
        if backgroundTasks.contains(id) || history.records.first(where: { $0.id == id })?.executionLane == "native" {
            return backgroundTasks.busy(id) || backgroundTasks.running(id)
        }
        return taskRecoveryBusy
    }
    func pauseTask(_ id: UUID) {
        if backgroundTasks.contains(id) {
            do { try backgroundTasks.pause(id); notice = "" } catch { notice = error.localizedDescription }
        } else if engine.currentRecord?.id == id { _ = pauseTask() }
    }
    func stopTask(_ id: UUID) {
        if backgroundTasks.contains(id) {
            do { try backgroundTasks.stop(id); notice = "" } catch { notice = error.localizedDescription }
        } else if engine.currentRecord?.id == id { stop() }
    }
}
