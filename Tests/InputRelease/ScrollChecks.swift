import Foundation

/// Runs the production executor and original transport methods, with synthetic
/// BLE I/O. These checks establish command order and rejection, not phone UI.
@MainActor func runScrollChecks(_ checks: Checks) async throws {
    func wheels(_ ble: BLETransport) -> [Data] {
        ble.writes.filter { $0.count == 10 && $0[1] == MouseProtocol.Operation.report.rawValue && $0[7] != 0 }
    }
    let target = AgentAction(kind:.scroll,x:0.4,y:0.6,amount:-3,reason:"定位评论区滚动")
    let mouse = BLETransport(); mouse.fixtureCapabilities = 4; mouse.setStatus(sequence:0)
    let executor = MouseExecutor(ble:mouse); executor.calibration = calibration()
    try await executor.execute(target,frame:.init())
    checks.expect(!mouse.keyboardReady && wheels(mouse).count == 1, "targeted wheel works with mouse-only capability retained through all ACKs")
    checks.expect(mouse.writes.count == 3 && mouse.writes[0][0] == 2 && mouse.writes[1][0] == 2 && mouse.writes[2] == wheels(mouse).first, "homing and positioning precede exactly one wheel report")
    checks.expect(mouse.writes.allSatisfy { $0[4] == 0 } && mouse.writes.allSatisfy { $0[0] != 1 || ![UInt8(2),UInt8(4)].contains($0[1]) }, "anchoring never clicks, holds a button or sends a keyboard report")
    checks.expect(wheels(mouse).first?[7] == UInt8(bitPattern:Int8(-3)) && mouse.pointerMotionTokens.isEmpty, "signed wheel and pointer ownership are preserved")
    checks.rows.append(["case":"targeted mouse-only wheel","movementCommands":2,"wheelCommands":1,"clicks":0,"physicalPhoneVerified":false])

    let legacy = BLETransport()
    // No calibration is needed when the caller explicitly keeps current-pointer behavior.
    let currentPointerExecutor = MouseExecutor(ble:legacy)
    try await currentPointerExecutor.execute(.init(kind:.scroll,amount:3,reason:"旧滚轮动作"),frame:.init())
    checks.expect(legacy.writes.count == 1 && wheels(legacy).count == 1, "legacy amount-only scroll does not move or require calibration")

    let delayed = BLETransport(), delayedExecutor = MouseExecutor(ble:delayed)
    var pendingWheel: UInt16?
    delayed.onWrite = { bytes, peer in
        Task { @MainActor in
            await Task.yield()
            // An ATT ACK alone cannot establish hardware input completion.
            pendingWheel = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
            delayed.peripheral(peer,didWriteValueFor:SyntheticCharacteristic(),error:nil)
        }
    }
    var completed = false
    let delayedTask = Task { @MainActor in
        try await delayedExecutor.execute(.init(kind:.scroll,amount:-2,reason:"等待真实序号状态"),frame:.init())
        completed = true
    }
    try await waitUntil("wheel ATT acknowledgement") { pendingWheel != nil && delayed.writer == nil }
    try await Task.sleep(nanoseconds:40_000_000)
    checks.expect(!completed && wheels(delayed).count == 1, "old idle plus ATT acknowledgement neither completes nor replays wheel")
    delayed.setStatus(sequence:pendingWheel!)
    try await delayedTask.value
    checks.expect(completed && wheels(delayed).count == 1, "matching released HID status completes wheel once; UI still needs observation")

    for (name, action) in [
        ("missing y",AgentAction(kind:.scroll,x:0.5,amount:-3,reason:"invalid")),
        ("missing x",AgentAction(kind:.scroll,y:0.5,amount:-3,reason:"invalid")),
        ("NaN",AgentAction(kind:.scroll,x:.nan,y:0.5,amount:-3,reason:"invalid")),
        ("infinity",AgentAction(kind:.scroll,x:0.5,y:.infinity,amount:-3,reason:"invalid")),
        ("out of frame",AgentAction(kind:.scroll,x:-0.01,y:0.5,amount:-3,reason:"invalid"))
    ] {
        let ble = BLETransport()
        let tested = MouseExecutor(ble:ble); tested.calibration = calibration()
        var rejected = false
        do { try await tested.execute(action,frame:.init()) } catch { rejected = true }
        checks.expect(rejected && ble.writes.isEmpty, "\(name) anchor rejected before any input")
    }
    for mode in ["uncalibrated","rotated","boot"] {
        let ble = BLETransport()
        let tested = MouseExecutor(ble:ble)
        if mode != "uncalibrated" { tested.calibration = calibration() }
        if mode == "boot" { ble.fixtureFlags = 39; ble.setStatus(sequence:0) }
        var rejected = false
        do {
            try await tested.execute(target,frame:mode == "rotated" ? .init(sourceWidth:844,sourceHeight:390) : .init())
        } catch { rejected = true }
        checks.expect(rejected && wheels(ble).isEmpty && ble.writes.allSatisfy { $0[1] == 3 }, "\(mode) cannot move or scroll; only same-session release cleanup may occur")
    }

    for interruption in ["cancel","reconnect"] {
        let ble = BLETransport()
        let tested = MouseExecutor(ble:ble); tested.calibration = calibration()
        var interrupted = false, movements = 0
        var task: Task<Bool,Never>?
        ble.beforeAcknowledge = { data in
            // Interrupt at the target movement ACK, after homing has completed.
            if data[0] == 2 { movements += 1 }
            if !interrupted && data[0] == 2 && movements == 2 {
                interrupted = true
                if interruption == "cancel" { task?.cancel() }
                else { ble.switchConnection() }
            }
        }
        task = Task { @MainActor in
            do { try await tested.execute(target,frame:.init()); return false } catch { return true }
        }
        let rejected = await task!.value
        checks.expect(interrupted && rejected && wheels(ble).isEmpty, "\(interruption) during positioning stops wheel submission")
        checks.expect(ble.pointerMotionTokens.isEmpty && (interruption != "reconnect" || releaseWrites(ble) == 0), "\(interruption) unwinds ownership without releasing replacement session")
        checks.rows.append(["case":"targeted scroll interrupted during positioning","interruption":interruption,"wheelCommands":wheels(ble).count,"releaseWrites":releaseWrites(ble)])
    }
}
