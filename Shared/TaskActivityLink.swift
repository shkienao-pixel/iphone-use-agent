import Foundation

/// Opening a receipt only selects its saved task; it never grants execution authority.
enum TaskActivityLink {
    static func url(taskID: UUID) -> URL {
        var parts = URLComponents()
        parts.scheme = "phoneagent"
        parts.host = "task"
        parts.queryItems = [URLQueryItem(name: "id", value: taskID.uuidString)]
        return parts.url!
    }

    static func taskID(from url: URL) -> UUID? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "phoneagent", parts.host == "task", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 1, items[0].name == "id",
              let value = items[0].value else { return nil }
        return UUID(uuidString: value)
    }
}
