import Foundation

/// A real visible profile observation, never a fabricated accessibility ID.
/// It is archived with the first conversation frame so the stable-account
/// decision and the exact navigation control remain inspectable offline.
struct WeChatContactProfileEvidence: Codable, Equatable {
    var frameID: String
    var captureSessionID: UUID
    var snapshot: PhoneUISnapshot
    var account: String
    var title: String
    var evidenceElementIDs: [String]
    var messageElementID: String
    var confirmedAt: Date? = nil

    func validate(for target: ChatConversationTarget) throws {
        let actual = try WeChatContactIdentity.profile(snapshot: snapshot, frameID: frameID,
            captureSessionID: captureSessionID, target: target, confirmedAt: confirmedAt)
        guard actual == self else { throw ChatEvidenceError.wrongConversation }
    }
}

struct WeChatContactNavigationEvidence: Codable, Equatable {
    var profile: WeChatContactProfileEvidence
    var tapStartedAt: Date
    var tapCompletedAt: Date
    /// System confirmation can advance while pixels remain unchanged. It is
    /// kept separate from the actual image capture timestamp.
    var chatConfirmedAt: Date? = nil

    func validate(target: ChatConversationTarget, chat: PhoneUISnapshot, captureSessionID: UUID?) throws {
        try profile.validate(for: target)
        guard captureSessionID == profile.captureSessionID, chat.deviceKey == profile.snapshot.deviceKey,
              profile.snapshot.capturedAt <= tapStartedAt, tapStartedAt <= tapCompletedAt,
              profile.confirmedAt.map({ $0 <= tapStartedAt }) ?? true,
              tapStartedAt.timeIntervalSince1970.isFinite, tapCompletedAt.timeIntervalSince1970.isFinite,
              tapStartedAt < chat.capturedAt,
              chatConfirmedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= chat.capturedAt && $0 > tapCompletedAt }) ?? (chat.capturedAt > tapCompletedAt),
              WeChatContactIdentity.chatPage(snapshot: chat, title: target.title) != nil else {
            throw ChatEvidenceError.wrongConversation
        }
    }
}

enum WeChatContactIdentity {
    static let accountPrefix = "wechat.account:"

