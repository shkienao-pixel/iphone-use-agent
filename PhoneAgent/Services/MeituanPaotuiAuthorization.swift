import Foundation
import CryptoKit
import Security

struct MeituanPaotuiAuthorization {
    static let clientID = "ac76c22d257c4c6d9164719eea64ed4b"
    struct Session {
        let code: String
        let verifier: String
        let link: URL
        let expires: Date
    }
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = MeituanMCPClient.load
    func get(_ path: String, parameters: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://passport.meituan.com/api/account/userauth/" + path)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1.0.5", forHTTPHeaderField: "cli-version")
        let (data, response) = try await transport(request); try Task.checkCancellation()
        guard response.url == request.url, (200...299).contains(response.statusCode), data.count < 65536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.message("暂时无法连接美团授权服务，请稍后重试")
        }
        let error = object["error"] as? [String: Any]
        let code = (error?["code"] as? NSNumber)?.intValue ?? (object["code"] as? NSNumber)?.intValue ?? 0
        guard code == 0 || code == 200 else {
            if [101144, 101368].contains(code) { throw AgentError.message("美团未完成此次授权，请在美团 App 中核对") }
            throw AgentError.message("美团授权暂未完成，请重新连接")
        }
        guard let result = object["data"] as? [String: Any] else { throw AgentError.message("美团授权结果不完整") }
        return result
    }
    func start() async throws -> Session {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AgentError.message("暂时无法准备安全授权") }
        // The pinned Passport CLI uses hexadecimal SHA256 PKCE, not OAuth's
        // more common base64url encoding. Keep the provider's exact contract.
        let verifier = bytes.map { String(format: "%02x", $0) }.joined()
        let challenge = SHA256.hash(data: Data(verifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let data = try await get("code", parameters: ["client_id": Self.clientID, "code_challenge": challenge])
        guard let code = data["authCode"] as? String, !code.isEmpty,
              let link = (data["shortLink"] as? String).flatMap(MeituanPaotuiClient.officialURL) else { throw AgentError.message("美团未返回有效授权链接") }
        return Session(code: code, verifier: verifier, link: link, expires: Date().addingTimeInterval(600))
    }
    func finish(_ session: Session) async throws -> String? {
        guard session.expires > Date() else { throw AgentError.message("授权链接已过期，请重新连接") }
        let data = try await get("check", parameters: ["client_id": Self.clientID, "auth_code": session.code, "code_verifier": session.verifier])
        let status = (data["authStatus"] as? NSNumber)?.intValue ?? 1
        if [2, 3].contains(status) { throw AgentError.message("美团未通过本次授权，请重新连接") }
        guard status == 4 else { return nil }
        guard (data["authMode"] as? Int ?? 0) == 1, let token = data["accessToken"] as? String, !token.isEmpty else {
            throw AgentError.message("请重新使用美团 App 完成跑腿授权")
        }
        return token
    }
}
