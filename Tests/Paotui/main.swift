import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
struct MeituanMCPClient {
    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { fatalError("Offline test cannot perform network") }
}
@main struct PaotuiChecks {
    static var checks = 0
    static func expect(_ result: Bool, _ name: String) { checks += 1; precondition(result, name) }
    static func rejects(_ action: () throws -> Void) { do { try action(); fatalError("Invalid input accepted") } catch { checks += 1 } }
    static func main() async throws {
        let recipient = PaotuiAddress(id: "address:1", name: "Fixture destination", address: "Fixture street", houseNumber: "101", contact: "Test", maskedPhone: "138****0000", latitude: 22518481, longitude: 113935456, cityID: 440300, savedID: 1, lastUse: 1)
        let sender = PaotuiAddress(id: "poi:1", name: "Fixture store", address: "Fixture store street", houseNumber: "店铺", contact: "", maskedPhone: "", latitude: 22512682, longitude: 113930192, cityID: 440300, savedID: nil, lastUse: 0)
        rejects { _ = try recipient.wire(phone: "138****0000") }
        expect(try recipient.wire(phone: "13800000000")["phone"] as? String == "13800000000", "Real phone stays only in request")
        expect(MeituanPaotuiClient.masked("13800000000") == "138****0000", "Phone masking")
        expect(sender.distance(to: recipient) > 0 && sender.distance(to: recipient) < 2000, "Nearby geometric sort")
        let client = MeituanPaotuiClient(credential: "fixture-credential-never-send")
        let request = try client.request(.addresses, payload: ["scene":"2"])
        expect(request.url!.absoluteString == "https://mcp-open-cater.meituan.com/v1/api/paotui/get_address_list", "Fixed official endpoint")
        expect(request.value(forHTTPHeaderField: "mtcp-ak") == "fixture-credential-never-send", "Passport header")
        expect(request.httpMethod == "POST" && !request.httpShouldHandleCookies, "POST and no cookies")
        rejects { _ = try MeituanPaotuiClient(credential: "bad\ncredential").request(.addresses, payload: [:]) }
        let body: [String: Any] = ["code":0, "data":["userAddresses":[]]]
        let outer = try JSONSerialization.data(withJSONObject: ["code":0,"result":"SUCCESS","data":String(data: JSONSerialization.data(withJSONObject: body),encoding:.utf8)!])
        expect(try MeituanPaotuiClient.decode(outer)["userAddresses"] as? [String] == [], "Nested JSON data envelope")
        for code in [10000,10309,10310,10311,10112,10115,10116,40001] {
            rejects { _ = try MeituanPaotuiClient.decode(JSONSerialization.data(withJSONObject: ["code":0,"data":["code":code,"data":[:]]])) }
        }
        rejects { _ = try MeituanPaotuiClient.decode(Data("{}".utf8)) }
        rejects { _ = try PaotuiToolQuery.decode("{\"action\":\"submit_order\"}") }
        rejects { _ = try PaotuiToolQuery.decode("{\"action\":\"addresses\",\"token\":\"injected\"}") }
        rejects { _ = try PaotuiToolQuery.decode("{\"action\":\"preview_buy\",\"recipient\":\"address:1\",\"goods\":\"rice\"}") }
        let nearby = try PaotuiToolQuery.decode("{\"action\":\"preview_buy\",\"recipient\":\"address:1\",\"nearby\":true,\"goods\":\"rice\"}")
        expect(nearby.action == .preview_buy, "Explicit nearby purchase")
        rejects { _ = try PaotuiToolQuery.decode("{\"action\":\"preview_send\",\"recipient\":\"address:1\",\"sender\":\"address:2\",\"goods\":\"parcel\",\"weight\":0}") }
        let draft = PaotuiDraft(service:.buy,recipientID:recipient.id,senderID:sender.id,goods:"鸡肉饭一份")
        let data: [String:Any] = ["deliveryFeeView":["totalAmount":18.0],"total":18.0,"orderToken":"fixture-order-token","distanceDesc":"1.3公里","estimateDeliveryTimeText":"预计送达","commonConfig":["goodsPayDesc":"商品费另计"],"userAgreement":["userAgreementUrl":"https://paotui.meituan.com/agreement"]]
        let quote = try MeituanPaotuiClient.quote(data:data,draft:draft,sender:sender,recipient:recipient,request:[:],account:"account-a",service:nil)
        expect(quote.fee == 18 && quote.goodsPaymentNote == "商品费另计", "Actual fee and goods payment note")
        expect(!quote.summary.contains("fixture-order-token") && !quote.summary.contains("13800000000"), "Quote summary excludes secrets and full phone")
        expect(quote.canSubmit(draft:draft,account:"account-a",unresolved:false), "Exact current quote allowed")
        var changed = draft;changed.goods="Different goods"
        expect(!quote.canSubmit(draft:changed,account:"account-a",unresolved:false), "Changed goods invalidate quote")
        expect(!quote.canSubmit(draft:draft,account:"account-b",unresolved:false), "Changed account invalidates quote")
        expect(!quote.canSubmit(draft:draft,account:"account-a",unresolved:true), "Uncertain submission blocks duplicates")
        expect(MeituanPaotuiClient.officialURL("https://dpurl.cn/fixture") != nil, "Official auth link")
        for url in ["http://paotui.meituan.com/","https://meituan.com.evil.test/","https://user:password@meituan.com/","https://meituan.com:8443/"] {
            expect(MeituanPaotuiClient.officialURL(url) == nil,"Untrusted URL rejected")
        }
        let system = try SystemToolRequest.decode("{\"operation\":\"meituan_paotui\",\"query\":\"{\\\"action\\\":\\\"addresses\\\"}\"}")
        expect(!system.operation.writes,"AI tool cannot submit orders")
        print("PASS: \(checks) Paotui contract, authorization-bound quote, phone privacy and duplicate protection checks")
    }
}
