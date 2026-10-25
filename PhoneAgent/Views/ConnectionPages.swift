import SwiftUI

struct AppConnectionsView: View {
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var connections = ExternalConnectionsCoordinator.shared
    @ObservedObject private var native = NativeConnectionsStore.shared
    @ObservedObject private var phoneContent = PhoneContentStore.shared
    @State private var showsPhoneContent = false
    let onNavigate: (WorkspaceDestination) -> Void
    let onConfiguration: (SettingsPage) -> Void

    var body: some View {
        ConnectionPage {
            ConnectionGroup("AI 服务") {
                ChatGPTConnectionCard(identifier: "apps.chatgpt", onConfiguration: onConfiguration)
            }
            ConnectionGroup("Sela 本机") {
                ConnectionRow("本机内容", detail: "查看已保存的原文与目录", icon: "doc.text.fill", brandAsset: "Brand-Sela",
                    status: phoneContent.error.isEmpty ? "\(phoneContent.artifacts.count) / \(PhoneContentStore.maximumArtifacts)" : "暂不可用",
                    ready: phoneContent.error.isEmpty, identifier: "apps.phoneContent") { showsPhoneContent = true }
            }
            ConnectionGroup("iPhone 原生服务") {
                ForEach(Array(NativeAppConnection.allCases.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { ConnectionDivider() }
                    ConnectionRow(app.title, detail: app.detail, icon: "location.fill", nativeApp: app,
                        status: native.state(app).title, ready: native.state(app).ready,
                        identifier: "apps.native." + app.rawValue) { onNavigate(.nativeAppConnection(app)) }
                }
            }
            ConnectionGroup("办公协作") {
                ForEach(Array(ExternalAppService.allCases.filter(\.isCLI).enumerated()), id: \.element.id) { index, service in
                    if index > 0 { ConnectionDivider() }
                    app(service)
                }
                ConnectionDivider()
                app(.wps)
            }
            ConnectionGroup("生活服务") {
                app(.ctrip)
                ConnectionDivider()
                app(.meituan)
            }
        }
        .accessibilityIdentifier("appConnections")
        .sheet(isPresented: $showsPhoneContent) { PhoneContentLibraryView() }
        .task { native.refresh(); await connections.refreshAll() }
        .onChange(of: phase) { _, value in if value == .active { native.refresh() } }
    }
    private func app(_ service: ExternalAppService) -> some View {
        ConnectionRow(service.title, detail: service.connectionDetail,
            icon: service.icon, brandAsset: service.brandAsset, status: connections.statusLabel(service),
            ready: service.isCLI ? connections.statuses[service.rawValue]?.connected == true : service == .meituan && (MeituanConnectionStore.verified || MeituanPaotuiStore.shared.ready),
            identifier: "apps." + service.rawValue) {
            onNavigate(.appConnection(service))
        }
    }
}

struct ExternalAppConnectionDetailView: View {
    let service: ExternalAppService
    let onConfiguration: (SettingsPage) -> Void
    let onNavigate: (WorkspaceDestination) -> Void

    var body: some View {
        ConnectionPage {
            HStack(spacing: 16) {
                BrandAppIcon(service: service, size: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text(service.title).font(.title2.weight(.semibold))
                    Text(service.connectionDetail)
                        .font(.subheadline).foregroundStyle(SelaHomePalette.secondary)
                }
            }
            if service == .ctrip {
                CtripSettingsView(showsIntro: false)
            } else if service == .meituan {
                MeituanPaotuiView(onChat: { onNavigate(.assistant) })
            } else if service == .wps {
                WPSConnectionView(onNavigate: onNavigate)
            } else {
                OfficeConnectionView(service: service, onBridgeSettings: { onNavigate(.connectionBridge) })
            }
        }
        .accessibilityIdentifier("appConnection." + service.rawValue)
    }
}

struct ModelMemoryConnectionsView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let onNavigate: (WorkspaceDestination) -> Void
    let onConfiguration: (SettingsPage) -> Void

