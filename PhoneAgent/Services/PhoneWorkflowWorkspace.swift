import Foundation
import Combine
import UIKit
import UniformTypeIdentifiers

struct SavedChatWorkflow: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var stableID: String
    var range: ChatReadRange
    var maxPages: Int
}

struct NativeFileSharePresentation: Identifiable {
    let id = UUID()
    let files: [URL]
    var automaticPayload: FileTransferPayload? = nil
}
struct SavedAutomaticFileWorkflow: Codable, Equatable, Identifiable {
    var id: String
    var recipient: FileTransferRecipient
    var artifactIDs: [UUID]
    var authorizedAt: Date
    func validate() throws {
        guard UUID(uuidString:id) != nil, authorizedAt.timeIntervalSince1970.isFinite,
              !artifactIDs.isEmpty, artifactIDs.count<=50, Set(artifactIDs).count==artifactIDs.count else {
            throw FileTransferError.invalid("自动发送范围")
        }
        try recipient.validate(artifactIDs:artifactIDs)
    }
}

/// Real App entry points for the three domain pipelines. Plans are explicit
/// native user input; model tools can reference plans but cannot create or widen
/// a private chat/recipient scope from arbitrary screen text.
@MainActor final class PhoneWorkflowWorkspace: ObservableObject {
    @Published private(set) var xhsTasks: [XiaohongshuCollectionTask] = []
    @Published private(set) var chatPlans: [SavedChatWorkflow] = []
    @Published private(set) var filePlans: [SavedAutomaticFileWorkflow] = []
    @Published private(set) var status = "先配置范围，再开始读取或发送"
    @Published private(set) var reportText = ""
    @Published private(set) var exportURL: URL?
    @Published private(set) var sharePresentation: NativeFileSharePresentation?
    let xhsStore = XiaohongshuCollectionStore.shared
    let chatStore = ChatEvidenceStore.shared
    let fileStore = FileTransferStore.shared
    let diagnostics = WorkflowDiagnosticsStore.shared
    @Published private(set) var diagnosticRecordingError=""
    private var activeDiagnosticWorkflowID:String?

    private let capture: CaptureService
    private let executor: MouseExecutor
    private let harness: PhoneHarnessRuntime
    private var registryReadable = true
    private var shareContinuation: CheckedContinuation<FileTransferNativeShareResult, Never>?
    private var automaticPresentation: CheckedContinuation<WeChatNativeShareBinding, Error>?
    private var automaticPresentationID: UUID?
    private var shareHosts = Set<UUID>()
    func registerShareHost(_ id:UUID) {shareHosts.insert(id)}
    func unregisterShareHost(_ id:UUID) {
        shareHosts.remove(id)
        if shareHosts.isEmpty,let current=sharePresentation {finishNativeShare(id:current.id,result:.dismissedOrUnknown)}
    }
    var model: ((String) async throws -> String)?
    private var observers = Set<AnyCancellable>()
    private struct Registry: Codable { var version = 1; var xhs: [XiaohongshuCollectionTask]; var chats: [SavedChatWorkflow]; var files: [SavedAutomaticFileWorkflow]? = nil }
    private var registryURL: URL { URL.applicationSupportDirectory.appendingPathComponent("PhoneAgent/workflow-plans.json") }
    var hasPendingReview: Bool { fileStore.hasPendingReview }
    var blocksGUI: Bool { fileStore.hasPendingReview || fileStore.hasActiveOperation }
    var recentXHSRuns: [XiaohongshuCollectionRun] { xhsStore.runs.reversed() }
    var recentChatSessions: [ChatEvidenceSession] { chatStore.sessions.reversed() }

