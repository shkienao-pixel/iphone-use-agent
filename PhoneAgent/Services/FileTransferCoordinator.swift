import Foundation

/// Production state machine shared by a native share sheet and a trusted GUI
/// driver. It commits the uncertain-submit boundary before calling any sender.
@MainActor final class FileTransferCoordinator {
    let store: FileTransferStore
    private let driver: (any FileTransferDriving)?
    init(store: FileTransferStore? = nil, driver: (any FileTransferDriving)? = nil) {
        self.store = store ?? .shared; self.driver = driver
    }

    @discardableResult func start(operationID: String, taskID: String, recipient: FileTransferRecipient,
                                  artifactIDs: [UUID], environment: FileTransferEnvironment) async throws -> FileTransferOperation {
        try store.claim(operationID: operationID); defer { store.release(operationID: operationID) }
        if let previous = try store.operation(id: operationID) {
            guard previous.manifest.map(\.id) == artifactIDs, previous.recipient == recipient else { throw FileTransferError.invalid("operation_id 已绑定其他文件或收件人") }
            return previous // New caller, task ID, or accessory never replays a receipt.
        }
        guard !store.hasPendingReview else { throw FileTransferError.pendingReview }
        let manifest = try store.manifest(artifactIDs: artifactIDs)
        try recipient.validate(artifactIDs: artifactIDs); try environment.validate()
        if let duplicate = duplicate(taskID: taskID, recipient: recipient, manifest: manifest) { return duplicate }
        var operation = makeOperation(id: operationID, taskID: taskID, recipient: recipient, manifest: manifest, environment: environment)
        try store.put(operation)
        operation = try await execute(operation, environment: environment)
        return operation
    }

    /// A pending operation is inspected ONCE without navigation/input/retry.
    /// Even if inspection establishes failure, a later explicit resume is needed
    /// to send the now-known unsent suffix. An unknown item blocks the whole batch.
    @discardableResult func resume(operationID: String, environment: FileTransferEnvironment) async throws -> FileTransferOperation {
        try store.claim(operationID: operationID); defer { store.release(operationID: operationID) }
        guard var operation = try store.operation(id: operationID) else { throw FileTransferError.invalid("未知 operation_id") }
        try environment.validate()
        if operation.pending {
            guard let driver else { return operation }
            let after = Date()
            do {
                let observations = try await driver.inspect(operation: operation, environment: environment, after: after)
                try apply(observations, to: &operation, environment: environment, after: after)
                try finish(&operation)
            } catch is CancellationError { throw CancellationError() }
            catch {
                operation.detail = "只读核查仍无确定结果：" + String(error.localizedDescription.prefix(500))
                operation.stage = .pendingReview; try checkpoint(&operation)
            }
            return operation
        }
        guard !store.hasPendingReview else { throw FileTransferError.pendingReview }
        guard !operation.cancelled, operation.stage != .complete else { return operation }
        guard operation.recipient.kind != .nativeShareRequestedUnverified else {
            // A native share always needs a new explicit user action. Never
            // launch another sheet from a generic resume/model request.
            return operation
        }
        return try await execute(operation, environment: environment)
    }

