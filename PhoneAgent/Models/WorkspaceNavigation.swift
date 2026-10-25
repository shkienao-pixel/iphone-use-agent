import Foundation

enum WorkspaceDestination: Hashable {
    case tasks, screenShare, device, settings, assistant, memory, workbench, tools
    case phoneConnections, appConnections, modelMemory, connectionBridge
    case appConnection(ExternalAppService)
    case nativeAppConnection(NativeAppConnection)

    var title: String {
        switch self {
        case .tasks: "Sela"
        case .settings: "设置"
        case .screenShare: "屏幕共享"
        case .device: "ESP32 与蓝牙鼠标"
        case .assistant: "对话"
        case .memory: "记忆"
        case .workbench: "记录与文件"
        case .tools: "工具与连接"
        case .phoneConnections: "手机连接"
        case .appConnections: "App 连接"
        case .modelMemory: "模型与记忆"
        case .connectionBridge: "连接服务"
        case .appConnection(let service): service.title
        case .nativeAppConnection(let app): app.title
        }
    }

    var isConversation: Bool { self == .tasks || self == .assistant }

    var pausesTaskOnEntry: Bool {
        switch self {
        case .assistant, .memory, .workbench, .nativeAppConnection(_), .appConnection(_), .connectionBridge: true
        default: false
        }
    }
}

enum WorkspaceSheet: Identifiable {
    case task(UUID), taskQueue, plan, preparation, consent, policy, connection(SettingsPage), tool(ToolApproval)
    var id: String {
        switch self {
        case .task(let id): return id.uuidString
        case .taskQueue: return "taskQueue"
        case .plan: return "plan"
        case .preparation: return "preparation"
        case .consent: return "consent"
        case .policy: return "policy"
        case .connection(let page): return "connection:" + page.rawValue
        case .tool(let value): return "tool:" + value.id.uuidString
        }
    }
}
enum TaskScreen: Hashable {
    case draft, conversation(UUID)
}

enum ConversationEvent: Identifiable {
    case activity(AgentLogEntry), amendment(TaskAmendment)
    var id: UUID {
        switch self { case .activity(let log): return log.id; case .amendment(let addition): return addition.id }
    }
    var date: Date {
        switch self { case .activity(let log): return log.date; case .amendment(let addition): return addition.createdAt }
    }
}
