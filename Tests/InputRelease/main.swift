import Foundation

enum InputReleaseFixtureError: Error { case failed, injected }
@MainActor final class Checks {
    var count = 0, failures: [String] = [], rows: [[String: Any]] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1; if !condition() { failures.append(message) }
    }
    func row(_ name: String, _ result: InputReleaseResult, _ extra: [String: Any] = [:]) {
        var row = extra; row["case"] = name; row["outcome"] = result.outcome.rawValue
        row["submittedToTransport"] = result.submittedToTransport; row["attAcknowledged"] = result.attAcknowledged
        rows.append(row)
    }
}
@MainActor final class PolicyFixture {
    var generation = UUID(), available = true, busy = false, time = 0.0
    var submissions = 0, pauses = 0, cancelledSubmissionContexts: [Bool] = []
    var onPause: (() async throws -> Void)?, onSubmit: ((@MainActor () -> Void) async throws -> Void)?
    lazy var controller = InputReleaseController(state: { self.state }, submit: { generation, mark in
        guard generation == self.generation else { throw InputReleaseFixtureError.injected }
        self.submissions += 1; self.cancelledSubmissionContexts.append(Task.isCancelled)
        if let onSubmit = self.onSubmit { try await onSubmit(mark) } else { mark() }
    }, now: { self.time }, pause: {
        self.pauses += 1
        if let onPause = self.onPause { try await onPause() } else { self.time += 0.25 }
    })
    var state: InputReleaseController.State { .init(generation:generation,transportAvailable:available,writerBusy:busy) }
}
@MainActor func waitUntil(_ description: String, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw AgentError.message("synthetic wait timeout: " + description) }
        try await Task.sleep(nanoseconds:1_000_000)
    }
}
@MainActor func calibration() -> PointerCalibration {
    .init(screenWidth:390,screenHeight:844,gainX:1,gainY:1,originX:0,originY:0,validationError:0,
        peripheralID:"synthetic-accessory",createdAt:Date(),movementVersion:PointerMotion.profileVersion,
        crossX:0,crossY:0,calibrationVersion:CalibrationSolver.version,fitSampleCount:9,
        validationSampleCount:CalibrationSolver.validationTargets.count,validationRMS:0,returnDrift:0)
}
@MainActor func releaseWrites(_ ble: BLETransport) -> Int {
    ble.writes.filter { $0.count == 10 && $0[1] == MouseProtocol.Operation.release.rawValue }.count
}

