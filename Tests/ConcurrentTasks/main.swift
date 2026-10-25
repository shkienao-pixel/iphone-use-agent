import Foundation

@main struct ConcurrentTaskChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<4000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
            throw AgentError.message("Concurrent fixture timed out")
        }
        let capture = CaptureService(), executor = MouseExecutor()
        var config = AgentSettings(); config.startDelay = 0; config.systemToolsEnabled = true; config.toolsOnly = true
        PrivacyConsent.grant(config); defer { PrivacyConsent.revoke() }
        ModelProbe.delay = 3_000_000_000
        ModelProbe.action = AgentAction(kind: .finish, reason: "offline completion")
        var workers: [AgentEngine] = [], receipts: [(UUID, UUID?)] = []
        let pool = BackgroundTaskCoordinator(maximumConcurrent: 3) { _ in
            let engine = AgentEngine(capture: capture, executor: executor, ownsScreenInput: false)
            engine.systemTool = { _, _ in "offline receipt" }; workers.append(engine); return engine
        }
        pool.onRecord = { record, origin in receipts.append((record.id, origin?.conversationID)) }
        let origins = (0..<4).map { _ in BackgroundTaskCoordinator.Origin(conversationID: UUID(), messageID: UUID()) }
        var ids: [UUID] = []
        for i in 0..<4 { ids.append(try pool.submit(goal: "independent native task \(i)", settings: config, attachments: [], reference: "source \(i)", origin: origins[i])) }
        try await wait { ModelProbe.calls == 3 }
        expect(workers.count == 3 && pool.records.count == 4, "Three workers run concurrently while fourth remains queued")
        expect(ids.allSatisfy { pool.token($0) != nil }, "All active and queued tasks have separate process-local tokens")
        expect(executor.invalidations == 0 && executor.ble.releases == 0 && executor.actions.isEmpty, "Native launch never invalidates, releases or drives shared screen input")
        let firstToken = pool.token(ids[0])!, secondToken = pool.token(ids[1])!
        try pool.pause(ids[0], expected: firstToken)
        try await wait { workers.count == 4 && ModelProbe.calls >= 4 }
        expect(pool.record(ids[0])?.outcome == .paused && pool.token(ids[1]) == secondToken, "Pausing one worker frees a slot without changing another worker's authority")
        do { try pool.stop(ids[0], expected: firstToken); preconditionFailure("Stale token accepted") } catch { checks += 1 }
        try pool.stop(ids[1], expected: secondToken)
        expect(pool.record(ids[1])?.outcome == .stopped && pool.record(ids[2])?.outcome == .running, "Independent stop preserves other running tasks")
        try await wait { !pool.busy(ids[0]) && !pool.busy(ids[1]) }
        try pool.resume(ids[0], expected: pool.token(ids[0]))
        try await wait { pool.record(ids[0])?.outcome == .running }
        expect(workers[0].currentRecord?.id == ids[0], "Resume preserves task identity and checkpoint")
        expect(executor.invalidations == 0 && executor.ble.releases == 0, "Pause, stop and resume of background tasks leave main BLE input untouched")
        for i in ids.indices { expect(receipts.filter { $0.0 == ids[i] }.allSatisfy { $0.1 == origins[i].conversationID }, "Every result belongs to its original conversation") }
        for id in ids where pool.token(id) != nil { try pool.stop(id) }
        try await wait { workers.allSatisfy(\.executionSettled) }

        // The real planning loop dispatches independent tool calls and keeps
        // their receipts isolated, while the OS/service response is synthetic.
        ModelProbe.delay = 0; ModelProbe.calls = 0
        ModelProbe.actionProvider = { call in
            if call <= 2 {
                let request = SystemToolRequest(operation: call == 1 ? .ctrip_query : .contact_search, query: call == 1 ? "offline trip" : "Alice")
                return AgentAction(kind: .system_tool, text: String(decoding: try! JSONEncoder().encode(request), as: UTF8.self), reason: "offline planned native action")
            }
            return AgentAction(kind: .finish, reason: "offline verified receipt")
        }
        let toolGate = TaskResourceGate()
        var toolCount = 0, peakToolCount = 0, toolIDs = Set<UUID>()
        let toolPool = BackgroundTaskCoordinator { _ in
            let engine = AgentEngine(capture: capture, executor: executor, ownsScreenInput: false)
            engine.systemTool = { id, request in
                try await toolGate.withResources(TaskResourceGate.resources(for: request.operation, confirmation: false)) {
                    toolCount += 1; peakToolCount = max(peakToolCount, toolCount); toolIDs.insert(id)
                    defer { toolCount -= 1 }
                    try await Task.sleep(for: .milliseconds(100))
                    return "offline completed tool receipt for " + id.uuidString
                }
            }
            return engine
        }
        let receiptOne = try toolPool.submit(goal: "native receipt one", settings: config, attachments: [], reference: "one", origin: origins[0])
        let receiptTwo = try toolPool.submit(goal: "native receipt two", settings: config, attachments: [], reference: "two", origin: origins[1])
        try await wait { toolPool.records.allSatisfy { $0.outcome == .completed } }
        expect(peakToolCount == 2 && toolIDs == Set([receiptOne, receiptTwo]), "Two real engine loops dispatch unrelated tools simultaneously")
        for id in [receiptOne, receiptTwo] {
            let other = id == receiptOne ? receiptTwo : receiptOne
            let ownLogs = toolPool.record(id)!.logs.filter { $0.title == "工具回执" }.map(\.detail).joined()
            expect(ownLogs.contains(id.uuidString) && !ownLogs.contains(other.uuidString), "Each worker retains only its own verified tool receipt")
            expect(toolPool.record(id)?.executionLane == "native", "Native scheduling provenance is persisted with each result")
        }
        expect(toolPool.sessions.isEmpty, "Completed workers relinquish all process-local control tokens")
        ModelProbe.actionProvider = nil

        let checkpoint = pool.record(ids[0])!
        let previousStep = checkpoint.checkpointStep ?? 0
        let recovered = try pool.recover(checkpoint, settings: config, mode: .continueTask)
        try await wait { pool.record(ids[0])?.outcome == .completed }
        expect(recovered && pool.record(ids[0])?.id == checkpoint.id && (pool.record(ids[0])?.checkpointStep ?? 0) > previousStep,
               "Explicit native recovery preserves task ID and accumulated progress")
        let persisted = try JSONDecoder().decode(PhoneTaskRecord.self, from: JSONEncoder().encode(pool.record(ids[0])!))
        expect(persisted.executionLane == "native", "Native history retains scheduling provenance across serialization")
        let afterRestart = BackgroundTaskCoordinator { _ in AgentEngine(capture: capture, executor: executor, ownsScreenInput: false) }
        expect(afterRestart.sessions.isEmpty && afterRestart.records.isEmpty, "Loading history never restores native execution authority automatically")

        ModelProbe.calls = 0
        ModelProbe.actionProvider = { call in
            if call <= 2 { return AgentAction(kind: .system_tool, text: "{\"operation\":\"contact_search\",\"query\":\"Alice\"}", reason: "requires approval") }
            return AgentAction(kind: .finish, reason: "approved result")
        }
        let approval = ApprovalStateProbe(), approvalGate = TaskResourceGate()
        let approvalPool = BackgroundTaskCoordinator { _ in
            let engine = AgentEngine(capture: capture, executor: executor, ownsScreenInput: false)
            engine.systemTool = { id, request in
                try await approvalGate.withResources(["toolApproval"]) { try await approval.executeApproval(request, taskID: id) }
            }
            return engine
        }
        let approvalA = try approvalPool.submit(goal: "approval A", settings: config, attachments: [], reference: "", origin: origins[0])
        let approvalB = try approvalPool.submit(goal: "approval B", settings: config, attachments: [], reference: "", origin: origins[1])
        try await wait { approval.pending != nil }
        let oldApproval = approval.pending!
        let owningTask = oldApproval.taskID!, otherTask = owningTask == approvalA ? approvalB : approvalA
        try approvalPool.stop(owningTask)
        try await wait { approval.pending?.taskID == otherTask }
        let nextApproval = approval.pending!
        approval.decide(true, expectedID: oldApproval.id)
        expect(approval.pending?.id == nextApproval.id, "An old approval view cannot approve the next task's pending request")
        expect(approvalPool.record(owningTask)?.outcome == .stopped && approvalPool.record(otherTask)?.outcome == .running,
               "Stopping the owner of an approval cancels only that worker and releases the approval lease")
        approval.decide(true, expectedID: nextApproval.id)
        try await wait { approvalPool.record(otherTask)?.outcome == .completed }
        expect(approval.pending == nil && executor.ble.releases == 0 && executor.invalidations == 0,
               "Approval cancellation and confirmation preserve shared screen input and do not strand continuations")
        ModelProbe.actionProvider = nil

        // A tools-only worker rejects a visual launch at the engine boundary.
        var screen = config; screen.toolsOnly = false
        let isolated = AgentEngine(capture: capture, executor: executor, ownsScreenInput: false)
        isolated.start(task: "must not drive the phone", settings: screen)
        expect(!isolated.running && !isolated.error.isEmpty, "No-screen engines cannot enter the visual loop even with a wrong routing hint")

        let gate = TaskResourceGate()
        var held = false, release = false, sharedEntered = false, unrelatedEntered = false
        let a = Task { try await gate.withResources(["eventKit"]) { held = true; while !release { try await Task.sleep(for: .milliseconds(1)) } } }
        try await wait { held }
        let b = Task { try await gate.withResources(["eventKit"]) { sharedEntered = true } }
        let c = Task { try await gate.withResources(["ctrip"]) { unrelatedEntered = true } }
        try await wait { unrelatedEntered }
        expect(!sharedEntered, "Same service is exclusive while an unrelated service progresses concurrently")
        b.cancel(); release = true
        _ = try await a.value; _ = try await c.value
        do { try await b.value; preconditionFailure("Cancelled waiter acquired") } catch { checks += 1 }
        try await gate.withResources(["eventKit"]) { sharedEntered = true }
        expect(sharedEntered, "Cancelling one waiter never strands a resource lease")
        expect(TaskResourceGate.resources(for: .calendar_create, confirmation: false) == TaskResourceGate.resources(for: .reminder_create, confirmation: false), "Calendar and reminder writes share the EventKit lock")
        expect(TaskResourceGate.resources(for: .ctrip_query, confirmation: true).contains("toolApproval"), "Approval UI has a separate global lease")

        for operation in [SystemToolRequest.Operation.notes_create, .health_query] {
            let request = operation == .notes_create ? SystemToolRequest(operation: operation, title: "title", content: "body") : SystemToolRequest(operation: operation, query: "steps", start: "2026-10-24T00:00:00+08:00", end: "2026-10-25T00:00:00+08:00")
            do { try BackgroundToolPolicy.validate(request); preconditionFailure("Screen/permission operation accepted") } catch { checks += 1 }
        }
        NativeConnectionsStore.shared.authorized = false
        do { try BackgroundToolPolicy.validate(.init(operation: .contact_search, query: "Alice")); preconditionFailure("Unapproved service accepted") } catch { checks += 1 }
        NativeConnectionsStore.shared.authorized = true
        try BackgroundToolPolicy.validate(.init(operation: .contact_search, query: "Alice")); checks += 1
        print("ConcurrentTasks: \(checks) checks passed. Actual coordinator/engine/resource policy; synthetic model and OS permissions, no hardware/model accuracy claim.")
    }
}
