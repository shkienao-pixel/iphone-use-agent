import Foundation
import Combine
import CryptoKit
import UIKit

@MainActor final class MeituanPaotuiStore: ObservableObject {
    static let shared = MeituanPaotuiStore()
    @Published var draft = PaotuiDraft() {
        didSet {
            if oldValue != draft { quotes = []; paymentURL = nil }
        }
    }
    @Published private(set) var addresses: [PaotuiAddress] = []
    @Published private(set) var places: [PaotuiAddress] = []
    private var cachedPlaces: [PaotuiAddress] = []
    @Published private(set) var quotes: [PaotuiQuote] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var message = ""
    @Published private(set) var failed = false
    @Published private(set) var authorizationLink: URL?
    @Published private(set) var paymentURL: URL?
    @Published private(set) var orderStatus = ""
    private var authorizationSession: MeituanPaotuiAuthorization.Session?
    private var revision = UUID()
    /// Runtime-only authority for one conversation request. Persisted cards cannot recreate it.
    struct ConversationRequest: Equatable {
        fileprivate let conversationID: UUID
        fileprivate let id: UUID
        fileprivate let revision: UUID
    }
    private struct ConversationScope {
        let request: ConversationRequest
        var draft: PaotuiDraft
        var places: [PaotuiAddress]
        var quotes: [PaotuiQuote] = []
    }
    private var conversationScopes: [UUID: ConversationScope] = [:]
    private var receiptReadable = true
    private var receipts: [OrderReceipt] = []
    private let clientFactory: (String) -> MeituanPaotuiClient
    private struct OrderReceipt: Codable {
        let quoteID: UUID
        let account: String
        var state: String
        var orderID: String?
        let createdAt: Date
    }
    private let receiptURL: URL
    private var credential: String { ConnectionCredentialStore.read("meituan-paotui-token") }
    var configured: Bool { !credential.isEmpty }
    private var account: String { SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined() }
    var chatAccount: String { account }
    var chatOrderURL: URL? {
        // An older successful order cannot identify a later uncertain submit.
        if hasUnresolvedSubmission { return URL(string: "https://i.meituan.com/") }
        guard let id = lastOrderID else { return URL(string: "https://i.meituan.com/") }
        return URL(string: "https://i.meituan.com/order/" + id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
    }
    var hasUnresolvedSubmission: Bool { !receiptReadable || receipts.contains { $0.state == "pending" } }
    var lastOrderID: String? { receipts.last(where: { $0.account == account && $0.state == "created" })?.orderID }
    func orderURL(quoteID: UUID) -> URL? {
        guard let receipt = receipts.last(where: { $0.quoteID == quoteID && $0.account == account }) else { return nil }
        guard receipt.state == "created", let id = receipt.orderID else { return URL(string: "https://i.meituan.com/") }
        return URL(string: "https://i.meituan.com/order/" + id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
    }
    var knownLocations: [PaotuiAddress] { addresses + cachedPlaces }
    var statusLabel: String { ready ? "跑腿已连接" : configured ? "跑腿待检测" : "跑腿未连接" }
    func beginConversationRequest(_ id: UUID, draft: PaotuiDraft) -> ConversationRequest {
        let request = ConversationRequest(conversationID: id, id: UUID(), revision: revision)
        let verifiedPlaces = conversationScopes[id]?.request.revision == revision ? conversationScopes[id]?.places ?? [] : []
        conversationScopes[id] = ConversationScope(request: request, draft: draft, places: verifiedPlaces)
        objectWillChange.send()
        return request
    }
    func isCurrent(_ request: ConversationRequest) -> Bool {
        configured && request.revision == revision && conversationScopes[request.conversationID]?.request == request
    }
    private func scope(_ request: ConversationRequest) throws -> ConversationScope {
        try Task.checkCancellation()
        guard isCurrent(request), let value = conversationScopes[request.conversationID] else {
            throw AgentError.message("本次跑腿需求或授权已改变，请使用当前对话继续")
        }
        return value
    }
    func updateConversationDraft(_ draft: PaotuiDraft, for request: ConversationRequest) throws {
        var current = try scope(request)
        if current.draft != draft { current.draft = draft; current.quotes = [] }
        conversationScopes[request.conversationID] = current
    }
    func discardConversationRequest(_ request: ConversationRequest) {
        guard isCurrent(request) else { return }
        conversationScopes.removeValue(forKey: request.conversationID)
        objectWillChange.send()
    }
    func owns(_ quote: PaotuiQuote, for request: ConversationRequest) -> Bool {
        guard isCurrent(request), let current = conversationScopes[request.conversationID] else { return false }
        return current.draft == quote.draft && quote.account == account && current.quotes.contains { $0.id == quote.id }
    }
    func locations(for request: ConversationRequest) -> [PaotuiAddress] {
        guard isCurrent(request), let current = conversationScopes[request.conversationID] else { return [] }
        return addresses + current.places
    }
    func selectService(_ service: PaotuiService) {
        guard service != draft.service else { return }
        var next = draft
        next.service = service; next.senderID = ""; next.nearby = false
        draft = next
    }

    init(receiptURL: URL = URL.applicationSupportDirectory.appendingPathComponent("PhoneAgent/paotui-orders.json"),
         clientFactory: @escaping (String) -> MeituanPaotuiClient = { MeituanPaotuiClient(credential: $0) }) {
        self.receiptURL = receiptURL; self.clientFactory = clientFactory
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            do {
                guard (try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                receipts = try JSONDecoder().decode([OrderReceipt].self, from: Data(contentsOf: receiptURL))
                guard receipts.count <= 2000, receipts.allSatisfy({ ["pending", "created", "reviewed"].contains($0.state) && ($0.state != "created" || $0.orderID?.isEmpty == false) }) else { throw CocoaError(.fileReadCorruptFile) }
            } catch { receiptReadable = false; message = "跑腿订单记录暂时不可读，请先在美团核对已有订单"; failed = true }
        }
    }
    func installCredential(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 8192, value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw AgentError.message("跑腿授权格式无效") }
        try ConnectionCredentialStore.save(value, account: "meituan-paotui-token")
        revision = UUID(); ready = false; addresses = []; places = []; cachedPlaces = []; quotes = []; paymentURL = nil
        conversationScopes = [:]
        authorizationSession = nil; authorizationLink = nil
    }
    func disconnect() throws {
        try ConnectionCredentialStore.save("", account: "meituan-paotui-token")
        revision = UUID(); ready = false; addresses = []; places = []; cachedPlaces = []; quotes = []; paymentURL = nil
        conversationScopes = [:]
        authorizationSession = nil; authorizationLink = nil; draft = PaotuiDraft(); message = "已断开跑腿连接"; failed = false
        // Uncertain order receipts deliberately survive logout/re-authorization.
    }
    func cancelAuthorization() { authorizationSession = nil; authorizationLink = nil; revision = UUID(); conversationScopes = [:] }
    func startAuthorization() async {
        await perform {
            let generation = self.revision
            let session = try await MeituanPaotuiAuthorization().start()
            guard generation == self.revision else { throw CancellationError() }
            self.authorizationSession = session; self.authorizationLink = session.link
            self.message = "请在美团 App 完成授权，再点“我已授权”。链接 10 分钟有效。"
            _ = await UIApplication.shared.open(session.link)
        }
    }
    func finishAuthorization() async {
        await perform {
            guard let session = self.authorizationSession else { throw AgentError.message("请先连接美团跑腿") }
            let generation = self.revision
            guard let value = try await MeituanPaotuiAuthorization().finish(session) else { self.message = "还在等待美团确认，请完成授权后再检测。"; return }
            guard generation == self.revision else { throw CancellationError() }
            try self.installCredential(value)
            try await self.loadAddresses()
        }
    }
    private func client() throws -> MeituanPaotuiClient {
        guard configured else { throw AgentError.message("请先在工具与连接中授权美团跑腿") }
        return clientFactory(credential)
    }
    private func unchanged(_ value: String, _ generation: UUID) throws {
        try Task.checkCancellation()
        guard value == credential, generation == revision else { throw AgentError.message("跑腿连接已改变，请重新查询") }
    }
    func loadAddresses() async throws {
        ready = false; quotes = []
        let key = credential, generation = revision
        let result = try await client().addresses(); try unchanged(key, generation)
        addresses = result; ready = true
        message = result.isEmpty ? "请先在美团 App 保存收货地址，再返回刷新。" : "可以选择地址查询跑腿费用。"
    }
    func refresh() async { await perform { try await self.loadAddresses() } }
    func search(keyword: String, city: String) async throws {
        let key = credential, generation = revision
        let near = addresses.first { $0.id == draft.recipientID }
        let result = try await client().search(keyword: keyword, city: city, near: near)
        try unchanged(key, generation)
        // A second conversation may search elsewhere. Keep verified references
        // available without mixing previous shops into this search's choices.
        cachedPlaces = Array((result + cachedPlaces.filter { old in !result.contains { $0.id == old.id } }).prefix(200))
        places = result
        message = result.isEmpty ? "没有找到匹配地址，请补充店名或街道。" : "请选择购买或取件地址。"
    }
    func searchFromUI(keyword: String, city: String) async { await perform { try await self.search(keyword: keyword, city: city) } }
    func search(keyword: String, city: String, for request: ConversationRequest) async throws -> [PaotuiAddress] {
        let current = try scope(request), key = credential, generation = revision
        let near = addresses.first { $0.id == current.draft.recipientID }
        let result = try await client().search(keyword: keyword, city: city, near: near)
        try unchanged(key, generation)
        var latest = try scope(request)
        guard latest.draft == current.draft else { throw AgentError.message("跑腿信息已修改，请重新查询门店") }
        latest.places = Array((result + latest.places.filter { old in !result.contains { $0.id == old.id } }).prefix(200))
        conversationScopes[request.conversationID] = latest
        cachedPlaces = Array((result + cachedPlaces.filter { old in !result.contains { $0.id == old.id } }).prefix(200))
        return result
    }
    func preview() async throws -> [PaotuiQuote] {
        let current = draft
        let results = try await preview(draft: current, locations: knownLocations) {
            guard current == self.draft else { throw AgentError.message("跑腿信息已修改，请重新查询费用") }
        }
        quotes = results; message = "请核对费用和地址。尚未下单。"
        return results
    }
    func preview(for request: ConversationRequest) async throws -> [PaotuiQuote] {
        let current = try scope(request)
        let results = try await preview(draft: current.draft, locations: addresses + current.places) {
            guard try self.scope(request).draft == current.draft else { throw AgentError.message("跑腿信息已修改，请重新查询费用") }
        }
        var latest = try scope(request)
        latest.quotes = results
        conversationScopes[request.conversationID] = latest
        objectWillChange.send()
        return results
    }
    private func preview(draft current: PaotuiDraft, locations: [PaotuiAddress], validate: () throws -> Void) async throws -> [PaotuiQuote] {
        try current.validate(); try validate()
        let key = credential, generation = revision, tag = account
        guard let recipient = addresses.first(where: { $0.id == current.recipientID }),
              let sender = current.nearby ? recipient : locations.first(where: { $0.id == current.senderID }) else { throw AgentError.message("请从真实地址结果中选择购买／取送地址") }
        guard sender.cityID == recipient.cityID else { throw AgentError.message("购买／取件地址与送达地址不在同一城市，请重新选择同城地址。") }
        let client = try client()
        let recipientPhone = try await client.phone(recipient); try unchanged(key, generation); try validate()
        let senderPhone: String
        if sender.savedID != nil, sender.id != recipient.id { senderPhone = try await client.phone(sender) }
        else { senderPhone = recipientPhone }
        try unchanged(key, generation); try validate()
        let senderWire = try sender.wire(phone: senderPhone, fallback: recipient)
        let recipientWire = try recipient.wire(phone: recipientPhone)
        var base: [String: Any] = ["sender": senderWire, "recipient": recipientWire,
            "businessType": current.service == .buy ? 2 : 1, "bizTypeSceneTag": 0,
            "location_city_id": recipient.cityID, "tipFee": 0, "remark": current.remark,
            "orderMode": "4", "needRecommendCoupon": "1", "lat": String(recipient.latitude), "lng": String(recipient.longitude)]
        if current.service == .buy {
            base["businessTypeTag"] = current.nearby ? 1 : 0; base["purchaseGoodDetail"] = current.goods
        } else {
            let goods: [String: Any] = ["goodsName": current.goods, "goodsWeight": current.weight,
                "goodTypes": [current.category.code], "goodTypeNames": [current.category.title]]
            base["goods"] = goods
            base["goodsInfo"] = String(data: try JSONSerialization.data(withJSONObject: goods, options: [.sortedKeys]), encoding: .utf8)!
            base["goodWeight"] = String(current.weight); base["businessTypeTag"] = 0; base["purchaseGoodDetail"] = ""
        }
        let services: [Int?] = current.service == .buy ? [nil] : [1003, 4033]
        var results: [PaotuiQuote] = []
        for service in services {
            var payload = base; if let service { payload["serviceType"] = service }
            let data = try await client.call(.preview, payload); try unchanged(key, generation)
            try validate()
            results.append(try MeituanPaotuiClient.quote(data: data, draft: current, sender: sender, recipient: recipient,
                                                       request: payload, account: tag, service: service))
        }
        return results
    }
    func previewFromUI() async { await perform { _ = try await self.preview() } }
    func canSubmit(_ quote: PaotuiQuote) -> Bool {
        !busy && quotes.contains(where: { $0.id == quote.id }) && quote.canSubmit(draft: draft, account: account, unresolved: hasUnresolvedSubmission)
    }
    func canSubmit(_ quote: PaotuiQuote, for request: ConversationRequest) -> Bool {
        guard !busy, owns(quote, for: request), let current = conversationScopes[request.conversationID],
              let canonical = current.quotes.first(where: { $0.id == quote.id }) else { return false }
        return canonical.canSubmit(draft: current.draft, account: account, unresolved: hasUnresolvedSubmission)
    }
    private func persist(_ updated: [OrderReceipt]) throws {
        guard receiptReadable, updated.count <= 2000 else { throw AgentError.message("跑腿订单记录不可写，未创建订单") }
        do {
            try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            #if os(iOS)
            try data.write(to: receiptURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: receiptURL, options: .atomic)
            #endif
        } catch { throw AgentError.message("本机订单记录保存失败，尚未发送订单。请检查存储空间或文件权限后重试。") }
        // Once the atomic write succeeds, retain pending in memory even if
        // backup metadata fails. It must never disappear until human review.
        receipts = updated
        do {
            var url = receiptURL; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { throw AgentError.message("本机订单记录的备份设置未完成，尚未发送订单，请先核对本机记录。") }
    }
    /// Called only by a current conversation confirmation card. The AI-facing tool has no
    /// submit operation and cannot supply a replacement phone, price or token.
    func submitConfirmed(_ quote: PaotuiQuote) async {
        guard canSubmit(quote), let canonical = quotes.first(where: { $0.id == quote.id }) else { message = "报价或连接已改变，请重新查询费用"; failed = true; return }
        await submitConfirmed(canonical, validate: {
            guard self.quotes.contains(where: { $0.id == canonical.id }), canonical.canSubmit(draft: self.draft, account: self.account, unresolved: self.hasUnresolvedSubmission) else {
                throw AgentError.message("报价或连接已改变，请重新查询费用")
            }
        }, invalidate: { self.quotes = [] })
    }
    func submitConfirmed(_ quote: PaotuiQuote, for request: ConversationRequest) async {
        guard canSubmit(quote, for: request), let canonical = conversationScopes[request.conversationID]?.quotes.first(where: { $0.id == quote.id }) else { message = "报价或连接已改变，请重新查询费用"; failed = true; return }
        await submitConfirmed(canonical, validate: {
            let current = try self.scope(request)
            guard self.owns(canonical, for: request), canonical.canSubmit(draft: current.draft, account: self.account, unresolved: self.hasUnresolvedSubmission) else {
                throw AgentError.message("报价或连接已改变，请重新查询费用")
            }
        }, invalidate: {
            guard self.isCurrent(request) else { return }
            self.conversationScopes[request.conversationID]?.quotes = []
        })
    }
    private func submitConfirmed(_ quote: PaotuiQuote, validate: () throws -> Void, invalidate: () -> Void) async {
        await perform {
            try Task.checkCancellation(); try validate()
            let key = self.credential, tag = self.account
            var payload = quote.request
            payload["orderToken"] = quote.orderToken
            payload["deliveryFee"] = String(quote.originalFee); payload["previewTotal"] = String(quote.fee)
            payload["deliveryFeeChangedAck"] = "true"; payload["couponViewId"] = quote.couponViewID
            payload["payType"] = "1"; payload["pushToken"] = ""
            var updated = self.receipts
            updated.append(OrderReceipt(quoteID: quote.id, account: tag, state: "pending", orderID: nil, createdAt: Date()))
            try self.persist(updated) // Durable BEFORE the only submit attempt.
            invalidate()
            let data: [String: Any]
            do { data = try await self.clientFactory(key).call(.submit, payload) }
            catch {
                // Even an interrupted/error response may follow a committed
                // order. Retain pending; never automatically submit it again.
                throw AgentError.message("本次提交结果需要核验，请先在美团查看订单。Sela 不会重复提交。")
            }
            let id = (data["orderId"] as? String) ?? (data["orderId"] as? NSNumber)?.stringValue
            guard let id, !id.isEmpty else { throw AgentError.message("美团未返回完整订单回执，请先在美团核对，勿重复下单") }
            updated[updated.count - 1].state = "created"; updated[updated.count - 1].orderID = id
            do { try self.persist(updated) } catch { throw AgentError.message("订单已创建，但本机回执保存失败。请在美团查看，勿重复下单。") }
            guard self.credential == key else { return }
            if let trade = data["tradeNo"] as? String, let token = data["payToken"] as? String, !trade.isEmpty, !token.isEmpty {
                self.paymentURL = Self.paymentURL(orderID: id, trade: trade, token: token)
            }
            self.message = "订单已创建，尚未确认付款。请前往美团收银台核对并支付。"
            self.orderStatus = "订单已创建，待支付状态以美团为准。"
        }
    }
    static func paymentURL(orderID: String, trade: String, token: String) -> URL? {
        var c = URLComponents(string: "https://npay.meituan.com/i/cashier/show/index")!
        let success = "https://i.meituan.com/order/" + orderID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        c.queryItems = ["auth": "v2", "tradeno": trade, "pay_token": token, "pay_success_url": success,
                        "redr_url": success, "nb_location": "0_0", "nb_ci": "0"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }
    func status(orderID: String) async throws -> String {
        guard receipts.contains(where: { $0.account == account && $0.orderID == orderID && $0.state == "created" }) else {
            throw AgentError.message("请先在这台设备核对实际创建的跑腿订单")
        }
        let key = credential, generation = revision
        let data = try await client().call(.status, ["orderId": orderID, "orderViewId": orderID])
        try unchanged(key, generation)
        // Do not let provider marketing/phone/payment payloads enter AI history.
        let texts = ["statusDesc", "orderStatusDesc", "statusName", "orderStatusName", "statusText"].compactMap { data[$0] as? String }
        let status = texts.first(where: { !$0.isEmpty && $0.count <= 200 }) ?? "已收到美团订单查询结果，请在美团查看完整配送进度。"
        orderStatus = status; return status
    }
    func refreshOrder() async { await perform { if let id = self.lastOrderID { self.message = try await self.status(orderID: id) } } }
    func resolveAfterHumanReview() {
        guard !busy, receiptReadable, hasUnresolvedSubmission else { return }
        var updated = receipts
        for index in updated.indices where updated[index].state == "pending" { updated[index].state = "reviewed" }
        do {
            try persist(updated); quotes = []
            for id in conversationScopes.keys { conversationScopes[id]?.quotes = [] }
            message = "已记录你在美团的人工核对，请重新查询费用后再下单。"; failed = false
        }
        catch { message = "未能保存核对记录，请稍后重试。"; failed = true }
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; failed = false; message = ""
        defer { busy = false }
        do { try await action() }
        catch is CancellationError { message = "本次查询已停止" }
        catch { failed = true; message = (error as? AgentError)?.localizedDescription ?? "网络请求未完成，请稍后重试。" }
    }
    func tool(_ query: String) async throws -> String {
        guard !busy else { throw AgentError.message("已有跑腿请求正在处理，请稍候") }
        busy = true; defer { busy = false }
        let value = try PaotuiToolQuery.decode(query)
        switch value.action {
        case .addresses:
            try await loadAddresses()
            let filtered = addresses.filter { value.keyword?.isEmpty != false || $0.fullAddress.localizedCaseInsensitiveContains(value.keyword!) }
            let rows = filtered.prefix(20).map { ["reference": $0.id, "address": $0.fullAddress, "contact": $0.contact, "phone": $0.maskedPhone, "city": $0.city] }
            return try Self.json(["addresses": rows, "total": filtered.count, "truncated": filtered.count > 20])
        case .search:
            if addresses.isEmpty { try await loadAddresses() }
            if let recipient = value.recipient {
                guard addresses.contains(where: { $0.id == recipient }) else { throw AgentError.message("收货地址引用不属于当前授权") }
                draft.recipientID = recipient
            }
            try await search(keyword: value.keyword!, city: value.city!)
            return try Self.json(["places": places.prefix(20).map { ["reference": $0.id, "name": $0.name, "address": $0.address] }])
        case .preview_buy, .preview_send:
            draft = PaotuiDraft(service: value.action == .preview_buy ? .buy : .send,
                recipientID: value.recipient ?? "", senderID: value.sender ?? "", nearby: value.nearby ?? false,
                goods: value.goods ?? "", remark: value.remark ?? "", category: value.category ?? .food, weight: value.weight ?? 1)
            return try await preview().map(\.summary).joined(separator: "\n\n") + "\n如需下单，请在 Sela 当前对话中核对完整订单确认卡片。连接页不提供下单功能。"
        case .order_status: return try await status(orderID: value.order_id!)
        }
    }
    private static func json(_ object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }
}
