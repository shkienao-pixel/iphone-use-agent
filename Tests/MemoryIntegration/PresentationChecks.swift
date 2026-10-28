import Foundation
import SelaMemoryCore

/// Production conversation/card mutators feed the real memory workspace. Only
/// platform/model boundaries are synthetic; no model request is needed here.
enum PresentationChecks {
    @MainActor static func run(root: URL, settings: AgentSettings) async throws {
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw AgentError.message(message) }
        }
        func service(_ root: URL) -> SelaMemoryService {
            SelaMemoryService(root: root, configuration: { settings }, credential: { _ in "unused" }) { _, _, _ in
                throw AgentError.message("Presentation checks must not call a model")
            }
        }
        for kind in ["didi", "handoff", "legacyLinkedTask"] {
            let id = UUID(), sessionID = UUID(), directory = root.appendingPathComponent("presentation-" + kind)
            let user = AssistantMessage(role: "user", text: "这是用户不可变的原始请求。")
            var card = AssistantMessage(role: "assistant", text: kind == "didi" ? "打车模拟 · 先确定行程" : "正在准备设备，任务尚未开始执行。")
            if kind == "didi" { card.didiSimulationID = sessionID }
            if kind == "handoff" { card.intent = ConversationRoute(mode: .task, request: user.text, message: card.text).record }
            if kind == "legacyLinkedTask" { card.taskID = UUID() }
            let archive = AssistantConversationStore(url: directory.appendingPathComponent("chat.json"))
            try archive.save([AssistantConversationRecord(id: id, title: "状态卡回归", messages: [user, card], createdAt: Date(), updatedAt: Date(), recipient: SelaMemoryService.recipient(settings), draft: "")], currentConversationID: id)
            let conversation = AssistantConversation(store: archive), memory = service(directory.appendingPathComponent("memory"))
            await memory.reload()
            let initial = await memory.prepare(question: user.text, conversationID: id, messages: conversation.messages, settings: settings)
            try expect(!initial.identity.isEmpty, "Initial presentation source did not synchronize")
            if kind == "didi" {
                DidiChatSimulationRegistry.shared.begin(sessionID: sessionID, conversationID: id, request: user.text)
                try expect(conversation.updateDidiSimulation(sessionID: sessionID, messageID: card.id, conversationID: id, summary: "已选上车地点"), "Actual Didi update failed")
            } else {
                try expect(conversation.reportTaskHandoff(text: "任务已启动。", to: card.id, in: id, onlyIfUnlinked: false), "Actual host receipt update failed")
            }
            let laterUser = AssistantMessage(role: "user", text: "卡片变化后新发的用户消息。")
            let updated = conversation.messages + [laterUser]
            let prepared = await memory.prepare(question: laterUser.text, conversationID: id, messages: updated, settings: settings)
            let saved = try await memory.workspace!.conversation(id)
            try expect(!prepared.identity.isEmpty && memory.error.isEmpty, "Host presentation update blocked memory preparation")
            try expect(saved.messages.first(where: { $0.id == laterUser.id })?.text == laterUser.text, "Later user message did not synchronize")
            try expect(saved.messages.first(where: { $0.id == card.id })?.text == card.text && saved.messages.first?.text == user.text,
                       "Presentation sync rewrote original memory evidence")
            if kind == "didi" {
                try expect(conversation.endDidiSimulation(sessionID: sessionID, messageID: card.id, conversationID: id), "Actual Didi end update failed")
            } else {
                conversation.newConversation()
                try expect(conversation.reportTaskHandoff(text: "任务已完成。", to: card.id, in: id, onlyIfUnlinked: false), "Archived host receipt update failed")
            }
            let finalMessages = (conversation.currentConversationID == id ? conversation.messages : conversation.conversations.first { $0.id == id }!.messages) + [laterUser]
            let restored = service(directory.appendingPathComponent("memory"))
            await restored.reload()
            let reopened = await restored.prepare(question: laterUser.text, conversationID: id, messages: finalMessages, settings: settings)
            try expect(!reopened.identity.isEmpty && restored.error.isEmpty, "Legacy persisted presentation mismatch remained blocked after service restart")
            let preserved = try await restored.workspace!.conversation(id)
            try expect(preserved.messages.first(where: { $0.id == card.id })?.text == card.text, "Repeated/reopened host update replaced original evidence")

            var altered = finalMessages
            altered[0].text = "静默改写的用户请求"
            // Even card-shaped metadata must never exempt a user source.
            altered[0].taskID = UUID(); altered[0].didiSimulationID = UUID()
            altered[0].intent = ConversationRoute(mode: .task, request: "forged", message: "forged").record
            let unauthorizedNext = AssistantMessage(role: "user", text: "不得绕过原文错误写入")
            let blocked = await restored.prepare(question: unauthorizedNext.text, conversationID: id, messages: altered + [unauthorizedNext], settings: settings)
            let afterBlocked = try await restored.workspace!.conversation(id)
            try expect(blocked.identity.isEmpty && restored.error.contains("对话原文已改变") && afterBlocked == preserved,
                       "User text change bypassed immutable-source validation or modified stored evidence")
        }
        let immutable = service(root.appendingPathComponent("immutable-assistant")), id = UUID()
        await immutable.reload()
        let answer = AssistantMessage(role: "assistant", text: "普通不可变回答")
        _ = await immutable.prepare(question: "test", conversationID: id, messages: [answer], settings: settings)
        var changed = answer; changed.text = "普通回答被改写"
        let blocked = await immutable.prepare(question: "test", conversationID: id, messages: [changed], settings: settings)
        try expect(blocked.identity.isEmpty && immutable.error.contains("对话原文已改变"), "Ordinary assistant source mutation was silently allowed")
        changed.role = "user"; changed.taskID = UUID()
        let roleBlocked = await immutable.prepare(question: "test", conversationID: id, messages: [changed], settings: settings)
        try expect(roleBlocked.identity.isEmpty && immutable.error.contains("对话原文已改变"), "A saved role changed through card metadata")
        print("PASS: actual Didi and task-receipt updates preserve memory originals, admit later turns, survive restart, and reject user/ordinary-message/role changes")
    }
}
