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
    func open(_ url: URL) async -> Bool { fatalError("Offline check opened a URL") }
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
    func client(_ key: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential:key,transport:{ request in try self.respond(request) })
    }
    func respond(_ request: URLRequest) throws -> (Data,HTTPURLResponse) {
        let path=request.url!.lastPathComponent
        let payload=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let data:[String:Any]
        switch path {
        case "get_address_list":
            data=["userAddresses":(1...2).map { ["id":$0,"address":"Fixture address \($0)","houseNumber":"101","name":"Test","phone":"138****0000","latitude":22518481+$0,"longitude":113935456+$0,"bmCityId":440300,"lastUseTime":$0] as [String:Any] }]
        case "get_address_info_by_id": data=["id":payload["addressId"]!,"phone":"13800000000"]
        case "delivery_preview":
            previews.append(payload)
            let service=payload["serviceType"] as? Int ?? 0
            data=["deliveryFeeView":["totalAmount":service == 4033 ? 23.0 : 18.0],"total":service == 4033 ? 23.0 : 18.0,"orderToken":"fixture-token-\(service)","distanceDesc":"1.3公里","estimateDeliveryTimeText":"Fixture estimate","couponPreviewView":["amount":0]]
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
@main struct StoreChecks {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("paotui-store-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let backend=Backend();let path=root.appendingPathComponent("orders.json")
        let store=MeituanPaotuiStore(receiptURL:path,clientFactory:backend.client)
        try store.installCredential("fixture-authorized-key")
        try await store.loadAddresses()
        store.draft=PaotuiDraft(service:.buy,recipientID:"address:1",senderID:"address:2",nearby:true,goods:"文件",category:.document)
        store.selectService(.send)
        expect(!store.draft.nearby && store.draft.senderID.isEmpty && store.draft.recipientID == "address:1", "Service switch resets the purchase mode and source address without losing destination")
        store.draft.senderID="address:2"
        let quotes=try await store.preview()
        expect(quotes.count==2,"Normal and express quotes")
        expect(backend.previews[0]["serviceType"] as? Int==1003 && backend.previews[1]["serviceType"] as? Int==4033,"Correct service contracts")
        let goods=backend.previews[0]["goods"] as! [String:Any]
        expect(goods["goodTypes"] as? [Int]==[4] && goods["goodTypeNames"] as? [String]==["文件"],"Document category mapped as a pair")
        expect(backend.previews[0]["goodsInfo"] as? String != nil,"Official goodsInfo wire contract")
        let express=quotes[1]
        await store.submitConfirmed(express)
        expect(backend.submissions.count==1,"Single confirmed submit")
        let sent=backend.submissions[0]
        expect(sent["serviceType"] as? Int==4033 && sent["orderToken"] as? String=="fixture-token-4033","Express uses its own token")
        expect(sent["deliveryFee"] as? String=="23.0" && sent["previewTotal"] as? String=="23.0","Express uses its own fees")
        expect(store.lastOrderID=="fixture-order-created" && !store.hasUnresolvedSubmission,"Success is durably recorded")
        expect(store.orderURL(quoteID:express.id)?.lastPathComponent == "fixture-order-created" && store.orderURL(quoteID:UUID()) == nil,"Conversation receipt belongs only to its actual quote, never an earlier order")
        await store.submitConfirmed(express)
        expect(backend.submissions.count==1,"Repeated old quote cannot resubmit")
        let status=try await store.status(orderID:"fixture-order-created")
        expect(status=="等待支付","Read actual status without assuming payment")
        let restored=MeituanPaotuiStore(receiptURL:path,clientFactory:backend.client)
        expect(restored.lastOrderID=="fixture-order-created","Receipt survives relaunch")
        let blockedDirectory=root.appendingPathComponent("not-a-folder");try Data("fixture".utf8).write(to:blockedDirectory)
        let blocked=MeituanPaotuiStore(receiptURL:blockedDirectory.appendingPathComponent("orders.json"),clientFactory:backend.client)
        try await blocked.loadAddresses()
        blocked.draft=PaotuiDraft(service:.buy,recipientID:"address:1",nearby:true,goods:"水一瓶")
        let unsaved=try await blocked.preview()[0]
        await blocked.submitConfirmed(unsaved)
        expect(backend.submissions.count==1 && blocked.failed && blocked.message.contains("订单记录保存失败"),"Local write failure is diagnosed before the submit endpoint is called")
        expect(blocked.orderURL(quoteID:unsaved.id)==nil,"Failed local preparation cannot show another order's receipt")
        let failingBackend=Backend();failingBackend.failSubmit=true
        let pendingPath=root.appendingPathComponent("pending.json")
        let uncertain=MeituanPaotuiStore(receiptURL:pendingPath,clientFactory:failingBackend.client)
        try await uncertain.loadAddresses()
        uncertain.draft=PaotuiDraft(service:.buy,recipientID:"address:1",nearby:true,goods:"饮料一瓶")
        let buy=try await uncertain.preview()[0]
        await uncertain.submitConfirmed(buy)
        expect(uncertain.hasUnresolvedSubmission && failingBackend.submissions.count==1,"Lost response remains pending")
        await uncertain.submitConfirmed(buy)
        expect(failingBackend.submissions.count==1,"No retry after lost response")
        let afterCrash=MeituanPaotuiStore(receiptURL:pendingPath,clientFactory:failingBackend.client)
        expect(afterCrash.hasUnresolvedSubmission,"Pending survives app crash")
        try afterCrash.disconnect();try afterCrash.installCredential("another-fixture-key")
        expect(afterCrash.hasUnresolvedSubmission,"Logout/new credential cannot bypass pending")
        let disk=try String(contentsOf:pendingPath,encoding:.utf8)
        expect(!disk.contains("13800000000") && !disk.contains("fixture-token-") && !disk.contains("fixture-authorized-key"),"Durable receipts contain no phones or secrets")
        afterCrash.resolveAfterHumanReview()
        expect(!afterCrash.hasUnresolvedSubmission,"Explicit human review unlocks a fresh query")
        let corrupted=root.appendingPathComponent("corrupt.json");try Data("bad".utf8).write(to:corrupted)
        let unreadable=MeituanPaotuiStore(receiptURL:corrupted,clientFactory:backend.client)
        expect(unreadable.hasUnresolvedSubmission,"Unreadable receipts fail closed")
        print("PASS: \(checks) production store request, confirmed submit, crash/restart and unknown-result checks; no network/phone/real orders")
    }
}
