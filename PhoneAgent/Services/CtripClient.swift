import Foundation
import CoreFoundation

enum CtripConnectionMode: String, CaseIterable, Identifiable {
    case wendao, legacy
    var id: String { rawValue }
    var title: String { self == .wendao ? "携程问道" : "兼容旧版授权码" }
    var endpoint: URL { self == .wendao ? CtripClient.wendaoEndpoint : CtripClient.endpoint }
}

// Redirects must never move the authorization code to another endpoint.
final class CtripRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct CtripClient {
    struct FlightResult {
        let providerText: String
        let attempts: Int
        let realtimeUnavailable: Bool
        var retryFailure: String? = nil
        var displayText: String {
            guard realtimeUnavailable else { return providerText }
            if let retryFailure {
                return "携程首次查询未取得实时报价，自动重试时未能完成：\(retryFailure)。\n\n已保留首次返回的时刻参考，尚未核价，不代表实时可售；可去携程查价。\n\n" + providerText
            }
            return "携程暂未返回本次查询的实时报价。已自动重试一次，仍未取得报价。\n\n以下时刻参考尚未核价，不代表实时可售；可去携程查价。\n\n" + providerText
        }
    }
    static let endpoint = URL(string: "https://externalcallback.ctrip.com/skills/api/crew/skillhub/searchInfo")!
    static let wendaoEndpoint = URL(string: "https://wendao-skill-prod.ctrip.com/skill/query")!
    static let responseLimit = 1_048_576
    static let textLimit = 12_000
    let apiKey: String
    var apiEndpoint: URL = Self.endpoint
    // Tests inject offline fixtures. Production uses only this bounded ephemeral transport.
    var transport: (URLRequest) async throws -> (Data, HTTPURLResponse) = Self.load

    private enum TransportFailure: LocalizedError {
        case response, origin, size, http(Int), timeout, network, connectionLost, emptyResult
        var canRetryFlightQuery: Bool {
            switch self {
            case .timeout, .connectionLost, .emptyResult: return true
            default: return false
            }
        }
        var errorDescription: String? { message }
        var message: String {
            switch self {
            case .response: return "携程服务没有返回有效的 HTTP 响应"
            case .origin: return "携程响应来源不匹配，已丢弃"
            case .size: return "携程响应超过 1 MiB，已丢弃"
            case .http(let code):
                if code == 401 || code == 403 { return "携程授权未通过，请核对授权码及使用权限" }
                if code == 429 { return "携程查询额度受限，请稍后重试" }
                if (300...399).contains(code) { return "携程请求发生重定向，已停止查询" }
                return "携程服务暂时无法完成查询，请稍后重试"
            case .timeout: return "携程查询超时，请稍后重试"
            case .network: return "无法连接携程服务，请检查网络"
            case .connectionLost: return "与携程的网络连接已中断"
            case .emptyResult: return "携程未返回可用的查询结果，请稍后重试"
            }
        }
        static func networkFailure(_ error: URLError) -> Self {
            switch error.code {
            case .timedOut: return .timeout
            case .networkConnectionLost: return .connectionLost
            default: return .network
            }
        }
    }

