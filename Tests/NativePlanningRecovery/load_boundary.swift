import Foundation

enum AgentError: LocalizedError { case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct LoadSettings { let usesChatGPTPlan: Bool }
enum LoadFixture {
    static let profileID = UUID()
    static var profileActive = true
    static var status = 503
    static var body = Data()
    static var headers = ["Retry-After": "120"]
    static var requests = 0
    static var lastRequest: URLRequest?
}
struct FixtureProfile { let accessToken: String? }
actor ChatGPTPlanTokens {
    static let shared = ChatGPTPlanTokens()
    func valid(_ id: UUID) async throws -> FixtureProfile { FixtureProfile(accessToken: "LOCAL_FIXTURE_BEARER") }
}
enum ChatGPTPlanStore { static func active(_ id: UUID) -> Bool { LoadFixture.profileActive } }
final class FixtureMetrics {}
final class ModelRequestMetricsDelegate {
    init(original: URL, recorder: FixtureMetrics, parentID: UUID?, allowsRedirects: Bool) {}
}
final class FixtureSession {
    func data(for request: URLRequest, delegate: ModelRequestMetricsDelegate? = nil) async throws -> (Data, URLResponse) {
        LoadFixture.requests += 1; LoadFixture.lastRequest = request
        return (LoadFixture.body, HTTPURLResponse(url: request.url!, statusCode: LoadFixture.status,
            httpVersion: "HTTP/1.1", headerFields: LoadFixture.headers)!)
    }
}
struct FixtureConnection { let session = FixtureSession() }

@main struct ProducerChecks {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        func request(_ plan: Bool) throws -> URLRequest {
            var request = URLRequest(url: URL(string: plan ? ChatGPTPlanProtocol.endpoint : "https://model.invalid/chat/completions")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "fixture-model", "messages": [["role": "user", "content": "public fixture"]]])
            return request
        }
        for plan in [false, true] {
            let client = LoadBoundaryClient(settings: LoadSettings(usesChatGPTPlan: plan))
            for status in [500, 503, 504] {
                LoadFixture.status = status; LoadFixture.requests = 0
                LoadFixture.body = try JSONSerialization.data(withJSONObject: ["error": ["code": "server_is_overloaded", "message": "PRIVATE_PROVIDER_TEXT"]])
                do { _ = try await client.load(request(plan)); preconditionFailure("Transient response lost typed provenance") }
                catch let failure as NativePlanningServiceFailure {
                    check(failure.status == status)
                    check(NativePlanningRecovery.delay(for: failure, retries: 0, jitter: 0) == 120_000_000_000)
                    check(!failure.localizedDescription.contains("PRIVATE_PROVIDER_TEXT"))
                }
                check(LoadFixture.requests == 1)
            }
            if plan {
                check(LoadFixture.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer LOCAL_FIXTURE_BEARER")
                let body = try JSONSerialization.jsonObject(with: LoadFixture.lastRequest!.httpBody!) as! [String: Any]
                check(body["stream"] as? Bool == true && body["store"] as? Bool == false)
            }
            for status in [401, 403, 429] {
                LoadFixture.status = status; LoadFixture.requests = 0
                LoadFixture.body = Data("{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}".utf8)
                do {
                    let value = try await client.load(request(plan))
                    check(!plan && (value.1 as? HTTPURLResponse)?.statusCode == status)
                } catch is NativePlanningServiceFailure { preconditionFailure("Authorization or quota turned into auto retry") }
                catch is ChatGPTPlanError { check(plan) }
                check(LoadFixture.requests == 1)
            }
        }
        LoadFixture.status = 503; LoadFixture.profileActive = false; LoadFixture.requests = 0
        let client = LoadBoundaryClient(settings: LoadSettings(usesChatGPTPlan: true))
        do { _ = try await client.load(request(true)); preconditionFailure("Old account response adopted") }
        catch is CancellationError { check(LoadFixture.requests == 1) }
        LoadFixture.profileActive = true; LoadFixture.status = 200; LoadFixture.body = Data("malformed stream".utf8)
        do { _ = try await client.load(request(true)); preconditionFailure("Invalid stream adopted") }
        catch is NativePlanningServiceFailure { preconditionFailure("Parse violation turned into HTTP retry") }
        catch is ChatGPTPlanError { check(true) }
        print("Native planning HTTP producer: \(checks) checks passed; actual unchanged load body, fake session/account only; no network or device")
    }
}
