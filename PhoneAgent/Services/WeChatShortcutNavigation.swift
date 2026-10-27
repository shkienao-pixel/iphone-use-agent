import Foundation

struct WeChatShortcutFrame {
    let snapshot: PhoneUISnapshot
    let captureID: UUID
    let frameID: String
    let confirmedAt: Date
}

/// The only possible input is a tap on a currently observed, locally verified
/// conversation row or profile message control. No text or send actions exist.
enum WeChatShortcutNavigation {
    private static let transferTitles = ["文件传输助手", "File Transfer", "File Transfer Assistant"]
    static func transferChat(_ value: PhoneUISnapshot) -> Bool {
        transferTitles.contains { WeChatContactIdentity.chatPage(snapshot: value, title: $0) != nil }
            && PhonePageAdapters.selfTransferEvidence(in: value) != nil
    }

    @MainActor static func run(initial: WeChatShortcutFrame, name: String, stableID: String,
                               tap: (PhoneUIElement) async throws -> Void,
                               read: () async throws -> WeChatShortcutFrame) async throws -> WeChatShortcutFrame {
        let snapshot = initial.snapshot
        let builtin = stableID == "wechat.builtin.file-transfer"
        if builtin, transferChat(snapshot) { return initial }
        if builtin {
            // The adapter resolves every supported alias and rejects ambiguous
            // rows itself. Calling it for each alias would duplicate one match.
            if let row = PhonePageAdapters.conversationRow(name, in: snapshot) {
                let started = Date()
                try await tap(row)
                let completed = Date()
                let chat = try await read()
                guard chat.captureID == initial.captureID, chat.confirmedAt > initial.confirmedAt,
                      chat.snapshot.deviceKey == snapshot.deviceKey,
                      chat.snapshot.capturedAt > started, chat.confirmedAt > completed,
                      transferChat(chat.snapshot) else { throw ChatEvidenceError.wrongConversation }
                return chat
            }
        }
        let target = ChatConversationTarget(stableID: stableID, title: name, deviceKey: snapshot.deviceKey)
        let profile = try WeChatContactIdentity.profile(snapshot: snapshot, frameID: initial.frameID,
            captureSessionID: initial.captureID, target: target, confirmedAt: initial.confirmedAt)
        guard let message = snapshot.element(id: profile.messageElementID) else { throw ChatEvidenceError.wrongConversation }
        let started = Date()
        try await tap(message)
        let completed = Date()
        let chat = try await read()
        try WeChatContactNavigationEvidence(profile: profile, tapStartedAt: started,
            tapCompletedAt: completed, chatConfirmedAt: chat.confirmedAt)
            .validate(target: target, chat: chat.snapshot, captureSessionID: chat.captureID)
        return chat
    }
}
