import Foundation

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
    static func validPhone(_ value: String) -> Bool {
        value.range(of: "^1[0-9]{10}$", options: .regularExpression) != nil
    }
}

struct PaotuiDraft: Equatable {
    var service: PaotuiService = .buy
    var recipientID = ""
    var senderID = ""
    var nearby = false
    var goods = ""
    var remark = ""
    var category: PaotuiCategory = .food
    var weight = 1.0
    func validate() throws {
        guard !recipientID.isEmpty, nearby || !senderID.isEmpty,
              !goods.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goods.count <= 500,
              remark.count <= 500, weight.isFinite, (0.1...50).contains(weight),
              service == .buy || !nearby else { throw AgentError.message("请补齐地址、物品和购买方式") }
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
    let fee: Double
    let originalFee: Double
    let goodsPaymentNote: String
    let quotedAt: Date
    let agreementURL: URL?
    let agreementTitle: String
    let account: String
    let request: [String: Any]
    let orderToken: String
    let couponViewID: String
    var expired: Bool { Date().timeIntervalSince(quotedAt) >= 5 * 60 }
    var feeText: String { fee.formatted(.number.precision(.fractionLength(0...2))) + " 元" }
    func canSubmit(draft: PaotuiDraft, account: String, unresolved: Bool) -> Bool {
        self.draft == draft && self.account == account && !expired && !unresolved && !orderToken.isEmpty
    }
    var summary: String {
        ["服务：" + serviceTitle, "购买／取件：" + senderTitle, "送达：" + recipientTitle,
         "物品：" + draft.goods, "距离：" + distance, "跑腿费：" + feeText, estimate,
         draft.service == .buy ? goodsPaymentNote : "", "尚未创建订单或付款"].filter { !$0.isEmpty }.joined(separator: "\n")
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
            try PaotuiDraft(service: value.action == .preview_buy ? .buy : .send,
                recipientID: value.recipient ?? "", senderID: value.sender ?? "", nearby: value.nearby ?? false,
                goods: value.goods ?? "", remark: value.remark ?? "", category: value.category ?? .food,
                weight: value.weight ?? 1).validate()
        }
        if value.action == .order_status, value.order_id?.isEmpty != false { throw AgentError.message("请提供真实跑腿订单编号") }
        return value
    }
}
