import Foundation

@main struct ConversationControlChecks {
    @MainActor static func main() async throws {
        var checks = 0, failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func drain() async { for _ in 0..<60 { await Task.yield() } }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<2000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw AgentError.message("Offline ownership gate did not open")
        }
        func vmWithTask(_ record: Record = Record()) -> PhoneAgentViewModel {
            let vm = PhoneAgentViewModel(); vm.engine.replace(record); vm.history.records = [record]
            vm.installRouteBridge(); return vm
        }
        func route(_ mode: ConversationRoute.Mode, id: UUID? = nil) -> ConversationRoute {
            .init(mode: mode, request: "只操作用户指定的任务", message: "收到请求", taskID: id)
        }
        func begin(_ vm: PhoneAgentViewModel) -> Task<ConversationRoute?, Never> {
            let input = try! ConversationRoutingInput(question: "对指定任务的明确操作", history: [],
                taskContext: vm.unifiedTaskContext(history: vm.conversation.messages), controlContext: vm.conversationControlContext, backgroundSessions: vm.backgroundTasks.sessions)
            return Task { try? await vm.conversation.unifiedRoute!(input) }
        }
        func finish(_ work: Task<ConversationRoute?, Never>, with result: ConversationRoute) async -> ConversationRoute? {
            let continuation = ControlRouteProbe.pending; ControlRouteProbe.pending = nil
            continuation!.resume(returning: result)
            return await work.value
        }
        func resolve(_ vm: PhoneAgentViewModel, _ result: ConversationRoute) async throws -> ConversationRoute? {
            let work = begin(vm); try await wait { ControlRouteProbe.pending != nil }
            return await finish(work, with: result)
        }
        let flightVM = vmWithTask()
        let retainedOffer = CtripFlightOffer(id: "retained", title: "CA1234", details: "出发时间：2026-10-27 15:00", price: "800元", bookingURL: nil,
            query: "2026-10-27上海到北京，直飞2人", queriedAt: Date())
        flightVM.conversation.messages = [.init(role: "assistant", text: "真实查询结果", flightOffers: [retainedOffer])] +
            (0..<14).map { .init(role: "user", text: "穿插聊天\($0)") }
        let flightWork = begin(flightVM)
        try await wait { ControlRouteProbe.pending != nil }
        expect(ControlRouteProbe.context.contains("CA1234") && ControlRouteProbe.context.contains("2026-10-27上海到北京"),
               "The production route bridge uses full current-conversation flight state even when recent input history is empty")
        _ = await finish(flightWork, with: .init(mode: .chat, request: "", message: ""))
        let preparingMemory = vmWithTask(), beforeMemory = begin(preparingMemory)
        preparingMemory.engine.replace(Record())
        try await wait { ControlRouteProbe.pending != nil }
        let afterMemory = await finish(beforeMemory, with: route(.stop))
        expect(afterMemory == nil && preparingMemory.effectCount == 0, "A task switch while preparing memory cannot transfer the submitted control to its replacement")
        let disabledMemory = vmWithTask()
        let oldConfiguration = ConversationRoutingConfiguration(connection: disabledMemory.settings.endpoint + "|offline-recipient",
            model: disabledMemory.settings.model, useMemories: true)
        let memoryInput = try ConversationRoutingInput(question: "继续", history: [], taskContext: "{}", memoryContext: "OLD-PRIVATE-MEMORY", configuration: oldConfiguration)
        let memoryResult = try? await disabledMemory.conversation.unifiedRoute!(memoryInput)
        expect(memoryResult == nil && ControlRouteProbe.pending == nil, "A memory switch during preparation rejects the old reference before any model request")
        let controls: [ConversationRoute.Mode] = [.supplement, .resume, .pause, .stop]
        for mode in controls {
            let original = Record(), replacement = Record(), vm = vmWithTask(original)
            let work = begin(vm); try await wait { ControlRouteProbe.pending != nil }
            expect(ControlRouteProbe.context.contains(original.id.uuidString), "Actual routing input contains the original task: \(mode)")
            vm.engine.replace(replacement)
            let result = await finish(work, with: route(mode))
            expect(result == nil, "Task changed during routing rejects the stale result: \(mode)")
            if let result { vm.handleConversationAction(result, messageID: UUID()) }
            await drain()
            expect(vm.effectCount == 0 && vm.conversation.links.isEmpty, "Late nil-ID control cannot affect or link the replacement: \(mode)")

            let stable = vmWithTask(original)
            let accepted = try await resolve(stable, route(mode))
            expect(accepted?.taskID == original.id, "Nil-ID control binds the task observed before routing: \(mode)")
            if let accepted { stable.handleConversationAction(accepted, messageID: UUID()) }
            await drain()
            let applied = mode == .resume ? stable.engine.resumedIDs == [original.id] : stable.actions.contains { $0.0 == mode.rawValue && $0.1 == original.id }
            expect(applied, "Same-task control still reaches its existing action: \(mode)")
            expect(stable.conversation.links.contains(original.id), "Accepted action links the original task: \(mode)")

            let gap = vmWithTask(original)
            let resolved = try await resolve(gap, route(mode))
            gap.engine.replace(replacement)
            if let resolved { gap.handleConversationAction(resolved, messageID: UUID()) }
            await drain()
            expect(gap.effectCount == 0 && gap.conversation.links.isEmpty, "Route-to-dispatch gap does not transfer control: \(mode)")
        }

