import Foundation

struct WeChatFileTransferObservation {
    var snapshot: PhoneUISnapshot
    var captureSessionID: UUID
    var frameID: String
    var confirmedAt: Date? = nil
    var effectiveConfirmedAt: Date { confirmedAt ?? snapshot.capturedAt }
}

/// Created by the native host only AFTER a UIActivityViewController is actually
/// presented using exactly payload.fileURLs. This is native source custody,
/// never a claim that a third-party picker exposed a remote file's hash.
struct WeChatNativeShareBinding {
    var presentationID: UUID
    var payloadBindingID: UUID
    var artifactIDs: [UUID]
    var fileURLs: [URL]
    var presentedAt: Date
    init(presentationID: UUID, payload: FileTransferPayload, presentedAt: Date = Date()) {
        self.presentationID = presentationID; self.payloadBindingID = payload.bindingID
        self.artifactIDs = payload.manifest.map(\.id); self.fileURLs = payload.fileURLs; self.presentedAt = presentedAt
    }
    func validate(payload: FileTransferPayload) throws {
        guard payloadBindingID == payload.bindingID, artifactIDs == payload.manifest.map(\.id),
              fileURLs.map(\.standardizedFileURL) == payload.fileURLs.map(\.standardizedFileURL),
              presentedAt <= Date(), Date().timeIntervalSince(presentedAt) < 15 else {
            throw FileTransferError.invalid("原生分享控制器未绑定这批准确原件和顺序")
        }
    }
}

struct WeChatFileConfirmation {
    var recipient: FileTransferRecipientEvidence
    var filenames: [PhoneUIElement]
    var byteSizes: [PhoneUIElement]
    var originalMode: PhoneUIElement
    var send: PhoneUIElement
}

