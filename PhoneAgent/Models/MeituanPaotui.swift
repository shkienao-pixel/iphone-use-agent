import Foundation
import CoreFoundation

enum PaotuiService: String, Codable, CaseIterable, Identifiable {
    case buy, send
    var id: String { rawValue }
    var title: String { self == .buy ? "帮买" : "帮取送" }
}

enum PaotuiCategory: String, Codable, CaseIterable, Identifiable {
    case food, document, fresh, cake, flowers, digital, clothing, parcel, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .food: "餐饮"
        case .document: "文件"
        case .fresh: "生鲜"
        case .cake: "蛋糕"
        case .flowers: "鲜花"
        case .digital: "数码"
        case .clothing: "服饰"
        case .parcel: "快递"
        case .other: "其他"
        }
    }
    var code: Int {
        switch self {
        case .food: 2
        case .document: 4
        case .fresh: 3
        case .cake: 9
        case .flowers: 1
        case .digital: 5
        case .clothing: 7
        case .parcel, .other: 8
        }
    }
}

struct PaotuiAddress: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let houseNumber: String
    let contact: String
    let maskedPhone: String
    let latitude: Int
    let longitude: Int
    let cityID: Int
    let savedID: Int64?
    let lastUse: Double
    var title: String { name.isEmpty ? address : name }
    var fullAddress: String { [address, houseNumber].filter { !$0.isEmpty }.joined(separator: " ") }
    var city: String {
        [440300: "深圳", 440100: "广州", 110100: "北京", 310100: "上海", 450100: "南宁",
         360200: "景德镇", 410100: "郑州", 411300: "南阳", 210200: "大连", 510100: "成都"][cityID] ?? ""
    }
    func distance(to other: Self) -> Double {
        let a = Double(latitude) / 1e6 * .pi / 180, b = Double(other.latitude) / 1e6 * .pi / 180
        let x = sin((b - a) / 2), y = sin(Double(other.longitude - longitude) / 1e6 * .pi / 360)
        let h = min(1, max(0, x * x + cos(a) * cos(b) * y * y))
        return 6_371_000 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }
    func wire(phone: String, fallback: PaotuiAddress? = nil) throws -> [String: Any] {
        guard Self.validPhone(phone), !address.isEmpty, abs(latitude) <= 90_000_000,
              abs(longitude) <= 180_000_000, latitude != 0, longitude != 0, cityID > 0 else {
            throw AgentError.message("请核对完整地址和联系电话")
        }
        return ["address": address, "houseNumber": houseNumber, "lat": latitude, "lng": longitude,
                "name": contact.isEmpty ? (fallback?.contact ?? "") : contact, "phone": phone,
                "cityId": cityID, "addressId": savedID ?? 0]
    }
    /// Redact phone-like text at every display projection, regardless of the
    /// provider field's label. The execution address and request stay intact.
    static func redactingPhones(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![0-9])(?:\+?86[ -]?)?1[0-9]{2}[ -]?[0-9]{4}[ -]?[0-9]{4}(?![0-9])"#) else { return value }
        var result = value
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let sourceRange = Range(match.range, in: value), let replacementRange = Range(match.range, in: result) else { continue }
            var digits = value[sourceRange].filter { $0.isNumber }
            if digits.count == 13, digits.hasPrefix("86") { digits.removeFirst(2) }
            guard digits.count == 11 else { continue }
            result.replaceSubrange(replacementRange, with: String(digits.prefix(3)) + "****" + String(digits.suffix(4)))
        }
        return result
    }
    static func validPhone(_ value: String) -> Bool {
        value.range(of: "^1[0-9]{10}$", options: .regularExpression) != nil
    }
}

enum PaotuiMissingField: String, Equatable {
    case service, goods, weight, category, recipient, purchaseMethod, sender

    var message: String {
        switch self {
        case .service: "请选择帮买或帮取送"
        case .goods: "请补充需要购买或取送的物品"
        case .weight: "帮取送需要实际物品重量，请补充公斤数后再询价"
        case .category: "帮取送需要物品品类，请根据实际物品确定后再询价"
        case .recipient: "请选择送达地址"
        case .purchaseMethod: "请选择附近购买或指定购买地址"
        case .sender: "请选择取件地址"
        }
    }
}

