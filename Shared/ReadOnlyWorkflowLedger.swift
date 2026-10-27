import Foundation
import CryptoKit
import Darwin

/// Immutable local scope, never a credential. Only its digest is written into a
/// workflow record; callers rotate generations whenever consent or a key changes.
struct ReadOnlyWorkflowConfiguration: Codable, Equatable, Sendable {
    var endpoint: String
    var recipient: String
    var model: String
    var credentialGeneration: UUID
    var consentGeneration: UUID
    var memoryRevision: String?
    var flightConnectionGeneration: UUID?
    var usesMemories = true
    /// The host can bind any additional request-policy settings without adding
    /// their contents to the persisted journal.
    var extraPolicyFingerprint: String?
    var fingerprint: String { ReadOnlyWorkflowDigest.of(self) }
}

enum ReadOnlyWorkflowStage: String, Codable, Sendable { case routing, flightQuery, answer }
struct ReadOnlyWorkflowRequest: Codable, Equatable, Sendable {
    var stage: ReadOnlyWorkflowStage
    var question: String
    var references = ""
    var fingerprint: String { ReadOnlyWorkflowDigest.of(self) }
    fileprivate var valid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        question.utf8.count <= 16_000 && references.utf8.count <= 64_000
    }
}

enum ReadOnlyWorkflowRoute: Codable, Equatable, Sendable {
    case flightQuery(question: String)
    case answer(question: String)
    /// Routing an action is data only. Recovery never restores phone authority.
    case requiresForeground
}

enum ReadOnlyWorkflowFailure: String, Codable, Sendable {
    case network, unauthorized, rateLimited, invalidResponse, credentialsUnavailable
    case transferMissing, scopeChanged, sourceDeleted, sourceChanged, foregroundActionRequired, deadline
}

enum ReadOnlyWorkflowResponse: Codable, Equatable, Sendable {
    case route(ReadOnlyWorkflowRoute)
    case text(String)
    case failure(ReadOnlyWorkflowFailure)
}

struct ReadOnlyWorkflowContext: Sendable {
    var configurationFingerprint: String
    /// Exact submitted-message membership; keeping a conversation with a deleted
    /// source message does not authorize an old result to reappear in it.
    var sourceMessages: [UUID: Set<UUID>]
    /// Digest of the immutable submitted message/attachment snapshot, independent
    /// of a stage's rewritten query. Same UUID with edited content is not a match.
    var sourceFingerprints: [UUID: String]
}

struct ReadOnlyWorkflowLease: Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let jobID: UUID
    let generation: UUID
    let stage: ReadOnlyWorkflowStage
    let attempt: Int
    let configurationFingerprint: String
    let requestFingerprint: String
}

/// A durable outbox value, not permission to write another store. The host must
/// serialize cancellation/deletion/edits with publication, then recheck its live
/// source and scope immediately before the conversation upsert (without a new
/// suspension between that check and the save).
struct ReadOnlyWorkflowPublication: Equatable, Sendable {
    let jobID: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let replyID: UUID
    let text: String
    let receivedAt: Date
}

struct ReadOnlyWorkflowJob: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case queued, transferring, resultReady, completed, needsForeground, cancelled, expired, abandoned }
    struct AppliedReceipt: Codable, Equatable, Sendable {
        let leaseID: UUID
        let responseFingerprint: String
    }
    let id: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let replyID: UUID
    let configurationFingerprint: String
    let initialRequestFingerprint: String
    let sourceFingerprint: String
    let createdAt: Date
    let deadline: Date
    var updatedAt: Date
    var request: ReadOnlyWorkflowRequest
    var state: State = .queued
    var generation = UUID()
    var attemptsInStage = 0
    var lease: ReadOnlyWorkflowLease?
    var appliedReceipts: [AppliedReceipt] = []
    var resultText: String?
    var resultReceivedAt: Date?
    var failure: ReadOnlyWorkflowFailure?
    var isUnsettled: Bool { [.queued, .transferring, .resultReady, .needsForeground].contains(state) }
    fileprivate var publication: ReadOnlyWorkflowPublication? {
        guard [.resultReady, .completed].contains(state), let resultText, let resultReceivedAt else { return nil }
        return .init(jobID: id, conversationID: conversationID, userMessageID: userMessageID,
                     replyID: replyID, text: resultText, receivedAt: resultReceivedAt)
    }
}

