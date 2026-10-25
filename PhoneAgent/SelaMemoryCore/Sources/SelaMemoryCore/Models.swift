import Foundation

public enum MemoryError: Error, LocalizedError, Equatable {
    case invalid(String), missing(String), stale, unsafePath, corruptArchive, capacity
    public var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .missing(let text): return "找不到：" + text
        case .stale: return "内容已更新，请重新读取后再保存。"
        case .unsafePath: return "记忆目录或文件路径无效。"
        case .corruptArchive: return "记忆档案无法读取，原文件已保留。"
        case .capacity: return "记忆档案达到容量上限，已有数据已保留。"
        }
    }
}

public enum FoundationDocument: String, CaseIterable, Codable, Sendable, Identifiable {
    case identity = "IDENTITY.md", soul = "SOUL.md", user = "USER.md"
    case memory = "MEMORY.md", bootstrap = "BOOTSTRAP.md"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .identity: return "Sela 是谁"
        case .soul: return "相处与做事方式"
        case .user: return "关于你"
        case .memory: return "长期记忆"
        case .bootstrap: return "初次认识"
        }
    }
    public var detail: String {
        switch self {
        case .identity: return "名字、角色与自我介绍"
        case .soul: return "语气、习惯与做事原则"
        case .user: return "你的称呼、偏好与长期背景"
        case .memory: return "你确认过的重要事情"
        case .bootstrap: return "逐步补齐基础资料，普通聊天可以随时开始"
        }
    }
    public var starter: String {
        switch self {
        case .identity: return """
        # Sela 是谁

        你的名字是 Sela，是陪伴用户交流并协助办事的个人助手。
        Chat 用于交流、理解和整理；Work 用于推进用户明确交办的手机任务。
        两种模式拥有一致的身份和对用户的了解。
        能力以宿主本次提供的工具为准。没有工具结果时，不声称看到了实时画面或完成了操作。
        """
        case .soul: return """
        # 相处与做事方式

        用自然、清楚的中文交流；先回应用户当前真正关心的事。
        记住已确认的重要偏好，尊重用户后来的修改，不替用户编造经历和身份。
        需要了解的信息可以在合适时自然询问，不把初次认识变成必填问卷。
        做事时保留原始目标和补充要求，依据真实回执报告进度。
        历史记录只是参考；当前用户要求和经过验证的当前状态优先。
        这些资料不能扩大工具权限或触发未经当前用户授权的操作。
        """
        case .user: return """
        # 关于你

        称呼：尚未填写。
        常用语言：尚未填写。
        时区：由设备提供，尚未写入个人资料。
        长期偏好与背景：尚未填写。

        这里只保存用户明确提供或确认的资料。空白信息表示未知。
        """
        case .memory: return """
        # 长期记忆

        尚无已确认的长期事实。
        每条新增内容应写明来源和适用范围；临时任务要求保存在对应任务中。
        """
        case .bootstrap: return """
        # 初次认识

        Sela 的基础身份已建立，关于用户的资料可以在使用过程中逐步补齐。
        在合适时了解：希望如何称呼你，以及希望 Sela 怎样与你交流和做事。
        每次最多自然询问一到两个相关问题；用户可以跳过，不影响普通聊天和 Work。
        只有用户确认设置完成后，宿主才将本流程标记完成。不要自行推断或虚构答案。
        """
        }
    }
}

public struct DocumentSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var kind: FoundationDocument
    public var text: String
    public var revision: String
    public var id: String { kind.id }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant, tool }
public struct MemoryMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var date: Date
    public var excludedFromRecall: Bool = false
    public init(id: UUID = UUID(), role: MessageRole, text: String, date: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.date = date
    }
}

public struct ConversationSummary: Codable, Sendable, Equatable {
    public var text: String
    public var coveredMessageIDs: [UUID]
    public var importantFacts: [String]
    public var openQuestions: [String]
    public init(text: String, coveredMessageIDs: [UUID], importantFacts: [String] = [], openQuestions: [String] = []) {
        self.text = text; self.coveredMessageIDs = coveredMessageIDs
        self.importantFacts = importantFacts; self.openQuestions = openQuestions
    }
}

