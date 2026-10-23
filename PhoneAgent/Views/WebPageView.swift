import SwiftUI
import UniformTypeIdentifiers

struct WebPageView: View {
    let source: WebSearchSource
    let onUse: (WebPageExcerpt?) throws -> Void
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var savedKey = ""
    @State private var page: WebPageDocument?
    @State private var start = 0
    @State private var length = 4000
    @State private var approval = false
    @State private var showFullText = false
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error = ""
    @State private var message = ""
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    private var selected: WebPageExcerpt? { page.flatMap { try? $0.excerpt(start: start, length: length) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(source.title).font(.title2.bold())
                    Text(source.url.absoluteString).font(.footnote).textSelection(.enabled)
                    AgentHelp(title: "正文服务与数据", text: "正文提取服务：Tavily。只向固定服务发送这条链接和 Tavily Key，App 不直接访问该网页，不发送画面、语音、问题、历史或模型 Key。服务可能收费；提取结果可能缺少登录、动态页面或部分内容。")
                    DisclosureGroup("正文服务 Key") { VStack(alignment: .leading, spacing: 12) {
                    SecureField("Tavily API Key", text: $key).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().disabled(work != nil).accessibilityLabel("Tavily 正文服务 API Key")
                    Button("保存 Tavily Key") {
                        do { try WebSearchStore.saveKey(key, for: .tavily); savedKey = key; error = ""; message = key.isEmpty ? "Tavily Key 已清除" : "Tavily Key 已保存；未更改搜索服务选择" }
                        catch { self.error = error.localizedDescription }
                    }.disabled(work != nil).frame(minHeight: 44)
                    }.padding(.top, 12) }.agentPanel()
                    Button(page == nil ? "确认提取这条网页正文" : "重新提取正文") { approval = true }.buttonStyle(AgentButtonStyle()).disabled(work != nil || savedKey.isEmpty || key != savedKey)
                    if key != savedKey { Text("Key 已修改，请先保存后再提取。") .font(.caption).foregroundStyle(.secondary) }
                    if work != nil { HStack { ProgressView("正在提取正文"); Spacer(); Button("取消") { cancel() } } }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if let previous = source.pageExcerpt, page == nil {
                        Text("上次用于回答的正文片段").font(.headline)
                        Text(previous.label).font(.caption).foregroundStyle(.secondary)
                        Text(previous.text).textSelection(.enabled)
                    }
                    if let page {
                        Text("已收到 \(page.text.count) 字提取正文").font(.headline)
                        Text("接收时间：\(page.retrievedAt.formatted(date: .abbreviated, time: .standard))。不是网页发布时间，不代表完整性或真实性已经核实。") .font(.caption).foregroundStyle(.secondary)
                        Button("查看全部提取正文") { showFullText = true }.frame(minHeight: 44)
                        Button("导出提取正文 TXT") {
                            let output = source.title + "\n" + page.url.absoluteString + "\nTavily 正文接收时间：" + ISO8601DateFormatter().string(from: page.retrievedAt) + "\n提取结果可能不完整，需核对；不是网页发布时间。\n\n" + page.text
                            document = ArtifactDocument(data: Data(output.utf8)); exporting = true
                        }.frame(minHeight: 44)
                        VStack(alignment: .leading, spacing: 14) {
                            Text("选择用于回答的正文").font(.title3.bold())
                            LabeledContent("起始位置（第几字）") {
                                TextField("起始位置", value: Binding(get: { start + 1 }, set: {
                                    start = max(1, min($0, page.text.count)) - 1
                                    length = min(length, page.text.count - start)
                                }), format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100).agentField().disabled(work != nil)
                            }
                            LabeledContent("片段长度（字）") {
                                TextField("片段长度", value: Binding(get: { length }, set: {
                                    length = max(1, min($0, min(12000, page.text.count - start)))
                                }), format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100).agentField().disabled(work != nil)
                            }
                            if let selected {
                                Text(selected.label).font(.caption).foregroundStyle(.secondary)
                                Text(selected.text).textSelection(.enabled)
                                Button("使用这段正文作为来源依据") {
                                    do { try onUse(selected); dismiss() } catch { self.error = error.localizedDescription }
                                }.buttonStyle(AgentButtonStyle(primary: false)).disabled(work != nil)
                            } else {
                                Text("当前片段为空白，请调整起始位置或长度。") .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("只替换这条来源的回答依据，原搜索摘录仍保留。不会自动调用模型；回到搜索页后另行核对回答材料。最长 12000 字，当前全部模型材料还须不超过 40000 字。") .font(.caption).foregroundStyle(.secondary)
                        }.agentPanel()
                    }
                    if source.pageExcerpt != nil {
                        Button("恢复使用原搜索摘录") { do { try onUse(nil); dismiss() } catch { self.error = error.localizedDescription } }.disabled(work != nil).frame(minHeight: 44)
                    }
                    AgentHelp(title: "正文保存说明", text: "网页正文在本页内存中，离开前可导出。加入来源的片段会保留在搜索页；离开搜索页清除。失败不清除已有正文，取消不自动重试。")
                }.padding(20)
            }.navigationTitle("网页正文").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { cancel(); dismiss() } } }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .onAppear { savedKey = WebSearchStore.key(.tavily); key = savedKey }
            .onChange(of: key) { _, _ in cancel(); approval = false }
            .onChange(of: start) { _, _ in if let page { length = min(length, page.text.count - start) } }
            .onChange(of: phase) { _, value in if value != .active { cancel(); approval = false } }
            .onDisappear { cancel(); document = nil }
            .confirmationDialog("确认由 Tavily 提取这条网页？", isPresented: $approval, titleVisibility: .visible) {
                Button("同意并提取一次") { read() }
            } message: { Text("完整链接：\(source.url.absoluteString)\n接收方：https://api.tavily.com/extract\n链接中的路径与查询参数都会发送。使用 Tavily Key，只请求正文，不发送问题、画面、语音、历史、记忆或模型 Key。服务可能计费并保存请求；不会自动提取页面中的其他链接。") }
            .sheet(isPresented: $showFullText) {
                NavigationStack { ScrollView { if let page { Text(page.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) } }.navigationTitle("提取正文").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showFullText = false } } } }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: ArtifactFiles.filename(source.title) + "-正文.txt") { result in
                if case .failure(let e) = result { error = e.localizedDescription }; document = nil
            }
    }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil }
    private func read() {
        guard phase == .active, work == nil, !savedKey.isEmpty, key == savedKey else { error = "页面或 Key 已变化，请重新核对"; return }
        let token = UUID(); generation = token; let credential = savedKey; error = ""; message = ""
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                let result = try await WebPageClient(apiKey: credential).read(url: source.url)
                try Task.checkCancellation()
                guard generation == token, phase == .active, savedKey == credential else { return }
                page = result; start = 0; length = min(4000, result.text.count); message = "正文已收到，请核对后选择回答片段；未调用模型"
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}
