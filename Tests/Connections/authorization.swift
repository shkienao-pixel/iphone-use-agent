import Foundation
import CoreImage

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
final class BackendFixture: OfficeAuthorizationBackend {
    var authorizationContext = "https://fixture.invalid"
    let id = UUID().uuidString
    var service: ExternalAppService = .feishu
    var state = "authorizing"
    var connected = false
    var verifications = 0
    var cancellations = 0
    var polls = 0
    func snapshot() -> OfficeAuthorizationJob {
        .init(id: id, service: service.rawValue, state: state, message: "fixture", authorizationURL: "https://accounts.feishu.cn/auth?ticket=fixture", qrCode: nil, verificationCode: nil)
    }
    func start(_ service: ExternalAppService, install: Bool) async throws -> OfficeAuthorizationJob { snapshot() }
    func poll(_ id: String) async throws -> OfficeAuthorizationJob { polls += 1; return snapshot() }
    func verifiedStatus(_ service: ExternalAppService) async throws -> OfficeConnectionStatus {
        verifications += 1
        return .init(service: service.rawValue, installed: true, connected: connected, state: connected ? "connected" : "login", message: "fixture", jobID: nil)
    }
    func cancel(_ id: String) async { cancellations += 1 }
}

@MainActor
final class PresenterFixture: OfficeAuthorizationPresenting {
    var openings = 0
    var dismissals = 0
    var route: OfficeAuthorizationLaunch = .web
    var callback: URL?
    var event: (@MainActor (OfficeAuthorizationPresentationEvent) -> Void)?
    func authorizationURL(for job: OfficeAuthorizationJob) async -> URL? { job.authorizationURL.flatMap(URL.init(string:)) }
    func open(_ url: URL, callback: URL, event: @escaping @MainActor (OfficeAuthorizationPresentationEvent) -> Void) async throws -> OfficeAuthorizationLaunch {
        openings += 1; self.callback = callback; self.event = event; return route
    }
    func dismiss() { dismissals += 1 }
}

