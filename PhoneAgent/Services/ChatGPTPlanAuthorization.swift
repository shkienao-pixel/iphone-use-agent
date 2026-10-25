import Foundation
import Combine
import UIKit
import SafariServices
import Network

/// A system Safari view keeps the app and its loopback listener foreground.
/// OAuth credentials are never read from another app or exposed to the view.
@MainActor final class ChatGPTPlanAuthorization: NSObject, ObservableObject, SFSafariViewControllerDelegate {
    static let shared = ChatGPTPlanAuthorization()
    struct Account: Identifiable { let id: UUID; let label: String; let sharing: Bool }
    struct Model: Identifiable { let id: String; let name: String }
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var models: [Model] = []
    @Published private(set) var connecting = false
    @Published private(set) var message = ""
    private var listener: NWListener?
    private var browser: SFSafariViewController?
    private var attempt: ChatGPTPlanProtocol.Attempt?
    private var continuation: CheckedContinuation<ChatGPTPlanProtocol.Callback, Error>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    override init() { super.init(); reload() }
    func reload() {
        do {
            let doc = try ChatGPTPlanStore.document()
            accounts = (doc?.profiles ?? []).enumerated().map { index, profile in
                Account(id: profile.id, label: "连接 \(index + 1) · " + (profile.email ?? "已注册账户"), sharing: profile.sharing)
            }
            activeID = doc?.selectedID
        } catch { message = "ChatGPT 登录资料暂时无法读取，原记录已保留" }
    }
    func select(_ id: UUID) {
        guard !connecting else { return }
        do { try ChatGPTPlanStore.select(id); models = []; reload(); Task { await loadModels() } }
        catch { message = "未能切换 ChatGPT 账户" }
    }
    func signIn(newAccount: Bool = false) async {
        guard !connecting else { return }
        connecting = true; message = "请在官方页面登录，并允许 Sela 使用你的 ChatGPT 计划用量。"
        generation = UUID(); let current = generation
        defer { if generation == current { connecting = false; closeBrowser(); listener?.cancel(); listener = nil; attempt = nil } }
        do {
            guard let doc = try ChatGPTPlanStore.document(create: true) else { throw ChatGPTPlanError.message("无法创建本机登录资料") }
            let previous = newAccount ? nil : doc.profiles.first { $0.id == doc.selectedID }
            let registrationID = previous?.id ?? UUID()
            let port = try await startListener()
            guard generation == current else { throw CancellationError() }
            let pending = try ChatGPTPlanProtocol.Attempt(port: port, clientID: previous?.clientID)
            attempt = pending
            let url = try pending.authorizationURL(hostID: doc.hostID)
            let callback = try await withCheckedThrowingContinuation { wait in
                continuation = wait
                let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                guard let root = (windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }))?.rootViewController else {
                    finish(.failure(ChatGPTPlanError.message("请回到 Sela 后重新登录"))); return
                }
                var presenter = root
                while let presented = presenter.presentedViewController { presenter = presented }
                let safari = SFSafariViewController(url: url); safari.delegate = self
                browser = safari; presenter.present(safari, animated: true)
                timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    self.finish(.failure(ChatGPTPlanError.message("ChatGPT 登录已超时，请重新开始")))
                }
            }
            guard generation == current else { throw CancellationError() }
            // The issued registration survives an expired one-time code.
            try ChatGPTPlanStore.stage(id: registrationID, clientID: callback.clientID)
            let staged = previous ?? ChatGPTPlanProfile(id: registrationID, clientID: callback.clientID)
            let response = try await ChatGPTPlanHTTP.json(ChatGPTPlanProtocol.tokenEndpoint, fields: [
                "grant_type": "authorization_code", "client_id": callback.clientID, "code": callback.code,
                "code_verifier": pending.verifier, "redirect_uri": pending.redirect.absoluteString, "resource": "https://api.openai.com/v1"])
            let profile = try await ChatGPTPlanHTTP.accept(response, previous: staged, nonce: pending.nonce)
            guard generation == current else { throw CancellationError() }
            try ChatGPTPlanStore.save(profile, select: true)
            reload()
            message = profile.sharing ? "已连接 ChatGPT 计划，使用该账户的可用额度。" : "已登录，但没有允许 Sela 使用计划用量；请重新授权。"
            if profile.sharing { await loadModels() }
        } catch is CancellationError { if generation == current { message = "ChatGPT 登录已取消" } }
        catch { if generation == current { message = (error as? ChatGPTPlanError)?.localizedDescription ?? "ChatGPT 登录未完成，请重试；原账户资料已保留。" } }
    }
    func loadModels() async {
        do {
            guard let id = activeID else { return }
            let profile = try await ChatGPTPlanTokens.shared.valid(id)
            let response = try await ChatGPTPlanHTTP.json("https://api.openai.com/v1/models", bearer: profile.accessToken)
            guard ChatGPTPlanStore.active(id), let list = response["models"] as? [[String: Any]] else { throw ChatGPTPlanError.message("ChatGPT 模型列表无效") }
            models = list.compactMap { value in
                guard value["visibility"] as? String == "list", let slug = value["slug"] as? String, !slug.isEmpty else { return nil }
                return Model(id: slug, name: value["display_name"] as? String ?? slug)
            }
            if models.isEmpty { message = "当前 ChatGPT 连接没有可选模型，请核对账户和工作区。" }
        } catch { message = (error as? ChatGPTPlanError)?.localizedDescription ?? "暂时无法读取 ChatGPT 模型列表" }
    }
    func signOut() async {
        guard !connecting, let profile = ChatGPTPlanStore.selected() else { return }
        connecting = true
        let revoked = await ChatGPTPlanHTTP.revoke(profile)
        do {
            try ChatGPTPlanStore.clearCredentials(profile.id); models = []; reload()
            message = revoked ? "已退出 ChatGPT 计划连接。" : "本机已退出，远端撤销未确认；可在 ChatGPT 设置中断开此应用。"
        } catch { message = "未能清除本机 ChatGPT 授权，请重试。" }
        connecting = false
    }
    func cancel() { finish(.failure(CancellationError())); generation = UUID(); connecting = false; attempt = nil; message = "ChatGPT 登录已取消" }
    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in if self?.browser === controller { self?.cancel() } }
    }
    private func closeBrowser() { let old = browser; browser = nil; old?.dismiss(animated: true) }
    private func finish(_ result: Result<ChatGPTPlanProtocol.Callback, Error>) {
        let wait = continuation; continuation = nil; timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil; closeBrowser()
        wait?.resume(with: result)
    }
    private func startListener() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.listener != nil else { connection.cancel(); return }
                connection.start(queue: .main); self.receive(connection, accumulated: Data())
            }
        }
        return try await withCheckedThrowingContinuation { wait in
            var settled = false
            server.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !settled else { return }
                    switch state {
                    case .ready:
                        settled = true
                        if let port = server.port { wait.resume(returning: port.rawValue) }
                        else { wait.resume(throwing: ChatGPTPlanError.message("无法创建本机登录回调")) }
                    case .failed, .cancelled:
                        settled = true; wait.resume(throwing: ChatGPTPlanError.message("本机登录回调未能启动"))
                    default: break
                    }
                }
            }
            server.start(queue: .main)
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, let pending = self.attempt, self.continuation != nil else { connection.cancel(); return }
                let bytes = accumulated + (chunk ?? Data())
                guard bytes.count <= 16_384, error == nil else { connection.cancel(); return }
                if bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
                    if complete { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
                    return
                }
                do {
                    let result = try ChatGPTPlanProtocol.callback(bytes, attempt: pending)
                    self.reply(connection, success: true); self.finish(.success(result))
                } catch ChatGPTPlanError.denied {
                    self.reply(connection, success: false); self.finish(.failure(ChatGPTPlanError.denied))
                } catch {
                    self.reply(connection, success: false)
                    // A foreign or malformed localhost request cannot cancel a
                    // legitimate pending sign-in. OAuth denial is bounded by UI cancellation.
                }
            }
        }
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); connection.cancel() }
    }
    private func reply(_ connection: NWConnection, success: Bool) {
        let body = success ? "Sela sign-in received. You can return to Sela." : "Sela sign-in callback rejected."
        let header = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
