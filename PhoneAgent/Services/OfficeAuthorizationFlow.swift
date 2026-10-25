import Foundation
import Combine

@MainActor
final class OfficeAuthorizationFlow: ObservableObject {
    #if canImport(UIKit)
    static let shared = OfficeAuthorizationFlow(backend: ExternalConnectionsCoordinator.shared, presenter: OfficeAuthorizationBrowser())
    #endif

    enum Phase: String { case idle, starting, waiting, verifying, connected, failed, cancelled }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var service: ExternalAppService?
    @Published private(set) var job: OfficeAuthorizationJob?
    @Published private(set) var message = ""
    @Published private(set) var pending: PendingOfficeAuthorization?
    private let backend: OfficeAuthorizationBackend
    private let presenter: OfficeAuthorizationPresenting
    private let defaults: UserDefaults
    private let storageKey = "connections.pendingAuthorization.v1"
    private var work: Task<Void, Never>?
    private var presentation: Task<Void, Never>?
    private var presentationID: UUID?
    private var openedURL: URL?
    private var presentedSource: String?
    private var active = true
    private var generation = UUID()
    private var operationID: UUID?
    private var automaticLaunch = false
    private let interval: Duration
    var running: Bool { [.starting, .waiting, .verifying].contains(phase) }

    init(backend: OfficeAuthorizationBackend, presenter: OfficeAuthorizationPresenting,
         defaults: UserDefaults = .standard, interval: Duration = .seconds(1)) {
        self.backend = backend; self.presenter = presenter; self.defaults = defaults; self.interval = interval
    }

    func restore() {
        guard pending == nil, !running,
              let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(PendingOfficeAuthorization.self, from: data) else { return }
        guard saved.service.isCLI, UUID(uuidString: saved.jobID) != nil,
              saved.state.count == 64, saved.context == backend.authorizationContext,
              Date().timeIntervalSince(saved.startedAt) >= 0,
              Date().timeIntervalSince(saved.startedAt) < OfficeAuthorizationPolicy.timeout else {
            defaults.removeObject(forKey: storageKey); return
        }
        pending = saved; service = saved.service; phase = .waiting
        automaticLaunch = false
        message = "正在恢复上次授权…"
        monitor(saved)
    }

    func start(_ service: ExternalAppService) {
        guard service.isCLI, !running else { return }
        resetPresentation(); generation = UUID(); let id = generation
        let context = backend.authorizationContext
        automaticLaunch = true
        self.service = service; phase = .starting; message = "正在发起官方账号授权…"; job = nil
        work = Task {
            do {
                let latest = try await backend.start(service, install: false)
                try Task.checkCancellation()
                guard generation == id else { return }
                guard validateContext(context) else { return }
                guard latest.service == service.rawValue, UUID(uuidString: latest.id) != nil else {
                    throw AgentError.message("授权任务与当前应用不匹配")
                }
                let saved = PendingOfficeAuthorization(service: service, jobID: latest.id,
                    state: UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    startedAt: Date(), context: context)
                pending = saved
                defaults.set(try JSONEncoder().encode(saved), forKey: storageKey)
                job = latest; phase = .waiting; message = latest.message
                monitor(saved)
            } catch is CancellationError {
                if generation == id { finish(.failed, message: "授权请求已中断，请重新连接") }
            }
            catch { if generation == id { finish(.failed, message: error.localizedDescription) } }
        }
    }

    func sceneActive(_ isActive: Bool) {
        active = isActive
        if isActive {
            restore()
            if let pending { Task { await refresh(pending, launch: false) } }
        }
    }

    func handle(_ url: URL) {
        guard let pending, OfficeAuthorizationPolicy.accepts(url, pending: pending) else { return }
        phase = .verifying; message = "已返回 Sela，正在验证授权…"
        // A callback is only a wake-up signal. It never supplies a trusted success flag.
        Task { await refresh(pending, launch: false) }
    }

    func continueAuthorization() {
        guard let pending, let job, running else { return }
        openedURL = nil; presentedSource = nil; automaticLaunch = true
        launch(job, pending: pending)
    }

    func cancel() {
        guard running else { return }
        let current = pending
        generation = UUID(); work?.cancel(); work = nil
        finish(.cancelled, message: "已取消本次授权")
        if let current {
            Task {
                guard current.context == backend.authorizationContext else { return }
                await backend.cancel(current.jobID)
            }
        }
    }

    func clearResult() {
        guard !running else { return }
        phase = .idle; service = nil; job = nil; message = ""
    }

