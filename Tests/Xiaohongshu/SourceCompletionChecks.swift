import Foundation

@MainActor private final class SourceCompletionPendingReplay: XiaohongshuCollectionDriving {
    let fixture = XHSNativeReplay()
    func read() async throws -> XiaohongshuCollectionFrame { try await fixture.read() }
    func openNote(_ element: PhoneUIElement) async throws { try await fixture.openNote(element) }
    func returnToResults() async throws {
        try await fixture.returnToResults()
        if fixture.returns == 1 { fixture.foreground = false }
    }
    func scrollResults(at element: PhoneUIElement) async throws { try await fixture.scrollResults(at: element) }
    func tapObserved(_ element: PhoneUIElement) async throws { try await fixture.tapObserved(element) }
    func clipboardSnapshot(readText: Bool) async throws -> XiaohongshuClipboardSnapshot { try await fixture.clipboardSnapshot(readText: readText) }
    func resolveShortLink(_ url: URL) async throws -> XiaohongshuResolvedLink { try await fixture.resolveShortLink(url) }
}

@MainActor private final class SourceCompletionGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation in self.continuation = continuation; entered = true } }
    func release() { let value = continuation; continuation = nil; value?.resume() }
    func awaitEntry() async throws {
        for _ in 0..<500 {
            if entered { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AgentError.message("Synthetic source-completion gate did not enter")
    }
}

@MainActor enum XHSSourceCompletionChecks {
    static func run(folder: URL) async throws -> Int {
        var count = 0, outcomes: [[String: String]] = []
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label); count += 1
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = ProcessInfo.processInfo.environment["XHS_SOURCE_COMPLETION_REPLAY_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        func retain(_ name: String, _ run: XiaohongshuCollectionRun) throws {
            if let output { try encoder.encode(run).write(to: output.appendingPathComponent(name + ".json"), options: .atomic) }
        }
        func store(_ name: String) -> XiaohongshuCollectionStore {
            XiaohongshuCollectionStore(url: folder.appendingPathComponent("completion-" + name + ".json"))
        }
        func resolvedNote(_ name: String, _ id: String, body: String) async throws -> XiaohongshuNoteObservation {
            let value = try await XiaohongshuCollector(store: store(name)).collect(
                task: .init(id: "completion-note-" + name, keyword: "人工智能", sampleSize: 1),
                driver: XHSReplay([[.init(id: id, body: body)]]))
            return value.notes[0]
        }
        let pendingNoteID = "4123456789abcdef01234567"
        let oldNote = try await resolvedNote("older", pendingNoteID, body: "人工智能 旧的可见正文")
        let driver = SourceCompletionPendingReplay(), seedStore = store("seed")
        let task = XiaohongshuCollectionTask(id: "source-completion-seed", keyword: "人工智能", sampleSize: 2)
        let seed = try await XiaohongshuCollector(store: seedStore).collect(task: task, driver: driver)
        expect(seed.notes.count == 1 && seed.pending.count == 1 && seed.analysisSegments.isEmpty,
            "Production collect stores one note and the next unresolved copied source")
        expect(seed.status == .paused && seed.sourceAttempts.map(\.stage) == [.completed, .copiedAwaitingRead],
            "The precise Copy transaction remains durable before foreground completion")
        driver.fixture.foreground = true
        let clipboard = try await driver.clipboardSnapshot(readText: true)
        let newerNote = try await resolvedNote("newer", pendingNoteID, body: "人工智能 更新的可见正文")
        expect(oldNote.observedAt < seed.pending[0].observedAt && seed.pending[0].observedAt < newerNote.observedAt,
            "Synthetic fixture ordering guarantees that both older and newer existing-note branches execute")
        let otherNote = try await resolvedNote("other", "5123456789abcdef01234567", body: "人工智能 其他合法笔记")
        let originalInputs = (driver.fixture.copyTaps, driver.fixture.shareTaps, driver.fixture.noteOpens, driver.fixture.returns)
        try retain("seed", seed)

        func response(_ prompt: String) throws -> String {
            let payload = prompt.components(separatedBy: "INPUT_EXCERPTS_JSON:\n").last!
            let inputs = try JSONDecoder().decode([XiaohongshuAnalysisInput].self, from: Data(payload.utf8))
            let quote = String(inputs[0].excerpt.prefix(100))
            struct Response: Encodable { var kind = "visible_fragment_topics"; var items: [XiaohongshuFragmentTopic] }
            return String(decoding: try encoder.encode(Response(items: [.init(noteID: inputs[0].noteID, quote: quote, topic: String(quote.prefix(4)))])), as: UTF8.self)
        }
        func result(_ operation: Task<XiaohongshuCollectionRun, Error>) async -> String {
            do { _ = try await operation.value; return "success" }
            catch is CancellationError { return "CancellationError" }
            catch let error as XiaohongshuCollectionError {
                switch error {
                case .changedEvidence: return "changedEvidence"
                case .invalidTask: return "invalidTask"
                case .unavailable: return "unavailable"
                default: return String(describing: error)
                }
            } catch { return String(reflecting: type(of: error)) }
        }
        func start(_ collector: XiaohongshuCollector, gate: SourceCompletionGate, resolverCalls: @escaping () -> Void = {}) -> Task<XiaohongshuCollectionRun, Error> {
            Task { try await collector.completeCopiedSource(taskID: seed.id, clipboard: clipboard, resolveShortLink: { url in
                resolverCalls(); await gate.wait(); return try await driver.resolveShortLink(url)
            }) }
        }

        for interleave in [true, false] {
            let name = interleave ? "analysis-progress-other-note-during-resolver" : "noninterleaved"
            let target = store(name); try target.save(seed)
            let analysis = XiaohongshuAnalysisService(store: target) { try response($0) }
            if !interleave { _ = try await analysis.analyze(taskID: seed.id) }
            let gate = SourceCompletionGate(), operation = start(XiaohongshuCollector(store: target), gate: gate)
            try await gate.awaitEntry()
            if interleave {
                _ = try await analysis.analyze(taskID: seed.id)
                var progress = try target.run(id: seed.id)!
                progress.notes.append(otherNote); progress.checkpoint?.readCount += 1
                progress.events.append(.init(at: Date(), kind: "legal_progress", detail: "synthetic progress while resolver awaits"))
                progress.updatedAt = Date(); try target.save(progress)
            }
            let before = try target.run(id: seed.id)!; try retain(name + "-during", before)
            gate.release(); let completed = try await operation.value
            expect(completed.analysisSegments == before.analysisSegments && completed.analysisSegments.count == 1,
                "Completing the copied source retains analysis committed during resolver await")
            expect(completed.events == before.events && completed.checkpoint == before.checkpoint,
                "Completion does not roll back intervening event and checkpoint progress")
            expect(before.notes.allSatisfy({ completed.notes.contains($0) }) && completed.pending.isEmpty,
                "Other valid notes survive and only the bound pending source is removed")
            let reopened = XiaohongshuCollectionStore(url: folder.appendingPathComponent("completion-" + name + ".json"))
            expect(try reopened.run(id: seed.id) == completed, "A production reopen retains completion and concurrent work")
            if let output { try reopened.export(id: seed.id).write(to: output.appendingPathComponent(name + "-export.json"), options: .atomic) }
            try retain(name + "-after", completed)
            outcomes.append(["case":name,"result":"success; concurrent evidence retained"])
        }

        let same = store("same-instance"); try same.save(seed)
        let sameCollector = XiaohongshuCollector(store: same), sameGate = SourceCompletionGate()
        let first = start(sameCollector, gate: sameGate); try await sameGate.awaitEntry()
        var secondResolverCalls = 0
        let second = Task { try await sameCollector.completeCopiedSource(taskID: seed.id, clipboard: clipboard, resolveShortLink: { url in
            secondResolverCalls += 1; return try await driver.resolveShortLink(url)
        }) }
        let secondResult = await result(second)
        expect(secondResult == "invalidTask" && secondResolverCalls == 0, "Same-instance overlapping completion rejects before resolver")
        sameGate.release(); _ = try await first.value
        expect(try same.run(id: seed.id)?.notes.count == 2, "The admitted same-instance source completion still succeeds")

        let cross = store("cross-instance"); try cross.save(seed)
        let gateA = SourceCompletionGate(), gateB = SourceCompletionGate()
        let a = start(XiaohongshuCollector(store: cross), gate: gateA), b = start(XiaohongshuCollector(store: cross), gate: gateB)
        try await gateA.awaitEntry(); try await gateB.awaitEntry()
        gateA.release(); _ = try await a.value
        let once = try cross.run(id: seed.id)!, onceBytes = try Data(contentsOf: folder.appendingPathComponent("completion-cross-instance.json"))
        gateB.release(); let duplicateResult = await result(b)
        expect(duplicateResult == "changedEvidence", "Another instance cannot complete an already removed pending capture")
        expect(try cross.run(id: seed.id) == once, "Duplicate completion does not increment counts or change any field")
        expect(try Data(contentsOf: folder.appendingPathComponent("completion-cross-instance.json")) == onceBytes, "Duplicate completion performs no disk replacement")

        for name in ["pending-removed", "pending-changed", "capture-changed", "resolved-note-added"] {
            let target = store(name); try target.save(seed)
            let gate = SourceCompletionGate(), operation = start(XiaohongshuCollector(store: target), gate: gate)
            try await gate.awaitEntry()
            var latest = try target.run(id: seed.id)!
            switch name {
            case "pending-removed": latest.pending.removeAll()
            case "pending-changed": latest.pending[0].reason += "; legal review progress"
            case "capture-changed": latest.pending[0].sourceCapture!.note.screenshotSHA256 = String(repeating: "b", count: 64)
            default: latest.notes.append(newerNote)
            }
            latest.updatedAt = Date(); try target.save(latest)
            let bytes = try Data(contentsOf: folder.appendingPathComponent("completion-" + name + ".json"))
            gate.release(); let outcome = await result(operation)
            expect(outcome == "changedEvidence", "A missing or changed immutable pending binding rejects completion: " + name)
            expect(try target.run(id: seed.id) == latest, "Latest evidence is retained without stale fallback: " + name)
            expect(try Data(contentsOf: folder.appendingPathComponent("completion-" + name + ".json")) == bytes, "Rejection does not write: " + name)
            try retain(name + "-after", latest); outcomes.append(["case":name,"result":outcome])
        }

        for preexisting in [oldNote, newerNote] {
            let old = preexisting.observedAt < seed.pending[0].observedAt
            let name = old ? "older-preexisting-note" : "newer-preexisting-note"
            let target = store(name); var value = seed; value.notes.append(preexisting); try target.save(value)
            let gate = SourceCompletionGate(), operation = start(XiaohongshuCollector(store: target), gate: gate)
            try await gate.awaitEntry(); gate.release(); let outcome = await result(operation)
            if old {
                let completed = try target.run(id: seed.id)!
                expect(outcome == "success" && completed.duplicateObservations == 1 && completed.noteRevisions == [oldNote],
                    "An unchanged older observation still follows the existing revision behavior")
                expect(completed.pending.isEmpty && completed.notes.count == 2, "An older existing ID remains one unique sample")
            } else {
                expect(outcome == "changedEvidence", "An already newer note is not replaced by an older pending capture")
                expect(try target.run(id: seed.id) == value, "A rejected older pending source leaves the newer note intact")
            }
        }

        let immutableTask = store("task-conflict"); try immutableTask.save(seed)
        let taskGate = SourceCompletionGate(), taskOperation = start(XiaohongshuCollector(store: immutableTask), gate: taskGate)
        try await taskGate.awaitEntry()
        var conflict = seed; conflict.task.sampleSize += 1
        var taskError = ""
        do { try immutableTask.save(conflict) } catch XiaohongshuCollectionError.conflictingTask { taskError = "conflictingTask" }
        expect(taskError == "conflictingTask", "The actual Store rejects a task replacement while resolver awaits")
        taskGate.release(); _ = try await taskOperation.value
        expect(try immutableTask.run(id: seed.id)?.task == seed.task, "A rejected task mutation cannot silently rebind completion")

        let cancelled = store("cancelled"); try cancelled.save(seed)
        let cancelledCollector = XiaohongshuCollector(store: cancelled), cancelGate = SourceCompletionGate()
        let cancelledOperation = start(cancelledCollector, gate: cancelGate); try await cancelGate.awaitEntry()
        let beforeCancel = try Data(contentsOf: folder.appendingPathComponent("completion-cancelled.json"))
        cancelledOperation.cancel(); cancelGate.release(); let cancellation = await result(cancelledOperation)
        expect(cancellation == "CancellationError", "Cancellation after resolver keeps the original cancellation type")
        expect(try cancelled.run(id: seed.id) == seed, "Cancellation retains pending and all original work")
        expect(try Data(contentsOf: folder.appendingPathComponent("completion-cancelled.json")) == beforeCancel, "Cancellation performs no completion write")
        _ = try await cancelledCollector.completeCopiedSource(taskID: seed.id, clipboard: clipboard, resolveShortLink: driver.resolveShortLink)
        expect(try cancelled.run(id: seed.id)?.pending.isEmpty == true, "Cancellation releases the same-instance admission guard for explicit retry")

        let failed = store("io-failure"); try failed.save(seed)
        let failureCollector = XiaohongshuCollector(store: failed), failureGate = SourceCompletionGate()
        let failureOperation = start(failureCollector, gate: failureGate); try await failureGate.awaitEntry()
        let path = folder.appendingPathComponent("completion-io-failure.json"), backup = folder.appendingPathComponent("completion-io-original.json")
        let originalBytes = try Data(contentsOf: path)
        try FileManager.default.moveItem(at: path, to: backup)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try Data("synthetic blocker".utf8).write(to: path.appendingPathComponent("blocker"))
        failureGate.release(); let failure = await result(failureOperation)
        expect(failure == "unavailable", "An actual atomic write failure remains a storage error")
        expect(try failed.run(id: seed.id) == seed, "A failed completion write does not advance memory")
        expect(try Data(contentsOf: backup) == originalBytes, "The original checkpoint bytes are retained under the controlled I/O failure")
        try FileManager.default.removeItem(at: path); try FileManager.default.moveItem(at: backup, to: path)
        expect(try XiaohongshuCollectionStore(url: path).run(id: seed.id) == seed, "The retained checkpoint reopens with its pending evidence")
        _ = try await failureCollector.completeCopiedSource(taskID: seed.id, clipboard: clipboard, resolveShortLink: driver.resolveShortLink)
        expect(try failed.run(id: seed.id)?.pending.isEmpty == true, "A failed write releases only the in-memory completion gate for explicit retry")
        expect(originalInputs == (driver.fixture.copyTaps, driver.fixture.shareTaps, driver.fixture.noteOpens, driver.fixture.returns),
            "All helper completions, errors and retries issue zero additional Share, Copy, open or Back inputs")

        if let output {
            let report: [String: Any] = ["checks":count,"allPass":true,"cases":outcomes,"sourceCompletionUIInputs":0,
                "taskMutationControl":"public Store rejects conflictingTask before mutation; helper full-task guard retained for future store changes",
                "noPhone":true,"noNetwork":true,"noRealModel":true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("source-completion-results.json"), options: .atomic)
        }
        return count
    }
}