enum WeChatFileTransferPages {
    static func unique(_ labels: [String], in snapshot: PhoneUISnapshot,
                       region: (PhoneUIRect) -> Bool = { _ in true }) -> PhoneUIElement? {
        guard !snapshot.blockingOverlay else { return nil }
        let keys = Set(labels.map(PhonePageAdapters.normalized))
        let values = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && region($0.rect) && keys.contains(PhonePageAdapters.normalized($0.label)) }
        return values.count == 1 ? values[0] : nil
    }
    static func uniqueExact(_ labels: [String], in snapshot: PhoneUISnapshot,
                            region: (PhoneUIRect) -> Bool = { _ in true }) -> PhoneUIElement? {
        guard !snapshot.blockingOverlay else { return nil }
        let values = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && region($0.rect) && labels.contains($0.label) }
        return values.count == 1 ? values[0] : nil
    }
    static func activity(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard ["存储到文件", "Save to Files", "拷贝", "Copy", "选项", "Options"].contains(where: { unique([$0], in: snapshot, region: { $0.centerY > 0.18 }) != nil }) else { return nil }
        return unique(["微信", "WeChat"], in: snapshot, region: { (0.18...0.85).contains($0.centerY) })
    }
    static func extensionHeading(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        unique(["发送给", "发送给：", "Send to", "Send to:", "选择聊天", "Select Chat"], in: snapshot, region: { $0.centerY < 0.35 })
    }
    /// Account labels must be standalone, explicit platform-account fields.
    /// A nickname containing an ID or arbitrary message body is not identity.
    static func recipient(_ target: FileTransferRecipient, in snapshot: PhoneUISnapshot) -> FileTransferRecipientEvidence? {
        guard extensionHeading(in: snapshot) != nil,
              let title = uniqueExact([target.displayName], in: snapshot, region: { (0.12...0.5).contains($0.centerY) }) else { return nil }
        switch target.kind {
        case .builtinSelfTransfer:
            guard PhonePageAdapters.selfConversation(target.displayName), let explanation = PhonePageAdapters.selfTransferEvidence(in: snapshot) else { return nil }
            return .init(stableID: target.stableID, basis: .builtinTransferExplanation, conversationEvidenceID: title.id + ":" + explanation.id)
        case .userSelectedStableAccount:
            guard target.stableID.hasPrefix("wechat.account:") else { return nil }
            let account = String(target.stableID.dropFirst("wechat.account:".count))
            guard !account.isEmpty, let identity = uniqueExact(["微信号: " + account, "微信号：" + account, "微信号： " + account,
                "WeChat ID: " + account], in: snapshot, region: { (0.12...0.5).contains($0.centerY) }) else { return nil }
            return .init(stableID: target.stableID, basis: .stableAccountIdentifier, conversationEvidenceID: title.id + ":" + identity.id)
        case .nativeShareRequestedUnverified: return nil
        }
    }
    /// Choosing a recipient is permitted only when the row already carries the
    /// stable ID/built-in explanation. Display-name-only quick-send rows are
    /// never tapped: some extensions submit immediately on row selection.
    static func recipientRow(_ target: FileTransferRecipient, in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard recipient(target, in: snapshot) != nil,
              unique(["下一步", "Next"], in: snapshot, region: { $0.centerY < 0.2 || $0.centerY > 0.7 }) != nil else { return nil }
        return uniqueExact([target.displayName], in: snapshot, region: { (0.12...0.5).contains($0.centerY) })
    }
    static func exactByteCount(_ label: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: "^([0-9]+)\\s*(?:B|bytes|字节)$", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let range = Range(match.range(at: 1), in: label) else { return nil }
        return Int64(label[range])
    }
    static func confirmation(payload: FileTransferPayload, recipient target: FileTransferRecipient,
                             in snapshot: PhoneUISnapshot) throws -> WeChatFileConfirmation {
        guard let recipient = recipient(target, in: snapshot),
              let original = unique(["已选择原文件", "原文件模式已开启", "Original files selected", "Send original files selected"], in: snapshot),
              let send = unique(["发送", "Send", "发送原文件", "Send original files"], in: snapshot),
              Set(payload.manifest.map { $0.artifact.filename }).count == payload.manifest.count else {
            throw FileTransferError.unsupported("扩展需独立显示准确账号/内置说明、唯一发送控件和明确原文件模式；重名文件不能凭名字核验顺序")
        }
        let counts = snapshot.elements.compactMap { element -> Int? in
            guard element.source == "ocr", element.rect.valid,
                  let regex = try? NSRegularExpression(pattern: "^([0-9]+)\\s*(?:个文件|files?)$", options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: element.label, range: NSRange(element.label.startIndex..., in: element.label)),
                  let range = Range(match.range(at: 1), in: element.label) else { return nil }
            return Int(element.label[range])
        }
        guard counts == [payload.manifest.count] else { throw FileTransferError.unsupported("当前扩展未显示唯一准确文件数量；不从本机原件数伪造扩展选择数") }
        var names: [PhoneUIElement] = [], sizes: [PhoneUIElement] = []
        for item in payload.manifest {
            guard let name = uniqueExact([item.artifact.filename], in: snapshot, region: { (0.2...0.85).contains($0.centerY) }) else {
                throw FileTransferError.unsupported("确认页未完整显示每个原文件名，未点击发送")
            }
            let candidates = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid &&
                abs($0.rect.centerY - name.rect.centerY) < 0.055 && abs($0.rect.centerX - name.rect.centerX) < 0.35 &&
                exactByteCount($0.label) == item.artifact.byteCount }
            guard candidates.count == 1 else { throw FileTransferError.unsupported("确认页缺独立精确字节数；KB/MB缩写不当精确值") }
            names.append(name); sizes.append(candidates[0])
        }
        let visualOrder = names.sorted { a, b in
            abs(a.rect.centerY - b.rect.centerY) > 0.015 ? a.rect.centerY < b.rect.centerY : a.rect.centerX < b.rect.centerX
        }
        guard names.map(\.id) == visualOrder.map(\.id),
              Set(names.map(\.id)).count == names.count, Set(sizes.map(\.id)).count == sizes.count else {
            throw FileTransferError.invalid("扩展确认列表原件顺序或逐项大小锚点不唯一")
        }
        return .init(recipient: recipient, filenames: names, byteSizes: sizes, originalMode: original, send: send)
    }
    static func more(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        let titles = snapshot.elements.filter { $0.source == "ocr" && $0.rect.valid && $0.rect.centerY < 0.18 && (0.28...0.76).contains($0.rect.centerX) }
        guard titles.count == 1, WeChatContactIdentity.chatPage(snapshot: snapshot, title: titles[0].label) != nil else { return nil }
        if let text = unique(["+", "更多", "More"], in: snapshot, region: { $0.centerY > 0.72 && $0.centerX > 0.72 }) { return text }
        let symbols = snapshot.elements.filter { $0.source == "local_visual" && $0.label == "视觉:添加" && $0.rect.valid && $0.rect.centerY > 0.72 && $0.rect.centerX > 0.72 }
        return symbols.count == 1 ? symbols[0] : nil
    }
    static func fileMenu(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard ["相册", "Album", "拍摄", "Camera"].contains(where: { unique([$0], in: snapshot, region: { $0.centerY > 0.4 }) != nil }) else { return nil }
        return unique(["文件", "File", "Files"], in: snapshot, region: { $0.centerY > 0.4 })
    }
    static func phoneFiles(in snapshot: PhoneUISnapshot) -> PhoneUIElement? {
        guard ["文件", "Files", "聊天文件", "Chat Files", "聊天中的文件"].contains(where: { unique([$0], in: snapshot, region: { $0.centerY < 0.5 }) != nil }) else { return nil }
        return unique(["手机文件", "从文件选择", "Phone Files", "Select from Files"], in: snapshot)
    }
    static func filePicker(in snapshot: PhoneUISnapshot) -> Bool {
        unique(["取消", "Cancel"], in: snapshot, region: { $0.centerY < 0.2 }) != nil &&
        unique(["浏览", "Browse", "最近项目", "Recents"], in: snapshot) != nil
    }
    /// Overlay policy helper only: a caller may remove a generic Cancel
    /// blocker for these recognized menus. It must never suppress permission,
    /// login, payment, password or generic OK/confirmation dialogs.
    static func isAllowedMenu(_ snapshot: PhoneUISnapshot) -> Bool {
        let forbidden = ["允许", "不允许", "allow", "don't allow", "登录", "log in", "付款", "pay", "确认付款", "输入密码", "enter passcode", "确定", "ok"]
        guard !snapshot.elements.contains(where: { forbidden.contains(PhonePageAdapters.normalized($0.label)) }) else { return false }
        var clean = snapshot; clean.blockingOverlay = false
        if activity(in: clean) != nil { return true }
        if extensionHeading(in: clean) != nil,
           unique(["取消", "Cancel"], in: clean) != nil,
           (["发送", "Send", "下一步", "Next", "搜索", "Search"].contains { unique([$0], in: clean) != nil }) { return true }
        if fileMenu(in: clean) != nil,
           ["相册", "Album"].contains(where: { unique([$0], in: clean, region: { $0.centerY > 0.4 }) != nil }),
           ["拍摄", "Camera"].contains(where: { unique([$0], in: clean, region: { $0.centerY > 0.4 }) != nil }) { return true }
        if phoneFiles(in: clean) != nil { return true }
        return filePicker(in: clean)
    }
    static func encodedSnapshot(_ observation: WeChatFileTransferObservation) throws -> String {
        struct Record: Encodable { var frameID: String; var captureSessionID: UUID; var snapshot: PhoneUISnapshot; var confirmedAt: Date }
        return String(decoding: try JSONEncoder().encode(Record(frameID: observation.frameID, captureSessionID: observation.captureSessionID, snapshot: observation.snapshot, confirmedAt: observation.effectiveConfirmedAt)), as: UTF8.self)
    }
}
