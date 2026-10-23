import Foundation
import CoreBluetooth
import Combine

struct AgentPeripheral: Identifiable {
    let peripheral: CBPeripheral
    var id: UUID { peripheral.identifier }
    var name: String { peripheral.name ?? "AgentMouse" }
}

@MainActor
final class BLETransport: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var devices: [AgentPeripheral] = []
    @Published private(set) var state = "蓝牙初始化中"
    @Published private(set) var connected = false
    @Published private(set) var scanning = false
    @Published private(set) var status: MouseProtocol.Status?
    @Published private(set) var error = ""
    @Published private(set) var selectedID: String?
    private var central: CBCentralManager!
    private var peer: CBPeripheral?
    private var command: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var taskIndicatorChar: CBCharacteristic?
    private var desiredIndicator: MouseProtocol.TaskIndicator = .idle
    private var sentIndicator: MouseProtocol.TaskIndicator?
    private var indicatorSentAt = Date.distantPast
    private var sequence: UInt16 = 0
    private var writer: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var serviceTimeout: Task<Void, Never>?
    private var poll: Timer?
    private var pairingInProgress = false
    private var secureSessionReady = false
    private var connectionGeneration = UUID()
    var pointerConnectionGeneration: UUID { connectionGeneration }
    private var diagnosticLines: [String] = []
    private var lastFlags: UInt8?
    private var latestStatus: MouseProtocol.Status?
    private var pointerMotionTokens = Set<UUID>()
    var ready: Bool { connected && secureSessionReady && command != nil && status?.ready == true }
    var keyboardReady: Bool { ready && status?.keyboardAvailable == true }
    var bufferedMotionReady: Bool { ready && status?.bufferedMotionAvailable == true }
    var writable: Bool { ready && writer == nil && status?.busy != true }

    override init() {
        super.init()
        record("App started; secure-handshake build")
        central = CBCentralManager(delegate: self, queue: .main)
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.flushTaskIndicator() }
        }
    }
    deinit { poll?.invalidate() }
    private func record(_ text: String) {
        diagnosticLines.append("\(Date().ISO8601Format()) \(text)")
        diagnosticLines = Array(diagnosticLines.suffix(150))
        let file = URL.documentsDirectory.appendingPathComponent("ble-diagnostics.log")
        try? diagnosticLines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    func scan() {
        guard central.state == .poweredOn else {
            error = central.state == .unauthorized ? "请在 iPhone 设置中允许 Phone Agent 使用蓝牙" : "请先开启 iPhone 蓝牙"
            return
        }
        guard !connected, peer == nil, !scanning else { return }
        devices = []; error = ""; scanning = true; state = "正在查找 AgentMouse…找到后会自动连接"
        record("Scan requested")
        let active = central.retrieveConnectedPeripherals(withServices: [MouseProtocol.hid, MouseProtocol.service])
        if let peripheral = active.first(where: { $0.name?.hasPrefix("AgentMouse") == true }) {
            let device = AgentPeripheral(peripheral: peripheral)
            add(peripheral)
            connect(device)
            return
        }
        // The control UUID is in the accessory's BLE scan response. An unfiltered scan
        // also sees devices that advertise only HID in their primary advertisement.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.scanning else { return }
            self.stopScan()
            if self.devices.isEmpty {
                self.error = "未找到 AgentMouse。先确认配件有电、iPhone 蓝牙已开启；新设备需先在 iOS“辅助触控 → 设备 → 蓝牙设备”配对，再回此页连接。"
                self.state = "未找到配件"
            }
        }
    }
    func stopScan() { central.stopScan(); scanTimeout?.cancel(); scanTimeout = nil; scanning = false }
    private func add(_ p: CBPeripheral) {
        if !devices.contains(where: { $0.id == p.identifier }) { devices.append(AgentPeripheral(peripheral: p)) }
    }
    func connect(_ d: AgentPeripheral) {
        guard central.state == .poweredOn, !connected, peer == nil else { return }
        stopScan(); state = "正在连接 \(d.name)"; error = ""
        peer = d.peripheral; selectedID = d.id.uuidString; peer?.delegate = self
        connectionGeneration = UUID()
        desiredIndicator = .idle; sentIndicator = nil; indicatorSentAt = .distantPast
        record("Connect requested: \(d.id)")
        central.connect(d.peripheral, options: nil)
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, !self.connected else { return }
            self.error = "App 连接超时。请确认 AgentMouse 已在 iOS“辅助触控 → 设备”配对；刚配对后可关闭再开启辅助触控，再回此页重试。"
            self.disconnect()
        }
    }
    func disconnect() { if let peer { central.cancelPeripheralConnection(peer) } }
    func beginPointerMotion() -> UUID {
        let token = UUID(); pointerMotionTokens.insert(token); return token
    }
    func endPointerMotion(_ token: UUID) { pointerMotionTokens.remove(token) }
    func recordPointerTiming(reports: Int, expectedMS: Double, maxAcknowledgementMS: Double, maxIntervalMS: Double) {
        guard reports > 0 else { return }
        // One aggregate after the move; no file writes inside the report loop.
        record(String(format: "Motion reports=%d expected=%.1fms maxAck=%.1fms maxInterval=%.1fms",
            reports, expectedMS, maxAcknowledgementMS, maxIntervalMS))
    }
    func refresh(afterBufferedMove: Bool = false) {
        // A periodic ATT read can occupy the request/response channel between
        // movement reports. Notifications still deliver errors/readiness while
        // moving, so status polling is reserved for gaps between movements.
        if connected, !pairingInProgress, writer == nil, (pointerMotionTokens.isEmpty || afterBufferedMove),
           let peer, let statusChar { peer.readValue(for: statusChar) }
    }
    func setTaskIndicator(_ value: MouseProtocol.TaskIndicator) {
        desiredIndicator = value
        flushTaskIndicator()
    }
    private func flushTaskIndicator() {
        // Optional S3 characteristic. LED updates do not enter the serial HID
        // acknowledgement queue, and old firmware simply has no such value.
        guard ready, let peer, let taskIndicatorChar,
              taskIndicatorChar.properties.contains(.writeWithoutResponse),
              peer.canSendWriteWithoutResponse else { return }
        guard sentIndicator != desiredIndicator || Date().timeIntervalSince(indicatorSentAt) >= 2 else { return }
        peer.writeValue(Data([1, desiredIndicator.rawValue]), for: taskIndicatorChar, type: .withoutResponse)
        sentIndicator = desiredIndicator; indicatorSentAt = Date()
    }
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if p === peer { flushTaskIndicator() }
    }
    func send(_ op: MouseProtocol.Operation, buttons: UInt8 = 0, x: Int = 0, y: Int = 0,
              wheel: Int = 0, delay: UInt16 = 0, pairingHandshake: Bool = false) async throws {
        try Task.checkCancellation()
        guard connected, peer != nil, command != nil else { throw AgentError.message("蓝牙配件未连接") }
        guard writer == nil else { throw AgentError.message("配件正在接收另一条指令") }
        guard !pairingInProgress || pairingHandshake else { throw AgentError.message("正在建立安全连接，请稍候") }
        guard !pairingHandshake || op == .release else { throw AgentError.message("无效的连接握手") }
        if op != .release && !ready { throw AgentError.message("请先连接辅助触控中的蓝牙鼠标") }
        if op != .release && status?.busy == true { throw AgentError.message("配件正在执行点击") }
        sequence &+= 1
        let bytes: Data
        if op == .keyboard {
            guard keyboardReady else { throw AgentError.message("蓝牙键盘未就绪，请在设备页查看连接状态") }
            guard x == 0 || (4...101).contains(x) else { throw AgentError.message("无效的键盘按键") }
            bytes = Data([1,4,UInt8(truncatingIfNeeded: sequence),UInt8(sequence >> 8),buttons,
                          UInt8(x),0,0,0,0])
        } else { bytes = MouseProtocol.packet(op, sequence: sequence, buttons: buttons, x: x, y: y, wheel: wheel, delay: delay) }
        try await writeCommand(bytes, pairingHandshake: pairingHandshake)
        if latestStatus?.sequence == sequence, let code = latestStatus?.error, code != 0 {
            throw AgentError.message("配件报告错误 \(code)，已停止动作")
        }
    }
    private func writeCommand(_ bytes: Data, pairingHandshake: Bool = false) async throws {
        guard let peer, let command, writer == nil else { throw AgentError.message("蓝牙写入状态异常") }
        try await withCheckedThrowingContinuation { continuation in
            writer = continuation
            if pairingHandshake { record("Encrypted release handshake: write submitted; timeout=35s") }
            peer.writeValue(bytes, for: command, type: .withResponse)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: pairingHandshake ? 35_000_000_000 : 3_000_000_000)
                guard !Task.isCancelled, let self, let writer = self.writer else { return }
                self.writer = nil
                self.error = pairingHandshake ? "安全连接未完成，已停止等待；请重新连接，若仍失败需检查配对记录。" : "蓝牙写入超时，停止执行"
                self.record(pairingHandshake ? "Handshake timed out" : "Command write timed out")
                writer.resume(throwing: AgentError.message(self.error))
                // Disconnect before permitting another write: late ATT responses have no transaction ID.
                self.command = nil; self.central.cancelPeripheralConnection(peer)
            }
        }
        try Task.checkCancellation()
    }
    func moveBuffered(x: Int, y: Int, buttons: UInt8 = 0, reports: Int, intervalMS: Int) async throws {
        try Task.checkCancellation()
        guard bufferedMotionReady else { throw AgentError.message("请升级配件到板端匀速移动固件后再校准") }
        guard writer == nil, latestStatus?.busy != true else { throw AgentError.message("配件仍在执行上一条动作") }
        guard abs(x) < 10000, abs(y) < 10000, buttons <= 7, (1...2000).contains(reports),
              (20...100).contains(intervalMS), reports * intervalMS <= 80000,
              (abs(x) + reports - 1) / reports <= 127, (abs(y) + reports - 1) / reports <= 127 else {
            throw AgentError.message("板端移动参数异常")
        }
        let connection = connectionGeneration
        sequence &+= 1; let moveSequence = sequence
        let duration = Double(reports * intervalMS) / 1000
        let began = ContinuousClock.now
        try await writeCommand(MouseProtocol.movementPacket(sequence: moveSequence, buttons: buttons,
            x: x, y: y, reports: reports, intervalMS: intervalMS))
        let ackTime = began.duration(to: .now).components
        let ackMS = Double(ackTime.seconds) * 1000 + Double(ackTime.attoseconds) / 1e15
        let expectedEnd = began.advanced(by: .seconds(duration + 0.35))
        let deadline = expectedEnd.advanced(by: .seconds(5))
        var nextRead = expectedEnd
        while true {
            try Task.checkCancellation()
            guard ready, connectionGeneration == connection else { throw AgentError.message("板端移动期间连接已变化") }
            guard sequence == moveSequence else { throw AgentError.message("板端移动已被中断") }
            if let s = latestStatus, s.sequence == moveSequence {
                guard s.error == 0 else { throw AgentError.message("板端移动失败，配件错误 \(s.error)") }
                if !s.busy {
                    record(String(format: "Buffered motion seq=%u reports=%d interval=%dms startAck=%.1fms completed",
                        moveSequence, reports, intervalMS, ackMS))
                    return
                }
            }
            let now = ContinuousClock.now
            guard now < deadline else { throw AgentError.message("等待板端移动完成超时，已停止定位") }
            // Recovery reads begin only after the trajectory should have ended.
            if now >= nextRead { refresh(afterBufferedMove: true); nextRead = now.advanced(by: .seconds(0.25)) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func release() async {
        for _ in 0..<100 {
            if writer == nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await send(.release)
    }
    func waitIdle() async throws {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            try Task.checkCancellation()
            refresh()
            try await Task.sleep(nanoseconds: 80_000_000)
            guard ready else { throw AgentError.message("鼠标连接已失效") }
            if status?.busy != true { return }
        } while Date() < deadline
        throw AgentError.message("等待配件释放按键超时")
    }
    private func clear() {
        timeout?.cancel(); connectTimeout?.cancel(); scanTimeout?.cancel(); serviceTimeout?.cancel()
        writer?.resume(throwing: AgentError.message("配件已断开")); writer = nil
        peer = nil; command = nil; statusChar = nil; taskIndicatorChar = nil; connected = false; status = nil; selectedID = nil
        latestStatus = nil; pointerMotionTokens.removeAll()
        pairingInProgress = false; secureSessionReady = false; lastFlags = nil
        desiredIndicator = .idle; sentIndicator = nil; indicatorSentAt = .distantPast
        connectionGeneration = UUID()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        record("Central state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            state = "蓝牙已开启"
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--connect-accessory") { scan() }
            #endif
        }
        else { stopScan(); clear(); state = central.state == .unauthorized ? "请允许蓝牙权限" : "请开启蓝牙" }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix("AgentMouse") else { return }
        add(peripheral)
        if peer == nil && !connected { connect(AgentPeripheral(peripheral: peripheral)) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peer?.identifier == peripheral.identifier else { return }
        record("Connected; discovering control service")
        connectTimeout?.cancel(); connected = true; state = "已连接，正在检查配件…"
        peripheral.discoverServices([MouseProtocol.service])
        serviceTimeout?.cancel()
        serviceTimeout = Task { [weak self, weak peripheral] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, let peripheral,
                  self.peer?.identifier == peripheral.identifier, self.command == nil else { return }
            self.error = "已连上蓝牙，但配件没有回应控制服务。请确认 AgentMouse 固件正在运行。"
            self.central.cancelPeripheralConnection(peripheral)
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        record("Connect failed: \(String(describing: error))")
        self.error = "iPhone 连接失败：\(error?.localizedDescription ?? "请重试")。若刚完成配对，可关闭再开启辅助触控后重试。"
        clear(); state = "连接失败"
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        record("Disconnected: \(String(describing: error))")
        if let error { self.error = error.localizedDescription }; clear(); state = "配件已断开"
    }
    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard p === peer, command != nil,
              invalidatedServices.contains(where: { $0.uuid == MouseProtocol.service }) else { return }
        // Never continue pointer writes with invalidated ATT handles.
        command = nil; taskIndicatorChar = nil; secureSessionReady = false
        error = "配件控制服务已更新，请重新连接"
        record("Control service invalidated; disconnecting stale handles")
        central.cancelPeripheralConnection(p)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peer else { return }
        record("Services: \(p.services?.map { $0.uuid.uuidString } ?? []); error=\(String(describing: error))")
        guard error == nil, let service = p.services?.first(where: { $0.uuid == MouseProtocol.service }) else {
            self.error = error.map { "读取蓝牙服务失败：\($0.localizedDescription)" } ?? "找不到配件控制服务，请确认固件版本。"
            return
        }
        p.discoverCharacteristics([MouseProtocol.command, MouseProtocol.status, MouseProtocol.taskIndicator], for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peer else { return }
        record("Characteristics discovered; error=\(String(describing: error))")
        command = service.characteristics?.first(where: { $0.uuid == MouseProtocol.command })
        statusChar = service.characteristics?.first(where: { $0.uuid == MouseProtocol.status })
        taskIndicatorChar = service.characteristics?.first(where: { $0.uuid == MouseProtocol.taskIndicator })
        record("Task RGB characteristic: \(taskIndicatorChar != nil)")
        guard error == nil, command?.properties.contains(.write) == true,
              let statusChar, statusChar.properties.contains(.read) else {
            self.error = error.map { "读取配件特征失败：\($0.localizedDescription)" } ?? "控制服务不完整，请检查 ESP32 固件。"
            return
        }
        serviceTimeout?.cancel(); serviceTimeout = nil
        p.setNotifyValue(true, for: statusChar)
        // The unencrypted status characteristic cannot trigger system pairing.
        // Access the encrypted command characteristic once, with a separate
        // pairing deadline. A release never generates a click or movement.
        pairingInProgress = true; secureSessionReady = false
        state = "正在建立安全连接…系统若询问蓝牙配对，请点“配对”"
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            do {
                try await self.send(.release, pairingHandshake: true)
                guard generation == self.connectionGeneration else { return }
                self.pairingInProgress = false; self.secureSessionReady = true
                self.record("Secure handshake acknowledged")
                self.state = "安全连接已建立，正在读取鼠标状态…"
                self.refresh(); self.flushTaskIndicator()
            } catch {
                guard generation == self.connectionGeneration else { return }
                self.pairingInProgress = false
                self.record("Secure handshake failed: \(error)")
                self.error = error.localizedDescription
                self.state = "安全连接失败，请重新连接"
                self.disconnect()
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { self.error = error.localizedDescription }; refresh()
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peer else { return }
        if let error { record("Status read failed: \(error)") }
        guard error == nil, c.uuid == MouseProtocol.status, let bytes = c.value, let s = MouseProtocol.Status(bytes) else { return }
        if lastFlags != s.flags {
            lastFlags = s.flags
            record("Status flags=\(s.flags) encrypted=\(s.encrypted) hid=\(s.hidSubscribed)")
        }
        // Preserve the full latest sequence for transport checks. Sequence-only
        // notifications don't need to redraw the whole SwiftUI app at 25 Hz.
        latestStatus = s
        if status?.flags != s.flags || status?.buttons != s.buttons ||
            status?.error != s.error || status?.keyboardAvailable != s.keyboardAvailable ||
            status?.keyboardSupported != s.keyboardSupported || status?.capsLock != s.capsLock ||
            status?.bufferedMotionAvailable != s.bufferedMotionAvailable { status = s }
        let nextState: String
        if pairingInProgress { nextState = "正在建立安全连接…系统若询问蓝牙配对，请点“配对”" }
        else if ready { nextState = "鼠标已就绪" }
        else if !s.encrypted { nextState = "连接尚未加密，请重新连接配件" }
        else if !s.hidSubscribed { nextState = "蓝牙已连上；请在辅助触控中连接 AgentMouse 作为鼠标" }
        else if s.suspended { nextState = "系统暂时暂停鼠标，请唤醒屏幕或重新连接" }
        else { nextState = "正在准备鼠标…" }
        if state != nextState { state = nextState }
        flushTaskIndicator()
        if s.error == 5, self.error != "配件按键保持超时，已触发释放保护" {
            self.error = "配件按键保持超时，已触发释放保护"
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peer, c.uuid == MouseProtocol.command, let writer else { return }
        if pairingInProgress || error != nil { record("Write response: \(String(describing: error))") }
        timeout?.cancel(); self.writer = nil
        if let error { self.error = error.localizedDescription; writer.resume(throwing: error) }
        else { writer.resume(); if !self.error.isEmpty { self.error = "" } }
    }
}