enum ReadOnlyWorkflowLedgerError: Error, Equatable {
    case invalid, unavailable, limit, unsupportedVersion, submissionConflict, storeChanged
}

enum ReadOnlyWorkflowReceiptDisposition: Equatable, Sendable {
    case applied, duplicate, stale, conflicting, rejected
}

/// A bounded, transactional outbox for three read-only network stages. A saved
/// lease may reattach to an existing transfer after process death. Disk state
/// never authorizes GUI actions or silently dispatches an absent transfer again.
actor ReadOnlyWorkflowLedger {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    private struct Document: Codable {
        var version = 1
        var jobs: [ReadOnlyWorkflowJob] = []
    }
    private let url: URL
    private let writer: Writer
    let maximumConcurrent: Int
    private var document: Document
    private var committedFileFingerprint: String?
    private var volatileCancellationIDs = Set<UUID>()
    private static let maximumBytes = 24_000_000
    private static let maximumJobs = 100
    private static let maximumAttempts = 2

    init(url: URL, maximumConcurrent: Int = 3, writer: @escaping Writer = { data, url in try ReadOnlyWorkflowLedger.atomicWrite(data, to: url) }) throws {
        guard (1...4).contains(maximumConcurrent) else { throw ReadOnlyWorkflowLedgerError.invalid }
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        self.url = normalizedURL; self.maximumConcurrent = maximumConcurrent; self.writer = writer
        if FileManager.default.fileExists(atPath: normalizedURL.path) {
            do {
                let size = try normalizedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumBytes
                guard size < Self.maximumBytes else { throw ReadOnlyWorkflowLedgerError.limit }
                let data = try Data(contentsOf: normalizedURL)
                let decoded = try JSONDecoder().decode(Document.self, from: data)
                guard decoded.version == 1 else { throw ReadOnlyWorkflowLedgerError.unsupportedVersion }
                try Self.validate(decoded)
                document = decoded; committedFileFingerprint = ReadOnlyWorkflowDigest.bytes(data)
            } catch let error as ReadOnlyWorkflowLedgerError { throw error }
            catch { throw ReadOnlyWorkflowLedgerError.unavailable }
        } else { document = Document(); committedFileFingerprint = nil }
    }

    func jobs() throws -> [ReadOnlyWorkflowJob] { try refresh(); return document.jobs }
    /// A caller must still cancel its OS transfer when durable cancellation
    /// fails. These IDs reject callbacks in this process until saving succeeds.
    func pendingCancellationIDs() -> Set<UUID> { volatileCancellationIDs }

    @discardableResult func submit(conversationID: UUID, userMessageID: UUID, configurationFingerprint: String, sourceFingerprint: String? = nil,
                                    request: ReadOnlyWorkflowRequest, deadline: Date, now: Date = Date()) throws -> ReadOnlyWorkflowJob {
        try refresh()
        let sourceFingerprint = sourceFingerprint ?? request.fingerprint
        guard Self.validFingerprint(configurationFingerprint), Self.validFingerprint(sourceFingerprint), request.valid, now.timeIntervalSince1970.isFinite,
              deadline > now, deadline.timeIntervalSince(now) <= 86_400 else { throw ReadOnlyWorkflowLedgerError.invalid }
        if let previous = document.jobs.first(where: { $0.conversationID == conversationID && $0.userMessageID == userMessageID }) {
            // Submission retries after a crash return the saved identity rather
            // than issue the same user's message as a second network job.
            guard previous.configurationFingerprint == configurationFingerprint,
                  previous.initialRequestFingerprint == request.fingerprint, previous.sourceFingerprint == sourceFingerprint else { throw ReadOnlyWorkflowLedgerError.submissionConflict }
            return previous
        }
        guard document.jobs.count < Self.maximumJobs else { throw ReadOnlyWorkflowLedgerError.limit }
        let job = ReadOnlyWorkflowJob(id: UUID(), conversationID: conversationID, userMessageID: userMessageID,
            replyID: UUID(), configurationFingerprint: configurationFingerprint, initialRequestFingerprint: request.fingerprint, sourceFingerprint: sourceFingerprint, createdAt: now,
            deadline: deadline, updatedAt: now, request: request)
        var next = document; next.jobs.append(job); try commit(next); return job
    }

    /// Persists before returning dispatch authority. A failed save returns no
    /// lease and leaves both the in-memory and on-disk snapshots unchanged.
    func leaseNext(context: ReadOnlyWorkflowContext, now: Date = Date()) throws -> ReadOnlyWorkflowLease? {
        try refresh()
        var next = document; try sweep(&next, context: context, now: now)
        guard next.jobs.filter({ $0.state == .transferring }).count < maximumConcurrent,
              let index = next.jobs.indices.filter({ next.jobs[$0].state == .queued }).min(by: {
                  let a = next.jobs[$0], b = next.jobs[$1]
                  return a.createdAt == b.createdAt ? a.id.uuidString < b.id.uuidString : a.createdAt < b.createdAt
              }) else {
            try commitIfChanged(next); return nil
        }
        var job = next.jobs[index]
        guard job.attemptsInStage < Self.maximumAttempts else { throw ReadOnlyWorkflowLedgerError.invalid }
        job.attemptsInStage += 1; job.updatedAt = now; job.state = .transferring
        let lease = ReadOnlyWorkflowLease(id: UUID(), jobID: job.id, generation: job.generation,
            stage: job.request.stage, attempt: job.attemptsInStage,
            configurationFingerprint: job.configurationFingerprint, requestFingerprint: job.request.fingerprint)
        job.lease = lease; next.jobs[index] = job; try commit(next); return lease
    }

    func request(for lease: ReadOnlyWorkflowLease, context: ReadOnlyWorkflowContext,
                 now: Date = Date()) throws -> ReadOnlyWorkflowRequest? {
        guard !volatileCancellationIDs.contains(lease.jobID) else { return nil }
        try refresh()
        var next = document; try sweep(&next, context: context, now: now); try commitIfChanged(next)
        guard !volatileCancellationIDs.contains(lease.jobID), let job = document.jobs.first(where: { $0.id == lease.jobID }),
              job.state == .transferring, job.lease == lease,
              job.configurationFingerprint == context.configurationFingerprint,
              context.sourceMessages[job.conversationID]?.contains(job.userMessageID) == true,
              context.sourceFingerprints[job.userMessageID] == job.sourceFingerprint else { return nil }
        return job.request
    }

    @discardableResult func receive(lease: ReadOnlyWorkflowLease, response: ReadOnlyWorkflowResponse,
                                    context: ReadOnlyWorkflowContext, now: Date = Date()) throws -> ReadOnlyWorkflowReceiptDisposition {
        guard !volatileCancellationIDs.contains(lease.jobID) else { return .stale }
        try refresh()
        var next = document; try sweep(&next, context: context, now: now)
        guard let index = next.jobs.firstIndex(where: { $0.id == lease.jobID }) else { try commitIfChanged(next); return .stale }
        var job = next.jobs[index]
        guard job.configurationFingerprint == context.configurationFingerprint,
              context.sourceMessages[job.conversationID]?.contains(job.userMessageID) == true,
              context.sourceFingerprints[job.userMessageID] == job.sourceFingerprint,
              ![.cancelled, .expired, .abandoned].contains(job.state) else { try commitIfChanged(next); return .stale }
        let responseFingerprint = ReadOnlyWorkflowDigest.of(response)
        if let receipt = job.appliedReceipts.first(where: { $0.leaseID == lease.id }) {
            try commitIfChanged(next)
            return receipt.responseFingerprint == responseFingerprint ? .duplicate : .conflicting
        }
        guard job.state == .transferring, job.lease == lease,
              lease.generation == job.generation, lease.requestFingerprint == job.request.fingerprint else {
            try commitIfChanged(next); return .stale
        }
        switch response {
        case .route(let route):
            guard job.request.stage == .routing else { return try rejectReceipt(at: index, fingerprint: responseFingerprint, in: &next, now: now) }
            switch route {
            case .flightQuery(let question), .answer(let question):
                let stage: ReadOnlyWorkflowStage
                if case .flightQuery = route { stage = .flightQuery } else { stage = .answer }
                let request = ReadOnlyWorkflowRequest(stage: stage, question: question, references: job.request.references)
                guard request.valid else { return try rejectReceipt(at: index, fingerprint: responseFingerprint, in: &next, now: now) }
                job.request = request; job.state = .queued; job.generation = UUID(); job.attemptsInStage = 0
            case .requiresForeground:
                job.state = .needsForeground; job.failure = .foregroundActionRequired
            }
        case .text(let text):
            guard job.request.stage != .routing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 64_000 else { return try rejectReceipt(at: index, fingerprint: responseFingerprint, in: &next, now: now) }
            job.resultText = text; job.resultReceivedAt = now; job.state = .resultReady; job.failure = nil
        case .failure(let reason):
            guard [.network, .unauthorized, .rateLimited, .invalidResponse, .credentialsUnavailable].contains(reason) else { return try rejectReceipt(at: index, fingerprint: responseFingerprint, in: &next, now: now) }
            job.state = .needsForeground; job.failure = reason
        }
        job.appliedReceipts.append(.init(leaseID: lease.id, responseFingerprint: responseFingerprint))
        job.lease = nil; job.updatedAt = now; next.jobs[index] = job; try commit(next); return .applied
    }

    private func rejectReceipt(at index: Int, fingerprint: String, in next: inout Document,
                               now: Date) throws -> ReadOnlyWorkflowReceiptDisposition {
        next.jobs[index].state = .needsForeground; next.jobs[index].failure = .invalidResponse
        next.jobs[index].appliedReceipts.append(.init(leaseID: next.jobs[index].lease!.id, responseFingerprint: fingerprint))
        next.jobs[index].lease = nil; next.jobs[index].generation = UUID(); next.jobs[index].updatedAt = now
        try commit(next); return .rejected
    }

    /// Reattach only exact existing transfer IDs. An absent transfer becomes a
    /// visible checkpoint; it is never silently sent again on app relaunch.
    @discardableResult func reconcile(activeLeaseIDs: Set<UUID>, context: ReadOnlyWorkflowContext,
                                      now: Date = Date()) throws -> [ReadOnlyWorkflowJob] {
        try refresh()
        var next = document; try sweep(&next, context: context, now: now)
        for index in next.jobs.indices where next.jobs[index].state == .transferring {
            guard let lease = next.jobs[index].lease, !activeLeaseIDs.contains(lease.id) else { continue }
            next.jobs[index].state = .needsForeground; next.jobs[index].failure = .transferMissing
            next.jobs[index].lease = nil; next.jobs[index].generation = UUID(); next.jobs[index].updatedAt = now
        }
        try commitIfChanged(next); return document.jobs
    }

    /// Explicit continuation of a read-only stage only. A resolved action route,
    /// changed scope, deleted source or exhausted retry budget cannot enter here.
    @discardableResult func retry(_ jobID: UUID, context: ReadOnlyWorkflowContext, now: Date = Date()) throws -> Bool {
        try refresh()
        var next = document; try sweep(&next, context: context, now: now)
        guard let index = next.jobs.firstIndex(where: { $0.id == jobID }),
              next.jobs[index].state == .needsForeground,
              [.network, .transferMissing, .credentialsUnavailable].contains(next.jobs[index].failure),
              next.jobs[index].configurationFingerprint == context.configurationFingerprint,
              next.jobs[index].deadline > now, next.jobs[index].attemptsInStage < Self.maximumAttempts else {
            try commitIfChanged(next); return false
        }
        next.jobs[index].state = .queued; next.jobs[index].failure = nil
        next.jobs[index].generation = UUID(); next.jobs[index].updatedAt = now
        try commit(next); return true
    }

    /// Tombstone commits before the caller cancels the corresponding OS task.
    /// Cancellation cannot erase the job and make a late callback look new.
    @discardableResult func cancel(_ jobID: UUID, now: Date = Date()) throws -> Bool {
        do { try refresh() }
        catch {
            if document.jobs.contains(where: { $0.id == jobID && $0.state != .completed }) { volatileCancellationIDs.insert(jobID) }
            throw error
        }
        guard let index = document.jobs.firstIndex(where: { $0.id == jobID }), document.jobs[index].state != .completed else { return false }
        if document.jobs[index].state == .cancelled { return true }
        var next = document
        next.jobs[index].state = .cancelled; next.jobs[index].lease = nil
        next.jobs[index].generation = UUID(); next.jobs[index].updatedAt = now
        next.jobs[index].resultText = nil; next.jobs[index].resultReceivedAt = nil
        do { try commit(next) }
        catch { volatileCancellationIDs.insert(jobID); throw error }
        return true
    }

    func pendingPublications(context: ReadOnlyWorkflowContext, now: Date = Date()) throws -> [ReadOnlyWorkflowPublication] {
        try refresh()
        var next = document; try sweep(&next, context: context, now: now); try commitIfChanged(next)
        return document.jobs.filter { $0.state == .resultReady }.compactMap(\.publication)
    }

    /// The host's serialized coordinator must revalidate source/scope/cancellation
    /// at its conversation-save boundary and upsert the exact replyID. This is
    /// acknowledgement only, not retroactive authorization for an external save.
    /// After a crash, the same replyID makes the host's idempotent upsert safe;
    /// this ledger cannot make an unrelated conversation store transaction atomic.
    @discardableResult func acknowledgePublished(_ publication: ReadOnlyWorkflowPublication,
                                                context: ReadOnlyWorkflowContext, now: Date = Date()) throws -> Bool {
        try refresh()
        var next = document; try sweep(&next, context: context, now: now)
        guard let index = next.jobs.firstIndex(where: { $0.id == publication.jobID }),
              next.jobs[index].publication == publication,
              next.jobs[index].configurationFingerprint == context.configurationFingerprint,
              context.sourceMessages[publication.conversationID]?.contains(publication.userMessageID) == true,
              context.sourceFingerprints[publication.userMessageID] == next.jobs[index].sourceFingerprint,
              [.resultReady, .completed].contains(next.jobs[index].state) else { try commitIfChanged(next); return false }
        if next.jobs[index].state == .completed { try commitIfChanged(next); return true }
        next.jobs[index].state = .completed; next.jobs[index].updatedAt = now
        try commit(next); return true
    }

    /// Explicit terminal-history deletion only. Active and review checkpoints
    /// survive. Late callbacks for removed IDs remain stale, never new jobs.
    @discardableResult func removeFinished(_ ids: Set<UUID>) throws -> Int {
        try refresh()
        var next = document
        let count = next.jobs.count
        next.jobs.removeAll { ids.contains($0.id) && !$0.isUnsettled }
        try commitIfChanged(next); return count - next.jobs.count
    }

    private func sweep(_ next: inout Document, context: ReadOnlyWorkflowContext, now: Date) throws {
        guard Self.validFingerprint(context.configurationFingerprint), now.timeIntervalSince1970.isFinite else {
            throw ReadOnlyWorkflowLedgerError.invalid
        }
        for index in next.jobs.indices {
            if volatileCancellationIDs.contains(next.jobs[index].id), next.jobs[index].state != .completed {
                next.jobs[index].state = .cancelled; next.jobs[index].lease = nil
                next.jobs[index].generation = UUID(); next.jobs[index].updatedAt = now
                next.jobs[index].resultText = nil; next.jobs[index].resultReceivedAt = nil
            }
            let sourceExists = context.sourceMessages[next.jobs[index].conversationID]?.contains(next.jobs[index].userMessageID) == true
            guard next.jobs[index].isUnsettled || !sourceExists else { continue }
            let reason: ReadOnlyWorkflowFailure?
            if !sourceExists { reason = .sourceDeleted }
            else if context.sourceFingerprints[next.jobs[index].userMessageID] != next.jobs[index].sourceFingerprint { reason = .sourceChanged }
            else if next.jobs[index].configurationFingerprint != context.configurationFingerprint { reason = .scopeChanged }
            else if [.queued, .transferring, .needsForeground].contains(next.jobs[index].state), now >= next.jobs[index].deadline { reason = .deadline }
            else { reason = nil }
            guard let reason else { continue }
            let state: ReadOnlyWorkflowJob.State = reason == .sourceDeleted ? .abandoned : reason == .deadline ? .expired : .needsForeground
            guard next.jobs[index].state != state || next.jobs[index].failure != reason || next.jobs[index].lease != nil else { continue }
            next.jobs[index].state = state; next.jobs[index].failure = reason; next.jobs[index].lease = nil
            next.jobs[index].generation = UUID(); next.jobs[index].updatedAt = now
            if reason == .sourceDeleted {
                next.jobs[index].request.question = "已删除的会话请求"; next.jobs[index].request.references = ""
                next.jobs[index].resultText = nil; next.jobs[index].resultReceivedAt = nil
            }
        }
    }

    private func refresh() throws {
        try withFileLock {
            let data = try diskData()
            let fingerprint = data.map(ReadOnlyWorkflowDigest.bytes)
            guard fingerprint != committedFileFingerprint else { return }
            guard let data else { throw ReadOnlyWorkflowLedgerError.storeChanged }
            do {
                let latest = try JSONDecoder().decode(Document.self, from: data)
                guard latest.version == 1 else { throw ReadOnlyWorkflowLedgerError.unsupportedVersion }
                try Self.validate(latest)
                document = latest; committedFileFingerprint = fingerprint
                volatileCancellationIDs.subtract(latest.jobs.filter { [.cancelled, .abandoned].contains($0.state) }.map(\.id))
            } catch let error as ReadOnlyWorkflowLedgerError { throw error }
            catch { throw ReadOnlyWorkflowLedgerError.unavailable }
        }
    }
    private func diskData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumBytes
        guard size < Self.maximumBytes else { throw ReadOnlyWorkflowLedgerError.limit }
        return try Data(contentsOf: url)
    }
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw ReadOnlyWorkflowLedgerError.unavailable }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw ReadOnlyWorkflowLedgerError.unavailable }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        } catch let error as ReadOnlyWorkflowLedgerError { throw error }
        catch { throw ReadOnlyWorkflowLedgerError.unavailable }
    }
    private func commitIfChanged(_ next: Document) throws {
        if next.jobs != document.jobs { try commit(next) }
    }
    private func commit(_ next: Document) throws {
        try Self.validate(next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count < Self.maximumBytes else { throw ReadOnlyWorkflowLedgerError.limit }
        try withFileLock {
            let current = try diskData().map(ReadOnlyWorkflowDigest.bytes)
            guard current == committedFileFingerprint else { throw ReadOnlyWorkflowLedgerError.storeChanged }
            do { try writer(data, url) } catch { throw ReadOnlyWorkflowLedgerError.unavailable }
            committedFileFingerprint = ReadOnlyWorkflowDigest.bytes(data)
        }
        document = next
        volatileCancellationIDs.subtract(next.jobs.filter { [.cancelled, .abandoned].contains($0.state) }.map(\.id))
    }
    private static func validFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && ($0.isHexDigit && !$0.isUppercase) }
    }
    private static func validate(_ document: Document) throws {
        guard document.version == 1, document.jobs.count <= maximumJobs,
              Set(document.jobs.map(\.id)).count == document.jobs.count,
              Set(document.jobs.map(\.replyID)).count == document.jobs.count,
              Set(document.jobs.map { $0.conversationID.uuidString + ":" + $0.userMessageID.uuidString }).count == document.jobs.count else { throw ReadOnlyWorkflowLedgerError.invalid }
        for job in document.jobs {
            guard validFingerprint(job.configurationFingerprint), validFingerprint(job.initialRequestFingerprint), validFingerprint(job.sourceFingerprint), job.request.valid,
                  job.createdAt.timeIntervalSince1970.isFinite, job.updatedAt.timeIntervalSince1970.isFinite,
                  job.deadline > job.createdAt, job.deadline.timeIntervalSince(job.createdAt) <= 86_400,
                  (0...maximumAttempts).contains(job.attemptsInStage), job.appliedReceipts.count <= 4,
                  Set(job.appliedReceipts.map(\.leaseID)).count == job.appliedReceipts.count,
                  (job.resultText?.utf8.count ?? 0) <= 64_000,
                  job.state == .transferring ? job.lease != nil : job.lease == nil else { throw ReadOnlyWorkflowLedgerError.invalid }
            if let lease = job.lease {
                guard lease.jobID == job.id, lease.generation == job.generation,
                      lease.stage == job.request.stage, lease.attempt == job.attemptsInStage,
                      lease.configurationFingerprint == job.configurationFingerprint,
                      lease.requestFingerprint == job.request.fingerprint else { throw ReadOnlyWorkflowLedgerError.invalid }
            }
            if [.resultReady, .completed].contains(job.state) {
                guard job.publication != nil, job.request.stage != .routing,
                      job.resultText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      job.resultReceivedAt?.timeIntervalSince1970.isFinite == true else { throw ReadOnlyWorkflowLedgerError.invalid }
            }
            guard job.appliedReceipts.allSatisfy({ validFingerprint($0.responseFingerprint) }) else { throw ReadOnlyWorkflowLedgerError.invalid }
        }
    }
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}

private enum ReadOnlyWorkflowDigest {
    static func of<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // All callers use finite, bounded Foundation-free request data. A failed
        // encoding is never turned into an accepted scope or response digest.
        guard let data = try? encoder.encode(value) else { return "" }
        return bytes(data)
    }
    static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