    init(capture: CaptureService, executor: MouseExecutor, harness: PhoneHarnessRuntime) {
        self.capture = capture; self.executor = executor; self.harness = harness
        fileStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        diagnostics.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&observers)
        harness.observationRecorder = { [weak self] frame,snapshot in
            guard let self,self.activeDiagnosticWorkflowID==nil,let captureID=frame.captureID else{return}
            do {
                _ = try self.diagnostics.record(jpeg:frame.jpeg,context:.init(workflowID:self.harness.taskScopeID?.uuidString,boundary:.observed,captureID:captureID,capturedAt:frame.capturedAt,confirmedAt:frame.confirmedAt,snapshot:snapshot,reason:snapshot.blockingOverlay ? "当前识别到遮挡或确认窗口" : nil))
                self.diagnosticRecordingError=""
            } catch {self.diagnosticRecordingError=error.localizedDescription}
        }
        if FileManager.default.fileExists(atPath: registryURL.path) {
            do {
                let data = try Data(contentsOf: registryURL)
                guard data.count <= 2_000_000 else { throw AgentError.message("任务范围存储过大") }
                let value = try JSONDecoder().decode(Registry.self, from: data)
                guard value.version == 1, value.xhs.count <= 50, value.chats.count <= 100,
                      Set(value.xhs.map(\.id)).count == value.xhs.count,
                      Set(value.chats.map(\.id)).count == value.chats.count else { throw AgentError.message("任务范围存储无效") }
                for task in value.xhs { try task.validate() }
                for plan in value.chats { try validate(plan) }
                guard (value.files?.count ?? 0)<=100, Set((value.files ?? []).map(\.id)).count == (value.files?.count ?? 0) else {throw FileTransferError.invalid("自动发送范围已满")}
                for plan in value.files ?? [] {try plan.validate()}
                xhsTasks = value.xhs; chatPlans = value.chats; filePlans = value.files ?? []
            } catch { registryReadable = false; status = "原任务范围文件无法读取，已保留；不会用空范围覆盖" }
        }
        reconcileDiagnosticProtection()
    }
    @discardableResult func createXHS(keyword: String, sampleSize: Int, sort: String, filters: [String], profileID: String? = nil, maxSeconds: Double = 120) throws -> String {
        var task = XiaohongshuCollectionTask(id: UUID().uuidString, keyword: keyword, range: profileID == nil ? "currentSearchResults" : "currentProfileNotes", profileID: profileID, sampleSize: sampleSize, sort: profileID == nil ? sort : "主页顺序", filters: filters)
        task.stops.maxSeconds = maxSeconds
        try task.validate(); try saveRegistry(xhs: xhsTasks + [task], chats: chatPlans)
        status = "采集范围已保存；请打开匹配的搜索结果页后开始"
        return task.id
    }
    @discardableResult func createChat(title: String, stableID: String, range: ChatReadRange, maxPages: Int) throws -> String {
        if case .latest = range { throw ChatEvidenceError.latestEndUnknown }
        let resolvedID: String
        if stableID == "wechat.builtin.file-transfer" {resolvedID = stableID}
        else if stableID.hasPrefix(WeChatContactIdentity.accountPrefix) {
            _ = try WeChatContactIdentity.account(fromStableID:stableID);resolvedID = stableID
        } else {resolvedID = try WeChatContactIdentity.stableID(account:stableID)}
        let pages: Int
        if case .currentPage = range { pages = 1 } else { pages = maxPages }
        let value = SavedChatWorkflow(id: UUID().uuidString, title: title, stableID: resolvedID, range: range, maxPages: pages)
        try validate(value); try saveRegistry(xhs: xhsTasks, chats: chatPlans + [value])
        status = "聊天范围已保存；开始时仍要核对当前真实会话身份"
        return value.id
    }
    private func validate(_ value: SavedChatWorkflow) throws {
        guard UUID(uuidString: value.id) != nil else { throw ChatEvidenceError.invalidRequest }
        try ChatReadRequest(scopeID: value.id, conversation: .init(stableID: value.stableID, title: value.title, deviceKey: "bind-at-first-observation"),
                            range: value.range, maxPages: value.maxPages).validate()
    }
    private func saveRegistry(xhs: [XiaohongshuCollectionTask], chats: [SavedChatWorkflow], files: [SavedAutomaticFileWorkflow]? = nil) throws {
        guard registryReadable, xhs.count <= 50, chats.count <= 100 else { throw AgentError.message("任务范围存储不可用或已满") }
        let files = files ?? filePlans
        guard files.count<=100 else {throw FileTransferError.invalid("自动发送范围已满")}
        let data = try JSONEncoder().encode(Registry(xhs: xhs, chats: chats, files: files))
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: registryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        xhsTasks = xhs; chatPlans = chats; filePlans = files
    }
    private func beginDiagnostics(id:String,gui:PhoneWorkflowCaptureDriver,operationID:String?=nil) {
        activeDiagnosticWorkflowID=id;gui.diagnosticWorkflowID=id;gui.diagnosticOperationID=operationID
    }
    private func endDiagnostics(gui:PhoneWorkflowCaptureDriver) {
        if let error=gui.diagnosticRecordingError {diagnosticRecordingError=error}
        activeDiagnosticWorkflowID=nil
    }
    func advertisedPlans() -> String {
        let object: [String: Any] = ["xhs": xhsTasks.suffix(20).map { ["id": $0.id, "keyword": $0.keyword, "sample_size": String($0.sampleSize), "max_seconds": String($0.stops.maxSeconds)] },
            "chats": chatPlans.suffix(20).map { plan in
                let capability: String
                switch plan.range {
                case .latest: capability = "latestEndUnknown; view/export only; no read or model upload"
                case .currentPage: capability = "first visible page only; once bound, view/export/summarize only; no newer reads"
                case .time: capability = "explicit time range; unknown times excluded; two-sided coverage required"
                }
                return ["id": plan.id, "title": plan.title, "range_capability": capability]
            },
            "automatic_file_tasks": filePlans.suffix(20).map { ["id":$0.id,"recipient":$0.recipient.displayName,"file_count":String($0.artifactIDs.count)] },
            "file_operations": fileStore.operations.suffix(20).map { ["id": $0.operationID, "stage": $0.stage.rawValue] }]
        return (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    func driver(initial: ScreenFrame? = nil, next: (@MainActor (Date) async throws -> ScreenFrame)? = nil) -> PhoneWorkflowCaptureDriver {
        PhoneWorkflowCaptureDriver(capture: capture, executor: executor, harness: harness, initial: initial, next: next,diagnostics:diagnostics)
    }
    func collectXHS(id: String, gui: PhoneWorkflowCaptureDriver) async throws -> String {
        guard !hasPendingReview, let task = xhsTasks.first(where: { $0.id == id }) else { throw AgentError.message("任务范围不存在或有待核验文件提交") }
        beginDiagnostics(id:id,gui:gui)
        defer {endDiagnostics(gui:gui)}
        gui.menuPolicy = { ["xiaohongshu.share","xiaohongshu.filters"].contains(XiaohongshuPageAdapter.identity(in:$0)?.scene ?? "") }
        status = "正在按固定范围采集；原始明细逐批保存"
        defer { objectWillChange.send() }
        do {
            let run = try await XiaohongshuCollector(store: xhsStore).collect(task: task, driver: LiveXiaohongshuCollectionDriver(gui: gui))
            let statistics = try run.statistics()
            reportText = String(decoding: try pretty(statistics), as: UTF8.self) + "\n\n" + run.stopReason + "\n" + run.readingBudgetReceipt
            exportURL = try export(try xhsStore.export(id: id), name: "小红书采集-\(id).json")
            status = "已保存 \(run.notes.count) 条有来源的笔记、\(run.pending.count) 条待核验；\(run.status.rawValue)"
            gui.recordOutcome(run.status == .sampleReached ? .completed : .paused,result:status+"；"+run.stopReason+"；"+run.readingBudgetReceipt)
            return status + "；\(run.stopReason)。" + run.readingBudgetReceipt + "统计只覆盖实际采样，不代表全站。"
        } catch {
            gui.recordOutcome(error is CancellationError ? .paused : .failed,reason:error.localizedDescription)
            status = error is CancellationError ? "采集已取消；完整批次和检查点保留" : error.localizedDescription
            throw error
        }
    }
    func analyzeXHS(id: String) async throws {
        guard let model else { throw AgentError.message("请先配置已授权的模型") }
        status = "正在分析已保存的可见文字；数量与分布由本机复算"
        let run = try await XiaohongshuAnalysisService(store: xhsStore, model: model).analyze(taskID: id)
        let exportedData = try xhsStore.export(id: id)
        reportText = String(decoding: exportedData, as: UTF8.self)
        exportURL = try export(exportedData, name: "小红书分析-\(id).json")
        status = "已保存增量分析；\(run.notes.count) 条来源，未读媒体未纳入结论"
        objectWillChange.send()
    }
    func readChat(id: String, gui: PhoneWorkflowCaptureDriver, direction: ChatReadDirection = .older) async throws -> String {
        guard !hasPendingReview, let plan = chatPlans.first(where: { $0.id == id }) else { throw ChatEvidenceError.invalidRequest }
        if case .latest = plan.range { status = ChatEvidenceError.latestEndUnknown.localizedDescription; throw ChatEvidenceError.latestEndUnknown }
        if let prior = chatStore.sessions.first(where: { $0.id == id }) {
            guard prior.request.range == plan.range, prior.request.conversation.stableID == plan.stableID,
                  prior.request.conversation.title == plan.title else { throw ChatEvidenceError.invalidRequest }
            if case .currentPage = plan.range, prior.pageSelection != nil || !prior.frames.isEmpty || !prior.messages.isEmpty { throw ChatEvidenceError.pageAlreadyBound }
        }
        if case .currentPage = plan.range, direction != .older { throw ChatEvidenceError.invalidRequest }
        beginDiagnostics(id:id,gui:gui)
        defer {endDiagnostics(gui:gui)}
        let (firstFrame, firstSnapshot) = try await gui.read()
        let request: ChatReadRequest
        if let prior = chatStore.sessions.first(where: { $0.id == id }) { request = prior.request }
        else {
            request = ChatReadRequest(scopeID: id, conversation: .init(stableID: plan.stableID, title: plan.title, deviceKey: firstSnapshot.deviceKey), range: plan.range, maxPages: plan.maxPages)
        }
        status = "正在核对资料账号并读取固定范围；不会按昵称搜索其他人"
        defer { objectWillChange.send() }
        do {
            let session = try await conversationDriver(gui:gui, first:(firstFrame,firstSnapshot)).read(request:request,store:chatStore,direction:direction)
            reportText = String(decoding: try pretty(session), as: UTF8.self)
            exportURL = try export(try pretty(session), name: "聊天证据-\(id).json")
            status = "已纳入 \(session.selectedMessages.count) 条消息；\(session.state.rawValue)：\(session.detail)"
            gui.recordOutcome(.completed,result:status)
            return status
        } catch { gui.recordOutcome(error is CancellationError ? .paused : .failed,reason:error.localizedDescription); status = error is CancellationError ? "读取已取消，已保存批次；未宣称范围完整" : error.localizedDescription; throw error }
    }
    func summarizeChat(id: String) async throws -> String {
        let session = try chatStore.session(id: id)
        if session.isLatestEndUnknown { status = ChatEvidenceError.latestEndUnknown.localizedDescription; throw ChatEvidenceError.latestEndUnknown }
        guard !session.selectedMessages.isEmpty else { throw ChatEvidenceError.invalidSummary }
        guard let model else { throw AgentError.message("请先配置已授权的模型") }
        status = "正在分批总结已有证据；每条结论核对原消息引用"
        let report = try await ChatEvidenceSummarizer(model: model).summarize(sessionID: id, store: chatStore)
        reportText = report.markdown(); exportURL = try export(Data(reportText.utf8), name: "聊天总结-\(id).md")
        status = "已保存 \(report.claims.count) 条带引用结论；未读范围单独列出"
        objectWillChange.send(); return status
    }
    func savedTool(_ request: PhoneHarnessRequest, initial: ScreenFrame,
                   next: @escaping @MainActor (Date) async throws -> ScreenFrame) async throws -> PhoneHarnessReceipt {
        guard let id = request.target else { throw AgentError.message("缺已保存任务 ID") }
        let result: String
        switch request.operation {
        case .xhs_collect: result = try await collectXHS(id: id, gui: driver(initial: initial, next: next))
        case .chat_read: result = try await readChat(id: id, gui: driver(initial: initial, next: next))
        case .chat_read_newer: result = try await readChat(id: id, gui: driver(initial: initial, next: next), direction: .newer)
        case .chat_summarize: result = try await summarizeChat(id: id)
        case .file_send: result = try await automaticSend(id:id, gui:driver(initial:initial,next:next))
        case .file_status:
            guard let value = try fileStore.operation(id: id) else { throw AgentError.message("文件操作 ID 不存在") }
            result = String(decoding: try pretty(value), as: UTF8.self)
        default: throw AgentError.message("该操作不是已保存流程")
        }
        return .init(summary: result, verifiedFrame: nil, lastInputCompletedAt: nil, requiresUserReview: hasPendingReview)
    }
    var referencedFileIDs:[UUID] {filePlans.flatMap(\.artifactIDs)}
    func archiveArtifact(_ id:UUID) throws {
        guard !fileStore.hasActiveOperation else {throw FileTransferError.pendingReview}
        try fileStore.archive(id:id)
        status="已归档原件；既有计划和发送证据保持保留"
    }
    func restoreArtifact(_ id:UUID) throws {
        guard !fileStore.hasActiveOperation else {throw FileTransferError.pendingReview}
        try fileStore.restore(id:id);status="已恢复到原件列表"
    }
    func deleteArtifact(_ id:UUID) throws {
        try fileStore.deleteUnreferenced(id:id,referencedBySavedPlans:referencedFileIDs)
        status="已删除未被回执或计划引用的本机副本"
    }
    func importFiles(_ urls: [URL]) async throws {
        for url in urls {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            _ = try await fileStore.importFileAsync(at: url, sourceID: "native-import-" + UUID().uuidString,
                mediaType: (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? "public.data")
        }
        status = "已保存原始文件，内容摘要和大小已核对；未发送"
    }
    func nativeSend(artifactIDs: [UUID], recipientDescription: String) async throws {
        guard UIApplication.shared.applicationState == .active else { throw AgentError.message("请回到 Sela 前台选择分享目标") }
        let operationID=UUID().uuidString
        activeDiagnosticWorkflowID=operationID
        defer {activeDiagnosticWorkflowID=nil}
        let environment = FileTransferEnvironment(deviceKey: UIDevice.current.identifierForVendor?.uuidString ?? "unknown-host",
            accessoryKey: "native-share-no-BLE", captureSessionID: "native-ui-" + UUID().uuidString, foreground: true)
        let operation = try await FileTransferCoordinator(store: fileStore).beginNativeShare(operationID: operationID,
            taskID: UUID().uuidString, artifactIDs: artifactIDs, requestedRecipientDescription: recipientDescription, environment: environment,
            present: { [weak self] urls in
                guard let self else { return .dismissedOrUnknown }
                await self.recordNativeShareBoundary(operationID:operationID,reason:"系统分享即将呈现；可能提交的回执已保存")
                return await self.presentNative(urls)
            })
        if operation.pending {await recordNativeShareBoundary(operationID:operationID,reason:operation.detail)}
        reportText = String(decoding: try pretty(operation), as: UTF8.self)
        exportURL = try export(try fileStore.exportData(), name: "文件发送回执.json")
        status = "分享阶段：\(operation.stage.rawValue)。扩展回调不能证明收件人、送达或已读；请按实际结果核验。"
    }
    private func recordNativeShareBoundary(operationID:String,reason:String) async {
        guard capture.running,let frame=capture.frame,let captureID=frame.captureID,frame.fullDisplay else {
            diagnosticRecordingError="本次系统分享没有可用的整屏捕获，关键截图未记录；文件提交回执仍保留"
            return
        }
        do {
            let snapshot=try await harness.workflowSnapshot(frame)
            _ = try diagnostics.record(jpeg:frame.jpeg,context:.init(workflowID:operationID,operationID:operationID,boundary:.pendingSubmission,captureID:captureID,capturedAt:frame.capturedAt,confirmedAt:frame.confirmedAt,snapshot:snapshot,reason:String(reason.prefix(3000)),protectPendingSubmission:true))
            diagnosticRecordingError=""
        } catch {diagnosticRecordingError=error.localizedDescription}
    }
    private func presentNative(_ urls: [URL]) async -> FileTransferNativeShareResult {
        // Hashing a large original can outlast a foreground session. Do not
        // leave the continuation waiting for UI that cannot be presented.
        guard UIApplication.shared.applicationState == .active, !Task.isCancelled else { return .dismissedOrUnknown }
        let presentation = NativeFileSharePresentation(files: urls)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .dismissedOrUnknown); return }
                shareContinuation = continuation; sharePresentation = presentation
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finishNativeShare(id: presentation.id, result: .dismissedOrUnknown) } })
    }
    func finishNativeShare(id: UUID, result: FileTransferNativeShareResult, cancelled: Bool = false) {
        guard sharePresentation?.id == id else { return }
        let automatic = automaticPresentation; automaticPresentation = nil; automaticPresentationID = nil
        if cancelled { automatic?.resume(throwing: CancellationError()) }
        else { automatic?.resume(throwing: AgentError.message("系统分享已关闭，自动发送结果保留待核验")) }
        let continuation = shareContinuation; shareContinuation = nil; sharePresentation = nil
        continuation?.resume(returning: result)
    }
    func reviewFile(_ request:FileTransferReviewRequest) throws {
        guard let current=try fileStore.operation(id:request.operationID) else {throw FileTransferError.invalid("未知回执")}
        try request.validate(operation:current)
        let operation=try FileTransferCoordinator(store:fileStore).resolveReviewed(operationID:request.operationID,artifactIDs:request.artifactIDs,resolution:request.resolution,detail:request.detail)
        status="已保存 \(request.artifactIDs.count) 项人工核验；其余原件保持原状态，没有重发"
        reconcileDiagnosticProtection()
        do {
            reportText=String(decoding:try pretty(operation),as:UTF8.self)
            exportURL=try export(try fileStore.exportData(),name:"文件发送回执.json")
        } catch {
            exportURL=nil
            status += "；核验记录已保存，导出文件未生成："+error.localizedDescription
        }
    }
    func reconcileDiagnosticProtection() {
        do {_ = try FileTransferReviewDiagnostics.reconcile(fileStore:fileStore,diagnostics:diagnostics)}
        catch {diagnosticRecordingError=error.localizedDescription}
    }
    func showSavedXHS(_ id: String) throws {
        let exportedData = try xhsStore.export(id: id)
        reportText = String(decoding: exportedData, as: UTF8.self)
        exportURL = try export(exportedData, name: "小红书明细-\(id).json")
    }
    func showSavedChat(_ id: String) throws {
        let value = try chatStore.session(id: id)
        if let report = value.reports.last { reportText = report.markdown() }
        else { reportText = String(decoding: try pretty(value), as: UTF8.self) }
        exportURL = try export(try pretty(value), name: "聊天证据与总结-\(id).json")
    }
    private func conversationDriver(gui:PhoneWorkflowCaptureDriver, first:(ScreenFrame,PhoneUISnapshot)? = nil) -> WeChatConversationDriver {
        var initial = first
        return WeChatConversationDriver(read: {
            let frame:ScreenFrame,snapshot:PhoneUISnapshot
            if let value=initial {(frame,snapshot)=value;initial=nil} else {(frame,snapshot)=try await gui.read()}
            return .init(snapshot:snapshot,captureSessionID:frame.captureID!,frameID:"\(frame.captureID!.uuidString)-\(frame.capturedAt.timeIntervalSinceReferenceDate.bitPattern)",confirmedAt:frame.confirmedAt)
        },tap:{try await gui.tap($0)},scroll:{try await gui.scroll(older:$0 == .older)})
    }
    func completeXHSSource(id:String) async throws {
        guard UIApplication.shared.applicationState == .active else {throw XiaohongshuClipboardError.foregroundRequired}
        let clipboard = XiaohongshuClipboardSnapshot(changeCount:UIPasteboard.general.changeCount,text:UIPasteboard.general.string,readAt:Date())
        let run=try await XiaohongshuCollector(store:xhsStore).completeCopiedSource(taskID:id,clipboard:clipboard,resolveShortLink:XiaohongshuLinkResolver.resolve)
        try showSavedXHS(id);status="已用当前真实复制内容补齐来源：\(run.notes.count) 条；请重新核对目标页后续作"
    }
    func createAutomaticFilePlan(title:String, account:String, artifactIDs:[UUID]) throws -> String {
        _ = try fileStore.manifest(artifactIDs:artifactIDs)
        let id=UUID().uuidString
        let recipient:FileTransferRecipient
        if account.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,PhonePageAdapters.selfConversation(title) {
            recipient = .selfTransfer(artifactIDs:artifactIDs)
        } else {
            let stable = account.hasPrefix(WeChatContactIdentity.accountPrefix) ? account : try WeChatContactIdentity.stableID(account:account)
            _ = try WeChatContactIdentity.account(fromStableID:stable)
            recipient = .init(kind:.userSelectedStableAccount,stableID:stable,displayName:title,userSelectionEvidenceID:id,authorizedArtifactIDs:artifactIDs)
        }
        let plan=SavedAutomaticFileWorkflow(id:id,recipient:recipient,artifactIDs:artifactIDs,authorizedAt:Date())
        try plan.validate();try saveRegistry(xhs:xhsTasks,chats:chatPlans,files:filePlans+[plan])
        status="自动发送范围已保存，收件人仍需在实际扩展确认页独立核号";return id
    }
    @discardableResult func automaticSend(id:String, gui:PhoneWorkflowCaptureDriver) async throws -> String {
        guard UIApplication.shared.applicationState == .active else {throw AgentError.message("请回到本App前台，从已保存范围启动自动分享")}
        guard !shareHosts.isEmpty else {throw AgentError.message("请先打开工作台的长任务工作区，使真实系统分享能够呈现；尚未创建提交记录")}
        guard !blocksGUI,let plan=filePlans.first(where:{$0.id==id}) else {throw FileTransferError.pendingReview}
        try plan.validate()
        beginDiagnostics(id:id,gui:gui,operationID:plan.id)
        defer {endDiagnostics(gui:gui)}
        gui.menuPolicy=WeChatFileTransferPages.isAllowedMenu
        let (frame,snapshot)=try await gui.read()
        guard let accessory=executor.ble.selectedID else {throw FileTransferError.invalid("缺实际配件")}
        let environment=FileTransferEnvironment(deviceKey:snapshot.deviceKey,accessoryKey:accessory,captureSessionID:frame.captureID!.uuidString,foreground:true)
        let driver=WeChatFileTransferDriver(read:{ after in
            let (f,s)=try await gui.read(after:after)
            return .init(snapshot:s,captureSessionID:f.captureID!,frameID:"\(f.captureID!.uuidString)-\(f.capturedAt.timeIntervalSinceReferenceDate.bitPattern)",confirmedAt:f.confirmedAt)
        },tap:{try await gui.tap($0)},scroll:{try await gui.scroll(older:$0)},present:{[weak self] payload in
            guard let self else {throw CancellationError()}
            gui.protectSubmissionEvidence=true
            gui.recordOutcome(.pendingSubmission,reason:"已落盘并进入可能呈现/提交窗口；结果未知时不重开分享")
            return try await self.presentAutomaticShare(payload)
        },isPresented:{[weak self] id in self?.automaticPresentationID==id && self?.sharePresentation?.id==id},
        bootstrap:{[weak self] target in guard let self else {throw CancellationError()};return try await self.conversationDriver(gui:gui).bootstrap(target:target)})
        defer {if let presentation=sharePresentation,presentation.automaticPayload != nil {finishNativeShare(id:presentation.id,result:.dismissedOrUnknown)}}
        status="正在准备准确原件并自动核对实际扩展对象；提交窗口前已保存回执"
        let operation:FileTransferOperation
        do {
        operation=try await FileTransferCoordinator(store:fileStore).beginAutomaticNativeShare(operationID:plan.id,taskID:plan.id,recipient:plan.recipient,artifactIDs:plan.artifactIDs,environment:environment,automaticDriver:driver,validatePresentationEligibility:{ [weak self] in
            guard let self, UIApplication.shared.applicationState == .active,
                  !self.shareHosts.isEmpty,self.sharePresentation==nil else {
                throw AgentError.message("原件校验后已离开可呈现的前台工作区；尚未打开系统分享，请返回后重新启动同一范围")
            }
        })
        } catch {
            gui.recordOutcome(error is CancellationError ? .paused : .failed,reason:error.localizedDescription)
            throw error
        }
        reportText=String(decoding:try pretty(operation),as:UTF8.self)
        exportURL=try export(try fileStore.exportData(),name:"文件发送回执.json")
        status="自动流程：\(operation.stage.rawValue)；\(operation.detail)"
        gui.recordOutcome(operation.pending ? .pendingSubmission : .completed,result:status)
        return status
    }
    private func presentAutomaticShare(_ payload:FileTransferPayload) async throws -> WeChatNativeShareBinding {
        guard UIApplication.shared.applicationState == .active,!shareHosts.isEmpty,sharePresentation==nil else {throw AgentError.message("系统分享只能从当前前台启动一次")}
        let presentation=NativeFileSharePresentation(files:payload.fileURLs,automaticPayload:payload)
        let binding: WeChatNativeShareBinding
        do { binding = try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<WeChatNativeShareBinding,Error>) in
                if Task.isCancelled {continuation.resume(throwing:CancellationError());return}
                automaticPresentation=continuation;sharePresentation=presentation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds:12_000_000_000)
                    guard let self,self.sharePresentation?.id==presentation.id,self.automaticPresentation != nil else{return}
                    self.finishNativeShare(id:presentation.id,result:.dismissedOrUnknown)
                }
            }
        },onCancel:{Task { @MainActor [weak self] in self?.finishNativeShare(id:presentation.id,result:.dismissedOrUnknown,cancelled:true)}})
        } catch { try Task.checkCancellation(); throw error }
        try Task.checkCancellation()
        return binding
    }
    func nativeSharePresented(id:UUID) {
        guard let current=sharePresentation,current.id==id,let payload=current.automaticPayload,
              current.files==payload.fileURLs,let continuation=automaticPresentation else{return}
        automaticPresentation=nil;automaticPresentationID=id
        continuation.resume(returning:.init(presentationID:id,payload:payload,presentedAt:Date()))
    }
    private func pretty<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private func export(_ bytes: Data, name: String) throws -> URL {
        let directory = URL.documentsDirectory.appendingPathComponent("WorkflowExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return file
    }
}