    /// Only a native user button calls this method. There is no claimed stable
    /// recipient binding: the extension owns recipient selection and may submit
    /// before completionHandler. Thus presenting the sheet is the send boundary.
    @discardableResult func beginNativeShare(operationID: String, taskID: String, artifactIDs: [UUID],
        requestedRecipientDescription: String, environment: FileTransferEnvironment,
        present: @MainActor ([URL]) async throws -> FileTransferNativeShareResult) async throws -> FileTransferOperation {
        try store.claim(operationID: operationID); defer { store.release(operationID: operationID) }
        guard !requestedRecipientDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              requestedRecipientDescription.count <= 120 else { throw FileTransferError.invalid("需保留用户要求的收件对象说明") }
        if let previous = try store.operation(id: operationID) {
            guard previous.manifest.map(\.id) == artifactIDs,
                  previous.recipient.displayName == requestedRecipientDescription,
                  previous.recipient.kind == .nativeShareRequestedUnverified else { throw FileTransferError.invalid("operation_id 已有其他业务绑定") }
            return previous
        }
        guard !store.hasPendingReview else { throw FileTransferError.pendingReview }
        try environment.validate()
        let manifest = try store.manifest(artifactIDs: artifactIDs)
        let recipient = FileTransferRecipient(kind: .nativeShareRequestedUnverified, stableID: "native-share:unverified",
            displayName: requestedRecipientDescription, userSelectionEvidenceID: nil, authorizedArtifactIDs: artifactIDs)
        if let duplicate = duplicate(taskID: taskID, recipient: recipient, manifest: manifest) { return duplicate }
        var operation = makeOperation(id: operationID, taskID: taskID, recipient: recipient, manifest: manifest, environment: environment)
        try store.put(operation)
        let payload = try await store.payloadAsync(manifest: manifest, bindingID: operation.payloadBindingID)
        do {
            try ensureActive(operation.operationID)
            try markSubmitting(&operation, artifactIDs: artifactIDs)
            let result = try await present(payload.fileURLs)
            switch result {
            case .extensionCompleted(let activityType):
                markUnknown(&operation)
                operation.detail = "分享扩展返回 completed（\(activityType ?? "未知扩展")）；收件人、原文件发送结果均未由扩展证明，保留待核验。不是对方收到或已读。"
            case .dismissedOrUnknown:
                markUnknown(&operation)
                operation.detail = "分享面板已关闭或回调不确定；扩展可能已提交，未自动重开或重发"
            case .confirmedNotSubmitted(let evidenceID):
                guard !evidenceID.isEmpty else { throw FileTransferError.invalid("缺独立的未提交证据") }
                for index in operation.items.indices { operation.items[index].state = .confirmedFailed }
                operation.stage = .cancelled; operation.cancelled = true
                operation.detail = "原生 UI 独立确认尚未提交：" + String(evidenceID.prefix(300))
            }
            try checkpoint(&operation); try Task.checkCancellation()
            return operation
        } catch {
            if operation.pending {
                markUnknown(&operation); operation.detail = "分享可能已经打开/提交，但未完成独立核验；中断后禁止自动重开或重发"
            } else {
                operation.stage = .cancelled; operation.cancelled = true; operation.detail = "分享调用前已中断，没有派发分享"
            }
            try checkpoint(&operation)
            if error is CancellationError { throw CancellationError() }
            return operation
        }
    }