        let changes: [(String, (PhoneAgentViewModel) -> Void)] = [
            ("same task changed execution", { $0.engine.activityControlSessionID = UUID() }),
            ("active task completed", { $0.engine.hasCurrentTask = false }),
            ("automatic preparation changed", { $0.automaticPreparationGeneration = UUID() }),
            ("voice preparation changed", { $0.voiceGeneration = UUID() }),
            ("queue operation changed", { $0.queueGeneration = UUID() }),
            ("manual operation changed and ended", { $0.manualBusy = true; $0.manualBusy = false }),
            ("calibration changed and ended", { $0.calibrating = true; $0.calibrating = false }),
            ("pending consent start changed and ended", { $0.setPendingConsent(true); $0.setPendingConsent(false) }),
            ("A to B to A", { vm in let old = vm.engine.currentRecord; vm.engine.replace(Record()); vm.engine.replace(old) }),
        ]
        for (label, change) in changes {
            let vm = vmWithTask(), work = begin(vm)
            try await wait { ControlRouteProbe.pending != nil }; change(vm)
            let result = await finish(work, with: route(.stop))
            if let result { vm.handleConversationAction(result, messageID: UUID()) }
            expect(result == nil && vm.effectCount == 0, "Changed control context rejects stale stop during routing: \(label)")
            let gap = vmWithTask(), resolved = try await resolve(gap, route(.stop))
            change(gap)
            if let resolved { gap.handleConversationAction(resolved, messageID: UUID()) }
            expect(gap.effectCount == 0, "Changed control context rejects stale stop after routing: \(label)")
        }

        for mode in [ConversationRoute.Mode.chat, .flightQuery, .task, .clarify] {
            let vm = vmWithTask(), work = begin(vm)
            try await wait { ControlRouteProbe.pending != nil }; vm.engine.replace(Record())
            let result = await finish(work, with: route(mode))
            expect(result?.mode == mode, "Task changes do not reject unrelated route mode: \(mode)")
        }
        let progressing = vmWithTask(), progressRoute = begin(progressing)
        try await wait { ControlRouteProbe.pending != nil }
        progressing.engine.currentRecord?.summary = "new observation"
        progressing.engine.currentRecord?.logs.append(.init(title: "观察", detail: "offline progress"))
        let progressResult = await finish(progressRoute, with: route(.pause))
        if let progressResult { progressing.handleConversationAction(progressResult, messageID: UUID()) }
        expect(progressing.actions.contains { $0.0 == "pause" }, "Ordinary same-execution progress does not invalidate a valid task control")
        let fresh = PhoneAgentViewModel(); fresh.installRouteBridge()
        if let result = try await resolve(fresh, route(.task)) { fresh.handleConversationAction(result, messageID: UUID()) }
        expect(fresh.actions.contains { $0.0 == "new" }, "New task still starts from idle")
        let enqueue = vmWithTask()
        if let result = try await resolve(enqueue, route(.task)) { enqueue.handleConversationAction(result, messageID: UUID()) }
        expect(enqueue.actions.contains { $0.0 == "enqueue" }, "A new request during an active task retains queue routing")

