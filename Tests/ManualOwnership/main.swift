import Foundation

enum ScaffoldError: LocalizedError {
    case blockFailure, timeout(String), failedChecks
    var errorDescription: String? {
        switch self {
        case .blockFailure: return "synthetic block failure"
        case let .timeout(stage): return "synthetic monotonic gate timeout: " + stage
        case .failedChecks: return "extracted-method ownership checks failed"
        }
    }
}

/// Ignores caller cancellation deliberately, but has its own real 5s deadman.
@MainActor final class Gate {
    private(set) var entered = false
    private var opened = false
    private var terminalError: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    func waitIgnoringCancellation() async throws {
        entered = true
        if opened { if let terminalError { throw terminalError }; return }
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            continuation = pending
            watchdog = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                finish(error: ScaffoldError.timeout("block gate deadman"))
            }
        }
    }
    private func finish(error: Error?) {
        guard !opened else { return }
        opened = true; terminalError = error
        watchdog?.cancel(); watchdog = nil
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func open() { finish(error: nil) }
}

@MainActor final class Log {
    let directory: URL
    var checks = 0, failures: [String] = [], rows: [[String: Any]] = []
    var phase = "not started"
    init(_ directory: URL) throws {
        self.directory = directory
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ScaffoldError.timeout("fresh result directory required") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !condition() { failures.append(message) }
    }
    func record(_ stage: String, _ owner: ExtractedManualOwnerScaffold? = nil, _ extra: [String: Any] = [:]) throws {
        phase = stage
        var row = extra; row["phase"] = stage; row["observedUptime"] = ProcessInfo.processInfo.systemUptime
        if let owner { row["owner"] = owner.snapshot() }
        rows.append(row); try save(complete: false)
    }
    func save(complete: Bool, terminalError: Error? = nil) throws {
        var value: [String: Any] = ["schemaVersion": 1, "complete": complete, "phase": phase,
            "checks": checks, "failures": failures, "rows": rows,
            "kind": "extracted-method/scaffold; not complete VM/UI/voice/queue integration",
            "realPhoneAPINetworkOrBLE": false]
        if let terminalError { value["terminalError"] = String(reflecting: terminalError) }
        else { value["terminalError"] = NSNull() }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }
}

@MainActor func waitUntil(_ stage: String, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ScaffoldError.timeout(stage) }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Each real manual Task is monitored independently. A timeout never enters a
/// task group or awaits an unsettled child's value on the controlling path.
@MainActor final class CaseScope {
    struct Child { let id: UUID; let task: Task<Void, Never> }
    let owner = ExtractedManualOwnerScaffold()
    private var gates: [Gate] = []
    private var children: [Child] = []
    private var monitors: [Task<Void, Never>] = []
    private var settled = Set<UUID>()
    func gate() -> Gate { let value = Gate(); gates.append(value); return value }
    func trackCurrent(_ label: String) throws -> Child {
        guard let task = owner.manual else { throw ScaffoldError.timeout(label + " admitted task missing") }
        let child = Child(id: UUID(), task: task); children.append(child)
        monitors.append(Task { @MainActor [weak self] in
            await task.value
            self?.settled.insert(child.id)
        })
        return child
    }
    func join(_ child: Child, label: String) async throws {
        try await waitUntil(label + " observed settled") { settled.contains(child.id) }
        // Only reached after the monitor observed the actual child return.
        await child.task.value
    }
    func cleanup() async -> Bool {
        for child in children { child.task.cancel() }
        for gate in gates { gate.open() }
        owner.ble.finishSyntheticIOForTeardown()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while settled.count != children.count && ProcessInfo.processInfo.systemUptime < deadline {
            // Synthetic teardown can close a newly entered release continuation.
            // No assertion attributes this to production writer clearing.
            owner.ble.finishSyntheticIOForTeardown()
            do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return false }
        }
        guard settled.count == children.count else { return false }
        for child in children { await child.task.value }
        for monitor in monitors { await monitor.value }
        return true
    }
}

@MainActor func withCase(_ log: Log, _ name: String, _ body: (CaseScope) async throws -> Void) async throws {
    let scope = CaseScope()
    var bodyError: Error?
    do { try log.record(name + ": begin", scope.owner); try await body(scope) }
    catch { bodyError = error }
    let cleanupSettled = await scope.cleanup()
    let savedBodyError: Any
    if let bodyError { savedBodyError = String(reflecting: bodyError) }
    else { savedBodyError = NSNull() }
    try log.record(name + ": bounded case teardown", scope.owner,
        ["bodyError": savedBodyError,
         "cleanupSettled": cleanupSettled, "syntheticTeardownCalls": scope.owner.ble.teardownCalls])
    guard cleanupSettled else { throw ScaffoldError.timeout(name + " cleanup did not settle") }
    if let bodyError { throw bodyError }
}

