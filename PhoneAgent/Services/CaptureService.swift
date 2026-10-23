import Foundation
import UIKit
import Combine
import CoreImage
import CoreMedia
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

struct ScreenFrame {
    let image: UIImage
    let jpeg: Data
    let capturedAt: Date
    // Pixel capture time and stream confirmation time differ on an unchanged screen.
    let confirmedAt: Date
    let captureID: UUID?
    let sourceWidth: Int
    let sourceHeight: Int
    let fullDisplay: Bool
    var width: Int { image.cgImage?.width ?? 0 }
    var height: Int { image.cgImage?.height ?? 0 }

    init(image: UIImage, jpeg: Data, capturedAt: Date, sourceWidth: Int,
         sourceHeight: Int, fullDisplay: Bool, confirmedAt: Date? = nil, captureID: UUID? = nil) {
        self.image = image; self.jpeg = jpeg; self.capturedAt = capturedAt
        self.confirmedAt = confirmedAt ?? capturedAt; self.captureID = captureID
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight; self.fullDisplay = fullDisplay
    }
}

@MainActor
final class CaptureService: ObservableObject {
    @Published private(set) var frame: ScreenFrame?
    private(set) var lastBackgroundFrame: ScreenFrame?
    @Published private(set) var state = "尚未开始捕获"
    @Published private(set) var running = false
    @Published private(set) var fps = 0.0
    @Published private(set) var error = ""
    @Published private(set) var waitingForPicker = false
    var onStop: (() -> Void)?
    var maxSide = 1280
    private var session = UUID()
    private var lastUpdateSequence: UInt64 = 0
    #if canImport(ScreenCaptureKit)
    private var capture: NativeCapture?
    #endif
    func start() {
        guard !running && !waitingForPicker else { return }
        #if canImport(ScreenCaptureKit)
        error = ""; frame = nil; lastBackgroundFrame = nil; waitingForPicker = true; state = "请在系统选择器中共享整屏"
        let token = UUID(); session = token; lastUpdateSequence = 0
        let capture = NativeCapture(maxSide: maxSide, onUpdate: { [weak self] update, generation, sequence in
            Task { @MainActor in
                guard let self, self.session == token,
                      self.capture?.accepts(generation) == true, sequence > self.lastUpdateSequence else { return }
                self.lastUpdateSequence = sequence
                self.waitingForPicker = false
                switch update {
                case .frame(let frame, let fps):
                    self.frame = frame; self.fps = fps; self.running = true; self.error = ""
                    if UIApplication.shared.applicationState == .background { self.lastBackgroundFrame = frame }
                    self.state = frame.fullDisplay ? "整屏捕获中" : "仅当前应用，不能执行整屏 Agent"
                case .waiting(let status):
                    self.frame = nil; self.lastBackgroundFrame = nil; self.fps = 0
                    self.running = true; self.state = status
                case .state(let running, let status, let error):
                    self.running = running; self.state = status; self.error = error ?? ""
                    if !running { self.frame = nil; self.lastBackgroundFrame = nil; self.fps = 0; self.onStop?() }
                }
            }
        })
        self.capture = capture; capture.present()
        #else
        error = "模拟器不支持此屏幕框架，请使用 iOS 27 真机"
        #endif
    }
    /// Requests new pixels from the current authorized selection. A true result
    /// only means a stream rebuild was accepted, not that a fresh frame exists.
    @discardableResult
    func requestFreshFrame() -> Bool {
        #if canImport(ScreenCaptureKit)
        guard running, let capture, capture.requestRefresh() else { return false }
        frame = nil; lastBackgroundFrame = nil; fps = 0
        state = "正在获取新的整屏画面"
        return true
        #else
        return false
        #endif
    }
    func stop() {
        session = UUID()
        #if canImport(ScreenCaptureKit)
        capture?.stop(); capture = nil
        #endif
        running = false; waitingForPicker = false; frame = nil; lastBackgroundFrame = nil; state = "捕获已停止"; onStop?()
    }
}

