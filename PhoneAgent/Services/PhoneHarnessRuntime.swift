import Foundation
#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif
import Vision

/// Native OCR and verified layout memory execute small UI workflows without a
/// remote model round trip for every tap or keystroke.
@MainActor
final class PhoneHarnessRuntime: PhoneHarnessDriving {
    private static let recognitionTimingNote = "OCR completed records recognition return only; post-recognition binding checks determine whether results are accepted."
    private let executor: MouseExecutor
    var metrics: RunMetricsRecorder?
    var taskScopeID: UUID?
    var savedWorkflow: ((PhoneHarnessRequest, ScreenFrame, @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt)?
    var externalPendingReview: (() -> Bool)?
    var savedWorkflowContext: (() -> String)?
    var observationRecorder: ((ScreenFrame, PhoneUISnapshot) -> Void)?
    var pendingWorkflowRecords: [PhoneWorkflowRecord] { workflows.records.filter { $0.stage != .observedOnce && $0.stage != .reviewedByUser } }
    var hasPendingReview: Bool { !workflowStorageUsable || !pendingWorkflowRecords.isEmpty || externalPendingReview?() == true }
    private var requiresUserReview = false
    private var executionFrameIdentity: (UUID?, Int, Int, Int, Int)?
    private let workflowURL: URL
    private var workflows = PhoneWorkflowJournal()
    private var workflowStorageUsable = true
    private var allowsReceiptReuse = true
    private var memory: PhoneLayoutMemory
    private let memoryURL: URL
    private var cachedFrame: HarnessObservationKey?
    private var cachedObservationProof: WorkflowObservationProof?
    private var workflowTitleProof: WorkflowObservationProof?
    private var observationGeneration = UUID()
    private var workflowTitleCache: (key: HarnessObservationKey, recognized: [PhoneUIElement])?
    private var executionAccessory: String?
    private var executionBinding: (connection: UUID, runtime: UUID)?
    private var executionObservationLease: WorkflowObservationLease?
    private var cachedSnapshot: PhoneUISnapshot?
    private var modelSnapshot: (capture: UUID?, snapshot: PhoneUISnapshot)?
    private var pendingLearning: (String, PhoneUIElement, PhoneUISnapshot, Date)?
    private var focusSelection: UUID?
    private var focusEstablishedAt = Date.distantPast
    private var lastFallback = ""
    private var lastInputCompletedAt: Date?
    private var lastObservedFrame: ScreenFrame?
    private var searchCheckpointFact: TaskCheckpointFact?
    private var searchCheckpointFrame: ScreenFrame?
    private var searchCheckpointBinding: (device: String?, connection: UUID, runtime: UUID)?
    var checkpointRuntimeGeneration: UUID? { observationGeneration }
    private let recognize: ((ScreenFrame) async throws -> [PhoneUIElement])?
    private let recognizeWorkflowTitle: ((ScreenFrame) async throws -> [PhoneUIElement])?
    private let contextCurrent: WorkflowObservationLease.Current?

    init(executor: MouseExecutor, memoryURL: URL? = nil,
         recognize: ((ScreenFrame) async throws -> [PhoneUIElement])? = nil,
         recognizeWorkflowTitle: ((ScreenFrame) async throws -> [PhoneUIElement])? = nil,
         contextCurrent: WorkflowObservationLease.Current? = nil) {
        self.executor = executor
        self.recognize = recognize
        self.recognizeWorkflowTitle = recognizeWorkflowTitle
        self.contextCurrent = contextCurrent
        self.memoryURL = memoryURL ?? URL.documentsDirectory.appendingPathComponent("phone-layout-memory.json")
        workflowURL = self.memoryURL.deletingPathExtension().appendingPathExtension("workflows.json")
        if FileManager.default.fileExists(atPath: workflowURL.path) {
            if let data = try? Data(contentsOf: workflowURL), let journal = try? JSONDecoder().decode(PhoneWorkflowJournal.self, from: data), journal.version == 3,
               Set(journal.records.map(\.operationID)).count == journal.records.count {
                workflows = journal
            } else { workflowStorageUsable = false }
        }
        memory = (try? Data(contentsOf: self.memoryURL)).flatMap { try? JSONDecoder().decode(PhoneLayoutMemory.self, from: $0) } ?? PhoneLayoutMemory()
    }

    func reset() {
        pendingLearning = nil; focusSelection = nil; focusEstablishedAt = .distantPast
        cachedFrame = nil; cachedSnapshot = nil; modelSnapshot = nil; lastFallback = ""
        observationGeneration = UUID(); workflowTitleCache = nil
        cachedObservationProof = nil; workflowTitleProof = nil
        lastInputCompletedAt = nil; lastObservedFrame = nil; searchCheckpointFact = nil; searchCheckpointFrame = nil; searchCheckpointBinding = nil
    }

    func context(for frame: ScreenFrame) async throws -> String {
        let generation = observationGeneration
        let observationIdentity = HarnessObservationKey(frame: frame, selectedDevice: executor.ble.selectedID)
        let lease: WorkflowObservationLease?
        if let contextCurrent, executor.ble.ready, let selected = executor.ble.selectedID, !selected.isEmpty {
            try Task.checkCancellation(); try requireActiveFrame(frame)
            lease = try WorkflowObservationLease.contextFrame(frame, runtimeGeneration: generation,
                selectedDeviceID: selected, connectionGeneration: executor.ble.pointerConnectionGeneration, current: contextCurrent)
            try measureObservationBinding(frame, identity: observationIdentity, generation: generation,
                label: "harness.context-lease-binding", lease: lease)
        } else { lease = nil }
        let snapshot = try await observe(frame, lease: lease)
        if let lease {
            try measureObservationBinding(frame, identity: observationIdentity, generation: generation,
                label: "harness.context-lease-binding", lease: lease)
        }
        let items = snapshot.elements.prefix(48).map { ["id": $0.id, "label": String($0.label.prefix(90)), "source": $0.source] }
        let identity = PhonePageAdapters.identity(in: snapshot)
        let pending = pendingWorkflowRecords.suffix(8).map {
            ["operation_id": $0.operationID, "stage": $0.stage.rawValue, "status": "pending_review_do_not_replay"]
        }
        let object: [String: Any] = ["scene": snapshot.scene, "device": snapshot.deviceKey,
            "blocked": snapshot.blockingOverlay, "elements": items,
            "remembered_search": memory.control(named: "home.search", in: snapshot) != nil,
            "remembered_back": memory.control(named: "navigation.back", in: snapshot) != nil,
            "keyboard_ready": executor.ble.keyboardReady,
            "keyboard_focus_confirmed": executor.ble.keyboardReady && (keyboardVisible(snapshot) || trustedSearchFocus(frame, snapshot: snapshot)),
            "last_fallback": lastFallback,
            "page_identity_evidence": identity?.evidence ?? [],
            "page_identity_basis": identity == nil ? "unknown" : "current_ocr_structure_not_device_acceptance",
            "workflow_pending": pending,
            "workflow_storage_ready": workflowStorageUsable,
            "saved_workflows": savedWorkflowContext?() ?? "{}"]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if let lease {
            try measureObservationBinding(frame, identity: observationIdentity, generation: generation,
                label: "harness.context-lease-binding", lease: lease)
        }
        modelSnapshot = (frame.captureID, snapshot)
        return String(decoding: data, as: UTF8.self)
    }
    /// Used by the single active workflow controller. It shares real-frame OCR
    /// and never accepts model-supplied text as a live observation.
    func workflowSnapshot(_ frame: ScreenFrame, allowingMenu: ((PhoneUISnapshot) -> Bool)? = nil) async throws -> PhoneUISnapshot {
        try await workflowSnapshot(frame, allowingMenu: allowingMenu, lease: nil)
    }

    /// Workflow-only paired observation. Snapshot-only calls and context
    /// without an admitted current provider retain strict caller-frame semantics.
    func workflowObservation(_ frame: ScreenFrame, after: Date, current: @escaping WorkflowObservationLease.Current,
                             allowingMenu: ((PhoneUISnapshot) -> Bool)? = nil) async throws -> WorkflowObservationPair {
        try Task.checkCancellation(); try requireActiveFrame(frame)
        let generation = observationGeneration
        let identity = HarnessObservationKey(frame: frame, selectedDevice: executor.ble.selectedID)
        let lease = try WorkflowObservationLease(frame: frame, after: after, runtimeGeneration: generation,
            selectedDeviceID: executor.ble.selectedID, connectionGeneration: executor.ble.pointerConnectionGeneration,
            current: current)
        try measureObservationBinding(frame, identity: identity, generation: generation,
            label: "harness.workflow-lease-binding", lease: lease)
        let snapshot = try await workflowSnapshot(frame, allowingMenu: allowingMenu, lease: lease)
        // Includes cache hits, title additions and the synchronous menu policy.
        try measureObservationBinding(frame, identity: identity, generation: generation,
            label: "harness.workflow-lease-binding", lease: lease)
        return WorkflowObservationPair(snapshot: snapshot, lease: lease)
    }

    /// Recheck the same operation-local lease after the caller's await resumes.
    /// A reset or new pixel delivered before that continuation cannot escape.
    func confirmWorkflowObservation(_ observation: WorkflowObservationPair) throws -> ScreenFrame {
        let validate = {
            let current = try observation.lease.advance(runtimeGeneration: self.observationGeneration)
            try self.requireActiveFrame(current)
            return current
        }
        if let metrics { return try metrics.measure(.verification, label: "harness.workflow-lease-binding", validate) }
        return try validate()
    }

    /// Binding portion only; the driver independently checks current pixels,
    /// its non-regressing confirmation floor, age, capture and calibration.
    func workflowProofBindingFailures(_ proof: WorkflowObservationProof) -> [WorkflowLeaseFailure.Predicate] {
        proof.bindingFailures(runtimeGeneration: observationGeneration, selectedDeviceID: executor.ble.selectedID,
            connectionGeneration: executor.ble.pointerConnectionGeneration)
    }

    private func workflowSnapshot(_ frame: ScreenFrame, allowingMenu: ((PhoneUISnapshot) -> Bool)?,
                                  lease: WorkflowObservationLease?) async throws -> PhoneUISnapshot {
        let generation = observationGeneration
        let identity = HarnessObservationKey(frame: frame, selectedDevice: executor.ble.selectedID)
        let proof = WorkflowObservationProof(frame: frame, runtimeGeneration: generation,
            selectedDeviceID: executor.ble.selectedID, connectionGeneration: executor.ble.pointerConnectionGeneration)
        var observed = try await observe(frame, lease: lease)
        try measureObservationBinding(frame, identity: identity, generation: generation, label: "harness.workflow-frame-binding", lease: lease)
        if WeChatBuiltinWorkflowTitleOCR.isCandidate(observed), let image = frame.image.cgImage {
            let recognized: [PhoneUIElement]
            if identity.canCache, workflowTitleCache?.key == identity, let cached = workflowTitleCache,
               lease.map({ workflowTitleProof?.matches($0.proof) == true }) ?? true {
                recognized = cached.recognized
            } else {
                let recorder = metrics
                recorder?.note(Self.recognitionTimingNote)
                let ocrToken = recorder?.begin(.ocr, label: "harness.workflow-title")
                do {
                if let recognizeWorkflowTitle { recognized = try await recognizeWorkflowTitle(frame) }
                else { recognized = try await Task.detached(priority: .userInitiated) {
                    try WeChatBuiltinWorkflowTitleOCR.recognize(in: image)
                }.value }
                if let ocrToken { recorder?.end(ocrToken) }
                } catch {
                    if let ocrToken { recorder?.end(ocrToken, outcome: error is CancellationError ? .cancelled : .failed) }
                    throw error
                }
                try measureObservationBinding(frame, identity: identity, generation: generation, label: "harness.workflow-title-binding", lease: lease)
                workflowTitleCache = identity.canCache ? (identity, recognized) : nil
                workflowTitleProof = identity.canCache ? proof : nil
            }
            let additions = WeChatBuiltinWorkflowTitleOCR.uniqueAddition(recognized, to: observed).map { element -> PhoneUIElement in
                var bound = element
                bound.id = "ocr.workflow-title." + Self.labelKey("\(frame.captureID?.uuidString ?? "none")|\(frame.capturedAt.timeIntervalSinceReferenceDate.bitPattern)|\(element.id)|\(element.label)")
                return bound
            }
            if !additions.isEmpty { observed.elements += additions; observed.scene = classify(observed) }
        }
        guard observed.blockingOverlay, let allowingMenu,
              !PhoneOverlayClassifier.evaluate(elements: observed.elements,
                  raster: frame.image.cgImage.flatMap { PhoneRasterEvidence.raster($0) }, ignoringMenuCancel: true).blocking else { return observed }
        var candidate = observed
        candidate.blockingOverlay = false
        guard allowingMenu(candidate) else { return observed }
        candidate.scene = classify(candidate)
        return candidate // domain-only copy; generic GUI cache stays blocked
    }

    func didExecute(_ action: AgentAction, frame: ScreenFrame) async {
        guard action.kind == .tap, let x = action.x, let y = action.y,
              let snapshot = try? await observe(frame), !snapshot.blockingOverlay else { return }
        let name: String
        if snapshot.scene == "home", let search = searchElement(snapshot), contains(search.rect, x: x, y: y) {
            pendingLearning = ("home.search", search, snapshot, Date()); return
        } else if snapshot.scene.hasPrefix("settings."), x < 0.25, (0.035...0.15).contains(y) {
            name = "navigation.back"
        } else { return }
        // The point only becomes remembered after a later local observation
        // proves the expected page transition. Dispatch is not success.
        let element = PhoneUIElement(id: "verified.back", label: "返回", rect: PhoneUIRect(
            x: max(0, x - 0.015), y: max(0, y - 0.012), width: 0.03, height: 0.024), source: "learned")
        var source = snapshot; source.elements.append(element)
        pendingLearning = (name, element, source, Date())
    }

    func execute(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt {
        lastInputCompletedAt = nil; lastObservedFrame = nil; searchCheckpointFact = nil; searchCheckpointFrame = nil; allowsReceiptReuse = true
        searchCheckpointBinding = (executor.ble.selectedID, executor.ble.pointerConnectionGeneration, observationGeneration)
        executionAccessory = executor.ble.selectedID
        executionBinding = (executor.ble.pointerConnectionGeneration, observationGeneration)
        executionObservationLease = nil
        executionFrameIdentity = (frame.captureID, frame.width, frame.height, frame.sourceWidth, frame.sourceHeight)
        requiresUserReview = hasPendingReview
        defer {
            executionAccessory = nil; executionFrameIdentity = nil
            executionBinding = nil; executionObservationLease = nil
        }
        if request.operation.isSavedWorkflow {
            try request.validate()
            guard (!hasPendingReview || request.operation == .file_status), let savedWorkflow else { throw fallback("流程尚未配置或存在待核验提交，请先到记录与文件查看") }
            return try await savedWorkflow(request, frame, nextFrame)
        }
        let summary = try await executeSummary(request, frame: frame, mappedHome: mappedHome, nextFrame: nextFrame)
        let verified = lastObservedFrame.flatMap { observed in
            allowsReceiptReuse && lastInputCompletedAt.map { observed.confirmedAt > $0 } == true ? observed : nil
        }
        return PhoneHarnessReceipt(summary: summary, verifiedFrame: verified, lastInputCompletedAt: lastInputCompletedAt,
            requiresUserReview: requiresUserReview, checkpointFact: searchCheckpointFact, checkpointFrame: searchCheckpointFrame)
    }

    private func executeSummary(_ request: PhoneHarnessRequest, frame: ScreenFrame, mappedHome: Bool,
                                nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> String {
        try request.validate(); try Task.checkCancellation()
        lastFallback = ""
        if hasPendingReview, request.operation != .wechat_send { throw fallback("既有业务输入/提交结果待人工核验，已禁止其他 GUI 操作绕过回执") }
        let snapshot = try await observe(frame)
        guard !snapshot.blockingOverlay else { throw fallback("当前有遮挡或系统确认窗口，改用当前画面处理") }
        _ = try executor.validateCalibration(frame: frame)
        switch request.operation {
        case .xhs_collect, .chat_read, .chat_read_newer, .chat_summarize, .file_status, .file_send:
            throw fallback("已保存流程必须通过工作台控制器执行")
        case .wechat_send:
            return try await sendSelfMessage(request, frame: frame, snapshot: snapshot, nextFrame: nextFrame)
        case .open_search:
            if snapshot.scene == "search" {
                searchCheckpointFact = checkpointFact(frame, snapshot: snapshot, source: .alreadyVisible, inputCompletedAt: nil)
                searchCheckpointFrame = frame
                return "本地确认搜索页面已打开；尚未输入或提交"
            }
            let (fresh, after) = try await openSearch(frame, snapshot: snapshot, nextFrame: nextFrame)
            searchCheckpointFact = checkpointFact(fresh, snapshot: after, source: .afterInput, inputCompletedAt: lastInputCompletedAt)
            searchCheckpointFrame = fresh
            return "已由本地布局打开搜索，并确认进入搜索页面"
        case .open_app:
            return try await openApp(request.target!, frame: frame, snapshot: snapshot, mappedHome: mappedHome, nextFrame: nextFrame)
        case .tap:
            let rebound = modelSnapshot.flatMap { prior in
                prior.capture == frame.captureID ? snapshot.reidentifiedElement(request.target!, from: prior.snapshot) : nil
            }
            guard let element = snapshot.element(id: request.target!) ?? snapshot.matchingLabel(request.target!) ?? rebound else {
                throw fallback("目标元素不存在或标签不唯一，请使用本轮元素 ID 或重新观察")
            }
            try await tap(element, frame: frame)
            let fresh = try await checkedNextFrame(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame)
            let after = try await observe(fresh)
            try requireUnobstructed(after)
            return "已点击当前元素 \(element.id)；当前本地页面为 \(after.scene)，需按实际画面核对业务结果"
        case .back:
            let element: PhoneUIElement
            if let visible = backElement(snapshot) { element = visible }
            else if let saved = memory.control(named: "navigation.back", in: snapshot) {
                element = PhoneUIElement(id: "navigation.back", label: saved.label, rect: saved.rect, source: "learned")
            }
            else { throw fallback("此页的返回入口尚未学习，先由模型定位一次，成功返回后会自动记住") }
            try await tap(element, frame: frame)
            guard let (_, after) = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame, matching: {
                $0.scene != snapshot.scene && ($0.scene == "settings" || $0.scene.hasPrefix("settings."))
            }) else {
                forget("navigation.back", snapshot: snapshot)
                throw fallback("返回后的页面尚未确认，已停用本页返回记忆；从新画面继续")
            }
            remember("navigation.back", element: element, source: snapshot, destination: after)
            return "本地返回已核实：\(snapshot.scene) → \(after.scene)"
        case .home:
            guard mappedHome else { throw fallback("当前配件未确认主屏幕中键映射，请用可见辅助触控菜单返回") }
            try await primitive(.press_key, text: "home", frame: frame, mappedHome: true)
            guard try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame,
                matching: { $0.scene == "home" }) != nil else {
                throw fallback("已发送主屏幕按键，但尚未确认桌面，请检查当前画面")
            }
            return "已通过已确认的主屏幕映射返回桌面"
        case .type_text:
            guard executor.ble.keyboardReady, keyboardVisible(snapshot) || trustedSearchFocus(frame, snapshot: snapshot) else {
                throw fallback("没有本地确认的输入焦点；先点击输入框，或使用普通单步输入")
            }
            // A generic field may submit on Enter/Tab. Keep semantic typing to
            // a single field; explicit press_key handles authorized submission.
            guard !request.text!.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
                throw fallback("整段输入只填写一个字段；回车或 Tab 请明确调用 press_key")
            }
            try await primitive(.type, text: request.text!, frame: frame)
            let after = try await observe(try await checkedNextFrame(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame))
            try requireUnobstructed(after)
            return "已通过蓝牙键盘输入 \(request.text!.count) 个 ASCII 字符；请核对实际字段内容"
        case .press_key:
            guard executor.ble.keyboardReady, keyboardVisible(snapshot) || trustedSearchFocus(frame, snapshot: snapshot) else {
                throw fallback("没有本地确认的键盘焦点，未发送按键")
            }
            try await primitive(.press_key, text: request.target!, frame: frame)
            let after = try await observe(try await checkedNextFrame(after: lastInputCompletedAt!, relativeTo: frame, nextFrame: nextFrame))
            try requireUnobstructed(after)
            return "已发送按键 \(request.target!)；请根据新画面确认效果"
        }
    }

