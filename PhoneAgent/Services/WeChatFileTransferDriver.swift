import Foundation

/// Actual page/controller adapter. Its injectable seam is only raw current
/// observations, observed-element taps and a real native presentation; tests
/// therefore exercise production page parsing and the send boundary itself.
@MainActor final class WeChatFileTransferDriver: FileTransferAutomaticNativeDriving {
    /// The native presentation/inspection watermark must reach the real capture
    /// adapter; a merely recent frame can still predate the native event.
    typealias Read = @MainActor (Date) async throws -> WeChatFileTransferObservation
    typealias Tap = @MainActor (PhoneUIElement) async throws -> Void
    typealias Scroll = @MainActor (Bool) async throws -> Void
    typealias Present = @MainActor (FileTransferPayload) async throws -> WeChatNativeShareBinding
    typealias Bootstrap = @MainActor (ChatConversationTarget) async throws -> ChatEvidenceFrame
    private let readObservation: Read
    private let tapElement: Tap
    private let scrollPage: Scroll
    private let present: Present
    private let isPresented: @MainActor (UUID) -> Bool
    private let bootstrap: Bootstrap?
    private var previousObservation: WeChatFileTransferObservation?
    private var selectedPickerObservation: WeChatFileTransferObservation?
    private var nativeBinding: WeChatNativeShareBinding?
    private var submitted = false
    private var active = false

    init(read: @escaping Read, tap: @escaping Tap, scroll: @escaping Scroll,
         present: @escaping Present, isPresented: @escaping @MainActor (UUID) -> Bool,
         bootstrap: Bootstrap? = nil) {
        self.readObservation = read; self.tapElement = tap; self.scrollPage = scroll
        self.present = present; self.isPresented = isPresented; self.bootstrap = bootstrap
    }

    func presentAndSubmit(payload: FileTransferPayload, recipient: FileTransferRecipient,
        environment: FileTransferEnvironment,
        confirmSelection: @MainActor (FileTransferSelectionEvidence) throws -> Void) async throws -> FileTransferAutomaticSubmission {
        guard !active, !submitted else { throw FileTransferError.pendingReview }
        active = true; defer { active = false }
        try recipient.validate(artifactIDs: payload.manifest.map(\.id)); try environment.validate()
        try Task.checkCancellation()
        // The coordinator has already persisted submissionPending. Calling
        // present may let a human submit, so any failure from here is UNKNOWN.
        let binding = try await present(payload)
        try binding.validate(payload: payload); nativeBinding = binding
        try requirePresented(binding.presentationID)
        var current = try await read(environment: environment, after: binding.presentedAt)
        if let activity = WeChatFileTransferPages.activity(in: current.snapshot) {
            try requirePresented(binding.presentationID)
            try await tap(activity, in: current)
            current = try await read(environment: environment, after: current.snapshot.capturedAt)
        }
        // A normal extension that exposes only nicknames is intentionally
        // unsupported; choosing such a quick-send row could itself send.
        if let row = WeChatFileTransferPages.recipientRow(recipient, in: current.snapshot) {
            try requirePresented(binding.presentationID)
            try await tap(row, in: current)
            current = try await read(environment: environment, after: current.snapshot.capturedAt)
            if WeChatFileTransferPages.recipient(recipient, in: current.snapshot) != nil,
               let next = WeChatFileTransferPages.unique(["下一步", "Next"], in: current.snapshot) {
                try requirePresented(binding.presentationID)
                try await tap(next, in: current)
                current = try await read(environment: environment, after: current.snapshot.capturedAt)
            }
        }
        let confirmation = try WeChatFileTransferPages.confirmation(payload: payload, recipient: recipient, in: current.snapshot)
        let selection = FileTransferSelectionEvidence(context: evidenceContext(current, environment: environment),
            recipient: confirmation.recipient, files: payload.manifest.map { originalEvidence($0, binding: payload.bindingID) },
            selectedCount: payload.manifest.count, visibleEvidenceJSON: try WeChatFileTransferPages.encodedSnapshot(current))
        try selection.context.validate(environment: environment, after: binding.presentedAt)
        try requirePresented(binding.presentationID)
        // Persist the ACTUAL current extension proof before the sole Send tap.
        try confirmSelection(selection)
        try Task.checkCancellation(); try requirePresented(binding.presentationID)
        submitted = true // Mark before the HID dispatch, including cancellation.
        try await tap(confirmation.send, in: current)
        return .init(selection: selection, dispatch: .init(signal: .dispatched,
            detail: "原生URL payload真实绑定；当前扩展账号、原文件模式、完整文件名/精确字节数/顺序已核对，发送控件仅派发一次；不证明远端原件或收到/已读"))
    }