@main struct ManualOwnershipScaffoldChecks {
    @MainActor static func ignoredCancellation(_ log: Log, stop: Bool) async throws {
        try await withCase(log, stop ? "stop ignores cancellation" : "pause ignores cancellation") { scope in
            let owner = scope.owner, block = scope.gate()
            let original = owner.ble.connectionGeneration
            owner.manualAction(allowsBackgroundScreen: true) { try await block.waitIgnoringCancellation() }
            let first = try scope.trackCurrent("ignored cancellation")
            try await waitUntil("block entered") { block.entered }
            log.expect(owner.manualBusy && owner.manualScreenWorkflow, "manual ownership and background-screen scope set synchronously")
            log.expect(owner.ble.capturedManualGenerations == [original], "connection generation captured by actual method at admission")
            if stop { owner.stop() } else { _ = owner.pauseTask(handoff: true) }
            try log.record(stop ? "stop requested with held block" : "pause requested with held block", owner)
            log.expect(first.task.isCancelled && owner.manualBusy && owner.manual != nil, "cancel request does not settle noncooperative block")
            log.expect(owner.manualContinuationRequired == !stop, "pause retains continuation intent; stop clears it")
            log.expect(owner.ble.submissions.isEmpty, "cleanup cannot start before block returns")
            var secondCalls = 0
            owner.manualAction { secondCalls += 1 }
            await Task.yield()
            log.expect(secondCalls == 0 && owner.manualBusy, "second manual action blocked while cancelled block is unsettled")
            block.open()
            try await waitUntil("release submission after block returns") { owner.ble.submissions.count == 1 }
            try log.record("block returned; release completion still gated", owner)
            log.expect(owner.manualBusy && owner.manualScreenWorkflow && owner.manual != nil, "ownership remains through await release completion")
            log.expect(owner.ble.submissions[0].expectedGeneration == original && owner.ble.submissions[0].generation == original,
                       "release submission remains bound to original connection")
            log.expect(!owner.ble.submissions[0].cancelledContext, "actual controller starts uncancelled cleanup task")
            owner.manualAction { secondCalls += 1 }
            await Task.yield()
            log.expect(secondCalls == 0, "second manual action also blocked during cleanup")
            owner.ble.acknowledge()
            try await scope.join(first, label: "original cleanup")
            try log.record("original cleanup completed; owner settled", owner)
            log.expect(!owner.manualBusy && !owner.manualScreenWorkflow && owner.manual == nil, "owner clears only after release completes")
            log.expect(owner.manualContinuationRequired == !stop, "cleanup does not erase pause continuation semantics")
            if stop {
                log.expect(owner.engine.stopCalls == 1 && owner.assistiveTouchVerification.calls == 1 && owner.liveCamera.stopCalls == 1,
                           "entire extracted stop invokes declared dependency doubles")
            } else { log.expect(owner.engine.handoffCalls == 0 && owner.engine.pauseCalls == 0, "manual pause returns before engine branch") }
            owner.ble.autoAcknowledge = true
            owner.manualAction { secondCalls += 1 }
            let next = try scope.trackCurrent("next explicit action")
            try await scope.join(next, label: "next explicit action")
            log.expect(secondCalls == 1 && !owner.manualContinuationRequired, "next action starts only after settlement and resets continuation intent")
        }
    }

