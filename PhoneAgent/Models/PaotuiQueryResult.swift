import Foundation

/// The shared read boundary. Projection happens on creation: this value cannot
/// retain a request payload, credential, account, full phone or quote token.
struct PaotuiQueryResult {
    struct AddressRecord: Equatable {
        let reference: String
        let name: String
        let address: String
        let contact: String
        let phone: String
        let city: String

        fileprivate init(_ value: PaotuiAddress) {
            reference = value.id; name = PaotuiAddress.redactingPhones(value.name)
            address = PaotuiAddress.redactingPhones(value.fullAddress)
            contact = PaotuiAddress.redactingPhones(value.contact); city = PaotuiAddress.redactingPhones(value.city)
            // Do not trust a caller to have already masked this display field.
            if PaotuiAddress.validPhone(value.maskedPhone) {
                phone = String(value.maskedPhone.prefix(3)) + "****" + String(value.maskedPhone.suffix(4))
            } else if value.maskedPhone.range(of: "^[0-9]{3}\\*{4}[0-9]{4}$", options: .regularExpression) != nil {
                phone = value.maskedPhone
            } else { phone = "" }
        }
    }

    struct QuoteRecord: Equatable {
        let reference: String
        let service: PaotuiService?
        let serviceTitle: String
        let sender: String
        let recipient: String
        let goods: String
        let distance: String
        let estimate: String
        let deliveryAmount: PaotuiMoney?
        let originalDeliveryAmount: PaotuiMoney?
        let goodsAmount: PaotuiMoney?
        let totalAmount: PaotuiMoney?
        var deliveryFee: Double? { deliveryAmount?.displayValue }
        var originalDeliveryFee: Double? { originalDeliveryAmount?.displayValue }
        var goodsFee: Double? { goodsAmount?.displayValue }
        var totalFee: Double? { totalAmount?.displayValue }
        let goodsPaymentNote: String
        let quotedAt: Date
        let validUntil: Date
        let summary: String

        fileprivate init(_ value: PaotuiQuote) {
            reference = value.id.uuidString; service = value.draft.service
            serviceTitle = PaotuiAddress.redactingPhones(value.serviceTitle)
            sender = PaotuiAddress.redactingPhones(value.senderTitle)
            recipient = PaotuiAddress.redactingPhones(value.recipientTitle)
            goods = PaotuiAddress.redactingPhones(value.draft.goods)
            distance = PaotuiAddress.redactingPhones(value.distance); estimate = PaotuiAddress.redactingPhones(value.estimate)
            deliveryAmount = value.deliveryAmount
            originalDeliveryAmount = value.originalDeliveryAmount
            // A delivery quote is not evidence of a purchase price. For send,
            // zero means there is no purchase, rather than an unknown price.
            goodsAmount = value.draft.service == .send ? try? PaotuiMoney(minorUnits: 0) : nil
            totalAmount = value.draft.service == .send ? value.deliveryAmount : nil
            goodsPaymentNote = PaotuiAddress.redactingPhones(value.goodsPaymentNote)
            quotedAt = value.quotedAt; validUntil = value.validUntil
            summary = PaotuiAddress.redactingPhones(value.summary)
        }
    }

    struct StatusRecord: Equatable { let status: String }
    enum Content {
        case addresses([AddressRecord])
        case places([AddressRecord])
        case quotes([QuoteRecord])
        case status(StatusRecord)
    }
    enum RenderError: LocalizedError {
        case budgetTooSmall
        var errorDescription: String? { "跑腿查询结果的长度上限不足以容纳结果信息" }
    }
    struct Rendered {
        let json: String
        /// Only references in records that survived the output budget.
        let references: Set<String>
    }

    let content: Content
    let queriedAt: Date
    /// Number of matching records before this read boundary's output limits.
    let total: Int
    static let source = "meituan_paotui"

    private init(content: Content, total: Int, at: Date) {
        self.content = content; self.total = max(0, total); queriedAt = at
    }
    static func addresses(_ values: [PaotuiAddress], total: Int, at: Date = Date()) -> Self {
        .init(content: .addresses(values.map(AddressRecord.init)), total: max(total, values.count), at: at)
    }
    static func places(_ values: [PaotuiAddress], total: Int, at: Date = Date()) -> Self {
        .init(content: .places(values.map(AddressRecord.init)), total: max(total, values.count), at: at)
    }
    static func quotes(_ values: [PaotuiQuote], at: Date = Date()) -> Self {
        .init(content: .quotes(values.map(QuoteRecord.init)), total: values.count, at: at)
    }
    /// `text` must be the order service's selected status description, never a
    /// provider response, order request or payment URL.
    static func status(_ text: String, at: Date = Date()) -> Self {
        .init(content: .status(.init(status: PaotuiAddress.redactingPhones(text))), total: 1, at: at)
    }

