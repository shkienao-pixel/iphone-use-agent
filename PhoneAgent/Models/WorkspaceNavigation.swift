import Foundation

enum WorkspaceDestination: Hashable {
    case tasks, screenShare, device, settings, assistant, memory, workbench, queue

    var title: String {
        switch self {
        case .tasks, .settings: "Phone Agent"
        case .screenShare: "屏幕共享"
        case .device: "设备"
        case .assistant: "问助手"
        case .memory: "记忆"
        case .workbench: "记录与文件"
        case .queue: "任务队列"
        }
    }

    var isConversation: Bool { self == .tasks || self == .assistant }

    var pausesTaskOnEntry: Bool {
        switch self {
        case .assistant, .memory, .workbench: true
        default: false
        }
    }
}

enum WorkspaceSheet: Identifiable {
    case task(UUID), plan, preparation, consent, policy, settings, tool(ToolApproval)
    var id: String {
        switch self {
        case .task(let id): return id.uuidString
        case .plan: return "plan"
        case .preparation: return "preparation"
        case .consent: return "consent"
        case .policy: return "policy"
        case .settings: return "settings"
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
