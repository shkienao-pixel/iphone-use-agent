import Foundation

struct ScreenFrame { let jpeg: Data; let capturedAt: Date }
enum PhoneControlSkill { static func instructions() throws -> String { "Offline phone skill boundary" } }
enum AppleSupportSkill { static func instructions(for task: String) throws -> String { "Offline support boundary" } }
enum NativeSkillCatalog {
    struct Selection { let names = [String](); let instructions = "Offline native skill resource boundary"; let receipt = ""; let runtimeReceipts = [String]() }
    static func selection(for task: String) throws -> Selection { Selection() }
}
enum CtripStore { static let enabled = false; static let hasCredential = false }
enum MeituanConnectionStore { static let verified = false }
struct MeituanPaotuiStore { static let shared = Self(); let configured = false; let ready = false }

@MainActor enum RoutingWireProbe {
    static var requests: [URLRequest] = []
    static var content = ""
    static var finishReason = "stop"
    static var responseStatus = "completed"
    static var refusal = false
    static var statusCode = 200
    static var responseURL: URL?
    static var rawPayload: Data?
    static var transportError: Error?
    static var gateNext = false
    static var pending: CheckedContinuation<Void, Never>?

    static func reset() {
        precondition(pending == nil, "Finish the earlier gated response first")
        content = #"{"mode":"chat","request":"","message":"","taskID":null}"#
        finishReason = "stop"; responseStatus = "completed"; refusal = false
        statusCode = 200; responseURL = nil; rawPayload = nil; transportError = nil; gateNext = false
    }
    static func route(_ mode: String, request: String = "", message: String = "", taskID: String? = nil) throws {
        content = String(decoding: try JSONSerialization.data(withJSONObject: ["mode": mode, "request": request,
            "message": message, "taskID": taskID.map { $0 as Any } ?? NSNull()]), as: UTF8.self)
    }
    static func response(_ request: URLRequest, connected: Bool) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data: Data
        if let rawPayload { data = rawPayload }
        else if connected {
            let part: [String: Any] = refusal ? ["type": "refusal", "refusal": "offline refusal"] : ["type": "output_text", "text": content]
            data = try JSONSerialization.data(withJSONObject: ["status": responseStatus, "model": "offline-returned-model",
                "output": [["type": "message", "role": "assistant", "content": [part]]]])
        } else {
            var message: [String: Any] = ["content": content]
            if refusal { message["refusal"] = "offline refusal" }
            data = try JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finishReason]]])
        }
        let response = HTTPURLResponse(url: responseURL ?? request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        let failure = transportError
        if gateNext {
            gateNext = false
            // Intentionally ignore cancellation until the local gate is resumed.
            await withCheckedContinuation { pending = $0 }
        }
        if let failure { throw failure }
        return (data, response)
    }
    static func load(_ request: URLRequest) async throws -> (Data, URLResponse) { try await response(request, connected: false) }
    static func loadConnected(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await response(request, connected: true) }
    static func resume() { let continuation = pending; pending = nil; continuation?.resume() }
}
