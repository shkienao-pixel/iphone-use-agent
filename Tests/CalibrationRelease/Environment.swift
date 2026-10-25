import Foundation
import CoreBluetooth
import CoreGraphics

struct ScreenFrame { var sourceWidth = 390; var sourceHeight = 844 }
@MainActor enum SettingsStore {
    static var saveCount = 0
    static func saveCalibration(_ value: PointerCalibration) { saveCount += 1 }
}
struct SystemToolRequest {
    struct Operation { var label: String { "unused fixture" } }
    var operation = Operation()
    static func decode(_ text: String?) throws -> Self { .init() }
}
struct PhoneHarnessRequest {
    var label: String { "unused fixture" }
    static func decode(_ text: String?) throws -> Self { .init() }
}
typealias CBPeripheral = SyntheticPeripheral
typealias CBCharacteristic = SyntheticCharacteristic
final class SyntheticCharacteristic { let uuid = MouseProtocol.command }
@MainActor final class SyntheticPeripheral {
    enum WriteType { case withResponse }
    var onWrite: ((Data) -> Void)?
    func writeValue(_ bytes: Data, for characteristic: SyntheticCharacteristic, type: WriteType) { onWrite?(bytes) }
}
@MainActor final class SyntheticCentral {
    var disconnectRequests = 0
    func cancelPeripheralConnection(_ peer: SyntheticPeripheral) { disconnectRequests += 1 }
}

@MainActor final class BLETransport {
    var connected = true
    var selectedID: String? = "synthetic-accessory"
    var connectionGeneration = UUID()
    var pointerConnectionGeneration: UUID { connectionGeneration }
    var command: CBCharacteristic? = SyntheticCharacteristic()
    var peer: CBPeripheral?
    let central = SyntheticCentral()
    var statusChar: CBCharacteristic?, taskIndicatorChar: CBCharacteristic?
    var desiredIndicator: MouseProtocol.TaskIndicator = .idle, sentIndicator: MouseProtocol.TaskIndicator?
    var indicatorSentAt = Date.distantPast
    var sequence: UInt16 = 0
    var writer: CheckedContinuation<Void, Error>?
    var timeout: Task<Void, Never>?, connectTimeout: Task<Void, Never>?, scanTimeout: Task<Void, Never>?, serviceTimeout: Task<Void, Never>?
    var pairingInProgress = false, secureSessionReady = true
    var lastFlags: UInt8?
    var status: MouseProtocol.Status?, latestStatus: MouseProtocol.Status?
    var error = ""
    var pointerMotionTokens = Set<UUID>()
    var ready: Bool { connected && secureSessionReady && command != nil && status?.ready == true }
    var keyboardReady: Bool { ready && status?.keyboardAvailable == true }
    var bufferedMotionReady: Bool { ready && status?.bufferedMotionAvailable == true }
    var records: [String] = [], writes: [Data] = [], writeWasCancelled: [Bool] = []
    var onWrite: ((Data, CBPeripheral) -> Void)?
    var beforeAcknowledge: ((Data) -> Void)?
    init() { installPeer(); setStatus(sequence: 0) }
    func installPeer() {
        let peripheral = CBPeripheral(); peer = peripheral
        peripheral.onWrite = { [weak self, weak peripheral] bytes in
            guard let self, let peripheral else { return }
            writes.append(bytes); writeWasCancelled.append(Task.isCancelled)
            if let onWrite { onWrite(bytes, peripheral) }
            else {
                Task { @MainActor in
                    await Task.yield()
                    self.beforeAcknowledge?(bytes)
                    self.acknowledge(bytes, from: peripheral)
                }
            }
        }
    }
    func setStatus(sequence: UInt16, buttons: UInt8 = 0, error: UInt8 = 0) {
        let bytes = Data([1,7,buttons,error,UInt8(truncatingIfNeeded:sequence),UInt8(sequence >> 8),7,1])
        status = MouseProtocol.Status(bytes); latestStatus = status
    }
    func acknowledge(_ bytes: Data, from peripheral: CBPeripheral, error: Error? = nil) {
        let data = Array(bytes), sequence = UInt16(data[2]) | UInt16(data[3]) << 8
        if error == nil && peripheral === peer { setStatus(sequence:sequence) }
        self.peripheral(peripheral, didWriteValueFor: SyntheticCharacteristic(), error:error)
    }
    func switchConnection() {
        clear(); connectionGeneration = UUID(); connected = true; secureSessionReady = true
        selectedID = "synthetic-second-accessory"; command = SyntheticCharacteristic(); installPeer(); setStatus(sequence:sequence)
    }
    func refresh(afterBufferedMove: Bool = false) { }
    func record(_ text: String) { records.append(text) }
    // PRODUCTION_BLE_MEMBERS
}


@MainActor enum CalibrationReleaseFixture {
    static var recordURL = FileManager.default.temporaryDirectory.appendingPathComponent("calibration-release-unused.log")
}
@MainActor final class MouseExecutor {
    let ble: BLETransport
    var calibrationInProgress = false
    var calibration: PointerCalibration?
    var homeCalls = 0, invalidations = 0, moveCalls = 0, clickCalls = 0
    var onHome: (() async throws -> Void)?
    init(ble: BLETransport) { self.ble = ble }
    func homePointer() async throws { homeCalls += 1; if let onHome { try await onHome() } else { throw AgentError.message("synthetic first-home failure") } }
    func movePositionUnits(x: Int, y: Int) async throws { moveCalls += 1; throw AgentError.message("unexpected movement after first home") }
    func moveToPositionUnits(x: Int, y: Int) async throws -> CGPoint { moveCalls += 1; throw AgentError.message("unexpected fitted move") }
    func sleep(_ seconds: Double) async throws { try Task.checkCancellation(); await Task.yield() }
    func click() async throws { clickCalls += 1; throw AgentError.message("unexpected calibration probe") }
    func invalidatePosition() { invalidations += 1 }
}
