import Foundation

/// Identity is derived from the current observation, never from a remembered row.
/// OCR structure is a conservative local hint, not proof of real-device acceptance.
struct PhonePageIdentity: Codable, Equatable {
    var scene: String
    var evidence: [String]
    var conversation: String? = nil
    var input: PhoneUIElement? = nil
    var send: PhoneUIElement? = nil
    var messages: [PhoneUIElement] = []
}

enum PhonePageAdapters {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func identity(in snapshot: PhoneUISnapshot) -> PhonePageIdentity? {
        guard !snapshot.blockingOverlay else { return nil }
        let elements = snapshot.elements.filter { $0.rect.valid && $0.source == "ocr" }
        func matches(_ names: [String], _ region: (PhoneUIRect) -> Bool = { _ in true }) -> [PhoneUIElement] {
            elements.filter { names.contains(normalized($0.label)) && region($0.rect) }
        }
        func one(_ names: [String], _ region: (PhoneUIRect) -> Bool = { _ in true }) -> PhoneUIElement? {
            let values = matches(names, region); return values.count == 1 ? values[0] : nil
        }
        let top: (PhoneUIRect) -> Bool = { $0.centerY < 0.18 }
        let bottom: (PhoneUIRect) -> Bool = { $0.centerY > 0.84 }
        let chatTabs = [matches(["微信", "wechat", "chats"], bottom), matches(["通讯录", "contacts"], bottom),
                        matches(["发现", "discover"], bottom), matches(["我", "me"], bottom)]
        if chatTabs.allSatisfy({ $0.count == 1 }), let heading = one(["微信", "wechat", "chats"], top) {
            return PhonePageIdentity(scene: "wechat.list", evidence: [heading.id] + chatTabs.map { $0[0].id })
        }
        if let heading = one(["朋友圈", "moments"], top),
           let back = one(["发现", "discover"], { $0.centerX < 0.28 && top($0) }),
           let album = one(["我的朋友圈", "my moments", "相册", "album"], { $0.centerY < 0.5 }) {
            return PhonePageIdentity(scene: "wechat.moments", evidence: [heading.id, back.id, album.id])
        }
        let search = one(["搜索", "search"], top), cancel = one(["取消", "cancel"], top)
        let wechatCategories = matches(["朋友圈", "moments", "文章", "articles", "公众号", "official accounts", "小程序", "mini programs", "聊天记录", "chat history", "联系人", "contacts"], { (0.18...0.7).contains($0.centerY) })
        if let search, let cancel, Set(wechatCategories.map { normalized($0.label) }).count >= 3 {
            return PhonePageIdentity(scene: "wechat.search", evidence: [search.id, cancel.id] + wechatCategories.map(\.id))
        }
        // Never infer a chat solely from a title. Require the WeChat back label
        // and one explicit composer affordance in the actual OCR observation.
        let backs = matches(["微信", "wechat", "chats"], { $0.centerX < 0.28 && top($0) })
        let titles = elements.filter { top($0.rect) && (0.28...0.76).contains($0.rect.centerX) }
        let inputs = matches(["发送消息", "send a message", "消息", "message"], { (0.5...0.96).contains($0.centerY) && $0.centerX < 0.8 })
        let sends = matches(["发送", "send"], { (0.5...0.86).contains($0.centerY) && $0.centerX > 0.73 })
        if backs.count == 1, titles.count == 1, inputs.count == 1 || sends.count == 1 {
            let title = titles[0]
            let composerY = min(inputs.first?.rect.y ?? 0.96, sends.first?.rect.y ?? 0.96)
            let messages = elements.filter { $0.rect.centerY > 0.18 && $0.rect.centerY < composerY - 0.025 && $0.id != inputs.first?.id && $0.id != sends.first?.id }
            return PhonePageIdentity(scene: "wechat.chat", evidence: [backs[0].id, title.id] + inputs.map(\.id) + sends.map(\.id),
                                     conversation: title.label, input: inputs.count == 1 ? inputs[0] : nil,
                                     send: sends.count == 1 ? sends[0] : nil, messages: messages)
        }
        return XiaohongshuPageAdapter.identity(in: snapshot)
    }