    static func validatedToken(_ value: String) throws -> String {
        guard (8...4096).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AgentError.message("请先保存有效的携程授权码")
        }
        return value
    }

    func request(query: String) throws -> URLRequest {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...4096).contains(clean.count) else {
            throw AgentError.message("携程查询内容需要 1 至 4096 个字符")
        }
        let token = try Self.validatedToken(apiKey)
        guard [Self.endpoint, Self.wendaoEndpoint].contains(apiEndpoint) else { throw AgentError.message("携程服务地址不受支持") }
        var request = URLRequest(url: apiEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The code occurs only in the JSON body, never a URL, header or diagnostic.
        let body: [String: Any] = apiEndpoint == Self.wendaoEndpoint ? ["token": token, "query": clean, "source": "sela"] : ["inputs": ["token": token, "query": clean]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let outgoingURL = request.url, [endpoint, wendaoEndpoint].contains(outgoingURL), request.httpMethod == "POST" else { throw TransportFailure.origin }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: CtripRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw TransportFailure.response }
            guard http.url == outgoingURL else { throw TransportFailure.origin }
            guard (200...299).contains(http.statusCode) else { throw TransportFailure.http(http.statusCode) }
            guard http.expectedContentLength <= Int64(responseLimit) else { throw TransportFailure.size }
            var data = Data()
            for try await byte in bytes {
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                guard data.count < responseLimit else { throw TransportFailure.size }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as TransportFailure { throw failure }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TransportFailure.networkFailure(error)
        } catch { throw TransportFailure.network }
    }

    func query(query: String) async throws -> String {
        do { return try await queryOnce(query: query) }
        catch let failure as TransportFailure { throw AgentError.message(failure.message) }
    }

    private func queryOnce(query: String) async throws -> String {
        let outgoing = try request(query: query)
        try Task.checkCancellation()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(outgoing)
            try Task.checkCancellation()
        } catch is CancellationError { throw CancellationError() }
        catch let failure as TransportFailure { throw failure }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TransportFailure.networkFailure(error)
        } catch { throw TransportFailure.network }
        guard response.url == apiEndpoint else { throw TransportFailure.origin }
        guard (200...299).contains(response.statusCode) else { throw TransportFailure.http(response.statusCode) }
        if apiEndpoint == Self.wendaoEndpoint,
           var envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any], envelope["result"] == nil {
            let payload = envelope["data"] as? [String: Any] ?? envelope
            if let text = (payload["answer"] ?? payload["content"] ?? payload["text"] ?? envelope["data"]) as? String {
                envelope["result"] = text
                return try Self.decode(JSONSerialization.data(withJSONObject: envelope), token: apiKey)
            }
        }
        return try Self.decode(data, token: apiKey)
    }

    // Queries are read-only. A lost connection, timeout, empty business response or
    // explicit provider quote failure shares one retry budget, with identical
    // constraints and fresh consent checks. Inventory, malformed/unsafe responses,
    // authentication failures and rate limits are never retried.
    func queryFlights(query: String, canRetry: () async -> Bool = { true }) async throws -> FlightResult {
        var firstReference: String?
        for attempt in 1...2 {
            do {
                let answer = try await queryOnce(query: query)
                let unavailable = Self.realtimeQuoteUnavailable(answer)
                if !unavailable || attempt == 2 {
                    return FlightResult(providerText: answer, attempts: attempt, realtimeUnavailable: unavailable)
                }
                firstReference = answer
            } catch is CancellationError { throw CancellationError() }
            catch let failure as TransportFailure {
                try Task.checkCancellation()
                guard failure.canRetryFlightQuery else { throw AgentError.message(failure.message) }
                if attempt == 2 {
                    if let firstReference {
                        return FlightResult(providerText: firstReference, attempts: 2,
                                            realtimeUnavailable: true, retryFailure: failure.message)
                    }
                    throw AgentError.message(failure.message + "（已自动重试一次）")
                }
            }
            try Task.checkCancellation()
            guard await canRetry() else { throw AgentError.message("携程连接已改变，请重新查询") }
            try Task.checkCancellation()
        }
        preconditionFailure("Flight query exceeded its bounded attempts")
    }

    static func realtimeQuoteUnavailable(_ text: String) -> Bool {
        // Inspect the provider's preamble, not one unavailable fare inside an
        // otherwise useful list of flights.
        let lead = String(text.components(separatedBy: "\n### ").first!.prefix(1800))
        let patterns = [
            #"暂无实时报价|无法(?:为您|为你)?(?:提供|获取|展示)实时报价|无法展示实时报价|(?:暂未|未成功|未能|没有|未)返回[^。！？\n，,；;]{0,100}(?:票价|报价|航班数据|航班号)"#,
            #"(?:官方机票|机票实时查询|机票查询系统|机票查询技能|航班查询接口).{0,60}(?:暂未返回|未成功返回|不可用|异常|失败)"#,
            #"(?i)(?:live|real[- ]?time)\s+(?:fares?|quotes?|prices?)\s+(?:are\s+|is\s+)?(?:unavailable|not available)|(?:flight|airfare)\s+(?:search|tool|api).{0,40}(?:unavailable|failed)"#
        ]
        return patterns.contains { lead.range(of: $0, options: .regularExpression) != nil }
    }

    static func decode(_ data: Data, token: String) throws -> String {
        guard data.count <= responseLimit else { throw AgentError.message(TransportFailure.size.message) }
        _ = try validatedToken(token)
        // Only documented business text is extracted. Error/debug envelopes never enter history.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any] else {
            throw AgentError.message("携程未返回有效的查询结果格式")
        }
        if let success = envelope["success"] as? NSNumber,
           CFGetTypeID(success) == CFBooleanGetTypeID(), !success.boolValue {
            throw AgentError.message("携程服务未能完成查询，请稍后重试")
        }
        if let code = envelope["code"] {
            let allowed: Bool
            if let number = code as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                allowed = number.doubleValue == 0 || number.doubleValue == 200
            } else if let text = code as? String {
                allowed = ["0", "200", "SUCCESS", "success", "OK", "ok"].contains(text)
            } else { allowed = false }
            guard allowed else { throw AgentError.message("携程服务未能完成查询，请稍后重试") }
        }
        if let error = envelope["error"], !(error is NSNull) {
            let allowed: Bool
            if let flag = error as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { allowed = !flag.boolValue }
            else if let text = error as? String { allowed = text.isEmpty }
            else if let details = error as? [String: Any] { allowed = details.isEmpty }
            else { allowed = false }
            guard allowed else { throw AgentError.message("携程服务未能完成查询，请稍后重试") }
        }
        let result: String?
        if let text = envelope["result"] as? String { result = text }
        else if let value = envelope["result"], !(value is NSNull) {
            guard let content = (value as? [String: Any])?["content"] as? String else {
                throw AgentError.message("携程未返回有效的查询结果格式")
            }
            result = content
        } else { result = nil }
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TransportFailure.emptyResult
        }
        // Fail closed if the provider echoes a code, including commonly escaped forms.
        // Preserve ordinary business text byte-for-byte; normalization is only for detection.
        if result.contains(token) || canonical(result).contains(canonical(token)) {
            throw AgentError.message("携程结果包含授权信息，已丢弃本次结果。请重新查询。")
        }
        if result.count > textLimit {
            return String(result.prefix(textLimit)) + "\n\n（结果较长，已截断至前 12000 个字符。）"
        }
        return result
    }

    private static func replacingMatches(_ text: String, pattern: String,
                                         transform: (String) -> String?) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var output = text
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: output), let valueRange = Range(match.range(at: 1), in: output),
                  let replacement = transform(String(output[valueRange])) else { continue }
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }

    private static func canonical(_ text: String) -> String {
        var value = text
        let entities = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "sol": "/",
                        "colon": ":", "equals": "=", "percnt": "%", "plus": "+", "num": "#",
                        "quest": "?", "commat": "@", "dollar": "$", "excl": "!", "lpar": "(",
                        "rpar": ")", "ast": "*", "comma": ",", "period": ".", "hyphen": "-",
                        "lowbar": "_", "bsol": "\\", "grave": "`", "vert": "|", "tilde": "~"]
        // Multiple passes cover nested URL/HTML/JSON escapes without changing displayed text.
        for _ in 0..<4 {
            let before = value
            value = replacingMatches(value, pattern: "%([0-9A-Fa-f]{2})") {
                UInt32($0, radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            }
            value = replacingMatches(value, pattern: "&#([0-9]{1,7});?") {
                UInt32($0).flatMap(UnicodeScalar.init).map(String.init)
            }
            value = replacingMatches(value, pattern: "&#[xX]([0-9A-Fa-f]{1,6});?") {
                UInt32($0, radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            }
            value = replacingMatches(value, pattern: "&([A-Za-z]+);") { entities[$0.lowercased()] }
            value = replacingMatches(value, pattern: #"\\u([0-9A-Fa-f]{4})"#) {
                UInt32($0, radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            }
            value = replacingMatches(value, pattern: #"\\x([0-9A-Fa-f]{2})"#) {
                UInt32($0, radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            }
            value = value.replacingOccurrences(of: #"\/"#, with: "/")
                .replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\\"#, with: "\\")
            if value == before { break }
        }
        return value
    }
}