@main struct InputReleaseChecks {
    @MainActor static func run(_ checks: Checks) async throws {
        try await runScrollChecks(checks)
        let delayed = PolicyFixture(); delayed.busy = true
        delayed.onPause = { delayed.time += 0.25; if delayed.time >= 1.25 { delayed.busy = false } }
        let waited = await delayed.controller.release(expectedGeneration:delayed.generation)
        checks.expect(waited.outcome == .acknowledgedWrite && delayed.time == 1.25 && delayed.submissions == 1, "writer completion after former1s limit still permits one release within ordinary3s budget")
        checks.row("writer clears at virtual1.25s",waited,["waitSeconds":delayed.time,"submissions":delayed.submissions])

        let blocked = PolicyFixture(); blocked.busy = true
        let busy = await blocked.controller.release(expectedGeneration:blocked.generation)
        checks.expect(busy.outcome == .notSubmittedWriterBusy && !busy.submittedToTransport && blocked.time == 3 && blocked.submissions == 0, "writer still occupied at3s is explicitly not submitted, never forcibly unlocked")
        blocked.busy = false
        let retryCleanup = await blocked.controller.release(expectedGeneration:blocked.generation)
        checks.expect(retryCleanup.attAcknowledged && blocked.submissions == 1, "completed cleanup result is not cached across later requests")
        checks.row("writer remains busy3s",busy,["waitSeconds":blocked.time])

        let changed = PolicyFixture(); changed.busy = true
        changed.onPause = { changed.time += 0.001; changed.generation = UUID(); changed.busy = false }
        let oldGeneration = changed.generation
        let switched = await changed.controller.release(expectedGeneration:oldGeneration)
        checks.expect(switched.outcome == .notSubmittedGenerationChanged && changed.submissions == 0, "generation changes after1ms waiting: no release written to new session")
        let registeredOld = await changed.controller.release(expectedGeneration:oldGeneration)
        checks.expect(registeredOld.outcome == .notSubmittedGenerationChanged && changed.pauses == 1, "old generation rejected before registering new work")
        checks.row("generation changes after virtual1ms",switched,["submissions":changed.submissions])

        let cancelled = PolicyFixture(); cancelled.busy = true
        var caller: Task<InputReleaseResult,Never>?
        cancelled.onPause = { cancelled.time += 0.001; caller?.cancel(); cancelled.busy = false }
        caller = Task { await cancelled.controller.release(expectedGeneration:cancelled.generation) }
        let cancellationResult = await caller!.value
        checks.expect(caller!.isCancelled && cancellationResult.attAcknowledged && cancelled.cancelledSubmissionContexts == [false], "caller cancelled after1ms cannot cancel fresh cleanup worker")
        checks.row("caller cancelled after virtual1ms",cancellationResult,["callerCancelled":caller!.isCancelled,"submissionContextsCancelled":cancelled.cancelledSubmissionContexts])

        for (name, action) in [("unavailable",0),("rejected",1),("unconfirmed",2),("postWriteGenerationChange",3)] {
            let fixture = PolicyFixture()
            if action == 0 { fixture.available = false }
            if action == 1 { fixture.onSubmit = { _ in throw InputReleaseFixtureError.injected } }
            if action == 2 { fixture.onSubmit = { mark in mark(); throw InputReleaseFixtureError.injected } }
            if action == 3 { fixture.onSubmit = { mark in mark(); fixture.generation = UUID() } }
            let result = await fixture.controller.release(expectedGeneration:fixture.generation)
            checks.expect(result.outcome == [InputReleaseResult.Outcome.notSubmittedUnavailable,.notSubmittedRejected,.unconfirmedWrite,.unconfirmedWrite][action], "fixed outcome truthfully reports \(name)")
            checks.expect(result.submittedToTransport == (action >= 2) && !result.attAcknowledged, "no false ATT acknowledgement for \(name)")
            checks.row(name,result)
        }
        let interrupted = PolicyFixture(); interrupted.busy = true
        interrupted.onPause = { throw InputReleaseFixtureError.injected }
        let interruptedResult = await interrupted.controller.release(expectedGeneration:interrupted.generation)
        checks.expect(interruptedResult.outcome == .notSubmittedWaitInterrupted && interrupted.submissions == 0, "a failed cleanup wait cannot be called a release write")
        let occupiedAtSubmit = PolicyFixture()
        occupiedAtSubmit.onSubmit = { _ in occupiedAtSubmit.busy = true; throw InputReleaseFixtureError.injected }
        let occupiedResult = await occupiedAtSubmit.controller.release(expectedGeneration:occupiedAtSubmit.generation)
        checks.expect(occupiedResult.outcome == .notSubmittedWriterBusy && !occupiedResult.submittedToTransport, "a writer acquired at the submit boundary remains busy and explicitly not submitted")
        checks.row("writer acquired at submit boundary",occupiedResult)

        let ble = BLETransport(), generation = ble.pointerConnectionGeneration
        let release = await ble.release(expectedConnection:generation)
        checks.expect(release.attAcknowledged && release.submittedToTransport && releaseWrites(ble) == 1, "actual extracted native-call observer and didWrite ACK produce acknowledgedWrite")
        checks.expect(ble.writeWasCancelled == [false], "cleanup transport write uses uncancelled context")
        checks.row("native transport call then actual extracted ACK method",release)
        let writesBefore = ble.writes.count
        let ordinaryCancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await ble.send(.click); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let ordinaryRejected = await ordinaryCancelled.value
        checks.expect(ordinaryRejected && ble.writes.count == writesBefore, "ordinary cancelled input retains cancellation gate and writes nothing")

        let rejectedBLE = BLETransport(); rejectedBLE.pairingInProgress = true
        let rejected = await rejectedBLE.release()
        checks.expect(rejected.outcome == .notSubmittedRejected && rejectedBLE.writes.isEmpty, "cleanup cannot bypass pairing guard")
        let errorBLE = BLETransport()
        errorBLE.onWrite = { data, peer in
            Task { @MainActor in await Task.yield(); errorBLE.acknowledge(data,from:peer,error:InputReleaseFixtureError.injected) }
        }
        let unconfirmed = await errorBLE.release()
        checks.expect(unconfirmed.outcome == .unconfirmedWrite && unconfirmed.submittedToTransport && !unconfirmed.attAcknowledged && releaseWrites(errorBLE) == 1, "native write followed by error remains unconfirmed and is never retried")
        checks.row("native release write ACK error",unconfirmed)
        let oldBLE = BLETransport(), expectedOld = oldBLE.pointerConnectionGeneration
        oldBLE.switchConnection()
        do { _ = try await oldBLE.send(.release,expectedConnection:expectedOld) } catch { }
        checks.expect(oldBLE.writes.isEmpty, "real send generation guard rejects stale expected connection before packet submission")

        let coalesced = BLETransport()
        var pendingRelease: (Data,CBPeripheral)?, starts = 0
        coalesced.onWrite = { data, peer in pendingRelease = (data,peer) }
        let requests = (0..<12).map { _ in Task { @MainActor in
            starts += 1
            return await coalesced.release(expectedConnection:coalesced.pointerConnectionGeneration)
        } }
        try await waitUntil("all cleanup callers join one pending write") { starts == 12 && pendingRelease != nil }
        checks.expect(releaseWrites(coalesced) == 1 && coalesced.writer != nil, "concurrent cleanup coalesces one writer without clearing it")
        coalesced.acknowledge(pendingRelease!.0,from:pendingRelease!.1)
        var results: [InputReleaseResult] = []
        for request in requests { results.append(await request.value) }
        checks.expect(results.count == 12 && results.allSatisfy { $0.attAcknowledged } && releaseWrites(coalesced) == 1, "same generation concurrent callers each receive same ACK evidence, with only one release write")
        checks.row("12 concurrent cleanup requests",results[0],["requests":12,"releaseWrites":releaseWrites(coalesced)])

        for kind in [AgentAction.Kind.tap,.long_press,.drag] {
            let native = BLETransport(), owner = ManualOwner(native)
            owner.executor.calibration = calibration()
            var cancelledAtACK = false
            native.beforeAcknowledge = { data in
                if !cancelledAtACK && ((kind == .tap && data[1] == MouseProtocol.Operation.click.rawValue) ||
                    (kind != .tap && data[0] == 1 && data[1] == MouseProtocol.Operation.report.rawValue && data[4] == 1)) {
                    cancelledAtACK = true; owner.manual?.cancel()
                }
            }
            owner.manualAction {
                try await owner.executor.execute(.init(kind:kind,x:0.5,y:0.5,x2:0.6,y2:0.6,seconds:0.6,reason:"synthetic ACK cancellation"),frame:.init())
            }
            let task = owner.manual!
            await task.value
            checks.expect(cancelledAtACK && task.isCancelled && !owner.manualBusy && owner.manual == nil, "\(kind) ACK cancellation returns ownership after cleanup")
            checks.expect(releaseWrites(native) >= 1 && native.writeWasCancelled.allSatisfy { !$0 }, "\(kind) cancellation still submits cleanup in fresh context")
            checks.expect(native.writes.filter { $0[0] == 1 && $0[1] == MouseProtocol.Operation.click.rawValue }.count == (kind == .tap ? 1:0), "\(kind) cleanup never repeats click")
            checks.expect(native.writes.filter { $0[0] == 1 && $0[1] == MouseProtocol.Operation.report.rawValue && $0[4] == 1 }.count == (kind == .tap ? 0:1), "\(kind) cancellation never continues held-button input")
            checks.rows.append(["case":"manual \(kind) cancelled at ACK","releaseWrites":releaseWrites(native),"ordinaryTaskCancelled":task.isCancelled,"writesFromCancelledTask":native.writeWasCancelled.contains(true)])
        }

        let draggingBLE = BLETransport(), draggingOwner = ManualOwner(draggingBLE)
        draggingOwner.executor.calibration = calibration()
        var cancelledInMotion = false
        draggingBLE.beforeAcknowledge = { data in
            if data[0] == 2 && data[4] == 1 {
                cancelledInMotion = true; draggingOwner.manual?.cancel()
            }
        }
        draggingOwner.manualAction {
            try await draggingOwner.executor.execute(.init(kind:.drag,x:0.5,y:0.5,x2:0.6,y2:0.6,seconds:0.6,reason:"synthetic motion ACK cancellation"),frame:.init())
        }
        let draggingTask = draggingOwner.manual!
        await draggingTask.value
        checks.expect(cancelledInMotion && draggingTask.isCancelled && !draggingOwner.manualBusy && releaseWrites(draggingBLE) >= 1, "drag movement ACK cancellation unwinds all ownership only after cleanup")
        checks.expect(draggingBLE.writes.filter { $0[0] == 2 && $0[4] == 1 }.count == 1 && draggingBLE.writeWasCancelled.allSatisfy { !$0 }, "cancelled held trajectory is not replayed or continued by uncancelling ordinary input")
        checks.rows.append(["case":"drag cancelled during held buffered movement","releaseWrites":releaseWrites(draggingBLE),"heldTrajectories":draggingBLE.writes.filter { $0[0] == 2 && $0[4] == 1 }.count])

        let changedManualBLE = BLETransport(), changedOwner = ManualOwner(changedManualBLE)
        changedOwner.executor.calibration = calibration()
        var switchedAtClick = false
        changedManualBLE.beforeAcknowledge = { data in
            if !switchedAtClick && data[1] == MouseProtocol.Operation.click.rawValue {
                switchedAtClick = true; changedOwner.manual?.cancel(); changedManualBLE.switchConnection()
            }
        }
        changedOwner.manualAction { try await changedOwner.executor.execute(.init(kind:.tap,x:0.5,y:0.5,reason:"synthetic session switch"),frame:.init()) }
        await changedOwner.manual!.value
        checks.expect(switchedAtClick && releaseWrites(changedManualBLE) == 0 && !changedOwner.manualBusy, "manual original-generation cleanup cannot release new accessory")

        let waitingBLE = BLETransport(), originalGeneration = waitingBLE.pointerConnectionGeneration
        var held: (Data,CBPeripheral)?
        waitingBLE.onWrite = { data, peer in held = (data,peer) }
        let writing = Task { @MainActor in try await waitingBLE.send(.report,x:1) }
        try await waitUntil("ordinary write submitted") { held != nil }
        let cleaning = Task { await waitingBLE.release(expectedConnection:originalGeneration) }
        try await Task.sleep(nanoseconds:1_000_000)
        waitingBLE.switchConnection()
        let changedResult = await cleaning.value
        _ = try? await writing.value
        waitingBLE.acknowledge(held!.0,from:held!.1)
        checks.expect(changedResult.outcome == .notSubmittedGenerationChanged && releaseWrites(waitingBLE) == 0, "connection change after1ms writer wait blocks old cleanup and old ACK")
        checks.row("generation change while waiting real extracted writer",changedResult)

        // One real three-second production timeout. The exact terminal state is
        // unavailable or still-busy if the cleanup deadline wins scheduling;
        // both prove no cleanup write. Neither is called an acknowledgement.
        let timed = BLETransport(), timedGeneration = timed.pointerConnectionGeneration
        var timedPacket: (Data,CBPeripheral)?
        timed.onWrite = { data, peer in timedPacket = (data,peer) }
        let timeoutWriter = Task { @MainActor in try await timed.send(.report,x:1) }
        try await waitUntil("timeout write submitted") { timedPacket != nil }
        let timeoutCleanup = Task { await timed.release(expectedConnection:timedGeneration) }
        var originalThrew = false
        do { _ = try await timeoutWriter.value } catch { originalThrew = true }
        let timeoutResult = await timeoutCleanup.value
        checks.expect(originalThrew && timed.command == nil && timed.central.disconnectRequests == 1, "actual3s write timeout quarantines command and requests disconnect before another write")
        checks.expect([.notSubmittedUnavailable,.notSubmittedWriterBusy].contains(timeoutResult.outcome) && !timeoutResult.submittedToTransport && releaseWrites(timed) == 0, "writer timeout cleanup never claims a release write or ACK")
        let timedCount = timed.writes.count
        timed.acknowledge(timedPacket!.0,from:timedPacket!.1)
        do { _ = try await timed.send(.click) } catch { }
        checks.expect(timed.writer == nil && timed.writes.count == timedCount, "late ATT callback cannot satisfy a new writer because quarantined command remains unavailable")
        checks.row("actual ordinary3s ATT timeout",timeoutResult,["disconnectRequests":timed.central.disconnectRequests,"releaseWrites":releaseWrites(timed)])
    }
    @MainActor static func main() async throws {
        let checks = Checks()
        do { try await run(checks) } catch { checks.failures.append("fixture aborted: " + error.localizedDescription) }
        let result: [String:Any] = ["schemaVersion":1,"checks":checks.count,"failures":checks.failures,"cases":checks.rows,
            "syntheticTransportOnly":true,"physicalBLEPhoneModelCalls":false,"attAcknowledgementIsNotHIDRelease":true]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]),options:.atomic)
        guard checks.failures.isEmpty else { for failure in checks.failures { print("FAIL: " + failure) }; throw InputReleaseFixtureError.failed }
        print("InputRelease: \(checks.count) production controller/Mouse/transport/manual cancellation checks passed (synthetic transport only; ATT ACK is not HID release)")
    }
}
