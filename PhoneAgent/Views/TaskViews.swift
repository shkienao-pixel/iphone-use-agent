import SwiftUI
import UniformTypeIdentifiers

struct TaskDetailView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var controlGlass
    @State private var showActions = false
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting = false
    @State private var exporting = false
    @State private var exportDocument: ArtifactDocument?
    @State private var exportError = ""
    let id: UUID
    private var current: Bool { model.engine.currentRecord?.id == id }
    private var record: PhoneTaskRecord? { model.history.records.first { $0.id == id } ?? (current ? model.engine.currentRecord : nil) }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let record {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(record.title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Label(record.outcome.label, systemImage: record.outcome == .completed ? "checkmark.circle" : "circle.dotted")
                            .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 10)
                            .agentGlass(in: Capsule())
                        Text(record.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        if !exportError.isEmpty { AgentNotice(text: exportError, error: true) }
                        AgentCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("任务内容").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                Text(record.goal).font(.body).textSelection(.enabled)
                                ForEach(record.amendments ?? []) { addition in
                                    Divider()
                                    Text("补充 · \(addition.createdAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(addition.text).textSelection(.enabled)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(current && model.engine.running ? "正在进行" : "执行结果").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(current ? model.engine.state : record.summary).font(.title3.weight(.medium))
                            if current, let action = model.engine.pendingAction { Text(action.reason).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        if let subtasks = record.subtasks {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("子任务 · \(subtasks.filter(\.completed).count)/\(subtasks.count)").font(.headline)
                                ForEach(subtasks) { item in
                                    Label(item.goal, systemImage: item.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(item.completed ? Color.green : .secondary)
                                    if let evidence = item.evidence { Text(evidence).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.agentPanel()
                        }
                        if let approval = model.tools.pending, approval.taskID == id {
                            NavigationLink { ToolApprovalView(approval: approval) } label: {
                                Label("核对待确认的工具操作", systemImage: "checkmark.shield")
                            }.buttonStyle(AgentButtonStyle())
                        }
                        if current, !model.engine.error.isEmpty { AgentNotice(text: model.engine.error, error: true) }
                        if !model.notice.isEmpty { AgentNotice(text: model.notice) }
                        DisclosureGroup("行动记录 · \(record.logs.count) 条", isExpanded: $showActions) {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(record.logs) { log in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text("\(log.step)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 28, height: 28).background(AgentPalette.surface, in: Circle())
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack { Text(log.title).font(.subheadline.weight(.semibold)); Spacer(); Text(log.date, style: .time).font(.caption2).foregroundStyle(.tertiary) }
                                            Text(log.detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.padding(.top, 10)
                                }
                            }
                        }.font(.subheadline)
                    }.padding(20)
                } else { Text("该任务已删除").padding(20) }
            }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline).scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let record {
                    VStack(spacing: 12) {
                        if current && (model.engine.running || model.engine.releasing) { controls }
                        else if model.backgroundTasks.running(id) || model.backgroundTasks.busy(id) {
                            HStack {
                                Button("暂停") { model.pauseTask(id) }.buttonStyle(AgentButtonStyle(primary: false))
                                Button("停止", role: .destructive) { model.stopTask(id) }.buttonStyle(AgentButtonStyle(primary: false))
                            }
                        }
                        else if model.recoverableTask(id) != nil {
                            HStack(spacing: 12) {
                                Button("重试") { _ = model.retryTask(id) }.buttonStyle(AgentButtonStyle(primary: false)).accessibilityIdentifier("task.retry")
                                Button("继续任务") { _ = model.continueTask(id) }.buttonStyle(AgentButtonStyle()).accessibilityIdentifier("task.continue")
                            }.disabled(model.taskRecoveryBusy(id))
                            Text("重试重新规划，继续保留进度；已确认回执保留，未知结果先核验。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        else if !model.engine.running && !model.engine.releasing {
                            Button("用作新任务") {
                                if model.reuseTaskInNewConversation(record) {
                                    model.showAssistant = true
                                    dismiss()
                                }
                            }.buttonStyle(AgentButtonStyle())
                            if record.outcome != .completed { Text("新任务会从头规划；上次可能已部分完成，请先删去无需重做的要求。不会自动恢复旧执行。") .font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("导出任务记录", action: exportTaskRecord)
                            .accessibilityIdentifier("task.export").disabled(record == nil)
                        Button("重命名") { title = record?.title ?? ""; renaming = true }
                        Button("删除任务", role: .destructive) { deleting = true }.disabled(model.engine.running || model.engine.releasing)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("任务选项")
                }
            }
            .alert("任务名称", isPresented: $renaming) {
                TextField("名称", text: $title)
                Button("保存") {
                    if current { model.engine.renameCurrent(title) }
                    else { model.history.rename(id, title: title) }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("删除这个任务及其行动记录？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除任务", role: .destructive) { model.removeTask(id); dismiss() }
            }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                          defaultFilename: "Sela 任务-" + id.uuidString + ".json") { result in
                if case .failure(let failure) = result { exportError = failure.localizedDescription }
                exportDocument = nil
            }
    }
    private func exportTaskRecord() {
        guard let snapshot = current ? model.engine.currentRecord : record else { return }
        do {
            exportDocument = ArtifactDocument(data: try TaskRecordExport.data(record: snapshot))
            exportError = ""; exporting = true
        } catch { exportError = error.localizedDescription }
    }
    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 12) {
                if model.engine.phase == .awaitingApproval {
                    Button(model.engine.pendingAction?.kind == .complete_subtask ? "确认这项已完成" : "执行这一步") { model.engine.approve() }.buttonStyle(AgentButtonStyle())
                        .glassEffectID("approve", in: controlGlass)
                }
                if model.engine.running {
                    HStack(spacing: 12) {
                        Button("暂停任务") { model.pauseTask() }.buttonStyle(AgentButtonStyle(primary: false))
                            .glassEffectID("continue", in: controlGlass)
                            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                        Button("停止", role: .destructive) { model.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                            .glassEffectID("stop", in: controlGlass)
                    }
                    Button("接管并补充") { model.beginVoice(.supplement) }.buttonStyle(AgentButtonStyle(primary: false))
                } else if model.engine.canResume {
                    Button("补充要求") { model.beginVoice(.supplement) }.buttonStyle(AgentButtonStyle(primary: false))
                    Button(model.engine.phase == .needsUser ? "我已处理，继续任务" : "继续任务") { _ = model.continueTask(id) }.buttonStyle(AgentButtonStyle())
                        .glassEffectID("continue", in: controlGlass)
                        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                    Button("结束任务", role: .destructive) { model.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                        .glassEffectID("stop", in: controlGlass)
                } else if model.engine.releasing {
                    ProgressView("正在释放输入…").padding(16).frame(maxWidth: .infinity)
                        .agentGlass(in: RoundedRectangle(cornerRadius: 20))
                        .glassEffectID("continue", in: controlGlass)
                }
            }
        }.animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: model.engine.phase)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: model.engine.releasing)
    }
}
