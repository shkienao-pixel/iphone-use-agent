#if DEBUG
import Foundation

@MainActor func runCtripDebugCaptureChecks(_ check: (String, Bool) -> Void) {
    do {
        try CtripHandoffDebugCapture.arm("clear")
        check("debug capture is off by default/after clear", CtripHandoffDebugCapture.snapshot.isEmpty)
        var invalidRejected = false
        do { try CtripHandoffDebugCapture.arm("HU7614|invalid-date") }
        catch { invalidRejected = true }
        check("debug capture requires an exact valid public test flight/date", invalidRejected)
        try CtripHandoffDebugCapture.arm("HU7614|2026-10-29")
        let offer = CtripFlightOffer(id: "public-flight", title: "HU7614", details: "出发日期：2026-10-29\n出发时间：07:20\n到达时间：09:40\n出发机场：上海浦东国际机场 T2\n到达机场：北京首都国际机场 T2\n舱位：经济舱", price: "300元", bookingURL: nil, query: "PRIVATE_QUERY_SENTINEL", queriedAt: Date())
        var wrong = offer; wrong.title = "CA8322"
        check("debug capture ignores another selected flight without consuming its permit", CtripHandoffDebugCapture.begin(for: wrong) == nil && CtripHandoffDebugCapture.snapshot["status"] as? String == "armed")
        var wrongDate = offer; wrongDate.details = wrongDate.details.replacingOccurrences(of: "2026-10-29", with: "2026-10-30")
        check("debug capture ignores another departure date", CtripHandoffDebugCapture.begin(for: wrongDate) == nil)
        let id = CtripHandoffDebugCapture.begin(for: offer)
        check("debug capture starts only for the exact explicit test identity", id != nil)
        let business = "### HU7614\n价格：300元（不含税）"
        CtripHandoffDebugCapture.response(business, reason: "exact_entry_facts_incomplete", id: id)
        let bytes = try JSONSerialization.data(withJSONObject: CtripHandoffDebugCapture.snapshot)
        let text = String(decoding: bytes, as: UTF8.self)
        check("debug capture does not copy the source question or request contents", !text.contains("PRIVATE_QUERY_SENTINEL"))
        check("debug capture preserves only the bounded decoded business response", CtripHandoffDebugCapture.snapshot["business_response"] as? String == business)
        check("debug capture permission is consumed by one handoff", CtripHandoffDebugCapture.begin(for: offer) == nil)
        CtripHandoffDebugCapture.response("wrong completion", reason: "wrong", id: UUID())
        check("debug capture rejects a mismatched completion nonce", CtripHandoffDebugCapture.snapshot["business_response"] as? String == business)
        try CtripHandoffDebugCapture.arm("clear")
        check("debug capture clear removes recorded text immediately", CtripHandoffDebugCapture.snapshot.isEmpty)
        try CtripHandoffDebugCapture.arm("HU7614|2026-10-29", at: Date().addingTimeInterval(-181))
        check("debug capture expires its permission and retained response within 180 seconds", CtripHandoffDebugCapture.snapshot["status"] as? String == "expired" && CtripHandoffDebugCapture.begin(for: offer) == nil && CtripHandoffDebugCapture.snapshot["business_response"] == nil)
        try CtripHandoffDebugCapture.arm("clear")
    } catch { check("debug capture local fixture completed", false) }
}
#endif
