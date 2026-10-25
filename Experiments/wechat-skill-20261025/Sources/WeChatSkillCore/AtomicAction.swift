import Foundation

public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var valid: Bool {
        [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 &&
        width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }
}
public enum ControlRole: String, Codable, Sendable {
    case navigation, contactRow, profileMessages, profileMoments, momentCard, actionMenu
    case textField, paste, scrollRegion, like, unlike, comment, sendMessage, sendComment
    var isEffect: Bool { [.like, .unlike, .sendMessage, .sendComment].contains(self) }
}
public enum ControlSource: String, Codable, Sendable { case ocr, localPixels, fixture, modelGuess }
public struct ObservedControl: Codable, Equatable, Sendable {
    public var id: String
    public var frameID: UUID
    public var role: ControlRole
    public var rect: UnitRect
    public var source: ControlSource
    public init(id: String, frameID: UUID, role: ControlRole, rect: UnitRect, source: ControlSource) {
        self.id = id; self.frameID = frameID; self.role = role; self.rect = rect; self.source = source
    }
}
public enum EditingKey: String, Codable, Sendable { case paste, selectAll, deleteBackward, switchInput }

/// Exactly one primitive, never a macro or an array. This module does not execute it.
/// Enter/Return is intentionally absent: submitting has its own guarded tap.
public enum AtomicAction: Codable, Equatable, Sendable {
    case tap(ObservedControl)
    case longPress(ObservedControl)
    case scroll(ObservedControl, ticks: Int)
    case inputASCII(ObservedControl, text: String)
    case editingKey(ObservedControl, key: EditingKey)
    case prepareClipboard(text: String)
}

public enum FieldAccess: Sendable { case unknown, empty, taskOwned, foreignDraft }
public struct ClipboardLease: Sendable {
    public var text: String
    public var preparedAt: Date
    public var expiresAt: Date
    public var invalidated: Bool
    public init(text: String, preparedAt: Date, expiresAt: Date, invalidated: Bool = false) {
        self.text = text; self.preparedAt = preparedAt; self.expiresAt = expiresAt; self.invalidated = invalidated
    }
    func usable(at now: Date) -> Bool {
        !invalidated && nonblank(text) && [preparedAt, expiresAt, now].allSatisfy { $0.timeIntervalSince1970.isFinite } &&
        preparedAt <= now && now < expiresAt
    }
}
public struct InputCapabilities: Sendable {
    public var keyboard: Bool
    public var hostForeground: Bool
    public var clipboardPreparation: Bool
    public var fieldAccess: FieldAccess
    public var focused: Bool
    public var clipboard: ClipboardLease?
    public init(keyboard: Bool = false, hostForeground: Bool = false, clipboardPreparation: Bool = false,
                fieldAccess: FieldAccess = .unknown, focused: Bool = false, clipboard: ClipboardLease? = nil) {
        self.keyboard = keyboard; self.hostForeground = hostForeground; self.clipboardPreparation = clipboardPreparation
        self.fieldAccess = fieldAccess; self.focused = focused; self.clipboard = clipboard
    }
    var mayWrite: Bool { focused && (fieldAccess == .empty || fieldAccess == .taskOwned) }
}

public enum AtomicActionRules {
    static func validateControl(_ control: ObservedControl, frame: FrameStamp, controls: [ObservedControl], mode: EvaluationMode) throws {
        guard control.rect.valid, nonblank(control.id), control.frameID == frame.id,
              controls.filter({ $0.id == control.id }).count == 1,
              controls.contains(control), control.source != .modelGuess,
              (mode == .offline ? control.source == .fixture : control.source != .fixture)
        else { throw SkillError.invalidAction }
    }

    public static func validateOrdinary(_ action: AtomicAction, frame: FrameStamp, controls: [ObservedControl],
                                       capabilities: InputCapabilities, mode: EvaluationMode,
                                       now: Date, maxAge: TimeInterval) throws {
        try frame.validate(mode: mode, now: now, maxAge: maxAge)
        switch action {
        case .prepareClipboard(let text):
            guard nonblank(text), capabilities.hostForeground, capabilities.clipboardPreparation else { throw SkillError.unavailableInput }
        case .tap(let control):
            try validateControl(control, frame: frame, controls: controls, mode: mode)
            guard !control.role.isEffect else { throw SkillError.unapprovedEffect }
            if control.role == .paste {
                guard capabilities.mayWrite, capabilities.clipboard?.usable(at: now) == true else { throw SkillError.unavailableInput }
            }
        case .longPress(let control):
            try validateControl(control, frame: frame, controls: controls, mode: mode)
            guard control.role == .textField else { throw SkillError.invalidAction }
        case .scroll(let control, let ticks):
            try validateControl(control, frame: frame, controls: controls, mode: mode)
            guard control.role == .scrollRegion, (-4...4).contains(ticks), ticks != 0 else { throw SkillError.invalidAction }
        case .inputASCII(let control, let text):
            try validateControl(control, frame: frame, controls: controls, mode: mode)
            guard control.role == .textField, capabilities.keyboard, capabilities.mayWrite, !text.isEmpty,
                  text.utf8.count <= 500, text.utf8.allSatisfy({ (32...126).contains($0) })
            else { throw SkillError.unavailableInput }
        case .editingKey(let control, let key):
            try validateControl(control, frame: frame, controls: controls, mode: mode)
            guard control.role == .textField, capabilities.keyboard, capabilities.focused else { throw SkillError.unavailableInput }
            if key != .switchInput {
                guard capabilities.mayWrite else { throw SkillError.unavailableInput }
            }
            if key == .paste {
                guard capabilities.clipboard?.usable(at: now) == true else { throw SkillError.unavailableInput }
            }
        }
    }
}
