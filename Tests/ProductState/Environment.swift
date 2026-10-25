// Offline environment for the production AgentEngine. No phone, model or BLE calls.
import Foundation
import CoreGraphics

struct UIImage {
    let cgImage: CGImage?
    init(shade: CGFloat = 1) {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: shade, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        cgImage = context.makeImage()
    }
}
struct ScreenFrame {
    let image: UIImage, jpeg = Data()
    let capturedAt: Date, fullDisplay = true
    private var systemConfirmedAt: Date?
    var confirmedAt: Date { systemConfirmedAt ?? capturedAt }
    /// Explicit fixture capture callback: preserve original pixels/time while
    /// advancing only a genuinely delivered synthetic system confirmation.
    func confirmed(at date:Date) -> ScreenFrame {
        var value=self;value.systemConfirmedAt=date;return value
    }
    let captureID: UUID?
    let width = 2, height = 2, sourceWidth = 2, sourceHeight = 2
    init(capturedAt: Date = Date(), captureID: UUID? = nil, shade: CGFloat = 1) {
        self.capturedAt = capturedAt; self.captureID = captureID; image = UIImage(shade: shade)
    }
}
@MainActor final class CaptureService {
    var running = true
    var frozenFrame: ScreenFrame?
    var refreshes = 0
    var onRefresh: (() -> Bool)?
    var frameProvider: (() -> ScreenFrame?)?
    var waitHandler: (@MainActor (Date,TimeInterval) async throws -> Bool)?
    var frame: ScreenFrame? {
        guard running else { return nil }
        if let frameProvider { return frameProvider() }
        return frozenFrame ?? ScreenFrame()
    }
    func requestFreshFrame() -> Bool { refreshes += 1; return onRefresh?() ?? false }
    func waitForFrame(after: Date, timeout: Double) async throws -> Bool {
        if let waitHandler {return try await waitHandler(after,timeout)}
        let until = Date().addingTimeInterval(timeout)
        repeat {
            try Task.checkCancellation()
            guard running else { return false }
            if let next = frame, next.confirmedAt > after,
               (0..<1.5).contains(Date().timeIntervalSince(next.confirmedAt)) { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < until
        return false
    }

}
@MainActor final class OfflineBLE {
    var ready = true, keyboardReady = true
    var selectedID: String? = "offline-device"
    var releases = 0
    var releaseDelay: UInt64 = 20_000_000
    func release() async { releases += 1; try? await Task.sleep(nanoseconds: releaseDelay) }
}
@MainActor final class MouseExecutor {
    let ble = OfflineBLE()
    var actions: [AgentAction.Kind] = []
    var dispatched: [AgentAction] = []
    var actionDelay: UInt64 = 0
    var pointerMoves: [(x: Int, y: Int, buttons: UInt8)] = []
    var movementDelay: UInt64 = 0
    var onMove: (() -> Void)?
    var calibrationValid = true
    var invalidations = 0
    func invalidatePosition() { invalidations += 1 }
    func validateCalibration(frame: ScreenFrame?) throws {
        if !ble.ready { throw AgentError.message("offline disconnect") }
        if !calibrationValid { throw AgentError.message("offline calibration invalid") }
    }
    func moveUnits(x: Int, y: Int, buttons: UInt8 = 0) async throws {
        try Task.checkCancellation()
        pointerMoves.append((x: x, y: y, buttons: buttons))
        if movementDelay > 0 { try await Task.sleep(nanoseconds: movementDelay) }
        try Task.checkCancellation()
        onMove?()
    }
    func execute(_ action: AgentAction, frame: ScreenFrame, mappedHomeAvailable: Bool = false) async throws {
        actions.append(action.kind); dispatched.append(action)
        if actionDelay > 0 { try await Task.sleep(nanoseconds: actionDelay) }
    }
}
enum SettingsStore { static func apiKey(for endpoint: String? = nil) -> String { "offline-placeholder" } }
enum ModelEndpointPolicy { static func url(_ endpoint: String) throws -> URL { URL(string: endpoint)! } }
@MainActor enum ModelProbe {
    static var calls = 0
    static var goals: [String] = []
    static var taskContexts: [String] = []
    static var attachmentRequests: [[ComposerAttachment]] = []
    static var skillReferences: [String] = []
    static var delay: UInt64 = 0
    static var action = AgentAction(kind: .finish, reason: "offline result")
    static var actionProvider: ((Int) -> AgentAction)?
    static var onRequest: (@MainActor () async throws -> Void)?
}
@MainActor struct VisionClient {
    let settings: AgentSettings, apiKey: String
    var metrics: RunMetricsRecorder? = nil
    func nextAction(task: String, jpeg: Data, width: Int, height: Int, history: [AgentLogEntry],
                    keyboardAvailable: Bool, mappedHomeAvailable: Bool,
                    tokenLimit: Int? = nil, formatRetry: Bool = false, memoryContext: String = "", harnessContext: String = "", taskContext: String = "", attachments: [ComposerAttachment] = [], skillReference: String = "") async throws -> AgentAction {
        let timer = metrics?.begin(.model, label: "offline model fake")
        defer { if let timer { metrics?.end(timer, outcome: Task.isCancelled ? .cancelled : .completed) } }
        ModelProbe.calls += 1
        ModelProbe.goals.append(task)
        ModelProbe.taskContexts.append(taskContext)
        ModelProbe.attachmentRequests.append(attachments)
        ModelProbe.skillReferences.append(skillReference)
        try await ModelProbe.onRequest?()
        if ModelProbe.delay > 0 { try await Task.sleep(nanoseconds: ModelProbe.delay) }
        return ModelProbe.actionProvider?(ModelProbe.calls) ?? ModelProbe.action
    }
}