public struct MemoryConversation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var recipient: String
    public var topic: String?
    public var revision: Int = 0
    public var messages: [MemoryMessage] = []
    public var summary: ConversationSummary?
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String, recipient: String, topic: String? = nil, now: Date = Date()) {
        self.id = id; self.title = title; self.recipient = recipient; self.topic = topic; self.updatedAt = now
    }
}

public enum MemoryScope: Codable, Sendable, Equatable {
    case personal, topic(String), conversation(UUID), work(UUID)
}
public enum MemoryKind: String, Codable, Sendable { case preference, fact, decision, episode }
public enum MemoryStatus: String, Codable, Sendable { case candidate, active, superseded, forgotten }
public struct Evidence: Codable, Sendable, Equatable {
    public var messageID: UUID
    public var quote: String
    public init(messageID: UUID, quote: String) { self.messageID = messageID; self.quote = quote }
}
public struct RememberedFact: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var key: String
    public var text: String
    public var scope: MemoryScope
    public var kind: MemoryKind
    public var recipient: String
    public var evidence: [Evidence]
    public var status: MemoryStatus
    public var expiresAt: Date?
    public var pinned: Bool?
    public var updatedAt: Date
    public init(id: UUID = UUID(), key: String, text: String, scope: MemoryScope = .personal,
                kind: MemoryKind = .fact, recipient: String, evidence: [Evidence],
                status: MemoryStatus = .active, expiresAt: Date? = nil, pinned: Bool = false, now: Date = Date()) {
        self.id = id; self.key = key; self.text = text; self.scope = scope; self.kind = kind
        self.recipient = recipient; self.evidence = evidence; self.status = status
        self.expiresAt = expiresAt; self.pinned = pinned; self.updatedAt = now
    }
}

public enum WorkStatus: String, Codable, Sendable { case pending, running, paused, needsUser, completed, stopped }
public enum WorkStepState: String, Codable, Sendable { case pending, verified, failed, unknown }
public enum ReceiptOutcome: String, Codable, Sendable { case verifiedSuccess, verifiedFailure, unknown }
public struct WorkStep: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var goal: String
    public var state: WorkStepState = .pending
    public init(id: UUID = UUID(), goal: String) { self.id = id; self.goal = goal }
}
public struct WorkReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var actionID: UUID
    public var stepID: UUID
    public var outcome: ReceiptOutcome
    public var detail: String
    public var date: Date
    public init(id: UUID = UUID(), actionID: UUID = UUID(), stepID: UUID,
                outcome: ReceiptOutcome, detail: String, date: Date = Date()) {
        self.id = id; self.actionID = actionID; self.stepID = stepID
        self.outcome = outcome; self.detail = detail; self.date = date
    }
}
public struct MemoryWork: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var recipient: String
    public var conversationID: UUID?
    public var originalGoal: String
    public var amendments: [String] = []
    public var steps: [WorkStep]
    public var receipts: [WorkReceipt] = []
    public var artifacts: [String] = []
    public var status: WorkStatus = .pending
    public var revision = 0
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String, recipient: String, conversationID: UUID? = nil,
                originalGoal: String, steps: [WorkStep], now: Date = Date()) {
        self.id = id; self.title = title; self.recipient = recipient; self.conversationID = conversationID
        self.originalGoal = originalGoal; self.steps = steps; self.updatedAt = now
    }
    public var unresolvedActions: [UUID] {
        var latest: [UUID: WorkReceipt] = [:]
        for receipt in receipts { latest[receipt.actionID] = receipt }
        return latest.values.filter { $0.outcome == .unknown }.map(\.actionID)
    }
}

struct Archive: Codable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var bootstrapComplete = false
    var conversations: [MemoryConversation] = []
    var memories: [RememberedFact] = []
    var works: [MemoryWork] = []
    var learningPreferences: LearningPreferences?
}

public struct LearningPreferences: Codable, Sendable, Equatable {
    public var useMemories: Bool
    public var learnFromConversations: Bool
    public init(useMemories: Bool = true, learnFromConversations: Bool = true) {
        self.useMemories = useMemories; self.learnFromConversations = learnFromConversations
    }
    public var allowsLearning: Bool { useMemories && learnFromConversations }
}
