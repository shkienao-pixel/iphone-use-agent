import Foundation

@main struct PaotuiChecks {
    static var checks = 0
    static func expect(_ result: Bool, _ name: String) { checks += 1; precondition(result, name) }
    static func rejects(_ action: () throws -> Void) { do { try action(); fatalError("Invalid input accepted") } catch { checks += 1 } }
    static func main() async throws {
        try moneyChecks()
        let recipient = PaotuiAddress(id: "address:1", name: "Fixture destination", address: "Fixture street", houseNumber: "101", contact: "Test", maskedPhone: "138****0000", latitude: 22518481, longitude: 113935456, cityID: 440300, savedID: 1, lastUse: 1)
        let sender = PaotuiAddress(id: "poi:1", name: "Fixture store", address: "Fixture store street", houseNumber: "店铺", contact: "", maskedPhone: "", latitude: 22512682, longitude: 113930192, cityID: 440300, savedID: nil, lastUse: 0)
        rejects { _ = try recipient.wire(phone: "138****0000") }
        expect(try recipient.wire(phone: "13800000000")["phone"] as? String == "13800000000", "Real phone stays only in request")
        expect(MeituanPaotuiClient.masked("13800000000") == "138****0000", "Phone masking")
        expect(sender.distance(to: recipient) > 0 && sender.distance(to: recipient) < 2000, "Nearby geometric sort")
        let emptyDraft = PaotuiDraft()
        expect(emptyDraft.service == nil && emptyDraft.weight == nil && emptyDraft.category == nil,
               "A new requirement has no fabricated service, category or weight")
        expect(emptyDraft.missingFields == [.service, .goods, .recipient], "Unknown service exposes only common missing fields in request order")
        rejects { _ = try emptyDraft.validated() }
        let completeBuy = PaotuiDraft(service: .buy, recipientID: recipient.id, nearby: true, goods: "水一瓶")
        let readyBuy = try completeBuy.validated()
        expect(completeBuy.missingFields.isEmpty && readyBuy.service == .buy && readyBuy.category == nil && readyBuy.weight == nil,
               "A complete buy request needs no send-only weight or category")
        expect(readyBuy.draft == completeBuy, "A ready request projects its exact draft without adding defaults")
        var incompleteBuy = completeBuy; incompleteBuy.nearby = false
        expect(incompleteBuy.missingFields == [.purchaseMethod], "Buying requires an explicit nearby or selected-store choice")
        rejects { try incompleteBuy.validate() }
        let incompleteSend = PaotuiDraft(service: .send)
        expect(incompleteSend.missingFields == [.goods, .recipient, .weight, .category, .sender],
               "Send completeness requires actual weight, category and a sender after common fields")
        rejects { _ = try incompleteSend.validated() }
        let completeSend = PaotuiDraft(service: .send, recipientID: recipient.id, senderID: sender.id,
                                      goods: "文件", category: .document, weight: 0.5)
        let readySend = try completeSend.validated()
        var changedSend = completeSend; changedSend.weight = 3
        expect(readySend.service == .send && readySend.category == .document && readySend.weight == 0.5 && readySend.draft == completeSend,
               "A validated send is an immutable snapshot of actual category and weight")
        expect(readySend.draft != changedSend, "Editing the original draft cannot mutate a ready request")
        for missing in [PaotuiMissingField.weight, .category, .sender] {
            var draft = completeSend
            switch missing {
            case .weight: draft.weight = nil
            case .category: draft.category = nil
            case .sender: draft.senderID = ""
            default: preconditionFailure("Unexpected fixture")
            }
            expect(draft.missingFields == [missing], "Each unknown send fact is identified explicitly")
            rejects { try draft.validate() }
        }
        for weight in [Double.nan, .infinity, 0, 50.1] {
            var draft = completeSend; draft.weight = weight
            expect(draft.missingFields.isEmpty, "An invalid known weight is not reported as unknown")
            rejects { _ = try draft.validated() }
        }
        var nearbySend = completeSend; nearbySend.nearby = true
        rejects { _ = try nearbySend.validated() }
        var oversized = completeBuy; oversized.remark = String(repeating: "x", count: 501)
        rejects { _ = try oversized.validated() }
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
        let sendFields: [String: Any] = ["action": "preview_send", "recipient": "address:1", "sender": "address:2", "goods": "文件"]
        for missing in [["category": "document"], ["weight": 0.5], [:]] as [[String: Any]] {
            rejects {
                let fields = sendFields.merging(missing) { _, new in new }
                _ = try PaotuiToolQuery.decode(String(decoding: JSONSerialization.data(withJSONObject: fields), as: UTF8.self))
            }
        }
        let actualSend = sendFields.merging(["weight": 0.5, "category": "document"] as [String: Any]) { _, new in new }
        let decodedSend = try PaotuiToolQuery.decode(String(decoding: JSONSerialization.data(withJSONObject: actualSend), as: UTF8.self))
        let sendDraft = try decodedSend.validatedDraft()
        expect(sendDraft.weight == 0.5 && sendDraft.category == .document, "Send draft preserves actual weight and item category")
        var toolSend = completeSend; toolSend.senderID = "address:2"
        expect(sendDraft == toolSend, "Tool and native drafts share one complete-send validation contract")
        let nearbyDraft = try nearby.validatedDraft()
        expect(nearbyDraft.service == .buy && nearbyDraft.weight == nil && nearbyDraft.category == nil,
               "Buying needs no artificial weight or category input")
        for invalidWeight in [0.0, 50.1] {
            rejects {
                let fields = actualSend.merging(["weight": invalidWeight]) { _, new in new }
                _ = try PaotuiToolQuery.decode(String(decoding: JSONSerialization.data(withJSONObject: fields), as: UTF8.self))
            }
        }
        let draft = PaotuiDraft(service:.buy,recipientID:recipient.id,senderID:sender.id,goods:"鸡肉饭一份")
        let data: [String:Any] = ["deliveryFeeView":["totalAmount":18.0],"total":18.0,"orderToken":"fixture-order-token","distanceDesc":"1.3公里","estimateDeliveryTimeText":"预计送达","commonConfig":["goodsPayDesc":"商品费另计"],"userAgreement":["userAgreementUrl":"https://paotui.meituan.com/agreement"]]
        let quote = try MeituanPaotuiClient.quote(data:data,draft:draft,sender:sender,recipient:recipient,request:[:],account:"account-a",service:nil)
        expect(quote.fee == 18 && quote.goodsPaymentNote == "商品费另计", "Actual fee and goods payment note")
        expect(quote.deliveryAmount?.minorUnits == 1800 && quote.originalDeliveryAmount?.currency == .cny,
               "Production quote owns typed exact CNY amounts")
        expect(quote.validUntil == quote.quotedAt.addingTimeInterval(PaotuiQuote.lifetime), "Single quote expiry projection")
        expect(!quote.isExpired(at: quote.validUntil.addingTimeInterval(-0.001)) && quote.isExpired(at: quote.validUntil),
               "Quote expiry uses one exact boundary at validUntil")
        // Exercise the production envelope boundary, before Foundation can
        // hide unsupported precision by rounding a number token into NSNumber.
        let rawQuote = "{\"code\":0,\"data\":{\"deliveryFeeView\":{\"totalAmount\":12.34},\"total\":92233720368547758.07,\"orderToken\":\"fixture\",\"distanceDesc\":\"1km\"}}"
        let decodedExact = try MeituanPaotuiClient.decode(Data(rawQuote.utf8))
        let exactEnvelopeQuote = try MeituanPaotuiClient.quote(data: decodedExact, draft: draft, sender: sender,
            recipient: recipient, request: [:], account: "account-a", service: nil)
        expect(exactEnvelopeQuote.deliveryAmount?.minorUnits == Int64.max,
               "Actual provider JSON envelope preserves the maximum exact CNY amount")
        let bomEnvelope = Data([0xEF, 0xBB, 0xBF]) + Data(rawQuote.utf8)
        expect(try MeituanPaotuiClient.decode(bomEnvelope)["total"] as? NSDecimalNumber == NSDecimalNumber(string: "92233720368547758.07"),
               "UTF-8 BOM cannot bypass the exact money projection")
        rejects { _ = try MeituanPaotuiClient.decode(rawQuote.data(using: .utf16)!) }
        for (literal, cents) in [("90071992547409.91", Int64(9_007_199_254_740_991)),
                                 ("90071992547409.92", 9_007_199_254_740_992),
                                 ("90071992547409.93", 9_007_199_254_740_993)] {
            let raw = "{\"code\":0,\"data\":{\"deliveryFeeView\":{\"totalAmount\":" + literal + "},\"total\":" + literal + ",\"orderToken\":\"fixture\",\"distanceDesc\":\"1km\"}}"
            for envelope in [Data(raw.utf8), try JSONSerialization.data(withJSONObject: ["code": 0, "data": raw])] {
                let response = try MeituanPaotuiClient.decode(envelope)
                let value = try MeituanPaotuiClient.quote(data: response, draft: draft, sender: sender,
                    recipient: recipient, request: [:], account: "account-a", service: nil)
                expect(value.deliveryAmount?.minorUnits == cents && value.originalDeliveryAmount?.minorUnits == cents,
                       "Real provider decode preserves original cents across Double's precision boundary: " + literal)
            }
        }
        for rawNumber in ["1.230000000000000000000000000000000000001", "0.001", "92233720368547758.08", "-1"] {
            let inner = "{\"code\":0,\"data\":{\"total\":" + rawNumber + "}}"
            rejects { _ = try MeituanPaotuiClient.decode(Data(inner.utf8)) }
            let nested = try JSONSerialization.data(withJSONObject: ["code": 0, "data": inner])
            rejects { _ = try MeituanPaotuiClient.decode(nested) }
        }
        for duplicate in [#"{"code":0,"data":{"total":1,"total":2}}"#,
                          #"{"code":0,"data":{"total":1,"tota\u006c":2}}"#,
                          #"{"code":0,"data":{"deliveryFeeView":{"totalAmount":1},"deliveryFeeView":{"totalAmount":2}}}"#] {
            rejects { _ = try MeituanPaotuiClient.decode(Data(duplicate.utf8)) }
        }
        let escapedKey = #"{"code":0,"data":{"tota\u006c":0.001}}"#
        rejects { _ = try MeituanPaotuiClient.decode(Data(escapedKey.utf8)) }
        let amountPhrase = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["statusDesc": "配送说明含 \"total\":0.001"]])
        expect(try MeituanPaotuiClient.decode(amountPhrase)["statusDesc"] as? String == "配送说明含 \"total\":0.001",
               "Money scanner skips quoted status text and does not reinterpret user content")
        let exactData = data.merging(["deliveryFeeView": ["totalAmount": NSDecimalNumber(string: "12.34")],
                                      "total": NSDecimalNumber(string: "0.29")]) { _, new in new }
        let exactQuote = try MeituanPaotuiClient.quote(data: exactData, draft: draft, sender: sender,
            recipient: recipient, request: [:], account: "account-a", service: nil)
        expect(exactQuote.deliveryAmount?.wireAmount == "0.29" && exactQuote.originalDeliveryAmount?.minorUnits == 1234,
               "Production quote decode preserves cents without Double arithmetic")
        for container in ["total", "original", "coupon"] {
            var foreign = data
            switch container {
            case "total": foreign["currency"] = "USD"
            case "original": foreign["deliveryFeeView"] = ["totalAmount": 18, "currency": "USD"]
            default: foreign["couponPreviewView"] = ["amount": 1, "couponViewId": "fixture", "currency": "USD"]
            }
            rejects { _ = try MeituanPaotuiClient.quote(data: foreign, draft: draft, sender: sender,
                recipient: recipient, request: [:], account: "account-a", service: nil) }
        }
        var cny = data; cny["currency"] = "CNY"
        cny["couponPreviewView"] = ["amount": NSDecimalNumber(string: "0.01"), "couponViewId": "coupon/fixture", "currency": "CNY"]
        let couponQuote = try MeituanPaotuiClient.quote(data: cny, draft: draft, sender: sender,
            recipient: recipient, request: [:], account: "account-a", service: nil)
        expect(couponQuote.couponViewID == "coupon%2Ffixture", "One-fen CNY coupon preserves existing selected-coupon wire contract")
        for invalid: Any in [true, -1, 0.001, Double.infinity, "0.01"] {
            var malformed = data
            malformed["couponPreviewView"] = ["amount": invalid, "couponViewId": "fixture"]
            rejects { _ = try MeituanPaotuiClient.quote(data: malformed, draft: draft, sender: sender,
                recipient: recipient, request: [:], account: "account-a", service: nil) }
        }
        for invalid: Any in [NSNumber(value: true), NSDecimalNumber(string: "0.001"), NSDecimalNumber(string: "-1"),
                             NSNumber(value: Double.infinity), NSDecimalNumber(string: "92233720368547758.08"), "12.34"] {
            for field in ["total", "original"] {
                var malformed = data
                if field == "total" { malformed["total"] = invalid }
                else { malformed["deliveryFeeView"] = ["totalAmount": invalid] }
                rejects { _ = try MeituanPaotuiClient.quote(data: malformed, draft: draft, sender: sender,
                    recipient: recipient, request: [:], account: "account-a", service: nil) }
            }
        }

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
    static func moneyChecks() throws {
        for (amount, cents, wire) in [("0", Int64(0), "0.0"), ("0.01", 1, "0.01"), ("0.10", 10, "0.1"),
                                      ("12.34", 1234, "12.34"), ("12.3400", 1234, "12.34"),
                                      ("1.234e1", 1234, "12.34"), ("1e-2", 1, "0.01"),
                                      ("92233720368547758.07", Int64.max, "92233720368547758.07")] {
            let money = try PaotuiMoney(amount: amount)
            expect(money.currency == .cny && money.minorUnits == cents && money.wireAmount == wire,
                   "CNY exact digit parsing and canonical string wire: " + amount)
            let restored = try JSONDecoder().decode(PaotuiMoney.self, from: JSONEncoder().encode(money))
            expect(restored == money, "Exact currency and minor units survive Codable")
        }
        for invalid in ["-1", "-0.01", "nan", "inf", "", "12.34x", " 12.34", ".01", "1,234.56",
                        "0.001", "12.345", "1e-3", "1.230000000000000000000000000000000000001",
                        "92233720368547758.08", "92233720368547759", "1e127", "1e9999999999999999999999"] {
            rejects { _ = try PaotuiMoney(amount: invalid) }
        }
        rejects { _ = try PaotuiMoney(minorUnits: -1) }
        for value in [Double.nan, .infinity, -.infinity, -1, 12.345, 0.1 + 0.2] {
            rejects { _ = try PaotuiMoney(displayValue: value) }
        }
        for value: Any in [true, false, "12.34", NSNull(), Date()] {
            rejects { _ = try PaotuiMoney(providerValue: value) }
        }
        expect(try PaotuiMoney(providerValue: NSNumber(value: 1)).minorUnits == 100,
               "Provider numeric one remains distinct from boolean true")
        expect(try PaotuiMoney(providerValue: NSNumber(value: Int8(12))).minorUnits == 1200,
               "A numeric byte is not confused with a CFBoolean")
        expect(try PaotuiMoney(providerValue: NSDecimalNumber(string: "92233720368547758.07")).minorUnits == Int64.max,
               "Exact provider Decimal reaches max Int64 fen without a binary conversion")
        for json in ["{\"currency\":\"USD\",\"minorUnits\":1}", "{\"currency\":\"CNY\",\"minorUnits\":-1}",
                     "{\"currency\":\"CNY\",\"minorUnits\":1.1}", "{\"currency\":\"CNY\",\"minorUnits\":9223372036854775808}"] {
            rejects { _ = try JSONDecoder().decode(PaotuiMoney.self, from: Data(json.utf8)) }
        }
    }

}
