import Foundation

enum OfficeAuthorizationPolicy {
    static let callbackScheme = "sela-auth"
    static let timeout: TimeInterval = 300

    @MainActor
    static func route(openApp: () async -> Bool, openWeb: () throws -> Void) async throws -> OfficeAuthorizationLaunch {
        try Task.checkCancellation()
        let opened = await openApp()
        try Task.checkCancellation()
        if opened { return .app }
        try openWeb()
        return .web
    }

    static func authorizationURL(_ text: String?, service: ExternalAppService) -> URL? {
        guard service.isCLI, let text, text.utf8.count <= 8192,
              let parts = URLComponents(string: text), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), let url = parts.url else { return nil }
        let domains: [String]
        switch service {
        case .feishu: domains = ["feishu.cn", "larksuite.com"]
        case .dingtalk: domains = ["dingtalk.com"]
        case .wecom: domains = ["work.weixin.qq.com"]
        default: return nil
        }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) } ? url : nil
    }

    static func callback(for pending: PendingOfficeAuthorization) -> URL {
        var parts = URLComponents()
        parts.scheme = callbackScheme; parts.host = "callback"
        parts.queryItems = [URLQueryItem(name: "service", value: pending.service.rawValue),
                            URLQueryItem(name: "job", value: pending.jobID),
                            URLQueryItem(name: "state", value: pending.state)]
        return parts.url!
    }

    static func accepts(_ url: URL, pending: PendingOfficeAuthorization, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(pending.startedAt) >= 0,
              now.timeIntervalSince(pending.startedAt) < timeout,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == callbackScheme, parts.host == "callback", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 3,
              Set(items.map(\.name)) == Set(["service", "job", "state"]) else { return false }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        return value("service") == pending.service.rawValue && value("job") == pending.jobID && value("state") == pending.state
    }
}

struct PendingOfficeAuthorization: Codable, Equatable {
    let service: ExternalAppService
    let jobID: String
    let state: String
    let startedAt: Date
    let context: String
}

enum OfficeAuthorizationLaunch { case app, web }
enum OfficeAuthorizationPresentationEvent { case callback(URL), closed }

@MainActor
protocol OfficeAuthorizationBackend: AnyObject {
    var authorizationContext: String { get }
    func start(_ service: ExternalAppService, install: Bool) async throws -> OfficeAuthorizationJob
    func poll(_ id: String) async throws -> OfficeAuthorizationJob
    func verifiedStatus(_ service: ExternalAppService) async throws -> OfficeConnectionStatus
    func cancel(_ id: String) async
}

@MainActor
protocol OfficeAuthorizationPresenting: AnyObject {
    func authorizationURL(for job: OfficeAuthorizationJob) async -> URL?
    func open(_ url: URL, callback: URL, event: @escaping @MainActor (OfficeAuthorizationPresentationEvent) -> Void) async throws -> OfficeAuthorizationLaunch
    func dismiss()
}
