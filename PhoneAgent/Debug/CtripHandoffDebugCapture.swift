#if DEBUG
import Foundation

/// One-shot, opt-in capture for a public flight/date test in the cable-only
/// diagnostic session. Off by default; no request, headers, token or account is
/// recorded. CtripClient has already rejected credential echoes in this text.
@MainActor enum CtripHandoffDebugCapture {
    private struct Permit {
        let flight: String
        let date: String
        let until: Date
    }
    private static var permit: Permit?
    private static var captureID: UUID?
    private static var captured: [String: Any] = [:]
    private static var retentionDeadline: Date?
    static var snapshot: [String: Any] {
        if let until = retentionDeadline, Date() >= until {
            permit = nil; captureID = nil; retentionDeadline = nil
            captured = ["status": "expired"]
        }
        return captured
    }

    static func arm(_ value: String?, at now: Date = Date()) throws {
        if value == "clear" {
            permit = nil; captureID = nil; retentionDeadline = nil; captured = [:]; return
        }
        let fields = (value ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2,
              fields[0].range(of: #"^[A-Z0-9]{2}\d{3,4}$"#, options: .regularExpression) != nil else {
            throw AgentError.message("补查诊断需要准确的公开测试航班号和日期")
        }
        let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "Asia/Shanghai")
        format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
        guard let day = format.date(from: fields[1]), format.string(from: day) == fields[1] else {
            throw AgentError.message("补查诊断日期无效")
        }
        let until = now.addingTimeInterval(180)
        permit = Permit(flight: fields[0], date: fields[1], until: until)
        retentionDeadline = until
        captureID = nil
        captured = ["status": "armed", "flight": fields[0], "date": fields[1], "expires_at": until.timeIntervalSince1970]
    }

    static func begin(for offer: CtripFlightOffer) -> UUID? {
        guard let allowed = permit else { return nil }
        guard Date() < allowed.until else { permit = nil; captured = ["status": "expired"]; return nil }
        guard CtripFlightParser.flightNumbers(in: offer.title) == [allowed.flight],
              offer.leg(departure: true).date == allowed.date else { return nil }
        permit = nil // The next handoff cannot inherit this permission.
        let id = UUID(); captureID = id
        captured = ["status": "started", "flight": allowed.flight, "date": allowed.date,
                    "capture_id": id.uuidString, "started_at": Date().timeIntervalSince1970]
        return id
    }

    static func response(_ text: String, reason: String, id: UUID?) {
        guard let id, captureID == id else { return }
        captured["status"] = "response_received"
        captured["reason"] = reason
        captured["business_response"] = String(text.prefix(CtripClient.textLimit))
        captured["response_characters"] = text.count
        captured["captured_at"] = Date().timeIntervalSince1970
    }
    static func failed(id: UUID?) {
        guard let id, captureID == id else { return }
        captured["status"] = "query_failed"
        captured["reason"] = "lookup_transport_failed"
    }
    static func completed(reason: String?, id: UUID?) {
        guard let id, captureID == id else { return }
        if captured["status"] as? String == "started" { captured["status"] = "no_supplement_needed" }
        captured["reason"] = reason ?? "unknown"
    }
}
#endif