    var body: some View {
        ConnectionPage {
            ConnectionGroup("AI 服务") {
                if model.settings.usesChatGPTPlan {
                    ChatGPTConnectionCard(identifier: "modelMemory.model", onConfiguration: onConfiguration)
                } else {
                ConnectionRow("模型连接", detail: model.modelReady ? "\(PrivacyConsent.recipient(model.settings)) · \(model.settings.model)" : "选择服务商与模型，管理 API Key",
                    icon: "sparkles", status: model.modelReady ? "已配置" : "待配置", ready: model.modelReady,
                    identifier: "modelMemory.model") { onConfiguration(.model) }
                }
                ConnectionDivider()
                ConnectionRow("数据使用授权", detail: "管理 AI 服务接收的数据范围", icon: "hand.raised",
                    status: model.consentReady ? "已授权" : "待确认", ready: model.consentReady,
                    identifier: "modelMemory.consent") { onConfiguration(.privacy) }
                ConnectionDivider()
                ConnectionRow("联网检索", detail: "搜索服务、API Key 与来源", icon: "globe",
                    identifier: "modelMemory.search") { onConfiguration(.search) }
            }
            ConnectionGroup("记忆") {
                ConnectionRow("记忆与上下文", detail: "管理偏好、笔记与已保存的上下文", icon: "bookmark",
                    identifier: "modelMemory.memory") { onNavigate(.memory) }
            }
        }
        .accessibilityIdentifier("modelMemoryConnections")
    }
}

struct ConnectionPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28, content: content)
                .padding(.horizontal, 20).padding(.vertical, 24)
                .frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .top)
        }.scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .foregroundStyle(SelaHomePalette.accent)
            .background(SelaHomePalette.background.ignoresSafeArea())
    }
}

private struct ConnectionGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(SelaHomePalette.secondary)
                .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct ConnectionDivider: View {
    var body: some View { Rectangle().fill(SelaHomePalette.line).frame(height: 0.5).padding(.leading, 64).accessibilityHidden(true) }
}

struct ConnectionRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let detail: String
    let icon: String
    var brandAsset: String? = nil
    var nativeApp: NativeAppConnection? = nil
    var status: String? = nil
    var ready = false
    let identifier: String
    let action: () -> Void
    init(_ title: String, detail: String, icon: String, brandAsset: String? = nil, nativeApp: NativeAppConnection? = nil, status: String? = nil, ready: Bool = false, identifier: String, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.icon = icon; self.brandAsset = brandAsset; self.nativeApp = nativeApp; self.status = status; self.ready = ready; self.identifier = identifier; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            rowIcon
                            Text(title).font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            chevron.padding(.top, 12)
                        }
                        Text(detail).font(.footnote).foregroundStyle(SelaHomePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        statusLabel
                    }
                } else {
                    HStack(spacing: 14) {
                        rowIcon
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title).font(.body.weight(.medium))
                            Text(detail).font(.footnote).foregroundStyle(SelaHomePalette.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        statusLabel.fixedSize(horizontal: true, vertical: false)
                        chevron
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 17).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(AgentPressStyle()).foregroundStyle(SelaHomePalette.accent)
            .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
    private var rowIcon: some View {
        Group {
            if let nativeApp {
                NativeConnectionIcon(app: nativeApp, size: 34)
            } else if let brandAsset {
                Image(brandAsset).resizable().scaledToFit().frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else { Image(systemName: icon).font(.system(size: 19)).frame(width: 32, height: 36) }
        }.accessibilityHidden(true)
    }
    @ViewBuilder private var statusLabel: some View {
        if let status { Text(status).font(.caption).foregroundStyle(ready ? Color.green : SelaHomePalette.secondary) }
    }
    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SelaHomePalette.secondary).accessibilityHidden(true)
    }
}
