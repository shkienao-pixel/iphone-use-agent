import Foundation
import Combine

@MainActor final class CoordinatorHarness {
    let store: TaskHistoryStore
    var pool: BackgroundTaskCoordinator!
    var workers: [AgentEngine] = []
    var poolWrites = 0, workerWrites = 0, callbacks = 0
    var rejected = Set<UUID>()
    var projections: [[PhoneTaskRecord]] = []
    var origins: [UUID: UUID] = [:]
    private var observation: AnyCancellable?
    init(url: URL, maximum: Int = 3, workerHook: Bool = false) {
        store = TaskHistoryStore(url: url)
        pool = BackgroundTaskCoordinator(maximumConcurrent: maximum) { [weak self] _ in
            let worker = AgentEngine()
            if workerHook {
                worker.persistRecord = { [weak self] record in
                    guard let self else { return false }
                    self.workerWrites += 1
                    return !self.rejected.contains(record.id) && self.store.upsert(record)
                }
            }
            self?.workers.append(worker); return worker
        }
        pool.persistRecord = { [weak self] record in
            guard let self else { return false }
            self.poolWrites += 1
            return !self.rejected.contains(record.id) && self.store.upsert(record)
        }
        pool.onRecord = { [weak self] record, origin in
            guard let self else { return }
            self.callbacks += 1
            precondition(self.store.records.contains { $0.id == record.id && $0.outcome == record.outcome && $0.summary == record.summary },
                "Coordinator callback must follow its exact durable commit")
            if let origin { self.origins[record.id] = origin.conversationID }
        }
        observation = pool.$records.dropFirst().sink { [weak self] records in
            guard let self else { return }
            self.projections.append(records)
            for record in records {
                precondition(self.store.records.contains { $0.id == record.id && $0.outcome == record.outcome && $0.summary == record.summary },
                    "Every record in a published pool projection must match a committed snapshot")
            }
        }
    }
    func submit(_ text: String, origin: BackgroundTaskCoordinator.Origin? = nil) throws -> UUID {
        try pool.submit(goal: text, settings: AgentSettings(), attachments: [], reference: "real host reference",
            origin: origin ?? .init(conversationID: UUID(), messageID: UUID()))
    }
}