    /// Only the built-in self conversation has a stable identity this adapter
    /// can establish from OCR. People with matching display names are not IDs.
    static func selfConversation(_ name: String) -> Bool {
        ["文件传输助手", "file transfer", "file transfer assistant"].contains(normalized(name))
    }
    static func canonicalConversation(_ name: String) -> String? {
        selfConversation(name) ? "wechat.builtin.file-transfer" : nil
    }
    static func conversationMatches(_ expected: String, _ actual: String?) -> Bool {
        // This helper supports only the built-in file-transfer workflow. A
        // shared label is not sufficient proof of the current chat's identity;
        // callers must still independently verify its built-in system evidence.
        guard let actual, let expectedID = canonicalConversation(expected),
              let actualID = canonicalConversation(actual) else { return false }
        return expectedID == actualID
    }
    /// A title can be imitated by a contact nickname. Require the separate,
    /// centered built-in transfer explanation, never just the title/row name.
    /// This is still OCR evidence; unsupported versions/themes safely stop.
    static func selfTransferEvidence(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let matches = selfTransferEvidenceCandidates(in: snapshot)
        return matches.count == 1 ? matches[0] : nil
    }
    /// Expose the same exact candidates so independently identified built-in
    /// navigation can reject ambiguity rather than treat system text as facts.
    static func selfTransferEvidenceCandidates(in snapshot: PhoneUISnapshot) -> [PhoneUIElement] {
        let texts = ["可以在手机和电脑间互传文件", "你可以在电脑与手机间互传文件", "你可以在手机和电脑间互传文件", "you can transfer files between your phone and computer.", "you can transfer files between your phone and computer"]
        return snapshot.elements.filter {
            $0.source == "ocr" && $0.rect.valid && texts.contains(normalized($0.label)) &&
                (0.18...0.42).contains($0.rect.centerY) && (0.35...0.65).contains($0.rect.centerX) && $0.rect.width >= 0.45
        }
    }
    static func conversationRow(_ name: String, in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard selfConversation(name), ["wechat.list", "wechat.search"].contains(snapshot.scene) else { return nil }
        // All supported aliases are candidates for the one built-in workflow.
        // A second alias (including a same-name contact) makes the row ambiguous.
        // A matching row only permits opening it, never sending without proof.
        let rows = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid &&
            conversationMatches(name, $0.label) && (0.18...0.83).contains($0.rect.centerY) }
        return rows.count == 1 ? rows[0] : nil
    }
    static func keyboardVisible(_ snapshot: PhoneUISnapshot) -> Bool {
        let labels = snapshot.elements.filter { $0.rect.centerY > 0.56 }.map { normalized($0.label) }
        return labels.contains(where: { ["space", "空格"].contains($0) }) &&
            labels.contains(where: { ["return", "换行", "发送", "send", "123"].contains($0) })
    }
    static func exactDraft(_ text: String, in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard let identity = identity(in: snapshot), let send = identity.send else { return nil }
        let matches = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && $0.label == text &&
            abs($0.rect.centerY - send.rect.centerY) < 0.045 && $0.rect.centerX < 0.8 }
        return matches.count == 1 ? matches[0] : nil
    }
    /// Without platform message IDs, a changed/scrolling viewport cannot prove
    /// that a matching bubble is new. Preserve every pre-submit visible anchor
    /// and its neighborhood; otherwise submission stays pending, never retries.
    static func retainsMessageAnchors(_ before: PhonePageIdentity, after: PhonePageIdentity) -> Bool {
        guard !before.messages.isEmpty else { return false }
        return before.messages.allSatisfy { old in
            after.messages.filter { current in
                current.label == old.label && abs(current.rect.centerX - old.rect.centerX) < 0.02 &&
                    abs(current.rect.centerY - old.rect.centerY) < 0.02 && abs(current.rect.width - old.rect.width) < 0.03
            }.count == 1
        }
    }
    static func outgoingCount(_ text: String, in identity: PhonePageIdentity) -> Int {
        identity.messages.filter { $0.label == text && $0.rect.centerX > 0.58 }.count
    }
}

enum PhoneWorkflowReviewResolution: String, Codable, CaseIterable {
    case confirmedSubmitted, confirmedNotSubmitted
}

struct PhoneWorkflowRecord: Codable, Equatable {
    enum Stage: String, Codable {
        case prepared, opening, focusing, typingPending, draftVerified, submissionPending, observedOnce, reviewedByUser
    }
    var operationID: String
    var target: String
    var text: String
    var deviceKey: String
    var stage: Stage
    var updatedAt: Date
    var sourceMessageCount: Int = 0
    var taskScopeID: UUID? = nil
    var reviewResolution: PhoneWorkflowReviewResolution? = nil
    var detail: String
}

/// Store intent BEFORE dispatch. An interrupted write or uncertain input is a
/// terminal pending receipt; retrying the same operation never repeats input.
struct PhoneWorkflowJournal: Codable {
    var version = 3
    var records: [PhoneWorkflowRecord] = []
    func record(id: String) -> PhoneWorkflowRecord? { records.first { $0.operationID == id } }
    mutating func put(_ record: PhoneWorkflowRecord) throws {
        guard version == 3 else { throw AgentError.message("本地流程回执版本不可用，未执行") }
        if let old = self.record(id: record.operationID) {
            guard old.target == record.target, old.text == record.text, old.deviceKey == record.deviceKey else {
                throw AgentError.message("operation_id 已绑定其他目标、内容或设备，未执行")
            }
            records.removeAll { $0.operationID == record.operationID }
        }
        // Pending records must not expire/evict into an accidental resend.
        guard records.count < 1000 else { throw AgentError.message("本地流程回执已满，请先导出核验，未执行") }
        records.append(record)
    }
}
