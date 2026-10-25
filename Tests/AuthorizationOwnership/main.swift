import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

@MainActor final class AuthorizationBackendProbe: OfficeAuthorizationBackend {
    enum Gate { case none, start, poll, verify, cancelledStart }
    var authorizationContext = "https://old-bridge.invalid"
    let id = UUID().uuidString
    var state = "complete"
    var gate: Gate = .none
    var continuation: CheckedContinuation<Void, Never>?
    var verifications = 0
    var cancellationContexts: [String] = []
    func job() -> OfficeAuthorizationJob {
        .init(id: id, service: "feishu", state: state, message: "offline job", authorizationURL: "https://accounts.feishu.cn/auth", qrCode: nil, verificationCode: nil)
    }
    func suspend(_ stage: Gate) async {
        if gate == stage { gate = .none; await withCheckedContinuation { continuation = $0 } }
    }
    func start(_ service: ExternalAppService, install: Bool) async throws -> OfficeAuthorizationJob {
        if gate == .cancelledStart { gate = .none; throw CancellationError() }
        await suspend(.start)
        return job()
    }
    func poll(_ id: String) async throws -> OfficeAuthorizationJob { await suspend(.poll); return job() }
    func verifiedStatus(_ service: ExternalAppService) async throws -> OfficeConnectionStatus {
        verifications += 1; await suspend(.verify)
        return .init(service: "feishu", installed: true, connected: true, state: "connected", message: "offline status", jobID: id)
    }
    func cancel(_ id: String) async { cancellationContexts.append(authorizationContext) }
}

@MainActor final class AuthorizationPresenterProbe: OfficeAuthorizationPresenting {
    var openings = 0
    var gatedResolve = false
    var gatedOpen = false
    var resolutions: [CheckedContinuation<URL?, Never>?] = []
    var opening: CheckedContinuation<OfficeAuthorizationLaunch, Never>?
    func authorizationURL(for job: OfficeAuthorizationJob) async -> URL? {
        if gatedResolve { return await withCheckedContinuation { resolutions.append($0) } }
        return job.authorizationURL.flatMap(URL.init(string:))
    }
    func open(_ url: URL, callback: URL, event: @escaping @MainActor (OfficeAuthorizationPresentationEvent) -> Void) async throws -> OfficeAuthorizationLaunch {
        openings += 1
        if gatedOpen { return await withCheckedContinuation { opening = $0 } }
        return .web
    }
    func dismiss() {}
}

@main struct AuthorizationOwnershipRegressions {
    @MainActor static func main() async throws {
        var failures: [String] = [], checks = 0, domains: [String] = []
        defer { for name in domains { UserDefaults.standard.removePersistentDomain(forName: name) } }
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !value() { failures.append(label); print("FAIL: " + label) }
        }
        func settle(_ predicate: () -> Bool) async throws {
            for _ in 0..<2000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            throw NSError(domain: "AuthorizationFixture", code: 1)
        }
        for stage in [AuthorizationBackendProbe.Gate.start, .poll, .verify] {
            let domain = "sela-authorization-ownership-" + UUID().uuidString; domains.append(domain)
            let backend = AuthorizationBackendProbe(); backend.gate = stage
            let presenter = AuthorizationPresenterProbe()
            let flow = OfficeAuthorizationFlow(backend: backend, presenter: presenter, defaults: UserDefaults(suiteName: domain)!, interval: .milliseconds(5))
            flow.start(.feishu)
            try await settle { backend.continuation != nil }
            backend.authorizationContext = "https://replacement-bridge.invalid"
            let previous = backend.continuation; backend.continuation = nil; previous!.resume()
            try await Task.sleep(for: .milliseconds(50))
            expect(flow.phase == .failed && flow.pending == nil, "Bridge change during \(stage) rejects the stale authorization result")
            expect(flow.phase != .connected, "Bridge change during \(stage) never reports connected")
            if stage != .verify { expect(backend.verifications == 0, "Bridge change during \(stage) never verifies the old job against the replacement bridge") }
            expect(presenter.openings == 0, "Bridge change during \(stage) never opens the old authorization URL")
            flow.cancel()
        }
        let cancelledDomain = "sela-authorization-cancelled-start-" + UUID().uuidString; domains.append(cancelledDomain)
        let cancelledBackend = AuthorizationBackendProbe(); cancelledBackend.gate = .cancelledStart
        let cancelled = OfficeAuthorizationFlow(backend: cancelledBackend, presenter: AuthorizationPresenterProbe(), defaults: UserDefaults(suiteName: cancelledDomain)!, interval: .milliseconds(5))
        cancelled.start(.feishu)
        try await Task.sleep(for: .milliseconds(50))
        expect(!cancelled.running && cancelled.phase == .failed, "Unexpected upstream cancellation cannot leave authorization stuck in starting")
        expect(!cancelled.message.isEmpty && cancelled.pending == nil, "Unexpected upstream cancellation leaves a visible retryable result")
        cancelled.cancel()

