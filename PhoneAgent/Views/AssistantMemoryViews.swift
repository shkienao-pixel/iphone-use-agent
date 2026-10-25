import SwiftUI
import SelaMemoryCore

struct AssistantMemorySection: View {
    @ObservedObject var service: SelaMemoryService
    let settings: AgentSettings
    let query: String
    @State private var selected: DocumentSnapshot?
    @State private var forgetting: RememberedFact?
    @State private var error = ""
    private var memories: [RememberedFact] {
        service.learned.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("从对话中学习", isOn: Binding(get: { service.automaticLearning }, set: { value in
                Task { await service.setAutomaticLearning(value, settings: settings) }
            })).tint(AgentPalette.accent).disabled(settings.useMemories != true)
            Text("基础资料").font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
            AgentCard {
                VStack(spacing: 0) {
                    ForEach(service.documents.filter { $0.kind != .bootstrap }) { document in
                        if document.kind != .identity { Divider().padding(.leading, 40) }
                        Button { selected = document } label: {
                            HStack(spacing: 12) {
                                Image(systemName: document.kind == .user ? "person.crop.circle" : document.kind == .memory ? "bookmark" : "doc.text").frame(width: 26)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(document.kind.title).font(.body)
                                    Text(document.kind.detail).font(.caption).foregroundStyle(AgentPalette.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            }.padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !memories.isEmpty {
                Text("从对话中记住").font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(memory.text).font(.body)
                            Spacer()
                            if memory.status == .candidate { Text("待确认").font(.caption).foregroundStyle(AgentPalette.secondaryText) }
                        }
                        HStack {
                            Text(scope(memory.scope)).font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            Spacer()
                            if memory.status == .candidate {
                                Button("记住") { Task { do { try await service.approve(memory) } catch { self.error = error.localizedDescription } } }
                            }
                        }
                    }.agentPanel()
                    .contextMenu { Button("忘记", role: .destructive) { forgetting = memory } }
                }
            }
            if !service.error.isEmpty { AgentNotice(text: service.error, error: true) }
            if !error.isEmpty { AgentNotice(text: error, error: true) }
        }
        .task { await service.reload() }
        .sheet(item: $selected) { AssistantFoundationEditor(service: service, document: $0) }
        .confirmationDialog("忘记这条记忆？", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("忘记", role: .destructive) {
                if let memory = forgetting { Task { do { try await service.forget(memory) } catch { self.error = error.localizedDescription } } }
                forgetting = nil
            }
        }
    }
    private func scope(_ scope: MemoryScope) -> String {
        switch scope { case .personal: return "长期记忆"; case .conversation: return "本次对话"; case .work: return "Work"; case .topic: return "相关话题" }
    }
}

private struct AssistantFoundationEditor: View {
    @ObservedObject var service: SelaMemoryService
    let document: DocumentSnapshot
    @State private var text: String
    @State private var error = ""
    @State private var saving = false
    @State private var confirmingClose = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    init(service: SelaMemoryService, document: DocumentSnapshot) {
        self.service = service; self.document = document; _text = State(initialValue: document.text)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextEditor(text: $text).focused($focused).frame(minHeight: 360).scrollContentBackground(.hidden).agentField()
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle(document.kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { focused = false; if text != document.text { confirmingClose = true } else { dismiss() } }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        focused = false; saving = true
                        Task { do { try await service.save(document, text: text); dismiss() } catch { self.error = error.localizedDescription; saving = false } }
                    }.disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focused = false } }
            }
        }.tint(AgentPalette.accent).agentSheetStyle().interactiveDismissDisabled(text != document.text || saving)
        .alert("修改尚未保存", isPresented: $confirmingClose) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive) { dismiss() }
        }
    }
}