        for mode in [ConversationRoute.Mode.pause, .stop] {
            let waiting = PhoneAgentViewModel(); waiting.preparingAutomatically = true; waiting.installRouteBridge()
            if let result = try await resolve(waiting, route(mode)) { waiting.handleConversationAction(result, messageID: UUID()) }
            expect(waiting.actions.contains { $0.0 == mode.rawValue }, "No-record preparation can still be controlled: \(mode)")
            let idle = PhoneAgentViewModel(); idle.installRouteBridge(); let work = begin(idle)
            try await wait { ControlRouteProbe.pending != nil }; idle.engine.replace(Record())
            let result = await finish(work, with: route(mode))
            if let result { idle.handleConversationAction(result, messageID: UUID()) }
            expect(result == nil && idle.effectCount == 0, "Idle control cannot acquire a newly started task: \(mode)")
        }
        let alreadyCompleted = vmWithTask(); alreadyCompleted.engine.hasCurrentTask = false
        if let result = try await resolve(alreadyCompleted, route(.resume)) { alreadyCompleted.handleConversationAction(result, messageID: UUID()) }
        await drain()
        expect(alreadyCompleted.engine.resumedIDs.isEmpty, "Completed records are never silently resumed")
        for mode in [ConversationRoute.Mode.pause, .stop] {
            let inactive = vmWithTask(); inactive.engine.hasCurrentTask = false; inactive.preparingAutomatically = true
            let oldID = inactive.engine.currentRecord!.id
            if let result = try await resolve(inactive, route(mode, id: oldID)) { inactive.handleConversationAction(result, messageID: UUID()) }
            expect(inactive.effectCount == 0 && inactive.conversation.links.isEmpty, "An explicit inactive record does not authorize control of unrelated preparation: \(mode)")
        }