/// An editable requirement may be incomplete. Unknown fields stay unknown until
/// a person or an interpretation grounded in their request supplies them.
struct PaotuiDraft: Equatable {
    var service: PaotuiService?
    var recipientID = ""
    var senderID = ""
    var nearby = false
    var goods = ""
    var remark = ""
    var category: PaotuiCategory?
    var weight: Double?

    var missingFields: [PaotuiMissingField] {
        var fields: [PaotuiMissingField] = []
        if service == nil { fields.append(.service) }
        if goods.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append(.goods) }
        if recipientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append(.recipient) }
        switch service {
        case .buy:
            if !nearby && senderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append(.purchaseMethod) }
        case .send:
            if weight == nil { fields.append(.weight) }
            if category == nil { fields.append(.category) }
            if senderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append(.sender) }
        case nil: break
        }
        return fields
    }

    func validated() throws -> PaotuiReadyRequest {
        if let missing = missingFields.first { throw AgentError.message(missing.message) }
        guard let service else { throw AgentError.message(PaotuiMissingField.service.message) }
        guard goods.count <= 500, remark.count <= 500 else {
            throw AgentError.message("物品或备注过长，请控制在 500 字以内")
        }
        if service == .send {
            guard let weight, weight.isFinite, (0.1...50).contains(weight) else {
                throw AgentError.message("请填写 0.1 到 50 公斤的实际物品重量")
            }
            guard !nearby else { throw AgentError.message("帮取送需要实际取件地址，不能使用附近购买") }
        }
        return PaotuiReadyRequest(draft: self, service: service)
    }

    func validate() throws { _ = try validated() }
}

/// A validated, immutable request. Send requests always carry actual category
/// and weight; buy requests can leave those unused fields unknown.
struct PaotuiReadyRequest: Equatable {
    let service: PaotuiService
    let recipientID: String
    let senderID: String
    let nearby: Bool
    let goods: String
    let remark: String
    let category: PaotuiCategory?
    let weight: Double?

    fileprivate init(draft: PaotuiDraft, service: PaotuiService) {
        self.service = service; recipientID = draft.recipientID; senderID = draft.senderID
        nearby = draft.nearby; goods = draft.goods; remark = draft.remark
        category = draft.category; weight = draft.weight
    }

    var draft: PaotuiDraft {
        PaotuiDraft(service: service, recipientID: recipientID, senderID: senderID, nearby: nearby,
                    goods: goods, remark: remark, category: category, weight: weight)
    }
}

/// Money accepted for this CNY-only provider. Integer fen are the authority;
/// Double exists only as a compatibility display projection, never for a send.
struct PaotuiMoney: Codable, Equatable, Comparable {
    enum Currency: String, Codable { case cny = "CNY" }
    enum ValidationError: Error { case invalidAmount, unsupportedPrecision, overflow }
    let currency: Currency
    let minorUnits: Int64

    init(minorUnits: Int64, currency: Currency = .cny) throws {
        guard minorUnits >= 0 else { throw ValidationError.invalidAmount }
        self.currency = currency; self.minorUnits = minorUnits
    }

