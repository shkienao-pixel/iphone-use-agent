import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
struct MeituanMCPClient {
    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { fatalError("Offline check attempted network") }
}
enum ConnectionCredentialStore {
    static var data: [String:String] = [:]
    static func read(_ key: String) -> String { data[key] ?? "" }
    static func save(_ value: String, account: String) throws { data[account] = value }
}
@MainActor struct UIApplication {
    static let shared = Self()
    func open(_ url: URL) async -> Bool { false }
}
struct MeituanPaotuiAuthorization {
    struct Session { let link: URL }
    func start() async throws -> Session { fatalError("Offline check attempted authorization") }
    func finish(_ session: Session) async throws -> String? { fatalError("Offline check attempted authorization") }
}
@MainActor final class Backend {
    var submissions: [[String:Any]] = []
    var previews: [[String:Any]] = []
    var failSubmit = false
    var addressCount = 2
    var alternateCity = false
    var searchRequests: [[String: Any]] = []
    var deliveryFee = 18.0
    func client(_ key: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential:key,transport:{ request in try self.respond(request) })
    }
    func respond(_ request: URLRequest) throws -> (Data,HTTPURLResponse) {
        let path=request.url!.lastPathComponent
        let payload=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let data:[String:Any]
        switch path {
        case "get_address_list":
            data=["userAddresses":(1...addressCount).map { ["id":$0,"address":"Fixture address \($0)","houseNumber":"101","name":"Test","phone":"138****0000","latitude":22518481+$0,"longitude":113935456+$0,"bmCityId":alternateCity && $0 == 1 ? 110100 : 440300,"lastUseTime":$0] as [String:Any] }]
        case "search_poi":
            searchRequests.append(payload)
            data=["result":["pois":[["id":"fixture-shop","name":"Fixture Kitchen","address":"Fixture store","location":"113.930192,22.512682","addr_info":[["level_desc":"city","admin_code":"440300"]]]]]]
        case "get_address_info_by_id": data=["id":payload["addressId"]!,"phone":"13800000000"]
        case "delivery_preview":
            previews.append(payload)
            let service=payload["serviceType"] as? Int ?? 0
            data=["deliveryFeeView":["totalAmount":service == 4033 ? deliveryFee+5 : deliveryFee],"total":service == 4033 ? deliveryFee+5 : deliveryFee,"orderToken":"fixture-token-\(service)","distanceDesc":"1.3公里","estimateDeliveryTimeText":"Fixture estimate","couponPreviewView":["amount":0]]
        case "submit_order":
            submissions.append(payload)
            if failSubmit { throw URLError(.networkConnectionLost) }
            data=["orderId":"fixture-order-created","tradeNo":"fixture-trade","payToken":"fixture-payment"]
        case "get_order_status": data=["statusDesc":"等待支付"]
        default: fatalError("Unexpected request: "+path)
        }
        let inner=try JSONSerialization.data(withJSONObject:["code":0,"data":data])
        let bytes=try JSONSerialization.data(withJSONObject:["code":0,"result":"SUCCESS","data":String(data:inner,encoding:.utf8)!])
        return (bytes,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}

struct AgentSettings {}
struct VisionClient {
 let settings: AgentSettings
 let apiKey: String
 func routeConversation(input: ConversationRoutingInput, instructions: String) async throws -> String { fatalError("Offline check attempted model") }
}
