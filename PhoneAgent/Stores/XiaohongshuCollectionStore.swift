import Foundation

/// Each batch is a complete atomic checkpoint. A corrupt/unknown document is
/// preserved and disables writes, rather than silently becoming an empty run.
@MainActor
final class XiaohongshuCollectionStore {
    static let shared = XiaohongshuCollectionStore()
    private var canonicalRuns: [ValidatedXiaohongshuCollectionRun] = []
    var runs: [XiaohongshuCollectionRun] { canonicalRuns.map(\.value) }
    private(set) var error: String?
    private let url: URL
    private var usable = true
    private struct Document: Codable { var version = 1; var runs: [XiaohongshuCollectionRun] }
    private struct Export: Codable {
        var run: XiaohongshuCollectionRun
        var recomputedStatistics: XiaohongshuCollectionStatistics
        var analysisStatus = "partial; only quoted visible OCR topics; unknown fields and unread media excluded"
    }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/xiaohongshu-collections.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            guard (try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 40_000_000 else {
                throw XiaohongshuCollectionError.unavailable
            }
            let value = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
            guard value.version == 1, value.runs.count <= 50,
                  Set(value.runs.map(\.id)).count == value.runs.count else { throw XiaohongshuCollectionError.invalidDocument }
            let validated = try value.runs.map { try ValidatedXiaohongshuCollectionRun(validating: $0) }
            canonicalRuns = validated
        } catch {
            usable = false; self.error = XiaohongshuCollectionError.unavailable.localizedDescription
        }
    }

    func run(id: String) throws -> XiaohongshuCollectionRun? {
        guard usable else { throw XiaohongshuCollectionError.unavailable }
        return canonicalRuns.first { $0.value.id == id }?.value
    }

    func save(_ run: XiaohongshuCollectionRun) throws {
        guard usable else { throw XiaohongshuCollectionError.unavailable }
        let validated = try ValidatedXiaohongshuCollectionRun(validating: run)
        if let existing = canonicalRuns.first(where: { $0.value.id == run.id }), existing.value.task != run.task {
            throw XiaohongshuCollectionError.conflictingTask
        }
        var next = canonicalRuns.filter { $0.value.id != run.id }; next.append(validated)
        try persist(next)
    }

    /// Appends only derived analysis to this Store's latest private validated
    /// value. The caller cannot supply a raw Run or a validation bypass flag.
    @discardableResult
    func appendAnalysis(_ segment: XiaohongshuAnalysisSegment, taskID: String, updatedAt: Date) throws -> XiaohongshuCollectionRun {
        guard usable else { throw XiaohongshuCollectionError.unavailable }
        guard let current = canonicalRuns.first(where: { $0.value.id == taskID }) else {
            throw XiaohongshuCollectionError.invalidTask
        }
        let validated = try current.appendingAnalysis(segment, updatedAt: updatedAt)
        var next = canonicalRuns.filter { $0.value.id != taskID }; next.append(validated)
        try persist(next)
        return validated.value
    }

    private func persist(_ next: [ValidatedXiaohongshuCollectionRun]) throws {
        guard next.count <= 50 else { throw XiaohongshuCollectionError.unavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(runs: next.map(\.value)))
        guard data.count <= 40_000_000 else { throw XiaohongshuCollectionError.unavailable }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if canImport(UIKit)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            // Keep the host's default protection for offline/macOS storage.
            // Applying the iOS-only policy can make a successful write unreadable.
            try data.write(to: url, options: .atomic)
            #endif
        } catch { throw XiaohongshuCollectionError.unavailable }
        canonicalRuns = next; error = nil
    }

    /// No analysis/model request is made while collecting. Exported evidence
    /// and program-derived statistics can be analyzed in a later independent job.
    func export(id: String) throws -> Data {
        guard let run = try run(id: id) else { throw XiaohongshuCollectionError.invalidTask }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(run: run, recomputedStatistics: run.statistics()))
    }
}
