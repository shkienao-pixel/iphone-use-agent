import Foundation
import Combine

/// Process-local ownership for chat preview anchors. No ride payload or
/// credentials are retained here, and archives never restart a simulation.
@MainActor
final class DidiChatSimulationRegistry: ObservableObject {
    static let shared = DidiChatSimulationRegistry()
    @Published private var owners: [UUID: UUID] = [:]
    @Published private var requests: [UUID: String] = [:]

    func begin(sessionID: UUID, conversationID: UUID, request: String = "") {
        guard owners[sessionID] != conversationID else { return }
        requests[sessionID] = String(request.prefix(4000))
        owners[sessionID] = conversationID
    }

    func request(sessionID: UUID) -> String { requests[sessionID] ?? "" }

    func appendRequest(_ text: String, sessionID: UUID, conversationID: UUID) -> Bool {
        guard contains(sessionID: sessionID, conversationID: conversationID), let existing = requests[sessionID] else { return false }
        let combined = existing + "\n用户补充：" + text
        guard combined.count <= 4000 else { return false }
        requests[sessionID] = combined
        return true
    }

    func contains(sessionID: UUID, conversationID: UUID) -> Bool {
        owners[sessionID] == conversationID
    }

    func end(sessionID: UUID) {
        guard owners[sessionID] != nil else { return }
        owners.removeValue(forKey: sessionID)
        requests.removeValue(forKey: sessionID)
    }

    func end(conversationID: UUID) {
        guard owners.values.contains(conversationID) else { return }
        let expired = owners.filter { $0.value == conversationID }.map(\.key)
        for id in expired { requests.removeValue(forKey: id) }
        owners = owners.filter { $0.value != conversationID }
    }
}

/// A conservative draft only; every location still needs a search and explicit selection.
struct DidiRequestHints: Equatable {
    var pickup: String = ""
    var destination: String = ""

    init(_ request: String) {
        guard !request.contains("\n用户补充：") else { return }
        let pattern = #"从([^，。！？；\n]{1,50}?)(?:到|前往)([^，。！？；\n]{1,50})"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
              let pickupRange = Range(match.range(at: 1), in: request),
              let destinationRange = Range(match.range(at: 2), in: request) else { return }
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: #"(?:帮我|请|我要|我想)?(?:打车|叫车|坐车|乘车).*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let start = clean(String(request[pickupRange])), end = clean(String(request[destinationRange]))
        guard !start.isEmpty, !end.isEmpty, start.count <= 50, end.count <= 50 else { return }
        pickup = start; destination = end
    }
}