    /// Four inputs at most: current row, observed composer, text, observed Send.
    /// No scroll/search guessing and no retry of any physical input.
    private func sendSelfMessage(_ request: PhoneHarnessRequest, frame: ScreenFrame, snapshot: PhoneUISnapshot,
                                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> String {
        let operationID = request.operationID!, target = request.target!, text = request.text!
        guard let canonicalTarget = PhonePageAdapters.canonicalConversation(target), let businessDevice = workflowDeviceKey else {
            throw fallback("业务对象或实际手机/配件身份缺失，未执行")
        }
        guard workflowStorageUsable else { throw fallback("流程回执损坏或不可写，已禁止发送；需先人工核验既有操作") }
        if let previous = workflows.record(id: operationID) {
            guard previous.target == canonicalTarget, previous.text == text, previous.deviceKey == businessDevice else {
                throw fallback("operation_id 已绑定其他目标、内容或设备，未执行")
            }
            allowsReceiptReuse = false
            requiresUserReview = previous.stage != .observedOnce && previous.stage != .reviewedByUser
            return workflowSummary(previous, status: previous.stage == .observedOnce ? "previously_observed_submission" : (previous.stage == .reviewedByUser ? "reviewed_by_user" : "pending_review"), detail: "恢复只读取持久化回执，未重放打开、输入或发送；待核验项不可换 operation_id 重试")
        }
        if let sameTask = workflows.records.first(where: { $0.target == canonicalTarget && $0.text == text && $0.taskScopeID == taskScopeID && ($0.stage == .observedOnce || $0.stage == .reviewedByUser) }) {
            allowsReceiptReuse = false
            return workflowSummary(sameTask, status: sameTask.stage == .observedOnce ? "previously_observed_submission" : "reviewed_by_user", detail: "同一任务已有这项业务操作的终态回执；新 operation_id 不会重复提交")
        }
        guard !hasPendingReview else { throw fallback("存在待人工核验业务操作，已停止全部 GUI 流程；不可换名称、布局或 operation_id 重试") }
        // A model must not sidestep a pending receipt by inventing another ID.
        if workflows.records.contains(where: { $0.deviceKey == businessDevice && $0.target == canonicalTarget && $0.text == text && $0.stage != .observedOnce && $0.stage != .reviewedByUser }) {
            throw fallback("相同目标和内容已有待核验流程，禁止通过新 operation_id 重放")
        }
        guard executor.ble.keyboardReady, PhonePageAdapters.selfConversation(target),
              ["wechat.list", "wechat.search", "wechat.chat"].contains(snapshot.scene) else {
            throw fallback("wechat_send 需要已识别的微信列表、搜索或聊天页及可用键盘；当前页面没有可靠身份")
        }
        let deadline = Date().addingTimeInterval(10)
        var record = PhoneWorkflowRecord(operationID: operationID, target: canonicalTarget, text: text, deviceKey: businessDevice,
                                         stage: .prepared, updatedAt: Date(), taskScopeID: taskScopeID, detail: "已绑定内置会话与固定内容；尚未输入")
        try checkpoint(&record, stage: .prepared, detail: record.detail)
        var current = frame, view = snapshot
        do {
            func checkDeadline() throws {
                try Task.checkCancellation()
                guard Date() < deadline else { throw PhoneHarnessFallback(message: "本地流程超过 10 秒上限，已有阶段保留；未重放动作") }
            }
            if view.scene != "wechat.chat" {
                guard let row = PhonePageAdapters.conversationRow(target, in: view) else {
                    throw fallback("指定内置会话在当前页缺失或同名不唯一；未点击旧行位置")
                }
                try checkDeadline()
                try checkpoint(&record, stage: .opening, detail: "会话点击即将派发；中断后先核验")
                try await tap(row, frame: current)
                guard let result = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current, nextFrame: nextFrame, matching: {
                    guard let identity = PhonePageAdapters.identity(in: $0) else { return false }
                    return identity.scene == "wechat.chat" && PhonePageAdapters.conversationMatches(target, identity.conversation)
                }) else { throw fallback("会话点击后未确认准确聊天身份；未继续输入") }
                (current, view) = result
            }
            guard let chat = PhonePageAdapters.identity(in: view), chat.scene == "wechat.chat",
                  PhonePageAdapters.conversationMatches(target, chat.conversation), PhonePageAdapters.selfTransferEvidence(in: view) != nil, let composer = chat.input,
                  PhonePageAdapters.outgoingCount(text, in: chat) == 0 else {
                throw fallback("聊天身份、内置互传说明、空输入框或已有同文消息无法排除；未猜坐标或输入")
            }
            try checkDeadline()
            try checkpoint(&record, stage: .focusing, detail: "准确会话内显式空输入框即将聚焦")
            try await tap(composer, frame: current)
            guard let focused = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current, nextFrame: nextFrame, matching: {
                guard let identity = PhonePageAdapters.identity(in: $0) else { return false }
                return PhonePageAdapters.conversationMatches(target, identity.conversation) && PhonePageAdapters.selfTransferEvidence(in: $0) != nil && identity.input != nil && PhonePageAdapters.keyboardVisible($0)
            }) else { throw fallback("聚焦后未确认原会话、空字段及可见键盘；未输入") }
            (current, view) = focused
            try checkDeadline()
            try checkpoint(&record, stage: .typingPending, detail: "整段输入即将派发；不确定或中断后禁止重复输入")
            try await primitive(.type, text: text, frame: current)
            guard let drafted = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current, nextFrame: nextFrame, matching: {
                guard let identity = PhonePageAdapters.identity(in: $0) else { return false }
                return PhonePageAdapters.conversationMatches(target, identity.conversation) && PhonePageAdapters.selfTransferEvidence(in: $0) != nil && identity.send != nil &&
                    PhonePageAdapters.keyboardVisible($0) && PhonePageAdapters.exactDraft(text, in: $0) != nil
            }) else { throw fallback("文字输入已派发，未全文读回准确字段；停止并保留待核验，勿重输或发送") }
            (current, view) = drafted
            guard let identity = PhonePageAdapters.identity(in: view), let send = identity.send,
                  PhonePageAdapters.outgoingCount(text, in: identity) == 0 else {
                throw fallback("提交前出现同文消息或发送控件变化；停止并保留草稿")
            }
            let identityBeforeSubmit = identity
            try checkpoint(&record, stage: .draftVerified, detail: "当前准确会话的单行草稿已全文 OCR 比对一致")
            try checkDeadline()
            try checkpoint(&record, stage: .submissionPending, detail: "发送即将派发；无论回执或画面结果如何均不可自动重发")
            try await tap(send, frame: current)
            guard let terminal = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current, nextFrame: nextFrame, matching: {
                guard let identity = PhonePageAdapters.identity(in: $0) else { return false }
                return PhonePageAdapters.conversationMatches(target, identity.conversation) && PhonePageAdapters.selfTransferEvidence(in: $0) != nil && identity.input != nil &&
                    identity.send == nil && PhonePageAdapters.exactDraft(text, in: $0) == nil &&
                    PhonePageAdapters.outgoingCount(text, in: identity) == 1 &&
                    PhonePageAdapters.retainsMessageAnchors(identityBeforeSubmit, after: identity)
            }) else { throw fallback("发送已派发一次，尚未同时确认清空字段和唯一新气泡；待核验，禁止自动重发") }
            (current, view) = terminal
            try checkpoint(&record, stage: .observedOnce, detail: "当前可见范围内一条准确同文右侧气泡，原会话身份与空输入框已核对；不代表送达或已读")
            return workflowSummary(record, status: "observed_submission", detail: record.detail)
        } catch is CancellationError {
            // The last checkpoint was committed before dispatch, including the
            // uncertain-send window. Cancellation must still reach the engine.
            allowsReceiptReuse = false
            throw CancellationError()
        } catch {
            allowsReceiptReuse = false; requiresUserReview = true
            let message = (error as? PhoneHarnessFallback)?.message ?? error.localizedDescription
            return workflowSummary(record, status: "partial_pending_review", detail: message)
        }
    }

    /// Called only by an explicit human review control. It records the user's
    /// finding, never infers delivery and never dispatches or retries input.
    func resolveReviewed(operationID: String, resolution: PhoneWorkflowReviewResolution) throws {
        guard workflowStorageUsable, var record = workflows.record(id: operationID),
              record.stage != .observedOnce, record.stage != .reviewedByUser else {
            throw fallback("没有可人工处理的待核验回执，未改变流程")
        }
        record.reviewResolution = resolution
        try checkpoint(&record, stage: .reviewedByUser, detail: "用户独立核验：\(resolution.rawValue)；仅记录结果，未自动重试任何 GUI 动作")
    }

    private func checkpoint(_ record: inout PhoneWorkflowRecord, stage: PhoneWorkflowRecord.Stage, detail: String) throws {
        try Task.checkCancellation()
        var stagedRecord = record
        stagedRecord.stage = stage; stagedRecord.updatedAt = Date(); stagedRecord.detail = detail
        var journal = workflows
        try journal.put(stagedRecord)
        do {
            let data = try JSONEncoder().encode(journal)
            try data.write(to: workflowURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            workflows = journal; record = stagedRecord
            var url = workflowURL; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            workflowStorageUsable = false
            throw fallback("流程回执写入失败，已停止后续输入；当前阶段待独立核验")
        }
    }
    private func workflowSummary(_ record: PhoneWorkflowRecord, status: String, detail: String) -> String {
        let object: [String: Any] = ["operation": "wechat_send", "operation_id": record.operationID,
            "target": record.target, "status": status, "stage": record.stage.rawValue,
            "replay_allowed": false, "detail": String(detail.prefix(320)),
            "verification_scope": "current_visible_ocr_only_not_delivery_or_read_status"]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "本地流程待核验；禁止重放" }
        return String(decoding: data, as: UTF8.self)
    }

    private func checkpointFact(_ frame: ScreenFrame, snapshot: PhoneUISnapshot, source: TaskCheckpointSource,
                                inputCompletedAt: Date?) -> TaskCheckpointFact? {
        guard let binding = searchCheckpointBinding else { return nil }
        return TaskCheckpointFact(scene: snapshot.scene, source: source, verificationScope: .searchSceneOnly, captureID: frame.captureID,
            capturedAt: frame.capturedAt, confirmedAt: frame.confirmedAt, inputCompletedAt: inputCompletedAt,
            fullDisplay: frame.fullDisplay, blockingOverlay: snapshot.blockingOverlay,
            selectedDeviceID: binding.device, connectionGeneration: binding.connection,
            runtimeGeneration: binding.runtime)
    }

    private func openSearch(_ frame: ScreenFrame, snapshot: PhoneUISnapshot,
                            nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> (ScreenFrame, PhoneUISnapshot) {
        guard snapshot.scene == "home" else { throw fallback("open_search 只在已识别的主屏幕使用；当前页 \(snapshot.scene)") }
        let element: PhoneUIElement
        if let visible = searchElement(snapshot) { element = visible }
        else if let saved = memory.control(named: "home.search", in: snapshot) {
            element = PhoneUIElement(id: "home.search", label: saved.label, rect: saved.rect, source: "learned")
        }
        else { throw fallback("主屏幕搜索入口尚未识别，请先定位一次") }
        try await tap(element, frame: frame)
        guard let (fresh, after) = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: frame,
            nextFrame: nextFrame, matching: { $0.scene == "search" }) else {
            forget("home.search", snapshot: snapshot)
            throw fallback("搜索入口点击后未确认搜索页面，已停止连续操作")
        }
        remember("home.search", element: element, source: snapshot, destination: after)
        focusSelection = fresh.captureID; focusEstablishedAt = Date()
        return (fresh, after)
    }

    private func openApp(_ name: String, frame: ScreenFrame, snapshot: PhoneUISnapshot, mappedHome: Bool,
                         nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> String {
        guard executor.ble.keyboardReady,
              name.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw fallback("本地应用搜索需要 ASCII 应用名和可用硬件键盘；中文名称请按当前候选词界面处理")
        }
        var current = frame; var view = snapshot
        if view.scene != "home", view.scene != "search" {
            guard mappedHome else { throw fallback("请先返回桌面；当前没有可用的主屏幕映射") }
            try await primitive(.press_key, text: "home", frame: current, mappedHome: true)
            guard let home = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current,
                nextFrame: nextFrame, matching: { $0.scene == "home" }) else {
                throw fallback("已发送主屏幕按键，尚未确认桌面；没有继续搜索或输入")
            }
            (current, view) = home
        }
        if view.scene == "home" { (current, view) = try await openSearch(current, snapshot: view, nextFrame: nextFrame) }
        guard trustedSearchFocus(current, snapshot: view) else {
            throw fallback("搜索输入框焦点未由本地流程确认，请先调用 open_search 或点击搜索输入框")
        }
        try await primitive(.press_key, text: "select_all", frame: current)
        // Selection can change the pixels (for example, highlighting an old
        // query). Observe that completed input before authorizing text entry.
        current = try await checkedNextFrame(after: lastInputCompletedAt!, relativeTo: current, nextFrame: nextFrame)
        view = try await observe(current)
        try requireUnobstructed(view)
        guard trustedSearchFocus(current, snapshot: view) else {
            throw fallback("选择文字后未确认搜索输入页，未继续输入应用名")
        }
        try await primitive(.type, text: name, frame: current)
        // Only an installed-app section is accepted. A matching web/contact/
        // suggestion label alone cannot establish that this is an app result.
        guard let result = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current,
            nextFrame: nextFrame, matching: { $0.scene == "search" && self.applicationResult(name, in: $0) != nil }) else {
            throw fallback("应用名已输入，但本地尚未找到唯一的应用结果；请根据当前搜索结果选择，勿重复输入")
        }
        (current, view) = result
        guard let app = applicationResult(name, in: view) else { throw fallback("应用结果已改变，请重新观察") }
        try await tap(app, frame: current)
        guard let destination = try await waitForSnapshot(after: lastInputCompletedAt!, relativeTo: current,
            nextFrame: nextFrame, matching: { self.matchesRequestedApp(name, snapshot: $0) }) else {
            throw fallback("已点击应用结果，但本地尚未确认目标应用身份；请根据当前画面核对，勿重复搜索或点击")
        }
        (current, view) = destination
        return "本地已完成搜索、输入和点击应用结果 \(name)，当前页面 \(view.scene)；请核对截图确认目标应用和任务结果"
    }

    /// Wait only for observations, never retry the input that caused a transition.
    /// The frame cap also bounds injected or unexpectedly high-rate streams.
    private func waitForSnapshot(after inputCompletedAt: Date, relativeTo source: ScreenFrame,
                                 nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame,
                                 matching: (PhoneUISnapshot) -> Bool) async throws -> (ScreenFrame, PhoneUISnapshot)? {
        let deadline = Date().addingTimeInterval(2)
        var newerThan = inputCompletedAt
        for _ in 0..<12 {
            try Task.checkCancellation()
            guard Date() < deadline else { return nil }
            let fresh: ScreenFrame
            do {
                fresh = try await withThrowingTaskGroup(of: ScreenFrame.self) { group in
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    let requiredAfter = newerThan
                    group.addTask { @MainActor in
                        try await self.checkedNextFrame(after: requiredAfter, relativeTo: source, nextFrame: nextFrame)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                        throw TransitionWaitExpired()
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch is TransitionWaitExpired { return nil }
            let snapshot = try await observe(fresh)
            try requireUnobstructed(snapshot)
            guard Date() <= deadline else { return nil }
            if matching(snapshot) { return (fresh, snapshot) }
            newerThan = fresh.confirmedAt
        }
        return nil
    }

    private struct TransitionWaitExpired: Error {}

    private func checkedNextFrame(after: Date, relativeTo source: ScreenFrame,
                                  nextFrame: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> ScreenFrame {
        try Task.checkCancellation()
        try requireAccessory()
        let fresh: ScreenFrame
        if let metrics { fresh = try await metrics.measureAsync(.wait, label: "harness.next-frame") { try await nextFrame(after) } }
        else { fresh = try await nextFrame(after) }
        try Task.checkCancellation(); try requireAccessory()
        guard fresh.captureID == source.captureID, fresh.sourceWidth == source.sourceWidth,
              fresh.sourceHeight == source.sourceHeight, fresh.width == source.width, fresh.height == source.height,
              fresh.fullDisplay else {
            throw AgentError.message("手机工具等待期间共享或屏幕尺寸已改变，已停止")
        }
        guard fresh.confirmedAt > after, (-0.15...1.5).contains(Date().timeIntervalSince(fresh.confirmedAt)), fresh.capturedAt <= fresh.confirmedAt else { throw fallback("没有收到动作完成后的新画面，已停止本地连续操作") }
        return fresh
    }

    private func matchesRequestedApp(_ name: String, snapshot: PhoneUISnapshot) -> Bool {
        // Other apps remain a model-verified fallback until their identity can
        // be recognized locally. Merely leaving Spotlight is not app identity.
        if Self.normalized(name) == "settings" { return snapshot.scene == "settings" || snapshot.scene.hasPrefix("settings.") }
        if ["wechat", "微信"].contains(Self.normalized(name)) { return snapshot.scene.hasPrefix("wechat.") }
        if ["xiaohongshu", "rednote", "小红书"].contains(Self.normalized(name)) { return snapshot.scene.hasPrefix("xiaohongshu.") }
        return false
    }

    private func primitive(_ kind: AgentAction.Kind, text: String, frame: ScreenFrame, mappedHome: Bool = false) async throws {
        let frame = try confirmedInputFrame(frame)
        _ = try executor.validateCalibration(frame: frame)
        let action = AgentAction(kind: kind, text: text, reason: "本地手机工具")
        let validateInput = { @MainActor in _ = try self.confirmedInputFrame(frame) }
        if let metrics { try await metrics.measureAsync(.input, label: "harness.keyboard") { try await executor.execute(action, frame: frame, mappedHomeAvailable: mappedHome, validateInput: validateInput) } }
        else { try await executor.execute(action, frame: frame, mappedHomeAvailable: mappedHome, validateInput: validateInput) }
        lastInputCompletedAt = Date()
        try Task.checkCancellation()
    }
    private func tap(_ element: PhoneUIElement, frame: ScreenFrame) async throws {
        guard element.rect.valid else { throw fallback("本地控件坐标无效") }
        let frame = try confirmedInputFrame(frame)
        _ = try executor.validateCalibration(frame: frame)
        let action = AgentAction(kind: .tap, x: element.rect.centerX, y: element.rect.centerY, reason: "本地定位 \(element.id)")
        let validateInput = { @MainActor in _ = try self.confirmedInputFrame(frame) }
        if let metrics { try await metrics.measureAsync(.input, label: "harness.tap") { try await executor.execute(action, frame: frame, validateInput: validateInput) } }
        else { try await executor.execute(action, frame: frame, validateInput: validateInput) }
        lastInputCompletedAt = Date()
        try Task.checkCancellation()
    }

    private func observe(_ frame: ScreenFrame, lease: WorkflowObservationLease? = nil) async throws -> PhoneUISnapshot {
        try Task.checkCancellation()
        try requireActiveFrame(frame)
        let lease = try lease ?? executionLease(for: frame)
        let generation = observationGeneration
        let identity = HarnessObservationKey(frame: frame, selectedDevice: executor.ble.selectedID)
        let proof = WorkflowObservationProof(frame: frame, runtimeGeneration: generation,
            selectedDeviceID: executor.ble.selectedID, connectionGeneration: executor.ble.pointerConnectionGeneration)
        if !identity.canCache {
            cachedFrame = nil; cachedSnapshot = nil; workflowTitleCache = nil
            cachedObservationProof = nil; workflowTitleProof = nil
        }
        lastObservedFrame = frame
        if identity.canCache, cachedFrame == identity, let cachedSnapshot,
           lease.map({ cachedObservationProof?.matches($0.proof) == true }) ?? true {
            if let lease {
                try measureObservationBinding(frame, identity: identity, generation: generation,
                    label: "harness.cached-frame-binding", lease: lease)
            }
            return cachedSnapshot
        }
        guard frame.fullDisplay, let image = frame.image.cgImage else { throw fallback("本地布局识别需要有效整屏画面") }
        let recognized: [PhoneUIElement]
        metrics?.note(Self.recognitionTimingNote)
        let ocrToken = metrics?.begin(.ocr, label: "harness.current-frame")
        do {
        if let recognize { recognized = try await recognize(frame) }
        else { recognized = try await Task.detached(priority: .userInitiated) { () -> [PhoneUIElement] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US", "zh-Hans"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).sorted { a, b in
                let rowA = Int((a.boundingBox.midY * 80).rounded()), rowB = Int((b.boundingBox.midY * 80).rounded())
                return rowA == rowB ? a.boundingBox.minX < b.boundingBox.minX : rowA > rowB
            }.prefix(100).compactMap { result in
                guard let text = result.topCandidates(1).first, text.confidence >= 0.45 else { return nil }
                let b = result.boundingBox
                let rect = PhoneUIRect(x: max(0, b.minX), y: max(0, 1 - b.maxY), width: min(b.width, 1 - b.minX), height: min(b.height, b.maxY))
                guard rect.valid else { return nil }
                let identifier = "ocr.\(Self.labelKey(text.string)).\(Int((rect.centerX * 40).rounded())).\(Int((rect.centerY * 80).rounded()))"
                return PhoneUIElement(id: identifier, label: text.string, rect: rect, source: "ocr")
            }
        }.value }
        if let ocrToken { metrics?.end(ocrToken) }
        } catch {
            if let ocrToken { metrics?.end(ocrToken, outcome: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
        try measureObservationBinding(frame, identity: identity, generation: generation, label: "harness.current-frame-binding", lease: lease)
        // IDs name one observed pixel frame. Dynamic objects never inherit an
        // old ID just because a new row occupies the same approximate point.
        let observationToken = Self.labelKey("\(frame.captureID?.uuidString ?? "none")|\(frame.capturedAt.timeIntervalSinceReferenceDate.bitPattern)")
        let raster = PhoneRasterEvidence.raster(image)
        let localControls = raster.map { PhoneVisualControls.detect(in: $0) } ?? []
        let elements = (recognized + localControls).map { element -> PhoneUIElement in
            var bound = element
            if ["ocr", "local_visual"].contains(element.source) { bound.id = "\(element.source).\(observationToken).\(Self.labelKey(element.id + "|" + element.label))" }
            return bound
        }
        let blocked = PhoneOverlayClassifier.evaluate(elements: elements, raster: raster).blocking
        #if canImport(UIKit)
        let scale = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.traitCollection.displayScale ?? 0
        let display = "\(scale)|\(UIApplication.shared.preferredContentSizeCategory.rawValue)|\(UIAccessibility.isBoldTextEnabled)"
        #else
        let display = "offline"
        #endif
        let appIdentity = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown").\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")"
        let key = "harness-v2|app-\(appIdentity)|\(executor.ble.selectedID ?? "unbound")|\(frame.sourceWidth)x\(frame.sourceHeight)|\(frame.width)x\(frame.height)|\(display)|\(Locale.current.identifier)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
        var snapshot = PhoneUISnapshot(deviceKey: key, scene: "unknown", elements: elements, capturedAt: frame.capturedAt, blockingOverlay: blocked)
        if let metrics { snapshot.scene = metrics.measure(.verification, label: "harness.page-identity") { classify(snapshot) } }
        else { snapshot.scene = classify(snapshot) }
        if let learning = pendingLearning {
            pendingLearning = nil
            if (0...8).contains(Date().timeIntervalSince(learning.3)) {
                remember(learning.0, element: learning.1, source: learning.2, destination: snapshot)
            }
        }
        if snapshot.scene != "search" { focusSelection = nil; focusEstablishedAt = .distantPast }
        if backElement(snapshot) == nil, let remembered = memory.control(named: "navigation.back", in: snapshot) {
            snapshot.elements.append(PhoneUIElement(id: "navigation.back", label: remembered.label, rect: remembered.rect, source: "learned"))
        }
        cachedFrame = identity.canCache ? identity : nil; cachedSnapshot = identity.canCache ? snapshot : nil
        cachedObservationProof = identity.canCache ? proof : nil
        observationRecorder?(lease?.frame ?? frame, snapshot)
        return snapshot
    }

    /// Every semantic observation belongs to the connection and runtime that
    /// admitted this operation. OCR may suspend while the live page changes.
    private func executionLease(for frame: ScreenFrame) throws -> WorkflowObservationLease? {
        guard executionFrameIdentity != nil, let contextCurrent else { return nil }
        try requireAccessory()
        guard let binding = executionBinding, let selected = executionAccessory, !selected.isEmpty else {
            throw fallback("本地操作缺少可核验的输入配件，已停止")
        }
        if let lease = executionObservationLease, lease.proof.pixelFailures(frame).isEmpty {
            _ = try lease.advance(runtimeGeneration: observationGeneration)
            return lease
        }
        let lease = try WorkflowObservationLease.contextFrame(frame, runtimeGeneration: binding.runtime,
            selectedDeviceID: selected, connectionGeneration: binding.connection, current: contextCurrent)
        _ = try lease.advance(runtimeGeneration: observationGeneration)
        executionObservationLease = lease
        return lease
    }

    /// Recheck the exact pixels that supplied the coordinates/focus immediately
    /// before dispatch, including cached OCR and subsequent workflow inputs.
    private func confirmedInputFrame(_ frame: ScreenFrame) throws -> ScreenFrame {
        try Task.checkCancellation(); try requireAccessory()
        let current: ScreenFrame
        if contextCurrent != nil {
            guard let lease = executionObservationLease, lease.proof.pixelFailures(frame).isEmpty else {
                throw fallback("输入缺少当前画面的识别凭据，未派发旧坐标")
            }
            current = try lease.advance(runtimeGeneration: observationGeneration)
        } else { current = frame }
        try requireActiveFrame(current)
        return current
    }

    private func measureObservationBinding(_ frame: ScreenFrame, identity: HarnessObservationKey, generation: UUID,
                                           label: String, lease: WorkflowObservationLease? = nil) throws {
        let validate = {
            let bound = try lease?.advance(runtimeGeneration: self.observationGeneration) ?? frame
            try self.requireObservation(bound, identity: identity, generation: generation)
        }
        if let metrics { try metrics.measure(.verification, label: label, validate) }
        else { try validate() }
    }

    private func requireObservation(_ frame: ScreenFrame, identity: HarnessObservationKey, generation: UUID) throws {
        try Task.checkCancellation(); try requireActiveFrame(frame)
        guard generation == observationGeneration,
              identity == HarnessObservationKey(frame: frame, selectedDevice: executor.ble.selectedID) else {
            throw fallback("识别期间设备、画面尺寸或准备状态已改变，旧结果未采用；请重新读取当前画面")
        }
    }

    private func classify(_ snapshot: PhoneUISnapshot) -> String {
        if let identity = PhonePageAdapters.identity(in: snapshot) { return identity.scene }
        let lower = snapshot.elements.map { (Self.normalized($0.label), $0.rect) }
        let hasKeyboard = keyboardVisible(snapshot)
        // Settings has its own bottom Search field. Its large leading title
        // must be recognized before the Home search capsule heuristic.
        if lower.contains(where: { ["settings", "设置"].contains($0.0) && $0.1.centerY < 0.21 }),
           lower.contains(where: { ["wi-fi", "无线局域网", "wlan"].contains($0.0) }),
           lower.contains(where: { ["bluetooth", "蓝牙"].contains($0.0) }) { return "settings" }
        let searchWords = ["search", "搜索"]
        let hasCancel = lower.contains { ["cancel", "取消"].contains($0.0) }
        let spotlightSection = lower.contains { ["siri suggestions", "siri 建议", "apps", "应用", "top hit", "热门结果"].contains($0.0) }
        if (hasKeyboard || (hasCancel && spotlightSection)) &&
            lower.contains(where: { searchWords.contains($0.0) || ["cancel", "取消"].contains($0.0) }) { return "search" }
        let headings = lower.filter { $0.1.centerY < 0.15 && $0.1.centerX > 0.27 && $0.1.centerX < 0.77 }
        let known: [String: String] = ["accessibility":"accessibility", "辅助功能":"accessibility", "touch":"touch", "触控":"touch",
            "assistivetouch":"assistivetouch", "辅助触控":"assistivetouch", "devices":"devices", "设备":"devices"]
        for (title, _) in headings { if let id = known[title] { return "settings." + id } }
        let gridColumns = Set(lower.filter({ (0.12...0.78).contains($0.1.centerY) }).map { Int(($0.1.centerX * 4).rounded()) })
        if !hasKeyboard, searchElement(snapshot) != nil, gridColumns.count >= 3 { return "home" }
        return "unknown"
    }
    private func keyboardVisible(_ snapshot: PhoneUISnapshot) -> Bool {
        let labels = snapshot.elements.filter { $0.rect.centerY > 0.56 }.map { Self.normalized($0.label) }
        return labels.contains(where: { ["space", "空格"].contains($0) }) &&
            labels.contains(where: { ["return", "search", "go", "done", "换行", "搜索", "完成", "123"].contains($0) })
    }
    private func trustedSearchFocus(_ frame: ScreenFrame, snapshot: PhoneUISnapshot) -> Bool {
        snapshot.scene == "search" && focusSelection == frame.captureID && Date().timeIntervalSince(focusEstablishedAt) < 20
    }
    private func searchElement(_ snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        // Native OCR sometimes includes the capsule's magnifier as Q/O. Only
        // those exact observed forms and the centered Home region are aliases.
        let labels = ["search", "q search", "o search", "🔍 search", "搜索", "q 搜索", "o 搜索"]
        let matches = snapshot.elements.filter { $0.source == "ocr" && labels.contains(Self.normalized($0.label)) &&
            (0.35...0.65).contains($0.rect.centerX) && (0.70...0.90).contains($0.rect.centerY) }
        return matches.count == 1 ? matches[0] : nil
    }
    private func backElement(_ snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard snapshot.scene.hasPrefix("settings.") else { return nil }
        let matches = snapshot.elements.filter { $0.source == "ocr" && $0.rect.centerX < 0.27 && (0.035...0.15).contains($0.rect.centerY) &&
            ["back", "返回", "settings", "设置", "accessibility", "辅助功能", "touch", "触控", "assistivetouch", "辅助触控"].contains(Self.normalized($0.label)) }
        return matches.count == 1 ? matches[0] : nil
    }
    private func applicationResult(_ name: String, in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let sections = snapshot.elements.filter { ["apps", "应用", "应用程序"].contains(Self.normalized($0.label)) }
        guard let section = sections.first else { return nil }
        let nextSection = snapshot.elements.filter { $0.rect.centerY > section.rect.centerY &&
            ["contacts", "联系人", "messages", "信息", "websites", "网站", "search web", "搜索网页", "app store"].contains(Self.normalized($0.label)) }.map(\.rect.y).min() ?? 0.59
        let matches = snapshot.elements.filter { Self.normalized($0.label) == Self.normalized(name) &&
            $0.rect.centerY > section.rect.centerY && $0.rect.centerY < min(nextSection, 0.62) }
        return matches.count == 1 ? matches[0] : nil
    }
    private func remember(_ name: String, element: PhoneUIElement, source: PhoneUISnapshot, destination: PhoneUISnapshot) {
        var source = source
        if source.element(id: element.id) == nil { source.elements.append(element) }
        guard (try? memory.record(name: name, element: element, source: source, destination: destination)) != nil else { return }
        persist()
    }
    private func forget(_ name: String, snapshot: PhoneUISnapshot) {
        memory.controls.removeAll { $0.deviceKey == snapshot.deviceKey && $0.scene == snapshot.scene && $0.name == name }
        cachedFrame = nil; cachedSnapshot = nil; persist()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: memoryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = memoryURL; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
    }
    private func fallback(_ message: String) -> PhoneHarnessFallback {
        lastFallback = String(message.prefix(240)); return PhoneHarnessFallback(message: lastFallback)
    }
    private func requireActiveFrame(_ frame: ScreenFrame) throws {
        guard frame.fullDisplay, frame.width > 0, frame.height > 0, frame.sourceWidth > 0, frame.sourceHeight > 0,
              (-0.15...1.5).contains(Date().timeIntervalSince(frame.confirmedAt)), frame.capturedAt <= frame.confirmedAt else {
            throw fallback("本地操作需要当前新鲜整屏画面；过期、未来或无效尺寸已停止")
        }
        if let expected = executionFrameIdentity {
            guard frame.captureID == expected.0, frame.width == expected.1, frame.height == expected.2,
                  frame.sourceWidth == expected.3, frame.sourceHeight == expected.4 else {
                throw fallback("本地流程的共享来源或屏幕尺寸已改变，已停止")
            }
            try requireAccessory()
        }
    }
    /// Business receipts must survive layout/font/app-version changes. They
    /// bind the actual host phone and selected BLE device, not a layout key.
    private var workflowDeviceKey: String? {
        guard let accessory = executor.ble.selectedID, !accessory.isEmpty else { return nil }
        #if canImport(UIKit)
        guard let phone = UIDevice.current.identifierForVendor?.uuidString else { return nil }
        #else
        let phone = "offline-fixture-host"
        #endif
        return "phone-\(phone)|accessory-\(accessory)"
    }
    private func requireAccessory() throws {
        guard executionAccessory == executor.ble.selectedID,
              executionBinding.map({ $0.connection == executor.ble.pointerConnectionGeneration && $0.runtime == observationGeneration }) ?? true else {
            throw fallback("本地流程期间输入配件发生变化，已停止后续操作")
        }
    }
    private func requireUnobstructed(_ snapshot: PhoneUISnapshot) throws {
        guard !snapshot.blockingOverlay else { throw fallback("页面出现遮挡或系统确认窗口，本地连续操作已停止") }
    }
    private func contains(_ rect: PhoneUIRect, x: Double, y: Double) -> Bool {
        (rect.x - 0.035...rect.x + rect.width + 0.035).contains(x) && (rect.y - 0.025...rect.y + rect.height + 0.025).contains(y)
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    nonisolated private static func labelKey(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}

/// Pixel evidence may be reused only inside one named capture and exact
/// geometry. A newer idle confirmation is deliberately not a new pixel key;
/// every caller still validates its own real confirmation and cancellation.
struct HarnessObservationKey: Equatable {
    var captureID: UUID?
    var capturedAt: Date
    var selectedDevice: String?
    var width: Int
    var height: Int
    var sourceWidth: Int
    var sourceHeight: Int
    var imageWidth: Int
    var imageHeight: Int
    var fullDisplay: Bool
    var canCache: Bool { captureID != nil }

    init(frame: ScreenFrame, selectedDevice: String?) {
        captureID = frame.captureID; capturedAt = frame.capturedAt; self.selectedDevice = selectedDevice
        width = frame.width; height = frame.height; sourceWidth = frame.sourceWidth; sourceHeight = frame.sourceHeight
        imageWidth = frame.image.cgImage?.width ?? 0; imageHeight = frame.image.cgImage?.height ?? 0
        fullDisplay = frame.fullDisplay
    }
}

/// Local recognition only, never identity authority. The final profile parser
/// still requires its full proof. This helper is used exclusively by the
/// workflow snapshot copy; the generic OCR cache and long-task context do not
/// receive a second recognition pass or any additional elements.
enum WeChatBuiltinWorkflowTitleOCR {
    static let region = CGRect(x: 0.20, y: 0.80, width: 0.55, height: 0.08)

    static func isCandidate(_ snapshot: PhoneUISnapshot) -> Bool {
        guard !snapshot.blockingOverlay else { return false }
        let elements = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid }
        guard Set(elements.map(\.id)).count == elements.count,
              !elements.contains(where: { (0.055...0.12).contains($0.rect.centerY) && (0.28...0.76).contains($0.rect.centerX) }),
              !snapshot.elements.contains(where: {
                  $0.source == "local_visual" && $0.label == "视觉:添加" && $0.rect.valid && $0.rect.centerY > 0.55
              }), !elements.contains(where: {
                  (0.12...0.19).contains($0.rect.centerY) && (0.20...0.50).contains($0.rect.x) &&
                      PhonePageAdapters.selfConversation($0.label)
              }) else { return false }
        let accountFields = elements.filter {
            guard (0.15...0.24).contains($0.rect.centerY), (0.20...0.50).contains($0.rect.x),
                  let separator = $0.label.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
            return ["weixin id", "wechat id", "微信号"].contains(PhonePageAdapters.normalized(String($0.label[..<separator])))
        }
        guard accountFields.count == 1, let accountField = accountFields.first,
              let separator = accountField.label.firstIndex(where: { $0 == ":" || $0 == "：" }),
              accountField.label[accountField.label.index(after: separator)...].trimmingCharacters(in: .whitespaces) == "filehelper" else { return false }
        let messages = elements.filter {
            ["messages", "• messages", "发消息"].contains(PhonePageAdapters.normalized($0.label)) &&
                (0.32...0.48).contains($0.rect.centerY) && (0.35...0.65).contains($0.rect.centerX)
        }
        guard messages.count == 1 else { return false }
        let description = elements.filter {
            (0.23...0.34).contains($0.rect.centerY) && (0.20...0.32).contains($0.rect.x) &&
                $0.rect.centerY < messages[0].rect.y - 0.015
        }.sorted { $0.rect.centerY < $1.rect.centerY }
        let expected = "transfer text, images, audio and video files between your device and your pc"
        return (1...4).contains(description.count) &&
            [expected, expected + "."].contains(PhonePageAdapters.normalized(description.map(\.label).joined(separator: " "))) &&
            zip(description, description.dropFirst()).allSatisfy { before, after in
                (0.005...0.05).contains(after.rect.centerY - before.rect.centerY) && abs(after.rect.x - before.rect.x) < 0.035
            }
    }

    /// Vision returns ROI-relative normalized rectangles. Convert the observed
    /// rectangle before using it as a full-frame anchor or a clickable target.
    static func fullFrameRect(_ box: CGRect) -> PhoneUIRect {
        let global = CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
            width: box.width * region.width, height: box.height * region.height)
        return .init(x: global.minX, y: 1 - global.maxY, width: global.width, height: global.height)
    }

    static func recognize(in image: CGImage) throws -> [PhoneUIElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.regionOfInterest = region
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).prefix(8).enumerated().compactMap { index, result in
            guard let text = result.topCandidates(1).first, text.confidence >= 0.45 else { return nil }
            let rect = fullFrameRect(result.boundingBox)
            guard rect.valid else { return nil }
            return .init(id: "workflow-title-roi.\(index)", label: text.string, rect: rect, source: "ocr")
        }
    }

    static func uniqueAddition(_ recognized: [PhoneUIElement], to snapshot: PhoneUISnapshot) -> [PhoneUIElement] {
        guard isCandidate(snapshot) else { return [] }
        let titles = recognized.filter {
            $0.source == "ocr" && $0.rect.valid && (0.12...0.19).contains($0.rect.centerY) &&
                (0.20...0.50).contains($0.rect.x) && PhonePageAdapters.selfConversation($0.label)
        }
        guard titles.count == 1, !snapshot.elements.contains(where: { $0.id == titles[0].id }) else { return [] }
        return titles // actual recognized label and rectangle; no preset title
    }
}
