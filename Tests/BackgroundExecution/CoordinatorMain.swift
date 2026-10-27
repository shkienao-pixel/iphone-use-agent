import Foundation
import UIKit
import BackgroundTasks

@main struct ExecutionMaintenanceChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
        func settle() async { for _ in 0..<3 { try? await Task.sleep(nanoseconds: 1_000_000); await Task.yield() } }
        let app = UIApplication.shared, scheduler = BGTaskScheduler.shared
        app.reset(); scheduler.reset()
        let maintenance = BackgroundExecutionController()
        var workers: [AgentEngine] = []
        let pool = BackgroundTaskCoordinator(maximumConcurrent: 1) { _ in
            let worker = AgentEngine(); workers.append(worker); return worker
        }
        pool.onExecutionChange = {
            maintenance.synchronize(pool.executionRecords.compactMap { record in
                guard let session = pool.executionSession(record.id) else { return nil }
                return .init(id: record.id, sessionID: session, completedUnits: Int64(record.checkpointStep ?? 0))
            })
        }
        maintenance.onExpiration = { expired in
            pool.expireExecutions(Dictionary(uniqueKeysWithValues: expired.map { ($0.id, $0.sessionID) }))
        }
        func submit(_ goal: String) throws -> UUID {
            try pool.submit(goal: goal, settings: AgentSettings(), attachments: [], reference: "",
                            origin: .init(conversationID: UUID(), messageID: UUID()))
        }
        let stopped = try submit("Stop a pending SDK call"); await settle()
        let stopSession = pool.executionSession(stopped)!, stopControl = pool.token(stopped)!
        let stopGrant = BGContinuedProcessingTask(); scheduler.handlers[scheduler.submitted[0].identifier]!(stopGrant)
        app.applicationState = .background; workers[0].holdCancellation = true
        try pool.stop(stopped); await settle()
        expect(pool.token(stopped) == nil, "Stop revokes all task-control authority immediately")
        expect(pool.executionSession(stopped) == stopSession && pool.hasUnsettledExecution,
               "A stopped but unsettled SDK worker retains its maintenance identity")
        expect(maintenance.diagnosticSnapshot.isContinuationActive && stopGrant.completions.isEmpty,
               "Stop does not end process execution time before its worker settles")
        var staleRejected = false
        do { try pool.pause(stopped, expected: stopControl) } catch { staleRejected = true }
        expect(staleRejected, "Maintenance retention never reauthorizes a revoked control token")
        workers[0].releasing = false; await settle()
        expect(pool.executionSession(stopped) == nil && !pool.hasUnsettledExecution,
               "Maintenance identity disappears after actual cleanup settles")
        expect(stopGrant.completions == [true] && !maintenance.diagnosticSnapshot.isContinuationActive,
               "The system grant ends exactly once at the settled execution boundary")

        app.applicationState = .active
        let completed = try submit("Complete with bookkeeping pending"); await settle()
        let completionSession = pool.executionSession(completed)!
        let completionGrant = BGContinuedProcessingTask(); scheduler.handlers[scheduler.submitted.last!.identifier]!(completionGrant)
        app.applicationState = .background
        workers[1].releasing = true; workers[1].complete(); await settle()
        expect(pool.token(completed) == nil && pool.executionSession(completed) == completionSession,
               "Completed control authority is revoked while independent bookkeeping maintenance remains")
        expect(completionGrant.completions.isEmpty && maintenance.diagnosticSnapshot.isContinuationActive,
               "A completion record cannot prematurely release an unsettled worker's grant")
        workers[1].releasing = false; await settle()
        expect(completionGrant.completions == [true], "Completed worker releases its grant after bookkeeping settles")

        app.applicationState = .active
        let expiring = try submit("An active expiring cohort"), queued = try submit("Queued sibling must not start"); await settle()
        let expiredSession = pool.executionSession(expiring)!, queuedSession = pool.executionSession(queued)!
        let expiredControl = pool.token(expiring)!
        let expirationGrant = BGContinuedProcessingTask(); scheduler.handlers[scheduler.submitted.last!.identifier]!(expirationGrant)
        app.applicationState = .background; workers[2].holdCancellation = true
        expirationGrant.expirationHandler!(); await settle()
        expect(workers.count == 3 && !pool.running(expiring) && !pool.running(queued),
               "Expiring an aggregate cohort revokes every queued sibling before releasing an execution slot")
        expect(pool.token(expiring) != expiredControl && pool.executionSession(expiring) == expiredSession,
               "Expiration revokes controls without losing the cancelled worker's cleanup identity")
        expect(pool.executionSession(queued) == nil && pool.record(queued)?.outcome == .paused,
               "A never-dispatched queued workload needs no maintenance after its pause checkpoint")
        expect(expirationGrant.completions == [false], "Expired lease reports failure only after synchronous cohort cancellation")
        workers[2].releasing = false; await settle()
        app.applicationState = .active
        try pool.resume(expiring); await settle()
        expect(pool.executionSession(expiring) != expiredSession && pool.token(expiring) == pool.executionSession(expiring),
               "Explicit resume creates a fresh maintenance and control generation")
        pool.expireExecutions([expiring: expiredSession, queued: queuedSession]); await settle()
        expect(pool.running(expiring) && workers[2].resumes == 1,
               "A late old maintenance expiration cannot pause an explicitly resumed generation")
        try pool.stop(expiring); workers[2].releasing = false; await settle()
        expect(!pool.hasUnsettledExecution && app.assertions.isEmpty,
               "Final cleanup balances all execution assertions without starting another worker")
        print("PASS: \(checks) real coordinator/background-grant maintenance and control isolation checks")
    }
}
