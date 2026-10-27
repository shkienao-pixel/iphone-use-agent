import Foundation
import Darwin
import CryptoKit

/// A person's account of their check in Meituan, never a platform order status.
enum PaotuiReviewConclusion: String, Codable, CaseIterable, Identifiable {
    case believesCreated, believesNotCreated, stillUnknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .believesCreated: "我认为已有订单"
        case .believesNotCreated: "我认为未创建订单"
        case .stillUnknown: "仍无法确定"
        }
    }
}

struct PaotuiPendingReview: Identifiable {
    let id: UUID
    let createdAt: Date
    let requestSummary: String?
    let deliveryAmount: PaotuiMoney?
    var deliveryFee: Double? { deliveryAmount?.displayValue }
    let isCurrentAuthorization: Bool
    let isSameCredentialScope: Bool
    let lastConclusion: PaotuiReviewConclusion?
    let reviewedAt: Date?
    let reviewSource: String?
    /// A user-supplied reference, never a verified provider receipt.
    let reportedOrderReference: String?
}

/// A token-derived local scope. Passport has not supplied a verified, stable
/// Meituan account ID; this type must never be presented as provider identity.
struct PaotuiCredentialBinding: Codable, Equatable {
    enum Kind: String, Codable { case credentialScope }
    let kind: Kind
    let fingerprint: String
    init(credentialScope: String) { kind = .credentialScope; fingerprint = credentialScope }
}

/// Captured from the native submission grant, before asynchronous dispatch.
/// Historical and direct-service fixture attempts may have no context.
struct PaotuiAttemptContext: Codable, Equatable {
    let sessionID: UUID
    let conversationID: UUID?
    let taskOrigin: String?
    let revision: UInt64
    let credentialEpoch: UUID
    let quoteID: UUID
    let credentialBinding: PaotuiCredentialBinding
}

struct PaotuiJournalMaintenanceSnapshot: Equatable {
    let isReadable: Bool
    let activeReceiptCount: Int
    let archivedReceiptCount: Int
    let unresolvedReceiptCount: Int
    let resolvedReceiptCount: Int
    let archivePageCount: Int
    let activeCapacity: Int
    var canArchive: Bool { isReadable && resolvedReceiptCount > 0 }
}

/// Owns provider receipts and separate human judgments. Schema 3 adds optional
/// native correlation without inventing context for historical records.
@MainActor final class PaotuiOrderJournal {
    private enum ReceiptState: String, Codable { case unknown, created, reviewed }
    private struct HumanReview: Codable, Equatable {
        let conclusion: PaotuiReviewConclusion
        let reviewedAt: Date
        let source: String
        let reportedOrderReference: String?
    }
    private struct OrderReceipt: Codable, Equatable {
        let attemptID: UUID
        let quoteID: UUID
        let account: String
        var journalSequence: UInt64?
        let credentialBinding: PaotuiCredentialBinding
        let context: PaotuiAttemptContext?
        var state: ReceiptState
        /// Written only from a provider-created response, never from human review.
        var orderID: String?
        let createdAt: Date
        let requestSummary: String?
        let deliveryAmount: PaotuiMoney?
        var reviews: [HumanReview]