    /// Standard WeChat file-picker route. locate authenticates LOCAL bytes,
    /// never the bytes of an external picker row. select then navigates actual
    /// pages; observeSelection deliberately reports metadataOnly. Coordinator
    /// will stop before submit because a Files row/path is no content hash.
    func locate(payload: FileTransferPayload, recipient: FileTransferRecipient,
                environment: FileTransferEnvironment) async throws -> [FileTransferLocatedFile] {
        try recipient.validate(artifactIDs: recipient.authorizedArtifactIDs); try environment.validate()
        guard payload.manifest.count == payload.fileURLs.count else { throw FileTransferError.invalid("原件URL数量") }
        let worker = Task.detached {
            try zip(payload.manifest, payload.fileURLs).map { item, url -> UUID in
                let digest = try FileTransferArtifact.digestFile(url)
                guard digest.0 == item.artifact.sha256, digest.1 == item.artifact.byteCount else { throw FileTransferError.invalid("本机原件已变更") }
                return item.id
            }
        }
        let verified = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard verified == payload.manifest.map(\.id) else { throw FileTransferError.invalid("本机原件顺序") }
        return payload.manifest.map { item in
            var evidence = originalEvidence(item, binding: payload.bindingID); evidence.identityLevel = .exactBytes
            return .init(handle: "local-original:" + item.id.uuidString, identity: evidence)
        }
    }
    func select(files: [FileTransferLocatedFile], payload: FileTransferPayload, recipient: FileTransferRecipient,
                environment: FileTransferEnvironment) async throws {
        guard !active, !submitted, files.map({ $0.identity.artifactID }) == payload.manifest.map(\.id) else { throw FileTransferError.pendingReview }
        active = true; defer { active = false }
        let target = ChatConversationTarget(stableID: recipient.kind == .builtinSelfTransfer ? (PhonePageAdapters.canonicalConversation(recipient.displayName) ?? "") : recipient.stableID,
            title: recipient.displayName, deviceKey: environment.deviceKey)
        let initial: ChatEvidenceFrame
        if let bootstrap { initial = try await bootstrap(target) }
        else if recipient.kind == .builtinSelfTransfer {
            let observation = try await read(environment: environment, after: .distantPast)
            var frame = try ChatEvidenceFrame.from(snapshot: observation.snapshot, id: observation.frameID)
            frame.captureSessionID = observation.captureSessionID; initial = frame
        } else { throw FileTransferError.unsupported("普通联系人需要真实个人资料微信号到聊天的受控导航") }
        try initial.validate(for: target)
        guard initial.captureSessionID?.uuidString == environment.captureSessionID else { throw FileTransferError.invalid("联系人导航共享已改变") }
        // Every navigation step reads current OCR; there are no coordinates,
        // fixed row indices, remote-model decisions, or automatic retry taps.
        var current = try await read(environment: environment, after: initial.snapshot.capturedAt)
        guard let currentPage = WeChatContactIdentity.chatPage(snapshot: current.snapshot, title: target.title),
              let oldPage = WeChatContactIdentity.chatPage(snapshot: initial.snapshot, title: target.title),
              !oldPage.messages.isEmpty, PhonePageAdapters.retainsMessageAnchors(oldPage, after: currentPage),
              let more = WeChatFileTransferPages.more(in: current.snapshot) else {
            throw FileTransferError.unsupported("当前会话缺独立连续锚点或明确附件入口，未点击旧位置")
        }
        try await tap(more, in: current); current = try await read(environment: environment, after: current.snapshot.capturedAt)
        guard let file = WeChatFileTransferPages.fileMenu(in: current.snapshot) else { throw FileTransferError.unsupported("未识别附件菜单的文件入口") }
        try await tap(file, in: current); current = try await read(environment: environment, after: current.snapshot.capturedAt)
        if let phone = WeChatFileTransferPages.phoneFiles(in: current.snapshot) {
            try await tap(phone, in: current); current = try await read(environment: environment, after: current.snapshot.capturedAt)
        }
        guard WeChatFileTransferPages.filePicker(in: current.snapshot) else { throw FileTransferError.unsupported("没有独立系统Files浏览器结构") }
        selectedPickerObservation = current
        // Do NOT tap external file rows. A single-document picker may return
        // to WeChat and submit immediately; its filename/size is insufficient
        // to establish byte custody, even for a folder created by this app.
    }
    func observeSelection(payload: FileTransferPayload, recipient: FileTransferRecipient,
                          environment: FileTransferEnvironment, after: Date) async throws -> FileTransferSelectionEvidence {
        guard selectedPickerObservation != nil else { throw FileTransferError.unsupported("没有当前外部文件选择器") }
        let current = try await read(environment: environment, after: after)
        guard WeChatFileTransferPages.filePicker(in: current.snapshot) else { throw FileTransferError.unsupported("外部选择器已改变") }
        let files = payload.manifest.map { item -> FileTransferFileEvidence in
            FileTransferFileEvidence(artifactID: item.id, sourceID: nil, filename: item.artifact.filename, mediaType: nil,
                byteCount: nil, sha256: nil, ordinal: item.ordinal, identityLevel: .metadataOnly,
                payloadBindingID: nil, originalBytesPreserved: false)
        }
        return .init(context: evidenceContext(current, environment: environment), recipient: .init(stableID: nil, basis: .unknown,
            conversationEvidenceID: current.frameID), files: files, selectedCount: 0,
            visibleEvidenceJSON: try WeChatFileTransferPages.encodedSnapshot(current))
    }
    func submit(payload: FileTransferPayload, recipient: FileTransferRecipient, selection: FileTransferSelectionEvidence,
                environment: FileTransferEnvironment) async throws -> FileTransferDispatchReceipt {
        throw FileTransferError.unsupported("跨App Files仅元数据，不能证明选中原件；使用ledger先落盘的原生URL分享路径")
    }

