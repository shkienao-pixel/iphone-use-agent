import Foundation

enum NativeAppConnection { case calendar, reminders, contacts, photos, alarm, music, location }
struct NativeConnectionAccess { var ready: Bool }
@MainActor final class NativeConnectionsStore {
    static let shared = NativeConnectionsStore()
    var authorized = true
    func refresh() {}
    func state(_ app: NativeAppConnection) -> NativeConnectionAccess { .init(ready: authorized) }
}