    static func stableID(account: String) throws -> String {
        // This is a conservative supported syntax, not a claim about every
        // historical WeChat ID. Keep the observed case and characters exact.
        guard account.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{5,63}$"#, options: .regularExpression) != nil else {
            throw ChatEvidenceError.invalidRequest
        }
        return accountPrefix + account
    }
    static func account(fromStableID stableID: String) throws -> String {
        guard stableID.hasPrefix(accountPrefix) else { throw ChatEvidenceError.invalidRequest }
        let account = String(stableID.dropFirst(accountPrefix.count))
        guard try self.stableID(account: account) == stableID else { throw ChatEvidenceError.invalidRequest }
        return account
    }

    /// Page structure only, never account identity. The caller must already
    /// possess a validated profile-navigation or independently proved built-in
    /// identity. Empty composers may expose no OCR placeholder: in that case
    /// require three distinct symbols detected from actual local pixels.
    static func chatPage(snapshot: PhoneUISnapshot, title: String) -> PhonePageIdentity? {
        guard !snapshot.blockingOverlay else { return nil }
        if let page = PhonePageAdapters.identity(in: snapshot), page.scene == "wechat.chat", page.conversation == title { return page }
        let titles = snapshot.elements.filter {
            $0.source == "ocr" && $0.rect.valid && $0.rect.centerY < 0.16 && (0.28...0.76).contains($0.rect.centerX)
        }
        guard titles.count == 1, titles[0].label == title else { return nil }
        let visuals = snapshot.elements.filter {
            let minimumHeight = $0.label == "视觉:更多" ? 0.0025 : 0.008
            let minimumWidth = $0.label == "视觉:返回" ? 0.015 : 0.02
            return $0.source == "local_visual" && $0.rect.valid && (minimumWidth...0.14).contains($0.rect.width) && (minimumHeight...0.10).contains($0.rect.height)
        }
        func one(_ label: String, _ area: (PhoneUIRect) -> Bool) -> PhoneUIElement? {
            let values = visuals.filter { $0.label == label && area($0.rect) }
            return values.count == 1 ? values[0] : nil
        }
        guard let back = one("视觉:返回", { $0.centerX < 0.18 && $0.centerY < 0.16 }),
              let more = one("视觉:更多", { $0.centerX > 0.80 && $0.centerY < 0.16 }),
              let plus = one("视觉:添加", { $0.centerX > 0.80 && (0.55...0.96).contains($0.centerY) }),
              Set([titles[0].id, back.id, more.id, plus.id]).count == 4 else { return nil }
        let evidence = [titles[0].id, back.id, more.id, plus.id]
        guard evidence.allSatisfy({ snapshot.element(id: $0) != nil }) else { return nil }
        return PhonePageIdentity(scene: "wechat.chat", evidence: evidence, conversation: title,
            messages: snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY > 0.18 && $0.rect.centerY < plus.rect.y - 0.025 })
    }

    /// Recognize an already-open personal profile by a visible WeChat account
    /// field plus app-specific neighboring controls. A title or a message
    /// containing "微信号" cannot establish this profile structure.
    static func profile(snapshot: PhoneUISnapshot, frameID: String, captureSessionID: UUID,
                        target: ChatConversationTarget, confirmedAt: Date? = nil) throws -> WeChatContactProfileEvidence {
        if target.stableID == "wechat.builtin.file-transfer" {
            return try builtInTransferProfile(snapshot: snapshot, frameID: frameID,
                captureSessionID: captureSessionID, target: target, confirmedAt: confirmedAt)
        }
        let account = try account(fromStableID: target.stableID)
        guard !snapshot.blockingOverlay, snapshot.deviceKey == target.deviceKey,
              !target.title.isEmpty, target.title.count <= 180,
              !frameID.isEmpty, frameID.count <= 180,
              snapshot.capturedAt.timeIntervalSince1970.isFinite,
              confirmedAt.map({ $0.timeIntervalSince1970.isFinite && snapshot.capturedAt <= $0 }) ?? true else { throw ChatEvidenceError.wrongConversation }
        let elements = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid }
        func one(_ names: [String], _ area: (PhoneUIRect) -> Bool) -> PhoneUIElement? {
            let found = elements.filter { names.contains(PhonePageAdapters.normalized($0.label)) && area($0.rect) }
            return found.count == 1 ? found[0] : nil
        }
        let backs = ["微信", "wechat", "chats", "通讯录", "contacts", "聊天信息", "chat info", "详细资料", "profile"]
        guard let back = one(backs, { $0.centerX < 0.28 && $0.centerY < 0.15 }),
              let message = one(["发消息", "send message", "message"], { (0.42...0.9).contains($0.centerY) && (0.3...0.7).contains($0.centerX) }),
              let call = one(["音视频通话", "语音或视频通话", "voice or video call", "voice/video call"], {
                  $0.centerY > message.rect.centerY + 0.025 && $0.centerY < 0.96 && abs($0.centerX - message.rect.centerX) < 0.16
              }),
              let moments = one(["朋友圈", "moments"], { (0.24...0.78).contains($0.centerY) && $0.centerY < message.rect.centerY - 0.025 }) else {
            throw ChatEvidenceError.wrongConversation
        }
        let titles = elements.filter { $0.label == target.title && (0.12...0.34).contains($0.rect.centerY) && $0.rect.centerX > 0.26 }
        guard titles.count == 1 else { throw ChatEvidenceError.wrongConversation }
        // Reject every conflicting or duplicate account field. Whitespace and
        // colon are field punctuation only; account content is never normalized.
        let fieldNames = ["微信号", "wechat id", "weixin id"]
        var accountCandidates: [(String, [String], Double)] = []
        for element in elements where (0.17...0.43).contains(element.rect.centerY) {
            let raw = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if let separator = raw.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                let field = PhonePageAdapters.normalized(String(raw[..<separator]))
                if fieldNames.contains(field) {
                    let value = String(raw[raw.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                    if value.isEmpty {
                        let adjacent = elements.filter { candidate in
                            candidate.id != element.id && candidate.rect.x >= element.rect.x + element.rect.width - 0.02 &&
                            abs(candidate.rect.centerY - element.rect.centerY) < 0.02 && (try? stableID(account: candidate.label)) != nil
                        }
                        guard adjacent.count == 1 else { throw ChatEvidenceError.wrongConversation }
                        accountCandidates.append((adjacent[0].label, [element.id, adjacent[0].id], element.rect.centerY))
                    } else { accountCandidates.append((value, [element.id], element.rect.centerY)) }
                }
            } else if fieldNames.contains(PhonePageAdapters.normalized(raw)) {
                let values = elements.filter { candidate in
                    candidate.id != element.id && candidate.rect.x >= element.rect.x + element.rect.width - 0.02 &&
                    abs(candidate.rect.centerY - element.rect.centerY) < 0.02 && (try? stableID(account: candidate.label)) != nil
                }
                if values.count == 1 { accountCandidates.append((values[0].label, [element.id, values[0].id], element.rect.centerY)) }
                else { throw ChatEvidenceError.wrongConversation }
            }
        }
        guard accountCandidates.count == 1, accountCandidates[0].0 == account,
              accountCandidates[0].2 > titles[0].rect.centerY,
              accountCandidates[0].2 < moments.rect.centerY else { throw ChatEvidenceError.wrongConversation }
        let evidence = [back.id, titles[0].id] + accountCandidates[0].1 + [moments.id, message.id, call.id]
        guard Set(evidence).count == evidence.count,
              evidence.allSatisfy({ snapshot.element(id: $0) != nil }) else { throw ChatEvidenceError.wrongConversation }
        return .init(frameID: frameID, captureSessionID: captureSessionID, snapshot: snapshot,
            account: account, title: target.title, evidenceElementIDs: evidence, messageElementID: message.id, confirmedAt: confirmedAt)
    }

    /// A built-in profile exposes the reserved account independently of its
    /// nickname. This layout is deliberately separate from ordinary contacts:
    /// generic Details controls and chat text cannot stand in for this page.
    private static func builtInTransferProfile(snapshot: PhoneUISnapshot, frameID: String,
        captureSessionID: UUID, target: ChatConversationTarget, confirmedAt: Date?) throws -> WeChatContactProfileEvidence {
        guard PhonePageAdapters.canonicalConversation(target.title) == target.stableID,
              !snapshot.blockingOverlay, snapshot.deviceKey == target.deviceKey,
              !frameID.isEmpty, frameID.count <= 180,
              snapshot.capturedAt.timeIntervalSince1970.isFinite,
              confirmedAt.map({ $0.timeIntervalSince1970.isFinite && snapshot.capturedAt <= $0 }) ?? true else {
            throw ChatEvidenceError.wrongConversation
        }
        let elements = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid }
        guard !elements.contains(where: { (0.055...0.12).contains($0.rect.centerY) && (0.28...0.76).contains($0.rect.centerX) }),
              !snapshot.elements.contains(where: {
                  $0.source == "local_visual" && $0.label == "视觉:添加" && $0.rect.valid &&
                      $0.rect.centerX > 0.80 && $0.rect.centerY > 0.55
              }), PhonePageAdapters.identity(in: snapshot)?.scene != "wechat.chat" else {
            throw ChatEvidenceError.wrongConversation
        }
        let names = elements.filter {
            $0.label == target.title && (0.12...0.19).contains($0.rect.centerY) &&
                (0.20...0.50).contains($0.rect.x)
        }
        let messages = elements.filter {
            ["messages", "• messages", "发消息"].contains(PhonePageAdapters.normalized($0.label)) &&
                (0.32...0.48).contains($0.rect.centerY) && (0.35...0.65).contains($0.rect.centerX)
        }
        guard names.count == 1, messages.count == 1 else { throw ChatEvidenceError.wrongConversation }
        let name = names[0], message = messages[0]
        let accountRows = elements.filter {
            (0.15...0.24).contains($0.rect.centerY) && $0.rect.centerY > name.rect.centerY + 0.01 &&
                (0.20...0.50).contains($0.rect.x)
        }
        let fieldNames = ["微信号", "wechat id", "weixin id"]
        var accounts: [(String, [String])] = []
        for row in accountRows {
            let raw = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let colon = raw.firstIndex(where: { $0 == ":" || $0 == "：" })
            let field = PhonePageAdapters.normalized(colon.map { String(raw[..<$0]) } ?? raw)
            guard fieldNames.contains(field) else { continue }
            let inlineValue = colon.map { String(raw[raw.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
            if !inlineValue.isEmpty { accounts.append((inlineValue, [row.id])); continue }
            let values = elements.filter {
                $0.id != row.id && $0.rect.x >= row.rect.x + row.rect.width - 0.015 &&
                    abs($0.rect.centerY - row.rect.centerY) < 0.015 &&
                    (try? stableID(account: $0.label)) != nil
            }
            guard values.count == 1 else { throw ChatEvidenceError.wrongConversation }
            accounts.append((values[0].label, [row.id, values[0].id]))
        }
        guard accounts.count == 1, accounts[0].0 == "filehelper" else { throw ChatEvidenceError.wrongConversation }
        // About may be covered by AssistiveTouch. Its full, dedicated text
        // block remains mandatory and is kept as actual individual OCR lines.
        let description = elements.filter {
            (0.23...0.34).contains($0.rect.centerY) && (0.20...0.32).contains($0.rect.x) &&
                $0.rect.centerY < message.rect.y - 0.015
        }.sorted { $0.rect.centerY < $1.rect.centerY }
        let text = PhonePageAdapters.normalized(description.map(\.label).joined(separator: " "))
        let expected = "transfer text, images, audio and video files between your device and your pc"
        guard (1...4).contains(description.count), [expected, expected + "."].contains(text),
              description.allSatisfy({ $0.rect.centerY > (accountRows.map(\.rect.centerY).max() ?? 1) }),
              zip(description, description.dropFirst()).allSatisfy({ before, after in
                  (0.005...0.05).contains(after.rect.centerY - before.rect.centerY) && abs(after.rect.x - before.rect.x) < 0.035
              }) else {
            throw ChatEvidenceError.wrongConversation
        }
        let visuals = snapshot.elements.filter {
            $0.source == "local_visual" && $0.rect.valid && (($0.label == "视觉:返回" ? 0.015 : 0.02)...0.14).contains($0.rect.width) &&
                $0.rect.centerY < 0.12 && $0.rect.y > 0.04
        }
        let back = visuals.filter { $0.label == "视觉:返回" && $0.rect.centerX < 0.18 && (0.008...0.10).contains($0.rect.height) }
        let more = visuals.filter { $0.label == "视觉:更多" && $0.rect.centerX > 0.80 && (0.0025...0.10).contains($0.rect.height) }
        guard back.count == 1, more.count == 1 else { throw ChatEvidenceError.wrongConversation }
        let evidence = [back[0].id, more[0].id, name.id] + accounts[0].1 + description.map(\.id) + [message.id]
        guard Set(evidence).count == evidence.count, evidence.allSatisfy({ snapshot.element(id: $0) != nil }) else {
            throw ChatEvidenceError.wrongConversation
        }
        return .init(frameID: frameID, captureSessionID: captureSessionID, snapshot: snapshot,
            account: "filehelper", title: target.title, evidenceElementIDs: evidence, messageElementID: message.id, confirmedAt: confirmedAt)
    }
}
