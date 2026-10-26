import SwiftUI
import UIKit

enum SelaSidebarPalette {
    static let background = adaptive(light: 0xFAFAFA, dark: 0x111111)
    static let accent = adaptive(light: 0x282828, dark: 0xEEEEEE)
    static let selection = adaptive(light: 0xEAEAEA, dark: 0x282828)
    static let action = adaptive(light: 0xEEEEEE, dark: 0x242424)
    static let secondary = adaptive(light: 0x707070, dark: 0xA0A0A0)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

private enum SidebarHistoryEntry: Identifiable {
    case task(PhoneTaskRecord)
    case conversation(AssistantConversationRecord)

    var id: String {
        switch self {
        case .task(let record): "task:" + record.id.uuidString
        case .conversation(let record): "chat:" + record.id.uuidString
        }
    }
    var title: String {
        switch self {
        case .task(let record): record.title
        case .conversation(let record): record.title
        }
    }
    var updatedAt: Date {
        switch self {
        case .task(let record): record.updatedAt
        case .conversation(let record): record.updatedAt
        }
    }
    var searchableText: String {
        switch self {
        case .task(let record): record.title + "\n" + record.effectiveGoal
        case .conversation(let record): record.title + "\n" + record.draft + "\n" + record.messages.map(\.text).joined(separator: "\n")
        }
    }
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        // Keep exact cross-field matching for pasted multiline searches.
        // Ordinary searches can short-circuit without copying whole histories.
        if query.contains("\n") { return searchableText.localizedCaseInsensitiveContains(query) }
        switch self {
        case .task(let record):
            return record.title.localizedCaseInsensitiveContains(query) || record.effectiveGoal.localizedCaseInsensitiveContains(query)
        case .conversation(let record):
            return record.title.localizedCaseInsensitiveContains(query) || record.draft.localizedCaseInsensitiveContains(query) ||
                record.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .title) private var wordmarkSize: CGFloat = 32
    @State private var showingAllHistory = false
    let selectedDestination: WorkspaceDestination
    let screen: TaskScreen
    @Binding var searchText: String
    @Binding var sidebarSearchExpanded: Bool
    let onNavigate: (WorkspaceDestination) -> Void
    let onTaskDetail: (UUID) -> Void
    let onOpenConversation: (PhoneTaskRecord) -> Void
    let onOpenAssistantConversation: (UUID) -> Void
    let onNewTask: () -> Void
    let onNewConversation: () -> Void

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var filteredHistory: [SidebarHistoryEntry] {
        let tasks = model.history.records.map(SidebarHistoryEntry.task)
        let conversations = model.conversation.conversations.map(SidebarHistoryEntry.conversation)
        return (tasks + conversations)
            .filter { $0.matches(query) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
    private var visibleHistory: [SidebarHistoryEntry] {
        query.isEmpty && !showingAllHistory ? Array(filteredHistory.prefix(5)) : filteredHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            if sidebarSearchExpanded { searchField }
            else { creationActions }

            Text("Recents")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SelaSidebarPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28).padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    historyContent
                    if !query.isEmpty, !filteredHistory.isEmpty {
                        Text("\(filteredHistory.count) 项结果")
                            .font(.caption).foregroundStyle(SelaSidebarPalette.secondary)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                    if !model.history.error.isEmpty {
                        AgentNotice(text: model.history.error, error: true).padding(.horizontal, 12)
                        Button("重试保存任务记录") { model.retryTaskRecordPersistence() }
                            .font(.caption).padding(.horizontal, 12)
                    }
                    if !model.conversation.storageError.isEmpty {
                        AgentNotice(text: model.conversation.storageError, error: true).padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            footer
        }
        .foregroundStyle(.primary)
        .background(SelaSidebarPalette.background.ignoresSafeArea(.container, edges: .vertical))
        .onChange(of: sidebarSearchExpanded) { _, expanded in searchFocused = expanded }
    }

    private var brandHeader: some View {
        HStack(spacing: 3) {
            Image("SelaMascot")
                .resizable().scaledToFit().frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("Sela")
                .font(.system(size: min(wordmarkSize, 40), weight: .semibold, design: .rounded))
                .tracking(-0.8)
                .accessibilityLabel("Sela")
            Spacer(minLength: 4)
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) {
                    sidebarSearchExpanded.toggle()
                    if !sidebarSearchExpanded { searchText = "" }
                }
            } label: {
                Image(systemName: sidebarSearchExpanded ? "xmark" : "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SelaSidebarPalette.secondary)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(AgentPressStyle())
            .accessibilityLabel(sidebarSearchExpanded ? "收起搜索" : "搜索对话与任务")
            .accessibilityIdentifier("sidebar.search.toggle")
        }
        .padding(.leading, 10).padding(.trailing, 16)
        .padding(.top, 4).padding(.bottom, 22)
    }

    private var creationActions: some View {
        HStack(spacing: 8) {
            creationButton("新任务", icon: "plus", identifier: "sidebar.newTask", action: onNewTask)
            creationButton("新对话", icon: "square.and.pencil", identifier: "sidebar.newConversation", action: onNewConversation)
        }
        .disabled(model.voiceMode != nil)
        .opacity(model.voiceMode == nil ? 1 : 0.45)
        .padding(.horizontal, 20)
    }

    private func creationButton(_ title: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).frame(width: 22)
                Text(title).font(.subheadline.weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(SelaSidebarPalette.action, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(AgentPressStyle())
        .accessibilityIdentifier(identifier)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(SelaSidebarPalette.secondary)
            TextField("搜索对话与任务", text: $searchText,
                      prompt: Text("搜索对话与任务").foregroundStyle(SelaSidebarPalette.secondary))
                .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($searchFocused).submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("sidebar.search.field")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(SelaSidebarPalette.secondary).frame(width: 32, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).frame(minHeight: 50)
        .background(SelaSidebarPalette.selection, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding(.horizontal, 20).transition(.opacity)
    }

    @ViewBuilder private var historyContent: some View {
        if filteredHistory.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(query.isEmpty ? "从一件小事开始" : "没有找到相关对话")
                    .font(.subheadline.weight(.medium))
                Text(query.isEmpty ? "聊聊想法，或交给 Sela 一件事。" : "试试其他关键词。")
                    .font(.footnote).foregroundStyle(SelaSidebarPalette.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.top, 20)
        } else {
            ForEach(visibleHistory) { entry in sidebarHistoryRow(entry) }
            if query.isEmpty && filteredHistory.count > 5 {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showingAllHistory.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showingAllHistory ? "See less" : "See all…")
                        Image(systemName: showingAllHistory ? "chevron.up" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.subheadline).foregroundStyle(SelaSidebarPalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                }
                .buttonStyle(AgentPressStyle())
                .accessibilityIdentifier("sidebar.recents.seeAll")
            }
        }
    }

    private func isSelected(_ entry: SidebarHistoryEntry) -> Bool {
        switch entry {
        case .task(let record): selectedDestination == .tasks && screen == .conversation(record.id)
        case .conversation(let record): selectedDestination == .assistant && model.conversation.currentConversationID == record.id
        }
    }

    private func isComplete(_ entry: SidebarHistoryEntry) -> Bool {
        switch entry {
        case .task(let record): record.outcome == .completed
        case .conversation(let record):
            record.messages.last?.role == "assistant" &&
                !(record.id == model.conversation.currentConversationID && model.conversation.loading)
        }
    }

    private func sidebarHistoryRow(_ entry: SidebarHistoryEntry) -> some View {
        let selected = isSelected(entry)
        let complete = isComplete(entry)
        return Button {
            switch entry {
            case .task(let record): onOpenConversation(record)
            case .conversation(let record): onOpenAssistantConversation(record.id)
            }
        } label: {
            HStack(spacing: 12) {
                Text(entry.title)
                    .font(.subheadline.weight(selected ? .medium : .regular))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if complete { Circle().fill(Color.green).frame(width: 7, height: 7) }
                    else { ProgressView().controlSize(.mini).tint(SelaSidebarPalette.secondary) }
                }
                .dynamicTypeSize(.large)
                .frame(width: 16, height: 16).accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(selected ? SelaSidebarPalette.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(AgentPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(complete ? "已完成" : "未完成")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar." + entry.id)
        .contextMenu {
            if case .task(let record) = entry {
                Button("任务详情与管理", systemImage: "checklist") { onTaskDetail(record.id) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { onNavigate(.tools) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 17))
                        Text(typeSize.isAccessibilitySize ? "更多" : "工具与连接")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.leading, 1)
                    }
                    .foregroundStyle(SelaSidebarPalette.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AgentPressStyle())
                .accessibilityIdentifier("sidebar.more")
                .accessibilityLabel("工具与连接")
                Spacer(minLength: 0)
                Button { onNavigate(.settings) } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(SelaSidebarPalette.secondary)
                        .frame(width: 44, height: 44)
                        .overlay { Circle().stroke(SelaSidebarPalette.secondary.opacity(0.25), lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(AgentPressStyle())
                .accessibilityLabel("Sela 设置")
                .accessibilityIdentifier("sidebar.settings")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4).padding(.bottom, 8)
    }
}
