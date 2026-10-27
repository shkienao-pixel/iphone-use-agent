import Foundation
import Darwin

/// An inert, deliberately narrow persistence format. No address/contact body,
/// provider request, quote, card, token or confirmation right can be encoded.
struct PaotuiPreparationSnapshot: Codable, Equatable {
    let conversationID: UUID
    let savedAt: Date
    let credentialFingerprint: String
    let service: PaotuiService?
    let goods: String
    let remark: String
    let nearby: Bool
    let category: PaotuiCategory?
    let weight: Double?
    let inquiryOnly: Bool
    let merchantKeyword: String
    let city: String
    let savedRecipientReference: String?
    let savedSenderReference: String?

    @MainActor init(session: PaotuiSession, addresses: [PaotuiAddress], credential: String, at date: Date) {
        conversationID = session.origin.conversationID!
        savedAt = date; credentialFingerprint = session.credentialScope
        let value = session.preparation
        service = value.draft.service
        goods = Self.safeText(value.draft.goods, credential: credential, limit: 500)
        remark = Self.safeText(value.draft.remark, credential: credential, limit: 500)
        nearby = value.draft.nearby; category = value.draft.category; weight = value.draft.weight
        inquiryOnly = value.inquiryOnly
        merchantKeyword = Self.safeText(value.keyword, credential: credential, limit: 120)
        city = Self.safeText(value.city, credential: credential, limit: 40)
        func saved(_ id: String) -> String? {
            guard id.range(of: #"^address:[0-9]{1,19}$"#, options: .regularExpression) != nil,
                  addresses.contains(where: { $0.id == id && $0.savedID != nil }) else { return nil }
            return id
        }
        savedRecipientReference = saved(value.draft.recipientID)
        savedSenderReference = saved(value.draft.senderID)
    }

    var needsPreservation: Bool {
        service != nil || !goods.isEmpty || !remark.isEmpty || !merchantKeyword.isEmpty || inquiryOnly || weight != nil || category != nil
    }
    var isValid: Bool {
        credentialFingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil &&
        goods.count <= 500 && remark.count <= 500 && merchantKeyword.count <= 120 && city.count <= 40 &&
        (weight.map { $0.isFinite && (0.1...50).contains($0) } ?? true) &&
        [savedRecipientReference, savedSenderReference].allSatisfy {
            $0.map { $0.range(of: #"^address:[0-9]{1,19}$"#, options: .regularExpression) != nil } ?? true
        } && [goods, remark, merchantKeyword, city].allSatisfy { Self.safeText($0, credential: "", limit: 500) == $0 }
    }
    /// Recovered references remain inert. Current addresses must be fetched and
    /// selected again, and merchants must be searched again before a new quote.
    @MainActor var preparationForReview: PaotuiSession.Preparation {
        var value = PaotuiSession.Preparation()
        value.draft = PaotuiDraft(service: service, nearby: nearby, goods: goods, remark: remark, category: category, weight: weight)
        value.keyword = merchantKeyword; value.city = city; value.inquiryOnly = inquiryOnly
        return value
    }
    static func safeText(_ value: String, credential: String, limit: Int) -> String {
        var value = value
        if !credential.isEmpty { value = value.replacingOccurrences(of: credential, with: "[已移除授权信息]") }
        // Free text is not a route for accidentally persisting credentials,
        // payment links, or full phone numbers supplied in a user's message.
        value = value.replacingOccurrences(of: #"https?://\S+"#, with: "[已移除链接]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)(?:bearer\s+\S+|[\"']?(?:[A-Za-z_]*token|authorization|cookie|password|secret|api[_-]?key)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,}]+)|[A-Za-z0-9_-]{32,})"#, with: "[已移除授权信息]", options: .regularExpression)
        value = PaotuiAddress.redactingPhones(value)
        // Persistence has no need to retain any long unmasked phone-like
        // sequence, including formatted mobiles, landlines and country codes.
        value = value.replacingOccurrences(of: #"(?<![0-9])\+?[0-9][0-9 ()-]{6,}[0-9](?![0-9])"#,
            with: "[已移除电话]", options: .regularExpression)
        return String(value.prefix(limit))
    }
}

struct PaotuiSavedPreparationSummary: Identifiable, Equatable {
    var id: UUID { conversationID }
    let conversationID: UUID
    let savedAt: Date
    let credentialMatches: Bool
    let inquiryOnly: Bool
    let serviceTitle: String?
    let goods: String
    let missingFields: [String]
    var reviewDescription: String { "仅恢复已脱敏的需求。请重新选择当前地址、查询门店和费用；历史确认不可继续下单。" }
}

/// Version 1 is the first preparation format. Unknown/corrupt bytes are never
/// migrated or overwritten. Durable tombstones win over an interrupted removal.
@MainActor final class PaotuiPreparationRepository {
    private struct Archive: Codable { let schemaVersion: Int; let preparations: [PaotuiPreparationSnapshot] }
    private let url: URL
    private let tombstoneDirectory: URL
    private let commit: (URL, URL) throws -> Void
    private let commitTombstone: (URL, URL) throws -> Void
    let capacity: Int
    private(set) var isReadable = true
    private(set) var issue: String?
    private(set) var snapshots: [PaotuiPreparationSnapshot] = []

    init(url: URL, capacity: Int = 128,
         commit: @escaping (URL, URL) throws -> Void = PaotuiPreparationRepository.atomicCommit,
         commitTombstone: @escaping (URL, URL) throws -> Void = PaotuiPreparationRepository.atomicCommit) {
        self.url = url; self.capacity = max(1, capacity); self.commit = commit; self.commitTombstone = commitTombstone
        tombstoneDirectory = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".cleared", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: url)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == 1, archive.preparations.count <= self.capacity,
                  Set(archive.preparations.map(\.conversationID)).count == archive.preparations.count,
                  archive.preparations.allSatisfy(\.isValid) else { throw CocoaError(.fileReadCorruptFile) }
            snapshots = archive.preparations.filter { !FileManager.default.fileExists(atPath: tombstone($0.conversationID).path) }
        } catch {
            isReadable = false
            issue = "跑腿准备记录暂时不可读，原文件已保留。订单记录仍独立保留，请勿从历史卡片重新提交。"
        }
    }
    func snapshot(for id: UUID) -> PaotuiPreparationSnapshot? { isReadable ? snapshots.first { $0.conversationID == id } : nil }

    func save(_ snapshot: PaotuiPreparationSnapshot) throws {
        guard isReadable, snapshot.isValid else { throw failure() }
        var updated = snapshots.filter { $0.conversationID != snapshot.conversationID }
        guard updated.count < capacity else {
            issue = "已保存的跑腿准备已达上限，请先移除不再需要的准备。"; throw failure()
        }
        updated.append(snapshot)
        try persist(updated)
        // Commit before removing the tombstone: a crash can only hide a newer
        // preparation, never resurrect one the user had forgotten.
        let marker = tombstone(snapshot.conversationID)
        if FileManager.default.fileExists(atPath: marker.path) {
            do { try FileManager.default.removeItem(at: marker) }
            catch { snapshots.removeAll { $0.conversationID == snapshot.conversationID }; issue = "新准备尚未完成保存，请检查存储空间后重试。"; throw failure() }
        }
        issue = nil
    }
    func discard(for id: UUID) throws {
        // Independent of archive readability: a clear request must remain
        // effective even while an unsupported/corrupt file is byte-preserved.
        do {
            try write(Data("cleared-v1".utf8), to: tombstone(id), commit: commitTombstone)
        } catch {
            // If a marker cannot be committed, quarantine the entire inert
            // archive with a same-directory rename. This preserves its bytes
            // while ensuring restart cannot silently offer the forgotten row.
            // It deliberately affects preparations only, never the journal.
            let quarantine = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".quarantine-" + UUID().uuidString)
            let quarantined = !FileManager.default.fileExists(atPath: url.path) || rename(url.path, quarantine.path) == 0
            issue = quarantined ? "准备恢复已停用，原文件已隔离保留；请检查存储空间。" :
                "跑腿准备清除未能保存，请检查存储空间；本次恢复入口已停用，原文件仍需处理。"
            isReadable = false; snapshots = []; throw failure()
        }
        snapshots.removeAll { $0.conversationID == id }
        guard isReadable else { return }
        do { try persist(snapshots); issue = nil }
        catch {
            // Tombstone already committed, so restart cannot revive this ID.
            issue = "准备已停止恢复，整理保存记录失败；原记录与订单事实仍保留。"
            throw failure()
        }
    }
    private func tombstone(_ id: UUID) -> URL { tombstoneDirectory.appendingPathComponent(id.uuidString) }
    private func failure() -> AgentError { .message(issue ?? "跑腿准备保存失败，请检查存储空间或文件权限。") }
    private func persist(_ updated: [PaotuiPreparationSnapshot]) throws {
        do {
            guard isReadable else { throw failure() }
            let data = try JSONEncoder().encode(Archive(schemaVersion: 1, preparations: updated))
            guard data.count <= 1_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            try write(data, to: url, commit: commit)
            snapshots = updated
        } catch { issue = "跑腿准备保存失败，请检查存储空间或文件权限。"; throw failure() }
    }
    private func write(_ data: Data, to destination: URL, commit: (URL, URL) throws -> Void) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stage = directory.appendingPathComponent(".paotui-preparation-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: stage) }
        #if os(iOS)
        try data.write(to: stage, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: stage, options: .atomic)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try stage.setResourceValues(values)
        try commit(stage, destination)
    }
    nonisolated static func atomicCommit(_ staged: URL, _ destination: URL) throws {
        let descriptor = open(staged.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0, rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
