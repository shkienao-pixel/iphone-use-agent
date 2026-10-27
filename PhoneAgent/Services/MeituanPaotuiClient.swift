import Foundation

/// Native implementation of the pinned official MT-Paotui-For-Client wire
/// contract. Requests go directly to Meituan; no Mac/CLI bridge is involved.
struct MeituanPaotuiClient {
    enum Endpoint: String {
        case addresses = "get_address_list", phone = "get_address_info_by_id", search = "search_poi"
        case preview = "delivery_preview", submit = "submit_order", status = "get_order_status"
    }
    let credential: String
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = PaotuiHTTPTransport.load
    var now: () -> Date = Date.init
    static let base = "https://mcp-open-cater.meituan.com/v1/api/paotui/"
    func request(_ endpoint: Endpoint, payload: [String: Any]) throws -> URLRequest {
        guard !credential.isEmpty, credential.utf8.count <= 8192,
              credential.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AgentError.message("请先授权美团跑腿")
        }
        var request = URLRequest(url: URL(string: Self.base + endpoint.rawValue)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential, forHTTPHeaderField: "mtcp-ak")
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body: [String: Any] = ["wm_ctype": "mtiphone", "wm_appversion": "12.49.202", "channel": "wx_miniPrograms",
            "channel_activity_id": "", "platform": "13", "trafficSource": 4, "uuid": identifier,
            "wm_uuid": identifier, "ajaxId": "\(Int(now().timeIntervalSince1970 * 1000))_1532"]
        body.merge(payload) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func call(_ endpoint: Endpoint, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let request = try request(endpoint, payload: payload)
        let (data, response) = try await transport(request)
        // A submit response must reach the local durable receipt even if its
        // initiating view disappears; there is deliberately no automatic retry.
        if endpoint != .submit { try Task.checkCancellation() }
        guard response.url == request.url, (200...299).contains(response.statusCode), data.count <= 1_048_576 else {
            throw AgentError.message(response.statusCode == 401 || response.statusCode == 403 ? "跑腿授权已失效，请重新连接" : "美团跑腿暂时没有返回有效结果")
        }
        return try Self.decode(data)
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentError.message("美团跑腿响应格式无效") }
        let outer = try exactMoneyProjection(in: data, parsed: parsed)
        try checkCode(outer)
        if let result = outer["result"] as? String, result != "SUCCESS" { throw AgentError.message("美团跑腿未确认本次请求") }
        let inner: [String: Any]
        if let text = outer["data"] as? String, let bytes = text.data(using: .utf8),
           let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            inner = try exactMoneyProjection(in: bytes, parsed: object)
        }
        else if let object = outer["data"] as? [String: Any] { inner = object["code"] != nil ? object : ["code": 0, "data": object] }
        else { throw AgentError.message("美团跑腿没有返回业务结果") }
        try checkCode(inner)
        guard let value = inner["data"] as? [String: Any] else { throw AgentError.message("美团跑腿结果不完整") }
        return value
    }
    /// JSONSerialization can round even a valid 17-digit fee into Double.
    /// Walk its already-validated JSON syntax, replacing monetary numeric leaves
    /// with exact Decimal numbers built from the original validated integer fen.
    /// Other fields keep Foundation's existing types and envelope behavior.
    private static func exactMoneyProjection(in data: Data, parsed: [String: Any]) throws -> [String: Any] {
        // This endpoint's JSON is UTF-8. Refuse auto-detected UTF-16/32 input
        // instead of walking its NUL bytes as if they were UTF-8 JSON syntax.
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw AgentError.message("美团跑腿响应编码无效")
        }
        let bytes = [UInt8](data)
        let monetaryKeys: Set<String> = ["total", "totalAmount", "amount"]
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        var cursor = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        func skipWhitespace() { while cursor < bytes.count && whitespace(bytes[cursor]) { cursor += 1 } }
        func stringToken() -> Data {
            let start = cursor; cursor += 1
            while cursor < bytes.count {
                if bytes[cursor] == 92 { cursor += 2 }
                else if bytes[cursor] == 34 { cursor += 1; break }
                else { cursor += 1 }
            }
            return Data(bytes[start..<cursor])
        }
        func value(_ original: Any?, monetary: Bool = false) throws -> Any {
            skipWhitespace()
            switch bytes[cursor] {
            case 123: // object; decoded string keys also cover escaped Unicode.
                cursor += 1; skipWhitespace()
                var object = original as? [String: Any] ?? [:]
                var keys: Set<String> = []
                while bytes[cursor] != 125 {
                    let key = try JSONDecoder().decode(String.self, from: stringToken())
                    guard keys.insert(key).inserted else { throw AgentError.message("美团跑腿响应包含重复字段，请重新查询") }
                    skipWhitespace(); cursor += 1 // colon
                    object[key] = try value(object[key], monetary: monetaryKeys.contains(key))
                    skipWhitespace()
                    if bytes[cursor] == 44 { cursor += 1; skipWhitespace() }
                    else { break }
                }
                cursor += 1; return object
            case 91: // array
                cursor += 1; skipWhitespace()
                let existing = original as? [Any] ?? []
                var array: [Any] = []
                while bytes[cursor] != 93 {
                    array.append(try value(array.count < existing.count ? existing[array.count] : nil))
                    skipWhitespace()
                    if bytes[cursor] == 44 { cursor += 1; skipWhitespace() }
                    else { break }
                }
                cursor += 1; return array
            case 34:
                _ = stringToken(); return original ?? NSNull()
            default:
                let start = cursor
                while cursor < bytes.count && !whitespace(bytes[cursor]) && ![44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
                if monetary, bytes[start] == 45 || (48...57).contains(bytes[start]) {
                    let amount: PaotuiMoney
                    do { amount = try PaotuiMoney(amount: String(decoding: bytes[start..<cursor], as: UTF8.self)) }
                    catch { throw AgentError.message("美团报价金额无效或精度不受支持，请重新询价") }
                    return NSDecimalNumber(mantissa: UInt64(amount.minorUnits), exponent: -2, isNegative: false)
                }
                return original ?? NSNull()
            }
        }
        return try value(parsed) as! [String: Any]
    }
    static func checkCode(_ object: [String: Any]) throws {
        let code = (object["code"] as? NSNumber)?.intValue ?? Int(object["code"] as? String ?? "")
        if let code, code != 0 && code != 200 {
            let message: String
            switch code {
            case 10000, 401: message = "跑腿授权已失效，请重新连接"
            case 10309: message = "配送费发生变化，请重新询价并确认"
            case 10310: message = "账号暂时无法下单，请在美团 App 中查看原因"
            case 10311: message = "报价已过期，请重新查询费用"
            case 10112, 10113: message = "这个地址暂未开通跑腿服务"
            case 10114: message = "这个地址暂时无法配送，请稍后重试"
            case 10115: message = "取送距离超出服务范围"
            case 10116: message = "请提供更精确的地址"
            case 40001: message = "跑腿不支持代购药品或医疗器械"
            default: message = "美团跑腿请求未完成（\(code)），请核对信息后重试"
            }
            throw AgentError.message(message)
        }
        if object["errorInfo"] is [String: Any] { throw AgentError.message("美团跑腿未完成本次请求") }
    }
    func addresses() async throws -> [PaotuiAddress] {
        let data = try await call(.addresses, ["addressType": "1", "businessType": "1", "scene": "2"])
        guard let rows = data["userAddresses"] as? [[String: Any]] else { throw AgentError.message("暂时无法读取跑腿收货地址") }
        return rows.prefix(200).compactMap { row in
            guard row["invalid"] as? Bool != true, row["disable"] as? Bool != true,
                  let id = row["id"] as? NSNumber, let lat = row["latitude"] as? Int, let lng = row["longitude"] as? Int,
                  let city = row["bmCityId"] as? Int, let address = row["address"] as? String else { return nil }
            return PaotuiAddress(id: "address:" + id.stringValue, name: address, address: address,
                houseNumber: row["houseNumber"] as? String ?? "", contact: row["name"] as? String ?? "",
                maskedPhone: Self.masked(row["phone"] as? String ?? ""), latitude: lat, longitude: lng,
                cityID: city, savedID: id.int64Value, lastUse: (row["lastUseTime"] as? Double) ?? 0)
        }.sorted { $0.lastUse > $1.lastUse }
    }
    func phone(_ address: PaotuiAddress) async throws -> String {
        guard let id = address.savedID else { throw AgentError.message("请在美团 App 中保存完整联系人地址后重试") }
        let result = try await call(.phone, ["addressId": String(id)])
        guard let phone = result["phone"] as? String, PaotuiAddress.validPhone(phone) else { throw AgentError.message("美团暂未提供完整联系电话，请在美团 App 中核对地址") }
        return phone
    }
    /// The API adapter owns the pinned preview wire format and transient phone
    /// lookup. The Store supplies canonical current references and a validation
    /// callback so every asynchronous boundary still revokes stale authority.
    @MainActor func preview(readyRequest current: PaotuiReadyRequest, sender: PaotuiAddress,
                            recipient: PaotuiAddress, account: String,
                            validate: () throws -> Void) async throws -> [PaotuiQuote] {
        try validate()
        let recipientPhone = try await phone(recipient); try validate()
        let senderPhone: String
        if sender.savedID != nil, sender.id != recipient.id { senderPhone = try await phone(sender) }
        else { senderPhone = recipientPhone }
        try validate()
        let senderWire = try sender.wire(phone: senderPhone, fallback: recipient)
        let recipientWire = try recipient.wire(phone: recipientPhone)
        var base: [String: Any] = ["sender": senderWire, "recipient": recipientWire,
            "businessType": current.service == .buy ? 2 : 1, "bizTypeSceneTag": 0,
            "location_city_id": recipient.cityID, "tipFee": 0, "remark": current.remark,
            "orderMode": "4", "needRecommendCoupon": "1", "lat": String(recipient.latitude), "lng": String(recipient.longitude)]
        if current.service == .buy {
            base["businessTypeTag"] = current.nearby ? 1 : 0; base["purchaseGoodDetail"] = current.goods
        } else {
            guard let category = current.category, let weight = current.weight else { throw AgentError.message("请补齐实际取送重量与品类") }
            let goods: [String: Any] = ["goodsName": current.goods, "goodsWeight": weight,
                "goodTypes": [category.code], "goodTypeNames": [category.title]]
            base["goods"] = goods
            base["goodsInfo"] = String(data: try JSONSerialization.data(withJSONObject: goods, options: [.sortedKeys]), encoding: .utf8)!
            base["goodWeight"] = String(weight); base["businessTypeTag"] = 0; base["purchaseGoodDetail"] = ""
        }
        let services: [Int?] = current.service == .buy ? [nil] : [1003, 4033]
        var results: [PaotuiQuote] = []
        for service in services {
            var payload = base; if let service { payload["serviceType"] = service }
            let data = try await call(.preview, payload); try validate()
            results.append(try Self.quote(data: data, draft: current.draft, sender: sender, recipient: recipient,
                request: payload, account: account, service: service, quotedAt: now()))
        }
        return results
    }
    func search(keyword: String, city: String, near: PaotuiAddress?) async throws -> [PaotuiAddress] {
        guard !keyword.isEmpty, keyword.count <= 120, !city.isEmpty, city.count <= 40 else { throw AgentError.message("请填写城市和地址关键词") }
        var payload: [String: Any] = ["keyword": keyword, "city": city]
        if let near { payload["lat"] = near.latitude; payload["lng"] = near.longitude }
        let data = try await call(.search, payload)
        guard let result = data["result"] as? [String: Any], let rows = result["pois"] as? [[String: Any]] else { throw AgentError.message("没有找到匹配地址，请补充店名或街道") }
        let values = rows.prefix(100).compactMap { row -> PaotuiAddress? in
            guard let id = row["id"] as? String, let title = row["name"] as? String,
                  let address = row["address"] as? String, let location = row["location"] as? String else { return nil }
            let pieces = location.split(separator: ",").compactMap { Double($0) }
            guard pieces.count == 2, pieces.allSatisfy(\.isFinite), abs(pieces[0]) <= 180, abs(pieces[1]) <= 90 else { return nil }
            let cityCode = (row["addr_info"] as? [[String: Any]])?.first(where: { ($0["level_desc"] as? String) == "city" })?["admin_code"] as? String
            guard let cityID = cityCode.flatMap(Int.init) else { return nil }
            return PaotuiAddress(id: "poi:" + id, name: title, address: address, houseNumber: title,
                contact: "", maskedPhone: "", latitude: Int((pieces[1] * 1e6).rounded()), longitude: Int((pieces[0] * 1e6).rounded()),
                cityID: cityID, savedID: nil, lastUse: 0)
        }
        return near.map { near in values.sorted { $0.distance(to: near) < $1.distance(to: near) } } ?? values
    }
    static func masked(_ phone: String) -> String {
        guard PaotuiAddress.validPhone(phone) else { return phone.contains("*") ? phone : "" }
        return String(phone.prefix(3)) + "****" + String(phone.suffix(4))
    }
    static func quote(data: [String: Any], draft: PaotuiDraft, sender: PaotuiAddress, recipient: PaotuiAddress,
                      request: [String: Any], account: String, service: Int?, quotedAt: Date = Date()) throws -> PaotuiQuote {
        let fee = data["deliveryFeeView"] as? [String: Any] ?? [:]
        guard let originalValue = fee["totalAmount"], let totalValue = data["total"],
              let original = try? PaotuiMoney(providerValue: originalValue),
              let total = try? PaotuiMoney(providerValue: totalValue),
              let token = data["orderToken"] as? String, !token.isEmpty,
              let distance = data["distanceDesc"] as? String, !distance.isEmpty else { throw AgentError.message("美团未返回完整报价，请重新询价") }
        let config = data["commonConfig"] as? [String: Any] ?? [:]
        let agreement = data["userAgreement"] as? [String: Any] ?? [:]
        let coupon = data["couponPreviewView"] as? [String: Any] ?? [:]
        // The endpoint contract is CNY. If the provider declares a currency,
        // do not interpret another currency's digits as fen.
        for amount in [data, fee, coupon] {
            if let currency = amount["currency"], currency as? String != PaotuiMoney.Currency.cny.rawValue {
                throw AgentError.message("美团报价币种不受支持，请重新询价")
            }
        }
        let couponAmount: PaotuiMoney?
        if let value = coupon["amount"] {
            guard let amount = try? PaotuiMoney(providerValue: value) else {
                throw AgentError.message("美团优惠报价金额无效，请重新询价")
            }
            couponAmount = amount
        } else { couponAmount = nil }
        let couponText: String
        if let couponAmount, couponAmount.minorUnits > 0 {
            guard let identifier = coupon["couponViewId"] as? String, !identifier.isEmpty else {
                throw AgentError.message("美团优惠报价不完整，请重新询价")
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
            couponText = identifier.addingPercentEncoding(withAllowedCharacters: allowed)!
        } else { couponText = "" }
        let title = draft.service == .buy ? "帮买" : service == 4033 ? "帮取送 · 1对1急送" : "帮取送 · 普通送"
        return PaotuiQuote(id: UUID(), draft: draft, senderTitle: draft.nearby ? "骑手就近购买" : sender.fullAddress,
            recipientTitle: recipient.fullAddress, serviceTitle: title, distance: distance,
            estimate: [data["waitTimeDesc4WX"] as? String, data["estimateDeliveryTimeText"] as? String].compactMap { $0 }.joined(separator: "，"),
            deliveryAmount: total, originalDeliveryAmount: original, goodsPaymentNote: config["goodsPayDesc"] as? String ?? "跑腿费不含商品费，餐价和库存由骑手到店核实。",
            quotedAt: quotedAt, agreementURL: (agreement["userAgreementUrl"] as? String).flatMap(Self.officialURL),
            agreementTitle: agreement["userAgreementName"] as? String ?? "跑腿服务协议", account: account,
            request: request, orderToken: token, couponViewID: couponText)
    }
    static func officialURL(_ text: String) -> URL? {
        guard let c = URLComponents(string: text), c.scheme == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, let host = c.host?.lowercased(),
              ["meituan.com", "meituan.net", "dianping.com", "dpurl.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return c.url
    }
}
