import Foundation

@MainActor final class LowLevelUI {
    var pages: [[PhoneUIElement]] = []
    var taps: [String] = []
    var current: PhoneUISnapshot?
    var store: FileTransferStore
    var operationID: String
    var captureID = UUID()
    var presentationID: UUID?
    var nativePresentations = 0
    var nativeURLs: [URL] = []
    var wrongBinding = false
    var cancelOnPresentation = false
    var cancelOnSend = false
    var onRead: (() throws -> Void)?
    var readBoundaries: [Date] = []
    var presentedAt: Date?
    var modifyObservation: ((inout WeChatFileTransferObservation, Date) -> Void)?
    var pixelAge: TimeInterval = 0
    init(store: FileTransferStore, operationID: String) { self.store = store; self.operationID = operationID }
    var environment: FileTransferEnvironment { .init(deviceKey: "real-fixture-device", accessoryKey: "real-fixture-accessory", captureSessionID: captureID.uuidString, foreground: true) }
    func read(after: Date) throws -> WeChatFileTransferObservation {
        guard !pages.isEmpty else { throw FileTransferError.unsupported("no next actual fixture pixels") }
        readBoundaries.append(after)
        try onRead?()
        // Explicit source delivery waits for the real clock, never a future
        // epsilon. Fault cases below deliberately return a stored old frame.
        while Date() <= after { Thread.sleep(forTimeInterval: 0.0001) }
        let snapshot = PhoneUISnapshot(deviceKey: environment.deviceKey, scene: "unknown", elements: pages.removeFirst(), capturedAt: Date().addingTimeInterval(-pixelAge))
        var value = WeChatFileTransferObservation(snapshot: snapshot, captureSessionID: captureID, frameID: UUID().uuidString, confirmedAt: Date())
        modifyObservation?(&value, after)
        current = value.snapshot
        return value
    }
    func tap(_ element: PhoneUIElement) throws {
        precondition(current?.element(id: element.id) == element, "tap belongs to actual most recent raw page")
        if element.id == "send" {
            let disk = FileTransferStore(url: store.url)
            let persisted = disk.operations.first { $0.operationID == operationID }!
            precondition(persisted.pending && persisted.lastSelection?.visibleEvidenceJSON != nil, "actual extension selection proof persisted BEFORE real Send dispatch")
        }
        taps.append(element.id)
        if element.id == "send" && cancelOnSend { throw CancellationError() }
    }
    func present(_ payload: FileTransferPayload) throws -> WeChatNativeShareBinding {
        let disk = FileTransferStore(url: store.url)
        precondition(disk.hasPendingReview && disk.operations.first { $0.operationID == operationID } != nil,
                     "ledger persisted BEFORE native host presentation")
        nativePresentations += 1; nativeURLs = payload.fileURLs
        for (item, url) in zip(payload.manifest, payload.fileURLs) {
            let actual = try FileTransferArtifact.digestFile(url)
            precondition(actual.0 == item.artifact.sha256 && actual.1 == item.artifact.byteCount)
        }
        if cancelOnPresentation { throw CancellationError() }
        let id = UUID(); presentationID = id
        var result = WeChatNativeShareBinding(presentationID: id, payload: payload)
        presentedAt = result.presentedAt
        if wrongBinding { result.artifactIDs.reverse() }
        return result
    }
    func driver() -> WeChatFileTransferDriver {
        .init(read: { try self.read(after: $0) }, tap: { try self.tap($0) }, scroll: { _ in preconditionFailure("native sending never scrolls guessed lists") },
              present: { try self.present($0) }, isPresented: { self.presentationID == $0 })
    }
}

