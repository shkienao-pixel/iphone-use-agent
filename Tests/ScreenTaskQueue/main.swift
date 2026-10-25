import Foundation

@main struct ScreenQueueChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<8000 { if condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
            throw AgentError.message("Screen queue fixture timed out")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenQueue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); PrivacyConsent.revoke() }
        func make(_ name: String) throws -> PhoneAgentViewModel {
            let path = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return PhoneAgentViewModel(directory: path)
        }
        func resetModel() {
            ModelProbe.calls = 0; ModelProbe.goals = []; ModelProbe.delay = 0; ModelProbe.actionProvider = nil; ModelProbe.onRequest = nil
            ModelProbe.action = AgentAction(kind: .finish, reason: "offline completed")
        }
        resetModel()
        let vm = try make("ordered")
        PrivacyConsent.grant(vm.settings)
        var allowA = false, allowB = false
        ModelProbe.onRequest = {
            let goal = ModelProbe.goals.last ?? ""
            while (goal == "A" && !allowA) || (goal == "B" && !allowB) { try await Task.sleep(for: .milliseconds(1)) }
        }
        vm.engine.executor.ble.releaseDelay = 200_000_000
        vm.engine.start(task: "A", settings: vm.settings)
        try await wait { ModelProbe.calls == 1 }
        let a = vm.engine.currentRecord!.id, b = vm.task("B"), c = vm.task("C")
        try vm.taskQueue.append(b); try vm.taskQueue.append(c)
        let originalSession = vm.engine.activityControlSessionID
        expect(vm.screenQueueCurrent?.id == a && vm.screenQueueCount == 3, "The initial direct screen task remains visible beside later queued work")
        expect(vm.startScreenQueue() && vm.engine.activityControlSessionID == originalSession && vm.engine.running, "Starting FIFO adopts the live task without pausing or replacing it")
        expect(vm.reorderScreenQueueTasks([c.id, b.id]), "Waiting tasks can be reordered while A runs")
        expect(vm.taskQueue.items.map(\.id) == [a, c.id, b.id] && vm.engine.activityControlSessionID == originalSession, "Reorder persists the future order and pins A")
        expect(!vm.reorderScreenQueueTasks([b.id]), "Stale or incomplete drag payload is rejected")
        expect(vm.queueRunning && vm.engine.running, "A stale drag is not treated as a storage failure")
        expect(vm.pauseScreenQueueTask(b.id) && vm.engine.activityControlSessionID == originalSession, "Pausing B does not pause or change A")
        expect(vm.resumeScreenQueueTask(b.id) && vm.screenQueueWaiting.map(\.id) == [c.id,b.id], "Starting B only restores its existing position")
        expect(vm.pauseScreenQueueTask(b.id), "Individual pause can be restored before reaching the head")
        allowA = true
        try await wait { vm.engine.releasing && vm.engine.currentRecord?.id == a }
        expect(!vm.pauseScreenQueueTask(a) && !vm.stopScreenQueueTask(a), "Late controls on completed A cannot pause/stop the queue during input release")
        expect(vm.queueRunning, "A stale completed-task control preserves the active FIFO run")
        expect(vm.reorderScreenQueueTasks([b.id,c.id]), "Reordering during release changes the next selected task")
        try await wait { !vm.queueRunning && !vm.engine.releasing }
        expect(ModelProbe.goals == ["A"] && vm.taskQueue.items.first(where: { $0.id == b.id })?.state == .paused, "A paused head blocks later tasks and is never automatically resumed")
        expect(vm.resumeScreenQueueTask(b.id) && ModelProbe.goals == ["A"], "Resuming an item while the queue is paused grants no immediate execution")
        expect(vm.startScreenQueue(), "Explicitly starting the queue resumes the ready head")
        try await wait { vm.engine.currentRecord?.id == b.id && ModelProbe.goals.last == "B" }
        vm.pauseScreenQueue()
        try await wait { vm.engine.executionSettled }
        expect(vm.taskQueue.items.map(\.id) == [a,b.id,c.id] && !vm.queueRunning, "Global pause preserves queue order and checkpoints")
        allowB = true
        expect(vm.startScreenQueue(), "Global start continues its globally paused current task")
        try await wait { !vm.queueRunning && vm.taskQueue.items.allSatisfy { !$0.resumable } }
        expect(ModelProbe.goals == ["A","B","B","C"], "After explicit resume the strict sequence is A, B, C; no selected item is moved to the front")
        expect(vm.taskQueue.items.map(\.id) == [a,b.id,c.id], "Completion preserves the original task identities/order")

        resetModel()
        let mutations = try make("mutations")
        var allowD = false, allowNative = false
        ModelProbe.onRequest = {
            let goal = ModelProbe.goals.last ?? ""
            while (goal == "D" && !allowD) || (goal == "NATIVE" && !allowNative) { try await Task.sleep(for: .milliseconds(1)) }
        }
        mutations.engine.start(task: "D", settings: mutations.settings)
        try await wait { ModelProbe.goals.contains("D") }
        let d = mutations.engine.currentRecord!.id, e = mutations.task("E"), f = mutations.task("F")
        try mutations.taskQueue.append(e); try mutations.taskQueue.append(f)
        var nativeConfig = mutations.settings; nativeConfig.toolsOnly = true; nativeConfig.systemToolsEnabled = true
        let native = AgentEngine(capture: CaptureService(), executor: mutations.engine.executor, ownsScreenInput: false)
        native.systemTool = { _, _ in "offline native receipt" }; native.start(task: "NATIVE", settings: nativeConfig)
        try await wait { ModelProbe.goals.contains("NATIVE") }
        let nativeSession = native.activityControlSessionID, dSession = mutations.engine.activityControlSessionID
        expect(mutations.startScreenQueue(), "A new FIFO run may coexist with an isolated native worker")
        expect(!mutations.removeScreenQueueTask(d), "Deleting the executing task requires precise termination first")
        expect(mutations.removeScreenQueueTask(e.id) && mutations.stopScreenQueueTask(f.id), "Future tasks may be removed or terminated while D runs")
        expect(mutations.history.records.first(where: { $0.id == e.id })?.summary.contains("尚未执行") == true, "A removed waiting task leaves a stopped history card instead of a dangling handoff")
        expect(mutations.engine.activityControlSessionID == dSession && native.activityControlSessionID == nativeSession && native.running, "Future mutations affect neither current input owner nor native workers")
        allowD = true
        try await wait { !mutations.queueRunning && mutations.engine.executionSettled }
        expect(!ModelProbe.goals.contains("E") && !ModelProbe.goals.contains("F"), "Removed and terminated items cannot execute through automatic advance")
        expect(native.running, "Finishing the screen queue leaves the independent native worker running")
        allowNative = true; try await wait { native.executionSettled }

        resetModel()
        let mixed = try make("mixed")
        let oldNative = mixed.task("OLD-NATIVE", toolsOnly: true), g = mixed.task("G"), h = mixed.task("H")
        try mixed.taskQueue.append(oldNative); try mixed.taskQueue.append(g); try mixed.taskQueue.append(h)
        expect(mixed.screenQueueWaiting.map(\.id) == [g.id,h.id], "Legacy tools-only queue entries are excluded from the screen queue")
        expect(mixed.reorderScreenQueueTasks([h.id,g.id]) && mixed.taskQueue.items.map(\.id) == [oldNative.id,h.id,g.id], "Screen-only drag reorders its subset without moving hidden legacy native entries")
        expect(mixed.startScreenQueue(), "A hidden legacy native item does not block starting the screen queue")
        try await wait { !mixed.queueRunning && mixed.engine.executionSettled }
        expect(ModelProbe.goals == ["H","G"] && mixed.taskQueue.items.first?.state == .waiting, "FIFO consumes only visible screen work and leaves legacy native state unchanged")
        var mainNativeConfig = mixed.settings; mainNativeConfig.toolsOnly = true; mainNativeConfig.systemToolsEnabled = true
        mixed.engine.systemTool = { _, _ in "offline" }; ModelProbe.delay = 1_000_000_000
        mixed.engine.start(task: "MAIN-NATIVE", settings: mainNativeConfig)
        let mainNativeSession = mixed.engine.activityControlSessionID
        try mixed.taskQueue.append(mixed.task("I"))
        expect(mixed.screenQueueCurrent == nil && !mixed.startScreenQueue() && mixed.engine.activityControlSessionID == mainNativeSession,
               "A legacy native task in the main engine is not shown or preempted as a screen task")
        mixed.engine.stop(); try await wait { mixed.engine.executionSettled }; ModelProbe.delay = 0

        resetModel()
        let restart = try make("restart")
        let held = restart.task("HELD", state: .paused), fresh = restart.task("FRESH")
        try restart.taskQueue.append(held); try restart.taskQueue.append(fresh)
        let loaded = try make("restart")
        expect(loaded.taskQueue.items[0].state == .paused && loaded.taskQueue.items[1].state == .suspended, "Manual per-item pause survives disk reload separately from restart review")
        expect(!loaded.startScreenQueue() && ModelProbe.calls == 0 && loaded.taskQueue.items[0].state == .paused,
               "Global start cannot clear a persisted individual hold")
        expect(loaded.resumeScreenQueueTask(held.id) && ModelProbe.calls == 0, "Item start restores only its place, not execution authority")
        expect(loaded.startScreenQueue(), "One explicit global start authorizes never-started queued work after restart")
        try await wait { !loaded.queueRunning && loaded.engine.executionSettled }
        expect(ModelProbe.goals == ["HELD","FRESH"], "Never-started restart items execute in saved order after one global start")

        // History failure after A completes must never be cleared by a later
        // successful queue write and permit B to start.
        resetModel()
        let historyFailure = try make("history-failure")
        var finishHistory = false
        ModelProbe.onRequest = { while !finishHistory { try await Task.sleep(for: .milliseconds(1)) } }
        historyFailure.engine.start(task: "HISTORY-A", settings: historyFailure.settings)
        try await wait { ModelProbe.calls == 1 }
        try historyFailure.taskQueue.append(historyFailure.task("HISTORY-B")); expect(historyFailure.startScreenQueue(), "History failure fixture starts with a persisted reservation")
        let historyURL = folder.appendingPathComponent("history-failure/history.json")
        try FileManager.default.removeItem(at: historyURL); try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: false)
        finishHistory = true
        try await wait { historyFailure.engine.executionSettled }
        expect(!historyFailure.queueRunning && !historyFailure.history.error.isEmpty && ModelProbe.goals == ["HISTORY-A"], "A history save failure blocks automatic dispatch of the next queued task")

        resetModel()
        let transient = try make("transient")
        var finishTransient = false
        ModelProbe.onRequest = { while !finishTransient { try await Task.sleep(for: .milliseconds(1)) } }
        transient.engine.start(task: "TRANSIENT-A", settings: transient.settings)
        try await wait { ModelProbe.calls == 1 }
        let future = transient.task("TRANSIENT-B"); try transient.taskQueue.append(future); expect(transient.startScreenQueue(), "Transient-write fixture starts running")
        let queueURL = folder.appendingPathComponent("transient/queue.json")
        let savedQueue = try Data(contentsOf: queueURL)
        try FileManager.default.removeItem(at: queueURL); try FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: false)
        expect(!transient.stopScreenQueueTask(future.id) && !transient.queueRunning && transient.engine.running, "A failed future-item mutation stops automatic advance without cancelling the current task")
        try FileManager.default.removeItem(at: queueURL); try savedQueue.write(to: queueURL)
        finishTransient = true; try await wait { transient.engine.executionSettled }
        expect(!ModelProbe.goals.contains("TRANSIENT-B") && !transient.queueRunning, "Recovering storage does not silently re-enable automatic advance after a failed stop")

        for stop in [false,true] {
            resetModel()
            let name = stop ? "unwritable-stop" : "unwritable-pause", active = try make(name)
            ModelProbe.delay = 1_000_000_000
            active.engine.start(task: name, settings: active.settings)
            try await wait { ModelProbe.calls == 1 }
            let currentID = active.engine.currentRecord!.id
            let brokenQueue = folder.appendingPathComponent(name + "/queue.json")
            try FileManager.default.createDirectory(at: brokenQueue, withIntermediateDirectories: false)
            let changed = stop ? active.stopScreenQueueTask(currentID) : active.pauseScreenQueueTask(currentID)
            expect(!changed && !active.engine.running && active.engine.currentRecord?.id == currentID,
                   "A queue write failure cannot prevent precise cancellation of the active screen task")
            try await wait { active.engine.executionSettled }
        }
        resetModel()
        print("ScreenTaskQueue: \(checks) checks passed. Actual complete VM queue extension, engine and stores; synthetic model/capture/BLE/UI, no phone execution.")
    }
}
