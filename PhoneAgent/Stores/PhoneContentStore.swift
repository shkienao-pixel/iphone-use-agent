import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// The injected access boundary permits offline tests to exercise the production
/// transaction without reading the developer's clipboard or operating a phone.
@MainActor
struct PhoneClipboardAccess {
    var isForeground: () -> Bool
    var write: (String, Date) throws -> Void
    var read: () -> String?
    var changeCount: () -> Int
    static var system: Self {
        #if canImport(UIKit)
        Self(isForeground: { UIApplication.shared.applicationState == .active }, write: { text, expiry in
            UIPasteboard.general.setItems([["public.utf8-plain-text": Data(text.utf8)]],
                                         options: [.localOnly: true, .expirationDate: expiry])
        }, read: { UIPasteboard.general.string }, changeCount: { UIPasteboard.general.changeCount })
        #else
        Self(isForeground: { false }, write: { _, _ in throw PhoneContentError.foregroundRequired }, read: { nil }, changeCount: { 0 })
        #endif
    }
}

@MainActor
final class PhoneContentStore: ObservableObject {
    static let shared = PhoneContentStore()
    static let maximumArtifacts = 100
    @Published private(set) var artifacts: [PhoneContentArtifact] = []
    @Published private(set) var preparations: [PhoneClipboardPreparation] = []
    @Published private(set) var error = ""
    private let url: URL
    private let clipboard: PhoneClipboardAccess
    private var readable = true
    // Restoring a persisted receipt never restores clipboard execution authority.
    private var currentPreparations: [String: PhoneClipboardPreparation] = [:]
    private struct Document: Codable { var version = 1; var artifacts: [PhoneContentArtifact]; var preparations: [PhoneClipboardPreparation] }

