import SwiftUI

#if DEBUG
// Visual-only launch routes. Never start hardware, permissions, or network work.
struct PhoneAgentReviewPage: View {
    let name: String
    @EnvironmentObject private var model: PhoneAgentViewModel
    private var recording: LocalRecording {
        model.recordings.records.first ?? .init(id: UUID(), title: "产品讨论", createdAt: Date(), updatedAt: Date(), duration: 180, interrupted: false)
    }
    private var meeting: MeetingEditorSeed {
        let source = "周五完成首页设计。下周评审交互流程。"
        var notes = MeetingNotes.empty(title: "产品讨论")
        notes.summary = .init(text: "完成首页设计并准备交互评审。", quote: source)
        notes.points = [.init(text: "周五完成首页设计", quote: "周五完成首页设计。")]
        notes.actions = [.init(text: "评审交互流程", quote: "下周评审交互流程。", owner: nil, due: "下周")]
        return .init(source: source, sourceName: "会议记录", notes: notes)
    }
    var body: some View {
        page.tint(AgentPalette.accent).background(AgentPalette.background)
    }
    @ViewBuilder private var page: some View {
        switch name {
        case "settings": SettingsView(onBack: {})
        case "task": TaskDetailView(id: model.history.records.first?.id ?? UUID())
        case "conversation": ContentView(reviewConversation: model.history.records.first?.id)
        case "sidebar": ContentView(reviewConversation: model.history.records.first?.id, reviewSidebarOpen: true)
        case "tools": ContentView(reviewDestination: .tools, reviewConversation: model.history.records.first?.id)
        case "tools-apps": ContentView(reviewDestination: .appConnections)
        case "tools-native-health": ContentView(reviewDestination: .nativeAppConnection(.health))
        case "tools-models": ContentView(reviewDestination: .modelMemory)
        case "device": ContentView(reviewDestination: .device)
        case "share": ContentView(reviewDestination: .screenShare)
        case "assistant": ContentView(reviewDestination: .assistant)
        case "screen-queue": ScreenQueueReview()
        case "screen-queue-empty": TaskQueueView(allowsExecution: false)
        case "paotui-chat": PaotuiConversationReview()
        case "ctrip-cards": CtripFlightReview()
        case "memory": ContentView(reviewDestination: .memory)
        case "workbench": ContentView(reviewDestination: .workbench)
        case "workflows": WorkflowWorkspaceView(workflows: model.workflowServices)
        case "voice", "voice-listening": ContentView(reviewVoice: .listening)
        case "voice-preparing": ContentView(reviewVoice: .preparing)
        case "voice-finalizing": ContentView(reviewVoice: .finalizing)
        case "voice-error": ContentView(reviewVoice: .idle, reviewVoiceError: "语音识别中断，已保留识别文字")
        case "assistant-voice": ContentView(reviewDestination: .assistant, reviewVoice: .listening)
        case "memory-editor": MemoryEditor(seed: .init(value: .init(title: "我的偏好", text: "请优先使用简短、清晰的中文回复。")))
        case "realtime": RealtimeView()
        case "recordings": RecordingsView(store: model.recordings) { _ in }
        case "speaker": SpeakerView(record: recording, store: model.recordings) { _ in }
        case "meeting": MeetingNotesView(seed: meeting, onApply: { _ in }, onRetainDraft: { _ in })
        case "spreadsheet": SpreadsheetView(seed: .init(title: "计划", text: "项目\t状态\n首页设计\t已完成\n交互评审\t待进行"))
        case "search": WebSearchView()
        case "search-settings": NavigationStack { WebSearchSettingsView().navigationTitle("搜索服务").navigationBarTitleDisplayMode(.inline) }
        case "research": WebInvestigationView(initialQuestion: "")
        case "webpage": WebPageView(source: .init(id: 1, title: "阅读来源", url: URL(string: "https://example.com/article")!, excerpt: "", publishedLabel: nil, excerptShortened: false), onUse: { _ in })
        case "plan": TaskPlanView()
        case "preparation": PreparationView(navigate: { _ in })
        case "policy": DataPolicyView()
        case "consent": DataConsentView(onDecision: {})
        case "tool": ToolApprovalView(approval: .init(request: .init(operation: .reminder_create, title: "周五核对设计稿", notes: "确认界面和交互")))
        case "calibration": CalibrationView(model: .init(executor: model.executor))
        default:
            if name.hasPrefix("settings-") { SettingsView(reviewPage: String(name.dropFirst(9)), onBack: {}) }
            else { ContentView() }
        }
    }
}

/// Explicit review flags may seed an empty queue, never replace real records.
/// Execution stays disabled; reorder/pause/remove use the production queue APIs.
private struct ScreenQueueReview: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @State private var prepared = false
    var body: some View {
        TaskQueueView(allowsExecution: false)
            .onAppear {
                guard !prepared else { return }; prepared = true
                guard ProcessInfo.processInfo.arguments.contains("--screen-queue-seed"),
                      model.taskQueue.items.isEmpty, model.taskQueue.error.isEmpty else { return }
                var settings = AgentSettings()
                settings.endpoint = "https://queue-preview.invalid/v1/chat/completions"
                settings.model = "offline-preview"; settings.previewOnly = true
                settings.toolsOnly = false; settings.systemToolsEnabled = false
                let titles = ["整理旅行计划", "核对待办清单", "汇总收藏内容"]
                let ids = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003"]
                let fixtures = zip(ids, titles).map { id, title in
                    QueuedPhoneTask(record: .init(id: UUID(uuidString: id)!, title: title, goal: title,
                        outcome: .paused, summary: "尚未开始", executionLane: "screen"), settings: settings)
                }
                do { try model.taskQueue.transaction { values in values.append(contentsOf: fixtures) } }
                catch { model.notice = error.localizedDescription }
            }
    }
}

/// Explicit offline display route. No credentials, model, tools or App handoff.
private struct CtripFlightReview: View {
    struct Fixture: Decodable {
        var text: String?
        var query: String?
        var offers: [CtripFlightOffer]?
        var date: Date?
        var width: Double?
        var accessibilitySize: Bool?
    }
    private let fixture: Fixture?
    private let offers: [CtripFlightOffer]
    private let summary: CtripFlightRecommendation
    @State private var lastSelection = ""

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let selected = arguments.firstIndex(of: "--ctrip-case").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } ?? "actual16"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelaCtripReview/fixtures.json")
        let fixtures = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Fixture].self, from: $0) } ?? [:]
        fixture = fixtures[selected]
        let item = fixtures[selected]
        let text = item?.text ?? ""
        offers = item?.offers ?? CtripFlightParser.offers(text, query: item?.query ?? "", at: item?.date ?? Date(timeIntervalSince1970: 0))
        summary = CtripFlightParser.recommendation(text, representedBy: offers)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("离线界面回放").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ctrip.review")
                if fixture == nil { Text("未加载离线测试资料").accessibilityIdentifier("ctrip.fixtureMissing") }
                CtripFlightCards(offers: offers, recommendation: summary) { offer in lastSelection = offer.cardTitle }
                if !lastSelection.isEmpty {
                    Text("测试点击：" + lastSelection + "；未打开其他 App。")
                        .accessibilityIdentifier("ctrip.review.selection")
                }
            }.padding(16).frame(maxWidth: fixture?.width.map { CGFloat($0) } ?? .infinity)
                .frame(maxWidth: .infinity)
        }.environment(\.dynamicTypeSize, fixture?.accessibilitySize == true ? .accessibility3 : .large)
    }
}

#endif
