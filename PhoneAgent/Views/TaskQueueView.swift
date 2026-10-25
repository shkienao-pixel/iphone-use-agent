import SwiftUI
import UniformTypeIdentifiers

struct TaskQueueView: View {
    var allowsExecution = true
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stopping: UUID?
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var error = ""
    private var waiting: [QueuedPhoneTask] { model.screenQueueWaiting }
    private var ended: [QueuedPhoneTask] {
        model.taskQueue.items.filter { $0.settings.toolsOnly != true && $0.record.executionLane != "native" && !$0.resumable && $0.id != model.screenQueueCurrent?.id }
    }
    private var canStart: Bool {
        allowsExecution && !model.screenQueueBusy && model.screenQueueCount > 0 && !model.engine.releasing &&
        !model.preparingAutomatically && !model.calibrating && !model.manualBusy && !model.voicePending
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.queueStatus).font(.subheadline.weight(.medium))
                        Text("一次执行一个屏幕任务。拖动等待项调整顺序；暂停项会等待你开始，再继续后面的任务。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 4)
                    if !model.taskQueue.error.isEmpty { AgentNotice(text: model.taskQueue.error, error: true) }
                    if !model.notice.isEmpty { AgentNotice(text: model.notice) }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                if let current = model.screenQueueCurrent {
                    Section("当前任务") {
                        currentRow(current)
                            .accessibilityIdentifier("screenQueue.current")
                    }
                }
                if !waiting.isEmpty {
                    Section {
                        waitingRows(waiting)
                    } header: {
                        Text("等待执行 · \(waiting.count)")
                    } footer: {
                        Text("当前任务的位置固定。开始此项仅恢复排队；队列暂停时，请再点“开始队列”。")
                    }
                } else if model.screenQueueCurrent == nil {
                    Section {
                        AgentEmptyState(title: "还没有排队任务", detail: "需要操作手机的任务会在这里等待。你可以回到对话，继续开始新任务。", icon: "list.bullet.rectangle")
                            .accessibilityIdentifier("screenQueue.empty")
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if !ended.isEmpty {
                    Section {
                        DisclosureGroup("已结束 · \(ended.count)") {
                            ForEach(ended) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.record.title).font(.subheadline.weight(.medium))
                                        Text(item.state.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    removeButton(item)
                                }.padding(.vertical, 4)
                            }
                        }.font(.subheadline)
                    }
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .background(AgentPalette.background)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: waiting.map(\.id))
            .navigationTitle("任务队列").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("screenQueue.panel")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        do { document = ArtifactDocument(data: try model.taskQueue.exportData()); exporting = true }
                        catch { self.error = error.localizedDescription }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("导出任务队列").accessibilityIdentifier("screenQueue.export")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("screenQueue.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    if model.screenQueueBusy {
                        ProgressView("正在切换任务…").frame(maxWidth: .infinity, minHeight: 48)
                    } else if model.queueRunning || model.screenQueueCurrent?.state == .running {
                        Button("暂停队列") { model.pauseScreenQueue() }
                            .buttonStyle(AgentButtonStyle()).accessibilityIdentifier("screenQueue.pause")
                    } else {
                        Button("开始队列") { _ = model.startScreenQueue() }
                            .buttonStyle(AgentButtonStyle()).disabled(!canStart)
                            .accessibilityIdentifier("screenQueue.start")
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
                    .background(AgentPalette.background)
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Sela 任务队列.json") { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
                document = nil
            }
            .confirmationDialog("终止这项任务？", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) {
                Button("终止任务", role: .destructive) {
                    if let id = stopping { _ = model.stopScreenQueueTask(id) }
                    stopping = nil
                }.accessibilityIdentifier("screenQueue.confirmStop")
            } message: { Text("任务将停止执行，已完成的操作和任务记录会保留。") }
        }
    }

    private func currentRow(_ item: QueuedPhoneTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            rowSummary(item)
            HStack(spacing: 12) {
                if item.state == .running {
                    Button("暂停") { _ = model.pauseScreenQueueTask(item.id) }
                        .accessibilityIdentifier("screenQueue.pause." + item.id.uuidString)
                } else {
                    Button("开始") { _ = model.resumeScreenQueueTask(item.id) }
                        .disabled(!allowsExecution)
                        .accessibilityIdentifier("screenQueue.start." + item.id.uuidString)
                }
                Button("终止", role: .destructive) { stopping = item.id }
                    .accessibilityIdentifier("screenQueue.stop." + item.id.uuidString)
            }.buttonStyle(AgentButtonStyle(primary: false)).disabled(model.screenQueueBusy || model.engine.releasing)
        }.padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screenQueue.row." + item.id.uuidString)
    }

    private func waitingRows(_ items: [QueuedPhoneTask]) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            waitingRow(item, index: index)
                .moveDisabled(model.screenQueueBusy)
        }
        .onMove { offsets, destination in
            guard !model.screenQueueBusy else { return }
            // SwiftUI supplies offsets for this displayed snapshot. Submit the
            // corresponding identities; the store rejects stale membership.
            var order = items.map(\.id)
            order.move(fromOffsets: offsets, toOffset: destination)
            _ = model.reorderScreenQueueTasks(order)
        }
    }

    private func waitingRow(_ item: QueuedPhoneTask, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 24)
                rowSummary(item)
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                if item.state == .waiting {
                    Button("暂停") { _ = model.pauseScreenQueueTask(item.id) }
                        .accessibilityIdentifier("screenQueue.pause." + item.id.uuidString)
                } else {
                    Button("开始") { _ = model.resumeScreenQueueTask(item.id) }
                        .accessibilityHint("恢复等待，按当前位置依次执行")
                        .accessibilityIdentifier("screenQueue.start." + item.id.uuidString)
                }
                Button("终止", role: .destructive) { stopping = item.id }
                    .accessibilityIdentifier("screenQueue.stop." + item.id.uuidString)
                Menu {
                    Button("使用当前配置") { model.useCurrentQueueConfiguration(item.id) }
                        .disabled(model.queueRunning || model.engine.running || model.engine.releasing)
                        .accessibilityIdentifier("screenQueue.configuration." + item.id.uuidString)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 36) }
                    .accessibilityLabel(item.record.title + "的队列选项")
                    .accessibilityIdentifier("screenQueue.options." + item.id.uuidString)
                Spacer(minLength: 0)
                removeButton(item)
            }.font(.subheadline.weight(.medium)).buttonStyle(.borderless)
                .disabled(model.screenQueueBusy)
        }.padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screenQueue.row." + item.id.uuidString)
            .accessibilityAction(named: "上移") { moveAccessible(item.id, by: -1) }
            .accessibilityAction(named: "下移") { moveAccessible(item.id, by: 1) }
    }

    private func rowSummary(_ item: QueuedPhoneTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.record.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if item.record.effectiveGoal != item.record.title {
                Text(item.record.effectiveGoal).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Label(item.state.label, systemImage: item.state == .running ? "circle.dotted" : item.state == .waiting ? "clock" : "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
            if item.started { Text("已执行至第 \(item.step) 步").font(.caption).foregroundStyle(.secondary) }
            if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removeButton(_ item: QueuedPhoneTask) -> some View {
        Button(role: .destructive) { _ = model.removeScreenQueueTask(item.id) } label: {
            Image(systemName: "trash").frame(width: 36, height: 36)
        }.buttonStyle(.borderless).disabled(model.screenQueueBusy)
            .accessibilityLabel("删除" + item.record.title)
            .accessibilityIdentifier("screenQueue.remove." + item.id.uuidString)
    }

    private func moveAccessible(_ id: UUID, by offset: Int) {
        guard !model.screenQueueBusy else { return }
        var order = waiting.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        _ = model.reorderScreenQueueTasks(order)
    }
}