    /// Actual automatic native-extension path. The saved recipient is an
    /// expectation until the driver independently verifies the extension's
    /// CURRENT stable-account confirmation screen. Presentation itself is an
    /// uncertain submission boundary and is therefore journaled first.
    @discardableResult func beginAutomaticNativeShare(operationID: String, taskID: String, recipient: FileTransferRecipient,
        artifactIDs: [UUID], environment: FileTransferEnvironment,
        automaticDriver: any FileTransferAutomaticNativeDriving,
        validatePresentationEligibility: @MainActor () throws -> Void = {}) async throws -> FileTransferOperation {
        try store.claim(operationID: operationID); defer { store.release(operationID: operationID) }
        if let previous = try store.operation(id: operationID) {
            guard previous.manifest.map(\.id) == artifactIDs, previous.recipient == recipient else { throw FileTransferError.invalid("operation_id 已绑定其他原件或收件对象") }
            return previous
        }
        guard !store.hasPendingReview, recipient.kind != .nativeShareRequestedUnverified else { throw FileTransferError.pendingReview }
        try recipient.validate(artifactIDs: artifactIDs); try environment.validate()
        let manifest = try store.manifest(artifactIDs: artifactIDs)
        if let duplicate = duplicate(taskID: taskID, recipient: recipient, manifest: manifest) { return duplicate }
        var operation = makeOperation(id: operationID, taskID: taskID, recipient: recipient, manifest: manifest, environment: environment)
        let payload = try await store.payloadAsync(manifest: manifest, bindingID: operation.payloadBindingID)
        // Large originals may finish hashing after the native host disappears
        // or the app backgrounds. This synchronous host check is deliberately
        // BEFORE the first operation checkpoint and any possible presentation.
        // A rejection here has no uncertain side effect and leaves this plan
        // available for a later explicit launch using the same operation ID.
        try Task.checkCancellation()
        try validatePresentationEligibility()
        try Task.checkCancellation()
        try store.put(operation)
        do {
            try ensureActive(operationID)
            try markSubmitting(&operation, artifactIDs: artifactIDs)
            var confirmedSelection: FileTransferSelectionEvidence?
            let submitted = try await automaticDriver.presentAndSubmit(payload: payload, recipient: recipient, environment: environment) { selection in
                try self.ensureActive(operationID)
                try selection.context.validate(environment: environment, after: operation.items.compactMap(\.submittedAt).min() ?? operation.createdAt)
                try selection.recipient.validate(recipient: recipient)
                guard selection.selectedCount == manifest.count, selection.files.count == manifest.count else { throw FileTransferError.invalid("扩展确认原件数量不符") }
                for (file, item) in zip(selection.files, manifest) { try file.validate(item: item, bindingID: payload.bindingID) }
                operation.lastSelection = selection
                operation.detail = "扩展当前准确账号、原件清单及顺序已核对；发送即将派发一次"
                try self.checkpoint(&operation); confirmedSelection = selection
            }
            guard confirmedSelection == submitted.selection else { throw FileTransferError.invalid("实际派发前未持久化准确选择证据") }
            markUnknown(&operation)
            operation.detail = "自动流程已在扩展精确身份确认页派发一次发送；实际收件结果仍待独立核验，不能从回调推断送达/已读"
            try checkpoint(&operation); try Task.checkCancellation()
            let after = Date()
            let results = try await automaticDriver.inspect(operation: operation, environment: environment, after: after)
            try apply(results, to: &operation, environment: environment, after: after)
            try finish(&operation); return operation
        } catch {
            if operation.pending {
                markUnknown(&operation); operation.detail = "原生分享已进入可能提交窗口，结果待核验；不重开、不重发：" + String(error.localizedDescription.prefix(700))
            } else { operation.stage = .cancelled; operation.cancelled = true; operation.detail = "呈现分享前已停止" }
            try checkpoint(&operation)
            if error is CancellationError { throw CancellationError() }
            return operation
        }
    }

    @discardableResult func cancel(operationID: String) throws -> FileTransferOperation {
        guard var operation = try store.operation(id: operationID) else { throw FileTransferError.invalid("未知 operation_id") }
        operation.cancelled = true
        if operation.pending {
            markUnknown(&operation); operation.detail = "用户已取消后续动作；已有提交仍待核验，取消不能证明未发送"
        } else { operation.stage = .cancelled; operation.detail = "用户已取消；没有继续选择或发送" }
        try checkpoint(&operation); return operation
    }

