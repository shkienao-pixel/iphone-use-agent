import Foundation

enum AutomaticPreparationStep: Hashable { case model, consent, systemTools, assistiveTouch, device, calibration, screen, ready }
struct ProbePreparationSnapshot { let nextStep: AutomaticPreparationStep }
enum ProbeAssistiveTouch { case enabled, disabled, unknown }
@MainActor final class UIApplication {
    enum State { case active }
    static let shared = UIApplication(), openSettingsURLString = "https://offline.invalid/settings"
    var applicationState = State.active
    @discardableResult func open(_ url: URL) async -> Bool { false }
}
@MainActor enum AccessibilitySettings {
    enum Destination { case assistiveTouch, assistiveTouchDevices }
    static var gateNext = false
    static var pending: CheckedContinuation<Void, Never>?
    static func openSettings(for destination: Destination) async throws {
        if gateNext { gateNext = false; await withCheckedContinuation { pending = $0 } }
    }
    static func resume() { let p = pending; pending = nil; p?.resume() }
}
@MainActor final class ScopeHistory {
    var records: [PhoneTaskRecord] = []
    var error = ""
    @discardableResult func upsert(_ record: PhoneTaskRecord) -> Bool {
        guard error.isEmpty else { return false }
        records.removeAll { $0.id == record.id }; records.append(record); return true
    }
}
@MainActor final class ScopeEngine {
    var currentRecord: PhoneTaskRecord?
    var hasCurrentTask = false, running = false, releasing = false, acceptsStart = true, publishesRecords = true
    var onRecord: ((PhoneTaskRecord) -> Void)?
    var persistRecord: ((PhoneTaskRecord) -> Bool)?
    var starts: [UUID] = []
    func start(task: String, settings: AgentSettings, subtasks: [String] = [], attachments: [ComposerAttachment] = [], taskID: UUID = UUID(), conversationReference: String = "") {
        guard acceptsStart else { return }
        starts.append(taskID)
        let record = PhoneTaskRecord(id: taskID, title: "offline", goal: task, summary: "started", outcome: .interrupted, conversationReference: conversationReference)
        currentRecord = record; hasCurrentTask = true; running = true
        if publishesRecords {
            guard persistRecord?(record) != false else { running = false; return }
            onRecord?(record)
        }
    }
    func stop() { running = false; hasCurrentTask = false }
    func pause() { running = false }
    func handoff() { running = false }
}
@MainActor final class ScopeCapture {
    var running = false, waitingForPicker = false, error = ""
    var frame: ScreenFrame?
    func start() { waitingForPicker = true }
    func stop() { running = false; waitingForPicker = false }
}
@MainActor final class ScopeStopper {
    func stop() {}
    func cancel() {}
    func invalidate() {}
    func invalidatePreparations() {}
    func send() {}
}
@MainActor final class ScopeBLE {
    var bluetoothNeedsPermission = false, bluetoothPoweredOff = false, bluetoothPoweredOn = true
    var connected = false, scanning = false, hasSavedAccessory = false, bufferedMotionReady = true
    var devices: [String] = [], error = "", state = "offline"
    func scan() { scanning = true }
}
@MainActor final class ScopeExecutor { var calibrationInProgress = false }
@MainActor final class ScopeQueue { var pendingCount = 0 }
@MainActor final class ScopeBackground {
    var records: [PhoneTaskRecord] = []
    func token(_ id: UUID) -> UUID? { nil }
}
@MainActor final class PhoneAgentViewModel {
    let backgroundTasks = ScopeBackground()
    let taskQueue = ScopeQueue()
    var screenQueueWaiting: [UUID] = []
    let history = ScopeHistory(), engine = ScopeEngine(), capture = ScopeCapture()
    let ble = ScopeBLE(), executor = ScopeExecutor(), objectWillChange = ScopeStopper()
    let speech = ScopeStopper(), liveCamera = ScopeStopper(), camera = ScopeStopper()
    let assistiveTouchVerification = ScopeStopper(), contentStore = ScopeStopper()
    let conversation: AssistantConversation
    var settings = AgentSettings(), goal = "", notice = ""
    var modelReady = true, preparationReady = true, configurationReady = false
    var consentReady: Bool { PrivacyConsent.allowed(settings) }
    var preparingAutomatically = false, preparingSavedConfiguration = false
    var queueSwitching = false, queueRunning = false, manualBusy = false, calibrating = false, voicePending = false
    var interactionBusy: Bool { preparingAutomatically || engine.running || engine.releasing || manualBusy || calibrating || queueSwitching || voicePending || recordingAudioOwner != nil }
    var recordingAudioOwner: UUID?, configurationCompletionID: UUID?
    var showPreparation = false, showPrivacyConsent = false, showConfigurationSettings = false
    var automaticCalibrationRequested = false, configurationSettingsOpen = false, awaitingAutomaticCalibration = false, automaticPreparationOwnsCapture = false
    var automaticPreparationStatus = "", taskPlan: [String] = []
    var automaticPreparationGeneration = UUID(), conversationInteractionID = UUID(), voiceGeneration = UUID()
    var automaticPreparation: Task<Void, Never>?, voicePreparation: Task<Void, Never>?, manual: Task<Void, Never>?
    var pendingConsentAttachments: [ComposerAttachment] = []
    var manualContinuationRequired = false, voiceMode: String?
    var cancelCalibration: (() -> Void)?
    var step = AutomaticPreparationStep.screen, assistiveTouchObservedState = ProbeAssistiveTouch.enabled
    var automaticPreparationSnapshot: ProbePreparationSnapshot { .init(nextStep: step) }
    init(url: URL) { conversation = AssistantConversation(store: AssistantConversationStore(url: url)) }
    func haltQueue(_ message: String) { queueRunning = false }
    func recordQueueProgress(_ record: PhoneTaskRecord) {}
    // EXACT_CONTROLLER_MEMBERS
}
