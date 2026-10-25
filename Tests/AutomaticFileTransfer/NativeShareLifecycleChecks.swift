import Foundation

@MainActor enum NativeShareLifecycleChecks {
    private enum Mode: String, CaseIterable {
        case cancelBeforeTaskStarts, cancelAtPresentEntry, cancelWhileAwaitingAppearance
        case cancelImmediatelyAfterAppearance, cancelDuringReadAfterAppearance, normalDismiss
        case dismissThenCancelSameTurn, cancelThenDismissSameTurn
    }
    private struct Outcome {
        var errorType: String
        var cancelled: Bool
        var returned: FileTransferOperation?
    }
    static func run(directory: URL, reportURL: URL? = nil) async throws -> Int {
        var checks = 0, cases: [[String: Any]] = []
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("fixture.txt")
        try Data("offline native presentation lifecycle".utf8).write(to: source)
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func until(_ description: String, _ predicate: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !predicate() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AgentError.message("Offline native lifecycle stage not reached: " + description) }
                await Task.yield()
            }
        }
        func record(_ entry: [String: Any]) throws {
            cases.append(entry)
            if let reportURL {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["offlineOnly": true, "cases": cases], options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportURL, options: .atomic)
            }
        }
        for mode in Mode.allCases {
            let store = FileTransferStore(url: directory.appendingPathComponent(mode.rawValue + "/journal.json"))
            let artifact = try await store.importFileAsync(at: source, sourceID: "lifecycle-fixture", mediaType: "public.plain-text")
            let recipient = FileTransferRecipient.selfTransfer(artifactIDs: [artifact.id])
            let environment = FileTransferEnvironment(deviceKey: "offline-device", accessoryKey: "offline-accessory", captureSessionID: UUID().uuidString, foreground: true)
            let boundary = WorkspacePresentationFixture()
            var presents = 0, reads = 0, taps = 0, bindingReturns = 0, task: Task<Outcome, Never>?
            let driver = WeChatFileTransferDriver(read: { _ in
                reads += 1
                // Cooperative frame I/O boundary only. There is no phone read.
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw FileTransferError.unsupported("Unexpected uncancelled frame wait")
            }, tap: { _ in taps += 1 }, scroll: { _ in preconditionFailure("No scrolling at native presentation lifecycle boundary") },
            present: { payload in
                presents += 1
                if mode == .cancelAtPresentEntry { task?.cancel() } // Real Task.cancel before handler/continuation registration.
                let binding = try await boundary.present(payload)
                bindingReturns += 1
                return binding
            }, isPresented: { boundary.automaticPresentationID == $0 && boundary.sharePresentation?.id == $0 })
            let operationID = "lifecycle-" + mode.rawValue
            task = Task { @MainActor in
                // Exact production automaticSend scope cleanup is generated from
                // Workspace; its common close path must run on every exit.
                defer { boundary.endAutomaticWorkflow() }
                do {
                    let operation = try await FileTransferCoordinator(store: store).beginAutomaticNativeShare(operationID: operationID,
                        taskID: operationID, recipient: recipient, artifactIDs: [artifact.id], environment: environment, automaticDriver: driver)
                    return Outcome(errorType: "none", cancelled: Task.isCancelled, returned: operation)
                } catch {
                    return Outcome(errorType: error is CancellationError ? "CancellationError" : String(reflecting: type(of: error)),
                        cancelled: Task.isCancelled, returned: nil)
                }
            }
            var presentationID: UUID?
            switch mode {
            case .cancelBeforeTaskStarts: task!.cancel()
            case .cancelAtPresentEntry: break
            default:
                try await until("registered continuation") { boundary.automaticPresentation != nil }
                presentationID = boundary.sharePresentation!.id
                switch mode {
                case .cancelWhileAwaitingAppearance: task!.cancel()
                case .cancelImmediatelyAfterAppearance:
                    boundary.nativeSharePresented(id: presentationID!)
                    task!.cancel() // Same MainActor turn, before the resumed driver can read/tap.
                case .cancelDuringReadAfterAppearance:
                    boundary.nativeSharePresented(id: presentationID!)
                    try await until("post-appearance frame wait") { reads == 1 }
                    task!.cancel()
                case .normalDismiss: boundary.finishNativeShare(id: presentationID!, result: .dismissedOrUnknown)
                case .dismissThenCancelSameTurn:
                    boundary.finishNativeShare(id: presentationID!, result: .dismissedOrUnknown)
                    task!.cancel()
                case .cancelThenDismissSameTurn:
                    task!.cancel()
                    boundary.finishNativeShare(id: presentationID!, result: .dismissedOrUnknown)
                default: break
                }
            }
            let outcome = await task!.value
            let persisted = try store.operation(id: operationID)
            let priorPresents = presents, priorReads = reads, priorTaps = taps
            if let presentationID {
                boundary.nativeSharePresented(id: presentationID) // A late native callback must not revive a cancelled/dismissed share.
                boundary.nativeSharePresented(id: UUID())
            }
            var replayStage = "none"
            if persisted != nil {
                let replay = try await FileTransferCoordinator(store: store).beginAutomaticNativeShare(operationID: operationID,
                    taskID: operationID, recipient: recipient, artifactIDs: [artifact.id], environment: environment, automaticDriver: driver)
                replayStage = replay.stage.rawValue
            }
            let entry: [String: Any] = ["case": mode.rawValue, "errorType": outcome.errorType, "taskIsCancelled": outcome.cancelled,
                "returnedNormally": outcome.returned != nil, "persisted": persisted != nil, "persistedStage": persisted?.stage.rawValue ?? "none",
                "persistedPending": persisted?.pending ?? false, "activeOperationReleased": !store.hasActiveOperation,
                "presentCalls": presents, "bindingReturns": bindingReturns, "readCalls": reads, "tapCalls": taps,
                "presentationCleared": boundary.sharePresentation == nil, "continuationCleared": boundary.automaticPresentation == nil,
                "presentationBindingCleared": boundary.automaticPresentationID == nil, "sameOperationReplayStage": replayStage]
            try record(entry) // Retain real calls/state/error before assertions.
            expect(!store.hasActiveOperation, mode.rawValue + ": exclusive operation claim is released on every exit")
            expect(boundary.sharePresentation == nil && boundary.automaticPresentation == nil && boundary.automaticPresentationID == nil,
                   mode.rawValue + ": all presentation/continuation/binding state is cleaned")
            expect(presents == priorPresents && reads == priorReads && taps == priorTaps && taps == 0,
                   mode.rawValue + ": late callbacks and same-operation replay cannot revive input or re-present")
            expect(bindingReturns == (mode == .cancelDuringReadAfterAppearance ? 1 : 0),
                   mode.rawValue + ": cancellation before successful return never forwards a native binding to the driver")
            if mode == .normalDismiss {
                expect(outcome.errorType == "none" && !outcome.cancelled && outcome.returned?.pending == true,
                       "Normal dismissal retains ordinary unknown result instead of becoming cancellation")
            } else {
                expect(outcome.errorType == "CancellationError" && outcome.cancelled && outcome.returned == nil,
                       mode.rawValue + ": real task cancellation reaches the coordinator caller as CancellationError")
            }
            if mode == .cancelBeforeTaskStarts {
                expect(presents == 0 && reads == 0 && persisted == nil && !store.hasPendingReview,
                       "Cancellation before payload/presentation never crosses or invents a pending submission")
            } else {
                expect(presents == 1 && persisted?.pending == true && store.hasPendingReview && persisted?.items.allSatisfy { $0.state == .unknown } == true,
                       mode.rawValue + ": the single possible-presentation boundary retains unknown pending items")
                expect(replayStage == persisted?.stage.rawValue,
                       mode.rawValue + ": durable operation replay returns the same unknown receipt without dispatch")
                expect(reads == (mode == .cancelDuringReadAfterAppearance ? 1 : 0),
                       mode.rawValue + ": cancellation phase determines whether a single non-input frame wait began")
            }
        }
        return checks
    }
}
