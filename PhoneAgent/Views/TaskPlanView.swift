import SwiftUI

struct TaskPlanView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var lines = ""
    @State private var error = ""
    @State private var original = ""
    @State private var generating = false
    @State private var request: Task<Void, Never>?
    private enum Field: Hashable { case original, items }
    private enum Prompt: String, Identifiable { case close, remove; var id: String { rawValue } }
    @FocusState private var focusedField: Field?
    @State private var initialOriginal: String?
    @State private var initialLines = ""
    @State private var prompt: Prompt?
    private var hasChanges: Bool { initialOriginal.map { original != $0 || lines != initialLines } ?? false }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("把一件复杂任务拆成几件小事。每行一个子任务，按顺序执行；完成一项后由你确认，再继续下一项。") .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("总任务与约束").font(.subheadline).foregroundStyle(.secondary)
                        TextField("描述需要完成的事情", text: $original, axis: .vertical).lineLimit(3...8).focused($focusedField, equals: .original).agentField().disabled(generating).accessibilityLabel("总任务与约束")
                    }
                    Button(generating ? "取消拆分" : "让 AI 拆分") {
                        if generating { request?.cancel(); request = nil; generating = false } else { split() }
                    }.buttonStyle(AgentButtonStyle(primary: false))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("子任务 · 每行一项").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $lines)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220, maxHeight: 360)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .items).agentField().disabled(generating)
                            .accessibilityLabel("子任务清单")
                        Text("每行写一项，可直接换行。例如：查找明天的日程、添加一条买菜提醒。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("最多 12 项，每项最多 240 字。已完成项目保留在任务记录中；暂停恢复不会从头重做。修改已完成事项请创建新任务。") .font(.footnote).foregroundStyle(.secondary)
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    Button("移除待执行清单", role: .destructive) { focusedField = nil; prompt = .remove }.frame(minHeight: 44).disabled(model.taskPlan.isEmpty)
                }.padding(20)
            }.safeAreaInset(edge: .bottom) {
                Button("使用这份清单", action: applyPlan).buttonStyle(AgentButtonStyle()).disabled(generating || lines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.horizontal, 20).padding(.vertical, 12).background(AgentPalette.background)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("组合任务").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { focusedField = nil; if hasChanges || generating { prompt = .close } else { dismiss() } } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle().onAppear {
            guard initialOriginal == nil else { return }
            lines = model.taskPlan.joined(separator: "\n")
            original = model.taskPlan.isEmpty ? model.goal : model.taskPlanOriginal
            initialOriginal = original; initialLines = lines
        }
        .interactiveDismissDisabled(hasChanges || generating)
        .onDisappear { request?.cancel() }
        .alert(item: $prompt) { value in
            switch value {
            case .close:
                return Alert(title: Text("清单尚未保存"), message: Text("继续编辑后可点底部“使用这份清单”。放弃修改也会停止正在进行的拆分。"), primaryButton: .cancel(Text("继续编辑")), secondaryButton: .destructive(Text("放弃修改")) { request?.cancel(); dismiss() })
            case .remove:
                return Alert(title: Text("移除待执行清单？"), message: Text("保留总任务与约束，移除尚未执行的子任务。"), primaryButton: .cancel(), secondaryButton: .destructive(Text("移除")) { model.removeTaskPlan(); dismiss() })
            }
        }
    }
    private func applyPlan() {
        focusedField = nil
        let items = lines.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...12).contains(items.count), items.allSatisfy({ $0.count <= 240 }) else { error = "请填写 1–12 项，每项不超过 240 字"; return }
        guard original.count <= 4000 else { error = "总任务最多 4000 字"; return }
        model.useTaskPlan(items, original: original); dismiss()
    }
    private func split() {
        guard model.modelReady, model.consentReady else { error = "请先配置并授权当前 AI 服务"; return }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, original.count <= 4000 else { error = "请填写 1–4000 字的总任务"; return }
        error = ""; generating = true
        let settings = model.settings; let key = SettingsStore.apiKey(for: settings.endpoint)
        request = Task {
            do {
                let answer = try await VisionClient(settings: settings, apiKey: key).answer(question: "请把下方用户任务拆成按顺序执行的子任务，保留约束，不增加未经要求的发送、付款、删除或共享。只返回 1–12 行，每行一个目标，不带编号、解释或代码块，每行最多 240 字。\n用户任务：" + original, frame: nil, history: [], drafting: true)
                guard !Task.isCancelled else { return }
                let items = answer.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard (1...12).contains(items.count), items.allSatisfy({ $0.count <= 240 && !$0.hasPrefix("```") }) else { throw AgentError.message("拆分结果不符合清单格式，请重试或手动填写") }
                lines = items.joined(separator: "\n"); generating = false; request = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; generating = false; request = nil } }
        }
    }
}
