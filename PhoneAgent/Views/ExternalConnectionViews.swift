import SwiftUI

struct BrandAppIcon: View {
    let service: ExternalAppService
    var size: CGFloat = 40
    var body: some View {
        Image(service.brandAsset).resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct OfficeConnectionView: View {
    let service: ExternalAppService
    let onBridgeSettings: () -> Void
    @ObservedObject private var connections = ExternalConnectionsCoordinator.shared
    @ObservedObject private var authorization = OfficeAuthorizationFlow.shared
    @State private var operation: Task<Void, Never>?
    @State private var message = ""
    @State private var failed = false
    @State private var checking = false
    private var snapshot: OfficeConnectionStatus? { connections.statuses[service.rawValue] }
    private var authorizing: Bool { authorization.service == service && authorization.running }
    private var anotherAuthorization: Bool { authorization.running && authorization.service != service }
    private var active: Bool { operation != nil || authorizing }
    private var job: OfficeAuthorizationJob? { authorization.service == service ? authorization.job : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AgentCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(authorizing ? "授权中" : connections.statusLabel(service)).font(.headline)
                        Spacer()
                        if active || checking { ProgressView() }
                        else if snapshot?.connected == true { Circle().fill(.green).frame(width: 8, height: 8) }
                    }
                }
            }
            if connections.bridgeAvailable {
                if snapshot?.installed == false {
                    Button("准备连接", action: prepare).buttonStyle(AgentButtonStyle())
                        .disabled(active || checking || anotherAuthorization).accessibilityIdentifier("apps.\(service.rawValue).install")
                } else {
                    Button(snapshot?.connected == true ? "重新授权" : "连接" + service.title.replacingOccurrences(of: " CLI", with: "")) {
                        message = ""; failed = false; authorization.start(service)
                    }.buttonStyle(AgentButtonStyle()).disabled(active || checking || anotherAuthorization)
                        .accessibilityIdentifier("apps.\(service.rawValue).connect")
                }
                Button("检测连接", action: refresh).buttonStyle(AgentButtonStyle(primary: false))
                    .disabled(active || checking).accessibilityIdentifier("apps.\(service.rawValue).check")
            } else {
                Button("配置连接服务", action: onBridgeSettings).buttonStyle(AgentButtonStyle())
                    .accessibilityIdentifier("apps.\(service.rawValue).configureBridge")
                Button("重新检测连接服务", action: refresh).buttonStyle(AgentButtonStyle(primary: false)).disabled(checking)
            }
            if anotherAuthorization { AgentNotice(text: "请先完成或取消正在进行的账号授权。") }
            if authorizing {
                AgentCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(authorization.message).font(.subheadline)
                        if let code = job?.verificationCode {
                            Text("在官方授权页填写此验证码").font(.caption).foregroundStyle(.secondary)
                            Text(code).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                        }
                        if let encoded = job?.qrCode, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 230, maxHeight: 230).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                            ShareLink(item: Image(uiImage: image), preview: SharePreview("企业微信授权二维码", image: Image(uiImage: image))) {
                                Label("保存或分享二维码", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                            }
                        }
                        if job?.authorizationURL != nil || job?.qrCode != nil {
                            Button("继续授权") { authorization.continueAuthorization() }.frame(minHeight: 44)
                                .accessibilityIdentifier("apps.\(service.rawValue).authorize")
                        }
                        Button("取消本次授权", role: .cancel) { authorization.cancel() }.frame(minHeight: 44)
                            .accessibilityIdentifier("apps.\(service.rawValue).cancel")
                    }
                }
            } else if authorization.service == service && !authorization.message.isEmpty {
                AgentNotice(text: authorization.message, error: authorization.phase == .failed)
                    .accessibilityIdentifier("apps.\(service.rawValue).authorizationResult")
            }
            if !message.isEmpty { AgentNotice(text: message, error: failed) }
            Link("查看官方接入说明", destination: service.documentationURL).frame(minHeight: 44)
            if connections.bridgeAvailable { Button("管理连接服务", action: onBridgeSettings).frame(minHeight: 44) }
            if snapshot?.connected == true {
                Button("断开连接", role: .destructive) {
                    operation = Task {
                        defer { operation = nil }
                        do { try await connections.disconnect(service); authorization.clearResult(); message = "已从 Sela 断开此连接"; failed = false }
                        catch { message = error.localizedDescription; failed = true }
                    }
                }.frame(minHeight: 44).disabled(active || checking)
            }
        }
        .task { checking = true; await connections.refresh(service); checking = false; authorization.restore() }
        .onDisappear { operation?.cancel(); operation = nil }
    }

    private func refresh() {
        guard !checking else { return }; checking = true
        operation = Task { await connections.refresh(service); checking = false; operation = nil }
    }
    private func prepare() {
        guard !active else { return }; message = ""; failed = false
        operation = Task {
            defer { operation = nil }
            do {
                var latest = try await connections.start(service, install: true)
                while !latest.finished {
                    try await Task.sleep(for: .seconds(1)); latest = try await connections.poll(latest.id)
                    try Task.checkCancellation()
                }
                message = latest.message; failed = latest.state != "complete"
                await connections.refresh(service)
            } catch is CancellationError { }
            catch { message = error.localizedDescription; failed = true }
        }
    }
}

