import Foundation
import CoreLocation

// Only the host's JSON envelope decoder is replaced. The production service,
// domain price presentation, cache guards and registry are compiled unchanged.
// Every RPC below uses an in-memory transport; no request reaches a network.
enum MeituanMCPClient {
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "offline-envelope", code: 1)
        }
        return value
    }
}

@MainActor final class OfflineMCP {
    var calledTools: [String] = []
    var cars: [[String: Any]] = [
        ["productCategory": "unknown", "productName": "价格未返回"],
        ["productCategory": "zero", "productName": "明确零价", "priceText": "0"],
        ["productCategory": "known", "productName": "快车", "priceText": "63"]
    ]
    var holdMethod: String?
    var gate: CheckedContinuation<Void, Never>?
    var invalidJSON = false
    var toolError = false

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let method = body["method"] as! String
        let params = body["params"] as? [String: Any] ?? [:]
        let operation = method == "tools/call" ? params["name"] as! String : method
        if operation == holdMethod { await withCheckedContinuation { gate = $0 } }
        let result: [String: Any]
        switch operation {
        case "tools/list":
            result = ["tools": ["maps_textsearch", "maps_regeocode", "taxi_estimate", "taxi_order", "taxi_pay"].map { ["name": $0] }]
        case "maps_textsearch":
            calledTools.append(operation)
            result = ["structuredContent": ["pois": [
                ["id": "public-a", "name": "公共测试地点A", "address": "测试城市公开地点A", "city": "测试市", "location": "121.4,31.2"],
                ["id": "public-b", "name": "公共测试地点B", "address": "测试城市公开地点B", "city": "测试市", "location": "121.5,31.3"]
            ]]]
        case "taxi_estimate":
            calledTools.append(operation)
            result = toolError ? ["isError": true] : ["structuredContent": ["items": cars]]
        default: fatalError("An unexpected or order-related tool was invoked")
        }
        let data = invalidJSON ? Data("not-json".utf8) : try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func release() { let pending = gate; gate = nil; holdMethod = nil; pending?.resume() }
}