    @MainActor static func completionVariants(_ log: Log) async throws {
        for mode in ["success", "throw", "cooperativeCancellation", "cleanupError"] {
            try await withCase(log, mode) { scope in
                let owner = scope.owner, gate = scope.gate()
                owner.manualAction {
                    try await gate.waitIgnoringCancellation()
                    if mode == "throw" { throw ScaffoldError.blockFailure }
                    if mode == "cooperativeCancellation" { try Task.checkCancellation() }
                }
                let first = try scope.trackCurrent(mode)
                try await waitUntil(mode + " block entered") { gate.entered }
                if mode == "cooperativeCancellation" { _ = owner.pauseTask() }
                gate.open()
                try await waitUntil(mode + " cleanup entered") { owner.ble.submissions.count == 1 }
                try log.record(mode + ": release held", owner)
                log.expect(owner.manualBusy && owner.manual != nil, mode + ": release await retains ownership")
                if mode == "throw" { log.expect(owner.notice == ScaffoldError.blockFailure.localizedDescription, "block error notice preserved") }
                if mode == "cooperativeCancellation" {
                    log.expect(first.task.isCancelled && owner.notice.contains("已请求暂停"), "CancellationError does not overwrite pause notice")
                }
                log.expect(owner.ble.submissions.allSatisfy { !$0.cancelledContext }, mode + ": cleanup uses uncancelled worker")
                owner.ble.acknowledge(error: mode == "cleanupError" ? ScaffoldError.blockFailure : nil)
                try await scope.join(first, label: mode)
                log.expect(!owner.manualBusy && owner.manual == nil, mode + ": completion settles owner even for unconfirmed transport result")
                try log.record(mode + ": settled", owner)
            }
        }
    }

    @MainActor static func oldWriter(_ log: Log) async throws {
        try await withCase(log, "foreign writer") { scope in
            let owner = scope.owner, gate = scope.gate()
            let oldWriter = owner.ble.beginForeignWriter()
            owner.manualAction { try await gate.waitIgnoringCancellation() }
            let first = try scope.trackCurrent("foreign writer")
            try await waitUntil("foreign-writer block entered") { gate.entered }
            _ = owner.pauseTask()
            let before = owner.ble.writerStateReads
            gate.open()
            try await waitUntil("controller performed existing-writer check") { owner.ble.writerStateReads >= before + 2 }
            try await Task.sleep(nanoseconds: 1_150_000_000)
            try log.record("foreign writer held after 1.15 real seconds", owner)
            log.expect(owner.manualBusy && owner.manual != nil && owner.ble.submissions.isEmpty, "cancelled manual stays busy past former1s while original writer remains held")
            owner.ble.finishForeignWriter(oldWriter)
            try await waitUntil("release after original writer settlement") { owner.ble.submissions.count == 1 }
            log.expect(owner.manualBusy, "original writer completion does not finish separate release")
            owner.ble.acknowledge()
            try await scope.join(first, label: "foreign writer cleanup")
            log.expect(!owner.manualBusy, "cleanup completion finally settles cancelled manual")
            try log.record("foreign-writer case settled", owner)
        }
    }

    @MainActor static func reconnect(_ log: Log) async throws {
        for whileWaiting in [false, true] {
            try await withCase(log, whileWaiting ? "reconnect waiting" : "reconnect before cleanup") { scope in
                let owner = scope.owner, gate = scope.gate()
                let original = owner.ble.connectionGeneration
                if whileWaiting { _ = owner.ble.beginForeignWriter() }
                owner.manualAction { try await gate.waitIgnoringCancellation(); try Task.checkCancellation() }
                let first = try scope.trackCurrent("reconnect")
                try await waitUntil("reconnect block entered") { gate.entered }
                _ = owner.pauseTask()
                if whileWaiting {
                    let before = owner.ble.writerStateReads
                    gate.open()
                    try await waitUntil("controller waiting before reconnect") { owner.ble.writerStateReads >= before + 2 }
                    try await Task.sleep(nanoseconds: 1_000_000)
                    owner.ble.changeConnection()
                } else { owner.ble.changeConnection(); gate.open() }
                try await scope.join(first, label: "reconnect cleanup")
                try log.record("reconnect owner settled", owner,
                    ["originalGeneration": original.uuidString, "currentGeneration": owner.ble.connectionGeneration.uuidString])
                log.expect(owner.ble.connectionGeneration != original && owner.ble.capturedManualGenerations == [original], "actual manual admission captured original generation")
                log.expect(owner.ble.submissions.isEmpty, "old cleanup cannot submit to replacement connection")
                log.expect(!owner.manualBusy && owner.manual == nil && owner.manualContinuationRequired, "not-submitted cleanup settles owner without claiming HID release")
            }
        }
    }

