import Foundation
import CryptoKit

/// One submission authority shared by every presentation and conversation scope.
/// A transport error after durable preparation is an unknown outcome, never a retry.
@MainActor final class PaotuiOrderService {
    enum SubmissionResult {
        case created(orderID: String, paymentURL: URL?)
        case notDispatched(message: String)
        case outcomeUnknown(attemptID: UUID, knownOrderID: String?, message: String)

        var message: String {
            switch self {
            case .created: "订单已创建，尚未确认付款。请在美团订单页核对并处理。"
            case .notDispatched(let message), .outcomeUnknown(_, _, let message): message
            }
        }
    }

    let journal: PaotuiOrderJournal
    private let clientFactory: (String) -> MeituanPaotuiClient
    private let clock: PaotuiClock
    private let diagnostics: PaotuiDiagnostics?
    private(set) var isSubmitting = false
    var onChange: (() -> Void)?

    init(journal: PaotuiOrderJournal,
         clientFactory: @escaping (String) -> MeituanPaotuiClient = { MeituanPaotuiClient(credential: $0) },
         clock: PaotuiClock? = nil, diagnostics: PaotuiDiagnostics? = nil) {
        self.journal = journal; self.clientFactory = clientFactory; self.clock = clock ?? .system
        self.diagnostics = diagnostics
    }

    func submit(quote: PaotuiQuote, credential: String, account: String, context: PaotuiAttemptContext? = nil,
                validate: () throws -> Void, invalidate: () -> Void) async -> SubmissionResult {
        let diagnosticContext = Self.diagnosticContext(context, quoteID: quote.id)
        guard !isSubmitting else {
            diagnostics?.record(command: .submitOrder, phase: .submitting, result: .notDispatched, context: diagnosticContext)
            return .notDispatched(message: "已有跑腿订单正在提交，请稍候")
        }
        let span = diagnostics?.start(command: .submitOrder, phase: .submitting, context: diagnosticContext)
        var diagnosticResult: PaotuiDiagnosticResult = .notDispatched
        var diagnosticAttemptID: UUID?
        defer {
            if let span { diagnostics?.finish(span, result: diagnosticResult, context: .init(attemptID: diagnosticAttemptID)) }
        }
        isSubmitting = true; onChange?()
        defer { isSubmitting = false; onChange?() }

        let client = clientFactory(credential)
        var payload = quote.request
        payload["orderToken"] = quote.orderToken
        payload["deliveryFeeChangedAck"] = "true"; payload["couponViewId"] = quote.couponViewID
        payload["payType"] = "1"; payload["pushToken"] = ""

        let attemptID: UUID
        do {
            try Task.checkCancellation()
            // Keep this authority safe even when invoked without the Store's
            // normal preparation path or with a manually constructed quote.
            _ = try quote.draft.validated()
            guard let original = quote.originalDeliveryAmount, let total = quote.deliveryAmount else {
                throw AgentError.message("跑腿报价金额无效，请重新查询费用")
            }
            payload["deliveryFee"] = original.wireAmount; payload["previewTotal"] = total.wireAmount
            guard quote.canSubmit(draft: quote.draft, account: account,
                                  unresolved: journal.hasUnresolvedSubmission, now: clock.now()) else {
                throw AgentError.message("报价或连接已改变，请重新查询费用")
            }
            try validate()
            if let context {
                let scope = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
                guard context.credentialBinding.fingerprint == scope, account == scope else {
                    throw AgentError.message("本次跑腿授权凭据与提交记录不匹配，请重新核对。")
                }
            }
            guard JSONSerialization.isValidJSONObject(payload) else {
                throw AgentError.message("跑腿报价请求格式无效，请重新查询费用")
            }
            // Validate credentials and JSON before recording an attempted send;
            // request creation performs no HTTP and the actual call stays singular.
            _ = try client.request(.submit, payload: payload)
            attemptID = try journal.beginAttempt(quote: quote, account: account, context: context)
            diagnosticAttemptID = attemptID
        } catch is CancellationError {
            return .notDispatched(message: "本次提交已停止，尚未发送订单。")
        } catch {
            return .notDispatched(message: (error as? AgentError)?.localizedDescription ?? "订单提交前检查未完成，请重新核对。")
        }

        diagnosticResult = .outcomeUnknown
        // Revocation happens only once the pending attempt is durable.
        invalidate()
        let data: [String: Any]
        do { data = try await client.call(.submit, payload) }
        catch {
            return .outcomeUnknown(attemptID: attemptID, knownOrderID: nil,
                message: "本次提交结果需要核验，请先在美团查看订单。Sela 不会重复提交。")
        }
        let id = (data["orderId"] as? String) ?? (data["orderId"] as? NSNumber)?.stringValue
        guard let id, !id.isEmpty else {
            return .outcomeUnknown(attemptID: attemptID, knownOrderID: nil,
                message: "美团未返回完整订单回执，请先在美团核对，勿重复下单")
        }
        do { try journal.markCreated(attemptID: attemptID, orderID: id) }
        catch {
            return .outcomeUnknown(attemptID: attemptID, knownOrderID: id,
                message: "订单已创建，但本机回执保存失败。请在美团查看，勿重复下单。")
        }
        // The caller decides whether the initiating presentation is still current.
        // A response for a replaced account is already saved under its original attempt.
        let payment: URL?
        if let trade = data["tradeNo"] as? String, let token = data["payToken"] as? String,
           !trade.isEmpty, !token.isEmpty {
            payment = Self.paymentURL(orderID: id, trade: trade, token: token)
        } else { payment = nil }
        diagnosticResult = .created
        return .created(orderID: id, paymentURL: payment)
    }

