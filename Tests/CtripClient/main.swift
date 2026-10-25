import Foundation

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

actor CtripFlightSequence {
    var queries: [String] = []
    let replies: [String]
    let status: Int
    init(_ replies: [String], status: Int = 200) { self.replies = replies; self.status = status }
    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        queries.append((body["inputs"] as! [String: String])["query"]!)
        let text = replies[min(queries.count - 1, replies.count - 1)]
        return (try JSONSerialization.data(withJSONObject: ["result": text]),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct CtripClientChecks {
    static var checks = 0
    static let token = "rawsecret-M8!/?&=+"
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    static func fixture(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
    static func response(_ status: Int = 200, url: URL = CtripClient.endpoint) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
    static func failure(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Unexpected success") }
        catch {
            check(!error.localizedDescription.contains(token), "Error exposed the code")
            check(!error.localizedDescription.contains("envelope-secret"), "Error exposed a response envelope")
        }
    }
    static func asyncFailure(_ body: () async throws -> String) async {
        do { _ = try await body(); preconditionFailure("Unexpected success") }
        catch {
            check(!error.localizedDescription.contains(token), "Transport error exposed the code")
            check(!error.localizedDescription.contains("envelope-secret"), "Transport error exposed its payload")
        }
    }
    static func main() async throws {
        let unavailable = "携程机票查询接口未返回2026年10月29日上海到北京的实际可售票价数据，无法生成含实际票价的航班卡片。以下信息来源于网络。"
        let quoted = "### CA1234\n起降时间：18:30 → 21:00\n票价：600元（不含税）\n行李、退改及实际税费未返回，待核实。"
        for text in [unavailable, "携程机票实时查询接口暂未返回该日期的航班数据。", "官方机票查询技能暂未返回该日期数据。", "官方机票接口暂未返回含票价、税费和库存的完整产品数据，无法展示实时报价。", "Live fares are unavailable.", "Flight search API failed."] {
            check(CtripClient.realtimeQuoteUnavailable(text), "Provider quote failure was missed")
        }
        for text in [quoted, "本次未检索到符合直飞条件的航班。", "没有符合预算的航班。", "未返回税费，当前票价600元。", "行李额度未返回，票价600元。", "携程查询结果如下。\n### CA1234\n票价600元\n### CA1235\n暂无实时报价"] {
            check(!CtripClient.realtimeQuoteUnavailable(text), "Inventory or partial-field absence was retried as a provider failure")
        }
        let sameQuery = "查询2026年10月29日上海到北京，18点以后、直飞、1位成人经济舱，预算900元。"
        for (replies, attempts, unavailableExpected) in [([quoted], 1, false), ([unavailable, quoted], 2, false), ([unavailable, unavailable], 2, true)] {
            let sequence = CtripFlightSequence(replies)
            let value = try await CtripClient(apiKey: token, transport: { try await sequence.load($0) }).queryFlights(query: sameQuery)
            let queries = await sequence.queries
            check(value.attempts == attempts && value.realtimeUnavailable == unavailableExpected, "Flight retry state incorrect")
            check(queries == Array(repeating: sameQuery, count: attempts), "Retry changed constraints or exceeded its bound")
            check(unavailableExpected ? value.displayText.contains("已自动重试一次") && value.displayText.contains("时刻参考尚未核价") && value.providerText == unavailable : value.displayText == quoted, "Degraded display lost its status or changed a usable response")
        }
        let revoked = CtripFlightSequence([unavailable, quoted])
        await asyncFailure { try await CtripClient(apiKey: token, transport: { try await revoked.load($0) }).queryFlights(query: sameQuery, canRetry: { false }).displayText }
        let revokedCount = await revoked.queries.count
        check(revokedCount == 1, "Revoked consent allowed a retry")
        let cancelled = CtripFlightSequence([unavailable, quoted])
        let cancelledTask = Task {
            try await CtripClient(apiKey: token, transport: { try await cancelled.load($0) }).queryFlights(query: sameQuery, canRetry: {
                withUnsafeCurrentTask { $0?.cancel() }; return true
            })
        }
        do { _ = try await cancelledTask.value; preconditionFailure("Cancelled flight query retried") }
        catch is CancellationError { }
        let cancelledCount = await cancelled.queries.count
        check(cancelledCount == 1, "Cancellation did not prevent a retry")
        for code in [401, 403, 429, 500] {
            let sequence = CtripFlightSequence([unavailable], status: code)
            await asyncFailure { try await CtripClient(apiKey: token, transport: { try await sequence.load($0) }).queryFlights(query: sameQuery).displayText }
            let count = await sequence.queries.count
            check(count == 1, "HTTP failure was automatically repeated")
        }
        let client = CtripClient(apiKey: token)
        let request = try client.request(query: "  上海到北京明天的机票\n")
        check(request.url == CtripClient.endpoint && request.httpMethod == "POST", "Wrong official protocol")
        check(request.url?.query == nil && !(request.url?.absoluteString.contains(token) ?? true), "Code entered the URL")
        check(!(request.allHTTPHeaderFields ?? [:]).values.contains(where: { $0.contains(token) }), "Code entered headers")
        check(request.httpShouldHandleCookies == false, "Cookies enabled")
        check(request.timeoutInterval == 45 && request.cachePolicy == .reloadIgnoringLocalCacheData, "Unbounded or cached request")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let inputs = body["inputs"] as! [String: String]
        check(body.count == 1 && inputs == ["token": token, "query": "上海到北京明天的机票"], "Wrong request body")
        for query in ["", " \n\t", String(repeating: "行", count: 4097)] { failure { _ = try client.request(query: query) } }
        check(try client.request(query: String(repeating: "行", count: 4096)).httpBody != nil, "Valid query rejected")
        for key in ["short", "with space", "授权码12345", "1234567\n", String(repeating: "k", count: 4097)] {
            failure { _ = try CtripClient(apiKey: key).request(query: "酒店") }
        }
        check(try CtripClient(apiKey: "12345678").request(query: "a").httpBody != nil, "Minimum key rejected")
        check(try CtripClient(apiKey: String(repeating: "k", count: 4096)).request(query: "a").httpBody != nil, "Maximum key rejected")

        let business = "  上海 → 北京\n¥680；余票和价格以携程实时页面为准。\n"
        check(try CtripClient.decode(fixture(["result": business, "state": "ignored", "token": token]), token: token) == business,
              "Business result changed or envelope returned")
        check(try CtripClient.decode(fixture(["result": ["content": business, "debug": token]]), token: token) == business,
              "Nested business result changed or debug returned")
        for extra: [String: Any] in [["error": NSNull()], ["error": false], ["error": ""], ["error": [String: Any]()],
                                    ["success": true], ["code": 0], ["code": 200], ["code": "0"], ["code": "200"],
                                    ["code": "SUCCESS"], ["code": "success"], ["code": "OK"], ["code": "ok"]] {
            check(try CtripClient.decode(fixture(extra.merging(["result": business]) { _, new in new }), token: token) == business,
                  "Non-error envelope rejected")
        }
        for extra: [String: Any] in [["success": false], ["error": "envelope-secret " + token], ["error": true],
                                    ["error": ["message": "envelope-secret " + token]], ["error": [Any]()], ["error": 0],
                                    ["code": 403], ["code": "403"], ["code": "envelope-secret " + token],
                                    ["code": NSNull()], ["code": false], ["code": true]] {
            failure {
                _ = try CtripClient.decode(fixture(extra.merging(["result": business]) { _, new in new }), token: token)
            }
        }
        for bad: Any in [["error": "envelope-secret " + token], ["result": ["error": "envelope-secret"]],
                         ["result": ["content": ["text": "nested"]]], ["result": " \n"], ["result": 3], ["result": NSNull()], []] {
            failure { _ = try CtripClient.decode(fixture(bad), token: token) }
        }
        failure { _ = try CtripClient.decode(Data("envelope-secret".utf8), token: token) }
        failure { _ = try CtripClient.decode(Data(repeating: 65, count: CtripClient.responseLimit + 1), token: token) }
        let exactPayload = Data(("{\"result\":\"ok\"}" + String(repeating: " ", count: CtripClient.responseLimit - 15)).utf8)
        check(exactPayload.count == CtripClient.responseLimit, "Boundary fixture incorrect")
        check(try CtripClient.decode(exactPayload, token: token) == "ok", "1 MiB response rejected")
        let long = String(repeating: "飞", count: 12001)
        let truncated = try CtripClient.decode(fixture(["result": long]), token: token)
        check(truncated.hasPrefix(String(long.prefix(12000))) && truncated.contains("已截断"), "Truncation was not explicit")

        let percent = token.utf8.map { String(format: "%%%02x", $0) }.joined()
        let unicode = token.utf8.map { String(format: "\\u%04x", $0) }.joined()
        let hexadecimal = token.utf8.map { String(format: "\\x%02x", $0) }.joined()
        let htmlDecimal = token.utf8.map { "&#\($0);" }.joined()
        let htmlHex = token.utf8.map { String(format: "&#x%x;", $0) }.joined()
        let escapedJSON = token.replacingOccurrences(of: "/", with: "\\/")
        let nestedPercent = percent.replacingOccurrences(of: "%", with: "%25")
        for echoed in [token, percent, unicode, hexadecimal, htmlDecimal, htmlHex, escapedJSON, nestedPercent,
                       token.replacingOccurrences(of: "&", with: "&amp;")] {
            do {
                _ = try CtripClient.decode(fixture(["result": "example \(echoed) trailing"]), token: token)
                preconditionFailure("Reflected authorization code was treated as query success")
            } catch {
                check(!error.localizedDescription.contains(token) && !error.localizedDescription.contains(echoed), "Escaped code entered error text")
                check(error.localizedDescription.contains("已丢弃"), "Reflected code did not produce a fixed safe error")
            }
        }
        let exact = try await CtripClient(apiKey: token, transport: { outgoing in
            check(outgoing.url == CtripClient.endpoint, "Transport called a different origin")
            return (try fixture(["result": business]), response())
        }).query(query: "航班")
        check(exact == business, "Transport result changed")
        for status in [301, 302, 307, 308, 401, 403, 429, 500] {
            await asyncFailure { try await CtripClient(apiKey: token, transport: { _ in
                (try fixture(["result": "envelope-secret " + token]), response(status))
            }).query(query: "航班") }
        }
        await asyncFailure { try await CtripClient(apiKey: token, transport: { _ in
            (try fixture(["result": "envelope-secret"]), response(url: URL(string: "https://example.invalid/")!))
        }).query(query: "航班") }
        await asyncFailure { try await CtripClient(apiKey: token, transport: { _ in
            throw AgentError.message("envelope-secret " + token)
        }).query(query: "航班") }
        await asyncFailure { try await CtripClient(apiKey: token, transport: { _ in throw URLError(.timedOut) }).query(query: "航班") }
        do {
            _ = try await CtripClient(apiKey: token, transport: { _ in throw CancellationError() }).query(query: "航班")
            preconditionFailure("Cancellation was swallowed")
        } catch is CancellationError { checks += 1 }
        catch { preconditionFailure("Cancellation changed type") }

        // Exercise the real redirect decision without resuming a network task.
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: CtripClient.endpoint)
        var redirectedRequest: URLRequest? = request
        CtripRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response(307),
                                        newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) {
            redirectedRequest = $0
        }
        check(redirectedRequest == nil, "Redirect was followed")
        task.cancel(); session.invalidateAndCancel()

        let suiteName = "CtripClientChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        check(CtripStore.isEnabled(defaults: defaults) == false, "Ctrip enabled by default")
        CtripStore.setEnabled(true, defaults: defaults)
        check(CtripStore.isEnabled(defaults: defaults), "Consent setting not retained")
        CtripStore.setEnabled(false, defaults: defaults)
        check(!CtripStore.isEnabled(defaults: defaults), "Consent setting not revocable")
        CtripStore.setEnabled(true, defaults: defaults)
        var persistedToken: String?
        try CtripStore.saveAPIKey(token, defaults: defaults) { persistedToken = $0 }
        check(persistedToken == token, "Replacement credential was not passed to the writer")
        check(!CtripStore.isEnabled(defaults: defaults), "Replacement credential inherited previous consent")
        CtripStore.setEnabled(true, defaults: defaults)
        failure {
            try CtripStore.saveAPIKey(token, defaults: defaults) { _ in throw AgentError.message("fixture-write-failed") }
        }
        check(CtripStore.isEnabled(defaults: defaults), "Failed replacement changed existing consent")

        let tool = try SystemToolRequest.decode(#"{"operation":"ctrip_query","query":"明天上海到北京的机票"}"#)
        check(tool.operation == .ctrip_query && tool.query == "明天上海到北京的机票", "Travel tool query was not accepted")
        for query in ["", " \n", String(repeating: "行", count: 4097)] {
            failure { try SystemToolRequest(operation: .ctrip_query, query: query).validate() }
        }
        for field in ["title", "notes", "start", "end", "content", "artifact_ref"] {
            failure {
                _ = try SystemToolRequest.decode(String(data: fixture(["operation": "ctrip_query", "query": "酒店", field: "unexpected"]), encoding: .utf8))
            }
        }
        check(!tool.operation.writes, "Travel query was marked as a write")
        check(tool.confirmationExplanation.contains("携程") && tool.confirmationExplanation.contains("当前 AI") &&
              !tool.confirmationExplanation.contains("已下单"), "Travel consent omitted the recipient or implied a booking")
        print("\(checks) Ctrip protocol, privacy and consent checks passed. Offline fixtures only; no credential reads or live requests.")
    }
}
