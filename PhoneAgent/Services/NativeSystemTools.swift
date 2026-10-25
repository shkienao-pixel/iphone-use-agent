import CoreLocation
import HealthKit
import MediaPlayer
import UIKit

@MainActor
final class NativeSystemTools {
    static let shared = NativeSystemTools()
    private let health = HKHealthStore()
    private let location = NativeLocationReader()
    private lazy var player = MPMusicPlayerController.applicationMusicPlayer

    func execute(_ request: SystemToolRequest) async throws -> String {
        try request.validate(); try Task.checkCancellation()
        try await NativeForegroundGate.waitUntilActive { UIApplication.shared.applicationState == .active }
        switch request.operation {
        case .health_query:
            let scope = NativeHealthScope(rawValue: request.query!)!
            try await NativeConnectionsStore.shared.authorizeHealth([scope])
            try Task.checkCancellation()
            return try await healthResult(scope, from: SystemToolRequest.date(request.start)!, to: SystemToolRequest.date(request.end)!,
                                          startText: request.start!, endText: request.end!)
        case .location_current:
            return try await location.read()
        case .music_search, .music_play, .music_pause, .music_resume, .music_status:
            #if targetEnvironment(simulator)
            throw AgentError.message("当前设备暂不支持音乐播放")
            #else
            let status = MPMediaLibrary.authorizationStatus()
            if status == .notDetermined { _ = await MPMediaLibrary.requestAuthorization() }
            guard MPMediaLibrary.authorizationStatus() == .authorized else { throw AgentError.message("没有音乐资料库访问权限，请在系统设置中允许") }
            try Task.checkCancellation()
            return try await musicResult(request)
            #endif
        default: throw AgentError.message("不支持的原生服务操作")
        }
    }

