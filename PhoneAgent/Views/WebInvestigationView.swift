import SwiftUI
import UniformTypeIdentifiers

private struct InvestigationApproval: Identifiable {
    let id = UUID()
    let question: String
    let rounds: Int
    let settings: WebSearchSettings
    let fingerprint: String
}
struct WebInvestigationView: View {
    let initialQuestion: String
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @FocusState private var questionFocused: Bool
    @State private var question = ""
    @State private var rounds = 3
    @State private var config = WebSearchStore.load()
    @State private var state: WebInvestigationState?
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var approval: InvestigationApproval?
    @State private var error = ""
    @State private var document: ArtifactDocument?
    @State private var exporting = false
    private var fingerprint: String { model.settings.endpoint + "|" + model.settings.model + "|" + PrivacyConsent.recipient(model.settings) + "|" + String(model.settings.responseTokenLimit) + "|" + String(model.settings.jsonMode) + "|" + String(model.settings.legacyTokenLimit) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("围绕问题，继续找依据").font(.title2.weight(.semibold))
                    Text("助手按已找到的来源提出下一轮关键词，依次检索，最后整理带原文引用的回答。你可以随时取消；研究收束不代表事实已全部核实。") .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("研究问题").font(.caption).foregroundStyle(.secondary)
                        TextField("输入希望核对的问题", text: $question, axis: .vertical).lineLimit(1...5).agentField().disabled(work != nil).focused($questionFocused).accessibilityLabel("研究问题")
                    }
                    DisclosureGroup("研究轮次与时间") { VStack(spacing: 14) {
                    Stepper("研究最多 \(rounds) 轮", value: $rounds, in: 1...3).disabled(work != nil)
                    LabeledContent("默认时间条件") { Picker("", selection: $config.freshness) { ForEach(WebSearchFreshness.allCases) { Text($0.title).tag($0) } }.labelsHidden().disabled(work != nil) }
                    }.padding(.top, 12) }.agentPanel()
                    Text("搜索接收方：\(config.provider.title)\n模型：\(model.settings.model.isEmpty ? "未配置" : model.settings.model)\n最多 \(rounds * 3) 次搜索与 \(rounds + 1) 次模型请求。关键词由模型自动提出，可能包含从来源中整理出的事实用语；只在这个问题与上限内继续。每次请求都可能消耗额度。") .font(.footnote).foregroundStyle(.secondary)
                    Button("核对并开始多轮研究") { prepare() }.buttonStyle(AgentButtonStyle()).disabled(work != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if work != nil { HStack { ProgressView(); Text(state?.phase.rawValue ?? "正在准备"); Spacer(); Button("取消研究") { cancel() } } }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if let state {
                        Text(state.question).font(.title3.bold()).textSelection(.enabled)
                        Text("\(state.phase.rawValue) · 已尝试 \(state.searches) 次搜索 / \(state.modelRequests) 次模型请求").font(.caption).foregroundStyle(.secondary)
                        if !state.message.isEmpty { Text(state.message).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(state.rounds, id: \.number) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("第 \(record.number) 轮 · \(record.decision.finish ? "建议收束" : "已完成 \(record.completedQueries)/\(record.decision.queries.count) 项")").font(.headline)
                                Text(record.decision.note).textSelection(.enabled)
                                ForEach(record.decision.queries.indices, id: \.self) { i in
                                    Text("\(i + 1). \(record.decision.queries[i].query)\n\(record.decision.queries[i].freshness.title) · \(record.decision.queries[i].reason)").font(.footnote).textSelection(.enabled)
                                }
                                Text("关键词与研究说明是模型草稿，不是事实证据。").font(.caption).foregroundStyle(.secondary)
                            }.agentPanel()
                        }
                        if let answer = state.answer, let evidence = state.evidence {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(answer.insufficient ? "依据不足，仍需核对" : "引用回答草稿").font(.title2.bold())
                                Text(answer.answer).textSelection(.enabled)
                                ForEach(answer.citations) { citation in
                                    if let source = evidence.sources.first(where: { $0.id == citation.source_id }) {
                                        Link("[\(source.id)] \(source.title)", destination: source.url).frame(minHeight: 44)
                                        Text(citation.quote).font(.footnote).textSelection(.enabled)
                                    }
                                }
                                Text("已逐字核对引用出处；来源质量、概括、日期与归因仍需人工核对。").font(.caption).foregroundStyle(.secondary)
                            }.agentPanel()
                        }
                        if let evidence = state.evidence {
                            Text("累计来源 \(evidence.sources.count) 条").font(.headline)
                            ForEach(evidence.sources) { source in
                                VStack(alignment: .leading, spacing: 10) {
                                    Link("[\(source.id)] \(source.title)", destination: source.url).font(.headline).frame(minHeight: 44)
                                    Text(source.excerpt).textSelection(.enabled)
                                    Text("日期：\(source.publishedLabel ?? "服务未提供")").font(.caption).foregroundStyle(.secondary)
                                    if let queries = source.matchedQueries { Text("来自检索：" + queries.joined(separator: "；")).font(.caption).foregroundStyle(.secondary) }
                                }.agentPanel()
                            }
                            if evidence.omitted > 0 { Text("另有 \(evidence.omitted) 条重复、无有效来源或超过 20 条累计上限的结果未使用。") .font(.caption).foregroundStyle(.secondary) }
                        }
                        Button("导出研究记录与回答 TXT") { document = ArtifactDocument(data: Data(state.report.utf8)); exporting = true }.disabled(work != nil).frame(minHeight: 44)
                    }
                    Text("独立搜索 Key 只给搜索服务；模型收到本次问题、轮次与时间条件、已尝试的关键词和累计来源摘录。没有截图、音频、聊天历史或本机记忆。网页正文不会自动读取；不执行手机动作。结果只保留在本页内存，离开前可导出。后台 / 离开停止，重启不自动恢复研究。") .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("多轮研究").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { questionFocused = false } }
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { cancel(); dismiss() } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .onAppear { if question.isEmpty { question = initialQuestion }; config = WebSearchStore.load() }
            .onChange(of: phase) { _, value in if value != .active { cancel() } }
            .onChange(of: fingerprint) { _, _ in cancel() }
            .onChange(of: model.consentReady) { _, _ in cancel() }
            .onChange(of: question) { _, _ in approval = nil }
            .onChange(of: rounds) { _, _ in approval = nil }
            .onChange(of: config) { _, _ in approval = nil }
            .onDisappear { cancel(); state = nil; document = nil }
            .sheet(item: $approval) { value in approvalView(value) }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "多轮研究.txt") { result in if case .failure(let e) = result { error = e.localizedDescription }; document = nil }
    }
    private func prepare() {
        questionFocused = false
        do {
            let q = try WebSearchBatch.validatedQuery(question)
            guard model.modelReady, model.consentReady, !WebSearchStore.key(config.provider).isEmpty else { throw AgentError.message("请先保存模型与独立搜索 Key，并确认当前 AI 数据授权") }
            error = ""; approval = .init(question: q, rounds: rounds, settings: config, fingerprint: fingerprint)
        } catch { self.error = error.localizedDescription }
    }
    private func approvalView(_ value: InvestigationApproval) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("确认这次多轮研究").font(.title.bold())
                    Text(value.question).font(.headline).textSelection(.enabled)
                    Text("搜索接收方：\(value.settings.provider.title)\n\(value.settings.provider.endpoint.absoluteString)\n模型接收方：\(PrivacyConsent.recipient(model.settings))\n\(model.settings.endpoint)").font(.footnote).textSelection(.enabled)
                    Text("授权助手在这个问题范围内自动提出下一轮关键词、依次检索，并生成一次引用回答。最多 \(value.rounds) 轮、\(value.rounds * 3) 次搜索与 \(value.rounds + 1) 次模型请求；可能提前结束。每次请求可能计费，来源不足时不保证得到完整答案。")
                    Text("本次问题、轮次 / 时间条件、已尝试关键词及累计来源摘录发给模型。模型提出的关键词和各项时间条件发给搜索服务；关键词可能包含来源里的事实用语。独立搜索 Key 只发给搜索服务，模型 Key 只发给模型接口。没有截图、音频、聊天历史、记忆或原文件；不自动提取正文、跟随网页链接或执行手机动作。") .font(.footnote)
                    Text("可随时取消。错误 / 后台 / 页面离开停止追加请求并保留已返回来源，不自动重试；服务已收到的数据无法撤回。接收方可能保存数据，请按其政策核对。记录只存本页内存，另行导出才保存。") .font(.footnote).foregroundStyle(.secondary)
                    Button("同意并开始这次研究") { approval = nil; start(value) }.buttonStyle(AgentButtonStyle())
                }.padding(20)
            }.navigationTitle("核对研究范围").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { approval = nil } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private func cancel() {
        generation = UUID(); work?.cancel(); work = nil; approval = nil
        if var current = state, [.planning, .searching, .answering].contains(current.phase) { current.phase = .cancelled; current.message = "已停止追加请求，已返回来源保留；无法撤回已发送的数据"; state = current }
    }
    private func start(_ value: InvestigationApproval) {
        guard phase == .active, work == nil, rounds == value.rounds, config == value.settings, fingerprint == value.fingerprint, model.modelReady, model.consentReady,
              (try? WebSearchBatch.validatedQuery(question)) == value.question else { error = "问题、配置或授权已变化，请重新核对"; return }
        let token = UUID(); generation = token; let settings = model.settings
        let searchKey = WebSearchStore.key(value.settings.provider); let modelKey = SettingsStore.apiKey(for: settings.endpoint)
        error = ""
        work = Task {
            defer { if generation == token { work = nil } }
            let authorized = { generation == token && phase == .active && fingerprint == value.fingerprint && model.consentReady && rounds == value.rounds && config == value.settings && (try? WebSearchBatch.validatedQuery(question)) == value.question && WebSearchStore.key(value.settings.provider) == searchKey && SettingsStore.apiKey(for: settings.endpoint) == modelKey }
            do {
                _ = try await WebInvestigationRunner(settings: value.settings, searchKey: searchKey).run(question: value.question, maxRounds: value.rounds, authorized: authorized,
                    decide: { try await VisionClient(settings: settings, apiKey: modelKey).researchDecision(context: $0) },
                    summarize: { try await VisionClient(settings: settings, apiKey: modelKey).searchAnswer(batch: $0) },
                    progress: { if generation == token { state = $0 } })
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}
