import SwiftUI
import UniformTypeIdentifiers

struct MeetingEditorSeed: Identifiable {
    let id = UUID()
    let source: String
    let sourceName: String
    let notes: MeetingNotes
}

private enum MeetingExport: String, CaseIterable, Identifiable {
    case word = "纪要 Word", minutesPDF = "纪要 PDF", markdown = "纪要 Markdown", json = "结构化纪要 JSON"
    case png = "鱼骨图 PNG", svg = "鱼骨图 SVG", diagramPDF = "鱼骨图 PDF"
    var id: String { rawValue }
    var ext: String { switch self { case .word:return "docx"; case .minutesPDF,.diagramPDF:return "pdf"; case .markdown:return "md"; case .json:return "json"; case .png:return "png"; case .svg:return "svg" } }
    var type: UTType { UTType(filenameExtension:ext) ?? .data }
    var diagram: Bool { [.png,.svg,.diagramPDF].contains(self) }
}

struct MeetingNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let seed: MeetingEditorSeed
    let onApply: (MeetingNotes) -> Void
    let onRetainDraft: (MeetingNotes) -> Void
    private enum SectionTab: String, CaseIterable { case minutes = "纪要", actions = "待办", diagram = "鱼骨图" }
    @State private var sectionTab: SectionTab = .minutes
    @State private var notes: MeetingNotes
    @State private var error = ""
    @State private var message = ""
    @State private var preview: CGImage?
    @State private var previewSize = CGSize.zero
    @State private var zoom = 0.6
    @State private var working = false
    @State private var operation: Task<Void,Never>?
    @State private var generation = UUID()
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportType = UTType.data
    @State private var exportName = "会议纪要"
    @FocusState private var focusedField: String?
    init(seed:MeetingEditorSeed,onApply:@escaping (MeetingNotes)->Void,onRetainDraft:@escaping (MeetingNotes)->Void) {
        self.seed=seed;self.onApply=onApply;self.onRetainDraft=onRetainDraft;_notes=State(initialValue:seed.notes)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    Text(notes.title).font(.title3.weight(.semibold))
                    DisclosureGroup("标题与参考原文") {
                        VStack(alignment: .leading, spacing: 14) {
                            MeetingLabeledField(label: "纪要标题", placeholder: "为这份纪要命名", text: $notes.title, focus: $focusedField, fieldID: "title", accessibility: "纪要标题，最多80字")
                            Text(seed.sourceName).font(.caption).foregroundStyle(.secondary)
                            Text(seed.source).font(.subheadline).textSelection(.enabled)
                            Text("引文匹配只确认出处；转写、释义与原因仍需核对。") .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.font(.subheadline).agentPanel()
                    Picker("纪要内容", selection: $sectionTab) {
                        ForEach(SectionTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).onChange(of: sectionTab) { _, _ in focusedField = nil }
                    switch sectionTab {
                    case .minutes: minutesPanel
                    case .actions: actionsPanel
                    case .diagram: diagramPanel
                    }
                    if working { ProgressView("正在生成文件") }
                    if !error.isEmpty { AgentNotice(text:error,error:true) }
                    if !message.isEmpty { AgentNotice(text:message) }
                    Menu {
                        ForEach(MeetingExport.allCases) { kind in Button(kind.rawValue) { export(kind) }.disabled(kind.diagram && notes.fishbone==nil) }
                    } label: { Label("导出纪要或鱼骨图",systemImage:"square.and.arrow.up") }.buttonStyle(AgentButtonStyle()).disabled(working || exporting)
                    Text("纪要文件和 JSON 包含引用的原文片段；SVG 的说明中也含这些片段，分享前请核对。草稿只保留在当前工作台会话，离开工作台前请保存或导出。点“使用纪要”后可保存文字记忆。鱼骨图 PDF 为完整矢量画布，适合缩放查看；复制文字请使用纪要文件。") .font(.caption).foregroundStyle(.secondary)
                }.padding(20).disabled(working || exporting)
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle("纪要编辑").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement:.keyboard) { Spacer();Button("收起键盘") { focusedField=nil } }
                    ToolbarItem(placement:.cancellationAction) { Button(working ? "取消处理" : "返回") { if working { cancel() } else { dismiss() } } }
                    ToolbarItem(placement:.confirmationAction) { Button("使用纪要") { do { try notes.validate(source:seed.source);onApply(notes);dismiss() } catch { self.error=error.localizedDescription } }.disabled(working || exporting) }
                }
                .fileExporter(isPresented:$exporting,document:document,contentType:exportType,defaultFilename:exportName) { result in
                    switch result { case .success:message="文件已导出";case .failure(let error):self.error=error.localizedDescription };document=nil
                }
                .onChange(of:phase) { _,value in if value == .background { cancel() } }
                .onDisappear { cancel();onRetainDraft(notes) }
        }.agentSheetStyle()
    }
    private var minutesPanel: some View { VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment:.leading,spacing:14) {
                        Text("概要").font(.headline)
                        if notes.summary != nil {
                            MeetingStatementFields(item:Binding(get:{notes.summary ?? .init(text:"",quote:"")},set:{notes.summary=$0}),focus:$focusedField)
                            Button("移除概要",role:.destructive) { notes.summary=nil }
                        } else { Button("添加概要") { notes.summary = .init(text:"",quote:"") } }
                    }.agentPanel()
                    statementSection("要点",items:$notes.points,maximum:24)
                    statementSection("决定",items:$notes.decisions,maximum:16)
                    statementSection("待确认",items:$notes.questions,maximum:12)
    } }
    private var actionsPanel: some View { VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment:.leading,spacing:14) {
                        Text("待办").font(.headline)
                        Text("仅记录，不会自动创建提醒或执行。负责人和期限未明确时留空。") .font(.caption).foregroundStyle(.secondary)
                        ForEach($notes.actions) { $item in
                            VStack(alignment:.leading,spacing:12) {
                                MeetingLabeledField(label:"待办内容",placeholder:"记录需要完成的事项",text:$item.text,focus:$focusedField,fieldID:item.id.uuidString+".text",lines:2...5)
                                MeetingLabeledField(label:"负责人",placeholder:"未明确则留空",text:optional($item.owner),focus:$focusedField,fieldID:item.id.uuidString+".owner")
                                MeetingLabeledField(label:"原文期限",placeholder:"未明确则留空",text:optional($item.due),focus:$focusedField,fieldID:item.id.uuidString+".due")
                                MeetingLabeledField(label:"原文依据",placeholder:"逐字引用原文",text:$item.quote,focus:$focusedField,fieldID:item.id.uuidString+".quote",lines:2...5,accessibility:"原文依据，必须逐字存在于材料中")
                                Button("删除这条待办",role:.destructive) { notes.actions.removeAll { $0.id==item.id } }.frame(minHeight:44)
                            }.padding(.vertical,8)
                        }
                        Button("添加待办") { notes.actions.append(.init(text:"",quote:"",owner:nil,due:nil)) }.frame(minHeight:44).disabled(notes.actions.count>=24)
                    }.agentPanel()
    } }
    private var diagramPanel: some View { VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment:.leading,spacing:14) {
                        Text("鱼骨图").font(.headline)
                        Text("将材料提及的原因分组；推断标为待核对假设。没有原因材料时可以不生成。") .font(.caption).foregroundStyle(.secondary)
                        if notes.fishbone != nil {
                            MeetingFishboneFields(bone:Binding(get:{notes.fishbone ?? .init(problem:.init(text:"",quote:""),groups:[])},set:{notes.fishbone=$0}),focus:$focusedField)
                            Button("移除鱼骨图",role:.destructive) { notes.fishbone=nil;preview=nil }
                            Button("更新鱼骨图预览") { focusedField=nil;makePreview() }.frame(minHeight:44)
                            if let preview {
                                ScrollView([.horizontal,.vertical]) { Image(decorative:preview,scale:1,orientation:.up).resizable().frame(width:previewSize.width*zoom,height:previewSize.height*zoom) }.frame(height:340).background(.white,in:RoundedRectangle(cornerRadius:16))
                                    .accessibilityLabel("鱼骨图预览，完整内容可在上方原因条目中阅读")
                                Slider(value:$zoom,in:0.25...1.5).accessibilityLabel("鱼骨图预览缩放")
                                Text("预览为上次更新的结果；导出时会重新绘制当前内容。") .font(.caption).foregroundStyle(.secondary)
                            }
                        } else { Button("添加鱼骨图") { notes.fishbone = .init(problem:.init(text:"",quote:""),groups:[]) }.frame(minHeight:44) }
                    }.agentPanel()
    } }
    private func optional(_ value:Binding<String?>)->Binding<String> { Binding(get:{value.wrappedValue ?? ""},set:{value.wrappedValue=$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0}) }
    private func statementSection(_ title:String,items:Binding<[MeetingStatement]>,maximum:Int)->some View {
        VStack(alignment:.leading,spacing:14) {
            Text(title).font(.headline)
            ForEach(items) { $item in
                VStack(alignment:.leading,spacing:10) { MeetingStatementFields(item:$item,focus:$focusedField);Button("删除这条\(title)",role:.destructive) { items.wrappedValue.removeAll { $0.id==item.id } }.frame(minHeight:44) }.padding(.vertical,8)
            }
            Button("添加\(title)") { items.wrappedValue.append(.init(text:"",quote:"")) }.frame(minHeight:44).disabled(items.wrappedValue.count>=maximum)
        }.agentPanel()
    }
    private func cancel() { generation=UUID();operation?.cancel();operation=nil;working=false }
    private func makePreview() {
        error="";message="";let value=notes;let source=seed.source;working=true;let token=UUID();generation=token
        operation=Task {
            let worker=Task.detached(priority:.userInitiated) { let layout=try FishboneDiagram.layout(notes:value,source:source);try Task.checkCancellation();return (try FishboneDiagram.image(layout),layout.size) }
            do {
                let result=try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
                guard !Task.isCancelled,token==generation,phase == .active else { return };preview=result.0;previewSize=result.1;working=false;operation=nil
            } catch { guard token==generation,!Task.isCancelled else { return };self.error=error.localizedDescription;working=false;operation=nil }
        }
    }
    private func export(_ kind:MeetingExport) {
        focusedField=nil
        do { try notes.validate(source:seed.source) } catch { self.error=error.localizedDescription;return }
        error="";message="";let value=notes;let source=seed.source;working=true;let token=UUID();generation=token
        operation=Task {
            do {
                let data:Data
                if kind.diagram {
                    let worker=Task.detached(priority:.userInitiated) {
                        let layout=try FishboneDiagram.layout(notes:value,source:source);try Task.checkCancellation()
                        switch kind { case .png:return try FishboneDiagram.png(layout);case .svg:return FishboneDiagram.svg(layout);default:return try FishboneDiagram.pdf(layout) }
                    }
                    data=try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
                } else if kind == .json {
                    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];data=try encoder.encode(value)
                } else if kind == .minutesPDF {
                    let worker=Task.detached(priority:.userInitiated) { try MeetingMinutesPDF.make(notes:value,source:source) }
                    data=try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
                }
                else { data=try ArtifactFiles.make(title:value.title,text:value.plainText,format:kind == .word ? .word : .markdown) }
                guard !Task.isCancelled,token==generation,phase == .active else { return }
                document=ArtifactDocument(data:data);exportType=kind.type;exportName=ArtifactFiles.filename(value.title)+(kind.diagram ? "-鱼骨图" : "-纪要")+"."+kind.ext
                working=false;operation=nil;exporting=true
            } catch { guard token==generation,!Task.isCancelled else { return };self.error=error.localizedDescription;working=false;operation=nil }
        }
    }
}