    /// This is a separate human finding, never promoted to automatic file hash,
    /// stable recipient verification, delivery, or read evidence.
    @discardableResult func resolveReviewed(operationID: String, resolution: FileTransferHumanResolution,
                                            detail: String) throws -> FileTransferOperation {
        guard let operation = try store.operation(id: operationID) else { throw FileTransferError.invalid("未知 operation_id") }
        return try resolveReviewed(operationID: operationID, artifactIDs: operation.items.filter(\.pending).map(\.artifactID),
                                   resolution: resolution, detail: detail)
    }
    /// Individual human findings support mixed multi-file outcomes. Resolving
    /// one item never silently clears another item's unknown state.
    @discardableResult func resolveReviewed(operationID: String, artifactIDs: [UUID], resolution: FileTransferHumanResolution,
                                            detail: String) throws -> FileTransferOperation {
        guard !store.hasActiveOperation, var operation = try store.operation(id: operationID), operation.pending,
              !artifactIDs.isEmpty, Set(artifactIDs).count == artifactIDs.count,
              Set(artifactIDs).isSubset(of: Set(operation.items.filter(\.pending).map(\.artifactID))),
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, detail.count <= 1000 else {
            throw FileTransferError.invalid("没有待核验原件，或缺用户核验说明")
        }
        // Keep room for a definitive finding for every original. Repeated
        // unknown notes must not fill the audit budget and lock a batch forever.
        if resolution == .stillUnknown, (operation.humanReviews?.count ?? 0) >= 450 {
            throw FileTransferError.invalid("未知状态已保留；重复未知说明达到上限，请在独立核实后记录确定结果")
        }
        for index in operation.items.indices where artifactIDs.contains(operation.items[index].artifactID) {
            switch resolution {
            case .userReportsSubmitted: operation.items[index].state = .userReportedSubmitted
            case .userConfirmsNotSubmitted: operation.items[index].state = .confirmedFailed
            case .stillUnknown: operation.items[index].state = .unknown
            }
        }
        let review = FileTransferHumanReview(id:UUID(),artifactIDs:artifactIDs,resolution:resolution,detail:detail,reviewedAt:Date())
        operation.humanReviews = (operation.humanReviews ?? []) + [review]
        operation.stage = operation.pending ? .pendingReview : .partial
        operation.detail = "用户独立核验（\(resolution.rawValue)，\(artifactIDs.count) 项）：" + detail + "。仅记录用户报告；未自动推断送达/已读，未派发动作。"
        try checkpoint(&operation); return operation
    }

