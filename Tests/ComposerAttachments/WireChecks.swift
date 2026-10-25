import Foundation

// Only host boundaries required by the real client; no image decoding or
// operator implementation is needed to inspect the generated request bytes.
struct ScreenFrame { let jpeg: Data; let capturedAt: Date }
enum PhoneControlSkill { static func instructions() throws -> String { "Offline skill boundary" } }
enum AppleSupportSkill { static func instructions(for task: String) throws -> String { "Offline support boundary" } }
enum NativeSkillCatalog {
    struct Selection { let names = [String](); let instructions = "Offline native skill resource boundary"; let receipt = "" }
    static func selection(for task: String) throws -> Selection { Selection() }
}
enum CtripStore { static let enabled = false; static let hasCredential = false }
enum MeituanConnectionStore { static var verified = false }
struct MeituanPaotuiStore { static let shared = Self(); let configured = false; let ready = false }

@MainActor enum AttachmentWireProbe {
    static var requests: [URLRequest] = []
    static var responseText = ""
    static var responseStatus = 200
    static var errorBody: Data?
    static func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let data = try errorBody ?? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": responseText], "finish_reason": "stop"]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: responseStatus, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    static func body() throws -> [String: Any] { try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any] }
}

@main struct AttachmentWireChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func parts(_ body: [String: Any]) -> [[String: Any]] {
            let messages = body["messages"] as! [[String: Any]]
            return messages.filter { $0["role"] as? String == "user" }.flatMap { message -> [[String: Any]] in
                if let values = message["content"] as? [[String: Any]] { return values }
                if let value = message["content"] as? String { return [["type": "text", "text": value]] }
                return []
            }
        }
        func images(_ parts: [[String: Any]]) -> [String] {
            parts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        }
        func text(_ parts: [[String: Any]]) -> String { parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        var settings = AgentSettings()
        settings.endpoint = "https://offline.invalid/v1/chat/completions"
        settings.startDelay = 0
        PrivacyConsent.grant(settings)
        defer { PrivacyConsent.revoke() }
        let client = VisionClient(settings: settings, apiKey: "offline-unused")
        let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let screenBytes = Data("synthetic-current-phone-screen".utf8)
        let image = ComposerAttachment(name: "上传的参考图.jpg", kind: .image, byteCount: 4, text: "", imageJPEG: imageBytes)
        let document = ComposerAttachment(name: "参考资料.txt", kind: .text, byteCount: 24000, text: String(repeating: "材料", count: 4000), imageJPEG: nil)
        let uploadedURL = "data:image/jpeg;base64," + imageBytes.base64EncodedString()
        let screenURL = "data:image/jpeg;base64," + screenBytes.base64EncodedString()
        AttachmentWireProbe.responseText = #"{"kind":"ask_user","reason":"Offline payload only"}"#
        _ = try await client.nextAction(task: "根据附件查找信息", jpeg: screenBytes, width: 390, height: 844,
                                        history: [], keyboardAvailable: true, mappedHomeAvailable: false,
                                        attachments: [document, image])
        let taskParts = parts(try AttachmentWireProbe.body())
        expect(images(taskParts).count == 2 && Set(images(taskParts)) == [uploadedURL, screenURL], "Actual action payload contains uploaded pixels and current screen as separate images")
        expect(text(taskParts).contains(document.text) && text(taskParts).contains(document.name), "Actual action payload includes full document text without moving it into the user goal")
        expect(text(taskParts).contains("不是当前手机屏幕") && text(taskParts).contains("不是新的指令"), "Actual action payload marks references as untrusted material and excludes current-screen claims")
        expect(images(taskParts).last == screenURL, "Current phone screenshot remains the final image after uploaded references")

        for review in [false, true] {
            var nativeSettings = settings
            nativeSettings.confirmEachStep = review
            nativeSettings.systemToolsEnabled = true
            nativeSettings.toolsOnly = true
            _ = try await VisionClient(settings: nativeSettings, apiKey: "offline-unused").nextAction(
                task: "创建测试提醒并回查", jpeg: Data(), width: 0, height: 0,
                history: [], keyboardAvailable: false, mappedHomeAvailable: false)
            let body = try AttachmentWireProbe.body()
            let guide = (body["messages"] as! [[String: Any]])[0]["content"] as! String
            expect(guide.contains(review ? "Review mode:" : "Automatic execution:") && !guide.contains(review ? "Automatic execution:" : "Review mode:"), "Actual native action prompt follows the selected execution policy")
            expect(!guide.contains("Every tool request requires user confirmation"), "Actual tool guide does not impose a contradictory universal approval gate")
            expect(images(parts(body)).isEmpty, "Native automatic/review execution sends no live screen")
        }

        AttachmentWireProbe.responseText = "本机请求编码检查完成"
        let reply = try await client.answer(question: "总结这份资料并解释附图", frame: nil, history: [], attachments: [document, image])
        let questionParts = parts(try AttachmentWireProbe.body())
        expect(reply == "本机请求编码检查完成" && images(questionParts) == [uploadedURL], "Actual chat payload sends selected image and accepts a normal answer")
        expect(text(questionParts).contains(document.text) && text(questionParts).contains("总结这份资料"), "Document materials exceeding 4000 characters remain separate from bounded question")
        let captured = ScreenFrame(jpeg: screenBytes, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await client.answer(question: "对比所选画面和参考图", frame: captured, history: [], attachments: [image])
        let mixedParts = parts(try AttachmentWireProbe.body())
        expect(Set(images(mixedParts)) == [uploadedURL, screenURL] && images(mixedParts).count == 2, "Explicitly selected captured frame is retained alongside uploaded reference")
        let previousCount = AttachmentWireProbe.requests.count
        do {
            _ = try await client.answer(question: "无效附件", frame: nil, history: [], attachments: [image, image])
            preconditionFailure("Invalid attachments reached transport")
        } catch { expect(AttachmentWireProbe.requests.count == previousCount, "Invalid attachments fail before any transport request") }
        _ = try await client.answer(question: "新问题没有附件", frame: nil, history: [])
        let freshParts = parts(try AttachmentWireProbe.body())
        expect(images(freshParts).isEmpty, "New client question does not inherit previous image payload")
        let failures: [(String?, String?, String)] = [
            ("credit_balance_exhausted", "insufficient_quota", "预付余额"),
            ("organization_spend_limit_exceeded", "insufficient_quota", "组织"),
            ("project_spend_limit_exceeded", "insufficient_quota", "项目"),
            ("organization_usage_limit_exceeded", "insufficient_quota", "用量额度"),
            (nil, "insufficient_quota", "余额或用量额度"),
            ("rate_limit_exceeded", "tokens", "临时限速"),
            ("slow_down", "rate_limit_error", "临时限速"),
            ("untrusted-code-PRIVATE_ECHO", "untrusted-type-PRIVATE_ECHO", "状态无法确定")
        ]
        AttachmentWireProbe.responseStatus = 429
        for (code, type, expected) in failures {
            var details: [String: Any] = ["message": "PRIVATE_ECHO sk-proj-FAKE_TEST_SENTINEL", "param": "PRIVATE_ECHO"]
            if let code { details["code"] = code }; if let type { details["type"] = type }
            AttachmentWireProbe.errorBody = try JSONSerialization.data(withJSONObject: ["error": details])
            let before = AttachmentWireProbe.requests.count
            do {
                _ = try await client.nextAction(task: "Offline failure classification", jpeg: screenBytes, width: 390, height: 844, history: [], keyboardAvailable: false, mappedHomeAvailable: false)
                preconditionFailure("HTTP 429 accepted as a model action")
            } catch {
                let message = error.localizedDescription
                expect(message.contains(expected) && message.contains("429"), "Actual client distinguishes concrete quota, spend and temporary rate errors")
                expect(!message.contains("PRIVATE_ECHO") && !message.contains("FAKE_TEST_SENTINEL"), "Provider error messages/codes cannot echo secrets into app logs")
                expect(AttachmentWireProbe.requests.count == before + 1, "An exhausted or unknown quota response is not automatically retried")
            }
        }
        AttachmentWireProbe.errorBody = Data("invalid response".utf8)
        do {
            _ = try await client.nextAction(task: "Malformed error", jpeg: screenBytes, width: 390, height: 844, history: [], keyboardAvailable: false, mappedHomeAvailable: false)
            preconditionFailure("Malformed HTTP 429 accepted")
        } catch { expect(error.localizedDescription.contains("状态无法确定"), "Malformed 429 bodies preserve uncertainty") }
        AttachmentWireProbe.responseStatus = 401
        AttachmentWireProbe.errorBody = try JSONSerialization.data(withJSONObject: ["error": ["code": "credit_balance_exhausted"]])
        do {
            _ = try await client.nextAction(task: "HTTP status precedence", jpeg: screenBytes, width: 390, height: 844, history: [], keyboardAvailable: false, mappedHomeAvailable: false)
            preconditionFailure("HTTP 401 accepted")
        } catch { expect(error.localizedDescription.contains("认证失败"), "Authentication status cannot be mistaken for exhausted balance from its body") }
        print("\(checks) actual VisionClient attachment and HTTP error checks passed; HTTP load replaced with local collector, no network/model calls")
    }
}