private struct MeetingLabeledField:View {
    let label:String
    let placeholder:String
    @Binding var text:String
    let focus:FocusState<String?>.Binding
    let fieldID:String
    var lines:ClosedRange<Int> = 1...1
    var accessibility:String? = nil
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if !label.isEmpty { Text(label).font(.caption).foregroundStyle(.secondary) }
            TextField(placeholder,text:$text,axis:.vertical).lineLimit(lines).agentField()
                .focused(focus,equals:fieldID).accessibilityLabel(accessibility ?? label)
        }
    }
}

private struct MeetingStatementFields:View {
    @Binding var item:MeetingStatement
    let focus:FocusState<String?>.Binding
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            MeetingLabeledField(label:"",placeholder:"输入纪要内容",text:$item.text,focus:focus,fieldID:item.id.uuidString+".text",lines:2...6,accessibility:"纪要条目内容")
            MeetingLabeledField(label:"原文依据",placeholder:"逐字引用原文",text:$item.quote,focus:focus,fieldID:item.id.uuidString+".quote",lines:2...5,accessibility:"原文依据，必须逐字存在于材料中")
        }
    }
}
private struct MeetingFishboneFields:View {
    @Binding var bone:MeetingFishbone
    let focus:FocusState<String?>.Binding
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("讨论的问题").font(.subheadline.bold());MeetingStatementFields(item:$bone.problem,focus:focus)
            ForEach($bone.groups) { $group in
                VStack(alignment:.leading,spacing:14) {
                    MeetingLabeledField(label:"原因分组",placeholder:"为这组原因命名",text:$group.name,focus:focus,fieldID:group.id.uuidString+".name")
                    ForEach($group.causes) { $cause in
                        VStack(alignment:.leading,spacing:10) {
                            MeetingLabeledField(label:"原因内容",placeholder:"输入材料提及的原因",text:$cause.text,focus:focus,fieldID:cause.id.uuidString+".text",lines:2...5)
                            Toggle("这是待核对的假设",isOn:$cause.hypothesis).tint(.orange)
                            MeetingLabeledField(label:"原因的原文依据",placeholder:"逐字引用原文",text:$cause.quote,focus:focus,fieldID:cause.id.uuidString+".quote",lines:2...5)
                            Button("删除这条原因",role:.destructive) { group.causes.removeAll { $0.id==cause.id } }.frame(minHeight:44)
                        }
                    }
                    Button("添加原因") { group.causes.append(.init(text:"",quote:"",hypothesis:true)) }.frame(minHeight:44).disabled(group.causes.count>=8)
                    Button("删除这个分组",role:.destructive) { bone.groups.removeAll { $0.id==group.id } }.frame(minHeight:44)
                }.padding(14).background(AgentPalette.inset,in:RoundedRectangle(cornerRadius:18))
            }
            Button("添加原因分组") { bone.groups.append(.init(name:"",causes:[])) }.frame(minHeight:44).disabled(bone.groups.count>=8)
        }
    }
}