    private func execute(_ prior: FileTransferOperation, environment: FileTransferEnvironment) async throws -> FileTransferOperation {
        var operation = prior
        guard let driver else {
            operation.stage = .unsupported; operation.detail = "当前没有可核验稳定收件人及原件选择身份的 GUI 适配器；可由用户显式使用原生分享，并保留待核验回执"
            try checkpoint(&operation); return operation
        }
        guard !operation.pending, !store.hasPendingReview else { throw FileTransferError.pendingReview }
        // Preserve sequence on retry. Retrying an earlier failed item after a
        // later successful item would change the requested original order.
        var unsentSeen = false
        for item in operation.items {
            if item.state == .notSubmitted || item.state == .confirmedFailed { unsentSeen = true }
            else if unsentSeen && [.observedSent, .userReportedSubmitted].contains(item.state) {
                operation.stage = .unsupported; operation.detail = "较早文件失败而较后文件已提交；补发会改变原始顺序，停止自动补发"
                try checkpoint(&operation); return operation
            }
        }
        let eligibleIDs = operation.retryableArtifactIDs
        guard !eligibleIDs.isEmpty else { try finish(&operation); return operation }
        let manifest = operation.manifest.filter { eligibleIDs.contains($0.id) }
        operation.environment = environment
        // A new preparation gets a new binding; the original per-file ordinals
        // remain intact, even when only an unsent suffix is selected.
        operation.payloadBindingID = UUID()
        let payload = try await store.payloadAsync(manifest: manifest, bindingID: operation.payloadBindingID)
        do {
            try ensureActive(operation.operationID); try environment.validate()
            operation.stage = .locating; operation.detail = "按 sourceID/原件 SHA256 找资料；尚未提交"; try checkpoint(&operation)
            let located = try await driver.locate(payload: payload, recipient: operation.recipient, environment: environment)
            guard located.count == manifest.count, Set(located.map(\.handle)).count == located.count,
                  located.allSatisfy({ !$0.handle.isEmpty }) else { throw FileTransferError.invalid("查找结果缺失或不唯一") }
            for (file, item) in zip(located, manifest) { try file.identity.validate(item: item, bindingID: payload.bindingID) }
            try ensureActive(operation.operationID)
            operation.stage = .selecting; operation.detail = "已找到原件，批量选择；此阶段禁止任何发送/分享扩展提交"; try checkpoint(&operation)
            try await driver.select(files: located, payload: payload, recipient: operation.recipient, environment: environment)
            try ensureActive(operation.operationID)
            // Rehash off the UI actor, then acquire the fresh selection frame.
            _ = try await store.payloadAsync(manifest: manifest, bindingID: payload.bindingID)
            try ensureActive(operation.operationID)
            let after = Date()
            let selected = try await driver.observeSelection(payload: payload, recipient: operation.recipient, environment: environment, after: after)
            try selected.context.validate(environment: environment, after: after)
            try selected.recipient.validate(recipient: operation.recipient)
            guard selected.selectedCount == manifest.count, selected.files.count == manifest.count else { throw FileTransferError.invalid("实际选择数量不符") }
            for (evidence, item) in zip(selected.files, manifest) { try evidence.validate(item: item, bindingID: payload.bindingID) }
            operation.lastSelection = selected; operation.stage = .selectionVerified
            operation.detail = "逐项核对原件内容、顺序、质量及当前稳定收件人；尚未提交"; try checkpoint(&operation)
            try selected.context.validate(environment: environment, after: after)
            try ensureActive(operation.operationID)
            try markSubmitting(&operation, artifactIDs: eligibleIDs)
            let dispatch = try await driver.submit(payload: payload, recipient: operation.recipient, selection: selected, environment: environment)
            operation.detail = "提交已派发一次（\(dispatch.signal.rawValue)）；等待上传和原对象消息证据，不代表送达/已读"
            markUnknown(&operation); try checkpoint(&operation)
            try Task.checkCancellation()
            // A cancelled operation may still be inspected read-only but no
            // further driver input is ever called from this point.
            let inspectAfter = Date()
            let observations = try await driver.inspect(operation: operation, environment: environment, after: inspectAfter)
            try apply(observations, to: &operation, environment: environment, after: inspectAfter)
            try finish(&operation); return operation
        } catch {
            if operation.pending { markUnknown(&operation); operation.detail = "已跨提交边界，结果待核验；禁止自动重发：" + String(error.localizedDescription.prefix(500)) }
            else {
                operation.stage = (error is CancellationError) ? .cancelled : .unsupported
                operation.cancelled = operation.cancelled || error is CancellationError
                operation.detail = "提交前停止：" + String(error.localizedDescription.prefix(500))
            }
            try checkpoint(&operation)
            if error is CancellationError { throw CancellationError() }
            return operation
        }
    }