#if canImport(ScreenCaptureKit)
private enum CaptureUpdate {
    case frame(ScreenFrame, fps: Double)
    case waiting(String)
    case state(running: Bool, status: String, error: String?)
}

private final class CaptureDiagnostics: @unchecked Sendable {
    static let shared = CaptureDiagnostics()
    private let queue = DispatchQueue(label: "PhoneAgent.capture.diagnostics")
    private var lines: [String] = []
    static func errorMetadata(_ error: Error) -> String {
        let value = error as NSError
        let domain = String(value.domain.prefix(100)).replacingOccurrences(of: "\n", with: "_")
        return "domain=\(domain) code=\(value.code)"
    }
    func record(_ message: String) {
        queue.async { [self] in
            lines.append(Date().ISO8601Format() + " " + String(message.prefix(240)))
            lines = Array(lines.suffix(180))
            let url = URL.documentsDirectory.appendingPathComponent("capture-diagnostics.log")
            do {
                try Data(lines.joined(separator: "\n").utf8).write(to: url,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var excluded = url
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try excluded.setResourceValues(values)
            } catch { /* Never log screen data or unbounded error descriptions. */ }
        }
    }
}

// Owned by the main actor; frame processing runs on a serial callback queue.
private final class NativeCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private let onUpdate: (CaptureUpdate, UUID, UInt64) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let maxSide: Int
    private var stream: SCStream?
    private var retiringStreams: [SCStream] = []
    // A refresh must not stop the last live authorized stream before the
    // replacement has delivered real pixels. This stream can be restored if
    // starting the replacement fails.
    private var refreshFallback: SCStream?
    private var selectedFilter: SCContentFilter?
    // Selection identity is stable during a refresh of the same authorized
    // filter. Internal generation changes on every stream replacement.
    private var selectionID = UUID()
    private var refreshAllowed = false
    // These values are confined to framesQueue, including resets between streams.
    private var framesGeneration: UUID?
    private var lastFrame: ScreenFrame?
    private struct PendingFrame {
        let buffer: CVPixelBuffer
        let capturedAt: Date
    }
    private var pendingFrame: PendingFrame?
    private var lastPublishedAt = Date.distantPast
    private var lastWaitingStatus: String?
    private var loggedFrameStatuses: Set<String> = []
    private var lastStatusLoggedAt = Date.distantPast
    private var times: [Date] = []
    private var fullDisplay = false
    private var stopped = false
    private var generation = UUID()
    private var updateSequence: UInt64 = 0
    private let framesQueue = DispatchQueue(label: "PhoneAgent.capture.frames")
    private let metadataLock = NSLock()
    init(maxSide: Int, onUpdate: @escaping (CaptureUpdate, UUID, UInt64) -> Void) {
        self.maxSide = max(640, min(2048, maxSide)); self.onUpdate = onUpdate
        super.init()
    }
    func accepts(_ token: UUID) -> Bool {
        metadataLock.lock(); defer { metadataLock.unlock() }
        return !stopped && generation == token
    }
    private func publish(_ update: CaptureUpdate, generation token: UUID) {
        metadataLock.lock()
        guard !stopped && generation == token else { metadataLock.unlock(); return }
        updateSequence += 1; let sequence = updateSequence
        metadataLock.unlock()
        onUpdate(update, token, sequence)
    }
    func present() {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else {
            publish(.state(running: false, status: "系统不允许屏幕捕获", error: "检查屏幕录制限制"), generation: generation)
            return
        }
        picker.add(self); picker.isActive = true; picker.present(using: .display)
    }
    func stop() {
        metadataLock.lock(); stopped = true; generation = UUID()
        let previous = stream; let retiring = retiringStreams; let fallback = refreshFallback
        stream = nil; retiringStreams = []; refreshFallback = nil; selectedFilter = nil; refreshAllowed = false
        metadataLock.unlock()
        let picker = SCContentSharingPicker.shared; picker.remove(self); picker.isActive = false
        CaptureDiagnostics.shared.record("capture_stop")
        previous?.stopCapture { _ in }
        for old in retiring { old.stopCapture { _ in } }
        if let fallback, fallback !== previous, !retiring.contains(where: { $0 === fallback }) { fallback.stopCapture { _ in } }
        framesQueue.async { [self] in resetFrames(for: nil) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        metadataLock.lock()
        guard !stopped else { metadataLock.unlock(); return }
        fullDisplay = filter.style == .display
        selectedFilter = filter; selectionID = UUID(); refreshAllowed = true
        generation = UUID(); let token = generation
        let captureID = selectionID
        let previous = self.stream; self.stream = nil
        var retiring = retiringStreams
        if let fallback = refreshFallback, !retiring.contains(where: { $0 === fallback }) { retiring.append(fallback) }
        retiringStreams = []; refreshFallback = nil
        metadataLock.unlock()
        // A new user selection invalidates all pixels and any pending refresh
        // of the prior selection, including its still-running fallback.
        for old in retiring { old.stopCapture { _ in } }
        CaptureDiagnostics.shared.record("selection_changed generation=\(token.uuidString) selection=\(captureID.uuidString)")
        prepareStream(filter: filter, generation: token, selection: captureID, previous: previous, refreshing: false)
    }
    @discardableResult
    func requestRefresh() -> Bool {
        metadataLock.lock()
        guard !stopped, refreshAllowed, refreshFallback == nil,
              let filter = selectedFilter, let previous = stream else {
            metadataLock.unlock()
            CaptureDiagnostics.shared.record("refresh_rejected no_active_authorized_stream")
            return false
        }
        generation = UUID(); let token = generation; let captureID = selectionID
        stream = nil; refreshFallback = previous; refreshAllowed = false
        metadataLock.unlock()
        CaptureDiagnostics.shared.record("refresh_requested generation=\(token.uuidString) selection=\(captureID.uuidString)")
        prepareStream(filter: filter, generation: token, selection: captureID, previous: previous, refreshing: true)
        return true
    }
    private func resetFrames(for token: UUID?) {
        // Called only on framesQueue. No pixel or confirmation survives a
        // generation boundary, including a refresh of the same selection.
        framesGeneration = token; lastFrame = nil; pendingFrame = nil
        lastPublishedAt = .distantPast; lastWaitingStatus = nil; times = []
        loggedFrameStatuses.removeAll(keepingCapacity: true); lastStatusLoggedAt = .distantPast
    }
    private func current(_ candidate: SCStream, generation token: UUID) -> Bool {
        metadataLock.lock(); defer { metadataLock.unlock() }
        return !stopped && generation == token && candidate === stream
    }
    private func prepareStream(filter: SCContentFilter, generation token: UUID, selection captureID: UUID,
                               previous: SCStream?, refreshing: Bool) {
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        let native = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(native.width * scale))
        config.height = max(1, Int(native.height * scale))
        let next = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: framesQueue)
            metadataLock.lock()
            guard !stopped && generation == token && selectionID == captureID else {
                metadataLock.unlock(); next.stopCapture { _ in }; previous?.stopCapture { _ in }; return
            }
            stream = next
            if let previous, !retiringStreams.contains(where: { $0 === previous }) { retiringStreams.append(previous) }
            metadataLock.unlock()
            framesQueue.async { [weak self] in
                guard let self, self.accepts(token) else { return }
                self.resetFrames(for: token)
            }
            publish(.waiting(refreshing ? "正在刷新捕获，等待完整画面" : "共享已更新，等待完整画面"), generation: token)
            if refreshing {
                // Keep the old stream capturing until render() has accepted a
                // real frame from this replacement. Stopping it first can end
                // the system's full-display sharing session on iOS.
                startPreparedStream(next, generation: token, refreshing: true)
            } else if let previous {
                previous.stopCapture { [weak self] error in
                    guard let self else { next.stopCapture { _ in }; return }
                    if error == nil {
                        self.metadataLock.lock()
                        self.retiringStreams.removeAll { $0 === previous }
                        self.metadataLock.unlock()
                    }
                    guard self.current(next, generation: token) else { next.stopCapture { _ in }; return }
                    if let error {
                        CaptureDiagnostics.shared.record("prior_stream_stop_failed " + CaptureDiagnostics.errorMetadata(error))
                        self.endStream(next, status: "捕获刷新失败", error: error.localizedDescription)
                    } else {
                        self.startPreparedStream(next, generation: token, refreshing: refreshing)
                    }
                }
            } else {
                startPreparedStream(next, generation: token, refreshing: refreshing)
            }
        } catch {
            CaptureDiagnostics.shared.record("stream_setup_failed generation=\(token.uuidString) " + CaptureDiagnostics.errorMetadata(error))
            if refreshing, restoreRefreshFallback(expectedGeneration: token) { return }
            previous?.stopCapture { _ in }
            terminateCapture(expectedGeneration: token, status: "捕获启动失败", error: error.localizedDescription)
        }
    }
    private func startPreparedStream(_ next: SCStream, generation token: UUID, refreshing: Bool) {
        // Linearize submission with stop/selection changes. The completion hops
        // to main so even a synchronous completion cannot reenter this lock.
        metadataLock.lock()
        guard !stopped && generation == token && next === stream else {
            metadataLock.unlock(); next.stopCapture { _ in }; return
        }
        CaptureDiagnostics.shared.record("stream_start generation=\(token.uuidString) refresh=\(refreshing)")
        next.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { next.stopCapture { _ in }; return }
                guard self.current(next, generation: token) else { next.stopCapture { _ in }; return }
                if let error {
                    CaptureDiagnostics.shared.record("stream_start_failed generation=\(token.uuidString) " + CaptureDiagnostics.errorMetadata(error))
                    self.endStream(next, status: "捕获启动失败", error: error.localizedDescription)
                } else {
                    CaptureDiagnostics.shared.record("stream_started generation=\(token.uuidString) refresh=\(refreshing)")
                    self.publish(.state(running: true, status: "捕获已开始", error: nil), generation: token)
                }
            }
        }
        metadataLock.unlock()
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        metadataLock.lock(); let empty = self.stream == nil; let token = generation; metadataLock.unlock()
        if empty { terminateCapture(expectedGeneration: token, status: "已取消屏幕共享", error: nil) }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        CaptureDiagnostics.shared.record("picker_failed " + CaptureDiagnostics.errorMetadata(error))
        metadataLock.lock(); let token = generation; metadataLock.unlock()
        terminateCapture(expectedGeneration: token, status: "共享选择器失败", error: error.localizedDescription)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        CaptureDiagnostics.shared.record("stream_delegate_stopped " + CaptureDiagnostics.errorMetadata(error))
        endStream(stream, error: error.localizedDescription)
    }
    private func endStream(_ stream: SCStream, status: String = "系统已停止屏幕共享", error: String?) {
        metadataLock.lock()
        guard stream === self.stream && !stopped else { metadataLock.unlock(); return }
        let token = generation
        metadataLock.unlock()
        if restoreRefreshFallback(expectedGeneration: token) { return }
        terminateCapture(expectedGeneration: token, status: status, error: error)
    }
    @discardableResult
    private func restoreRefreshFallback(expectedGeneration expected: UUID) -> Bool {
        metadataLock.lock()
        guard !stopped, generation == expected, let previous = refreshFallback else {
            metadataLock.unlock(); return false
        }
        let failed = stream
        stream = previous; refreshFallback = nil
        retiringStreams.removeAll { $0 === previous }
        generation = UUID(); let token = generation
        refreshAllowed = false
        metadataLock.unlock()
        CaptureDiagnostics.shared.record("refresh_failed_retaining_original generation=\(token.uuidString)")
        failed?.stopCapture { _ in }
        framesQueue.async { [weak self] in
            guard let self, self.accepts(token) else { return }
            if self.framesGeneration != token { self.resetFrames(for: token) }
        }
        // No cached pixels or timestamp cross the failed refresh. Only a new
        // callback from the original stream can make a frame available again.
        publish(.waiting("刷新未成功，保留原共享并等待新画面"), generation: token)
        return true
    }
    private func finishRefreshAfterFrame(generation token: UUID) {
        metadataLock.lock()
        guard !stopped, generation == token, let previous = refreshFallback else {
            metadataLock.unlock(); return
        }
        refreshFallback = nil
        metadataLock.unlock()
        CaptureDiagnostics.shared.record("refresh_first_frame generation=\(token.uuidString)")
        previous.stopCapture { [weak self] error in
            if let error {
                CaptureDiagnostics.shared.record("refreshed_stream_retire_failed " + CaptureDiagnostics.errorMetadata(error))
            } else if let self {
                self.metadataLock.lock()
                self.retiringStreams.removeAll { $0 === previous }
                self.metadataLock.unlock()
            }
        }
    }
    private func terminateCapture(expectedGeneration expected: UUID, status: String, error: String?) {
        metadataLock.lock()
        guard !stopped && generation == expected else { metadataLock.unlock(); return }
        let previous = stream
        var retiring = retiringStreams
        if let fallback = refreshFallback, !retiring.contains(where: { $0 === fallback }) { retiring.append(fallback) }
        retiringStreams = []
        self.stream = nil; generation = UUID(); let token = generation
        selectedFilter = nil; selectionID = UUID(); refreshAllowed = false; refreshFallback = nil
        metadataLock.unlock()
        let failure = error == nil ? "none" : "present"
        CaptureDiagnostics.shared.record("stream_ended generation=\(token.uuidString) error=\(failure)")
        previous?.stopCapture { _ in }
        for old in retiring { old.stopCapture { _ in } }
        framesQueue.async { [weak self] in
            guard let self, self.accepts(token) else { return }
            self.resetFrames(for: nil)
        }
        publish(.state(running: false, status: status, error: error), generation: token)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        metadataLock.lock(); let valid = stream === self.stream && !stopped
        let isFullDisplay = fullDisplay; let token = generation; let captureID = selectionID; metadataLock.unlock()
        guard valid, type == .screen else { return }
        if framesGeneration != token { resetFrames(for: token) }
        guard CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            let now = Date()
            if loggedFrameStatuses.insert("invalid").inserted || now.timeIntervalSince(lastStatusLoggedAt) >= 5 {
                lastStatusLoggedAt = now
                CaptureDiagnostics.shared.record("frame_status=invalid generation=\(token.uuidString)")
            }
            waitForFrame("等待可用的屏幕画面", generation: token)
            return
        }
        let now = Date()
        let statusName: String
        switch status {
        case .complete: statusName = "complete"
        case .idle: statusName = "idle"
        case .blank: statusName = "blank"
        case .suspended: statusName = "suspended"
        case .started: statusName = "started"
        case .stopped: statusName = "stopped"
        @unknown default: statusName = "unknown"
        }
        if loggedFrameStatuses.insert(statusName).inserted || now.timeIntervalSince(lastStatusLoggedAt) >= 5 {
            lastStatusLoggedAt = now
            CaptureDiagnostics.shared.record("frame_status=\(statusName) generation=\(token.uuidString) pixels=\(CMSampleBufferGetImageBuffer(sampleBuffer) != nil)")
        }
        switch status {
        case .idle:
            // The final changed frame may have arrived during the render throttle.
            // Render those pixels before accepting any idle confirmation.
            if let pending = pendingFrame {
                pendingFrame = nil
                render(pending.buffer, capturedAt: pending.capturedAt, confirmedAt: now,
                       fullDisplay: isFullDisplay, generation: token, captureID: captureID)
                return
            }
            // Only an actual idle callback confirms that these pixels remain current.
            // Never renew freshness from a timer or from blank/suspended buffers.
            guard let previous = lastFrame, now.timeIntervalSince(lastPublishedAt) >= 0.25 else { return }
            let frame = ScreenFrame(image: previous.image, jpeg: previous.jpeg, capturedAt: previous.capturedAt,
                sourceWidth: previous.sourceWidth, sourceHeight: previous.sourceHeight, fullDisplay: isFullDisplay,
                confirmedAt: now, captureID: captureID)
            lastFrame = frame; lastPublishedAt = now; lastWaitingStatus = nil
            publish(.frame(frame, fps: 0), generation: token)
            return
        case .complete, .started:
            // A started buffer can contain the stream's first real pixels.
            // The valid-sample and image-buffer checks still apply below.
            lastFrame = nil
        case .blank, .suspended:
            metadataLock.lock()
            if generation == token { refreshAllowed = false }
            metadataLock.unlock()
            waitForFrame(status == .blank ? "屏幕暂不可用，等待画面恢复" : "等待屏幕画面恢复", generation: token)
            return
        case .stopped:
            lastFrame = nil; pendingFrame = nil
            endStream(stream, error: nil)
            return
        @unknown default:
            waitForFrame("等待可用的屏幕画面", generation: token)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            waitForFrame("等待完整的屏幕画面", generation: token)
            return
        }
        metadataLock.lock()
        if generation == token && !stopped { refreshAllowed = true }
        metadataLock.unlock()
        times.append(now); times.removeAll { now.timeIntervalSince($0) > 2 }
        // minimumFrameInterval is unavailable on iOS. Keep the newest complete
        // buffer while throttling expensive image conversion locally to 4 FPS.
        guard now.timeIntervalSince(lastPublishedAt) >= 0.25 else {
            pendingFrame = PendingFrame(buffer: buffer, capturedAt: now)
            return
        }
        pendingFrame = nil
        render(buffer, capturedAt: now, confirmedAt: now, fullDisplay: isFullDisplay, generation: token, captureID: captureID)
    }
    private func waitForFrame(_ status: String, generation token: UUID) {
        lastFrame = nil; pendingFrame = nil
        guard lastWaitingStatus != status else { return }
        lastWaitingStatus = status
        publish(.waiting(status), generation: token)
    }
    private func render(_ buffer: CVPixelBuffer, capturedAt: Date, confirmedAt: Date,
                        fullDisplay: Bool, generation token: UUID, captureID: UUID) {
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            let s = min(1, CGFloat(maxSide) / max(source.extent.width, source.extent.height))
            let scaled = source.transformed(by: CGAffineTransform(scaleX: s, y: s))
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
                waitForFrame("等待完整的屏幕画面", generation: token)
                return
            }
            let image = UIImage(cgImage: cg)
            guard let jpeg = image.jpegData(compressionQuality: 0.72) else {
                waitForFrame("等待完整的屏幕画面", generation: token)
                return
            }
            let duration = confirmedAt.timeIntervalSince(times.first ?? confirmedAt)
            let fps = duration > 0 ? Double(max(0, times.count - 1)) / duration : 0
            let frame = ScreenFrame(image: image, jpeg: jpeg, capturedAt: capturedAt,
                sourceWidth: CVPixelBufferGetWidth(buffer), sourceHeight: CVPixelBufferGetHeight(buffer),
                fullDisplay: fullDisplay, confirmedAt: confirmedAt, captureID: captureID)
            lastFrame = frame; lastPublishedAt = confirmedAt; lastWaitingStatus = nil
            publish(.frame(frame, fps: fps), generation: token)
            finishRefreshAfterFrame(generation: token)
        }
    }
}
#endif
