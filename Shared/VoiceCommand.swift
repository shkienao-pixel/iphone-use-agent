import Foundation

enum VoiceInputMode: String, Identifiable {
    case task, supplement, question
    var id: String { rawValue }
    var title: String {
        switch self { case .task: return "说出你的任务"; case .supplement: return "补充当前任务"; case .question: return "和助手聊聊" }
    }
}

enum VoiceCommand: Equatable {
    case pause, handoff, resume, stop, supplement
    static func parse(_ text: String) -> VoiceCommand? {
        var value = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        // Speech recognition may repeat a wake phrase when the speaker pauses.
        // Strip repeated prefixes but still require the rest to be a whole command.
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in ["助手助手", "豆包豆包", "phoneagent"] where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count); removedPrefix = true; break
            }
        }
        // Match a whole command. Sentences such as “不要暂停” remain task text.
        switch value {
        case "暂停", "暂停任务", "暂停一下", "暂停一下任务", "先暂停", "先暂停任务", "停一下", "先停一下",
             "帮我暂停", "帮我暂停任务", "帮我暂停当前任务", "帮我暂停一下", "帮我暂停一下任务",
             "暂停当前", "暂停当前任务吧", "先暂停一下", "先停", "先停一下当前任务", "帮我停一下", "帮我暂停下",
             "请暂停", "请暂停任务", "请帮我暂停", "请帮我暂停任务", "请帮我暂停当前任务", "pause": return .pause
        case "接管", "接管任务", "接管手机", "我要接管", "我来接管", "让我接管", "帮我接管",
             "接管一下", "先接管", "先接管一下", "我接管", "我接管一下", "我来处理", "接下来我来", "这一步我来",
             "请接管", "请帮我接管", "我来操作", "让我来操作", "让我来接手", "handoff": return .handoff
        case "继续", "继续任务", "恢复任务", "继续执行", "继续吧", "帮我继续", "帮我继续任务",
             "继续当前任务", "继续操作", "接着做", "接着执行", "接着来", "你继续", "可以继续了",
             "请继续", "请继续任务", "resume": return .resume
        case "停止", "停止任务", "结束任务", "取消任务", "停止执行", "取消执行",
             "终止任务", "帮我停止", "帮我停止任务", "请停止", "请停止任务", "stop": return .stop
        case "补充", "补充任务", "补充要求", "我要补充", "我要补充要求", "补充一下", "补充一下任务",
             "补充当前任务", "补充一下要求", "我想补充", "我再补充", "我还有补充", "我补充几点",
             "再加一个要求", "再加一条要求", "加个要求", "添加要求", "我加个要求", "给任务补充要求",
             "补充一句", "我要补充一句", "我补充一下", "我还要补充", "我还要补充要求", "请补充": return .supplement
        default: return nil
        }
    }
}

enum VoiceTaskRequestRoute: Equatable {
    case start
    case queue
    case busy
}

enum VoiceTaskRequestRouter {
    static func route(
        hasCurrentTask: Bool,
        pendingTaskCount: Int,
        queueRunning: Bool,
        engineRunning: Bool,
        queueSwitching: Bool,
        engineReleasing: Bool,
        voicePending: Bool,
        manualBusy: Bool,
        calibrating: Bool
    ) -> VoiceTaskRequestRoute {
        guard !queueSwitching, !engineReleasing, !voicePending, !manualBusy, !calibrating else { return .busy }
        if hasCurrentTask || pendingTaskCount > 0 { return .queue }
        guard !queueRunning, !engineRunning else { return .busy }
        return .start
    }
}