    /// Always emits a complete JSON object within the requested character
    /// budget. References, prices and times are atomic; only display strings
    /// may become flagged excerpts. If metadata cannot fit, no result is emitted.
    func renderJSON(maxCharacters: Int = 11_000) throws -> String {
        try render(maxCharacters: maxCharacters).json
    }
    func render(maxCharacters: Int = 11_000) throws -> Rendered {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: queriedAt)
        let kind: String
        let available: Int
        switch content {
        case .addresses(let rows): kind = "addresses"; available = rows.count
        case .places(let rows): kind = "places"; available = rows.count
        case .quotes(let rows): kind = "quotes"; available = rows.count
        case .status: kind = "status"; available = 1
        }
        func encode(_ rows: [[String: Any]], fieldsTruncated: Bool) throws -> Rendered {
            let object: [String: Any] = [
                "source": Self.source, "queriedAt": stamp, "kind": kind,
                "records": rows, "total": total, "returned": rows.count,
                "truncated": rows.count < total || rows.count < available || fieldsTruncated
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return Rendered(json: String(decoding: data, as: UTF8.self),
                references: Set(rows.compactMap { $0["reference"] as? String }))
        }
        let empty = try encode([], fieldsTruncated: false)
        guard maxCharacters >= empty.json.count else { throw RenderError.budgetTooSmall }

        var count = min(20, available)
        // Bound excerpts before dropping records. A quote's ID/service/fees/time
        // are never excerpted, including when the enclosing record is omitted.
        var fieldLimit = 512
        while count > 0 {
            let rows = records(count: count, fieldLimit: fieldLimit, formatter: formatter)
            let shortened = rows.contains { ($0["truncated"] as? Bool) == true }
            let json = try encode(rows, fieldsTruncated: shortened)
            if json.json.count <= maxCharacters { return json }
            if fieldLimit > 32 { fieldLimit /= 2 }
            else { count -= 1 }
        }
        return empty
    }

    private func records(count: Int, fieldLimit: Int, formatter: ISO8601DateFormatter) -> [[String: Any]] {
        func display(_ fields: [(String, String)], atomic: [String: Any]) -> [String: Any] {
            var record = atomic
            var shortened: [String] = []
            for (key, value) in fields {
                if value.count > fieldLimit {
                    record[key] = String(value.prefix(fieldLimit)); shortened.append(key)
                } else { record[key] = value }
            }
            record["truncated"] = !shortened.isEmpty
            record["truncatedFields"] = shortened
            return record
        }
        func address(_ value: AddressRecord) -> [String: Any] {
            display([("name", value.name), ("address", value.address), ("contact", value.contact),
                     ("city", value.city)], atomic: ["reference": value.reference, "phone": value.phone])
        }
        func nullable(_ value: PaotuiMoney?) -> Any {
            // JSON numbers remain the public contract; NSDecimalNumber writes
            // the exact integer-fen value instead of the Double display value.
            value.map { NSDecimalNumber(mantissa: UInt64($0.minorUnits), exponent: -2, isNegative: false) as Any } ?? NSNull()
        }
        func minorUnits(_ value: PaotuiMoney?) -> Any { value.map { $0.minorUnits as Any } ?? NSNull() }
        switch content {
        case .addresses(let rows), .places(let rows):
            return rows.prefix(count).map(address)
        case .quotes(let rows):
            return rows.prefix(count).map { value in
                display([("serviceTitle", value.serviceTitle), ("sender", value.sender),
                         ("recipient", value.recipient), ("goods", value.goods),
                         ("distance", value.distance), ("estimate", value.estimate),
                         ("goodsPaymentNote", value.goodsPaymentNote), ("summary", value.summary)], atomic: [
                    "reference": value.reference, "service": value.service.map { $0.rawValue as Any } ?? NSNull(),
                    "serviceKnown": value.service != nil,
                    "currency": PaotuiMoney.Currency.cny.rawValue,
                    "deliveryFee": nullable(value.deliveryAmount), "originalDeliveryFee": nullable(value.originalDeliveryAmount),
                    "goodsFee": nullable(value.goodsAmount), "totalFee": nullable(value.totalAmount),
                    "deliveryFeeMinorUnits": minorUnits(value.deliveryAmount),
                    "originalDeliveryFeeMinorUnits": minorUnits(value.originalDeliveryAmount),
                    "goodsFeeMinorUnits": minorUnits(value.goodsAmount), "totalFeeMinorUnits": minorUnits(value.totalAmount),
                    "goodsFeeKnown": value.goodsAmount != nil, "totalFeeKnown": value.totalAmount != nil,
                    "quotedAt": formatter.string(from: value.quotedAt),
                    "validUntil": formatter.string(from: value.validUntil)
                ])
            }
        case .status(let value): return [display([("status", value.status)], atomic: [:])]
        }
    }
}