    /// Read-only result inspection never treats a filename bubble or extension
    /// completed callback as a remote byte/delivery receipt. Visible metadata
    /// is archived as UNKNOWN, with no copied/invented observed SHA256.
    func inspect(operation: FileTransferOperation, environment: FileTransferEnvironment,
                 after: Date) async throws -> [FileTransferResultEvidence] {
        let current = try await read(environment: environment, after: after)
        guard let recipient = WeChatFileTransferPages.recipient(operation.recipient, in: current.snapshot) else { return [] }
        let encoded = try WeChatFileTransferPages.encodedSnapshot(current)
        return operation.manifest.filter { item in operation.items.contains { $0.artifactID == item.id && $0.pending } }.map { item in
            let visible = WeChatFileTransferPages.unique([item.artifact.filename], in: current.snapshot)
            let uploading = WeChatFileTransferPages.unique(["上传中", "Uploading", "发送中", "Sending"], in: current.snapshot)
            return FileTransferResultEvidence(context: evidenceContext(current, environment: environment), recipient: recipient,
                file: .init(artifactID: item.id, sourceID: nil, filename: item.artifact.filename, mediaType: nil,
                    byteCount: nil, sha256: nil, ordinal: item.ordinal, identityLevel: .metadataOnly,
                    payloadBindingID: nil, originalBytesPreserved: false), status: .unknown,
                messageID: visible.map { current.frameID + ":" + $0.id },
                detail: uploading != nil ? "当前页面可见上传/发送中，但仅文件名元数据无法独立证明该原件；保留unknown" : "当前可见文件名/扩展结果仅是元数据；不可见的远端内容hash、提交、送达、已读均未推断",
                visibleEvidenceJSON: encoded)
        }
    }