@main struct DidiChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ title: String) {
            precondition(condition(), title); checks += 1; print("PASS: " + title)
        }
        func rejected(_ title: String, contains text: String? = nil, _ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure(title) }
            catch {
                if let text { check(error.localizedDescription.contains(text), title) }
                else { checks += 1; print("PASS: " + title) }
            }
        }
        func cancelled(_ title: String, _ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure(title) }
            catch is CancellationError { checks += 1; print("PASS: " + title) }
            catch { preconditionFailure("Expected cancellation: " + title) }
        }
        func waitForGate(_ fake: OfflineMCP) async {
            for _ in 0..<500 {
                if fake.gate != nil { return }
                await Task.yield()
            }
            preconditionFailure("Offline request did not reach the controlled gate")
        }

        let unconfigured = DidiSimulationService()
        check(!unconfigured.isConfigured && unconfigured.nearbyPlaces.isEmpty, "new card has no connection or nearby place")
        await rejected("city is required", contains: "城市") {
            _ = try await unconfigured.searchPlaces("人民广场", city: "")
        }
        let fake = DidiSimulationPlace(id: "map", name: "地图选点", detail: "", latitude: 31.2, longitude: 121.4)
        await rejected("unverified map points cannot obtain a quote", contains: "搜索并选择") {
            _ = try await unconfigured.loadCars(from: fake, to: fake, stops: [])
        }
        var forged = fake; forged.verifiedByDidi = true
        await rejected("forged verified flag cannot obtain a quote", contains: "搜索并选择") {
            _ = try await unconfigured.loadCars(from: forged, to: forged, stops: [])
        }
        unconfigured.requestLocation()
        check(unconfigured.locationState == .failed && unconfigured.nearbyPlaces.isEmpty, "location requires an existing connection without asking the OS")
        unconfigured.resetTripData()
        check(unconfigured.locationState == .idle && unconfigured.locationError.isEmpty && !unconfigured.isConfigured, "trip reset clears failed location state without creating a connection")

        let transport = OfflineMCP()
        let service = DidiSimulationService(transport: { try await transport.load($0) })
        try await service.configure(credential: "offline-regression-key")
        check(service.isConfigured, "offline connection validates permitted capabilities")
        let points = try await service.searchPlaces("公开地点", city: "测试市")
        check(points.count == 2 && points.allSatisfy(\.verifiedByDidi), "production decoder binds actual search results to the current cache")
        let cars = try await service.loadCars(from: points[0], to: points[1], stops: [])
        check(cars.count == 3 && cars[0].priceText.isEmpty && cars[0].displayPrice == "待核实", "missing price remains unknown instead of zero")
        check(cars[1].displayPrice == "¥0", "explicit zero remains a true zero")
        check(cars[2].displayPrice == "¥63", "numeric source amount retains its value")
        for marker in ["待核实", "价格待确认", "—", "null", "  "] {
            let car = DidiSimulationCar(id: marker, name: "测试", detail: "", priceText: marker)
            check(!car.displayPrice.contains("¥") && !car.displayPrice.contains("0"), "unknown source price does not gain a currency or zero: " + marker)
        }
        let stopCars = try await service.loadCars(from: points[0], to: points[1], stops: [points[0]])
        check(stopCars.allSatisfy { $0.detail == "直达预估，未计经停" }, "stopovers are explicitly excluded from direct estimates")
        transport.cars = []
        await rejected("empty cars do not become a successful zero quote", contains: "没有返回可用车型") {
            _ = try await service.loadCars(from: points[0], to: points[1], stops: [])
        }
        transport.cars = [["productCategory": "known", "productName": "快车", "priceText": "65"]]
        transport.toolError = true
        await rejected("upstream tool error remains an error", contains: "未成功") {
            _ = try await service.loadCars(from: points[0], to: points[1], stops: [])
        }
        transport.toolError = false
        transport.invalidJSON = true
        do {
            _ = try await service.searchPlaces("公开地点", city: "测试市")
            preconditionFailure("Invalid JSON should fail")
        } catch {
            check(!error.localizedDescription.contains("offline-regression-key") && !error.localizedDescription.contains("mcp.didichuxing.com"), "invalid response errors do not expose the credential-bearing URL")
        }
        transport.invalidJSON = false

        service.resetTripData()
        check(service.isConfigured && service.nearbyPlaces.isEmpty && service.locationState == .idle, "restart clears trip state while retaining a connected card")
        await rejected("restart invalidates previously searched places", contains: "搜索并选择") {
            _ = try await service.loadCars(from: points[0], to: points[1], stops: [])
        }
        _ = try await service.searchPlaces("公开地点", city: "测试市")
        transport.holdMethod = "maps_textsearch"
        let oldSearch = Task { try await service.searchPlaces("迟到的搜索", city: "测试市") }
        await waitForGate(transport)
        service.resetTripData(); transport.release()
        await cancelled("late search cannot refill the new trip cache") { _ = try await oldSearch.value }
        await rejected("late search results are not quote-authorized", contains: "搜索并选择") {
            _ = try await service.loadCars(from: points[0], to: points[1], stops: [])
        }
        let current = try await service.searchPlaces("当前地点", city: "测试市")
        transport.holdMethod = "taxi_estimate"
        let oldQuote = Task { try await service.loadCars(from: current[0], to: current[1], stops: []) }
        await waitForGate(transport)
        service.resetTripData(); transport.release()
        await cancelled("late estimate is rejected after restart") { _ = try await oldQuote.value }
        check(service.isConfigured, "cancelled trip work does not revoke the live card connection")

        transport.holdMethod = "maps_textsearch"
        let disconnectedSearch = Task { try await service.searchPlaces("断开前请求", city: "测试市") }
        await waitForGate(transport)
        service.disconnect(); transport.release()
        await cancelled("disconnect rejects late service results") { _ = try await disconnectedSearch.value }
        check(!service.isConfigured && service.nearbyPlaces.isEmpty && service.locationState == .idle && service.locationError.isEmpty, "disconnect clears connection and temporary state")

        let connectingTransport = OfflineMCP(); connectingTransport.holdMethod = "tools/list"
        let connectingService = DidiSimulationService(transport: { try await connectingTransport.load($0) })
        let attempt = Task { try await connectingService.configure(credential: "offline-pending-key") }
        await waitForGate(connectingTransport)
        connectingService.disconnect(); connectingTransport.release()
        await cancelled("late configure cannot reconnect an ended card") { try await attempt.value }
        check(!connectingService.isConfigured, "ended connection remains disconnected")
        check(Set(transport.calledTools).isSubset(of: ["maps_textsearch", "taxi_estimate"]), "all exercised tools remain read-only")

        let registry = DidiChatSimulationRegistry()
        let first = UUID(), other = UUID(), session = UUID()
        registry.begin(sessionID: session, conversationID: first, request: "从公共A到公共B")
        check(registry.contains(sessionID: session, conversationID: first) && !registry.contains(sessionID: session, conversationID: other), "registry ownership is scoped to one conversation")
        check(!registry.appendRequest("旧会话补充", sessionID: session, conversationID: other), "another conversation cannot modify the trip request")
        registry.end(conversationID: first)
        check(!registry.contains(sessionID: session, conversationID: first) && registry.request(sessionID: session).isEmpty, "ending a conversation removes the old request and ownership")
        check(!registry.appendRequest("迟到补充", sessionID: session, conversationID: first), "ended registry rejects late updates")
        print("PASS: \(checks) production-service/domain/registry checks (offline transport, no network or device)")
    }
}
