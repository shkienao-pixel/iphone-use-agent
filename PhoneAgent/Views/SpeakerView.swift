import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

private struct SpeakerApproval: Identifiable {
    let id: UUID
    let record: LocalRecording
    let settings: SpeakerSettings
    let key: String
    let audio: Data
}
struct SpeakerView: View {
    let record: LocalRecording
    @ObservedObject var store: RecordingStore
    let onUseText: (RecordingTextSeed) -> Void
    @EnvironmentObject private var model: PhoneAgentViewModel
    @StateObject private var audition = RecordingAudioController()
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var settings = SpeakerSettings()
    @State private var saved = SpeakerSettings()
    @State private var key = ""
    @State private var savedKey = ""
    @State private var draft: SpeakerDocument?
    @State private var approval: SpeakerApproval?
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error = ""
    @State private var message = ""
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportType = UTType.plainText
    @State private var exportName = "说话人分段.txt"
    @State private var savedDraft: SpeakerDocument?
    @State private var confirmingDiscard = false
    @State private var pendingSeed: RecordingTextSeed?
    @FocusState private var focusedField: String?
    private var hasChanges: Bool { settings != saved || key != savedKey || draft != savedDraft }
    private var busy: Bool { work != nil || exporting || audition.busy }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    AgentPageIntro(title: "核对说话人", subtitle: record.title, icon: "person.2.wave.2")
                    Text("说话人 A / B 是本段录音中的服务标签，不能证明真实身份。需要上传这一段原音频；本机转写和原录音会保留。每次核对后才发送。") .foregroundStyle(.secondary)
                    DisclosureGroup("独立音频服务配置") {
                        VStack(spacing: 14) {
                            labeledField("音频分段服务商", text: $settings.provider, placeholder: "服务商名称", id: "provider")
                            labeledField("音频转写接口", text: $settings.endpoint, placeholder: "https://…/v1/audio/transcriptions", id: "endpoint", keyboard: .URL, lines: 1...3)
                            labeledField("说话人分段模型", text: $settings.model, placeholder: "支持 diarized_json 的模型", id: "model")
                            VStack(alignment: .leading, spacing: 8) {
                                Text("独立音频服务 Key").font(.caption).foregroundStyle(.secondary)
                                SecureField("填写独立音频 API Key", text: $key).textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("独立音频服务 Key").focused($focusedField, equals: "key")
                            }
                            Button("保存音频配置") { saveConfiguration() }.buttonStyle(AgentButtonStyle(primary: false))
                            Text("不是 Chat / 实时语音接口；不会使用任务、实时语音或搜索 Key。服务必须支持音频上传及 diarized_json，说话人参考样本不会上传。") .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.disabled(busy)
                    if audition.busy { Text(audition.state).font(.headline); Text("回听位置：" + SpeakerDocument.time(audition.seconds)).font(.caption.monospacedDigit()); Button("停止回听") { audition.stop() }.frame(minHeight: 44) }
                    if !audition.error.isEmpty { AgentNotice(text: audition.error, error: true) }
                    if work != nil { ProgressView("正在处理所选录音"); Button("取消处理") { cancel() }.frame(minHeight: 44) }
                    else { Button(draft == nil ? "核对并分析这段录音" : "核对并重新分析") { prepare() }.buttonStyle(AgentButtonStyle()).disabled(exporting || audition.busy) }
                    AgentHelp(title: "处理限制", text: "一段不超过 25 MB / 10 分钟；只发起一次请求，不自动拆分或重试。取消 / 后台会停止接收，无法撤回已发送的音频。")
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if let draft {
                        Text("核对标签与片段").font(.title3.bold())
                        Text("\(draft.speakers.count) 位服务说话人 · \(draft.segments.count) 个片段\n点回听按片段开始播放，结束位置约以 0.1 秒轮询停止；不修改音频。标签和转写可能有误。改名只作为人工注释，纪要中的归属、时间与文字需要回听核对；未保存的修改只在本页。") .font(.caption).foregroundStyle(.secondary)
                        ForEach(draft.speakers.indices, id: \.self) { index in
                            labeledField("说话人 \(index + 1) 的人工标签", text: speakerBinding(index), placeholder: "人工标签", id: "speaker-\(index)").disabled(busy)
                        }
                        ForEach(Array(draft.segments.enumerated()), id: \.element.id) { item in
                            segmentRow(item.offset, snapshot: draft)
                        }
                        DisclosureGroup("服务原始合并文字") { Text(draft.serviceText).font(.footnote).textSelection(.enabled); Text("原始合并文字不随你的片段编辑更新。") .font(.caption).foregroundStyle(.secondary) }
                        Button("保存核对后的分段") {
                            do { try store.saveSpeakerDocument(draft); savedDraft = draft; focusedField = nil; message = "分段已保存，本机转写未替换"; error = "" } catch { self.error = error.localizedDescription }
                        }.buttonStyle(AgentButtonStyle()).disabled(busy)
                        Button("将分段文字用于纪要") {
                            do {
                                let text = try draft.referenceText()
                                guard text.count <= 12000 else { throw AgentError.message("带标签的纪要材料超过 12000 字，请减少需要的片段后再使用；完整分段仍可导出") }
                                requestClose(seed: .init(title: record.title, text: text, source: "说话人分段文字（标签非身份、需核对） · " + record.title))
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(AgentButtonStyle(primary: false)).disabled(busy)
                        Text("只把当前分段文字放入工作台；不会在这里调用纪要模型或再次上传音频。") .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("导出 TXT") { export(draft, json: false) }.frame(minHeight: 44)
                            Spacer()
                            Button("导出分段 JSON") { export(draft, json: true) }.frame(minHeight: 44)
                        }.disabled(busy)
                        Button("删除本机分段结果", role: .destructive) { confirmDelete = true }.disabled(busy).frame(minHeight: 44)
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("说话人分段").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { requestClose() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .interactiveDismissDisabled(hasChanges || busy)
            .alert("放弃未保存的音频配置或分段？", isPresented: $confirmingDiscard) {
                Button("继续编辑", role: .cancel) { pendingSeed = nil }
                Button("放弃修改", role: .destructive) { close() }
            } message: { Text("未保存的配置、Key 和分段修改会丢失，已保存的录音与分段不变。") }
            .onAppear {
                audition.reserve = model.reserveRecordingAudio; audition.release = model.releaseRecordingAudio; audition.prepareAudio = { try await model.pip.suspendForVoice() }
                saved = SpeakerStore.load(); settings = saved; savedKey = SpeakerStore.key(for: saved); key = savedKey
                do { draft = try store.speakerDocument(record.id); savedDraft = draft } catch { self.error = error.localizedDescription }
            }
            .onChange(of: phase) { _, value in if value != .active { cancel(); audition.stop() } }
            .onChange(of: settings) { _, _ in cancel() }
            .onChange(of: key) { _, _ in cancel() }
            .onDisappear { cancel(); audition.stop(); document = nil }
            .sheet(item: $approval, onDismiss: { approval = nil }) { value in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("确认上传这段原音频").font(.title.bold())
                            Text("录音：\(value.record.title)\n时长：\(SpeakerDocument.time(value.record.duration))\n大小：\(ByteCountFormatter.string(fromByteCount: Int64(value.audio.count), countStyle: .file))\n接收方：\(value.settings.provider)\n\(value.settings.endpoint)\n模型：\(value.settings.model)").font(.footnote).textSelection(.enabled)
                            Text("这次会发送选中的整段录音及独立认证 Key，服务可能计费、保存或转发声音；请核对其政策并确认参与者同意。App 不额外附带说话人参考样本、姓名字段、任务、屏幕、历史或其他录音；所选录音本身包含的声音与信息都会发送。")
                            Text("结果先在本页核对，不自动覆盖本机转写。说话人标签、归属和转写可能错误；保存 / 导出 / 纪要由你另外选择。取消无法撤回已经发出的音频。重新分析成功后会替换本页旧草稿，失败则保留旧草稿。") .font(.footnote).foregroundStyle(.secondary)
                            Button("同意并发送这一次") { start(value) }.buttonStyle(AgentButtonStyle())
                        }.padding(20)
                    }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { cancel() } } }
                }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .confirmationDialog("删除本机分段结果？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除分段", role: .destructive) { do { try store.removeSpeakerDocument(record.id); draft = nil; savedDraft = nil; message = "分段已删除，原音频和本机转写保留" } catch { self.error = error.localizedDescription } }
            } message: { Text("不会删除原音频、本机转写、已经导出的副本或服务收到的数据。") }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in if case .failure(let e) = result { error = e.localizedDescription }; document = nil }
    }
    private func requestClose(seed: RecordingTextSeed? = nil) {
        focusedField = nil; pendingSeed = seed
        if hasChanges { confirmingDiscard = true } else { close() }
    }
    private func close() {
        cancel(); audition.stop()
        if let seed = pendingSeed { onUseText(seed); pendingSeed = nil }
        dismiss()
    }
    private func labeledField(_ label: String, text: Binding<String>, placeholder: String, id: String, keyboard: UIKeyboardType = .default, lines: ClosedRange<Int> = 1...1) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical).lineLimit(lines).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(keyboard).agentField().accessibilityLabel(label).focused($focusedField, equals: id)
        }
    }
    private func speakerBinding(_ index: Int) -> Binding<String> {
        .init(get: { draft?.speakers.indices.contains(index) == true ? draft!.speakers[index] : "" }, set: { value in guard draft?.speakers.indices.contains(index) == true else { return }; draft!.speakers[index] = value; draft!.edited = true })
    }
    private func segmentBinding<T>(_ index: Int, id: UUID, _ path: WritableKeyPath<SpeakerSegment, T>, fallback: T) -> Binding<T> {
        .init(get: { draft?.segments.indices.contains(index) == true && draft!.segments[index].id == id ? draft!.segments[index][keyPath: path] : fallback }, set: { value in guard draft?.segments.indices.contains(index) == true, draft!.segments[index].id == id else { return }; draft!.segments[index][keyPath: path] = value; draft!.edited = true })
    }
    private func segmentRow(_ index: Int, snapshot: SpeakerDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("片段 \(index + 1) · \(SpeakerDocument.time(snapshot.segments[index].start))–\(SpeakerDocument.time(snapshot.segments[index].end))").font(.caption).foregroundStyle(.secondary)
            Button("回听这一段") { model.speech.cancel(); audition.play(record, store: store, start: snapshot.segments[index].start, end: snapshot.segments[index].end) }.frame(minHeight: 44)
            Picker("说话人", selection: segmentBinding(index, id: snapshot.segments[index].id, \.speaker, fallback: 0)) { ForEach(snapshot.speakers.indices, id: \.self) { Text(snapshot.speakers[$0]).tag($0) } }.pickerStyle(.menu)
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("开始秒").font(.caption).foregroundStyle(.secondary)
                    TextField("开始秒", value: segmentBinding(index, id: snapshot.segments[index].id, \.start, fallback: 0), format: .number).keyboardType(.decimalPad).agentField().accessibilityLabel("片段 \(index + 1) 开始秒").focused($focusedField, equals: "start-\(index)")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("结束秒").font(.caption).foregroundStyle(.secondary)
                    TextField("结束秒", value: segmentBinding(index, id: snapshot.segments[index].id, \.end, fallback: 0), format: .number).keyboardType(.decimalPad).agentField().accessibilityLabel("片段 \(index + 1) 结束秒").focused($focusedField, equals: "end-\(index)")
                }
            }
            labeledField("片段 \(index + 1) 文字", text: segmentBinding(index, id: snapshot.segments[index].id, \.text, fallback: ""), placeholder: "核对这一段文字", id: "text-\(index)", lines: 2...8)
            Button("移除这一段", role: .destructive) { guard draft?.segments.indices.contains(index) == true, draft!.segments[index].id == snapshot.segments[index].id else { return }; draft!.segments.remove(at: index); draft!.edited = true }.frame(minHeight: 44)
        }.agentPanel().disabled(busy)
    }
    private func saveConfiguration() {
        focusedField = nil
        do { try SpeakerStore.save(settings, key: key); saved = settings; savedKey = key; error = ""; message = key.isEmpty ? "音频 Key 已清除" : "音频配置已保存，未发起请求" } catch { self.error = error.localizedDescription }
    }
    private func check(_ token: UUID, settings expected: SpeakerSettings, key expectedKey: String) throws {
        try Task.checkCancellation()
        guard generation == token, phase == .active, settings == expected, saved == expected, key == expectedKey, savedKey == expectedKey, saved == SpeakerStore.load(),
              store.error.isEmpty, store.records.first(where: { $0.id == record.id }) == record else { throw CancellationError() }
    }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil; approval = nil }
    private func prepare() {
        focusedField = nil
        guard !busy, phase == .active, settings == saved, key == savedKey, SpeakerSettings.validKey(key) else { error = "请先保存有效的独立音频配置和 Key"; return }
        cancel(); let token = UUID(); generation = token; let expected = settings; let expectedKey = key; error = ""; message = ""
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                _ = try expected.validate(); try check(token, settings: expected, key: expectedKey)
                let url = try store.audioURL(record.id); let duration = record.duration
                let reader = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= SpeakerDocument.maxFileBytes else { throw AgentError.message("所选录音超过 25 MB 或文件无效，未上传") }
                    let file = try AVAudioFile(forReading: url); let actual = Double(file.length) / file.processingFormat.sampleRate
                    guard actual.isFinite, abs(actual - duration) <= 0.15 else { throw AgentError.message("录音时长与记录不匹配，未上传") }
                    let data = try Data(contentsOf: url); try Task.checkCancellation()
                    guard data.count == size else { throw AgentError.message("读取期间音频变化，请重新核对") }; return data
                }
                let data = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
                try check(token, settings: expected, key: expectedKey)
                approval = .init(id: token, record: record, settings: expected, key: expectedKey, audio: data)
            } catch { if generation == token && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func start(_ value: SpeakerApproval) {
        guard approval?.id == value.id, !busy else { return }
        do { try check(value.id, settings: value.settings, key: value.key) } catch { cancel(); return }
        approval = nil
        work = Task {
            defer { if generation == value.id { work = nil } }
            do {
                try check(value.id, settings: value.settings, key: value.key)
                guard SpeakerDocument.digest(try Data(contentsOf: store.audioURL(record.id))) == SpeakerDocument.digest(value.audio) else { throw AgentError.message("录音在确认后发生变化，未继续处理") }
                let result = try await SpeakerClient(settings: value.settings, key: value.key).analyze(audio: value.audio, recordingID: record.id, duration: record.duration)
                try check(value.id, settings: value.settings, key: value.key)
                guard SpeakerDocument.digest(try Data(contentsOf: store.audioURL(record.id))) == result.audioSHA256 else { throw AgentError.message("响应返回时录音已变化，未替换草稿") }
                draft = result; message = "分段已返回，请回听核对；尚未保存"; error = ""
            } catch { if generation == value.id && !Task.isCancelled { self.error = "分段处理未完成，旧草稿保留。" + error.localizedDescription } }
        }
    }
    private func export(_ value: SpeakerDocument, json: Bool) {
        do { try value.validate(); document = ArtifactDocument(data: json ? try JSONEncoder().encode(value) : Data(try value.exportText().utf8)); exportType = json ? .json : .plainText; exportName = ArtifactFiles.filename(record.title) + (json ? "-分段.json" : "-分段.txt"); exporting = true } catch { self.error = error.localizedDescription }
    }
}