    private func monitor(_ saved: PendingOfficeAuthorization) {
        let id = generation
        work = Task {
            while !Task.isCancelled, pending == saved, generation == id {
                if Date().timeIntervalSince(saved.startedAt) >= OfficeAuthorizationPolicy.timeout {
                    finish(.failed, message: "授权已超时，请重新连接")
                    if saved.context == backend.authorizationContext { await backend.cancel(saved.jobID) }
                    return
                }
                if active { await refresh(saved, launch: automaticLaunch) }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func refresh(_ saved: PendingOfficeAuthorization, launch: Bool) async {
        guard pending == saved, operationID == nil else { return }
        guard validateContext(saved.context) else { return }
        let operation = UUID(); operationID = operation
        defer { if operationID == operation { operationID = nil } }
        do {
            let latest = try await backend.poll(saved.jobID)
            try Task.checkCancellation()
            guard pending == saved else { return }
            guard validateContext(saved.context) else { return }
            guard latest.id == saved.jobID, latest.service == saved.service.rawValue else {
                throw AgentError.message("授权任务返回了不匹配的状态")
            }
            job = latest
            if latest.state == "complete" {
                phase = .verifying; message = "正在确认账号连接…"
                let status = try await backend.verifiedStatus(saved.service)
                try Task.checkCancellation()
                guard pending == saved else { return }
                guard validateContext(saved.context) else { return }
                guard status.service == saved.service.rawValue, status.connected, status.state == "connected" else {
                    finish(.failed, message: "尚未验证到有效授权，请重新连接"); return
                }
                finish(.connected, message: "已连接" + saved.service.title.replacingOccurrences(of: " CLI", with: ""))
            } else if latest.finished {
                finish(latest.state == "cancelled" ? .cancelled : .failed, message: latest.message)
            } else {
                phase = .waiting
                if openedURL == nil { message = latest.message }
                if launch, active { self.launch(latest, pending: saved) }
            }
        } catch is CancellationError { }
        catch {
            guard pending == saved else { return }
            message = "暂时无法确认授权，恢复网络后会继续检测。也可取消后重新连接。"
        }
    }

    private func launch(_ latest: OfficeAuthorizationJob, pending saved: PendingOfficeAuthorization) {
        guard pending == saved, validateContext(saved.context), presentation == nil,
              let source = latest.authorizationURL ?? latest.qrCode, source != presentedSource else { return }
        presentedSource = source
        let id = UUID(); presentationID = id
        presentation = Task { [self] in
            defer { if presentationID == id { presentation = nil; presentationID = nil } }
            let resolved = await presenter.authorizationURL(for: latest)
            guard !Task.isCancelled, pending == saved, validateContext(saved.context) else { return }
            guard let resolved,
                  let url = OfficeAuthorizationPolicy.authorizationURL(resolved.absoluteString, service: saved.service),
                  url != openedURL, pending == saved, active else {
                if pending == saved, latest.qrCode != nil, latest.authorizationURL == nil {
                    message = "当前官方入口提供扫码授权，请使用企业微信扫码；返回 Sela 后会继续验证。"
                }
                return
            }
            openedURL = url
            do {
                let route = try await presenter.open(url, callback: OfficeAuthorizationPolicy.callback(for: saved)) { [weak self] event in
                    guard let self, self.pending == saved else { return }
                    switch event {
                    case .callback(let url): self.handle(url)
                    case .closed:
                        self.message = "授权页已关闭，仍在检测授权结果。未完成时可点击继续授权。"
                        Task { await self.refresh(saved, launch: false) }
                    }
                }
                try Task.checkCancellation()
                guard pending == saved else { return }
                guard validateContext(saved.context) else { return }
                message = route == .app ? "已打开官方 App。完成授权后返回 Sela，将自动验证连接。" : "请在官方页面确认授权，完成后将自动返回。"
            } catch {
                guard pending == saved else { return }
                message = error.localizedDescription
            }
        }
    }

    private func validateContext(_ context: String) -> Bool {
        guard context == backend.authorizationContext else {
            finish(.failed, message: "连接服务已更换，请重新发起授权")
            return false
        }
        return true
    }

    private func resetPresentation() {
        presentationID = nil; presentation?.cancel(); presentation = nil; openedURL = nil; presentedSource = nil
        presenter.dismiss()
    }
    private func finish(_ phase: Phase, message: String) {
        pending = nil; defaults.removeObject(forKey: storageKey)
        self.phase = phase; self.message = message; operationID = nil
        resetPresentation()
    }
}
