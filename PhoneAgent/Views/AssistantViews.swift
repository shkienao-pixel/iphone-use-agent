import SwiftUI
import UIKit

enum DictationPhase { case preparing, listening, finalizing, idle }

// Shared by task and chat composers. Recording stays on the current canvas.
struct InlineVoiceBar: View {
    let phase: DictationPhase
    let transcript: String
    let status: String
    let error: String
    let startedAt: Date
    let onCancel: () -> Void
    let onFinish: () -> Void
    let onRetry: () -> Void
    var onSend: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var working: Bool { phase == .preparing || phase == .finalizing }
    private var retry: Bool { phase == .idle && transcript.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !transcript.isEmpty {
                Text(transcript).font(.body).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("正在转写：" + transcript)
            }
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    AgentComposerLeadingSlot()
                }.buttonStyle(AgentPressStyle()).accessibilityLabel("取消本次听写")
                VStack(alignment: .leading, spacing: 4) {
                    if phase == .listening {
                        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
                            let time = context.date.timeIntervalSince(startedAt)
                            HStack(spacing: 4) {
                                ForEach(0..<13, id: \.self) { index in
                                    Capsule().fill(AgentPalette.ink.opacity(0.86))
                                        .frame(width: 3, height: 22)
                                        .scaleEffect(x: 1, y: reduceMotion ? 0.5 : 0.2 + abs(sin(time * 3 + Double(index) * 0.8)) * 0.8)
                                }
                            }
                        }.accessibilityHidden(true)
                    } else {
                        HStack(spacing: 6) {
                            if working { ProgressView().controlSize(.mini) }
                            Text(phase == .finalizing ? "正在转写…" : phase == .preparing ? "准备麦克风…" : "听写已停止")
                                .font(.subheadline).lineLimit(1)
                        }
                    }
                    Text(error.isEmpty ? (phase == .listening ? "正在听" : status) : error)
                        .font(.caption2)
                        .foregroundStyle(error.isEmpty ? Color.secondary : Color.red)
                        .lineLimit(error.isEmpty ? 1 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if phase == .listening {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.accessibilityHidden(true)
                }
                if !retry {
                    Button(action: onFinish) {
                        Image(systemName: "pause.fill").frame(width: 44, height: 44)
                    }.buttonStyle(.plain).disabled(working)
                        .accessibilityLabel("暂停并转成文字")
                }
                Button(action: retry ? onRetry : (onSend ?? onFinish)) {
                    Image(systemName: retry ? "mic.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(AgentPalette.onContrast)
                        .frame(width: 44, height: 44).background(AgentPalette.ink, in: Circle())
                }.buttonStyle(AgentPressStyle()).disabled(working).opacity(working ? 0.4 : 1)
                    .accessibilityLabel(retry ? "重新开始听写" : "发送语音文字")
            }
            .foregroundStyle(.primary).padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: AgentInputMetrics.height)
            .agentGlass(in: AgentInputMetrics.shape)
        }
    }
}

@MainActor
struct InlineDictationComposer: View {
    @ObservedObject var speech: VoiceController
    @Binding var draft: String
    let isCurrent: () -> Bool
    let isVisible: Bool
    let onEnd: (String?) -> Void
    let onSend: (() -> Void)?
    @Environment(\.scenePhase) private var appPhase
    @State private var originalDraft: String
    @State private var awaitingStart = true
    @State private var hasBeenVisible = false
    @State private var startedAt = Date()
    @State private var resolved = false
    @State private var active = true
    @State private var finishTask: Task<Void, Never>?
    init(speech: VoiceController, draft: Binding<String>, isVisible: Bool, isCurrent: @escaping () -> Bool, onSend: (() -> Void)? = nil, onEnd: @escaping (String?) -> Void) {
        _speech = ObservedObject(wrappedValue: speech); _draft = draft
        _originalDraft = State(initialValue: draft.wrappedValue)
        self.isVisible = isVisible; self.isCurrent = isCurrent; self.onEnd = onEnd; self.onSend = onSend
    }
    private var phase: DictationPhase {
        if awaitingStart { return .preparing }
        if speech.preparing { return .preparing }
        if speech.finalizing { return .finalizing }
        if speech.listening { return .listening }
        return .idle
    }
    var body: some View {
        InlineVoiceBar(phase: phase, transcript: awaitingStart ? "" : speech.transcript, status: awaitingStart ? "本机语音识别" : speech.status,
                       error: awaitingStart ? "" : speech.error, startedAt: startedAt,
                       onCancel: cancel, onFinish: { finish(send: false) }, onRetry: retry, onSend: { finish(send: true) })
            .task(id: isVisible && appPhase == .active) {
                guard isVisible, appPhase == .active, awaitingStart else { return }
                hasBeenVisible = true
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-review") { return }
                #endif
                // Siri can still own the audio route when it hands the task to the app.
                let deadline = Date().addingTimeInterval(6)
                while UIApplication.shared.applicationState != .active && Date() < deadline {
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard !Task.isCancelled, active, isCurrent(), UIApplication.shared.applicationState == .active else { return }
                guard isVisible else { retainPartialAndClose(); return }
                awaitingStart = false; startedAt = Date(); speech.start()
            }
            .onChange(of: speech.listening) { _, listening in if listening { startedAt = Date() } }
            .onChange(of: isVisible) { _, visible in if !visible && hasBeenVisible { retainPartialAndClose() } }
            .onChange(of: appPhase) { _, phase in if phase == .background { retainPartialAndClose() } }
            .onDisappear {
                active = false; finishTask?.cancel(); finishTask = nil
                guard isCurrent() else { return }
                if !resolved { retainPartialAndClose() }
                speech.onSilence = nil; speech.cancel()
            }
    }
    private func retry() {
        guard active, !resolved, isCurrent(), isVisible else { return }
        startedAt = Date(); speech.start()
    }
    private func cancel() {
        guard isCurrent() else { return }
        resolved = true; finishTask?.cancel(); finishTask = nil
        speech.onSilence = nil; speech.cancel(); onEnd(nil)
    }
    private func finish(send: Bool) {
        guard finishTask == nil, !awaitingStart, !speech.preparing, !speech.finalizing, isCurrent() else { return }
        finishTask = Task {
            await speech.finish()
            guard !Task.isCancelled, active, isCurrent() else { return }
            let value = Self.appending(speech.transcript, to: originalDraft)
            resolved = true; draft = value; finishTask = nil
            let hasTranscript = !speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            speech.onSilence = nil; speech.cancel(); onEnd(value)
            if send && hasTranscript { onSend?() }
        }
    }
    private func retainPartialAndClose() {
        guard !resolved, isCurrent() else { return }
        resolved = true; finishTask?.cancel(); finishTask = nil
        let value = awaitingStart ? originalDraft : Self.appending(speech.transcript, to: originalDraft)
        draft = value; speech.onSilence = nil; speech.cancel(); onEnd(value)
    }
    static func appending(_ transcript: String, to draft: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return draft }
        return draft.isEmpty ? text : draft + (draft.last?.isWhitespace == true ? "" : "\n") + text
    }
}

