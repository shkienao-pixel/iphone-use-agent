import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selectedDestination: WorkspaceDestination
    let screen: TaskScreen
    let displayedRecord: PhoneTaskRecord?
    @Binding var searchText: String
    @Binding var sidebarSearchExpanded: Bool
    let onNavigate: (WorkspaceDestination) -> Void
    let onTaskDetail: (UUID) -> Void
    let onPreparation: () -> Void
    let onOpenConversation: (PhoneTaskRecord) -> Void
    let onNewConversation: () -> Void

    private var filteredTasks: [PhoneTaskRecord] {
        guard !searchText.isEmpty else { return model.history.records }
        return model.history.records.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.effectiveGoal.localizedCaseInsensitiveContains(searchText) }
    }
    private var groupedHistory: [(title: String, records: [PhoneTaskRecord])] {
        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        var today: [PhoneTaskRecord] = []
        var yesterday: [PhoneTaskRecord] = []
        var pastWeek: [PhoneTaskRecord] = []
        var older: [PhoneTaskRecord] = []
        for record in filteredTasks {
            if calendar.isDateInToday(record.createdAt) {
                today.append(record)
            } else if calendar.isDateInYesterday(record.createdAt) {
                yesterday.append(record)
            } else if record.createdAt >= sevenDaysAgo {
                pastWeek.append(record)
            } else {
                older.append(record)
            }
        }
        var sections: [(title: String, records: [PhoneTaskRecord])] = []
        if !today.isEmpty { sections.append(("今天", today)) }
        if !yesterday.isEmpty { sections.append(("昨天", yesterday)) }
        if !pastWeek.isEmpty { sections.append(("过去 7 天", pastWeek)) }
        if !older.isEmpty { sections.append(("更早", older)) }
        return sections
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Phone Agent").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) {
                        sidebarSearchExpanded.toggle()
                        if !sidebarSearchExpanded { searchText = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .agentGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(AgentPressStyle())
                .accessibilityLabel(sidebarSearchExpanded ? "收起搜索" : "搜索历史任务")
            }
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 6)

            if sidebarSearchExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    TextField("搜索历史任务", text: $searchText,
                              prompt: Text("搜索历史任务").foregroundStyle(AgentPalette.placeholder))
                        .font(.subheadline)
                        .autocorrectionDisabled()
                        .accessibilityLabel("搜索任务历史")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 14).frame(height: 42)
                .agentGlass(in: Capsule(), interactive: true)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if selectedDestination == .tasks, let record = displayedRecord {
                        sidebarButton("任务详情与管理", icon: "checklist") { onTaskDetail(record.id) }
                    }
                    sidebarButton("任务队列", icon: "list.bullet", count: model.taskQueue.pendingCount) { onNavigate(.queue) }
                    sidebarButton("设备与校准", icon: "computermouse") { onNavigate(.device) }
                    sidebarButton("屏幕共享", icon: "rectangle.on.rectangle") { onNavigate(.screenShare) }
                    sidebarButton("记忆与上下文", icon: "bookmark") { onNavigate(.memory) }
                    sidebarButton("记录与文件", icon: "doc.text") { onNavigate(.workbench) }
                    sidebarButton("使用准备", icon: "checklist") { onPreparation() }

                    if searchText.isEmpty {
                        Text("最近")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 4)
                    }

                    if !searchText.isEmpty || !model.history.records.isEmpty {
                        if filteredTasks.isEmpty {
                            Text("没有找到相关任务")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        } else if !searchText.isEmpty {
                            Text("搜索结果")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                            ForEach(filteredTasks) { record in
                                sidebarTaskRow(record)
                            }
                        } else {
                            ForEach(groupedHistory, id: \.title) { group in
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                                ForEach(group.records) { record in
                                    sidebarTaskRow(record)
                                }
                            }
                        }
                    } else if searchText.isEmpty {
                        Text("任务会显示在这里")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }

                    if !model.history.error.isEmpty {
                        AgentNotice(text: model.history.error, error: true).padding(.horizontal, 14)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button {
                        onNewConversation()
                    } label: {
                        Label("新建", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 22).frame(minHeight: 40)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .tint(AgentPalette.accent).foregroundStyle(.white)
                    .disabled(model.voiceMode != nil)
                    .accessibilityLabel("新建")
                    Spacer(minLength: 8)
                    Button { onNavigate(.settings) } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.primary).frame(width: 52, height: 52)
                            .agentGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(AgentPressStyle()).accessibilityLabel("Phone Agent 设置")
                }
            }
            .padding(.leading, 40).padding(.trailing, 30).padding(.top, 10).padding(.bottom, 12)
        }
    }
    private func sidebarTaskRow(_ record: PhoneTaskRecord) -> some View {
        Button { onOpenConversation(record) } label: {
            HStack(spacing: 10) {
                Image(systemName: record.outcome == .completed ? "checkmark.circle" : "bubble.left")
                    .font(.system(size: 14))
                    .foregroundStyle(record.outcome == .completed ? Color.green.opacity(0.8) : AgentPalette.ink.opacity(0.4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Text(record.outcome.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if screen == .conversation(record.id) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(screen == .conversation(record.id) ? AgentPalette.ink.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(AgentPressStyle())
    }
    private func sidebarButton(_ title: String, icon: String, count: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 22)
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                if count > 0 { Text(String(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).frame(minHeight: 50).contentShape(Rectangle())
        }.buttonStyle(AgentPressStyle())
    }
}