struct ConnectionBridgeSettingsView: View {
    @Environment(\.scenePhase) private var phase
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var connections = ExternalConnectionsCoordinator.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var message = ""
    @State private var failed = false
    @State private var checking = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AgentPageIntro(title: "连接办公服务", subtitle: "填写你的连接服务配置，然后使用飞书、钉钉或企业微信账号授权。", icon: "link")
                AgentCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("连接服务地址").font(.subheadline.weight(.medium))
                        TextField("https://connect.example.com", text: $endpoint, axis: .vertical).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().agentField()
                            .focused($fieldFocused).accessibilityLabel("连接服务地址")
                        Text("配对码").font(.subheadline.weight(.medium))
                        SecureField(connections.paired ? "已配对，填写可替换配对码" : "填写连接服务生成的配对码", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().agentField()
                            .focused($fieldFocused).submitLabel(.done).onSubmit { fieldFocused = false }
                            .accessibilityLabel("连接服务配对码")
                    }
                }
                Button("保存并检测") {
                    fieldFocused = false; checking = true
                    Task {
                        defer { checking = false }
                        do {
                            let key = token.isEmpty ? ConnectionCredentialStore.read("bridge-token") : token
                            try connections.saveBridge(endpoint: endpoint, token: key)
                            OfficeAuthorizationFlow.shared.clearResult()
                            token = ""; await connections.checkBridge()
                            message = connections.bridgeMessage; failed = !connections.bridgeAvailable
                        } catch { message = error.localizedDescription; failed = true }
                    }
                }.buttonStyle(AgentButtonStyle()).disabled(checking)
                if checking { ProgressView("检测连接服务…") }
                if !message.isEmpty { AgentNotice(text: message, error: failed) }
            }.padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { endpoint = connections.endpointText; await connections.checkBridge(); message = connections.bridgeMessage; failed = !connections.bridgeAvailable }
        .onChange(of: phase) { _, value in if value != .active { token = ""; fieldFocused = false } }
        .onDisappear { token = "" }
    }
}