    init(url: URL? = nil, clipboard: PhoneClipboardAccess? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/phone-content.json")
        self.clipboard = clipboard ?? .system
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            guard (try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw PhoneContentError.unavailable }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
            guard document.version == 1 else { throw PhoneContentError.unavailable }
            try Self.validate(document)
            artifacts = document.artifacts
            preparations = document.preparations.map { prior in
                var receipt = prior
                if receipt.state == .preparing {
                    receipt.state = .unknown
                    receipt.detail = "上次准备中断，无法确认剪贴板结果；先核对目标已有内容，不自动重复粘贴"
                }
                return receipt
            }
        } catch { readable = false; self.error = PhoneContentError.unavailable.localizedDescription }
    }
    @discardableResult
    func create(title: String, body: String) throws -> PhoneContentArtifact {
        try Task.checkCancellation()
        let value = try PhoneContentArtifact(title: title, body: body)
        try save(artifacts: artifacts + [value], preparations: preparations)
        return value
    }
    func artifact(reference: String) throws -> PhoneContentArtifact {
        guard readable else { throw PhoneContentError.unavailable }
        guard PhoneContentArtifact.validReference(reference), let value = artifacts.first(where: { $0.reference == reference }) else { throw PhoneContentError.invalidReference }
        try value.validate(); return value
    }
    @discardableResult
    func prepareClipboard(reference: String, now: Date = Date()) throws -> PhoneClipboardPreparation {
        let value = try artifact(reference: reference)
        guard clipboard.isForeground() else { throw PhoneContentError.foregroundRequired }
        try Task.checkCancellation()
        var receipt = PhoneClipboardPreparation(id: UUID(), artifactReference: value.reference, preparedAt: now,
            expiresAt: now.addingTimeInterval(120), changeCount: nil, state: .preparing, detail: "准备写入；不能证明目标已粘贴或保存")
        try save(artifacts: artifacts, preparations: Array(preparations.suffix(199)) + [receipt])
        // Remove any earlier lease before attempting to change the clipboard.
        currentPreparations.removeAll()
        do {
            try Task.checkCancellation()
            guard clipboard.isForeground() else { throw PhoneContentError.foregroundRequired }
            try clipboard.write(value.body, receipt.expiresAt)
            guard clipboard.isForeground(), let actual = clipboard.read(),
                  Data(actual.utf8) == Data(value.body.utf8) else { throw PhoneContentError.clipboardMismatch }
            receipt.changeCount = clipboard.changeCount(); receipt.state = .prepared
            receipt.detail = "仅本机剪贴板全文 UTF-8 回读一致；不代表输入框聚焦、已粘贴、保存或发送。切换 App 后剪贴板可能变化，目标正文仍须独立核验。"
            try replace(receipt)
            currentPreparations[reference] = receipt
            try Task.checkCancellation()
            return receipt
        } catch {
            currentPreparations.removeAll()
            receipt.state = .unknown; receipt.detail = "准备被中断或无法核验；先查看目标已有内容，不自动重复粘贴"
            try? replace(receipt)
            throw error
        }
    }
    /// Metadata only; no background clipboard reads. A valid lease must still be
    /// paired with current target/focus evidence and post-paste verification.
    func clipboardLease(reference: String, now: Date = Date()) throws -> PhoneClipboardPreparation {
        _ = try artifact(reference: reference)
        guard let receipt = currentPreparations[reference], receipt.state == .prepared else { throw PhoneContentError.notPrepared }
        guard receipt.expiresAt > now, now >= receipt.preparedAt else { throw PhoneContentError.expiredPreparation }
        return receipt
    }
    func invalidatePreparations() { currentPreparations.removeAll() }
    func status(reference: String) throws -> String {
        let value = try artifact(reference: reference)
        var metadata = value.metadata
        let latest = preparations.last(where: { $0.artifactReference == reference })
        metadata["last_preparation"] = latest?.state.rawValue ?? "none"
        metadata["current_session_lease"] = (try? clipboardLease(reference: reference)) == nil ? "unavailable" : "prepared"
        metadata["target_verification"] = "unknown: clipboard preparation is not a paste/save/send receipt"
        return String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? "{}"
    }
    func exportData() throws -> Data {
        guard readable else { return try Data(contentsOf: url) }
        return try JSONEncoder().encode(Document(artifacts: artifacts, preparations: preparations))
    }
    private func replace(_ receipt: PhoneClipboardPreparation) throws {
        var values = preparations
        guard let index = values.firstIndex(where: { $0.id == receipt.id }) else { throw PhoneContentError.unavailable }
        values[index] = receipt; try save(artifacts: artifacts, preparations: values)
    }
    private static func validate(_ document: Document) throws {
        guard document.artifacts.count <= maximumArtifacts, document.preparations.count <= 200,
              Set(document.artifacts.map(\.id)).count == document.artifacts.count,
              Set(document.preparations.map(\.id)).count == document.preparations.count else { throw PhoneContentError.unavailable }
        for value in document.artifacts { try value.validate() }
        let refs = Set(document.artifacts.map(\.reference))
        for value in document.preparations {
            guard refs.contains(value.artifactReference), value.expiresAt > value.preparedAt,
                  value.expiresAt.timeIntervalSince(value.preparedAt) <= 120, value.detail.count <= 1000,
                  value.state != .prepared || value.changeCount != nil else { throw PhoneContentError.unavailable }
        }
    }
    private func save(artifacts values: [PhoneContentArtifact], preparations receipts: [PhoneClipboardPreparation]) throws {
        guard readable else { throw PhoneContentError.unavailable }
        let document = Document(artifacts: values, preparations: receipts); try Self.validate(document)
        let data = try JSONEncoder().encode(document)
        guard data.count <= 8_000_000 else { throw PhoneContentError.unavailable }
        let folder = url.deletingLastPathComponent(); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var backup = URLResourceValues(); backup.isExcludedFromBackup = true; var directory = folder; try directory.setResourceValues(backup)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        artifacts = values; preparations = receipts; error = ""
    }
}