        private enum CodingKeys: String, CodingKey {
            case attemptID, quoteID, account, journalSequence, credentialBinding, context, state, orderID, createdAt, requestSummary, deliveryAmount, reviews
        }
        private enum LegacyCodingKeys: String, CodingKey { case deliveryFee }
        init(attemptID: UUID, quoteID: UUID, account: String, state: ReceiptState, orderID: String?,
             createdAt: Date, requestSummary: String?, deliveryAmount: PaotuiMoney?, reviews: [HumanReview],
             context: PaotuiAttemptContext? = nil, journalSequence: UInt64? = nil) {
            self.attemptID = attemptID; self.quoteID = quoteID; self.account = account; self.state = state
            self.orderID = orderID; self.createdAt = createdAt; self.requestSummary = requestSummary
            self.deliveryAmount = deliveryAmount; self.reviews = reviews
            self.credentialBinding = PaotuiCredentialBinding(credentialScope: account); self.context = context
            self.journalSequence = journalSequence
        }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            attemptID = try fields.decode(UUID.self, forKey: .attemptID)
            quoteID = try fields.decode(UUID.self, forKey: .quoteID)
            account = try fields.decode(String.self, forKey: .account)
            journalSequence = try fields.decodeIfPresent(UInt64.self, forKey: .journalSequence)
            credentialBinding = try fields.decodeIfPresent(PaotuiCredentialBinding.self, forKey: .credentialBinding)
                ?? PaotuiCredentialBinding(credentialScope: account)
            context = try fields.decodeIfPresent(PaotuiAttemptContext.self, forKey: .context)
            state = try fields.decode(ReceiptState.self, forKey: .state)
            orderID = try fields.decodeIfPresent(String.self, forKey: .orderID)
            createdAt = try fields.decode(Date.self, forKey: .createdAt)
            requestSummary = try fields.decodeIfPresent(String.self, forKey: .requestSummary)
            reviews = try fields.decode([HumanReview].self, forKey: .reviews)
            if fields.contains(.deliveryAmount) {
                deliveryAmount = try fields.decodeIfPresent(PaotuiMoney.self, forKey: .deliveryAmount)
            } else {
                let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
                let fee = try legacy.decodeIfPresent(Double.self, forKey: .deliveryFee)
                // Unrepresentable historical fees stay unknown. Order facts and
                // their unresolved barrier survive even a malformed old amount.
                deliveryAmount = fee.flatMap { try? PaotuiMoney(displayValue: $0) }
            }
        }
    }
    private struct ArchiveReference: Codable, Equatable {
        let pageNumber: Int
        let pageID: UUID
        let fileSHA256: String
    }
    private struct OrderJournal: Codable {
        let schemaVersion: Int
        let receipts: [OrderReceipt]
        let archivePages: [ArchiveReference]
        private enum CodingKeys: String, CodingKey { case schemaVersion, receipts, archivePages }
        init(schemaVersion: Int, receipts: [OrderReceipt], archivePages: [ArchiveReference]) {
            self.schemaVersion = schemaVersion; self.receipts = receipts; self.archivePages = archivePages
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            receipts = try values.decode([OrderReceipt].self, forKey: .receipts)
            archivePages = schemaVersion >= 3 ? try values.decode([ArchiveReference].self, forKey: .archivePages) : []
        }
    }
    private struct LegacyOrderReceipt: Decodable {
        let quoteID: UUID
        let account: String
        let state: String
        let orderID: String?
        let createdAt: Date
    }

    private struct ArchivePage: Codable {
        let schemaVersion: Int
        let pageNumber: Int
        let pageID: UUID
        let receipts: [OrderReceipt]
        let sha256: String
    }
    private struct ArchiveContents {
        let receipts: [OrderReceipt]
        let pageCount: Int
        let lastPageNumber: Int
        let totalBytes: Int
        let references: [ArchiveReference]
        let pages: [ArchivePage]
    }
    private static let activeCapacity = 2000
    private static let maximumFileBytes = 2_000_000
    private static let maximumArchiveBytes = 64_000_000
    private static let maximumArchivePages = 256
    private let url: URL
    private var archiveURL: URL { url.appendingPathExtension("archive") }
    private let clock: PaotuiClock
    private let commit: (URL, URL) throws -> Void
    private var receipts: [OrderReceipt] = []
    private var archivedReceipts: [OrderReceipt] = []
    private var archivePageCount = 0
    private var archiveReferences: [ArchiveReference] = []
    private(set) var isReadable = true
    /// Called only after a durable commit and the matching in-memory update.
    var onChange: (() -> Void)?

    init(url: URL, clock: PaotuiClock? = nil,
         commit: @escaping (URL, URL) throws -> Void = { staged, destination in
             guard rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
         }) {
        self.url = url; self.clock = clock ?? .system; self.commit = commit
        do {
            let archive = try readArchive()
            archivedReceipts = archive.receipts; archivePageCount = archive.pageCount
            guard FileManager.default.fileExists(atPath: url.path) else {
                guard archive.references.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                return
            }
            let data = try Self.boundedData(url)
            let migrated: Bool
            var loaded: [OrderReceipt]
            let expectedArchive: [ArchiveReference]
            if let legacy = try? JSONDecoder().decode([LegacyOrderReceipt].self, from: data) {
                guard legacy.allSatisfy({ ["pending", "created", "reviewed"].contains($0.state) }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                loaded = legacy.map { old in
                    OrderReceipt(attemptID: old.quoteID, quoteID: old.quoteID, account: old.account,
                        state: old.state == "pending" ? .unknown : old.state == "created" ? .created : .reviewed,
                        orderID: old.orderID, createdAt: old.createdAt, requestSummary: nil, deliveryAmount: nil, reviews: [])
                }
                migrated = true; expectedArchive = []
            } else {
                let journal = try JSONDecoder().decode(OrderJournal.self, from: data)
                guard [1, 2, 3].contains(journal.schemaVersion) else { throw CocoaError(.fileReadCorruptFile) }
                loaded = journal.receipts; migrated = journal.schemaVersion != 3
                expectedArchive = journal.archivePages
            }
            if migrated {
                // This is original file order, not inferred conversation or
                // credential metadata. It keeps last-order lookup stable when
                // an older unknown resolves after a newer receipt is archived.
                for index in loaded.indices { loaded[index].journalSequence = UInt64(index) }
            }
            guard expectedArchive.count <= Self.maximumArchivePages,
                  Set(expectedArchive.map(\.pageID)).count == expectedArchive.count else { throw CocoaError(.fileReadCorruptFile) }
            let actualReferences = Dictionary(uniqueKeysWithValues: archive.references.map { ($0.pageID, $0) })
            for reference in expectedArchive {
                guard actualReferences[reference.pageID] == reference else { throw CocoaError(.fileReadCorruptFile) }
            }
            let loadedByID = Dictionary(loaded.map { ($0.attemptID, $0) }, uniquingKeysWith: { first, _ in first })
            let expectedIDs = Set(expectedArchive.map(\.pageID))
            let expectedFacts = Dictionary(archive.pages.filter { expectedIDs.contains($0.pageID) }.flatMap(\.receipts).map { ($0.attemptID, $0) }, uniquingKeysWith: { first, _ in first })
            for page in archive.pages where !expectedIDs.contains(page.pageID) {
                // An unreferenced page can only be the durable first half of an
                // interrupted move; it must match complete active facts exactly.
                guard page.receipts.allSatisfy({ loadedByID[$0.attemptID] == $0 || expectedFacts[$0.attemptID] == $0 }) else { throw CocoaError(.fileReadCorruptFile) }
            }
            archiveReferences = archive.references
            guard loaded.count <= Self.activeCapacity, Set(loaded.map(\.attemptID)).count == loaded.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try loaded.forEach(Self.validateReceipt)
            // A crash between archive commit and primary pruning can leave the
            // same complete fact in both files. Only identical facts deduplicate.
            let archivedByID = Dictionary(uniqueKeysWithValues: archivedReceipts.map { ($0.attemptID, $0) })
            let active = try loaded.filter { receipt in
                guard let archived = archivedByID[receipt.attemptID] else { return true }
                guard receipt == archived else { throw CocoaError(.fileReadCorruptFile) }
                return false
            }
            let sequences = archivedReceipts.compactMap(\.journalSequence) + active.compactMap(\.journalSequence)
            guard Set(sequences).count == archivedReceipts.count + active.count else { throw CocoaError(.fileReadCorruptFile) }
            // Old pending rows remain unknown; migration/recovery never sends HTTP.
            receipts = loaded
            if migrated || active.count != loaded.count { try persist(active) }
            else { receipts = active }
        } catch { isReadable = false }
    }

    var maintenanceSnapshot: PaotuiJournalMaintenanceSnapshot {
        PaotuiJournalMaintenanceSnapshot(isReadable: isReadable, activeReceiptCount: receipts.count,
            archivedReceiptCount: archivedReceipts.count,
            unresolvedReceiptCount: receipts.filter { $0.state == .unknown }.count,
            resolvedReceiptCount: receipts.filter { $0.state != .unknown }.count,
            archivePageCount: archivePageCount, activeCapacity: Self.activeCapacity)
    }

    func attemptContext(attemptID: UUID) -> PaotuiAttemptContext? {
        receipts.first { $0.attemptID == attemptID }?.context ?? archivedReceipts.first { $0.attemptID == attemptID }?.context
    }
    private func latestReceipt(where predicate: (OrderReceipt) -> Bool) -> OrderReceipt? {
        var latest: OrderReceipt?
        for receipt in archivedReceipts where predicate(receipt) {
            if latest == nil || (receipt.journalSequence ?? 0) > (latest?.journalSequence ?? 0) { latest = receipt }
        }
        for receipt in receipts where predicate(receipt) {
            if latest == nil || (receipt.journalSequence ?? 0) > (latest?.journalSequence ?? 0) { latest = receipt }
        }
        return latest
    }

    /// Archives only resolved facts. Unknowns, including a person's
    /// still-unknown report, always remain active and keep the global barrier.
    @discardableResult func archiveResolved() throws -> Int {
        guard isReadable else { throw AgentError.message("订单记录不可读，暂时无法归档。请保留本机记录。") }
        let moved = receipts.filter { $0.state != .unknown }
        guard !moved.isEmpty else { return 0 }
        do {
            // Re-read before maintenance so a prior interrupted commit is safely
            // recognized and corruption cannot be overwritten by a subsequent try.
            let existing = try readArchive()
            let actualReferences = Dictionary(uniqueKeysWithValues: existing.references.map { ($0.pageID, $0) })
            guard archiveReferences.allSatisfy({ actualReferences[$0.pageID] == $0 }) else { throw CocoaError(.fileReadCorruptFile) }
            let expectedIDs = Set(archiveReferences.map(\.pageID))
            let activeByID = Dictionary(uniqueKeysWithValues: receipts.map { ($0.attemptID, $0) })
            let priorByID = Dictionary(uniqueKeysWithValues: archivedReceipts.map { ($0.attemptID, $0) })
            for page in existing.pages where !expectedIDs.contains(page.pageID) {
                guard page.receipts.allSatisfy({ activeByID[$0.attemptID] == $0 || priorByID[$0.attemptID] == $0 }) else { throw CocoaError(.fileReadCorruptFile) }
            }
            var byID = Dictionary(uniqueKeysWithValues: existing.receipts.map { ($0.attemptID, $0) })
            var newRows: [OrderReceipt] = []
            for receipt in moved {
                if let old = byID[receipt.attemptID] {
                    guard old == receipt else { throw CocoaError(.fileReadCorruptFile) }
                } else { newRows.append(receipt); byID[receipt.attemptID] = receipt }
            }
            var pageCount = existing.pageCount, pageNumber = existing.lastPageNumber
            var references = existing.references
            if !newRows.isEmpty {
                guard pageCount < Self.maximumArchivePages else { throw CocoaError(.fileWriteOutOfSpace) }
                pageNumber += 1
                let page = ArchivePage(schemaVersion: 1, pageNumber: pageNumber, pageID: UUID(), receipts: newRows,
                    sha256: try Self.digest(newRows))
                let data = try Self.encode(page)
                guard data.count <= Self.maximumFileBytes, existing.totalBytes + data.count <= Self.maximumArchiveBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try prepareDirectory(archiveURL)
                let filename = String(format: "%08d", pageNumber) + "-" + page.pageID.uuidString + ".json"
                try write(data, to: archiveURL.appendingPathComponent(filename), syncDirectory: true)
                references.append(ArchiveReference(pageNumber: pageNumber, pageID: page.pageID, fileSHA256: Self.digest(data)))
                pageCount += 1
            }
            // The archive file and its directory are durable before this prune.
            // A failed prune keeps the old active rows in memory and on disk.
            try persist(receipts.filter { $0.state == .unknown }, archivePages: references, notify: false)
            archivedReceipts = existing.receipts + newRows
            archivePageCount = pageCount; archiveReferences = references
            onChange?()
            return moved.count
        } catch {
            throw AgentError.message("历史记录归档失败，原记录仍保留。请检查存储空间或文件权限后重试。")
        }
    }

    var hasUnresolvedSubmission: Bool { !isReadable || receipts.contains { $0.state == .unknown } }

    func pendingReviews(account: String, credentialEpoch: UUID? = nil) -> [PaotuiPendingReview] {
        receipts.filter { $0.state == .unknown }.map {
            PaotuiPendingReview(id: $0.attemptID, createdAt: $0.createdAt,
                requestSummary: $0.requestSummary, deliveryAmount: $0.deliveryAmount,
                isCurrentAuthorization: $0.account == account && credentialEpoch != nil && $0.context?.credentialEpoch == credentialEpoch,
                isSameCredentialScope: $0.account == account, lastConclusion: $0.reviews.last?.conclusion,
                reviewedAt: $0.reviews.last?.reviewedAt, reviewSource: $0.reviews.last?.source,
                reportedOrderReference: $0.reviews.reversed().compactMap(\.reportedOrderReference).first)
        }
    }

    func lastOrderID(account: String) -> String? {
        guard isReadable else { return nil }
        return latestReceipt(where: { $0.account == account && $0.state == .created })?.orderID
    }

    func orderURL(quoteID: UUID, account: String) -> URL? {
        guard isReadable, let receipt = latestReceipt(where: { $0.quoteID == quoteID && $0.account == account }) else { return nil }
        guard receipt.state == .created, let id = receipt.orderID else { return URL(string: "https://i.meituan.com/") }
        return Self.orderURL(orderID: id)
    }

    func knowsCreatedOrder(orderID: String, account: String) -> Bool {
        guard isReadable else { return false }
        return receipts.contains { $0.account == account && $0.orderID == orderID && $0.state == .created } ||
            archivedReceipts.contains { $0.account == account && $0.orderID == orderID && $0.state == .created }
    }

    func beginAttempt(quote: PaotuiQuote, account: String, context: PaotuiAttemptContext? = nil) throws -> UUID {
        guard isReadable else {
            throw AgentError.message("跑腿订单记录不可写，请先保留记录并核对已有订单。")
        }
        guard !hasUnresolvedSubmission else {
            throw AgentError.message("已有提交结果需要核验，请先逐笔核对，勿重复下单。")
        }
        guard let amount = quote.deliveryAmount, quote.originalDeliveryAmount != nil else {
            throw AgentError.message("跑腿报价金额无效，请重新查询费用")
        }
        if let context {
            guard context.quoteID == quote.id, context.credentialBinding.fingerprint == account,
                  Self.validContext(context) else {
                throw AgentError.message("本次跑腿提交上下文不匹配，请重新核对。")
            }
        }
        let greatestSequence = max(receipts.compactMap(\.journalSequence).max() ?? 0,
                                   archivedReceipts.compactMap(\.journalSequence).max() ?? 0)
        guard greatestSequence < UInt64.max else { throw AgentError.message("订单记录序号已满，请保留本机记录。") }
        let nextSequence = receipts.isEmpty && archivedReceipts.isEmpty ? 0 : greatestSequence + 1
        let id = UUID()
        let requestSummary: String?
        switch quote.draft.service {
        case .buy: requestSummary = "帮买"
        case .send:
            requestSummary = [quote.serviceTitle, quote.draft.category?.title].compactMap { $0 }.joined(separator: " · ")
        case nil: requestSummary = nil
        }
        var updated = receipts
        updated.append(OrderReceipt(attemptID: id, quoteID: quote.id, account: account,
            state: .unknown, orderID: nil, createdAt: clock.now(),
            requestSummary: requestSummary,
            deliveryAmount: amount, reviews: [], context: context, journalSequence: nextSequence))
        try persist(updated)
        return id
    }

    func markCreated(attemptID: UUID, orderID: String) throws {
        guard !orderID.isEmpty, let index = receipts.firstIndex(where: { $0.attemptID == attemptID && $0.state == .unknown }) else {
            throw AgentError.message("本机订单尝试记录不匹配，请在美团核对，勿重复下单。")
        }
        var updated = receipts
        updated[index].state = .created; updated[index].orderID = orderID
        try persist(updated)
    }

    func recordReview(attemptID: UUID, conclusion: PaotuiReviewConclusion, reportedOrderReference: String? = nil) throws {
        guard isReadable else {
            throw AgentError.message("订单记录暂时不可读，未解除提交限制。请先保留并核对本机记录。")
        }
        guard let index = receipts.firstIndex(where: { $0.attemptID == attemptID && $0.state == .unknown }) else {
            throw AgentError.message("这笔记录已处理或不存在，请使用当前待核验记录。")
        }
        let reference = try Self.normalizedReportedOrderReference(reportedOrderReference)
        var updated = receipts
        updated[index].reviews.append(HumanReview(conclusion: conclusion, reviewedAt: clock.now(),
            source: "user_report_in_sela", reportedOrderReference: reference))
        if conclusion != .stillUnknown { updated[index].state = .reviewed }
        // A failed write leaves the unknown row and the global barrier intact.
        try persist(updated)
    }

    private static func orderURL(orderID: String) -> URL? {
        URL(string: "https://i.meituan.com/order/" + orderID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
    }

    /// Narrow, local ID input only. URLs, phone-shaped numbers, free text and
    /// recognizable credential/payment material do not belong in human reports.
    private static func normalizedReportedOrderReference(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.utf8.count <= 128 else { throw AgentError.message("请只填写美团订单编号，不要填写链接、手机号或授权信息。") }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        let secretMarkers = ["token", "secret", "password", "credential", "bearer", "authorization", "payment", "pay_", "pay-", "sk-", "sk_", "pk_", "access_"]
        let digits = value.utf8.allSatisfy { (48...57).contains($0) }
        guard (4...64).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              value.utf8.contains(where: { (48...57).contains($0) }),
              !(digits && (10...15).contains(value.count)),
              !secretMarkers.contains(where: lower.contains) else {
            throw AgentError.message("请只填写美团订单编号，不要填写链接、手机号或授权信息。")
        }
        return value
    }

    private static func validContext(_ value: PaotuiAttemptContext) -> Bool {
        (value.conversationID != nil) != (value.taskOrigin != nil) &&
        (value.taskOrigin.map { !$0.isEmpty && $0.count <= 128 && !$0.contains("\n") } ?? true)
    }

    private static func validateReceipt(_ value: OrderReceipt) throws {
        guard value.journalSequence != nil, !value.account.isEmpty, value.account.count <= 256,
              value.credentialBinding.fingerprint == value.account,
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              value.state != .created || value.orderID?.isEmpty == false,
              value.orderID.map({ $0.count <= 256 }) ?? true,
              value.requestSummary.map({ $0.count <= 200 }) ?? true,
              value.reviews.count <= 2000,
              value.reviews.allSatisfy({ $0.reviewedAt.timeIntervalSinceReferenceDate.isFinite && $0.source == "user_report_in_sela" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for review in value.reviews {
            guard try normalizedReportedOrderReference(review.reportedOrderReference) == review.reportedOrderReference else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if let context = value.context {
            guard validContext(context), context.quoteID == value.quoteID,
                  context.credentialBinding == value.credentialBinding else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func digest(_ values: [OrderReceipt]) throws -> String {
        digest(try encode(values))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func boundedData(_ path: URL) throws -> Data {
        let values = try path.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let bytes = values.fileSize, bytes <= maximumFileBytes else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: path)
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    private func readArchive() throws -> ArchiveContents {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            return ArchiveContents(receipts: [], pageCount: 0, lastPageNumber: 0, totalBytes: 0, references: [], pages: [])
        }
        let values = try archiveURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        let files = try FileManager.default.contentsOfDirectory(at: archiveURL, includingPropertiesForKeys: [.fileSizeKey])
        // Staging files have never committed an archive fact. They may remain
        // after a process crash; every other unrecognized entry fails closed.
        let pages = files.filter { !$0.lastPathComponent.hasPrefix(".paotui-orders-") || $0.pathExtension != "tmp" }
        guard pages.count <= Self.maximumArchivePages else { throw CocoaError(.fileReadCorruptFile) }
        var bytes = 0, rows: [OrderReceipt] = [], byID: [UUID: OrderReceipt] = [:], numbers = Set<Int>(), pageIDs = Set<UUID>()
        var sequenceOwners: [UInt64: UUID] = [:]
        var lastNumber = 0, references: [ArchiveReference] = [], loadedPages: [ArchivePage] = []
        for path in pages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Self.boundedData(path); bytes += data.count
            guard bytes <= Self.maximumArchiveBytes else { throw CocoaError(.fileReadCorruptFile) }
            let page = try JSONDecoder().decode(ArchivePage.self, from: data)
            let filename = String(format: "%08d", page.pageNumber) + "-" + page.pageID.uuidString + ".json"
            guard page.schemaVersion == 1, page.pageNumber > 0, numbers.insert(page.pageNumber).inserted,
                  pageIDs.insert(page.pageID).inserted,
                  path.lastPathComponent == filename, !page.receipts.isEmpty,
                  page.receipts.count <= Self.activeCapacity,
                  page.receipts.allSatisfy({ $0.state != .unknown }),
                  page.sha256 == (try Self.digest(page.receipts)),
                  data == (try Self.encode(page)) else { throw CocoaError(.fileReadCorruptFile) }
            for receipt in page.receipts {
                try Self.validateReceipt(receipt)
                let sequence = receipt.journalSequence!
                guard sequenceOwners[sequence] == nil || sequenceOwners[sequence] == receipt.attemptID else { throw CocoaError(.fileReadCorruptFile) }
                sequenceOwners[sequence] = receipt.attemptID
                if let old = byID[receipt.attemptID] {
                    guard old == receipt else { throw CocoaError(.fileReadCorruptFile) }
                } else { byID[receipt.attemptID] = receipt; rows.append(receipt) }
            }
            lastNumber = max(lastNumber, page.pageNumber)
            references.append(ArchiveReference(pageNumber: page.pageNumber, pageID: page.pageID, fileSHA256: Self.digest(data)))
            loadedPages.append(page)
        }
        return ArchiveContents(receipts: rows, pageCount: pages.count, lastPageNumber: lastNumber,
            totalBytes: bytes, references: references, pages: loadedPages)
    }
    private func prepareDirectory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        var directory = path
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path.path)
        #endif
    }
    private func write(_ data: Data, to destination: URL, syncDirectory: Bool = false) throws {
        let directory = destination.deletingLastPathComponent()
        try prepareDirectory(directory)
        var staged = directory.appendingPathComponent(".paotui-orders-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        #if os(iOS)
        try data.write(to: staged, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: staged, options: .atomic)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try staged.setResourceValues(values)
        let file = open(staged.path, O_RDONLY)
        guard file >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let result = fsync(file); close(file)
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        try commit(staged, destination)
        // Archive pruning is allowed only after its directory entry is durable.
        // Primary's atomic rename is the publication boundary; no throwing work
        // follows it, so a reported failed primary write preserves old state.
        let folder = open(directory.path, O_RDONLY)
        if folder >= 0 {
            let result = fsync(folder); close(folder)
            if syncDirectory && result != 0 { throw CocoaError(.fileWriteUnknown) }
        } else if syncDirectory { throw CocoaError(.fileWriteUnknown) }
        if syncDirectory {
            // Persist creation of the archive directory itself before pruning.
            let parent = open(directory.deletingLastPathComponent().path, O_RDONLY)
            guard parent >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let result = fsync(parent); close(parent)
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    private func persist(_ updated: [OrderReceipt], archivePages: [ArchiveReference]? = nil, notify: Bool = true) throws {
        guard isReadable, updated.count <= Self.activeCapacity else {
            throw AgentError.message("跑腿订单记录不可写，请先归档已处理记录并核对已有订单。")
        }
        do {
            try updated.forEach(Self.validateReceipt)
            let sequences = updated.compactMap(\.journalSequence)
            guard Set(sequences).count == updated.count else { throw CocoaError(.fileWriteUnknown) }
            let data = try Self.encode(OrderJournal(schemaVersion: 3, receipts: updated, archivePages: archivePages ?? archiveReferences))
            guard data.count <= Self.maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try write(data, to: url)
        } catch {
            throw AgentError.message("本机订单记录保存失败。请检查存储空间或文件权限后重试。")
        }
        receipts = updated
        if notify { onChange?() }
    }
}