struct MeituanConnectionView: View {
    @Environment(\.scenePhase) private var phase
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var connections = ExternalConnectionsCoordinator.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var message = ""
    @State private var failed = false
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var tools: [String] = []
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Link(destination: ExternalAppService.meituan.documentationURL) {
                Label("获取美团接入配置", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityIdentifier("apps.meituan.getConfiguration")
            AgentCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("美团官方服务地址").font(.subheadline.weight(.medium))
                    TextField("粘贴美团提供的 HTTPS 地址", text: $endpoint, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().agentField()
                        .focused($fieldFocused)
                        .accessibilityLabel("美团官方服务地址")
                    Text("访问凭据").font(.subheadline.weight(.medium))
                    SecureField("若服务需要，填写访问凭据", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().agentField()
                        .focused($fieldFocused).submitLabel(.done).onSubmit { fieldFocused = false }
                        .accessibilityLabel("美团访问凭据")
                }
            }.disabled(working)
            Button("保存配置", action: save).buttonStyle(AgentButtonStyle())
                .disabled(working || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("apps.meituan.save")
            Button("检测连接与开放能力", action: check).buttonStyle(AgentButtonStyle(primary: false))
                .disabled(working || !MeituanConnectionStore.configured).accessibilityIdentifier("apps.meituan.check")
            if working {
                HStack { ProgressView("连接美团…"); Spacer(); Button("取消") { cancel() } }
            }
            if !message.isEmpty { AgentNotice(text: message, error: failed) }
            if !tools.isEmpty {
                DisclosureGroup("已开放 \(tools.count) 项能力") {
                    VStack(alignment: .leading, spacing: 10) { ForEach(tools, id: \.self) { Text($0).font(.footnote) } }.padding(.top, 12)
                }.agentPanel()
            }
            if MeituanConnectionStore.configured {
                Button("断开并清除本机配置", role: .destructive) { confirmingDisconnect = true }.frame(minHeight: 44).disabled(working)
            }
        }
        .onAppear {
            endpoint = MeituanConnectionStore.endpoint; token = MeituanConnectionStore.credential
            tools = MeituanConnectionStore.capabilities
            if MeituanConnectionStore.verified { message = "已连接美团开放服务" }
        }
        .onChange(of: phase) { _, value in
            if value != .active { cancel(); token = "" }
            else if token.isEmpty { token = MeituanConnectionStore.credential }
        }
        .onDisappear { cancel(); token = "" }
        .confirmationDialog("清除这台设备的美团连接配置？", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("清除配置", role: .destructive) {
                do { try MeituanConnectionStore.disconnect(); endpoint = ""; token = ""; tools = []; failed = false; message = "已断开美团连接" }
                catch { message = error.localizedDescription; failed = true }
            }
        }
    }
    private func save() {
        fieldFocused = false
        do {
            try MeituanConnectionStore.save(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            tools = []; message = "配置已保存，请检测连接"; failed = false
        } catch { message = error.localizedDescription; failed = true }
    }
    private func check() {
        guard !working else { return }
        working = true; message = ""; failed = false
        UserDefaults.standard.set(false, forKey: "connections.meituan.verified")
        operation = Task {
            defer { working = false; operation = nil }
            do {
                let savedEndpoint = MeituanConnectionStore.endpoint, savedToken = MeituanConnectionStore.credential
                let client = try MeituanMCPClient(endpoint: MeituanMCPClient.validatedEndpoint(savedEndpoint), token: savedToken)
                let names: [String]
                if savedEndpoint == MeituanTravelClient.endpoint.absoluteString {
                    _ = try await MeituanTravelClient(token: savedToken).query("查询上海一日游景点，仅查询，不预订不下单。")
                    names = ["旅行查询"]
                } else { names = try await client.checkConnection() }
                try Task.checkCancellation()
                guard phase == .active, savedEndpoint == MeituanConnectionStore.endpoint, savedToken == MeituanConnectionStore.credential else { return }
                MeituanConnectionStore.verified(tools: names); tools = names
                message = "美团连接成功，已检测到 \(names.count) 项开放能力"; failed = false
                await connections.refresh(.meituan)
            } catch is CancellationError { }
            catch { message = error.localizedDescription; failed = true }
        }
    }
    private func cancel() { operation?.cancel(); operation = nil; working = false }
}
