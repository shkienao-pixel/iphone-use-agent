import Foundation
import Combine
import CoreLocation

/// Location, place lookup, and read-only estimates for the ride simulation.
/// Credentials are saved only in this iPhone's Keychain after validation.
/// Precise coordinates remain temporary; this client has no order API.
enum DidiSimulationLocationState: Equatable {
    case idle, locating, ready, failed
}

@MainActor
final class DidiSimulationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    /// The default client uses an ephemeral, non-redirecting URLSession. The
    /// injectable transport lets offline checks exercise the same RPC/parser
    /// and lifecycle guards without importing a credential or contacting DiDi.
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    @Published private(set) var locationState: DidiSimulationLocationState = .idle
    @Published private(set) var locationError = ""
    @Published private(set) var nearbyPlaces: [DidiSimulationPlace] = []
    @Published private(set) var isConfigured = false
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionError = ""
    @Published private(set) var removalNeedsRetry = false
    var hasSavedConnection: Bool { credentialStore.canRestore }

    private static let permittedTools: Set<String> = [
        "maps_textsearch", "maps_regeocode", "maps_place_around", "taxi_estimate"
    ]
    private var credential = ""
    private var endpoint: URL?
    private var availableTools: Set<String> = []
    private var sessionID: String?
    private var connectionID = UUID()
    private var credentialRevision: UUID?
    private var tripID = UUID()
    private let transport: Transport?
    private let credentialStore: any DidiCredentialStoring
    private var credentialChanges: AnyCancellable?
    private var rpcID = 0
    private var searchCache: [String: (place: DidiSimulationPlace, date: Date)] = [:]
    private var locationToken: UUID?
    private var locationStarted = false
    private var locationTimeout: Task<Void, Never>?
    private var locationResolution: Task<Void, Never>?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        return manager
    }()

    override init() {
        transport = nil; credentialStore = DidiConnectionStore.shared; super.init(); observeCredentialChanges()
    }
    init(transport: @escaping Transport, credentialStore: any DidiCredentialStoring) {
        self.transport = transport; self.credentialStore = credentialStore; super.init(); observeCredentialChanges()
    }

    private func observeCredentialChanges() {
        removalNeedsRetry = credentialStore.hasPendingRemoval
        credentialChanges = credentialStore.revisions.sink { [weak self] revision in
            guard let self, let active = self.credentialRevision, active != revision else { return }
            self.suspend()
            self.removalNeedsRetry = self.credentialStore.hasPendingRemoval
            self.connectionError = self.credentialStore.canRestore ? "滴滴连接已更新，请重新连接。" : "滴滴连接已断开。"
        }
    }

    /// Accepts an existing personal MCP key or its official production URL.
    /// Save only the normalized key, after the service and attempt are verified.
    func configure(credential value: String) async throws {
        try await connect(credential: value, restoring: false)
    }

    /// Called on an active card, never from init or a background scheduler.
    /// A temporary failure keeps the saved connection available for retry.
    func restoreSavedConnection() async {
        guard !isConfigured, !isConnecting else { return }
        do {
            try Task.checkCancellation()
            if credentialStore.hasPendingRemoval {
                removalNeedsRetry = true; connectionError = DidiCredentialStoreError.remove.localizedDescription
                return
            }
            guard let value = try credentialStore.load() else { return }
            try Task.checkCancellation()
            try await connect(credential: value, restoring: true)
        } catch is CancellationError { }
        catch { connectionError = safe(error).localizedDescription }
    }

    private func connect(credential value: String, restoring: Bool) async throws {
        try Task.checkCancellation()
        let parsed = try Self.connection(value)
        let revision = restoring ? credentialStore.revision : credentialStore.beginConnectionAttempt()
        resetTripData()
        let attempt = UUID()
        connectionID = attempt
        credentialRevision = revision
        isConfigured = false
        isConnecting = true; connectionError = ""
        credential = parsed.key
        endpoint = parsed.url
        sessionID = nil
        availableTools = []
        do {
            let result = try await rpc("tools/list", params: [:], connection: attempt)
            guard let definitions = result["tools"] as? [[String: Any]] else {
                throw Failure.message("滴滴没有返回可用服务列表，请重新连接。")
            }
            let names = Set(definitions.compactMap { $0["name"] as? String })
            let required: Set<String> = ["maps_textsearch", "maps_regeocode", "taxi_estimate"]
            guard required.isSubset(of: names) else {
                throw Failure.message("当前滴滴连接未开放地点搜索、地址解析或真实询价，请核对 MCP 权益。")
            }
            try Task.checkCancellation()
            guard connectionID == attempt, credentialStore.revision == revision else { throw CancellationError() }
            if !restoring { try credentialStore.save(parsed.key, revision: revision) }
            availableTools = names.intersection(Self.permittedTools)
            isConfigured = true; isConnecting = false; removalNeedsRetry = false
        } catch {
            if connectionID == attempt {
                credential = ""; endpoint = nil; sessionID = nil
                credentialRevision = nil; availableTools = []; searchCache = [:]; isConfigured = false; isConnecting = false
                if !(error is CancellationError) { connectionError = safe(error).localizedDescription }
            }
            throw safe(error)
        }
    }

    /// Explicit removal revokes every card before attempting Keychain deletion.
    func disconnect() {
        suspend()
        do { try credentialStore.remove(); removalNeedsRetry = false }
        catch { connectionError = safe(error).localizedDescription; removalNeedsRetry = true }
    }

    /// Ordinary navigation ends transient work but preserves the saved key.
    func suspend() {
        connectionID = UUID()
        resetTripData()
        credential = ""; endpoint = nil; sessionID = nil
        credentialRevision = nil; availableTools = []; isConfigured = false; isConnecting = false; connectionError = ""
    }

    /// Start an empty itinerary in the same connected card. A new trip epoch
    /// also rejects late search/quote results even if their caller did not
    /// cooperate with cancellation. The current connection remains available;
    /// saved credentials are independent of temporary itinerary data.
    func resetTripData() {
        tripID = UUID()
        if let token = locationToken { endLocation(token) }
        locationState = .idle; locationError = ""; nearbyPlaces = []
        searchCache = [:]
    }

    /// Only called by an explicit location button in Sela. No continuous tracking.
    func requestLocation() {
        guard locationState != .locating else { return }
        guard isConfigured, credentialRevision == credentialStore.revision else {
            locationState = .failed
            locationError = "请先连接滴滴，再使用设备位置。你也可以搜索上车地址。"
            nearbyPlaces = []
            return
        }
        locationToken = UUID()
        locationStarted = false
        locationState = .locating
        locationError = ""
        nearbyPlaces = []
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            beginLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationToken != nil else { return }
        beginLocation()
    }

    private func beginLocation() {
        guard let token = locationToken else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            guard !locationStarted else { return }
            locationStarted = true
            // Permission-sheet time is not acquisition time. The one-shot
            // request and its address lookup share a bounded 30-second window.
            locationTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.locationToken == token else { return }
                self.finishLocation(token, error: "定位超时，请检查位置服务，或直接搜索上车地址。")
            }
            locationManager.requestLocation()
        case .denied, .restricted:
            finishLocation(token, error: "没有位置访问权限。请在系统设置中允许，或直接搜索上车地址。")
        case .notDetermined:
            break
        @unknown default:
            finishLocation(token, error: "暂时无法获取位置权限，请直接搜索上车地址。")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let token = locationToken, locationStarted, locationResolution == nil else { return }
        guard let location = locations.last(where: {
            CLLocationCoordinate2DIsValid($0.coordinate) && $0.coordinate.latitude.isFinite && $0.coordinate.longitude.isFinite &&
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 3_000 &&
            $0.timestamp.timeIntervalSinceNow >= -30 && $0.timestamp.timeIntervalSinceNow < 5
        }) else {
            finishLocation(token, error: "没有获得有效的新位置，请重试或搜索上车地址。")
            return
        }
        manager.stopUpdatingLocation()
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        locationResolution = Task { [weak self] in
            guard let self else { return }
            do {
                let place = try await self.resolvePlace(latitude: latitude, longitude: longitude)
                try Task.checkCancellation()
                var choices = [place]
                if self.availableTools.contains("maps_place_around") {
                    do {
                        let excluded = ["内部", "专用", "禁止", "禁停", "停车场", "员工", "货运", "物流",
                                        "车库", "卸货", "消防", "施工", "封闭", "私人", "专属"]
                        @MainActor func nearby(_ keyword: String, radius: String) async throws -> [DidiSimulationPlace] {
                            let result = try await self.call("maps_place_around", arguments: [
                                "keywords": keyword, "location": Self.coordinateText(latitude: latitude, longitude: longitude),
                                "max_distance": radius
                            ])
                            return try self.places(in: result, city: place.city, searchVerified: false).filter { candidate in
                                let text = candidate.name + " " + candidate.detail
                                return !excluded.contains(where: text.contains)
                            }
                        }
                        // Generic entrances include private and restricted car parks.
                        // Prefer explicit pickup places, then public transit entrances;
                        // an empty result leaves only the manually selectable location.
                        var candidates = try await nearby("上车点", radius: "1000")
                        if candidates.isEmpty { candidates = try await nearby("地铁站出入口", radius: "1500") }
                        choices += candidates.prefix(4)
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* A verified address remains usable if nearby lookup is unavailable. */ }
                }
                try Task.checkCancellation()
                guard self.locationToken == token else { return }
                var seen: Set<String> = []
                self.nearbyPlaces = choices.filter { seen.insert($0.id).inserted }.prefix(5).map { $0 }
                self.locationState = .ready
                self.locationError = ""
                self.endLocation(token)
            } catch {
                guard self.locationToken == token else { return }
                self.finishLocation(token, error: self.safe(error).localizedDescription)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let token = locationToken else { return }
        finishLocation(token, error: "设备暂时没有返回位置。请检查位置服务，或直接搜索上车地址。")
    }

    private func finishLocation(_ token: UUID, error: String) {
        guard locationToken == token else { return }
        locationState = .failed
        locationError = error
        nearbyPlaces = []
        endLocation(token)
    }

    private func endLocation(_ token: UUID) {
        guard locationToken == token else { return }
        locationToken = nil; locationStarted = false
        locationManager.stopUpdatingLocation()
        locationTimeout?.cancel(); locationTimeout = nil
        locationResolution?.cancel(); locationResolution = nil
    }

    func searchPlaces(_ query: String, city: String, near: DidiSimulationPlace? = nil) async throws -> [DidiSimulationPlace] {
        let trip = tripID
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200 else { throw Failure.message("请输入要查找的地点名称或地址。") }
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty, city.count <= 100 else { throw Failure.message("请填写地点所在城市后再搜索。") }
        var arguments: [String: Any] = ["keywords": query, "city": city]
        if let near, Self.valid(latitude: near.latitude, longitude: near.longitude) {
            arguments["location"] = Self.coordinateText(latitude: near.latitude, longitude: near.longitude)
        }
        do {
            let result = try await call("maps_textsearch", arguments: arguments)
            guard trip == tripID else { throw CancellationError() }
            let found = try places(in: result, city: city, searchVerified: true)
            let now = Date()
            searchCache = searchCache.filter { now.timeIntervalSince($0.value.date) <= 600 }
            if searchCache.count + found.count > 200 { searchCache = [:] }
            for place in found { searchCache[place.id] = (place, now) }
            return found
        } catch { throw safe(error) }
    }

    func resolvePlace(latitude: Double, longitude: Double) async throws -> DidiSimulationPlace {
        let trip = tripID
        guard Self.valid(latitude: latitude, longitude: longitude) else { throw Failure.message("这个地图位置无效，请重新选点。") }
        do {
            let result = try await call("maps_regeocode", arguments: ["location": Self.coordinateText(latitude: latitude, longitude: longitude)])
            guard trip == tripID else { throw CancellationError() }
            var found = try places(in: result, city: "", searchVerified: false)
            // Some reverse-geocoding payloads return an address but omit the
            // requested coordinate. Reusing the exact requested point is valid
            // here; loadCars still resolves it through maps_textsearch first.
            if found.isEmpty, let address = reverseAddress(in: result) {
                found = [.init(id: "didi-reverse-\(longitude),\(latitude)", name: address.name, detail: address.detail,
                               latitude: latitude, longitude: longitude, city: address.city, verifiedByDidi: false)]
            }
            guard let place = found.first else { throw Failure.message("滴滴暂时没有识别这个位置，请移动地图或搜索地点。") }
            return place
        } catch { throw safe(error) }
    }

    func loadCars(from: DidiSimulationPlace, to: DidiSimulationPlace, stops: [DidiSimulationPlace]) async throws -> [DidiSimulationCar] {
        let trip = tripID
        do {
            let origin = try await estimatePlace(from)
            let destination = try await estimatePlace(to)
            let result = try await call("taxi_estimate", arguments: [
                "from_lng": Self.number(origin.longitude), "from_lat": Self.number(origin.latitude), "from_name": origin.name,
                "to_lng": Self.number(destination.longitude), "to_lat": Self.number(destination.latitude), "to_name": destination.name
            ])
            guard trip == tripID else { throw CancellationError() }
            guard let structured = result["structuredContent"] as? [String: Any],
                  let items = structured["items"] as? [[String: Any]] else {
                throw Failure.message("滴滴没有返回结构化车型信息，请重新询价。")
            }
            var seen: Set<String> = []
            let cars = items.prefix(60).compactMap { item -> DidiSimulationCar? in
                guard let category = field(item["productCategory"]), !category.isEmpty,
                      let name = field(item["productName"]), !name.isEmpty,
                      seen.insert(category).inserted else { return nil }
                return .init(id: category, name: name,
                             detail: stops.isEmpty ? "滴滴实时预估" : "直达预估，未计经停", priceText: field(item["priceText"]) ?? "")
            }
            guard !cars.isEmpty else { throw Failure.message("滴滴本次没有返回可用车型，请修改地址或稍后重试。") }
            return cars
        } catch { throw safe(error) }
    }

    /// An externally constructed `verifiedByDidi` flag alone is insufficient:
    /// only a recent result from this connection's own text search is reused.
    private func estimatePlace(_ place: DidiSimulationPlace) async throws -> DidiSimulationPlace {
        if place.verifiedByDidi, let cached = searchCache[place.id], Date().timeIntervalSince(cached.date) <= 600,
           cached.place.name == place.name, cached.place.latitude == place.latitude, cached.place.longitude == place.longitude {
            return cached.place
        }
        throw Failure.message("请搜索并选择滴滴返回的准确地点，再查询车型；地图选点和定位附近地点需先搜索确认。")
    }

    private func call(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard isConfigured, Self.permittedTools.contains(name), availableTools.contains(name) else {
            throw Failure.message("请先连接滴滴，并确认已开通地点和询价服务。")
        }
        let result = try await rpc("tools/call", params: ["name": name, "arguments": arguments], connection: connectionID)
        guard result["isError"] as? Bool != true else { throw Failure.message("滴滴本次查询未成功，请核对地址或稍后重试。") }
        return result
    }

    private func rpc(_ method: String, params: [String: Any], connection: UUID) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard connection == connectionID, let revision = credentialRevision,
              revision == credentialStore.revision else { throw CancellationError() }
        guard let endpoint,
              method == "tools/list" || (method == "tools/call" && (params["name"] as? String).map(Self.permittedTools.contains) == true) else {
            throw Failure.message("滴滴连接暂不可用，请重新连接。")
        }
        rpcID += 1
        let id = rpcID
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        do {
            let loaded: (Data, HTTPURLResponse)
            if let transport { loaded = try await transport(request) }
            else { loaded = try await Self.load(request) }
            let (data, response) = loaded
            try Task.checkCancellation()
            guard connection == connectionID, credentialRevision == revision,
                  credentialStore.revision == revision else { throw CancellationError() }
            guard response.url == endpoint, (200...299).contains(response.statusCode) else {
                switch response.statusCode {
                case 401, 403: throw Failure.message("滴滴授权未通过，请检查 MCP Key 和权益。")
                case 429: throw Failure.message("滴滴查询较频繁，请稍后重试。")
                default: throw Failure.message("滴滴连接暂时未完成，请检查网络或稍后重试。")
                }
            }
            if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !value.isEmpty,
               value.utf8.count <= 4_096, value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) { sessionID = value }
            let object = try MeituanMCPClient.decode(data)
            guard (object["id"] as? NSNumber)?.intValue == id else { throw Failure.message("滴滴返回的查询结果不完整，请重试。") }
            if let error = object["error"] as? [String: Any] {
                switch (error["code"] as? NSNumber)?.intValue {
                case -32001: throw Failure.message("滴滴查询较频繁，请稍后重试。")
                case -32002: throw Failure.message("滴滴授权未通过，请检查 MCP Key 和权益。")
                case -32010: throw Failure.message("滴滴未接受这个地址参数，请重新搜索地点。")
                default: throw Failure.message("滴滴本次查询未成功，请稍后重试。")
                }
            }
            guard let result = object["result"] as? [String: Any] else { throw Failure.message("滴滴没有返回可用查询结果。") }
            return result
        } catch { throw safe(error) }
    }

    private static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: DidiSimulationNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.message("滴滴未返回有效响应。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw Failure.message("滴滴返回信息过多，请缩小查询范围。") }
            data.append(byte)
            if byte == 10, let text = String(data: data, encoding: .utf8),
               (text.hasSuffix("\n\n") || text.hasSuffix("\r\n\r\n")), (try? MeituanMCPClient.decode(data)) != nil { break }
        }
        return (data, response)
    }

    private func places(in result: [String: Any], city: String, searchVerified: Bool) throws -> [DidiSimulationPlace] {
        let payloads = try payloads(in: result)
        var objects: [[String: Any]] = []
        func collect(_ value: Any, depth: Int) {
            guard depth < 7, objects.count < 100 else { return }
            if let array = value as? [Any] {
                for item in array.prefix(100) { collect(item, depth: depth + 1) }
            } else if let object = value as? [String: Any] {
                if Self.coordinates(object) != nil, object["display_name"] != nil || object["name"] != nil || object["poi_name"] != nil || object["formatted_address"] != nil {
                    objects.append(object)
                }
                for key in ["pois", "results", "items", "data", "result", "addresses", "locations", "regeocode"] {
                    if let nested = object[key] { collect(nested, depth: depth + 1) }
                }
            }
        }
        payloads.forEach { collect($0, depth: 0) }
        var seen: Set<String> = []
        return objects.compactMap { object -> DidiSimulationPlace? in
            guard let coordinate = Self.coordinates(object),
                  let name = field(object["display_name"] ?? object["name"] ?? object["poi_name"] ?? object["formatted_address"]), !name.isEmpty else { return nil }
            let detail = field(object["address_all"] ?? object["address"] ?? object["formatted_address"]) ?? name
            let placeCity = field(object["city"]) ?? city
            let id = field(object["poi_id"] ?? object["id"]) ?? "didi-\(coordinate.longitude),\(coordinate.latitude)-\(name)"
            guard seen.insert(id).inserted else { return nil }
            return .init(id: id, name: name, detail: detail, latitude: coordinate.latitude, longitude: coordinate.longitude,
                         city: placeCity.isEmpty ? city : placeCity, verifiedByDidi: searchVerified)
        }
    }

    private func reverseAddress(in result: [String: Any]) -> (name: String, detail: String, city: String)? {
        guard let payloads = try? payloads(in: result) else { return nil }
        func find(_ value: Any, depth: Int) -> (name: String, detail: String, city: String)? {
            guard depth < 7 else { return nil }
            if let array = value as? [Any] {
                for item in array.prefix(20) { if let found = find(item, depth: depth + 1) { return found } }
            } else if let object = value as? [String: Any] {
                let name = field(object["display_name"] ?? object["name"] ?? object["poi_name"] ?? object["formatted_address"] ?? object["address_all"] ?? object["address"])
                if let name, !name.isEmpty {
                    return (name, field(object["address_all"] ?? object["formatted_address"] ?? object["address"]) ?? name,
                            field(object["city"]) ?? "")
                }
                for key in ["data", "result", "regeocode", "results", "address", "addressComponent"] {
                    if let nested = object[key], let found = find(nested, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        for payload in payloads { if let found = find(payload, depth: 0) { return found } }
        return nil
    }

    private func payloads(in result: [String: Any]) throws -> [Any] {
        var values: [Any] = []
        if let structured = result["structuredContent"] { values.append(structured) }
        for content in (result["content"] as? [[String: Any]] ?? []).prefix(10) {
            guard let text = content["text"] as? String, text.utf8.count <= 1_048_576,
                  let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            values.append(value)
        }
        guard !values.isEmpty else { throw Failure.message("滴滴没有返回可读取的地点信息，请换一个关键词。") }
        for value in values {
            if let object = value as? [String: Any], let code = (object["status"] ?? object["code"]) as? NSNumber,
               ![0, 200, 10000].contains(code.intValue) {
                throw Failure.message("滴滴地点查询暂时未成功，请稍后重试。")
            }
        }
        return values
    }

    /// Host-owned errors only. Do not propagate URLs, RPC text, or URLSession
    /// descriptions, which may contain the key-bearing endpoint.
    private func safe(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let failure = error as? Failure { return failure }
        if let failure = error as? DidiCredentialStoreError { return failure }
        return Failure.message("滴滴暂时无法连接，请检查网络，或稍后重试。")
    }

    private func field(_ value: Any?) -> String? {
        let text: String
        if let value = value as? String { text = value }
        else if let value = value as? NSNumber { text = value.stringValue }
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 1_000, credential.isEmpty || !trimmed.contains(credential),
              !trimmed.lowercased().contains("key="), !trimmed.lowercased().contains("https://") else { return nil }
        return trimmed
    }

    private static func connection(_ value: String) throws -> (key: String, url: URL) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8_192,
              !trimmed.contains("\n"), !trimmed.contains("\r") else { throw Failure.message("请填写有效的滴滴 MCP Key。") }
        let key: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == "mcp.didichuxing.com", components.port == nil || components.port == 443,
                  components.user == nil, components.password == nil, components.fragment == nil,
                  components.path == "/mcp-servers", let items = components.queryItems, items.count == 1,
                  items[0].name == "key", let value = items[0].value else {
                throw Failure.message("请使用滴滴官方的生产 MCP 地址或个人 MCP Key。")
            }
            key = value
        } else { key = trimmed }
        guard !key.isEmpty, key.utf8.count <= 4_096,
              key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw Failure.message("滴滴 MCP Key 格式不正确。") }
        var components = URLComponents()
        components.scheme = "https"; components.host = "mcp.didichuxing.com"; components.path = "/mcp-servers"
        components.queryItems = [.init(name: "key", value: key)]
        guard let url = components.url else { throw Failure.message("无法创建滴滴连接，请重新填写。") }
        return (key, url)
    }

    private static func number(_ value: Double) -> String { String(value) }
    private static func coordinateText(latitude: Double, longitude: Double) -> String { number(longitude) + "," + number(latitude) }
    private static func valid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude))
    }
    private static func coordinates(_ object: [String: Any]) -> (latitude: Double, longitude: Double)? {
        func numeric(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }
        let latitude: Double?, longitude: Double?
        if let location = object["location"] as? [String: Any] {
            latitude = numeric(location["lat"] ?? location["latitude"])
            longitude = numeric(location["lng"] ?? location["lon"] ?? location["longitude"])
        } else if let location = object["location"] as? String {
            let parts = location.split(separator: ",").map(String.init)
            guard parts.count == 2 else { return nil }
            longitude = Double(parts[0]); latitude = Double(parts[1])
        } else {
            latitude = numeric(object["lat"] ?? object["latitude"])
            longitude = numeric(object["lng"] ?? object["lon"] ?? object["longitude"])
        }
        guard let latitude, let longitude, valid(latitude: latitude, longitude: longitude) else { return nil }
        return (latitude, longitude)
    }
    private static func normalized(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}

private final class DidiSimulationNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
