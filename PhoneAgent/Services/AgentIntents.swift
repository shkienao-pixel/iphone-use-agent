import Foundation
import AppIntents

struct StartCurrentPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "开始当前手机任务"
    static let description = IntentDescription("执行 Phone Agent 中保存的当前任务。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestVoiceTask(PhoneAgentViewModel.shared.goal)
        return .result(dialog: "\(message)")
    }
}

struct RunPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "执行手机任务"
    static let description = IntentDescription("把文字任务交给 Phone Agent，可用于固定口令或接收听写结果。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "任务", requestValueDialog: "你想让手机做什么？")
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("执行手机任务 \(\.$task)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestVoiceTask(task)
        return .result(dialog: "\(message)")
    }
}

struct StopPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "停止手机任务"
    static let description = IntentDescription("取消等待中的语音任务，停止当前执行并释放鼠标按键。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneAgentViewModel.shared.stop()
        PhoneAgentViewModel.shared.notice = "已通过 Siri 停止任务"
        PhoneAgentViewModel.shared.voiceRequestID = UUID()
        return .result(dialog: "已停止任务并取消待执行请求。")
    }
}

struct PausePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停手机任务"
    static let description = IntentDescription("取消旧计划并释放输入，保留当前任务进度。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.pauseTask()
        return .result(dialog: "\(message)")
    }
}

struct HandoffPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "接管手机任务"
    static let description = IntentDescription("暂停自动操作，由你手动处理，之后可以继续原任务。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.pauseTask(handoff: true)
        return .result(dialog: "\(message)")
    }
}

struct ResumePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "继续手机任务"
    static let description = IntentDescription("按原任务和最新补充重新观察，继续执行。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await PhoneAgentViewModel.shared.resumeVoiceTask()
        return .result(dialog: "\(message)")
    }
}

struct BeginTaskSupplementIntent: AppIntent {
    static let title: LocalizedStringResource = "补充当前任务"
    static let description = IntentDescription("先暂停当前任务，再打开补充要求的听写界面。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.beginVoice(.supplement)
        return .result(dialog: "\(message)")
    }
}

struct AmendPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "加入任务补充"
    static let description = IntentDescription("用于暂停后接收快捷指令的听写结果；加入后等待你继续。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "补充要求", requestValueDialog: "你想补充什么要求？") var text: String
    static var parameterSummary: some ParameterSummary { Summary("加入补充 \(\.$text)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.supplementTask(text)
        return .result(dialog: "\(message)")
    }
}

struct ListenPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "语音告诉助手"
    static let description = IntentDescription("打开 Phone Agent 本机听写，识别后可修改并提交任务。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = PhoneAgentViewModel.shared
        let message = model.beginVoice(model.engine.hasCurrentTask ? .supplement : .task)
        return .result(dialog: "\(message)")
    }
}

// Available as parameterized actions in Shortcuts. Existing App Shortcut phrases
// remain stable; queue controls require the authenticated foreground app.
struct QueuePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "将手机任务加入队列"
    static let description = IntentDescription("保存新任务，保留当前执行；运行队列后依次处理。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "任务", requestValueDialog: "要加入哪项任务？") var task: String
    static var parameterSummary: some ParameterSummary { Summary("将 \(\.$task) 加入手机任务队列") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestQueuedVoiceTask(task, priority: false)
        return .result(dialog: "\(message)")
    }
}
struct PrioritizePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "优先执行手机任务"
    static let description = IntentDescription("收到任务参数后暂停原任务，优先执行新任务，完成后继续原任务。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "任务", requestValueDialog: "要优先做什么？") var task: String
    static var parameterSummary: some ParameterSummary { Summary("优先执行 \(\.$task)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestQueuedVoiceTask(task, priority: true)
        return .result(dialog: "\(message)")
    }
}
struct RunPhoneQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "运行手机任务队列"
    static let description = IntentDescription("明确确认后继续下一项；有执行中的任务时，等待它完成。")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = PhoneAgentViewModel.shared
        guard model.taskQueue.pendingCount > 0 else { return .result(dialog: "队列没有待处理任务。") }
        model.runTaskQueue(); model.voiceRequestID = UUID()
        let message = model.queueStatus
        return .result(dialog: "\(message)")
    }
}

struct PhoneAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartCurrentPhoneTaskIntent(), phrases: [
            "Start the current task with \(.applicationName)",
            "Run my phone task with \(.applicationName)",
            "在 \(.applicationName) 中开始当前任务",
            "让 \(.applicationName) 开始干活"
        ], shortTitle: "开始当前任务", systemImageName: "play.fill")
        AppShortcut(intent: RunPhoneTaskIntent(), phrases: [
            "Run a new task with \(.applicationName)",
            "让 \(.applicationName) 执行手机任务"
        ], shortTitle: "执行手机任务", systemImageName: "text.bubble")
        AppShortcut(intent: StopPhoneTaskIntent(), phrases: [
            "Stop the task in \(.applicationName)",
            "Stop \(.applicationName)",
            "停止 \(.applicationName) 的任务"
        ], shortTitle: "停止任务", systemImageName: "stop.fill")
        AppShortcut(intent: PausePhoneTaskIntent(), phrases: ["Pause the task in \(.applicationName)", "暂停 \(.applicationName) 的任务"], shortTitle: "暂停任务", systemImageName: "pause.fill")
        AppShortcut(intent: HandoffPhoneTaskIntent(), phrases: ["Take over the task in \(.applicationName)", "接管 \(.applicationName) 的任务"], shortTitle: "接管任务", systemImageName: "hand.raised.fill")
        AppShortcut(intent: ResumePhoneTaskIntent(), phrases: ["Resume the task in \(.applicationName)", "继续 \(.applicationName) 的任务"], shortTitle: "继续任务", systemImageName: "play.fill")
        AppShortcut(intent: BeginTaskSupplementIntent(), phrases: ["Add instructions in \(.applicationName)", "补充 \(.applicationName) 的任务要求"], shortTitle: "补充任务", systemImageName: "text.badge.plus")
        AppShortcut(intent: AmendPhoneTaskIntent(), phrases: ["Update the task in \(.applicationName)", "向 \(.applicationName) 的任务加入补充"], shortTitle: "加入补充", systemImageName: "pencil")
        AppShortcut(intent: ListenPhoneTaskIntent(), phrases: ["Talk to \(.applicationName)", "用语音告诉 \(.applicationName)"], shortTitle: "语音告诉助手", systemImageName: "mic.fill")
    }
}
