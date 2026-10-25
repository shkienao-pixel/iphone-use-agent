import Foundation
import EventKit
import UIKit

/// One source of truth for connection pages and task tools. EventKit may finish
/// its grant callback before its static status query catches up.
@MainActor final class NativeEventAccess {
    static let shared = NativeEventAccess()
    private var grants: [EKEntityType: Bool] = [:]
    private(set) var diagnostics: [String: String] = [:]
    func access(_ type: EKEntityType) -> NativeConnectionAccess {
        let status = EKEventStore.authorizationStatus(for: type)
        switch status {
        case .fullAccess: grants[type] = true; return .authorized
        case .writeOnly: grants[type] = nil; return .writeOnly
        case .denied: grants[type] = nil; return .denied
        case .restricted: grants[type] = nil; return .restricted
        default: return grants[type] == true ? .authorized : .notDetermined
        }
    }
    func request(_ type: EKEntityType) async throws -> Bool {
        guard UIApplication.shared.applicationState == .active else { throw AgentError.message("请回到 Sela 前台再允许访问") }
        let key = type == .event ? "calendar" : "reminders"
        if access(type) == .authorized { return true }
        let store = EKEventStore()
        do {
            let granted = type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
            grants[type] = granted
            store.reset()
            for _ in 0..<5 {
                if EKEventStore.authorizationStatus(for: type) == .fullAccess { break }
                try await Task.sleep(for: .milliseconds(120))
            }
            diagnostics[key] = "callback=\(granted); status=\(EKEventStore.authorizationStatus(for: type).rawValue)"
            return access(type) == .authorized
        } catch {
            let value = error as NSError
            diagnostics[key] = "domain=\(value.domain); code=\(value.code); status=\(EKEventStore.authorizationStatus(for: type).rawValue)"
            throw error
        }
    }
}
