import Combine
import UIKit

/// Public Shortcuts handoff only. SystemTools must persist its pending write
/// before calling run; cancellation cannot undo an external write already made.
@MainActor
final class NotesShortcutBridge: ObservableObject {
    static let shared = NotesShortcutBridge()
    @Published private(set) var running = false
    private let defaults: UserDefaults
    private let now: () -> Date
    private var session = NotesShortcutSession()
    private var continuation: CheckedContinuation<String, Error>?
    private var cancellation: NotesShortcutCancellation?
    private var timeout: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private static let configurationKey = "connections.notes.shortcut.v1"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
    }

    var configuration: NotesShortcutConfiguration? {
        guard let data = defaults.data(forKey: Self.configurationKey),
              let value = try? JSONDecoder().decode(NotesShortcutConfiguration.self, from: data),
              (try? value.validate()) != nil else { return nil }
        return value
    }
    func configure(_ value: NotesShortcutConfiguration) throws {
        guard !running else { throw NotesShortcutError.alreadyRunning }
        try value.validate(); defaults.set(try JSONEncoder().encode(value), forKey: Self.configurationKey)
        objectWillChange.send()
    }
    func preflight(taskID: UUID, digest: String, title: String, body: String, folderName: String? = nil) throws -> NotesShortcutInvocation {
        guard UIApplication.shared.applicationState == .active else { throw AgentError.message("请保持 Sela 在前台启动备忘录任务") }
        guard !running else { throw NotesShortcutError.alreadyRunning }
        guard let configuration else { throw NotesShortcutError.invalidConfiguration }
        if let folderName, configuration.folderName != folderName { throw NotesShortcutError.invalidConfiguration }
        return try NotesShortcutInvocation(taskID: taskID, digest: digest, title: title, body: body,
            configuration: configuration, now: now())
    }

    func run(_ invocation: NotesShortcutInvocation) async throws -> String {
        try Task.checkCancellation()
        guard now() <= invocation.expiresAt, configuration == invocation.configuration,
              UIApplication.shared.applicationState == .active else {
            throw NotesShortcutError.invalidConfiguration
        }
        try session.begin(invocation); running = true
        let signal = NotesShortcutCancellation(); cancellation = signal
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { result in
                continuation = result
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Notes shortcut result") { [weak self] in
                    // iOS may expire background processing while Shortcuts is
                    // showing its first privacy sheet. No background work is
                    // needed to await a URL return; retain the bound attempt.
                    Task { @MainActor in self?.releaseBackgroundTask() }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(180))
                    guard !Task.isCancelled, self?.session.active?.id == invocation.id else { return }
                    self?.finish(.failure(NotesShortcutError.interrupted))
                }
                UIApplication.shared.open(invocation.launchURL, options: [:]) { [weak self] opened in
                    Task { @MainActor in
                        guard self?.session.active?.id == invocation.id else { return }
                        if !opened { self?.finish(.failure(NotesShortcutError.unavailable)) }
                    }
                }
            }
        } onCancel: {
            signal.cancel()
            Task { @MainActor [weak self] in
                guard self?.session.active?.id == invocation.id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    @discardableResult func handle(_ url: URL) -> Bool {
        guard url.scheme == "phoneagent", url.host == "notes-result" else { return false }
        guard let invocation = session.active else { return true }
        guard cancellation?.isCancelled == false else { finish(.failure(CancellationError())); return true }
        let date = now()
        guard date <= invocation.expiresAt else { finish(.failure(NotesShortcutError.interrupted)); return true }
        guard let callback = session.take(url, now: date) else { return true }
        guard callback.status == .success else { finish(.failure(NotesShortcutError.interrupted)); return true }
        guard let output = callback.output, output.utf8.elementsEqual(invocation.text.utf8) else {
            finish(.failure(NotesShortcutError.unverifiedOutput)); return true
        }
        let object: [String: Any] = ["source": "iPhone Shortcuts / Apple Notes", "shortcut_completed": true,
            "output_matches_requested_text": true, "expected_folder": invocation.configuration.folderName,
            "folder_independently_verified": false, "receipt_id": invocation.id.uuidString,
            "notice": "快捷指令回传正文与提交正文逐字一致；文件夹和重复数量仍须独立核对。"]
        do { finish(.success(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))) }
        catch { finish(.failure(error)) }
        return true
    }

    func becameActive() {
        if let active = session.active, now() > active.expiresAt { finish(.failure(NotesShortcutError.interrupted)) }
    }
    private func finish(_ result: Result<String, Error>) {
        guard continuation != nil else { return }
        let pending = continuation; continuation = nil; cancellation = nil
        if let id = session.active?.id { session.cancel(id: id) }
        timeout?.cancel(); timeout = nil; running = false
        releaseBackgroundTask()
        pending?.resume(with: result)
    }
    private func releaseBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
}
