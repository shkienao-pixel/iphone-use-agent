import Foundation

/// Shared by the screen executor and native workers. A tool holds only the
/// resources it touches; independent services may make progress concurrently.
@MainActor final class TaskResourceGate {
    private struct Waiter {
        let id: UUID
        let keys: Set<String>
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var held: [UUID: Set<String>] = [:]
    private var waiting: [Waiter] = []

    func withResources<T>(_ keys: Set<String>, operation: () async throws -> T) async throws -> T {
        let lease = try await acquire(keys)
        defer { held.removeValue(forKey: lease); drain() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire(_ keys: Set<String>) async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiting.append(Waiter(id: id, keys: keys, continuation: continuation)); drain()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                self.waiting.remove(at: index).continuation.resume(throwing: CancellationError()); self.drain()
            }
        }
    }
    private func drain() {
        var blocked = Set<String>(), index = 0
        while index < waiting.count {
            let item = waiting[index], busy = held.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            if item.keys.isDisjoint(with: busy), item.keys.isDisjoint(with: blocked) {
                waiting.remove(at: index); held[item.id] = item.keys; item.continuation.resume(returning: item.id)
            } else { blocked.formUnion(item.keys); index += 1 }
        }
    }
    static func resources(for operation: SystemToolRequest.Operation, confirmation: Bool) -> Set<String> {
        let resource: String
        switch operation {
        case .calendar_search, .calendar_create, .reminder_search, .reminder_create: resource = "eventKit"
        case .content_create, .content_prepare_clipboard, .content_status: resource = "content"
        case .music_search, .music_play, .music_pause, .music_resume, .music_status: resource = "music"
        case .contact_search: resource = "contacts"
        case .photo_search: resource = "photos"
        case .alarm_list, .alarm_create: resource = "alarms"
        case .health_query: resource = "health"
        case .location_current: resource = "location"
        case .notes_create: resource = "screen"
        case .ctrip_query: resource = "ctrip"
        case .meituan_query: resource = "meituanTravel"
        case .meituan_paotui: resource = "meituanPaotui"
        }
        return confirmation ? [resource, "toolApproval"] : [resource]
    }
}
