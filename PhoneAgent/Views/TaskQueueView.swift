import SwiftUI
import UniformTypeIdentifiers

struct TaskQueueView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clear = false
    @State private var removing: UUID?
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var error = ""
    private var locked: Bool { model.queueRunning || model.queueSwitching || model.engine.releasing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("按顺序完成任务").font(.title2.weight(.semibold)); Spacer()
                    Menu {
                        Button("导出队列") {
                            do { document = ArtifactDocument(data: try model.taskQueue.exportData()); exporting = true }
                            catch { self.error = error.localizedDescription }
                        }
                        Button("清除队列", role: .destructive) { clear = true }.disabled(locked || model.engine.running)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.buttonStyle(.glass).accessibilityLabel("队列选项")
                }
                Text(model.queueStatus).font(.subheadline.weight(.medium))
                AgentHelp(title: "队列如何运行", text: "完成一项后按顺序继续。插队会保存原任务，优先任务完成后从新画面恢复。暂停、需你处理或发生错误时，整个队列等待确认。重新打开 App 后不会自动运行。仅在前台开启下一项；已执行操作不会因移除队列而撤销。")
                if !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("首页草稿").font(.subheadline.weight(.semibold))
                        Text(model.goal).font(.subheadline).lineLimit(3).foregroundStyle(.secondary)
                        Button("加入首页草稿") { model.enqueueDraft() }
                            .buttonStyle(AgentButtonStyle(primary: false))
                            .disabled(locked || model.voicePending || model.calibrating || model.manualBusy || model.executor.calibrationInProgress || model.taskQueue.items.count >= 20)
                        Text("只加入队列；点“运行队列”后才开始执行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.agentPanel()
                }
                if !model.notice.isEmpty { AgentNotice(text: model.notice) }
                if !model.taskQueue.error.isEmpty { AgentNotice(text: model.taskQueue.error, error: true) }
                if !error.isEmpty { AgentNotice(text: error, error: true) }
                if model.taskQueue.items.isEmpty {
                    AgentEmptyState(title: "还没有排队任务", detail: "在主页填写任务，再加入队列。最多保留 20 项。", icon: "list.bullet")
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(model.taskQueue.items.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, index: index)
                        }
                    }
                }
            }.padding(20)
        }.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3), value: model.taskQueue.items.map(\.id))
            .safeAreaBar(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    if model.queueSwitching { ProgressView("正在切换任务…").frame(maxWidth: .infinity, minHeight: 48) }
                    else if model.queueRunning { Button("暂停队列") { model.pauseQueue() }.buttonStyle(AgentButtonStyle()) }
                    else { Button("运行队列") { model.runTaskQueue() }.buttonStyle(AgentButtonStyle()).disabled(model.taskQueue.pendingCount == 0 || model.engine.releasing || model.calibrating || model.manualBusy || model.voicePending) }
                }.padding(.horizontal, 24).padding(.vertical, 10)
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Phone Agent 任务队列.json") { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }; document = nil
            }
            .confirmationDialog("清除本机任务队列？", isPresented: $clear, titleVisibility: .visible) {
                Button("清除队列", role: .destructive) { model.clearTaskQueue() }
            } message: { Text("删除等待项与保存的进度，不会撤销手机上已经执行的操作，也不会删除任务历史和工具回执。当前已暂停的任务仍可在主页手动继续。") }
            .confirmationDialog("移除此队列任务？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("移除", role: .destructive) { if let id = removing { model.removeQueuedTask(id) }; removing = nil }
            } message: { Text("已执行的实际操作和任务历史不会撤销。") }
    }
    private func queueRow(_ item: QueuedPhoneTask, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, height: 24)
                Text(item.record.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu {
                    Button("移到上一项") { model.moveQueuedTask(item.id, by: -1) }.disabled(locked || index == 0)
                    Button("移到下一项") { model.moveQueuedTask(item.id, by: 1) }.disabled(locked || index == model.taskQueue.items.count - 1)
                    Button("使用当前配置") { model.useCurrentQueueConfiguration(item.id) }.disabled(locked || !item.resumable || model.engine.running)
                    Button("移除", role: .destructive) { removing = item.id }.disabled(locked || (model.engine.currentRecord?.id == item.id && model.engine.hasCurrentTask))
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("\(item.record.title)的队列选项")
            }
            Text(item.record.effectiveGoal).font(.subheadline).lineLimit(4)
            Label(item.state.label, systemImage: item.state == .completed ? "checkmark.circle" : item.state == .running ? "circle.dotted" : "clock")
                .font(.caption).foregroundStyle(item.state == .completed ? Color.green : .secondary)
            Text("\(item.settings.toolsOnly == true ? "仅系统工具" : "视觉操控") · \(PrivacyConsent.recipient(item.settings)) · \(item.settings.model)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if item.started { Text("已执行至第 \(item.step) 步 · \((item.record.subtasks ?? []).filter(\.completed).count) 个子任务已确认").font(.caption).foregroundStyle(.secondary) }
            if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if item.resumable && item.state != .running {
                Button(model.engine.running ? "优先执行这项" : item.started ? "核对结果后继续这项" : "执行这项") { model.runTaskQueue(first: item.id) }
                    .buttonStyle(AgentButtonStyle(primary: false))
                    .disabled(model.queueSwitching || model.engine.releasing || model.calibrating || model.manualBusy || model.voicePending)
            }
        }.agentPanel()
    }
}
