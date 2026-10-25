import Foundation

// The only boundary stub: this fixed-error type satisfies production service
// errors without linking unrelated UI/model settings. ResolvedLink, URL policy,
// redirect delegate and source validators are their actual production types.
enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

@main struct XiaohongshuLinkChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        func rejects(_ body: () throws -> Void, _ message: String) {
            var failed = false; do { try body() } catch { failed = true }; expect(failed, message)
        }
        func url(_ raw: String) -> URL { URL(string: raw)! }

        let trustedHosts = ["xhslink.com", "www.xhslink.com", "xhslink.cn", "xiaohongshu.com", "www.xiaohongshu.com"]
        for host in trustedHosts {
            expect(XiaohongshuLinkPolicy.allowed(url("https://\(host)/fixture")), "Exact HTTPS platform host is permitted: \(host)")
            expect(XiaohongshuLinkPolicy.allowed(url("https://\(host):443/fixture?xsec_token=fixture")), "The HTTPS default explicit port is supported by the resolver: \(host)")
            expect(XiaohongshuLinkPolicy.allowed(url("https://\(host.uppercased())/fixture")), "Hostname case is normalized without widening the whitelist")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://\(host).attacker.invalid/fixture")), "Suffix spoof does not select a trusted host")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://\(host):444/fixture")), "Non-default HTTPS port is rejected")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://\(host):80/fixture")), "HTTPS URL cannot select an HTTP port")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://user@\(host)/fixture")), "Userinfo is rejected even when the final host is trusted")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://user:secret@\(host)/fixture")), "Password-bearing authority is rejected")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://@\(host)/fixture")), "Empty-but-present userinfo is rejected")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://\(host)/fixture#details")), "Fragments are not silently ignored")
            expect(!XiaohongshuLinkPolicy.allowed(url("https://\(host)/fixture#")), "Empty-but-present fragment is rejected")
            expect(!XiaohongshuLinkPolicy.allowed(url("ftp://\(host)/fixture"), initial: true), "Trusted host cannot make a non-web scheme permissible")
        }
        for host in ["xhslink.com", "www.xhslink.com"] {
            expect(XiaohongshuLinkPolicy.allowed(url("http://\(host)/fixture"), initial: true), "HTTP short URL is allowed only as an initial upgrade candidate")
            expect(XiaohongshuLinkPolicy.allowed(url("http://\(host):80/fixture"), initial: true), "Initial short URL may explicitly name port 80")
            expect(!XiaohongshuLinkPolicy.allowed(url("http://\(host)/fixture")), "HTTP is forbidden as any redirect/final target")
            expect(!XiaohongshuLinkPolicy.allowed(url("http://\(host):443/fixture"), initial: true), "Initial HTTP cannot use the HTTPS port")
        }
        for raw in ["http://xiaohongshu.com/explore/fixture", "http://www.xiaohongshu.com/explore/fixture",
                    "http://xhslink.cn/o/fixture", "https://www.xhslink.cn/o/fixture", "https://api.xhslink.cn/o/fixture",
                    "https://m.xiaohongshu.com/fixture", "https://api.xhslink.com/fixture", "https://xhslink.com./fixture",
                    "https://127.0.0.1/fixture", "https://localhost/fixture", "file://xhslink.com/fixture", "/relative/path",
                    "https://xhslink.com@attacker.invalid/fixture", "https://attacker.invalid@xhslink.com/fixture"] {
            expect(!XiaohongshuLinkPolicy.allowed(url(raw), initial: true), "Unsupported scheme/authority cannot pass the initial policy: \(raw)")
        }

        // Real Foundation request/response/session objects call the production
        // URLSessionTaskDelegate method. Tasks are CREATED BUT NEVER RESUMED;
        // there are no actual outbound requests in this suite.
        func exercise(_ initial: URL, _ body: (XiaohongshuRedirectGuard, URLSession, URLSessionTask) throws -> Void) rethrows {
            let guardDelegate = XiaohongshuRedirectGuard(url: initial)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
            let task = session.dataTask(with: URLRequest(url: initial))
            defer { task.cancel(); session.invalidateAndCancel() }
            expect(task.state == .suspended, "Delegate test task stays suspended and never starts network traffic")
            try body(guardDelegate, session, task)
        }
        func redirect(_ delegate: XiaohongshuRedirectGuard, _ session: URLSession, _ task: URLSessionTask,
                      from: URL, to: URL?, status: Int = 302, method: String = "HEAD") -> URLRequest? {
            let response = HTTPURLResponse(url: from, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": to?.absoluteString ?? ""])!
            var request = URLRequest(url: to ?? from); request.url = to; request.httpMethod = method
            var accepted: URLRequest?, callbacks = 0
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { value in
                callbacks += 1; accepted = value
            }
            expect(callbacks == 1, "Production redirect delegate completes exactly once")
            expect(task.state == .suspended, "Calling the actual delegate does not start the URLSession task")
            return accepted
        }
        let initial = url("https://xhslink.com/fixture-start")
        let final = url("https://www.xiaohongshu.com/explore/0123456789abcdef01234567")
        let observedCN = url("https://xhslink.cn/o/fixture-mac-copy")
        let cnRequest = try XiaohongshuLinkResolver.request(for: observedCN)
        let legacyRequest = try XiaohongshuLinkResolver.request(for: initial)
        expect(cnRequest.httpMethod == "GET" && cnRequest.url == observedCN && cnRequest.timeoutInterval == 15,
            "The exact CN host uses GET after the real HEAD-404/GET-302 regression")
        expect(cnRequest.httpBody == nil && cnRequest.allHTTPHeaderFields?.keys.contains(where: { $0.lowercased() == "authorization" }) != true,
            "Public source resolution does not attach content or authorization")
        expect(legacyRequest.httpMethod == "HEAD", "Existing share hosts retain the original HEAD behavior")
        rejects({ _ = try XiaohongshuLinkResolver.request(for: url("https://attacker.invalid/o/fixture")) },
            "Request construction cannot bypass the original exact-host policy")
        expect(XiaohongshuSource.copiedURL(in: "公开笔记 https://xhslink.cn/o/fixture-mac-copy 打开小红书") == observedCN,
            "Share text with the exact HTTPS host observed in Mac 9.49 remains usable by the source parser")
        expect(XiaohongshuSource.directURL(observedCN.absoluteString) == nil, "A copied CN short link is never promoted to a canonical note ID")
        for raw in ["http://xhslink.cn/o/fixture", "https://xhslink.cn.attacker.invalid/o/fixture", "https://user@xhslink.cn/o/fixture",
                    "https://xhslink.cn:444/o/fixture", "https://api.xhslink.cn/o/fixture"] {
            expect(XiaohongshuSource.copiedURL(in: raw) == nil, "CN share parsing retains exact scheme, authority and port boundaries")
        }
        try exercise(observedCN) { delegate, session, task in
            let accepted = redirect(delegate, session, task, from: observedCN, to: final, method: "GET")
            expect(accepted?.url == final && accepted?.httpMethod == "GET", "Observed CN host preserves GET while redirecting to the exact canonical platform host")
            let result = try delegate.result(final: final)
            try XiaohongshuSource.validateResolution(result, original: observedCN)
            expect(result.redirectChain == [observedCN.absoluteString, final.absoluteString], "CN source binding retains both actual hop values")
        }
        try exercise(initial) { delegate, _, _ in
            let result = try delegate.result(final: initial)
            expect(result.redirectChain == [initial.absoluteString] && result.finalURL == initial.absoluteString,
                "A zero-redirect HTTPS result retains the exact initial observation")
        }
        for status in [301, 302, 303, 307, 308] {
            try exercise(initial) { delegate, session, task in
                let accepted = redirect(delegate, session, task, from: initial, to: final, status: status)
                expect(accepted?.url == final && accepted?.httpMethod == "HEAD", "Supported redirect status preserves the actual permitted request")
                let result = try delegate.result(final: final)
                expect(result.redirectChain == [initial.absoluteString, final.absoluteString], "Cross-host hop inside the exact platform whitelist is recorded, not dropped")
                try XiaohongshuSource.validateResolution(result, original: initial)
                expect(true, "Actual resolved output is usable by the production source validator")
            }
        }
        let httpInitial = url("http://xhslink.com/fixture-initial-http")
        try exercise(httpInitial) { delegate, session, task in
            let upgrade = url("https://xhslink.com/fixture-upgrade")
            expect(redirect(delegate, session, task, from: httpInitial, to: upgrade) != nil, "An authorized initial HTTP short URL can upgrade to HTTPS")
            expect(redirect(delegate, session, task, from: upgrade, to: final) != nil, "An upgraded URL can resolve to the trusted canonical note host")
            expect(try delegate.result(final: final).redirectChain == [httpInitial.absoluteString, upgrade.absoluteString, final.absoluteString], "HTTP upgrade and final source are both preserved in the real chain")
        }
        exercise(httpInitial) { delegate, _, _ in
            rejects({ _ = try delegate.result(final: httpInitial) }, "HTTP initial allowance never permits an HTTP final result")
        }
        for forbidden in ["https://attacker.invalid/note", "http://www.xiaohongshu.com/explore/note", "http://xhslink.com/downgrade",
                          "https://xhslink.com:444/port", "https://user@www.xiaohongshu.com/note",
                          "https://www.xiaohongshu.com/note#fragment", "file://xhslink.com/local"] {
            exercise(initial) { delegate, session, task in
                expect(redirect(delegate, session, task, from: initial, to: url(forbidden)) == nil,
                    "The production delegate refuses the unsafe redirect instead of forwarding it")
                rejects({ _ = try delegate.result(final: initial) }, "A rejected redirect invalidates the entire final result")
            }
        }
        exercise(initial) { delegate, session, task in
            expect(redirect(delegate, session, task, from: initial, to: nil) == nil, "A redirect request with no URL is explicitly rejected")
            rejects({ _ = try delegate.result(final: initial) }, "A nil-target redirect cannot fall back to a successful initial result")
        }
        exercise(initial) { delegate, session, task in
            expect(redirect(delegate, session, task, from: initial, to: initial) == nil, "Immediate redirect loop to the initial URL is rejected")
            rejects({ _ = try delegate.result(final: initial) }, "Loop detection persists into final-result validation")
        }
        exercise(initial) { delegate, session, task in
            let middle = url("https://xhslink.com/fixture-middle")
            expect(redirect(delegate, session, task, from: initial, to: middle) != nil, "First unique hop is permitted")
            expect(redirect(delegate, session, task, from: middle, to: initial) == nil, "A later hop cannot return to any previously visited URL")
            rejects({ _ = try delegate.result(final: middle) }, "A loop does not leave its prior intermediate URL as a usable final result")
        }
        exercise(initial) { delegate, session, task in
            expect(redirect(delegate, session, task, from: initial, to: final) != nil, "Final mismatch test first records an actual accepted redirect")
            rejects({ _ = try delegate.result(final: initial) }, "An earlier URL in the chain is not the accepted final URL")
            rejects({ _ = try delegate.result(final: url("https://www.xiaohongshu.com/explore/abcdefabcdefabcdefabcdef")) }, "Another whitelisted URL cannot substitute for the observed final hop")
            rejects({ _ = try delegate.result(final: url("https://attacker.invalid/final")) }, "An untrusted final response cannot become source evidence")
        }
        try exercise(initial) { delegate, session, task in
            var current = initial
            for hop in 1...5 {
                let next = hop == 5 ? final : url("https://xhslink.com/fixture-hop-\(hop)")
                expect(redirect(delegate, session, task, from: current, to: next) != nil, "The production delegate accepts unique permitted redirect \(hop) of five")
                current = next
            }
            let result = try delegate.result(final: final)
            expect(result.redirectChain.count == 6, "Five actual redirects mean six observed URLs including the original")
            try XiaohongshuSource.validateResolution(result, original: initial)
            expect(true, "The maximum accepted real delegate chain also passes the production persisted source validator")
        }
        exercise(initial) { delegate, session, task in
            var current = initial
            for hop in 1...5 {
                let next = url("https://xhslink.com/fixture-limit-\(hop)")
                _ = redirect(delegate, session, task, from: current, to: next); current = next
            }
            expect(redirect(delegate, session, task, from: current, to: final) == nil, "Redirect six is rejected before dispatch, keeping at most six URLs including the original")
            rejects({ _ = try delegate.result(final: current) }, "Exceeding the redirect budget prevents a partial chain from masquerading as success")
        }
        exercise(initial) { delegate, session, task in
            _ = redirect(delegate, session, task, from: initial, to: url("https://attacker.invalid/rejected"))
            _ = redirect(delegate, session, task, from: initial, to: final)
            rejects({ _ = try delegate.result(final: final) }, "A rejected chain cannot recover by later presenting a permitted final URL")
        }
        // Public resolver rejection executes before it creates any session.
        for forbidden in ["https://attacker.invalid/fixture", "https://user@xhslink.com/fixture", "https://xhslink.com/fixture#part"] {
            var rejected = false
            do { _ = try await XiaohongshuLinkResolver.resolve(url(forbidden)) } catch { rejected = true }
            expect(rejected, "Public production resolver rejects an unauthorized initial URL before any network work")
        }
        print("XiaohongshuLinks: \(checks) checks passed (production URL policy + real URLSession redirect delegate callbacks; all tasks suspended, no network)")
    }
}
