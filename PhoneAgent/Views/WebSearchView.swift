import SwiftUI
import UniformTypeIdentifiers

struct WebSearchSettingsView: View {
    var embedded = false
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keyFocused: Bool
    @State private var savedConfig = WebSearchStore.load()
    @State private var savedKey = ""
    @State private var confirmingDiscard = false
    @State private var pendingProvider: WebSearchProvider?
    private var hasChanges: Bool { config != savedConfig || key != savedKey }
    @State private var config = WebSearchStore.load()
    @State private var key = ""
    @State private var message = ""
    @State private var failed = false
    var body: some View {
        Group {
            if embedded { content } else { ScrollView { content } }
        }.onAppear { savedConfig = config; savedKey = WebSearchStore.key(config.provider); key = savedKey }
            .onChange(of: config.provider) { _, value in savedKey = WebSearchStore.key(value); key = savedKey; message = "" }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(hasChanges)
            .navigationBarBackButtonHidden(embedded && hasChanges)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { keyFocused = false } }
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { requestClose() } }
                } else if hasChanges {
                    ToolbarItem(placement: .topBarLeading) { Button { requestClose() } label: { Image(systemName:"chevron.left") }.accessibilityLabel("返回设置") }
                }
            }
            .alert("放弃未保存的搜索配置？", isPresented: $confirmingDiscard) {
                Button("继续编辑", role: .cancel) { pendingProvider = nil }
                Button("放弃修改", role: .destructive) {
                    if let provider = pendingProvider { pendingProvider = nil; config.provider = provider }
                    else { finishClose() }
                }
            } message: {
                Text(pendingProvider == nil ? "当前修改还没有保存。继续编辑后可保存；离开会放弃本页修改。" : "当前服务的 Key 已修改但尚未保存。切换服务会放弃这段输入，其他配置继续保留。")
            }
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                AgentPageIntro(title: "连接搜索服务", subtitle: "使用独立搜索 Key，查找有出处的信息。", icon: "globe")
                AgentCard {
                    VStack(alignment: .leading, spacing: 18) {
                        LabeledContent("搜索服务") { Picker("", selection: Binding(get: { config.provider }, set: { selectProvider($0) })) { ForEach(WebSearchProvider.allCases) { Text($0.title).tag($0) } }.labelsHidden() }
                        LabeledContent("默认时间范围") { Picker("", selection: $config.freshness) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }.labelsHidden() }
                        Text(config.provider.endpoint.absoluteString).font(.caption).textSelection(.enabled).foregroundStyle(AgentPalette.secondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("搜索服务 API Key").font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            SecureField("填写当前服务的 Key", text: $key, prompt: Text("填写当前服务的 Key").foregroundStyle(AgentPalette.placeholder)).textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never).agentField()
                                .accessibilityLabel("搜索服务 API Key").focused($keyFocused)
                        }
                    }
                }
                Button("保存搜索配置") {
                    do { try WebSearchStore.saveKey(key, for: config.provider); WebSearchStore.save(config); savedConfig = config; savedKey = key; keyFocused = false; failed = false; message = key.isEmpty ? "配置已保存，当前服务的搜索 Key 已清除" : "搜索配置已保存" }
                    catch { failed = true; message = error.localizedDescription }
                }.buttonStyle(AgentButtonStyle())
                if !message.isEmpty { AgentNotice(text: message, error: failed) }
                Link("查看服务的官方说明", destination: config.provider.documentation).frame(minHeight: 44)
                AgentHelp(title: "数据与额度说明", text: "模型规划会发送本次问题、默认时间条件和当前时间；不会自动搜索。搜索会发送检索词、时间筛选和认证 Key，不发送画面、语音、对话历史或本机记忆。点击基于来源回答时，问题、已确认的计划与完成数量，以及展示的搜索摘录或你选中的正文片段会发给当前已授权的模型。每项搜索分别消耗额度，请核对账户额度和服务政策。")
                AgentHelp(title: "配置与时间条件", text: "清空 Key 后保存可停用当前搜索服务；切换服务不会复用另一服务的 Key。保存配置不会自动发起请求。时间筛选由服务处理，不能保证每条结果都有可靠发布时间。")
            }.padding(embedded ? 0 : 24)
    }
    private func selectProvider(_ provider: WebSearchProvider) {
        guard provider != config.provider else { return }
        keyFocused = false
        if key != savedKey { pendingProvider = provider; confirmingDiscard = true }
        else { config.provider = provider }
    }
    private func requestClose() {
        keyFocused = false; pendingProvider = nil
        if hasChanges { confirmingDiscard = true } else { finishClose() }
    }
    private func finishClose() { if let onClose { onClose() } else { dismiss() } }
}

