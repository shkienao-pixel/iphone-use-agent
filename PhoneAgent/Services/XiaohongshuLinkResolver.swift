import Foundation

/// Resolves only the public platform's share links. No cookies, credentials or
/// API keys are attached; redirects cannot switch to an arbitrary host.
enum XiaohongshuLinkPolicy {
    static func allowed(_ url: URL, initial: Bool = false) -> Bool {
        guard let parts=URLComponents(url:url,resolvingAgainstBaseURL:false), let host=parts.host?.lowercased(),
              parts.user==nil,parts.password==nil,parts.fragment==nil,
              ["xhslink.com","www.xhslink.com","xhslink.cn","xiaohongshu.com","www.xiaohongshu.com"].contains(host) else { return false }
        if parts.scheme=="https" {return parts.port==nil || parts.port==443}
        return initial && parts.scheme=="http" && ["xhslink.com","www.xhslink.com"].contains(host) && (parts.port==nil || parts.port==80)
    }
}
final class XiaohongshuRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock=NSLock()
    private var chain:[String]
    private var rejected=false
    init(url:URL) {chain=[url.absoluteString]}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
        lock.lock()
        guard let url=request.url,XiaohongshuLinkPolicy.allowed(url),chain.count<6,!chain.contains(url.absoluteString) else {
            rejected=true;lock.unlock();completionHandler(nil);return
        }
        chain.append(url.absoluteString);lock.unlock();completionHandler(request)
    }
    func result(final:URL) throws -> XiaohongshuResolvedLink {
        lock.lock();defer{lock.unlock()}
        guard !rejected,XiaohongshuLinkPolicy.allowed(final),chain.last==final.absoluteString else {
            throw AgentError.message("小红书短链发生不受信跳转或超过次数，未绑定来源")
        }
        return .init(redirectChain:chain,finalURL:final.absoluteString)
    }
}
@MainActor enum XiaohongshuLinkResolver {
    static func request(for url:URL) throws -> URLRequest {
        guard XiaohongshuLinkPolicy.allowed(url,initial:true) else {throw AgentError.message("只允许小红书真实分享域名")}
        var request=URLRequest(url:url)
        // Mac 9.49 emits this exact host. Its real HEAD response is 404,
        // while GET redirects to the canonical note. Keep legacy hosts on HEAD.
        request.httpMethod = url.host?.lowercased() == "xhslink.cn" ? "GET" : "HEAD"
        request.timeoutInterval=15
        return request
    }
    static func resolve(_ url:URL) async throws -> XiaohongshuResolvedLink {
        let request = try request(for:url)
        let delegate=XiaohongshuRedirectGuard(url:url)
        let config=URLSessionConfiguration.ephemeral;config.httpCookieStorage=nil;config.urlCredentialStorage=nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session=URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        let (_,response)=try await session.data(for:request)
        try Task.checkCancellation()
        guard let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode),let final=http.url else {
            throw AgentError.message("短链解析未取得可信最终来源，保留待核验")
        }
        return try delegate.result(final:final)
    }
}
