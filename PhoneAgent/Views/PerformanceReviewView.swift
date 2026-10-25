import SwiftUI

/// Local review/export only. Completing a model plan never sets verified here.
struct PerformanceReviewView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @State private var draft = RunInitialConditions()
    @State private var acknowledged = false
    @State private var applied = false
    @State private var records: [RecordFile] = []
    @State private var exportURLs: [URL] = []
    @State private var loadMessage = ""
    private var locked: Bool { model.engine.running || model.engine.releasing || model.queueRunning }
    private var ready: Bool {
        [draft.taskKey, draft.comparisonKey, draft.initialPage, draft.searchState, draft.clipboardState, draft.bodyPreparation]
            .allSatisfy { let text = $0.trimmingCharacters(in: .whitespacesAndNewlines); return !text.isEmpty && text != "unknown" && text != "unspecified" && text.count <= 240 }
            && draft.connectedToMac != nil && acknowledged
    }
    private struct RecordFile: Identifiable {
        let url: URL
        let metrics: AgentRunMetrics
        var id: UUID { metrics.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("先固定起点，再比较同一任务。这里的设置用于下一次启动或恢复；每次测试前重新核对。")
                .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
            AgentCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("下一次测试的起点").font(.headline)
                    field("固定任务标识", key: \.taskKey, example: "例如 wechat-filehelper-hello-v1")
                    field("同条件对照组", key: \.comparisonKey, example: "例如 同手机同文本-第一组")
                    field("初始页面", key: \.initialPage, example: "例如 固定主屏第 1 页")
                    field("搜索状态", key: \.searchState, example: "例如 已清空搜索和历史结果")
                    field("剪贴板状态", key: \.clipboardState, example: "例如 空 / 固定测试正文已准备")
                    field("正文准备", key: \.bodyPreparation, example: "例如 不适用 / 手机产物 ID 与准备耗时")
                    Picker("是否连接 Mac", selection: Binding(get: { draft.connectedToMac.map { $0 ? 1 : 0 } ?? -1 }, set: {
                        draft.connectedToMac = $0 == -1 ? nil : $0 == 1; invalidateConfirmation()
                    })) {
                        Text("未核对").tag(-1); Text("已连接").tag(1); Text("未连接").tag(0)
                    }.pickerStyle(.menu)
                    Stepper("人工介入：\(draft.humanInterventions) 次", value: Binding(get: { draft.humanInterventions }, set: {
                        draft.humanInterventions = $0; invalidateConfirmation()
                    }), in: 0...10000)
                    Toggle("已核对这些起点与本次范围", isOn: Binding(get: { acknowledged }, set: {
                        acknowledged = $0
                        if !$0 { applied = false; model.engine.initialRunConditions = RunInitialConditions() }
                    }))
                    Button(applied ? "已设置，等待下一次任务" : "用于下一次任务") {
                        guard ready, !locked else { return }
                        var next = draft; next.confirmed = true
                        model.engine.initialRunConditions = next; applied = true
                    }.buttonStyle(AgentButtonStyle()).disabled(!ready || locked)
                    if applied { Text("若起点发生变化，请修改后重新确认。").font(.caption).foregroundStyle(AgentPalette.secondaryText) }
                }.font(.subheadline)
            }.disabled(locked)
            AgentCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("最近的运行记录").font(.headline)
                        Spacer()
                        Button("刷新", action: load).font(.subheadline)
                    }
                    Text("模型判断完成与独立正确性核验分别记录。未知和取消也保留在全部尝试中。")
                        .font(.caption).foregroundStyle(AgentPalette.secondaryText)
                    if records.isEmpty { Text("还没有可查看的本机记录。").font(.subheadline).foregroundStyle(AgentPalette.secondaryText) }
                    ForEach(Array(records.prefix(20))) { record in
                        Divider()
                        recordRow(record)
                    }
                    if !exportURLs.isEmpty {
                        ShareLink(items: exportURLs) { Label("导出全部原始记录（\(exportURLs.count)）", systemImage: "square.and.arrow.up") }
                            .font(.subheadline)
                    }
                    if !loadMessage.isEmpty { Text(loadMessage).font(.caption).foregroundStyle(AgentPalette.secondaryText) }
                }
            }
        }
        .onAppear {
            draft = model.engine.initialRunConditions; acknowledged = draft.confirmed; applied = draft.confirmed
            load()
        }
        .onChange(of: model.engine.running) { _, running in
            if running { applied = false; acknowledged = false; draft.confirmed = false }
        }
    }
    private func field(_ title: String, key: WritableKeyPath<RunInitialConditions, String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(example, text: Binding(get: {
                let value = draft[keyPath: key]; return ["unknown", "unspecified"].contains(value) ? "" : value
            }, set: { draft[keyPath: key] = String($0.prefix(240)); invalidateConfirmation() }), axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel(title)
        }
    }
    private func invalidateConfirmation() {
        acknowledged = false; applied = false; draft.confirmed = false
        model.engine.initialRunConditions = RunInitialConditions()
    }
    private func recordRow(_ record: RecordFile) -> some View {
        let run = record.metrics
        return VStack(alignment: .leading, spacing: 6) {
            Text(run.startedAt.formatted(date: .abbreviated, time: .standard)).font(.subheadline.weight(.medium))
            Text("\(outcome(run.outcome)) · \(correctness(run.correctness))").font(.subheadline)
            Text(String(format: "%.2f 秒 · 模型 %d 次", run.elapsedSeconds, run.modelRequests)).font(.caption).monospacedDigit()
            Text("App \(run.versions.appVersion) (\(run.versions.appBuild)) · \(execution(run.versions.executionKind))")
                .font(.caption).foregroundStyle(AgentPalette.secondaryText)
            Text("源码：\(run.versions.sourceRevision)").font(.caption).foregroundStyle(AgentPalette.secondaryText).textSelection(.enabled)
            ShareLink(item: record.url) { Label("导出此记录", systemImage: "square.and.arrow.up") }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func execution(_ value: RunExecutionKind) -> String {
        switch value {
        case .deviceGUI: return "手机操作记录"
        case .simulator: return "模拟器记录"
        case .offlineReplay: return "离线回放"
        case .unknown: return "来源未知"
        }
    }
    private func outcome(_ value: RunAttemptOutcome) -> String {
        switch value {
        case .completed: return "模型判断完成"
        case .partial: return "部分完成，需核对"
        case .failed: return "执行失败"
        case .unknown: return "结果未知"
        case .cancelled: return "已取消"
        }
    }
    private func correctness(_ value: RunCorrectness) -> String {
        switch value {
        case .verified: return "独立核验已通过"
        case .partial: return "仅部分核验"
        case .failed: return "正确性核验失败"
        case .unknown: return "准确性未独立核验"
        }
    }
    private func load() {
        records = []; exportURLs = []; loadMessage = ""
        guard let directory = model.engine.metricsDirectory, FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            // Export every raw attempt, including malformed/old records. The
            // report tool must reject bad data rather than lose failed samples.
            exportURLs = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var unreadable = 0
            let decoded: [RecordFile] = urls.compactMap { url in
                do { return RecordFile(url: url, metrics: try decoder.decode(AgentRunMetrics.self, from: Data(contentsOf: url))) }
                catch { unreadable += 1; return nil }
            }
            records = decoded.sorted { $0.metrics.startedAt > $1.metrics.startedAt }
            if unreadable > 0 { loadMessage = "另有 \(unreadable) 份记录无法解析，原文件已保留。" }
            if let issue = model.engine.runMetrics?.snapshot.persistenceError { loadMessage = issue }
        } catch { loadMessage = "暂时无法读取本机记录，请稍后刷新。" }
    }
}
