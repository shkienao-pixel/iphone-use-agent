import AuthenticationServices
import UIKit

@MainActor
final class OfficeAuthorizationBrowser: NSObject, OfficeAuthorizationPresenting, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?
    private var generation = UUID()

    func authorizationURL(for job: OfficeAuthorizationJob) async -> URL? {
        guard let service = ExternalAppService(rawValue: job.service) else { return nil }
        if let url = OfficeAuthorizationPolicy.authorizationURL(job.authorizationURL, service: service) { return url }
        guard let encoded = job.qrCode else { return nil }
        // Scan only this authorization QR. Never send its one-time ticket to another service.
        let payload = await OfficeAuthorizationQRCode.payload(encoded)
        return OfficeAuthorizationPolicy.authorizationURL(payload, service: service)
    }

    func open(_ url: URL, callback: URL, event: @escaping @MainActor (OfficeAuthorizationPresentationEvent) -> Void) async throws -> OfficeAuthorizationLaunch {
        dismiss()
        let current = generation
        // Do not invent a URL scheme or open the provider's home screen. Try the
        // actual authorization URL as a Universal Link, with no browser fallback here.
        return try await OfficeAuthorizationPolicy.route(openApp: {
            await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
        }, openWeb: {
        guard generation == current else { throw CancellationError() }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }) else {
            throw AgentError.message("暂时无法显示授权页，请回到 Sela 后点击继续授权")
        }
        anchor = window
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: callback.scheme) { [weak self] returned, _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.session = nil
                if let returned { event(.callback(returned)) }
                else { event(.closed) }
            }
        }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = false
        session = browser
        guard browser.start() else {
            session = nil
            throw AgentError.message("未能打开官方授权页，请点击继续授权重试")
        }
        })
    }

    func dismiss() {
        generation = UUID()
        let old = session; session = nil
        old?.cancel(); anchor = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
