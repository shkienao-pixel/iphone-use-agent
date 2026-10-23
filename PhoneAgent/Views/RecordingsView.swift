import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

private enum RecordingNavigation { case close, choose(UUID), library, startRecording, importAudio }

struct RecordingsView: View {
    @ObservedObject var store: RecordingStore
    let onUseText: (RecordingTextSeed) -> Void
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = RecordingAudioController()
    @State private var newTitle = "新录音"
    @State private var confirmRecord = false
    @State private var selected: UUID?
    @State private var speakerRecord: LocalRecording?
    @State private var editedTitle = ""
    @State private var text = ""
    @State private var error = ""
    @State private var message = ""
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var deleteTarget: RecordingProblem?
    @State private var confirmDelete = false
    @State private var confirmTranscribe = false
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var exportName = "录音文字.txt"
    @State private var exportType = UTType.plainText
    @State private var importing = false
    @State private var confirmingDiscard = false
    @State private var pendingNavigation: RecordingNavigation?
    @State private var workLabel = "正在本机处理"
    @FocusState private var focusedField: String?
    private var recordHasChanges: Bool { record.map { editedTitle != $0.title || text != $0.transcript } ?? false }
    private var hasChanges: Bool { newTitle != "新录音" || recordHasChanges }
    private var record: LocalRecording? { store.records.first { $0.id == selected } }
    private var busy: Bool { audio.busy || work != nil || exporting }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recordingNotices
                    if let record {
                        Button { requestNavigation(.library) } label: { Label("全部录音", systemImage: "chevron.left") }.frame(minHeight: 44)
                        detail(record)
                    } else {
                        recordingControls
                        Text("\(store.records.count) 段录音 · \(ByteCountFormatter.string(fromByteCount: Int64(store.audioBytes), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        if store.records.isEmpty {
                            AgentEmptyState(title: "还没有录音", detail: "开始录音，或导入已有的音频。", icon: "waveform")
                        } else { savedRecordings }
                    }
                    unfinishedRecordings
                    AgentHelp(title: "保存与使用说明", text: "音频和文字保存在受系统保护且排除 iCloud 备份的本机目录。删除会同时移除音频和文字，但不删除你已经导出的副本或另存的记忆。本机转写不区分说话人；可选择独立分段入口，返回标签需回听核对。")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("录音历史").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { requestNavigation(.close) } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .interactiveDismissDisabled(hasChanges || busy)
            .alert("放弃未保存的录音修改？", isPresented: $confirmingDiscard) {
                Button("继续编辑", role: .cancel) { pendingNavigation = nil }
                Button("放弃修改", role: .destructive) {
                    let action = pendingNavigation; pendingNavigation = nil
                    if let record { choose(record) }
                    if let action { navigate(action) }
                }
            } message: { Text("未保存的标题和文字会丢失，已保存的录音保持不变。") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): importAudio(url)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .confirmationDialog("确认保存本次原始音频？", isPresented: $confirmRecord, titleVisibility: .visible) {
                Button("同意并开始本机录音") { cancelWork(); selected = nil; audio.record(title: newTitle, store: store); newTitle = "新录音" }
            } message: { Text("标题：\(newTitle)\n麦克风音频将保存在这台 iPhone，供回听和本机转写，不上传模型。请先告知参与者并获得必要同意。此确认仅适用于这次录音。") }
            .confirmationDialog("删除音频及文字记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    do { try store.remove(target.id, pending: target.pending); if selected == target.id { selected = nil; text = "" }; message = "本机音频及文字记录已删除" }
                    catch { self.error = error.localizedDescription }; deleteTarget = nil
                }
            } message: { Text("已导出到其他位置的副本和另存的记忆不会一起删除。") }
            .confirmationDialog("重新转写会替换当前文字草稿，继续？", isPresented: $confirmTranscribe, titleVisibility: .visible) {
                Button("重新本机转写") { if let record { transcribe(record) } }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: exportType, defaultFilename: exportName) { result in
                if case .failure(let e) = result { error = e.localizedDescription }; document = nil
            }
            .sheet(item: $speakerRecord) { value in SpeakerView(record: value, store: store) { seed in onUseText(seed); dismiss() } }
            .onAppear {
                store.reload()
                audio.reserve = { model.reserveRecordingAudio($0) }; audio.release = { model.releaseRecordingAudio($0) }
                audio.prepareAudio = { try await model.pip.suspendForVoice() }
            }
            .onChange(of: phase) { _, value in
                if value == .background || (value == .inactive && audio.mode != .preparing) { cancelWork(); audio.stop(interrupted: true); confirmRecord = false }
            }
            .onDisappear { cancelWork(); audio.stop(interrupted: true) }
    }
    @ViewBuilder private var recordingControls: some View {
                    AgentPageIntro(title: "记录声音", subtitle: "本机保存与转写，随后核对文字。", icon: "waveform")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("新录音标题").font(.caption).foregroundStyle(.secondary)
                        TextField("这次录音的标题", text: $newTitle).agentField().accessibilityLabel("新录音标题").focused($focusedField, equals: "newTitle").disabled(busy)
                    }
                    HStack(spacing: 12) {
                    Button("开始本机录音") { requestNavigation(.startRecording) }.buttonStyle(AgentButtonStyle()).disabled(busy || !store.error.isEmpty || newTitle.count > 80 || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("导入音频文件") { requestNavigation(.importAudio) }.buttonStyle(AgentButtonStyle(primary: false)).disabled(busy || !store.error.isEmpty)
                    }
                    AgentHelp(title: "导入与录音限制", text: "导入文件会转换为本机 M4A 副本，源文件不改动。不会自动回听、转写或上传；输入与副本均限 30 MB / 10 分钟。")
                    if work != nil { ProgressView(workLabel); Button("取消处理") { cancelWork() }.frame(minHeight: 44) }
                    if audio.busy {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(audio.state).font(.headline)
                            HStack {
                                Text(time(audio.seconds)).font(.system(.title, design: .monospaced).bold())
                                Spacer()
                                if audio.mode == .recording || audio.mode == .paused {
                                    HStack(alignment: .center, spacing: 5) { ForEach(0..<5) { n in Capsule().fill(AgentPalette.ink).frame(width: 5, height: max(5, audio.level * Double(12 + n * 6))) } }.frame(height: 40).animation(.linear(duration: 0.1), value: audio.level)
                                }
                            }
                            if audio.mode == .recording || audio.mode == .paused { Button(audio.mode == .paused ? "继续录音" : "暂停录音") { audio.pauseOrResume() }.frame(minHeight: 44) }
                            Button(audio.mode == .playing ? "停止回听" : "结束并保存录音") { audio.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                        }.agentPanel()
                    }
    }
    @ViewBuilder private var recordingNotices: some View {
                    if !audio.state.isEmpty && !audio.busy { AgentNotice(text: audio.state) }
                    if !audio.error.isEmpty { AgentNotice(text: audio.error, error: true) }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if !store.error.isEmpty { AgentNotice(text: store.error, error: true); Button("重新读取录音库") { store.reload() }.disabled(busy) }
                    if store.trashCount > 0 {
                        Button("清理 \(store.trashCount) 项待删除音频") { do { try store.clearTrash(); message = "待删除文件已清理" } catch { self.error = "清理失败，请核对文件权限或空间后重试" } }.disabled(busy).frame(minHeight: 44)
                    }
    }
    @ViewBuilder private var savedRecordings: some View {
                    ForEach(store.records) { r in
                        Button { if selected != r.id { requestNavigation(.choose(r.id)) } } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(r.title).font(.headline)
                                Text("\(r.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(time(r.duration))\(r.interrupted ? " · 已中断" : "")").font(.caption).foregroundStyle(.secondary)
                                Text(r.transcript.isEmpty ? "尚未转写" : String(r.transcript.prefix(80))).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(selected == r.id ? AgentPalette.inset : .clear, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).disabled(busy)
                    }
    }
    @ViewBuilder private var unfinishedRecordings: some View {
                    if !store.pending.isEmpty { Text("未完成录音").font(.headline); Text("录音或保存中断后保留的原文件。完整可读的音频可以恢复；无法恢复的文件仍可导出或删除。") .font(.caption).foregroundStyle(.secondary) }
                    ForEach(store.pending) { p in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(p.title).font(.headline)
                            Button("核对音频并恢复") { recover(p.id) }.disabled(busy).frame(minHeight: 44)
                            Button("导出音频") { exportAudio(p.id, pending: true, title: p.title) }.disabled(busy).frame(minHeight: 44)
                            Button("删除未完成录音", role: .destructive) { deleteTarget = .init(id: p.id, pending: true); confirmDelete = true }.disabled(busy).frame(minHeight: 44)
                        }.agentPanel()
                    }
                    ForEach(store.problems) { problem in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("无法读取文字记录 · \(problem.id.uuidString.prefix(8))")
                            Button("导出可读取的音频") { exportAudio(problem.id, pending: problem.pending, title: "待核对录音") }.disabled(busy).frame(minHeight: 44)
                            Button("删除损坏记录", role: .destructive) { deleteTarget = problem; confirmDelete = true }.disabled(busy).frame(minHeight: 44)
                        }.agentPanel()
                    }
    }
    private func time(_ seconds: Double) -> String { let n = max(0, Int(seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d", n / 60, n % 60) }
    private func choose(_ r: LocalRecording) { selected = r.id; text = r.transcript; editedTitle = r.title; error = ""; message = "" }
    private func detail(_ r: LocalRecording) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("核对这段录音").font(.title3.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("录音标题").font(.caption).foregroundStyle(.secondary)
                TextField("填写标题", text: $editedTitle).agentField().accessibilityLabel("录音标题").focused($focusedField, equals: "title").disabled(busy)
            }
            Button("保存标题") { do { try store.rename(r.id, title: editedTitle); editedTitle = record?.title ?? editedTitle; focusedField = nil; message = "标题已保存" } catch { self.error = error.localizedDescription } }.disabled(busy).frame(minHeight: 44)
            Button("回听录音") { model.speech.cancel(); audio.play(r, store: store) }.disabled(busy).frame(minHeight: 44)
            Button("本机转写") { focusedField = nil; if !text.isEmpty { confirmTranscribe = true } else { transcribe(r) } }.disabled(busy).frame(minHeight: 44)
            Button("说话人分段与核对") { speakerRecord = r }.disabled(busy).frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 8) {
                Text("核对转写文字").font(.caption).foregroundStyle(.secondary)
                TextField("填写或修正文字", text: $text, axis: .vertical).lineLimit(6...18).agentField().accessibilityLabel("核对转写文字").focused($focusedField, equals: "text").disabled(busy)
            }
            Text("\(text.count)/12000 字 · \(r.textOrigin == .localRecognition ? "上次保存为本机转写" : r.textOrigin == .edited ? "上次保存为人工修改" : "尚未保存文字")").font(.caption).foregroundStyle(.secondary)
            Button("保存核对后的文字") { do { try store.saveText(r.id, text: text, origin: .edited); focusedField = nil; message = "文字已保存" } catch { self.error = error.localizedDescription } }.disabled(busy || text.count > 12000).frame(minHeight: 44)
            Button("将当前文字用于纪要") {
                onUseText(.init(title: editedTitle, text: text, source: "本机录音文字 · \(r.title) · \(r.createdAt.formatted())")); audio.stop(); dismiss()
            }.buttonStyle(AgentButtonStyle(primary: false)).disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 12000 || editedTitle.isEmpty || editedTitle.count > 80)
            Text("此步骤只把文字放入工作台，不上传音频，也不自动调用模型。未点保存的修改不会写入录音库。") .font(.caption).foregroundStyle(.secondary)
            Button("导出音频") { exportAudio(r.id, title: r.title) }.disabled(busy).frame(minHeight: 44)
            Button("导出当前文字") {
                document = ArtifactDocument(data: Data((editedTitle + "\n\n" + text).utf8)); exportType = .plainText; exportName = ArtifactFiles.filename(editedTitle) + ".txt"; exporting = true
            }.disabled(busy || text.count > 12000 || editedTitle.count > 80).frame(minHeight: 44)
            Button("删除录音", role: .destructive) { deleteTarget = .init(id: r.id, pending: false); confirmDelete = true }.disabled(busy).frame(minHeight: 44)
        }.agentPanel()
    }
    private func requestNavigation(_ action: RecordingNavigation) {
        focusedField = nil
        let needsConfirmation: Bool
        if case .close = action { needsConfirmation = hasChanges } else { needsConfirmation = recordHasChanges }
        if needsConfirmation { pendingNavigation = action; confirmingDiscard = true } else { navigate(action) }
    }
    private func navigate(_ action: RecordingNavigation) {
        switch action {
        case .close: cancelWork(); audio.stop(interrupted: true); dismiss()
        case .library: selected = nil; text = ""; editedTitle = ""
        case .choose(let id): if let value = store.records.first(where: { $0.id == id }) { choose(value) }
        case .startRecording: confirmRecord = true
        case .importAudio: importing = true
        }
    }
    private func importAudio(_ url: URL) {
        cancelWork(); focusedField = nil; let token = UUID(); generation = token
        let title = String(url.deletingPathExtension().lastPathComponent.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        error = ""; message = ""; workLabel = "正在转换本机音频副本"
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                let result = try await RecordingImport.convert(url)
                try Task.checkCancellation()
                guard generation == token, phase == .active else { return }
                let value = try store.importAudio(result.data, title: title.isEmpty ? "导入音频" : title, duration: result.duration)
                choose(value); message = "已保存 M4A 音频副本，未回听、转写或上传"
            } catch { if generation == token && !Task.isCancelled { self.error = "音频未导入：" + error.localizedDescription } }
        }
    }
    private func cancelWork() { generation = UUID(); work?.cancel(); work = nil }
    private func transcribe(_ r: LocalRecording) {
        guard phase == .active else { return }; cancelWork(); let token = UUID(); generation = token; error = ""; focusedField = nil; workLabel = "正在本机转写"
        work = Task {
            defer { if generation == token { work = nil } }
            do {
                let result = try await LocalFileRecognition.audioText(store.audioURL(r.id)); try Task.checkCancellation()
                guard generation == token, phase == .active, selected == r.id, store.records.contains(where: { $0.id == r.id }) else { return }
                try store.saveText(r.id, text: result, origin: .localRecognition); text = result; message = "本机转写已保存，请核对；没有识别说话人身份"
            } catch { if generation == token && !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func recover(_ id: UUID) {
        do {
            let file = try AVAudioFile(forReading: store.audioURL(id, pending: true))
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let record = try store.finalize(id, duration: duration, interrupted: true); choose(record); message = "已恢复可读取的音频；可能缺少结束前的部分，请回听核对"
        } catch { self.error = "无法恢复这段音频，原文件仍保留，可导出或删除" }
    }
    private func exportAudio(_ id: UUID, pending: Bool = false, title: String) {
        do {
            let url = try store.audioURL(id, pending: pending); cancelWork(); let token = UUID(); generation = token; focusedField = nil; workLabel = "正在准备音频导出"
            let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); let value = try Data(contentsOf: url); try Task.checkCancellation(); return value }
            work = Task {
                defer { if generation == token { work = nil } }
                do {
                    let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard generation == token, phase == .active else { return }; document = ArtifactDocument(data: value); exportType = .mpeg4Audio; exportName = ArtifactFiles.filename(title) + ".m4a"; exporting = true
                } catch { if generation == token && !Task.isCancelled { self.error = "无法导出音频，原记录未删除" } }
            }
        } catch { self.error = "没有可导出的有效音频文件" }
    }
}