    @MainActor static func guards(_ log: Log) async throws {
        let setups: [(String, (ExtractedManualOwnerScaffold) -> Void)] = [
            ("preparingAutomatically", { $0.preparingAutomatically = true }),
            ("recordingAudioOwner", { $0.recordingAudioOwner = UUID() }),
            ("queueRunning", { $0.queueRunning = true }),
            ("queueSwitching", { $0.queueSwitching = true }),
            ("engine.running", { $0.engine.running = true }),
            ("engine.releasing", { $0.engine.releasing = true }),
            ("manualBusy", { $0.manualBusy = true }),
            ("voicePending", { $0.voicePending = true }),
            ("calibrating", { $0.calibrating = true }),
            ("executor.calibrationInProgress", { $0.executor.calibrationInProgress = true }),
            ("workflowServices.blocksGUI", { $0.workflowServices.blocksGUI = true }),
        ]
        for (name, setup) in setups {
            try await withCase(log, "guard " + name) { scope in
                let owner = scope.owner; owner.ble.autoAcknowledge = true
                setup(owner)
                var entered = 0
                owner.manualAction { entered += 1 }
                let unexpectedlyAdmitted = owner.manual != nil
                if unexpectedlyAdmitted {
                    let unexpected = try scope.trackCurrent("unexpected guard admission")
                    try await scope.join(unexpected, label: "unexpected guard admission")
                }
                await Task.yield()
                log.expect(entered == 0 && !unexpectedlyAdmitted && owner.ble.submissions.isEmpty, "entire original admission guard rejects " + name)
                try log.record("admission guard asserted: " + name, owner)
            }
        }
        for handoff in [false, true] {
            try await withCase(log, handoff ? "nonmanual handoff" : "nonmanual pause") { scope in
                let owner = scope.owner; owner.engine.hasCurrentTask = true
                _ = owner.pauseTask(handoff: handoff)
                log.expect(owner.engine.pauseCalls == (handoff ? 0 : 1) && owner.engine.handoffCalls == (handoff ? 1 : 0), "nonmanual pause/handoff calls declared engine dependency")
                log.expect(owner.manual == nil && owner.ble.submissions.isEmpty, "nonmanual branch invents no manual cleanup")
            }
        }
    }

    @MainActor static func pendingOwnership(_ log: Log) async throws {
        for stopping in [false, true] {
            for consent in [false, true] {
                for engineState in 0..<3 {
                    try await withCase(log, "pending submission ownership") { scope in
                        let owner = scope.owner
                        let pending = ConversationTaskSubmission(conversationID: UUID(), messageID: UUID(), goal: "synthetic pending task")
                        if consent { owner.pendingConsentConversationTask = pending; owner.pendingConsentStart = true }
                        else { owner.pendingConversationTask = pending }
                        owner.engine.running = engineState > 0
                        owner.engine.hasCurrentTask = engineState > 0
                        owner.engine.currentRecord = engineState == 0 ? nil : .init(id: engineState == 1 ? pending.taskID : UUID())
                        if stopping { owner.stop() } else { _ = owner.pauseTask() }
                        let reports = owner.conversation.handoffReports
                        log.expect(reports.count == 1 && reports.first?.messageID == pending.messageID && reports.first?.conversationID == pending.conversationID,
                                   "pending stop/pause reports only to the owning chat and message")
                        log.expect(owner.pendingConversationTask == nil && owner.pendingConsentConversationTask == nil && !owner.pendingConsentStart,
                                   "pending and consent authority is revoked after stop/pause")
                        let unstarted = reports.first?.text.contains("\u{4efb}\u{52a1}\u{672a}\u{542f}\u{52a8}") ?? false
                        log.expect(unstarted == (engineState != 1), "only the same running task is reported as handed to an executor")
                    }
                }
            }
        }
    }

    @MainActor static func main() async {
        var log: Log?
        do {
            guard CommandLine.arguments.count == 2 else { throw ScaffoldError.timeout("one fresh result directory required") }
            let created = try Log(URL(fileURLWithPath: CommandLine.arguments[1])); log = created
            try created.record("prepared extracted methods executing in declared scaffold")
            try await ignoredCancellation(created, stop: false)
            try await ignoredCancellation(created, stop: true)
            try await completionVariants(created)
            try await oldWriter(created)
            try await reconnect(created)
            try await guards(created)
            try await pendingOwnership(created)
            try created.save(complete: true)
            guard created.failures.isEmpty else { throw ScaffoldError.failedChecks }
            print("Extracted-method/scaffold ownership: \(created.checks) checks passed")
        } catch {
            try? log?.save(complete: false, terminalError: error)
            print("Extracted-method/scaffold failed: \(String(reflecting: error))")
            exit(1)
        }
    }
}
