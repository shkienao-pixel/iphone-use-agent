import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

private struct RealtimeApproval: Identifiable { let id = UUID(); let settings: RealtimeSettings; let camera: Bool }
struct RealtimeView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    private enum Field: Hashable { case provider, endpoint, model, voice, key }
    @FocusState private var focusedField: Field?
    @StateObject private var session = RealtimeSession()
    @StateObject private var camera = CameraService()
    @State private var settings = RealtimeStore.load()
    @State private var saved = RealtimeStore.load()
    @State private var key = ""
    @State private var savedKey = ""
    @State private var shareCamera = false
    @State private var approval: RealtimeApproval?
    @State private var error = ""
    @State private var message = ""
    @State private var showSettings = false
    @State private var document: ArtifactDocument?
    @State private var exporting = false
    private enum DiscardAction { case close, restart }
    @State private var discardAction = DiscardAction.close
    @State private var confirmingDiscard = false
    @State private var exportedReplies: [String] = []
    @State private var exportSnapshot: [String]?
    private var replySnapshot: [String] { session.transcripts.map { $0.id + "\u{0}" + $0.text } }
    private var configurationChanged: Bool { settings != saved || key != savedKey }
    private var repliesChanged: Bool { !session.transcripts.isEmpty && replySnapshot != exportedReplies }
    private var hasChanges: Bool { configurationChanged || repliesChanged }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 12) {
                        AgentOrb(size: 104, active: session.mode == .live, idleIcon: "waveform")
                        Text(session.status).font(.title2.weight(.semibold))
                        Text("用声音提问，随时打断回复。") .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 18)
                    DisclosureGroup("实时服务配置", isExpanded: $showSettings) {
                        VStack(alignment: .leading, spacing: 14) {
                            field("服务商名称") {
                                TextField("填写实时服务商", text: $settings.provider).agentField().accessibilityLabel("实时服务商").focused($focusedField, equals: .provider)
                            }
                            field("WebSocket 接口地址") {
                                TextField("wss://…/v1/realtime", text: $settings.endpoint, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).agentField().accessibilityLabel("实时 WebSocket 地址").focused($focusedField, equals: .endpoint)
                            }
                            field("实时模型 ID") {
                                TextField("填写服务商提供的实时模型 ID", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("实时模型").focused($focusedField, equals: .model)
                            }
                            field("声音名称") {
                                TextField("填写服务商支持的声音", text: $settings.voice).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("实时声音").focused($focusedField, equals: .voice)
                            }
                            field("独立 API Key") {
                                SecureField("粘贴实时服务 API Key", text: $key).textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled().agentField().accessibilityLabel("实时服务自己的 API Key").focused($focusedField, equals: .key)
                            }
                            Button("保存实时配置") { focusedField = nil; save() }.buttonStyle(AgentButtonStyle(primary: false))
                            Text("接口不填 /chat/completions，不含查询参数；App 单独加入模型参数。Key 与文字模型、搜索 Key 分开，绑定这条实时地址。不会更换现有任务模型。服务支持的模型与声音名称需按服务文档填写。") .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.disabled(session.busy)
                    Toggle("本次允许手动分享相机帧", isOn: $shareCamera).disabled(session.busy)
                    Text("相机不会自动传图。连通后手动选择并发送当前帧，最多 20 帧；这是带时间的静态图片，不是视频流。") .font(.caption).foregroundStyle(.secondary)
                    if session.busy { Text("\(session.seconds) 秒 / 最多 5 分钟 · 已尝试分享 \(session.cameraShares)/20 帧").font(.caption).foregroundStyle(.secondary) }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    if !session.error.isEmpty { AgentNotice(text: session.error, error: true) }
                    if !message.isEmpty { AgentNotice(text: message) }
                    if session.mode == .live && shareCamera {
                        if let frame = camera.frame { Image(uiImage: frame.image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 18)) }
                        if camera.running {
                            Button("把这一帧加入下次提问") {
                                guard let frame = camera.sequence().last else { error = "请等待一张新的相机帧"; return }; session.share(jpeg: frame.jpeg, capturedAt: frame.capturedAt)
                            }.buttonStyle(AgentButtonStyle(primary: false)).disabled(session.cameraShares >= 20)
                        } else { Button("开启相机预览") { camera.start(); camera.setSequenceEnabled(true) }.frame(minHeight: 44).disabled(camera.preparing) }
                        Button("关闭相机预览") { camera.stop() }.frame(minHeight: 44)
                        if !camera.error.isEmpty { AgentNotice(text: camera.error, error: true) }
                    }
                    ForEach(session.transcripts) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("助手回复文字").font(.caption).foregroundStyle(.secondary)
                            Text(entry.text).textSelection(.enabled)
                        }.agentPanel()
                    }
                    if !session.transcripts.isEmpty {
                        Button("导出回复文字 TXT") {
                            let text = "实时对话服务：\(saved.provider)\n\(saved.endpoint)\n模型：\(saved.model)\n服务回复文字，可能包含未播放部分；不是逐字核对的录音转写。原始音频与相机图片不保存。\n\n" + session.transcripts.map(\.text).joined(separator: "\n\n")
                            focusedField = nil; exportSnapshot = replySnapshot
                            document = ArtifactDocument(data: Data(text.utf8)); exporting = true
                        }.disabled(session.busy).frame(minHeight: 44)
                    }
                    AgentHelp(title: "运行与数据说明", text: "只在前台运行，离开页面、后台、系统中断、配置变化或连接积压就结束，不自动重连。音频和相机帧不落盘；回复文字只留在本页内存，主动导出才保存。服务可能计费与保存音频 / 图片，请核对其政策。此模式不执行手机动作，不包含全局唤醒词。")
                }.padding(20)
            }.safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !session.busy {
                        Button("核对并开始实时对话") {
                            focusedField = nil; requestStart()
                        }.buttonStyle(AgentButtonStyle()).disabled(!canStart)
                        if !canStart { Text("填写并保存有效的实时配置和独立 API Key 后，才能开始对话。") .font(.caption).foregroundStyle(.secondary) }
                    } else {
                        HStack(spacing: 12) {
                            Button("结束对话") { session.stop(); camera.stop() }.buttonStyle(AgentButtonStyle())
                            Button("打断回复") { session.interruptReply() }.buttonStyle(AgentButtonStyle(primary: false)).disabled(session.mode != .live)
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12).background(AgentPalette.background)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("实时语音").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { requestClose() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focusedField = nil } }
            }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .interactiveDismissDisabled(hasChanges || session.busy || exporting)
            .alert(discardAction == .close ? "放弃未保存的实时配置或回复？" : "开始新的实时对话？", isPresented: $confirmingDiscard) {
                Button("继续留在此页", role: .cancel) { }
                Button(discardAction == .close ? "放弃并退出" : "替换上一轮回复", role: .destructive) {
                    if discardAction == .close { close() } else { prepareApproval() }
                }
            } message: {
                Text(discardAction == .close ? "未保存的配置、Key 草稿及未导出的回复会丢失。若此前正在实时对话，连接已停止；可以留在此页保存配置或导出回复。" : "确认开启后，上一轮回复文字会被新会话替换。可取消，先导出上一轮文字。")
            }
            .onAppear {
                saved = RealtimeStore.load(); settings = saved; savedKey = RealtimeStore.key(for: saved); key = savedKey
                session.reserve = model.reserveRecordingAudio; session.release = model.releaseRecordingAudio
                session.prepareAudio = { try await model.pip.suspendForVoice() }
                session.permission = { await AVAudioApplication.requestRecordPermission() }
                session.authorized = { phase == .active && settings == saved && saved == RealtimeStore.load() && key == savedKey && !savedKey.isEmpty }
                session.makeAudio = { RealtimeAudio() }
            }
            .onChange(of: phase) { _, value in if value == .background || (value != .active && session.mode == .live) { approval = nil; session.stop(); camera.stop() } }
            .onChange(of: session.mode) { _, value in if value == .idle { camera.stop() } }
            .onChange(of: settings) { _, _ in approval = nil; if session.busy { session.stop(); camera.stop() } }
            .onChange(of: key) { _, _ in approval = nil; if session.busy { session.stop(); camera.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in if session.busy { session.stop(reason: "系统音频中断，对话已结束"); camera.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in session.stop(); camera.stop() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue, session.mode == .live { session.stop(reason: "音频路线变化，对话已结束"); camera.stop() }
            }
            .onDisappear { session.stop(); camera.stop(); approval = nil; document = nil; exportSnapshot = nil }
            .sheet(item: $approval) { value in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("确认发送实时音频").font(.title.bold())
                            Text("接收方：\(value.settings.provider)\n\(value.settings.endpoint)\n模型：\(value.settings.model) · 声音：\(value.settings.voice)").font(.footnote).textSelection(.enabled)
                            Text("开启后，本次麦克风原始音频会持续发送给这条实时接口，服务直接返回声音。最长 5 分钟，不是本机转写；附近人的声音也可能被采集，请选择合适环境。每次会话可能计费。")
                            Text(value.camera ? "本次另行允许手动分享最多 20 张新相机帧及其时间；相机需要你开启预览，每张仍由你点发送。不会自动传图，也不上传原生视频流。" : "本次不发送相机画面。")
                            Text("独立实时 Key 只给这条接口；没有文字模型 / 搜索 Key、屏幕截图、任务、聊天历史或本机记忆。音频与图片不保存在本机，但服务的保留、转发和删除方式取决于其政策。结束无法撤回已经发送的数据。") .font(.footnote).foregroundStyle(.secondary)
                            Button("同意并开启这次会话") {
                                guard settings == value.settings, saved == value.settings, shareCamera == value.camera, key == savedKey, phase == .active else { error = "配置或页面变化，请重新核对"; approval = nil; return }
                                approval = nil; session.start(settings: value.settings, key: savedKey, includeCamera: value.camera)
                                if session.busy { exportedReplies = [] }
                            }.buttonStyle(AgentButtonStyle())
                        }.padding(20)
                    }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { approval = nil } } }
                }.tint(AgentPalette.accent).agentSheetStyle()
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: "实时回复.txt") { result in
                switch result {
                case .success:
                    if let exportSnapshot { exportedReplies = exportSnapshot }
                    error = ""; message = "回复文字已导出；配置请另外保存"
                case .failure(let e): error = e.localizedDescription
                }
                document = nil; exportSnapshot = nil
            }
    }
    private func requestClose() {
        focusedField = nil; approval = nil; if session.busy { session.stop() }; camera.stop()
        guard !exporting else { return }
        if hasChanges { discardAction = .close; confirmingDiscard = true } else { close() }
    }
    private func close() {
        session.stop(); camera.stop(); approval = nil; document = nil; exportSnapshot = nil; dismiss()
    }
    private func requestStart() {
        guard canStart else { error = "请先保存当前实时配置和独立 Key"; return }
        if repliesChanged { discardAction = .restart; confirmingDiscard = true } else { prepareApproval() }
    }
    private func prepareApproval() {
        guard !session.busy, canStart, phase == .active else { error = "配置或页面变化，请重新核对"; return }
        do { _ = try settings.request(key: key); error = ""; approval = .init(settings: settings, camera: shareCamera) } catch { self.error = error.localizedDescription }
    }
    private var canStart: Bool { settings == saved && key == savedKey && !key.isEmpty && (try? settings.request(key: key)) != nil }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func save() {
        do { try RealtimeStore.save(settings, key: key); saved = settings; savedKey = key; error = ""; message = key.isEmpty ? "实时 Key 已清除" : "实时配置已保存，未发起连接" } catch { self.error = error.localizedDescription }
    }
}
