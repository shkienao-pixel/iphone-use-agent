import Combine
import AlarmKit
import Contacts
import CoreLocation
import EventKit
import HealthKit
import MediaPlayer
import Photos
import PhotosUI
import UIKit

@MainActor
final class NativeConnectionsStore: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = NativeConnectionsStore()
    @Published private(set) var states: [NativeAppConnection: NativeConnectionAccess] = [:]
    @Published private(set) var requesting: NativeAppConnection?
    @Published private(set) var healthAuthorizationPending = false
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    private let events = EKEventStore()
    private let contacts = CNContactStore()
    private lazy var location: CLLocationManager = {
        // Core Location delivers delegate callbacks on this manager's main run loop.
        let manager = CLLocationManager(); manager.delegate = self; return manager
    }()
    private var locationTimeout: Task<Void, Never>?
    private var requestGeneration = UUID()
    private let defaults: UserDefaults = .standard
    var healthConfigured: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        HKHealthStore.isHealthDataAvailable()
        #endif
    }

    func state(_ app: NativeAppConnection) -> NativeConnectionAccess { states[app] ?? .notDetermined }
    var requestedHealthScopes: Set<NativeHealthScope> {
        guard let raw = defaults.stringArray(forKey: "connections.health.allowedScopes") else { return Set(NativeHealthScope.allCases) }
        return Set(raw.compactMap(NativeHealthScope.init(rawValue:)))
    }
    func refresh() {
        states[.notes] = NotesShortcutBridge.shared.configuration == nil ? .unconfigured : .configured
        states[.calendar] = NativeEventAccess.shared.access(.event)
        states[.reminders] = NativeEventAccess.shared.access(.reminder)
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: states[.alarm] = .notDetermined
        case .denied: states[.alarm] = .denied
        case .authorized: states[.alarm] = .authorized
        @unknown default: states[.alarm] = .unavailable
        }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: states[.contacts] = .authorized
        case .limited: states[.contacts] = .limited
        case .denied: states[.contacts] = .denied
        case .restricted: states[.contacts] = .restricted
        default: states[.contacts] = .notDetermined
        }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: states[.photos] = .authorized
        case .limited: states[.photos] = .limited
        case .denied: states[.photos] = .denied
        case .restricted: states[.photos] = .restricted
        default: states[.photos] = .notDetermined
        }
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: states[.music] = .authorized
        case .denied: states[.music] = .denied
        case .restricted: states[.music] = .restricted
        default: states[.music] = .notDetermined
        }
        states[.location] = locationAccess(location.authorizationStatus)
        // HealthKit intentionally does not disclose whether read access was granted.
        states[.health] = healthConfigured ? (defaults.stringArray(forKey: "connections.health.requestedScopes")?.isEmpty == false ? .reviewed : .notDetermined) : .unavailable
    }

    func request(_ app: NativeAppConnection, healthScopes: Set<NativeHealthScope> = Set(NativeHealthScope.allCases)) async {
        guard requesting == nil else { return }
        requesting = app; message = ""; failed = false
        requestGeneration = UUID(); let generation = requestGeneration
        defer { if requesting != .location { requesting = nil }; refresh() }
        do {
            switch app {
            case .notes: throw NotesShortcutError.invalidConfiguration
            case .calendar: _ = try await NativeEventAccess.shared.request(.event)
            case .reminders: _ = try await NativeEventAccess.shared.request(.reminder)
            case .alarm: _ = try await AlarmManager.shared.requestAuthorization()
            case .contacts: _ = try await contacts.requestAccess(for: .contacts)
            case .photos: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            case .music: _ = await MPMediaLibrary.requestAuthorization()
            case .health:
                try await authorizeHealth(healthScopes, updateSelection: true)
            case .location:
                guard location.authorizationStatus == .notDetermined else { refresh(); requesting = nil; return }
                location.requestWhenInUseAuthorization()
                locationTimeout?.cancel()
                locationTimeout = Task {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, requesting == .location, requestGeneration == generation else { return }
                    requesting = nil; message = "请在系统设置中确认位置权限，然后返回此页刷新。"; refresh()
                }
                return
            }
            guard !Task.isCancelled, requestGeneration == generation else { return }
            refresh()
            if app != .health && !state(app).ready {
                failed = true
                message = state(app).needsSettings ? "请在系统设置中允许访问，然后返回自动刷新" : "系统尚未确认授权，请重新允许或打开管理权限"
            } else { failed = false; message = "" }
        } catch is CancellationError {
            requesting = nil; failed = false; message = "已取消授权等待；如系统授权页仍在显示，请先关闭它"
        } catch {
            requesting = nil; failed = true; message = error.localizedDescription
        }
    }

    func resetMessage() { if requesting == nil { message = ""; failed = false } }

    // Only an explicit settings action presents selection UI. Native reads keep
    // using the user's existing limited selection without a reminder each launch.
    func managePhotoSelection() async {
        guard requesting == nil else { return }
        refresh()
        guard state(.photos) == .limited else {
            failed = true; message = "请先在系统中允许有限照片访问，或到管理权限修改授权"; return
        }
        requesting = .photos; message = ""; failed = false
        defer { requesting = nil; refresh() }
        do {
            guard UIApplication.shared.applicationState == .active else { throw AgentError.message("请回到 Sela 前台管理已选照片") }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let root = scenes.filter({ $0.activationState == .foregroundActive })
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
                throw AgentError.message("当前没有可呈现照片选择的窗口")
            }
            var presenter = root
            while let next = presenter.presentedViewController { presenter = next }
            guard !presenter.isBeingDismissed, !presenter.isBeingPresented, presenter.transitionCoordinator == nil else {
                throw AgentError.message("请等当前页面显示完成后再管理照片")
            }
            _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
            guard !Task.isCancelled else { return }
            message = "照片选择已关闭，权限状态已刷新"
        } catch { failed = true; message = error.localizedDescription }
    }

    // Task requests may only use types enabled in the connection page. OS read
    // grants remain private; the saved values are request history, not grants.
    func authorizeHealth(_ scopes: Set<NativeHealthScope>, updateSelection: Bool = false) async throws {
        guard healthConfigured else { throw AgentError.message("当前设备暂不支持健康数据") }
        guard !scopes.isEmpty else { throw AgentError.message("请至少选择一种健康数据") }
        guard updateSelection || scopes.isSubset(of: requestedHealthScopes) else {
            throw AgentError.message("此健康数据类型未启用，请在 App 连接的健康页选择后授权")
        }
        try Task.checkCancellation()
        guard !healthAuthorizationPending else { throw AgentError.message("已有系统健康授权尚未结束，请先处理授权页") }
        try await NativePermissionPresentation.waitUntilReady()
        guard !healthAuthorizationPending else { throw AgentError.message("已有系统健康授权尚未结束，请先处理授权页") }
        let store = HKHealthStore()
        let types = Set(scopes.compactMap(healthType))
        let gate = NativeAuthorizationGate()
        try await gate.wait { completion in
            healthAuthorizationPending = true
            store.requestAuthorization(toShare: [], read: types) { [store] success, error in
                _ = store // Keep this store alive through its authorization callback.
                Task { @MainActor in
                    self.healthAuthorizationPending = false
                    if let error { completion(.failure(error)) }
                    else if success { completion(.success(())) }
                    else { completion(.failure(AgentError.message("健康授权流程未完成，未读取数据"))) }
                }
            }
        }
        try Task.checkCancellation()
        if updateSelection { defaults.set(scopes.map(\.rawValue).sorted(), forKey: "connections.health.allowedScopes") }
        let previous = Set(defaults.stringArray(forKey: "connections.health.requestedScopes") ?? [])
        defaults.set(previous.union(scopes.map(\.rawValue)).sorted(), forKey: "connections.health.requestedScopes")
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        states[.location] = locationAccess(manager.authorizationStatus)
        guard requesting == .location, manager.authorizationStatus != .notDetermined else { return }
        locationTimeout?.cancel(); locationTimeout = nil; requesting = nil
        failed = !state(.location).ready
        message = state(.location).ready ? "" : "未获得位置权限"
    }

    private func eventAccess(_ status: EKAuthorizationStatus) -> NativeConnectionAccess {
        switch status {
        case .fullAccess: .authorized
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    private func locationAccess(_ status: CLAuthorizationStatus) -> NativeConnectionAccess {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    private func healthType(_ scope: NativeHealthScope) -> HKObjectType? {
        switch scope {
        case .steps: HKObjectType.quantityType(forIdentifier: .stepCount)
        case .sleep: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .workouts: HKObjectType.workoutType()
        }
    }
}