    /// Parse digits directly so neither Decimal's precision limit nor binary
    /// floating point can silently round a provider amount before validation.
    init(amount: String, currency: Currency = .cny) throws {
        guard amount.utf8.count <= 128,
              amount.range(of: "^[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil else {
            throw ValidationError.invalidAmount
        }
        let parts = amount.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (-128...128).contains(parsed) else { throw ValidationError.overflow }
            exponent = parsed
        } else { exponent = 0 }
        let decimal = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let fractionCount = decimal.count == 2 ? decimal[1].count : 0
        var digits = decimal.joined().drop(while: { $0 == "0" }).description
        if digits.isEmpty { try self.init(minorUnits: 0, currency: currency); return }
        let power = 2 + exponent - fractionCount
        if power >= 0 {
            guard digits.count + power <= 19 else { throw ValidationError.overflow }
            digits += String(repeating: "0", count: power)
        } else {
            let discarded = -power
            guard discarded <= digits.count,
                  digits.suffix(discarded).allSatisfy({ $0 == "0" }) else { throw ValidationError.unsupportedPrecision }
            digits = String(digits.dropLast(discarded))
        }
        guard let cents = Int64(digits) else { throw ValidationError.overflow }
        try self.init(minorUnits: cents, currency: currency)
    }

    init(providerValue: Any) throws {
        guard let number = providerValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ValidationError.invalidAmount
        }
        try self.init(amount: number.stringValue)
    }
    init(displayValue: Double) throws {
        guard displayValue.isFinite, displayValue >= 0 else { throw ValidationError.invalidAmount }
        try self.init(amount: String(displayValue))
    }
    var displayValue: Double { Double(minorUnits) / 100 }
    /// Preserve the existing provider string contract, including an integral .0.
    var wireAmount: String {
        let whole = minorUnits / 100, fraction = minorUnits % 100
        if fraction == 0 { return "\(whole).0" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)" }
        return "\(whole)." + (fraction < 10 ? "0" : "") + String(fraction)
    }
    var displayText: String { wireAmount.hasSuffix(".0") ? String(wireAmount.dropLast(2)) : wireAmount }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.minorUnits < rhs.minorUnits }
    private enum CodingKeys: String, CodingKey { case currency, minorUnits }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(minorUnits: fields.decode(Int64.self, forKey: .minorUnits),
                      currency: fields.decode(Currency.self, forKey: .currency))
    }
}

/// A short-lived, exact request snapshot. Neither private phones nor the order
/// token enter model context. Submission is available only from native review UI.
struct PaotuiQuote: Identifiable {
    let id: UUID
    let draft: PaotuiDraft
    let senderTitle: String
    let recipientTitle: String
    let serviceTitle: String
    let distance: String
    let estimate: String
    let deliveryAmount: PaotuiMoney?
    let originalDeliveryAmount: PaotuiMoney?
    var fee: Double { deliveryAmount?.displayValue ?? .nan }
    var originalFee: Double { originalDeliveryAmount?.displayValue ?? .nan }
    let goodsPaymentNote: String
    let quotedAt: Date
    let agreementURL: URL?
    let agreementTitle: String
    let account: String
    let request: [String: Any]
    let orderToken: String
    let couponViewID: String
    static let lifetime: TimeInterval = 5 * 60
    var validUntil: Date { quotedAt.addingTimeInterval(Self.lifetime) }
    var expired: Bool { isExpired(at: Date()) }
    func isExpired(at date: Date) -> Bool { date >= validUntil }
    var feeText: String { deliveryAmount.map { $0.displayText + " 元" } ?? "费用待核实" }