@main struct AutomaticFileTransferChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); checks += 1 }
        func element(_ id: String, _ label: String, _ x: Double, _ y: Double) -> PhoneUIElement {
            .init(id: id, label: label, rect: .init(x: x - 0.05, y: y - 0.012, width: 0.1, height: 0.024), source: "ocr")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-native-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = root.appendingPathComponent("a.txt"), bURL = root.appendingPathComponent("b.txt")
        try Data("first original".utf8).write(to: aURL); try Data("second original".utf8).write(to: bURL)
        var fixtureIndex = 0
        func fixture() async throws -> (FileTransferStore, FileTransferCoordinator, LowLevelUI, [UUID], FileTransferRecipient) {
            fixtureIndex += 1
            let store = FileTransferStore(url: root.appendingPathComponent("case-\(fixtureIndex)/journal.json"))
            let a = try await store.importFileAsync(at: aURL, sourceID: "native-a", mediaType: "public.plain-text")
            let b = try await store.importFileAsync(at: bURL, sourceID: "native-b", mediaType: "public.plain-text")
            let ids = [a.id, b.id]
            let recipient = FileTransferRecipient(kind: .userSelectedStableAccount, stableID: "wechat.account:authorized_account", displayName: "授权联系人",
                userSelectionEvidenceID: "explicit-native-user-scope", authorizedArtifactIDs: ids)
            return (store, FileTransferCoordinator(store: store), LowLevelUI(store: store, operationID: "automatic-native"), ids, recipient)
        }
        func activity() -> [PhoneUIElement] { [element("copy", "拷贝", 0.25, 0.65), element("options", "选项", 0.8, 0.3), element("activity-wechat", "微信", 0.4, 0.5)] }
        func confirmation(_ store: FileTransferStore, _ target: FileTransferRecipient, account: String = "authorized_account", original: Bool = true,
                          wrongSize: Bool = false, rounded: Bool = false, reversed: Bool = false) -> [PhoneUIElement] {
            var values = [element("heading", "发送给", 0.5, 0.08), element("target", target.displayName, 0.35, 0.17),
                element("account", "微信号：" + account, 0.5, 0.21), element("count", "2 个文件", 0.8, 0.28), element("send", "发送", 0.8, 0.85)]
            if original { values.append(element("original-selected", "已选择原文件", 0.5, 0.74)) }
            let artifacts = reversed ? Array(store.artifacts.reversed()) : store.artifacts
            for (index, file) in artifacts.enumerated() {
                let y = 0.35 + Double(index) * 0.16
                values.append(element("file-" + file.id.uuidString, file.filename, 0.4, y))
                values.append(element("size-" + file.id.uuidString, rounded ? "1 KB" : "\(file.byteCount + (wrongSize ? 1 : 0)) 字节", 0.4, y + 0.03))
            }
            return values
        }
        func send(_ coordinator: FileTransferCoordinator, _ ui: LowLevelUI, _ ids: [UUID], _ recipient: FileTransferRecipient) async throws -> FileTransferOperation {
            try await coordinator.beginAutomaticNativeShare(operationID: "automatic-native", taskID: "explicit-native-task", recipient: recipient,
                artifactIDs: ids, environment: ui.environment, automaticDriver: ui.driver())
        }
        let (store, coordinator, ui, ids, recipient) = try await fixture()
        ui.pages = [activity(), confirmation(store, recipient), confirmation(store, recipient)]
        let result = try await send(coordinator, ui, ids, recipient)
        expect(ui.nativePresentations == 1 && ui.taps == ["activity-wechat", "send"], "production driver performs real host->observed WeChat->observed Send path")
        expect(result.pending && result.observedSentCount == 0 && result.stage == .pendingReview, "a Send tap and native payload do not prove remote bytes or completed delivery")
        expect(result.lastSelection?.files.allSatisfy { $0.identityLevel == .managedOriginalBytes } == true, "native controller actual original source custody is retained")
        expect(result.lastSelection?.visibleEvidenceJSON?.contains("authorized_account") == true, "actual current extension account/frame evidence archived")
        expect(result.items.allSatisfy { $0.evidence?.status == .unknown && $0.evidence?.file.sha256 == nil && $0.evidence?.file.identityLevel == .metadataOnly }, "unseen remote SHA256 is never copied from local original")
        expect(ui.nativeURLs.map(\.lastPathComponent) == ["a.txt", "b.txt"], "native host receives exact original order")
        expect(ui.readBoundaries.first == ui.presentedAt && ui.readBoundaries.count == 3,
               "the actual native presentation watermark reaches the first source read; inspection also requests its own boundary")
        let prior = try await coordinator.beginAutomaticNativeShare(operationID: "automatic-native", taskID: "different-task", recipient: recipient,
            artifactIDs: ids, environment: ui.environment, automaticDriver: ui.driver())
        expect(prior.pending && ui.nativePresentations == 1, "existing operation never reopens native controller")
        do {
            _ = try await coordinator.beginAutomaticNativeShare(operationID: "brand-new-operation", taskID: "new-task", recipient: recipient,
                artifactIDs: ids, environment: ui.environment, automaticDriver: ui.driver())
            preconditionFailure("new task must not bypass pending")
        } catch { checks += 1 }

        for scenario in ["wrong-account", "no-id", "no-original", "wrong-size", "rounded-size", "reordered", "duplicate-send", "missing-count", "wrong-count", "conflicting-count", "wrong-case-account", "wrong-case-filename"] {
            let (s, c, gui, values, target) = try await fixture()
            var page = confirmation(s, target, account: scenario == "wrong-account" ? "wrong_account" : "authorized_account",
                original: scenario != "no-original", wrongSize: scenario == "wrong-size", rounded: scenario == "rounded-size", reversed: scenario == "reordered")
            if scenario == "no-id" { page.removeAll { $0.id == "account" } }
            if scenario == "duplicate-send" { page.append(element("other-send", "发送", 0.2, 0.85)) }
            if scenario == "missing-count" { page.removeAll { $0.id == "count" } }
            if scenario == "wrong-count" { page = page.map { var e = $0; if e.id == "count" { e.label = "3 个文件" }; return e } }
            if scenario == "conflicting-count" { page.append(element("other-count", "3 个文件", 0.2, 0.28)) }
            if scenario == "wrong-case-account" { page = page.map { var e = $0; if e.id == "account" { e.label = "微信号：AUTHORIZED_ACCOUNT" }; return e } }
            if scenario == "wrong-case-filename" { page = page.map { var e = $0; if e.label == "a.txt" { e.label = "A.txt" }; return e } }
            gui.pages = [activity(), page]
            let stopped = try await send(c, gui, values, target)
            expect(stopped.pending && !gui.taps.contains("send"), "\(scenario) never sends and presentation remains unknown")
            expect(gui.taps == ["activity-wechat"], "\(scenario) never taps display-name-only quick-send/guessed control")
        }
        let (bindingStore, bindingCoordinator, bindingUI, bindingIDs, bindingTarget) = try await fixture()
        bindingUI.wrongBinding = true; bindingUI.pages = [activity()]
        let bindingResult = try await send(bindingCoordinator, bindingUI, bindingIDs, bindingTarget)
        expect(bindingResult.pending && bindingUI.taps.isEmpty && bindingStore.hasPendingReview, "wrong native original payload/order stops before activity selection")
        let (cancelStore, cancelCoordinator, cancelUI, cancelIDs, cancelTarget) = try await fixture()
        cancelUI.cancelOnSend = true; cancelUI.pages = [activity(), confirmation(cancelStore, cancelTarget)]
        do { _ = try await send(cancelCoordinator, cancelUI, cancelIDs, cancelTarget); preconditionFailure("cancel propagates") }
        catch is CancellationError { checks += 1 }
        expect(cancelStore.hasPendingReview && cancelStore.operations[0].lastSelection != nil && cancelUI.taps.filter { $0 == "send" }.count == 1,
               "interrupted actual Send preserves proof and never retries")
        let restored = FileTransferStore(url: cancelStore.url)
        let resumeUI = LowLevelUI(store: restored, operationID: "automatic-native"); resumeUI.captureID = cancelUI.captureID
        resumeUI.pages = [confirmation(restored, cancelTarget)]
        let resumed = try await FileTransferCoordinator(store: restored, driver: resumeUI.driver()).resume(operationID: "automatic-native", environment: resumeUI.environment)
        expect(resumed.pending && resumeUI.taps.isEmpty && resumeUI.nativePresentations == 0, "restart resumes only read-only actual result inspection")
        let (_, presentationCoordinator, presentationUI, presentationIDs, presentationTarget) = try await fixture()
        presentationUI.cancelOnPresentation = true
        do { _ = try await send(presentationCoordinator, presentationUI, presentationIDs, presentationTarget); preconditionFailure("present cancel propagates") }
        catch is CancellationError { checks += 1 }
        expect(presentationUI.store.hasPendingReview && presentationUI.taps.isEmpty, "cancel during native presentation cannot reset uncertain ledger")

        let (chooserStore, chooserCoordinator, chooserUI, chooserIDs, chooserTarget) = try await fixture()
        let chooser = [element("chooser-heading", "选择聊天", 0.5, 0.08), element("account-row", chooserTarget.displayName, 0.35, 0.17),
            element("row-account", "微信号：authorized_account", 0.5, 0.21), element("next", "下一步", 0.8, 0.85)]
        chooserUI.pages = [activity(), chooser, chooser, confirmation(chooserStore, chooserTarget), confirmation(chooserStore, chooserTarget)]
        _ = try await send(chooserCoordinator, chooserUI, chooserIDs, chooserTarget)
        expect(chooserUI.taps == ["activity-wechat", "account-row", "next", "send"], "actual recipient-list row and Next are driven only with visible exact account")
        let (builtinStore, builtinCoordinator, builtinUI, builtinIDs, _) = try await fixture()
        let builtinTarget = FileTransferRecipient.selfTransfer(artifactIDs: builtinIDs)
        var builtinConfirmation = confirmation(builtinStore, builtinTarget)
        builtinConfirmation.removeAll { $0.id == "account" }
        builtinConfirmation.append(.init(id: "builtin-explanation", label: "你可以在手机和电脑间互传文件",
            rect: .init(x: 0.2, y: 0.258, width: 0.6, height: 0.024), source: "ocr"))
        builtinUI.pages = [activity(), builtinConfirmation, builtinConfirmation]
        let builtinResult = try await send(builtinCoordinator, builtinUI, builtinIDs, builtinTarget)
        expect(builtinUI.taps == ["activity-wechat", "send"] && builtinResult.lastSelection?.recipient.basis == .builtinTransferExplanation,
               "builtin assistant requires real independent transfer explanation, not title-only identity")
        let (idleStore, idleCoordinator, idleUI, idleIDs, idleTarget) = try await fixture()
        idleUI.pixelAge = 60
        idleUI.pages = [activity(), confirmation(idleStore, idleTarget), confirmation(idleStore, idleTarget)]
        let idleResult = try await send(idleCoordinator, idleUI, idleIDs, idleTarget)
        expect(idleUI.taps.contains("send") && idleResult.lastSelection?.context.confirmedAt != nil,
               "real idle confirmation permits unchanged pixels without rewriting their old capturedAt")
        expect(idleResult.lastSelection!.context.capturedAt < idleResult.createdAt, "pixel capture timestamp remains truthful")
        let (hiddenStore, hiddenCoordinator, hiddenUI, hiddenIDs, hiddenTarget) = try await fixture()
        hiddenUI.pages = [activity(), confirmation(hiddenStore, hiddenTarget)]
        hiddenUI.onRead = { if hiddenUI.pages.count == 1 { hiddenUI.presentationID = nil } }
        let hiddenResult = try await send(hiddenCoordinator, hiddenUI, hiddenIDs, hiddenTarget)
        expect(hiddenResult.pending && !hiddenUI.taps.contains("send"), "dismissed native presentation cannot retain Send authority")
        let permission = PhoneUISnapshot(deviceKey: "device", scene: "unknown", elements: activity() + [element("allow", "允许", 0.5, 0.8)], capturedAt: Date(), blockingOverlay: true)
        expect(!WeChatFileTransferPages.isAllowedMenu(permission), "native menu allowance never suppresses a permission dialog")
        let normalMenu = PhoneUISnapshot(deviceKey: "device", scene: "unknown", elements: activity() + [element("cancel", "取消", 0.5, 0.9)], capturedAt: Date(), blockingOverlay: true)
        expect(WeChatFileTransferPages.isAllowedMenu(normalMenu), "recognized native activity plus Cancel can be handled by page adapter")

        // Native eligibility is rechecked AFTER asynchronous original-byte
        // preparation, BEFORE any operation record or uncertain-send boundary.
        // A foreground/host loss at this exact pre-presentation gate is known
        // not submitted and must not poison the saved plan's stable ID.
        let (eligibilityStore, eligibilityCoordinator, eligibilityUI, eligibilityIDs, eligibilityTarget) = try await fixture()
        var eligibilityChecks = 0
        do {
            _ = try await eligibilityCoordinator.beginAutomaticNativeShare(operationID: "automatic-native", taskID: "explicit-native-task",
                recipient: eligibilityTarget, artifactIDs: eligibilityIDs, environment: eligibilityUI.environment,
                automaticDriver: eligibilityUI.driver(), validatePresentationEligibility: {
                    eligibilityChecks += 1
                    precondition(try! eligibilityStore.operation(id: "automatic-native") == nil,
                                 "host eligibility runs before first operation checkpoint")
                    throw FileTransferError.unsupported("native host vanished while originals were hashing")
                })
            preconditionFailure("ineligible native host must reject")
        } catch { checks += 1 }
        expect(eligibilityChecks == 1 && eligibilityUI.nativePresentations == 0 && eligibilityUI.taps.isEmpty,
               "ineligible host is rechecked and causes no presentation or GUI input")
        expect(eligibilityStore.operations.isEmpty && !eligibilityStore.hasPendingReview && !eligibilityStore.hasActiveOperation,
               "known pre-presentation ineligibility leaves no operation ledger, pending status or active lease")
        eligibilityUI.pages = [activity(), confirmation(eligibilityStore, eligibilityTarget), confirmation(eligibilityStore, eligibilityTarget)]
        let eligibleRetry = try await eligibilityCoordinator.beginAutomaticNativeShare(operationID: "automatic-native", taskID: "explicit-native-task",
            recipient: eligibilityTarget, artifactIDs: eligibilityIDs, environment: eligibilityUI.environment,
            automaticDriver: eligibilityUI.driver(), validatePresentationEligibility: { eligibilityChecks += 1 })
        expect(eligibilityChecks == 2 && eligibilityUI.nativePresentations == 1 && eligibilityUI.taps.filter { $0 == "send" }.count == 1,
               "same authorized operation ID can launch once when the host returns")
        expect(eligibleRetry.pending, "a later actually presented/submitted attempt still remains unknown")
        let (postGateStore, postGateCoordinator, postGateUI, postGateIDs, postGateTarget) = try await fixture()
        postGateUI.cancelOnPresentation = true
        do {
            _ = try await postGateCoordinator.beginAutomaticNativeShare(operationID: "automatic-native", taskID: "explicit-native-task",
                recipient: postGateTarget, artifactIDs: postGateIDs, environment: postGateUI.environment,
                automaticDriver: postGateUI.driver(), validatePresentationEligibility: {})
            preconditionFailure("presentation cancellation propagates")
        } catch is CancellationError { checks += 1 }
        expect(postGateStore.hasPendingReview && postGateUI.nativePresentations == 1,
               "failure after an accepted gate and presentation is NEVER downgraded to not submitted")

        for failure in ["confirmationAfterBoundary", "deviceKeyMatches", "captureSessionMatches"] {
            let (s, c, source, values, target) = try await fixture()
            source.pages = [activity()]
            source.modifyObservation = { observation, boundary in
                if failure == "confirmationAfterBoundary" {
                    observation.snapshot.capturedAt = boundary
                    observation.confirmedAt = boundary // equality is deliberately NOT fresh
                } else if failure == "deviceKeyMatches" { observation.snapshot.deviceKey = "PRIVATE-DEVICE-IDENTITY" }
                else { observation.captureSessionID = UUID() }
            }
            let stopped = try await send(c, source, values, target)
            expect(stopped.pending && stopped.lastSelection == nil && source.nativePresentations == 1 && source.taps.isEmpty,
                   "invalid post-presentation observation never taps and remains unknown: " + failure)
            expect(stopped.detail.contains("failedFields=" + failure) && !stopped.detail.contains("PRIVATE-DEVICE-IDENTITY") &&
                   !stopped.detail.contains("authorized_account") && !stopped.detail.contains(source.environment.deviceKey),
                   "failure receipt identifies only failed field names, without device identity or OCR account text")
            expect(s.hasPendingReview && FileTransferStore(url: s.url).hasPendingReview,
                   "post-presentation read rejection remains durable pending across restart")
        }

        // Execute the production file-picker navigation with only raw GUI pages.
        // External rows are intentionally NOT selected, because a single-file
        // picker may submit on return and its metadata has no byte custody.
        let (pickerStore, _, pickerUI, pickerIDs, _) = try await fixture()
        let selfTarget = FileTransferRecipient.selfTransfer(artifactIDs: pickerIDs)
        func chat() -> [PhoneUIElement] {
            [element("back", "微信", 0.1, 0.08), element("title", "文件传输助手", 0.5, 0.08),
             PhoneUIElement(id: "self-explanation", label: "你可以在手机和电脑间互传文件", rect: .init(x: 0.2, y: 0.288, width: 0.6, height: 0.024), source: "ocr"), element("old-message", "previous unique message", 0.7, 0.46),
             element("composer", "发送消息", 0.3, 0.9), element("more", "+", 0.9, 0.9)]
        }
        let menu = [element("album", "相册", 0.2, 0.65), element("camera", "拍摄", 0.5, 0.65), element("file-entry", "文件", 0.8, 0.65)]
        let filePage = [element("heading", "文件", 0.5, 0.08), element("phone-files", "手机文件", 0.5, 0.25)]
        let picker = [element("cancel", "取消", 0.9, 0.08), element("browse", "浏览", 0.5, 0.08), element("external-row", "a.txt", 0.4, 0.4)]
        pickerUI.pages = [chat(), chat(), menu, filePage, picker, picker]
        let pickerCoordinator = FileTransferCoordinator(store: pickerStore, driver: pickerUI.driver())
        let pickerResult = try await pickerCoordinator.start(operationID: "automatic-native", taskID: "picker-task", recipient: selfTarget,
            artifactIDs: pickerIDs, environment: pickerUI.environment)
        expect(pickerUI.taps == ["more", "file-entry", "phone-files"], "actual WeChat attachment/file/phone-Files navigation executes")
        expect(!pickerUI.taps.contains("external-row") && !pickerUI.taps.contains("send") && pickerUI.nativePresentations == 0,
               "unproved external picker selection never crosses accidental-return/send boundary")
        expect(pickerResult.stage == .unsupported && !pickerResult.pending, "metadata-only external picker is explicit unsupported before submit")
        let lifecycleReport = ProcessInfo.processInfo.environment["NATIVE_SHARE_LIFECYCLE_REPORT"].map { URL(fileURLWithPath: $0) }
        checks += try await NativeShareLifecycleChecks.run(directory: root.appendingPathComponent("native-lifecycle"), reportURL: lifecycleReport)
        print("AutomaticFileTransfer: \(checks) production coordinator + actual page-driver checks passed (raw low-level GUI fixtures; no real messages)")
    }
}
