import Foundation
import CoreGraphics

@MainActor
final class MouseExecutor {
    let ble: BLETransport
    var calibrationInProgress = false
    var calibration: PointerCalibration? {
        didSet {
            if oldValue?.gainX != calibration?.gainX || oldValue?.gainY != calibration?.gainY ||
                oldValue?.originX != calibration?.originX || oldValue?.originY != calibration?.originY ||
                oldValue?.crossX != calibration?.crossX || oldValue?.crossY != calibration?.crossY ||
                oldValue?.screenWidth != calibration?.screenWidth || oldValue?.screenHeight != calibration?.screenHeight ||
                oldValue?.peripheralID != calibration?.peripheralID || oldValue?.movementVersion != calibration?.movementVersion {
                invalidatePosition()
            }
        }
    }
    private var pointerUnits: CGPoint?
    private var pointerConnection: UUID?
    func invalidatePosition() { pointerUnits = nil; pointerConnection = nil }
    init(ble: BLETransport) {
        self.ble = ble
        if let saved = SettingsStore.calibration(), saved.usable { calibration = saved }
    }
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(max(0, min(10, seconds)) * 1_000_000_000))
    }
    func moveUnits(x: Int, y: Int, buttons: UInt8 = 0) async throws {
        // Manual movement can begin from an unknown location.
        invalidatePosition()
        try await movePositionUnits(x: x, y: y, buttons: buttons)
    }
    func homePointer() async throws {
        // Physical pointer homing, not the phone's Home action.
        let motionToken = ble.beginPointerMotion()
        defer { ble.endPointerMotion(motionToken) }
        invalidatePosition()
        let connection = ble.pointerConnectionGeneration
        do {
            try await ble.moveBuffered(x: -127 * 18, y: -127 * 18, reports: 18, intervalMS: 30)
            try await sleep(0.15)
            guard ble.ready, ble.pointerConnectionGeneration == connection else { throw AgentError.message("鼠标连接已变化") }
            pointerUnits = .zero; pointerConnection = connection
        } catch {
            invalidatePosition()
            await Task { @MainActor in
                if ble.pointerConnectionGeneration == connection { await ble.release(expectedConnection: connection) }
            }.value
            throw error
        }
    }
    func movePositionUnits(x: Int, y: Int, buttons: UInt8 = 0, minimumDuration: Double? = nil) async throws {
        guard abs(x) < 10000, abs(y) < 10000 else { throw AgentError.message("移动距离异常，请重新校准") }
        let motionToken = ble.beginPointerMotion()
        defer { ble.endPointerMotion(motionToken) }
        let connection = ble.pointerConnectionGeneration
        if pointerConnection != connection { invalidatePosition() }
        let reports = PointerMotion.reportCount(x: x, y: y, minimumDuration: minimumDuration)
        guard reports > 0 else { return }
        do {
            try await ble.moveBuffered(x: x, y: y, buttons: buttons, reports: reports,
                intervalMS: Int((PointerMotion.reportInterval * 1000).rounded()))
            guard ble.pointerConnectionGeneration == connection else { throw AgentError.message("连接已变化，移动已停止") }
            if let previous = pointerUnits {
                pointerUnits = CGPoint(x: previous.x + CGFloat(x), y: previous.y + CGFloat(y))
            }
        } catch {
            invalidatePosition()
            await Task { @MainActor in
                if ble.pointerConnectionGeneration == connection { await ble.release(expectedConnection: connection) }
            }.value
            throw error
        }
    }
    func click(button: UInt8 = 1) async throws {
        let connection = ble.pointerConnectionGeneration
        do {
            let sequence = try await ble.send(.click, buttons: button)
            try await ble.waitIdle(after: sequence)
        }
        catch {
            invalidatePosition()
            await ble.release(expectedConnection: connection)
            throw error
        }
    }
    func validateCalibration(frame: ScreenFrame? = nil) throws -> PointerCalibration {
        guard !calibrationInProgress else { throw AgentError.message("校准尚未结束，请稍候") }
        guard let c = calibration, c.usable, c.peripheralID == ble.selectedID else {
            throw AgentError.message("请先对当前配件完成定位校准")
        }
        if let frame {
            let actual = Double(frame.sourceWidth) / Double(max(1, frame.sourceHeight))
            let expected = c.screenWidth / c.screenHeight
            guard abs(actual - expected) < 0.035 else { throw AgentError.message("屏幕旋转或捕获比例已改变，请恢复竖屏并重新校准") }
        }
        return c
    }
    /// Every new target starts from the homed corner to avoid accumulated drift.
    /// A drag homes at its start; its held-button segment remains continuous.
    @discardableResult
    func locate(x: Double, y: Double, frame: ScreenFrame? = nil) async throws -> CGPoint {
        let c = try validateCalibration(frame: frame)
        let units = c.fit.units(x: x * c.screenWidth, y: y * c.screenHeight)
        return try await moveToPositionUnits(x: units.x, y: units.y)
    }
    /// Shared by ordinary positioning and isolated calibration measurements.
    /// Calibration uses a local fit until independent validation has passed.
    @discardableResult
    func moveToPositionUnits(x: Int, y: Int) async throws -> CGPoint {
        guard abs(x) < 10000, abs(y) < 10000 else { throw AgentError.message("定位参数异常，请重新校准") }
        try await homePointer()
        let moveX = max(0, x), moveY = max(0, y)
        let current = pointerUnits ?? .zero
        try await movePositionUnits(x: moveX - Int(current.x), y: moveY - Int(current.y))
        return CGPoint(x: moveX, y: moveY)
    }
    func execute(_ action: AgentAction, frame: ScreenFrame, mappedHomeAvailable: Bool = false,
                 validateInput: (@MainActor () throws -> Void)? = nil) async throws {
        try action.validate()
        guard ble.ready else { throw AgentError.message("鼠标未就绪，已停止执行") }
        switch action.kind {
        case .tap:
            try await locate(x: action.x!, y: action.y!, frame: frame)
            try validateInput?()
            try await click()
        case .long_press:
            let connection = ble.pointerConnectionGeneration
            try await locate(x: action.x!, y: action.y!, frame: frame)
            do {
                try validateInput?()
                try await ble.send(.report, buttons: 1)
                for _ in 0..<max(1, Int((action.seconds ?? 0.8) / 0.3)) {
                    try await sleep(0.3); try await ble.send(.report, buttons: 1)
                }
                try await ble.send(.release)
            } catch {
                invalidatePosition(); await ble.release(expectedConnection: connection); throw error
            }
        case .drag:
            let connection = ble.pointerConnectionGeneration
            let c = try validateCalibration(frame: frame)
            try await locate(x: action.x!, y: action.y!, frame: frame)
            let units = c.fit.units(x: action.x2! * c.screenWidth, y: action.y2! * c.screenHeight)
            let destinationX = max(0, units.x), destinationY = max(0, units.y)
            guard destinationX < 10000, destinationY < 10000 else { throw AgentError.message("拖动终点异常，请重新校准") }
            let current = pointerUnits ?? .zero
            do {
                try validateInput?()
                try await ble.send(.report, buttons: 1)
                try await movePositionUnits(x: destinationX - Int(current.x), y: destinationY - Int(current.y),
                    buttons: 1, minimumDuration: action.seconds ?? 0.6)
                try await ble.send(.release)
            } catch {
                invalidatePosition(); await ble.release(expectedConnection: connection); throw error
            }
        case .scroll:
            guard ble.status?.bootMode != true else { throw AgentError.message("系统 Boot 模式不支持滚轮") }
            let connection = ble.pointerConnectionGeneration
            do {
                // Move without clicking: an opening button may sit outside the
                // newly presented scroll container. Legacy amount-only actions
                // retain their current-pointer behavior.
                if let x = action.x, let y = action.y {
                    try await locate(x: x, y: y, frame: frame)
                }
                guard ble.status?.bootMode != true else { throw AgentError.message("系统 Boot 模式不支持滚轮") }
                try validateInput?()
                let sequence = try await ble.send(.report, wheel: action.amount!, expectedConnection: connection)
                try await ble.waitIdle(after: sequence)
            } catch {
                invalidatePosition()
                await Task { @MainActor in
                    if ble.pointerConnectionGeneration == connection { await ble.release(expectedConnection: connection) }
                }.value
                throw error
            }
        case .type:
            guard ble.keyboardReady else { throw AgentError.message("蓝牙键盘未就绪，请查看设备连接状态或使用屏幕键盘") }
            let connection = ble.pointerConnectionGeneration
            let text = (action.text ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            // Validate the entire string before sending any keys.
            for character in text { _ = try HIDKeyboard.ascii(character) }
            // A text operation legitimately changes the pixels as it types.
            // Validate focus once before its first key, not between characters.
            try validateInput?()
            for character in text {
                guard ble.pointerConnectionGeneration == connection else { throw AgentError.message("键盘连接已变化，文字输入已停止") }
                let (mod, key) = try HIDKeyboard.ascii(character, capsLock: ble.status?.capsLock == true)
                try await press(modifier: mod, key: key)
            }
        case .press_key:
            if action.text?.lowercased() == "home" {
                guard mappedHomeAvailable else {
                    throw AgentError.message("中键主屏幕映射尚未确认，请通过可见辅助触控菜单返回桌面")
                }
                // Configure mouse middle button to "Home" in AssistiveTouch.
                try validateInput?()
                try await click(button: 4)
            } else {
                let (mod, key) = try HIDKeyboard.key(action.text ?? "")
                try validateInput?()
                try await press(modifier: mod, key: key)
            }
        case .wait: try await sleep(action.seconds ?? 1)
        case .complete_subtask: throw AgentError.message("子任务确认必须由任务引擎处理")
        case .phone_tool: throw AgentError.message("手机工具必须通过布局 harness 处理")
        case .system_tool: throw AgentError.message("系统工具必须通过工具执行器处理")
        case .finish, .ask_user: break
        }
    }
    private func press(modifier: UInt8, key: UInt8) async throws {
        guard ble.keyboardReady else { throw AgentError.message("蓝牙键盘未就绪") }
        let connection = ble.pointerConnectionGeneration
        do {
            try await ble.send(.keyboard, buttons: modifier, x: Int(key))
            try await sleep(0.045)
            try await ble.send(.keyboard, x: 0)
            try await sleep(0.045)
        } catch {
            // A fresh task can release even when its parent was cancelled.
            await Task { @MainActor in
                if ble.pointerConnectionGeneration == connection { await ble.release(expectedConnection: connection) }
            }.value
            throw error
        }
    }
}