    private func healthResult(_ scope: NativeHealthScope, from: Date, to: Date, startText: String, endText: String) async throws -> String {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        // Preserve the exact supplied bounds, including fractional seconds;
        // the same parsed instants are used in the actual HealthKit predicate.
        var result: [String: Any] = ["source": "HealthKit", "type": scope.rawValue, "start": startText, "end": endText,
            "coverage": "visible_data_only", "notice": "空结果不能区分未允许读取和没有记录；结果不保证覆盖全部来源。"]
        switch scope {
        case .steps:
            let type = HKQuantityType.quantityType(forIdentifier: .stepCount)!
            let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum)
            let statistics = try await descriptor.result(for: health)
            result["steps"] = statistics?.sumQuantity().map { Int($0.doubleValue(for: .count()).rounded()) } as Any? ?? NSNull()
            result["has_visible_data"] = statistics?.sumQuantity() != nil
        case .sleep:
            let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
            let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\HKCategorySample.startDate, order: .reverse)], limit: 1001)
            let samples = try await descriptor.result(for: health)
            let asleepValues: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
            let intervals = samples.prefix(1000).filter { asleepValues.contains($0.value) }.map { DateInterval(start: $0.startDate, end: $0.endDate) }
            result["asleep_seconds"] = intervals.isEmpty ? NSNull() : NativeToolData.sleepSeconds(intervals, within: DateInterval(start: from, end: to))
            result["visible_sample_count"] = min(samples.count, 1000)
            result["truncated"] = samples.count > 1000
            result["overlapping_intervals_merged"] = true
        case .workouts:
            let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)],
                sortDescriptors: [SortDescriptor(\HKWorkout.startDate, order: .reverse)], limit: 21)
            let samples = try await descriptor.result(for: health)
            result["matches"] = samples.prefix(20).map { sample in
                ["activity_type": sample.workoutActivityType.rawValue, "start": iso(sample.startDate), "end": iso(sample.endDate),
                 "duration_seconds": sample.duration] as [String: Any]
            }
            result["returned_count"] = min(samples.count, 20)
            result["truncated"] = samples.count > 20
        }
        try Task.checkCancellation()
        return try encode(result)
    }

    private func musicResult(_ request: SystemToolRequest) async throws -> String {
        switch request.operation {
        case .music_search:
            let items = MPMediaQuery.songs().items ?? []
            let matches = items.prefix(5000).filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(request.query!) || ($0.artist ?? "").localizedCaseInsensitiveContains(request.query!)
            }
            return try encode(["source": "Music library", "matches": matches.prefix(20).map(track), "returned_count": min(matches.count, 20),
                "truncated": items.count > 5000 || matches.count > 20, "catalog_search": false])
        case .music_play:
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: UInt64(request.query!)!), forProperty: MPMediaItemPropertyPersistentID))
            guard let item = query.items?.first, item.persistentID > 0, item.title == request.title else { throw AgentError.message("歌曲编号和标题不匹配或歌曲已不在资料库，请重新搜索") }
            player.setQueue(with: MPMediaItemCollection(items: [item]))
            try await player.prepareToPlay()
            try Task.checkCancellation()
            player.play()
            await waitForPlayback(.playing)
        case .music_pause:
            player.pause(); await waitForPlayback(.paused)
        case .music_resume:
            guard player.nowPlayingItem != nil else { throw AgentError.message("Sela 没有可继续的播放队列，请先搜索并播放歌曲") }
            player.play(); await waitForPlayback(.playing)
        case .music_status: break
        default: throw AgentError.message("不支持的音乐操作")
        }
        // Observe the OS state; never call a dispatched play command a success.
        let state: String
        switch player.playbackState {
        case .playing: state = "playing"
        case .paused: state = "paused"
        case .stopped: state = "stopped"
        case .interrupted: state = "interrupted"
        case .seekingForward, .seekingBackward: state = "seeking"
        @unknown default: state = "unknown"
        }
        var object: [String: Any] = ["source": "Sela Music player", "state": state, "queue_owner": "Sela", "position_seconds": max(0, player.currentPlaybackTime)]
        if let item = player.nowPlayingItem { object["track"] = track(item) }
        if request.operation.changesPlayback {
            object["command"] = request.operation.rawValue
            object["confirmed"] = request.operation == .music_pause ? player.playbackState == .paused : player.playbackState == .playing
        }
        return try encode(object)
    }
    private func waitForPlayback(_ expected: MPMusicPlaybackState) async {
        for _ in 0..<20 {
            if player.playbackState == expected || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    private func track(_ item: MPMediaItem) -> [String: Any] {
        ["id": String(item.persistentID), "title": item.title ?? "", "artist": item.artist ?? "", "album": item.albumTitle ?? "", "duration_seconds": item.playbackDuration]
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

@MainActor
private final class NativeLocationReader: NSObject, @preconcurrency CLLocationManagerDelegate {
    private lazy var manager: CLLocationManager = {
        let value = CLLocationManager(); value.delegate = self; value.desiredAccuracy = kCLLocationAccuracyHundredMeters; return value
    }()
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var token: UUID?
    private var started = false

    func read() async throws -> String {
        guard continuation == nil else { throw AgentError.message("已有一次定位正在进行") }
        let id = UUID(); token = id; started = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { result in
                continuation = result
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
                else { begin() }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.token == id { self?.finish(.failure(CancellationError())) } } }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { if continuation != nil { begin() } }
    private func begin() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard !started, let id = token else { return }; started = true
            // A system permission sheet is not a failed acquisition. Start the
            // deadline after permission is resolved, so returning from it does
            // not require the user to submit or confirm the task again.
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, self?.token == id else { return }
                self?.finish(.failure(AgentError.message("定位超时，请检查位置服务后重试")))
            }
            manager.requestLocation()
        case .denied, .restricted: finish(.failure(AgentError.message("没有位置访问权限，请在系统设置中允许")))
        case .notDetermined: break
        @unknown default: finish(.failure(AgentError.message("无法确定位置权限")))
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last(where: { $0.horizontalAccuracy >= 0 && $0.timestamp.timeIntervalSinceNow > -120 && $0.timestamp.timeIntervalSinceNow < 5 }) else {
            finish(.failure(AgentError.message("未获得有效的新位置，请重试"))); return
        }
        let object: [String: Any] = ["source": "CoreLocation", "latitude": NativeToolData.approximateCoordinate(value.coordinate.latitude),
            "longitude": NativeToolData.approximateCoordinate(value.coordinate.longitude), "accuracy_metres": max(150, value.horizontalAccuracy),
            "timestamp": ISO8601DateFormatter().string(from: value.timestamp), "approximate": true, "continuous_tracking": false]
        do { finish(.success(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))) }
        catch { finish(.failure(error)) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(.failure(error)) }
    private func finish(_ value: Result<String, Error>) {
        let pending = continuation; continuation = nil; token = nil; started = false
        timeout?.cancel(); timeout = nil; manager.stopUpdatingLocation(); pending?.resume(with: value)
    }
}
