import Foundation

enum HIDKeyboard {
    static func ascii(_ c: Character, capsLock: Bool = false) throws -> (UInt8, UInt8) {
        guard let value = c.asciiValue else { throw AgentError.message("硬件键盘只支持 ASCII，请用屏幕键盘输入中文") }
        switch value {
        case 97...122: return (capsLock ? 2 : 0, value - 97 + 4)
        case 65...90: return (capsLock ? 0 : 2, value - 65 + 4)
        case 49...57: return (0, value - 49 + 30)
        case 48: return (0, 39)
        case 10,13: return (0,40)
        case 9: return (0,43)
        case 32: return (0,44)
        default:
            let plain = "-=[]\\;'`,./"
            let shifted = "_+{}|:\"~<>?"
            let usage: [UInt8] = [45,46,47,48,49,51,52,53,54,55,56]
            if let i = Array(plain).firstIndex(of: c) { return (0, usage[i]) }
            if let i = Array(shifted).firstIndex(of: c) { return (2, usage[i]) }
            let digits = "!@#$%^&*()"
            if let i = Array(digits).firstIndex(of: c) { return (2, i == 9 ? 39 : UInt8(30 + i)) }
            throw AgentError.message("暂不支持字符 \(c)")
        }
    }
    static func key(_ name: String) throws -> (UInt8, UInt8) {
        switch name.lowercased() {
        case "enter": return (0,40)
        case "escape": return (0,41)
        case "backspace": return (0,42)
        case "tab": return (0,43)
        case "space": return (0,44)
        case "delete": return (0,76)
        case "right": return (0,79)
        case "left": return (0,80)
        case "down": return (0,81)
        case "up": return (0,82)
        case "page_up": return (0,75)
        case "page_down": return (0,78)
        case "line_start": return (8,80) // Command-Left; "home" remains the phone Home action.
        case "line_end": return (8,79)
        case "select_all": return (8,4) // Left GUI + A (Command-A).
        case "copy": return (8,6)
        case "paste": return (8,25)
        case "cut": return (8,27)
        case "undo": return (8,29)
        case "redo": return (10,29) // Command-Shift-Z.
        case "switch_input": return (1,44) // Control-Space; observe the active input source.
        default: throw AgentError.message("未知按键 \(name)")
        }
    }
}