struct AssistantView: View {
    /// A general app opening never implies a particular train or bus is selected.
    private func openGroundTravel(_ specificURL: URL?, mode: CtripGroundTravelMode) {
        let searchURL = mode == .bus ? "https://3g.ctrip.com/webapp/bus" : "https://3g.ctrip.com/webapp/train/"
        guard let target = specificURL ?? URL(string: searchURL) else {
            model.notice = "无法打开携程，请在携程中查询车次。"
            return
        }
        UIApplication.shared.open(target, options: [:]) { accepted in
            if !accepted {
                Task { @MainActor in model.notice = "未能打开携程查询，请检查网络或稍后重试。" }
            }
        }
    }
    let reviewDictation: DictationPhase?
    let allowsDictation: Bool
    var canvasBackground: Color = AgentPalette.background
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.scenePhase) private var phase
    let onModelSetup: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentationID = UUID()
    @State private var followingConversation = true
    @State private var flightHandoffVisibilityEpoch = UUID()
    @State private var conversationUserScrolling = false
    @State private var lastSpokenMessage: UUID?
    @State private var useCamera = false
    @State private var memoryEditor: MemoryEditorSeed?
    @State private var continuous = false
    @State private var dictating = false
    @State private var dictationID = UUID()
    @State private var dictationConversationID: UUID?
    @State private var videoMode = false
    @State private var observationFocus = ""
    @State private var observationInterval: Double = 15
    @State private var speakObservations = false
    @State private var videoQuestionTask: Task<Void, Never>?
    @State private var videoQuestionID = UUID()
    @State private var mediaConversationID: UUID?
    @State private var clear = false
    @StateObject private var attachmentDraft = ComposerAttachmentStore()
    @State private var attachmentConversationID: UUID?
    @State private var showAttachmentPhotos = false
    @State private var showAttachmentFiles = false
    @State private var realtime = false
    @State private var webSearch = false
    @State private var transcriptTask: Task<Void, Never>?
    @FocusState private var composing: Bool
    private var flightOpeningVisible: Bool {
        allowsDictation && !clear && !realtime && !webSearch && memoryEditor == nil &&
            !showAttachmentPhotos && !showAttachmentFiles
    }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.conversation.messages.isEmpty || composing || dictating {
                        SelaConversationAvatar(motion: model.conversation.loading ? "thinking" : dictating && model.speech.listening ? "listening" : "idle")
                    }
                    if useCamera {
                        if let frame = model.camera.frame { Image(uiImage: frame.image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 18)) }
                        else if model.camera.preparing { ProgressView("正在准备相机") }
                        Toggle("连续视频观察", isOn: $videoMode).tint(AgentPalette.accent)
                        if videoMode { videoObservationPanel }
                        else { Text("提问时发送一张相机画面；不上传音频或视频流，离开此页即关闭。") .font(.caption).foregroundStyle(.secondary) }
                        if !model.camera.error.isEmpty { AgentNotice(text: model.camera.error, error: true) }
                    }
                    if let frame = model.conversation.selectedFrame, !useCamera {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(uiImage: frame.image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            HStack {
                                Text("所选画面 · \(frame.capturedAt.formatted(date: .omitted, time: .standard))").font(.caption)
                                Button("保存记忆") { memoryEditor = MemoryEditorSeed(value: AssistantMemory(title: "画面记忆", text: "", kind: .screen, source: "整屏共享 · " + frame.capturedAt.formatted()), image: frame.image) }.font(.caption).frame(minHeight: 44)
                                Spacer(); Button("移除") { model.conversation.selectFrame(nil) }.font(.caption).frame(minHeight: 44)
                            }.foregroundStyle(.secondary)
                            Text("发送问题时会附上这张画面。切换页面后，请重新选择。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.agentPanel()
                    }
                    if model.conversation.messages.isEmpty && !composing && !dictating {
                        conversationEmptyState
                    }
                    ForEach(model.conversation.messages) { message in
                        HStack(alignment: .top) {
                            if message.role == "user" { Spacer(minLength: 36) }
                            VStack(alignment: .leading, spacing: 10) {
                                if message.role == "assistant" {
                                    if let sessionID = message.didiSimulationID {
                                        // A tall ride card opens below the floating navigation controls.
                                        Color.clear.frame(height: 76).id("didi-top-" + message.id.uuidString)
                                        let conversationID = model.conversation.currentConversationID
                                        DidiConversationCard(sessionID: sessionID, messageID: message.id,
                                            conversationID: conversationID,
                                            active: model.conversation.isCurrentDidiSimulation(sessionID: sessionID,
                                                messageID: message.id, conversationID: conversationID),
                                            onSummary: { summary in
                                                _ = model.conversation.updateDidiSimulation(sessionID: sessionID,
                                                    messageID: message.id, conversationID: conversationID, summary: summary)
                                            },
                                            onEnd: {
                                                _ = model.conversation.endDidiSimulation(sessionID: sessionID,
                                                    messageID: message.id, conversationID: conversationID)
                                            },
                                            onRestart: { _ = model.conversation.startDidiSimulation() })
                                    } else if let card = message.paotuiCard {
                                        if message.text.trimmingCharacters(in: .whitespacesAndNewlines) != card.title.trimmingCharacters(in: .whitespacesAndNewlines) {
                                            SelaMarkdownText(text: message.text)
                                        }
                                        PaotuiConversationCards(card: card,
                                            presentation: { model.conversation.paotuiCardPresentation(card) },
                                            onSelect: { model.conversation.selectPaotui(card, $0) })
                                    } else if message.groundQuery != nil,
                                              let mode = CtripGroundTravelMode(rawValue: message.groundTravelMode ?? "") {
                                        CtripGroundTravelResult(text: message.text, mode: mode) { url in
                                            openGroundTravel(url, mode: mode)
                                        }
                                    } else {
                                    let offers = model.conversation.flightOffers(for: message)
                                    if !offers.isEmpty {
                                        let flightOrigin = CtripFlightHandoffOrigin(
                                            conversationID: model.conversation.currentConversationID, messageID: message.id)
                                        CtripFlightCards(offers: offers,
                                            recommendation: model.conversation.flightRecommendation(for: message),
                                            showsSortExplanation: CtripFlightCardPresentationPolicy.showsSortExplanation(
                                                messageID: message.id, messages: model.conversation.messages),
                                            onBook: { offer in
                                                let handoffEpoch = flightHandoffVisibilityEpoch
                                                model.bookFlight(offer, origin: flightOrigin,
                                                    isVisible: { handoffEpoch == flightHandoffVisibilityEpoch })
                                            })
                                    } else if message.flightQuery != nil || message.flightOffers != nil {
                                        CtripFlightEmptyResult(text: message.text)
                                    } else { SelaMarkdownText(text: ConversationQueuePresentation.messageText(message.text, taskLinked: message.taskID != nil)) }
                                    }
                                }
                                else { Text(message.text).font(.body).lineSpacing(4).textSelection(.enabled) }
                                if let taskID = message.taskID { ConversationTaskCard(taskID: taskID, savedResult: message.nativeTaskResult) }
                                if let attachments = message.attachments, !attachments.isEmpty {
                                    ComposerAttachmentList(attachments: attachments)
                                }
                                if let frames = message.cameraFrames {
                                    Text("相机序列 · \(frames) 帧 · \(Int((message.cameraDuration ?? 0).rounded())) 秒")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if message.role == "assistant", message.didiSimulationID == nil {
                                    let references = model.conversation.references(for: message)
                                    if !references.isEmpty {
                                        conversationReferences(references)
                                    }
                                    messageActions(message)
                                }
                            }
                            .frame(maxWidth: message.role == "assistant" ? .infinity : nil, alignment: .leading)
                            .padding(.horizontal, message.role == "user" ? 14 : 0)
                            .padding(.vertical, message.role == "user" ? 12 : 0)
                            .background(message.role == "user" ? AgentPalette.userBubble : Color.clear, in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier((message.role == "assistant" ? "conversation.message.body." : "conversation.user.bubble.") + message.id.uuidString)

                            if message.role != "user" { Spacer(minLength: 0) }
                        }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded { composing = false })
                            .id(message.id)
                    }
                    if model.conversation.loading, !model.conversation.contextReferences.isEmpty {
                        conversationReferences(model.conversation.contextReferences, pending: true)
                    }
                    if model.conversation.loading {
                        HStack {
                            ProgressView(); Text("正在思考…").foregroundStyle(.secondary); Spacer()
                            Button("新任务") { stopVoice(); stopVideo(); model.conversation.newConversation(); composing = true }
                                .accessibilityIdentifier("conversation.newTaskWhileWaiting")
                            Button("取消") { stopVoice(); model.liveCamera.stop(); model.conversation.cancel() }
                        }.font(.subheadline)
                    }
                    if model.conversation.backgroundRequestCount > 0 {
                        Text("另有 \(model.conversation.backgroundRequestCount) 个对话正在处理，可以继续开始新任务。")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("conversation.backgroundWork")
                    }
                    if !model.conversation.error.isEmpty { AgentNotice(text: model.conversation.error, error: true) }
                    if let failedMode = model.conversation.currentGroundFailureMode,
                       let mode = CtripGroundTravelMode(rawValue: failedMode) {
                        Button("打开携程普通查询") { openGroundTravel(nil, mode: mode) }
                            .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                            .accessibilityIdentifier("ground.failure.search")
                    }
                    if !model.conversation.storageError.isEmpty { AgentNotice(text: model.conversation.storageError, error: true) }
                    if !model.notice.isEmpty { AgentNotice(text: model.notice) }
                    if model.speech.usingAudio && !dictating { Text(model.speech.status).font(.footnote).foregroundStyle(.secondary) }
                    if !model.speech.error.isEmpty && !dictating { AgentNotice(text: model.speech.error, error: true) }
                    if continuous { Text("点按麦克风开始。停顿后自动发送识别文字，播报结束再听下一句；离开此页或 App 后停止。")
                        .font(.caption).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("bottom")
                }.id(model.conversation.currentConversationID)
                    .padding(.horizontal, 16).padding(.vertical, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, _ in
                        guard followingConversation else { return }
                        let conversationID = model.conversation.currentConversationID
                        DispatchQueue.main.async {
                            guard followingConversation, model.conversation.currentConversationID == conversationID else { return }
                            reader.scrollTo("bottom", anchor: .bottom)
                        }
                    }
            }.scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectHidden(for: .top)
                .onScrollPhaseChange { _, phase in
                    conversationUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                } action: { _, nearBottom in
                    // Growing task cards and keyboard dismissal are not a user
                    // choosing to leave the latest message.
                    if nearBottom { followingConversation = true }
                    else if conversationUserScrolling { followingConversation = false }
                }
                .overlay(alignment: .bottom) {
                    if !followingConversation && !model.conversation.messages.isEmpty {
                        SelaScrollLatestButton {
                            followingConversation = true
                            withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("bottom", anchor: .bottom) }
                        }.padding(.bottom, 12)
                    }
                }
                .onChange(of: model.conversation.messages.count) { _, _ in
                    if let latest = model.conversation.messages.last, latest.didiSimulationID != nil {
                        followingConversation = false
                        let id = latest.id
                        DispatchQueue.main.async { reader.scrollTo("didi-top-" + id.uuidString, anchor: .top) }
                    } else {
                        if model.conversation.messages.last?.role == "user" { followingConversation = true }
                        if followingConversation { reader.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .onChange(of: model.engine.state) { _, _ in
                    if followingConversation { reader.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.conversation.currentConversationID) { _, _ in
                    followingConversation = true
                    reader.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear {
                    if let latest = model.conversation.messages.last, latest.didiSimulationID != nil {
                        followingConversation = false
                        let id = latest.id
                        DispatchQueue.main.async { reader.scrollTo("didi-top-" + id.uuidString, anchor: .top) }
                    } else { reader.scrollTo("bottom", anchor: .bottom) }
                }
        }
        .onChange(of: composing || dictating) { _, active in
            if model.conversation.ownsPresentation(presentationID) { model.assistantInputActive = active }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if !attachmentDraft.items.isEmpty || attachmentDraft.importing || !attachmentDraft.error.isEmpty {
                    ComposerAttachmentTray(store: attachmentDraft)
                        .disabled(model.conversation.loading || videoQuestionTask != nil)
                }
                if continuous {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                            Text("连续语音")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }.padding(.horizontal, 10)
                }

                if let phase = reviewDictation {
                    InlineVoiceBar(phase: phase, transcript: phase == .preparing ? "" : "帮我总结一下这张画面。",
                                   status: "本机语音识别", error: "", startedAt: Date().addingTimeInterval(-8),
                                   onCancel: {}, onFinish: {}, onRetry: {})
                } else if dictating {
                    let token = dictationID
                    let conversationID = dictationConversationID
                    InlineDictationComposer(speech: model.speech, draft: $model.conversation.draft,
                                            isVisible: allowsDictation && !clear && !realtime && !webSearch && memoryEditor == nil,
                                            isCurrent: { model.conversation.ownsPresentation(presentationID) && dictating && dictationID == token && model.conversation.currentConversationID == conversationID },
                                            onSend: { send() }) { _ in
                        guard model.conversation.ownsPresentation(presentationID), dictationID == token, model.conversation.currentConversationID == conversationID else { return }
                        transcriptTask?.cancel(); transcriptTask = nil
                        dictationID = UUID(); dictating = false; dictationConversationID = nil
                        if model.voiceMode == .question { model.voiceMode = nil }
                    }.id(token).transition(.opacity)
                } else {
                    SelaComposerLayout(expanded: composing) {
                        SelaAttachmentMenu(onPhotos: { composing = false; stopVoice(); showAttachmentPhotos = true },
                                           onFiles: { composing = false; stopVoice(); showAttachmentFiles = true })
                            .disabled(attachmentDraft.importing || model.conversation.loading || videoQuestionTask != nil)

                        TextField("Ask Sela", text: $model.conversation.draft, prompt: Text("Ask Sela").foregroundStyle(AgentPalette.placeholder), axis: .vertical)
                            .lineLimit(1...5)
                            .font(.body)
                            .focused($composing)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .disabled(model.conversation.loading || videoQuestionTask != nil || model.speech.preparing || model.speech.finalizing || model.speech.listening)
                            .accessibilityLabel("和 Sela 聊天")
                            .accessibilityIdentifier("composer.text")

                        HStack(spacing: 8) {
                        if composing || (model.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentDraft.items.isEmpty && !model.conversation.loading && videoQuestionTask == nil) {
                            Button {
                                if model.speech.usingAudio { stopVoice() } else { startListening() }
                            } label: {
                                Image(systemName: model.speech.listening ? "waveform" : "mic.fill")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(AgentPalette.ink.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(AgentPressStyle())
                            .accessibilityLabel(model.speech.usingAudio ? "结束语音" : "语音提问")
                            .accessibilityIdentifier("composer.mic")
                            .disabled(model.conversation.loading || videoQuestionTask != nil || attachmentDraft.importing)
                            .transition(.opacity)
                        }
                        if !model.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentDraft.items.isEmpty || model.conversation.loading || videoQuestionTask != nil {
                            Button {
                                if model.conversation.loading || videoQuestionTask != nil { stopVoice(); stopVideo(); model.conversation.cancel() }
                                else { send() }
                            } label: {
                                Image(systemName: model.conversation.loading || videoQuestionTask != nil ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 44, height: 44)
                                    .background(AgentPalette.accent, in: Circle())
                            }
                            .buttonStyle(AgentPressStyle())
                            .disabled(attachmentDraft.importing && !model.conversation.loading && videoQuestionTask == nil)
                            .accessibilityLabel(model.conversation.loading || videoQuestionTask != nil ? "停止生成回答" : "发送问题")
                            .accessibilityIdentifier("composer.send")
                            .transition(.opacity)
                        }
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("composer.actions")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: AgentInputMetrics.height)
                    .modifier(SelaHomeComposerSurface(active: model.conversation.messages.isEmpty))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer.container")
                    .accessibilityValue(composing ? "两行输入" : "单行输入")
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.conversation.draft.isEmpty)
                }
            }
            .agentComposerLeadingGlyph(recording: reviewDictation != nil || dictating)
            .padding(.horizontal, 16)
            .padding(.top, model.conversation.messages.isEmpty ? 12 : 4)
            .padding(.bottom, 8)
            .background(canvasBackground)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: dictating)
        }
        .composerAttachmentPicker(store: attachmentDraft, showPhotos: $showAttachmentPhotos, showFiles: $showAttachmentFiles,
                                  selectionID: model.conversation.currentConversationID)
        .sheet(item: $memoryEditor) { MemoryEditor(seed: $0) }
        .sheet(isPresented: $realtime) { RealtimeView() }
        .sheet(isPresented: $webSearch) { WebSearchView() }
        .confirmationDialog("清空本次对话？", isPresented: $clear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { resetConversation() }
        }
        .onChange(of: model.conversation.currentConversationID) { previousID, _ in
            DidiChatSimulationRegistry.shared.end(conversationID: previousID)
            synchronizeConversationDraft()
            guard model.conversation.ownsPresentation(presentationID) else { return }
            stopConversationMedia()
        }
        .onChange(of: model.conversation.retryAttachments, initial: true) { _, attachments in
            if !attachments.isEmpty, attachmentDraft.items.isEmpty { attachmentDraft.replace(attachments) }
        }
        .onChange(of: attachmentDraft.items) { _, attachments in
            guard model.conversation.ownsPresentation(presentationID) else { return }
            if let conversationID = attachmentConversationID {
                model.conversation.retainDraftAttachments(attachments, conversationID: conversationID)
            }
        }
        .onAppear {
            let questionRequested = model.voiceMode == .question
            synchronizeConversationDraft()
            if model.conversation.claimPresentation(presentationID) { stopConversationMedia() }
            model.conversation.setFlightOpeningVisible(flightOpeningVisible, owner: presentationID)
            model.assistantInputActive = composing || dictating
            if questionRequested { model.voiceMode = .question; startListening() }
        }
        .onChange(of: flightOpeningVisible) { _, visible in
            model.conversation.setFlightOpeningVisible(visible, owner: presentationID)
        }
        .onChange(of: model.voiceMode) { _, mode in
            if model.conversation.ownsPresentation(presentationID), mode == .question { startListening() }
        }
        .onChange(of: model.conversation.messages.last?.id) { _, _ in
            guard model.conversation.ownsPresentation(presentationID) else { return }
            guard let last = model.conversation.messages.last, last.role == "assistant", !model.conversation.loading, lastSpokenMessage != last.id, model.voiceMode == nil else { return }
            lastSpokenMessage = last.id
            if continuous || model.settings.spokenFeedback == true {
                model.speech.speak(last.text) { if continuous && phase == .active { startListening() } }
            }
        }
        .onChange(of: useCamera) { _, enabled in
            guard model.conversation.ownsPresentation(presentationID) else { return }
            stopVideo()
            if enabled || mediaConversationID == model.conversation.currentConversationID { model.conversation.cancel() }
            model.conversation.selectFrame(nil)
            if enabled {
                mediaConversationID = model.conversation.currentConversationID
                model.camera.start(); model.camera.setSequenceEnabled(videoMode)
            } else {
                mediaConversationID = nil; videoMode = false; model.camera.stop()
            }
        }
        .onChange(of: videoMode) { _, enabled in
            guard model.conversation.ownsPresentation(presentationID) else { return }
            stopVideo()
            if useCamera && mediaConversationID == model.conversation.currentConversationID { model.conversation.cancel() }
            model.conversation.selectFrame(nil); model.camera.setSequenceEnabled(enabled && useCamera)
        }
        .onChange(of: model.camera.running) { _, running in
            if model.conversation.ownsPresentation(presentationID), !running { stopVideo() }
        }
        .onChange(of: model.conversation.loading) { wasLoading, loading in
            guard model.conversation.ownsPresentation(presentationID) else { return }
            if wasLoading, !loading, model.conversation.error.isEmpty, model.conversation.draft.isEmpty {
                attachmentDraft.clear()
            }
            if !loading, model.liveCamera.running, model.liveCamera.suspended {
                if model.conversation.error.isEmpty && phase == .active && videoMode && useCamera { startVideo() }
                else { model.liveCamera.stop() }
            }
        }
        .onChange(of: model.liveCamera.results.last?.id) { _, _ in
            guard model.conversation.ownsPresentation(presentationID) else { return }
            if speakObservations, phase == .active, !model.speech.usingAudio, !model.conversation.loading, let result = model.liveCamera.results.last { model.speech.speak(result.text) }
        }
        .onChange(of: continuous) { _, enabled in
            if model.conversation.ownsPresentation(presentationID), !enabled { stopVoice() }
        }
        .onChange(of: phase) { _, value in
            if model.conversation.ownsPresentation(presentationID), value == .background {
                continuous = false; useCamera = false; stopVideo(); model.camera.stop(); stopVoice()
                model.conversation.cancelScreenBoundRequest(); model.conversation.selectFrame(nil)
            }
        }
        .onDisappear {
            flightHandoffVisibilityEpoch = UUID()
            // The outgoing page can disappear after its replacement has already
            // sent a request. Only the current presenter may clear shared state.
            guard model.conversation.releasePresentation(presentationID) else {
                attachmentDraft.cancelImport(); transcriptTask?.cancel(); videoQuestionTask?.cancel()
                return
            }
            DidiChatSimulationRegistry.shared.end(conversationID: model.conversation.currentConversationID)
            composing = false; model.assistantInputActive = false
            if let conversationID = attachmentConversationID {
                model.conversation.retainDraftAttachments(attachmentDraft.items, conversationID: conversationID)
            }
            attachmentDraft.cancelImport(); showAttachmentPhotos = false; showAttachmentFiles = false; continuous = false; useCamera = false; stopVideo(); model.camera.stop(); stopVoice(); model.conversation.cancelScreenBoundRequest(); model.conversation.selectFrame(nil)
        }
    }
    private var conversationEmptyState: some View {
        VStack(spacing: 18) {
            Image("SelaMascot")
                .resizable().scaledToFit().frame(width: 136, height: 136)
                .accessibilityHidden(true)
            Text("想聊点什么？").font(.largeTitle.weight(.semibold)).tracking(-0.8)
            Text("聊天、查资料、操作手机，\n都可以在这里接着说。")
                .font(.subheadline).foregroundStyle(AgentPalette.secondaryText)
                .multilineTextAlignment(.center).lineSpacing(5)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { conversationSuggestions }
                VStack(spacing: 8) { conversationSuggestions }
            }
            Button {
                composing = false
                stopConversationMedia()
                _ = model.conversation.startDidiSimulation()
            } label: {
                Label("体验打车模拟", systemImage: "car.side")
                    .font(.subheadline)
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(AgentPalette.surface, in: Capsule())
            }
            .buttonStyle(AgentPressStyle())
            .accessibilityIdentifier("conversation.didiSimulation")
        }.frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 24)
    }
    @ViewBuilder private var conversationSuggestions: some View {
        conversationSuggestion("周末去哪儿玩", icon: "sun.max")
        conversationSuggestion("今天吃点什么", icon: "fork.knife")
    }
    private func conversationSuggestion(_ text: String, icon: String) -> some View {
        Button {
            model.conversation.draft = text
            composing = true
        } label: {
            Label(text, systemImage: icon)
                .font(.caption).foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func conversationReferences(_ references: [AssistantConversationContextHit], pending: Bool = false) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(references) { reference in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: reference.sourceKind == .task ? "checklist" : "bubble.left")
                                .font(.caption2)
                            Text(reference.title).font(.caption.weight(.medium)).lineLimit(2)
                        }
                        Text(reference.excerpt).font(.caption).foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(4).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 8)
        } label: {
            Label("\(pending ? "正在参考" : "已参考") \(references.count) 条记录", systemImage: "text.bubble")
                .font(.caption)
        }
        .tint(AgentPalette.secondaryText)
        .foregroundStyle(AgentPalette.secondaryText)
        .padding(12)
        .background(AgentPalette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
    private var videoObservationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("希望关注什么，例如：这个物体如何变化", text: $observationFocus, axis: .vertical).lineLimit(1...3).agentField()
                .accessibilityLabel("连续观察关注内容").disabled(model.liveCamera.running)
            Picker("观察间隔", selection: $observationInterval) { Text("15 秒").tag(15.0); Text("30 秒").tag(30.0); Text("60 秒").tag(60.0) }
                .pickerStyle(.segmented).disabled(model.liveCamera.running)
            Text("开启后定期发送最近 12 秒内最多 8 张抽样画面，持续分析变化。提问会优先处理，回答后继续。自动观察最多 10 分钟或 40 次；多帧会增加模型用量，快速变化可能漏采。")
                .font(.caption).foregroundStyle(.secondary)
            Button { if model.liveCamera.running { stopVideo() } else { startVideo() } } label: {
                Label(model.liveCamera.running ? "停止连续观察" : "开始连续观察", systemImage: model.liveCamera.running ? "stop.fill" : "video.fill")
            }.buttonStyle(AgentButtonStyle(primary: !model.liveCamera.running)).disabled(!model.liveCamera.running && (model.conversation.loading || videoQuestionTask != nil))
            Text(model.liveCamera.state).font(.footnote).foregroundStyle(.secondary)
            if model.liveCamera.loading { ProgressView("正在分析画面变化") }
            if !model.liveCamera.error.isEmpty { AgentNotice(text: model.liveCamera.error, error: true) }
            if let result = model.liveCamera.results.last {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近观察 · \(result.through.formatted(date: .omitted, time: .standard)) · \(result.frames) 帧").font(.caption).foregroundStyle(.secondary)
                    Text(result.text).textSelection(.enabled)
                    Button("保存观察记忆") { memoryEditor = MemoryEditorSeed(value: AssistantMemory(title: String(result.text.prefix(30)), text: result.text, source: "相机抽样观察 · " + result.through.formatted())) }.font(.caption).frame(minHeight: 44)
                }.agentPanel()
            }
            Toggle("空闲时播报观察结果", isOn: $speakObservations).tint(AgentPalette.accent)
            Text("需要模型接口支持多张图片。语音提问使用本机转写，不发送音频；此模式下说“暂停”“停止”“继续”控制连续观察。关闭模式会清除抽样缓存。") .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func resetConversation() {
        attachmentDraft.clear(); showAttachmentPhotos = false; showAttachmentFiles = false
        stopVoice(); stopVideo(); model.liveCamera.stop(clearResults: true); model.camera.stop()
        useCamera = false; continuous = false
        model.conversation.clear()
    }
    private func stopConversationMedia() {
        mediaConversationID = nil
        // An old dictation must never write into the newly opened conversation.
        dictationID = UUID(); dictating = false; dictationConversationID = nil
        transcriptTask?.cancel(); transcriptTask = nil
        model.speech.onSilence = nil; model.speech.cancel()
        if model.voiceMode == .question { model.voiceMode = nil }
        stopVideo(); model.liveCamera.stop(clearResults: true); model.camera.stop()
        useCamera = false; continuous = false
        model.conversation.selectFrame(nil)
    }
    private func startVideo() {
        guard model.modelReady else { model.notice = "请先连接支持多图的模型服务"; onModelSetup(); return }
        guard model.consentReady else { model.requestConsent(); return }
        guard videoMode, useCamera, phase == .active else { return }
        model.liveCamera.start(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint), focus: observationFocus,
                               interval: observationInterval, camera: model.camera, currentConfiguration: { [weak model] in model?.settings ?? AgentSettings() })
    }
    private func stopVideo() { videoQuestionID = UUID(); videoQuestionTask?.cancel(); videoQuestionTask = nil; model.liveCamera.stop() }
    private func selectScreen() {
        guard model.capture.running else { model.notice = "请先在屏幕共享中开启整屏，然后切换到想问的页面再回来"; return }
        guard let frame = model.capture.lastBackgroundFrame ?? model.capture.frame, frame.fullDisplay else { model.notice = "没有可用的整屏画面"; return }
        model.conversation.selectFrame(frame); model.notice = ""
    }
    private func startListening() {
        guard model.conversation.ownsPresentation(presentationID), !dictating, model.recordingAudioOwner == nil, !model.conversation.loading, videoQuestionTask == nil else { return }
        composing = false; model.speech.cancel()
        let token = UUID()
        let conversationID = model.conversation.currentConversationID
        dictationID = token; dictating = true; dictationConversationID = conversationID
        model.speech.onSilence = continuous ? {
            guard model.conversation.ownsPresentation(presentationID), dictating, dictationID == token, model.conversation.currentConversationID == conversationID else { return }
            finishAndSend()
        } : nil
    }
    private func stopVoice() {
        if dictating && dictationConversationID == model.conversation.currentConversationID && (model.speech.listening || model.speech.finalizing) {
            model.conversation.draft = InlineDictationComposer.appending(model.speech.transcript, to: model.conversation.draft)
        }
        dictationID = UUID(); dictating = false; dictationConversationID = nil
        transcriptTask?.cancel(); transcriptTask = nil; model.speech.onSilence = nil; model.speech.cancel()
        if model.voiceMode == .question { model.voiceMode = nil }
    }
    private func finishAndSend() {
        guard model.conversation.ownsPresentation(presentationID), transcriptTask == nil, dictating, let conversationID = dictationConversationID,
              conversationID == model.conversation.currentConversationID else { return }
        let token = dictationID
        transcriptTask = Task {
            await model.speech.finish()
            guard model.conversation.ownsPresentation(presentationID), dictationID == token, model.conversation.currentConversationID == conversationID else { return }
            guard !Task.isCancelled, dictating, phase == .active else { transcriptTask = nil; return }
            model.conversation.draft = model.speech.transcript
            dictationID = UUID(); dictating = false; dictationConversationID = nil
            if model.voiceMode == .question { model.voiceMode = nil }
            transcriptTask = nil; send()
        }
    }
    private func messageActions(_ message: AssistantMessage) -> some View {
        let taskRetry = message.taskID.map { model.recoverableTask($0) != nil && !model.taskRecoveryBusy } ?? false
        let available = !dictating && !useCamera && !model.speech.usingAudio && videoQuestionTask == nil && !attachmentDraft.importing &&
            (message.taskID == nil ? model.conversation.canRetry(message) : taskRetry)
        return HStack(spacing: 6) {
            Button {
                UIPasteboard.general.string = message.text
                model.notice = "已复制回答"
            } label: { Label("复制", systemImage: "doc.on.doc").frame(width: 44, height: 44) }
                .accessibilityIdentifier("response.copy")
            Button {
                composing = false
                if let taskID = message.taskID { _ = model.retryTask(taskID) }
                else {
                    _ = model.conversation.retry(message, settings: model.settings,
                        apiKey: SettingsStore.apiKey(for: model.settings.endpoint), memories: model.memories,
                        taskRecords: model.history.records)
                }
            } label: { Label("重试", systemImage: "arrow.clockwise").frame(width: 44, height: 44) }
                .disabled(!available).accessibilityIdentifier("response.retry")
                .accessibilityHint(available ? "重新生成回答，保留原回答" : "仅最新且保留原始输入的回答可重试；任务可在任务卡中继续")
        }.font(.caption).foregroundStyle(.secondary).labelStyle(.iconOnly).buttonStyle(AgentPressStyle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.response.actions." + message.id.uuidString)
    }
    /// Local drafts follow the selected chat even while another mounted view
    /// owns shared media. Replacing invalidates any old picker/import generation.
    private func synchronizeConversationDraft() {
        let conversationID = model.conversation.currentConversationID
        guard attachmentConversationID != conversationID else { return }
        attachmentConversationID = conversationID
        attachmentDraft.replace(model.conversation.retryAttachments)
        showAttachmentPhotos = false; showAttachmentFiles = false
        followingConversation = true
        lastSpokenMessage = model.conversation.messages.last?.id
    }

    private func send() {
        guard model.conversation.ownsPresentation(presentationID) else { return }
        synchronizeConversationDraft()
        composing = false
        if model.speech.listening { finishAndSend(); return }
        guard !attachmentDraft.importing, !showAttachmentPhotos, !showAttachmentFiles else { return }
        let originalDraft = model.conversation.draft
        let attachments = attachmentDraft.items
        let value = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.isEmpty ? "请帮我看看这些附件" : originalDraft
        let conversationID = model.conversation.currentConversationID
        if videoMode && useCamera, let command = VoiceCommand.parse(value) {
            // These controls apply only to the explicitly enabled camera observation.
            // Plain conversation text never routes to the phone task executor.
            if [.pause, .stop, .handoff].contains(command) {
                stopVoice(); model.conversation.draft = ""
                stopVideo(); model.notice = "连续观察已停止"
                if command == .stop { useCamera = false; model.camera.stop() }
                return
            }
            if command == .resume { stopVoice(); model.conversation.draft = ""; startVideo(); return }
        }
        guard model.modelReady else { stopVoice(); model.notice = "请先连接模型服务"; onModelSetup(); return }
        guard model.consentReady else { stopVoice(); model.requestConsent(); return }
        if useCamera {
            if videoMode {
                guard videoQuestionTask == nil else { return }
                let token = UUID(); videoQuestionID = token
                let configuration = model.settings
                videoQuestionTask = Task {
                    defer { if videoQuestionID == token { videoQuestionTask = nil } }
                    await model.liveCamera.suspendForQuestion()
                    guard model.conversation.ownsPresentation(presentationID), !Task.isCancelled, videoQuestionID == token, phase == .active, videoMode, useCamera,
                          model.camera.running, model.conversation.currentConversationID == conversationID else { return }
                    guard model.conversation.draft == originalDraft, attachmentDraft.items == attachments else { model.notice = "问题已变化，请重新发送"; model.liveCamera.stop(); return }
                    guard model.settings.endpoint == configuration.endpoint, model.settings.model == configuration.model,
                          PrivacyConsent.recipient(model.settings) == PrivacyConsent.recipient(configuration),
                          PrivacyConsent.allowed(model.settings) else { model.notice = "模型或授权已变化，请重新提问"; model.liveCamera.stop(); return }
                    let frames = model.camera.sequence()
                    do { _ = try CameraObservationWindow.content(question: value, frames: frames, now: ProcessInfo.processInfo.systemUptime) }
                    catch { model.notice = error.localizedDescription; model.liveCamera.stop(); return }
                    model.conversation.selectSequence(frames)
                    model.conversation.draft = value
                    if !model.conversation.send(settings: configuration, apiKey: SettingsStore.apiKey(for: configuration.endpoint), memories: model.memories,
                                                observationContext: model.liveCamera.results.last?.text ?? "", taskRecords: model.history.records, attachments: attachments) {
                        model.liveCamera.stop()
                    }
                }
                return
            }
            guard let frame = model.camera.frame, Date().timeIntervalSince(frame.capturedAt) < 2 else { model.notice = "相机没有新画面，请检查权限或关闭相机模式后重试"; return }
            model.conversation.selectFrame(frame)
        }
        model.conversation.draft = value
        model.conversation.send(settings: model.settings, apiKey: SettingsStore.apiKey(for: model.settings.endpoint), memories: model.memories,
                                taskRecords: model.history.records, attachments: attachments)
    }
}
