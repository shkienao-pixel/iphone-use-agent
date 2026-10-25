import Foundation
import Combine
import UIKit
import UserNotifications

@MainActor
final class TaskNotificationsController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = TaskNotificationsController()
    struct OpenRequest: Identifiable { let id = UUID(); let taskID: UUID }
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "agent.taskNotifications.enabled")
    @Published private(set) var requesting = false
    @Published private(set) var authorization = "尚未读取"
    @Published private(set) var error = ""
    @Published private(set) var openRequest: OpenRequest?
    private(set) var lastSubmittedID = ""
    private(set) var lastOpenedTaskID: UUID?
    private(set) var foregroundSuppressions = 0
    private(set) var responseCompletionOnMain: Bool?
    private let center = UNUserNotificationCenter.current()
    private let journal = TaskNotificationJournal(url: URL.applicationSupportDirectory
        .appendingPathComponent("PhoneAgent/task-notifications.json"))
    private var policy = TaskNotificationPolicy()
    private var generation = UUID()
    private var authorizationGeneration = UUID()
    private var delivery: Task<Void, Never>?
    var reservationCount: Int { journal.totalReservations }
    var status: String { enabled ? "已开启 · " + authorization : "已关闭 · " + authorization }

    override init() {
        super.init()
        error = journal.error
    }
    func registerDelegate() { center.delegate = self }
    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorization = Self.authorizationTitle(settings)
    }
    private static func allowed(_ settings: UNNotificationSettings) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }
    private static func authorizationTitle(_ settings: UNNotificationSettings) -> String {
        switch settings.authorizationStatus {
        case .notDetermined: return "系统尚未询问"
        case .denied: return "系统未允许"
        case .authorized: return settings.alertSetting == .enabled ? "系统已允许" : "系统已允许，横幅关闭"
        case .provisional: return "系统允许静默通知"
        case .ephemeral: return "系统临时允许"
        @unknown default: return "系统权限未知"
        }
    }
    func setEnabled(_ value: Bool) async {
        let token = UUID(); authorizationGeneration = token
        if !value {
            requesting = false
            enabled = false; UserDefaults.standard.set(false, forKey: "agent.taskNotifications.enabled")
            generation = UUID(); delivery?.cancel(); delivery = nil
            await clearOwnedNotifications(taskID: nil)
            await refreshAuthorization()
            return
        }
        requesting = true
        defer { if authorizationGeneration == token { requesting = false } }
        do {
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard authorizationGeneration == token else { return }
            authorization = Self.authorizationTitle(settings)
            enabled = Self.allowed(settings)
            UserDefaults.standard.set(enabled, forKey: "agent.taskNotifications.enabled")
            error = enabled ? journal.error : "系统未允许任务通知，可在通知设置中调整；任务仍可在 App 中查看。"
        } catch {
            guard authorizationGeneration == token else { return }
            self.error = "暂时无法读取通知授权，请在系统通知设置中核对。"
        }
    }
    func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }
    func consumeOpenRequest(_ id: UUID) { if openRequest?.id == id { openRequest = nil } }

    func observe(taskID: UUID?, title: String, sessionID: UUID, phase: String, releasing: Bool) {
        let decision = policy.observe(taskID: taskID, sessionID: sessionID, phase: phase, title: title,
            releasing: releasing, foreground: UIApplication.shared.applicationState == .active, enabled: enabled)
        if decision.invalidated { generation = UUID(); delivery?.cancel(); delivery = nil }
        guard decision.clearTaskID != nil || decision.event != nil else { return }
        let token = generation
        delivery = Task { [weak self] in
            guard let self else { return }
            if let id = decision.clearTaskID { await self.clearOwnedNotifications(taskID: id, generation: token) }
            guard !Task.isCancelled, self.generation == token, let event = decision.event else { return }
            await self.submit(event, generation: token)
        }
    }
    private func submit(_ event: TaskNotificationEvent, generation token: UUID, delay: TimeInterval = 0) async {
        var reserved = false
        do {
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, generation == token, enabled else { return }
            authorization = Self.authorizationTitle(settings)
            guard Self.allowed(settings) else {
                error = "系统未允许任务通知，结果仍保存在 App 中。"
                return
            }
            // Foreground results are already visible in the App. The delegate
            // also suppresses a banner if activation races the OS submission.
            guard delay > 0 || UIApplication.shared.applicationState != .active else { return }
            guard try journal.reserve(event) else { return }
            reserved = true
            let content = UNMutableNotificationContent()
            content.title = "Sela · " + event.kind.title
            content.body = event.taskTitle.isEmpty ? "打开 App 查看任务记录。" : event.taskTitle
            content.categoryIdentifier = TaskNotificationEvent.category
            content.userInfo = event.userInfo
            content.sound = .default
            content.threadIdentifier = "sela.task." + event.taskID.uuidString
            let trigger: UNNotificationTrigger? = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
            try await center.add(UNNotificationRequest(identifier: event.identifier, content: content, trigger: trigger))
            guard !Task.isCancelled, generation == token, enabled else {
                remove([event.identifier]); return
            }
            lastSubmittedID = event.identifier; error = ""
        } catch {
            if reserved && (Task.isCancelled || generation != token || !enabled) { remove([event.identifier]); return }
            guard !Task.isCancelled, generation == token else { return }
            // No automatic replay after an uncertain OS submission.
            self.error = journal.error.isEmpty ? "本次任务通知未确认提交，请在 App 查看结果；不会自动重复发送。" : journal.error
        }
    }
    private func clearOwnedNotifications(taskID: UUID?, generation token: UUID? = nil) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
        if let token, generation != token { return }
        let prefix = TaskNotificationEvent.prefix + (taskID.map { $0.uuidString + "." } ?? "")
        remove((pending + delivered).filter { $0.hasPrefix(prefix) })
    }
    private func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func flush() async { await delivery?.value }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let request = notification.request
        let ours = TaskNotificationEvent.taskID(identifier: request.identifier, category: request.content.categoryIdentifier,
            userInfo: request.content.userInfo) != nil
        Task { @MainActor in
            if ours { self.foregroundSuppressions += 1 }
            completionHandler([])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let id = TaskNotificationEvent.taskID(identifier: request.identifier, category: request.content.categoryIdentifier,
            userInfo: request.content.userInfo)
        // UIKit performs launch/state-restoration work in this completion. The
        // async delegate bridge can finish on a worker queue during cold launch.
        // Complete every path on main, including ignored/invalid responses.
        Task { @MainActor in
            defer { self.responseCompletionOnMain = Thread.isMainThread; completionHandler() }
            guard isDefault, let id else { return }
            self.lastOpenedTaskID = id
            self.openRequest = OpenRequest(taskID: id)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func diagnostics() async -> [String: Any] {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(TaskNotificationEvent.prefix) }
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }.filter { $0.hasPrefix(TaskNotificationEvent.prefix) }
        return ["enabled": enabled, "authorization": authorization, "error": error,
                "pending": pending, "delivered": delivered, "reservations": reservationCount,
                "lastSubmittedID": lastSubmittedID, "lastOpenedTaskID": lastOpenedTaskID?.uuidString ?? "",
                "foregroundSuppressions": foregroundSuppressions,
                "responseCompletionOnMain": responseCompletionOnMain as Any? ?? NSNull()]
    }
    /// Transport-only foreground race test; production observes actual App state.
    func schedulePresentationFixture(_ event: TaskNotificationEvent, delay: TimeInterval) async {
        guard ProcessInfo.processInfo.arguments.contains("--sela-notification-fixtures"), (2...10).contains(delay) else { return }
        await submit(event, generation: generation, delay: delay)
    }
    #endif
}

@MainActor
final class SelaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TaskNotificationsController.shared.registerDelegate()
        return true
    }
}
