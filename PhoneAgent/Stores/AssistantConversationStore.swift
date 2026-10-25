import Foundation

enum AssistantConversationStoreError: LocalizedError {
    case unavailable, limit, invalid
    var errorDescription: String? {
        switch self {
        case .unavailable: return "对话记录暂时无法读取或保存，原文件已保留。本次对话仍可继续。"
        case .limit: return "对话记录已达到本地保存上限，已有记录已保留。"
        case .invalid: return "对话记录内容无效，原文件已保留。"
        }
    }
}

/// Transactional archive. A failed read permanently disables writes for this
/// instance; a corrupt or future-version archive is never replaced with blanks.
@MainActor
final class AssistantConversationStore {
    private(set) var records: [AssistantConversationRecord] = []
    private(set) var currentConversationID = UUID()
    private(set) var error = ""
    private var readable = true
    private let url: URL
    private let maximumBytes = 32_000_000
    private struct Document: Codable {
        var version = 1
        var currentConversationID: UUID
        var records: [AssistantConversationRecord]
    }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent", isDirectory: true).appendingPathComponent("conversations.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            guard (try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumBytes) < maximumBytes else {
                throw AssistantConversationStoreError.limit
            }
            let data = try Data(contentsOf: self.url)
            guard data.count < maximumBytes else { throw AssistantConversationStoreError.limit }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw AssistantConversationStoreError.invalid }
            try validate(document.records)
            records = sorted(document.records); currentConversationID = document.currentConversationID
        } catch {
            readable = false
            self.error = AssistantConversationStoreError.unavailable.localizedDescription
        }
    }

    func upsert(_ record: AssistantConversationRecord, currentConversationID: UUID) throws {
        guard readable else { throw AssistantConversationStoreError.unavailable }
        var updated = records.filter { $0.id != record.id }
        if !record.messages.isEmpty || !record.draft.isEmpty || !(record.draftAttachments ?? []).isEmpty { updated.append(record) }
        try persist(sorted(updated), currentConversationID: currentConversationID)
    }

    func activate(_ id: UUID) throws {
        guard readable else { throw AssistantConversationStoreError.unavailable }
        try persist(records, currentConversationID: id)
    }

    func save(_ records: [AssistantConversationRecord], currentConversationID: UUID) throws {
        guard readable else { throw AssistantConversationStoreError.unavailable }
        try persist(sorted(records), currentConversationID: currentConversationID)
    }

    private func sorted(_ values: [AssistantConversationRecord]) -> [AssistantConversationRecord] {
        values.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    private func validate(_ records: [AssistantConversationRecord]) throws {
        guard records.count <= 100, Set(records.map(\.id)).count == records.count else { throw AssistantConversationStoreError.limit }
        for record in records {
            try ComposerAttachmentPolicy.validate(record.draftAttachments ?? [])
            for message in record.messages { try ComposerAttachmentPolicy.validate(message.attachments ?? []) }
            guard !record.title.isEmpty, record.title.count <= 80, record.recipient.count <= 4000,
                  record.draft.count <= 4000, record.messages.count <= 100,
                  record.createdAt.timeIntervalSince1970.isFinite, record.updatedAt.timeIntervalSince1970.isFinite,
                  Set(record.messages.map(\.id)).count == record.messages.count,
                  valid(record.contextReferences), record.messages.allSatisfy({ message in
                      ["user", "assistant"].contains(message.role) && !message.text.isEmpty && message.text.count <= 60_000 &&
                      message.createdAt.timeIntervalSince1970.isFinite && valid(message.references ?? []) &&
                      (message.paotuiCard == nil || (message.paotuiCard!.valid && message.paotuiCard!.conversationID == record.id)) &&
                      (message.xhsCard == nil || (message.xhsCard!.valid && message.xhsCard!.conversationID == record.id))
                  }) else { throw AssistantConversationStoreError.invalid }
        }
    }

    private func valid(_ hits: [AssistantConversationContextHit]) -> Bool {
        hits.count <= 3 && hits.allSatisfy {
            !$0.title.isEmpty && $0.title.count <= 80 && $0.excerpt.count <= 902 &&
            $0.updatedAt.timeIntervalSince1970.isFinite && ($0.state?.count ?? 0) <= 80
        }
    }

    private func persist(_ updated: [AssistantConversationRecord], currentConversationID: UUID) throws {
        do {
            try validate(updated)
            let data = try JSONEncoder().encode(Document(currentConversationID: currentConversationID, records: updated))
            guard data.count < maximumBytes else { throw AssistantConversationStoreError.limit }
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = folder; try excluded.setResourceValues(values)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            records = updated; self.currentConversationID = currentConversationID; error = ""
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
}