        for openGate in [false, true] {
            let domain = "sela-authorization-presenter-" + UUID().uuidString; domains.append(domain)
            let backend = AuthorizationBackendProbe(); backend.state = "authorizing"
            let presenter = AuthorizationPresenterProbe(); presenter.gatedResolve = !openGate; presenter.gatedOpen = openGate
            let flow = OfficeAuthorizationFlow(backend: backend, presenter: presenter, defaults: UserDefaults(suiteName: domain)!, interval: .seconds(30))
            flow.start(.feishu)
            try await settle { openGate ? presenter.opening != nil : !presenter.resolutions.isEmpty }
            backend.authorizationContext = "https://replacement-presenter-bridge.invalid"
            if openGate { presenter.opening!.resume(returning: .web); presenter.opening = nil }
            else { presenter.resolutions[0]!.resume(returning: URL(string: "https://accounts.feishu.cn/auth")); presenter.resolutions[0] = nil }
            try await Task.sleep(for: .milliseconds(50))
            expect(flow.phase == .failed && flow.pending == nil, "Bridge change while presenter \(openGate ? "opens" : "resolves") rejects the stale UI result")
            if !openGate { expect(presenter.openings == 0, "Bridge change during URL resolution never opens the stale URL") }
            flow.cancel()
        }

        let ownerDomain = "sela-authorization-presentation-owner-" + UUID().uuidString; domains.append(ownerDomain)
        let ownerBackend = AuthorizationBackendProbe(); ownerBackend.state = "authorizing"
        let ownerPresenter = AuthorizationPresenterProbe(); ownerPresenter.gatedResolve = true
        let owner = OfficeAuthorizationFlow(backend: ownerBackend, presenter: ownerPresenter, defaults: UserDefaults(suiteName: ownerDomain)!, interval: .seconds(30))
        owner.start(.feishu)
        try await settle { ownerPresenter.resolutions.count == 1 }
        owner.cancel(); owner.start(.feishu)
        try await settle { ownerPresenter.resolutions.count == 2 }
        ownerPresenter.resolutions[0]!.resume(returning: URL(string: "https://accounts.feishu.cn/auth")); ownerPresenter.resolutions[0] = nil
        try await Task.sleep(for: .milliseconds(50))
        owner.continueAuthorization()
        try await Task.sleep(for: .milliseconds(50))
        expect(ownerPresenter.resolutions.count == 2, "A cancelled presenter cannot clear the replacement presenter's ownership and launch a duplicate")
        owner.cancel()
        for index in ownerPresenter.resolutions.indices {
            ownerPresenter.resolutions[index]?.resume(returning: nil); ownerPresenter.resolutions[index] = nil
        }
        let cancelDomain = "sela-authorization-cancel-destination-" + UUID().uuidString; domains.append(cancelDomain)
        let cancelBackend = AuthorizationBackendProbe(); cancelBackend.state = "authorizing"
        let cancelPresenter = AuthorizationPresenterProbe()
        let cancelFlow = OfficeAuthorizationFlow(backend: cancelBackend, presenter: cancelPresenter, defaults: UserDefaults(suiteName: cancelDomain)!, interval: .seconds(30))
        cancelFlow.start(.feishu)
        try await settle { cancelPresenter.openings == 1 }
        cancelBackend.authorizationContext = "https://replacement-cancel-bridge.invalid"
        cancelFlow.cancel()
        try await Task.sleep(for: .milliseconds(50))
        expect(cancelBackend.cancellationContexts.isEmpty, "Cancelling an old grant never submits its job ID to a replacement bridge")
        print(String(data: try JSONSerialization.data(withJSONObject: ["checks": checks, "failures": failures, "mode": "offline backend/presenter gates only"], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
