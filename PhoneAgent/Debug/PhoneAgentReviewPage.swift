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
        case "device": ContentView(reviewDestination: .device)
        case "share": ContentView(reviewDestination: .screenShare)
        case "assistant": ContentView(reviewDestination: .assistant)
        case "memory": ContentView(reviewDestination: .memory)
        case "workbench": ContentView(reviewDestination: .workbench)
        case "queue": ContentView(reviewDestination: .queue)
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
#endif