private struct SearchApproval: Identifiable {
    enum Kind { case search, plan, research, answer }
    let id = UUID()
    let kind: Kind
    let query: String
    let config: WebSearchSettings
    let batch: WebSearchBatch?
    let modelFingerprint: String
    var plan: WebSearchPlan? = nil
}
private struct PageReadTarget: Identifiable {
    let id = UUID()
    let batchID: UUID
    let source: WebSearchSource
}

struct WebSearchView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var config = WebSearchStore.load()
    @State private var query = ""
    @State private var batch: WebSearchBatch?
    @State private var answer: WebSearchAnswer?
    @State private var plan: WebSearchPlan?
    @State private var planQuestion = ""
    @State private var error = ""
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var state = ""
    @FocusState private var focusedField: String?
    @State private var showInvestigation = false
    @State private var showSettings = false
    @State private var approval: SearchApproval?
    @State private var pageTarget: PageReadTarget?
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    private var fingerprint: String { model.settings.endpoint + "|" + model.settings.model + "|" + PrivacyConsent.recipient(model.settings) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AgentPageIntro(title: "想了解什么？", subtitle: "搜索、核对来源，再整理答案。", icon: "magnifyingglass")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("检索问题或关键词").font(.caption).foregroundStyle(.secondary)
                        TextField("例如：今天的科技新闻", text: $query, axis: .vertical).lineLimit(1...5).agentField().disabled(work != nil).focused($focusedField, equals: "query").accessibilityLabel("检索问题或关键词")
                    }
                    LabeledContent("时间范围") { Picker("", selection: $config.freshness) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }.labelsHidden().disabled(work != nil) }
                    Text("当前搜索服务：\(config.provider.title)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                    Button("核对检索词") { prepareSearch() }.buttonStyle(AgentButtonStyle()).disabled(work != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("让 AI 制定检索计划") { preparePlan() }.buttonStyle(AgentButtonStyle(primary: false)).disabled(work != nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button { cancel(); approval = nil; showInvestigation = true } label: { Label("多轮研究", systemImage: "sparkle.magnifyingglass") }.frame(minHeight: 44).disabled(work != nil)
                    if let plan {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("检索计划草稿").font(.title3.bold())
                            ForEach(plan.queries.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("第 \(index + 1) 项 · \(plan.queries[index].reason)").font(.footnote).foregroundStyle(.secondary)
                                    Text("检索词").font(.caption).foregroundStyle(.secondary)
                                    TextField("检索词", text: planQuery(index), axis: .vertical).lineLimit(1...4).agentField().accessibilityLabel("第 \(index + 1) 项检索词").focused($focusedField, equals: "plan.\(index)")
                                    Picker("第 \(index + 1) 项时间范围", selection: planFreshness(index)) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }
                                    if plan.queries.count > 1 { Button("移除此项", role: .destructive) { if self.plan?.queries.indices.contains(index) == true { self.plan?.queries.remove(at: index) } }.frame(minHeight: 44) }
                                }
                            }
                            if !plan.note.isEmpty { Text(plan.note).font(.footnote).textSelection(.enabled) }
                            Text("可修改关键词和时间范围。确认后依次搜索 \(plan.queries.count) 次，每项都会消耗搜索额度；不会自动增加检索或调用模型回答。") .font(.caption).foregroundStyle(.secondary)
                            Button("核对计划并检索") { prepareResearch() }.buttonStyle(AgentButtonStyle(primary: false))
                        }.agentPanel().disabled(work != nil)
                    }
                    if work != nil { HStack { ProgressView(); Text(state); Spacer(); Button("取消") { cancel() } } }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if let batch {
                        Text("检索：\(batch.query)").font(.headline).textSelection(.enabled)
                        Text("\(batch.provider.title) · \(batch.retrievedAt.formatted(date: .abbreviated, time: .standard)) · \(batch.freshnessSummary)").font(.caption).foregroundStyle(.secondary)
                        if let applied = batch.plan {
                            Text("计划已完成 \(batch.completedQueries ?? 0)/\(applied.queries.count) 项\((batch.completedQueries ?? 0) < applied.queries.count ? " · 只有已返回的部分来源，尚未完成全部检索" : "")").font(.footnote).foregroundStyle(.secondary)
                        }
                        if batch.sources.isEmpty { Text("没有可用的网页摘录。可调整关键词或时间范围后重试。") }
                        else {
                            Text("默认使用搜索摘录。可另行确认提取一条网页正文，并核对选择回答片段；提取结果不保证包含网页全部内容。点击链接由你打开。") .font(.caption).foregroundStyle(.secondary)
                            ForEach(batch.sources) { source in
                                VStack(alignment: .leading, spacing: 10) {
                                    Link("[\(source.id)] \(source.title)", destination: source.url).font(.headline).frame(minHeight: 44, alignment: .leading)
                                    Text(source.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                                    if let matched = source.matchedQueries { Text("来自：" + matched.joined(separator: "；")).font(.caption).foregroundStyle(.secondary) }
                                    Text(source.excerpt).textSelection(.enabled)
                                    Text("服务标注日期：\(source.publishedLabel ?? "未提供")\(source.excerptShortened ? " · 摘录已缩短" : "")").font(.caption).foregroundStyle(.secondary)
                                    if let selected = source.pageExcerpt {
                                        Text("当前回答依据：所选网页正文").font(.headline)
                                        Text(selected.label).font(.caption).foregroundStyle(.secondary)
                                        Text(selected.text).textSelection(.enabled)
                                    }
                                    Button(source.pageExcerpt == nil ? "读取网页正文" : "查看 / 调整正文依据") { pageTarget = .init(batchID: batch.id, source: source) }.disabled(work != nil).frame(minHeight: 44)
                                }.agentPanel()
                            }
                            if batch.omitted > 0 { Text("另有 \(batch.omitted) 条重复、无有效链接 / 摘录或超出数量的结果未使用。") .font(.caption).foregroundStyle(.secondary) }
                            Button("基于这些来源回答") { prepareAnswer(batch) }.buttonStyle(AgentButtonStyle(primary: false)).disabled(work != nil)
                        }
                        if let answer {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(answer.insufficient ? "来源不足，需继续核对" : "来源整理草稿").font(.title3.bold())
                                Text(answer.answer).textSelection(.enabled)
                                ForEach(answer.citations) { c in
                                    if let source = batch.sources.first(where: { $0.id == c.source_id }) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Link("[\(c.source_id)] 引用依据 · \(source.title)", destination: source.url).frame(minHeight: 44)
                                            Text(c.quote).font(.footnote).textSelection(.enabled)
                                        }
                                    }
                                }
                                Text("已核对引用来自所选依据（搜索摘录或正文片段）；概括、日期和事实仍需人工核对。链接存在或检索成功不代表来源可信。") .font(.caption).foregroundStyle(.secondary)
                            }.agentPanel()
                        }
                        Button("导出来源与回答") { export(batch) }.disabled(work != nil).frame(minHeight: 44)
                    }
                    AgentHelp(title: "结果保存说明", text: "结果和回答只留在当前页面内存。离开页面前可导出；离开或后台会取消处理，但无法撤回服务已收到的请求。")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("联网检索").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focusedField = nil } }
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { cancel(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { cancel(); approval = nil; showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("搜索配置") }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .sheet(isPresented: $showInvestigation) { WebInvestigationView(initialQuestion: query) }
            .sheet(isPresented: $showSettings, onDismiss: refreshConfig) {
                NavigationStack { WebSearchSettingsView(onClose: { showSettings = false }).navigationTitle("搜索配置").navigationBarTitleDisplayMode(.inline) }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .sheet(item: $approval) { snapshot in approvalView(snapshot) }
            .sheet(item: $pageTarget) { target in
                WebPageView(source: target.source) { excerpt in
                    guard phase == .active, work == nil, let current = batch, current.id == target.batchID else { throw AgentError.message("当前来源已变化，请返回后重新选择") }
                    batch = try current.usingPage(sourceID: target.source.id, excerpt: excerpt); answer = nil
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "联网检索.txt") { result in
                if case .failure(let e) = result { error = e.localizedDescription }; document = nil
            }
            .onChange(of: phase) { _, value in if value != .active { cancel(); approval = nil } }
            .onChange(of: query) { _, _ in cancel(); approval = nil; plan = nil; planQuestion = "" }
            .onChange(of: fingerprint) { _, _ in cancel(); approval = nil; pageTarget = nil; answer = nil; plan = nil; planQuestion = "" }
            .onChange(of: model.consentReady) { _, _ in cancel(); approval = nil; pageTarget = nil; answer = nil; plan = nil; planQuestion = "" }
            .onDisappear { cancel(); batch = nil; answer = nil; plan = nil }
    }
    private func approvalView(_ value: SearchApproval) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(value.kind == .plan ? "确认制定检索计划" : value.kind == .research ? "确认全部检索项" : value.kind == .search ? "确认这次搜索" : "确认整理来源").font(.title.bold())
                    Text(value.kind == .search || value.kind == .research ? "接收方：\(value.config.provider.title)\n\(value.config.provider.endpoint.absoluteString)" : "接收方：\(PrivacyConsent.recipient(model.settings))\n\(model.settings.endpoint)").font(.footnote).textSelection(.enabled)
                    Text(value.kind == .plan ? "以下问题、默认时间条件和当前时间将发送给模型，生成可编辑的计划，会消耗一次模型请求额度。本步骤不会搜索。" : value.kind == .research ? "以下每项关键词与时间条件会依次发给搜索服务，每项分别消耗额度。可以中途取消，但无法撤回已发送的请求。不会自动追加查询或整理回答。" : value.kind == .search ? "以下检索词和时间筛选将发送给搜索服务，并消耗其账户额度。不会发送画面、语音、历史或记忆。" : "问题、以下计划与完成数量（如有）和全部所选来源依据将发送给当前模型，会消耗模型额度。不会发送搜索 Key、画面、语音、对话历史或记忆。")
                    Text(value.query).font(.headline).textSelection(.enabled)
                    if let plan = value.plan {
                        ForEach(plan.queries.indices, id: \.self) { i in Text("\(i + 1). \(plan.queries[i].query)\n\(plan.queries[i].freshness.title) · \(plan.queries[i].reason)").textSelection(.enabled) }
                    } else { Text(value.config.freshness.title).font(.caption) }
                    if let batch = value.batch { Text(batch.referenceText).font(.footnote).textSelection(.enabled) }
                    Text("接收方可能保存请求并继续处理数据，请按其政策了解保存和删除方式。") .font(.footnote).foregroundStyle(.secondary)
                    Text("不发送画面、语音、对话历史或本机记忆；搜索 Key 只发给搜索服务。") .font(.caption).foregroundStyle(.secondary)
                    Button(value.kind == .plan ? "同意并生成一次计划" : value.kind == .research ? "同意并执行以上检索" : value.kind == .search ? "同意并搜索一次" : "同意并整理一次") { approval = nil; execute(value) }.buttonStyle(AgentButtonStyle())
                }.padding(20)
            }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { approval = nil } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func refreshConfig() {
        let latest = WebSearchStore.load()
        if latest != config { cancel(); batch = nil; answer = nil }
        config = latest
    }
    private func prepareSearch() {
        focusedField = nil
        do {
            let q = try WebSearchBatch.validatedQuery(query)
            guard !WebSearchStore.key(config.provider).isEmpty else { error = "请先在搜索配置中保存搜索 Key"; showSettings = true; return }
            error = ""; approval = SearchApproval(kind: .search, query: q, config: config, batch: nil, modelFingerprint: fingerprint)
        } catch { self.error = error.localizedDescription }
    }
    private func planQuery(_ index: Int) -> Binding<String> {
        Binding(get: { guard let current = plan, current.queries.indices.contains(index) else { return "" }; return current.queries[index].query }, set: { if plan?.queries.indices.contains(index) == true { plan?.queries[index].query = $0 } })
    }
    private func planFreshness(_ index: Int) -> Binding<WebSearchFreshness> {
        Binding(get: { guard let current = plan, current.queries.indices.contains(index) else { return .any }; return current.queries[index].freshness }, set: { if plan?.queries.indices.contains(index) == true { plan?.queries[index].freshness = $0 } })
    }
    private func preparePlan() {
        focusedField = nil
        do {
            let q = try WebSearchBatch.validatedQuery(query)
            guard model.modelReady, model.consentReady else { error = "请先保存模型并确认当前 AI 数据授权"; return }
            error = ""; approval = .init(kind: .plan, query: q, config: config, batch: nil, modelFingerprint: fingerprint)
        } catch { self.error = error.localizedDescription }
    }
    private func prepareResearch() {
        focusedField = nil
        do {
            guard let plan, planQuestion == (try WebSearchBatch.validatedQuery(query)) else { throw AgentError.message("问题已变化，请重新制定计划") }
            try plan.validate()
            guard !WebSearchStore.key(config.provider).isEmpty else { error = "请先保存搜索 Key"; showSettings = true; return }
            error = ""; approval = .init(kind: .research, query: planQuestion, config: config, batch: nil, modelFingerprint: fingerprint, plan: plan)
        } catch { self.error = error.localizedDescription }
    }
    private func prepareAnswer(_ batch: WebSearchBatch) {
        focusedField = nil
        guard model.modelReady, model.consentReady else { error = "请先在模型设置中保存模型并确认当前 AI 数据授权"; return }
        error = ""; approval = SearchApproval(kind: .answer, query: batch.query, config: config, batch: batch, modelFingerprint: fingerprint)
    }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil; state = "" }
    private func execute(_ value: SearchApproval) {
        guard work == nil, phase == .active, config == value.config else { error = "页面或搜索配置已变化，请重新确认"; return }
        if value.kind == .search || value.kind == .research {
            guard (try? WebSearchBatch.validatedQuery(query)) == value.query else { error = "检索词已变化，请重新确认"; return }
            if value.kind == .research {
                guard let approved = value.plan, approved == plan, planQuestion == value.query, (try? approved.validate()) != nil else { error = "计划已变化，请重新核对"; return }
            }
        } else if value.kind == .plan {
            guard value.modelFingerprint == fingerprint, model.modelReady, model.consentReady, (try? WebSearchBatch.validatedQuery(query)) == value.query else { error = "问题、模型或授权已变化，请重新确认"; return }
        } else {
            guard value.modelFingerprint == fingerprint, model.consentReady, value.batch?.id == batch?.id else { error = "模型、授权或来源已变化，请重新确认"; return }
        }
        let token = UUID(); generation = token
        let settings = model.settings
        let key = value.kind == .search || value.kind == .research ? WebSearchStore.key(value.config.provider) : SettingsStore.apiKey(for: settings.endpoint)
        state = value.kind == .plan ? "正在制定检索计划" : value.kind == .search || value.kind == .research ? "正在检索来源" : "正在整理来源"; error = ""
        work = Task {
            defer { if generation == token { work = nil; state = "" } }
            var completed = 0
            do {
                if value.kind == .search {
                    let result = try await WebSearchClient(settings: value.config, apiKey: key).search(query: value.query)
                    try Task.checkCancellation()
                    guard generation == token, phase == .active, config == value.config else { return }
                    batch = result; answer = nil
                } else if value.kind == .plan {
                    let result = try await VisionClient(settings: settings, apiKey: key).searchPlan(question: value.query, freshness: value.config.freshness)
                    try Task.checkCancellation()
                    guard generation == token, phase == .active, fingerprint == value.modelFingerprint, model.consentReady, (try? WebSearchBatch.validatedQuery(query)) == value.query else { return }
                    plan = result; planQuestion = value.query
                } else if value.kind == .research, let approved = value.plan {
                    _ = try await WebResearchClient(settings: value.config, apiKey: key).search(question: value.query, plan: approved) { partial in
                        guard generation == token, phase == .active, config == value.config else { return }
                        completed = partial.completedQueries ?? 0; batch = partial; answer = nil
                        state = "已完成 \(completed)/\(approved.queries.count) 项检索"
                    }
                } else if let source = value.batch {
                    let result = try await VisionClient(settings: settings, apiKey: key).searchAnswer(batch: source)
                    try Task.checkCancellation()
                    guard generation == token, phase == .active, fingerprint == value.modelFingerprint, model.consentReady, batch?.id == source.id else { return }
                    answer = result
                }
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription + (completed > 0 ? "。本次已完成 \(completed) 项，已返回来源保留；未继续后续检索" : "") } }
        }
    }
    private func export(_ batch: WebSearchBatch) {
        var text = batch.referenceText
        if let answer { text += "\n\n模型整理草稿\(answer.insufficient ? "（来源不足）" : "")\n" + answer.answer + "\n\n" + answer.citations.map { "[\($0.source_id)] 引用：\($0.quote)" }.joined(separator: "\n") }
        text += "\n\n以上仅为搜索摘录与模型草稿，引用核对不保证事实 / 归因正确。\n"
        document = ArtifactDocument(data: Data(text.utf8)); exporting = true
    }
}