        let target = UUID(), queued = vmWithTask()
        queued.taskQueue.items = [.init(id: target)]
        if let result = try await resolve(queued, route(.resume, id: target)) { queued.handleConversationAction(result, messageID: UUID()) }
        expect(queued.actions.contains { $0.0 == "queue" && $0.1 == target } && queued.conversation.links == [target], "An explicit resumable queued target remains usable")
        for current in [false, true] {
            let archived = PhoneAgentViewModel(); archived.installRouteBridge()
            var failed = Record(); failed.outcome = .failed
            archived.history.records = [failed]
            archived.conversation.messages = [.init(role: "assistant", text: "先前的联系人查询", taskID: failed.id)]
            if current { archived.engine.replace(failed, active: false) }
            if let result = try await resolve(archived, route(.resume, id: failed.id)) { archived.handleConversationAction(result, messageID: UUID()) }
            expect(archived.actions.contains { $0.0 == "history" && $0.1 == failed.id } && archived.conversation.links == [failed.id], "Explicit continuation reaches guarded failed-history recovery after relaunch or inactive current record: \(current)")
        }
        for restriction in ["unreferenced", "completed", "guard blocked", "other active", "nonresumable queue"] {
            let archived = PhoneAgentViewModel(); archived.installRouteBridge()
            var failed = Record(); failed.outcome = restriction == "completed" ? .completed : .failed
            archived.history.records = [failed]
            if restriction != "unreferenced" { archived.conversation.messages = [.init(role: "assistant", text: "先前任务", taskID: failed.id)] }
            if restriction == "guard blocked" { archived.historicalRecoveryAllowed = false }
            if restriction == "other active" { archived.engine.replace(Record()) }
            if restriction == "nonresumable queue" { archived.taskQueue.items = [.init(id: failed.id, resumable: false)] }
            if let result = try await resolve(archived, route(.resume, id: failed.id)) { archived.handleConversationAction(result, messageID: UUID()) }
            expect(archived.actions.isEmpty && archived.conversation.links.isEmpty, "Historical continuation preserves selection, completion, queue and recovery guards: \(restriction)")
        }
        for absent in [false, true] {
            let unavailable = vmWithTask(); unavailable.taskQueue.items = absent ? [] : [.init(id: target, resumable: false)]
            if let result = try await resolve(unavailable, route(.resume, id: target)) { unavailable.handleConversationAction(result, messageID: UUID()) }
            expect(unavailable.effectCount == 0, "Explicit queued target must still exist and be resumable: absent=\(absent)")
        }
        for mode in [ConversationRoute.Mode.supplement, .pause, .stop] {
            let wrong = vmWithTask()
            if let result = try await resolve(wrong, route(mode, id: target)) { wrong.handleConversationAction(result, messageID: UUID()) }
            expect(wrong.effectCount == 0, "Explicit wrong task ID is never rebound to current: \(mode)")
        }
        for mode in controls {
            let unbound = vmWithTask()
            unbound.handleConversationAction(route(mode, id: unbound.engine.currentRecord!.id), messageID: UUID())
            await drain()
            expect(unbound.effectCount == 0, "An unbound control cannot bypass local ownership: \(mode)")
        }

        // The child continuation is deferred; replace state without yielding first.
        for mode in [ConversationRoute.Mode.supplement, .resume] {
            let vm = vmWithTask()
            if let result = try await resolve(vm, route(mode)) { vm.handleConversationAction(result, messageID: UUID()) }
            let haltsBeforeReplacement = vm.halts
            vm.engine.replace(Record()); await drain()
            expect(vm.engine.resumedIDs.isEmpty && vm.halts == haltsBeforeReplacement, "Deferred \(mode) resume cannot halt or resume a replacement task")
            let superseded = vmWithTask()
            if let result = try await resolve(superseded, route(mode)) { superseded.handleConversationAction(result, messageID: UUID()) }
            let initialHalts = superseded.halts
            superseded.queueGeneration = UUID()
            await drain()
            expect(superseded.engine.resumedIDs.isEmpty && superseded.halts == initialHalts, "A newer pause or queue decision wins over a deferred \(mode) resume")
        }

        for change in ["replacement", "same-ID new session", "queue", "cancel", "none"] {
            let vm = vmWithTask(), original = vm.engine.currentRecord!
            vm.engine.releasing = true
            let resume = Task { await vm.resumeVoiceTask() }
            try await wait { vm.halts == 1 }
            switch change {
            case "replacement": vm.engine.replace(Record())
            case "same-ID new session": vm.engine.replace(original)
            case "queue": vm.queueGeneration = UUID()
            case "cancel": resume.cancel()
            default: break
            }
            vm.engine.releasing = false
            _ = await resume.value
            expect(change == "none" ? vm.engine.resumedIDs == [original.id] : vm.engine.resumedIDs.isEmpty, "Resume wait preserves execution ownership: \(change)")
            if change != "none" {
                expect(vm.speech.cancellations == 0 && vm.conversation.cancellations == 0, "Stale/cancelled wait leaves the newer conversation and audio alone: \(change)")
            }
        }
        let notReady = vmWithTask(); notReady.preparationReady = false
        _ = await notReady.resumeVoiceTask()
        expect(notReady.showPreparation && notReady.engine.resumedIDs.isEmpty, "Existing resume readiness check remains in force")
        let manual = vmWithTask(); manual.manualContinuationRequired = true
        _ = await manual.resumeVoiceTask()
        expect(manual.halts == 0 && manual.engine.resumedIDs.isEmpty, "Existing saved-workflow continuation restriction remains in force")
        let canceled = vmWithTask(), pending = begin(canceled)
        try await wait { ControlRouteProbe.pending != nil }; pending.cancel()
        let canceledResult = await finish(pending, with: route(.stop))
        expect(canceledResult == nil && canceled.effectCount == 0, "Canceled routing cannot acquire control")

