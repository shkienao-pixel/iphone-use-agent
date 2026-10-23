import Foundation
import Combine

@MainActor protocol RealtimeConnection: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}
@MainActor protocol RealtimeAudioSink: AnyObject {
    var inbox: RealtimePCMInbox { get }
    var playedMilliseconds: Int { get }
    var scheduledMilliseconds: Int { get }
    var hasPending: Bool { get }
    func start() throws
    func play(_ data: Data) throws
    func clearPlayback()
    func stop()
}
private final class RealtimeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class RealtimeWebSocket: RealtimeConnection {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForResource = 330
        session = URLSession(configuration: config, delegate: RealtimeRedirectPolicy(), delegateQueue: nil)
        socket = session.webSocketTask(with: request); socket.maximumMessageSize = 1000000; socket.resume()
    }
    func send(_ data: Data) async throws { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
    func receive() async throws -> Data { switch try await socket.receive() { case .string(let value): return Data(value.utf8); case .data(let data): return data; @unknown default: throw AgentError.message("实时服务返回未知消息格式") } }
    func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
struct RealtimeTranscript: Identifiable { let id: String; var text: String }
@MainActor final class RealtimeSession: ObservableObject {
    enum Mode { case idle, preparing, connecting, live }
    @Published private(set) var mode = Mode.idle
    @Published private(set) var status = "尚未开启实时语音"
    @Published private(set) var error = ""
    @Published private(set) var transcripts: [RealtimeTranscript] = []
    @Published private(set) var seconds = 0
    @Published private(set) var cameraShares = 0
    var busy: Bool { mode != .idle }
    var reserve: ((UUID) -> Bool)?
    var release: ((UUID) -> Void)?
    var prepareAudio: (() async throws -> Void)?
    var permission: () async -> Bool = { false }
    var authorized: () -> Bool = { false }
    var makeAudio: (() -> any RealtimeAudioSink)?
    var makeConnection: (URLRequest) -> any RealtimeConnection = { RealtimeWebSocket(request: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var generation = UUID()
    private var lease: UUID?
    private var settings: RealtimeSettings?
    private var includeCamera = false
    private var socket: (any RealtimeConnection)?
    private var audio: (any RealtimeAudioSink)?
    private var setup: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var configured = false
    private var configSent = false
    private var responding = false
    private var interrupting = false
    private var item: (id: String, index: Int)?
    private var ignored: [String] = []
    private var deadline = 0.0
    func start(settings: RealtimeSettings, key: String, includeCamera: Bool) {
        guard !busy else { return }
        error = ""
        let request: URLRequest
        do { request = try settings.request(key: key) } catch { self.error = error.localizedDescription; return }
        guard authorized(), let makeAudio else { error = "页面授权或音频环境未就绪"; return }
        let token = UUID()
        guard reserve?(token) == true else { error = "请先结束当前任务、语音、录音或回听，再开启实时对话"; return }
        generation = token; lease = token; self.settings = settings; self.includeCamera = includeCamera
        configured = false; configSent = false; responding = false; ignored = []; item = nil
        seconds = 0; cameraShares = 0; transcripts = []; mode = .preparing; status = "准备麦克风权限"
        setup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareAudio?(); try self.check(token)
                guard await self.permission() else { throw AgentError.message("请在系统设置中允许麦克风权限；未发送音频") }; try self.check(token)
                self.audio = makeAudio(); self.socket = self.makeConnection(request); self.mode = .connecting; self.status = "等待实时服务确认格式"
                self.deadline = self.now() + 20; self.watch(token); self.listen(token); self.setup = nil
            } catch is CancellationError { if self.generation == token { self.stop() } }
            catch { if self.generation == token { self.fail("无法准备实时对话，请核对权限与接口；未自动重试") } }
        }
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard generation == token, authorized() else { throw CancellationError() } }
    private func listen(_ token: UUID) {
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try self.check(token); guard let socket = self.socket, let settings = self.settings else { return }
                    let data = try await socket.receive(); try self.check(token)
                    try await self.handle(RealtimeProtocol.decode(data, settings: settings), token: token)
                }
            } catch is CancellationError { if self.generation == token { self.stop() } }
            catch { if self.generation == token { self.fail("实时连接或事件处理失败，请核对独立接口、模型、声音和额度；未自动重连") } }
        }
    }
    private func handle(_ event: RealtimeProtocol.Event, token: UUID) async throws {
        switch event {
        case .created:
            guard !configSent, !configured, let settings, let socket else { throw AgentError.message("重复的实时会话创建事件") }
            configSent = true; try await socket.send(RealtimeProtocol.configuration(settings)); try check(token)
        case .configured:
            guard configSent, !configured, mode == .connecting, let audio else { throw AgentError.message("实时配置确认顺序无效") }
            try check(token); try audio.start(); configured = true; mode = .live; deadline = now() + 300; status = "正在实时听你说"; stream(token)
        case .speechStarted:
            guard configured else { throw AgentError.message("实时服务尚未确认格式") }
            try await interrupt(cancelResponse: false, token: token); status = "听你说"
        case .speechStopped: if configured { status = "正在理解这句话" }
        case .responseStarted:
            guard configured else { throw AgentError.message("实时回复早于格式确认") }; responding = true; status = "助手正在回答"
        case .responseEnded: responding = false; if configured { status = "可以继续说" }
        case .audio(let id, let index, let data):
            guard configured, let audio else { throw AgentError.message("音频早于配置确认") }
            if ignored.contains(id) { return }
            if item?.id != id {
                guard !audio.hasPending else { throw AgentError.message("实时音频回复重叠，未混播") }; audio.clearPlayback(); item = (id, index)
            }
            guard item?.index == index else { throw AgentError.message("实时音频片段索引变化") }
            try audio.play(data)
        case .transcript(let id, let contentIndex, let text, let done):
            guard configured else { throw AgentError.message("转写早于配置确认") }; if ignored.contains(id) { return }
            if item == nil && responding { audio?.clearPlayback(); item = (id, contentIndex) }
            if let index = transcripts.firstIndex(where: { $0.id == id }) {
                let newText = done ? text : transcripts[index].text + text
                guard newText.count <= 12000 else { throw AgentError.message("实时转写超过上限") }; transcripts[index].text = newText
            } else { if transcripts.count == 40 { transcripts.removeFirst() }; transcripts.append(.init(id: id, text: text)) }
        case .failure: throw AgentError.message("实时服务未完成本次回复")
        case .ignored: break
        }
    }
    private func stream(_ token: UUID) {
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try self.check(token); guard let audio = self.audio, let socket = self.socket else { return }
                    if audio.inbox.failed { throw AgentError.message("实时上行拥塞") }
                    if let data = audio.inbox.pop() { try await socket.send(RealtimeProtocol.append(data)); try self.check(token) }
                    else { try await Task.sleep(nanoseconds: 20000000) }
                }
            } catch is CancellationError { if self.generation == token { self.stop() } }
            catch { if self.generation == token { self.fail("实时音频发送中断或积压，连接已停止；未自动重试") } }
        }
    }
    private func watch(_ token: UUID) {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200000000) } catch { return }
                guard let self, self.generation == token else { return }
                guard self.authorized() else { self.stop(reason: "页面或配置变化，实时对话已结束"); return }
                if self.audio?.inbox.failed == true { self.fail("上行音频积压，已停止麦克风与连接"); return }
                if self.now() >= self.deadline { self.stop(reason: self.configured ? "已达到本次 5 分钟上限" : "实时配置确认超时，麦克风未开启"); return }
                if self.configured { self.seconds = max(0, min(300, 300 - Int(self.deadline - self.now()))) }
            }
        }
    }
    func interruptReply() {
        guard mode == .live, !interrupting else { return }; let token = generation; interrupting = true
        Task { defer { if generation == token { interrupting = false } }; do { try await interrupt(cancelResponse: true, token: token); try check(token); status = "回复已打断，可以继续说" } catch { if generation == token { fail("无法同步回复中断，连接已结束") } } }
    }
    private func interrupt(cancelResponse: Bool, token: UUID) async throws {
        try check(token); guard let socket, let audio else { return }
        let previous = item; let heard = audio.playedMilliseconds; let total = audio.scheduledMilliseconds
        audio.clearPlayback(); item = nil
        if let previous, responding || heard < total {
            if ignored.count == 50 { ignored.removeFirst() }; ignored.append(previous.id)
            if let index = transcripts.firstIndex(where: { $0.id == previous.id }) { transcripts[index].text = "（回复已打断，未播放文字不保留）" }
        }
        if cancelResponse && responding { try await socket.send(RealtimeProtocol.json(["type": "response.cancel"])); try check(token) }
        if let previous, heard < total || responding { try await socket.send(RealtimeProtocol.truncate(item: previous.id, index: previous.index, milliseconds: heard)); try check(token) }
    }
    func share(jpeg: Data, capturedAt: Date) {
        guard mode == .live, includeCamera, cameraShares < 20 else { error = "本次未授权相机或已达到 20 帧上限"; return }
        let token = generation
        let data: Data
        do { data = try RealtimeProtocol.image(jpeg, capturedAt: capturedAt, now: Date()) } catch { self.error = error.localizedDescription; return }
        cameraShares += 1 // Reserve synchronously so rapid taps cannot bypass the session limit.
        Task {
            do {
                try check(token); guard let socket else { return }
                try await socket.send(data); try check(token); status = "这一帧已发送，继续说出你的问题"
            } catch { if generation == token { fail("相机帧未能发送，实时连接已停止") } }
        }
    }
    func stop(reason: String = "实时对话已结束") {
        generation = UUID(); setup?.cancel(); receiver?.cancel(); sender?.cancel(); timer?.cancel(); setup = nil; receiver = nil; sender = nil; timer = nil
        socket?.close(); socket = nil; audio?.stop(); audio = nil; mode = .idle; configured = false; responding = false; interrupting = false; configSent = false; item = nil; ignored = []; status = reason
        if let lease { self.lease = nil; release?(lease) }
    }
    private func fail(_ message: String) { stop(reason: "实时对话已停止"); error = message }
}