    private func read(environment: FileTransferEnvironment, after: Date) async throws -> WeChatFileTransferObservation {
        try Task.checkCancellation()
        let value = try await readObservation(after)
        let now = Date()
        let checks: [(String, Bool)] = [
            ("overlayClear", !value.snapshot.blockingOverlay),
            ("captureSessionMatches", value.captureSessionID.uuidString == environment.captureSessionID),
            ("deviceKeyMatches", value.snapshot.deviceKey == environment.deviceKey),
            ("frameIDPresent", !value.frameID.isEmpty),
            ("pixelBeforeConfirmation", value.snapshot.capturedAt <= value.effectiveConfirmedAt),
            ("confirmationFresh", now.timeIntervalSince(value.effectiveConfirmedAt) <= 1.5),
            ("confirmationNotTooFarFuture", value.effectiveConfirmedAt <= now.addingTimeInterval(2)),
            ("confirmationAfterBoundary", value.effectiveConfirmedAt > after),
            ("confirmationAfterPrevious", previousObservation.map({ value.effectiveConfirmedAt > $0.effectiveConfirmedAt }) ?? true)
        ]
        let failed = checks.filter { !$0.1 }.map(\.0)
        guard failed.isEmpty else {
            // Field names only: no account/device IDs, OCR text, screenshots or
            // file contents enter the failure receipt. Never retime this frame.
            throw FileTransferError.invalid("真实新画面、手机或capture session不符；failedFields=" + failed.joined(separator: ","))
        }
        try evidenceContext(value, environment: environment).validate(environment: environment, after: after)
        previousObservation = value; return value
    }
    private func tap(_ element: PhoneUIElement, in observation: WeChatFileTransferObservation) async throws {
        try Task.checkCancellation()
        guard observation.snapshot.element(id: element.id) == element, previousObservation?.frameID == observation.frameID,
              (element.source == "ocr" || (element.source == "local_visual" && element.label == "视觉:添加")),
              Date().timeIntervalSince(observation.effectiveConfirmedAt) < 1.5 else {
            throw FileTransferError.invalid("点击目标不属于刚读取的真实OCR画面")
        }
        try await tapElement(element); try Task.checkCancellation()
    }
    private func requirePresented(_ id: UUID) throws {
        try Task.checkCancellation()
        guard isPresented(id) else { throw FileTransferError.pendingReview }
    }
    private func evidenceContext(_ observation: WeChatFileTransferObservation, environment: FileTransferEnvironment) -> FileTransferEvidenceContext {
        .init(evidenceID: observation.frameID, capturedAt: observation.snapshot.capturedAt, environment: environment, confirmedAt: observation.effectiveConfirmedAt)
    }
    private func originalEvidence(_ item: FileTransferManifestItem, binding: UUID) -> FileTransferFileEvidence {
        .init(artifactID: item.id, sourceID: item.artifact.sourceID, filename: item.artifact.filename,
            mediaType: item.artifact.mediaType, byteCount: item.artifact.byteCount, sha256: item.artifact.sha256,
            ordinal: item.ordinal, identityLevel: .managedOriginalBytes, payloadBindingID: binding, originalBytesPreserved: true)
    }
}