@main @MainActor
struct AuthorizationChecks {
    static var checks = 0
    static var suites: [String] = []
    static func expect(_ passed: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(passed(), message)
    }
    static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { expect(true, message); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure(message)
    }
    static func defaults() -> UserDefaults {
        let name = "sela-auth-test-" + UUID().uuidString; suites.append(name)
        return UserDefaults(suiteName: name)!
    }
    static func flow(_ backend: BackendFixture, _ presenter: PresenterFixture, _ store: UserDefaults? = nil) -> OfficeAuthorizationFlow {
        OfficeAuthorizationFlow(backend: backend, presenter: presenter, defaults: store ?? defaults(), interval: .milliseconds(10))
    }
    static func main() async throws {
        defer { for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) } }
        expect(OfficeAuthorizationPolicy.authorizationURL("https://accounts.feishu.cn/auth", service: .feishu) != nil, "Official link rejected")
        for bad in ["http://accounts.feishu.cn/auth", "https://feishu.cn.attacker.invalid/auth", "https://accounts.feishu.cn@attacker.invalid/auth", "https://accounts.feishu.cn/auth#token", "https://accounts.feishu.cn:8443/auth", "lark://home"] {
            expect(OfficeAuthorizationPolicy.authorizationURL(bad, service: .feishu) == nil, "Unsafe link accepted")
        }
        expect(OfficeAuthorizationPolicy.authorizationURL("https://accounts.feishu.cn/auth", service: .dingtalk) == nil, "Cross-provider link accepted")
        let qrURL = "https://work.weixin.qq.com/auth?ticket=fixture-only"
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(qrURL.utf8), forKey: "inputMessage")
        let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let png = CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())!
        let decoded = await OfficeAuthorizationQRCode.payload(png.base64EncodedString())
        expect(decoded == qrURL && OfficeAuthorizationPolicy.authorizationURL(decoded, service: .wecom) != nil, "Official QR could not open the same authorization URL")
        let invalidQR = await OfficeAuthorizationQRCode.payload("invalid-base64")
        expect(invalidQR == nil, "Invalid QR decoded")
        var calls: [String] = []
        var route = try await OfficeAuthorizationPolicy.route(openApp: { calls.append("app"); return true }, openWeb: { calls.append("web") })
        expect(route == .app && calls == ["app"], "App-first route was not exclusive")
        calls = []
        route = try await OfficeAuthorizationPolicy.route(openApp: { calls.append("app"); return false }, openWeb: { calls.append("web") })
        expect(route == .web && calls == ["app", "web"], "Web fallback ordering failed")
        let cancelled = Task {
            try await OfficeAuthorizationPolicy.route(openApp: { calls.append("cancelled-app"); return true }, openWeb: { calls.append("cancelled-web") })
        }
        cancelled.cancel()
        _ = try? await cancelled.value
        expect(!calls.contains("cancelled-app") && !calls.contains("cancelled-web"), "Cancelled flow opened an authorization UI")

        let backend = BackendFixture(), presenter = PresenterFixture(), store = defaults()
        let auth = flow(backend, presenter, store)
        auth.start(.feishu)
        try await eventually("Authorization did not open", { presenter.openings == 1 })
        let pending = auth.pending!, callback = presenter.callback!
        auth.clearResult()
        expect(auth.pending == pending && auth.running, "Clearing old result interrupted an active authorization")
        expect(OfficeAuthorizationPolicy.accepts(callback, pending: pending), "Valid callback rejected")
        expect(!OfficeAuthorizationPolicy.accepts(URL(string: callback.absoluteString + "&state=duplicate")!, pending: pending), "Duplicate state accepted")
        expect(!OfficeAuthorizationPolicy.accepts(URL(string: callback.absoluteString.replacingOccurrences(of: pending.state, with: "wrong"))!, pending: pending), "Wrong state accepted")
        expect(!OfficeAuthorizationPolicy.accepts(callback, pending: pending, now: pending.startedAt.addingTimeInterval(301)), "Expired callback accepted")
        auth.handle(URL(string: callback.absoluteString + "&success=true")!)
        expect(auth.phase != .connected && backend.verifications == 0, "Callback success flag was trusted")
        auth.handle(callback)
        try await Task.sleep(for: .milliseconds(30))
        expect(auth.phase != .connected && backend.verifications == 0, "Callback bypassed pending backend grant")
        presenter.event?(.closed)
        expect(auth.pending != nil && auth.running, "Closing browser discarded pending authorization")
        try await Task.sleep(for: .milliseconds(30))
        expect(presenter.openings == 1, "Polling repeatedly opened the browser")
        auth.continueAuthorization()
        try await eventually("Continue did not reopen", { presenter.openings == 2 })
        let priorDismissals = presenter.dismissals
        backend.state = "complete"; backend.connected = true
        try await eventually("Verified grant did not complete", { auth.phase == .connected })
        expect(auth.pending == nil && store.data(forKey: "connections.pendingAuthorization.v1") == nil, "Completed flow persisted callback state")
        expect(backend.verifications == 1 && presenter.dismissals > priorDismissals, "Successful grant was not verified or browser stayed open")
        auth.clearResult()
        expect(auth.phase == .idle && auth.service == nil && auth.message.isEmpty, "Disconnect or changed configuration retained a connected banner")

        let b2 = BackendFixture(), p2 = PresenterFixture(), auth2 = flow(b2, p2)
        auth2.start(.feishu)
        try await eventually("Background fixture did not start", { p2.openings == 1 })
        auth2.sceneActive(false); b2.state = "complete"; b2.connected = true
        try await Task.sleep(for: .milliseconds(40))
        expect(auth2.phase != .connected, "Background state was advanced without returning")
        auth2.sceneActive(true)
        try await eventually("Foreground return did not verify", { auth2.phase == .connected })

        let b3 = BackendFixture(), p3 = PresenterFixture(), auth3 = flow(b3, p3)
        auth3.start(.feishu)
        try await eventually("Unverified fixture did not start", { auth3.pending != nil })
        b3.state = "complete"; b3.connected = false
        try await eventually("Process success faked connected", { auth3.phase == .failed })

        let b4 = BackendFixture(), p4 = PresenterFixture(), auth4 = flow(b4, p4)
        auth4.start(.feishu)
        try await eventually("Cancel fixture did not start", { p4.openings == 1 })
        let old = p4.callback!; auth4.cancel(); auth4.handle(old)
        try await eventually("Cancel was not forwarded", { b4.cancellations == 1 })
        expect(auth4.phase == .cancelled && auth4.pending == nil, "Late callback revived a cancelled grant")

        let b5 = BackendFixture(), p5 = PresenterFixture(), saved = defaults(), first = flow(b5, p5, saved)
        first.start(.feishu)
        try await eventually("Recovery fixture did not start", { p5.openings == 1 })
        first.sceneActive(false)
        let restoredPresenter = PresenterFixture(), restored = flow(b5, restoredPresenter, saved)
        restored.restore()
        expect(restored.pending?.jobID == first.pending?.jobID, "App relaunch lost pending grant")
        try await Task.sleep(for: .milliseconds(30))
        expect(restoredPresenter.openings == 0, "Restoring state unexpectedly reopened external app")
        b5.state = "complete"; b5.connected = true
        restored.sceneActive(true)
        try await eventually("Restored flow failed to verify", { restored.phase == .connected })
        first.cancel()

        let b6 = BackendFixture(), p6 = PresenterFixture(), mismatch = flow(b6, p6)
        b6.service = .dingtalk; mismatch.start(.feishu)
        try await eventually("Wrong-provider task was not rejected", { mismatch.phase == .failed })
        expect(p6.openings == 0, "Wrong-provider task opened an authorization UI")

        let expiredDefaults = defaults()
        let expired = PendingOfficeAuthorization(service: .feishu, jobID: UUID().uuidString, state: String(repeating: "a", count: 64), startedAt: Date().addingTimeInterval(-301), context: "https://fixture.invalid")
        expiredDefaults.set(try JSONEncoder().encode(expired), forKey: "connections.pendingAuthorization.v1")
        let expiredFlow = flow(BackendFixture(), PresenterFixture(), expiredDefaults); expiredFlow.restore()
        expect(expiredFlow.pending == nil && expiredDefaults.data(forKey: "connections.pendingAuthorization.v1") == nil, "Expired authorization was restored")
        print("PASS: \(checks) app-first, web fallback, callback validation, verified completion, foreground recovery, cancellation and relaunch checks. Offline fixtures only.")
    }
}
