import Foundation

@MainActor final class FixtureDriver: FileTransferDriving {
    enum Fault { case none, wrongRecipient, wrongHash, metadataOnly, wrongOrder, compressed, stale, submitInterrupted, wrongResultRecipient, duplicateMessage }
    var fault = Fault.none
    var submissions: [[UUID]] = []
    var selected: [[UUID]] = []
    var resultRounds: [[FileTransferResultEvidence.Status]] = []
    var onSelect: (() throws -> Void)?
    var onSubmit: (() throws -> Void)?
    var store: FileTransferStore
    var operationID: String
    var inspections = 0
    var locatedBytes = 0
    init(store: FileTransferStore, operationID: String) { self.store = store; self.operationID = operationID }
    func identity(_ item: FileTransferManifestItem, binding: UUID) -> FileTransferFileEvidence {
        FileTransferFileEvidence(artifactID: item.id, sourceID: item.artifact.sourceID, filename: item.artifact.filename,
            mediaType: item.artifact.mediaType, byteCount: item.artifact.byteCount, sha256: item.artifact.sha256,
            ordinal: item.ordinal, identityLevel: .exactBytes, payloadBindingID: binding, originalBytesPreserved: true)
    }
    func recipient(_ requested: FileTransferRecipient) -> FileTransferRecipientEvidence {
        FileTransferRecipientEvidence(stableID: requested.stableID, basis: requested.kind == .builtinSelfTransfer ? .builtinTransferExplanation : .stableAccountIdentifier,
            conversationEvidenceID: "current-account-profile-and-chat")
    }
    func context(_ environment: FileTransferEnvironment, stale: Bool = false) -> FileTransferEvidenceContext {
        FileTransferEvidenceContext(evidenceID: UUID().uuidString, capturedAt: Date().addingTimeInterval(stale ? -2 : 0), environment: environment)
    }
    func locate(payload: FileTransferPayload, recipient: FileTransferRecipient, environment: FileTransferEnvironment) async throws -> [FileTransferLocatedFile] {
        try zip(payload.manifest, payload.fileURLs).map { item, url in
            let bytes = try Data(contentsOf: url)
            precondition(FileTransferArtifact.digest(bytes) == item.artifact.sha256)
            locatedBytes += bytes.count
            return FileTransferLocatedFile(handle: item.id.uuidString, identity: identity(item, binding: payload.bindingID))
        }
    }
    func select(files: [FileTransferLocatedFile], payload: FileTransferPayload, recipient: FileTransferRecipient, environment: FileTransferEnvironment) async throws {
        selected.append(files.map { $0.identity.artifactID }); try onSelect?()
    }
    func observeSelection(payload: FileTransferPayload, recipient: FileTransferRecipient, environment: FileTransferEnvironment, after: Date) async throws -> FileTransferSelectionEvidence {
        var files = payload.manifest.map { identity($0, binding: payload.bindingID) }
        var target = self.recipient(recipient)
        switch fault {
        case .wrongRecipient: target.stableID = "wechat:another-contact"
        case .wrongHash: files[0].sha256 = String(repeating: "f", count: 64)
        case .metadataOnly: files[0].identityLevel = .metadataOnly
        case .wrongOrder: files.reverse()
        case .compressed: files[0].originalBytesPreserved = false
        default: break
        }
        return FileTransferSelectionEvidence(context: context(environment, stale: fault == .stale), recipient: target, files: files, selectedCount: files.count)
    }
    func submit(payload: FileTransferPayload, recipient: FileTransferRecipient, selection: FileTransferSelectionEvidence, environment: FileTransferEnvironment) async throws -> FileTransferDispatchReceipt {
        // Assert the production store was committed BEFORE the send callback.
        let durable = try JSONDecoder().decode(Document.self, from: Data(contentsOf: store.url))
        let checkpoint = durable.operations.first { $0.operationID == operationID }!
        precondition(checkpoint.stage == .submissionPending)
        precondition(checkpoint.items.filter { payload.manifest.map(\.id).contains($0.artifactID) }.allSatisfy { $0.state == .submissionPending && $0.submittedAt != nil })
        for (item, url) in zip(payload.manifest, payload.fileURLs) {
            let actual = try FileTransferArtifact.digestFile(url)
            precondition(actual.0 == item.artifact.sha256)
        }
        submissions.append(payload.manifest.map(\.id)); try onSubmit?()
        if fault == .submitInterrupted { throw CancellationError() }
        return FileTransferDispatchReceipt(signal: .dispatched, detail: "fixture transport dispatched")
    }
    func inspect(operation: FileTransferOperation, environment: FileTransferEnvironment, after: Date) async throws -> [FileTransferResultEvidence] {
        inspections += 1
        let pending = operation.manifest.filter { item in operation.items.contains { $0.artifactID == item.id && $0.pending } }
        let statuses = resultRounds.isEmpty ? pending.map { _ in FileTransferResultEvidence.Status.outgoingMessageObserved } : resultRounds.removeFirst()
        return zip(pending, statuses).map { item, status in
            var target = recipient(operation.recipient)
            if fault == .wrongResultRecipient { target.stableID = "wechat:wrong-result-chat" }
            return FileTransferResultEvidence(context: context(environment), recipient: target,
                file: identity(item, binding: operation.payloadBindingID), status: status,
                messageID: fault == .duplicateMessage ? "same-bubble" : "bubble-" + item.id.uuidString,
                detail: status == .confirmedNotSent ? "App independently reports this bound original attachment failed before successful submission" : "fixture-bound result")
        }
    }
    struct Document: Decodable { var operations: [FileTransferOperation] }
}

