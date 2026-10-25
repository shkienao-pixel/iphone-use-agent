import SwiftUI
import AppIntents
import UniformTypeIdentifiers

enum SettingsPage: String, Hashable {
    case model = "模型连接", behavior = "执行偏好", floating = "动作浮窗"
    case siri = "Siri 与快捷指令", privacy = "隐私与数据", about = "使用说明"
    case search = "联网检索", ctrip = "携程连接", performance = "运行与基准记录"
    case notifications = "任务通知"
}

struct SettingsView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(AgentTheme.storageKey) private var appearance = AgentTheme.system.rawValue
    var reviewPage: String? = nil
    var focusedPage: SettingsPage? = nil
    @State private var path: [SettingsPage] = []
    let onBack: () -> Void
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var checking = false
    @State private var providerSelection = "custom"
    @State private var advancedConnection = false
    @State private var clearHistory = false
    @State private var clearReceipts = false
    @State private var exportingReceipts = false
    @State private var receiptDocument: ArtifactDocument?
    @State private var receiptError = ""
    @State private var revoke = false
    @State private var connectionMessage = ""
    @State private var connectionFailed = false
    private var locked: Bool { model.engine.running || model.engine.releasing || model.voicePending }
    private var modelSummary: String {
        model.modelReady ? "\(PrivacyConsent.recipient(model.settings)) · \(model.settings.model)" : "连接你使用的 AI 服务"
    }
    var body: some View {
        NavigationStack(path: $path) {
            Group {
            if let focusedPage {
                detail(focusedPage)
                    .navigationTitle(focusedPage.rawValue).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成", action: onBack).accessibilityIdentifier("connection.done") }
                    }
            } else {
            ScrollView {
                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 26) {
                        settingsGroup("助手") {
                            route(.behavior, subtitle: "行动节奏与确认方式", icon: "slider.horizontal.3")
                            groupDivider
                            route(.floating, subtitle: model.settings.autoPiPOnExit == true ? "离开时自动开启" : "在其他 App 中查看执行状态", icon: "pip")
                            groupDivider
                            route(.notifications, subtitle: model.taskNotifications.status, icon: "bell.badge")
                                .accessibilityIdentifier("settings.notifications")
                            groupDivider
                            route(.siri, subtitle: "语音与快捷指令", icon: "waveform")
                            groupDivider
                            route(.performance, subtitle: "固定起点、查看与导出记录", icon: "chart.bar.xaxis")
                        }
                        settingsGroup("显示") {
                            HStack(spacing: 8) {
                                AgentSettingsRow(title: "外观", subtitle: "", icon: "circle.lefthalf.filled")
                                Picker("外观", selection: $appearance) {
                                    ForEach(AgentTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
                                }
                                .labelsHidden().pickerStyle(.menu).tint(.primary)
                                .accessibilityLabel("外观")
                            }
                            .frame(minHeight: 72)
                        }
                        settingsGroup("关于") {
                            route(.privacy, subtitle: model.consentReady ? "已授权当前服务" : "管理授权和本机记录", icon: "hand.raised")
                            groupDivider
                            route(.about, subtitle: "能力与使用条件", icon: "questionmark.circle")
                        }
                        Label("API Key 保存在这台设备的钥匙串", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            .padding(.horizontal, 16)
                    }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 28)
                }
            }.background(AgentPalette.background)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                            .tint(.primary).accessibilityLabel("返回上一页")
                            .accessibilityIdentifier("settings.back")
                    }
                }
            }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                detail(page)
                    .navigationTitle(page.rawValue).navigationBarTitleDisplayMode(.inline)
            }
        }
        .tint(AgentPalette.accent)
        .accessibilityIdentifier("settings.page")
        .fileExporter(isPresented: $exportingReceipts, document: receiptDocument, contentType: .json, defaultFilename: "Sela 工具回执.json") { result in
            if case .failure(let failure) = result { receiptError = failure.localizedDescription }; receiptDocument = nil
        }
        .confirmationDialog("清除本机工具回执？", isPresented: $clearReceipts, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                guard !model.engine.hasCurrentTask, !model.engine.releasing else { receiptError = "请先结束当前的可恢复任务"; return }
                do { try model.tools.clearReceipts(); receiptError = "" } catch { receiptError = error.localizedDescription }
            }
        } message: { Text("不会删除系统里已创建的日程、提醒或闹钟。重复提交防护记录将删除；请先核对所有未确认结果。当前有可恢复任务时不能清理。") }
        .confirmationDialog("删除全部任务和行动记录？", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("删除全部历史", role: .destructive) { model.clearHistory() }
        }
        .confirmationDialog("撤回后会停止任务和屏幕共享。", isPresented: $revoke, titleVisibility: .visible) {
            Button("撤回 AI 数据授权", role: .destructive) { model.revokeConsent() }
        }
        .onAppear {
            loadConnectionDraft()
            #if DEBUG
            if let reviewPage, path.isEmpty {
                let pages: [String: SettingsPage] = ["model": .model, "behavior": .behavior, "floating": .floating, "siri": .siri, "privacy": .privacy, "about": .about, "search": .search, "ctrip": .ctrip, "performance": .performance, "notifications": .notifications]
                if let page = pages[reviewPage] { path = [page] }
            }
            #endif
        }
        .onChange(of: model.settings.endpoint) { _, _ in
            apiKey = SettingsStore.apiKey(for: model.settings.endpoint)
            connectionMessage = ""
        }
    }
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                .padding(.horizontal, 16).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .agentGlass(in: AgentInputMetrics.shape)
        }
    }
    private var groupDivider: some View { Divider().padding(.leading, 38) }
    private func route(_ page: SettingsPage, subtitle: String, icon: String) -> some View {
        NavigationLink(value: page) {
            HStack(spacing: 8) {
                AgentSettingsRow(title: page.rawValue, subtitle: [.model, .floating, .notifications].contains(page) ? subtitle : "", icon: icon)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }.frame(minHeight: 72).contentShape(Rectangle())
        }.buttonStyle(AgentPressStyle())
    }
    private func detail(_ page: SettingsPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch page {
                case .model:
                    connection.disabled(locked || checking)
                        .onAppear { loadConnectionDraft() }
                case .search: WebSearchSettingsView(embedded: true)
                case .ctrip: CtripSettingsView()
                case .performance: PerformanceReviewView()
                case .notifications: TaskNotificationsView(notifications: model.taskNotifications)
                case .behavior: preferences.disabled(locked)
                case .floating: floatingWindow
                case .siri: siri
                case .privacy: privacy
                case .about: about
                }
                if locked && [.model, .behavior].contains(page) {
                    AgentNotice(text: "任务结束或暂停后，可调整这些设置。")
                }
            }.padding(20)
        }.background(AgentPalette.background).scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onDisappear { showKey = false }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("操作屏幕、识屏及相机对话需要支持图像的模型。\n仅工具和文字模式可以使用文本模型。")
                .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
            AgentCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("服务商").font(.subheadline.weight(.medium))
                        Spacer()
                        Picker("服务商", selection: Binding(get: { providerSelection }, set: { chooseService($0) })) {
                            Text("ChatGPT 计划").tag("chatgpt_plan")
                            Text("OpenAI").tag("openai")
                            Text("火山方舟").tag("ark")
                            Text("自定义接口").tag("custom")
                        }.labelsHidden().pickerStyle(.menu).lineLimit(1)
                            .accessibilityIdentifier("model.provider")
                    }
                    if providerSelection == "chatgpt_plan" {
                        ChatGPTPlanSettingsView()
                    } else {
                    if providerSelection == "custom" {
                        field("服务商名称") {
                            TextField("例如：基元律动", text: Binding(get: { model.settings.providerName ?? "" }, set: { model.settings.providerName = $0 }), prompt: Text("例如：基元律动").foregroundStyle(AgentPalette.placeholder))
                                .agentField().accessibilityLabel("服务商名称")
                        }
                    }
                    field("接口地址") {
                        TextField("https://example.com/v1/chat/completions", text: $model.settings.endpoint, prompt: Text("https://example.com/v1/chat/completions").foregroundStyle(AgentPalette.placeholder), axis: .vertical)
                            .lineLimit(1...3).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .agentField().accessibilityLabel("模型接口地址")
                    }
                    field("模型 ID") {
                        TextField("填写服务商提供的模型 ID", text: $model.settings.model, prompt: Text("填写服务商提供的模型 ID").foregroundStyle(AgentPalette.placeholder))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .agentField().accessibilityLabel("模型 ID")
                    }
                    field("API Key") {
                        HStack(spacing: 8) {
                            Group {
                                if showKey { TextField("粘贴 API Key", text: $apiKey, prompt: Text("粘贴 API Key").foregroundStyle(AgentPalette.placeholder)) }
                                else { SecureField("粘贴 API Key", text: $apiKey, prompt: Text("粘贴 API Key").foregroundStyle(AgentPalette.placeholder)) }
                            }.textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("API Key")
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye").frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(showKey ? "隐藏 API Key" : "显示 API Key")
                        }.agentField()
                    }
                    Text("模型接口必须使用有效 HTTPS 地址。请填写完整的 Chat Completions URL。")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                    }
                }.font(.subheadline)
            }
            if providerSelection != "chatgpt_plan" {
            GlassEffectContainer(spacing: 12) {
                let actionLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                actionLayout {
                    Button("保存配置") { model.saveKey(apiKey); connectionFailed = false; connectionMessage = model.notice }
                        .buttonStyle(AgentButtonStyle())
                    Button(checking ? "连接中…" : "测试连接") { checkConnection() }
                        .buttonStyle(AgentButtonStyle(primary: false))
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !connectionMessage.isEmpty { AgentNotice(text: connectionMessage, error: connectionFailed) }
            AgentCard {
                DisclosureGroup("兼容性与回复长度", isExpanded: $advancedConnection) {
                    VStack(alignment: .leading, spacing: 20) {
                        Toggle("JSON 模式", isOn: $model.settings.jsonMode).tint(AgentPalette.accent).padding(.trailing, 6)
                        Toggle("使用旧版 Token 参数", isOn: $model.settings.legacyTokenLimit).tint(AgentPalette.accent).padding(.trailing, 6)
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("回复长度上限").font(.subheadline.weight(.medium))
                            Stepper(value: Binding(get: { model.settings.responseTokenLimit }, set: { model.settings.maxResponseTokens = $0 }), in: 1024...16384, step: 1024) {
                                Text("\(model.settings.responseTokenLimit) Token").monospacedDigit()
                            }
                        }
                        Text("默认设置适合多数接口。服务商不支持 JSON 模式时可关闭；截断后会提高回复上限并重新观察，重试会消耗额度。")
                            .font(.caption).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }.font(.subheadline).padding(.top, 20)
                }.font(.subheadline.weight(.medium))
            }
            }
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentCard {
                VStack(alignment: .leading, spacing: 20) {
                    Text("任务执行").font(.headline)
                    Toggle(isOn: $model.settings.confirmEachStep) {
                        preferenceLabel("执行前逐项确认", value: "默认关闭：收到任务直接执行，可随时暂停或停止")
                    }.tint(AgentPalette.accent)
                    Divider()
                    Toggle(isOn: $model.settings.previewOnly) {
                        preferenceLabel("只生成计划", value: "观察一次，展示下一步建议")
                    }.tint(AgentPalette.accent)
                    Divider()
                    Toggle(isOn: Binding(get: { model.settings.runsContinuously }, set: { model.settings.continuousExecution = $0 })) {
                        preferenceLabel("长任务模式", value: "不限行动步数，自动压缩上下文；可随时暂停或停止")
                    }.tint(AgentPalette.accent)
                    if !model.settings.runsContinuously {
                        Stepper(value: $model.settings.maxSteps, in: 1...100) { preferenceLabel("最多行动", value: "\(model.settings.maxSteps) 步") }
                    }
                }
            }
            AgentCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("行动节奏").font(.headline)
                    Stepper(value: $model.settings.startDelay, in: 0...10, step: 1) { preferenceLabel("开始前等待", value: "\(Int(model.settings.startDelay)) 秒 · 留出切换 App 的时间") }
                    Divider()
                    Stepper(value: $model.settings.stepInterval, in: 0.5...5, step: 0.5) { preferenceLabel("动作间隔", value: String(format: "%.1f 秒", model.settings.stepInterval)) }
                }
            }
            AgentCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("画面清晰度").font(.headline)
                    Picker("上传画面清晰度", selection: $model.settings.imageMaxSide) {
                        Text("标准").tag(960); Text("清晰").tag(1280); Text("精细").tag(1920)
                    }.pickerStyle(.segmented)
                    Text("更精细的画面有助于识别小字，也会增加传输与模型用量。")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }
            }
            DisclosureGroup("工具与状态显示") {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("实时活动展示任务状态", isOn: Binding(get: { model.settings.liveTaskStatus != false }, set: { model.settings.liveTaskStatus = $0 })).tint(AgentPalette.accent)
                    Text("在锁屏与支持的灵动岛中显示步骤和状态，可暂停或停止当前任务；系统可能要求先认证设备。继续、补充和工具确认请回到 App。状态 60 秒未刷新时会提示核对；不增加后台执行时间。") .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                    if !model.taskActivity.error.isEmpty { AgentNotice(text: model.taskActivity.error) }
                    Divider()
                    Toggle("启用系统工具", isOn: Binding(get: { model.settings.systemToolsEnabled == true }, set: { model.settings.systemToolsEnabled = $0; if !$0 { model.settings.toolsOnly = false } })).tint(AgentPalette.accent)
                    Toggle("仅使用系统工具", isOn: Binding(get: { model.settings.toolsOnly == true }, set: { model.settings.toolsOnly = $0 })).tint(AgentPalette.accent).disabled(model.settings.systemToolsEnabled != true)
                    Text("日历、提醒、联系人、照片元数据与本 App 闹钟。自动模式下收到明确请求即执行；首次使用需系统授权。仅工具模式无需配件和屏幕共享，无法点击其他 App。混合模式仍需鼠标与整屏共享。")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }.padding(.top, 16)
            }.font(.subheadline).agentPanel()

        }
    }
    private var floatingWindow: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "pip").font(.system(size: 44, weight: .light))
                .frame(maxWidth: .infinity).padding(.vertical, 24).accessibilityHidden(true)
            AgentCard {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("离开 App 时自动开启", isOn: Binding(get: { model.settings.autoPiPOnExit ?? false }, set: { model.settings.autoPiPOnExit = $0 }))
                        .tint(AgentPalette.accent)
                    Text("切换到其他 App 或返回桌面时，浮窗显示当前动作和任务进度。")
                        .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                }
            }
            Text("请在 iOS“设置 → 通用 → 画中画”中允许自动开启。手动关闭后，下次返回 App 再离开会重新准备。强制退出 App 时不可用。")
                .font(.footnote).foregroundStyle(AgentPalette.secondaryText)
        }
    }
    private var siri: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentPageIntro(title: "一句话，开始干活", subtitle: "嘿 Siri，让 Sela 开始干活。", icon: "waveform")
            ShortcutsLink().shortcutsLinkStyle(.automaticOutline)
                .frame(minHeight: AgentInputMetrics.height)
            AgentHelp(title: "给常用任务设置口令", text: "添加“执行手机任务”，填入固定要求，再用你习惯的口令命名。也可以让 Siri 执行当前保存的任务，或说“停止 Sela 的任务”。")
            AgentHelp(title: "用语音输入任意任务", text: "先添加“听写文本”，再添加“执行手机任务”；把“任务”参数设为听写结果，并用你习惯的口令命名。说“嘿 Siri”加口令后，就能口述任务。画面、配件和校准就绪后才会开始，否则先完成系统整屏共享；语音请求最多等待 90 秒。")
            AgentHelp(title: "任务中途暂停、接管与补充", text: "可以说：暂停 Sela 的任务、接管 Sela 的任务、给 Sela 补充要求、继续 Sela 的任务。补充先暂停再听写，加入要求后等待继续；恢复会重新观察当前画面。Sela 无法在其他 App 中常驻监听“豆包豆包”，请用 Siri 口令唤起；App 前台听写时可直接说控制词。")
            DisclosureGroup("设置你习惯的唤醒名字") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("系统设置 → 辅助功能 → 人声快捷指令，选择“语音告诉助手”或对应 Siri 请求，输入“助手助手”并按系统提示训练。")
                    Text("也可分别为暂停、接管、补充和继续设置短语。先等唤醒回应再说内容；这些入口需要解锁，并可能打开 Sela。")
                    Link("查看苹果设置说明", destination: URL(string: "https://support.apple.com/zh-hans/guide/iphone/iph7f242ea2c/ios")!).frame(minHeight: 44)
                }.font(.footnote).foregroundStyle(AgentPalette.secondaryText).padding(.top, 12)
            }.font(.subheadline).agentPanel()
            Toggle("自动朗读回复与任务结果", isOn: Binding(get: { model.settings.spokenFeedback ?? false }, set: { model.settings.spokenFeedback = $0 }))
                .tint(AgentPalette.accent).agentPanel()
            Text("本机识别中文；不支持时可输入文字或使用快捷指令听写。App 内连续对话在离开页面或进入后台后结束。") .font(.caption).foregroundStyle(AgentPalette.secondaryText)
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label(model.consentReady ? "已授权当前服务" : "尚未授权", systemImage: "hand.raised")
                        .font(.headline)
                    Text(PrivacyConsent.recipient(model.settings)).font(.title3.weight(.medium))
                    Text("AI 会接收你同意发送的画面、任务、问题、转写或文件文字及相关记录。记忆和系统工具依其开关及当前执行模式使用；自动模式直接处理明确任务，只有主动开启逐项审核时才逐次确认。")
                        .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                    Button("查看数据使用说明") { model.showPrivacyPolicy = true }.frame(minHeight: 44)
                    if model.consentReady {
                        Button("撤回 AI 数据授权", role: .destructive) { revoke = true }.foregroundStyle(.red).frame(minHeight: 44)
                    } else if model.modelReady {
                        Button("确认 AI 数据使用") { model.requestConsent() }.buttonStyle(AgentButtonStyle())
                    } else {
                        NavigationLink(value: SettingsPage.model) { Text("先连接模型服务") }.buttonStyle(AgentButtonStyle())
                    }
                }
            }
            AgentCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("本机记录").font(.headline)
                    Text("已保存 \(model.history.records.count) 个任务").font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                    DisclosureGroup("工具提交回执") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("本机保存提交记录用于防止同一任务重复创建；它独立于任务历史。清理前请核对系统中的实际结果。") .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            Button("导出工具回执") { do { receiptDocument = ArtifactDocument(data: try model.tools.exportReceipts()); exportingReceipts = true } catch { receiptError = error.localizedDescription } }.frame(minHeight: 44)
                            Button("清除工具回执", role: .destructive) { clearReceipts = true }.frame(minHeight: 44).disabled(model.engine.hasCurrentTask || model.engine.releasing)
                            if !receiptError.isEmpty { AgentNotice(text: receiptError, error: true) }
                            if !model.tools.error.isEmpty { AgentNotice(text: model.tools.error, error: true) }
                        }.padding(.top, 12)
                    }
                    Button("清除任务历史", role: .destructive) { clearHistory = true }
                        .foregroundStyle(.red).frame(minHeight: 44).disabled(model.history.records.isEmpty || model.engine.running || model.engine.releasing)
                    Text("删除本机记录不会删除服务商已接收的数据。")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                }
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentCard {
                VStack(alignment: .leading, spacing: 20) {
                    preferenceLabel("你授权的画面", value: "通过系统整屏共享观察当前页面。受保护的内容可能无法捕获。")
                    Divider()
                    preferenceLabel("你连接的配件", value: "由 AgentMouse 发送蓝牙鼠标和键盘输入。复杂页面和很小的目标仍可能影响精度。")
                    Divider()
                    preferenceLabel("每一步都重新观察", value: "动作后检查结果；需要登录、权限或人工处理时会停下来提示。")
                    Divider()
                    preferenceLabel("苹果操作指南", value: "已内置官方手册的查阅与操作规则，辅助系统导航、鼠标、键盘和 Siri 任务。当前动作模型不具备实时网页检索能力。")
                }
            }
            Text("需要 iOS 27 与兼容配件。硬件键盘可输入英文、数字和拼音，中文需要选择候选词。")
                .font(.footnote).foregroundStyle(AgentPalette.secondaryText)
        }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(AgentPalette.secondaryText)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func preferenceLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(value).font(.caption).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var inferredService: String {
        if model.settings.usesChatGPTPlan { return "chatgpt_plan" }
        let host = URLComponents(string: model.settings.endpoint)?.host ?? ""
        if host == "api.openai.com" { return "openai" }
        if host == "ark.cn-beijing.volces.com" { return "ark" }
        return "custom"
    }
    private func loadConnectionDraft() {
        // The destination may appear independently of the settings root (for
        // example a Debug review route). Populate its local draft when visible.
        apiKey = model.settings.usesChatGPTPlan ? "" : SettingsStore.apiKey(for: model.settings.endpoint)
        providerSelection = inferredService
    }
    private func chooseService(_ value: String) {
        guard value != providerSelection else { return }
        providerSelection = value; advancedConnection = false; connectionMessage = ""
        let wasPlan = model.settings.usesChatGPTPlan
        if value == "chatgpt_plan" {
            model.settings.modelAuthentication = "chatgpt_plan"
            model.settings.endpoint = ChatGPTPlanProtocol.endpoint
            model.settings.providerName = "ChatGPT 计划"
            model.settings.jsonMode = true; model.settings.legacyTokenLimit = false
            apiKey = ""; return
        }
        model.settings.modelAuthentication = nil
        switch value {
        case "openai":
            model.settings.endpoint = "https://api.openai.com/v1/chat/completions"
            if !wasPlan { model.settings.model = "gpt-4.1-mini" }; model.settings.providerName = nil
            model.settings.jsonMode = true; model.settings.legacyTokenLimit = false
        case "ark":
            model.settings.endpoint = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
            model.settings.model = ""; model.settings.providerName = nil
            model.settings.jsonMode = false; model.settings.legacyTokenLimit = true
        default:
            model.settings.endpoint = ""; model.settings.model = ""; model.settings.providerName = nil
        }
        if wasPlan { apiKey = SettingsStore.apiKey(for: model.settings.endpoint) }
        else { apiKey = ""; model.saveKey("") }
    }
    private func checkConnection() {
        checking = true; connectionMessage = ""
        Task {
            defer { checking = false }
            do {
                try await VisionClient(settings: model.settings, apiKey: apiKey).checkConnection()
                connectionFailed = false; connectionMessage = "接口连接成功。图像与动作能力会在实际任务中确认。"
            } catch { connectionFailed = true; connectionMessage = error.localizedDescription }
        }
    }
}
