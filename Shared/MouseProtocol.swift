import Foundation
import CoreBluetooth

enum MouseProtocol {
    static let service = CBUUID(string: "A1000001-7A3B-4F45-9F11-123456789ABC")
    static let command = CBUUID(string: "A1000002-7A3B-4F45-9F11-123456789ABC")
    static let status = CBUUID(string: "A1000003-7A3B-4F45-9F11-123456789ABC")
    static let taskIndicator = CBUUID(string: "A1000004-7A3B-4F45-9F11-123456789ABC")
    enum TaskIndicator: UInt8 { case idle = 0, running = 1, failed = 2, completed = 3 }
    static let hid = CBUUID(string: "1812")

    enum Operation: UInt8 { case report = 1, click = 2, release = 3, keyboard = 4 }
    static func packet(_ op: Operation, sequence: UInt16, buttons: UInt8 = 0,
                       x: Int = 0, y: Int = 0, wheel: Int = 0, delay: UInt16 = 0) -> Data {
        func signed(_ v: Int) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, v)))) }
        return Data([1, op.rawValue, UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8),
                     buttons & 7, signed(x), signed(y), signed(wheel),
                     UInt8(truncatingIfNeeded: delay), UInt8(delay >> 8)])
    }
    static func movementPacket(sequence: UInt16, buttons: UInt8, x: Int, y: Int,
                               reports: Int, intervalMS: Int) -> Data {
        let dx = UInt16(bitPattern: Int16(x)), dy = UInt16(bitPattern: Int16(y))
        func low(_ value: UInt16) -> UInt8 { UInt8(truncatingIfNeeded: value) }
        func high(_ value: UInt16) -> UInt8 { UInt8(value >> 8) }
        return Data([2, 5, low(sequence), high(sequence), buttons,
                     low(dx), high(dx), low(dy), high(dy),
                     low(UInt16(reports)), high(UInt16(reports)),
                     low(UInt16(intervalMS)), high(UInt16(intervalMS)), 0])
    }
    struct Status {
        let flags: UInt8
        let buttons: UInt8
        let error: UInt8
        let sequence: UInt16
        let keyboardAvailable: Bool
        let keyboardSupported: Bool
        let capsLock: Bool
        let bufferedMotionAvailable: Bool
        init?(_ data: Data) {
            let p = Array(data)
            guard p.count == 8, p[0] == 1 else { return nil }
            flags = p[1]; buttons = p[2]; error = p[3]
            sequence = UInt16(p[4]) | UInt16(p[5]) << 8
            keyboardAvailable = p[6] & 2 != 0 && p[7] & 1 != 0
            keyboardSupported = p[6] & 1 != 0 && p[7] & 1 != 0
            capsLock = p[7] & 2 != 0
            bufferedMotionAvailable = p[6] & 4 != 0 && p[7] & 1 != 0
        }
        var encrypted: Bool { flags & 2 != 0 }
        var hidSubscribed: Bool { flags & 4 != 0 }
        var busy: Bool { flags & 8 != 0 }
        var suspended: Bool { flags & 16 != 0 }
        var bootMode: Bool { flags & 32 != 0 }
        var ready: Bool { flags & 7 == 7 && !suspended }
    }
}