@main struct CoordinatorPersistenceChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); count += 1 }
        func settle() async { for _ in 0..<10 { await Task.yield() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-transaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let blocked = folder.appendingPathComponent("blocked-parent")
        try Data("not a directory".utf8).write(to: blocked)
        let failed = CoordinatorHarness(url: blocked.appendingPathComponent("tasks.json"))
        var threw = false
        do { _ = try failed.submit("Never dispatch before saving") } catch { threw = true }
        check(threw && failed.workers.isEmpty, "A failed submission commit throws before creating or dispatching a worker")
        check(failed.pool.records.isEmpty && failed.callbacks == 0 && failed.projections.isEmpty,
            "A failed submission emits no committed task projection or callback")
        let failedCheckpoint = failed.pool.checkpointRecords.first!
        check(failedCheckpoint.outcome == .paused && failedCheckpoint.executionLane == "native" && failedCheckpoint.goal == "Never dispatch before saving",
            "The exact unsaved submission remains a paused volatile checkpoint for explicit retry")
        check(!failed.pool.running(failedCheckpoint.id) && !failed.pool.hasUnsettledExecution,
            "A failed submission holds no queued run request or input execution")
        try FileManager.default.removeItem(at: blocked)
        let retrySnapshots = failed.pool.checkpointRecords
        check(failed.store.saveCheckpoints(retrySnapshots), "The host can explicitly save all volatile checkpoints after storage recovery")
        let retryToken = failed.pool.token(failedCheckpoint.id)
        check(failed.pool.acknowledgeSavedCheckpoints(retrySnapshots) && failed.pool.records.first?.outcome == .paused,
            "Only an exact successfully saved checkpoint can update the formerly failed pool projection")
        check(failed.pool.token(failedCheckpoint.id) == retryToken,
            "Acknowledging a durable retry does not issue a new task-control token")
        await settle()
        check(failed.workers.isEmpty && !failed.pool.hasUnsettledExecution,
            "Saving recovered records does not start or resume a task")
        try failed.pool.resume(failedCheckpoint.id)
        check(failed.workers.count == 1 && failed.workers[0].dispatches == 1,
            "Only a subsequent explicit resume grants a worker its execution slot")

        let inherited = CoordinatorHarness(url: folder.appendingPathComponent("inherited.json"))
        let origin = BackgroundTaskCoordinator.Origin(conversationID: UUID(), messageID: UUID())
        let inheritedID = try inherited.submit("Coordinator owns persistence", origin: origin)
        check(inherited.poolWrites == 2 && inherited.callbacks == 2,
            "A worker without its own hook inherits coordinator persistence for reservation and start exactly once each")
        check(inherited.workers[0].persistRecord != nil && inherited.workers[0].dispatches == 1,
            "A coordinator persistence hook participates in the worker's pre-dispatch commit boundary")
        check(inherited.store.records.first?.executionLane == "native" && inherited.origins[inheritedID] == origin.conversationID,
            "Persisted native provenance and original conversation ownership survive inherited worker commits")

        let own = CoordinatorHarness(url: folder.appendingPathComponent("own.json"), workerHook: true)
        let ownID = try own.submit("Worker owns persistence")
        check(own.poolWrites == 1 && own.workerWrites == 1 && own.callbacks == 2,
            "An already committed worker start is not written again by the coordinator")
        own.workers[0].complete()
        check(own.poolWrites == 1 && own.workerWrites == 2 && own.pool.record(ownID)?.outcome == .completed,
            "A committed terminal worker result is published without a duplicate repository write")
        check(own.store.records.first?.executionLane == "native", "The coordinator normalizes native provenance before an existing worker hook saves")

        let isolation = CoordinatorHarness(url: folder.appendingPathComponent("isolation.json"), maximum: 2, workerHook: true)
        let a = try isolation.submit("A"), b = try isolation.submit("B")
        isolation.rejected.insert(a)
        let beforeFailureCallbacks = isolation.callbacks, beforeFailurePoolWrites = isolation.poolWrites
        isolation.workers[0].complete()
        check(isolation.callbacks == beforeFailureCallbacks && isolation.poolWrites == beforeFailurePoolWrites,
            "Worker persistence failure uses only the failure callback, without publication or an implicit second write")
        check(isolation.pool.checkpointRecords.first { $0.id == a }?.outcome == .paused && !isolation.pool.running(a),
            "A failed worker terminal commit retains a paused checkpoint and cancels future dispatch")
        check(isolation.pool.records.first { $0.id == a }?.outcome == .running,
            "The committed projection remains at A's last saved state after A's write fails")
        isolation.workers[1].complete()
        check(isolation.pool.records.first { $0.id == b }?.outcome == .completed && isolation.pool.records.first { $0.id == a }?.outcome == .running,
            "B's successful publication cannot leak A's uncommitted paused or completed snapshot")
        check(isolation.pool.checkpointRecords.first { $0.id == a }?.outcome == .paused,
            "A's complete volatile checkpoint remains separately available after B publishes")
        let firstPausedA = isolation.pool.checkpointRecords.first { $0.id == a }!
        isolation.rejected.remove(a)
        let isolationRetry = isolation.pool.checkpointRecords
        let dispatchesBeforeRetry = isolation.workers.map(\.dispatches)
        check(isolation.store.saveCheckpoints(isolationRetry) && isolation.pool.acknowledgeSavedCheckpoints(isolationRetry),
            "The host can atomically save then acknowledge every exact failed checkpoint")
        await settle()
        check(isolation.pool.records.first { $0.id == a }?.outcome == .paused && isolation.workers.map(\.dispatches) == dispatchesBeforeRetry,
            "Successful acknowledgement clears the stale projection without pumping or resuming work")
        try isolation.pool.resume(a)
        check(isolation.workers[0].dispatches == dispatchesBeforeRetry[0] + 1,
            "An explicit resume succeeds after the exact saved checkpoint has been acknowledged")
        isolation.rejected.insert(a)
        try isolation.workers[0].amendTask("new explicit requirement")
        let newest = isolation.pool.checkpointRecords
        let staleMixed = newest.map { $0.id == a ? firstPausedA : $0 }.sorted { $0.id == b && $1.id != b }
        let beforeStaleCallbacks = isolation.callbacks, beforeStaleProjections = isolation.projections.count
        check(!isolation.pool.acknowledgeSavedCheckpoints(staleMixed),
            "An earlier paused snapshot cannot acknowledge a newer same-task requirement or checkpoint")
        check(isolation.callbacks == beforeStaleCallbacks && isolation.projections.count == beforeStaleProjections,
            "A later invalid snapshot rejects the entire acknowledgement before any matching entry publishes")
        check(isolation.pool.checkpointRecords.first { $0.id == a }?.amendments?.last?.text == "new explicit requirement",
            "Rejected stale acknowledgement cannot overwrite the latest volatile requirement")
        check(!isolation.pool.acknowledgeSavedCheckpoints([newest[0], newest[0]]),
            "Duplicate task IDs are rejected instead of acknowledging an ambiguous version")
        isolation.rejected.remove(a)
        let unrelatedMain = PhoneTaskRecord(title: "Main engine checkpoint", goal: "not owned by native pool", outcome: .paused)
        let finalRetry = isolation.pool.checkpointRecords + [unrelatedMain]
        let dispatchesBeforeFinalRetry = isolation.workers.map(\.dispatches)
        check(isolation.store.saveCheckpoints(finalRetry) && isolation.pool.acknowledgeSavedCheckpoints(finalRetry),
            "A successful complete retry acknowledges matching entries and ignores the host's main-engine record")
        await settle()
        check(isolation.workers.map(\.dispatches) == dispatchesBeforeFinalRetry && !isolation.pool.running(a),
            "Even the final successful retry grants no queued work or automatic execution")

        let queued = CoordinatorHarness(url: folder.appendingPathComponent("queued.json"), maximum: 1)
        let active = try queued.submit("Active slot owner"), waiting = try queued.submit("Waiting for a slot")
        check(queued.workers.count == 1 && queued.pool.running(waiting), "A waiting task has a durable reservation without a second worker")
        queued.rejected.insert(waiting)
        try queued.pool.pause(waiting)
        check(!queued.pool.running(waiting) && queued.pool.checkpointRecords.first { $0.id == waiting }?.outcome == .paused,
            "A queued pause still removes run authority when its checkpoint cannot be saved")
        let resumed = queued.pool.checkpointRecords.first { $0.id == waiting }!
        let recovered = try queued.pool.recover(resumed, settings: AgentSettings(), mode: .continueTask)
        check(!recovered && queued.workers.count == 1 && !queued.pool.running(waiting),
            "A failed queued recovery reservation returns false and never creates or pumps its worker")
        queued.workers[0].complete(); await settle()
        check(queued.workers.count == 1 && queued.pool.record(active)?.outcome == .completed,
            "An unrelated worker finishing cannot dispatch a failed queued recovery")
        check(queued.pool.records.contains { $0.id == waiting },
            "A failed replacement recovery retains its last committed pool projection")

        let cancellation = CoordinatorHarness(url: folder.appendingPathComponent("cancel.json"), maximum: 1)
        let cancellingID = try cancellation.submit("Cancel SDK owner")
        cancellation.workers[0].holdCancellation = true
        cancellation.rejected.insert(cancellingID)
        try cancellation.pool.stop(cancellingID)
        check(cancellation.workers[0].stops == 1 && !cancellation.workers[0].running && cancellation.workers[0].releasing,
            "Stop cancels immediately even while saving its cancellation checkpoint fails")
        check(cancellation.pool.hasUnsettledExecution && cancellation.pool.busy(cancellingID),
            "The maintenance guard covers the SDK cancellation settlement window")
        let maintenance = ToolReceiptMaintenanceContext(protectedTaskIDs: Set(cancellation.pool.checkpointRecords.map(\.id)),
            executionInFlight: cancellation.pool.hasUnsettledExecution, taskStorageAvailable: true)
        check(ToolReceiptMaintenancePolicy.blockedReason(context: maintenance, approvalPending: false, receiptsReadable: true) != nil,
            "Receipt maintenance stays blocked until pending SDK cancellation settles")
        cancellation.workers[0].releasing = false; await settle()
        check(!cancellation.pool.hasUnsettledExecution && cancellation.pool.checkpointRecords.first?.outcome == .paused,
            "After cancellation settles there is no run authority, but the failed checkpoint remains recoverable")
        let protected = ToolReceiptMaintenanceContext(protectedTaskIDs: Set(cancellation.pool.checkpointRecords.map(\.id)),
            executionInFlight: false, taskStorageAvailable: true)
        check(!ToolReceiptMaintenancePolicy.mayRemove(key: cancellingID.uuidString + ":write", state: "completed", context: protected),
            "A volatile recoverable checkpoint still protects its write receipts after cancellation")
        print("Task coordinator persistence: \(count) actual coordinator/repository checks passed; worker boundary synthetic, no device/model/network calls")
    }
}