    init(id: UUID, draft: PaotuiDraft, senderTitle: String, recipientTitle: String, serviceTitle: String,
         distance: String, estimate: String, deliveryAmount: PaotuiMoney?, originalDeliveryAmount: PaotuiMoney?,
         goodsPaymentNote: String, quotedAt: Date, agreementURL: URL?, agreementTitle: String,
         account: String, request: [String: Any], orderToken: String, couponViewID: String) {
        self.id = id; self.draft = draft; self.senderTitle = senderTitle; self.recipientTitle = recipientTitle
        self.serviceTitle = serviceTitle; self.distance = distance; self.estimate = estimate
        self.deliveryAmount = deliveryAmount; self.originalDeliveryAmount = originalDeliveryAmount
        self.goodsPaymentNote = goodsPaymentNote; self.quotedAt = quotedAt
        self.agreementURL = agreementURL; self.agreementTitle = agreementTitle; self.account = account
        self.request = request; self.orderToken = orderToken; self.couponViewID = couponViewID
    }
    /// Compatibility for old in-process callers. Invalid fees become unknown,
    /// and cannot authorize an order or be recorded as a monetary fact.
    init(id: UUID, draft: PaotuiDraft, senderTitle: String, recipientTitle: String, serviceTitle: String,
         distance: String, estimate: String, fee: Double, originalFee: Double, goodsPaymentNote: String,
         quotedAt: Date, agreementURL: URL?, agreementTitle: String, account: String,
         request: [String: Any], orderToken: String, couponViewID: String) {
        self.init(id: id, draft: draft, senderTitle: senderTitle, recipientTitle: recipientTitle,
                  serviceTitle: serviceTitle, distance: distance, estimate: estimate,
                  deliveryAmount: try? PaotuiMoney(displayValue: fee),
                  originalDeliveryAmount: try? PaotuiMoney(displayValue: originalFee),
                  goodsPaymentNote: goodsPaymentNote, quotedAt: quotedAt, agreementURL: agreementURL,
                  agreementTitle: agreementTitle, account: account, request: request,
                  orderToken: orderToken, couponViewID: couponViewID)
    }
    func canSubmit(draft: PaotuiDraft, account: String, unresolved: Bool, now: Date = Date()) -> Bool {
        self.draft == draft && self.account == account && !isExpired(at: now) && !unresolved && !orderToken.isEmpty
            && deliveryAmount != nil && originalDeliveryAmount != nil
    }
    var summary: String {
        ["服务：" + serviceTitle, "购买／取件：" + senderTitle, "送达：" + recipientTitle,
         "物品：" + draft.goods, "距离：" + distance, "跑腿费：" + feeText, estimate,
         draft.service == .buy ? goodsPaymentNote : "", "尚未创建订单或付款"].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var senderContact: String? { Self.safeContact(request["sender"]) }
    var recipientContact: String? { Self.safeContact(request["recipient"]) }
    private static func safeContact(_ value: Any?) -> String? {
        guard let row = value as? [String: Any], let phone = row["phone"] as? String,
              PaotuiAddress.validPhone(phone) else { return nil }
        let masked = String(phone.prefix(3)) + "****" + String(phone.suffix(4))
        let name = String(PaotuiAddress.redactingPhones(row["name"] as? String ?? "").prefix(100))
        return [name, masked].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct PaotuiToolQuery: Decodable {
    enum Action: String, Decodable { case addresses, search, preview_buy, preview_send, order_status }
    let action: Action
    var keyword: String?
    var city: String?
    var recipient: String?
    var sender: String?
    var goods: String?
    var nearby: Bool?
    var category: PaotuiCategory?
    var weight: Double?
    var remark: String?
    var order_id: String?
    func validatedDraft() throws -> PaotuiDraft {
        guard [.preview_buy, .preview_send].contains(action) else {
            throw AgentError.message("这个跑腿操作不提供询价需求")
        }
        let service: PaotuiService = action == .preview_buy ? .buy : .send
        let draft = PaotuiDraft(service: service, recipientID: recipient ?? "", senderID: sender ?? "",
            nearby: nearby ?? false, goods: goods ?? "", remark: remark ?? "", category: category, weight: weight)
        return try draft.validated().draft
    }
    static func decode(_ text: String) throws -> Self {
        guard let data = text.data(using: .utf8), data.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["action", "keyword", "city", "recipient", "sender", "goods", "nearby", "category", "weight", "remark", "order_id"]) else {
            throw AgentError.message("跑腿查询参数无效")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard (value.keyword?.count ?? 0) <= 120, (value.city?.count ?? 0) <= 40,
              (value.goods?.count ?? 0) <= 500, (value.remark?.count ?? 0) <= 500,
              (value.recipient?.count ?? 0) <= 100, (value.sender?.count ?? 0) <= 100,
              (value.order_id?.count ?? 0) <= 100 else { throw AgentError.message("跑腿查询参数过长") }
        if value.action == .search {
            guard value.keyword?.isEmpty == false, value.city?.isEmpty == false else { throw AgentError.message("搜索地址需要城市和关键词") }
        }
        if [.preview_buy, .preview_send].contains(value.action) {
            _ = try value.validatedDraft()
        }
        if value.action == .order_status, value.order_id?.isEmpty != false { throw AgentError.message("请提供真实跑腿订单编号") }
        return value
    }
}
