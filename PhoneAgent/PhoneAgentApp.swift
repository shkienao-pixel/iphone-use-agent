import SwiftUI
import AppIntents

@main
struct PhoneAgentApp: App {
    @UIApplicationDelegateAdaptor(SelaAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = PhoneAgentViewModel.shared
    @StateObject private var authorization = OfficeAuthorizationFlow.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        DebugPaotuiConfigImport.runIfRequested()
        #endif
        PhoneAgentShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(viewModel)
                .agentTheme()
                .task { authorization.restore() }
                .task {
                    #if DEBUG
                    await SelaDeviceDiagnostics.run(model: viewModel)
                    #endif
                }
                .onOpenURL { url in if !NotesShortcutBridge.shared.handle(url) { authorization.handle(url) } }
                .onChange(of: scenePhase) { _, phase in
                    authorization.sceneActive(phase != .background)
                    if phase == .active {
                        NotesShortcutBridge.shared.becameActive()
                        viewModel.refreshBackgroundExecution()
                        Task { await viewModel.taskNotifications.refreshAuthorization() }
                    }
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let reviewPage {
            PhoneAgentReviewPage(name: reviewPage)
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }

    #if DEBUG
    private var reviewPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-page"),
              arguments.indices.contains(flag + 1) else {
            return nil
        }
        return arguments[flag + 1]
    }
    #endif
}
