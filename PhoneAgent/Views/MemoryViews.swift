import SwiftUI
import UniformTypeIdentifiers

struct MemoryEditorSeed: Identifiable {
    var value: AssistantMemory
    var image: UIImage? = nil
    var id: UUID { value.id }
}
struct MemoryEditor: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State var seed: MemoryEditorSeed
    @State private var keepImage = false
    @State private var error = ""
    private enum Field: Hashable { case title, content }
    @FocusState private var focusedField: Field?
    @State private var originalValue: AssistantMemory?
    @State private var originalKeepImage = false
    @State private var confirmingClose = false
    private var hasChanges: Bool {
        guard let originalValue else { return false }
        return seed.value != originalValue || keepImage != originalKeepImage
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("标题").font(.subheadline).foregroundStyle(.secondary)
                        TextField("为这条记忆命名", text: $seed.value.title).focused($focusedField, equals: .title).agentField().accessibilityLabel("记忆标题")
                    }
                    Picker("类型", selection: $seed.value.kind) { ForEach(MemoryKind.allCases) { Text($0.rawValue).tag($0) } }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("内容").font(.subheadline).foregroundStyle(.secondary)
                        TextField("记下内容，或总结你的偏好", text: $seed.value.text, axis: .vertical).lineLimit(6...20).focused($focusedField, equals: .content).agentField().accessibilityLabel("记忆内容")
                    }
                    Text("来源：\(seed.value.source)").font(.footnote).foregroundStyle(.secondary)
                    Toggle("允许在相关任务中引用", isOn: $seed.value.enabled).tint(AgentPalette.accent)
                    Text("保存到本机。只有开启“使用本机记忆”并授权当前 AI 服务后，相关文字才会随问题或任务发送；保存的图片不会自动发送。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let image = seed.image ?? model.memories.image(for: seed.value) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 18))
                        Toggle("保存这张画面", isOn: $keepImage).tint(AgentPalette.accent)
                    }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { focusedField = nil; if hasChanges { confirmingClose = true } else { dismiss() } } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).accessibilityLabel("保存记忆到本机") }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .onAppear { if originalValue == nil { keepImage = seed.value.imageName != nil; originalKeepImage = keepImage; originalValue = seed.value } }
            .interactiveDismissDisabled(hasChanges)
            .alert("记忆尚未保存", isPresented: $confirmingClose) {
                Button("继续编辑", role: .cancel) { }
                Button("放弃修改", role: .destructive) { dismiss() }
            } message: { Text("继续编辑后可点右上角“保存”，将内容留在本机。") }
    }
    private func save() {
        focusedField = nil
        do {
            var value = seed.value
            if !keepImage { value.imageName = nil }
            try model.memories.save(value, image: keepImage ? seed.image : nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct MemoryView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @State private var exporting = false
    @State private var exportDocument: ArtifactDocument?
    @State private var query = ""
    @State private var result = MemorySearchResult(hits: [], semantic: false)
    @State private var searching = false
    @State private var editor: MemoryEditorSeed?
    @State private var delete: AssistantMemory?
    @State private var clear = false
    @State private var error = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("保存你的偏好").font(.title2.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("导出记忆文字与索引") {
                            do { exportDocument = ArtifactDocument(data: try model.memories.exportText()); exporting = true }
                            catch { self.error = error.localizedDescription }
                        }
                        Button("清空所有记忆", role: .destructive) { clear = true }
                            .disabled(model.memories.records.isEmpty && model.memories.error.isEmpty)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("记忆管理")
                    Button { editor = MemoryEditorSeed(value: AssistantMemory(title: "", text: "")) } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44).agentGlass(in: Circle(), interactive: true)
                    }.accessibilityLabel("新增记忆")
                }
                Toggle("使用本机记忆", isOn: Binding(get: { model.settings.useMemories == true }, set: { model.settings.useMemories = $0 })).tint(AgentPalette.accent)
                Text("开启后，每次问题或任务最多引用 3 条相关记忆的文字，发送给你配置并授权的 AI 服务。关闭后仍可本机搜索。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("搜索内容或意思", text: $query).agentField()
                if searching { ProgressView() }
                else if !query.isEmpty { Text(result.semantic ? "使用本机语义与关键词检索" : "此设备使用关键词检索").font(.caption).foregroundStyle(.secondary) }
                if !model.memories.error.isEmpty { AgentNotice(text: model.memories.error, error: true) }
                if !error.isEmpty { AgentNotice(text: error, error: true) }
                let items = query.isEmpty ? model.memories.records : result.hits.map(\.memory)
                if items.isEmpty { AgentEmptyState(title: query.isEmpty ? "还没有记忆" : "没有匹配内容", detail: "记下偏好，或从对话中保存回答。", icon: "bookmark") }
                ForEach(items) { memory in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(memory.title).font(.headline); Spacer(); if !memory.enabled { Image(systemName: "eye.slash").accessibilityLabel("不引用") } }
                        Text(memory.text).lineLimit(3).foregroundStyle(.secondary)
                        Text("\(memory.kind.rawValue) · \(memory.updatedAt.formatted(date: .abbreviated, time: .omitted)) · \(memory.source)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.agentPanel().contentShape(Rectangle())
                        .onTapGesture { editor = MemoryEditorSeed(value: memory) }
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                        .accessibilityAction { editor = MemoryEditorSeed(value: memory) }
                        .contextMenu {
                            Button("查看与编辑") { editor = MemoryEditorSeed(value: memory) }
                            Button("删除", role: .destructive) { delete = memory }
                        }
                }
                AgentHelp(title: "导出内容说明", text: "导出的 JSON 不包含图片文件；保存的画面仍在本机。")
            }.padding(20)
        }
        .task(id: query + model.memories.records.map { $0.updatedAt.description }.joined()) {
            searching = true
            let value = await model.memories.search(query)
            guard !Task.isCancelled else { return }; result = value; searching = false
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Phone Agent 记忆.json") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }; exportDocument = nil
        }
        .sheet(item: $editor) { MemoryEditor(seed: $0) }
        .confirmationDialog("删除这条记忆？", isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let delete { do { try model.memories.remove(delete.id) } catch { self.error = error.localizedDescription } }; delete = nil }
        }
        .confirmationDialog("清空本机记忆和保存的画面？", isPresented: $clear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { do { try model.memories.clear() } catch { self.error = error.localizedDescription } }
        } message: { Text("此操作无法撤销，也不会删除 AI 服务已接收的数据。") }
    }
}
