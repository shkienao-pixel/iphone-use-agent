import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
struct UIBackgroundTaskIdentifier: Equatable, Hashable {
    let value: Int
    static let invalid = Self(value: 0)
}
@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.active
    var opened = true
    var urls: [URL] = []
    var leases: [UIBackgroundTaskIdentifier: () -> Void] = [:]
    private var nextID = 1
    func beginBackgroundTask(withName name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        let id = UIBackgroundTaskIdentifier(value: nextID); nextID += 1
        leases[id] = expirationHandler; return id
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { leases[id] = nil }
    func open(_ url: URL, options: [String: Any], completionHandler: @escaping (Bool) -> Void) {
        urls.append(url); completionHandler(opened)
    }
}
