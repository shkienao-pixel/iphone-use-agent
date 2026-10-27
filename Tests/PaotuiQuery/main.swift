import Foundation

@main private struct PaotuiQueryChecks {
    static var checks = 0
    static let time = Date(timeIntervalSince1970: 1_800_000_000)
    static let privatePhone = "13812345678"
    static let privateToken = "PRIVATE-ORDER-TOKEN-fixture"
    static let privateAccount = "PRIVATE-ACCOUNT-fixture"
    static let privateCoupon = "PRIVATE-COUPON-fixture"
    static let privateRequest = "PRIVATE-REQUEST-fixture"

    static func expect(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        precondition(value(), label)
    }
    static func decode(_ result: PaotuiQueryResult, budget: Int = 11_000) throws -> [String: Any] {
        let rendered = try result.render(maxCharacters: budget)
        let text = rendered.json
        let jsonOnly = try result.renderJSON(maxCharacters: budget)
        expect(text == jsonOnly, "JSON-only compatibility projection uses the same bounded renderer")
        expect(text.count <= budget, "complete JSON respects requested character budget")
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(object["source"] as? String == "meituan_paotui", "source present")
        expect(object["queriedAt"] as? String == "2027-01-15T08:00:00Z", "actual read timestamp present")
        expect(object["total"] is Int && object["returned"] is Int && object["truncated"] is Bool,
               "common completeness metadata present")
        let rows = object["records"] as! [[String: Any]]
        expect(rendered.references == Set(rows.compactMap { $0["reference"] as? String }), "only complete actually exported references gain query scope")
        expect(rows.count == object["returned"] as? Int, "returned count matches records")
        for secret in [privatePhone, privateToken, privateAccount, privateCoupon, privateRequest] {
            expect(!text.contains(secret), "private execution field excluded from JSON")
        }
        return object
    }
    static func address(_ id: String, text: String = "深圳市南山区科技园", phone: String = "138****5678") -> PaotuiAddress {
        .init(id: id, name: text, address: text, houseNumber: "A 座", contact: "测试联系人", maskedPhone: phone,
              latitude: 22_541_000, longitude: 113_956_000, cityID: 440300, savedID: 42, lastUse: 1)
    }
    static func quote(_ service: PaotuiService?, text: String = "文件", fee: Double = 12.5, id: UUID = UUID()) -> PaotuiQuote {
        let draft = PaotuiDraft(service: service, recipientID: "address:42", senderID: "poi:real-42", nearby: false,
                                goods: text, remark: "", category: .document, weight: 0.4)
        return .init(id: id, draft: draft, senderTitle: "真实取件点", recipientTitle: "真实送达点", serviceTitle: service?.title ?? "服务待确定",
                     distance: "3 公里", estimate: "预计 30 分钟", fee: fee, originalFee: 15,
                     goodsPaymentNote: "商品费待核实", quotedAt: time, agreementURL: nil, agreementTitle: "服务协议",
                     account: privateAccount, request: ["phone": privatePhone, "secret": privateRequest,
                         "payToken": "PRIVATE-PAY-TOKEN-fixture"], orderToken: privateToken, couponViewID: privateCoupon)
    }
    static func noRetainedSecrets(_ result: PaotuiQueryResult) {
        let reflected = String(reflecting: result)
        for secret in [privatePhone, privateToken, privateAccount, privateCoupon, privateRequest, "PRIVATE-PAY-TOKEN-fixture"] {
            expect(!reflected.contains(secret), "shared typed result retains no private execution field")
        }
        expect(!reflected.contains("PaotuiQuote("), "shared typed result cannot retain raw quote")
    }
    static func main() throws {
        try safeAddressProjection()
        try adversarialDisplayPhones()
        try completeQuotePrices()
        try boundedLongResults()
        try statusAndBudgets()
        print("PASS: \(checks) actual-source typed query projection, JSON, budget, reference, price and privacy checks; offline only")
    }
    static func safeAddressProjection() throws {
        let result = PaotuiQueryResult.addresses([address("address:42", phone: privatePhone)], total: 1, at: time)
        noRetainedSecrets(result)
        let object = try decode(result)
        expect(object["kind"] as? String == "addresses", "address kind")
        expect(object["truncated"] as? Bool == false, "complete address result")
        let row = (object["records"] as! [[String: Any]])[0]
        expect(row["reference"] as? String == "address:42", "reference copied exactly")
        expect(row["phone"] as? String == "138****5678", "full phone masked during projection")
        expect(row["savedID"] == nil && row["latitude"] == nil && row["longitude"] == nil,
               "execution address metadata excluded")
        let invalidPhone = PaotuiQueryResult.addresses([address("address:43", phone: "138****5678 private-phone")], total: 1, at: time)
        let invalid = try decode(invalidPhone)
        expect((invalid["records"] as! [[String: Any]])[0]["phone"] as? String == "", "untrusted mask rejected")
        let deceptiveMask = PaotuiQueryResult.addresses([address("address:44", phone: "*" + privatePhone)], total: 1, at: time)
        noRetainedSecrets(deceptiveMask)
        let deceptive = try decode(deceptiveMask)
        expect((deceptive["records"] as! [[String: Any]])[0]["phone"] as? String == "", "an asterisk cannot bless an otherwise complete private phone")
    }
    static func adversarialDisplayPhones() throws {
        let text = "字段 " + privatePhone + " 或 +86" + privatePhone
        let masked = "字段 138****5678 或 138****5678"
        expect(PaotuiAddress.redactingPhones(text) == masked,
               "Shared display redactor masks phone-looking text and country-code forms")
        expect(PaotuiAddress.redactingPhones("订单 123456789012345") == "订单 123456789012345",
               "Redaction leaves unrelated longer numeric identifiers intact")
        let place = PaotuiAddress(id: "address:private-display", name: text, address: text, houseNumber: text,
            contact: text, maskedPhone: privatePhone, latitude: 22_541_000, longitude: 113_956_000,
            cityID: 440300, savedID: 42, lastUse: 1)
        for result in [PaotuiQueryResult.addresses([place], total: 1, at: time),
                       PaotuiQueryResult.places([place], total: 1, at: time)] {
            noRetainedSecrets(result)
            let row = (try decode(result)["records"] as! [[String: Any]])[0]
            expect(row["name"] as? String == masked && row["contact"] as? String == masked,
                   "Provider name and contact redact before typed retention and JSON export")
            expect(row["address"] as? String == masked + " " + masked,
                   "Address and house-number text are both redacted")
        }
        let executionAddress = try place.wire(phone: privatePhone)
        expect(executionAddress["phone"] as? String == privatePhone && executionAddress["name"] as? String == text &&
               executionAddress["address"] as? String == text,
               "Display redaction does not alter execution phone, contact or address")
        let draft = PaotuiDraft(service: .buy, recipientID: place.id, nearby: true, goods: text, remark: text)
        let quote = PaotuiQuote(id: UUID(), draft: draft, senderTitle: text, recipientTitle: text,
            serviceTitle: text, distance: text, estimate: text, fee: 12.5, originalFee: 15,
            goodsPaymentNote: text, quotedAt: time, agreementURL: nil, agreementTitle: text,
            account: privateAccount, request: ["sender": ["name": privatePhone, "phone": privatePhone],
                "recipient": ["name": text, "phone": privatePhone], "secret": privateRequest],
            orderToken: privateToken, couponViewID: privateCoupon)
        expect(quote.senderContact == "138****5678 · 138****5678" && quote.recipientContact == masked + " · 138****5678",
               "Safe quote contact masks a full phone even when provider returns it as a name")
        expect((quote.request["sender"] as? [String: Any])?["name"] as? String == privatePhone,
               "Quote safe-contact projection does not mutate its private execution request")
        let result = PaotuiQueryResult.quotes([quote], at: time)
        noRetainedSecrets(result)
        let row = (try decode(result)["records"] as! [[String: Any]])[0]
        for field in ["serviceTitle", "sender", "recipient", "goods", "distance", "estimate", "goodsPaymentNote"] {
            expect(row[field] as? String == masked, "Every quote display field redacts before retention: " + field)
        }
        expect(!(row["summary"] as! String).contains(privatePhone) && (row["summary"] as! String).contains("138****5678"),
               "Composed quote summary also redacts embedded phones")
        let status = PaotuiQueryResult.status(text, at: time)
        noRetainedSecrets(status)
        let statusRow = (try decode(status)["records"] as! [[String: Any]])[0]
        expect(statusRow["status"] as? String == masked,
               "Selected provider status text cannot retain or render an embedded full phone")
    }
    static func completeQuotePrices() throws {
        let buy = quote(.buy)
        let result = PaotuiQueryResult.quotes([buy, quote(.send)], at: time)
        noRetainedSecrets(result)
        let object = try decode(result)
        let rows = object["records"] as! [[String: Any]]
        expect(object["kind"] as? String == "quotes", "quote kind")
        expect(object["total"] as? Int == 2, "all quote count")
        expect(rows[0]["reference"] as? String == buy.id.uuidString, "exact quote identity")
        expect(rows[0]["service"] as? String == "buy", "quote service preserved")
        expect(rows[0]["deliveryFee"] as? Double == 12.5, "actual delivery fee preserved")
        expect(rows[0]["currency"] as? String == "CNY" && rows[0]["deliveryFeeMinorUnits"] as? Int64 == 1250,
               "Safe DTO exposes explicit currency and integer fen alongside legacy numeric fee")
        expect(rows[0]["goodsFeeMinorUnits"] is NSNull && rows[0]["totalFeeMinorUnits"] is NSNull &&
               rows[1]["goodsFeeMinorUnits"] as? Int64 == 0 && rows[1]["totalFeeMinorUnits"] as? Int64 == 1250,
               "Exact-money unknowns and actual send zero preserve the same completeness semantics")
        expect(rows[0]["goodsFee"] is NSNull && rows[0]["totalFee"] is NSNull,
               "buy goods fee and total remain explicit null")
        expect(rows[0]["goodsFeeKnown"] as? Bool == false && rows[0]["totalFeeKnown"] as? Bool == false,
               "buy unknown cost flags")
        expect(rows[1]["goodsFee"] as? Double == 0 && rows[1]["totalFee"] as? Double == 12.5,
               "send no-purchase zero and delivery total are distinct from buy unknowns")
        expect(rows[1]["goodsFeeKnown"] as? Bool == true && rows[1]["totalFeeKnown"] as? Bool == true,
               "send cost completeness")
        expect(rows[0]["quotedAt"] as? String == "2027-01-15T08:00:00Z", "quote time exact")
        expect(rows[0]["validUntil"] as? String == ISO8601DateFormatter().string(from: buy.validUntil),
               "Safe query expiry is the quote model's single authority")
        if case .quotes(let projected) = result.content {
            expect(projected[0].validUntil == buy.validUntil && projected[0].deliveryAmount == buy.deliveryAmount,
                   "Typed safe quote copies exact money and the canonical expiry")
        } else { preconditionFailure("Expected quote DTO") }
        expect(rows[0]["summary"] as? String == buy.summary, "safe quote summary present")
        expect(rows[0]["request"] == nil && rows[0]["orderToken"] == nil && rows[0]["couponViewID"] == nil,
               "private quote fields absent")
        let malformed = try decode(.quotes([quote(.send, fee: .infinity)], at: time))
        let badRow = (malformed["records"] as! [[String: Any]])[0]
        expect(badRow["deliveryFee"] is NSNull && badRow["totalFee"] is NSNull,
               "nonfinite values cannot break JSON or become false zeros")
        for invalid in [Double.nan, -1, 0.001, 12.345, 0.1 + 0.2] {
            let candidate = quote(.send, fee: invalid)
            expect(!candidate.canSubmit(draft: candidate.draft, account: privateAccount, unresolved: false, now: time),
                   "Invalid money cannot regain submission rights through its display compatibility constructor")
            let malformed = try decode(.quotes([candidate], at: time))
            let row = (malformed["records"] as! [[String: Any]])[0]
            expect(row["deliveryFee"] is NSNull && row["totalFee"] is NSNull &&
                   row["deliveryFeeMinorUnits"] is NSNull && row["totalFeeMinorUnits"] is NSNull,
                   "Invalid precision or amount stays unknown in all numeric projections")
            expect(!(row["summary"] as! String).contains("nan"), "Unknown fee summary is readable and has no nonfinite monetary text")
        }
        let template = quote(.send)
        let exact = PaotuiQuote(id: template.id, draft: template.draft, senderTitle: template.senderTitle,
            recipientTitle: template.recipientTitle, serviceTitle: template.serviceTitle, distance: template.distance,
            estimate: template.estimate, deliveryAmount: try PaotuiMoney(amount: "92233720368547758.07"),
            originalDeliveryAmount: try PaotuiMoney(amount: "12.34"), goodsPaymentNote: template.goodsPaymentNote,
            quotedAt: time, agreementURL: nil, agreementTitle: template.agreementTitle,
            account: privateAccount, request: template.request, orderToken: privateToken, couponViewID: privateCoupon)
        let exactResult = PaotuiQueryResult.quotes([exact], at: time)
        noRetainedSecrets(exactResult)
        let exactJSON = try exactResult.renderJSON()
        expect(exactJSON.contains("\"deliveryFee\":92233720368547758.07") &&
               exactJSON.contains("\"totalFee\":92233720368547758.07") &&
               exactJSON.contains("\"deliveryFeeMinorUnits\":9223372036854775807"),
               "Safe JSON number and explicit minor units retain a maximum exact amount without Double conversion")
        let incomplete = try decode(.quotes([quote(nil)], at: time))
        let unknown = (incomplete["records"] as! [[String: Any]])[0]
        expect(unknown["service"] is NSNull && unknown["serviceKnown"] as? Bool == false,
               "defensive projection cannot assume an unspecified service")
        expect(unknown["goodsFee"] is NSNull && unknown["totalFee"] is NSNull,
               "an unspecified service cannot claim no-purchase zero or a complete total")
    }
    static func boundedLongResults() throws {
        let long = String(repeating: "长地址👩🏽‍💻\\\"\n\u{0000}", count: 4_000)
        let addresses = (0..<45).map { address("address:exact:\($0):" + String(repeating: "r", count: 150), text: long) }
        let addressResult = PaotuiQueryResult.addresses(addresses, total: 61, at: time)
        let places = (0..<45).map { address("poi:exact:\($0):" + String(repeating: "p", count: 150), text: long) }
        let placeResult = PaotuiQueryResult.places(places, total: places.count, at: time)
        let quotes = (0..<30).map { _ in quote(.buy, text: long) }
        let quoteResult = PaotuiQueryResult.quotes(quotes, at: time)
        for (result, refs, total) in [
            (addressResult, Set(addresses.map(\.id)), 61),
            (placeResult, Set(places.map(\.id)), places.count),
            (quoteResult, Set(quotes.map { $0.id.uuidString }), quotes.count)
        ] {
            noRetainedSecrets(result)
            for budget in [512, 1_000, 2_000, 4_096, 11_000] {
                let object = try decode(result, budget: budget)
                expect(object["total"] as? Int == total, "total survives output shrinking")
                expect(object["truncated"] as? Bool == true, "long partial result explicitly flagged")
                let rows = object["records"] as! [[String: Any]]
                expect(rows.count <= 20, "record count bounded")
                for row in rows {
                    let ref = row["reference"] as! String
                    expect(refs.contains(ref), "every emitted reference is a complete exact source reference")
                    expect(row["truncated"] as? Bool == true, "display excerpts flagged per record")
                    expect((row["truncatedFields"] as? [String])?.isEmpty == false,
                           "excerpted fields explicitly named")
                    if object["kind"] as? String == "quotes" {
                        expect(row["goodsFee"] is NSNull && row["totalFee"] is NSNull,
                               "shrinking never changes unknown purchase prices")
                        expect(row["deliveryFee"] as? Double == 12.5 && row["service"] as? String == "buy",
                               "shrinking retains atomic service and fee")
                        expect(row["quotedAt"] as? String == "2027-01-15T08:00:00Z", "shrinking retains time")
                    }
                }
            }
        }
        let hugeRef = "poi:" + String(repeating: "whole-reference-", count: 2_000)
        let omitted = try decode(.places([address(hugeRef)], total: 1, at: time), budget: 512)
        expect((omitted["records"] as! [[String: Any]]).isEmpty, "oversize reference omits whole record")
        expect(omitted["total"] as? Int == 1 && omitted["truncated"] as? Bool == true,
               "omitted atomic reference honestly reported")
        let empty = try decode(.addresses([], total: 0, at: time))
        expect(empty["truncated"] as? Bool == false && empty["total"] as? Int == 0, "true empty not unknown/truncated")
    }
    static func statusAndBudgets() throws {
        let result = PaotuiQueryResult.status(String(repeating: "订单配送中\n\"", count: 10_000), at: time)
        let object = try decode(result, budget: 512)
        expect(object["kind"] as? String == "status", "status uses same envelope")
        expect(object["total"] as? Int == 1 && object["truncated"] as? Bool == true, "status excerpt explicit")
        expect((object["records"] as! [[String: Any]])[0]["truncatedFields"] as? [String] == ["status"],
               "status never cut outside JSON")
        for budget in [-1, 0, 1, 20] {
            do {
                _ = try result.renderJSON(maxCharacters: budget)
                preconditionFailure("insufficient metadata budget must not return an oversized result")
            } catch PaotuiQueryResult.RenderError.budgetTooSmall { checks += 1 }
        }
    }
}
