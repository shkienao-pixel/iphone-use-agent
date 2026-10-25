import Foundation
import CryptoKit
import Security

enum ChatGPTPlanError: LocalizedError {
    case message(String)
    case denied
    var errorDescription: String? { if case .message(let value) = self { return value }; return "ChatGPT 登录未获授权" }
}

struct ChatGPTPlanProfile: Codable, Identifiable {
    var id: UUID
    var clientID: String
    var issuer: String?
    var subject: String?
    var email: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var scopes: [String] = []
    var expiresAt: Date?
    var authorizationID: UUID? = nil
    var sharing: Bool {
        subject != nil && issuer == "https://auth.openai.com" && accessToken?.isEmpty == false &&
        scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke")
    }
    /// Account/grant identity for in-flight work. Routine bearer rotation must
    /// not cancel a successful chat or memory result. This is never a bearer.
    var authorizationBinding: String? {
        guard sharing else { return nil }
        let fields = [id.uuidString, clientID, issuer ?? "", subject ?? "", authorizationID?.uuidString ?? "legacy"] + Set(scopes).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return "chatgpt-plan:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ChatGPTPlanProtocol {
    static let endpoint = "https://api.openai.com/v1/responses"
    static let authorizeEndpoint = "https://auth.openai.com/api/accounts/authorize"
    static let tokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    struct Attempt {
        let state: String
        let nonce: String
        let verifier: String
        let redirect: URL
        let existingClientID: String?
        init(port: UInt16, clientID: String? = nil) throws {
            state = try ChatGPTPlanProtocol.random(); nonce = try ChatGPTPlanProtocol.random()
            verifier = try ChatGPTPlanProtocol.random()
            redirect = URL(string: "http://127.0.0.1:\(port)/auth/callback")!
            existingClientID = clientID
        }
        func authorizationURL(hostID: String) throws -> URL {
            guard hostID.hasPrefix("urn:uuid:"), UUID(uuidString: String(hostID.dropFirst(9))) != nil else {
                throw ChatGPTPlanError.message("ChatGPT 本机标识无效")
            }
            var parts = URLComponents(string: ChatGPTPlanProtocol.authorizeEndpoint)!
            var items = [URLQueryItem(name: "client_id", value: existingClientID ?? "dynamic_agent_client"),
                .init(name: "ext_agent_host_id", value: hostID), .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "scope", value: ChatGPTPlanProtocol.scopes),
                .init(name: "resource", value: "https://api.openai.com/v1"), .init(name: "state", value: state),
                .init(name: "nonce", value: nonce), .init(name: "code_challenge_method", value: "S256"),
                .init(name: "code_challenge", value: ChatGPTPlanProtocol.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))))]
            if existingClientID == nil { items.append(.init(name: "agent_name_hint", value: "Sela")) }
            parts.queryItems = items
            return parts.url!
        }
    }
    struct Callback { let code: String; let clientID: String }
    static func callback(_ request: Data, attempt: Attempt) throws -> Callback {
        guard request.count <= 16_384, let text = String(data: request, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else { throw ChatGPTPlanError.message("登录回调无效") }
        let line = first.split(separator: " ")
        guard line.count == 3, line[0] == "GET", line[2] == "HTTP/1.1", line[1].hasPrefix("/auth/callback?"),
              let parts = URLComponents(string: "http://127.0.0.1:\(attempt.redirect.port!)" + line[1]),
              parts.percentEncodedPath == "/auth/callback", parts.fragment == nil else { throw ChatGPTPlanError.message("登录回调路径无效") }
        let headers = text.components(separatedBy: "\r\n").dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard headers.count == 1, headers[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(attempt.redirect.port!)" else {
            throw ChatGPTPlanError.message("登录回调来源无效")
        }
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { throw ChatGPTPlanError.message("登录回调参数重复或缺失") }
            values[item.name] = value
        }
        guard values["state"] == attempt.state else { throw ChatGPTPlanError.message("登录回调与当前请求不匹配") }
        if values["error"] != nil { throw ChatGPTPlanError.denied }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 4096 else { throw ChatGPTPlanError.message("登录回调缺少授权码") }
        let client = values["client_id"] ?? attempt.existingClientID ?? ""
        guard !client.isEmpty, client != "dynamic_agent_client", client.utf8.count <= 256,
              attempt.existingClientID == nil || attempt.existingClientID == client else { throw ChatGPTPlanError.message("ChatGPT 客户端注册不匹配") }
        return Callback(code: code, clientID: client)
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTPlanError.message("无法安全创建登录请求") }
        return base64url(Data(bytes))
    }
    static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode64(_ text: String) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }
    struct Identity { let issuer: String; let subject: String; let email: String? }
    static func validateIDToken(_ token: String, jwks: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> Identity {
        func invalid() -> ChatGPTPlanError { .message("ChatGPT 身份签名或账户校验失败") }
        guard token.utf8.count <= 32_768 else { throw invalid() }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let head = decode64(String(pieces[0])), let claims = decode64(String(pieces[1])), let signature = decode64(String(pieces[2])),
              let h = try JSONSerialization.jsonObject(with: head) as? [String: Any], h["alg"] as? String == "RS256", let kid = h["kid"] as? String,
              let payload = try JSONSerialization.jsonObject(with: claims) as? [String: Any],
              let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]] else { throw invalid() }
        let matches = keys.filter { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] == nil || $0["use"] as? String == "sig") && ($0["alg"] == nil || $0["alg"] as? String == "RS256") }
        guard matches.count == 1, let n = matches[0]["n"] as? String, let e = matches[0]["e"] as? String,
              let modulus = decode64(n), let exponent = decode64(e), modulus.count >= 256, modulus.count <= 1024,
              let key = SecKeyCreateWithData(rsaDER(modulus, exponent) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((pieces[0] + "." + pieces[1]).utf8) as CFData, signature as CFData, nil),
              payload["iss"] as? String == "https://auth.openai.com", let subject = payload["sub"] as? String, !subject.isEmpty,
              let expiry = payload["exp"] as? Double, expiry > now.timeIntervalSince1970,
              (payload["aud"] as? String == clientID || (payload["aud"] as? [String])?.contains(clientID) == true),
              nonce == nil || payload["nonce"] as? String == nonce else { throw invalid() }
        if let audience = payload["aud"] as? [String], audience.count > 1, payload["azp"] as? String != clientID { throw invalid() }
        return Identity(issuer: "https://auth.openai.com", subject: subject, email: payload["email"] as? String)
    }
    private static func rsaDER(_ n: Data, _ e: Data) -> Data {
        func length(_ count: Int) -> Data {
            if count < 128 { return Data([UInt8(count)]) }
            var value = count, bytes: [UInt8] = []
            while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ bytes: Data) -> Data {
            var value = Data(bytes.drop(while: { $0 == 0 })); if value.isEmpty { value = Data([0]) }
            if value[0] >= 128 { value.insert(0, at: 0) }
            return Data([2]) + length(value.count) + value
        }
        let body = integer(n) + integer(e); return Data([0x30]) + length(body.count) + body
    }
}
