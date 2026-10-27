import Foundation

/// Bounded ordinary HTTP transport. Paotui JSON responses do not use the MCP
/// event-stream parser or its early-result termination policy.
enum PaotuiHTTPTransport {
    static let maximumResponseBytes = 1_048_576

    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await load(request, configuration: .ephemeral)
    }

    /// The configuration seam lets offline checks exercise this exact transport
    /// with a URLProtocol fixture; security policy is applied in either case.
    static func load(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: PaotuiNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.message("美团服务未返回有效响应") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw AgentError.message("美团响应过大，请稍后重试") }
            data.append(byte)
        }
        return (data, http)
    }
}

private final class PaotuiNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
