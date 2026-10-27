import Foundation
import Darwin

/// Fixtures are injected only through production HTTP, clock and file-commit seams.
/// These checks compile each production source directly, without app-name stand-ins.
@MainActor private final class FixtureClock {
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var clock: PaotuiClock { PaotuiClock(now: { self.date }) }
}

@MainActor private final class Gate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters = []
        await withCheckedContinuation { release = $0 }
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func resume() { release?.resume(); release = nil }
}

@MainActor private final class Backend {
    var submissions: [[String: Any]] = []
    var statuses: [[String: Any]] = []
    var credentials: [String] = []
    var submitResponse: [String: Any] = ["orderId": "fixture-order", "tradeNo": "fixture-trade", "payToken": "fixture-payment"]
    var statusResponse: [String: Any] = ["statusDesc": "等待支付", "phone": "13800000000", "payToken": "secret"]
    var failSubmit = false
    var submitGate: Gate?
    var statusGate: Gate?
    var onSubmit: (() throws -> Void)?
    func client(_ credential: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential: credential, transport: { request in
            try await self.respond(request)
        })
    }
    private func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let data: [String: Any]
        credentials.append(request.value(forHTTPHeaderField: "mtcp-ak") ?? "")
        switch request.url!.lastPathComponent {
        case "submit_order":
            submissions.append(payload)
            try onSubmit?()
            if let submitGate { await submitGate.suspend() }
            if failSubmit { throw URLError(.networkConnectionLost) }
            data = submitResponse
        case "get_order_status":
            statuses.append(payload)
            if let statusGate { await statusGate.suspend() }
            data = statusResponse
        default: preconditionFailure("Unexpected offline endpoint")
        }
        let inner = try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
        let bytes = try JSONSerialization.data(withJSONObject: ["code": 0, "result": "SUCCESS", "data": String(data: inner, encoding: .utf8)!])
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct OrderChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
        checks += 1; let result = try value(); precondition(result, label)
    }
    @MainActor private static func rejects(_ label: String, _ work: () throws -> Void) {
        do { try work(); preconditionFailure(label) } catch { checks += 1 }
    }
    @MainActor private static func rejectsAsync(_ label: String, _ work: () async throws -> Void) async {
        do { try await work(); preconditionFailure(label) } catch { checks += 1 }
    }
    @MainActor private static func quote(_ time: Date, account: String = "fixture-account", service: PaotuiService = .buy,
                                         request: [String: Any]? = nil, fee: Double = 18, originalFee: Double = 23, draft suppliedDraft: PaotuiDraft? = nil) -> PaotuiQuote {
        let draft = suppliedDraft ?? PaotuiDraft(service: service, recipientID: "address:1", senderID: "address:2", nearby: service == .buy,
                                               goods: "Private item detail", remark: "Private contact note",
                                               category: service == .send ? .document : nil, weight: service == .send ? 2 : nil)
        return PaotuiQuote(id: UUID(), draft: draft, senderTitle: "Fixture sender", recipientTitle: "Fixture recipient",
            serviceTitle: service == .buy ? "帮买" : "帮取送 · 1对1急送", distance: "1.3公里", estimate: "Fixture estimate",
            fee: fee, originalFee: originalFee, goodsPaymentNote: "商品费未知", quotedAt: time, agreementURL: nil,
            agreementTitle: "跑腿服务协议", account: account,
            request: request ?? ["sender": ["phone": "13800000000"], "recipient": ["phone": "13900000000"],
                "businessType": service == .buy ? 2 : 1, "serviceType": 4033, "purchaseGoodDetail": draft.goods],
            orderToken: "fixture-order-token", couponViewID: "coupon%2Ffixture")
    }
    private static func object(_ path: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }
    private static func rows(_ path: URL) throws -> [[String: Any]] { try object(path)["receipts"] as! [[String: Any]] }
    private static func writeLegacy(_ path: URL, _ rows: [[String: Any]]) throws {
        try JSONSerialization.data(withJSONObject: rows).write(to: path)
    }
    @MainActor private static func checkNotDispatched(_ result: PaotuiOrderService.SubmissionResult, _ label: String) {
        if case .notDispatched(let message) = result { expect(!message.isEmpty, label) }
        else { preconditionFailure(label) }
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-orders-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = FixtureClock()
        let account = "fixture-account", otherAccount = "different-account"
        let path = directory.appendingPathComponent("orders.json")
        let journal = PaotuiOrderJournal(url: path, clock: clock.clock)
        expect(journal.isReadable && !journal.hasUnresolvedSubmission, "A missing journal starts readable with no invented attempts")
        expect(journal.lastOrderID(account: account) == nil && journal.pendingReviews(account: account).isEmpty,
               "Empty history has no created order or pending review")
        let buy = quote(clock.date)
        var changes = 0
        journal.onChange = {
            changes += 1
            expect(FileManager.default.fileExists(atPath: path.path), "Change notification follows durable commit")
        }
        let attempt = try journal.beginAttempt(quote: buy, account: account)
        expect(changes == 1 && journal.hasUnresolvedSubmission, "Pending state commits before it is published")
        let pending = journal.pendingReviews(account: account)[0]
        expect(pending.id == attempt && pending.createdAt == clock.date && pending.requestSummary == "帮买" && pending.deliveryFee == 18,
               "Attempt identity, safe summary, exact fee and injected time survive the projection")
        expect(pending.isSameCredentialScope && !pending.isCurrentAuthorization && !journal.pendingReviews(account: otherAccount)[0].isSameCredentialScope,
               "Pending reviews retain their original authorization identity")
        expect(journal.orderURL(quoteID: buy.id, account: account)?.absoluteString == "https://i.meituan.com/" &&
               journal.orderURL(quoteID: buy.id, account: otherAccount) == nil, "Unknown rows link only to the platform home and matching account")
        let disk = try String(contentsOf: path, encoding: .utf8)
        expect(!disk.contains("13800000000") && !disk.contains("fixture-order-token") && !disk.contains("Private item") && !disk.contains("Private contact"),
               "The journal excludes private phones, full requests, goods notes and order tokens")
        try expect(object(path)["schemaVersion"] as? Int == 3 && rows(path)[0]["state"] as? String == "unknown",
                   "New pending records declare schemaVersion 3 with exact money")
        let savedAmount = try rows(path)[0]["deliveryAmount"] as! [String: Any]
        expect(savedAmount["currency"] as? String == "CNY" && savedAmount["minorUnits"] as? Int64 == 1800,
               "Journal persists currency and integer fen, with no floating amount authority")
        try expect(rows(path)[0]["deliveryFee"] == nil, "New exact-money journal writes no legacy Double fee")
        try expect(rows(path)[0]["context"] == nil, "Direct journal fixtures do not invent native conversation, session or credential epochs")
        try expect(path.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                   "Committed metadata inherits backup exclusion from staging")
        try journal.markCreated(attemptID: attempt, orderID: "order/with space")
        expect(changes == 2 && !journal.hasUnresolvedSubmission && journal.lastOrderID(account: account) == "order/with space",
               "Only a saved provider ID resolves the attempt as created")
        expect(journal.knowsCreatedOrder(orderID: "order/with space", account: account) &&
               !journal.knowsCreatedOrder(orderID: "order/with space", account: otherAccount), "Known created orders are account scoped")
        expect(journal.orderURL(quoteID: buy.id, account: account)?.absoluteString.hasSuffix("order%2Fwith%20space") == true,
               "Order IDs are escaped as a single path component")
        rejects("A settled attempt must not be edited as unknown") { try journal.markCreated(attemptID: attempt, orderID: "replacement") }
        rejects("A created provider receipt cannot be converted by human review") { try journal.recordReview(attemptID: attempt, conclusion: .believesNotCreated) }
        expect(PaotuiOrderJournal(url: path, clock: clock.clock).lastOrderID(account: account) == "order/with space",
               "Exact-money provider-created receipts survive restart")

        let legacyPath = directory.appendingPathComponent("legacy.json")
        let first = UUID(), second = UUID(), created = UUID(), reviewed = UUID()
        try writeLegacy(legacyPath, [
            ["quoteID": first.uuidString, "account": account, "state": "pending", "createdAt": clock.date.timeIntervalSinceReferenceDate],
            ["quoteID": second.uuidString, "account": otherAccount, "state": "pending", "createdAt": clock.date.timeIntervalSinceReferenceDate],
            ["quoteID": created.uuidString, "account": account, "state": "created", "orderID": "old-order", "createdAt": clock.date.timeIntervalSinceReferenceDate],
            ["quoteID": reviewed.uuidString, "account": account, "state": "reviewed", "createdAt": clock.date.timeIntervalSinceReferenceDate]
        ])
        let migrated = PaotuiOrderJournal(url: legacyPath, clock: clock.clock)
        expect(migrated.isReadable && migrated.hasUnresolvedSubmission && migrated.pendingReviews(account: account).count == 2,
               "Old arrays migrate every pending row conservatively to unknown")
        expect(Set(migrated.pendingReviews(account: account).map(\.id)) == Set([first, second]), "Legacy quote IDs remain stable attempt IDs")
        expect(migrated.pendingReviews(account: account).allSatisfy { $0.requestSummary == nil && $0.deliveryFee == nil && $0.reviewedAt == nil },
               "Migration does not invent missing summary, fee, review time or conclusion")
        expect(migrated.lastOrderID(account: account) == "old-order" && migrated.orderURL(quoteID: created, account: account)?.lastPathComponent == "old-order",
               "Existing created order IDs retain their historical meaning")
        try expect(object(legacyPath)["schemaVersion"] as? Int == 3 && rows(legacyPath)[3]["state"] as? String == "reviewed" &&
                   rows(legacyPath).allSatisfy { ($0["reviews"] as? [[String: Any]])?.isEmpty == true }, "Migration persists schema 3 without fabricating human reviews")
        clock.date.addTimeInterval(45)
        try migrated.recordReview(attemptID: first, conclusion: .stillUnknown)
        let human = migrated.pendingReviews(account: account).first { $0.id == first }!
        expect(human.reviewedAt == clock.date && human.lastConclusion == .stillUnknown && human.reviewSource == "user_report_in_sela",
               "Human reports use the injected time and explicit user-report source")
        expect(migrated.pendingReviews(account: account).count == 2 && migrated.hasUnresolvedSubmission, "Still unknown never lifts either attempt's barrier")
        let reviewRestart = PaotuiOrderJournal(url: legacyPath, clock: clock.clock)
        expect(reviewRestart.pendingReviews(account: account).first { $0.id == first }?.lastConclusion == .stillUnknown,
               "Human review history survives restart")
        try migrated.recordReview(attemptID: first, conclusion: .believesCreated)
        expect(migrated.pendingReviews(account: account).map(\.id) == [second] && migrated.hasUnresolvedSubmission,
               "Reviewing one attempt leaves the other unresolved regardless of account")
        expect(migrated.lastOrderID(account: account) == "old-order" && !migrated.knowsCreatedOrder(orderID: first.uuidString, account: account),
               "Believing an order was created does not fabricate a provider receipt")
        try expect(rows(legacyPath)[0]["orderID"] == nil && (rows(legacyPath)[0]["reviews"] as? [[String: Any]])?.count == 2,
                   "Resolved human reports keep their earlier unknown conclusion and no provider ID")
        rejects("An obsolete review must not change another row") { try migrated.recordReview(attemptID: first, conclusion: .believesNotCreated) }
        try migrated.recordReview(attemptID: second, conclusion: .believesNotCreated)
        expect(!migrated.hasUnresolvedSubmission && migrated.pendingReviews(account: account).isEmpty,
               "Only successful review of the final pending row lifts the global barrier")

        // Version 1 summaries used Double; migration preserves every row and
        // known exact fee, and does not convert unsupported precision into zero.
        let moneyLegacyPath = directory.appendingPathComponent("legacy-money.json")
        let moneyLegacyRows: [[String: Any]] = [12.34, 0, -1, 0.001].map { fee in
            ["attemptID": UUID().uuidString, "quoteID": UUID().uuidString, "account": account,
             "state": "unknown", "createdAt": 0, "requestSummary": "帮买", "deliveryFee": fee, "reviews": []]
        } + [["attemptID": UUID().uuidString, "quoteID": UUID().uuidString, "account": account,
              "state": "unknown", "createdAt": 0, "reviews": []]]
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "receipts": moneyLegacyRows]).write(to: moneyLegacyPath)
        let moneyMigrated = PaotuiOrderJournal(url: moneyLegacyPath, clock: clock.clock)
        let moneyReviews = moneyMigrated.pendingReviews(account: account)
        expect(moneyMigrated.isReadable && moneyMigrated.hasUnresolvedSubmission && moneyReviews.count == 5,
               "V1 amount migration preserves all unresolved attempts")
        expect(moneyReviews[0].deliveryAmount?.minorUnits == 1234 && moneyReviews[1].deliveryAmount?.minorUnits == 0,
               "V1 known fees migrate exactly, including an actual zero")
        expect(moneyReviews.dropFirst(2).allSatisfy { $0.deliveryAmount == nil && $0.deliveryFee == nil },
               "V1 negative, unsupported precision and absent fees stay unknown")
        try expect(object(moneyLegacyPath)["schemaVersion"] as? Int == 3 && rows(moneyLegacyPath).allSatisfy { $0["deliveryFee"] == nil },
                   "V1 legacy Double fees are replaced by explicit exact-money v3")
        let moneyRestart = PaotuiOrderJournal(url: moneyLegacyPath, clock: clock.clock)
        expect(moneyRestart.isReadable && moneyRestart.pendingReviews(account: account).map(\.deliveryAmount) == moneyReviews.map(\.deliveryAmount),
               "V2 restart preserves exact fees and unknowns from migration")

        let failPath = directory.appendingPathComponent("failing.json")
        let initial = PaotuiOrderJournal(url: failPath, clock: clock.clock)
        let failAttempt = try initial.beginAttempt(quote: quote(clock.date, service: .send), account: account)
        expect(initial.pendingReviews(account: account)[0].requestSummary == "帮取送 · 1对1急送 · 文件", "Send recovery uses service and actual item category only")
        let saved = try Data(contentsOf: failPath)
        var commits = 0, failedChanges = 0
        let failJournal = PaotuiOrderJournal(url: failPath, clock: clock.clock, commit: { staged, destination in
            commits += 1
            expect(staged.deletingLastPathComponent() == destination.deletingLastPathComponent(), "Staging and replacement use one directory")
            try expect(staged.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                       "Metadata is ready before commit is attempted")
            try expect(rows(staged).count >= 1, "A complete decodable journal exists at the commit boundary")
            throw CocoaError(.fileWriteNoPermission)
        })
        failJournal.onChange = { failedChanges += 1 }
        rejects("Failed review commit cannot unlock an unknown attempt") { try failJournal.recordReview(attemptID: failAttempt, conclusion: .believesNotCreated) }
        expect(commits == 1 && failedChanges == 0 && failJournal.hasUnresolvedSubmission && failJournal.pendingReviews(account: account)[0].lastConclusion == nil,
               "Failed commit publishes neither a review nor a state change")
        try expect(Data(contentsOf: failPath) == saved, "Failed review keeps previous journal bytes intact")
        rejects("Failed created receipt commit must retain the unknown attempt") { try failJournal.markCreated(attemptID: failAttempt, orderID: "provider-known") }
        expect(failJournal.lastOrderID(account: account) == nil && failJournal.hasUnresolvedSubmission, "Failed receipt commit cannot report a durable created order")
        try expect(FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".paotui-orders-") },
                   "Failed atomic staging is cleaned up")

        let futurePath = directory.appendingPathComponent("future.json")
        let future = try JSONSerialization.data(withJSONObject: ["schemaVersion": 99, "receipts": rows(failPath)])
        try future.write(to: futurePath)
        let futureJournal = PaotuiOrderJournal(url: futurePath, clock: clock.clock)
        expect(!futureJournal.isReadable && futureJournal.hasUnresolvedSubmission, "Future schema versions fail closed")
        rejects("Future schema writes must be blocked") { _ = try futureJournal.beginAttempt(quote: buy, account: account) }
        rejects("Future schema reviews must be blocked") { try futureJournal.recordReview(attemptID: failAttempt, conclusion: .believesNotCreated) }
        try expect(Data(contentsOf: futurePath) == future, "Unknown schema bytes remain unchanged")
        for (name, bytes) in [
            ("corrupt", Data("bad".utf8)),
            ("negativeMoney", try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "receipts": [["attemptID": UUID().uuidString, "quoteID": UUID().uuidString, "account": account, "state": "unknown", "createdAt": 0, "reviews": [], "deliveryAmount": ["currency": "CNY", "minorUnits": -1]]]])),
            ("foreignMoney", try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "receipts": [["attemptID": UUID().uuidString, "quoteID": UUID().uuidString, "account": account, "state": "unknown", "createdAt": 0, "reviews": [], "deliveryAmount": ["currency": "USD", "minorUnits": 1]]]])),
            ("oversized", Data(repeating: 32, count: 2_000_001)),
            ("invalidLegacy", try JSONSerialization.data(withJSONObject: [["quoteID": UUID().uuidString, "account": account, "state": "new-state", "createdAt": 0]])),
            ("duplicate", try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "receipts": [rows(failPath)[0], rows(failPath)[0]]])),
            ("missingID", try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "receipts": [["attemptID": UUID().uuidString, "quoteID": UUID().uuidString, "account": account, "state": "created", "createdAt": 0, "reviews": []]]]))
        ] {
            let invalidPath = directory.appendingPathComponent(name + ".json")
            try bytes.write(to: invalidPath)
            let invalid = PaotuiOrderJournal(url: invalidPath, clock: clock.clock)
            expect(!invalid.isReadable && invalid.hasUnresolvedSubmission, "Invalid journal fails closed: " + name)
            rejects("Invalid journal must remain read only: " + name) { _ = try invalid.beginAttempt(quote: buy, account: account) }
            try expect(Data(contentsOf: invalidPath) == bytes, "Invalid bytes remain intact: " + name)
        }

        // Exact submission wire contract, persistence and invalidation order.
        let servicePath = directory.appendingPathComponent("service.json")
        let serviceJournal = PaotuiOrderJournal(url: servicePath, clock: clock.clock)
        let backend = Backend()
        let service = PaotuiOrderService(journal: serviceJournal, clientFactory: backend.client, clock: clock.clock)
        var invalidations = 0
        backend.onSubmit = {
            expect(service.isSubmitting && serviceJournal.hasUnresolvedSubmission, "Independent service lock and unknown barrier precede HTTP")
            try expect(rows(servicePath).last?["state"] as? String == "unknown", "Pending attempt is durable before the only send")
            expect(invalidations == 1, "Presentation authority is revoked after commit and before HTTP")
        }
        let serviceQuote = quote(clock.date)
        let result = await service.submit(quote: serviceQuote, credential: "offline-credential", account: account, validate: {}, invalidate: { invalidations += 1 })
        if case .created(let id, let payment) = result {
            expect(id == "fixture-order" && payment?.host == "npay.meituan.com", "Created structured result contains the saved ID and official payment URL")
            let parameters = URLComponents(url: payment!, resolvingAgainstBaseURL: false)!.queryItems!
            expect(parameters.first { $0.name == "pay_token" }?.value == "fixture-payment" &&
                   parameters.first { $0.name == "pay_success_url" }?.value == "https://i.meituan.com/order/fixture%2Dorder",
                   "Cashier contract preserves payment token and escaped order-return link")
        } else { preconditionFailure("Valid offline submission did not create") }
        expect(!service.isSubmitting && !serviceJournal.hasUnresolvedSubmission && serviceJournal.lastOrderID(account: account) == "fixture-order",
               "A created result is published only after the created receipt committed")
        expect(backend.submissions.count == 1 && backend.credentials == ["offline-credential"], "One confirmation produces exactly one authenticated submit")
        let wire = backend.submissions[0]
        expect(wire["orderToken"] as? String == serviceQuote.orderToken && wire["serviceType"] as? Int == 4033 &&
               wire["deliveryFee"] as? String == "23.0" && wire["previewTotal"] as? String == "18.0", "Exact quote payload, service, token and fee string contract survive extraction")
        expect(wire["deliveryFeeChangedAck"] as? String == "true" && wire["couponViewId"] as? String == "coupon%2Ffixture" &&
               wire["payType"] as? String == "1" && wire["pushToken"] as? String == "", "Submit acknowledgment, coupon and payment fields keep their original types")

        // Known-order read authority is checked on both sides of the await.
        var authorizationChecks = 0
        let status = try await service.status(orderID: "fixture-order", credential: "offline-credential", account: account) { authorizationChecks += 1 }
        expect(status == "等待支付" && authorizationChecks == 2, "Status uses real provider text after before/after authorization checks")
        expect(backend.statuses[0]["orderId"] as? String == "fixture-order" && backend.statuses[0]["orderViewId"] as? String == "fixture-order",
               "Status keeps exact known order identifiers")
        await rejectsAsync("Foreign account status must not call HTTP") { _ = try await service.status(orderID: "fixture-order", credential: "offline-credential", account: otherAccount, validateAuthorization: {}) }
        await rejectsAsync("Unrecorded order status must not call HTTP") { _ = try await service.status(orderID: "unknown", credential: "offline-credential", account: account, validateAuthorization: {}) }
        await rejectsAsync("Revoked authorization must fail before status HTTP") { _ = try await service.status(orderID: "fixture-order", credential: "offline-credential", account: account) { throw CancellationError() } }
        expect(backend.statuses.count == 1, "Rejected status reads make no provider requests")
        backend.statusResponse = ["statusDesc": String(repeating: "x", count: 201), "orderStatusDesc": "已接单", "phone": "13800000000"]
        let boundedStatus = try await service.status(orderID: "fixture-order", credential: "offline-credential", account: account, validateAuthorization: {})
        expect(boundedStatus == "已接单",
               "Status filters oversized content and returns only bounded status text")
        backend.statusResponse = ["phone": "13800000000", "payToken": "secret"]
        let fallbackStatus = try await service.status(orderID: "fixture-order", credential: "offline-credential", account: account, validateAuthorization: {})
        expect(fallbackStatus.contains("完整配送进度"),
               "Other provider fields never leak through a status fallback")
        let statusGate = Gate(); backend.statusGate = statusGate
        var authorized = true
        let statusWork = Task { try await service.status(orderID: "fixture-order", credential: "offline-credential", account: account) {
            guard authorized else { throw AgentError.message("Authorization replaced") }
        } }
        await statusGate.wait(); authorized = false; statusGate.resume()
        await rejectsAsync("Authorization changed during status must reject late result") { _ = try await statusWork.value }
        backend.statusGate = nil

        // The service rejects invalid account, age, caller authority and local writes before send.
        let countBefore = backend.submissions.count
        for (candidate, token, tag) in [(quote(clock.date, account: otherAccount), "offline-credential", account),
                                        (quote(clock.date.addingTimeInterval(-300)), "offline-credential", account),
                                        (quote(clock.date), "", account),
                                        (quote(clock.date), "invalid token", account),
                                        (quote(clock.date, request: ["notJSON": Date()]), "offline-credential", account)] {
            let rejected = await service.submit(quote: candidate, credential: token, account: tag, validate: {}, invalidate: { preconditionFailure("Preflight failure invalidated quote") })
            checkNotDispatched(rejected, "Invalid account/expiry/credential/JSON is explicitly not dispatched")
        }
        for invalid in [Double.nan, .infinity, -1, 0.001, 12.345, 0.1 + 0.2] {
            for candidate in [quote(clock.date, fee: invalid), quote(clock.date, originalFee: invalid)] {
                let rejected = await service.submit(quote: candidate, credential: "offline-credential", account: account,
                    validate: {}, invalidate: { preconditionFailure("Invalid money invalidated quote") })
                checkNotDispatched(rejected, "Malformed compatibility amount cannot dispatch")
                rejects("Journal refuses malformed quote money independently") {
                    _ = try serviceJournal.beginAttempt(quote: candidate, account: account)
                }
            }
        }
        let rejectedAuthority = await service.submit(quote: quote(clock.date), credential: "offline-credential", account: account,
            validate: { throw AgentError.message("Revoked quote") }, invalidate: { preconditionFailure("Revoked authority invalidated") })
        checkNotDispatched(rejectedAuthority, "Caller authority failure is explicitly not dispatched")
        expect(backend.submissions.count == countBefore && invalidations == 1, "No failed preflight dispatches, retries or invalidates a quote")

        let incompleteDrafts = [
            PaotuiDraft(recipientID: "address:1", senderID: "address:2", goods: "文件", category: .document, weight: 0.5),
            PaotuiDraft(service: .send, recipientID: "address:1", senderID: "address:2", goods: "文件", category: .document),
            PaotuiDraft(service: .send, recipientID: "address:1", senderID: "address:2", goods: "文件", weight: 0.5),
            PaotuiDraft(service: .send, recipientID: "address:1", goods: "文件", category: .document, weight: 0.5),
            PaotuiDraft(service: .send, recipientID: "address:1", senderID: "address:2", goods: "文件", category: .document, weight: 0),
            PaotuiDraft(service: .send, recipientID: "address:1", senderID: "address:2", nearby: true, goods: "文件", category: .document, weight: 0.5),
            PaotuiDraft(service: .buy, recipientID: "address:1", goods: "水一瓶")
        ]
        let receiptCountBefore = try rows(servicePath).count
        for draft in incompleteDrafts {
            let rejected = await service.submit(quote: quote(clock.date, draft: draft), credential: "offline-credential", account: account,
                validate: {}, invalidate: { preconditionFailure("Incomplete request invalidated quote") })
            checkNotDispatched(rejected, "The order service independently rejects incomplete or invalid native or tool request facts")
        }
        expect(backend.submissions.count == countBefore && !serviceJournal.hasUnresolvedSubmission,
               "Incomplete manually constructed quotes never dispatch or create an unknown attempt")
        try expect(rows(servicePath).count == receiptCountBefore, "Incomplete requests leave the durable journal unchanged")

        let preCancelled = Task { await service.submit(quote: quote(clock.date), credential: "offline-credential", account: account,
            validate: {}, invalidate: { preconditionFailure("Cancelled preflight invalidated") }) }
        preCancelled.cancel()
        checkNotDispatched(await preCancelled.value, "Cancellation before dispatch creates no attempt")
        let noWritePath = directory.appendingPathComponent("no-write.json")
        let noWriteJournal = PaotuiOrderJournal(url: noWritePath, clock: clock.clock, commit: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let noWriteService = PaotuiOrderService(journal: noWriteJournal, clientFactory: backend.client, clock: clock.clock)
        checkNotDispatched(await noWriteService.submit(quote: quote(clock.date), credential: "offline-credential", account: account,
            validate: {}, invalidate: { preconditionFailure("Failed write invalidated") }), "Pending persistence failure is not dispatched")
        expect(!noWriteJournal.hasUnresolvedSubmission && !FileManager.default.fileExists(atPath: noWritePath.path) && backend.submissions.count == countBefore,
               "Failed initial persistence creates neither a pending memory row nor HTTP")

        // The independent lock and review guard survive suspension; cancellation
        // and caller/account replacement after dispatch cannot erase the receipt.
        let gatedPath = directory.appendingPathComponent("gated.json")
        let gatedJournal = PaotuiOrderJournal(url: gatedPath, clock: clock.clock)
        let gatedBackend = Backend(), gate = Gate(); gatedBackend.submitGate = gate
        let gatedService = PaotuiOrderService(journal: gatedJournal, clientFactory: gatedBackend.client, clock: clock.clock)
        var currentAccount = account
        let gatedWork = Task { await gatedService.submit(quote: quote(clock.date), credential: "old-offline-token", account: currentAccount,
            validate: {}, invalidate: {}) }
        await gate.wait()
        expect(gatedService.isSubmitting && gatedJournal.hasUnresolvedSubmission, "Submission lock is independent of any Store busy flag")
        let activeAttempt = gatedJournal.pendingReviews(account: account)[0].id
        checkNotDispatched(await gatedService.submit(quote: quote(clock.date), credential: "old-offline-token", account: account,
            validate: {}, invalidate: {}), "A parallel submission is not dispatched")
        rejects("A review cannot race a dispatched submission") { try gatedService.recordReview(attemptID: activeAttempt, conclusion: .believesNotCreated) }
        expect(gatedJournal.pendingReviews(account: account)[0].lastConclusion == nil, "Rejected in-flight review does not mutate the journal")
        currentAccount = otherAccount; gatedWork.cancel(); gate.resume()
        if case .created = await gatedWork.value { checks += 1 } else { preconditionFailure("Late cancellation erased successful submit") }
        expect(gatedJournal.lastOrderID(account: account) == "fixture-order" && gatedJournal.lastOrderID(account: currentAccount) == nil &&
               gatedBackend.credentials == ["old-offline-token"], "Cancelled old-account success is persisted under captured original credentials")
        expect(!gatedService.isSubmitting && gatedBackend.submissions.count == 1, "Cancellation after dispatch never retries")

        // No write path may publish created unless the second commit succeeds.
        let secondCommitPath = directory.appendingPathComponent("second-commit.json")
        var commitNumber = 0
        let secondCommitJournal = PaotuiOrderJournal(url: secondCommitPath, clock: clock.clock, commit: { staged, destination in
            commitNumber += 1
            if commitNumber == 2 { throw CocoaError(.fileWriteNoPermission) }
            guard rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        })
        let secondBackend = Backend()
        let secondService = PaotuiOrderService(journal: secondCommitJournal, clientFactory: secondBackend.client, clock: clock.clock)
        let unsavedResult = await secondService.submit(quote: quote(clock.date), credential: "offline-token", account: account, validate: {}, invalidate: {})
        if case .outcomeUnknown(let id, let known, _) = unsavedResult {
            expect(id == secondCommitJournal.pendingReviews(account: account)[0].id && known == "fixture-order", "Failed created commit returns typed unknown with known provider ID")
        } else { preconditionFailure("Failed receipt commit was reported as created") }
        expect(secondCommitJournal.hasUnresolvedSubmission && secondCommitJournal.lastOrderID(account: account) == nil,
               "Known but unsaved order keeps the durable unknown barrier")
        try expect(rows(secondCommitPath)[0]["state"] as? String == "unknown", "Second commit failure leaves the first durable pending row")
        checkNotDispatched(await secondService.submit(quote: quote(clock.date, account: otherAccount), credential: "new-token", account: otherAccount,
            validate: {}, invalidate: {}), "A new authorization cannot bypass an unsaved receipt")
        expect(secondBackend.submissions.count == 1, "A failed created commit causes no automatic retry")

        for missing in [false, true] {
            let unknownPath = directory.appendingPathComponent(missing ? "missing-id.json" : "lost-response.json")
            let unknownJournal = PaotuiOrderJournal(url: unknownPath, clock: clock.clock)
            let unknownBackend = Backend(); unknownBackend.failSubmit = !missing; unknownBackend.submitResponse = [:]
            let unknownService = PaotuiOrderService(journal: unknownJournal, clientFactory: unknownBackend.client, clock: clock.clock)
            let unknownResult = await unknownService.submit(quote: quote(clock.date), credential: "offline-token", account: account, validate: {}, invalidate: {})
            if case .outcomeUnknown(let id, let known, let message) = unknownResult {
                expect(id == unknownJournal.pendingReviews(account: account)[0].id && known == nil && !message.isEmpty,
                       "Lost response and missing provider ID return an explicit unknown attempt")
            } else { preconditionFailure("Dispatched uncertainty was classified not dispatched") }
            checkNotDispatched(await unknownService.submit(quote: quote(clock.date, account: otherAccount), credential: "new-token", account: otherAccount,
                validate: {}, invalidate: {}), "Changed account and request cannot bypass a dispatched unknown")
            expect(unknownBackend.submissions.count == 1 && PaotuiOrderJournal(url: unknownPath, clock: clock.clock).hasUnresolvedSubmission,
                   "Unknown outcomes survive restart and never retry")
            try unknownService.recordReview(attemptID: unknownJournal.pendingReviews(account: account)[0].id, conclusion: .stillUnknown)
            expect(unknownJournal.hasUnresolvedSubmission, "Service review of still-unknown keeps the global barrier")
        }

        let numericJournal = PaotuiOrderJournal(url: directory.appendingPathComponent("numeric.json"), clock: clock.clock)
        let numericBackend = Backend(); numericBackend.submitResponse = ["orderId": 12345]
        let numericService = PaotuiOrderService(journal: numericJournal, clientFactory: numericBackend.client, clock: clock.clock)
        let freshBoundary = quote(clock.date.addingTimeInterval(-299.999))
        if case .created(let id, let payment) = await numericService.submit(quote: freshBoundary, credential: "offline-token", account: account, validate: {}, invalidate: {}) {
            expect(id == "12345" && payment == nil && numericJournal.lastOrderID(account: account) == "12345",
                   "Sub-five-minute quote and numeric provider ID preserve existing behavior without inventing payment data")
        } else { preconditionFailure("Valid injected-clock boundary quote was rejected") }
        let exactJournal = PaotuiOrderJournal(url: directory.appendingPathComponent("exact-money.json"), clock: clock.clock)
        let exactBackend = Backend()
        let exactService = PaotuiOrderService(journal: exactJournal, clientFactory: exactBackend.client, clock: clock.clock)
        let template = quote(clock.date)
        let exactQuote = PaotuiQuote(id: UUID(), draft: template.draft, senderTitle: template.senderTitle,
            recipientTitle: template.recipientTitle, serviceTitle: template.serviceTitle, distance: template.distance,
            estimate: template.estimate, deliveryAmount: try PaotuiMoney(amount: "92233720368547758.07"),
            originalDeliveryAmount: try PaotuiMoney(amount: "92233720368547758.06"),
            goodsPaymentNote: template.goodsPaymentNote, quotedAt: template.quotedAt,
            agreementURL: nil, agreementTitle: template.agreementTitle, account: account, request: template.request,
            orderToken: template.orderToken, couponViewID: template.couponViewID)
        if case .created = await exactService.submit(quote: exactQuote, credential: "offline-token", account: account, validate: {}, invalidate: {}) {
            checks += 1
        } else { preconditionFailure("Exact Int64-limit quote was rejected") }
        expect(exactBackend.submissions[0]["previewTotal"] as? String == "92233720368547758.07" &&
               exactBackend.submissions[0]["deliveryFee"] as? String == "92233720368547758.06",
               "Wire uses exact integer fen even when display Double cannot distinguish the two amounts")
        let preciseRows = try rows(directory.appendingPathComponent("exact-money.json"))
        expect((preciseRows[0]["deliveryAmount"] as? [String: Any])?["minorUnits"] as? Int64 == Int64.max,
               "Journal retains exact Int64 maximum fen across JSON persistence")
        print("PASS: \(checks) actual production journal/order-service checks; synthetic transport, no device/network/orders")
    }
}