    private func makeOperation(id: String, taskID: String, recipient: FileTransferRecipient,
                               manifest: [FileTransferManifestItem], environment: FileTransferEnvironment) -> FileTransferOperation {
        FileTransferOperation(operationID: id, taskID: taskID, recipient: recipient, manifest: manifest,
            environment: environment, payloadBindingID: UUID(), items: manifest.map { FileTransferItemProgress(artifactID: $0.id) },
            createdAt: Date(), updatedAt: Date())
    }
    private func duplicate(taskID: String, recipient: FileTransferRecipient, manifest: [FileTransferManifestItem]) -> FileTransferOperation? {
        store.operations.first { $0.taskID == taskID && $0.recipient == recipient && $0.manifest == manifest &&
            ($0.pending || $0.items.contains { [.observedSent, .userReportedSubmitted].contains($0.state) }) }
    }
    private func ensureActive(_ operationID: String) throws {
        try Task.checkCancellation()
        guard let latest = try store.operation(id: operationID), !latest.cancelled else { throw CancellationError() }
        guard !store.pendingOperations.contains(where: { $0.operationID != operationID }) else { throw FileTransferError.pendingReview }
    }
    private func checkpoint(_ operation: inout FileTransferOperation) throws {
        if let latest = try store.operation(id: operation.operationID), latest.cancelled { operation.cancelled = true }
        operation.updatedAt = Date(); try store.put(operation)
    }
    private func markSubmitting(_ operation: inout FileTransferOperation, artifactIDs: [UUID]) throws {
        let now = Date()
        for index in operation.items.indices where artifactIDs.contains(operation.items[index].artifactID) {
            guard [.notSubmitted, .confirmedFailed].contains(operation.items[index].state) else { throw FileTransferError.pendingReview }
            operation.items[index].state = .submissionPending; operation.items[index].submittedAt = now; operation.items[index].attemptCount += 1
        }
        operation.stage = .submissionPending; operation.detail = "提交/分享即将派发；先落盘，进程终止/取消/回调缺失均不得自动重发"
        try checkpoint(&operation)
    }
    private func markUnknown(_ operation: inout FileTransferOperation) {
        for index in operation.items.indices where operation.items[index].pending { operation.items[index].state = .unknown }
        operation.stage = .pendingReview
    }
    private func apply(_ observations: [FileTransferResultEvidence], to operation: inout FileTransferOperation,
                       environment: FileTransferEnvironment, after: Date) throws {
        // Validate every observation before changing any item; one wrong object
        // invalidates the entire batch of result evidence.
        guard Set(observations.map { $0.file.artifactID }).count == observations.count else { throw FileTransferError.invalid("结果中同一文件重复") }
        for observation in observations {
            try observation.context.validate(environment: environment, after: after)
            try observation.recipient.validate(recipient: operation.recipient)
            guard let item = operation.manifest.first(where: { $0.id == observation.file.artifactID }),
                  let progress = operation.items.first(where: { $0.artifactID == item.id }), progress.pending else { throw FileTransferError.invalid("结果不属于待核验原件") }
            if observation.status == .unknown && [.metadataOnly, .unknown].contains(observation.file.identityLevel) {
                guard observation.file.artifactID == item.id, observation.file.ordinal == item.ordinal,
                      observation.file.filename == item.artifact.filename, observation.file.sha256 == nil,
                      observation.visibleEvidenceJSON != nil else { throw FileTransferError.invalid("未知结果的元数据证据不完整或伪装内容hash") }
            } else { try observation.file.validate(item: item, bindingID: operation.payloadBindingID) }
            if observation.status == .outgoingMessageObserved {
                guard let message = observation.messageID, !message.isEmpty,
                      !operation.items.contains(where: { $0.artifactID != item.id && $0.messageID == message }),
                      !observations.contains(where: { $0.file.artifactID != item.id && $0.messageID == message }) else { throw FileTransferError.invalid("缺唯一原对象发送消息锚点") }
            }
            if [.confirmedNotSent, .notSubmittedConfirmed].contains(observation.status) {
                guard !observation.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileTransferError.invalid("缺明确未提交/失败依据") }
            }
        }
        for observation in observations {
            guard let index = operation.items.firstIndex(where: { $0.artifactID == observation.file.artifactID }) else { continue }
            operation.items[index].evidence = observation
            switch observation.status {
            case .notSubmittedConfirmed, .confirmedNotSent: operation.items[index].state = .confirmedFailed
            case .uploading: operation.items[index].state = .uploading
            case .outgoingMessageObserved: operation.items[index].state = .observedSent; operation.items[index].messageID = observation.messageID
            case .unknown: operation.items[index].state = .unknown
            }
        }
    }
    private func finish(_ operation: inout FileTransferOperation) throws {
        if operation.pending {
            operation.stage = operation.items.contains(where: { $0.state == .uploading }) ? .uploading : .pendingReview
            operation.detail = "仍有上传中/未知文件；只读核查后仍未知则停止，不能补发未知项"
        } else if operation.items.allSatisfy({ $0.state == .observedSent }) {
            operation.stage = .complete; operation.detail = "每个原文件均有绑定原会话的独立发送消息证据；只证明当前 App 可见提交，不代表对方收到或已读"
        } else { operation.stage = .partial; operation.detail = "部分文件已核验；仅明确未提交/确认失败的后缀允许再次准备，已提交项不会重发" }
        try checkpoint(&operation)
    }
}