@main struct FileTransferChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
        func rejected(_ message: String, _ body: () async throws -> Void) async {
            do { try await body(); preconditionFailure(message) } catch { checks += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("source-a/report.txt"), secondURL = root.appendingPathComponent("source-b/report.txt")
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("原始甲\n😀".utf8).write(to: firstURL)
        try Data("原始乙\n😀".utf8).write(to: secondURL)
        let environment = FileTransferEnvironment(deviceKey: "phone-A", accessoryKey: "BLE-A", captureSessionID: "capture-A", foreground: true)
        var scenario = 0
        func fixture(_ operationID: String = "fixture-send") async throws -> (FileTransferStore, FixtureDriver, FileTransferCoordinator, [UUID]) {
            scenario += 1
            let store = FileTransferStore(url: root.appendingPathComponent("case-\(scenario)/journal.json"))
            let a = try await store.importFileAsync(at: firstURL, sourceID: "source-A", mediaType: "public.plain-text")
            let b = try await store.importFileAsync(at: secondURL, sourceID: "source-B", mediaType: "public.plain-text")
            let driver = FixtureDriver(store: store, operationID: operationID)
            return (store, driver, FileTransferCoordinator(store: store, driver: driver), [a.id, b.id])
        }
        func send(_ coordinator: FileTransferCoordinator, _ ids: [UUID], id: String = "fixture-send", task: String = "task-A") async throws -> FileTransferOperation {
            try await coordinator.start(operationID: id, taskID: task, recipient: .selfTransfer(artifactIDs: ids), artifactIDs: ids, environment: environment)
        }

        let (store, driver, coordinator, ids) = try await fixture()
        expect(store.artifacts[0].filename == store.artifacts[1].filename && store.artifacts[0].byteCount == store.artifacts[1].byteCount, "fixture covers same name/size")
        expect(store.artifacts[0].sha256 != store.artifacts[1].sha256, "different original bytes retain separate identities")
        let completed = try await send(coordinator, ids)
        expect(completed.stage == .complete && !store.hasPendingReview, "complete only after exact bound outgoing evidence")
        expect(driver.submissions == [ids] && completed.items.allSatisfy { $0.attemptCount == 1 }, "ordered batch submits exactly once")
        expect(driver.locatedBytes > 0 && completed.verificationScope.contains("not_recipient_delivery"), "uses actual file bytes and limits receipt scope")
        let duplicate = try await send(coordinator, ids, id: "new-id-same-task")
        expect(duplicate.operationID == completed.operationID && driver.submissions.count == 1, "new operation ID cannot repeat successful task")
        await rejected("ID rebinding") { _ = try await send(coordinator, ids.reversed()) }

        for fault in [FixtureDriver.Fault.wrongRecipient, .wrongHash, .metadataOnly, .wrongOrder, .compressed, .stale] {
            let (s, d, c, values) = try await fixture(); d.fault = fault
            let result = try await send(c, values)
            expect(result.stage == .unsupported && d.submissions.isEmpty && !s.hasPendingReview, "wrong/unsupported/stale selection never sends")
        }
        let (_, _, userCoordinator, userIDs) = try await fixture()
        let badRecipient = FileTransferRecipient(kind: .userSelectedStableAccount, stableID: "display-name:Alice", displayName: "Alice", authorizedArtifactIDs: userIDs)
        await rejected("ordinary recipient requires explicit stable selection evidence") {
            _ = try await userCoordinator.start(operationID: "ordinary-test", taskID: "task", recipient: badRecipient, artifactIDs: userIDs, environment: environment)
        }

        let (uncertainStore, uncertainDriver, uncertain, uncertainIDs) = try await fixture()
        uncertainDriver.fault = .submitInterrupted
        await rejected("interrupted submit propagates cancellation") { _ = try await send(uncertain, uncertainIDs) }
        expect(uncertainStore.hasPendingReview && uncertainDriver.submissions.count == 1, "cancel after durable boundary is pending")
        let repeated = try await send(uncertain, uncertainIDs, task: "new-task")
        expect(repeated.pending && uncertainDriver.submissions.count == 1, "same ID new task never replays")
        await rejected("global pending blocks new operation/task") { _ = try await send(uncertain, uncertainIDs, id: "brand-new-id", task: "other-task") }
        let changed = FileTransferEnvironment(deviceKey: "phone-B", accessoryKey: "BLE-B", captureSessionID: "capture-B", foreground: true)
        await rejected("new device/accessory cannot bypass pending") {
            _ = try await uncertain.start(operationID: "different-device", taskID: "other", recipient: .selfTransfer(artifactIDs: uncertainIDs), artifactIDs: uncertainIDs, environment: changed)
        }
        let restoredStore = FileTransferStore(url: uncertainStore.url)
        expect(restoredStore.hasPendingReview && restoredStore.operations[0].items.allSatisfy { $0.state == .unknown && $0.attemptCount == 1 }, "restart retains unknown without loss")
        let restoredDriver = FixtureDriver(store: restoredStore, operationID: "fixture-send")
        restoredDriver.resultRounds = [[.unknown, .unknown]]
        let restoredCoordinator = FileTransferCoordinator(store: restoredStore, driver: restoredDriver)
        let stillUnknown = try await restoredCoordinator.resume(operationID: "fixture-send", environment: changed)
        expect(stillUnknown.pending && restoredDriver.submissions.isEmpty && restoredDriver.selected.isEmpty && restoredDriver.inspections == 1, "resume is read-only even with changed accessory")
        _ = try restoredCoordinator.cancel(operationID: "fixture-send")
        expect(restoredStore.hasPendingReview && restoredStore.operations[0].cancelled, "cancel cannot erase pending send")
        _ = try restoredCoordinator.resolveReviewed(operationID: "fixture-send", resolution: .stillUnknown, detail: "无法排除已发")
        expect(restoredStore.hasPendingReview, "unknown review never unlocks sending")
        _ = try restoredCoordinator.resolveReviewed(operationID: "fixture-send", resolution: .userReportsSubmitted, detail: "用户逐项检查目标会话及原件")
        expect(!restoredStore.hasPendingReview && restoredStore.operations[0].items.allSatisfy { $0.state == .userReportedSubmitted }, "human report is separately labelled")

        let (cancelStore, cancelDriver, cancelCoordinator, cancelIDs) = try await fixture()
        cancelDriver.onSelect = { _ = try cancelCoordinator.cancel(operationID: "fixture-send") }
        await rejected("cancel selection") { _ = try await send(cancelCoordinator, cancelIDs) }
        expect(cancelDriver.submissions.isEmpty && cancelStore.operations[0].cancelled && !cancelStore.hasPendingReview, "cancel before submission cannot continue input")

        let (_, partialDriver, partialCoordinator, partialIDs) = try await fixture()
        partialDriver.resultRounds = [[.outgoingMessageObserved, .confirmedNotSent], [.outgoingMessageObserved]]
        let partial = try await send(partialCoordinator, partialIDs)
        expect(partial.stage == .partial && !partial.pending, "certain failed item is distinct from unknown")
        let supplemented = try await partialCoordinator.resume(operationID: "fixture-send", environment: environment)
        expect(supplemented.stage == .complete && partialDriver.submissions == [partialIDs, [partialIDs[1]]], "only confirmed failed suffix is supplemented")
        expect(supplemented.items.map(\.attemptCount) == [1, 2] && supplemented.manifest.map(\.ordinal) == [0, 1], "attempts and original ordering persist")

        let (_, orderDriver, orderCoordinator, orderIDs) = try await fixture()
        orderDriver.resultRounds = [[.confirmedNotSent, .outgoingMessageObserved]]
        _ = try await send(orderCoordinator, orderIDs)
        let orderStopped = try await orderCoordinator.resume(operationID: "fixture-send", environment: environment)
        expect(orderStopped.stage == .unsupported && orderDriver.submissions.count == 1, "retry of earlier failed file cannot violate sequence")

        for fault in [FixtureDriver.Fault.wrongResultRecipient, .duplicateMessage] {
            let (s, d, c, values) = try await fixture(); d.fault = fault
            let result = try await send(c, values)
            expect(result.pending && result.observedSentCount == 0 && s.hasPendingReview, "invalid result proof never becomes success or known failure")
        }
        let (uploadStore, uploadDriver, uploadCoordinator, uploadIDs) = try await fixture()
        uploadDriver.resultRounds = [[.uploading, .unknown], [.outgoingMessageObserved, .outgoingMessageObserved]]
        let upload = try await send(uploadCoordinator, uploadIDs)
        expect(upload.stage == .uploading && uploadStore.hasPendingReview, "upload and sending are separate")
        let uploaded = try await uploadCoordinator.resume(operationID: "fixture-send", environment: environment)
        expect(uploaded.stage == .complete && uploadDriver.submissions.count == 1, "upload recovery inspects rather than resubmits")

        let (nativeStore, _, native, nativeIDs) = try await fixture("native-share-test")
        var presentations = 0
        let nativeResult = try await native.beginNativeShare(operationID: "native-share-test", taskID: "native-task", artifactIDs: nativeIDs,
            requestedRecipientDescription: "用户指定的文件传输助手", environment: environment) { urls in
                presentations += 1
                let durable = FileTransferStore(url: nativeStore.url)
                expect(durable.hasPendingReview && durable.operations[0].stage == .pendingReview, "native presentation has durable uncertain checkpoint")
                expect(try! Data(contentsOf: urls[0]) == Data(contentsOf: firstURL), "native sheet gets original exact file bytes")
                expect(try! Data(contentsOf: urls[1]) == Data(contentsOf: secondURL), "native original order retained")
                return .extensionCompleted(activityType: "WeChat")
            }
        expect(nativeResult.pending && nativeResult.recipient.kind == .nativeShareRequestedUnverified && nativeResult.observedSentCount == 0, "extension completion proves no recipient or send result")
        await rejected("native new task cannot bypass unresolved share") {
            _ = try await native.beginNativeShare(operationID: "new-native-operation", taskID: "new-task", artifactIDs: nativeIDs,
                requestedRecipientDescription: "别名", environment: changed) { _ in presentations += 1; return .dismissedOrUnknown }
        }
        expect(presentations == 1, "uncertain native sheet is never re-presented")
        _ = try native.cancel(operationID: "native-share-test")
        expect(nativeStore.hasPendingReview, "native cancellation retains unknown")

        let (mixedStore, mixedDriver, mixedCoordinator, mixedIDs) = try await fixture()
        mixedDriver.resultRounds = [[.unknown, .unknown]]
        _ = try await send(mixedCoordinator, mixedIDs)
        _ = try mixedCoordinator.resolveReviewed(operationID: "fixture-send", artifactIDs: [mixedIDs[0]], resolution: .userReportsSubmitted, detail: "仅第一项已检查")
        expect(mixedStore.hasPendingReview && mixedStore.operations[0].items[1].state == .unknown, "per-item human review never clears other unknown files")
        _ = try mixedCoordinator.resolveReviewed(operationID: "fixture-send", artifactIDs: [mixedIDs[1]], resolution: .userConfirmsNotSubmitted, detail: "第二项独立确认未提交")
        expect(!mixedStore.hasPendingReview && mixedStore.operations[0].items.map(\.state) == [.userReportedSubmitted, .confirmedFailed], "mixed outcomes retain per-file truth")

        let (dismissedStore, _, dismissedCoordinator, dismissedIDs) = try await fixture("dismissed-share")
        let dismissed = try await dismissedCoordinator.beginNativeShare(operationID: "dismissed-share", taskID: "task", artifactIDs: dismissedIDs,
            requestedRecipientDescription: "文件传输助手", environment: environment) { _ in .dismissedOrUnknown }
        expect(dismissed.pending && dismissedStore.hasPendingReview, "completed=false/dismissed is not proof of no submission")
        let (confirmedStore, _, confirmedCoordinator, confirmedIDs) = try await fixture("confirmed-no-share")
        let noShare = try await confirmedCoordinator.beginNativeShare(operationID: "confirmed-no-share", taskID: "task", artifactIDs: confirmedIDs,
            requestedRecipientDescription: "文件传输助手", environment: environment) { _ in .confirmedNotSubmitted(evidenceID: "host-proved-no-extension-was-launched") }
        expect(!noShare.pending && noShare.cancelled && !confirmedStore.hasPendingReview, "only independently proven no-submit unlocks cancelled share")
        let (_, _, unsupportedCoordinator, unsupportedIDs) = try await fixture("no-driver-test")
        let noDriverStore = FileTransferStore(url: root.appendingPathComponent("no-driver/journal.json"))
        let noDriverArtifact = try await noDriverStore.importFileAsync(at: firstURL, sourceID: "no-driver-original", mediaType: "public.plain-text")
        let noDriver = try await FileTransferCoordinator(store: noDriverStore).start(operationID: "no-driver-operation", taskID: "task",
            recipient: .selfTransfer(artifactIDs: [noDriverArtifact.id]), artifactIDs: [noDriverArtifact.id], environment: environment)
        expect(noDriver.stage == .unsupported && noDriver.items[0].state == .notSubmitted, "missing trusted driver is explicit unsupported without simulated success")
        _ = unsupportedCoordinator; _ = unsupportedIDs
        let (reentrantStore, reentrantDriver, reentrantCoordinator, reentrantIDs) = try await fixture()
        reentrantDriver.onSubmit = {
            do { _ = try reentrantCoordinator.resolveReviewed(operationID: "fixture-send", resolution: .userReportsSubmitted, detail: "while running"); preconditionFailure("active review must reject") }
            catch { checks += 1 }
        }
        _ = try await send(reentrantCoordinator, reentrantIDs)
        expect(!reentrantStore.hasActiveOperation, "active lease releases at terminal return")
        let (cancelNativeStore, _, cancelNativeCoordinator, cancelNativeIDs) = try await fixture("cancel-native-active")
        let cancelledNative = try await cancelNativeCoordinator.beginNativeShare(operationID: "cancel-native-active", taskID: "task", artifactIDs: cancelNativeIDs,
            requestedRecipientDescription: "文件传输助手", environment: environment) { _ in
                _ = try cancelNativeCoordinator.cancel(operationID: "cancel-native-active")
                return .extensionCompleted(activityType: "WeChat")
            }
        expect(cancelledNative.cancelled && cancelNativeStore.hasPendingReview, "native cancel cannot be undone by a late completed callback")
        let (missingStore, missingDriver, missingCoordinator, missingIDs) = try await fixture()
        missingDriver.resultRounds = [[.outgoingMessageObserved], [.unknown]]
        let missingResult = try await send(missingCoordinator, missingIDs)
        expect(missingResult.items[0].state == .observedSent && missingResult.items[1].state == .unknown, "missing result stays unknown, never zero/failed")
        _ = try await missingCoordinator.resume(operationID: "fixture-send", environment: environment)
        expect(missingStore.hasPendingReview && missingDriver.submissions.count == 1, "known sent file and unknown file never batch-resend")
        let binaryURL = root.appendingPathComponent("original-video.mov")
        let binary = Data((0..<8192).map { UInt8($0 % 256) })
        try binary.write(to: binaryURL)
        let binaryStore = FileTransferStore(url: root.appendingPathComponent("video/journal.json"))
        let video = try await binaryStore.importFileAsync(at: binaryURL, sourceID: "original-video", mediaType: "com.apple.quicktime-movie")
        let videoPayload = try await binaryStore.payloadAsync(manifest: binaryStore.manifest(artifactIDs: [video.id]), bindingID: UUID())
        expect(try! Data(contentsOf: videoPayload.fileURLs[0]) == binary, "binary original retains every byte; no video recompression path")
        let (failingStore, failingDriver, failingCoordinator, failingIDs) = try await fixture()
        failingDriver.onSubmit = {
            try FileManager.default.removeItem(at: failingStore.url)
            try FileManager.default.createDirectory(at: failingStore.url, withIntermediateDirectories: true)
        }
        await rejected("write failure after dispatch") { _ = try await send(failingCoordinator, failingIDs) }
        expect(failingStore.hasPendingReview && !failingStore.readable && failingDriver.submissions.count == 1, "post-dispatch journal failure fails closed and never retries")

        let (tamperedStore, tamperedDriver, tampered, tamperedIDs) = try await fixture()
        let payload = try tamperedStore.payload(manifest: tamperedStore.manifest(artifactIDs: tamperedIDs), bindingID: UUID())
        try Data("changed".utf8).write(to: payload.fileURLs[0])
        await rejected("modified original bytes stop before UI") { _ = try await send(tampered, tamperedIDs) }
        expect(tamperedDriver.submissions.isEmpty && tamperedDriver.selected.isEmpty, "mutated local file never enters selection")
        let corruptURL = root.appendingPathComponent("corrupt/checkpoints.json")
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptURL)
        let corrupt = FileTransferStore(url: corruptURL)
        expect(corrupt.hasPendingReview && !corrupt.readable, "corrupt journal fails closed")
        await rejected("corrupt journal blocks native dispatch") {
            _ = try await FileTransferCoordinator(store: corrupt).beginNativeShare(operationID: "corrupt-native", taskID: "task", artifactIDs: ids,
                requestedRecipientDescription: "文件传输助手", environment: environment) { _ in preconditionFailure("must not present") }
        }
        print("FileTransfer: \(checks) production coordinator/store/driver checks passed (offline fixtures; no real recipients or sends)")
    }
}
