import Foundation
public struct UIBackgroundTaskIdentifier: Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let invalid = UIBackgroundTaskIdentifier(rawValue: -1)
}
@MainActor public final class UIApplication {
    public enum State { case active, inactive, background }
    public static let shared = UIApplication()
    public var applicationState = State.active
    public var assertions: [UIBackgroundTaskIdentifier: @MainActor @Sendable () -> Void] = [:]
    public var ended: [UIBackgroundTaskIdentifier] = []
    private var serial = 0
    public func beginBackgroundTask(withName: String?, expirationHandler: (@MainActor @Sendable () -> Void)?) -> UIBackgroundTaskIdentifier {
        serial += 1; let id = UIBackgroundTaskIdentifier(rawValue: serial)
        assertions[id] = expirationHandler; return id
    }
    public func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { ended.append(id); assertions.removeValue(forKey: id) }
    public func reset() { applicationState = .active; assertions = [:]; ended = [] }
}