    func recordReview(attemptID: UUID, conclusion: PaotuiReviewConclusion, reportedOrderReference: String? = nil) throws {
        guard !isSubmitting else {
            throw AgentError.message("正在处理跑腿请求，请稍后再记录核验结果。")
        }
        let context = Self.diagnosticContext(journal.attemptContext(attemptID: attemptID), attemptID: attemptID)
        do {
            try journal.recordReview(attemptID: attemptID, conclusion: conclusion, reportedOrderReference: reportedOrderReference)
            diagnostics?.record(command: .recordReview, phase: .maintenance, result: .succeeded, context: context)
        } catch {
            diagnostics?.record(command: .recordReview, phase: .maintenance, result: .failed, context: context)
            throw error
        }
    }

    var maintenanceSnapshot: PaotuiJournalMaintenanceSnapshot { journal.maintenanceSnapshot }

    @discardableResult func archiveResolved() throws -> Int {
        guard !isSubmitting else {
            diagnostics?.record(command: .archiveResolved, phase: .maintenance, result: .rejected)
            throw AgentError.message("正在处理跑腿请求，请稍后再归档历史记录。")
        }
        do {
            let count = try journal.archiveResolved()
            diagnostics?.record(command: .archiveResolved, phase: .maintenance, result: .succeeded)
            return count
        } catch {
            diagnostics?.record(command: .archiveResolved, phase: .maintenance, result: .failed)
            throw error
        }
    }

    private static func diagnosticContext(_ value: PaotuiAttemptContext?, quoteID: UUID? = nil,
                                          attemptID: UUID? = nil) -> PaotuiDiagnosticContext {
        PaotuiDiagnosticContext(conversationID: value?.conversationID, sessionID: value?.sessionID,
            revision: value?.revision, quoteID: value?.quoteID ?? quoteID, attemptID: attemptID,
            credentialEpoch: value?.credentialEpoch, taskID: value?.taskOrigin.flatMap(UUID.init(uuidString:)))
    }

    func status(orderID: String, credential: String, account: String,
                validateAuthorization: () throws -> Void) async throws -> String {
        try Task.checkCancellation()
        try validateAuthorization()
        guard journal.knowsCreatedOrder(orderID: orderID, account: account) else {
            throw AgentError.message("请先在这台设备核对实际创建的跑腿订单")
        }
        let data = try await clientFactory(credential).call(.status, ["orderId": orderID, "orderViewId": orderID])
        try Task.checkCancellation()
        try validateAuthorization()
        guard journal.knowsCreatedOrder(orderID: orderID, account: account) else {
            throw AgentError.message("请先在这台设备核对实际创建的跑腿订单")
        }
        // Provider marketing, phone and payment fields never enter AI history.
        let texts = ["statusDesc", "orderStatusDesc", "statusName", "orderStatusName", "statusText"].compactMap { data[$0] as? String }
        return texts.first(where: { !$0.isEmpty && $0.count <= 200 }) ?? "已收到美团订单查询结果，请在美团查看完整配送进度。"
    }

    static func paymentURL(orderID: String, trade: String, token: String) -> URL? {
        var components = URLComponents(string: "https://npay.meituan.com/i/cashier/show/index")!
        let success = "https://i.meituan.com/order/" + orderID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        components.queryItems = ["auth": "v2", "tradeno": trade, "pay_token": token, "pay_success_url": success,
                                "redr_url": success, "nb_location": "0_0", "nb_ci": "0"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }
}