        let owned = vmWithTask(), ownedResult = try await resolve(owned, route(.stop))!
        let encoded = try JSONEncoder().encode(ownedResult)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        expect(Set(object.keys) == Set(["mode", "request", "message", "taskID"]), "Process-local control ownership is excluded from encoded route JSON")
        var injected = object
        injected["controlContext"] = ["taskID": owned.engine.currentRecord!.id.uuidString]
        let decoded = try JSONDecoder().decode(ConversationRoute.self, from: JSONSerialization.data(withJSONObject: injected))
        owned.handleConversationAction(decoded, messageID: UUID())
        expect(owned.effectCount == 0, "Decoded or model-injected JSON cannot restore action authority")
        expect(ControlRouteProbe.pending == nil, "All synthetic route gates were drained")
        let acceptedTask = PhoneAgentViewModel(), acceptedMessage = UUID()
        acceptedTask.handleConversationAction(.init(mode: .task, request: "打开时钟", message: "已经开始"), messageID: acceptedMessage)
        expect(acceptedTask.actions.map(\.0) == ["new"] && acceptedTask.conversation.handoffs[acceptedMessage]?.contains("已交给执行器") == true,
               "Accepted new handoff reports executor receipt without pretending it already ran")
        let queuedTask = vmWithTask(), queuedMessage = UUID()
        queuedTask.goal = "用户正在编辑的另一项新任务"
        queuedTask.handleConversationAction(.init(mode: .task, request: "创建闹钟", message: "已创建"), messageID: queuedMessage)
        expect(queuedTask.actions.map(\.0) == ["enqueue"] && queuedTask.conversation.linkedMessages[queuedMessage] == queuedTask.taskQueue.items.last?.id,
               "Queued handoff links its actual queue ID")
        expect(queuedTask.conversation.handoffs[queuedMessage]?.contains("已加入任务队列，尚未开始执行") == true,
               "Enqueue acknowledgement distinguishes queued from executing")
        expect(queuedTask.goal == "用户正在编辑的另一项新任务", "A late screen route cannot overwrite or clear the user's new task draft")
        let idleDraft = PhoneAgentViewModel(), idleDraftMessage = UUID()
        idleDraft.goal = "新会话里尚未发送的草稿"
        idleDraft.handleConversationAction(.init(mode: .task, request: "迟到路由的屏幕任务", message: "开始"), messageID: idleDraftMessage)
        expect(idleDraft.goal == "新会话里尚未发送的草稿" && idleDraft.actions.map(\.0) == ["enqueue"],
               "Even an idle screen executor queues a late task while preserving a newer unsent draft")
        let rejectedQueue = vmWithTask(), rejectedQueueMessage = UUID(); rejectedQueue.enqueueAllowed = false
        rejectedQueue.handleConversationAction(.init(mode: .task, request: "创建闹钟", message: "开始"), messageID: rejectedQueueMessage)
        expect(rejectedQueue.actions.isEmpty && rejectedQueue.conversation.handoffs[rejectedQueueMessage]?.contains("也未加入队列") == true,
               "Queue rejection produces an explicit not-started result")
        for (name, busy) in [("preparing", { (vm: PhoneAgentViewModel) in vm.preparingAutomatically = true }),
                             ("switching", { (vm: PhoneAgentViewModel) in vm.queueSwitching = true }),
                             ("manual", { (vm: PhoneAgentViewModel) in vm.manualBusy = true }),
                             ("calibrating", { (vm: PhoneAgentViewModel) in vm.calibrating = true }),
                             ("releasing", { (vm: PhoneAgentViewModel) in vm.engine.releasing = true })] {
            let blocked = PhoneAgentViewModel(), message = UUID(); busy(blocked)
            blocked.handleConversationAction(.init(mode: .task, request: "打开时钟", message: "已开始"), messageID: message)
            expect(blocked.actions.isEmpty && blocked.conversation.handoffs[message]?.contains("任务未启动") == true,
                   "Busy \(name) path cannot leave a model execution promise")
        }
        let missingModel = PhoneAgentViewModel(), missingModelMessage = UUID(); missingModel.startAllowed = false
        missingModel.handleConversationAction(.init(mode: .task, request: "打开时钟", message: "正在执行"), messageID: missingModelMessage)
        expect(missingModel.actions.isEmpty && missingModel.conversation.handoffs[missingModelMessage]?.contains("offline model unavailable") == true,
               "Start rejection retains the actual host preparation reason")
        let preparingTask = PhoneAgentViewModel(), preparingMessage = UUID(); preparingTask.prepareOnStart = true
        preparingTask.handleConversationAction(.init(mode: .task, request: "打开时钟", message: "已开始"), messageID: preparingMessage)
        expect(preparingTask.conversation.handoffs[preparingMessage]?.contains("正在准备设备，任务尚未开始") == true,
               "Preparation handoff is explicitly waiting, not started")
        let consentTask = PhoneAgentViewModel(), consentMessage = UUID(); consentTask.requireConsentOnStart = true
        consentTask.handleConversationAction(.init(mode: .task, request: "打开时钟", message: "已开始"), messageID: consentMessage)
        expect(consentTask.conversation.handoffs[consentMessage]?.contains("等待已有的数据使用授权") == true,
               "Existing consent handoff is explicit and does not imply tool execution")
        let waitingSubmission = consentTask.pendingConversationTask, secondConsentMessage = UUID()
        consentTask.handleConversationAction(.init(mode: .task, request: "创建另一个闹钟", message: "已开始"), messageID: secondConsentMessage)
        expect(consentTask.pendingConversationTask == waitingSubmission && consentTask.actions.isEmpty &&
               consentTask.conversation.handoffs[secondConsentMessage]?.contains("上一条执行请求") == true,
               "A second request cannot replace the origin awaiting existing data authorization")
        let emptyTask = PhoneAgentViewModel(), emptyTaskMessage = UUID()
        emptyTask.handleConversationAction(.init(mode: .task, request: "", message: "开始"), messageID: emptyTaskMessage)
        expect(emptyTask.actions.isEmpty && emptyTask.conversation.handoffs[emptyTaskMessage]?.contains("任务内容为空") == true,
               "An empty task request has a concrete rejection rather than an action promise")
        let nativeVM = vmWithTask(), nativeMessage = UUID(), nativeOrigin = UUID()
        var nativeRoute = ConversationRoute(mode: .task, request: "独立查询已授权联系人", message: "开始", execution: .native)
        nativeRoute.originConversationID = nativeOrigin
        nativeVM.preparingAutomatically = true; nativeVM.engine.running = true
        nativeVM.handleConversationAction(nativeRoute, messageID: nativeMessage)
        let nativeID = nativeVM.backgroundTasks.records[0].id
        expect(nativeVM.backgroundTasks.origins[nativeID]?.conversationID == nativeOrigin && nativeVM.actions.isEmpty,
               "Native handoff preserves original conversation and starts independently while screen execution/preparation continues")
        expect(nativeVM.conversation.linkedMessages[nativeMessage] == nativeID && nativeVM.pendingConversationTask == nil,
               "Native task receives its own card without replacing the pending screen submission")
        for _ in 0..<3 { _ = try nativeVM.backgroundTasks.submit(goal: "another worker", settings: nativeVM.settings, attachments: [], reference: "", origin: .init(conversationID: UUID(), messageID: UUID())) }
        let nativeContext = nativeVM.unifiedTaskContext(history: [])
        expect(nativeVM.backgroundTasks.records.allSatisfy { nativeContext.contains($0.id.uuidString) } && nativeContext.contains(nativeVM.engine.currentRecord!.id.uuidString),
               "All workers and the screen task retain IDs in routing context, including more than three tasks")
        let contextBudget = vmWithTask()
        let hugeReference = String(repeating: "😀\\\"罕见资料", count: 4000)
        for _ in 0..<20 { _ = try contextBudget.backgroundTasks.submit(goal: hugeReference, settings: contextBudget.settings, attachments: [], reference: hugeReference, origin: .init(conversationID: UUID(), messageID: UUID())) }
        contextBudget.conversation.messages = [.init(role: "assistant", text: "候选参考", flightOffers: (0..<24).map { index in
            CtripFlightOffer(id: "budget-\(index)", title: "CA\(1000 + index)" + hugeReference, details: hugeReference,
                             price: "待核对", bookingURL: nil, query: hugeReference, queriedAt: Date())
        })]
        let boundedContext = contextBudget.unifiedTaskContext(history: contextBudget.conversation.messages)
        let boundedObject = try JSONSerialization.jsonObject(with: Data(boundedContext.utf8)) as! [String: Any]
        expect(boundedContext.utf8.count <= 64_000 && (boundedObject["flightOffers"] as? [[String: Any]])?.count == 24,
               "Twenty workers plus 24 large escaped/Unicode flight references fit the context byte budget without losing card positions")
        expect(contextBudget.backgroundTasks.records.allSatisfy { boundedContext.contains($0.id.uuidString) },
               "Budget compaction never drops an active or queued task ID")
        expect(boundedObject["contextDetailsOmitted"] as? Bool == true, "Context explicitly reports omitted details")
        let workerStop = begin(nativeVM)
        try await wait { ControlRouteProbe.pending != nil }
        // Another worker and the main screen task change while this command resolves.
        nativeVM.engine.replace(Record())
        nativeVM.backgroundTasks.sessions[nativeVM.backgroundTasks.records[1].id] = UUID()
        let workerAccepted = await finish(workerStop, with: route(.stop, id: nativeID))
        expect(workerAccepted?.backgroundControlToken == nativeVM.backgroundTasks.token(nativeID),
               "Control binds only the selected worker token despite unrelated worker/screen changes")
        if let workerAccepted { nativeVM.handleConversationAction(workerAccepted, messageID: UUID()) }
        expect(nativeVM.backgroundTasks.actions.last?.0 == "stop" && nativeVM.backgroundTasks.actions.last?.1 == nativeID && nativeVM.actions.isEmpty,
               "Worker stop affects exactly its own task")
        let stableWorker = nativeVM.backgroundTasks.records[2].id
        let staleWorker = begin(nativeVM)
        try await wait { ControlRouteProbe.pending != nil }
        nativeVM.backgroundTasks.sessions[stableWorker] = UUID()
        let workerRejected = await finish(staleWorker, with: route(.pause, id: stableWorker))
        expect(workerRejected == nil, "A changed selected-worker token rejects stale control")
        let ambiguousWorker = try await resolve(nativeVM, route(.stop))
        expect(ambiguousWorker == nil, "A targetless command with multiple tasks cannot silently stop the screen task")
        let disabledNative = PhoneAgentViewModel(); disabledNative.settings.systemToolsEnabled = false
        disabledNative.handleConversationAction(nativeRoute, messageID: UUID())
        expect(disabledNative.backgroundTasks.records.isEmpty, "A native routing hint cannot grant system-tool permission")
        let report: [String: Any] = ["checks": checks, "failures": failures,
            "scope": "Unchanged extracted route closure, context/action/resume methods and interaction observers; synthetic engine/queue/audio/router; no model/network/phone"]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(String(decoding: bytes, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
