import SwiftUI

struct NativeConnectionIcon: View {
    let app: NativeAppConnection
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let asset = app.brandAsset { Image(asset).resizable().scaledToFit() }
            else {
                RoundedRectangle(cornerRadius: size * 0.23).fill(.blue.gradient)
                    .overlay { Image(systemName: "location.fill").font(.system(size: size * 0.48)).foregroundStyle(.white) }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

struct NativeConnectionDetailView: View {
    let app: NativeAppConnection
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var permissions = NativeConnectionsStore.shared
    @State private var healthScopes = Set(NativeHealthScope.allCases)
    @State private var request: Task<Void, Never>?
    private var state: NativeConnectionAccess { permissions.state(app) }
    private var taskRunning: Bool { model.engine.running || model.engine.releasing || model.voicePending }
    private var busy: Bool { permissions.requesting != nil || taskRunning || (app == .health && permissions.healthAuthorizationPending) }
    var body: some View {
        if app == .notes { NotesShortcutConnectionView() }
        else {
        ConnectionPage {
            HStack(spacing: 16) {
                NativeConnectionIcon(app: app, size: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.title).font(.title2.weight(.semibold))
                }
            }
            Text(app.purpose).font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                .accessibilityIdentifier("native.\(app.rawValue).purpose")
            AgentCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(state.title).font(.headline)
                        Spacer()
                        if permissions.requesting == app { ProgressView() }
                        else if state.ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                }
            }
            if app == .health {
                AgentCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("数据类型").font(.headline)
                        ForEach(NativeHealthScope.allCases) { scope in
                            Toggle(scope.title, isOn: Binding(get: { healthScopes.contains(scope) }, set: { enabled in
                                if enabled { healthScopes.insert(scope) } else { healthScopes.remove(scope) }
                            }))
                        }
                    }
                }.disabled(busy)
            }
            if state != .unavailable && !state.needsSettings {
                Button(state == .reviewed ? "确认所选健康授权" : state.ready ? "刷新授权状态" : "允许访问" + app.title) {
                    if state.ready { permissions.refresh(); enableAgentAccess() }
                    else { request = Task { await permissions.request(app, healthScopes: healthScopes); enableAgentAccess(); request = nil } }
                }.buttonStyle(AgentButtonStyle()).disabled(busy || (app == .health && healthScopes.isEmpty))
                    .accessibilityIdentifier("native.\(app.rawValue).authorize")
            }
            if app == .photos && state == .limited {
                Button("管理已选照片") {
                    request = Task { await permissions.managePhotoSelection(); enableAgentAccess(); request = nil }
                }.buttonStyle(AgentButtonStyle(primary: false)).disabled(busy)
                    .accessibilityIdentifier("native.photos.manageSelection")
            }
            Button("管理权限") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                .buttonStyle(AgentButtonStyle(primary: false)).disabled(busy)
                .accessibilityIdentifier("native.\(app.rawValue).settings")
            if !permissions.message.isEmpty { AgentNotice(text: permissions.message, error: permissions.failed) }
            if taskRunning { AgentNotice(text: "任务进行中") }
            if app == .health && permissions.healthAuthorizationPending { AgentNotice(text: "系统健康授权尚未结束；停止任务不会读取后续返回的数据。请先处理或关闭系统授权页。") }
        }
        .task { permissions.resetMessage(); permissions.refresh(); if app == .health { healthScopes = permissions.requestedHealthScopes } }
        .onChange(of: phase) { _, value in if value == .active { permissions.refresh(); if state.ready { permissions.resetMessage() } } }
        .onChange(of: permissions.requesting) { previous, current in
            if previous == app && current == nil { enableAgentAccess() }
        }
        .accessibilityIdentifier("nativeConnection." + app.rawValue)
        }
    }
    private func enableAgentAccess() {
        if !permissions.failed && (state.ready || (app == .health && state == .reviewed)) {
            model.settings.systemToolsEnabled = true
        }
    }
}

struct WPSConnectionView: View {
    let onNavigate: (WorkspaceDestination) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button("打开文档工作区") { onNavigate(.workbench) }.buttonStyle(AgentButtonStyle())
                .accessibilityIdentifier("apps.wps.documents")
        }
    }
}