// A user-selected file is snapshotted before conversion. Only the closed M4A
// output is committed to the library; every temporary file is removed on exit.
private enum RecordingImport {
    struct Result { let data: Data; let duration: Double }
    static func convert(_ url: URL) async throws -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("PhoneAgentAudio-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        var protectedFolder = folder; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try protectedFolder.setResourceValues(flags)
        let source = folder.appendingPathComponent("source").appendingPathExtension(url.pathExtension)
        let reader = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= LocalRecording.maxAudioBytes else { throw AgentError.message("请选择不超过 30 MB 的有效音频文件") }
            let data = try Data(contentsOf: url); try Task.checkCancellation()
            guard data.count == size else { throw AgentError.message("音频读取时发生变化，请重新选择") }
            try data.write(to: source, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, duration <= LocalRecording.maxDuration, !audioTracks.isEmpty, videoTracks.isEmpty else { throw AgentError.message("需为不超过 10 分钟的纯音频文件，没有截断导入") }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw AgentError.message("系统无法转换这类音频") }
        let output = folder.appendingPathComponent("converted.m4a")
        exporter.metadata = []
        try await exporter.export(to: output, as: .m4a)
        try Task.checkCancellation()
        let values = try output.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= LocalRecording.maxAudioBytes else { throw AgentError.message("转换后的音频超过 30 MB，未保存") }
        let file = try AVAudioFile(forReading: output)
        let actual = Double(file.length) / file.processingFormat.sampleRate
        guard actual.isFinite, actual > 0, actual <= LocalRecording.maxDuration, abs(actual - duration) <= 0.15 else { throw AgentError.message("转换后时长不匹配，未保存") }
        let data = try Data(contentsOf: output); try Task.checkCancellation()
        guard data.count == size else { throw AgentError.message("转换文件发生变化，未保存") }
        return Result(data: data, duration: actual)
    }
}
