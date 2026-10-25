import UIKit

@MainActor enum NativePermissionPresentation {
    /// HealthKit presents inside the app. Wait for a tool approval sheet's real
    /// dismissal instead of attaching authorization to a disappearing controller.
    static func waitUntilReady() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard UIApplication.shared.applicationState == .active else {
                throw AgentError.message("请回到 Sela 前台再完成系统授权")
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let root = scenes.filter({ $0.activationState == .foregroundActive })
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
                throw AgentError.message("当前没有可呈现系统授权的窗口")
            }
            if root.presentedViewController == nil && root.transitionCoordinator == nil && !root.isBeingDismissed { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentError.message("其他页面尚未关闭，未请求健康授权；请关闭弹窗后重试")
    }
}
