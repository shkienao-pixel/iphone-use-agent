import Combine
import UIKit
import WebKit

/// Owns the on-demand iPhone browser and in-process MCP host. The browser is
/// released after each read; its isolated website store retains the user's login.
@MainActor final class XiaohongshuLocalMCPHost: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = XiaohongshuLocalMCPHost()
    @Published private(set) var webView: WKWebView?
    @Published private(set) var presented = false
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var accountName = ""
    private let websiteStore: WKWebsiteDataStore
    private let pageLoader: ((WKWebView, URL) -> Void)?
    private let connection: XiaohongshuMCPStore
    private var generation = UUID()
    private var accountID: String?
    private var navigationFailed = false
    private lazy var mcp = XiaohongshuLocalMCP { [weak self] tool, args in
        guard let self else { throw CancellationError() }
        return try await self.execute(tool, arguments: args)
    }
    private let home = URL(string: "https://www.xiaohongshu.com/explore")!

    init(websiteStore: WKWebsiteDataStore? = nil, connection: XiaohongshuMCPStore? = nil,
         pageLoader: ((WKWebView, URL) -> Void)? = nil) {
        self.websiteStore = websiteStore ?? WKWebsiteDataStore(forIdentifier: UUID(uuidString: "92E74D3B-93B5-467B-9D32-AD6AF3E45BF1")!)
        self.connection = connection ?? .shared
        self.pageLoader = pageLoader
        super.init()
    }

    func install() {
        connection.installLocal(call: { [weak self] tool, args in
            guard let self else { throw XHSReadError.disconnected }
            return try await self.mcp.call(tool, arguments: args)
        }, stop: { [weak self] in self?.stop() })
    }

    func openLogin() {
        guard !busy, UIApplication.shared.applicationState != .background else { return }
        stop(); connection.invalidateLocalSession(); accountID = nil; accountName = ""
        let web = browser()
        message = "请在小红书网页登录自己的账号，完成后点右上角确认登录。"
        presented = true; load(web, url: home)
    }

    func stop() {
        generation = UUID(); webView?.stopLoading(); webView?.navigationDelegate = nil
        webView = nil; presented = false; busy = false
    }

    func sceneActive(_ active: Bool) {
        if !active && (webView != nil || busy) {
            stop(); message = "本机网页任务已暂停，请回到 Sela 后重试。"
        }
    }

    func clearLogin() async {
        guard !busy else { return }
        stop(); connection.invalidateLocalSession(); accountID = nil; accountName = ""; busy = true
        await websiteStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        busy = false; message = "已清除 Sela 内的小红书网页登录。"
    }

    private func browser() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = false
        webView = web
        return web
    }

    private func load(_ web: WKWebView, url: URL) {
        navigationFailed = false
        if let pageLoader { pageLoader(web, url) }
        else { web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)) }
    }

    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operation == generation, UIApplication.shared.applicationState != .background else { throw CancellationError() }
        guard !navigationFailed else { throw AgentError.message("小红书网页未能打开，请在 Sela 内检查网页或完成网站验证。") }
    }

    private func navigate(_ url: URL, operation: UUID) async throws {
        try check(operation)
        let web = browser()
        load(web, url: url)
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(35))
        while clock.now < deadline {
            try check(operation)
            if !web.isLoading, let actual = web.url,
               actual.scheme == "https", actual.host == "www.xiaohongshu.com", actual.path == url.path {
                let expectedKeyword = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "keyword" }?.value
                let keyword = URLComponents(url: actual, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "keyword" }?.value
                if keyword == expectedKeyword {
                    try await Task.sleep(for: .milliseconds(650)); try check(operation); return
                }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw AgentError.message("小红书网页加载超时，请检查当前页面；本次请求未完成。")
    }

    private func snapshot(_ action: String, noteID: String = "", operation: UUID) async throws -> [String: Any] {
        try check(operation)
        guard let webView, let url = Bundle.main.url(forResource: "XiaohongshuLocalReader", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { throw XHSReadError.invalidResponse }
        let value: Any
        do {
            value = try await webView.callAsyncJavaScript(script + "\nreturn JSON.stringify(SelaXHSReader.snapshot(action, noteID));",
                arguments: ["action": action, "noteID": noteID], in: nil, contentWorld: .page)
        } catch { try check(operation); throw AgentError.message("当前小红书网页暂不能读取，请检查登录或网站验证。") }
        try check(operation)
        guard let raw = value as? String, raw.utf8.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw XHSReadError.invalidResponse }
        return object
    }

    private func readPage(_ action: String, noteID: String = "", operation: UUID) async throws -> [String: Any] {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(12))
        var previousEmpty = false
        while clock.now < deadline {
            let object = try await snapshot(action, noteID: noteID, operation: operation)
            if object["error"] as? String == "login" { throw AgentError.message("小红书网页尚未确认登录，请先登录自己的账号。") }
            if object["payload"] is [String: Any] {
                let payload = object["payload"] as? [String: Any]
                let emptySearch = action == "search" && (payload?["feeds"] as? [Any])?.isEmpty == true
                if !emptySearch || previousEmpty { return object }
                previousEmpty = true
            }
            try await Task.sleep(for: .milliseconds(600))
        }
        throw AgentError.message("当前网页未提供可核验的笔记数据。可查看网页完成验证；手机适配仍在验证中。")
    }

    private func identity(_ object: [String: Any]) -> (String, String)? {
        guard let info = object["account"] as? [String: Any], let id = info["id"] as? String,
              id.range(of: "^[0-9a-fA-F]{24}$", options: .regularExpression) != nil else { return nil }
        return (id, String((info["name"] as? String ?? "").prefix(100)))
    }

    private func requireAccount(_ object: [String: Any]) throws {
        guard let id = identity(object)?.0, let accountID, id == accountID else {
            connection.invalidateLocalSession(); self.accountID = nil; accountName = ""
            throw AgentError.message("本机网页登录的账号已改变或尚未登录，请重新确认自己的账号。")
        }
    }

    private func execute(_ tool: XiaohongshuMCPClient.Tool, arguments: [String: Any]) async throws -> [String: Any] {
        guard !busy, UIApplication.shared.applicationState != .background else { throw AgentError.message("请在 Sela 前台运行手机本地小红书任务。") }
        busy = true; generation = UUID(); let operation = generation
        var keepOpen = false
        presented = true; message = tool == .status ? "正在检查本机网页登录…" : "手机正在读取小红书网页…"
        defer {
            if generation == operation {
                busy = false
                if !keepOpen { webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil; presented = false }
            }
        }
        do {
            if tool == .status {
                // Reuse a manually opened login page so confirming login never
                // destroys the SMS/QR interaction by navigating elsewhere.
                if webView?.url?.host != "www.xiaohongshu.com" { try await navigate(home, operation: operation) }
                let object = try await snapshot("status", operation: operation)
                if let (id, name) = identity(object) {
                    accountID = id; accountName = name; message = "本机网页登录已确认。"
                    return ["content": [["type": "text", "text": "✅ 已登录\n"]]]
                }
                accountID = nil; accountName = ""; keepOpen = true
                message = "请在此网页完成登录，再点右上角确认登录。"
                return ["content": [["type": "text", "text": "❌ 未登录"]]]
            }
            guard tool == .search || tool == .detail else { throw XHSReadError.invalidQuery }
            try await navigate(home, operation: operation)
            try requireAccount(try await snapshot("status", operation: operation))
            let target: URL
            if tool == .search {
                var components = URLComponents(string: "https://www.xiaohongshu.com/search_result")!
                components.queryItems = [.init(name: "keyword", value: arguments["keyword"] as? String), .init(name: "source", value: "web_explore_feed")]
                guard let url = components.url else { throw XHSReadError.invalidQuery }; target = url
            } else {
                guard let id = arguments["feed_id"] as? String, let ref = arguments["xsec_token"] as? String else { throw XHSReadError.invalidQuery }
                var components = URLComponents(string: "https://www.xiaohongshu.com/explore/" + id)!
                components.queryItems = [.init(name: "xsec_token", value: ref), .init(name: "xsec_source", value: "pc_search")]
                guard let url = components.url else { throw XHSReadError.invalidQuery }; target = url
            }
            try await navigate(target, operation: operation)
            let action = tool == .search ? "search" : "detail", id = arguments["feed_id"] as? String ?? ""
            var object = try await readPage(action, noteID: id, operation: operation)
            try requireAccount(object)
            if tool == .detail, arguments["load_all_comments"] as? Bool == true, let webView {
                // Bounded scroll only. No posting, liking, arbitrary clicks or
                // direct/private API requests. Explicitly partial comment scope.
                for _ in 0..<3 {
                    try check(operation)
                    _ = try await webView.callAsyncJavaScript("const c = document.querySelector('.note-scroller'); if (c) c.scrollBy(0, 600); else window.scrollBy(0, 600); return true;", arguments: [:], in: nil, contentWorld: .page)
                    try await Task.sleep(for: .milliseconds(700))
                }
                object = try await readPage(action, noteID: id, operation: operation); try requireAccount(object)
            }
            guard let payload = object["payload"] as? [String: Any] else { throw XHSReadError.invalidResponse }
            message = "本机网页读取完成，结果已返回对话。"
            return ["structuredContent": payload]
        } catch {
            if !(error is CancellationError), generation == operation {
                keepOpen = true
                message = (error as? AgentError)?.localizedDescription ?? "本机网页读取未完成，请检查当前网页。"
            }
            throw error
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https", url.host == "www.xiaohongshu.com",
              navigationAction.targetFrame != nil else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { navigationFailed = true }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { navigationFailed = true }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { navigationFailed = true }
}
